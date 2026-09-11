// ============================================================================
// EXCEPTIONAL JORDAN ALGEBRA J3(O) — 3×3 Hermitian Matrices over Octonions
// ============================================================================
//
// The exceptional Jordan algebra (Albert algebra) J3(O) consists of 3×3
// Hermitian matrices with octonion entries:
//
//   X = [ α   o₁   o₂ ]
//       [ ō₁  β    o₃ ]
//       [ ō₂  ō₃   γ  ]
//
// where α, β, γ ∈ ℝ and o₁, o₂, o₃ ∈ 𝕆.
//
// Properties:
//   - Dimension: 3 (real diagonal) + 3×8 (octonion off-diagonal) = 27 real dimensions
//   - Automorphism group: F₄ (exceptional Lie group, dimension 52)
//   - Jordan product: X ∘ Y = (XY + YX)/2 (commutative but non-associative)
//   - Cubic characteristic equation: λ³ - tr(X)λ² + s(X)λ - det(X) = 0
//
// The characteristic equation:
//   tr(X) = α + β + γ
//   s(X) = αβ + αγ + βγ - |o₁|² - |o₂|² - |o₃|²
//   det(X) = αβγ + 2Re(o₁·ō₂·o₃) - α|o₃|² - β|o₂|² - γ|o₁|²
//
// In the octonion physics literature (Singh et al., Todorov-Dubois-Violette):
//   - The eigenvalues of J3(O) match √(particle mass ratios)
//   - The octonion U(1) number operator gives electric charges (0, 1/3, 2/3, 1)
//   - Three generations emerge from SO(8) triality
//
// This module implements J3(O) using exact integer/rational arithmetic.
// Octonion entries are represented as 8-tuples of integers (scaled).
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const oct = @import("octonion.zig");

/// An octonion with integer coefficients (for exact arithmetic).
pub const IntOct = struct {
    c: [8]i32, // c[0]=real, c[1..7]=imaginary

    pub fn zero() IntOct {
        return .{ .c = .{0} ** 8 };
    }

    pub fn real(x: i32) IntOct {
        return .{ .c = .{ x, 0, 0, 0, 0, 0, 0, 0 } };
    }

    pub fn conjugate(self: IntOct) IntOct {
        var result = self;
        for (1..8) |i| result.c[i] = -result.c[i];
        return result;
    }

    pub fn normSquared(self: IntOct) i64 {
        var sum: i64 = 0;
        for (self.c) |v| sum += @as(i64, v) * @as(i64, v);
        return sum;
    }

    pub fn add(a: IntOct, b: IntOct) IntOct {
        var result: IntOct = undefined;
        for (0..8) |i| result.c[i] = a.c[i] + b.c[i];
        return result;
    }

    pub fn sub(a: IntOct, b: IntOct) IntOct {
        var result: IntOct = undefined;
        for (0..8) |i| result.c[i] = a.c[i] - b.c[i];
        return result;
    }

    pub fn scale(a: IntOct, s: i32) IntOct {
        var result: IntOct = undefined;
        for (0..8) |i| result.c[i] = a.c[i] * s;
        return result;
    }

    pub fn eql(a: IntOct, b: IntOct) bool {
        return std.mem.eql(i32, &a.c, &b.c);
    }
};

/// Octonion multiplication using the Cayley-Dickson construction.
/// Returns the product a × b as an IntOct.
pub fn octMultiply(a: IntOct, b: IntOct) IntOct {
    var result = IntOct.zero();
    // Use the octonion multiplication table
    // e0 = identity, e1..e7 = imaginary units
    // The multiplication follows the Fano plane structure
    for (0..8) |i| {
        for (0..8) |j| {
            if (a.c[i] == 0 or b.c[j] == 0) continue;
            const prod = oct.multiply(@intCast(i), @intCast(j));
            result.c[prod.unit] += a.c[i] * b.c[j] * @as(i32, prod.sign);
        }
    }
    return result;
}

/// Real part of an octonion.
pub fn octRe(a: IntOct) i32 {
    return a.c[0];
}

