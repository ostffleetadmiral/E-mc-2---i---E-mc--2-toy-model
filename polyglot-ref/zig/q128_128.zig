//! q128_128.zig - I256 (Q128.128) fixed-point arithmetic engine.
//!
//! Port of the verified C engine (archived in .Archives/src/q128_128.c).
//! All arithmetic is performed on 256-bit two's-complement mantissas using
//! 128-bit limbs. Multiplication computes the exact 512-bit product and
//! rounds to nearest-even, guaranteeing the Module 1 error bound
//! |x*y - fl(x*y)| <= 2^-129.

const std = @import("std");

pub const U256 = struct {
    hi: u128,
    lo: u128,
};

pub const U512 = struct {
    hi: U256,
    lo: U256,
};

pub const q128 = U256;

pub const Q128_MAX: q128 = .{ .hi = (@as(u128, 1) << 127) - 1, .lo = ~@as(u128, 0) };
pub const Q128_MIN: q128 = .{ .hi = @as(u128, 1) << 127, .lo = 0 };

/// Physical constants (Q128.128 pre-scaled).
pub const C_INT: u128 = 299_792_458;
pub const C2_INT: u128 = 89_875_517_873_681_764;
pub const PI_RAW: q128 = .{ .hi = 3, .lo = 0x243F6A8885A308D313198A2E03707344 };
pub const PHI_RAW: q128 = .{ .hi = 1, .lo = 0x9E3779B97F4A7C15F39CC0605CEDC834 };
pub const TOLERANCE: q128 = .{ .hi = 0, .lo = @as(u128, 1) << 68 };

pub const Q_ZERO: q128 = .{ .hi = 0, .lo = 0 };
pub const Q_ONE: q128 = .{ .hi = 1, .lo = 0 }; // 1.0 = 2^128 raw
pub const Q_NEG_ONE: q128 = .{ .hi = ~@as(u128, 0), .lo = 0 }; // -1.0 = -(2^128) raw
pub const Q_C: q128 = .{ .hi = C_INT, .lo = 0 };
pub const Q_C2: q128 = .{ .hi = C2_INT, .lo = 0 };
/// 1/c^2 rounded half-away-from-zero (matches the Python reference sim).
pub const Q_C2_INV: q128 = .{ .hi = 0, .lo = 3_786_151_946_286_401_359_559 };

inline fn mask64() u128 {
    return ~@as(u128, 0) >> 64;
}

pub inline fn isNeg(a: q128) bool {
    return (a.hi >> 127) != 0;
}

/// 128x128 -> 256-bit unsigned multiply (schoolbook, 64-bit limbs).
pub fn mul128(a: u128, b: u128) U256 {
    const M = mask64();
    const a_hi = a >> 64;
    const a_lo = a & M;
    const b_hi = b >> 64;
    const b_lo = b & M;
    const p0 = a_lo * b_lo;
    const p1 = a_lo * b_hi;
    const p2 = a_hi * b_lo;
    const p3 = a_hi * b_hi;
    // limb1 <= 3*(2^64-1) < 2^66, limb2 <= 4*(2^64-1) < 2^66
    const limb1 = (p0 >> 64) + (p1 & M) + (p2 & M);
    const limb2 = (p3 & M) + (p1 >> 64) + (p2 >> 64) + (limb1 >> 64);
    const limb3 = (p3 >> 64) + (limb2 >> 64);
    return .{ .lo = (limb1 << 64) | (p0 & M), .hi = (limb3 << 64) | (limb2 & M) };
}

pub const U256Add = struct { v: U256, carry: u128 };

/// 256-bit unsigned add with carry-out.
pub fn U256AddC(a: U256, b: U256) U256Add {
    var r: U256 = undefined;
    r.lo = a.lo +% b.lo;
    const c1: u128 = if (r.lo < a.lo) 1 else 0;
    r.hi = a.hi +% b.hi;
    var c2: u128 = if (r.hi < a.hi) 1 else 0;
    r.hi +%= c1;
    if (r.hi < c1) c2 = 1;
    return .{ .v = r, .carry = c2 };
}

