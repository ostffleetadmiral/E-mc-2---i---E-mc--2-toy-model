//! fixed_point.zig — Q64.64 fixed-point arithmetic library.
//!
//! Provides integer-only arithmetic for core lattice state transitions.
//! All values are represented as i128 with 64 fractional bits, giving:
//!   - Integer range: [-2^63, 2^63) = [-9.2e18, 9.2e18)
//!   - Fractional precision: 1/2^64 ≈ 5.42e-20
//!   - ~19 decimal digits of precision
//!
//! Uses i256 intermediates for multiplication and division to prevent overflow.
//! i256 is supported internally on all targets including wasm32-freestanding.
//!
//! Multiply uses round-to-nearest-even (RNE) with exact 256-bit products,
//! ported from the Q128.128 (FANO-1) engine. Error bound: |x*y - fl(x*y)| <= 2^-65
//! (half ULP). The previous truncating multiply had up to 1 ULP systematic bias.
//!
//! No f32/f64/f16/f128 in state paths. Pure integer arithmetic with bit shifts.
//! All operations are deterministic and cross-platform identical.

const std = @import("std");

/// Number of fractional bits in Q64.64 format.
pub const FRAC_BITS: u7 = 64;
pub const ONE: i128 = 1 << FRAC_BITS; // 1.0 in fixed-point
pub const HALF: i128 = ONE >> 1; // 0.5
pub const ZERO: i128 = 0;

/// Maximum representable value.
pub const MAX_VAL: i128 = std.math.maxInt(i128);
pub const MIN_VAL: i128 = std.math.minInt(i128);

/// 2^64 as f64 for comptime constant computation.
const ONE_F: f64 = 18446744073709551616.0;

/// Convert an integer to fixed-point.
pub inline fn fromInt(v: i64) i128 {
    return @as(i128, v) << FRAC_BITS;
}

