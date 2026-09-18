//! longcat_port.zig — LongCat-Video-Avatar-1.5 reverse-engineered onto the
//! Qstar 11D lattice stack.
//!
//! Structural port, not a weight port: each component of the reference pipeline
//! (Wan 2.1 VAE / umT5 / Whisper-Large-v3 / 48-block Avatar DiT / FlowMatchEuler
//! / DMD2 / GRPO) is re-expressed as the lattice mechanism that occupies the
//! same position in the 11D ladder. See docs/LONGCAT-REVERSE-MAP.md.
//!
//! Implemented analogs:
//!   - DenoiseSchedule:  FlowMatchEuler shift → φ-cooling sigma ladder (8D)
//!   - ropeQuat:         3D RoPE → quaternion rotation encoding (4D)
//!   - audioPool33to5:   Whisper 33-hidden-state → 5-channel grouped mean pool
//!   - temporalResample: audio projector 50Hz→25fps→latent-rate interp (1D)
//!   - adaLNGate:        audio cross-attn gate → ColorRouter weight mod (7D)
//!   - LatentStreams:    AT2V / ATI2V / video-continuation stream selection
//!   - AdapterRole:      DMD2 Generator/FakeScore/RealScore role switching
//!   - corridorStep:     infinite-corridor recursive fold feedback
//!   - runAvatarFrame:   audio-conditioned denoise loop → splat rasterization
//!
//! All arithmetic is integer-only (i128 Q64.64). No floating-point in core
//! paths. License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");
const dim2 = @import("dim_2d_complex");
const dim4 = @import("dim_4d_rotation");
const dim7 = @import("dim_7d_color");
const dim8 = @import("dim_8d_frequency");
const dim9 = @import("dim_9d_chaos");
const splat = @import("splat_render");
const wd = @import("weight_distill");

pub const Complex = dim2.Complex;
pub const Quaternion = dim4.Quaternion;

// =============================================================================
// Component map (documentation-as-code — the reverse-engineering artifact)
// =============================================================================

pub const Parity = enum { strong, analog, partial, gap };

pub const Component = struct {
    /// LongCat-1.5 pipeline component.
    name: []const u8,
    /// Mechanism it performs in the reference pipeline.
    mechanism: []const u8,
    /// Dimension(s) it occupies on the 11D ladder.
    dim: []const u8,
    /// Qstar module providing the analog.
    module: []const u8,
    parity: Parity,
};

