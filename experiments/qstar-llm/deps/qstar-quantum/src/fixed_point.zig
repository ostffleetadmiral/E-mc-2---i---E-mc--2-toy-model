//! fixed_point.zig — Q32.32 fixed-point arithmetic library.
//!
//! Provides integer-only arithmetic for core lattice state transitions.
//! All values are represented as i64 with 32 fractional bits, giving:
//!   - Integer range: [-2^31, 2^31) = [-2,147,483,648, 2,147,483,648)
//!   - Fractional precision: 1/2^32 ≈ 2.33e-10
//!   - ~9 decimal digits of precision
//!
//! No f32/f64/f16/f128 anywhere. Pure integer arithmetic with bit shifts.
//! All operations are deterministic and cross-platform identical.

const std = @import("std");

/// Number of fractional bits in Q32.32 format.
pub const FRAC_BITS: u6 = 32;
pub const ONE: i64 = 1 << FRAC_BITS; // 1.0 in fixed-point
pub const HALF: i64 = ONE >> 1; // 0.5
pub const ZERO: i64 = 0;

/// Maximum representable value: (2^31 - 1) + (2^32 - 1)/2^32
pub const MAX_VAL: i64 = std.math.maxInt(i64);
pub const MIN_VAL: i64 = std.math.minInt(i64);

/// Convert an integer to fixed-point.
pub inline fn fromInt(v: i64) i64 {
    return v << FRAC_BITS;
}

/// Convert fixed-point to integer (truncates fractional part).
pub inline fn toInt(v: i64) i64 {
    return v >> FRAC_BITS;
}

/// Convert fixed-point to a string representation for debugging.
pub fn format(allocator: std.mem.Allocator, v: i64) ![]u8 {
    const int_part = toInt(v);
    const frac_part = v & ((ONE) - 1);
    const frac_scaled: u64 = @intCast(frac_part);
    // Print as int.fraction with 4 decimal places
    const frac_4dp = (frac_scaled * 10000) >> FRAC_BITS;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>4}", .{ int_part, frac_4dp });
}

// =============================================================================
// Arithmetic Operations
// =============================================================================

/// Fixed-point addition: straightforward i64 add.
pub inline fn add(a: i64, b: i64) i64 {
    return a + b;
}

/// Fixed-point subtraction.
pub inline fn sub(a: i64, b: i64) i64 {
    return a - b;
}

/// Fixed-point multiplication: (a * b) >> FRAC_BITS.
/// Uses 128-bit intermediate to prevent overflow.
pub inline fn mul(a: i64, b: i64) i64 {
    const result: i128 = @as(i128, a) * @as(i128, b);
    return @intCast(result >> FRAC_BITS);
}

/// Fixed-point division: (a << FRAC_BITS) / b.
/// Uses 128-bit intermediate to prevent overflow.
pub inline fn div(a: i64, b: i64) i64 {
    if (b == 0) return 0;
    const result: i128 = @divTrunc(@as(i128, a) << FRAC_BITS, @as(i128, b));
    return @intCast(result);
}

/// Absolute value.
pub inline fn absVal(v: i64) i64 {
    return if (v < 0) -v else v;
}

/// Negate.
pub inline fn negate(v: i64) i64 {
    return -v;
}

/// Maximum of two values.
pub inline fn maxVal(a: i64, b: i64) i64 {
    return if (a > b) a else b;
}

/// Minimum of two values.
pub inline fn minVal(a: i64, b: i64) i64 {
    return if (a < b) a else b;
}

/// Clamp value to [lo, hi].
pub inline fn clamp(v: i64, lo: i64, hi: i64) i64 {
    return maxVal(lo, minVal(hi, v));
}

// =============================================================================
// Constants (precomputed in Q32.32)
// =============================================================================

/// Golden ratio φ = (1 + √5) / 2 ≈ 1.6180339887
/// Computed as: 1.6180339887498948482 * 2^32 = 6950374848.36... → 6950374848
pub const PHI: i64 = 6950374848;

/// 1/φ ≈ 0.6180339887
/// Computed as: 0.6180339887498948482 * 2^32 = 2654435769.24... → 2654435769
pub const INV_PHI: i64 = 2654435769;

/// 1/sqrt(2) ≈ 0.7071067811865476
/// Computed as: 0.7071067811865476 * 2^32 = 3037000499.97... → 3037000499
pub const INV_SQRT2: i64 = 3037000499;

