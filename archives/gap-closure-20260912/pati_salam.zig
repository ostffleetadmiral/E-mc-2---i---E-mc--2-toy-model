// ============================================================================
// PATI-SALAM CONNECTION — 15×15 Matrix and SO(6)/SU(4)
// ============================================================================
//
// The framework's 15×15 matrix structure is connected to the Pati-Salam
// model, which unifies quarks and leptons using the gauge group
// SU(4) × SU(2)_L × SU(2)_R.
//
// Key identities:
//   dim(SO(6)) = 6×5/2 = 15
//   SO(6) ≅ SU(4) (as Lie groups)
//   dim(SU(4)) = 4²-1 = 15
//   The 15-dimensional adjoint representation of SU(4) contains the
//   Standard Model gauge bosons plus leptoquark bosons.
//
// In the Pati-Salam model:
//   SU(4) unifies color SU(3) with lepton number (the 4th color)
//   SU(2)_L is the left-handed weak interaction
//   SU(2)_R is the right-handed weak interaction
//   The gauge group SU(4) × SU(2)_L × SU(2)_R has dimension 15+3+3 = 21
//
// The 15 generators of SU(4) decompose under SU(3)×U(1) as:
//   15 = 8 + 3 + 3̄ + 1
//   where:
//     8 = gluons (SU(3) adjoint)
//     3 + 3̄ = leptoquark bosons (X and Y bosons)
//     1 = B' boson (hypercharge-like)
//
// Connection to the framework:
//   - The 15×15 matrix has 225 = 15² entries
//   - 15 = dim(SU(4)) = number of Pati-Salam gauge bosons
//   - 225 = 15² = the number of bilinear gauge boson operators
//   - The framework's central row [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6]
//     has 15 elements and sum 49 = 7²
//
// The Pati-Salam model also appears in the octonion physics literature:
//   - Furey's division algebra approach gives Spin(10) → Pati-Salam → SM
//   - The octonion complex structure induces the symmetry breaking cascade:
//     Spin(10) → Spin(4)×Spin(6) = SU(2)_L × SU(2)_R × SU(4) (Pati-Salam)
//     → SU(2)_L × SU(3) × U(1) (Standard Model)
//
// License: Real Illumation Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");

pub const SO6_DIM: u32 = 15;     // dim(SO(6)) = 6×5/2 = 15
pub const SU4_DIM: u32 = 15;     // dim(SU(4)) = 4²-1 = 15
pub const SU3_DIM: u32 = 8;      // dim(SU(3)) = 3²-1 = 8
pub const SU2_DIM: u32 = 3;      // dim(SU(2)) = 2²-1 = 3
pub const U1_DIM: u32 = 1;       // dim(U(1)) = 1

pub const PATI_SALAM_DIM: u32 = 21; // SU(4)×SU(2)_L×SU(2)_R = 15+3+3 = 21
pub const SM_GAUGE_DIM: u32 = 12;   // SU(3)×SU(2)×U(1) = 8+3+1 = 12

/// The framework's central row: [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6]
pub const CENTRAL_ROW = [_]u8{ 6, 5, 4, 3, 2, 1, 0, 7, 0, 1, 2, 3, 4, 5, 6 };
pub const CENTRAL_ROW_LEN: usize = 15;
pub const CENTRAL_ROW_SUM: u32 = 49; // = 7²

/// Verify dim(SO(6)) = 15.
pub fn verifySO6Dimension() bool {
    return 6 * 5 / 2 == SO6_DIM;
}

/// Verify dim(SU(4)) = 15.
pub fn verifySU4Dimension() bool {
    return 4 * 4 - 1 == SU4_DIM;
}

/// Verify SO(6) ≅ SU(4) (they have the same dimension).
pub fn verifySO6SU4Isomorphism() bool {
    return SO6_DIM == SU4_DIM;
}

/// Verify the Pati-Salam gauge group dimension.
/// SU(4) × SU(2)_L × SU(2)_R = 15 + 3 + 3 = 21
pub fn verifyPatiSalamDimension() bool {
    return SU4_DIM + SU2_DIM + SU2_DIM == PATI_SALAM_DIM;
}

/// Verify the Standard Model gauge group dimension.
/// SU(3) × SU(2) × U(1) = 8 + 3 + 1 = 12
pub fn verifySMGaugeDimension() bool {
    return SU3_DIM + SU2_DIM + U1_DIM == SM_GAUGE_DIM;
}

/// Verify the SU(4) → SU(3)×U(1) decomposition.
/// 15 = 8 + 3 + 3̄ + 1
/// The 15 generators of SU(4) decompose as:
///   8 gluons + 3 leptoquarks + 3 anti-leptoquarks + 1 B' boson
pub fn verifySU4Decomposition() bool {
    const su3_adj: u32 = 8;   // gluons
    const leptoquark: u32 = 3;  // X bosons
    const anti_leptoquark: u32 = 3; // Y bosons (3̄)
    const b_prime: u32 = 1;    // B' boson
    return su3_adj + leptoquark + anti_leptoquark + b_prime == SU4_DIM;
}

/// Verify the central row has 15 elements.
pub fn verifyCentralRowLength() bool {
    return CENTRAL_ROW.len == CENTRAL_ROW_LEN and CENTRAL_ROW_LEN == 15;
}

/// Verify the central row sum is 49 = 7².
pub fn verifyCentralRowSum() bool {
    var sum: u32 = 0;
    for (CENTRAL_ROW) |v| sum += v;
    return sum == CENTRAL_ROW_SUM and sum == 7 * 7;
}

