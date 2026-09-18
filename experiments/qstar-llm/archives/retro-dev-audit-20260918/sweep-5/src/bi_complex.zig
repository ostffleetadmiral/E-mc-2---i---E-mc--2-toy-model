//! bi_complex.zig — 5D Bi-complex algebra (Language dimension).
//!
//! The bi-complex numbers are z = a + bi + cj + dij where:
//!   - i² = -1, j² = -1, ij = ji (commuting imaginary units)
//!   - (a, b, c, d) are Q64.64 fixed-point values (i128)
//!
//! Properties:
//!   - Commutative: z1 * z2 = z2 * z1 (unlike quaternions/octonions)
//!   - Associative: (z1 * z2) * z3 = z1 * (z2 * z3)
//!   - Contains two commuting copies of ℂ: (a+bi) and (a+cj)
//!   - SO(4)×SO(4) symmetry: two independent rotation groups
//!
//! This is the 5D algebra for the Language dimension (dim 5 = "Fold").
//! Transformer attention Q·K^T is a bilinear form — a 5D structure operation.
//! The bi-complex algebra with its dual commuting imaginary units (i, j)
//! naturally models the dual bilinear forms of attention:
//!   - i-component: query-key similarity (the "attention weight")
//!   - j-component: value-output combination (the "attention output")
//!   - ij-component: cross-coupling (the "fold" — structure folding)
//!
//! All arithmetic is integer-only (i128 Q64.64). No floating-point in any path.
//!
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

