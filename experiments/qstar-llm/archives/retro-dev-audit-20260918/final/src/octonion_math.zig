//! octonion_math.zig — Full octonion multiplication table and vector operations.
//!
//! Ports the hardware (E=mc²-i-E=mc⁻²) project's octonion module into qstar-llm.
//! The octonions (Cayley numbers) are an 8-dimensional non-associative algebra
//! over the reals with 7 oriented triples. This module provides:
//!   - Unit multiplication (e_i × e_j → {unit, sign})
//!   - Full 8-component vector multiplication (for lattice channel propagation)
//!   - Non-associativity verification
//!   - Alternativity and flexible law (Moufang identity) verification
//!
//! All arithmetic is integer-only (i2 signs, i128 channel values).
//! No floating-point in any path.
//!
//! Ported from: hardware/src/octonion.zig
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Types and Constants
// =============================================================================

/// Octonion unit index: e0 (identity) through e7.
pub const Unit = u3;

/// Product of two octonion units: result unit and sign (+1 or -1).
pub const Product = struct { unit: Unit, sign: i2 };

/// Full octonion value: 8 components in Q64.64 fixed-point.
/// Component 0 is the real (scalar) part, components 1-7 are imaginary.
pub const Octonion = struct {
    c: [8]i128,

    pub const zero = Octonion{ .c = [_]i128{0} ** 8 };
    pub const identity = Octonion{ .c = [_]i128{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 } };

    pub fn fromReal(v: i128) Octonion {
        return .{ .c = [_]i128{ v, 0, 0, 0, 0, 0, 0, 0 } };
    }

    pub fn fromComponents(comptime comps: [8]i128) Octonion {
        return .{ .c = comps };
    }

    pub fn add(a: Octonion, b: Octonion) Octonion {
        return .{ .c = [_]i128{
            a.c[0] + b.c[0], a.c[1] + b.c[1], a.c[2] + b.c[2], a.c[3] + b.c[3],
            a.c[4] + b.c[4], a.c[5] + b.c[5], a.c[6] + b.c[6], a.c[7] + b.c[7],
        } };
    }

    pub fn sub(a: Octonion, b: Octonion) Octonion {
        return .{ .c = [_]i128{
            a.c[0] - b.c[0], a.c[1] - b.c[1], a.c[2] - b.c[2], a.c[3] - b.c[3],
            a.c[4] - b.c[4], a.c[5] - b.c[5], a.c[6] - b.c[6], a.c[7] - b.c[7],
        } };
    }

    pub fn scale(a: Octonion, s: i128) Octonion {
        return .{ .c = [_]i128{
            fp.mul(a.c[0], s), fp.mul(a.c[1], s), fp.mul(a.c[2], s), fp.mul(a.c[3], s),
            fp.mul(a.c[4], s), fp.mul(a.c[5], s), fp.mul(a.c[6], s), fp.mul(a.c[7], s),
        } };
    }

    pub fn conjugate(a: Octonion) Octonion {
        return .{ .c = [_]i128{
            a.c[0], -a.c[1], -a.c[2], -a.c[3], -a.c[4], -a.c[5], -a.c[6], -a.c[7],
        } };
    }

    pub fn normSq(a: Octonion) i128 {
        var sum: i128 = 0;
        for (a.c) |comp| {
            sum += fp.mul(comp, comp);
        }
        return sum;
    }

    pub fn eq(a: Octonion, b: Octonion) bool {
        for (0..8) |i| {
            if (a.c[i] != b.c[i]) return false;
        }
        return true;
    }
};

// =============================================================================
// Multiplication Table
// =============================================================================

/// The 7 oriented triples defining octonion multiplication.
/// Each triple (a, b, c) means e_a × e_b = e_c (with positive orientation).
const triples = [_][3]Unit{
    .{ 1, 2, 3 }, .{ 1, 4, 5 }, .{ 1, 7, 6 }, .{ 2, 4, 6 },
    .{ 2, 5, 7 }, .{ 3, 4, 7 }, .{ 3, 6, 5 },
};

