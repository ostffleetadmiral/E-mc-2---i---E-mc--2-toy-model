//! dim_4d_rotation.zig — 4D Rotation (Quaternion dimension).
//!
//! The 4D dimension handles quaternion rotation, Möbius twist, and boundary reflection.
//! Algebra: Quaternions (SO(5)=Sp(2)), quaternion rotation.
//! Purpose: Rotation operations, Möbius twist, boundary reflection.
//!
//! All arithmetic is integer-only (i128 Q64.64). No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

/// A quaternion: q = a + bi + cj + dk where i²=j²=k²=ijk=-1.
/// Components are Q64.64 fixed-point (i128).
pub const Quaternion = struct {
    a: i128, // real part
    b: i128, // i-component
    c: i128, // j-component
    d: i128, // k-component

    pub fn zero() Quaternion {
        return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
    }

    pub fn one() Quaternion {
        return .{ .a = fp.ONE, .b = 0, .c = 0, .d = 0 };
    }

    pub fn fromReal(a: i128) Quaternion {
        return .{ .a = a, .b = 0, .c = 0, .d = 0 };
    }

    pub fn fromParts(a: i128, b: i128, c: i128, d: i128) Quaternion {
        return .{ .a = a, .b = b, .c = c, .d = d };
    }

    pub fn eql(self: Quaternion, other: Quaternion) bool {
        return self.a == other.a and self.b == other.b and self.c == other.c and self.d == other.d;
    }

    pub fn add(self: Quaternion, other: Quaternion) Quaternion {
        return .{ .a = self.a + other.a, .b = self.b + other.b, .c = self.c + other.c, .d = self.d + other.d };
    }

    pub fn sub(self: Quaternion, other: Quaternion) Quaternion {
        return .{ .a = self.a - other.a, .b = self.b - other.b, .c = self.c - other.c, .d = self.d - other.d };
    }

    /// Multiplication: q1 * q2 (NON-commutative for quaternions).
    /// i²=j²=k²=ijk=-1, ij=k, ji=-k, jk=i, kj=-i, ki=j, ik=-j
    pub fn mul(self: Quaternion, other: Quaternion) Quaternion {
        const a1 = @as(i256, self.a); const b1 = @as(i256, self.b);
        const c1 = @as(i256, self.c); const d1 = @as(i256, self.d);
        const a2 = @as(i256, other.a); const b2 = @as(i256, other.b);
        const c2 = @as(i256, other.c); const d2 = @as(i256, other.d);
        const shift: u7 = fp.FRAC_BITS;
        return .{
            .a = @intCast(((a1*a2 - b1*b2 - c1*c2 - d1*d2) >> shift)),
            .b = @intCast(((a1*b2 + b1*a2 + c1*d2 - d1*c2) >> shift)),
            .c = @intCast(((a1*c2 - b1*d2 + c1*a2 + d1*b2) >> shift)),
            .d = @intCast(((a1*d2 + b1*c2 - c1*b2 + d1*a2) >> shift)),
        };
    }

    pub fn conjugate(self: Quaternion) Quaternion {
        return .{ .a = self.a, .b = -self.b, .c = -self.c, .d = -self.d };
    }

    pub fn normSquared(self: Quaternion) i128 {
        const a = @as(i256, self.a); const b = @as(i256, self.b);
        const c = @as(i256, self.c); const d = @as(i256, self.d);
        return @intCast(((a*a + b*b + c*c + d*d) >> fp.FRAC_BITS));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Quaternion: zero and one" {
    const q0 = Quaternion.zero();
    try std.testing.expect(q0.a == 0 and q0.b == 0 and q0.c == 0 and q0.d == 0);
    const q1 = Quaternion.one();
    try std.testing.expect(q1.a == fp.ONE and q1.b == 0 and q1.c == 0 and q1.d == 0);
}

test "Quaternion: fromReal and fromParts" {
    const qr = Quaternion.fromReal(fp.fromInt(5));
    try std.testing.expect(qr.a == fp.fromInt(5));
    const qp = Quaternion.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    try std.testing.expect(qp.a == fp.fromInt(1));
    try std.testing.expect(qp.b == fp.fromInt(2));
    try std.testing.expect(qp.c == fp.fromInt(3));
    try std.testing.expect(qp.d == fp.fromInt(4));
}

test "Quaternion: addition" {
    const q1 = Quaternion.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const q2 = Quaternion.fromParts(fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8));
    const q3 = q1.add(q2);
    try std.testing.expect(q3.a == fp.fromInt(6));
    try std.testing.expect(q3.b == fp.fromInt(8));
    try std.testing.expect(q3.c == fp.fromInt(10));
    try std.testing.expect(q3.d == fp.fromInt(12));
}

test "Quaternion: i*i = -1" {
    const i = Quaternion.fromParts(0, fp.ONE, 0, 0);
    const i_sq = i.mul(i);
    try std.testing.expect(i_sq.a == -fp.ONE);
    try std.testing.expect(i_sq.b == 0);
    try std.testing.expect(i_sq.c == 0);
    try std.testing.expect(i_sq.d == 0);
}

test "Quaternion: j*j = -1" {
    const j = Quaternion.fromParts(0, 0, fp.ONE, 0);
    const j_sq = j.mul(j);
    try std.testing.expect(j_sq.a == -fp.ONE);
}

test "Quaternion: k*k = -1" {
    const k = Quaternion.fromParts(0, 0, 0, fp.ONE);
    const k_sq = k.mul(k);
    try std.testing.expect(k_sq.a == -fp.ONE);
}

test "Quaternion: i*j = k (non-commutative)" {
    const i = Quaternion.fromParts(0, fp.ONE, 0, 0);
    const j = Quaternion.fromParts(0, 0, fp.ONE, 0);
    const ij = i.mul(j);
    try std.testing.expect(ij.d == fp.ONE); // k-component
    // j*i = -k (non-commutative)
    const ji = j.mul(i);
    try std.testing.expect(ji.d == -fp.ONE);
}

test "Quaternion: NON-commutativity" {
    const q1 = Quaternion.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const q2 = Quaternion.fromParts(fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8));
    const q1q2 = q1.mul(q2);
    const q2q1 = q2.mul(q1);
    // Quaternions are NON-commutative: q1*q2 ≠ q2*q1
    try std.testing.expect(!q1q2.eql(q2q1));
}

test "Quaternion: conjugate" {
    const q = Quaternion.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const qc = q.conjugate();
    try std.testing.expect(qc.a == fp.fromInt(1));
    try std.testing.expect(qc.b == -fp.fromInt(2));
    try std.testing.expect(qc.c == -fp.fromInt(3));
    try std.testing.expect(qc.d == -fp.fromInt(4));
}

test "Quaternion: normSquared" {
    const q = Quaternion.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    // |q|² = 1 + 4 + 9 + 16 = 30
    try std.testing.expect(q.normSquared() == fp.fromInt(30));
}

test "Quaternion: identity multiplication" {
    const q = Quaternion.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const q_times_one = q.mul(Quaternion.one());
    try std.testing.expect(q.eql(q_times_one));
}