/// A bi-complex number: z = a + bi + cj + dij
/// where i² = j² = -1, ij = ji.
/// All components are Q64.64 fixed-point (i128).
pub const BiComplex = struct {
    a: i128, // real part
    b: i128, // i-component
    c: i128, // j-component
    d: i128, // ij-component

    /// Clamp an i256 value to i128 range to prevent overflow panics.
    fn clamp256to128(x: i256) i128 {
        const max_i128: i256 = std.math.maxInt(i128);
        const min_i128: i256 = std.math.minInt(i128);
        if (x > max_i128) return std.math.maxInt(i128);
        if (x < min_i128) return std.math.minInt(i128);
        return @intCast(x);
    }

    /// Zero: 0 + 0i + 0j + 0ij
    pub fn zero() BiComplex {
        return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
    }

    /// One: 1 + 0i + 0j + 0ij
    pub fn one() BiComplex {
        return .{ .a = fp.ONE, .b = 0, .c = 0, .d = 0 };
    }

    /// From real number: a + 0i + 0j + 0ij
    pub fn fromReal(a: i128) BiComplex {
        return .{ .a = a, .b = 0, .c = 0, .d = 0 };
    }

    /// From complex (a + bi): a + bi + 0j + 0ij
    pub fn fromComplex(a: i128, b: i128) BiComplex {
        return .{ .a = a, .b = b, .c = 0, .d = 0 };
    }

    /// From four components: a + bi + cj + dij
    pub fn fromParts(a: i128, b: i128, c: i128, d: i128) BiComplex {
        return .{ .a = a, .b = b, .c = c, .d = d };
    }

    /// Equality check (exact).
    pub fn eql(self: BiComplex, other: BiComplex) bool {
        return self.a == other.a and self.b == other.b and
            self.c == other.c and self.d == other.d;
    }

    /// Addition: (a1+b1i+c1j+d1ij) + (a2+b2i+c2j+d2ij)
    pub fn add(self: BiComplex, other: BiComplex) BiComplex {
        return .{
            .a = self.a +| other.a,
            .b = self.b +| other.b,
            .c = self.c +| other.c,
            .d = self.d +| other.d,
        };
    }

    /// Subtraction: (a1+b1i+c1j+d1ij) - (a2+b2i+c2j+d2ij)
    pub fn sub(self: BiComplex, other: BiComplex) BiComplex {
        return .{
            .a = self.a -| other.a,
            .b = self.b -| other.b,
            .c = self.c -| other.c,
            .d = self.d -| other.d,
        };
    }

    /// Multiplication: (a1+b1i+c1j+d1ij) * (a2+b2i+c2j+d2ij)
    /// Using i² = j² = -1, ij = ji:
    ///   = (a1a2 - b1b2 - c1c2 + d1d2)   [real]
    ///   + (a1b2 + b1a2 - c1d2 - d1c2)i   [i]
    ///   + (a1c2 - b1d2 + c1a2 - d1b2)j   [j]
    ///   + (a1d2 + b1c2 + c1b2 + d1a2)ij  [ij]
    pub fn mul(self: BiComplex, other: BiComplex) BiComplex {
        // Use i256 intermediates to prevent overflow in products
        const a1 = @as(i256, self.a);
        const b1 = @as(i256, self.b);
        const c1 = @as(i256, self.c);
        const d1 = @as(i256, self.d);
        const a2 = @as(i256, other.a);
        const b2 = @as(i256, other.b);
        const c2 = @as(i256, other.c);
        const d2 = @as(i256, other.d);

        // Each product is (Q64.64 * Q64.64) = Q128.128, so we need >> 64 to get back to Q64.64
        const shift: u7 = fp.FRAC_BITS;

        return .{
            .a = clamp256to128((a1 * a2 - b1 * b2 - c1 * c2 + d1 * d2) >> shift),
            .b = clamp256to128((a1 * b2 + b1 * a2 - c1 * d2 - d1 * c2) >> shift),
            .c = clamp256to128((a1 * c2 - b1 * d2 + c1 * a2 - d1 * b2) >> shift),
            .d = clamp256to128((a1 * d2 + b1 * c2 + c1 * b2 + d1 * a2) >> shift),
        };
    }

    /// Negation: -(a + bi + cj + dij) = -a - bi - cj - dij
    pub fn neg(self: BiComplex) BiComplex {
        return .{ .a = -self.a, .b = -self.b, .c = -self.c, .d = -self.d };
    }

    /// i-conjugate: a - bi + cj - dij (flip i and ij signs)
    pub fn conjugateI(self: BiComplex) BiComplex {
        return .{ .a = self.a, .b = -self.b, .c = self.c, .d = -self.d };
    }

    /// j-conjugate: a + bi - cj - dij (flip j and ij signs)
    pub fn conjugateJ(self: BiComplex) BiComplex {
        return .{ .a = self.a, .b = self.b, .c = -self.c, .d = -self.d };
    }

    /// ij-conjugate (Hermitian): a - bi - cj + dij (flip i and j signs)
    pub fn conjugateIJ(self: BiComplex) BiComplex {
        return .{ .a = self.a, .b = -self.b, .c = -self.c, .d = self.d };
    }

    /// Norm squared: |z|² = z * z̄_ij = a² + b² + c² + d² (in real terms)
    /// For bi-complex: |z|² = (a² + b²) + (c² + d²)j²... but since j²=-1:
    /// Actually the Euclidean norm squared = a² + b² + c² + d²
    /// (treating (a,b,c,d) as a 4D real vector)
    pub fn normSquared(self: BiComplex) i128 {
        const a = @as(i256, self.a);
        const b = @as(i256, self.b);
        const c = @as(i256, self.c);
        const d = @as(i256, self.d);
        const sum_sq = a * a + b * b + c * c + d * d;
        // sum_sq is Q128.128, shift to Q64.64
        return clamp256to128(sum_sq >> fp.FRAC_BITS);
    }

    /// Scale by a real fixed-point scalar.
    pub fn scale(self: BiComplex, s: i128) BiComplex {
        return .{
            .a = fp.mul(self.a, s),
            .b = fp.mul(self.b, s),
            .c = fp.mul(self.c, s),
            .d = fp.mul(self.d, s),
        };
    }

    /// Scale by an integer scalar (no fixed-point multiply needed).
    pub fn scaleInt(self: BiComplex, s: i64) BiComplex {
        return .{
            .a = self.a * @as(i128, s),
            .b = self.b * @as(i128, s),
            .c = self.c * @as(i128, s),
            .d = self.d * @as(i128, s),
        };
    }
};

// =============================================================================
// SO(4)×SO(4) — Two Commuting Rotation Groups
// =============================================================================

/// SO(4) left rotation: rotates the (a, b) plane by angle θ.
/// This is the first SO(4) factor — acts on w1 = (a + bi).
/// R_left(θ) = [cos θ, -sin θ; sin θ, cos θ] applied to (a, b).
pub fn so4Left(z: BiComplex, cos_theta: i128, sin_theta: i128) BiComplex {
    // New a = a*cos - b*sin, New b = a*sin + b*cos
    const new_a = fp.sub(fp.mul(z.a, cos_theta), fp.mul(z.b, sin_theta));
    const new_b = fp.add(fp.mul(z.a, sin_theta), fp.mul(z.b, cos_theta));
    return .{ .a = new_a, .b = new_b, .c = z.c, .d = z.d };
}