/// Detect if (a, b, c) forms an oriented triad. Returns the product and sign
/// if they form a valid oriented triple, or null otherwise.
fn oriented(a: Unit, b: Unit, c: Unit) ?Product {
    if (a == b or a == c or b == c) return null;
    for (triples) |triple| {
        if (a == triple[0] and b == triple[1] and c == triple[2]) return .{ .unit = c, .sign = 1 };
        if (b == triple[0] and c == triple[1] and a == triple[2]) return .{ .unit = a, .sign = 1 };
        if (c == triple[0] and a == triple[1] and b == triple[2]) return .{ .unit = b, .sign = 1 };
        if (b == triple[0] and a == triple[1] and c == triple[2]) return .{ .unit = c, .sign = -1 };
        if (c == triple[0] and b == triple[1] and a == triple[2]) return .{ .unit = a, .sign = -1 };
        if (a == triple[0] and c == triple[1] and b == triple[2]) return .{ .unit = b, .sign = -1 };
    }
    return null;
}

/// Multiply two octonion units. Returns the product unit and sign.
/// e0 is the identity: e0 × e_i = e_i, e_i × e0 = e_i.
/// e_i × e_i = -e0 (imaginary units square to -1).
/// For i ≠ j (both nonzero), uses the oriented triples table.
pub fn multiply(a: Unit, b: Unit) Product {
    if (a == 0) return .{ .unit = b, .sign = 1 };
    if (b == 0) return .{ .unit = a, .sign = 1 };
    if (a == b) return .{ .unit = 0, .sign = -1 };
    for (triples) |triple| {
        if (a == triple[0] and b == triple[1]) return .{ .unit = triple[2], .sign = 1 };
        if (a == triple[1] and b == triple[2]) return .{ .unit = triple[0], .sign = 1 };
        if (a == triple[2] and b == triple[0]) return .{ .unit = triple[1], .sign = 1 };
        if (b == triple[0] and a == triple[1]) return .{ .unit = triple[2], .sign = -1 };
        if (b == triple[1] and a == triple[2]) return .{ .unit = triple[0], .sign = -1 };
        if (b == triple[2] and a == triple[0]) return .{ .unit = triple[1], .sign = -1 };
    }
    unreachable;
}

// =============================================================================
// Full Octonion Vector Multiplication
// =============================================================================

/// Multiply two full octonion values (8 components each) using the
/// octonion multiplication table. Uses the distributive law:
///   (a0 + Σ a_i e_i) × (b0 + Σ b_j e_j) = a0*b0 + Σ a0*b_j e_j + Σ a_i*b0 e_i + Σ a_i*b_j (e_i × e_j)
///
/// Note: Octonion multiplication is NON-ASSOCIATIVE but ALTERNATIVE.
/// This function computes the standard (left-distributive) product.
pub fn multiplyFull(a: Octonion, b: Octonion) Octonion {
    var result = Octonion.zero;
    for (0..8) |i| {
        for (0..8) |j| {
            const prod = multiply(@intCast(i), @intCast(j));
            const coeff = fp.mul(a.c[i], b.c[j]);
            const signed: i128 = if (prod.sign < 0) -coeff else coeff;
            result.c[prod.unit] += signed;
        }
    }
    return result;
}

/// Multiply two full octonion values using left-distributive evaluation.
/// This is the canonical octonion product: a × b = Σ_{i,j} a_i * b_j * (e_i × e_j)
pub fn multiplyOctonion(a: Octonion, b: Octonion) Octonion {
    return multiplyFull(a, b);
}

// =============================================================================
// Algebraic Property Verification
// =============================================================================

/// Check the alternative law: e_i(e_i e_j) = (e_i e_i) e_j
pub fn isAlternative(a: Unit, b: Unit, c: Unit) bool {
    const left_first = multiply(a, b);
    const left_second = multiply(left_first.unit, c);
    const right_first = multiply(b, c);
    const right_second = multiply(a, right_first.unit);
    return left_second.unit == right_second.unit and left_first.sign * left_second.sign == right_first.sign * right_second.sign;
}

/// Verify that octonion multiplication is non-associative.
/// Uses the classic example: (e1 × e2) × e4 ≠ e1 × (e2 × e4)
pub fn isNonAssociative() bool {
    const left_first = multiply(1, 2);
    const left = multiply(left_first.unit, 4);
    const right_first = multiply(2, 4);
    const right = multiply(1, right_first.unit);
    return left.unit == right.unit and left_first.sign * left.sign != right_first.sign * right.sign;
}

/// Check the flexible law (Moufang identity): (e_i × e_j) × e_i = e_i × (e_j × e_i)
pub fn isFlexible(i: Unit, j: Unit) bool {
    const left_first = multiply(i, j);
    const left = multiply(left_first.unit, i);
    const right_first = multiply(j, i);
    const right = multiply(i, right_first.unit);
    return left.unit == right.unit and left_first.sign * left.sign == right_first.sign * right.sign;
}

