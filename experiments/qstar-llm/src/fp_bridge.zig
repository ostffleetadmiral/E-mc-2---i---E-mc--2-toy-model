//! fp_bridge.zig — Downscale bridge: Q64.64 (i128) → Q32.32 (i64).
//!
//! Converts fixed-point values from the master Q64.64 engine to the peripheral
//! Q32.32 format used by Maple/ESP32 and other resource-constrained devices.
//!
//! Conversion process:
//!   1. Extract integer part (bits 64..127) — check for i32 overflow
//!   2. Extract fractional part (bits 0..63) — right-shift by 32 with rounding
//!   3. Combine into Q32.32 i64
//!
//! Rounding: adds half-bit (1 << 31) before right-shifting fractional part
//! by 32 bits, giving round-to-nearest behavior.

const std = @import("std");
const fp = @import("fixed_point");
const fp32 = @import("fixed_point32");

/// Error returned when the integer part of a Q64.64 value exceeds i32 range.
pub const OverflowError = error{IntegerOverflow};

/// Convert a single Q64.64 value to Q32.32.
/// Returns OverflowError if the integer part exceeds [-2^31, 2^31).
pub fn downscaleQ64ToQ32(v: i128) OverflowError!i64 {
    // Extract integer part: bits 64..127
    const int_part: i128 = v >> 64;

    // Check for i32 overflow
    if (int_part > std.math.maxInt(i32)) return OverflowError.IntegerOverflow;
    if (int_part < std.math.minInt(i32)) return OverflowError.IntegerOverflow;

    // Extract fractional part: bits 0..63
    const frac_part: u128 = @intCast(v & ((@as(i128, 1) << 64) - 1));

    // Round-to-nearest: add half-bit before right-shifting
    // Half-bit at Q32.32 level = 1 << 31 = 2147483648
    const half_bit: u128 = 1 << 31;
    const frac_shifted: u64 = @intCast((frac_part + half_bit) >> 32);

    // Combine: int_part << 32 | frac_shifted
    const int_shifted: i64 = @as(i64, @intCast(int_part)) << 32;
    const result: i64 = int_shifted | @as(i64, @intCast(frac_shifted));

    // Handle sign: if v was negative and frac_part was non-zero,
    // the int_part already captures the sign via arithmetic shift
    return result;
}

/// Convert a single Q64.64 value to Q32.32 with saturation.
/// If the integer part exceeds i32 range, saturates to max/min.
pub fn downscaleSaturating(v: i128) i64 {
    const int_part: i128 = v >> 64;

    if (int_part > std.math.maxInt(i32)) return std.math.maxInt(i32) << 32;
    if (int_part < std.math.minInt(i32)) return std.math.minInt(i32) << 32;

    const frac_part: u128 = @intCast(v & ((@as(i128, 1) << 64) - 1));
    const half_bit: u128 = 1 << 31;
    const frac_shifted: u64 = @intCast((frac_part + half_bit) >> 32);

    const int_shifted: i64 = @as(i64, @intCast(int_part)) << 32;
    return int_shifted | @as(i64, @intCast(frac_shifted));
}

/// Batch downscale an array of Q64.64 values to Q32.32.
/// Returns the number of values that overflowed (saturated).
pub fn downscaleBatch(dst: []i64, src: []const i128) usize {
    const n = @min(dst.len, src.len);
    var overflow_count: usize = 0;
    for (0..n) |i| {
        dst[i] = downscaleSaturating(src[i]);
        // Check if overflow occurred by comparing integer parts
        const int_part: i128 = src[i] >> 64;
        if (int_part > std.math.maxInt(i32) or int_part < std.math.minInt(i32)) {
            overflow_count += 1;
        }
    }
    return overflow_count;
}

/// Upscale a Q32.32 value to Q64.64 (lossless).
/// The fractional bits are shifted left by 32, integer bits are sign-extended.
pub fn upscaleQ32ToQ64(v: i64) i128 {
    return @as(i128, v) << 32;
}

/// Round-trip test: Q64.64 → Q32.32 → Q64.64 should preserve integer part
/// and approximate fractional part to Q32.32 precision.
pub fn roundTripError(original: i128) i128 {
    const downscaled = downscaleSaturating(original);
    const upscaled = upscaleQ32ToQ64(downscaled);
    return fp.absVal(original - upscaled);
}