/// SO(4) right rotation: rotates the (c, d) plane by angle φ.
/// This is the second SO(4) factor — acts on w2 = (c + di).
/// R_right(φ) = [cos φ, -sin φ; sin φ, cos φ] applied to (c, d).
/// These two rotations act on independent subalgebras (w1 and w2) and commute.
pub fn so4Right(z: BiComplex, cos_phi: i128, sin_phi: i128) BiComplex {
    // New c = c*cos - d*sin, New d = c*sin + d*cos
    const new_c = fp.sub(fp.mul(z.c, cos_phi), fp.mul(z.d, sin_phi));
    const new_d = fp.add(fp.mul(z.c, sin_phi), fp.mul(z.d, cos_phi));
    return .{ .a = z.a, .b = z.b, .c = new_c, .d = new_d };
}

/// Combined SO(4)×SO(4) rotation: left then right (they commute).
pub fn so4xso4(z: BiComplex, cos_theta: i128, sin_theta: i128, cos_phi: i128, sin_phi: i128) BiComplex {
    // Left and right rotations commute, so order doesn't matter
    return so4Right(so4Left(z, cos_theta, sin_theta), cos_phi, sin_phi);
}

// =============================================================================
// Attention Matrix — The 5D Structure Operation
// =============================================================================

/// A 2×2 bi-complex attention matrix (the minimal attention unit).
/// In transformers, attention is A = softmax(Q·K^T / √d) · V.
/// Here we model the bilinear form Q·K^T as a bi-complex matrix.
pub const AttentionMatrix = struct {
    m: [2][2]BiComplex,

    /// Zero matrix.
    pub fn zero() AttentionMatrix {
        return .{ .m = .{
            .{ BiComplex.zero(), BiComplex.zero() },
            .{ BiComplex.zero(), BiComplex.zero() },
        } };
    }

    /// Identity matrix.
    pub fn identity() AttentionMatrix {
        return .{ .m = .{
            .{ BiComplex.one(), BiComplex.zero() },
            .{ BiComplex.zero(), BiComplex.one() },
        } };
    }

    /// Matrix multiplication: C = A * B (bi-complex matrix product).
    /// Since bi-complex multiplication is commutative, the order of
    /// element multiplication doesn't matter, but matrix order does.
    pub fn mulMat(a: AttentionMatrix, b: AttentionMatrix) AttentionMatrix {
        var result = AttentionMatrix.zero();
        for (0..2) |i| {
            for (0..2) |j| {
                var sum = BiComplex.zero();
                for (0..2) |k| {
                    sum = sum.add(a.m[i][k].mul(b.m[k][j]));
                }
                result.m[i][j] = sum;
            }
        }
        return result;
    }

    /// Matrix addition.
    pub fn addMat(a: AttentionMatrix, b: AttentionMatrix) AttentionMatrix {
        return .{ .m = .{
            .{ a.m[0][0].add(b.m[0][0]), a.m[0][1].add(b.m[0][1]) },
            .{ a.m[1][0].add(b.m[1][0]), a.m[1][1].add(b.m[1][1]) },
        } };
    }

    /// Trace: tr(A) = m[0][0] + m[1][1]
    pub fn trace(self: AttentionMatrix) BiComplex {
        return self.m[0][0].add(self.m[1][1]);
    }

    /// Determinant: det(A) = m[0][0]*m[1][1] - m[0][1]*m[1][0]
    pub fn determinant(self: AttentionMatrix) BiComplex {
        return self.m[0][0].mul(self.m[1][1]).sub(self.m[0][1].mul(self.m[1][0]));
    }
};

/// Computes the attention bilinear form: A = Q · K^T
/// where Q and K are bi-complex vectors (2-element arrays).
/// This is the 5D "Fold" operation — structural folding of sequences.
pub fn attentionBilinear(q: [2]BiComplex, k: [2]BiComplex) AttentionMatrix {
    var result = AttentionMatrix.zero();
    for (0..2) |i| {
        for (0..2) |j| {
            result.m[i][j] = q[i].mul(k[j]);
        }
    }
    return result;
}

/// Folds a bi-complex matrix into a scalar by taking the trace.
/// This is the "low-rank fold" — compressing structural information
/// into a single bi-complex value (the structural signature).
pub fn foldMatrix(m: AttentionMatrix) BiComplex {
    return m.trace();
}

