//! q128.zig — Q128.128 fixed-point arithmetic library (i256 raw, i512 intermediates).
//!
//! Provides integer-only arithmetic for core lattice state transitions.
//! All values are represented as i256 with 128 fractional bits, giving:
//!   - Integer range: [-2^127, 2^127) = [-1.7e38, 1.7e38)
//!   - Fractional precision: 1/2^128 ≈ 2.94e-39
//!   - ~39 decimal digits of precision
//!
//! Uses i512 intermediates for multiplication and division to prevent overflow.
//! i256 and i512 are supported internally on all targets including wasm32-freestanding.
//!
//! Multiply uses round-to-nearest-even (RNE) with exact 512-bit products,
//! ported from the Q128.128 (FANO-1) engine. Error bound: |x*y - fl(x*y)| <= 2^-129
//! (half ULP).
//!
//! No f32/f64/f16/f128 in state paths. Pure integer arithmetic with bit shifts.
//! All operations are deterministic and cross-platform identical.
//!
//! This module provides BOTH a structured Q128 struct API (matching the hardware
//! project) AND free functions (matching the qstar fixed_point.zig API) for
//! backward-compatible migration.

const std = @import("std");

// =============================================================================
// Core Types
// =============================================================================

/// The fixed-point type: i256 with 128 fractional bits.
pub const Fp = i256;

/// Wide intermediate type for multiplication (512-bit).
pub const Wide = i512;

/// Number of fractional bits in Q128.128 format.
pub const FRAC_BITS: u8 = 128;

/// 1.0 in fixed-point: 2^128
pub const ONE: Fp = @as(Fp, 1) << FRAC_BITS;

/// 0.5 in fixed-point
pub const HALF: Fp = ONE >> 1;

/// Zero
pub const ZERO: Fp = 0;

/// Maximum representable value.
pub const MAX_VAL: Fp = std.math.maxInt(i256);

/// Minimum representable value.
pub const MIN_VAL: Fp = std.math.minInt(i256);

/// 2^128 as f64 for comptime constant computation (sidecar only).
const ONE_F: f64 = @as(f64, @floatFromInt(ONE));

pub const Error = error{ DivisionByZero, Overflow };

// =============================================================================
// Q128 Struct API (matches hardware project fixed_point.zig)
// =============================================================================

pub const Q128 = struct {
    raw: Fp,

    pub const zero = Q128{ .raw = 0 };
    pub const one = Q128{ .raw = ONE };

    pub fn fromInteger(value: i256) Q128 {
        return .{ .raw = value * ONE };
    }

    pub fn fromRaw(raw: Fp) Q128 {
        return .{ .raw = raw };
    }

    pub fn add(self: Q128, other: Q128) Q128 {
        return .{ .raw = self.raw + other.raw };
    }

    pub fn sub(self: Q128, other: Q128) Q128 {
        return .{ .raw = self.raw - other.raw };
    }

    pub fn neg(self: Q128) Q128 {
        return .{ .raw = -self.raw };
    }

    pub fn mul(self: Q128, other: Q128) Q128 {
        const product: Wide = @as(Wide, self.raw) * @as(Wide, other.raw);
        const truncated: Fp = @truncate(product >> FRAC_BITS);
        const low_mask: Wide = (@as(Wide, 1) << FRAC_BITS) - 1;
        const discarded: Wide = product & low_mask;
        const halfway: Wide = @as(Wide, 1) << (FRAC_BITS - 1);
        if (discarded > halfway) {
            return .{ .raw = truncated +% 1 };
        } else if (discarded == halfway) {
            if ((truncated & 1) != 0) {
                return .{ .raw = truncated +% 1 };
            }
        }
        return .{ .raw = truncated };
    }

    pub fn div(self: Q128, other: Q128) Error!Q128 {
        if (other.raw == 0) return error.DivisionByZero;
        const numerator: Wide = @as(Wide, self.raw) << FRAC_BITS;
        return .{ .raw = @truncate(@divTrunc(numerator, @as(Wide, other.raw))) };
    }

    pub fn fromRatio(num: i256, den: i256) Error!Q128 {
        if (den == 0) return error.DivisionByZero;
        const sign: i256 = if ((num < 0) != (den < 0)) -1 else 1;
        const abs_num: i256 = if (num < 0) -num else num;
        const abs_den: i256 = if (den < 0) -den else den;
        const scaled_num: Wide = @as(Wide, abs_num) << FRAC_BITS;
        const quotient: Wide = @divTrunc(scaled_num, @as(Wide, abs_den));
        const remainder: Wide = @mod(scaled_num, @as(Wide, abs_den));
        const half_den: Wide = @as(Wide, abs_den) >> 1;
        var result: Wide = quotient;
        if (remainder > half_den or (remainder == half_den and remainder != 0)) {
            result +%= 1;
        }
        const raw: Fp = @truncate(if (sign < 0) -result else result);
        return .{ .raw = raw };
    }

    pub fn pow(self: Q128, exponent: i32) Error!Q128 {
        if (exponent == 0) return one;
        if (exponent < 0) {
            const positive = try self.pow(-exponent);
            return try one.div(positive);
        }
        var result = one;
        var base = self;
        var n: u32 = @intCast(exponent);
        while (n > 0) : (n >>= 1) {
            if ((n & 1) == 1) result = result.mul(base);
            if (n > 1) base = base.mul(base);
        }
        return result;
    }

    pub fn abs(self: Q128) Q128 {
        return if (self.raw < 0) self.neg() else self;
    }

    pub fn cmp(a: Q128, b: Q128) i8 {
        if (a.raw < b.raw) return -1;
        if (a.raw > b.raw) return 1;
        return 0;
    }

    pub fn eq(a: Q128, b: Q128) bool {
        return a.raw == b.raw;
    }

    pub fn fromI64(value: i64) Q128 {
        return fromInteger(@as(i256, value));
    }

    pub fn toInteger(self: Q128) i256 {
        return @divTrunc(self.raw, ONE);
    }

    pub fn sqrt(self: Q128) Error!Q128 {
        if (self.raw < 0) return error.Overflow;
        if (self.raw == 0) return zero;
        if (self.raw == ONE) return one;
        const n: u256 = @intCast(self.raw);
        var bitlen: u8 = 0;
        var tmp = n;
        while (tmp > 0) : (tmp >>= 1) bitlen += 1;
        var x: u256 = @as(u256, 1) << @intCast((bitlen / 2) + 64);
        const max_iters: u32 = 200;
        var i: u32 = 0;
        while (i < max_iters) : (i += 1) {
            const s_scaled: u512 = @as(u512, n) << 128;
            const x_u512: u512 = @as(u512, x);
            if (x_u512 == 0) break;
            const quotient = s_scaled / x_u512;
            const x_new = (x_u512 + quotient) / 2;
            const x_new_trunc: u256 = @truncate(x_new);
            if (x_new_trunc == x) break;
            x = x_new_trunc;
        }
        return .{ .raw = @intCast(x) };
    }
};