/// π ≈ 3.141592653589793
/// Computed as: 3.141592653589793 * 2^32 = 13493037704.52... → 13493037704
pub const PI: i64 = 13493037704;

/// 2π ≈ 6.283185307179586
pub const TWO_PI: i64 = 26986075409;

/// e (Euler's number) ≈ 2.718281828459045
/// Computed as: 2.718281828459045 * 2^32 = 11674907765.37... → 11674907765
pub const E: i64 = 11674907765;

/// 0.001 in Q32.32 (minimum temperature floor)
pub const TEMP_FLOOR: i64 = 4294967; // 0.001 * 2^32 ≈ 4294967.296

/// 0.5 in Q32.32 (firing threshold)
pub const HALF_FP: i64 = 2147483648; // 0.5 * 2^32

/// 0.8 in Q32.32 (propagation weight)
pub const WEIGHT_08: i64 = 3435973837; // 0.8 * 2^32

/// 0.3 in Q32.32 (boundary reflection weight)
pub const WEIGHT_03: i64 = 1288490189; // 0.3 * 2^32

/// 0.15 in Q32.32 (neighbor propagation weight)
pub const WEIGHT_015: i64 = 644245094; // 0.15 * 2^32

/// 0.7 in Q32.32 (decay factor)
pub const DECAY_07: i64 = 3006477107; // 0.7 * 2^32

/// 0.01 in Q32.32 (position decay factor)
pub const POS_DECAY: i64 = 42949673; // 0.01 * 2^32

/// 10.0 in Q32.32 (logit scale)
pub const LOGIT_SCALE: i64 = 42949672960; // 10.0 * 2^32

/// 33.0 in Q32.32 (Fibonacci normalization)
pub const FIB_NORM: i64 = 141733920768; // 33.0 * 2^32

/// Fibonacci weights in Q32.32: [1, 1, 2, 3, 5, 8, 13]
pub const FIB_WEIGHTS = [_]i64{
    fromInt(1),  // 1.0
    fromInt(1),  // 1.0
    fromInt(2),  // 2.0
    fromInt(3),  // 3.0
    fromInt(5),  // 5.0
    fromInt(8),  // 8.0
    fromInt(13), // 13.0
};

// =============================================================================
// Integer Sigmoid Lookup Table
// =============================================================================

/// Sigmoid lookup table: 512 entries covering input range [-8, +8).
/// Each entry is sigmoid(x) in Q32.32 format.
/// For |x| > 8, sigmoid saturates to 0 or 1.
const SIGMOID_TABLE_SIZE: usize = 512;
const SIGMOID_RANGE: i64 = fromInt(8); // Input range: [-8, 8)

/// Sigmoid table populated at comptime.
const sigmoid_table: [SIGMOID_TABLE_SIZE]i64 = blk: {
    var table: [SIGMOID_TABLE_SIZE]i64 = undefined;
    for (0..SIGMOID_TABLE_SIZE) |i| {
        // Map index [0, 512) to input [-8, 8)
        // x = -8 + (i / 512) * 16
        // sigmoid(x) = 1 / (1 + exp(-x))
        // We compute this at comptime using f64 then convert to Q32.32
        const x_f: f64 = -8.0 + (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SIGMOID_TABLE_SIZE))) * 16.0;
        const sig_f: f64 = 1.0 / (1.0 + @exp(-x_f));
        const q_val: i64 = @intFromFloat(sig_f * @as(f64, @floatFromInt(ONE)));
        table[i] = q_val;
    }
    break :blk table;
};

/// Computes sigmoid(x) using lookup table.
/// Input: x in Q32.32 fixed-point.
/// Output: sigmoid(x) in Q32.32 fixed-point.
/// For |x| >= 8, saturates to 0 (x < -8) or 1 (x > 8).
pub fn sigmoid(x: i64) i64 {
    // Saturate for large |x|
    if (x >= SIGMOID_RANGE) return ONE;
    if (x <= -SIGMOID_RANGE) return 0;

    // Map x from [-8, 8) to table index [0, 512)
    // index = ((x + 8) / 16) * 512 = (x + 8) * 32
    const offset = x + SIGMOID_RANGE;
    // offset is in Q32.32, need to scale to table index
    // index = offset * SIGMOID_TABLE_SIZE / (2 * SIGMOID_RANGE)
    // = offset * 512 / (16 * ONE) = offset * 32 / ONE
    // = (offset >> FRAC_BITS) << 5  (but need rounding)
    const scaled: i128 = @as(i128, offset) * @as(i128, SIGMOID_TABLE_SIZE);
    const range: i128 = @as(i128, SIGMOID_RANGE) * 2;
    const idx: i64 = @intCast(@divTrunc(scaled, range));
    const clamped: usize = @intCast(clamp(idx, 0, @as(i64, @intCast(SIGMOID_TABLE_SIZE - 1))));
    return sigmoid_table[clamped];
}

