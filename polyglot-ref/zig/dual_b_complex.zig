// ============================================================================
// 10D DUAL-B-COMPLEX — Final Scaling to Measurable Values
// ============================================================================
//
// Extends the 9D anti-octonion with a 10th basis element e9, the "dual"
// dimension from Dual-B-Complex numbers. The 10D structure provides the
// final scaling that maps physical scales to measurable values.
//
// Algebraic structure:
//   - e0..e7: standard octonion basis (e_i² = -1 for i>0)
//   - e8: anti/scaling element (e8² = +1, split signature)
//   - e9: dual element (e9² = 0, nilpotent — like dual numbers ε²=0)
//   - e9 commutes with all elements
//   - e9 × e_i = e9 (absorbing, like dual number multiplication)
//
// Physical interpretation:
//   - 8D octonions: particle structure (charges, generations)
//   - 9D anti-octonion: scaling transformation (lattice → physical scale)
//   - 10D Dual-B-Complex: final scaling (physical scale → measurable values)
//   - 10D → SO(10) GUT gauge group
//
// THE KEY CONNECTION: 10D → SO(10) → 16 chiral spinor → fermions
//
// In the SO(10) Grand Unified Theory:
//   - SO(10) has a 16-dimensional chiral spinor representation
//   - This 16-spinor contains exactly one generation of SM fermions:
//     - 15 Standard Model fermions + 1 sterile neutrino
//   - 16 = 15 + 1 (SM + sterile ν)
//   - 15² = 225 = framework's 15×15 matrix element count
//   - 15×16 = 240 = E8 root count
//   - 16³ - 15³ = 721 = 3(240) + 1 = shell transition
//
// This means the framework's 15 and 16 are NOT arbitrary:
//   15 = number of SM fermions per generation (excluding sterile ν)
//   16 = dimension of SO(10) chiral spinor = one full generation
//   225 = 15² = mass matrix entries (bilinear fermion operators)
//   240 = 15×16 = E8 root count (E8 contains SO(16) ⊃ SO(10))
//
// The 10D structure completes the dimensional model:
//   0D (origin/Higgs) → 8D (octonion/structure) → 9D (anti-octonion/scaling)
//   → 10D (Dual-B-Complex/SO(10) GUT)
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const oct = @import("octonion.zig");
const anti = @import("anti_octonion.zig");

pub const DualUnit = u4; // 0..9 (but u4 holds 0..15, so we use values 0..9)

pub const DualProduct = struct {
    unit: u4, // 0..9
    sign: i2,
};

/// The 10th basis element index.
pub const E9: u4 = 9;

/// The 10D algebra has 10 basis elements.
pub const DIM: u8 = 10;

/// SO(10) has dimension 10×9/2 = 45.
pub const SO10_DIM: u32 = 45;

/// SO(10) chiral spinor representation dimension = 2^(10/2 - 1) = 16.
pub const SO10_SPINOR_DIM: u32 = 16;

/// SM fermions per generation (excluding sterile neutrino) = 15.
pub const SM_FERMIONS: u32 = 15;

/// Sterile neutrino count = 1.
pub const STERILE_NEUTRINO: u32 = 1;

/// Mass matrix entries = 15² = 225.
pub const MASS_MATRIX_ENTRIES: u32 = 225;

/// E8 root count = 15 × 16 = 240.
pub const E8_ROOTS: u32 = 240;

/// Shell transition = 16³ - 15³ = 721 = 3(240) + 1.
pub const SHELL_TRANSITION: u32 = 721;

/// Dual-B-Complex multiplication.
/// e0..e8: follow anti-octonion rules
/// e9: dual/nilpotent element (e9² = 0)
///   e9 × e9 = 0 (nilpotent, like dual numbers)
///   e9 × e_i = e9 (absorbing)
///   e_i × e9 = e9 (absorbing)
pub fn multiply(a: u4, b: u4) DualProduct {
    if (a == E9 and b == E9) return .{ .unit = 0, .sign = 0 }; // e9² = 0
    if (a == E9) return .{ .unit = E9, .sign = 1 }; // e9 × e_i = e9
    if (b == E9) return .{ .unit = E9, .sign = 1 }; // e9 × e_i = e9

    // Anti-octonion multiplication for e0..e8
    const anti_prod = anti.multiply(@intCast(a), @intCast(b));
    return .{ .unit = @intCast(anti_prod.unit), .sign = anti_prod.sign };
}

/// Norm signature for Dual-B-Complex elements.
/// e0: +1 (real)
/// e1-e7: -1 (octonion imaginary)
/// e8: +1 (anti/scaling)
/// e9: 0 (nilpotent/dual)
pub fn normSign(a: u4) i8 {
    if (a == 0) return 1;
    if (a == 8) return 1; // e8: anti, positive
    if (a == 9) return 0; // e9: dual, nilpotent
    return -1; // e1-e7: imaginary
}

/// Verify the 10D dimension count.
pub fn verifyDimension() bool {
    return DIM == 10;
}

/// Verify SO(10) dimension: 10×9/2 = 45.
pub fn verifySO10Dimension() bool {
    return DIM * (DIM - 1) / 2 == SO10_DIM;
}