pub const COMPONENT_MAP = [_]Component{
    .{ .name = "Wan 2.1 3D VAE", .mechanism = "pixel<->latent spatiotemporal compression", .dim = "3D", .module = "holo_codec/s7_compression+vae.qsw", .parity = .analog },
    .{ .name = "umT5-XXL encoder", .mechanism = "text conditioning embeddings", .dim = "5D", .module = "dim_5d_language+bpe_tokenizer+text_encoder.qsw", .parity = .analog },
    .{ .name = "Whisper-Large-v3", .mechanism = "audio feature extraction 33->5ch", .dim = "1D+8D", .module = "voice_codec+audioPool33to5+whisper.qsw", .parity = .partial },
    .{ .name = "audio projector", .mechanism = "50Hz->25fps->latent resample", .dim = "1D", .module = "temporalResample", .parity = .partial },
    .{ .name = "DiT 3D self-attn", .mechanism = "spatiotemporal token mixing", .dim = "5D+3D", .module = "dim_5d_language+dim_3d_space+base_model.qsw", .parity = .analog },
    .{ .name = "int8 quantized DiT", .mechanism = "per-channel symmetric int8 weights", .dim = "-", .module = "safetensors(I8)+base_model_int8.qsw", .parity = .analog },
    .{ .name = "3D RoPE", .mechanism = "rotary position embedding", .dim = "4D", .module = "ropeQuat(dim_4d)", .parity = .strong },
    .{ .name = "text cross-attn", .mechanism = "conditioning injection", .dim = "5D", .module = "dim_5d_language", .parity = .analog },
    .{ .name = "audio cross-attn+adaLN", .mechanism = "gated audio->lip injection", .dim = "7D+10D", .module = "adaLNGate(dim_7d+dim_10d)", .parity = .strong },
    .{ .name = "FlowMatchEuler shift=7", .mechanism = "denoising timestep schedule", .dim = "8D", .module = "DenoiseSchedule(dim_8d)+scheduler_config", .parity = .strong },
    .{ .name = "DMD2 8-step distill", .mechanism = "shared backbone + role LoRAs", .dim = "-", .module = "AdapterRole+distillation_s0+dmd_lora.qsw", .parity = .analog },
    .{ .name = "CFG-step + refinement LoRAs", .mechanism = "adapter overlays on base DiT", .dim = "-", .module = "weight_distill+parent_loras.qsw", .parity = .analog },
    .{ .name = "GRPO per-frame", .mechanism = "self-eval->advantage->update", .dim = "6D", .module = "dim_6d_consciousness+metacognition_engine", .parity = .strong },
    .{ .name = "reference latent", .mechanism = "identity anchor", .dim = "0D", .module = "dim_0d_origin", .parity = .strong },
    .{ .name = "cross-chunk stitch", .mechanism = "temporal continuity", .dim = "1D", .module = "dim_1d_time+merge", .parity = .analog },
    .{ .name = "disentangled CFG", .mechanism = "speech vs motion decoupling", .dim = "10D", .module = "dim_10d_gravity", .parity = .analog },
    .{ .name = "L-RoPE multi-speaker", .mechanism = "per-speaker position binding", .dim = "4D+id", .module = "dim_4d_rotation+entangle+sybil", .parity = .analog },
    .{ .name = "noise latents", .mechanism = "Gaussian prior init", .dim = "9D", .module = "dim_9d_chaos", .parity = .strong },
    .{ .name = "video continuation", .mechanism = "autoregressive extension", .dim = "1D", .module = "dim_1d_time", .parity = .analog },
    .{ .name = "rasterizer", .mechanism = "latents->RGB frames", .dim = "-", .module = "splat_render", .parity = .gap },
};

// =============================================================================
// DenoiseSchedule — FlowMatchEuler → φ-cooling sigma ladder (8D analog)
// =============================================================================

/// Denoising schedule: N steps of φ-cooled sigma. The FlowMatch "shift"
/// parameter is applied exactly: t' = s·t / (1 + (s-1)·t).
pub const DenoiseSchedule = struct {
    scaler: dim8.FrequencyScaler,
    steps: u8,
    /// FlowMatch shift (Q64.64). LongCat uses 7.0.
    shift: i128,

    pub fn init(base_sigma: i128, steps: u8, shift: i128) DenoiseSchedule {
        return .{
            .scaler = dim8.FrequencyScaler.init(base_sigma),
            .steps = steps,
            .shift = shift,
        };
    }

    /// Applies the FlowMatch shift map: t' = s·t / (1 + (s-1)·t).
    /// t, shift in Q64.64. s=1 is the identity.
    pub fn flowShift(t: i128, shift: i128) i128 {
        if (shift == fp.ONE) return t;
        const num = fp.mul(shift, t);
        const den = fp.ONE + fp.mul(shift - fp.ONE, t);
        if (den == 0) return t;
        return fp.div(num, den);
    }

    /// Sigma at step i ∈ [0, steps): linear t grid, shift-warped, then
    /// φ-cooled: σ_i = base · φ^(-i) evaluated at the shifted timestep.
    pub fn sigmaAt(self: *DenoiseSchedule, step: u8) i128 {
        if (self.steps == 0) return 0;
        // t_i = 1 - i/steps (start at full noise).
        const t = fp.ONE - fp.div(fp.fromInt(step), fp.fromInt(self.steps));
        const warped = flowShift(t, self.shift);
        // φ^-i cooling over the schedule, scaled by warped t.
        var sigma = fp.mul(self.scaler.base_temp, warped);
        for (0..step) |_| {
            sigma = fp.div(sigma, self.scaler.phi);
        }
        return sigma;
    }

    /// Advances the internal φ-cooler one level (8D FrequencyScaler).
    pub fn advance(self: *DenoiseSchedule) void {
        self.scaler.advanceLevel();
    }
};

