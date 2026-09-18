//! weight_distill.zig — Distills SafeTensors weight files into lattice-native
//! signatures (the "S7→S0 seed" pattern applied to model weights).
//!
//! Each tensor is streamed in bounded windows (never fully resident) and
//! reduced to a `TensorSignature`: param count, mean, RMS energy, an 8-bin
//! integer-DFT spectral signature, and a node binding (hash → E0 node).
//! Signatures aggregate into a `WeightSeed` — a small, serializable artifact
//! that lets the lattice's generative pipeline (longcat_port) be conditioned
//! by the real weight structure of the source model.
//!
//! Honest scope: this captures weight *structure* (moments + spectrum), not
//! function — ~26B params → a few KB of signatures. The lattice learns from
//! the weights' shape, not their values.
//!
//! All arithmetic is integer-only (i128 Q64.64 / i256 accumulators).
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");
const st = @import("safetensors");

pub const CHANNELS: usize = 8;
/// DFT bins for the spectral signature (k = 1..8 of a 1024-point transform).
pub const SPECTRAL_BINS: usize = CHANNELS;
/// Samples used for the spectral signature per tensor.
pub const SPECTRAL_N: usize = 1024;
/// Node count of the E0 lattice.
pub const E0_NODES: usize = 421;

/// Tensor role inferred from the parameter name — binds each signature to the
/// lattice module that owns the analogous function (see COMPONENT_MAP).
pub const Role = enum(u8) {
    attn_qkv, // fused QKV projection → 5D attention
    attn_proj, // output projection → 5D attention
    attn_norm, // q/k RMSNorm → 5D attention
    cross_attn, // text cross-attention → 5D language
    audio_cross_attn, // audio cross-attention → 7D router
    ffn_w1, // gated MLP up-projection → 5D
    ffn_w2, // gated MLP down-projection → 5D
    ffn_w3, // gated MLP gate-projection → 5D
    adaln, // adaLN modulation → 10D gating
    audio_adaln, // audio adaLN modulation → 7D gating
    audio_proj, // Whisper→latent projector → 1D resample
    norm, // other norms → stabilization
    bias, // bias vectors → 0D offset
    embedding, // embeddings → 5D language
    other,
};

/// Sentinel: tensor does not belong to a numbered transformer block.
pub const NO_BLOCK: u8 = 255;

/// Per-tensor distilled signature.
pub const TensorSignature = struct {
    name: []const u8,
    elements: u64,
    /// Σx/n in Q64.64.
    mean: i128,
    /// sqrt(Σx²/n) in Q64.64.
    rms: i128,
    /// Min/max element values (Q64.64).
    min_v: i128 = 0,
    max_v: i128 = 0,
    /// Fraction of exact-zero elements (Q64.64 in [0,1]) — weight sparsity.
    zero_frac: i128 = 0,
    /// Per-segment RMS: tensor split into 8 contiguous regions, each region's
    /// RMS normalized so the vector sums to ≈1. Direct octonionic channel
    /// binding — seg[c] is channel c's share of the tensor's energy.
    seg: [CHANNELS]i128 = [_]i128{0} ** CHANNELS,
    /// 8-bin spectral magnitudes (normalized to sum ≈ 1.0).
    spectral: [CHANNELS]i128,
    /// Role classification from the parameter name.
    role: Role = .other,
    /// Transformer block index (`blocks.N.*`), or NO_BLOCK.
    block: u8 = NO_BLOCK,
    /// Lattice node binding: hash(name) mod 421.
    node: u32,
};

/// Per-block rollup: aggregate channel energy + RMS across all tensors in one
/// transformer block. Drives depth-resolved conditioning (48 blocks → 8 steps).
pub const BlockProfile = struct {
    /// Block index (0..N).
    index: u8,
    /// Sum of member tensors' seg vectors, normalized to ≈1.
    channel: [CHANNELS]i128,
    /// Mean RMS of member tensors (Q64.64).
    rms: i128,
    /// Number of member tensors.
    count: u16,
};

/// Aggregate distilled artifact for a whole safetensors file.
pub const WeightSeed = struct {
    signatures: []TensorSignature,
    total_params: u64,
    /// Channel-folded aggregate spectrum (sum of per-tensor spectral vecs,
    /// normalized). This is the vector the lattice consumes.
    channel_sum: [CHANNELS]i128,
    /// Per-block rollup for depth-resolved conditioning (empty for
    /// non-blocked files). Ordered by block index.
    blocks: []BlockProfile = &.{},
    /// Content digest: XOR-folded FNV over all signatures.
    digest: u64,

    pub fn deinit(self: WeightSeed, allocator: std.mem.Allocator) void {
        for (self.signatures) |s| allocator.free(s.name);
        allocator.free(self.signatures);
        if (self.blocks.len > 0) allocator.free(self.blocks);
    }
};

// =============================================================================
// Classification
// =============================================================================

/// Model families recognized by the distiller. Detection is best-effort from
/// tensor-name conventions; the authoritative family for a checkpoint lives in
/// the model registry (Phase B).
pub const ModelFamily = enum(u8) {
    longcat_dit, // LongCat-Video-Avatar DiT (audio cross-attn + adaLN)
    hunyuan, // HunyuanVideo (img_attn_qkv fused streams)
    flux, // FLUX (double/single blocks, img_attn.qkv, modulation.lin)
    sdxl_unet, // SDXL UNet (down/mid/up blocks, attn1/attn2)
    mmdit, // SD3/SD3.5 MMDiT (add_q/k/v_proj, ff_context)
    wan, // Wan2.1 T2V (self_attn.q/k/v/o, ffn.0/2, scale_shift_table)
    cogvideox, // CogVideoX (transformer_blocks, attn1, patch_embed)
    ltx, // LTX-Video (transformer_blocks + scale_shift_table + proj_in)
    clip, // CLIP ViT (q/k/v_proj, fc1/fc2, logit_scale)
    llm, // decoder LLM (layers.N, gate/up/down_proj, embed_tokens)
    t5, // T5/UMT5 encoder (SelfAttention, DenseReluDense)
    whisper, // Whisper (encoder.conv*, decoder.layers)
    vae, // VAE (conv_in/out, quant_conv)
    lora, // LoRA adapters (lora_down/up, alpha)
    unknown,
};

/// Classifies a tensor name into its functional role across all supported
/// families. Conventions covered: LongCat/Wan DiT (`blocks.N.{attn,self_attn,
/// cross_attn,ffn}`), FLUX/Hunyuan (`img_attn.qkv`, `img_mlp`, `linear1/2`,
/// `modulation`), SDXL/CogVideoX (`attn1/2`, `to_q/k/v/out`, `ff.net`),
/// MMDiT (`add_*_proj`, `ff_context`), CLIP/LLM (`q/k/v/o_proj`, `fc1/2`,
/// `gate/up/down_proj`), T5 (`wi_0/1`, `wo`), plus sanitized `lorahyphen`
/// variants.
pub fn classifyName(name: []const u8) Role {
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;

    if (has(name, "bias")) return .bias;
    if (has(name, "audio_adaLN") or has(name, "audio_adaln")) return .audio_adaln;
    if (has(name, "adaLN_modulation") or has(name, "adaln") or has(name, "modulation") or
        has(name, "scale_shift_table") or has(name, "img_mod.") or has(name, "txt_mod.") or
        has(name, "norm1.linear") or has(name, "norm2.linear") or has(name, "norm1_context.linear")) return .adaln;
    if (has(name, "audio_cross_attn") or has(name, "audio_cross")) return .audio_cross_attn;
    // Cross-attention: explicit `cross_attn`, SDXL/CogVideoX `attn2`, MMDiT
    // context-stream `add_*_proj`/`to_add_out` — all checked before generic
    // q/k/v needles so `attn2.to_k` lands here.
    if (has(name, "cross_attn") or has(name, "attn2.") or has(name, "add_q_proj") or
        has(name, "add_k_proj") or has(name, "add_v_proj") or has(name, "to_add_out") or
        has(name, "add_out")) return .cross_attn;
    if (has(name, "audio_proj")) return .audio_proj;
    if (has(name, "attn.qkv") or has(name, "attn___lorahyphen___qkv") or has(name, "to_qkv") or
        has(name, "attn_qkv") or has(name, "SelfAttention.q") or has(name, "SelfAttention.k") or
        has(name, "SelfAttention.v") or has(name, "self_attn.q") or has(name, "self_attn.k") or
        has(name, "self_attn.v") or has(name, "to_q") or has(name, "to_k") or has(name, "to_v") or
        has(name, "q_proj") or has(name, "k_proj") or has(name, "v_proj") or has(name, "linear1")) return .attn_qkv;
    if (has(name, "attn.proj") or has(name, "attn___lorahyphen___proj") or has(name, "to_out") or
        has(name, "attn_proj") or has(name, "SelfAttention.o") or has(name, "self_attn.o") or
        has(name, "o_proj") or has(name, "out_proj") or has(name, "linear2")) return .attn_proj;
    if (has(name, "q_norm") or has(name, "k_norm") or has(name, "norm_added")) return .attn_norm;
    if (has(name, "ffn.w1") or has(name, "w1.weight") or has(name, "wi_0") or has(name, "wi_1") or
        has(name, "DenseReluDense.wi") or has(name, "ff.net.0") or has(name, "ff_context.net.0") or
        has(name, "net.0.proj") or has(name, "mlp.0") or has(name, "fc1") or has(name, "gate_proj") or
        has(name, "ffn.0")) return .ffn_w1;
    if (has(name, "ffn.w2") or has(name, "w2.weight") or has(name, "DenseReluDense.wo") or
        has(name, "wo.weight") or has(name, "ff.net.2") or has(name, "ff_context.net.2") or
        has(name, "mlp.2") or has(name, "fc2") or has(name, "down_proj") or has(name, "ffn.2")) return .ffn_w2;
    if (has(name, "ffn.w3") or has(name, "w3.weight") or has(name, "up_proj")) return .ffn_w3;
    if (has(name, "norm") or has(name, "gamma") or has(name, "layernorm")) return .norm;
    if (has(name, "embed") or has(name, "wte") or has(name, "token_embedding") or has(name, "lm_head") or
        has(name, "proj_in") or has(name, "proj_out") or has(name, "conv_in") or has(name, "conv_out")) return .embedding;
    return .other;
}