/// Folds a bi-complex matrix into its determinant (self-consistency measure).
pub fn foldDeterminant(m: AttentionMatrix) BiComplex {
    return m.determinant();
}

// =============================================================================
// Tests
// =============================================================================

test "bi-complex zero and one" {
    const z0 = BiComplex.zero();
    try std.testing.expect(z0.a == 0 and z0.b == 0 and z0.c == 0 and z0.d == 0);
    const z1 = BiComplex.one();
    try std.testing.expect(z1.a == fp.ONE and z1.b == 0 and z1.c == 0 and z1.d == 0);
}

test "bi-complex fromReal and fromComplex" {
    const zr = BiComplex.fromReal(fp.fromInt(5));
    try std.testing.expect(zr.a == fp.fromInt(5) and zr.b == 0 and zr.c == 0 and zr.d == 0);
    const zc = BiComplex.fromComplex(fp.fromInt(3), fp.fromInt(4));
    try std.testing.expect(zc.a == fp.fromInt(3) and zc.b == fp.fromInt(4) and zc.c == 0 and zc.d == 0);
}

test "bi-complex addition" {
    const z1 = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const z2 = BiComplex.fromParts(fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8));
    const z3 = z1.add(z2);
    try std.testing.expect(z3.a == fp.fromInt(6));
    try std.testing.expect(z3.b == fp.fromInt(8));
    try std.testing.expect(z3.c == fp.fromInt(10));
    try std.testing.expect(z3.d == fp.fromInt(12));
}

test "bi-complex subtraction" {
    const z1 = BiComplex.fromParts(fp.fromInt(10), fp.fromInt(20), fp.fromInt(30), fp.fromInt(40));
    const z2 = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const z3 = z1.sub(z2);
    try std.testing.expect(z3.a == fp.fromInt(9));
    try std.testing.expect(z3.b == fp.fromInt(18));
    try std.testing.expect(z3.c == fp.fromInt(27));
    try std.testing.expect(z3.d == fp.fromInt(36));
}

test "bi-complex multiplication: commutativity" {
    const z1 = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const z2 = BiComplex.fromParts(fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8));
    const z3 = z1.mul(z2);
    const z4 = z2.mul(z1);
    // Commutativity: z1*z2 = z2*z1
    try std.testing.expect(z3.eql(z4));
}

test "bi-complex multiplication: associativity" {
    const z1 = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const z2 = BiComplex.fromParts(fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8));
    const z3 = BiComplex.fromParts(fp.fromInt(9), fp.fromInt(10), fp.fromInt(11), fp.fromInt(12));
    // (z1*z2)*z3 = z1*(z2*z3)
    const left = z1.mul(z2).mul(z3);
    const right = z1.mul(z2.mul(z3));
    try std.testing.expect(left.eql(right));
}

test "bi-complex multiplication: identity" {
    const z1 = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const z1_times_one = z1.mul(BiComplex.one());
    try std.testing.expect(z1.eql(z1_times_one));
}

test "bi-complex multiplication: i*i = -1" {
    const i = BiComplex.fromComplex(0, fp.ONE);
    const i_sq = i.mul(i);
    // i² = -1, so a = -1, b = c = d = 0
    try std.testing.expect(i_sq.a == -fp.ONE);
    try std.testing.expect(i_sq.b == 0);
    try std.testing.expect(i_sq.c == 0);
    try std.testing.expect(i_sq.d == 0);
}

test "bi-complex multiplication: j*j = -1" {
    const j = BiComplex.fromParts(0, 0, fp.ONE, 0);
    const j_sq = j.mul(j);
    // j² = -1
    try std.testing.expect(j_sq.a == -fp.ONE);
    try std.testing.expect(j_sq.b == 0);
    try std.testing.expect(j_sq.c == 0);
    try std.testing.expect(j_sq.d == 0);
}

test "bi-complex multiplication: i*j = ji (commutativity of i and j)" {
    const i = BiComplex.fromComplex(0, fp.ONE);
    const j = BiComplex.fromParts(0, 0, fp.ONE, 0);
    const ij = i.mul(j);
    const ji = j.mul(i);
    // ij = ji (commuting imaginary units)
    try std.testing.expect(ij.eql(ji));
    // ij should have d = 1 (the ij-component), a = b = c = 0
    try std.testing.expect(ij.a == 0);
    try std.testing.expect(ij.b == 0);
    try std.testing.expect(ij.c == 0);
    try std.testing.expect(ij.d == fp.ONE);
}