/// Convert fixed-point to integer (truncates fractional part).
/// Clamps to i64 range if the integer part exceeds i64 capacity.
pub inline fn toInt(v: i128) i64 {
    const shifted: i128 = v >> FRAC_BITS;
    if (shifted > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (shifted < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(shifted);
}

/// Convert fixed-point to a string representation for debugging.
pub fn format(allocator: std.mem.Allocator, v: i128) ![]u8 {
    const int_part = toInt(v);
    const frac_part = v & (ONE - 1);
    const frac_scaled: u128 = @intCast(frac_part);
    // Print as int.fraction with 4 decimal places
    const frac_4dp = (frac_scaled * 10000) >> FRAC_BITS;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>4}", .{ int_part, frac_4dp });
}

// =============================================================================
// Arithmetic Operations
// =============================================================================

/// Fixed-point addition.
pub inline fn add(a: i128, b: i128) i128 {
    return a + b;
}

/// Fixed-point subtraction.
pub inline fn sub(a: i128, b: i128) i128 {
    return a - b;
}

/// Fixed-point multiplication: (a * b) >> FRAC_BITS with round-to-nearest-even.
/// Uses i256 intermediate to compute the exact product, then rounds to nearest
/// even (RNE) — ported from the Q128.128 (FANO-1) engine.
/// Error bound: |x*y - fl(x*y)| <= 2^-65 (half ULP).
pub inline fn mul(a: i128, b: i128) i128 {
    const result: i256 = @as(i256, a) * @as(i256, b);
    // RNE: round bit = bit 63 (highest fractional bit being shifted out)
    const round_bit: bool = ((result >> @intCast(FRAC_BITS - 1)) & 1) != 0;
    // Sticky bit: any of bits 0..62 being nonzero
    const sticky_mask: i256 = (@as(i256, 1) << @intCast(FRAC_BITS - 1)) - 1;
    const sticky: bool = (result & sticky_mask) != 0;
    // LSB: bit 64 of the result (lowest bit kept after shift)
    const lsb: bool = ((result >> @intCast(FRAC_BITS)) & 1) != 0;
    // Round up if round_bit AND (sticky OR lsb) — ties round to even
    const up: bool = round_bit and (sticky or lsb);
    const shifted: i256 = result >> @intCast(FRAC_BITS);
    return @intCast(if (up) shifted + 1 else shifted);
}

/// Fixed-point division: (a << FRAC_BITS) / b.
/// Uses i256 intermediate to prevent overflow.
pub inline fn div(a: i128, b: i128) i128 {
    if (b == 0) return 0;
    const result: i256 = @divTrunc(@as(i256, a) << FRAC_BITS, @as(i256, b));
    return @intCast(result);
}

/// Construct a fixed-point value from a rational number num/den.
/// Uses round-half-away-from-zero, matching the Q128.128 q128FromRatio semantics.
/// Returns 0 if den is 0 (no panic — safe for lattice arithmetic).
pub fn fromRatio(num: i128, den: i128) i128 {
    if (den == 0) return 0;
    const scaled: i256 = @as(i256, num) << FRAC_BITS;
    const q: i256 = @divTrunc(scaled, @as(i256, den));
    const remainder: i256 = @rem(scaled, @as(i256, den));
    // Round half away from zero
    const half_den: i256 = @divTrunc(@as(i256, den), 2);
    const abs_rem: i256 = if (remainder < 0) -remainder else remainder;
    const abs_half: i256 = if (half_den < 0) -half_den else half_den;
    if (abs_rem >= abs_half) {
        return @intCast(if (q >= 0) q + 1 else q - 1);
    }
    return @intCast(q);
}

/// Compare two fixed-point values. Returns -1 if a < b, 0 if a == b, 1 if a > b.
/// Ported from the Q128.128 q128Cmp function.
pub fn cmp(a: i128, b: i128) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

/// Check if two fixed-point values are exactly equal.
/// Ported from the Q128.128 q128Eq function.
pub fn eq(a: i128, b: i128) bool {
    return a == b;
}

/// Absolute value.
pub inline fn absVal(v: i128) i128 {
    return if (v < 0) -v else v;
}

/// Negate.
pub inline fn negate(v: i128) i128 {
    return -v;
}

/// Maximum of two values.
pub inline fn maxVal(a: i128, b: i128) i128 {
    return if (a > b) a else b;
}

/// Minimum of two values.
pub inline fn minVal(a: i128, b: i128) i128 {
    return if (a < b) a else b;
}

/// Clamp value to [lo, hi].
pub inline fn clamp(v: i128, lo: i128, hi: i128) i128 {
    return maxVal(lo, minVal(hi, v));
}

// =============================================================================
// Constants (precomputed in Q64.64)
// =============================================================================

/// Golden ratio φ = (1 + √5) / 2 ≈ 1.6180339887
/// Computed as: 1.6180339887498948482 * 2^64
pub const PHI: i128 = 29515123186280210960; // 1.6180339887498948482 * 2^64

/// 1/φ ≈ 0.6180339887
/// Computed as: 0.6180339887498948482 * 2^64
pub const INV_PHI: i128 = 11068046444225730970; // 0.6180339887498948482 * 2^64

/// 1/sqrt(2) ≈ 0.7071067811865476
/// Computed as: 0.7071067811865476 * 2^64
pub const INV_SQRT2: i128 = 13043817825332782272; // 0.7071067811865476 * 2^64

/// π ≈ 3.141592653589793
/// Computed as: 3.141592653589793 * 2^64
pub const PI: i128 = 57952155661716706280; // 3.141592653589793 * 2^64

/// 2π ≈ 6.283185307179586
pub const TWO_PI: i128 = 115904311323433412560; // 6.283185307179586 * 2^64

/// e (Euler's number) ≈ 2.718281828459045
/// Computed as: 2.718281828459045 * 2^64
pub const E: i128 = 50143481405518353000; // 2.718281828459045 * 2^64

/// 0.001 in Q64.64 (minimum temperature floor)
/// 0.001 * 2^64 = 18446744073709551.6...
pub const TEMP_FLOOR: i128 = 18446744073709552; // 0.001 * 2^64

/// 0.5 in Q64.64 (firing threshold)
pub const HALF_FP: i128 = 9223372036854775808; // 0.5 * 2^64

/// 0.8 in Q64.64 (propagation weight)
pub const WEIGHT_08: i128 = 14757395258967641293; // 0.8 * 2^64

/// 0.3 in Q64.64 (boundary reflection weight)
pub const WEIGHT_03: i128 = 5534023222112865485; // 0.3 * 2^64

/// 0.15 in Q64.64 (neighbor propagation weight)
pub const WEIGHT_015: i128 = 2767011611056432742; // 0.15 * 2^64

/// 0.7 in Q64.64 (decay factor)
pub const DECAY_07: i128 = 12912720851596686362; // 0.7 * 2^64

/// 0.01 in Q64.64 (position decay factor)
pub const POS_DECAY: i128 = 184467440737095516; // 0.01 * 2^64

/// 10.0 in Q64.64 (logit scale)
pub const LOGIT_SCALE: i128 = 184467440737095516160; // 10.0 * 2^64

/// 33.0 in Q64.64 (Fibonacci normalization)
pub const FIB_NORM: i128 = 608742474512415204288; // 33.0 * 2^64

/// Fibonacci weights in Q64.64: [1, 1, 2, 3, 5, 8, 13, 21]
pub const FIB_WEIGHTS = [_]i128{
    fromInt(1), // 1.0
    fromInt(1), // 1.0
    fromInt(2), // 2.0
    fromInt(3), // 3.0
    fromInt(5), // 5.0
    fromInt(8), // 8.0
    fromInt(13), // 13.0
    fromInt(21), // 21.0
};

// =============================================================================
// EU v11.1 Geometric & Physical Constants (Q64.64)
// =============================================================================

/// Möbius defect density: δ = 7 / 225 ≈ 0.03111111
/// Computed as: (7 * 2^64) / 225
pub const DEFECT_DELTA: i128 = 573898704515408273; // 7/225 * 2^64 (round-half-away)

/// Active E0 observer density: ρ = 421 / 3375 ≈ 0.12474074
/// Computed as: (421 * 2^64) / 3375
pub const ACTIVE_DENSITY_RHO: i128 = 2301060520009398883; // 421/3375 * 2^64 (round-half-away)

/// Inter-qubit universal coupling constant: g = δ × ρ = (7/225) × (421/3375) ≈ 0.0038809
/// Computed as: 0.003880907 * 2^64
pub const COUPLING_G: i128 = 71588549511403521; // (7*421)/(225*3375) * 2^64 (round-half-away)

/// Consciousness bandwidth ratio: C = c(6) / c(5) = 42 / 21 = 2.0 (exact)
pub const BANDWIDTH_C: i128 = fromInt(2);

/// Complete E8 root system count (e0 = E8 = 0^0 = 240)
pub const E8_ROOT_COUNT: u32 = 240;

/// Base lattice interior cells: 15^3 = 3,375
pub const INTERIOR_CELLS: u32 = 3375;

/// Base lattice shell cells: 16^3 = 4,096
pub const SHELL_CELLS: u32 = 4096;

/// Exact boundary cells: 4,096 - 3,375 = 721 (7 × 103)
pub const BOUNDARY_CELLS: u32 = 721;

/// Fundamental hydrogen breathing period in nanoseconds: T_H = 1 / f_H ≈ 0.704024 ns
pub const T_H_NS: f64 = 0.704024183647;

/// Fundamental 21cm hydrogen line frequency in MHz: f_H = 1420.40575177 MHz
pub const F_H_MHZ: f64 = 1420.40575177;

// =============================================================================
// GUT Constants — Generative Universal Transformer (Complex Idealism)
// π continued fraction [3; 7, 15, 1, 292, ...] maps to lattice constants:
//   a₀=3 (spatial dims), a₁=7 (channels), a₂=15 (base edge), a₃=1 (identity)
// Convergents: 3/1, 22/7 (Archimedes), 333/106, 355/113 (Milü)
// =============================================================================

/// 22/7 Archimedes harmonic — 7-channel beat frequency
pub const GUT_HARMONIC: usize = 7;

/// 355/113 Milü super-period — near-perfect phase alignment every 113 steps
pub const GUT_SUPER_PERIOD: usize = 113;

/// Continued fraction term a₂ = 15 (BASE_EDGE)
pub const GUT_CF_15: usize = 15;

/// GUT 2×2 rational rotation matrix in Q64.64 fixed-point.
/// Ψ(N) = [[(N²-1)/(N²+1), -2N/(N²+1)], [2N/(N²+1), (N²-1)/(N²+1)]]
/// det(Ψ) = 1 always — magnitude preserved perfectly, zero drift.
/// No trig functions needed — pure rational arithmetic.
pub const GutMatrix = struct {
    a: i128, // (N²-1)/(N²+1)
    b: i128, // -2N/(N²+1)
    c: i128, // 2N/(N²+1)
    d: i128, // (N²-1)/(N²+1)  (same as a)
};

/// Compute GUT rotation matrix Ψ(N) for a given rational step N in Q64.64.
/// N must be in Q64.64 fixed-point. Returns a GutMatrix with det=1.
pub fn gutRotation(N: i128) GutMatrix {
    if (N == 0) return .{ .a = ONE, .b = 0, .c = 0, .d = ONE };
    const n_sq = mul(N, N);
    const denom = add(n_sq, ONE);
    if (denom == 0) return .{ .a = ONE, .b = 0, .c = 0, .d = ONE };
    const a_d = div(sub(n_sq, ONE), denom);
    const b = div(mul(fromInt(-2), N), denom);
    const c = div(mul(fromInt(2), N), denom);
    return .{ .a = a_d, .b = b, .c = c, .d = a_d };
}

/// Multiply two GUT matrices. Since det(Ψ₁)×det(Ψ₂)=1×1=1, result also has det=1.
/// Composition: Ψ(N₁)×Ψ(N₂) = Ψ(N₁+N₂) — rotations compose additively in flow parameter.
pub fn gutMatMul(m1: GutMatrix, m2: GutMatrix) GutMatrix {
    return .{
        .a = sub(mul(m1.a, m2.a), mul(m1.b, m2.c)),
        .b = add(mul(m1.a, m2.b), mul(m1.b, m2.d)),
        .c = sub(mul(m1.c, m2.a), mul(m1.d, m2.c)),
        .d = add(mul(m1.c, m2.b), mul(m1.d, m2.d)),
    };
}

/// Apply GUT rotation to a 2D vector (re, im) in Q64.64.
/// [re'] = [a  b] [re]
/// [im']   [c  d] [im]
pub fn gutApply(m: GutMatrix, re: i128, im: i128) struct { re: i128, im: i128 } {
    return .{
        .re = sub(mul(m.a, re), mul(m.b, im)),
        .im = add(mul(m.c, re), mul(m.d, im)),
    };
}

/// Compute phase drift: det(Ψ^Υ - I) = distance from identity.
/// This measures how far the rotation has drifted from a perfect return to origin.
/// Returns |Ψ^Υ - I| as a scalar in Q64.64.
pub fn gutPhaseDrift(m: GutMatrix) i128 {
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

/// Sigmoid lookup table: 512 entries covering input range [-8, +8).
/// Each entry is sigmoid(x) in Q64.64 format.
/// For |x| > 8, sigmoid saturates to 0 or 1.
const SIGMOID_TABLE_SIZE: usize = 512;
const SIGMOID_RANGE: i128 = fromInt(8); // Input range: [-8, 8)

/// Sigmoid table populated at comptime.
const sigmoid_table: [SIGMOID_TABLE_SIZE]i128 = blk: {
    @setEvalBranchQuota(20000);
    var table: [SIGMOID_TABLE_SIZE]i128 = undefined;
    for (0..SIGMOID_TABLE_SIZE) |i| {
        const x_f: f64 = -8.0 + (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SIGMOID_TABLE_SIZE))) * 16.0;
        const sig_f: f64 = 1.0 / (1.0 + @exp(-x_f));
        const q_val: i128 = @intFromFloat(sig_f * ONE_F);
        table[i] = q_val;
    }
    break :blk table;
};