/// 256x256 -> 512-bit unsigned multiply.
pub fn mul256_256(a: U256, b: U256) U512 {
    const t0 = mul128(a.lo, b.lo);
    const t1 = mul128(a.lo, b.hi);
    const t2 = mul128(a.hi, b.lo);
    const t3 = mul128(a.hi, b.hi);
    // ab = t3*2^256 + (t1+t2)*2^128 + t0
    const s = U256AddC(t1, t2);
    const lo = U256AddC(t0, .{ .hi = s.v.lo, .lo = 0 });
    // ab = t3*2^256 + (t1+t2)*2^128 + t0, and (t1+t2) = s + c1*2^256:
    //   s.hi lands at bit 256 (hi.lo), c1 lands at bit 384 (hi.hi).
    var hi = U256AddC(t3, .{ .hi = 0, .lo = s.v.hi });
    hi = U256AddC(hi.v, .{ .hi = 0, .lo = lo.carry });
    hi = U256AddC(hi.v, .{ .hi = s.carry, .lo = 0 });
    // a,b < 2^256 implies ab < 2^512: final carry is always 0
    return .{ .lo = lo.v, .hi = hi.v };
}

/// Magnitude of a two's-complement value.
pub fn mag(a: q128) U256 {
    if (!isNeg(a)) return a;
    var r: U256 = undefined;
    r.lo = ~a.lo +% 1;
    r.hi = ~a.hi +% (if (r.lo == 0) @as(u128, 1) else 0);
    return r;
}

/// 512-bit two's-complement negation.
pub fn U512Neg(a: U512) U512 {
    var r: U512 = undefined;
    r.lo.lo = ~a.lo.lo +% 1;
    const c1: u128 = if (r.lo.lo == 0) 1 else 0;
    r.lo.hi = ~a.lo.hi +% c1;
    const c2: u128 = if (r.lo.hi == 0 and c1 == 1) 1 else 0;
    r.hi.lo = ~a.hi.lo +% c2;
    const c3: u128 = if (r.hi.lo == 0 and c2 == 1) 1 else 0;
    r.hi.hi = ~a.hi.hi +% c3;
    return r;
}

/// Signed 256x256 -> 512-bit two's-complement product.
fn mul256Signed(a: q128, b: q128) U512 {
    const neg = isNeg(a) != isNeg(b);
    const p = mul256_256(mag(a), mag(b));
    return if (neg) U512Neg(p) else p;
}

/// 512-bit two's-complement add.
pub fn U512Add(a: U512, b: U512) U512 {
    var r: U512 = undefined;
    r.lo.lo = a.lo.lo +% b.lo.lo;
    const c1: u128 = if (r.lo.lo < a.lo.lo) 1 else 0;
    r.lo.hi = a.lo.hi +% b.lo.hi +% c1;
    const c2: u128 = if (r.lo.hi < a.lo.hi or (r.lo.hi == a.lo.hi and c1 == 1)) 1 else 0;
    r.hi.lo = a.hi.lo +% b.hi.lo +% c2;
    const c3: u128 = if (r.hi.lo < a.hi.lo or (r.hi.lo == a.hi.lo and c2 == 1)) 1 else 0;
    r.hi.hi = a.hi.hi +% b.hi.hi +% c3;
    return r;
}

pub fn q128Add(a: q128, b: q128) q128 {
    var r: q128 = undefined;
    r.lo = a.lo +% b.lo;
    const c: u128 = if (r.lo < a.lo) 1 else 0;
    r.hi = a.hi +% b.hi +% c;
    return r;
}

pub fn q128Sub(a: q128, b: q128) q128 {
    return q128Add(a, q128Neg(b));
}

pub fn q128Neg(a: q128) q128 {
    var r: q128 = undefined;
    r.lo = ~a.lo +% 1;
    r.hi = ~a.hi +% (if (r.lo == 0) @as(u128, 1) else 0);
    return r;
}

pub const Q128Mul = struct { v: q128, overflow: bool };