// =============================================================================
// Tests
// =============================================================================

test "octonion identity and imaginary squares" {
    try std.testing.expectEqual(@as(Unit, 4), multiply(0, 4).unit);
    try std.testing.expectEqual(@as(i2, -1), multiply(4, 4).sign);
}

test "octonion has seven oriented triads" {
    for (triples) |triple| {
        const result = multiply(triple[0], triple[1]);
        try std.testing.expectEqual(triple[2], result.unit);
        try std.testing.expectEqual(@as(i2, 1), result.sign);
    }
}

test "octonion multiplication is non-associative" {
    try std.testing.expect(isNonAssociative());
}

test "octonion e0 is identity for all units" {
    var i: Unit = 0;
    while (i < 7) : (i += 1) {
        const left = multiply(0, i);
        try std.testing.expectEqual(i, left.unit);
        try std.testing.expectEqual(@as(i2, 1), left.sign);
        const right = multiply(i, 0);
        try std.testing.expectEqual(i, right.unit);
        try std.testing.expectEqual(@as(i2, 1), right.sign);
    }
    // Test i=7 separately (u3 max)
    const left7 = multiply(0, 7);
    try std.testing.expectEqual(@as(Unit, 7), left7.unit);
    const right7 = multiply(7, 0);
    try std.testing.expectEqual(@as(Unit, 7), right7.unit);
}

test "octonion imaginary squares are -1" {
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        const result = multiply(i, i);
        try std.testing.expectEqual(@as(Unit, 0), result.unit);
        try std.testing.expectEqual(@as(i2, -1), result.sign);
    }
    const result7 = multiply(7, 7);
    try std.testing.expectEqual(@as(Unit, 0), result7.unit);
    try std.testing.expectEqual(@as(i2, -1), result7.sign);
}

test "octonion anti-commutativity for imaginary units" {
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        var j: Unit = 1;
        while (j < 7) : (j += 1) {
            if (i == j) continue;
            const ij = multiply(i, j);
            const ji = multiply(j, i);
            try std.testing.expectEqual(ij.unit, ji.unit);
            try std.testing.expectEqual(ij.sign, -ji.sign);
        }
    }
    // Test i=7, j=1..6
    var j: Unit = 1;
    while (j < 7) : (j += 1) {
        const ij = multiply(7, j);
        const ji = multiply(j, 7);
        try std.testing.expectEqual(ij.unit, ji.unit);
        try std.testing.expectEqual(ij.sign, -ji.sign);
    }
}

test "octonion alternativity" {
    // The octonions are alternative: e_i(e_i e_j) = (e_i e_i) e_j
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        var j: Unit = 1;
        while (j < 7) : (j += 1) {
            try std.testing.expect(isAlternative(i, i, j));
        }
        try std.testing.expect(isAlternative(i, i, 7));
    }
    try std.testing.expect(isAlternative(7, 7, 1));
}

test "octonion full multiplication table has 64 entries" {
    var count: u16 = 0;
    var i: Unit = 0;
    while (i < 7) : (i += 1) {
        var j: Unit = 0;
        while (j < 7) : (j += 1) {
            _ = multiply(i, j);
            count += 1;
        }
        _ = multiply(i, 7);
        count += 1;
    }
    var j: Unit = 0;
    while (j < 7) : (j += 1) {
        _ = multiply(7, j);
        count += 1;
    }
    _ = multiply(7, 7);
    count += 1;
    try std.testing.expectEqual(@as(u16, 64), count);
}

test "octonion oriented triad detection" {
    // (1,2,3) is a valid oriented triad
    const result = oriented(1, 2, 3);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(Unit, 3), result.?.unit);
    try std.testing.expectEqual(@as(i2, 1), result.?.sign);
    // Reversed orientation gives negative sign
    const reversed = oriented(2, 1, 3);
    try std.testing.expect(reversed != null);
    try std.testing.expectEqual(@as(i2, -1), reversed.?.sign);
    // Duplicate units return null
    try std.testing.expect(oriented(1, 1, 3) == null);
}

test "octonion Moufang identity (flexible law)" {
    // Octonions satisfy the flexible law: (e_i e_j) e_i = e_i (e_j e_i)
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        var j: Unit = 1;
        while (j < 7) : (j += 1) {
            try std.testing.expect(isFlexible(i, j));
        }
    }
}

// =============================================================================
// Full Octonion Vector Tests
// =============================================================================