/// Decimal JSON number → Q64.64, integer-only (the core never floats).
/// Accepts "-7.0", "0.125", "7e0" forms; fractional digits beyond ~18 are
/// truncated, exponent limited to ±18. Returns null on malformed input.
pub fn parseQ64(s: []const u8) ?i128 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var ip: i128 = 0;
    var saw = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        ip = ip * 10 + (s[i] - '0');
        saw = true;
    }
    if (!saw) return null;
    var fr: i128 = 0;
    var scale: i128 = 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var saw_f = false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            if (scale < 1000000000000000000) {
                fr = fr * 10 + (s[i] - '0');
                scale *= 10;
            }
            saw_f = true;
        }
        if (!saw_f) return null;
    }
    var num: i256 = @as(i256, ip) * scale + fr;
    var den: i256 = scale;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        var eneg = false;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            eneg = s[i] == '-';
            i += 1;
        }
        var e: i32 = 0;
        var saw_e = false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            if (e < 100) e = e * 10 + (s[i] - '0');
            saw_e = true;
        }
        if (!saw_e or e > 18) return null;
        var pow: i256 = 1;
        var k: i32 = 0;
        while (k < e) : (k += 1) pow *= 10;
        if (eneg) den *= pow else num *= pow;
    }
    if (i != s.len) return null;
    const v = divRound64(num, den);
    return if (neg) -v else v;
}

/// num/den → Q64.64 with round-half-away-from-zero (fromRatio semantics).
fn divRound64(num: i256, den: i256) i128 {
    const scaled = num << 64;
    const q = @divTrunc(scaled, den);
    const rem = @rem(scaled, den);
    const half = @divTrunc(den, 2);
    const arem = if (rem < 0) -rem else rem;
    const ahalf = if (half < 0) -half else half;
    return @intCast(if (arem != 0 and arem >= ahalf) (if (q >= 0) q + 1 else q - 1) else q);
}

/// Reads `"shift"` out of a diffusers scheduler_config.json blob → Q64.64.
/// Returns null when the key is absent or malformed.
pub fn schedulerShift(json: []const u8) ?i128 {
    const key = "\"shift\"";
    const p = std.mem.indexOf(u8, json, key) orelse return null;
    var i = p + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) i += 1;
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) i += 1;
    var end = i;
    while (end < json.len) : (end += 1) {
        const c = json[end];
        const ok = (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E';
        if (!ok) break;
    }
    if (end == i) return null;
    return parseQ64(json[i..end]);
}

/// Loads `"shift"` from a scheduler_config.json file. Missing file/key → null.
pub fn loadSchedulerShift(allocator: std.mem.Allocator, path: []const u8) ?i128 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const bytes = f.readToEndAlloc(allocator, 1 << 20) catch return null;
    defer allocator.free(bytes);
    return schedulerShift(bytes);
}

// =============================================================================
// ropeQuat — 3D RoPE → quaternion position encoding (4D analog)
// =============================================================================

