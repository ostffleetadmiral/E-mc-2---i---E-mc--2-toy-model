//! dim_2d_complex.zig — 2D Complex (Plane/Complex numbers dimension).
//!
//! The 2D dimension handles complex arithmetic and token embeddings.
//! Algebra: Complex numbers (SU(2) weak force copy 1).
//! Purpose: Token embedding (real + imaginary), complex arithmetic.
//!
//! All arithmetic is integer-only (i128 Q64.64). No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

/// A complex number: z = a + bi where i² = -1.
/// Components are Q64.64 fixed-point (i128).
pub const Complex = struct {
    a: i128, // real part
    b: i128, // imaginary part

    pub fn zero() Complex {
        return .{ .a = 0, .b = 0 };
    }

    pub fn one() Complex {
        return .{ .a = fp.ONE, .b = 0 };
    }

    pub fn fromReal(a: i128) Complex {
        return .{ .a = a, .b = 0 };
    }

    pub fn fromParts(a: i128, b: i128) Complex {
        return .{ .a = a, .b = b };
    }

    pub fn eql(self: Complex, other: Complex) bool {
        return self.a == other.a and self.b == other.b;
    }

    pub fn add(self: Complex, other: Complex) Complex {
        return .{ .a = self.a + other.a, .b = self.b + other.b };
    }

    pub fn sub(self: Complex, other: Complex) Complex {
        return .{ .a = self.a - other.a, .b = self.b - other.b };
    }

    /// Multiplication: (a1+b1i)(a2+b2i) = (a1a2-b1b2) + (a1b2+b1a2)i
    pub fn mul(self: Complex, other: Complex) Complex {
        const a1 = @as(i256, self.a); const b1 = @as(i256, self.b);
        const a2 = @as(i256, other.a); const b2 = @as(i256, other.b);
        return .{
            .a = @intCast(((a1 * a2 - b1 * b2) >> fp.FRAC_BITS)),
            .b = @intCast(((a1 * b2 + b1 * a2) >> fp.FRAC_BITS)),
        };
    }

    pub fn conjugate(self: Complex) Complex {
        return .{ .a = self.a, .b = -self.b };
    }

    pub fn normSquared(self: Complex) i128 {
        const a = @as(i256, self.a); const b = @as(i256, self.b);
        return @intCast(((a * a + b * b) >> fp.FRAC_BITS));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Complex: zero and one" {
    const z0 = Complex.zero();
    try std.testing.expect(z0.a == 0 and z0.b == 0);
    const z1 = Complex.one();
    try std.testing.expect(z1.a == fp.ONE and z1.b == 0);
}

test "Complex: fromReal and fromParts" {
    const zr = Complex.fromReal(fp.fromInt(5));
    try std.testing.expect(zr.a == fp.fromInt(5) and zr.b == 0);
    const zp = Complex.fromParts(fp.fromInt(3), fp.fromInt(4));
    try std.testing.expect(zp.a == fp.fromInt(3) and zp.b == fp.fromInt(4));
}

test "Complex: addition" {
    const z1 = Complex.fromParts(fp.fromInt(1), fp.fromInt(2));
    const z2 = Complex.fromParts(fp.fromInt(3), fp.fromInt(4));
    const z3 = z1.add(z2);
    try std.testing.expect(z3.a == fp.fromInt(4));
    try std.testing.expect(z3.b == fp.fromInt(6));
}

test "Complex: subtraction" {
    const z1 = Complex.fromParts(fp.fromInt(10), fp.fromInt(20));
    const z2 = Complex.fromParts(fp.fromInt(1), fp.fromInt(2));
    const z3 = z1.sub(z2);
    try std.testing.expect(z3.a == fp.fromInt(9));
    try std.testing.expect(z3.b == fp.fromInt(18));
}

test "Complex: multiplication" {
    const z1 = Complex.fromParts(fp.fromInt(1), fp.fromInt(2));
    const z2 = Complex.fromParts(fp.fromInt(3), fp.fromInt(4));
    const z3 = z1.mul(z2);
    // (1+2i)(3+4i) = 3 + 4i + 6i + 8i² = 3 - 8 + 10i = -5 + 10i
    try std.testing.expect(z3.a == fp.fromInt(-5));
    try std.testing.expect(z3.b == fp.fromInt(10));
}

test "Complex: i*i = -1" {
    const i = Complex.fromParts(0, fp.ONE);
    const i_sq = i.mul(i);
    try std.testing.expect(i_sq.a == -fp.ONE);
    try std.testing.expect(i_sq.b == 0);
}

test "Complex: conjugate" {
    const z = Complex.fromParts(fp.fromInt(3), fp.fromInt(4));
    const zc = z.conjugate();
    try std.testing.expect(zc.a == fp.fromInt(3));
    try std.testing.expect(zc.b == -fp.fromInt(4));
}

test "Complex: normSquared" {
    const z = Complex.fromParts(fp.fromInt(3), fp.fromInt(4));
    // |z|² = 3² + 4² = 9 + 16 = 25
    try std.testing.expect(z.normSquared() == fp.fromInt(25));
}

test "Complex: commutativity" {
    const z1 = Complex.fromParts(fp.fromInt(1), fp.fromInt(2));
    const z2 = Complex.fromParts(fp.fromInt(3), fp.fromInt(4));
    try std.testing.expect(z1.mul(z2).eql(z2.mul(z1)));
}
