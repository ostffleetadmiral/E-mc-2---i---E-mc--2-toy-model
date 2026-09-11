// ============================================================================
// NEURALEAK PHYSICS — Framework Physics Constants
// ============================================================================
//
// Provides the physics constants used by the neuraleak system, cross-wired to
// the existing mathematical framework.
//
// The key constant is the consciousness octonion layer fraction: 1/8.
// This represents one octonion dimension out of eight, connecting to the
// framework's 6D observer / 7/8 observed split.
//
// In exact arithmetic: 1/8 is represented as a rational. The f64 value is
// only used for display and approximate computation in the neuraleak modules.
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");

/// The consciousness fraction: 1/8 of the octonion space.
/// Exact: 1/8. f64: 0.125.
pub fn consciousnessOctonionLayerFraction() f64 {
    return 1.0 / 8.0;
}

/// The observed fraction: 7/8 of the octonion space.
/// Exact: 7/8. f64: 0.875.
pub fn observedOctonionLayerFraction() f64 {
    return 7.0 / 8.0;
}

/// The observer dimension count: 1 (one octonion dimension).
pub const OBSERVER_DIMENSIONS: u8 = 1;

/// The observed dimension count: 7 (seven octonion dimensions).
pub const OBSERVED_DIMENSIONS: u8 = 7;

/// The total octonion dimension count: 8.
pub const TOTAL_OCTONION_DIMENSIONS: u8 = 8;

/// The 6D Jordan layer dimension count: 6 (e0..e6).
pub const JORDAN_LAYER_DIMENSIONS: u8 = 6;

/// The 7D observed layer dimension count: 7 (e0..e7 minus observer).
pub const OBSERVED_LAYER_DIMENSIONS: u8 = 7;

/// E8 root count (established mathematics).
pub const E8_ROOT_COUNT: u32 = 240;

/// 15×15 matrix element count.
pub const MATRIX_15X15_ELEMENTS: u32 = 225;

/// 15³ interior cell count.
pub const INTERIOR_15_CUBED: u32 = 3375;

/// 16³ closure cell count.
pub const CLOSURE_16_CUBED: u32 = 4096;

/// Shell transition: 16³ - 15³ = 721 = 3(240) + 1.
pub const SHELL_TRANSITION: u32 = 721;

/// Verify the shell transition identity in exact arithmetic.
pub fn verifyShellTransition() bool {
    return CLOSURE_16_CUBED - INTERIOR_15_CUBED == SHELL_TRANSITION and
        SHELL_TRANSITION == 3 * E8_ROOT_COUNT + 1;
}

/// Verify the matrix-E8 identity: 225 = 240 - 15.
pub fn verifyMatrixE8Identity() bool {
    return MATRIX_15X15_ELEMENTS == E8_ROOT_COUNT - 15;
}

/// Verify the consciousness fraction: 1/8 + 7/8 = 1.
pub fn verifyConsciousnessSplit() bool {
    return OBSERVER_DIMENSIONS + OBSERVED_DIMENSIONS == TOTAL_OCTONION_DIMENSIONS;
}

// ============================================================================
// Tests
// ============================================================================

test "consciousness fraction is 1/8" {
    try std.testing.expectApproxEqAbs(consciousnessOctonionLayerFraction(), 0.125, 1e-15);
}

test "observed fraction is 7/8" {
    try std.testing.expectApproxEqAbs(observedOctonionLayerFraction(), 0.875, 1e-15);
}

test "consciousness + observed = 1" {
    const total = consciousnessOctonionLayerFraction() + observedOctonionLayerFraction();
    try std.testing.expectApproxEqAbs(total, 1.0, 1e-15);
}

test "shell transition identity 16³ - 15³ = 3(240) + 1" {
    try std.testing.expect(verifyShellTransition());
}

test "matrix E8 identity 225 = 240 - 15" {
    try std.testing.expect(verifyMatrixE8Identity());
}

test "consciousness split 1 + 7 = 8" {
    try std.testing.expect(verifyConsciousnessSplit());
}

test "observer dimensions connect to octonion" {
    try std.testing.expectEqual(@as(u8, 1), OBSERVER_DIMENSIONS);
    try std.testing.expectEqual(@as(u8, 7), OBSERVED_DIMENSIONS);
    try std.testing.expectEqual(@as(u8, 8), TOTAL_OCTONION_DIMENSIONS);
    try std.testing.expectEqual(@as(u8, 6), JORDAN_LAYER_DIMENSIONS);
}