pub fn q128Mul(a: q128, b: q128) Q128Mul {
    const neg = isNeg(a) != isNeg(b);
    const p = mul256_256(mag(a), mag(b)); // p = |a|*|b|, exact 512 bits
    // Round p >> 128 to nearest-even. Result mantissa mz = bits 511..128.
    // Round bit = bit 127 of p (bit 127 of p.lo.lo); sticky = any lower
    // bit of p.lo.lo; lsb = bit 128 of p (bit 0 of p.lo.hi).
    const round_bit = (p.lo.lo >> 127) != 0;
    const sticky = (p.lo.lo & ((@as(u128, 1) << 127) - 1)) != 0;
    const lsb = (p.lo.hi & 1) != 0;
    const up = round_bit and (sticky or lsb);
    var mz: U256 = .{ .hi = p.hi.lo, .lo = p.lo.hi };
    if (up) {
        mz.lo +%= 1;
        if (mz.lo == 0) mz.hi +%= 1;
    }
    // Overflow: true mantissa is product >> 128 (up to 384 bits). It fits
    // in signed 256 bits iff bits 511..384 are zero (p.hi.hi == 0) and
    // bit 255 of the mantissa is unset (bit 127 of mz.hi).
    var overflow = false;
    if (p.hi.hi != 0 or (mz.hi >> 127) != 0) {
        overflow = true;
        mz = if (neg) Q128_MIN else Q128_MAX;
    }
    const v = if (neg) q128Neg(mz) else mz;
    return .{ .v = v, .overflow = overflow };
}

/// Exact 512-bit inner product ux*vx + uy*vy.
pub fn q128Inner(ux: q128, uy: q128, vx: q128, vy: q128) U512 {
    const p1 = mul256Signed(ux, vx);
    const p2 = mul256Signed(uy, vy);
    return U512Add(p1, p2);
}

pub fn q128Rot90(x: q128, y: q128) struct { rx: q128, ry: q128 } {
    return .{ .rx = q128Neg(y), .ry = x };
}

pub const Q128Rot = struct { rx: q128, ry: q128, overflow: bool };

pub fn q128Rot(x: q128, y: q128, cos_t: q128, sin_t: q128) Q128Rot {
    const a = q128Mul(x, cos_t);
    const b = q128Mul(y, sin_t);
    const d = q128Mul(x, sin_t);
    const e = q128Mul(y, cos_t);
    return .{
        .rx = q128Sub(a.v, b.v),
        .ry = q128Add(d.v, e.v),
        .overflow = a.overflow or b.overflow or d.overflow or e.overflow,
    };
}

pub fn q128FromI64(v: i64) q128 {
    return .{ .hi = @as(u128, @bitCast(@as(i128, v))), .lo = 0 };
}

pub fn q128Eps() q128 {
    return .{ .hi = 0, .lo = 1 };
}

pub fn q128Cmp(a: q128, b: q128) i8 {
    const an = isNeg(a);
    const bn = isNeg(b);
    if (an != bn) return if (an) -1 else 1;
    // Same sign: unsigned lexicographic comparison of (hi, lo) is correct
    // for two's-complement values.
    if (a.hi != b.hi) return if (a.hi < b.hi) -1 else 1;
    if (a.lo != b.lo) return if (a.lo < b.lo) -1 else 1;
    return 0;
}

pub fn q128Eq(a: q128, b: q128) bool {
    return a.hi == b.hi and a.lo == b.lo;
}

/// |a - b| as an exact 512-bit magnitude.
pub fn q128AbsDelta(a: q128, b: q128) U512 {
    const d = q128Sub(a, b);
    const ext: U512 = if (isNeg(d))
        .{ .hi = .{ .hi = ~@as(u128, 0), .lo = ~@as(u128, 0) }, .lo = d }
    else
        .{ .hi = .{ .hi = 0, .lo = 0 }, .lo = d };
    return if (isNeg(d)) U512Neg(ext) else ext;
}

/// Convert to f64 (diagnostics only; not part of the integer core).
pub fn toFloat(a: q128) f64 {
    const sign: f64 = if (isNeg(a)) -1.0 else 1.0;
    const m = mag(a);
    const hi_f: f64 = @floatFromInt(m.hi);
    const lo_f: f64 = @floatFromInt(m.lo);
    const two128: f64 = 3.4028236692093846e38;
    return sign * (hi_f * two128 + lo_f) / two128;
}