/// Best-effort family detection from a tensor name. Characteristic needles are
/// checked most-specific first; ambiguous names fall back to `unknown`.
pub fn detectFamily(name: []const u8) ModelFamily {
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;

    if (has(name, "lora_down") or has(name, "lora_up") or has(name, "lora_A") or has(name, "lora_B")) return .lora;
    if (has(name, "audio_cross_attn") or has(name, "audio_adaLN") or has(name, "audio_proj")) return .longcat_dit;
    if (has(name, "quant_conv") or has(name, "post_quant_conv") or has(name, "encoder.conv_in") or has(name, "decoder.conv_out")) return .vae;
    // CLIP before Whisper: `text_model.encoder.layers` contains the substring
    // `encoder.layers`, so the vision/text-model guard must run first.
    if (has(name, "text_model") or has(name, "vision_model") or has(name, "logit_scale")) return .clip;
    if (has(name, "encoder.conv1") or has(name, "encoder.conv2") or has(name, "decoder.embed_tokens") or
        has(name, "decoder.layers") or has(name, "encoder.layers")) return .whisper;
    if (has(name, "img_attn_qkv") or has(name, "txt_attn_qkv") or has(name, "img_mlp") and has(name, "img_mod")) return .hunyuan;
    if (has(name, "single_blocks") or has(name, "modulation.lin") or has(name, "img_attn.")) return .flux;
    if (has(name, "double_blocks")) return if (has(name, "img_attn_qkv")) .hunyuan else .flux;
    if (has(name, "add_q_proj") or has(name, "add_k_proj") or has(name, "to_add_out") or has(name, "ff_context")) return .mmdit;
    if (has(name, "down_blocks") or has(name, "up_blocks") or has(name, "mid_block")) {
        // VAE encoders share down/up block naming; SDXL UNet has attentions.
        if (has(name, "attentions") or has(name, "attn1") or has(name, "resnets") or has(name, "time_embed")) return .sdxl_unet;
        return .vae;
    }
    if (has(name, "blocks.") and has(name, "self_attn.")) return .wan;
    if (has(name, "scale_shift_table") and (has(name, "attn1") or has(name, "proj_in"))) return .ltx;
    if (has(name, "transformer_blocks") or has(name, "patch_embed")) return .cogvideox;
    if (has(name, "fc1") or has(name, "fc2") or has(name, "logit_scale") or has(name, "text_model") or has(name, "vision_model")) return .clip;
    if (has(name, "SelfAttention") or has(name, "DenseReluDense") or has(name, "wi_0") or has(name, "wi_1")) return .t5;
    if (has(name, "embed_tokens") or has(name, "lm_head") or has(name, "gate_proj") or has(name, "down_proj") or has(name, "q_proj")) return .llm;
    return .unknown;
}

/// Whole-file family: distinctive-marker families win by presence (a single
/// `add_q_proj`/`ff_context` signature means SD3-family no matter how many
/// generic `transformer_blocks` rows surround it); the rest are decided by
/// plurality over per-signature `detectFamily` results, ignoring `unknown`.
/// Ties break toward the family that appears earliest in the file. Returns
/// `.unknown` only when every signature is unrecognized.
pub fn dominantFamily(seed: WeightSeed) ModelFamily {
    const F = @typeInfo(ModelFamily).Enum.fields.len;
    var counts = [_]u32{0} ** F;
    var first_seen = [_]u32{0} ** F;
    var order: u32 = 1;
    for (seed.signatures) |sig| {
        const fam = detectFamily(sig.name);
        if (fam == .unknown) continue;
        const k = @intFromEnum(fam);
        counts[k] += 1;
        if (first_seen[k] == 0) {
            first_seen[k] = order;
            order += 1;
        }
    }
    // Distinctive markers are unambiguous per-file — presence beats plurality.
    inline for (.{ ModelFamily.mmdit, ModelFamily.hunyuan, ModelFamily.flux, ModelFamily.ltx }) |fam| {
        if (counts[@intFromEnum(fam)] > 0) return fam;
    }
    var best: usize = @intFromEnum(ModelFamily.unknown);
    var best_count: u32 = 0;
    var best_order: u32 = std.math.maxInt(u32);
    for (0..F) |k| {
        if (counts[k] == 0) continue;
        if (counts[k] > best_count or (counts[k] == best_count and first_seen[k] < best_order)) {
            best = k;
            best_count = counts[k];
            best_order = first_seen[k];
        }
    }
    return @enumFromInt(best);
}

/// Extracts the transformer block index from `blocks.N.`, `block.N.`, or
/// `layers.N.` names. Substring matching covers `double_blocks`, `single_blocks`,
/// `down/up_blocks`, `transformer_blocks`, and `mid_block` (which carries no
/// index → NO_BLOCK). Returns NO_BLOCK when the name carries no block index.
pub fn blockIndex(name: []const u8) u8 {
    const needles = [_][]const u8{ "blocks.", "block.", "layers." };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, name, needle)) |pos| {
            var i = pos + needle.len;
            var val: u32 = 0;
            var digits: usize = 0;
            while (i < name.len and name[i] >= '0' and name[i] <= '9') : (i += 1) {
                val = val * 10 + (name[i] - '0');
                digits += 1;
            }
            if (digits > 0 and i < name.len and name[i] == '.' and val < 255)
                return @intCast(val);
        }
    }
    // Sanitized names: `blocks___lorahyphen___N` splits to tokens
    // ["blocks","","lorahyphen","","N"] — find the "blocks"/"block" token,
    // then take the next all-digit token as the index.
    var it = std.mem.splitScalar(u8, name, '_');
    var saw_blocks = false;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (!saw_blocks) {
            saw_blocks = std.mem.eql(u8, tok, "blocks") or std.mem.eql(u8, tok, "block") or
                std.mem.eql(u8, tok, "layers");
            continue;
        }
        var all_digits = true;
        for (tok) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            const v = std.fmt.parseInt(u32, tok, 10) catch return NO_BLOCK;
            return if (v < 255) @intCast(v) else NO_BLOCK;
        }
        if (!std.mem.eql(u8, tok, "lorahyphen")) saw_blocks = false;
    }
    return NO_BLOCK;
}

// =============================================================================
// Distillation
// =============================================================================

/// Streams a safetensors file and distills every tensor into a signature.
/// `max_elems_per_tensor` bounds per-tensor sampling (0 = full stream).
pub fn distillFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_elems_per_tensor: u64,
) !WeightSeed {
    var file = try st.SafeTensors.open(allocator, path);
    defer file.close();

    var sigs = try std.ArrayList(TensorSignature).initCapacity(allocator, file.tensorCount());
    errdefer {
        for (sigs.items) |s| allocator.free(s.name);
        sigs.deinit();
    }

    const window = try allocator.alloc(i128, st.WINDOW_ELEMS);
    defer allocator.free(window);

    var channel_sum = [_]i128{0} ** CHANNELS;
    var digest: u64 = 0xcbf29ce484222325; // FNV offset basis

    for (file.tensors) |t| {
        const sig = try distillTensor(allocator, &file, t, window, max_elems_per_tensor);
        for (0..CHANNELS) |c| channel_sum[c] += sig.spectral[c];
        digest = fnv1a(digest, sig.name);
        digest ^= sig.elements *% 0x9e3779b97f4a7c15;
        digest ^= @as(u64, @bitCast(@as(i64, @truncate(sig.mean))));
        try sigs.append(sig);
    }

    // Normalize aggregate channel vector to ≈1.0 total.
    var total: i128 = 0;
    for (channel_sum) |v| total += v;
    if (total > 0) {
        for (&channel_sum) |*v| v.* = fp.div(v.*, total);
    }

    const owned = try sigs.toOwnedSlice();
    return .{
        .signatures = owned,
        .total_params = file.totalParams(),
        .channel_sum = channel_sum,
        .blocks = try buildBlocks(allocator, owned),
        .digest = digest,
    };
}