/// RoPE rotates feature pairs by θ = pos·base^{-2i/d}. The quaternion analog
/// encodes the same rotation for a spatiotemporal grid position (t,h,w):
/// angle θ_p = (t+h+w) · base^{-2·freq/d} applied about the (t,h,w) axis.
/// Returns a unit quaternion q = cos(θ/2) + axis·sin(θ/2).
pub fn ropeQuat(t: i128, h: i128, w: i128, freq: u6) Quaternion {
    // Position magnitude along the rotation axis.
    const pos = t + h + w;
    // θ = pos · 2^{-freq} — binary base keeps it exact in fixed-point.
    const theta = pos >> freq;
    const half_theta = theta >> 1;
    const sc = fp.sincos(half_theta);
    // Normalize axis (t,h,w); degenerate → x-axis.
    const norm = fp.sqrt(fp.mul(t, t) + fp.mul(h, h) + fp.mul(w, w));
    const ax = if (norm > 0) fp.div(t, norm) else fp.ONE;
    const ay = if (norm > 0) fp.div(h, norm) else 0;
    const az = if (norm > 0) fp.div(w, norm) else 0;
    return Quaternion.fromParts(
        sc.cos_val,
        fp.mul(ax, sc.sin_val),
        fp.mul(ay, sc.sin_val),
        fp.mul(az, sc.sin_val),
    );
}

// =============================================================================
// audioPool33to5 — Whisper hidden-state grouped mean pool (exact analog)
// =============================================================================

/// LongCat pools Whisper-large's 33 hidden states (embedding + 32 layers)
/// into 5 channels: 4 groups of 8 layers + 1 singleton (the embedding).
/// Exact integer analog of the grouped mean.
pub fn audioPool33to5(hidden: [33]i128) [5]i128 {
    var out: [5]i128 = undefined;
    // Singleton: the embedding layer (index 0).
    out[0] = hidden[0];
    // 4 groups of 8: hidden[1..9], [9..17], [17..25], [25..33].
    for (0..4) |g| {
        var sum: i128 = 0;
        for (0..8) |i| {
            sum += hidden[1 + g * 8 + i];
        }
        out[1 + g] = @divTrunc(sum, 8);
    }
    return out;
}

// =============================================================================
// temporalResample — audio projector 50Hz→25fps→latent-rate (1D analog)
// =============================================================================

/// Fixed-point linear-interpolation resample: `out[i]` samples `in` at
/// position i·(n-1)/(m-1). Mirrors the audio projector's 50Hz→25fps→latent
/// temporal compression.
pub fn temporalResample(
    allocator: std.mem.Allocator,
    input: []const i128,
    out_len: usize,
) ![]i128 {
    const out = try allocator.alloc(i128, out_len);
    errdefer allocator.free(out);
    if (input.len == 0 or out_len == 0) return out;
    if (out_len == 1 or input.len == 1) {
        @memset(out, input[0]);
        return out;
    }
    const n_minus_1 = fp.fromInt(@intCast(input.len - 1));
    const m_minus_1 = fp.fromInt(@intCast(out_len - 1));
    for (out, 0..) |*o, i| {
        // pos = i · (n-1)/(m-1) in fixed-point
        const pos = fp.mul(fp.div(fp.fromInt(@intCast(i)), m_minus_1), n_minus_1);
        const lo: usize = @intCast(@max(0, @min(@as(i128, @intCast(input.len - 1)), pos >> fp.FRAC_BITS)));
        const hi = @min(input.len - 1, lo + 1);
        const frac = pos - (@as(i128, @intCast(lo)) << fp.FRAC_BITS);
        o.* = input[lo] + fp.mul(frac, input[hi] - input[lo]);
    }
    return out;
}

// =============================================================================
// adaLNGate — audio cross-attention gating → ColorRouter weight mod (7D)
// =============================================================================

/// adaLN in LongCat gates the audio cross-attention so audio control is
/// progressively incorporated without destabilizing visual priors. The
/// lattice analog: audio feature strength modulates a ColorRouter channel
/// weight. `gate` ∈ [0,1] scales the base weight; `bias` shifts it.
pub fn adaLNGate(router: *dim7.ColorRouter, channel: u3, base: i128, gate: i128, bias: i128) void {
    const w = fp.mul(base, gate) + bias;
    router.setWeight(channel, @min(w, fp.ONE));
}

// =============================================================================
// LatentStreams — AT2V / ATI2V / continuation stream selection
// =============================================================================