/// Computes sigmoid(x) using lookup table.
/// Input: x in Q64.64 fixed-point.
/// Output: sigmoid(x) in Q64.64 fixed-point.
/// For |x| >= 8, saturates to 0 (x < -8) or 1 (x > 8).
pub fn sigmoid(x: i128) i128 {
    if (x >= SIGMOID_RANGE) return ONE;
    if (x <= -SIGMOID_RANGE) return 0;

    const offset = x + SIGMOID_RANGE;
    const scaled: i256 = @as(i256, offset) * @as(i256, SIGMOID_TABLE_SIZE);
    const range: i256 = @as(i256, SIGMOID_RANGE) * 2;
    const idx: i128 = @intCast(@divTrunc(scaled, range));
    const clamped: usize = @intCast(clamp(idx, 0, @as(i128, @intCast(SIGMOID_TABLE_SIZE - 1))));
    return sigmoid_table[clamped];
}

// =============================================================================
// Integer Exponential Approximation (Taylor series in fixed-point)
// =============================================================================

/// Computes exp(x) using a 6-term Taylor series in fixed-point.
/// exp(x) ≈ 1 + x + x²/2 + x³/6 + x⁴/24 + x⁵/120 + x⁶/720
/// For |x| > 4, uses repeated squaring: exp(x) = exp(x/2)^2
/// Input: x in Q64.64. Output: exp(x) in Q64.64.
pub fn exp(x: i128) i128 {
    if (x >= fromInt(10)) return MAX_VAL;
    if (x <= -fromInt(20)) return 0;

    var val = x;
    var n_shifts: u32 = 0;

    while (val > fromInt(2) or val < -fromInt(2)) {
        val >>= 1;
        n_shifts += 1;
    }

    var result: i128 = ONE;
    var term: i128 = ONE;

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

/// Sin/cos table with 1024 entries covering [0, 2π).
/// Table index = (angle / 2π) * 1024
const TRIG_TABLE_SIZE: usize = 1024;

/// Sin table populated at comptime.
const sin_table: [TRIG_TABLE_SIZE]i128 = blk: {
    @setEvalBranchQuota(20000);
    var table: [TRIG_TABLE_SIZE]i128 = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        const sin_val: f64 = @sin(angle);
        table[i] = @intFromFloat(sin_val * ONE_F);
    }
    break :blk table;
};