/// Aggregates signatures into per-block profiles, ordered by block index.
/// Blocks get channel = normalized Σseg and rms = mean member rms.
pub fn buildBlocks(allocator: std.mem.Allocator, sigs: []const TensorSignature) ![]BlockProfile {
    var max_block: u8 = 0;
    var any = false;
    for (sigs) |s| {
        if (s.block != NO_BLOCK) {
            any = true;
            if (s.block > max_block) max_block = s.block;
        }
    }
    if (!any) return &.{};

    const n: usize = @as(usize, max_block) + 1;
    const blocks = try allocator.alloc(BlockProfile, n);
    for (blocks) |*b| b.* = .{ .index = 0, .channel = [_]i128{0} ** CHANNELS, .rms = 0, .count = 0 };

    var rms_sum = try allocator.alloc(i256, n);
    defer allocator.free(rms_sum);
    @memset(rms_sum, 0);

    for (sigs) |s| {
        if (s.block == NO_BLOCK) continue;
        const b = &blocks[s.block];
        for (0..CHANNELS) |c| b.channel[c] += s.seg[c];
        rms_sum[s.block] += s.rms;
        b.count += 1;
    }
    for (blocks, 0..) |*b, i| {
        b.index = @intCast(i);
        if (b.count > 0) {
            b.rms = @intCast(@divTrunc(rms_sum[i], @as(i256, b.count)));
            var total: i128 = 0;
            for (b.channel) |v| total += v;
            if (total > 0) {
                for (&b.channel) |*v| v.* = fp.div(v.*, total);
            }
        }
    }
    return blocks;
}

/// Streaming accumulator shared by file- and slice-based distillation.
const Accum = struct {
    sum: i256 = 0,
    sum_sq: i256 = 0,
    seg_sq: [CHANNELS]i256 = [_]i256{0} ** CHANNELS,
    min_v: i128 = fp.MAX_VAL,
    max_v: i128 = fp.MIN_VAL,
    zeros: u64 = 0,
    seen: u64 = 0,
    /// Element index where each segment begins (segment c covers
    /// [seg_start[c], seg_start[c+1])); seg_start[8] = total.
    seg_start: [CHANNELS + 1]u64 = [_]u64{0} ** (CHANNELS + 1),

    fn init(total: u64) Accum {
        var a = Accum{};
        for (0..CHANNELS + 1) |c| a.seg_start[c] = total * @as(u64, c) / CHANNELS;
        return a;
    }

    /// Absorb `window` elements starting at absolute index `base`.
    fn absorb(self: *Accum, window: []const i128, base: u64) void {
        for (window, 0..) |x, j| {
            const idx = base + j;
            self.sum +|= x;
            self.sum_sq +|= fp.mul(x, x);
            if (x < self.min_v) self.min_v = x;
            if (x > self.max_v) self.max_v = x;
            if (x == 0) self.zeros += 1;
            // Segment = first c with idx < seg_start[c+1].
            var c: usize = 0;
            while (c + 1 < CHANNELS and idx >= self.seg_start[c + 1]) c += 1;
            self.seg_sq[c] +|= fp.mul(x, x);
        }
        self.seen += window.len;
    }
};

/// Distills one tensor: streaming moments + segment energies + sparsity +
/// spectral signature + node binding. Never materializes the full tensor.
fn distillTensor(
    allocator: std.mem.Allocator,
    file: *const st.SafeTensors,
    tensor: st.TensorInfo,
    window: []i128,
    max_elems: u64,
) !TensorSignature {
    const total_elems = if (max_elems > 0) @min(tensor.elements(), max_elems) else tensor.elements();

    var acc = Accum.init(total_elems);
    var seen: u64 = 0;
    while (seen < total_elems) {
        const want: usize = @intCast(@min(@as(u64, window.len), total_elems - seen));
        const n = try file.readWindow(tensor, seen, window[0..want]);
        if (n == 0) break;
        acc.absorb(window[0..n], seen);
        seen += n;
    }

    // Spectral signature: integer DFT of the first window, folded to 8 bins.
    const spectral = try spectralSignature(allocator, file, tensor);
    return finalizeSignature(allocator, tensor.name, tensor.elements(), acc, spectral);
}

/// Distills an in-memory element slice — used by fidelityCheck and tests.
pub fn distillSlice(
    allocator: std.mem.Allocator,
    name: []const u8,
    data: []const i128,
) !TensorSignature {
    var acc = Accum.init(data.len);
    acc.absorb(data, 0);
    const spectral = spectralSlice(data);
    return finalizeSignature(allocator, name, data.len, acc, spectral);
}

/// Shared signature assembly from an Accum + spectral vector.
fn finalizeSignature(
    allocator: std.mem.Allocator,
    name: []const u8,
    elements: u64,
    acc: Accum,
    spectral: [CHANNELS]i128,
) !TensorSignature {
    const n_i = @as(i256, @intCast(@max(1, acc.seen)));
    const mean: i128 = @intCast(@divTrunc(acc.sum, n_i));
    const mean_sq: i128 = @intCast(@divTrunc(acc.sum_sq, n_i));
    const rms: i128 = fp.sqrt(@max(0, mean_sq));

    // Segment energies: sqrt(seg_sq / seg_count) per channel, normalized.
    var seg: [CHANNELS]i128 = [_]i128{0} ** CHANNELS;
    var seg_total: i128 = 0;
    for (0..CHANNELS) |c| {
        const cnt = acc.seg_start[c + 1] - acc.seg_start[c];
        if (cnt > 0) {
            const ms: i128 = @intCast(@divTrunc(acc.seg_sq[c], @as(i256, @intCast(cnt))));
            seg[c] = fp.sqrt(@max(0, ms));
            seg_total += seg[c];
        }
    }
    if (seg_total > 0) {
        for (&seg) |*v| v.* = fp.div(v.*, seg_total);
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .elements = elements,
        .mean = mean,
        .rms = rms,
        .min_v = if (acc.seen > 0) acc.min_v else 0,
        .max_v = if (acc.seen > 0) acc.max_v else 0,
        .zero_frac = if (acc.seen > 0) @intCast(@divTrunc(@as(i256, @intCast(acc.zeros)) * @as(i256, fp.ONE), n_i)) else 0,
        .seg = seg,
        .spectral = spectral,
        .role = classifyName(name),
        .block = blockIndex(name),
        .node = @intCast(fnv1a(0xcbf29ce484222325, name) % E0_NODES),
    };
}

/// 8-bin spectral signature over an in-memory slice (bins k=1..8).
fn spectralSlice(samples: []const i128) [CHANNELS]i128 {
    var bins = [_]i128{0} ** CHANNELS;
    const n = @min(samples.len, SPECTRAL_N);
    if (n < 4) return bins;
    for (1..CHANNELS + 1) |k| {
        var re: i128 = 0;
        var im: i128 = 0;
        for (samples[0..n], 0..) |x, j| {
            const tw = fp.twiddle(j * k, n);
            re +|= fp.mul(x, tw.re);
            im +|= fp.mul(x, tw.im);
        }
        // re/im may be saturated (±i128max) on extreme payloads — clamp to
        // the squarable bound (same 1<<95 as safetensors.DECODE_CLAMP) so
        // fp.mul cannot overflow the i128 cast; sqrt of saturated sum is
        // still a valid "energy ≥ bound" signal.
        const SQ_B: i128 = 1 << 95;
        const rc = @min(@max(re, -SQ_B), SQ_B);
        const ic = @min(@max(im, -SQ_B), SQ_B);
        bins[k - 1] = fp.sqrt(fp.mul(rc, rc) +| fp.mul(ic, ic));
    }
    var total: i128 = 0;
    for (bins) |b| total += b;
    if (total > 0) {
        for (&bins) |*b| b.* = fp.div(b.*, total);
    }
    return bins;
}

/// 8-bin spectral signature: DFT bins k=1..8 of the first SPECTRAL_N samples,
/// magnitudes normalized to sum ≈ 1.0. Bins 1..8 because bin 0 (DC) is already
/// captured by `mean`.
fn spectralSignature(
    allocator: std.mem.Allocator,
    file: *const st.SafeTensors,
    tensor: st.TensorInfo,
) ![CHANNELS]i128 {
    const n_samples: usize = @intCast(@min(tensor.elements(), SPECTRAL_N));
    if (n_samples < 4) return [_]i128{0} ** CHANNELS;

    const samples = try allocator.alloc(i128, n_samples);
    defer allocator.free(samples);
    const got = try file.readWindow(tensor, 0, samples);
    if (got < 4) return [_]i128{0} ** CHANNELS;
    return spectralSlice(samples[0..got]);
}

/// Merges several per-shard seeds into one aggregate seed: signatures are
/// concatenated (caller-owned copies), channel_sum is folded then renormalized,
/// digests are combined. Consumed seeds are NOT freed (caller retains them).
pub fn mergeSeeds(allocator: std.mem.Allocator, seeds: []const WeightSeed) !WeightSeed {
    var total_sigs: usize = 0;
    var total_params: u64 = 0;
    for (seeds) |s| {
        total_sigs += s.signatures.len;
        total_params += s.total_params;
    }

    const sigs = try allocator.alloc(TensorSignature, total_sigs);
    errdefer allocator.free(sigs);
    var idx: usize = 0;
    var channel_sum = [_]i128{0} ** CHANNELS;
    var digest: u64 = 0xcbf29ce484222325;

    for (seeds) |s| {
        digest ^= s.digest *% 0x9e3779b97f4a7c15;
        for (s.signatures) |src| {
            for (0..CHANNELS) |c| channel_sum[c] += src.spectral[c];
            sigs[idx] = .{
                .name = try allocator.dupe(u8, src.name),
                .elements = src.elements,
                .mean = src.mean,
                .rms = src.rms,
                .min_v = src.min_v,
                .max_v = src.max_v,
                .zero_frac = src.zero_frac,
                .seg = src.seg,
                .spectral = src.spectral,
                .role = src.role,
                .block = src.block,
                .node = src.node,
            };
            idx += 1;
        }
    }
    var total: i128 = 0;
    for (channel_sum) |v| total += v;
    if (total > 0) {
        for (&channel_sum) |*v| v.* = fp.div(v.*, total);
    }
    return .{
        .signatures = sigs,
        .total_params = total_params,
        .channel_sum = channel_sum,
        .blocks = try buildBlocks(allocator, sigs),
        .digest = digest,
    };
}