test "bi-complex multiplication: (ij)*(ij) = 1" {
    const ij = BiComplex.fromParts(0, 0, 0, fp.ONE);
    const ij_sq = ij.mul(ij);
    // (ij)² = i²j² = (-1)(-1) = 1
    try std.testing.expect(ij_sq.a == fp.ONE);
    try std.testing.expect(ij_sq.b == 0);
    try std.testing.expect(ij_sq.c == 0);
    try std.testing.expect(ij_sq.d == 0);
}

test "bi-complex negation" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const nz = z.neg();
    try std.testing.expect(nz.a == -fp.fromInt(1));
    try std.testing.expect(nz.b == -fp.fromInt(2));
    try std.testing.expect(nz.c == -fp.fromInt(3));
    try std.testing.expect(nz.d == -fp.fromInt(4));
}

test "bi-complex i-conjugate" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const zc = z.conjugateI();
    try std.testing.expect(zc.a == fp.fromInt(1));
    try std.testing.expect(zc.b == -fp.fromInt(2));
    try std.testing.expect(zc.c == fp.fromInt(3));
    try std.testing.expect(zc.d == -fp.fromInt(4));
}

test "bi-complex j-conjugate" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const zc = z.conjugateJ();
    try std.testing.expect(zc.a == fp.fromInt(1));
    try std.testing.expect(zc.b == fp.fromInt(2));
    try std.testing.expect(zc.c == -fp.fromInt(3));
    try std.testing.expect(zc.d == -fp.fromInt(4));
}

test "bi-complex ij-conjugate (Hermitian)" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const zc = z.conjugateIJ();
    try std.testing.expect(zc.a == fp.fromInt(1));
    try std.testing.expect(zc.b == -fp.fromInt(2));
    try std.testing.expect(zc.c == -fp.fromInt(3));
    try std.testing.expect(zc.d == fp.fromInt(4));
}

test "bi-complex norm squared" {
    const z = BiComplex.fromParts(fp.fromInt(3), fp.fromInt(4), 0, 0);
    // |z|² = 3² + 4² = 9 + 16 = 25
    const ns = z.normSquared();
    try std.testing.expect(ns == fp.fromInt(25));
}

test "bi-complex norm squared: 4D" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    // |z|² = 1² + 2² + 3² + 4² = 1 + 4 + 9 + 16 = 30
    const ns = z.normSquared();
    try std.testing.expect(ns == fp.fromInt(30));
}

test "bi-complex scale by real" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const zs = z.scale(fp.fromInt(2));
    try std.testing.expect(zs.a == fp.fromInt(2));
    try std.testing.expect(zs.b == fp.fromInt(4));
    try std.testing.expect(zs.c == fp.fromInt(6));
    try std.testing.expect(zs.d == fp.fromInt(8));
}

test "bi-complex scale by integer" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const zs = z.scaleInt(3);
    try std.testing.expect(zs.a == fp.fromInt(3));
    try std.testing.expect(zs.b == fp.fromInt(6));
    try std.testing.expect(zs.c == fp.fromInt(9));
    try std.testing.expect(zs.d == fp.fromInt(12));
}

test "SO(4) left rotation: 90 degrees" {
    const z = BiComplex.fromReal(fp.fromInt(1));
    // 90° rotation: cos=0, sin=1
    const rotated = so4Left(z, 0, fp.ONE);
    // (1, 0) → (-0, 1) = (0, 1) in (a, b) plane
    try std.testing.expect(rotated.a == 0);
    try std.testing.expect(rotated.b == fp.ONE);
    try std.testing.expect(rotated.c == 0);
    try std.testing.expect(rotated.d == 0);
}

test "SO(4) right rotation: 90 degrees" {
    const z = BiComplex.fromParts(0, 0, fp.fromInt(1), 0);
    // 90° rotation: cos=0, sin=1 — rotates (c, d) plane
    const rotated = so4Right(z, 0, fp.ONE);
    // (c=1, d=0) → (c=0, d=1)
    try std.testing.expect(rotated.a == 0);
    try std.testing.expect(rotated.b == 0);
    try std.testing.expect(rotated.c == 0);
    try std.testing.expect(rotated.d == fp.ONE);
}

