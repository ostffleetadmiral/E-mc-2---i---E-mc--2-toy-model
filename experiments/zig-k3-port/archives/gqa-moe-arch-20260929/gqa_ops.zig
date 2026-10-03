//! gqa_ops.zig — kernels for the generic GQA+MoE architecture family
//! (qwen3_moe / olmoe today; qwen3_next gated pieces in the DeltaNet phase).
//! All q128, no floats, same convention as ops.zig.
//!
//! RoPE needs real transcendentals — q128.zig's sin/cos are 1024-entry
//! tables (~6e-3 rad grain), too coarse for position·freq angles up to
//! ~260k radians. sincosQ/lnQ below are series implementations in pure
//! integer q128: mod-2π reduction + quadrant folding + Taylor for sin/cos,
//! 2^k extraction + atanh series for ln. Constants (π, ln2) are embedded at
//! full q128 precision.

const std = @import("std");
const fp = @import("fixed_point");
const k3 = @import("k3");
const gqa_cfg = @import("gqa_cfg");
const ops = @import("ops");

pub const Q = k3.Q128;
pub const QSlice = []Q;
pub const QConst = k3.Q128Slice;
const SCALE = fp.SCALE;

const zero = Q.zero;
const one = Q.one;

// π, 2π, π/2, ln2 at full q128 precision (128 fraction bits).
const PI = Q.fromRaw(1069028584064966747859680373161870783300);
const TWO_PI = Q.fromRaw(2138057168129933495719360746323741566601);
const PI_2 = Q.fromRaw(534514292032483373929840186580935391650);
const LN2 = Q.fromRaw(235865763225513294137944142764154484399);

/// Natural log in q128: x = 2^e·m with m∈[1,2), ln x = e·ln2 + ln m,
/// ln m = 2·Σ t^(2k+1)/(2k+1), t = (m-1)/(m+1) ∈ [0, 1/3).
/// 40 terms keep t^81/81 < 2^-128. Domain x > 0 (and raw must not be
/// near the i256 extremes — config thetas are ~1e3..1e7, fine).
pub fn lnQ(x: Q) fp.Error!Q {
    if (x.raw <= 0) return error.InvalidValue;
    const raw: u256 = @bitCast(x.raw);
    const p: i32 = 255 - @as(i32, @intCast(@clz(raw)));
    const e: i32 = p - 128;
    const mraw: i256 = if (e >= 0)
        @intCast(raw >> @intCast(e))
    else
        @intCast(raw << @intCast(-e));
    const m = Q.fromRaw(mraw); // in [1, 2)
    // t = (m-1)/(m+1)
    const t = try (try m.sub(one)).div(try m.add(one));
    const t2 = try t.mul(t);
    var sum = t;
    var term = t;
    for (1..40) |k| {
        term = try term.mul(t2);
        sum = try sum.add(try term.div(Q.fromInt(2 * @as(i64, @intCast(k)) + 1)));
    }
    const ln_m = try sum.mul(Q.fromInt(2));
    return ln_m.add(try LN2.mul(Q.fromInt(e)));
}

pub const SinCos = struct { s: Q, c: Q };

