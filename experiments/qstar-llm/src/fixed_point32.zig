//! fixed_point32.zig — Q32.32 fixed-point arithmetic for peripheral subsystems.
//!
//! This is the downscale target for Maple/ESP32 and other resource-constrained
//! devices. It mirrors the original Q32.32 API but is kept as a separate module
//! so the master Q64.64 engine can coexist and feed downscaled values via fp_bridge.
//!
//! All values are i64 with 32 fractional bits:
//!   - Integer range: [-2^31, 2^31)
//!   - Fractional precision: 1/2^32 ≈ 2.33e-10
//!   - ~9 decimal digits of precision

const std = @import("std");

pub const FRAC_BITS: u6 = 32;
pub const ONE: i64 = 1 << FRAC_BITS;
pub const HALF: i64 = ONE >> 1;
pub const ZERO: i64 = 0;

pub const MAX_VAL: i64 = std.math.maxInt(i64);
pub const MIN_VAL: i64 = std.math.minInt(i64);

pub inline fn fromInt(v: i32) i64 {
    return @as(i64, v) << FRAC_BITS;
}

pub inline fn toInt(v: i64) i32 {
    const shifted: i64 = v >> FRAC_BITS;
    if (shifted > std.math.maxInt(i32)) return std.math.maxInt(i32);
    if (shifted < std.math.minInt(i32)) return std.math.minInt(i32);
    return @intCast(shifted);
}

pub fn format(allocator: std.mem.Allocator, v: i64) ![]u8 {
    const int_part = toInt(v);
    const frac_part = v & (ONE - 1);
    const frac_scaled: u64 = @intCast(frac_part);
    const frac_4dp = (frac_scaled * 10000) >> FRAC_BITS;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>4}", .{ int_part, frac_4dp });
}

pub inline fn add(a: i64, b: i64) i64 {
    return a + b;
}

pub inline fn sub(a: i64, b: i64) i64 {
    return a - b;
}

pub inline fn mul(a: i64, b: i64) i64 {
    const result: i128 = @as(i128, a) * @as(i128, b);
    return @intCast(result >> FRAC_BITS);
}

pub inline fn div(a: i64, b: i64) i64 {
    if (b == 0) return 0;
    const result: i128 = @divTrunc(@as(i128, a) << FRAC_BITS, @as(i128, b));
    return @intCast(result);
}

pub inline fn absVal(v: i64) i64 {
    return if (v < 0) -v else v;
}

pub inline fn negate(v: i64) i64 {
    return -v;
}

pub inline fn maxVal(a: i64, b: i64) i64 {
    return if (a > b) a else b;
}

pub inline fn minVal(a: i64, b: i64) i64 {
    return if (a < b) a else b;
}

pub inline fn clamp(v: i64, lo: i64, hi: i64) i64 {
    return maxVal(lo, minVal(hi, v));
}

// =============================================================================
// Constants (Q32.32)
// =============================================================================

pub const PHI: i64 = 6950374848;
pub const INV_PHI: i64 = 2654435769;
pub const INV_SQRT2: i64 = 3037000499;
pub const PI: i64 = 13493037704;
pub const TWO_PI: i64 = 26986075409;
pub const E: i64 = 11674907765;
pub const TEMP_FLOOR: i64 = 4294967;
pub const HALF_FP: i64 = 2147483648;
pub const WEIGHT_08: i64 = 3435973837;
pub const WEIGHT_03: i64 = 1288490189;
pub const WEIGHT_015: i64 = 644245094;
pub const DECAY_07: i64 = 3006477107;
pub const POS_DECAY: i64 = 42949673;
pub const LOGIT_SCALE: i64 = 42949672960;
pub const FIB_NORM: i64 = 141733920768;

pub const FIB_WEIGHTS = [_]i64{
    fromInt(1), fromInt(1), fromInt(2), fromInt(3), fromInt(5), fromInt(8), fromInt(13),
};

pub const DEFECT_DELTA: i64 = 133621204;
pub const ACTIVE_DENSITY_RHO: i64 = 535759902;
pub const COUPLING_G: i64 = 16668461;
pub const BANDWIDTH_C: i64 = fromInt(2);
pub const E8_ROOT_COUNT: u32 = 240;
pub const INTERIOR_CELLS: u32 = 3375;
pub const SHELL_CELLS: u32 = 4096;
pub const BOUNDARY_CELLS: u32 = 721;

// =============================================================================
// Sigmoid (Q32.32 lookup table)
// =============================================================================

const SIGMOID_TABLE_SIZE: usize = 512;
const SIGMOID_RANGE: i64 = fromInt(8);