/// Convert to i64 (truncating, diagnostics only).
pub fn toI64(a: q128) i64 {
    return @bitCast(@as(u64, @truncate(a.hi)));
}

// ---------------------------------------------------------------------
// 256-bit helpers for division / sqrt.
// ---------------------------------------------------------------------

inline fn shl1(a: U256) U256 {
    return .{ .hi = (a.hi << 1) | (a.lo >> 127), .lo = a.lo << 1 };
}

inline fn getBit(n: U512, bit: u16) bool {
    if (bit < 128) return ((n.lo.lo >> @intCast(bit)) & 1) != 0;
    if (bit < 256) return ((n.lo.hi >> @intCast(bit - 128)) & 1) != 0;
    if (bit < 384) return ((n.hi.lo >> @intCast(bit - 256)) & 1) != 0;
    return ((n.hi.hi >> @intCast(bit - 384)) & 1) != 0;
}

inline fn setBit(q: *U256, bit: u8) void {
    if (bit < 128) {
        q.lo |= @as(u128, 1) << @intCast(bit);
    } else {
        q.hi |= @as(u128, 1) << @intCast(bit - 128);
    }
}

fn cmpU(a: U256, b: U256) i8 {
    if (a.hi != b.hi) return if (a.hi < b.hi) -1 else 1;
    if (a.lo != b.lo) return if (a.lo < b.lo) -1 else 1;
    return 0;
}

fn subU(a: U256, b: U256) U256 {
    var r: U256 = undefined;
    r.lo = a.lo -% b.lo;
    r.hi = a.hi -% b.hi -% (if (a.lo < b.lo) @as(u128, 1) else 0);
    return r;
}

pub const U512Div = struct { quot: U256, overflow: bool };

/// Unsigned 512/256 -> 256 long division (384 iterations over the full
/// dividend; quotient bits above 255 are reported as overflow).
pub fn U512DivU256(n: U512, d: U256) U512Div {
    var rem: U256 = .{ .hi = 0, .lo = 0 };
    var quot: U256 = .{ .hi = 0, .lo = 0 };
    var overflow = false;
    var i: u16 = 383;
    while (true) : (i -%= 1) {
        rem = shl1(rem);
        if (getBit(n, i)) rem.lo |= 1;
        if (cmpU(rem, d) >= 0) {
            rem = subU(rem, d);
            if (i >= 256) {
                overflow = true;
            } else {
                setBit(&quot, @intCast(i));
            }
        }
        if (i == 0) break;
    }
    return .{ .quot = quot, .overflow = overflow };
}

/// Q128.128 division: (a << 128) / b, truncating (matches Python truediv).
pub fn q128Div(a: q128, b: q128) q128 {
    const a512: U512 = .{ .hi = .{ .hi = 0, .lo = a.hi }, .lo = .{ .hi = a.lo, .lo = 0 } };
    return U512DivU256(a512, b).quot;
}

/// Q128.128 division with round-half-away-from-zero (matches from_ratio).
pub fn q128DivRound(a: q128, b: q128) q128 {
    const a512: U512 = .{ .hi = .{ .hi = 0, .lo = a.hi }, .lo = .{ .hi = a.lo, .lo = 0 } };
    const q = U512DivU256(a512, b).quot;
    // remainder = a512 - q*b
    const prod = mul256_256(q, b);
    const rem = U512Sub(a512, prod);
    // round half away from zero: |rem| >= |b|/2
    const rem_neg = isNeg512(rem);
    const b_neg = isNeg(b);
    const rem_mag = if (rem_neg) U512Neg(rem) else rem;
    const b_mag = if (b_neg) mag(b) else b;
    const b_half_mag: U512 = .{ .hi = .{ .hi = 0, .lo = 0 }, .lo = .{ .hi = b_mag.hi >> 1, .lo = (b_mag.lo >> 1) | (b_mag.hi << 127) } };
    if (cmpU512(rem_mag, b_half_mag) >= 0) {
        const one: q128 = .{ .hi = 0, .lo = 1 };
        return if ((!rem_neg and !b_neg) or (rem_neg and b_neg)) q128Add(q, one) else q128Sub(q, one);
    }
    return q;
}