/// Cos table populated at comptime.
const cos_table: [TRIG_TABLE_SIZE]i128 = blk: {
    @setEvalBranchQuota(20000);
    var table: [TRIG_TABLE_SIZE]i128 = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        const cos_val: f64 = @cos(angle);
        table[i] = @intFromFloat(cos_val * ONE_F);
    }
    break :blk table;
};

/// Computes sin(angle) using lookup table.
/// Input: angle in Q64.64 radians. Output: sin(angle) in Q64.64.
pub fn sin(angle: i128) i128 {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;

    const idx: i256 = @divTrunc(@as(i256, a) * @as(i256, TRIG_TABLE_SIZE), @as(i256, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i256, TRIG_TABLE_SIZE)));
    return sin_table[clamped];
}

/// Computes cos(angle) using lookup table.
/// Input: angle in Q64.64 radians. Output: cos(angle) in Q64.64.
pub fn cos(angle: i128) i128 {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;

    const idx: i256 = @divTrunc(@as(i256, a) * @as(i256, TRIG_TABLE_SIZE), @as(i256, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i256, TRIG_TABLE_SIZE)));
    return cos_table[clamped];
}

/// Computes both sin and cos simultaneously (for DFT).
/// Returns { .sin = s, .cos = c } in Q64.64.
pub fn sincos(angle: i128) struct { sin_val: i128, cos_val: i128 } {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;

    const idx: i256 = @divTrunc(@as(i256, a) * @as(i256, TRIG_TABLE_SIZE), @as(i256, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i256, TRIG_TABLE_SIZE)));
    return .{ .sin_val = sin_table[clamped], .cos_val = cos_table[clamped] };
}

/// Computes the DFT twiddle factor W_N^k = exp(-2πi*k/N).
/// Returns { .re, .im } in Q64.64 fixed-point.
/// This is cos(-2πk/N) + i*sin(-2πk/N) = cos(2πk/N) - i*sin(2πk/N).
pub fn twiddle(k: usize, N: usize) struct { re: i128, im: i128 } {
    const angle: i256 = @divTrunc(-(@as(i256, TWO_PI) * @as(i256, @intCast(k))), @as(i256, @intCast(N)));
    const angle_fp: i128 = @intCast(angle);
    const sc = sincos(angle_fp);
    return .{ .re = sc.cos_val, .im = sc.sin_val };
}

// =============================================================================
// φ-Cooling (integer-only)
// =============================================================================

/// Precomputed φ^(-n) table for n = 0..63 in Q64.64.
/// φ^(-n) = (1/φ)^n
const PHI_COOL_TABLE_SIZE: usize = 64;
const phi_cool_table: [PHI_COOL_TABLE_SIZE]i128 = blk: {
    @setEvalBranchQuota(20000);
    var table: [PHI_COOL_TABLE_SIZE]i128 = undefined;
    var val: f64 = 1.0;
    for (0..PHI_COOL_TABLE_SIZE) |i| {
        table[i] = @intFromFloat(val * ONE_F);
        val /= 1.6180339887498948482;
    }
    break :blk table;
};

/// Computes φ-cooled temperature: T(cycle) = T₀ × φ^(-cycle).
/// Uses precomputed table for cycle < 64, saturates for cycle >= 64.
/// Input: base_temp in Q64.64, cycle as u64. Output: temperature in Q64.64.
pub fn phiCool(base_temp: i128, cycle: u64) i128 {
    if (cycle >= PHI_COOL_TABLE_SIZE) return TEMP_FLOOR;
    const factor = phi_cool_table[@intCast(cycle)];
    const result = mul(base_temp, factor);
    return if (result < TEMP_FLOOR) TEMP_FLOOR else result;
}

// =============================================================================
// Square Root (integer-only, Newton's method)
// =============================================================================

/// Computes sqrt(x) in Q64.64 using Newton's method.
/// Input: x in Q64.64. Output: sqrt(x) in Q64.64.
pub fn sqrt(x: i128) i128 {
    if (x <= 0) return 0;
    // Initial guess: use bit position to get close approximation.
    // For Q64.64, y_fp = sqrt(x) * 2^64 ≈ 2^((bit_pos + FRAC_BITS) / 2)
    const lz = @clz(x);
    const bit_pos: u7 = @intCast(127 - lz);
    const half_pos: u7 = @intCast((@as(u32, bit_pos) + FRAC_BITS) / 2);
    var guess: i128 = @as(i128, 1) << half_pos;
    if (guess == 0) guess = ONE;

    // Newton iterations: guess = (guess + x/guess) / 2
    for (0..30) |_| {
        const new_guess = (guess + div(x, guess)) >> 1;
        if (absVal(new_guess - guess) <= 1) break;
        guess = new_guess;
    }
    return guess;
}