/// sin/cos via mod-2π reduction + quadrant folding + Taylor on [0, π/2].
/// Accurate to ~2^-80 for inputs in the rope range (|x| up to ~1e6).
/// The integer quotient @divTrunc on raw pairs is exact toward zero, so
/// r = x - k·2π carries the correct sign for negative x too.
pub fn sincosQ(x: Q) fp.Error!SinCos {
    // r = x mod 2π, in [0, 2π)
    const ki = @divTrunc(x.raw, TWO_PI.raw);
    var r = Q.fromRaw(x.raw -% (ki *% TWO_PI.raw));
    if (r.raw < 0) r = r.add(TWO_PI) catch unreachable;
    if (r.raw >= TWO_PI.raw) r = r.sub(TWO_PI) catch unreachable;

    // quadrant = floor(r / (π/2)), rem = r - q·π/2 ∈ [0, π/2]
    var q: u2 = 0;
    var rem = r;
    if (rem.raw >= PI_2.raw) {
        rem = try rem.sub(PI_2);
        q = 1;
    }
    if (rem.raw >= PI_2.raw) {
        rem = try rem.sub(PI_2);
        q = 2;
    }
    if (rem.raw >= PI_2.raw) {
        rem = try rem.sub(PI_2);
        q = 3;
    }
    if (rem.raw >= PI_2.raw) rem = try rem.sub(PI_2); // r ≈ 2π wrap

    const rem2 = try rem.mul(rem);
    // sin(rem): alternating odd powers / factorials
    var s = rem;
    var st = rem;
    for (1..12) |n| {
        st = try st.mul(rem2);
        st = try st.div(Q.fromInt(-(2 * @as(i64, @intCast(n))) * (2 * @as(i64, @intCast(n)) + 1)));
        s = try s.add(st);
    }
    // cos(rem): even powers
    var c = one;
    var ct = one;
    for (1..12) |n| {
        ct = try ct.mul(rem2);
        ct = try ct.div(Q.fromInt(-(2 * @as(i64, @intCast(n)) - 1) * (2 * @as(i64, @intCast(n)))));
        c = try c.add(ct);
    }
    return switch (q) {
        0 => .{ .s = s, .c = c },
        1 => .{ .s = c, .c = try s.neg() },
        2 => .{ .s = try s.neg(), .c = try c.neg() },
        3 => .{ .s = try c.neg(), .c = s },
    };
}

// ------------------------------------------------------------------- rope ---

/// inv_freq_i = theta^(-2i/rot_dim) computed as expQ(-2i·lnθ/rot_dim).
/// Theta range sanity: lnθ must stay inside expQ's (-16, 8) domain —
/// every shipped theta (1e4..1e6 → ln 9.2..13.8) fits.
pub fn invFreq(theta: Q, i: usize, rot_dim: usize) fp.Error!Q {
    const ln_theta = try lnQ(theta);
    const num = try ln_theta.mul(Q.fromInt(-2 * @as(i64, @intCast(i))));
    return ops.expQ(try num.div(Q.fromInt(@intCast(rot_dim))));
}

/// In-place RoPE on one head vector x[0..head_dim] at absolute position
/// `pos`, rotating the first `rot_dim` elements in rotate-half pairs:
///   x1' = x1·cos(mθ) − x2·sin(mθ)
///   x2' = x2·cos(mθ) + x1·sin(mθ)
/// (GPT-NeoX convention — what HF calls rotate_half, used by Qwen3/OLMoE.)
pub fn ropeApply(x: QSlice, pos: usize, theta: Q, rot_dim: usize) !void {
    const half = rot_dim / 2;
    const m = Q.fromInt(@intCast(pos));
    for (0..half) |i| {
        const angle = try m.mul(try invFreq(theta, i, rot_dim));
        const sc = try sincosQ(angle);
        const x1 = x[i];
        const x2 = x[i + half];
        x[i] = try (try x1.mul(sc.c)).sub(try x2.mul(sc.s));
        x[i + half] = try (try x2.mul(sc.c)).add(try x1.mul(sc.s));
    }
}

// ------------------------------------------------------------------ norms ---

/// Per-head RMSNorm on packed [n_heads*head_dim] — each head normed with
/// its own gain w[0..head_dim] (Qwen3 q_norm/k_norm shapes are per-head-dim).
pub fn qkNorm(x: QSlice, w: QConst, eps: Q, head_dim: usize) !void {
    var off: usize = 0;
    while (off + head_dim <= x.len) : (off += head_dim) {
        try ops.rmsnorm(x[off .. off + head_dim], x[off .. off + head_dim], w, eps);
    }
}

// ---------------------------------------------------------------- softmax ---