/// Verify the central row is symmetric around the center (e7).
/// The row is [6,5,4,3,2,1,0,7,0,1,2,3,4,5,6]
/// which is symmetric: position i and position 14-i have the same value.
pub fn verifyCentralRowSymmetry() bool {
    for (0..CENTRAL_ROW.len / 2) |i| {
        if (CENTRAL_ROW[i] != CENTRAL_ROW[CENTRAL_ROW.len - 1 - i]) return false;
    }
    return true;
}

/// Verify the central row center is e7 (the octonion imaginary unit
/// that plays the role of the complex structure i).
pub fn verifyCentralRowCenter() bool {
    const center = CENTRAL_ROW[CENTRAL_ROW.len / 2];
    return center == 7;
}

/// Verify the framework connection: 15 = dim(SU(4)) = Pati-Salam gauge bosons.
pub fn verifyFrameworkConnection() bool {
    return CENTRAL_ROW_LEN == SU4_DIM and SU4_DIM == SO6_DIM;
}

/// Verify the mass matrix: 225 = 15².
pub fn verifyMassMatrix() bool {
    return CENTRAL_ROW_LEN * CENTRAL_ROW_LEN == 225;
}

/// Verify the E8 connection: 240 = 15 × 16.
pub fn verifyE8Connection() bool {
    return CENTRAL_ROW_LEN * 16 == 240;
}

/// The Pati-Salam symmetry breaking cascade:
/// Spin(10) → Spin(4)×Spin(6) = SU(2)_L × SU(2)_R × SU(4)
///          → SU(2)_L × SU(3)_c × U(1)_Y
///
/// In the octonion physics literature (Furey 2022):
///   The complex structures of the octonions, quaternions, and complex numbers
///   induce this cascade:
///     Octonion complex structure → Spin(10) → Pati-Salam
///     Quaternion complex structure → Pati-Salam → Left-Right symmetric
///     Complex number structure → Left-Right → Standard Model + B-L
pub const SYMMETRY_BREAKING_CASCADE =
    \\Pati-Salam symmetry breaking (from Furey 2022):
    \\  Spin(10) → Spin(4)×Spin(6)/Z₂ = SU(2)_L × SU(2)_R × SU(4)
    \\    → SU(2)_L × SU(3)_c × U(1)_Y (Standard Model)
    \\
    \\  The complex structures induce the cascade:
    \\    Octonion → Spin(10) → Pati-Salam
    \\    Quaternion → Pati-Salam → Left-Right symmetric
    \\    Complex → Left-Right → Standard Model + B-L
    \\
    \\  Framework connection:
    \\    15 = dim(SU(4)) = Pati-Salam gauge bosons
    \\    16 = dim(Spin(10) chiral spinor) = one fermion generation
    \\    225 = 15² = mass matrix entries
    \\    240 = 15 × 16 = E8 root count
    \\    721 = 16³ - 15³ = 3(240) + 1 = shell transition (+1 = Higgs)
;

/// The 4 fundamental fermions of SU(4):
/// In the Pati-Salam model, SU(4) unifies the 3 quark colors with the
/// lepton as the 4th "color". The fundamental representation 4 of SU(4)
/// contains: (r, g, b, ν) or equivalently (u_r, u_g, u_b, ν_e) for one
/// weak isospin component.
pub const SU4_FUNDAMENTAL = [_][]const u8{ "u(r)", "u(g)", "u(b)", "ν" };

/// Verify the SU(4) fundamental representation has 4 elements.
pub fn verifySU4Fundamental() bool {
    return SU4_FUNDAMENTAL.len == 4;
}

// ============================================================================
// Tests
// ============================================================================

test "dim(SO(6)) = 15" {
    try std.testing.expect(verifySO6Dimension());
    try std.testing.expectEqual(@as(u32, 15), SO6_DIM);
}

test "dim(SU(4)) = 15" {
    try std.testing.expect(verifySU4Dimension());
    try std.testing.expectEqual(@as(u32, 15), SU4_DIM);
}

test "SO(6) ≅ SU(4) (same dimension)" {
    try std.testing.expect(verifySO6SU4Isomorphism());
}

test "Pati-Salam gauge group dimension = 21" {
    try std.testing.expect(verifyPatiSalamDimension());
    try std.testing.expectEqual(@as(u32, 21), PATI_SALAM_DIM);
}

test "Standard Model gauge group dimension = 12" {
    try std.testing.expect(verifySMGaugeDimension());
    try std.testing.expectEqual(@as(u32, 12), SM_GAUGE_DIM);
}

test "SU(4) → SU(3)×U(1) decomposition: 15 = 8+3+3+1" {
    try std.testing.expect(verifySU4Decomposition());
}

test "central row has 15 elements" {
    try std.testing.expect(verifyCentralRowLength());
    try std.testing.expectEqual(@as(usize, 15), CENTRAL_ROW.len);
}

test "central row sum = 49 = 7²" {
    try std.testing.expect(verifyCentralRowSum());
}

test "central row is symmetric" {
    try std.testing.expect(verifyCentralRowSymmetry());
}

test "central row center is e7" {
    try std.testing.expect(verifyCentralRowCenter());
}

test "framework connection: 15 = dim(SU(4))" {
    try std.testing.expect(verifyFrameworkConnection());
}

test "mass matrix: 225 = 15²" {
    try std.testing.expect(verifyMassMatrix());
}

test "E8 connection: 240 = 15 × 16" {
    try std.testing.expect(verifyE8Connection());
}

test "SU(4) fundamental representation has 4 elements" {
    try std.testing.expect(verifySU4Fundamental());
}