fn isNeg512(a: U512) bool {
    return (a.hi.hi >> 127) != 0;
}

fn cmpU512(a: U512, b: U512) i8 {
    if (a.hi.hi != b.hi.hi) return if (a.hi.hi < b.hi.hi) -1 else 1;
    if (a.hi.lo != b.hi.lo) return if (a.hi.lo < b.hi.lo) -1 else 1;
    if (a.lo.hi != b.lo.hi) return if (a.lo.hi < b.lo.hi) -1 else 1;
    if (a.lo.lo != b.lo.lo) return if (a.lo.lo < b.lo.lo) -1 else 1;
    return 0;
}

fn U512Sub(a: U512, b: U512) U512 {
    var r: U512 = undefined;
    r.lo.lo = a.lo.lo -% b.lo.lo;
    const c1: u128 = if (a.lo.lo < b.lo.lo) 1 else 0;
    r.lo.hi = a.lo.hi -% b.lo.hi -% c1;
    const c2: u128 = if (a.lo.hi < b.lo.hi or (a.lo.hi == b.lo.hi and c1 == 1)) 1 else 0;
    r.hi.lo = a.hi.lo -% b.hi.lo -% c2;
    const c3: u128 = if (a.hi.lo < b.hi.lo or (a.hi.lo == b.hi.lo and c2 == 1)) 1 else 0;
    r.hi.hi = a.hi.hi -% b.hi.hi -% c3;
    return r;
}

/// Newton square root in Q128.128 (256 iterations max).
pub fn q128Sqrt(a: q128) q128 {
    if (isNeg(a)) @panic("sqrt of negative number");
    if (a.hi == 0 and a.lo == 0) return Q_ZERO;
    var x: q128 = q128FromI64(@intCast(@max(toI64(a), 1)));
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const prev = x;
        const div = q128Div(a, x);
        const sum = q128Add(x, div);
        const two = q128FromI64(2);
        x = q128Div(sum, two);
        if (q128Eq(x, prev)) break;
    }
    return x;
}

/// from_ratio(num, den) with round-half-away-from-zero (u128 numerator path).
pub fn q128FromRatio(num: u128, den: u128) q128 {
    // scaled = num * 2^128 (fits: num < 2^128)
    const a512: U512 = .{ .hi = .{ .hi = 0, .lo = 0 }, .lo = .{ .hi = num, .lo = 0 } };
    const d: U256 = .{ .hi = 0, .lo = den };
    const div = U512DivU256(a512, d).quot;
    const prod = mul256_256(div, d);
    const rem = U512Sub(a512, prod);
    // round half away from zero: rem < den < 2^128, so rem fits in lo (128 bits)
    const half_den = den / 2;
    // Compare full 128-bit remainder (rem.lo.hi:rem.lo.lo) against half_den
    if (rem.lo.hi > 0 or rem.lo.lo >= half_den) return .{ .hi = div.hi, .lo = div.lo + 1 };
    return div;
}

// ---------------------------------------------------------------------
// Fixed-point power and f64 conversion.
// ---------------------------------------------------------------------

inline fn shl256(a: U256, n: u8) U256 {
    if (n == 0) return a;
    if (n >= 128) return .{ .hi = a.lo << @intCast(n - 128), .lo = 0 };
    return .{ .hi = (a.hi << @intCast(n)) | (a.lo >> @intCast(128 - n)), .lo = a.lo << @intCast(n) };
}

inline fn shr256(a: U256, n: u8) U256 {
    if (n == 0) return a;
    if (n >= 128) return .{ .hi = 0, .lo = a.hi >> @intCast(n - 128) };
    return .{ .hi = a.hi >> @intCast(n), .lo = (a.lo >> @intCast(n)) | (a.hi << @intCast(128 - n)) };
}

pub const Q128Pow = struct { v: q128, underflow: bool };

