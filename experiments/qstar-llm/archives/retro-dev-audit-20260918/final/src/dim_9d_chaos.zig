//! dim_9d_chaos.zig — 9D Chaos (Anti-octonion dimension).
//!
//! The 9D dimension handles anti-octonion structure, chaos, and inflation.
//! Algebra: Anti-octonions (no symmetry — pure chaos/inflation).
//! Purpose: Chaos injection, randomness, inflation.
//!
//! All arithmetic is integer-only. No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");

/// The 9D chaos injector — injects randomness and chaos into the system.
pub const ChaosInjector = struct {
    /// RNG state for deterministic chaos.
    rng_state: u64,
    /// Chaos intensity (0-100, higher = more chaos).
    intensity: u8,
    /// Number of chaos injections performed.
    injection_count: u64,

    pub fn init(seed: u64) ChaosInjector {
        return .{
            .rng_state = seed,
            .intensity = 50,
            .injection_count = 0,
        };
    }

    /// Sets the chaos intensity (0-100).
    pub fn setIntensity(self: *ChaosInjector, intensity: u8) void {
        self.intensity = @min(intensity, 100);
    }

    /// Generates a chaotic value using xorshift64.
    pub fn chaoticValue(self: *ChaosInjector) u64 {
        var x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng_state = x;
        self.injection_count += 1;
        return x;
    }

    /// Generates a chaotic channel selection (0-6 for 7 octonionic channels).
    pub fn chaoticChannel(self: *ChaosInjector) u3 {
        return @intCast(self.chaoticValue() % 7);
    }

    /// Returns whether chaos should be injected (based on intensity).
    pub fn shouldInject(self: ChaosInjector) bool {
        return (self.rng_state % 100) < self.intensity;
    }

    /// Returns the current chaos intensity.
    pub fn currentIntensity(self: ChaosInjector) u8 {
        return self.intensity;
    }

    /// Returns the number of injections performed.
    pub fn injectionCount(self: ChaosInjector) u64 {
        return self.injection_count;
    }

    /// Resets the chaos injector.
    pub fn reset(self: *ChaosInjector) void {
        self.injection_count = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ChaosInjector: init" {
    const ci = ChaosInjector.init(42);
    try std.testing.expect(ci.intensity == 50);
    try std.testing.expect(ci.injection_count == 0);
}

test "ChaosInjector: setIntensity" {
    var ci = ChaosInjector.init(42);
    ci.setIntensity(75);
    try std.testing.expect(ci.currentIntensity() == 75);
}

test "ChaosInjector: setIntensity clamps to 100" {
    var ci = ChaosInjector.init(42);
    ci.setIntensity(200);
    try std.testing.expect(ci.currentIntensity() == 100);
}

test "ChaosInjector: chaoticValue is deterministic" {
    var ci1 = ChaosInjector.init(42);
    var ci2 = ChaosInjector.init(42);
    try std.testing.expect(ci1.chaoticValue() == ci2.chaoticValue());
}

test "ChaosInjector: chaoticValue changes state" {
    var ci = ChaosInjector.init(42);
    const v1 = ci.chaoticValue();
    const v2 = ci.chaoticValue();
    try std.testing.expect(v1 != v2);
}

test "ChaosInjector: chaoticChannel is 0-6" {
    var ci = ChaosInjector.init(42);
    for (0..100) |_| {
        const ch = ci.chaoticChannel();
        try std.testing.expect(ch < 7);
    }
}

test "ChaosInjector: injectionCount" {
    var ci = ChaosInjector.init(42);
    _ = ci.chaoticValue();
    _ = ci.chaoticValue();
    _ = ci.chaoticValue();
    try std.testing.expect(ci.injectionCount() == 3);
}

test "ChaosInjector: reset" {
    var ci = ChaosInjector.init(42);
    _ = ci.chaoticValue();
    _ = ci.chaoticValue();
    ci.reset();
    try std.testing.expect(ci.injectionCount() == 0);
}

test "ChaosInjector: shouldInject based on intensity" {
    var ci = ChaosInjector.init(42);
    ci.setIntensity(100);
    // With 100% intensity, should always inject
    // (depends on rng_state, but with 100% intensity, all values < 100)
    try std.testing.expect(ci.shouldInject());
}