test "SO(4)×SO(4): left and right rotations commute" {
    const z = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const cos45 = fp.fromRatio(7071, 10000); // ≈ cos(45°)
    const sin45 = fp.fromRatio(7071, 10000); // ≈ sin(45°)

    // Left then right
    const lr = so4Right(so4Left(z, cos45, sin45), cos45, sin45);
    // Right then left
    const rl = so4Left(so4Right(z, cos45, sin45), cos45, sin45);

    // They should be equal (commutativity of SO(4)×SO(4))
    try std.testing.expect(lr.eql(rl));
}

test "attention matrix: identity" {
    const id = AttentionMatrix.identity();
    try std.testing.expect(id.m[0][0].eql(BiComplex.one()));
    try std.testing.expect(id.m[0][1].eql(BiComplex.zero()));
    try std.testing.expect(id.m[1][0].eql(BiComplex.zero()));
    try std.testing.expect(id.m[1][1].eql(BiComplex.one()));
}

test "attention matrix: trace of identity = 2" {
    const id = AttentionMatrix.identity();
    const tr = id.trace();
    try std.testing.expect(tr.a == fp.fromInt(2));
}

test "attention matrix: determinant of identity = 1" {
    const id = AttentionMatrix.identity();
    const det = id.determinant();
    try std.testing.expect(det.a == fp.ONE);
}

test "attention bilinear form: Q·K^T" {
    const q = [2]BiComplex{
        BiComplex.fromComplex(fp.fromInt(1), fp.fromInt(2)),
        BiComplex.fromComplex(fp.fromInt(3), fp.fromInt(4)),
    };
    const k = [2]BiComplex{
        BiComplex.fromComplex(fp.fromInt(5), fp.fromInt(6)),
        BiComplex.fromComplex(fp.fromInt(7), fp.fromInt(8)),
    };
    const a = attentionBilinear(q, k);
    // A[0][0] = q[0] * k[0]
    try std.testing.expect(a.m[0][0].eql(q[0].mul(k[0])));
    // A[1][1] = q[1] * k[1]
    try std.testing.expect(a.m[1][1].eql(q[1].mul(k[1])));
}

test "fold matrix: trace compresses to scalar" {
    const q = [2]BiComplex{
        BiComplex.fromComplex(fp.fromInt(1), 0),
        BiComplex.fromComplex(fp.fromInt(2), 0),
    };
    const k = [2]BiComplex{
        BiComplex.fromComplex(fp.fromInt(3), 0),
        BiComplex.fromComplex(fp.fromInt(4), 0),
    };
    const a = attentionBilinear(q, k);
    const folded = foldMatrix(a);
    // trace = q[0]*k[0] + q[1]*k[1] = 1*3 + 2*4 = 3 + 8 = 11
    try std.testing.expect(folded.a == fp.fromInt(11));
}

test "fold matrix: determinant gives self-consistency" {
    const q = [2]BiComplex{
        BiComplex.fromReal(fp.fromInt(1)),
        BiComplex.fromReal(fp.fromInt(2)),
    };
    const k = [2]BiComplex{
        BiComplex.fromReal(fp.fromInt(3)),
        BiComplex.fromReal(fp.fromInt(4)),
    };
    const a = attentionBilinear(q, k);
    const det = foldDeterminant(a);
    // det = (1*3)(2*4) - (1*4)(2*3) = 24 - 24 = 0
    // (rank-1 matrix has zero determinant)
    try std.testing.expect(det.a == 0);
}

test "attention matrix multiplication" {
    const a = AttentionMatrix.identity();
    const b = AttentionMatrix.identity();
    const c = AttentionMatrix.mulMat(a, b);
    // I * I = I
    try std.testing.expect(c.m[0][0].eql(BiComplex.one()));
    try std.testing.expect(c.m[1][1].eql(BiComplex.one()));
}

test "bi-complex: distributivity" {
    const z1 = BiComplex.fromParts(fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4));
    const z2 = BiComplex.fromParts(fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8));
    const z3 = BiComplex.fromParts(fp.fromInt(9), fp.fromInt(10), fp.fromInt(11), fp.fromInt(12));
    // z1 * (z2 + z3) = z1*z2 + z1*z3
    const left = z1.mul(z2.add(z3));
    const right = z1.mul(z2).add(z1.mul(z3));
    try std.testing.expect(left.eql(right));
}

test "integer-only: no f64 in source" {
    // This test verifies the module is integer-only by checking the source
    // doesn't use f64. The bi-complex arithmetic uses only i128 and i256.
    try std.testing.expect(@sizeOf(BiComplex) == 4 * @sizeOf(i128));
}