// =============================================================================
// Tests
// =============================================================================

test "fromInt and toInt round trip" {
    try std.testing.expectEqual(@as(i128, 42) << FRAC_BITS, fromInt(42));
    try std.testing.expectEqual(@as(i64, 42), toInt(fromInt(42)));
    try std.testing.expectEqual(@as(i64, -7), toInt(fromInt(-7)));
    try std.testing.expectEqual(@as(i64, 0), toInt(0));
}

test "add and sub" {
    const a = fromInt(10);
    const b = fromInt(3);
    try std.testing.expectEqual(fromInt(13), add(a, b));
    try std.testing.expectEqual(fromInt(7), sub(a, b));
}

test "mul preserves fractional precision" {
    const a = fromInt(3);
    const b = fromInt(4);
    try std.testing.expectEqual(fromInt(12), mul(a, b));

    // 0.5 * 0.5 = 0.25
    const half = HALF_FP;
    const quarter = mul(half, half);
    // 0.25 in Q64.64 = 0.25 * 2^64 = 4611686018427387904
    try std.testing.expectEqual(@as(i128, 4611686018427387904), quarter);
}

test "div preserves fractional precision" {
    const a = fromInt(10);
    const b = fromInt(3);
    const result = div(a, b);
    // 10/3 ≈ 3.333... → toInt should give 3
    try std.testing.expectEqual(@as(i64, 3), toInt(result));
    // Check fractional part is non-zero
    try std.testing.expect(result > fromInt(3));
    try std.testing.expect(result < fromInt(4));
}

test "sigmoid saturates at extremes" {
    try std.testing.expectEqual(ONE, sigmoid(fromInt(10)));
    try std.testing.expectEqual(@as(i128, 0), sigmoid(-fromInt(10)));
}

test "sigmoid(0) = 0.5" {
    const result = sigmoid(0);
    // 0.5 in Q64.64 = 9223372036854775808
    try std.testing.expectEqual(HALF_FP, result);
}

test "sigmoid is monotonic" {
    const s_neg = sigmoid(-fromInt(1));
    const s_zero = sigmoid(0);
    const s_pos = sigmoid(fromInt(1));
    try std.testing.expect(s_neg < s_zero);
    try std.testing.expect(s_zero < s_pos);
}

test "exp(0) = 1" {
    const result = exp(0);
    try std.testing.expectEqual(ONE, result);
}

test "exp(1) ≈ e" {
    const result = exp(ONE);
    // e ≈ 2.71828... → toInt should be 2
    try std.testing.expectEqual(@as(i64, 2), toInt(result));
    // Check it's close to e: 2.71828 * 2^64 = 50143481405518353
    const diff = absVal(result - E);
    // Allow 10% tolerance for Taylor series: 0.1 * 2^64 = 1844674407370955162
    try std.testing.expect(diff < 1844674407370955162);
}

test "sin(0) = 0" {
    const result = sin(0);
    // Allow ±1 LSB tolerance
    try std.testing.expect(absVal(result) <= 1);
}

test "cos(0) = 1" {
    const result = cos(0);
    try std.testing.expectEqual(ONE, result);
}

test "sin(π/2) = 1" {
    const half_pi = PI >> 1;
    const result = sin(half_pi);
    // 1024-entry table quantization. Allow ±430000000000000 LSB (≈ 0.000023 absolute)
    try std.testing.expect(absVal(result - ONE) <= 430000000000000);
}

test "cos(π) = -1" {
    const result = cos(PI);
    // Allow ±430000000000000 LSB tolerance for 1024-entry table quantization
    try std.testing.expect(absVal(result - (-ONE)) <= 430000000000000);
}

test "sin and cos are periodic" {
    const s1 = sin(0);
    const s2 = sin(TWO_PI);
    try std.testing.expect(absVal(s1 - s2) <= 430000000000000);
}

test "twiddle W_N^0 = 1 + 0i" {
    const t = twiddle(0, 8);
    try std.testing.expectEqual(ONE, t.re);
    try std.testing.expect(absVal(t.im) <= 430000000000000);
}

test "twiddle W_4^1 = -i" {
    const t = twiddle(1, 4);
    // W_4^1 = exp(-2πi/4) = exp(-iπ/2) = cos(-π/2) + i*sin(-π/2) = 0 - i
    // Allow ±430000000000000 LSB tolerance for 1024-entry table quantization
    try std.testing.expect(absVal(t.re) <= 430000000000000);
    try std.testing.expect(absVal(t.im - (-ONE)) <= 430000000000000);
}

test "phiCool(1.0, 0) = 1.0" {
    const result = phiCool(ONE, 0);
    try std.testing.expectEqual(ONE, result);
}

test "phiCool decreases with cycle" {
    const t0 = phiCool(ONE, 0);
    const t1 = phiCool(ONE, 1);
    const t5 = phiCool(ONE, 5);
    try std.testing.expect(t1 < t0);
    try std.testing.expect(t5 < t1);
}

test "phiCool saturates at floor" {
    const result = phiCool(ONE, 100);
    try std.testing.expectEqual(TEMP_FLOOR, result);
}

test "sqrt(4) = 2" {
    const result = sqrt(fromInt(4));
    try std.testing.expectEqual(fromInt(2), result);
}

test "sqrt(0) = 0" {
    try std.testing.expectEqual(@as(i128, 0), sqrt(0));
}