/// FNV-1a over bytes, seeded — used for digest and node binding.
pub fn fnv1a(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// =============================================================================
// Serialization (QSW2; QSW1 readable for backward compatibility)
// =============================================================================

pub const SEED_MAGIC_V1: [4]u8 = .{ 'Q', 'S', 'W', '1' };
pub const SEED_MAGIC: [4]u8 = .{ 'Q', 'S', 'W', '2' };

/// Serializes a WeightSeed to QSW2 bytes (caller owns).
pub fn serializeSeed(allocator: std.mem.Allocator, seed: WeightSeed) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll(&SEED_MAGIC);
    try w.writeInt(u64, seed.total_params, .little);
    try w.writeInt(u64, seed.digest, .little);
    try w.writeInt(u16, @intCast(seed.blocks.len), .little);
    for (seed.channel_sum) |v| try w.writeInt(i128, v, .little);
    for (seed.blocks) |b| {
        try w.writeInt(u8, b.index, .little);
        try w.writeInt(u16, b.count, .little);
        try w.writeInt(i128, b.rms, .little);
        for (b.channel) |v| try w.writeInt(i128, v, .little);
    }
    try w.writeInt(u32, @intCast(seed.signatures.len), .little);
    for (seed.signatures) |s| {
        try w.writeInt(u16, @intCast(s.name.len), .little);
        try w.writeAll(s.name);
        try w.writeInt(u64, s.elements, .little);
        try w.writeInt(i128, s.mean, .little);
        try w.writeInt(i128, s.rms, .little);
        try w.writeInt(i128, s.min_v, .little);
        try w.writeInt(i128, s.max_v, .little);
        try w.writeInt(i128, s.zero_frac, .little);
        for (s.seg) |v| try w.writeInt(i128, v, .little);
        for (s.spectral) |v| try w.writeInt(i128, v, .little);
        try w.writeInt(u8, @intFromEnum(s.role), .little);
        try w.writeInt(u8, s.block, .little);
        try w.writeInt(u32, s.node, .little);
    }
    return try out.toOwnedSlice();
}

/// Deserializes a QSW1 or QSW2 WeightSeed. QSW1 seeds get derived role/block
/// (from names) and seg=spectral fallback. Caller deinits with seed.deinit.
pub fn deserializeSeed(allocator: std.mem.Allocator, bytes: []const u8) !WeightSeed {
    var fbs = std.io.fixedBufferStream(bytes);
    const r = fbs.reader();

    var magic: [4]u8 = undefined;
    try r.readNoEof(&magic);
    const is_v1 = std.mem.eql(u8, &magic, &SEED_MAGIC_V1);
    const is_v2 = std.mem.eql(u8, &magic, &SEED_MAGIC);
    if (!is_v1 and !is_v2) return error.BadMagic;

    const total_params = try r.readInt(u64, .little);
    const digest = try r.readInt(u64, .little);

    // V2: block table precedes channel_sum... actually V2 writes n_blocks then
    // channel_sum then blocks then sigs; V1 writes sig count then channel_sum.
    var blocks: []BlockProfile = &.{};
    var count: u32 = 0;
    var channel_sum: [CHANNELS]i128 = undefined;
    if (is_v1) {
        count = try r.readInt(u32, .little);
        for (&channel_sum) |*v| v.* = try r.readInt(i128, .little);
    } else {
        const n_blocks = try r.readInt(u16, .little);
        for (&channel_sum) |*v| v.* = try r.readInt(i128, .little);
        if (n_blocks > 0) {
            blocks = try allocator.alloc(BlockProfile, n_blocks);
            errdefer allocator.free(blocks);
            for (blocks) |*b| {
                b.index = try r.readInt(u8, .little);
                b.count = try r.readInt(u16, .little);
                b.rms = try r.readInt(i128, .little);
                for (&b.channel) |*v| v.* = try r.readInt(i128, .little);
            }
        }
        count = try r.readInt(u32, .little);
    }

    const sigs = try allocator.alloc(TensorSignature, count);
    errdefer allocator.free(sigs);
    var filled: usize = 0;
    errdefer for (sigs[0..filled]) |s| {
        allocator.free(s.name);
    };

    for (sigs) |*s| {
        const name_len = try r.readInt(u16, .little);
        if (name_len == 0 or name_len > 4096) return error.BadSeed;
        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        try r.readNoEof(name);
        s.* = .{
            .name = name,
            .elements = try r.readInt(u64, .little),
            .mean = try r.readInt(i128, .little),
            .rms = try r.readInt(i128, .little),
            .spectral = undefined,
            .node = 0,
        };
        if (is_v2) {
            s.min_v = try r.readInt(i128, .little);
            s.max_v = try r.readInt(i128, .little);
            s.zero_frac = try r.readInt(i128, .little);
            for (&s.seg) |*v| v.* = try r.readInt(i128, .little);
        }
        for (&s.spectral) |*v| v.* = try r.readInt(i128, .little);
        if (is_v2) {
            const role_v = try r.readInt(u8, .little);
            if (role_v >= @typeInfo(Role).Enum.fields.len) return error.BadSeed;
            s.role = @enumFromInt(role_v);
            s.block = try r.readInt(u8, .little);
        }
        s.node = try r.readInt(u32, .little);
        if (is_v1) {
            // Derive post-V1 fields from the name; seg falls back to spectral.
            s.min_v = s.mean;
            s.max_v = s.mean;
            s.seg = s.spectral;
            s.role = classifyName(name);
            s.block = blockIndex(name);
        }
        filled += 1;
    }
    // V1 files carry no block table — rebuild it from derived block indices.
    if (is_v1) blocks = try buildBlocks(allocator, sigs);
    return .{
        .signatures = sigs,
        .total_params = total_params,
        .channel_sum = channel_sum,
        .blocks = blocks,
        .digest = digest,
    };
}

/// Folded channel weight for denoise step `i` — consumed by longcat_port's
/// schedule to modulate sigma per step. Returns Q64.64 in ~(0,1].
pub fn stepGate(seed: WeightSeed, step: usize) i128 {
    const v = seed.channel_sum[step % CHANNELS];
    return if (v > 0) v else fp.fromRatio(1, 16);
}

/// Depth-resolved gate: folds the block profiles into `steps` groups and
/// returns the channel vector for the group owning `step`. Falls back to
/// `channel_sum` for seeds without block structure. Returns Q64.64 in ~(0,1].
pub fn stepChannel(seed: WeightSeed, step: usize, steps: usize, out: *[CHANNELS]i128) void {
    if (seed.blocks.len == 0 or steps == 0) {
        out.* = seed.channel_sum;
        return;
    }
    // Block group for this step: blocks are contiguous and ordered. When a
    // seed has fewer blocks than steps (e.g. a 4-block VAE under an 8-step
    // schedule), lo can run past the end — clamp to an empty tail slice so
    // those steps fall back to channel_sum rather than slicing lo>hi.
    const per_group = (seed.blocks.len + steps - 1) / steps;
    const lo = @min(step * per_group, seed.blocks.len);
    const hi = @min(lo + per_group, seed.blocks.len);
    var acc = [_]i128{0} ** CHANNELS;
    var n: usize = 0;
    for (seed.blocks[lo..hi]) |b| {
        if (b.count == 0) continue;
        n += 1;
        for (0..CHANNELS) |c| acc[c] += b.channel[c];
    }
    if (n == 0) {
        out.* = seed.channel_sum;
        return;
    }
    for (0..CHANNELS) |c| out[c] = fp.div(acc[c], fp.fromInt(@intCast(n)));
}

// =============================================================================
// Synthesis + fidelity (lattice-native weight reconstruction)
// =============================================================================

/// Deterministic PRNG (xorshift64*) seeded per-tensor — the "training" seed.
fn prngNext(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545F4914F6CDD1D;
}

/// Synthesizes a tensor matching a signature's low-order structure:
/// uniform variates scaled per-segment to hit seg RMS targets, shifted to
/// the signature mean. Deterministic — same signature → same tensor.
/// This is the lattice-native "weight": generated from the seed alone.
/// Synthesis length cap — signatures are iid statistics, so a bounded prefix
/// preserves moments/segments/spectrum without materializing giant tensors
/// (a 66M-param embed would otherwise allocate ~1 GB of i128).
pub const SYN_MAX_ELEMS: u64 = 1 << 20;

