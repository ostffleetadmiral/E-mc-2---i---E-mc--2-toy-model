//! smith.zig - Quad Smith chart impedance algebra in Q128.128.
//!
//! Maps the complex reflection coefficient Gamma (|Gamma| <= 1) to
//! normalized impedance z = (1+Gamma)/(1-Gamma) with exact Q128.128
//! complex arithmetic. The four chart quadrants are exact 90-degree
//! rotations (negate/swap — no trig), giving Gamma_k = Gamma * e^(jk*pi/2)
//! for k in {0,1,2,3}. With 128 integer bits of headroom, impedances up to
//! ~1.7e38 track explicitly at the Gamma -> 1 singularity instead of
//! saturating to infinity.

const std = @import("std");
const Q = @import("q128_128");

/// Complex Q128.128 value.
pub const Cx = struct {
    re: Q.q128,
    im: Q.q128,

    pub fn fromF64(re: f64, im: f64) Cx {
        return .{ .re = Q.q128FromF64(re), .im = Q.q128FromF64(im) };
    }

    pub fn eq(a: Cx, b: Cx) bool {
        return Q.q128Eq(a.re, b.re) and Q.q128Eq(a.im, b.im);
    }

    pub fn add(a: Cx, b: Cx) Cx {
        return .{ .re = Q.q128Add(a.re, b.re), .im = Q.q128Add(a.im, b.im) };
    }

    pub fn sub(a: Cx, b: Cx) Cx {
        return .{ .re = Q.q128Sub(a.re, b.re), .im = Q.q128Sub(a.im, b.im) };
    }

    /// (a+bi)(c+di) = (ac - bd) + (ad + bc)i
    pub fn mul(a: Cx, b: Cx) Cx {
        const ac = Q.q128Mul(a.re, b.re);
        const bd = Q.q128Mul(a.im, b.im);
        const ad = Q.q128Mul(a.re, b.im);
        const bc = Q.q128Mul(a.im, b.re);
        return .{
            .re = Q.q128Sub(ac.v, bd.v),
            .im = Q.q128Add(ad.v, bc.v),
        };
    }
};

fn isNegV(a: Q.q128) bool {
    return (a.hi >> 127) != 0;
}

fn absV(a: Q.q128) Q.q128 {
    return if (isNegV(a)) Q.q128Neg(a) else a;
}

/// Exact left shift by k (two's complement multiply by 2^k).
fn shlQ(a: Q.q128, k: u8) Q.q128 {
    if (k == 0) return a;
    if (k >= 128) return .{ .hi = a.lo << @intCast(k - 128), .lo = 0 };
    return .{ .hi = (a.hi << @intCast(k)) | (a.lo >> @intCast(128 - k)), .lo = a.lo << @intCast(k) };
}

/// Bit length (position of the highest set bit + 1); 0 for zero.
fn bitlenQ(a: Q.q128) u9 {
    if (a.hi != 0) return 256 - @as(u9, @clz(a.hi));
    if (a.lo != 0) return 128 - @as(u9, @clz(a.lo));
    return 0;
}

pub const ComplexDiv = struct { v: Cx, overflow: bool };

/// |num| << 128 / den (den > 0), sign applied. Truncating toward zero.
fn divPos(num: Q.q128, den: Q.q128) Q.U512Div {
    const neg = isNegV(num);
    const m = absV(num);
    const num512: Q.U512 = .{ .hi = .{ .hi = 0, .lo = m.hi }, .lo = .{ .hi = m.lo, .lo = 0 } };
    const d = Q.U512DivU256(num512, den);
    return .{ .quot = if (neg) Q.q128Neg(d.quot) else d.quot, .overflow = d.overflow };
}

/// (a_re + a_im i) / (b_re + b_im i)
///   = [(a_re*b_re + a_im*b_im) + (a_im*b_re - a_re*b_im)i] / (b_re^2 + b_im^2)
/// Exact Q128.128 long division (truncating toward zero). The denominator
/// is normalized (exact power-of-two scaling of both operands) so that
/// Gamma arbitrarily close to +1 — denominator squared-norm below the
/// 2^-128 floor — still yields the correct finite impedance. A zero
/// denominator (Gamma = 1 exactly) saturates with overflow = true.
pub fn complexDiv(a: Cx, b: Cx) ComplexDiv {
    if (Q.q128Eq(b.re, Q.Q_ZERO) and Q.q128Eq(b.im, Q.Q_ZERO)) {
        return .{ .v = .{ .re = Q.Q128_MAX, .im = Q.Q128_MAX }, .overflow = true };
    }
    // Normalize b: scale so max(|b.re|, |b.im|) has bit-length 127.
    const bits = @max(bitlenQ(absV(b.re)), bitlenQ(absV(b.im)));
    const k: u8 = if (bits < 127) @intCast(127 - bits) else 0;
    const a2re = shlQ(a.re, k);
    const a2im = shlQ(a.im, k);
    const b2re = shlQ(b.re, k);
    const b2im = shlQ(b.im, k);
    const b2re2 = Q.q128Mul(b2re, b2re);
    const b2im2 = Q.q128Mul(b2im, b2im);
    const denom = Q.q128Add(b2re2.v, b2im2.v);
    const num_re = Q.q128Add(Q.q128Mul(a2re, b2re).v, Q.q128Mul(a2im, b2im).v);
    const num_im = Q.q128Sub(Q.q128Mul(a2im, b2re).v, Q.q128Mul(a2re, b2im).v);
    const re_q = divPos(num_re, denom);
    const im_q = divPos(num_im, denom);
    return .{
        .v = .{ .re = re_q.quot, .im = im_q.quot },
        .overflow = b2re2.overflow or b2im2.overflow or re_q.overflow or im_q.overflow,
    };
}