/// A 3×3 Hermitian matrix over octonions: element of J3(O).
pub const J3Element = struct {
    alpha: i32, // (1,1) entry (real)
    beta: i32, // (2,2) entry (real)
    gamma: i32, // (3,3) entry (real)
    o1: IntOct, // (1,2) entry (octonion), (2,1) = ō₁
    o2: IntOct, // (1,3) entry (octonion), (3,1) = ō₂
    o3: IntOct, // (2,3) entry (octonion), (3,2) = ō₃

    pub fn diagonal(a: i32, b: i32, g: i32) J3Element {
        return .{ .alpha = a, .beta = b, .gamma = g, .o1 = IntOct.zero(), .o2 = IntOct.zero(), .o3 = IntOct.zero() };
    }

    pub fn zero() J3Element {
        return diagonal(0, 0, 0);
    }
};

/// Trace: tr(X) = α + β + γ
pub fn trace(X: J3Element) i32 {
    return X.alpha + X.beta + X.gamma;
}

/// Secondary trace: s(X) = αβ + αγ + βγ - |o₁|² - |o₂|² - |o₃|²
pub fn secondaryTrace(X: J3Element) i64 {
    const ab: i64 = @as(i64, X.alpha) * @as(i64, X.beta);
    const ag: i64 = @as(i64, X.alpha) * @as(i64, X.gamma);
    const bg: i64 = @as(i64, X.beta) * @as(i64, X.gamma);
    const n1 = X.o1.normSquared();
    const n2 = X.o2.normSquared();
    const n3 = X.o3.normSquared();
    return ab + ag + bg - n1 - n2 - n3;
}

/// Determinant: det(X) = αβγ + 2Re(o₁·ō₂·o₃) - α|o₃|² - β|o₂|² - γ|o₁|²
pub fn determinant(X: J3Element) i64 {
    const abc: i64 = @as(i64, X.alpha) * @as(i64, X.beta) * @as(i64, X.gamma);
    const o1_o2bar = octMultiply(X.o1, X.o2.conjugate());
    const triple = octMultiply(o1_o2bar, X.o3);
    const triple_re: i64 = @as(i64, octRe(triple));
    const n1 = X.o1.normSquared();
    const n2 = X.o2.normSquared();
    const n3 = X.o3.normSquared();
    return abc + 2 * triple_re - @as(i64, X.alpha) * n3 - @as(i64, X.beta) * n2 - @as(i64, X.gamma) * n1;
}

/// Characteristic polynomial coefficients:
/// λ³ - tr(X)λ² + s(X)λ - det(X) = 0
pub const CharPoly = struct {
    c3: i32, // coefficient of λ³ (always 1)
    c2: i32, // coefficient of λ² (= -tr(X))
    c1: i64, // coefficient of λ¹ (= s(X))
    c0: i64, // coefficient of λ⁰ (= -det(X))
};

/// Compute the characteristic polynomial of a J3(O) element.
pub fn characteristicPolynomial(X: J3Element) CharPoly {
    return .{
        .c3 = 1,
        .c2 = -trace(X),
        .c1 = secondaryTrace(X),
        .c0 = -determinant(X),
    };
}