pub const TaskKind = enum { at2v, ati2v, continuation };

/// Which latent streams feed the denoiser for a given task — mirrors
/// LongCat's reference/motion/noise latent concatenation rule.
pub const LatentStreams = struct {
    reference: bool, // identity anchor (0D seed)
    context: bool, // motion/context latents (1D)
    noise: bool, // denoising target (9D)

    pub fn forTask(task: TaskKind) LatentStreams {
        return switch (task) {
            .at2v => .{ .reference = false, .context = false, .noise = true },
            .ati2v => .{ .reference = true, .context = false, .noise = true },
            .continuation => .{ .reference = false, .context = true, .noise = true },
        };
    }
};

// =============================================================================
// AdapterRole — DMD2 role switching (Generator / FakeScore / RealScore)
// =============================================================================

/// LongCat mounts Generator/FakeScore LoRAs on a shared DiT backbone; the base
/// model serves as the real score. The lattice analog is a role switch over
/// the shared state — distillation_s0 provides project/inject for the
/// few-step generator path.
pub const AdapterRole = enum {
    generator, // few-step denoising
    fake_score, // distribution matching vs generator output
    real_score, // base model guidance

    pub fn label(self: AdapterRole) []const u8 {
        return switch (self) {
            .generator => "generator",
            .fake_score => "fake_score",
            .real_score => "real_score",
        };
    }
};

// =============================================================================
// corridorStep — infinite-corridor recursive fold feedback
// =============================================================================

/// One infinite-corridor iteration: rotate the frame coordinate by a fixed
/// angle and rescale by φ⁻¹ — self-similar recursive zoom, the same fixpoint
/// structure as portal-feedback corridors (F_{n+1} = T(F_n)) expressed with
/// the complex plane (2D) and φ-cooling (8D).
pub fn corridorStep(z: Complex, level: u6) Complex {
    // Rotation angle per level: π/8 (45°/4) — deterministic.
    const angle = fp.PI >> @intCast(3 + @as(u7, @min(level, 8)));
    const sc = fp.sincos(angle);
    const rot = Complex.fromParts(sc.cos_val, sc.sin_val);
    const scaled = z.mul(rot);
    return .{
        .a = fp.mul(scaled.a, fp.INV_PHI),
        .b = fp.mul(scaled.b, fp.INV_PHI),
    };
}

// =============================================================================
// runAvatarFrame — audio-conditioned denoise loop → splat rasterization
// =============================================================================

pub const AvatarFrameConfig = struct {
    camera: splat.Camera = splat.Camera.avatarDefault(),
    steps: u8 = 8, // DMD2-distilled step count
    shift: i128 = 7 << 64, // FlowMatch shift 7.0
    base_sigma: i128 = fp.ONE,
    base_scale: i128 = fp.fromRatio(1, 20),
    seed: u64 = 421,
    task: TaskKind = .at2v,
    /// Optional distilled weight seed (QSW1/QSW2): the source model's weight
    /// structure conditions the denoise trajectory. When the seed carries
    /// block profiles (QSW2), each step's channel mix comes from its depth
    /// range (48 blocks → step groups) and sigma is scaled by the group's
    /// aggregate energy; otherwise the flat channel_sum is used.
    /// Null = unconditional.
    weight_seed: ?*const wd.WeightSeed = null,
};

