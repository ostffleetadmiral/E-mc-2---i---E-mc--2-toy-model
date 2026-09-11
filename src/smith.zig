// License: CC BY-NC-SA 4.0

//! smith.zig - Quad Smith chart impedance algebra in Q128.128 fixed-point.
//!
//! Ported from the Q128.128 (FANO-1) `smith.zig` module to the hardware
//! project's `fixed_point.zig` API. Maps the complex reflection coefficient
//! Gamma (|Gamma| <= 1) to normalized impedance z = (1+Gamma)/(1-Gamma) with
//! exact Q128.128 complex arithmetic. The four chart quadrants are exact
//! 90-degree rotations (negate/swap -- no trig), giving
//! Gamma_k = Gamma * e^(jk*pi/2) for k in {0,1,2,3}. With 128 integer bits of
//! headroom, impedances up to ~1.7e38 track explicitly at the Gamma -> 1
//! singularity instead of saturating to infinity.
//!
//! No floating-point is used in this module. All tests assert on exact integer
//! raw values or bounded integer tolerances (in raw Q128.128 units).

const std = @import("std");
const fixed = @import("fixed_point.zig");

const Q128 = fixed.Q128;
const Raw = fixed.Raw;

/// Complex Q128.128 value.
pub const Cx = struct {
    re: Q128,
    im: Q128,

    pub const zero = Cx{ .re = Q128.zero, .im = Q128.zero };

    /// Construct from rational numerator/denominator pairs.
    /// A zero numerator short-circuits to `Q128.zero` (avoids the
    /// round-half-away-from-zero edge case in `fromRatio` for 0/n).
    pub fn fromRatio(re_num: i256, re_den: i256, im_num: i256, im_den: i256) fixed.Error!Cx {
        const re = if (re_num == 0) Q128.zero else try Q128.fromRatio(re_num, re_den);
        const im = if (im_num == 0) Q128.zero else try Q128.fromRatio(im_num, im_den);
        return .{ .re = re, .im = im };
    }

    /// Construct from raw Q128.128 integer encodings.
    pub fn fromRaw(re_raw: Raw, im_raw: Raw) Cx {
        return .{ .re = Q128.fromRaw(re_raw), .im = Q128.fromRaw(im_raw) };
    }

    pub fn eq(a: Cx, b: Cx) bool {
        return Q128.eq(a.re, b.re) and Q128.eq(a.im, b.im);
    }

    pub fn add(a: Cx, b: Cx) Cx {
        return .{ .re = a.re.add(b.re), .im = a.im.add(b.im) };
    }

    pub fn sub(a: Cx, b: Cx) Cx {
        return .{ .re = a.re.sub(b.re), .im = a.im.sub(b.im) };
    }

    /// (a+bi)(c+di) = (ac - bd) + (ad + bc)i
    pub fn mul(a: Cx, b: Cx) Cx {
        const ac = a.re.mul(b.re);
        const bd = a.im.mul(b.im);
        const ad = a.re.mul(b.im);
        const bc = a.im.mul(b.re);
        return .{
            .re = ac.sub(bd),
            .im = ad.add(bc),
        };
    }
};

/// Bit length (position of the highest set bit + 1); 0 for zero.
/// Computed on the absolute value of the raw i256 encoding.
fn bitlenQ(a: Q128) u9 {
    const ar = a.raw;
    const x: u256 = @intCast(if (ar < 0) -ar else ar);
    if (x == 0) return 0;
    return 256 - @as(u9, @clz(x));
}

/// Exact left shift by k (two's complement multiply by 2^k) on the raw i256.
fn shlQ(a: Q128, k: u8) Q128 {
    if (k == 0) return a;
    return Q128.fromRaw(a.raw << @as(u8, @intCast(k)));
}

/// Largest finite Q128 value (used to saturate the singular case).
const Q128_MAX: Q128 = Q128.fromRaw(std.math.maxInt(i256));

pub const ComplexDiv = struct { v: Cx, overflow: bool };