// =============================================================================
// Free Function API (matches qstar fixed_point.zig for backward compatibility)
// =============================================================================

/// Convert an integer to fixed-point.
pub inline fn fromInt(v: i64) Fp {
    return @as(Fp, v) << FRAC_BITS;
}

/// Convert a large integer to fixed-point.
pub inline fn fromI256(v: i256) Fp {
    return v * ONE;
}

/// Convert fixed-point to integer (truncates fractional part).
/// Clamps to i64 range if the integer part exceeds i64 capacity.
pub inline fn toInt(v: Fp) i64 {
    const shifted: Fp = v >> FRAC_BITS;
    if (shifted > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (shifted < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(shifted);
}

/// Convert fixed-point to i256 integer.
pub inline fn toI256(v: Fp) i256 {
    return @divTrunc(v, ONE);
}

/// Convert fixed-point to a string representation for debugging.
pub fn format(allocator: std.mem.Allocator, v: Fp) ![]u8 {
    const int_part = toInt(v);
    const frac_part = v & (ONE - 1);
    const frac_scaled: u256 = @intCast(frac_part);
    const frac_4dp = (frac_scaled * 10000) >> FRAC_BITS;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>4}", .{ int_part, frac_4dp });
}

// =============================================================================
// Arithmetic Operations
// =============================================================================

/// Fixed-point addition.
pub inline fn add(a: Fp, b: Fp) Fp {
    return a + b;
}

/// Fixed-point subtraction.
pub inline fn sub(a: Fp, b: Fp) Fp {
    return a - b;
}

/// Fixed-point multiplication: (a * b) >> FRAC_BITS with round-to-nearest-even.
/// Uses i512 intermediate to compute the exact product, then rounds to nearest
/// even (RNE) — ported from the Q128.128 (FANO-1) engine.
/// Error bound: |x*y - fl(x*y)| <= 2^-129 (half ULP).
pub inline fn mul(a: Fp, b: Fp) Fp {
    const result: Wide = @as(Wide, a) * @as(Wide, b);
    const round_bit: bool = ((result >> @intCast(FRAC_BITS - 1)) & 1) != 0;
    const sticky_mask: Wide = (@as(Wide, 1) << @intCast(FRAC_BITS - 1)) - 1;
    const sticky: bool = (result & sticky_mask) != 0;
    const lsb: bool = ((result >> @intCast(FRAC_BITS)) & 1) != 0;
    const up: bool = round_bit and (sticky or lsb);
    const shifted: Wide = result >> @intCast(FRAC_BITS);
    return @intCast(if (up) shifted + 1 else shifted);
}

/// Fixed-point division: (a << FRAC_BITS) / b.
/// Uses i512 intermediate to prevent overflow.
pub inline fn div(a: Fp, b: Fp) Fp {
    if (b == 0) return 0;
    const result: Wide = @divTrunc(@as(Wide, a) << FRAC_BITS, @as(Wide, b));
    return @intCast(result);
}

/// Construct a fixed-point value from a rational number num/den.
/// Uses round-half-away-from-zero, matching the Q128.128 q128FromRatio semantics.
/// Returns 0 if den is 0 (no panic — safe for lattice arithmetic).
pub fn fromRatio(num: Fp, den: Fp) Fp {
    if (den == 0) return 0;
    const scaled: Wide = @as(Wide, num) << FRAC_BITS;
    const q: Wide = @divTrunc(scaled, @as(Wide, den));
    const remainder: Wide = @rem(scaled, @as(Wide, den));
    const half_den: Wide = @divTrunc(@as(Wide, den), 2);
    const abs_rem: Wide = if (remainder < 0) -remainder else remainder;
    const abs_half: Wide = if (half_den < 0) -half_den else half_den;
    if (abs_rem >= abs_half) {
        return @intCast(if (q >= 0) q + 1 else q - 1);
    }
    return @intCast(q);
}

/// Compare two fixed-point values. Returns -1 if a < b, 0 if a == b, 1 if a > b.
pub fn cmp(a: Fp, b: Fp) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

/// Check if two fixed-point values are exactly equal.
pub fn eq(a: Fp, b: Fp) bool {
    return a == b;
}

/// Absolute value.
pub inline fn absVal(v: Fp) Fp {
    return if (v < 0) -v else v;
}

/// Negate.
pub inline fn negate(v: Fp) Fp {
    return -v;
}

/// Alias for negate (matches Q128 struct method name).
pub inline fn neg(v: Fp) Fp {
    return -v;
}

/// Maximum of two values.
pub inline fn maxVal(a: Fp, b: Fp) Fp {
    return if (a > b) a else b;
}

/// Minimum of two values.
pub inline fn minVal(a: Fp, b: Fp) Fp {
    return if (a < b) a else b;
}

/// Clamp value to [lo, hi].
pub inline fn clamp(v: Fp, lo: Fp, hi: Fp) Fp {
    return maxVal(lo, minVal(hi, v));
}

/// Power: raises base to an integer exponent. Returns ONE for exp=0.
/// For negative exponents, returns the reciprocal (0 if base is 0).
pub fn pow(base: Fp, exponent: i32) Fp {
    if (exponent == 0) return ONE;
    if (base == 0) return 0;
    if (exponent < 0) {
        const positive = pow(base, -exponent);
        return div(ONE, positive);
    }
    var result: Fp = ONE;
    var b: Fp = base;
    var n: u32 = @intCast(exponent);
    while (n > 0) : (n >>= 1) {
        if ((n & 1) == 1) result = mul(result, b);
        if (n > 1) b = mul(b, b);
    }
    return result;
}

// =============================================================================
// Q64.64 ↔ Q128.128 Conversion (for backward compatibility)
// =============================================================================

/// Convert a Q64.64 value (i128, 64 fractional bits) to Q128.128 (i256, 128 fractional bits).
/// Shifts left by 64 bits to add 64 more fractional bits of precision.
pub inline fn q64ToQ128(v: i128) Fp {
    return @as(Fp, v) << 64;
}

/// Convert a Q128.128 value (i256, 128 fractional bits) to Q64.64 (i128, 64 fractional bits).
/// Shifts right by 64 bits, losing 64 bits of fractional precision.
pub inline fn q128ToQ64(v: Fp) i128 {
    return @intCast(v >> 64);
}

/// Convert an f64 to Q128.128 (sidecar bridge only — not for state paths).
pub inline fn fromF64(v: f64) Fp {
    return @intFromFloat(v * @as(f64, @floatFromInt(ONE)));
}

/// Convert Q128.128 to f64 (sidecar bridge only — not for state paths).
pub inline fn toF64(v: Fp) f64 {
    return @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(ONE));
}