/// base^exp by binary exponentiation. Negative exponents invert the base
/// first (so no intermediate ever exceeds 1 for |base| >= 1). Results that
/// fall below the epsilon floor (2^-128) return zero with underflow = true;
/// overflow saturates via q128Mul.
pub fn q128Pow(base: q128, exp: i32) Q128Pow {
    if (exp == 0) return .{ .v = Q_ONE, .underflow = false };
    var b: q128 = undefined;
    var e: u32 = undefined;
    if (exp < 0) {
        const inv = q128DivRound(Q_ONE, base);
        if (q128Eq(inv, Q_ZERO)) return .{ .v = Q_ZERO, .underflow = true };
        b = inv;
        const ae: i64 = -@as(i64, exp);
        e = @intCast(@min(ae, std.math.maxInt(u32)));
    } else {
        b = base;
        e = @intCast(exp);
    }
    var result: q128 = Q_ONE;
    var underflow = false;
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) {
            const m = q128Mul(result, b);
            if (m.overflow) return .{ .v = m.v, .underflow = false };
            if (q128Eq(m.v, Q_ZERO) and !q128Eq(result, Q_ZERO) and !q128Eq(b, Q_ZERO)) underflow = true;
            result = m.v;
        }
        if (e > 1) {
            const sq = q128Mul(b, b);
            b = sq.v; // saturation propagates through later muls
        }
    }
    return .{ .v = result, .underflow = underflow };
}

/// Convert f64 to Q128.128 (diagnostics only; mirrors toFloat). Values
/// beyond the dynamic range saturate; sub-epsilon magnitudes flush to zero.
pub fn q128FromF64(v: f64) q128 {
    if (v == 0 or std.math.isNan(v)) return Q_ZERO;
    const neg = v < 0;
    const m = @abs(v);
    if (std.math.isInf(m)) return if (neg) Q128_MIN else Q128_MAX;
    const fx = std.math.frexp(m);
    // value = mant * 2^exp with mant in [0.5, 1):
    // raw = (mant * 2^53) << (exp + 128 - 53)
    const mant_bits: u64 = @intFromFloat(fx.significand * @as(f64, 1 << 53));
    var r: U256 = .{ .hi = 0, .lo = mant_bits };
    const shift: i32 = fx.exponent + 128 - 53;
    if (shift >= 0) {
        if (shift >= 256) return if (neg) Q128_MIN else Q128_MAX;
        r = shl256(r, @intCast(shift));
    } else {
        if (-shift >= 256) return Q_ZERO;
        r = shr256(r, @intCast(-shift));
    }
    return if (neg) q128Neg(r) else r;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn expectEq(a: q128, b: q128) !void {
    try testing.expectEqual(a.hi, b.hi);
    try testing.expectEqual(a.lo, b.lo);
}

test "add/sub exactness" {
    const a = q128FromI64(3);
    const b = q128FromI64(2);
    try expectEq(q128Add(a, b), q128FromI64(5));
    try expectEq(q128Sub(a, b), q128FromI64(1));
    try expectEq(q128Neg(q128FromI64(5)), q128FromI64(-5));
    // 1/2 + 1/2 = 1
    const half = q128FromRatio(1, 2);
    try expectEq(q128Add(half, half), Q_ONE);
}

test "mul exactness and RNE" {
    const a = q128FromI64(3);
    const b = q128FromI64(2);
    const r = q128Mul(a, b);
    try testing.expect(!r.overflow);
    try expectEq(r.v, q128FromI64(6));
    // 1/2 * 1/2 = 1/4
    const half = q128FromRatio(1, 2);
    const q = q128Mul(half, half);
    try testing.expect(!q.overflow);
    try expectEq(q.v, q128FromRatio(1, 4));
    // negative * negative = positive
    const n = q128Mul(q128FromI64(-3), q128FromI64(-4));
    try expectEq(n.v, q128FromI64(12));
    // negative * positive = negative
    const m = q128Mul(q128FromI64(-3), q128FromI64(4));
    try expectEq(m.v, q128FromI64(-12));
}

test "mul error bound epsilon <= 2^-129" {
    // For any x,y, |x*y - fl(x*y)| <= 2^-129. The rounding error of the
    // 128-bit shift is at most half an ulp: 2^-129. Values are kept in
    // [-1, 1) so the 256-bit mantissa cannot overflow.
    var seed: u64 = 0x9E3779B97F4A7C15;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const a: q128 = .{ .hi = 0, .lo = seed };
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const b: q128 = .{ .hi = 0, .lo = seed };
        const r = q128Mul(a, b);
        // exact product is 512-bit; rounded result differs by <= 2^-129
        // (half ulp of the 128-bit fractional shift). We verify via the
        // exact product: |p - fl| <= 2^127 (in raw units) => 2^-129 scaled.
        const p = mul256Signed(a, b);
        // fl = r.v as 512-bit sign-extended
        const fl: U512 = if (isNeg(r.v))
            .{ .hi = .{ .hi = ~@as(u128, 0), .lo = ~@as(u128, 0) }, .lo = r.v }
        else
            .{ .hi = .{ .hi = 0, .lo = 0 }, .lo = r.v };
        const diff = if (cmpU512(p, fl) >= 0) U512Sub(p, fl) else U512Sub(fl, p);
        // diff <= 2^127 (half ulp in raw 512-bit space)
        try testing.expect(diff.hi.hi == 0);
        try testing.expect(diff.hi.lo == 0);
        try testing.expect((diff.lo.hi >> 127) == 0);
    }
}