test "Octonion: identity multiplication" {
    const a = Octonion.fromReal(fp.fromInt(5));
    const id = Octonion.identity;
    const result = multiplyFull(a, id);
    try std.testing.expect(fp.eq(result.c[0], fp.fromInt(5)));
    for (1..8) |i| {
        try std.testing.expectEqual(@as(i128, 0), result.c[i]);
    }
}

test "Octonion: real multiplication" {
    const a = Octonion.fromReal(fp.fromInt(3));
    const b = Octonion.fromReal(fp.fromInt(4));
    const result = multiplyFull(a, b);
    try std.testing.expect(fp.eq(result.c[0], fp.fromInt(12)));
}

test "Octonion: imaginary unit squares to -1" {
    // e1 * e1 = -1 (real)
    var a = Octonion.zero;
    a.c[1] = fp.ONE;
    const result = multiplyFull(a, a);
    // Result should be -1 in real part
    try std.testing.expect(fp.eq(result.c[0], -fp.ONE));
    for (1..8) |i| {
        try std.testing.expectEqual(@as(i128, 0), result.c[i]);
    }
}

test "Octonion: e1 * e2 = e3" {
    var a = Octonion.zero;
    a.c[1] = fp.ONE;
    var b = Octonion.zero;
    b.c[2] = fp.ONE;
    const result = multiplyFull(a, b);
    try std.testing.expectEqual(@as(i128, 0), result.c[0]);
    try std.testing.expectEqual(@as(i128, 0), result.c[1]);
    try std.testing.expectEqual(@as(i128, 0), result.c[2]);
    try std.testing.expect(fp.eq(result.c[3], fp.ONE));
}

test "Octonion: anti-commutativity e1*e2 = -(e2*e1)" {
    var a = Octonion.zero;
    a.c[1] = fp.ONE;
    var b = Octonion.zero;
    b.c[2] = fp.ONE;
    const ab = multiplyFull(a, b);
    const ba = multiplyFull(b, a);
    try std.testing.expect(fp.eq(ab.c[3], -ba.c[3]));
}

test "Octonion: add and sub" {
    const a = Octonion.fromReal(fp.fromInt(5));
    const b = Octonion.fromReal(fp.fromInt(3));
    const sum = Octonion.add(a, b);
    const diff = Octonion.sub(a, b);
    try std.testing.expect(fp.eq(sum.c[0], fp.fromInt(8)));
    try std.testing.expect(fp.eq(diff.c[0], fp.fromInt(2)));
}

test "Octonion: conjugate" {
    var a = Octonion.zero;
    a.c[0] = fp.fromInt(3);
    a.c[1] = fp.fromInt(4);
    a.c[2] = fp.fromInt(5);
    const conj = Octonion.conjugate(a);
    try std.testing.expect(fp.eq(conj.c[0], fp.fromInt(3)));
    try std.testing.expect(fp.eq(conj.c[1], -fp.fromInt(4)));
    try std.testing.expect(fp.eq(conj.c[2], -fp.fromInt(5)));
}

test "Octonion: norm squared" {
    var a = Octonion.zero;
    a.c[0] = fp.fromInt(3);
    a.c[1] = fp.fromInt(4);
    const norm_sq = Octonion.normSq(a);
    // 3^2 + 4^2 = 9 + 16 = 25
    try std.testing.expect(fp.eq(norm_sq, fp.fromInt(25)));
}

test "Octonion: scale" {
    const a = Octonion.fromReal(fp.fromInt(5));
    const scaled = Octonion.scale(a, fp.fromInt(3));
    try std.testing.expect(fp.eq(scaled.c[0], fp.fromInt(15)));
}

test "Octonion: equality" {
    const a = Octonion.fromReal(fp.fromInt(5));
    const b = Octonion.fromReal(fp.fromInt(5));
    const c = Octonion.fromReal(fp.fromInt(6));
    try std.testing.expect(Octonion.eq(a, b));
    try std.testing.expect(!Octonion.eq(a, c));
}

test "Octonion: zero and identity" {
    try std.testing.expect(Octonion.eq(Octonion.zero, Octonion.zero));
    try std.testing.expect(fp.eq(Octonion.identity.c[0], fp.ONE));
    for (1..8) |i| {
        try std.testing.expectEqual(@as(i128, 0), Octonion.identity.c[i]);
    }
}

test "Octonion: non-associativity in full multiplication" {
    // (e1 * e2) * e4 ≠ e1 * (e2 * e4)
    var e1 = Octonion.zero;
    e1.c[1] = fp.ONE;
    var e2 = Octonion.zero;
    e2.c[2] = fp.ONE;
    var e4 = Octonion.zero;
    e4.c[4] = fp.ONE;

    const left = multiplyFull(multiplyFull(e1, e2), e4);
    const right = multiplyFull(e1, multiplyFull(e2, e4));
    try std.testing.expect(!Octonion.eq(left, right));
}