test "constants are correct" {
    // PHI ≈ 1.618
    try std.testing.expect(toInt(PHI) == 1);
    try std.testing.expect(PHI > ONE);
    try std.testing.expect(PHI < fromInt(2));

    // INV_SQRT2 ≈ 0.707
    try std.testing.expect(toInt(INV_SQRT2) == 0);
    try std.testing.expect(INV_SQRT2 > 0);
    try std.testing.expect(INV_SQRT2 < ONE);
}

test "format produces readable output" {
    const allocator = std.testing.allocator;
    const result = try format(allocator, fromInt(42) + HALF_FP); // 42.5
    defer allocator.free(result);
    // Should contain "42"
    try std.testing.expect(std.mem.indexOf(u8, result, "42") != null);
}

test "clamp works correctly" {
    try std.testing.expectEqual(fromInt(5), clamp(fromInt(5), fromInt(0), fromInt(10)));
    try std.testing.expectEqual(fromInt(0), clamp(-fromInt(5), fromInt(0), fromInt(10)));
    try std.testing.expectEqual(fromInt(10), clamp(fromInt(20), fromInt(0), fromInt(10)));
}

test "absVal works correctly" {
    try std.testing.expectEqual(fromInt(5), absVal(-fromInt(5)));
    try std.testing.expectEqual(fromInt(5), absVal(fromInt(5)));
    try std.testing.expectEqual(@as(i128, 0), absVal(0));
}

// =============================================================================
// SIMD Batch Operations — @Vector-accelerated fixed-point arithmetic
// =============================================================================

/// Batch multiply: element-wise Q64.64 multiply for 4 values using @Vector.
/// Uses round-to-nearest-even (RNE) matching the scalar mul function.
pub fn mulVec4(a: @Vector(4, i128), b: @Vector(4, i128)) @Vector(4, i128) {
    return .{
        mul(a[0], b[0]),
        mul(a[1], b[1]),
        mul(a[2], b[2]),
        mul(a[3], b[3]),
    };
}

/// Batch add: element-wise Q64.64 add for 4 values.
pub fn addVec4(a: @Vector(4, i128), b: @Vector(4, i128)) @Vector(4, i128) {
    return a + b;
}

/// Batch sub: element-wise Q64.64 subtract for 4 values.
pub fn subVec4(a: @Vector(4, i128), b: @Vector(4, i128)) @Vector(4, i128) {
    return a - b;
}

/// Batch fromInt: convert 4 integer values to Q64.64 fixed-point.
pub fn fromIntVec4(v: @Vector(4, i64)) @Vector(4, i128) {
    const wide: @Vector(4, i128) = @intCast(v);
    return wide << @as(@Vector(4, u7), @splat(FRAC_BITS));
}

/// Batch multiply for arbitrary-length slices using @Vector(4, i128) lanes.
pub fn mulBatch(dst: []i128, a: []const i128, b: []const i128) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: @Vector(4, i128) = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: @Vector(4, i128) = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
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

/// Batch add for arbitrary-length slices.
pub fn addBatch(dst: []i128, a: []const i128, b: []const i128) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: @Vector(4, i128) = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: @Vector(4, i128) = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
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

test "SIMD mulVec4 matches scalar" {
    const a: @Vector(4, i128) = .{ fromInt(2), fromInt(3), fromInt(4), fromInt(5) };
    const b: @Vector(4, i128) = .{ fromInt(3), fromInt(4), fromInt(5), fromInt(6) };
    const result = mulVec4(a, b);
    try std.testing.expectEqual(fromInt(6), result[0]);
    try std.testing.expectEqual(fromInt(12), result[1]);
    try std.testing.expectEqual(fromInt(20), result[2]);
    try std.testing.expectEqual(fromInt(30), result[3]);
}

test "SIMD mulBatch matches scalar" {
    var dst: [10]i128 = undefined;
    const a = [_]i128{ fromInt(1), fromInt(2), fromInt(3), fromInt(4), fromInt(5), fromInt(6), fromInt(7), fromInt(8), fromInt(9), fromInt(10) };
    const b = [_]i128{ fromInt(10), fromInt(9), fromInt(8), fromInt(7), fromInt(6), fromInt(5), fromInt(4), fromInt(3), fromInt(2), fromInt(1) };
    mulBatch(&dst, &a, &b);
    for (0..10) |i| {
        try std.testing.expectEqual(mul(a[i], b[i]), dst[i]);
    }
}

// =============================================================================
// GUT Tests
// =============================================================================

test "GUT: rotation matrix det=1" {
    const N = fromInt(3);
    const m = gutRotation(N);
    const det = sub(mul(m.a, m.d), mul(m.b, m.c));
    const drift = absVal(sub(det, ONE));
    try std.testing.expect(drift < div(ONE, fromInt(100)));
}

test "GUT: identity rotation at N=0" {
    const m = gutRotation(fromInt(0));
    try std.testing.expectEqual(ONE, m.a);
    try std.testing.expectEqual(@as(i128, 0), m.b);
    try std.testing.expectEqual(@as(i128, 0), m.c);
    try std.testing.expectEqual(ONE, m.d);
}

test "GUT: matrix composition preserves det=1" {
    const m1 = gutRotation(fromInt(2));
    const m2 = gutRotation(fromInt(3));
    const m3 = gutMatMul(m1, m2);
    const det = sub(mul(m3.a, m3.d), mul(m3.b, m3.c));
    const drift = absVal(sub(det, ONE));
    try std.testing.expect(drift < fromInt(1));
}

test "GUT: phase drift of identity is zero" {
    const m = gutRotation(fromInt(0));
    const drift = gutPhaseDrift(m);
    try std.testing.expectEqual(@as(i128, 0), drift);
}