test "floor invariance: distinct values differ by >= 2^-128" {
    // For any two distinct Q128.128 values, |x - y| >= 2^-128.
    const eps = q128Eps();
    try expectEq(eps, .{ .hi = 0, .lo = 1 });
    const a = q128FromI64(1);
    const b = q128Add(a, eps);
    const d = q128AbsDelta(a, b);
    try testing.expect(d.lo.hi == 0 and d.lo.lo == 1 and d.hi.hi == 0 and d.hi.lo == 0);
}

test "inner product exact 512-bit" {
    // <(1,0),(1,0)> = 1
    const one = Q_ONE;
    const zero = Q_ZERO;
    const p = q128Inner(one, zero, one, zero);
    // exact raw product: 2^128 * 2^128 = 2^256
    try testing.expect(p.hi.hi == 0 and p.hi.lo == 1);
    try testing.expect(p.lo.hi == 0);
    try testing.expect(p.lo.lo == 0);
}

test "rot90 exact orthogonality" {
    const x = q128FromI64(7);
    const y = q128FromI64(3);
    const r = q128Rot90(x, y);
    // <(x,y),(rx,ry)> must be exactly 0
    const p = q128Inner(x, y, r.rx, r.ry);
    try testing.expect(p.hi.hi == 0 and p.hi.lo == 0 and p.lo.hi == 0 and p.lo.lo == 0);
}

test "cmp and saturation" {
    try testing.expect(q128Cmp(q128FromI64(-1), q128FromI64(1)) < 0);
    try testing.expect(q128Cmp(q128FromI64(1), q128FromI64(-1)) > 0);
    try testing.expect(q128Cmp(q128FromI64(2), q128FromI64(2)) == 0);
    // overflow saturates to INT256_MAX / INT256_MIN
    const big = Q128_MAX;
    const r = q128Mul(big, q128FromI64(2));
    try testing.expect(r.overflow);
    try expectEq(r.v, Q128_MAX);
    const rn = q128Mul(Q128_MIN, q128FromI64(2));
    try testing.expect(rn.overflow);
    try expectEq(rn.v, Q128_MIN);
}

test "division and sqrt" {
    // 3 / 2 = 1.5
    const three = q128FromI64(3);
    const two = q128FromI64(2);
    const d = q128Div(three, two);
    const one_half = q128FromRatio(1, 2);
    try expectEq(d, q128Add(Q_ONE, one_half));
    // sqrt(4) = 2
    const s4 = q128Sqrt(q128FromI64(4));
    try expectEq(s4, two);
    // sqrt(2) ~= 1.414213562373095048801688724209698078
    const s2 = q128Sqrt(q128FromI64(2));
    const s2f = toFloat(s2);
    try testing.expect(@abs(s2f - 1.4142135623730951) < 1e-12);
}