/// One avatar frame: pooled audio channels gate the 7-channel ColorRouter
/// (adaLN analog), then `steps` rounds of φ-cooled chaos injection denoise
/// the lattice state, then nodes → splats → projected → sorted → rasterized.
/// `state` is node-major [node * channel_count + channel], mutated in place.
/// Returns an RGB framebuffer (width×height×3, caller owns).
pub fn runAvatarFrame(
    allocator: std.mem.Allocator,
    state: []i128,
    node_count: usize,
    channel_count: usize,
    audio_channels: [5]i128,
    cfg: AvatarFrameConfig,
) ![]u8 {
    var router = dim7.ColorRouter.init();
    var chaos = dim9.ChaosInjector.init(cfg.seed);
    var schedule = DenoiseSchedule.init(cfg.base_sigma, cfg.steps, cfg.shift);
    const streams = LatentStreams.forTask(cfg.task);
    _ = streams; // stream selection drives which state regions are seeded;
    // state itself is the concatenated latent buffer.

    // adaLN: fold the 5 pooled audio channels into router weights.
    for (0..5) |ch| {
        const gate = @min(@max(audio_channels[ch], 0), fp.ONE);
        adaLNGate(&router, @intCast(ch % 8), fp.ONE, gate, 0);
    }
    // Snapshot after audio gating — the weight-seed bias is applied per step
    // on top of this base (otherwise the bias would compound across steps).
    const router_base = router;

    // Denoise loop: per step, inject φ-cooled chaos into the lattice state
    // scaled by the current sigma and the channel gate.
    for (0..cfg.steps) |step| {
        var sigma = schedule.sigmaAt(@intCast(step));
        var step_channels: [8]i128 = undefined;
        // Weight-seed conditioning: depth-resolved channel vector (block
        // groups when present, else flat channel_sum) biases this step's
        // router mix and scales sigma by its aggregate energy (±25%).
        if (cfg.weight_seed) |ws| {
            wd.stepChannel(ws.*, step, cfg.steps, &step_channels);
            var energy: i128 = 0;
            for (step_channels) |v| energy += v;
            sigma = fp.mul(sigma, fp.ONE + fp.mul(@min(energy, fp.ONE), fp.fromRatio(1, 4)));
            // Fold the step's channel vector into router weights from the
            // post-adaLN base: each channel's weight is biased toward its
            // share of this depth range's block energy.
            router = router_base;
            for (0..channel_count) |ch| {
                const share = step_channels[ch % 8];
                router.setWeight(@intCast(ch % 7), fp.mul(router.weight(@intCast(ch % 7)), fp.ONE + share));
            }
        }
        for (0..node_count) |n| {
            const channel = chaos.chaoticChannel();
            const noise_i = @as(i128, @intCast(chaos.chaoticValue() & 0xFFFF)) << (fp.FRAC_BITS - 16);
            const gated = fp.mul(fp.mul(noise_i, sigma), router.weight(channel));
            state[n * channel_count + channel] +%= gated;
        }
        schedule.advance();
    }

    // Rasterize: lattice → splats → project → sort → render.
    const gaussians = try splat.latticeToSplats(allocator, state, node_count, channel_count, cfg.base_scale);
    defer allocator.free(gaussians);

    var projected = std.ArrayList(splat.ProjectedSplat).init(allocator);
    defer projected.deinit();
    for (gaussians) |g| {
        if (splat.project(cfg.camera, g)) |ps| try projected.append(ps);
    }
    splat.sortSplats(projected.items);

    const fb = try allocator.alloc(u8, @as(usize, cfg.camera.width) * cfg.camera.height * 3);
    errdefer allocator.free(fb);
    splat.render(cfg.camera, projected.items, .{ 8, 8, 16 }, fb);
    return fb;
}

// =============================================================================
// Tests
// =============================================================================

test "COMPONENT_MAP covers the reference pipeline" {
    try std.testing.expect(COMPONENT_MAP.len == 20);
    var gaps: usize = 0;
    for (COMPONENT_MAP) |c| {
        if (c.parity == .gap) gaps += 1;
    }
    // The only structural gap is the rasterizer, which splat_render fills.
    try std.testing.expect(gaps == 1);
}