// =============================================================================
// Constants (precomputed in Q128.128)
// =============================================================================

/// Golden ratio φ = (1 + √5) / 2 ≈ 1.6180339887
pub const PHI: Fp = @intFromFloat(1.6180339887498948482 * ONE_F);

/// 1/φ ≈ 0.6180339887
pub const INV_PHI: Fp = @intFromFloat(0.6180339887498948482 * ONE_F);

/// 1/sqrt(2) ≈ 0.7071067811865476
pub const INV_SQRT2: Fp = @intFromFloat(0.7071067811865476 * ONE_F);

/// π ≈ 3.141592653589793
pub const PI: Fp = @intFromFloat(3.141592653589793 * ONE_F);

/// 2π ≈ 6.283185307179586
pub const TWO_PI: Fp = @intFromFloat(6.283185307179586 * ONE_F);

/// e (Euler's number) ≈ 2.718281828459045
pub const E: Fp = @intFromFloat(2.718281828459045 * ONE_F);

/// 0.001 in Q128.128 (minimum temperature floor)
pub const TEMP_FLOOR: Fp = @divTrunc(ONE, 1000);

/// 0.5 in Q128.128 (firing threshold)
pub const HALF_FP: Fp = HALF;

/// 0.8 in Q128.128 (propagation weight)
pub const WEIGHT_08: Fp = @divTrunc(ONE * 8, 10);