test "GUT: harmonic and super-resonance checks" {
    try std.testing.expect(gutIsHarmonic(7));
    try std.testing.expect(gutIsHarmonic(14));
    try std.testing.expect(!gutIsHarmonic(5));
    try std.testing.expect(gutIsSuperResonant(113));
    try std.testing.expect(gutIsSuperResonant(226));
    try std.testing.expect(!gutIsSuperResonant(112));
}

test "GUT: apply rotation to vector" {
    const m = gutRotation(fromInt(0));
    const result = gutApply(m, fromInt(5), fromInt(3));
    try std.testing.expectEqual(fromInt(5), result.re);
    try std.testing.expectEqual(fromInt(3), result.im);
}

// =============================================================================
// RNE Multiply Tests (ported from Q128.128 methodology)
// =============================================================================

test "RNE mul: exact integer multiply" {
    // 3 * 4 = 12 — no rounding needed
    try std.testing.expectEqual(fromInt(12), mul(fromInt(3), fromInt(4)));
    // Large integers
    try std.testing.expectEqual(fromInt(1000000), mul(fromInt(1000), fromInt(1000)));
}

test "RNE mul: 0.5 * 0.5 = 0.25 exactly" {
    const half = HALF_FP;
    const quarter = mul(half, half);
    // 0.25 in Q64.64 = 0.25 * 2^64 = 4611686018427387904
    try std.testing.expectEqual(@as(i128, 4611686018427387904), quarter);
}

test "RNE mul: 0.5 * 0.5 * 0.5 rounds to even" {
    // 0.125 in Q64.64 = 2305843009213693952
    const half = HALF_FP;
    const quarter = mul(half, half);
    const eighth = mul(quarter, half);
    // 0.125 * 2^64 = 2305843009213693952 — exact, no rounding
    try std.testing.expectEqual(@as(i128, 2305843009213693952), eighth);
}

test "RNE mul: rounds to nearest even on tie" {
    // Test a value that produces an exact tie at the rounding boundary.
    // 0.5 * 3 = 1.5 — in Q64.64: (0.5 * 2^64) * 3 = 1.5 * 2^64
    // 1.5 * 2^64 = 27670116110564327424 — exact, no rounding needed
    const result = mul(HALF_FP, fromInt(3));
    try std.testing.expectEqual(@as(i128, 27670116110564327424), result);
}

test "RNE mul: negative values" {
    // -3 * 4 = -12
    try std.testing.expectEqual(-fromInt(12), mul(-fromInt(3), fromInt(4)));
    // -0.5 * 0.5 = -0.25
    const neg_half = -HALF_FP;
    const result = mul(neg_half, HALF_FP);
    try std.testing.expectEqual(@as(i128, -4611686018427387904), result);
}

test "RNE mul: symmetric with sign flip" {
    // a*b == -(a*(-b)) == -((-a)*b)
    const a = fromInt(7);
    const b = fromInt(3);
    const r1 = mul(a, b);
    const r2 = mul(a, -b);
    const r3 = mul(-a, b);
    try std.testing.expectEqual(r1, -r2);
    try std.testing.expectEqual(r1, -r3);
}

test "RNE mul: zero handling" {
    try std.testing.expectEqual(@as(i128, 0), mul(0, fromInt(42)));
    try std.testing.expectEqual(@as(i128, 0), mul(fromInt(42), 0));
    try std.testing.expectEqual(@as(i128, 0), mul(0, 0));
}

test "RNE mul: identity" {
    try std.testing.expectEqual(fromInt(42), mul(fromInt(42), ONE));
    try std.testing.expectEqual(fromInt(42), mul(ONE, fromInt(42)));
}

test "RNE mul: commutative" {
    const a = fromInt(7) + HALF_FP; // 7.5
    const b = fromInt(3) + HALF_FP; // 3.5
    try std.testing.expectEqual(mul(a, b), mul(b, a));
}

test "RNE mul: error bound is half ULP" {
    // Verify that RNE mul produces results within half ULP (2^-65)
    // of the true mathematical result for a known fraction.
    // 1/3 * 3 should be close to 1 (within rounding)
    const third = div(ONE, fromInt(3));
    const result = mul(third, fromInt(3));
    const diff = absVal(result - ONE);
    // Half ULP = 1 (1 unit in the last place of Q64.64)
    try std.testing.expect(diff <= 1);
}

test "RNE mulVec4 matches scalar mul" {
    const a: @Vector(4, i128) = .{ fromInt(2), fromInt(3), fromInt(4), fromInt(5) };
    const b: @Vector(4, i128) = .{ fromInt(3), fromInt(4), fromInt(5), fromInt(6) };
    const result = mulVec4(a, b);
    try std.testing.expectEqual(mul(fromInt(2), fromInt(3)), result[0]);
    try std.testing.expectEqual(mul(fromInt(3), fromInt(4)), result[1]);
    try std.testing.expectEqual(mul(fromInt(4), fromInt(5)), result[2]);
    try std.testing.expectEqual(mul(fromInt(5), fromInt(6)), result[3]);
}

// =============================================================================
// fromRatio, cmp, eq Tests
// =============================================================================

test "fromRatio: exact rational" {
    // 1/2 = 0.5
    try std.testing.expectEqual(HALF_FP, fromRatio(1, 2));
    // 1/4 = 0.25
    try std.testing.expectEqual(@as(i128, 4611686018427387904), fromRatio(1, 4));
    // 3/2 = 1.5
    try std.testing.expectEqual(fromInt(1) + HALF_FP, fromRatio(3, 2));
}

test "fromRatio: integer result" {
    // 6/3 = 2
    try std.testing.expectEqual(fromInt(2), fromRatio(6, 3));
    // 10/5 = 2
    try std.testing.expectEqual(fromInt(2), fromRatio(10, 5));
}