/// Numerically stable softmax in q128: subtract max before expQ (keeps the
/// argument ≤ 0, inside expQ's domain; underflow past -16 clamps to 0, which
/// is the correct limit).
pub fn softmaxQ(y: QSlice, x: QConst) !void {
    var m = x[0];
    for (x[1..]) |v| {
        if (v.raw > m.raw) m = v;
    }
    var sum = zero;
    for (y, x) |*o, v| {
        o.* = try ops.expQ(try v.sub(m));
        sum = try sum.add(o.*);
    }
    if (sum.raw == 0) return error.InvalidValue;
    for (y) |*o| o.* = try o.*.div(sum);
}

// ------------------------------------------------------------------ silu ----

/// silu(x) = x·sigmoid(x) — SwiGLU's gate half.
pub fn siluQ(x: Q) fp.Error!Q {
    return x.mul(try ops.sigmoidQ(x));
}

/// y = silu(gate) ⊙ up over n elements read from x[0..2n] (gate|up packed).
pub fn swiglu(y: QSlice, x: QConst) !void {
    const n = y.len;
    for (y, 0..) |*o, i| {
        o.* = try (try siluQ(x[i])).mul(x[n + i]);
    }
}

// ------------------------------------------------------------- attention ----

/// Causal GQA attention over a packed KV cache.
/// q:  [T][n_heads*head_dim]      (already qk-normed + roped)
/// kc: [cap][n_kv*head_dim] cache slice; positions [0, cached+T) live
/// vc: same layout
/// Writes k/v for the new T tokens into the cache at offsets [cached, cached+T)
/// BEFORE attending, then computes causal attention for each new position.
/// Head g of q reads kv head g/(n_heads/n_kv).
pub fn gqaAttn(
    out: QSlice, // [T][n_heads*head_dim]
    q: QConst,
    kv_packed: QConst, // [T][n_kv*head_dim*2] fresh k|v for the new tokens
    kc: QSlice,
    vc: QSlice,
    cached: usize,
    cap: usize,
    n_heads: usize,
    n_kv: usize,
    head_dim: usize,
    T: usize,
    scratch: QSlice, // >= cap scores + eps
) !void {
    const kv_span = n_kv * head_dim;
    // write new k/v into cache
    for (0..T) |t| {
        const dst_k = kc[(cached + t) * kv_span ..][0..kv_span];
        const dst_v = vc[(cached + t) * kv_span ..][0..kv_span];
        @memcpy(dst_k, kv_packed[t * kv_span * 2 ..][0..kv_span]);
        @memcpy(dst_v, kv_packed[t * kv_span * 2 + kv_span ..][0..kv_span]);
    }
    const scale = try one.div(try ops.sqrtQ(Q.fromInt(@intCast(head_dim))));
    const group = n_heads / n_kv;
    const scores = scratch[0..cap];
    for (0..T) |t| {
        const tpos = cached + t;
        const nrow = tpos + 1; // causal: attend to 0..tpos
        for (0..n_heads) |h| {
            const qh = q[(t * n_heads + h) * head_dim ..][0..head_dim];
            const kv_h = h / group;
            for (0..nrow) |s| {
                const kh = kc[s * kv_span + kv_h * head_dim ..][0..head_dim];
                var dot = zero;
                for (0..head_dim) |d| dot = try dot.add(try qh[d].mul(kh[d]));
                scores[s] = try dot.mul(scale);
            }
            try softmaxQ(scores[0..nrow], scores[0..nrow]);
            const o = out[(t * n_heads + h) * head_dim ..][0..head_dim];
            @memset(o, zero);
            for (0..nrow) |s| {
                const vh = vc[s * kv_span + kv_h * head_dim ..][0..head_dim];
                for (0..head_dim) |d| o[d] = try o[d].add(try scores[s].mul(vh[d]));
            }
        }
    }
}

// ------------------------------------------------------------------ moe -----