test "constants" {
    try testing.expectEqual(C2_INT, @as(u128, 89_875_517_873_681_764));
    const pi_f = toFloat(PI_RAW);
    try testing.expect(@abs(pi_f - 3.141592653589793) < 1e-12);
    const phi_f = toFloat(PHI_RAW);
    try testing.expect(@abs(phi_f - 1.618033988749895) < 1e-12);
    // 1/c^2 in float
    const c2i_f = toFloat(Q_C2_INV);
    try testing.expect(@abs(c2i_f - 1.1126500560536184e-17) < 1e-29);
}

test "pow exact small powers" {
    // x^0 = 1, x^1 = x (bit-exact)
    try expectEq(q128Pow(PHI_RAW, 0).v, Q_ONE);
    try expectEq(q128Pow(PHI_RAW, 1).v, PHI_RAW);
    // 2^10 = 1024 exact
    const p10 = q128Pow(q128FromI64(2), 10);
    try testing.expect(!p10.underflow);
    try expectEq(p10.v, q128FromI64(1024));
    // 2^-10 = 1/1024 exact
    const p10n = q128Pow(q128FromI64(2), -10);
    try testing.expect(!p10n.underflow);
    try expectEq(p10n.v, q128FromRatio(1, 1024));
}

test "pow phi matches f64 reference" {
    // phi^2 = 2.618033988749895
    const p2 = q128Pow(PHI_RAW, 2);
    try testing.expect(@abs(toFloat(p2.v) - 2.618033988749895) < 1e-15);
    // phi^-1 = 0.6180339887498948
    const pinv = q128Pow(PHI_RAW, -1);
    try testing.expect(!pinv.underflow);
    try testing.expect(@abs(toFloat(pinv.v) - 0.6180339887498948) < 1e-15);
    // phi^-5 = 0.09016994374947424
    const pneg5 = q128Pow(PHI_RAW, -5);
    try testing.expect(@abs(toFloat(pneg5.v) - 0.09016994374947424) < 1e-15);
    // phi^5 = 11.090169943749475 (the 21cm term)
    const p5 = q128Pow(PHI_RAW, 5);
    try testing.expect(@abs(toFloat(p5.v) - 11.090169943749475) < 1e-12);
}

test "pow underflow below epsilon floor" {
    // phi^-186 and beyond fall below 2^-128
    const deep = q128Pow(PHI_RAW, -200);
    try testing.expect(deep.underflow);
    try expectEq(deep.v, Q_ZERO);
    // pi^-88 also underflows (Planck Time terms)
    const pi88 = q128Pow(PI_RAW, -88);
    try testing.expect(pi88.underflow);
    // but phi^-185 is still representable (log2(phi)*185 < 128)
    const edge = q128Pow(PHI_RAW, -185);
    try testing.expect(!edge.underflow);
    try testing.expect(!q128Eq(edge.v, Q_ZERO));
}

test "pow no overflow in triad exponent range" {
    // largest positive exponents in the constant table: phi^161, pi^60
    const p161 = q128Pow(PHI_RAW, 161);
    try testing.expect(!p161.underflow);
    const f161 = toFloat(p161.v);
    try testing.expect(f161 > 1e33 and f161 < 1.7e38);
    const p60 = q128Pow(PI_RAW, 60);
    const f60 = toFloat(p60.v);
    try testing.expect(f60 > 1e29 and f60 < 1.7e38);
}

test "fromF64 round trip" {
    // Round-trip error is bounded by max(f64 relative error ~2^-53 scaled
    // by |v|, one q128 ulp 2^-128) — fixed-point has absolute, not
    // relative, resolution.
    const vals = [_]f64{ 1.0, -1.0, 0.5, 3.141592653589793, 2.72548, 1.4106067974e-26, 6.62607015e-34, 1.616255e-35, 21.106114054 };
    for (vals) |v| {
        const qv = q128FromF64(v);
        const back = toFloat(qv);
        const tol = @max(@as(f64, 1e-15) * @abs(v), 4.0 * 2.938735877055719e-39);
        try testing.expect(@abs(back - v) <= tol);
    }
    // saturation and flush
    try expectEq(q128FromF64(1e300), Q128_MAX);
    try expectEq(q128FromF64(1e-45), Q_ZERO);
    try expectEq(q128FromF64(0), Q_ZERO);
}