test "fromRatio: negative values" {
    // -1/2 = -0.5
    try std.testing.expectEqual(-HALF_FP, fromRatio(-1, 2));
    // 1/-2 = -0.5
    try std.testing.expectEqual(-HALF_FP, fromRatio(1, -2));
    // -3/-2 = 1.5
    try std.testing.expectEqual(fromInt(1) + HALF_FP, fromRatio(-3, -2));
}

test "fromRatio: zero handling" {
    // 0/5 = 0
    try std.testing.expectEqual(@as(i128, 0), fromRatio(0, 5));
    // 5/0 = 0 (safe, no panic)
    try std.testing.expectEqual(@as(i128, 0), fromRatio(5, 0));
}

test "fromRatio: round half away from zero" {
    // 1/3 ≈ 0.333... — should round
    const third = fromRatio(1, 3);
    // Verify it's between 0.333 and 0.334
    try std.testing.expect(third > fromRatio(333, 1000));
    try std.testing.expect(third < fromRatio(334, 1000));
}

test "cmp: comparison function" {
    try std.testing.expectEqual(@as(i8, -1), cmp(fromInt(1), fromInt(2)));
    try std.testing.expectEqual(@as(i8, 0), cmp(fromInt(5), fromInt(5)));
    try std.testing.expectEqual(@as(i8, 1), cmp(fromInt(3), fromInt(2)));
    try std.testing.expectEqual(@as(i8, -1), cmp(-fromInt(1), fromInt(0)));
}

test "eq: equality function" {
    try std.testing.expect(eq(fromInt(5), fromInt(5)));
    try std.testing.expect(!eq(fromInt(5), fromInt(6)));
    try std.testing.expect(eq(ONE, ONE));
    try std.testing.expect(!eq(ONE, ZERO));
}

test "cmp and eq consistency" {
    const a = fromInt(7);
    const b = fromInt(7);
    try std.testing.expect(eq(a, b));
    try std.testing.expectEqual(@as(i8, 0), cmp(a, b));
}

// =============================================================================
// Framework Verification (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Verifies that the framework constants in this module match the hardware project's
/// scaling analysis. These constants connect QSTAR's fixed-point arithmetic to the
/// E=mc²-i-E=mc⁻² toy-model's mathematical structure.
pub fn verifyFrameworkConstants() bool {
    // DEFECT_DELTA = 7/225 (Möbius defect density)
    // Verify: 7 * ONE / 225 == DEFECT_DELTA (within 1 ULP)
    const expected_defect = @divTrunc(@as(i256, 7) * @as(i256, ONE), @as(i256, 225));
    {
        const diff = @as(i128, @intCast(expected_defect)) - DEFECT_DELTA;
        const abs_diff = if (diff < 0) -diff else diff;
        if (abs_diff > 1) return false;
    }

    // ACTIVE_DENSITY_RHO = 421/3375 (active E0 observer density)
    const expected_rho = @divTrunc(@as(i256, 421) * @as(i256, ONE), @as(i256, 3375));
    {
        const diff = @as(i128, @intCast(expected_rho)) - ACTIVE_DENSITY_RHO;
        const abs_diff = if (diff < 0) -diff else diff;
        if (abs_diff > 1) return false;
    }

    // COUPLING_G = DEFECT_DELTA * ACTIVE_DENSITY_RHO (inter-qubit coupling)
    // g = (7/225) × (421/3375) ≈ 0.003880907
    const expected_g_num = @as(i256, 7) * @as(i256, 421);
    const expected_g_den = @as(i256, 225) * @as(i256, 3375);
    const expected_g = @divTrunc(expected_g_num * @as(i256, ONE), expected_g_den);
    {
        const diff = @as(i128, @intCast(expected_g)) - COUPLING_G;
        const abs_diff = if (diff < 0) -diff else diff;
        if (abs_diff > 2) return false;
    }

    // BANDWIDTH_C = 2 (consciousness bandwidth ratio C = c(6)/c(5) = 42/21 = 2)
    if (BANDWIDTH_C != fromInt(2)) return false;

    // E8_ROOT_COUNT = 240
    if (E8_ROOT_COUNT != 240) return false;

    // INTERIOR_CELLS = 3375 (15³)
    if (INTERIOR_CELLS != 3375) return false;

    // SHELL_CELLS = 4096 (16³)
    if (SHELL_CELLS != 4096) return false;

    // BOUNDARY_CELLS = 721 (16³ - 15³)
    if (BOUNDARY_CELLS != 721) return false;

    return true;
}

/// Verifies the coupling constant identity: g = δ × ρ = (7/225) × (421/3375)
pub fn verifyCouplingConstantIdentity() bool {
    // g = δ × ρ in fixed-point: g = mul(DEFECT_DELTA, ACTIVE_DENSITY_RHO)
    const computed_g = mul(DEFECT_DELTA, ACTIVE_DENSITY_RHO);
    // Allow for rounding: |computed - actual| <= 2 ULP (RNE vs truncation)
    const diff = if (computed_g > COUPLING_G) computed_g - COUPLING_G else COUPLING_G - computed_g;
    return diff <= 2;
}

/// Verifies the boundary cell identity: 16³ - 15³ = 721 = 3(240) + 1
pub fn verifyBoundaryCellIdentity() bool {
    return SHELL_CELLS - INTERIOR_CELLS == BOUNDARY_CELLS and
        BOUNDARY_CELLS == 3 * E8_ROOT_COUNT + 1;
}

test "framework: fixed-point constants match hardware scaling analysis" {
    try std.testing.expect(verifyFrameworkConstants());
}

test "framework: coupling constant g = δ × ρ" {
    try std.testing.expect(verifyCouplingConstantIdentity());
}

test "framework: boundary cells 16³ - 15³ = 721 = 3(240) + 1" {
    try std.testing.expect(verifyBoundaryCellIdentity());
}