/// Softmax or sigmoid-masked top-k routing. Fills idx[0..topk] with expert
/// ids (descending score, first-index tie order) and wt[0..topk] with the
/// normalized-or-not weights × routed_scale.
pub fn routerTopK(
    idx: []usize,
    wt: QSlice,
    logits: QConst, // [n_experts]
    topk: usize,
    mode: gqa_cfg.RouterMode,
    norm_topk: bool,
    routed_scale: Q,
    scratch: QSlice, // >= n_experts
) !void {
    const n = logits.len;
    const prob = scratch[0..n];
    switch (mode) {
        .softmax => try softmaxQ(prob, logits),
        .sigmoid_topk => {
            for (prob, logits) |*p, v| p.* = try ops.sigmoidQ(v);
        },
    }
    // Taken experts are slammed to -inf in prob — ascending scan with strict
    // > keeps first-index tie order, no bitmap needed.
    var sum = zero;
    for (0..topk) |k| {
        var best: usize = 0;
        var bv: Q = .{ .raw = std.math.minInt(i256) };
        for (0..n) |e| {
            if (prob[e].raw > bv.raw) {
                bv = prob[e];
                best = e;
            }
        }
        prob[best] = .{ .raw = std.math.minInt(i256) };
        idx[k] = best;
        wt[k] = bv;
        sum = try sum.add(bv);
    }
    for (0..topk) |k| {
        if (norm_topk and sum.raw != 0) wt[k] = try wt[k].div(sum);
        wt[k] = try wt[k].mul(routed_scale);
    }
}

/// One classic expert FFN: y = W_down · (silu(W_gate·x) ⊙ (W_up·x)).
/// Matrices are [out][in] in storage type wdt (bf16 on released ckpts).
pub fn expertFfn(
    y: QSlice,
    x: QConst,
    w_gate: ?*const anyopaque,
    w_up: ?*const anyopaque,
    w_down: ?*const anyopaque,
    wdt: k3.Wdt,
    hidden: usize,
    inter: usize,
    scratch: QSlice, // >= 2*inter
) !void {
    const g = scratch[0..inter];
    const u = scratch[inter .. 2 * inter];
    try ops.mmw(g, x, w_gate, wdt, hidden, inter);
    try ops.mmw(u, x, w_up, wdt, hidden, inter);
    for (0..inter) |i| g[i] = try (try siluQ(g[i])).mul(u[i]);
    try ops.mmw(y, g, w_down, wdt, inter, hidden);
}

// ------------------------------------------------------------ tests -------

const expectF = std.testing.expect;

fn near(a: Q, b: Q, tol: f64) !void {
    const d = @abs(a.toF64() - b.toF64());
    if (d > tol) {
        std.debug.print("near: |{d} - {d}| = {d} > {d}\n", .{ a.toF64(), b.toF64(), d, tol });
        return error.TestExpectedApprox;
    }
}

test "lnQ: e, 1, powers" {
    const E = Q.fromRaw(924983374546220337150911035843336795079);
    try near(try lnQ(E), one, 1e-6);
    try near(try lnQ(one), zero, 1e-9);
    try near(try lnQ(Q.fromInt(1024)), try Q.fromInt(10).mul(LN2), 1e-6);
    try near(try lnQ(try Q.fromF32Bits(@bitCast(@as(f32, 1e6)))), try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(13.815510557964274)))), 1e-4);
}

test "sincosQ: known angles" {
    const s0 = try sincosQ(zero);
    try near(s0.s, zero, 1e-9);
    try near(s0.c, one, 1e-9);
    const sp = try sincosQ(PI_2);
    try near(sp.s, one, 1e-9);
    try near(sp.c, zero, 1e-9);
    const sp2 = try sincosQ(PI);
    try near(sp2.s, zero, 1e-8);
    try near(sp2.c, try one.neg(), 1e-9);
    // sin(1) ≈ 0.841470984807897
    const s1 = try sincosQ(one);
    try near(s1.s, try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(0.841470984807897)))), 1e-6);
    try near(s1.c, try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(0.540302305868140)))), 1e-6);
    // large angle: pos 1000 * inv_freq 1 -> mod 2π
    const s1000 = try sincosQ(Q.fromInt(1000));
    try near(s1000.s, try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(@sin(@as(f64, 1000.0)))))), 1e-5);
    try near(s1000.c, try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(@cos(@as(f64, 1000.0)))))), 1e-5);
}