/// (a_re + a_im i) / (b_re + b_im i)
///   = [(a_re*b_re + a_im*b_im) + (a_im*b_re - a_re*b_im)i] / (b_re^2 + b_im^2)
/// Exact Q128.128 long division (truncating toward zero). The denominator is
/// normalized (exact power-of-two scaling of both operands) so that Gamma
/// arbitrarily close to +1 -- denominator squared-norm below the 2^-128 floor
/// -- still yields the correct finite impedance. A zero denominator
/// (Gamma = 1 exactly) saturates with overflow = true.
///
/// The hardware `fixed_point.zig` multiply uses an exact i512 intermediate
/// product (round-to-nearest-even) and `div` performs
/// `@as(Wide, self.raw) << 128 / @as(Wide, other.raw)` with truncation, which
/// matches the Q128.128 `divPos` semantics directly.
pub fn complexDiv(a: Cx, b: Cx) ComplexDiv {
    if (Q128.eq(b.re, Q128.zero) and Q128.eq(b.im, Q128.zero)) {
        return .{ .v = .{ .re = Q128_MAX, .im = Q128_MAX }, .overflow = true };
    }
    // Normalize b: scale so max(|b.re|, |b.im|) has bit-length 127.
    const bits = @max(bitlenQ(b.re.abs()), bitlenQ(b.im.abs()));
    const k: u8 = if (bits < 127) @intCast(127 - bits) else 0;
    const a2re = shlQ(a.re, k);
    const a2im = shlQ(a.im, k);
    const b2re = shlQ(b.re, k);
    const b2im = shlQ(b.im, k);
    const b2re2 = b2re.mul(b2re);
    const b2im2 = b2im.mul(b2im);
    const denom = b2re2.add(b2im2);
    if (denom.raw == 0) {
        return .{ .v = .{ .re = Q128_MAX, .im = Q128_MAX }, .overflow = true };
    }
    const num_re = a2re.mul(b2re).add(a2im.mul(b2im));
    const num_im = a2im.mul(b2re).sub(a2re.mul(b2im));
    const re_q = num_re.div(denom) catch {
        return .{ .v = .{ .re = Q128_MAX, .im = Q128_MAX }, .overflow = true };
    };
    const im_q = num_im.div(denom) catch {
        return .{ .v = .{ .re = Q128_MAX, .im = Q128_MAX }, .overflow = true };
    };
    return .{
        .v = .{ .re = re_q, .im = im_q },
        .overflow = false,
    };
}

const ONE_CX = Cx{ .re = Q128.one, .im = Q128.zero };

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
    return .{ .re = v.im.neg(), .im = v.re };
}

/// The four chart quadrants: Gamma_k = Gamma * e^(jk*pi/2), exact.
pub fn quadChart(g: Cx) [4]Cx {
    const g1 = rot90(g);
    const g2 = rot90(g1);
    const g3 = rot90(g2);
    return .{ g, g1, g2, g3 };
}

/// Absolute difference in raw Q128.128 units.
fn diffRaw(a: Q128, b: Q128) Raw {
    return a.sub(b).abs().raw;
}

/// Near-equality within `tol_raw` raw Q128.128 units (1 ulp = 2^-128).
fn nearEq(a: Q128, b: Q128, tol_raw: Raw) bool {
    return diffRaw(a, b) <= tol_raw;
}

// ---------------------------------------------------------------------
// Tests (exact integer assertions only -- no f64)
// ---------------------------------------------------------------------

const testing = std.testing;

test "gamma to z known values" {
    // Gamma = 0 -> z = 1 (exact)
    const z0 = gammaToZ(Cx.zero);
    try testing.expect(!z0.overflow);
    try testing.expect(Q128.eq(z0.v.re, Q128.one));
    try testing.expect(Q128.eq(z0.v.im, Q128.zero));

    // Gamma = 0.5 (real) -> z = 3 (exact: 0.5 = 2^127 is exactly representable)
    const g_half = try Cx.fromRatio(1, 2, 0, 1);
    const z3 = gammaToZ(g_half);
    try testing.expect(!z3.overflow);
    try testing.expect(Q128.eq(z3.v.re, Q128.fromInteger(3)));
    try testing.expect(Q128.eq(z3.v.im, Q128.zero));

    // Gamma = 0.5j -> z = 0.6 + 0.8j (|z| = 1). 3/5 and 4/5 are not exactly
    // representable, and `div` truncates while `fromRatio` rounds, so the
    // result differs from `fromRatio(3,5)`/`fromRatio(4,5)` by at most 1 ulp.
    const g_j = try Cx.fromRatio(0, 1, 1, 2);
    const zj = gammaToZ(g_j);
    try testing.expect(!zj.overflow);
    const expected_re = try Q128.fromRatio(3, 5);
    const expected_im = try Q128.fromRatio(4, 5);
    try testing.expect(nearEq(zj.v.re, expected_re, 4));
    try testing.expect(nearEq(zj.v.im, expected_im, 4));
}