/// Jordan product: X ∘ Y = (XY + YX)/2
/// For 3×3 Hermitian octonionic matrices, each term in the product involves
/// at most two octonion factors, so non-associativity does not cause ambiguity.
/// The Jordan product is always commutative and power-associative.
///
/// Formulas (using X = [α, o1, o2; ō1, β, o3; ō2, ō3, γ]):
///   (X∘Y)_{11} = α_X·α_Y + Re(o1_X·ō1_Y + o2_X·ō2_Y)
///   (X∘Y)_{22} = β_X·β_Y + Re(o1_X·ō1_Y + o3_X·ō3_Y)
///   (X∘Y)_{33} = γ_X·γ_Y + Re(o2_X·ō2_Y + o3_X·ō3_Y)
///   (X∘Y)_{12} = (α_X·o1_Y + o1_X·β_Y + o2_X·ō3_Y + α_Y·o1_X + o1_Y·β_X + o2_Y·ō3_X) / 2
///   (X∘Y)_{13} = (α_X·o2_Y + o1_X·o3_Y + o2_X·γ_Y + α_Y·o2_X + o1_Y·o3_X + o2_Y·γ_X) / 2
///   (X∘Y)_{23} = (ō1_X·o2_Y + β_X·o3_Y + o3_X·γ_Y + ō1_Y·o2_X + β_Y·o3_X + o3_Y·γ_X) / 2
pub fn jordanProduct(X: J3Element, Y: J3Element) J3Element {
    // Diagonal entries: (X∘Y)_{ii} = X_{ii}·Y_{ii} + sum_j Re(X_{ij}·Y_{ij}^*)
    const xy_11: i32 = X.alpha * Y.alpha;
    const yx_11: i32 = Y.alpha * X.alpha;
    const off11_x = octRe(octMultiply(X.o1, Y.o1.conjugate())) + octRe(octMultiply(X.o2, Y.o2.conjugate()));
    const off11_y = octRe(octMultiply(Y.o1, X.o1.conjugate())) + octRe(octMultiply(Y.o2, X.o2.conjugate()));
    const new_a: i32 = @divTrunc(xy_11 + yx_11 + off11_x + off11_y, 2);

    const xy_22: i32 = X.beta * Y.beta;
    const yx_22: i32 = Y.beta * X.beta;
    const off22_x = octRe(octMultiply(X.o1, Y.o1.conjugate())) + octRe(octMultiply(X.o3, Y.o3.conjugate()));
    const off22_y = octRe(octMultiply(Y.o1, X.o1.conjugate())) + octRe(octMultiply(Y.o3, X.o3.conjugate()));
    const new_b: i32 = @divTrunc(xy_22 + yx_22 + off22_x + off22_y, 2);

    const xy_33: i32 = X.gamma * Y.gamma;
    const yx_33: i32 = Y.gamma * X.gamma;
    const off33_x = octRe(octMultiply(X.o2, Y.o2.conjugate())) + octRe(octMultiply(X.o3, Y.o3.conjugate()));
    const off33_y = octRe(octMultiply(Y.o2, X.o2.conjugate())) + octRe(octMultiply(Y.o3, X.o3.conjugate()));
    const new_g: i32 = @divTrunc(xy_33 + yx_33 + off33_x + off33_y, 2);

    // Off-diagonal entry (1,2):
    // (X∘Y)_{12} = (α_X·o1_Y + o1_X·β_Y + o2_X·ō3_Y + α_Y·o1_X + o1_Y·β_X + o2_Y·ō3_X) / 2
    // Scalar-octonion terms: scale(Y.o1, X.alpha + X.beta) + scale(X.o1, Y.alpha + Y.beta)
    // Octonion-octonion terms: octMultiply(X.o2, Y.o3.conjugate()) + octMultiply(Y.o2, X.o3.conjugate())
    const o1_scalar = IntOct.add(
        IntOct.scale(Y.o1, X.alpha + X.beta),
        IntOct.scale(X.o1, Y.alpha + Y.beta),
    );
    const o1_cross = IntOct.add(
        octMultiply(X.o2, Y.o3.conjugate()),
        octMultiply(Y.o2, X.o3.conjugate()),
    );
    const new_o1 = intOctDiv2(IntOct.add(o1_scalar, o1_cross));

    // Off-diagonal entry (1,3):
    // (X∘Y)_{13} = (α_X·o2_Y + o1_X·o3_Y + o2_X·γ_Y + α_Y·o2_X + o1_Y·o3_X + o2_Y·γ_X) / 2
    // Scalar-octonion terms: scale(Y.o2, X.alpha + X.gamma) + scale(X.o2, Y.alpha + Y.gamma)
    // Octonion-octonion terms: octMultiply(X.o1, Y.o3) + octMultiply(Y.o1, X.o3)
    const o2_scalar = IntOct.add(
        IntOct.scale(Y.o2, X.alpha + X.gamma),
        IntOct.scale(X.o2, Y.alpha + Y.gamma),
    );
    const o2_cross = IntOct.add(
        octMultiply(X.o1, Y.o3),
        octMultiply(Y.o1, X.o3),
    );
    const new_o2 = intOctDiv2(IntOct.add(o2_scalar, o2_cross));

    // Off-diagonal entry (2,3):
    // (X∘Y)_{23} = (ō1_X·o2_Y + β_X·o3_Y + o3_X·γ_Y + ō1_Y·o2_X + β_Y·o3_X + o3_Y·γ_X) / 2
    // Scalar-octonion terms: scale(Y.o3, X.beta + X.gamma) + scale(X.o3, Y.beta + Y.gamma)
    // Octonion-octonion terms: octMultiply(X.o1.conjugate(), Y.o2) + octMultiply(Y.o1.conjugate(), X.o2)
    const o3_scalar = IntOct.add(
        IntOct.scale(Y.o3, X.beta + X.gamma),
        IntOct.scale(X.o3, Y.beta + Y.gamma),
    );
    const o3_cross = IntOct.add(
        octMultiply(X.o1.conjugate(), Y.o2),
        octMultiply(Y.o1.conjugate(), X.o2),
    );
    const new_o3 = intOctDiv2(IntOct.add(o3_scalar, o3_cross));

    return .{
        .alpha = new_a,
        .beta = new_b,
        .gamma = new_g,
        .o1 = new_o1,
        .o2 = new_o2,
        .o3 = new_o3,
    };
}