pub fn synthesizeTensor(allocator: std.mem.Allocator, sig: TensorSignature, digest: u64) ![]i128 {
    const n: usize = @intCast(@min(sig.elements, SYN_MAX_ELEMS));
    const out = try allocator.alloc(i128, n);
    errdefer allocator.free(out);
    if (n == 0) return out;

    var rng = digest ^ fnv1a(0xcbf29ce484222325, sig.name);
    if (rng == 0) rng = 0x9e3779b97f4a7c15;

    // Segment boundaries mirror Accum.init.
    var seg_start: [CHANNELS + 1]u64 = undefined;
    for (0..CHANNELS + 1) |c| seg_start[c] = @as(u64, n) * @as(u64, c) / CHANNELS;

    // Target per-segment RMS: seg is normalized to sum ≈1, so absolute target
    // = seg[c] * CHANNELS * rms (mean-of-squares preserved approximately).
    for (0..n) |i| {
        var c: usize = 0;
        while (c + 1 < CHANNELS and i >= seg_start[c + 1]) c += 1;
        // Uniform u ∈ [0,1) in Q64.64: u64 bits are already the fraction.
        const u: i128 = @intCast(prngNext(&rng));
        const centered = u - fp.HALF; // symmetric range [-0.5, 0.5)
        // Uniform [-a,a] has rms a/√3 → to hit target t use a = t·√3.
        // seg normalized → t = seg[c]·CHANNELS·rms; scale = centered·2·t·√3.
        const target = fp.mul(fp.mul(sig.seg[c], fp.fromInt(CHANNELS)), sig.rms);
        const scaled = fp.mul(fp.mul(centered, fp.fromInt(2)), fp.mul(target, fp.fromRatio(1732, 1000)));
        out[i] = sig.mean + scaled;
    }
    return out;
}

/// Fidelity report comparing a source signature to its synthesized
/// reconstruction. All fields Q64.64.
pub const Fidelity = struct {
    /// |rms_syn - rms_src| / rms_src.
    rms_err: i128,
    /// |mean_syn - mean_src| (absolute — mean can be ~0).
    mean_err: i128,
    /// Channel cosine similarity between seg vectors, [−1,1] (1 = perfect).
    seg_cosine: i128,
    /// Spectral L1 distance (Σ|a−b|, [0,2]).
    spectral_l1: i128,
};

/// Distills a synthesized tensor and compares its signature to the source —
/// the honest loss metric for the distillation. Returns the comparison.
pub fn fidelityCheck(allocator: std.mem.Allocator, src: TensorSignature, digest: u64) !Fidelity {
    const syn = try synthesizeTensor(allocator, src, digest);
    defer allocator.free(syn);
    const syn_sig = try distillSlice(allocator, src.name, syn);
    defer allocator.free(syn_sig.name);
    return signatureDistance(src, syn_sig);
}

/// Compares two signatures: moment error, channel cosine, spectral distance.
pub fn signatureDistance(a: TensorSignature, b: TensorSignature) Fidelity {
    const rms_err = if (a.rms != 0) fp.div(@as(i128, @intCast(@abs(a.rms - b.rms))), @as(i128, @intCast(@abs(a.rms)))) else @as(i128, @intCast(@abs(b.rms)));
    var dot: i128 = 0;
    var na: i128 = 0;
    var nb: i128 = 0;
    var l1: i128 = 0;
    for (0..CHANNELS) |c| {
        dot += fp.mul(a.seg[c], b.seg[c]);
        na += fp.mul(a.seg[c], a.seg[c]);
        nb += fp.mul(b.seg[c], b.seg[c]);
        l1 += @as(i128, @intCast(@abs(a.spectral[c] - b.spectral[c])));
    }
    const denom = fp.mul(fp.sqrt(@max(0, na)), fp.sqrt(@max(0, nb)));
    return .{
        .rms_err = rms_err,
        .mean_err = @as(i128, @intCast(@abs(a.mean - b.mean))),
        .seg_cosine = if (denom > 0) fp.div(dot, denom) else 0,
        .spectral_l1 = l1,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "fnv1a: deterministic and sensitive to input" {
    try std.testing.expect(fnv1a(0xcbf29ce484222325, "abc") == fnv1a(0xcbf29ce484222325, "abc"));
    try std.testing.expect(fnv1a(0xcbf29ce484222325, "abc") != fnv1a(0xcbf29ce484222325, "abd"));
}

test "distillFile: distills moments and spectrum from real container" {
    const alloc = std.testing.allocator;
    const path = "/tmp/test_distill.safetensors";
    defer std.fs.cwd().deleteFile(path) catch {};

    // One bf16 tensor: [1.0, 2.0, 0.5, -1.0] → mean=0.625, rms≈1.78
    const header =
        \\{"w":{"dtype":"BF16","shape":[4],"data_offsets":[0,8]}}
    ;
    var f = try std.fs.cwd().createFile(path, .{});
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, header.len, .little);
    try f.writeAll(&len_buf);
    try f.writeAll(header);
    try f.writeAll(&[_]u8{ 0x80, 0x3F, 0x00, 0x40, 0x00, 0x3F, 0x80, 0xBF });
    f.close();

    var seed = try distillFile(alloc, path, 0);
    defer seed.deinit(alloc);

    try std.testing.expect(seed.signatures.len == 1);
    try std.testing.expect(seed.total_params == 4);
    const sig = seed.signatures[0];
    try std.testing.expect(sig.mean == fp.fromRatio(5, 8)); // (1+2+0.5-1)/4
    // rms = sqrt((1+4+0.25+1)/4) = sqrt(1.5625) = 1.25
    try std.testing.expect(sig.rms == fp.fromRatio(5, 4));
    try std.testing.expect(sig.node < E0_NODES);
    // Spectral normalized: sums to ≈1 (within fixed-point tolerance).
    var total: i128 = 0;
    for (sig.spectral) |v| total += v;
    try std.testing.expect(total > 0);
}

test "serialize/deserialize: QSW1 round-trip preserves signatures" {
    const alloc = std.testing.allocator;
    const sig = TensorSignature{
        .name = try alloc.dupe(u8, "dit.blocks.7.attn.to_q.weight"),
        .elements = 4096,
        .mean = fp.fromRatio(1, 8),
        .rms = fp.fromRatio(3, 4),
        .spectral = .{ fp.HALF, fp.fromRatio(1, 4), 0, 0, fp.fromRatio(1, 8), 0, fp.fromRatio(1, 8), 0 },
        .node = 137,
    };
    const seed = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 4096,
        .channel_sum = sig.spectral,
        .digest = 0xdeadbeefcafebabe,
    };
    seed.signatures[0] = sig;
    defer seed.deinit(alloc);

    const bytes = try serializeSeed(alloc, seed);
    defer alloc.free(bytes);

    var back = try deserializeSeed(alloc, bytes);
    defer back.deinit(alloc);

    try std.testing.expect(back.total_params == 4096);
    try std.testing.expect(back.digest == 0xdeadbeefcafebabe);
    try std.testing.expect(back.signatures.len == 1);
    try std.testing.expectEqualStrings("dit.blocks.7.attn.to_q.weight", back.signatures[0].name);
    try std.testing.expect(back.signatures[0].elements == 4096);
    try std.testing.expect(back.signatures[0].mean == fp.fromRatio(1, 8));
    try std.testing.expect(back.signatures[0].rms == fp.fromRatio(3, 4));
    try std.testing.expect(back.signatures[0].node == 137);
    for (0..CHANNELS) |c| {
        try std.testing.expect(back.signatures[0].spectral[c] == sig.spectral[c]);
        try std.testing.expect(back.channel_sum[c] == sig.spectral[c]);
    }
    // Bad magic rejected.
    var bad = try alloc.dupe(u8, bytes);
    defer alloc.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, deserializeSeed(alloc, bad));
}

test "mergeSeeds: concatenates signatures, refolds channels, combines digest" {
    const alloc = std.testing.allocator;

    var s1 = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 100,
        .channel_sum = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .digest = 0x1111,
    };
    s1.signatures[0] = .{
        .name = try alloc.dupe(u8, "a.weight"),
        .elements = 100,
        .mean = fp.HALF,
        .rms = fp.ONE,
        .spectral = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .node = 10,
    };
    defer s1.deinit(alloc);

    var s2 = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 300,
        .channel_sum = .{ 0, fp.ONE, 0, 0, 0, 0, 0, 0 },
        .digest = 0x2222,
    };
    s2.signatures[0] = .{
        .name = try alloc.dupe(u8, "b.weight"),
        .elements = 300,
        .mean = fp.fromRatio(1, 4),
        .rms = fp.HALF,
        .spectral = .{ 0, fp.ONE, 0, 0, 0, 0, 0, 0 },
        .node = 20,
    };
    defer s2.deinit(alloc);

    var merged = try mergeSeeds(alloc, &.{ s1, s2 });
    defer merged.deinit(alloc);

    try std.testing.expect(merged.signatures.len == 2);
    try std.testing.expect(merged.total_params == 400);
    try std.testing.expectEqualStrings("a.weight", merged.signatures[0].name);
    try std.testing.expectEqualStrings("b.weight", merged.signatures[1].name);
    // channel_sum = sum of per-tensor spectral = [1,1,0,...] → normalized [0.5,0.5,...]
    try std.testing.expect(merged.channel_sum[0] == fp.HALF);
    try std.testing.expect(merged.channel_sum[1] == fp.HALF);
    try std.testing.expect(merged.digest != s1.digest and merged.digest != s2.digest);
}

