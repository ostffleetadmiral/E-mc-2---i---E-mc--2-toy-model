//! precision_scaler.zig — Hardware-agnostic precision scaling orchestrator.
//!
//! Uses hardware_detect to determine the native precision tier at comptime,
//! then provides a unified API that operates at the highest available precision.
//!
//! On native targets (x86_64, aarch64, wasm32): operates in Q64.64 (i128).
//! On embedded targets (AVR, etc.): operates in Q32.32 (i64) directly.
//! For peripheral output (Maple/ESP32): downscales via fp_bridge.

const std = @import("std");
const hw = @import("hardware_detect");
const fp = @import("fixed_point");
const fp32 = @import("fixed_point32");
const bridge = @import("fp_bridge");

/// The active fixed-point type for this build target.
pub const FpType = if (hw.NATIVE_PRECISION == .q128_native) i128 else i64;

/// The active fractional bit count.
pub const ACTIVE_FRAC_BITS: comptime_int = if (hw.NATIVE_PRECISION == .q128_native) 64 else 32;

/// The active ONE constant.
pub const ACTIVE_ONE: FpType = if (hw.NATIVE_PRECISION == .q128_native) fp.ONE else fp32.ONE;

/// Whether this build uses Q64.64 (true) or Q32.32 (false).
pub const IS_Q64: bool = hw.NATIVE_PRECISION == .q128_native;

/// Convert integer to active fixed-point format.
pub inline fn fromInt(v: i64) FpType {
    if (IS_Q64) return fp.fromInt(v);
    return fp32.fromInt(@intCast(v));
}

/// Convert active fixed-point to integer.
pub inline fn toInt(v: FpType) i64 {
    if (IS_Q64) return fp.toInt(v);
    return @as(i64, fp32.toInt(v));
}

/// Active add.
pub inline fn add(a: FpType, b: FpType) FpType {
    if (IS_Q64) return fp.add(a, b);
    return fp32.add(a, b);
}

/// Active sub.
pub inline fn sub(a: FpType, b: FpType) FpType {
    if (IS_Q64) return fp.sub(a, b);
    return fp32.sub(a, b);
}

/// Active mul.
pub inline fn mul(a: FpType, b: FpType) FpType {
    if (IS_Q64) return fp.mul(a, b);
    return fp32.mul(a, b);
}

/// Active div.
pub inline fn div(a: FpType, b: FpType) FpType {
    if (IS_Q64) return fp.div(a, b);
    return fp32.div(a, b);
}

/// Active absVal.
pub inline fn absVal(v: FpType) FpType {
    if (IS_Q64) return fp.absVal(v);
    return fp32.absVal(v);
}

/// Active clamp.
pub inline fn clamp(v: FpType, lo: FpType, hi: FpType) FpType {
    if (IS_Q64) return fp.clamp(v, lo, hi);
    return fp32.clamp(v, lo, hi);
}

/// Active sigmoid.
pub inline fn sigmoid(x: FpType) FpType {
    if (IS_Q64) return fp.sigmoid(x);
    return fp32.sigmoid(x);
}

/// Active sqrt.
pub inline fn sqrt(x: FpType) FpType {
    if (IS_Q64) return fp.sqrt(x);
    return fp32.sqrt(x);
}

/// Downscale to Q32.32 for peripheral output (Maple/ESP32).
/// On Q64.64 builds: uses fp_bridge. On Q32.32 builds: identity.
pub inline fn toPeripheral(v: FpType) i64 {
    if (IS_Q64) return bridge.downscaleSaturating(v);
    return v;
}

/// Upscale from Q32.32 peripheral input to active format.
/// On Q64.64 builds: uses fp_bridge. On Q32.32 builds: identity.
pub inline fn fromPeripheral(v: i64) FpType {
    if (IS_Q64) return bridge.upscaleQ32ToQ64(v);
    return v;
}

/// Batch downscale to Q32.32 for peripheral output.
pub fn toPeripheralBatch(dst: []i64, src: []const FpType) usize {
    if (IS_Q64) return bridge.downscaleBatch(dst, src);
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return 0;
}

/// Get a description of the active precision mode.
pub fn activeModeDescription() []const u8 {
    if (IS_Q64) return "Q64.64 (i128, i256 intermediates)";
    return "Q32.32 (i64, i128 intermediates)";
}

// =============================================================================
// Tests
// =============================================================================

test "fromInt/toInt round trip" {
    const v = fromInt(42);
    try std.testing.expectEqual(@as(i64, 42), toInt(v));
}

test "add and mul work" {
    const a = fromInt(3);
    const b = fromInt(4);
    try std.testing.expectEqual(fromInt(7), add(a, b));
    try std.testing.expectEqual(fromInt(12), mul(a, b));
}

test "toPeripheral produces i64" {
    const v = fromInt(5);
    const p = toPeripheral(v);
    try std.testing.expectEqual(@as(i64, 5), fp32.toInt(@intCast(p)));
}

test "fromPeripheral round trips" {
    const original = fp32.fromInt(10);
    const upscaled = fromPeripheral(original);
    const back = toPeripheral(upscaled);
    try std.testing.expectEqual(@as(i64, 10), fp32.toInt(@intCast(back)));
}

test "activeModeDescription is non-empty" {
    try std.testing.expect(activeModeDescription().len > 0);
}

// =============================================================================
// Framework Scaling Chain (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework scaling chain: 15 → 16 → 32 → 62 → 128 → 256
/// Each level corresponds to a doubling in the cubic lattice.
/// 15 = 2⁴ - 1 (closure - Higgs)
/// 16 = 2⁴ (first closure)
/// 32 = 2⁵ (first doubling)
/// 62 = 2⁶ - 2 (codon capacity - boundary)
/// 128 = 2⁷ (third doubling)
/// 256 = 2⁸ (octonion capacity)
pub const SCALING_CHAIN = [_]u32{ 15, 16, 32, 62, 128, 256 };

/// Returns the framework scaling level for a given lattice level.
/// Level 0 → 15, Level 1 → 16, Level 2 → 32, etc.
pub fn frameworkScalingLevel(level: u8) u32 {
    if (level >= SCALING_CHAIN.len) return SCALING_CHAIN[SCALING_CHAIN.len - 1];
    return SCALING_CHAIN[level];
}

/// Verifies the framework scaling chain matches the hardware project's scaling analysis.
pub fn verifyScalingChain() bool {
    // 15³ = 3375 (interior volume)
    if (SCALING_CHAIN[0] * SCALING_CHAIN[0] * SCALING_CHAIN[0] != 3375) return false;
    // 16³ = 4096 (shell volume)
    if (SCALING_CHAIN[1] * SCALING_CHAIN[1] * SCALING_CHAIN[1] != 4096) return false;
    // 62 = 64 - 2 (codon capacity - boundary)
    if (SCALING_CHAIN[3] != 64 - 2) return false;
    // 256 = 2⁸ (octonion capacity)
    if (SCALING_CHAIN[5] != 256) return false;
    return true;
}

test "framework: scaling chain 15→16→32→62→128→256" {
    try std.testing.expect(verifyScalingChain());
    try std.testing.expectEqual(@as(u32, 15), frameworkScalingLevel(0));
    try std.testing.expectEqual(@as(u32, 16), frameworkScalingLevel(1));
    try std.testing.expectEqual(@as(u32, 256), frameworkScalingLevel(5));
}