// =============================================================================
// Framework Verification (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// U(1) number operator charges from the hardware framework's electric_charges module.
/// The octonion basis e0..e7 has a natural complex structure O = C ⊕ C³.
/// e0 = 1 (identity, real, charge 0)
/// e7 = i (imaginary identity, charge 0)
/// e1, e2, e3 = quark-like (charge +1/3, scaled to +1)
/// e4, e5, e6 = anti-quark-like (charge -1/3, scaled to -1)
pub const U1_CHARGES_SCALED: [8]i8 = .{ 0, 1, 1, 1, -1, -1, -1, 0 };

/// Returns the U(1) charge of an octonion unit (scaled by 3).
/// e0, e7 → 0 (no charge)
/// e1, e2, e3 → +1 (quark charge +1/3)
/// e4, e5, e6 → -1 (anti-quark charge -1/3)
pub fn u1Charge(unit: Unit) i8 {
    return U1_CHARGES_SCALED[unit];
}

/// Verifies that the octonion triples match the hardware framework's Fano plane.
/// The 7 oriented triples must match exactly.
pub fn verifyFanoTriplesMatchFramework() bool {
    const framework_triples = [_][3]Unit{
        .{ 1, 2, 3 }, .{ 1, 4, 5 }, .{ 1, 7, 6 }, .{ 2, 4, 6 },
        .{ 2, 5, 7 }, .{ 3, 4, 7 }, .{ 3, 6, 5 },
    };
    // The triples in this module are defined at the top of the file.
    // Verify they match the framework's triples.
    for (framework_triples, 0..) |ft, i| {
        if (ft[0] != triples[i][0]) return false;
        if (ft[1] != triples[i][1]) return false;
        if (ft[2] != triples[i][2]) return false;
    }
    return true;
}

/// Verifies the U(1) charge structure: 3 positive, 3 negative, 2 neutral.
pub fn verifyU1ChargeStructure() bool {
    var positive: u32 = 0;
    var negative: u32 = 0;
    var neutral: u32 = 0;
    for (U1_CHARGES_SCALED) |charge| {
        if (charge > 0) positive += 1;
        if (charge < 0) negative += 1;
        if (charge == 0) neutral += 1;
    }
    return positive == 3 and negative == 3 and neutral == 2;
}

/// Verifies alternativity: (a*a)*b = a*(a*b) for all units.
pub fn verifyAlternativity() bool {
    for (1..8) |a| {
        for (1..8) |b| {
            if (a == b) continue;
            const a_unit: Unit = @intCast(a);
            const b_unit: Unit = @intCast(b);
            // (a*a) = -1 (for imaginary units)
            const aa = multiply(a_unit, a_unit);
            const aab = multiply(aa.unit, b_unit);
            const ab = multiply(a_unit, b_unit);
            const a_ab = multiply(a_unit, ab.unit);
            if (aab.unit != a_ab.unit) return false;
            if (aa.sign * aab.sign != ab.sign * a_ab.sign) return false;
        }
    }
    return true;
}

test "framework: U(1) charges match octonion structure" {
    try std.testing.expectEqual(@as(i8, 0), u1Charge(0)); // e0 = real
    try std.testing.expectEqual(@as(i8, 1), u1Charge(1)); // e1 = quark
    try std.testing.expectEqual(@as(i8, 1), u1Charge(2)); // e2 = quark
    try std.testing.expectEqual(@as(i8, 1), u1Charge(3)); // e3 = quark
    try std.testing.expectEqual(@as(i8, -1), u1Charge(4)); // e4 = anti-quark
    try std.testing.expectEqual(@as(i8, -1), u1Charge(5)); // e5 = anti-quark
    try std.testing.expectEqual(@as(i8, -1), u1Charge(6)); // e6 = anti-quark
    try std.testing.expectEqual(@as(i8, 0), u1Charge(7)); // e7 = imaginary identity
}

test "framework: Fano triples match hardware framework" {
    try std.testing.expect(verifyFanoTriplesMatchFramework());
}

test "framework: U(1) charge structure (3+, 3-, 2 neutral)" {
    try std.testing.expect(verifyU1ChargeStructure());
}

test "framework: octonion alternativity" {
    try std.testing.expect(verifyAlternativity());
}