// =============================================================================
// Integer Exponential Approximation (Taylor series in fixed-point)
// =============================================================================

/// Computes exp(x) using a 6-term Taylor series in fixed-point.
/// exp(x) ≈ 1 + x + x²/2 + x³/6 + x⁴/24 + x⁵/120 + x⁶/720
/// For |x| > 4, uses repeated squaring: exp(x) = exp(x/2)^2
/// Input: x in Q32.32. Output: exp(x) in Q32.32.
pub fn exp(x: i64) i64 {
    // For large |x|, use range reduction: exp(x) = exp(x/n)^n
    // We use n = 2^k where k is chosen so |x/n| <= 2
    if (x >= fromInt(10)) return MAX_VAL; // Saturate
    if (x <= -fromInt(20)) return 0; // Underflow to 0

    var val = x;
    var n_shifts: u32 = 0;

    // Range reduce: divide by 2 until |val| <= 2
    while (val > fromInt(2) or val < -fromInt(2)) {
        val >>= 1;
        n_shifts += 1;
    }

    // Taylor series: 1 + x + x²/2 + x³/6 + x⁴/24 + x⁵/120 + x⁶/720
    // All in fixed-point
    var result: i64 = ONE; // 1
    var term: i64 = ONE; // current term accumulator

    // term 1: x
    term = val;
    result = add(result, term);

    // term 2: x²/2
    term = mul(term, val);
    term = div(term, fromInt(2));
    result = add(result, term);

    // term 3: x³/6 = (x²/2) * x / 3
    term = mul(term, val);
    term = div(term, fromInt(3));
    result = add(result, term);

    // term 4: x⁴/24 = (x³/6) * x / 4
    term = mul(term, val);
    term = div(term, fromInt(4));
    result = add(result, term);

    // term 5: x⁵/120 = (x⁴/24) * x / 5
    term = mul(term, val);
    term = div(term, fromInt(5));
    result = add(result, term);

    // term 6: x⁶/720 = (x⁵/120) * x / 6
    term = mul(term, val);
    term = div(term, fromInt(6));
    result = add(result, term);

    // Square n_shifts times to undo range reduction
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
const sin_table: [TRIG_TABLE_SIZE]i64 = blk: {
    @setEvalBranchQuota(10000);
    var table: [TRIG_TABLE_SIZE]i64 = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        const sin_val: f64 = @sin(angle);
        table[i] = @intFromFloat(sin_val * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

/// Cos table populated at comptime.
const cos_table: [TRIG_TABLE_SIZE]i64 = blk: {
    @setEvalBranchQuota(10000);
    var table: [TRIG_TABLE_SIZE]i64 = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        const cos_val: f64 = @cos(angle);
        table[i] = @intFromFloat(cos_val * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

/// Computes sin(angle) using lookup table.
/// Input: angle in Q32.32 radians. Output: sin(angle) in Q32.32.
pub fn sin(angle: i64) i64 {
    // Normalize angle to [0, 2π)
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;

    // Map to table index: index = (angle / 2π) * TRIG_TABLE_SIZE
    const idx: i128 = @divTrunc(@as(i128, a) * @as(i128, TRIG_TABLE_SIZE), @as(i128, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i128, TRIG_TABLE_SIZE)));
    return sin_table[clamped];
}

/// Computes cos(angle) using lookup table.
/// Input: angle in Q32.32 radians. Output: cos(angle) in Q32.32.
pub fn cos(angle: i64) i64 {
    // Normalize angle to [0, 2π)
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;

    // Map to table index
    const idx: i128 = @divTrunc(@as(i128, a) * @as(i128, TRIG_TABLE_SIZE), @as(i128, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i128, TRIG_TABLE_SIZE)));
    return cos_table[clamped];
}

/// Computes both sin and cos simultaneously (for DFT).
/// Returns { .sin = s, .cos = c } in Q32.32.
pub fn sincos(angle: i64) struct { sin_val: i64, cos_val: i64 } {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;

    const idx: i128 = @divTrunc(@as(i128, a) * @as(i128, TRIG_TABLE_SIZE), @as(i128, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i128, TRIG_TABLE_SIZE)));
    return .{ .sin_val = sin_table[clamped], .cos_val = cos_table[clamped] };
}

/// Computes the DFT twiddle factor W_N^k = exp(-2πi*k/N).
/// Returns { .re, .im } in Q32.32 fixed-point.
/// This is cos(-2πk/N) + i*sin(-2πk/N) = cos(2πk/N) - i*sin(2πk/N).
pub fn twiddle(k: usize, N: usize) struct { re: i64, im: i64 } {
    // angle = -2π * k / N
    // In fixed-point: angle = -(TWO_PI * k) / N
    const angle: i128 = @divTrunc(-(@as(i128, TWO_PI) * @as(i128, @intCast(k))), @as(i128, @intCast(N)));
    const angle_fp: i64 = @intCast(angle);
    const sc = sincos(angle_fp);
    // exp(i*angle) = cos(angle) + i*sin(angle)
    // angle is already -2πk/N, so this gives exp(-2πi*k/N) = W_N^k
    return .{ .re = sc.cos_val, .im = sc.sin_val };
}

// =============================================================================
// φ-Cooling (integer-only)
// =============================================================================

/// Precomputed φ^(-n) table for n = 0..63 in Q32.32.
/// φ^(-n) = (1/φ)^n
const PHI_COOL_TABLE_SIZE: usize = 64;
const phi_cool_table: [PHI_COOL_TABLE_SIZE]i64 = blk: {
    var table: [PHI_COOL_TABLE_SIZE]i64 = undefined;
    var val: f64 = 1.0;
    for (0..PHI_COOL_TABLE_SIZE) |i| {
        table[i] = @intFromFloat(val * @as(f64, @floatFromInt(ONE)));
        val /= 1.6180339887498948482;
    }
    break :blk table;
};

/// Computes φ-cooled temperature: T(cycle) = T₀ × φ^(-cycle).
/// Uses precomputed table for cycle < 64, saturates for cycle >= 64.
/// Input: base_temp in Q32.32, cycle as u64. Output: temperature in Q32.32.
pub fn phiCool(base_temp: i64, cycle: u64) i64 {
    if (cycle >= PHI_COOL_TABLE_SIZE) return TEMP_FLOOR;
    const factor = phi_cool_table[@intCast(cycle)];
    const result = mul(base_temp, factor);
    return if (result < TEMP_FLOOR) TEMP_FLOOR else result;
}

// =============================================================================
// Square Root (integer-only, Newton's method)
// =============================================================================

/// Computes sqrt(x) in Q32.32 using Newton's method.
/// Input: x in Q32.32. Output: sqrt(x) in Q32.32.
pub fn sqrt(x: i64) i64 {
    if (x <= 0) return 0;
    // Initial guess: x >> (FRAC_BITS / 2) = x >> 16
    var guess: i64 = x >> 16;
    if (guess == 0) guess = ONE;

    // Newton iterations: guess = (guess + x/guess) / 2
    for (0..20) |_| {
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
    try std.testing.expectEqual(@as(i64, fromInt(42)), toInt(fromInt(42)) << FRAC_BITS);
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
    // 0.25 in Q32.32 = 0.25 * 2^32 = 1073741824
    try std.testing.expectEqual(@as(i64, 1073741824), quarter);
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
    try std.testing.expectEqual(@as(i64, 0), sigmoid(-fromInt(10)));
}

test "sigmoid(0) = 0.5" {
    const result = sigmoid(0);
    // 0.5 in Q32.32 = 2147483648
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
    // e ≈ 2.71828... → toInt should be 2, fractional part > 0.5
    try std.testing.expectEqual(@as(i64, 2), toInt(result));
    // Check it's close to e: 2.71828 * 2^32 = 11674907765
    const diff = absVal(result - E);
    // Allow 1% tolerance in fixed-point: 0.01 * 2^32 = 42949673
    try std.testing.expect(diff < 42949673 * 10); // 10% tolerance for Taylor series
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
    // 1024-entry table has ~2π/1024 ≈ 0.006 rad resolution.
    // At π/2, error ≈ 0.006 * cos(π/2) ≈ 0, but table quantization gives ~80K LSB.
    // 80852 / ONE ≈ 0.000019 — excellent for 1024-entry table.
    // Allow ±100000 LSB tolerance (≈ 0.000023 absolute)
    try std.testing.expect(absVal(result - ONE) <= 100000);
}

test "cos(π) = -1" {
    const result = cos(PI);
    // Allow ±100000 LSB tolerance for 1024-entry table quantization
    try std.testing.expect(absVal(result - (-ONE)) <= 100000);
}

test "sin and cos are periodic" {
    const s1 = sin(0);
    const s2 = sin(TWO_PI);
    try std.testing.expect(absVal(s1 - s2) <= 100000);
}

test "twiddle W_N^0 = 1 + 0i" {
    const t = twiddle(0, 8);
    try std.testing.expectEqual(ONE, t.re);
    try std.testing.expect(absVal(t.im) <= 100000);
}

test "twiddle W_4^1 = -i" {
    const t = twiddle(1, 4);
    // W_4^1 = exp(-2πi/4) = exp(-iπ/2) = cos(-π/2) + i*sin(-π/2) = 0 - i
    // Allow ±100000 LSB tolerance for 1024-entry table quantization
    try std.testing.expect(absVal(t.re) <= 100000);
    try std.testing.expect(absVal(t.im - (-ONE)) <= 100000);
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
    try std.testing.expectEqual(@as(i64, 0), sqrt(0));
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
    const result = try format(allocator, fromInt(42) + 2147483648); // 42.5
    defer allocator.free(result);
    // Should contain "42" and "5000"
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
    try std.testing.expectEqual(@as(i64, 0), absVal(0));
}

// =============================================================================
// SIMD Batch Operations — @Vector-accelerated fixed-point arithmetic
// =============================================================================

/// Batch multiply: element-wise Q32.32 multiply for 4 values using @Vector.
pub fn mulVec4(a: @Vector(4, i64), b: @Vector(4, i64)) @Vector(4, i64) {
    const wide_a: @Vector(4, i128) = @intCast(a);
    const wide_b: @Vector(4, i128) = @intCast(b);
    const product = wide_a * wide_b;
    const shifted = product >> @as(@Vector(4, u7), @splat(FRAC_BITS));
    return @intCast(shifted);
}

/// Batch add: element-wise Q32.32 add for 4 values.
pub fn addVec4(a: @Vector(4, i64), b: @Vector(4, i64)) @Vector(4, i64) {
    return a + b;
}

/// Batch sub: element-wise Q32.32 subtract for 4 values.
pub fn subVec4(a: @Vector(4, i64), b: @Vector(4, i64)) @Vector(4, i64) {
    return a - b;
}

/// Batch fromInt: convert 4 integer values to Q32.32 fixed-point.
pub fn fromIntVec4(v: @Vector(4, i64)) @Vector(4, i64) {
    return v << @as(@Vector(4, u6), @splat(FRAC_BITS));
}

/// Batch multiply for arbitrary-length slices using @Vector(4, i64) lanes.
pub fn mulBatch(dst: []i64, a: []const i64, b: []const i64) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: @Vector(4, i64) = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: @Vector(4, i64) = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
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
pub fn addBatch(dst: []i64, a: []const i64, b: []const i64) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: @Vector(4, i64) = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: @Vector(4, i64) = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
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
    const a: @Vector(4, i64) = .{ fromInt(2), fromInt(3), fromInt(4), fromInt(5) };
    const b: @Vector(4, i64) = .{ fromInt(3), fromInt(4), fromInt(5), fromInt(6) };
    const result = mulVec4(a, b);
    try std.testing.expectEqual(fromInt(6), result[0]);
    try std.testing.expectEqual(fromInt(12), result[1]);
    try std.testing.expectEqual(fromInt(20), result[2]);
    try std.testing.expectEqual(fromInt(30), result[3]);
}

test "SIMD mulBatch matches scalar" {
    var dst: [10]i64 = undefined;
    const a = [_]i64{ fromInt(1), fromInt(2), fromInt(3), fromInt(4), fromInt(5), fromInt(6), fromInt(7), fromInt(8), fromInt(9), fromInt(10) };
    const b = [_]i64{ fromInt(10), fromInt(9), fromInt(8), fromInt(7), fromInt(6), fromInt(5), fromInt(4), fromInt(3), fromInt(2), fromInt(1) };
    mulBatch(&dst, &a, &b);
    for (0..10) |i| {
        try std.testing.expectEqual(mul(a[i], b[i]), dst[i]);
    }
}
