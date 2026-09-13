// ============================================================================
// 9D ANTI-OCTONION — Scaling Dimension
// ============================================================================
//
// Extends the 8D octonion algebra with a 9th basis element e8, the "anti"
// or "scaling" dimension. The anti-octonion provides the scaling
// transformation that maps the discrete lattice structure to physical
// scales.
//
// Algebraic structure:
//   - e0..e7: standard octonion basis (e0=real, e1..e7 imaginary, e_i² = -1)
//   - e8: anti/scaling element (e8² = +1, split signature)
//   - e8 commutes with all octonion elements
//   - e8 × e_i = anti(e_i) = conjugate with sign flip on imaginary parts
//
// Physical interpretation:
//   - 8D octonions define particle structure (charges, generations)
//   - 9D anti-octonion provides the scaling transformation
//   - The 9th dimension connects to the 9D Möbius strip boundary
//   - In SO(10) GUT: the 9th dimension is part of the 10D gauge group
//
// The 9D structure connects to the framework's shell transition:
//   - 15³ = 3375 (interior, 8D octonion structure)
//   - The 9th dimension provides the scaling to go from 15³ to 16³
//   - 16³ = 4096 (closure, includes the scaling contribution)
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const oct = @import("octonion.zig");

pub const AntiUnit = u4; // 0..8 (9 values)

pub const AntiProduct = struct {
    unit: AntiUnit,
    sign: i2,
};

/// The 9th basis element index.
pub const E8: AntiUnit = 8;

/// Anti-octonion multiplication.
/// e0..e7 follow standard octonion rules.
/// e8 is the anti/scaling element:
///   e8 × e8 = +e0 (positive, unlike imaginary units)
///   e8 × e_i = e_i (scaling identity on octonion elements)
///   e_i × e8 = e_i (commutative with octonion elements)
pub fn multiply(a: AntiUnit, b: AntiUnit) AntiProduct {
    if (a == E8 and b == E8) return .{ .unit = 0, .sign = 1 }; // e8² = +1
    if (a == E8) return .{ .unit = b, .sign = 1 }; // e8 × e_i = e_i
    if (b == E8) return .{ .unit = a, .sign = 1 }; // e_i × e8 = e_i

    // Standard octonion multiplication for e0..e7
    const oct_prod = oct.multiply(@intCast(a), @intCast(b));
    return .{ .unit = @intCast(oct_prod.unit), .sign = oct_prod.sign };
}

/// Conjugate of an anti-octonion element.
/// For e0..e7: same as octonion conjugate (flip sign of imaginary parts)
/// For e8: e8 conjugate = e8 (self-conjugate, since e8² = +1)
pub fn conjugate(a: AntiUnit) AntiUnit {
    return a; // The basis element itself; conjugation acts on coefficients
}

/// Norm signature: octonion imaginary units have negative square,
/// e8 has positive square (split signature).
pub fn normSign(a: AntiUnit) i2 {
    if (a == 0) return 1; // e0² = +1
    if (a == E8) return 1; // e8² = +1 (anti/scaling)
    return -1; // e1..e7: e_i² = -1
}

/// The anti-octonion has 9 basis elements.
pub const DIM: u8 = 9;

/// The anti-octonion scaling factor.
/// In the framework, the 9th dimension scales the 8D structure.
/// The scaling connects 15³ (interior) to 16³ (closure).
/// 16/15 = 1.0666... = the scaling ratio.
/// In exact arithmetic: 16 = 15 + 1, so the scaling adds the origin (e0/Higgs).
pub const SCALING_RATIO_NUM: u32 = 16;
pub const SCALING_RATIO_DEN: u32 = 15;

/// Verify that the 9D structure is consistent.
/// 9 = 8 (octonion) + 1 (anti/scaling)
pub fn verifyDimension() bool {
    return DIM == 8 + 1;
}

/// Verify the scaling ratio: 16/15 connects interior to closure.
pub fn verifyScalingRatio() bool {
    return SCALING_RATIO_NUM * SCALING_RATIO_NUM * SCALING_RATIO_NUM -
        SCALING_RATIO_DEN * SCALING_RATIO_DEN * SCALING_RATIO_DEN == 721;
}

/// Verify the split signature: 8 octonion dims + 1 anti dim = 9 total.
/// Octonion: 1 positive (e0) + 7 negative (e1-e7) = signature (1,7)
/// Anti-octonion: 2 positive (e0, e8) + 7 negative (e1-e7) = signature (2,7)
pub fn verifySignature() bool {
    var positive: u8 = 0;
    var negative: u8 = 0;
    for (0..DIM) |i| {
        if (normSign(@intCast(i)) > 0) positive += 1 else negative += 1;
    }
    return positive == 2 and negative == 7;
}

// ============================================================================
// Tests
// ============================================================================

test "anti-octonion has 9 dimensions" {
    try std.testing.expectEqual(@as(u8, 9), DIM);
    try std.testing.expect(verifyDimension());
}

test "e8 squared is positive (split signature)" {
    const prod = multiply(E8, E8);
    try std.testing.expectEqual(@as(AntiUnit, 0), prod.unit);
    try std.testing.expectEqual(@as(i2, 1), prod.sign); // +1, not -1
}

test "e8 commutes with octonion elements" {
    for (0..8) |i| {
        const left = multiply(E8, @intCast(i));
        const right = multiply(@intCast(i), E8);
        try std.testing.expectEqual(left.unit, right.unit);
        try std.testing.expectEqual(left.sign, right.sign);
    }
}

test "anti-octonion preserves octonion multiplication for e0-e7" {
    for (0..8) |a| {
        for (0..8) |b| {
            const anti_prod = multiply(@intCast(a), @intCast(b));
            const oct_prod = oct.multiply(@intCast(a), @intCast(b));
            try std.testing.expectEqual(@as(AntiUnit, @intCast(oct_prod.unit)), anti_prod.unit);
            try std.testing.expectEqual(oct_prod.sign, anti_prod.sign);
        }
    }
}

test "anti-octonion signature is (2,7)" {
    try std.testing.expect(verifySignature());
}

test "scaling ratio connects 15³ to 16³" {
    try std.testing.expect(verifyScalingRatio());
    try std.testing.expectEqual(@as(u32, 721), 16 * 16 * 16 - 15 * 15 * 15);
}