test "classifyName: role table for LongCat/DiT families" {
    const cases = [_]struct { name: []const u8, role: Role }{
        .{ .name = "blocks.0.attn.qkv.weight", .role = .attn_qkv },
        .{ .name = "blocks.3.attn.proj.weight", .role = .attn_proj },
        .{ .name = "blocks.0.attn.q_norm.weight", .role = .attn_norm },
        .{ .name = "blocks.0.attn.k_norm.weight", .role = .attn_norm },
        .{ .name = "blocks.0.cross_attn.q_linear.weight", .role = .cross_attn },
        .{ .name = "blocks.0.audio_cross_attn.q_linear.weight", .role = .audio_cross_attn },
        .{ .name = "blocks.0.ffn.w1.weight", .role = .ffn_w1 },
        .{ .name = "blocks.0.ffn.w2.weight", .role = .ffn_w2 },
        .{ .name = "blocks.0.ffn.w3.weight", .role = .ffn_w3 },
        .{ .name = "blocks.0.adaLN_modulation.1.weight", .role = .adaln },
        .{ .name = "blocks.0.audio_adaLN_modulation.1.weight", .role = .audio_adaln },
        .{ .name = "audio_proj.proj1.weight", .role = .audio_proj },
        .{ .name = "blocks.0.pre_crs_attn_norm.weight", .role = .norm },
        .{ .name = "final_layer.linear.bias", .role = .bias },
        .{ .name = "encoder.block.0.layer.0.SelfAttention.q.weight", .role = .attn_qkv },
        .{ .name = "encoder.block.0.layer.1.DenseReluDense.wi_0.weight", .role = .ffn_w1 },
        .{ .name = "en___attn___lorahyphen___proj.lora_down.weight", .role = .attn_proj },
        .{ .name = "something.else.weight", .role = .other },
    };
    for (cases) |c| try std.testing.expectEqual(c.role, classifyName(c.name));
}

test "blockIndex: standard, T5, and sanitized names" {
    try std.testing.expectEqual(@as(u8, 0), blockIndex("blocks.0.attn.qkv.weight"));
    try std.testing.expectEqual(@as(u8, 47), blockIndex("blocks.47.ffn.w2.weight"));
    try std.testing.expectEqual(@as(u8, 20), blockIndex("encoder.block.20.layer.0.SelfAttention.o.weight"));
    // Sanitized lora names: lora___lorahyphen___blocks___lorahyphen___5___...
    try std.testing.expectEqual(@as(u8, 5), blockIndex("lora___lorahyphen___blocks___lorahyphen___5___lorahyphen___attn___lorahyphen___qkv.lora_down.weight"));
    try std.testing.expectEqual(NO_BLOCK, blockIndex("final_layer.linear.weight"));
    try std.testing.expectEqual(NO_BLOCK, blockIndex("audio_proj.proj1.weight"));
    // wi_0 / wi_1 must not be read as block indices.
    try std.testing.expectEqual(NO_BLOCK, blockIndex("encoder.layer.1.DenseReluDense.wi_0.weight"));
}

test "classifyName: multi-family role table" {
    const cases = [_]struct { name: []const u8, role: Role }{
        // FLUX: double/single blocks, fused qkv per stream, modulation.lin.
        .{ .name = "double_blocks.0.img_attn.qkv.weight", .role = .attn_qkv },
        .{ .name = "double_blocks.0.txt_attn.proj.weight", .role = .attn_proj },
        .{ .name = "double_blocks.0.img_mlp.0.weight", .role = .ffn_w1 },
        .{ .name = "double_blocks.0.txt_mlp.2.weight", .role = .ffn_w2 },
        .{ .name = "single_blocks.0.linear1.weight", .role = .attn_qkv },
        .{ .name = "single_blocks.0.linear2.weight", .role = .attn_proj },
        .{ .name = "single_blocks.0.modulation.lin.weight", .role = .adaln },
        // HunyuanVideo: fused stream names without inner dots.
        .{ .name = "double_blocks.0.img_attn_qkv.weight", .role = .attn_qkv },
        .{ .name = "double_blocks.0.img_attn_proj.weight", .role = .attn_proj },
        .{ .name = "double_blocks.0.img_mod.lin.weight", .role = .adaln },
        // SDXL UNet: attn1 = self, attn2 = cross, ff.net GEGLU.
        .{ .name = "down_blocks.0.attentions.0.transformer_blocks.0.attn1.to_q.weight", .role = .attn_qkv },
        .{ .name = "down_blocks.1.attentions.0.transformer_blocks.3.attn2.to_k.weight", .role = .cross_attn },
        .{ .name = "mid_block.attentions.0.transformer_blocks.0.ff.net.0.proj.weight", .role = .ffn_w1 },
        .{ .name = "up_blocks.2.attentions.1.transformer_blocks.0.ff.net.2.weight", .role = .ffn_w2 },
        .{ .name = "conv_in.weight", .role = .embedding },
        .{ .name = "time_embed.linear_1.weight", .role = .embedding },
        // CogVideoX: transformer_blocks + attn1 + ff.net.
        .{ .name = "transformer_blocks.0.attn1.to_q.weight", .role = .attn_qkv },
        .{ .name = "transformer_blocks.0.attn1.to_out.0.weight", .role = .attn_proj },
        .{ .name = "transformer_blocks.0.ff.net.0.proj.weight", .role = .ffn_w1 },
        .{ .name = "patch_embed.proj.weight", .role = .embedding },
        // SD3 MMDiT: context-stream projections, ff_context, norm1.linear adaLN.
        .{ .name = "transformer_blocks.0.attn.add_k_proj.weight", .role = .cross_attn },
        .{ .name = "transformer_blocks.0.attn.to_add_out.weight", .role = .cross_attn },
        .{ .name = "transformer_blocks.0.ff_context.net.0.proj.weight", .role = .ffn_w1 },
        .{ .name = "transformer_blocks.0.norm1.linear.weight", .role = .adaln },
        // Wan2.1: self_attn/cross_attn, ffn.0/2, scale_shift_table.
        .{ .name = "blocks.0.self_attn.q.weight", .role = .attn_qkv },
        .{ .name = "blocks.0.self_attn.o.weight", .role = .attn_proj },
        .{ .name = "blocks.0.cross_attn.k.weight", .role = .cross_attn },
        .{ .name = "blocks.0.ffn.0.weight", .role = .ffn_w1 },
        .{ .name = "blocks.0.ffn.2.weight", .role = .ffn_w2 },
        .{ .name = "blocks.0.scale_shift_table", .role = .adaln },
        // LTX: attn1 + scale_shift_table + proj_in.
        .{ .name = "transformer_blocks.0.attn1.scale_shift_table", .role = .adaln },
        .{ .name = "proj_in.weight", .role = .embedding },
        // CLIP: q/k/v_proj + fc1/fc2.
        .{ .name = "text_model.encoder.layers.0.self_attn.q_proj.weight", .role = .attn_qkv },
        .{ .name = "text_model.encoder.layers.0.self_attn.out_proj.weight", .role = .attn_proj },
        .{ .name = "text_model.encoder.layers.0.mlp.fc1.weight", .role = .ffn_w1 },
        .{ .name = "text_model.encoder.layers.0.mlp.fc2.weight", .role = .ffn_w2 },
        .{ .name = "text_model.embeddings.token_embedding.weight", .role = .embedding },
        // Qwen3 LLM: gate/up/down_proj, o_proj, layernorm, embed_tokens.
        .{ .name = "model.layers.0.self_attn.q_proj.weight", .role = .attn_qkv },
        .{ .name = "model.layers.0.self_attn.o_proj.weight", .role = .attn_proj },
        .{ .name = "model.layers.0.mlp.gate_proj.weight", .role = .ffn_w1 },
        .{ .name = "model.layers.0.mlp.down_proj.weight", .role = .ffn_w2 },
        .{ .name = "model.layers.0.mlp.up_proj.weight", .role = .ffn_w3 },
        .{ .name = "model.layers.0.input_layernorm.weight", .role = .norm },
        .{ .name = "model.embed_tokens.weight", .role = .embedding },
        .{ .name = "lm_head.weight", .role = .embedding },
    };
    for (cases) |c| try std.testing.expectEqual(c.role, classifyName(c.name));
}

test "blockIndex: multi-family conventions" {
    try std.testing.expectEqual(@as(u8, 0), blockIndex("double_blocks.0.img_attn.qkv.weight"));
    try std.testing.expectEqual(@as(u8, 3), blockIndex("single_blocks.3.linear1.weight"));
    try std.testing.expectEqual(@as(u8, 2), blockIndex("down_blocks.2.attentions.0.transformer_blocks.5.ff.net.0.proj.weight"));
    try std.testing.expectEqual(@as(u8, 1), blockIndex("up_blocks.1.attentions.2.transformer_blocks.0.attn2.to_k.weight"));
    try std.testing.expectEqual(@as(u8, 4), blockIndex("mid_block.attentions.0.transformer_blocks.4.norm1.weight"));
    try std.testing.expectEqual(@as(u8, 7), blockIndex("transformer_blocks.7.attn1.to_q.weight"));
    try std.testing.expectEqual(@as(u8, 23), blockIndex("model.layers.23.mlp.gate_proj.weight"));
    try std.testing.expectEqual(@as(u8, 11), blockIndex("text_model.encoder.layers.11.self_attn.q_proj.weight"));
    try std.testing.expectEqual(@as(u8, 0), blockIndex("blocks.0.scale_shift_table"));
    try std.testing.expectEqual(NO_BLOCK, blockIndex("model.embed_tokens.weight"));
}