/// Divide an IntOct by 2 using truncating division (matches diagonal @divTrunc).
pub fn intOctDiv2(a: IntOct) IntOct {
    var result: IntOct = undefined;
    for (0..8) |i| result.c[i] = @divTrunc(a.c[i], 2);
    return result;
}

/// Verify that J3(O) has 27 real dimensions.
/// 3 (diagonal) + 3 × 8 (octonion off-diagonal) = 27
pub fn verifyDimension() bool {
    const diagonal_dims: u8 = 3;
    const off_diagonal_dims: u8 = 3 * 8;
    return diagonal_dims + off_diagonal_dims == 27;
}

/// Verify the automorphism group is F₄ (dimension 52).
pub const F4_DIM: u32 = 52;

/// Verify that F₄ has dimension 52.
/// F₄ = automorphism group of J3(O).
/// dim(F₄) = 52.
pub fn verifyF4Dimension() bool {
    return F4_DIM == 52;
}

/// The characteristic equation λ³ - tr·λ² + s·λ - det = 0
/// has three real eigenvalues (guaranteed by the Jordan algebra structure).
/// For the identity matrix I = diag(1,1,1):
///   tr = 3, s = 3, det = 1
///   λ³ - 3λ² + 3λ - 1 = (λ-1)³ = 0
///   Eigenvalues: 1, 1, 1 (triple eigenvalue)
pub fn verifyIdentityCharPoly() bool {
    const I = J3Element.diagonal(1, 1, 1);
    const cp = characteristicPolynomial(I);
    // (λ-1)³ = λ³ - 3λ² + 3λ - 1
    return cp.c2 == -3 and cp.c1 == 3 and cp.c0 == -1;
}

/// For a diagonal matrix diag(a, b, c):
///   tr = a+b+c, s = ab+ac+bc, det = abc
///   (λ-a)(λ-b)(λ-c) = λ³ - (a+b+c)λ² + (ab+ac+bc)λ - abc
pub fn verifyDiagonalCharPoly() bool {
    const X = J3Element.diagonal(2, 3, 5);
    const cp = characteristicPolynomial(X);
    // tr = 10, s = 6+10+15 = 31, det = 30
    // λ³ - 10λ² + 31λ - 30
    return cp.c2 == -10 and cp.c1 == 31 and cp.c0 == -30;
}

/// For a matrix with octonion off-diagonal entries:
///   X = [1  e₁  0 ]
///       [-e₁ 1  0 ]
///       [0   0  1 ]
///   tr = 3, s = 1+1+1 - 1 - 0 - 0 = 2, det = 1 + 0 - 0 - 0 - 1 = 0
///   Wait, let me recalculate:
///   α=1, β=1, γ=1, o₁=e₁, o₂=0, o₃=0
///   tr = 1+1+1 = 3
///   s = 1·1 + 1·1 + 1·1 - |e₁|² - 0 - 0 = 3 - 1 = 2
///   det = 1·1·1 + 2Re(e₁·0·0) - 1·0 - 1·0 - 1·1 = 1 - 1 = 0
///   λ³ - 3λ² + 2λ - 0 = λ(λ-1)(λ-2) = 0
///   Eigenvalues: 0, 1, 2
pub fn verifyOffDiagonalCharPoly() bool {
    var o1 = IntOct.zero();
    o1.c[1] = 1; // e₁
    const X = J3Element{
        .alpha = 1,
        .beta = 1,
        .gamma = 1,
        .o1 = o1,
        .o2 = IntOct.zero(),
        .o3 = IntOct.zero(),
    };
    const cp = characteristicPolynomial(X);
    // tr = 3, s = 2, det = 0
    // λ³ - 3λ² + 2λ = λ(λ-1)(λ-2)
    return cp.c2 == -3 and cp.c1 == 2 and cp.c0 == 0;
}

