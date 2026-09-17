//! dim_0d_origin.zig — 0D Origin (Point/Real/Observer dimension).
//!
//! The 0D dimension is the axiom, seed, and observer anchor.
//! Algebra: Real numbers (U(1) phase rotation around e0).
//! Purpose: Initial state anchor, SYSTEM_PROMPT seed, phase rotation.
//!
//! All arithmetic is integer-only. No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

/// The 0D origin state — the axiom/seed.
pub const OriginState = struct {
    /// The seed value (Q64.64 fixed-point).
    seed: i128,
    /// Phase rotation angle (Q64.64 fixed-point, U(1) phase).
    phase: i128,
    /// Whether the origin has been initialized.
    initialized: bool,

    /// Creates a zero origin state.
    pub fn zero() OriginState {
        return .{ .seed = 0, .phase = 0, .initialized = false };
    }

    /// Creates an origin state from a seed value.
    pub fn fromSeed(seed: i128) OriginState {
        return .{ .seed = seed, .phase = 0, .initialized = true };
    }

    /// Applies U(1) phase rotation: phase += delta (mod 2π).
    /// Since we use fixed-point, we mod by 2*fp.ONE (representing 2π).
    pub fn rotatePhase(self: *OriginState, delta: i128) void {
        self.phase = @mod(self.phase + delta, 2 * fp.ONE);
    }

    /// Returns the current phase as a fixed-point value.
    pub fn currentPhase(self: OriginState) i128 {
        return self.phase;
    }

    /// Returns the seed value.
    pub fn seedValue(self: OriginState) i128 {
        return self.seed;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "OriginState: zero state" {
    const state = OriginState.zero();
    try std.testing.expect(state.seed == 0);
    try std.testing.expect(state.phase == 0);
    try std.testing.expect(state.initialized == false);
}

test "OriginState: fromSeed" {
    const state = OriginState.fromSeed(fp.fromInt(42));
    try std.testing.expect(state.seed == fp.fromInt(42));
    try std.testing.expect(state.phase == 0);
    try std.testing.expect(state.initialized == true);
}

test "OriginState: rotatePhase" {
    var state = OriginState.fromSeed(fp.fromInt(1));
    state.rotatePhase(fp.fromInt(1));
    try std.testing.expect(state.phase == fp.fromInt(1));
    // After second rotation: (1 + 1) mod 2 = 0 (wraps around 2π)
    state.rotatePhase(fp.fromInt(1));
    try std.testing.expect(state.phase == 0);
}

test "OriginState: phase wraps around 2π" {
    var state = OriginState.fromSeed(fp.fromInt(1));
    // Set phase to near 2π, then rotate past it
    state.phase = 2 * fp.ONE - fp.fromInt(1);
    state.rotatePhase(fp.fromInt(2));
    // Should wrap: (2π - 1 + 2) mod 2π = 1
    try std.testing.expect(state.phase == fp.fromInt(1));
}

test "OriginState: seedValue and currentPhase" {
    const state = OriginState.fromSeed(fp.fromInt(99));
    try std.testing.expect(state.seedValue() == fp.fromInt(99));
    try std.testing.expect(state.currentPhase() == 0);
}