/// 0.3 in Q128.128 (boundary reflection weight)
pub const WEIGHT_03: Fp = @divTrunc(ONE * 3, 10);

/// 0.15 in Q128.128 (neighbor propagation weight)
pub const WEIGHT_015: Fp = @divTrunc(ONE * 15, 100);

/// 0.7 in Q128.128 (decay factor)
pub const DECAY_07: Fp = @divTrunc(ONE * 7, 10);

/// 0.01 in Q128.128 (position decay factor)
pub const POS_DECAY: Fp = @divTrunc(ONE, 100);

/// 10.0 in Q128.128 (logit scale)
pub const LOGIT_SCALE: Fp = fromInt(10);

/// 33.0 in Q128.128 (Fibonacci normalization)
pub const FIB_NORM: Fp = fromInt(33);

/// Fibonacci weights in Q128.128: [1, 1, 2, 3, 5, 8, 13, 21]
pub const FIB_WEIGHTS = [_]Fp{
    fromInt(1),
    fromInt(1),
    fromInt(2),
    fromInt(3),
    fromInt(5),
    fromInt(8),
    fromInt(13),
    fromInt(21),
};

// =============================================================================
// EU v11.1 Geometric & Physical Constants (Q128.128)
// =============================================================================

/// Möbius defect density: δ = 7 / 225 ≈ 0.03111111
pub const DEFECT_DELTA: Fp = fromRatio(7, 225);

/// Active E0 observer density: ρ = 421 / 3375 ≈ 0.12474074
pub const ACTIVE_DENSITY_RHO: Fp = fromRatio(421, 3375);

/// Inter-qubit universal coupling constant: g = δ × ρ = (7/225) × (421/3375) ≈ 0.0038809
pub const COUPLING_G: Fp = fromRatio(7 * 421, 225 * 3375);

/// Consciousness bandwidth ratio: C = c(6) / c(5) = 42 / 21 = 2.0 (exact)
pub const BANDWIDTH_C: Fp = fromInt(2);

/// Complete E8 root system count (e0 = E8 = 0^0 = 240)
pub const E8_ROOT_COUNT: u32 = 240;

/// Base lattice interior cells: 15^3 = 3,375
pub const INTERIOR_CELLS: u32 = 3375;

/// Base lattice shell cells: 16^3 = 4,096
pub const SHELL_CELLS: u32 = 4096;

/// Exact boundary cells: 4,096 - 3,375 = 721 (7 × 103)
pub const BOUNDARY_CELLS: u32 = 721;

// =============================================================================
// GUT Constants — Generative Universal Transformer (Complex Idealism)
// =============================================================================

/// 22/7 Archimedes harmonic — 7-channel beat frequency
pub const GUT_HARMONIC: usize = 7;

/// 355/113 Milü super-period — near-perfect phase alignment every 113 steps
pub const GUT_SUPER_PERIOD: usize = 113;

/// Continued fraction term a₂ = 15 (BASE_EDGE)
pub const GUT_CF_15: usize = 15;

/// GUT 2×2 rational rotation matrix in Q128.128 fixed-point.
pub const GutMatrix = struct {
    a: Fp,
    b: Fp,
    c: Fp,
    d: Fp,
};

/// Compute GUT rotation matrix Ψ(N) for a given rational step N in Q128.128.
pub fn gutRotation(N: Fp) GutMatrix {
    if (N == 0) return .{ .a = ONE, .b = 0, .c = 0, .d = ONE };
    const n_sq = mul(N, N);
    const denom = add(n_sq, ONE);
    if (denom == 0) return .{ .a = ONE, .b = 0, .c = 0, .d = ONE };
    const a_d = div(sub(n_sq, ONE), denom);
    const b = div(mul(fromInt(-2), N), denom);
    const c = div(mul(fromInt(2), N), denom);
    return .{ .a = a_d, .b = b, .c = c, .d = a_d };
}

/// Multiply two GUT matrices.
pub fn gutMatMul(m1: GutMatrix, m2: GutMatrix) GutMatrix {
    return .{
        .a = sub(mul(m1.a, m2.a), mul(m1.b, m2.c)),
        .b = add(mul(m1.a, m2.b), mul(m1.b, m2.d)),
        .c = sub(mul(m1.c, m2.a), mul(m1.d, m2.c)),
        .d = add(mul(m1.c, m2.b), mul(m1.d, m2.d)),
    };
}

/// Apply GUT rotation to a 2D vector (re, im) in Q128.128.
pub fn gutApply(m: GutMatrix, re: Fp, im: Fp) struct { re: Fp, im: Fp } {
    return .{
        .re = sub(mul(m.a, re), mul(m.b, im)),
        .im = add(mul(m.c, re), mul(m.d, im)),
    };
}