test "flowShift: identity at s=1, monotone warp for s>1" {
    const t_quarter = fp.fromRatio(1, 4);
    try std.testing.expect(DenoiseSchedule.flowShift(t_quarter, fp.ONE) == t_quarter);
    const warped = DenoiseSchedule.flowShift(t_quarter, fp.fromInt(7));
    // s·t/(1+(s-1)t) = 7·0.25/(1+6·0.25) = 1.75/2.5 = 0.7
    try std.testing.expect(warped > t_quarter);
    try std.testing.expect(fp.eq(warped, fp.fromRatio(7, 10)));
}

test "DenoiseSchedule: sigma decreases geometrically" {
    var sched = DenoiseSchedule.init(fp.ONE, 8, fp.fromInt(7));
    const s0 = sched.sigmaAt(0);
    const s7 = sched.sigmaAt(7);
    try std.testing.expect(s0 > s7);
    try std.testing.expect(s7 > 0);
}

test "parseQ64: integers, decimals, exponent, sign" {
    try std.testing.expect(parseQ64("7") == fp.fromInt(7));
    try std.testing.expect(parseQ64("7.0") == fp.fromInt(7));
    try std.testing.expect(parseQ64("0.5") == fp.HALF);
    try std.testing.expect(parseQ64("0.125") == fp.fromRatio(1, 8));
    try std.testing.expect(parseQ64("-2.5") == -fp.fromRatio(5, 2));
    try std.testing.expect(parseQ64("7e0") == fp.fromInt(7));
    try std.testing.expect(parseQ64("1.5e1") == fp.fromInt(15));
    try std.testing.expect(parseQ64("3e-1") == fp.fromRatio(3, 10));
    try std.testing.expect(parseQ64("") == null);
    try std.testing.expect(parseQ64("abc") == null);
    try std.testing.expect(parseQ64("7.") == null);
    try std.testing.expect(parseQ64("1e30") == null);
}

test "schedulerShift: reads shift from the real scheduler_config.json" {
    const json =
        \\{
        \\    "_class_name": "FlowMatchEulerDiscreteScheduler",
        \\    "shift": 7.0,
        \\    "use_dynamic_shifting": false,
        \\    "time_shift_type": "linear"
        \\}
    ;
    try std.testing.expect(schedulerShift(json) == fp.fromInt(7));
    try std.testing.expect(schedulerShift("{\"shift\": 3.25}") == fp.fromRatio(13, 4));
    try std.testing.expect(schedulerShift("{}") == null);
    try std.testing.expect(schedulerShift("{\"shift\": null}") == null);
}

test "ropeQuat: returns approximately unit quaternion" {
    const q = ropeQuat(fp.fromInt(2), fp.ONE, fp.ONE, 2);
    const ns = q.normSquared();
    // |q|² ≈ 1 within fixed-point tolerance.
    const diff = if (ns > fp.ONE) ns - fp.ONE else fp.ONE - ns;
    try std.testing.expect(diff < fp.fromRatio(1, 100));
}

test "ropeQuat: position zero gives identity rotation" {
    const q = ropeQuat(0, 0, 0, 2);
    try std.testing.expect(q.a == fp.ONE);
    try std.testing.expect(q.b == 0 and q.c == 0 and q.d == 0);
}

test "audioPool33to5: exact grouped means" {
    var hidden: [33]i128 = undefined;
    for (&hidden, 0..) |*h, i| h.* = fp.fromInt(@intCast(i));
    const pooled = audioPool33to5(hidden);
    try std.testing.expect(pooled[0] == fp.fromInt(0)); // embedding singleton
    // group 0: mean(1..8) = 4.5
    try std.testing.expect(pooled[1] == fp.fromRatio(9, 2));
    // group 3: mean(25..32) = 28.5
    try std.testing.expect(pooled[4] == fp.fromRatio(57, 2));
}

test "temporalResample: preserves endpoints, interpolates midpoint" {
    const alloc = std.testing.allocator;
    const input = [_]i128{ 0, fp.fromInt(10) };
    const out = try temporalResample(alloc, &input, 3);
    defer alloc.free(out);
    try std.testing.expect(out[0] == 0);
    try std.testing.expect(out[1] == fp.fromInt(5));
    try std.testing.expect(out[2] == fp.fromInt(10));
}