test "ropeApply: pos=0 is identity, pos rotates" {
    const theta = try Q.fromF32Bits(@bitCast(@as(f32, 10000.0)));
    var x = [_]Q{ one, zero, zero, zero };
    try ropeApply(x[0..], 0, theta, 4);
    try near(x[0], one, 1e-9);
    try near(x[2], zero, 1e-9);
    var y = [_]Q{ one, zero, zero, zero };
    try ropeApply(y[0..], 1, theta, 4);
    // i=0: angle=1 → (cos1, sin1); i=1: angle=theta^-0.5=0.01
    try near(y[0], try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(@cos(@as(f64, 1.0)))))), 1e-6);
    try near(y[2], try Q.fromF32Bits(@bitCast(@as(f32, @floatCast(@sin(@as(f64, 1.0)))))), 1e-6);
}

test "softmaxQ sums to one" {
    const x = [_]Q{ one, one, try one.neg(), Q.fromInt(2) };
    var y: [4]Q = undefined;
    try softmaxQ(y[0..], x[0..]);
    var sum = zero;
    for (y) |v| sum = try sum.add(v);
    try near(sum, one, 1e-9);
}

test "gqaAttn: single position attends only itself" {
    // n_heads=2, n_kv=1, head_dim=4, T=1: trivial causal case.
    var kc = [_]Q{zero} ** 8;
    var vc = [_]Q{zero} ** 8;
    var kv = [_]Q{zero} ** 8;
    for (&kv, 0..) |*v, i| v.* = Q.fromInt(@intCast(i));
    const q = [_]Q{ one, zero, zero, zero, zero, one, zero, zero };
    var out = [_]Q{zero} ** 8;
    var scratch = [_]Q{zero} ** 16;
    try gqaAttn(out[0..], q[0..], kv[0..], kc[0..4], vc[0..4], 0, 1, 2, 1, 4, 1, scratch[0..]);
    // softmax over a single score is 1 → output = v row for both heads
    for (0..4) |d| {
        try near(out[d], vc[d], 1e-9);
        try near(out[4 + d], vc[d], 1e-9);
    }
}

test "routerTopK: softmax mode picks descending probs" {
    const logits = [_]Q{ Q.fromInt(3), one, zero, Q.fromInt(2) };
    var idx: [2]usize = undefined;
    var wt: [2]Q = undefined;
    var scratch = [_]Q{zero} ** 8;
    try routerTopK(idx[0..], wt[0..], logits[0..], 2, .softmax, true, one, scratch[0..]);
    try expectF(idx[0] == 0 and idx[1] == 3);
    var sum = zero;
    for (wt) |w| sum = try sum.add(w);
    try near(sum, one, 1e-9); // norm_topk renormalizes
}

test "expertFfn: gate/up/down shape through mmw" {
    // hidden=4, inter=8; w as f32 identity-ish slices.
    var wg = [_]f32{0} ** 32;
    var wu = [_]f32{0} ** 32;
    var wd = [_]f32{0} ** 16;
    for (0..8) |r| {
        wg[r * 4 + (r % 4)] = 1.0;
        wu[r * 4 + (r % 4)] = 1.0;
    }
    for (0..4) |r| wd[r * 8 + r] = 1.0;
    var x = [_]Q{ one, one, one, one };
    var y = [_]Q{zero} ** 4;
    var scratch = [_]Q{zero} ** 16;
    try expertFfn(y[0..], x[0..], &wg, &wu, &wd, .f32, 4, 8, scratch[0..]);
    // y[i] = silu(1)*1 for i<4 lanes of inter — nonzero positive
    for (y) |v| try expectF(v.raw > 0);
}