test "detectFamily: characteristic names map to families" {
    const cases = [_]struct { name: []const u8, family: ModelFamily }{
        .{ .name = "blocks.0.audio_cross_attn.q_linear.weight", .family = .longcat_dit },
        .{ .name = "blocks.0.self_attn.q.weight", .family = .wan },
        .{ .name = "double_blocks.0.img_attn_qkv.weight", .family = .hunyuan },
        .{ .name = "double_blocks.0.img_attn.qkv.weight", .family = .flux },
        .{ .name = "single_blocks.0.linear1.weight", .family = .flux },
        .{ .name = "down_blocks.0.attentions.0.transformer_blocks.0.attn1.to_q.weight", .family = .sdxl_unet },
        .{ .name = "transformer_blocks.0.attn.add_k_proj.weight", .family = .mmdit },
        .{ .name = "transformer_blocks.0.attn1.to_q.weight", .family = .cogvideox },
        .{ .name = "text_model.encoder.layers.0.self_attn.q_proj.weight", .family = .clip },
        .{ .name = "model.layers.0.mlp.gate_proj.weight", .family = .llm },
        .{ .name = "model.decoder.layers.0.self_attn.q_proj.weight", .family = .whisper },
        .{ .name = "encoder.block.0.layer.0.SelfAttention.q.weight", .family = .t5 },
        .{ .name = "encoder.conv_in.weight", .family = .vae },
        .{ .name = "decoder.conv_out.weight", .family = .vae },
        .{ .name = "lora___lorahyphen___blocks___lorahyphen___5.lora_down.weight", .family = .lora },
        .{ .name = "totally.unrelated.tensor", .family = .unknown },
    };
    for (cases) |c| try std.testing.expectEqual(c.family, detectFamily(c.name));
}

test "seg energies: 8 contiguous segments map to channels" {
    const alloc = std.testing.allocator;
    // 8 segments: first all 1.0, rest all 0 → seg[0]=1, others 0.
    var data = try alloc.alloc(i128, 64);
    defer alloc.free(data);
    @memset(data, 0);
    for (0..8) |i| data[i] = fp.ONE;
    const sig = try distillSlice(alloc, "blocks.0.attn.qkv.weight", data);
    defer alloc.free(sig.name);
    try std.testing.expect(sig.seg[0] == fp.ONE);
    for (1..CHANNELS) |c| try std.testing.expect(sig.seg[c] == 0);
    // Sparsity: 56 of 64 zeros → zero_frac = 7/8.
    try std.testing.expect(sig.zero_frac == fp.fromRatio(7, 8));
    try std.testing.expect(sig.min_v == 0 and sig.max_v == fp.ONE);
    try std.testing.expect(sig.role == .attn_qkv and sig.block == 0);
}

test "buildBlocks: aggregates signatures by block index" {
    const alloc = std.testing.allocator;
    const sigs = try alloc.alloc(TensorSignature, 3);
    defer alloc.free(sigs);
    sigs[0] = .{ .name = "blocks.0.a", .elements = 4, .mean = 0, .rms = fp.ONE, .seg = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 }, .spectral = undefined, .block = 0, .node = 0 };
    sigs[1] = .{ .name = "blocks.0.b", .elements = 4, .mean = 0, .rms = fp.HALF, .seg = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 }, .spectral = undefined, .block = 0, .node = 0 };
    sigs[2] = .{ .name = "blocks.2.c", .elements = 4, .mean = 0, .rms = fp.ONE, .seg = .{ 0, fp.ONE, 0, 0, 0, 0, 0, 0 }, .spectral = undefined, .block = 2, .node = 0 };
    const blocks = try buildBlocks(alloc, sigs);
    defer alloc.free(blocks);
    try std.testing.expect(blocks.len == 3);
    try std.testing.expect(blocks[0].count == 2);
    try std.testing.expect(blocks[0].rms == fp.fromRatio(3, 4)); // (1 + 0.5)/2
    try std.testing.expect(blocks[0].channel[0] == fp.ONE);
    try std.testing.expect(blocks[1].count == 0);
    try std.testing.expect(blocks[2].channel[1] == fp.ONE);
    // No block indices → empty.
    sigs[0].block = NO_BLOCK;
    sigs[1].block = NO_BLOCK;
    sigs[2].block = NO_BLOCK;
    const empty = try buildBlocks(alloc, sigs);
    try std.testing.expect(empty.len == 0);
}

test "synthesizeTensor + fidelityCheck: deterministic, bounded error" {
    const alloc = std.testing.allocator;
    const sig = TensorSignature{
        .name = "blocks.0.attn.qkv.weight",
        .elements = 4096,
        .mean = 0,
        .rms = fp.fromRatio(1, 10),
        .seg = .{ fp.ONE / 8, fp.ONE / 8, fp.ONE / 8, fp.ONE / 8, fp.ONE / 8, fp.ONE / 8, fp.ONE / 8, fp.ONE / 8 },
        .spectral = undefined,
        .block = 0,
        .node = 0,
    };
    const a = try synthesizeTensor(alloc, sig, 0xabcd);
    defer alloc.free(a);
    const b = try synthesizeTensor(alloc, sig, 0xabcd);
    defer alloc.free(b);
    try std.testing.expectEqualSlices(i128, a, b); // deterministic

    const fid = try fidelityCheck(alloc, sig, 0xabcd);
    // Uniform-variate synthesis matches RMS within ~10% at n=4096.
    try std.testing.expect(fid.rms_err < fp.fromRatio(1, 10));
    // Channel cosine ≈ 1 — same segment profile by construction.
    try std.testing.expect(fid.seg_cosine > fp.fromRatio(9, 10));
}

test "stepChannel: falls back without blocks, folds block groups" {
    const alloc = std.testing.allocator;
    var out: [CHANNELS]i128 = undefined;

    const flat = WeightSeed{
        .signatures = &.{},
        .total_params = 0,
        .channel_sum = .{ fp.HALF, fp.HALF, 0, 0, 0, 0, 0, 0 },
        .digest = 0,
    };
    stepChannel(flat, 3, 8, &out);
    try std.testing.expect(out[0] == fp.HALF and out[1] == fp.HALF);

    // 4 blocks over 2 steps: step0 → blocks[0,1], step1 → blocks[2,3].
    const blocks = try alloc.alloc(BlockProfile, 4);
    defer alloc.free(blocks);
    for (blocks, 0..) |*b, i| {
        b.* = .{ .index = @intCast(i), .channel = [_]i128{0} ** CHANNELS, .rms = 0, .count = 1 };
        b.channel[i] = fp.ONE;
    }
    const seeded = WeightSeed{
        .signatures = &.{},
        .total_params = 0,
        .channel_sum = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .blocks = blocks,
        .digest = 0,
    };
    stepChannel(seeded, 0, 2, &out);
    try std.testing.expect(out[0] == fp.HALF and out[1] == fp.HALF and out[2] == 0);
    stepChannel(seeded, 1, 2, &out);
    try std.testing.expect(out[2] == fp.HALF and out[3] == fp.HALF and out[0] == 0);
}

test "QSW1 backward compatibility: v1 bytes deserialize with derived fields" {
    const alloc = std.testing.allocator;
    // Hand-craft a V1 stream: magic, params, digest, count, channel_sum, sigs.
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();
    const w = out.writer();
    try w.writeAll(&SEED_MAGIC_V1);
    try w.writeInt(u64, 4, .little);
    try w.writeInt(u64, 0x111, .little);
    try w.writeInt(u32, 1, .little);
    try w.writeInt(i128, fp.ONE, .little); // channel_sum[0]
    for (0..7) |_| try w.writeInt(i128, 0, .little);
    const name = "blocks.2.attn.qkv.weight";
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeAll(name);
    try w.writeInt(u64, 4, .little);
    try w.writeInt(i128, fp.HALF, .little);
    try w.writeInt(i128, fp.ONE, .little);
    for (0..8) |_| try w.writeInt(i128, fp.ONE / 8, .little); // spectral
    try w.writeInt(u32, 42, .little);

    var seed = try deserializeSeed(alloc, out.items);
    defer seed.deinit(alloc);
    const s = seed.signatures[0];
    try std.testing.expect(s.role == .attn_qkv); // derived from name
    try std.testing.expect(s.block == 2); // derived from name
    try std.testing.expect(s.node == 42);
    try std.testing.expect(s.min_v == s.mean); // v1 fallback
    // Block table rebuilt from derived indices.
    try std.testing.expect(seed.blocks.len == 3);
    try std.testing.expect(seed.blocks[2].count == 1);
}