/// Compute phase drift: det(Ψ^Υ - I) = distance from identity.
pub fn gutPhaseDrift(m: GutMatrix) Fp {
    const da = sub(m.a, ONE);
    const db = m.b;
    const dc = m.c;
    const dd = sub(m.d, ONE);
    return add(add(absVal(da), absVal(db)), add(absVal(dc), absVal(dd)));
}

/// Check if the GUT flow parameter Υ is at a harmonic resonance (Υ mod 7 == 0).
pub fn gutIsHarmonic(upsilon: usize) bool {
    return @rem(upsilon, GUT_HARMONIC) == 0;
}

/// Check if the GUT flow parameter Υ is at a super-resonance (Υ mod 113 == 0).
pub fn gutIsSuperResonant(upsilon: usize) bool {
    return @rem(upsilon, GUT_SUPER_PERIOD) == 0;
}

// =============================================================================
// Integer Sigmoid Lookup Table
// =============================================================================

const SIGMOID_TABLE_SIZE: usize = 512;
const SIGMOID_RANGE: Fp = fromInt(8);

const sigmoid_table: [SIGMOID_TABLE_SIZE]Fp = blk: {
    @setEvalBranchQuota(20000);
    var table: [SIGMOID_TABLE_SIZE]Fp = undefined;
    for (0..SIGMOID_TABLE_SIZE) |i| {
        const x_f: f64 = -8.0 + (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SIGMOID_TABLE_SIZE))) * 16.0;
        const sig_f: f64 = 1.0 / (1.0 + @exp(-x_f));
        const q_val: Fp = @intFromFloat(sig_f * @as(f64, @floatFromInt(ONE)));
        table[i] = q_val;
    }
    break :blk table;
};

pub fn sigmoid(x: Fp) Fp {
    if (x >= SIGMOID_RANGE) return ONE;
    if (x <= -SIGMOID_RANGE) return 0;
    const offset = x + SIGMOID_RANGE;
    const scaled: Wide = @as(Wide, offset) * @as(Wide, SIGMOID_TABLE_SIZE);
    const range: Wide = @as(Wide, SIGMOID_RANGE) * 2;
    const idx: Fp = @intCast(@divTrunc(scaled, range));
    const clamped: usize = @intCast(clamp(idx, 0, @as(Fp, @intCast(SIGMOID_TABLE_SIZE - 1))));
    return sigmoid_table[clamped];
}

// =============================================================================
// Integer Exponential Approximation (Taylor series in fixed-point)
// =============================================================================

pub fn exp(x: Fp) Fp {
    if (x >= fromInt(10)) return MAX_VAL;
    if (x <= -fromInt(20)) return 0;
    var val = x;
    var n_shifts: u32 = 0;
    while (val > fromInt(2) or val < -fromInt(2)) {
        val >>= 1;
        n_shifts += 1;
    }
    var result: Fp = ONE;
    var term: Fp = ONE;
    term = val;
    result = add(result, term);
    term = mul(term, val);
    term = div(term, fromInt(2));
    result = add(result, term);
    term = mul(term, val);
    term = div(term, fromInt(3));
    result = add(result, term);
    term = mul(term, val);
    term = div(term, fromInt(4));
    result = add(result, term);
    term = mul(term, val);
    term = div(term, fromInt(5));
    result = add(result, term);
    term = mul(term, val);
    term = div(term, fromInt(6));
    result = add(result, term);
    while (n_shifts > 0) : (n_shifts -= 1) {
        result = mul(result, result);
    }
    return result;
}

// =============================================================================
// Integer Sin/Cos Lookup Tables (for DFT roots of unity)
// =============================================================================

const TRIG_TABLE_SIZE: usize = 1024;