const ONE_CX = Cx{ .re = Q.Q_ONE, .im = Q.Q_ZERO };

/// z = (1 + Gamma) / (1 - Gamma)
pub fn gammaToZ(g: Cx) ComplexDiv {
    return complexDiv(ONE_CX.add(g), ONE_CX.sub(g));
}

/// Gamma = (z - 1) / (z + 1)
pub fn zToGamma(z: Cx) ComplexDiv {
    return complexDiv(z.sub(ONE_CX), z.add(ONE_CX));
}

/// Exact 90-degree rotation: (re, im) -> (-im, re). Negation and swap only.
pub fn rot90(v: Cx) Cx {
    return .{ .re = Q.q128Neg(v.im), .im = v.re };
}

/// The four chart quadrants: Gamma_k = Gamma * e^(jk*pi/2), exact.
pub fn quadChart(g: Cx) [4]Cx {
    const g1 = rot90(g);
    const g2 = rot90(g1);
    const g3 = rot90(g2);
    return .{ g, g1, g2, g3 };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "gamma to z known values" {
    // Gamma = 0 -> z = 1
    const z0 = gammaToZ(Cx.fromF64(0, 0));
    try testing.expect(!z0.overflow);
    try testing.expect(Q.q128Eq(z0.v.re, Q.Q_ONE));
    try testing.expect(Q.q128Eq(z0.v.im, Q.Q_ZERO));
    // Gamma = 0.5 (real) -> z = 3
    const z3 = gammaToZ(Cx.fromF64(0.5, 0));
    try testing.expect(Q.q128Eq(z3.v.re, Q.q128FromI64(3)));
    try testing.expect(Q.q128Eq(z3.v.im, Q.Q_ZERO));
    // Gamma = 0.5j -> z = 0.6 + 0.8j (|z| = 1)
    const zj = gammaToZ(Cx.fromF64(0, 0.5));
    try testing.expect(@abs(Q.toFloat(zj.v.re) - 0.6) < 1e-12);
    try testing.expect(@abs(Q.toFloat(zj.v.im) - 0.8) < 1e-12);
}

test "gamma z round trips" {
    const cases = [_]Cx{
        Cx.fromF64(0.3, -0.4),
        Cx.fromF64(-0.7, 0.1),
        Cx.fromF64(0.0, -0.99),
        Cx.fromF64(0.99, 0.01),
    };
    for (cases) |g| {
        const z = gammaToZ(g);
        const g2 = zToGamma(z.v);
        // Truncating divisions do not compose bit-exactly; verify with a
        // relative-or-absolute bound (covers zero components).
        const dre = @abs(Q.toFloat(g2.v.re) - Q.toFloat(g.re));
        const dim = @abs(Q.toFloat(g2.v.im) - Q.toFloat(g.im));
        try testing.expect(dre <= @max(1e-12 * @abs(Q.toFloat(g.re)), 1e-30));
        try testing.expect(dim <= @max(1e-12 * @abs(Q.toFloat(g.im)), 1e-30));
    }
}

test "quad chart rotations exact" {
    const g = Cx.fromF64(0.6, 0.8);
    const q = quadChart(g);
    // Q1 = j*Q0: (re, im) -> (-im, re)
    try testing.expect(q[1].eq(.{ .re = Q.q128Neg(g.im), .im = g.re }));
    // Q2 = -Q0
    try testing.expect(q[2].eq(.{ .re = Q.q128Neg(g.re), .im = Q.q128Neg(g.im) }));
    // Q3 = -Q1 (rot90^3 = -rot90)
    try testing.expect(q[3].eq(.{ .re = Q.q128Neg(q[1].re), .im = Q.q128Neg(q[1].im) }));
    // all quadrants preserve |Gamma| ~ 1 (0.6^2 + 0.8^2 = 1; the f64
    // inputs round so |Gamma| may sit a hair above 1)
    for (q) |gk| {
        const r2 = Q.toFloat(Q.q128Add(Q.q128Mul(gk.re, gk.re).v, Q.q128Mul(gk.im, gk.im).v));
        try testing.expect(r2 <= 1.0 + 1e-12);
    }
}

test "singularity saturation at Gamma = 1" {
    const z = gammaToZ(Cx.fromF64(1, 0));
    try testing.expect(z.overflow);
    // near-singularity: Gamma = 1 - 2^-100 -> z ~ 2^99, finite in Q128.128
    const eps = Q.q128Pow(Q.q128FromI64(2), -100).v;
    const g = Cx{ .re = Q.q128Sub(Q.Q_ONE, eps), .im = Q.Q_ZERO };
    const zn = gammaToZ(g);
    try testing.expect(!zn.overflow);
    try testing.expect(Q.toFloat(zn.v.re) > 1e29);
}