test "QSW2 round-trip preserves deepened fields" {
    const alloc = std.testing.allocator;
    const sig = TensorSignature{
        .name = try alloc.dupe(u8, "blocks.5.ffn.w2.weight"),
        .elements = 1024,
        .mean = fp.fromRatio(-1, 8),
        .rms = fp.HALF,
        .min_v = -fp.ONE,
        .max_v = fp.ONE,
        .zero_frac = fp.fromRatio(1, 10),
        .seg = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .spectral = .{ 0, fp.ONE, 0, 0, 0, 0, 0, 0 },
        .role = .ffn_w2,
        .block = 5,
        .node = 77,
    };
    const blocks = try alloc.alloc(BlockProfile, 6);
    for (blocks, 0..) |*b, i| b.* = .{ .index = @intCast(i), .channel = [_]i128{0} ** CHANNELS, .rms = 0, .count = 0 };
    blocks[5] = .{ .index = 5, .channel = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 }, .rms = fp.HALF, .count = 1 };
    const seed = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 1024,
        .channel_sum = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .blocks = blocks,
        .digest = 0xfeed,
    };
    seed.signatures[0] = sig;
    defer seed.deinit(alloc);

    const bytes = try serializeSeed(alloc, seed);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, &SEED_MAGIC));

    const back = try deserializeSeed(alloc, bytes);
    defer back.deinit(alloc);
    const bs = back.signatures[0];
    try std.testing.expect(bs.min_v == -fp.ONE and bs.max_v == fp.ONE);
    try std.testing.expect(bs.zero_frac == fp.fromRatio(1, 10));
    try std.testing.expect(bs.seg[0] == fp.ONE and bs.seg[1] == 0);
    try std.testing.expect(bs.role == .ffn_w2 and bs.block == 5);
    try std.testing.expect(back.blocks.len == 6 and back.blocks[5].count == 1);
    try std.testing.expect(back.blocks[5].channel[0] == fp.ONE);
}

test "stepGate: folds channel_sum, never zero" {
    const seed = WeightSeed{
        .signatures = &.{},
        .total_params = 0,
        .channel_sum = .{ fp.HALF, 0, fp.HALF, 0, 0, 0, 0, 0 },
        .digest = 0,
    };
    try std.testing.expect(stepGate(seed, 0) == fp.HALF);
    try std.testing.expect(stepGate(seed, 1) > 0); // zero → floor
    try std.testing.expect(stepGate(seed, 8) == fp.HALF); // wraps mod 8
}

test "deserializeSeed: corrupt seeds rejected, never panic" {
    const alloc = std.testing.allocator;

    // Bad magic.
    try std.testing.expectError(error.BadMagic, deserializeSeed(alloc, "XXXXgarbage"));

    // Truncated QSW1.
    try std.testing.expectError(error.EndOfStream, deserializeSeed(alloc, "QSW1\x01"));

    // A well-formed QSW2 seed, then corrupted variants.
    var sigs = [_]TensorSignature{.{ .name = "w", .elements = 2, .mean = fp.ONE, .rms = fp.ONE, .spectral = .{fp.ONE} ++ [_]i128{0} ** 7, .node = 3, .role = .norm, .block = 2 }};
    const seed = WeightSeed{
        .signatures = &sigs,
        .total_params = 2,
        .channel_sum = .{fp.ONE} ++ [_]i128{0} ** 7,
        .digest = 9,
    };
    const bytes = try serializeSeed(alloc, seed);
    defer alloc.free(bytes);

    // Truncated mid-record → EndOfStream, no panic.
    try std.testing.expectError(error.EndOfStream, deserializeSeed(alloc, bytes[0 .. bytes.len - 8]));

    // Corrupt role byte (255 > enum count) → BadSeed, no panic.
    var bad = try alloc.dupe(u8, bytes);
    defer alloc.free(bad);
    // role byte sits just before block(1)+node(4): last 6 bytes are
    // role,block,node(4) — second-to-last record field.
    bad[bad.len - 6] = 200;
    try std.testing.expectError(error.BadSeed, deserializeSeed(alloc, bad));

    // Corrupt name_len (first u16 after the block count) → BadSeed.
    var bad2 = try alloc.dupe(u8, bytes);
    defer alloc.free(bad2);
    // QSW2: magic(4) + params(8) + digest(8) + n_blocks(2) + channel_sum(8×16)
    // + sig_count(4) → name_len at offset 4+8+8+2+128+4 = 154
    bad2[154] = 0xFF;
    bad2[155] = 0xFF;
    try std.testing.expectError(error.BadSeed, deserializeSeed(alloc, bad2));
}

test "extreme values: clamped decode + saturating accumulation never panic" {
    const st_local = @import("safetensors");
    // bf16 inf/nan and shift-overflowing finite values all clamp to the
    // squarable bound — never i128max (which overflowed fp.mul pre-fix).
    try std.testing.expectEqual(st_local.DECODE_CLAMP, st_local.decodeBf16(0x7F80)); // +inf
    try std.testing.expectEqual(-st_local.DECODE_CLAMP, st_local.decodeBf16(0xFF80)); // -inf
    try std.testing.expectEqual(st_local.DECODE_CLAMP, st_local.decodeBf16(0x7FC0)); // nan
    try std.testing.expectEqual(st_local.DECODE_CLAMP, st_local.decodeBf16(0x7F00)); // huge finite
    // Saturated values flow through moments + DFT without panic.
    const data = [_]i128{ st_local.DECODE_CLAMP, -st_local.DECODE_CLAMP, fp.ONE, -fp.ONE } ** 64;
    const sig = try distillSlice(std.testing.allocator, "extreme", &data);
    defer std.testing.allocator.free(sig.name);
    try std.testing.expectEqual(@as(u64, 256), sig.elements);
    try std.testing.expect(sig.rms > 0);
}

test "stepChannel: fewer blocks than steps falls back without panic" {
    const blocks = try std.testing.allocator.alloc(BlockProfile, 4);
    defer std.testing.allocator.free(blocks);
    for (blocks, 0..) |*b, i| {
        b.* = .{
            .index = @intCast(i),
            .channel = [_]i128{fp.fromRatio(1, 8)} ** CHANNELS,
            .rms = fp.fromInt(1),
            .count = 3,
        };
    }
    const seed = WeightSeed{
        .signatures = &.{},
        .total_params = 12,
        .channel_sum = [_]i128{fp.fromRatio(1, 8)} ** CHANNELS,
        .blocks = blocks,
        .digest = 0,
    };
    var ch: [CHANNELS]i128 = undefined;
    // 8 steps over 4 blocks: steps 4..7 hit the clamped empty-tail path.
    for (0..8) |step_i| stepChannel(seed, step_i, 8, &ch);
    try std.testing.expectEqual(fp.fromRatio(1, 8), ch[0]);
}

test "dominantFamily: plurality vote, unknowns ignored, earliest wins ties" {
    const mk = struct {
        fn sig(name: []const u8) TensorSignature {
            return .{
                .name = name,
                .elements = 4,
                .mean = 0,
                .rms = fp.ONE,
                .spectral = [_]i128{0} ** CHANNELS,
                .node = 0,
            };
        }
    }.sig;
    var sigs = [_]TensorSignature{
        mk("blocks.0.self_attn.q.weight"), // wan
        mk("blocks.1.self_attn.k.weight"), // wan
        mk("weird.tensor"), // unknown
        mk("blocks.2.self_attn.v.weight"), // wan
    };
    const seed = WeightSeed{
        .signatures = &sigs,
        .total_params = 16,
        .channel_sum = [_]i128{0} ** CHANNELS,
        .digest = 0,
    };
    try std.testing.expectEqual(ModelFamily.wan, dominantFamily(seed));
    // All-unknown file → unknown.
    var sigs2 = [_]TensorSignature{ mk("zzz"), mk("yyy") };
    const seed2 = WeightSeed{
        .signatures = &sigs2,
        .total_params = 8,
        .channel_sum = [_]i128{0} ** CHANNELS,
        .digest = 0,
    };
    try std.testing.expectEqual(ModelFamily.unknown, dominantFamily(seed2));
}

test "dominantFamily: distinctive markers beat generic plurality" {
    const mk = struct {
        fn sig(name: []const u8) TensorSignature {
            return .{
                .name = name,
                .elements = 4,
                .mean = 0,
                .rms = fp.ONE,
                .spectral = [_]i128{0} ** CHANNELS,
                .node = 0,
            };
        }
    }.sig;
    // SD3.5 MMDiT layout: norm/ff rows carry only the generic
    // `transformer_blocks` marker (cogvideox), while a minority of rows
    // carry the distinctive add_q_proj/ff_context markers (mmdit).
    var sigs = [_]TensorSignature{
        mk("transformer_blocks.0.norm1.linear.weight"), // cogvideox
        mk("transformer_blocks.0.norm1_context.linear.weight"), // cogvideox
        mk("transformer_blocks.0.ff.net.0.proj.weight"), // cogvideox
        mk("transformer_blocks.0.attn.add_q_proj.weight"), // mmdit
        mk("transformer_blocks.1.norm1.linear.weight"), // cogvideox
        mk("transformer_blocks.1.attn2.to_out.0.weight"), // cogvideox
    };
    const seed = WeightSeed{
        .signatures = &sigs,
        .total_params = 24,
        .channel_sum = [_]i128{0} ** CHANNELS,
        .digest = 0,
    };
    try std.testing.expectEqual(ModelFamily.mmdit, dominantFamily(seed));
}