test "rot90 is exact negate and swap" {
    // (re, im) -> (-im, re) with exact raw values.
    const g = Cx.fromRaw(123456789, -987654321);
    const r = rot90(g);
    try testing.expect(Q128.eq(r.re, g.im.neg()));
    try testing.expect(Q128.eq(r.im, g.re));
    // rot90^4 == identity
    const r4 = rot90(rot90(rot90(rot90(g))));
    try testing.expect(r4.eq(g));
}

test "quad chart rotations exact" {
    // 0.6 + 0.8j, |Gamma| = 1 (3/5, 4/5).
    const g = try Cx.fromRatio(3, 5, 4, 5);
    const q = quadChart(g);
    // Q1 = j*Q0: (re, im) -> (-im, re)
    try testing.expect(q[1].eq(.{ .re = g.im.neg(), .im = g.re }));
    // Q2 = -Q0
    try testing.expect(q[2].eq(.{ .re = g.re.neg(), .im = g.im.neg() }));
    // Q3 = -Q1 (rot90^3 = -rot90)
    try testing.expect(q[3].eq(.{ .re = q[1].re.neg(), .im = q[1].im.neg() }));
    // Rotation is exact negate/swap, so |Gamma|^2 is preserved bit-for-bit
    // across all four quadrants (signs vanish under squaring).
    const r2_0 = g.re.mul(g.re).add(g.im.mul(g.im));
    for (q) |gk| {
        const r2 = gk.re.mul(gk.re).add(gk.im.mul(gk.im));
        try testing.expect(Q128.eq(r2, r2_0));
    }
}

test "gamma z round trips" {
    // Truncating divisions do not compose bit-exactly; verify with a tight
    // integer tolerance (2^-64 in value) covering zero components.
    const c0 = try Cx.fromRatio(3, 10, -2, 5); // 0.3 - 0.4j
    const c1 = try Cx.fromRatio(-7, 10, 1, 10); // -0.7 + 0.1j
    const c2 = try Cx.fromRatio(0, 1, -99, 100); // 0 - 0.99j
    const c3 = try Cx.fromRatio(99, 100, 1, 100); // 0.99 + 0.01j
    const cases = [_]Cx{ c0, c1, c2, c3 };
    const tol: Raw = @as(Raw, 1) << 64;
    for (cases) |g| {
        const z = gammaToZ(g);
        try testing.expect(!z.overflow);
        const g2 = zToGamma(z.v);
        try testing.expect(nearEq(g2.v.re, g.re, tol));
        try testing.expect(nearEq(g2.v.im, g.im, tol));
    }
}

test "singularity saturation at Gamma = 1" {
    // Gamma = 1 exactly -> zero denominator -> overflow saturation.
    const g_one = Cx{ .re = Q128.one, .im = Q128.zero };
    const z = gammaToZ(g_one);
    try testing.expect(z.overflow);

    // Near-singularity: Gamma = 1 - 2^-100 -> z ~ 2^101, finite in Q128.128.
    // 2^-100 in Q128.128 is raw = 2^(128-100) = 2^28 (exact power of two).
    const eps = Q128.fromRaw(@as(Raw, 1) << 28);
    const g = Cx{ .re = Q128.one.sub(eps), .im = Q128.zero };
    const zn = gammaToZ(g);
    try testing.expect(!zn.overflow);
    // z.re ~ 2^101 -> raw ~ 2^(101+128) = 2^229. Assert it is large and finite.
    try testing.expect(zn.v.re.raw > (@as(Raw, 1) << 225));
    try testing.expect(Q128.eq(zn.v.im, Q128.zero));
}