// =============================================================================
// Tests
// =============================================================================

test "downscale zero" {
    const result = try downscaleQ64ToQ32(0);
    try std.testing.expectEqual(@as(i64, 0), result);
}

test "downscale one" {
    const result = try downscaleQ64ToQ32(fp.ONE);
    try std.testing.expectEqual(fp32.ONE, result);
}

test "downscale half" {
    const result = try downscaleQ64ToQ32(fp.HALF_FP);
    try std.testing.expectEqual(fp32.HALF_FP, result);
}

test "downscale negative value" {
    const result = try downscaleQ64ToQ32(-fp.fromInt(5));
    try std.testing.expectEqual(-fp32.fromInt(5), result);
}

test "downscale integer overflow saturates" {
    // 2^31 in Q64.64 exceeds i32 range
    const big = fp.fromInt(std.math.maxInt(i32) + 1);
    const result = downscaleSaturating(big);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)) << 32, result);
}

test "downscale returns error on overflow" {
    const big = fp.fromInt(std.math.maxInt(i32) + 1);
    try std.testing.expectError(OverflowError.IntegerOverflow, downscaleQ64ToQ32(big));
}

test "downscale preserves fractional precision" {
    // 0.5 in Q64.64 → 0.5 in Q32.32
    const result = try downscaleQ64ToQ32(fp.HALF_FP);
    try std.testing.expectEqual(fp32.HALF_FP, result);

    // 0.25 in Q64.64 → 0.25 in Q32.32
    const quarter_q64 = fp.mul(fp.HALF_FP, fp.HALF_FP);
    const result_q32 = try downscaleQ64ToQ32(quarter_q64);
    const quarter_q32 = fp32.mul(fp32.HALF_FP, fp32.HALF_FP);
    try std.testing.expectEqual(quarter_q32, result_q32);
}

test "downscale rounding: 0.5 + 0.25 = 0.75" {
    const val = fp.add(fp.HALF_FP, fp.mul(fp.HALF_FP, fp.HALF_FP));
    const result = try downscaleQ64ToQ32(val);
    const expected = fp32.add(fp32.HALF_FP, fp32.mul(fp32.HALF_FP, fp32.HALF_FP));
    try std.testing.expectEqual(expected, result);
}

test "upscale is lossless" {
    const q32_val = fp32.fromInt(42) + fp32.HALF_FP;
    const upscaled = upscaleQ32ToQ64(q32_val);
    // Should be exactly 42.5 in Q64.64
    const expected = fp.fromInt(42) + fp.HALF_FP;
    try std.testing.expectEqual(expected, upscaled);
}

test "batch downscale" {
    const src = [_]i128{ fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.HALF_FP };
    var dst: [4]i64 = undefined;
    const overflow = downscaleBatch(&dst, &src);
    try std.testing.expectEqual(@as(usize, 0), overflow);
    try std.testing.expectEqual(fp32.fromInt(1), dst[0]);
    try std.testing.expectEqual(fp32.fromInt(2), dst[1]);
    try std.testing.expectEqual(fp32.fromInt(3), dst[2]);
    try std.testing.expectEqual(fp32.HALF_FP, dst[3]);
}

test "batch downscale with overflow" {
    const big = fp.fromInt(std.math.maxInt(i32) + 1);
    const src = [_]i128{ fp.fromInt(1), big, fp.fromInt(3) };
    var dst: [3]i64 = undefined;
    const overflow = downscaleBatch(&dst, &src);
    try std.testing.expectEqual(@as(usize, 1), overflow);
    try std.testing.expectEqual(fp32.fromInt(1), dst[0]);
    try std.testing.expectEqual(fp32.fromInt(3), dst[2]);
}

test "round-trip error is within Q32.32 precision" {
    // For values that fit in Q32.32, round-trip error should be < 1 Q32.32 LSB
    // which is 2^32 in Q64.64 terms
    const val = fp.fromInt(42) + fp.HALF_FP;
    const err = roundTripError(val);
    try std.testing.expect(err < (@as(i128, 1) << 32));
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
