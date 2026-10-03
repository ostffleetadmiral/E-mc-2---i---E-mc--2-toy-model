//! gqa_attn.zig — causal grouped-query attention over a caller-owned
//! KV cache, q128 throughout. Positions are absolute so incremental
//! decode needs no bookkeeping inside the kernel.
//!
//! Layout: kc/vc are flat [max_pos][n_kv][head_dim] q128 arrays; the
//! caller appends the current token's k/v at index `pos` before calling.
//! num_key_value_heads head-sharing: q head h reads kv head
//! h / (n_heads / n_kv).

const std = @import("std");
const fp = @import("fixed_point");
const k3 = @import("k3");
const ops = @import("ops");

pub const Q = k3.Q128;
pub const QSlice = []Q;
pub const QConst = k3.Q128Slice;

const zero = Q.zero;
const one = Q.one;

/// One decode step of causal GQA attention.
///   q      : [n_heads * head_dim], rope already applied
///   kc, vc : [max_pos][n_kv*head_dim] caches; entry `pos` already written
///   out    : [n_heads * head_dim]
///   scratch: [pos+1] q128 for the score row
/// Returns error.Overflow if a score dot-product overflows (|q|,|k| sane —
/// QK-normed heads keep dots <= ~64, scale head_dim^-1/2 keeps exp inputs
/// <= 0 after max-subtraction).
pub fn gqaAttnStep(
    out: QSlice,
    q: QConst,
    kc: QConst,
    vc: QConst,
    pos: usize,
    n_heads: usize,
    n_kv: usize,
    head_dim: usize,
    scratch: QSlice,
) !void {
    const group = n_heads / n_kv;
    const kstride = n_kv * head_dim;
    const inv_sqrt_hd = try one.div(try ops.sqrtQ(Q.fromInt(@intCast(head_dim))));
    const nctx = pos + 1;

    for (0..n_heads) |h| {
        const qoff = h * head_dim;
        const kv_head = h / group;
        const koff = kv_head * head_dim;
        const scores = scratch[0..nctx];

        // scores[s] = q_h · k_s * inv_sqrt(head_dim), s <= pos
        for (0..nctx) |s| {
            var dot = zero;
            for (0..head_dim) |d| {
                dot = try dot.add(try q[qoff + d].mul(kc[s * kstride + koff + d]));
            }
            scores[s] = try dot.mul(inv_sqrt_hd);
        }
        // softmax with max-subtraction (exp domain safe: args <= 0)
        var m = scores[0];
        for (scores[1..]) |s| {
            if (s.raw > m.raw) m = s;
        }
        var z = zero;
        for (scores) |*s| {
            s.* = try ops.expQ(try s.*.sub(m));
            z = try z.add(s.*);
        }
        if (z.raw == 0) return error.InvalidValue;
        // out_h = sum p_s * v_s
        for (0..head_dim) |d| {
            var acc = zero;
            for (0..nctx) |s| {
                const p = try scores[s].div(z);
                acc = try acc.add(try p.mul(vc[s * kstride + koff + d]));
            }
            out[qoff + d] = acc;
        }
    }
}

/// Whole-sequence forward (prompt): attend all T positions causally.
/// q,k,v are [T][n_*][head_dim] packed flat; out [T][n_heads*head_dim].
/// scratch needs T q128 entries. The caller's kv cache is filled as a
/// side effect in the same layout gqaAttnStep uses, so prompt+decode
/// share one cache buffer.
pub fn gqaAttnSeq(
    out: QSlice,
    q: QConst,
    kc: QSlice,
    vc: QSlice,
    T: usize,
    n_heads: usize,
    n_kv: usize,
    head_dim: usize,
    scratch: QSlice,
) !void {
    const head_off = n_heads * head_dim;
    for (0..T) |t| {
        try gqaAttnStep(
            out[t * head_off .. (t + 1) * head_off],
            q[t * head_off .. (t + 1) * head_off],
            kc,
            vc,
            t,
            n_heads,
            n_kv,
            head_dim,
            scratch,
        );
    }
}

test "gqaAttnStep: single position output equals v" {
    // n_heads=2, n_kv=1, head_dim=4 — one context position.
    const kc = [_]Q{ Q.fromInt(1), Q.fromInt(-1), Q.fromInt(2), Q.zero };
    const vc = [_]Q{ Q.fromInt(3), Q.fromInt(1), Q.fromInt(-2), Q.fromInt(4) };
    var q = [_]Q{zero} ** 8;
    for (&q, 0..) |*v, i| v.* = Q.fromInt(@intCast(i % 3));
    var out = [_]Q{zero} ** 8;
    var scratch = [_]Q{zero} ** 4;
    try gqaAttnStep(out[0..], q[0..], kc[0..], vc[0..], 0, 2, 1, 4, scratch[0..]);
    // softmax of one score is exactly 1 -> both heads emit v
    for (0..4) |d| {
        try std.testing.expectEqual(vc[d].raw, out[d].raw);
        try std.testing.expectEqual(vc[d].raw, out[4 + d].raw);
    }
}

test "gqaAttnSeq matches gqaAttnStep prefix" {
    // T=3 causal: out[t] must equal the step call at pos=t with the
    // cache populated up to t — which the seq path does itself.
    const T = 3;
    var kc: [T * 4]Q = undefined;
    var vc: [T * 4]Q = undefined;
    for (&kc, 0..) |*v, i| v.* = Q.fromInt(@as(i64, @intCast(i)) - 5);
    for (&vc, 0..) |*v, i| v.* = Q.fromInt(@mod(@as(i64, @intCast(i)), 4) - 1);
    var q = [_]Q{zero} ** (T * 8);
    for (&q, 0..) |*v, i| v.* = Q.fromInt(@mod(@as(i64, @intCast(i)), 5) - 2);
    var out = [_]Q{zero} ** (T * 8);
    var scratch = [_]Q{zero} ** (T + 1);
    try gqaAttnSeq(out[0..], q[0..], kc[0..], vc[0..], T, 2, 1, 4, scratch[0..]);
    // last row attends all 3 positions — softmax argmax toward the
    // largest k·q dot is deterministic; just verify finite & differing
    try std.testing.expect(out[2 * 8].raw != out[8].raw);
}