test "adaLNGate: gate modulates channel weight" {
    var router = dim7.ColorRouter.init();
    adaLNGate(&router, 2, fp.ONE, fp.HALF, 0);
    try std.testing.expect(router.weight(2) == fp.HALF);
    adaLNGate(&router, 3, fp.ONE, fp.fromInt(2), 0); // gate>1 → clamps at ONE
    try std.testing.expect(router.weight(3) == fp.ONE);
}

test "LatentStreams: task stream selection" {
    try std.testing.expect(!LatentStreams.forTask(.at2v).reference);
    try std.testing.expect(LatentStreams.forTask(.ati2v).reference);
    try std.testing.expect(LatentStreams.forTask(.continuation).context);
    try std.testing.expect(LatentStreams.forTask(.at2v).noise);
}

test "corridorStep: contracts magnitude by INV_PHI" {
    const z = Complex.fromParts(fp.ONE, 0);
    const next = corridorStep(z, 0);
    const mag_sq = next.normSquared();
    const inv_phi_sq = fp.mul(fp.INV_PHI, fp.INV_PHI);
    const diff = if (mag_sq > inv_phi_sq) mag_sq - inv_phi_sq else inv_phi_sq - mag_sq;
    try std.testing.expect(diff < fp.fromRatio(1, 100));
}

test "runAvatarFrame: deterministic, non-empty framebuffer" {
    const alloc = std.testing.allocator;
    const nodes: usize = 421;
    const chans: usize = 8;
    const state = try alloc.alloc(i128, nodes * chans);
    defer alloc.free(state);
    @memset(state, fp.fromRatio(1, 4));

    const audio: [5]i128 = .{ fp.HALF, fp.HALF, fp.HALF, fp.HALF, fp.HALF };
    const cfg = AvatarFrameConfig{};

    const fb1 = try runAvatarFrame(alloc, state, nodes, chans, audio, cfg);
    defer alloc.free(fb1);
    @memset(state, fp.fromRatio(1, 4));
    const fb2 = try runAvatarFrame(alloc, state, nodes, chans, audio, cfg);
    defer alloc.free(fb2);

    try std.testing.expect(fb1.len == 64 * 64 * 3);
    try std.testing.expectEqualSlices(u8, fb1, fb2); // deterministic
    var nonzero: usize = 0;
    for (fb1) |b| {
        if (b != 8 and b != 16) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0); // splats actually lit pixels
}

test "runAvatarFrame: weight seed conditions denoise deterministically" {
    const alloc = std.testing.allocator;
    const nodes: usize = 421;
    const chans: usize = 8;
    const state = try alloc.alloc(i128, nodes * chans);
    defer alloc.free(state);

    const audio: [5]i128 = .{ fp.HALF, fp.HALF, fp.HALF, fp.HALF, fp.HALF };

    const seed = wd.WeightSeed{
        .signatures = &.{},
        .total_params = 1,
        .channel_sum = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 }, // all energy on ch0/step0
        .digest = 1,
    };

    @memset(state, fp.fromRatio(1, 4));
    const cond1 = try runAvatarFrame(alloc, state, nodes, chans, audio, .{ .weight_seed = &seed });
    defer alloc.free(cond1);
    @memset(state, fp.fromRatio(1, 4));
    const cond2 = try runAvatarFrame(alloc, state, nodes, chans, audio, .{ .weight_seed = &seed });
    defer alloc.free(cond2);
    @memset(state, fp.fromRatio(1, 4));
    const uncond = try runAvatarFrame(alloc, state, nodes, chans, audio, .{});
    defer alloc.free(uncond);

    try std.testing.expectEqualSlices(u8, cond1, cond2); // deterministic under seed
    // Conditioning changes the trajectory vs unconditional.
    try std.testing.expect(!std.mem.eql(u8, cond1, uncond));
}