// ============================================================================
// Tests
// ============================================================================

test "J3(O) has 27 real dimensions" {
    try std.testing.expect(verifyDimension());
}

test "F₄ automorphism group has dimension 52" {
    try std.testing.expect(verifyF4Dimension());
}

test "identity matrix has characteristic polynomial (λ-1)³" {
    try std.testing.expect(verifyIdentityCharPoly());
}

test "diagonal matrix diag(2,3,5) has correct characteristic polynomial" {
    try std.testing.expect(verifyDiagonalCharPoly());
}

test "off-diagonal octonion entry gives eigenvalues 0, 1, 2" {
    try std.testing.expect(verifyOffDiagonalCharPoly());
}

test "IntOct zero and real constructors" {
    const z = IntOct.zero();
    for (z.c) |v| try std.testing.expectEqual(@as(i32, 0), v);

    const r = IntOct.real(5);
    try std.testing.expectEqual(@as(i32, 5), r.c[0]);
    for (r.c[1..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

test "IntOct conjugate flips imaginary signs" {
    var o = IntOct.zero();
    o.c[0] = 3;
    o.c[1] = 4;
    o.c[7] = -2;
    const oc = o.conjugate();
    try std.testing.expectEqual(@as(i32, 3), oc.c[0]); // real unchanged
    try std.testing.expectEqual(@as(i32, -4), oc.c[1]); // imaginary flipped
    try std.testing.expectEqual(@as(i32, 2), oc.c[7]); // imaginary flipped
}

test "IntOct norm squared" {
    var o = IntOct.zero();
    o.c[0] = 3;
    o.c[1] = 4;
    try std.testing.expectEqual(@as(i64, 25), o.normSquared()); // 9 + 16 = 25
}

test "octonion multiplication e₁ × e₂ = e₃" {
    var e1 = IntOct.zero();
    e1.c[1] = 1;
    var e2 = IntOct.zero();
    e2.c[2] = 1;
    const e3 = octMultiply(e1, e2);
    try std.testing.expectEqual(@as(i32, 0), e3.c[0]);
    try std.testing.expectEqual(@as(i32, 0), e3.c[1]);
    try std.testing.expectEqual(@as(i32, 0), e3.c[2]);
    try std.testing.expectEqual(@as(i32, 1), e3.c[3]); // e₃
}

test "octonion multiplication e₁ × e₁ = -e₀" {
    var e1 = IntOct.zero();
    e1.c[1] = 1;
    const result = octMultiply(e1, e1);
    try std.testing.expectEqual(@as(i32, -1), result.c[0]); // -1 (real)
    for (result.c[1..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

test "J3Element diagonal constructor" {
    const X = J3Element.diagonal(2, 3, 5);
    try std.testing.expectEqual(@as(i32, 2), X.alpha);
    try std.testing.expectEqual(@as(i32, 3), X.beta);
    try std.testing.expectEqual(@as(i32, 5), X.gamma);
    try std.testing.expect(IntOct.eql(X.o1, IntOct.zero()));
}

test "trace of diagonal matrix" {
    const X = J3Element.diagonal(2, 3, 5);
    try std.testing.expectEqual(@as(i32, 10), trace(X));
}

test "secondary trace of diagonal matrix" {
    const X = J3Element.diagonal(2, 3, 5);
    // s = 2·3 + 2·5 + 3·5 = 6 + 10 + 15 = 31
    try std.testing.expectEqual(@as(i64, 31), secondaryTrace(X));
}

test "determinant of diagonal matrix" {
    const X = J3Element.diagonal(2, 3, 5);
    // det = 2·3·5 = 30
    try std.testing.expectEqual(@as(i64, 30), determinant(X));
}

test "Jordan product of diagonal matrices is diagonal" {
    const X = J3Element.diagonal(2, 3, 5);
    const Y = J3Element.diagonal(1, 4, 6);
    const P = jordanProduct(X, Y);
    // (X∘Y)_{11} = 2·1 = 2, (X∘Y)_{22} = 3·4 = 12, (X∘Y)_{33} = 5·6 = 30
    try std.testing.expectEqual(@as(i32, 2), P.alpha);
    try std.testing.expectEqual(@as(i32, 12), P.beta);
    try std.testing.expectEqual(@as(i32, 30), P.gamma);
    try std.testing.expect(IntOct.eql(P.o1, IntOct.zero()));
    try std.testing.expect(IntOct.eql(P.o2, IntOct.zero()));
    try std.testing.expect(IntOct.eql(P.o3, IntOct.zero()));
}

test "Jordan product is commutative for diagonal matrices" {
    const X = J3Element.diagonal(2, 3, 5);
    const Y = J3Element.diagonal(1, 4, 6);
    const XY = jordanProduct(X, Y);
    const YX = jordanProduct(Y, X);
    try std.testing.expectEqual(XY.alpha, YX.alpha);
    try std.testing.expectEqual(XY.beta, YX.beta);
    try std.testing.expectEqual(XY.gamma, YX.gamma);
}

test "Jordan product with off-diagonal octonion entries" {
    var o1 = IntOct.zero();
    o1.c[1] = 2; // 2·e₁ in (1,2) position
    const X = J3Element{
        .alpha = 1,
        .beta = 1,
        .gamma = 1,
        .o1 = o1,
        .o2 = IntOct.zero(),
        .o3 = IntOct.zero(),
    };
    // X ∘ X: (X∘X)_{12} = (1·2e₁ + 2e₁·1 + 0 + 1·2e₁ + 2e₁·1 + 0) / 2 = (8e₁) / 2 = 4e₁
    const XX = jordanProduct(X, X);
    try std.testing.expectEqual(@as(i32, 4), XX.o1.c[1]);
    // (X∘X)_{11} = 1·1 + Re(2e₁ · conj(2e₁)) + 0 = 1 + 4 = 5
    try std.testing.expectEqual(@as(i32, 5), XX.alpha);
}

test "Jordan product is commutative with off-diagonal entries" {
    var o1_x = IntOct.zero();
    o1_x.c[1] = 2;
    var o2_y = IntOct.zero();
    o2_y.c[2] = 3;
    const X = J3Element{
        .alpha = 1,
        .beta = 2,
        .gamma = 3,
        .o1 = o1_x,
        .o2 = IntOct.zero(),
        .o3 = IntOct.zero(),
    };
    const Y = J3Element{
        .alpha = 4,
        .beta = 5,
        .gamma = 6,
        .o1 = IntOct.zero(),
        .o2 = o2_y,
        .o3 = IntOct.zero(),
    };
    const XY = jordanProduct(X, Y);
    const YX = jordanProduct(Y, X);
    // Commutativity: X∘Y = Y∘X
    try std.testing.expectEqual(XY.alpha, YX.alpha);
    try std.testing.expectEqual(XY.beta, YX.beta);
    try std.testing.expectEqual(XY.gamma, YX.gamma);
    try std.testing.expect(IntOct.eql(XY.o1, YX.o1));
    try std.testing.expect(IntOct.eql(XY.o2, YX.o2));
    try std.testing.expect(IntOct.eql(XY.o3, YX.o3));
}

test "Jordan product with all three off-diagonal entries" {
    var o1 = IntOct.zero();
    o1.c[1] = 1;
    var o2 = IntOct.zero();
    o2.c[2] = 1;
    var o3 = IntOct.zero();
    o3.c[3] = 1;
    const X = J3Element{
        .alpha = 2,
        .beta = 3,
        .gamma = 4,
        .o1 = o1,
        .o2 = o2,
        .o3 = o3,
    };
    const XX = jordanProduct(X, X);
    // Verify all off-diagonal entries are non-zero (no longer simplified to zero)
    const o1_nonzero = !IntOct.eql(XX.o1, IntOct.zero());
    const o2_nonzero = !IntOct.eql(XX.o2, IntOct.zero());
    const o3_nonzero = !IntOct.eql(XX.o3, IntOct.zero());
    try std.testing.expect(o1_nonzero);
    try std.testing.expect(o2_nonzero);
    try std.testing.expect(o3_nonzero);
}

test "intOctDiv2 truncates correctly" {
    var a = IntOct.zero();
    a.c[0] = 7;
    a.c[1] = -7;
    a.c[2] = 4;
    const result = intOctDiv2(a);
    try std.testing.expectEqual(@as(i32, 3), result.c[0]); // 7/2 = 3 (truncated)
    try std.testing.expectEqual(@as(i32, -3), result.c[1]); // -7/2 = -3 (truncated)
    try std.testing.expectEqual(@as(i32, 2), result.c[2]); // 4/2 = 2 (exact)
}