const sin_table: [TRIG_TABLE_SIZE]Fp = blk: {
    @setEvalBranchQuota(20000);
    var table: [TRIG_TABLE_SIZE]Fp = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        const sin_val: f64 = @sin(angle);
        table[i] = @intFromFloat(sin_val * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

const cos_table: [TRIG_TABLE_SIZE]Fp = blk: {
    @setEvalBranchQuota(20000);
    var table: [TRIG_TABLE_SIZE]Fp = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        const cos_val: f64 = @cos(angle);
        table[i] = @intFromFloat(cos_val * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

pub fn sin(angle: Fp) Fp {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;
    const idx: Wide = @divTrunc(@as(Wide, a) * @as(Wide, TRIG_TABLE_SIZE), @as(Wide, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(Wide, TRIG_TABLE_SIZE)));
    return sin_table[clamped];
}

pub fn cos(angle: Fp) Fp {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;
    const idx: Wide = @divTrunc(@as(Wide, a) * @as(Wide, TRIG_TABLE_SIZE), @as(Wide, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(Wide, TRIG_TABLE_SIZE)));
    return cos_table[clamped];
}

pub fn sincos(angle: Fp) struct { sin_val: Fp, cos_val: Fp } {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;
    const idx: Wide = @divTrunc(@as(Wide, a) * @as(Wide, TRIG_TABLE_SIZE), @as(Wide, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(Wide, TRIG_TABLE_SIZE)));
    return .{ .sin_val = sin_table[clamped], .cos_val = cos_table[clamped] };
}

pub fn twiddle(k: usize, N: usize) struct { re: Fp, im: Fp } {
    const angle: Wide = @divTrunc(-(@as(Wide, TWO_PI) * @as(Wide, @intCast(k))), @as(Wide, @intCast(N)));
    const angle_fp: Fp = @intCast(angle);
    const sc = sincos(angle_fp);
    return .{ .re = sc.cos_val, .im = sc.sin_val };
}

// =============================================================================
// φ-Cooling (integer-only)
// =============================================================================

const PHI_COOL_TABLE_SIZE: usize = 64;
const phi_cool_table: [PHI_COOL_TABLE_SIZE]Fp = blk: {
    @setEvalBranchQuota(20000);
    var table: [PHI_COOL_TABLE_SIZE]Fp = undefined;
    var val: f64 = 1.0;
    for (0..PHI_COOL_TABLE_SIZE) |i| {
        table[i] = @intFromFloat(val * @as(f64, @floatFromInt(ONE)));
        val /= 1.6180339887498948482;
    }
    break :blk table;
};

pub fn phiCool(base_temp: Fp, cycle: u64) Fp {
    if (cycle >= PHI_COOL_TABLE_SIZE) return TEMP_FLOOR;
    const factor = phi_cool_table[@intCast(cycle)];
    const result = mul(base_temp, factor);
    return if (result < TEMP_FLOOR) TEMP_FLOOR else result;
}

// =============================================================================
// Square Root (integer-only, Newton's method)
// =============================================================================

pub fn sqrt(x: Fp) Fp {
    if (x <= 0) return 0;
    const lz = @clz(x);
    const bit_pos: u8 = @intCast(255 - lz);
    const half_pos: u8 = @intCast((@as(u32, bit_pos) + FRAC_BITS) / 2);
    var guess: Fp = @as(Fp, 1) << half_pos;
    if (guess == 0) guess = ONE;
    for (0..30) |_| {
        const new_guess = (guess + div(x, guess)) >> 1;
        if (absVal(new_guess - guess) <= 1) break;
        guess = new_guess;
    }
    return guess;
}

// =============================================================================
// SIMD Batch Operations — @Vector-accelerated fixed-point arithmetic
// =============================================================================

pub fn mulVec4(a: @Vector(4, Fp), b: @Vector(4, Fp)) @Vector(4, Fp) {
    return .{
        mul(a[0], b[0]),
        mul(a[1], b[1]),
        mul(a[2], b[2]),
        mul(a[3], b[3]),
    };
}

pub fn addVec4(a: @Vector(4, Fp), b: @Vector(4, Fp)) @Vector(4, Fp) {
    return a + b;
}

pub fn subVec4(a: @Vector(4, Fp), b: @Vector(4, Fp)) @Vector(4, Fp) {
    return a - b;
}

pub fn fromIntVec4(v: @Vector(4, i64)) @Vector(4, Fp) {
    const wide: @Vector(4, Fp) = @intCast(v);
    return wide << @as(@Vector(4, u8), @splat(FRAC_BITS));
}

pub fn mulBatch(dst: []Fp, a: []const Fp, b: []const Fp) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: @Vector(4, Fp) = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: @Vector(4, Fp) = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
        const result = mulVec4(va, vb);
        dst[i] = result[0];
        dst[i + 1] = result[1];
        dst[i + 2] = result[2];
        dst[i + 3] = result[3];
    }
    while (i < n) : (i += 1) {
        dst[i] = mul(a[i], b[i]);
    }
}

pub fn addBatch(dst: []Fp, a: []const Fp, b: []const Fp) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: @Vector(4, Fp) = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: @Vector(4, Fp) = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
        const result = va + vb;
        dst[i] = result[0];
        dst[i + 1] = result[1];
        dst[i + 2] = result[2];
        dst[i + 3] = result[3];
    }
    while (i < n) : (i += 1) {
        dst[i] = a[i] + b[i];
    }
}

// =============================================================================
// Framework Verification
// =============================================================================