/// Verify the chiral spinor dimension: 2^(10/2 - 1) = 16.
pub fn verifySpinorDimension() bool {
    const computed: u32 = @as(u32, 1) << (@as(u5, @intCast(DIM / 2 - 1)));
    return computed == SO10_SPINOR_DIM;
}

/// Verify the fermion decomposition: 16 = 15 + 1.
pub fn verifyFermionDecomposition() bool {
    return SO10_SPINOR_DIM == SM_FERMIONS + STERILE_NEUTRINO;
}

/// Verify the mass matrix: 225 = 15².
pub fn verifyMassMatrix() bool {
    return MASS_MATRIX_ENTRIES == SM_FERMIONS * SM_FERMIONS;
}

/// Verify the E8 connection: 240 = 15 × 16.
pub fn verifyE8Connection() bool {
    return E8_ROOTS == SM_FERMIONS * SO10_SPINOR_DIM;
}

/// Verify the shell transition: 721 = 16³ - 15³ = 3(240) + 1.
pub fn verifyShellTransition() bool {
    const closure = SO10_SPINOR_DIM * SO10_SPINOR_DIM * SO10_SPINOR_DIM;
    const interior = SM_FERMIONS * SM_FERMIONS * SM_FERMIONS;
    return closure - interior == SHELL_TRANSITION and
        SHELL_TRANSITION == 3 * E8_ROOTS + 1;
}

/// Verify the full chain: 10D → SO(10) → 16 → 15+1 → 225 → 240 → 721.
pub fn verifyFullChain() bool {
    return verifyDimension() and
        verifySO10Dimension() and
        verifySpinorDimension() and
        verifyFermionDecomposition() and
        verifyMassMatrix() and
        verifyE8Connection() and
        verifyShellTransition();
}

/// The 10D → SO(10) → 16 spinor connection.
/// This is the key insight: the framework's 15 and 16 come from SO(10),
/// not from arbitrary choice.
pub const SO10_CHAIN =
    \\10D Dual-B-Complex → SO(10) GUT
    \\  SO(10) chiral spinor = 16 dimensions = one fermion generation
    \\    16 = 15 (SM fermions) + 1 (sterile neutrino)
    \\      15² = 225 = mass matrix entries = 15×15 matrix elements
    \\      15×16 = 240 = E8 root count
    \\        16³ - 15³ = 721 = 3(240) + 1 = shell transition
    \\          +1 = e0 = 0D = Higgs field = 0^0 = i
;

// ============================================================================
// Tests
// ============================================================================

test "Dual-B-Complex has 10 dimensions" {
    try std.testing.expectEqual(@as(u8, 10), DIM);
    try std.testing.expect(verifyDimension());
}

test "e9 squared is zero (nilpotent)" {
    const prod = multiply(E9, E9);
    try std.testing.expectEqual(@as(u4, 0), prod.unit);
    try std.testing.expectEqual(@as(i2, 0), prod.sign); // zero
}

test "e9 is absorbing" {
    for (0..9) |i| {
        const left = multiply(E9, @intCast(i));
        const right = multiply(@intCast(i), E9);
        try std.testing.expectEqual(E9, left.unit);
        try std.testing.expectEqual(E9, right.unit);
    }
}

test "Dual-B-Complex preserves anti-octonion multiplication for e0-e8" {
    for (0..9) |a| {
        for (0..9) |b| {
            const dual_prod = multiply(@intCast(a), @intCast(b));
            const anti_prod = anti.multiply(@intCast(a), @intCast(b));
            try std.testing.expectEqual(@as(u4, @intCast(anti_prod.unit)), dual_prod.unit);
            try std.testing.expectEqual(anti_prod.sign, dual_prod.sign);
        }
    }
}

test "SO(10) dimension is 45" {
    try std.testing.expect(verifySO10Dimension());
    try std.testing.expectEqual(@as(u32, 45), SO10_DIM);
}

test "SO(10) chiral spinor is 16-dimensional" {
    try std.testing.expect(verifySpinorDimension());
    try std.testing.expectEqual(@as(u32, 16), SO10_SPINOR_DIM);
}

test "16 = 15 SM fermions + 1 sterile neutrino" {
    try std.testing.expect(verifyFermionDecomposition());
    try std.testing.expectEqual(@as(u32, 15), SM_FERMIONS);
    try std.testing.expectEqual(@as(u32, 1), STERILE_NEUTRINO);
}

test "mass matrix has 225 = 15² entries" {
    try std.testing.expect(verifyMassMatrix());
    try std.testing.expectEqual(@as(u32, 225), MASS_MATRIX_ENTRIES);
}

test "E8 root count = 15 × 16 = 240" {
    try std.testing.expect(verifyE8Connection());
    try std.testing.expectEqual(@as(u32, 240), E8_ROOTS);
}

test "shell transition = 16³ - 15³ = 721 = 3(240) + 1" {
    try std.testing.expect(verifyShellTransition());
    try std.testing.expectEqual(@as(u32, 721), SHELL_TRANSITION);
}

test "full 10D → SO(10) → 16 → 15+1 → 225 → 240 → 721 chain verifies" {
    try std.testing.expect(verifyFullChain());
}

test "SO(10) chain string is non-empty" {
    try std.testing.expect(SO10_CHAIN.len > 0);
}
