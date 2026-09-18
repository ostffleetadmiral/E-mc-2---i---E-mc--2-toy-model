//! dim_8d_frequency.zig — 8D Frequency (Dual numbers dimension).
//!
//! The 8D dimension handles dual number arithmetic, φ-cooling, and lattice scaling.
//! Algebra: Dual numbers (U(1) frequency scaling).
//! Purpose: φ-cooling schedule, lattice level scaling (8^s), frequency scaling.
//!
//! Dual numbers: z = a + bε where ε² = 0.
//! All arithmetic is integer-only (i128 Q64.64). No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

/// A dual number: z = a + bε where ε² = 0.
pub const Dual = struct {
    a: i128, // real part
    b: i128, // dual part (ε)

    pub fn zero() Dual {
        return .{ .a = 0, .b = 0 };
    }

    pub fn one() Dual {
        return .{ .a = fp.ONE, .b = 0 };
    }

    pub fn fromReal(a: i128) Dual {
        return .{ .a = a, .b = 0 };
    }

    pub fn fromParts(a: i128, b: i128) Dual {
        return .{ .a = a, .b = b };
    }

    pub fn add(self: Dual, other: Dual) Dual {
        return .{ .a = self.a + other.a, .b = self.b + other.b };
    }

    pub fn sub(self: Dual, other: Dual) Dual {
        return .{ .a = self.a - other.a, .b = self.b - other.b };
    }

    /// Multiplication: (a1+b1ε)(a2+b2ε) = a1a2 + (a1b2+b1a2)ε (since ε²=0)
    pub fn mul(self: Dual, other: Dual) Dual {
        const a1 = @as(i256, self.a);
        const b1 = @as(i256, self.b);
        const a2 = @as(i256, other.a);
        const b2 = @as(i256, other.b);
        return .{
            .a = @intCast(((a1 * a2) >> fp.FRAC_BITS)),
            .b = @intCast(((a1 * b2 + b1 * a2) >> fp.FRAC_BITS)),
        };
    }
};

/// The 8D frequency scaler — φ-cooling and lattice level scaling.
pub const FrequencyScaler = struct {
    /// Base temperature (Q64.64 fixed-point).
    base_temp: i128,
    /// Current lattice level.
    level: u8,
    /// φ (golden ratio) as Q64.64 fixed-point: φ = (1+√5)/2 ≈ 1.618
    phi: i128,

    pub fn init(base_temp: i128) FrequencyScaler {
        // φ ≈ 1.618033988749895
        // Using fromRatio for integer-only computation
        return .{
            .base_temp = base_temp,
            .level = 0,
            .phi = fp.fromRatio(1618, 1000),
        };
    }

    /// φ-cooling: T(level) = T₀ × φ^(-level)
    /// Each level reduces temperature by factor φ.
    pub fn cool(self: *FrequencyScaler) i128 {
        var temp = self.base_temp;
        for (0..self.level) |_| {
            temp = fp.div(temp, self.phi);
        }
        return temp;
    }

    /// Advances to the next lattice level.
    pub fn advanceLevel(self: *FrequencyScaler) void {
        self.level += 1;
    }

    /// Returns the current lattice level.
    pub fn currentLevel(self: FrequencyScaler) u8 {
        return self.level;
    }

    /// Returns the lattice edge at the current level: 8^level
    pub fn latticeEdge(self: FrequencyScaler) u64 {
        var edge: u64 = 1;
        for (0..self.level) |_| {
            edge *= 8;
        }
        return edge;
    }

    /// Resets to level 0.
    pub fn reset(self: *FrequencyScaler) void {
        self.level = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Dual: zero and one" {
    const z0 = Dual.zero();
    try std.testing.expect(z0.a == 0 and z0.b == 0);
    const z1 = Dual.one();
    try std.testing.expect(z1.a == fp.ONE and z1.b == 0);
}

test "Dual: fromReal and fromParts" {
    const zr = Dual.fromReal(fp.fromInt(5));
    try std.testing.expect(zr.a == fp.fromInt(5) and zr.b == 0);
    const zp = Dual.fromParts(fp.fromInt(3), fp.fromInt(4));
    try std.testing.expect(zp.a == fp.fromInt(3) and zp.b == fp.fromInt(4));
}

test "Dual: addition" {
    const z1 = Dual.fromParts(fp.fromInt(1), fp.fromInt(2));
    const z2 = Dual.fromParts(fp.fromInt(3), fp.fromInt(4));
    const z3 = z1.add(z2);
    try std.testing.expect(z3.a == fp.fromInt(4));
    try std.testing.expect(z3.b == fp.fromInt(6));
}

test "Dual: multiplication" {
    const z1 = Dual.fromParts(fp.fromInt(1), fp.fromInt(2));
    const z2 = Dual.fromParts(fp.fromInt(3), fp.fromInt(4));
    const z3 = z1.mul(z2);
    // (1+2ε)(3+4ε) = 3 + (4+6)ε = 3 + 10ε (since ε²=0)
    try std.testing.expect(z3.a == fp.fromInt(3));
    try std.testing.expect(z3.b == fp.fromInt(10));
}

test "Dual: ε² = 0" {
    const eps = Dual.fromParts(0, fp.ONE);
    const eps_sq = eps.mul(eps);
    try std.testing.expect(eps_sq.a == 0);
    try std.testing.expect(eps_sq.b == 0);
}

test "FrequencyScaler: init" {
    const fs = FrequencyScaler.init(fp.fromInt(100));
    try std.testing.expect(fs.base_temp == fp.fromInt(100));
    try std.testing.expect(fs.level == 0);
}

test "FrequencyScaler: cool at level 0" {
    var fs = FrequencyScaler.init(fp.fromInt(100));
    try std.testing.expect(fs.cool() == fp.fromInt(100));
}

test "FrequencyScaler: advanceLevel" {
    var fs = FrequencyScaler.init(fp.fromInt(100));
    fs.advanceLevel();
    try std.testing.expect(fs.currentLevel() == 1);
}

test "FrequencyScaler: latticeEdge" {
    const fs = FrequencyScaler.init(fp.fromInt(100));
    try std.testing.expect(fs.latticeEdge() == 1);
}

test "FrequencyScaler: reset" {
    var fs = FrequencyScaler.init(fp.fromInt(100));
    fs.advanceLevel();
    fs.advanceLevel();
    fs.reset();
    try std.testing.expect(fs.currentLevel() == 0);
}