pub fn verifyFrameworkConstants() bool {
    // DEFECT_DELTA = 7/225
    const expected_defect = fromRatio(7, 225);
    {
        const diff = expected_defect - DEFECT_DELTA;
        const abs_diff = if (diff < 0) -diff else diff;
        if (abs_diff > 1) return false;
    }
    // ACTIVE_DENSITY_RHO = 421/3375
    const expected_rho = fromRatio(421, 3375);
    {
        const diff = expected_rho - ACTIVE_DENSITY_RHO;
        const abs_diff = if (diff < 0) -diff else diff;
        if (abs_diff > 1) return false;
    }
    // COUPLING_G = (7*421)/(225*3375)
    const expected_g = fromRatio(7 * 421, 225 * 3375);
    {
        const diff = expected_g - COUPLING_G;
        const abs_diff = if (diff < 0) -diff else diff;
        if (abs_diff > 2) return false;
    }
    if (BANDWIDTH_C != fromInt(2)) return false;
    if (E8_ROOT_COUNT != 240) return false;
    if (INTERIOR_CELLS != 3375) return false;
    if (SHELL_CELLS != 4096) return false;
    if (BOUNDARY_CELLS != 721) return false;
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "Q128.128: fromInt and toInt round trip" {
    try std.testing.expectEqual(fromInt(42), @as(Fp, 42) << FRAC_BITS);
    try std.testing.expectEqual(@as(i64, 42), toInt(fromInt(42)));
    try std.testing.expectEqual(@as(i64, -7), toInt(fromInt(-7)));
    try std.testing.expectEqual(@as(i64, 0), toInt(0));
}

test "Q128.128: add and sub" {
    const a = fromInt(10);
    const b = fromInt(3);
    try std.testing.expectEqual(fromInt(13), add(a, b));
    try std.testing.expectEqual(fromInt(7), sub(a, b));
}

test "Q128.128: mul preserves fractional precision" {
    const a = fromInt(3);
    const b = fromInt(4);
    try std.testing.expectEqual(fromInt(12), mul(a, b));
    const half = HALF_FP;
    const quarter = mul(half, half);
    try std.testing.expectEqual(ONE >> 2, quarter);
}

test "Q128.128: div preserves fractional precision" {
    const a = fromInt(10);
    const b = fromInt(3);
    const result = div(a, b);
    try std.testing.expectEqual(@as(i64, 3), toInt(result));
    try std.testing.expect(result > fromInt(3));
    try std.testing.expect(result < fromInt(4));
}

test "Q128.128: Q128 struct round trip" {
    const value = Q128.fromInteger(-123456);
    try std.testing.expectEqual(@as(i256, -123456), value.toInteger());
}

test "Q128.128: Q128 struct mul and div" {
    const six = Q128.fromInteger(6);
    const seven = Q128.fromInteger(7);
    const product = six.mul(seven);
    try std.testing.expectEqual(@as(i256, 42), product.toInteger());
}

test "Q128.128: Q128 struct fromRatio" {
    const half = try Q128.fromRatio(1, 2);
    try std.testing.expectEqual(ONE / 2, half.raw);
}

test "Q128.128: Q128 struct sqrt" {
    const four = Q128.fromInteger(4);
    const result = try four.sqrt();
    try std.testing.expectEqual(Q128.fromInteger(2).raw, result.raw);
}

test "Q128.128: Q64↔Q128 conversion" {
    const q64_val: i128 = 42 << 64; // 42.0 in Q64.64
    const q128_val = q64ToQ128(q64_val);
    try std.testing.expectEqual(fromInt(42), q128_val);
    const back = q128ToQ64(q128_val);
    try std.testing.expectEqual(q64_val, back);
}

test "Q128.128: sigmoid saturates at extremes" {
    try std.testing.expectEqual(ONE, sigmoid(fromInt(10)));
    try std.testing.expectEqual(@as(Fp, 0), sigmoid(-fromInt(10)));
}

test "Q128.128: sigmoid(0) = 0.5" {
    const result = sigmoid(0);
    try std.testing.expectEqual(HALF_FP, result);
}

test "Q128.128: exp(0) = 1" {
    const result = exp(0);
    try std.testing.expectEqual(ONE, result);
}

test "Q128.128: sin(0) = 0" {
    const result = sin(0);
    try std.testing.expect(absVal(result) <= 1);
}

test "Q128.128: cos(0) = 1" {
    const result = cos(0);
    try std.testing.expectEqual(ONE, result);
}

test "Q128.128: phiCool(1.0, 0) = 1.0" {
    const result = phiCool(ONE, 0);
    try std.testing.expectEqual(ONE, result);
}

test "Q128.128: phiCool decreases with cycle" {
    const t0 = phiCool(ONE, 0);
    const t1 = phiCool(ONE, 1);
    const t5 = phiCool(ONE, 5);
    try std.testing.expect(t1 < t0);
    try std.testing.expect(t5 < t1);
}

test "Q128.128: sqrt(4) = 2" {
    const result = sqrt(fromInt(4));
    try std.testing.expectEqual(fromInt(2), result);
}

test "Q128.128: constants are correct" {
    try std.testing.expect(toInt(PHI) == 1);
    try std.testing.expect(PHI > ONE);
    try std.testing.expect(PHI < fromInt(2));
    try std.testing.expect(toInt(INV_SQRT2) == 0);
    try std.testing.expect(INV_SQRT2 > 0);
    try std.testing.expect(INV_SQRT2 < ONE);
}

test "Q128.128: clamp works correctly" {
    try std.testing.expectEqual(fromInt(5), clamp(fromInt(5), fromInt(0), fromInt(10)));
    try std.testing.expectEqual(fromInt(0), clamp(-fromInt(5), fromInt(0), fromInt(10)));
    try std.testing.expectEqual(fromInt(10), clamp(fromInt(20), fromInt(0), fromInt(10)));
}

test "Q128.128: absVal works correctly" {
    try std.testing.expectEqual(fromInt(5), absVal(-fromInt(5)));
    try std.testing.expectEqual(fromInt(5), absVal(fromInt(5)));
    try std.testing.expectEqual(@as(Fp, 0), absVal(0));
}

test "Q128.128: GUT rotation matrix det=1" {
    const N = fromInt(3);
    const m = gutRotation(N);
    const det = sub(mul(m.a, m.d), mul(m.b, m.c));
    const drift = absVal(sub(det, ONE));
    try std.testing.expect(drift < div(ONE, fromInt(100)));
}

test "Q128.128: GUT identity rotation at N=0" {
    const m = gutRotation(fromInt(0));
    try std.testing.expectEqual(ONE, m.a);
    try std.testing.expectEqual(@as(Fp, 0), m.b);
    try std.testing.expectEqual(@as(Fp, 0), m.c);
    try std.testing.expectEqual(ONE, m.d);
}

test "Q128.128: GUT harmonic and super-resonance" {
    try std.testing.expect(gutIsHarmonic(7));
    try std.testing.expect(gutIsHarmonic(14));
    try std.testing.expect(!gutIsHarmonic(5));
    try std.testing.expect(gutIsSuperResonant(113));
    try std.testing.expect(!gutIsSuperResonant(112));
}

test "Q128.128: RNE mul exact integer" {
    try std.testing.expectEqual(fromInt(12), mul(fromInt(3), fromInt(4)));
    try std.testing.expectEqual(fromInt(1000000), mul(fromInt(1000), fromInt(1000)));
}

test "Q128.128: RNE mul 0.5 * 0.5 = 0.25" {
    const half = HALF_FP;
    const quarter = mul(half, half);
    try std.testing.expectEqual(ONE >> 2, quarter);
}

test "Q128.128: RNE mul negative values" {
    try std.testing.expectEqual(-fromInt(12), mul(-fromInt(3), fromInt(4)));
    const neg_half = -HALF_FP;
    const result = mul(neg_half, HALF_FP);
    try std.testing.expectEqual(-(ONE >> 2), result);
}

test "Q128.128: RNE mul commutative" {
    const a = fromInt(7) + HALF_FP;
    const b = fromInt(3) + HALF_FP;
    try std.testing.expectEqual(mul(a, b), mul(b, a));
}

test "Q128.128: fromRatio exact rational" {
    try std.testing.expectEqual(HALF_FP, fromRatio(1, 2));
    try std.testing.expectEqual(fromInt(2), fromRatio(6, 3));
}

test "Q128.128: fromRatio negative" {
    try std.testing.expectEqual(-HALF_FP, fromRatio(-1, 2));
    try std.testing.expectEqual(-HALF_FP, fromRatio(1, -2));
    try std.testing.expectEqual(fromInt(1) + HALF_FP, fromRatio(-3, -2));
}

test "Q128.128: fromRatio zero handling" {
    try std.testing.expectEqual(@as(Fp, 0), fromRatio(0, 5));
    try std.testing.expectEqual(@as(Fp, 0), fromRatio(5, 0));
}

test "Q128.128: framework constants verification" {
    try std.testing.expect(verifyFrameworkConstants());
}

test "Q128.128: FIB_WEIGHTS has 8 elements" {
    try std.testing.expectEqual(@as(usize, 8), FIB_WEIGHTS.len);
    try std.testing.expectEqual(fromInt(1), FIB_WEIGHTS[0]);
    try std.testing.expectEqual(fromInt(21), FIB_WEIGHTS[7]);
}

test "Q128.128: SIMD mulVec4 matches scalar" {
    const a: @Vector(4, Fp) = .{ fromInt(2), fromInt(3), fromInt(4), fromInt(5) };
    const b: @Vector(4, Fp) = .{ fromInt(3), fromInt(4), fromInt(5), fromInt(6) };
    const result = mulVec4(a, b);
    try std.testing.expectEqual(fromInt(6), result[0]);
    try std.testing.expectEqual(fromInt(12), result[1]);
    try std.testing.expectEqual(fromInt(20), result[2]);
    try std.testing.expectEqual(fromInt(30), result[3]);
}

test "Q128.128: SIMD mulBatch matches scalar" {
    var dst: [10]Fp = undefined;
    const a = [_]Fp{ fromInt(1), fromInt(2), fromInt(3), fromInt(4), fromInt(5), fromInt(6), fromInt(7), fromInt(8), fromInt(9), fromInt(10) };
    const b = [_]Fp{ fromInt(10), fromInt(9), fromInt(8), fromInt(7), fromInt(6), fromInt(5), fromInt(4), fromInt(3), fromInt(2), fromInt(1) };
    mulBatch(&dst, &a, &b);
    for (0..10) |i| {
        try std.testing.expectEqual(mul(a[i], b[i]), dst[i]);
    }
}

test "Q128.128: Q128 struct pow" {
    const two = Q128.fromInteger(2);
    try std.testing.expectEqual(@as(i256, 32), (try two.pow(5)).toInteger());
}