const sigmoid_table: [SIGMOID_TABLE_SIZE]i64 = blk: {
    var table: [SIGMOID_TABLE_SIZE]i64 = undefined;
    for (0..SIGMOID_TABLE_SIZE) |i| {
        const x_f: f64 = -8.0 + (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SIGMOID_TABLE_SIZE))) * 16.0;
        const sig_f: f64 = 1.0 / (1.0 + @exp(-x_f));
        table[i] = @intFromFloat(sig_f * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

pub fn sigmoid(x: i64) i64 {
    if (x >= SIGMOID_RANGE) return ONE;
    if (x <= -SIGMOID_RANGE) return 0;
    const offset = x + SIGMOID_RANGE;
    const scaled: i128 = @as(i128, offset) * @as(i128, SIGMOID_TABLE_SIZE);
    const range: i128 = @as(i128, SIGMOID_RANGE) * 2;
    const idx: i64 = @intCast(@divTrunc(scaled, range));
    const clamped: usize = @intCast(clamp(idx, 0, @as(i64, @intCast(SIGMOID_TABLE_SIZE - 1))));
    return sigmoid_table[clamped];
}

// =============================================================================
// Trig tables (Q32.32)
// =============================================================================

const TRIG_TABLE_SIZE: usize = 1024;

const sin_table: [TRIG_TABLE_SIZE]i64 = blk: {
    @setEvalBranchQuota(10000);
    var table: [TRIG_TABLE_SIZE]i64 = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        table[i] = @intFromFloat(@sin(angle) * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

const cos_table: [TRIG_TABLE_SIZE]i64 = blk: {
    @setEvalBranchQuota(10000);
    var table: [TRIG_TABLE_SIZE]i64 = undefined;
    for (0..TRIG_TABLE_SIZE) |i| {
        const angle: f64 = (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRIG_TABLE_SIZE))) * 2.0 * std.math.pi;
        table[i] = @intFromFloat(@cos(angle) * @as(f64, @floatFromInt(ONE)));
    }
    break :blk table;
};

pub fn sin(angle: i64) i64 {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;
    const idx: i128 = @divTrunc(@as(i128, a) * @as(i128, TRIG_TABLE_SIZE), @as(i128, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i128, TRIG_TABLE_SIZE)));
    return sin_table[clamped];
}

pub fn cos(angle: i64) i64 {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;
    const idx: i128 = @divTrunc(@as(i128, a) * @as(i128, TRIG_TABLE_SIZE), @as(i128, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i128, TRIG_TABLE_SIZE)));
    return cos_table[clamped];
}

pub fn sincos(angle: i64) struct { sin_val: i64, cos_val: i64 } {
    var a = angle;
    const two_pi = TWO_PI;
    while (a < 0) a += two_pi;
    while (a >= two_pi) a -= two_pi;
    const idx: i128 = @divTrunc(@as(i128, a) * @as(i128, TRIG_TABLE_SIZE), @as(i128, two_pi));
    const clamped: usize = @intCast(@mod(idx, @as(i128, TRIG_TABLE_SIZE)));
    return .{ .sin_val = sin_table[clamped], .cos_val = cos_table[clamped] };
}

pub fn twiddle(k: usize, N: usize) struct { re: i64, im: i64 } {
    const angle: i128 = @divTrunc(-(@as(i128, TWO_PI) * @as(i128, @intCast(k))), @as(i128, @intCast(N)));
    const angle_fp: i64 = @intCast(angle);
    const sc = sincos(angle_fp);
    return .{ .re = sc.cos_val, .im = sc.sin_val };
}

// =============================================================================
// φ-Cooling (Q32.32)
// =============================================================================

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

pub fn phiCool(base_temp: i64, cycle: u64) i64 {
    if (cycle >= PHI_COOL_TABLE_SIZE) return TEMP_FLOOR;
    const factor = phi_cool_table[@intCast(cycle)];
    const result = mul(base_temp, factor);
    return if (result < TEMP_FLOOR) TEMP_FLOOR else result;
}

// =============================================================================
// Square Root (Q32.32, Newton's method)
// =============================================================================

pub fn sqrt(x: i64) i64 {
    if (x <= 0) return 0;
    var guess: i64 = x >> 16;
    if (guess == 0) guess = ONE;
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
    const half = HALF_FP;
    const quarter = mul(half, half);
    try std.testing.expectEqual(@as(i64, 1073741824), quarter);
}

test "div preserves fractional precision" {
    const a = fromInt(10);
    const b = fromInt(3);
    const result = div(a, b);
    try std.testing.expectEqual(@as(i64, 3), toInt(result));
    try std.testing.expect(result > fromInt(3));
    try std.testing.expect(result < fromInt(4));
}

test "sigmoid(0) = 0.5" {
    const result = sigmoid(0);
    try std.testing.expectEqual(HALF_FP, result);
}

test "sin(0) = 0" {
    const result = sin(0);
    try std.testing.expect(absVal(result) <= 1);
}

test "cos(0) = 1" {
    const result = cos(0);
    try std.testing.expectEqual(ONE, result);
}

test "sqrt(4) = 2" {
    const result = sqrt(fromInt(4));
    try std.testing.expectEqual(fromInt(2), result);
}

test "clamp works correctly" {
    try std.testing.expectEqual(fromInt(5), clamp(fromInt(5), fromInt(0), fromInt(10)));
    try std.testing.expectEqual(fromInt(0), clamp(-fromInt(5), fromInt(0), fromInt(10)));
    try std.testing.expectEqual(fromInt(10), clamp(fromInt(20), fromInt(0), fromInt(10)));
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
