//! so10.zig — SO(10) → Standard Model decomposition.
//!
//! Ports the hardware (E=mc²-i-E=mc⁻²) project's SO(10) decomposition into
//! qstar-llm. The SO(10) Grand Unified Theory has a 16-dimensional chiral
//! spinor representation that contains exactly one generation of Standard
//! Model fermions plus a sterile neutrino.
//!
//! Decomposition under SU(3)_c × SU(2)_L × U(1)_Y:
//!
//!   16 = (3, 2, 1/6)      → u_L, d_L (3 colors × 2 weak = 6 states)
//!      + (1, 2, -1/2)     → ν_L, e_L (2 states)
//!      + (3̄, 1, -2/3)    → u_R^c (3 states, anti-up right-handed)
//!      + (3̄, 1, 1/3)     → d_R^c (3 states, anti-down right-handed)
//!      + (1, 1, 1)        → e_R^c (1 state, positron right-handed)
//!      + (1, 1, 0)        → N_R (1 state, sterile neutrino)
//!
//!   Total: 6 + 2 + 3 + 3 + 1 + 1 = 16
//!   SM fermions (without sterile ν): 6 + 2 + 3 + 3 + 1 = 15
//!
//! Connection to the Qstar framework:
//!   15 = SM fermions (Qstar lattice base edge)
//!   16 = 15 + 1 (Qstar lattice shell edge)
//!   240 = 15 × 16 (E8 root count)
//!   721 = 16³ - 15³ = 3(240) + 1 (Qstar boundary cells)
//!
//! All quantum numbers are scaled to integers (i8).
//! No floating-point in any path.
//!
//! Ported from: hardware/src/so10_decomposition.zig
//! License: CC BY-NC-SA 4.0

const std = @import("std");

pub const FermionState = struct {
    name: []const u8,
    color: u8, // 0=none, 1=red, 2=green, 3=blue, 4=anti-red, 5=anti-green, 6=anti-blue
    weak_isospin: i8, // T₃: +1 or -1 (scaled by 2, so +1 = +1/2, -1 = -1/2)
    hypercharge: i8, // Y: scaled by 6 (so 1 = 1/6, -3 = -1/2, 6 = 1, 0 = 0)
    electric_charge: i8, // Q = T₃ + Y, scaled by 6 (so 4 = 2/3, -2 = -1/3, 0 = 0, -6 = -1)
    is_sm: bool, // true if Standard Model fermion, false if sterile neutrino
};

/// The 16 fermion states in the SO(10) chiral spinor.
pub const FERMION_STATES = [_]FermionState{
    // Quarks: u_L, d_L (3 colors × 2 weak = 6 states)
    .{ .name = "u_L(r)", .color = 1, .weak_isospin = 1, .hypercharge = 1, .electric_charge = 4, .is_sm = true },
    .{ .name = "u_L(g)", .color = 2, .weak_isospin = 1, .hypercharge = 1, .electric_charge = 4, .is_sm = true },
    .{ .name = "u_L(b)", .color = 3, .weak_isospin = 1, .hypercharge = 1, .electric_charge = 4, .is_sm = true },
    .{ .name = "d_L(r)", .color = 1, .weak_isospin = -1, .hypercharge = 1, .electric_charge = -2, .is_sm = true },
    .{ .name = "d_L(g)", .color = 2, .weak_isospin = -1, .hypercharge = 1, .electric_charge = -2, .is_sm = true },
    .{ .name = "d_L(b)", .color = 3, .weak_isospin = -1, .hypercharge = 1, .electric_charge = -2, .is_sm = true },

    // Leptons: ν_L, e_L (2 states)
    .{ .name = "ν_L", .color = 0, .weak_isospin = 1, .hypercharge = -3, .electric_charge = 0, .is_sm = true },
    .{ .name = "e_L", .color = 0, .weak_isospin = -1, .hypercharge = -3, .electric_charge = -6, .is_sm = true },

    // Anti-quarks: u_R^c (3 states)
    .{ .name = "u_R^c(r̄)", .color = 4, .weak_isospin = 0, .hypercharge = -4, .electric_charge = -4, .is_sm = true },
    .{ .name = "u_R^c(ḡ)", .color = 5, .weak_isospin = 0, .hypercharge = -4, .electric_charge = -4, .is_sm = true },
    .{ .name = "u_R^c(b̄)", .color = 6, .weak_isospin = 0, .hypercharge = -4, .electric_charge = -4, .is_sm = true },

    // Anti-quarks: d_R^c (3 states)
    .{ .name = "d_R^c(r̄)", .color = 4, .weak_isospin = 0, .hypercharge = 2, .electric_charge = 2, .is_sm = true },
    .{ .name = "d_R^c(ḡ)", .color = 5, .weak_isospin = 0, .hypercharge = 2, .electric_charge = 2, .is_sm = true },
    .{ .name = "d_R^c(b̄)", .color = 6, .weak_isospin = 0, .hypercharge = 2, .electric_charge = 2, .is_sm = true },

    // Anti-lepton: e_R^c (1 state)
    .{ .name = "e_R^c", .color = 0, .weak_isospin = 0, .hypercharge = 6, .electric_charge = 6, .is_sm = true },

    // Sterile neutrino: N_R (1 state)
    .{ .name = "N_R", .color = 0, .weak_isospin = 0, .hypercharge = 0, .electric_charge = 0, .is_sm = false },
};

pub const TOTAL_STATES: usize = 16;
pub const SM_STATES: usize = 15;
pub const STERILE_STATES: usize = 1;

/// Verify the total state count: 16 = 15 + 1.
pub fn verifyStateCount() bool {
    return FERMION_STATES.len == TOTAL_STATES and
        SM_STATES + STERILE_STATES == TOTAL_STATES;
}

/// Count SM fermion states (excluding sterile neutrino).
pub fn countSMStates() usize {
    var count: usize = 0;
    for (FERMION_STATES) |f| {
        if (f.is_sm) count += 1;
    }
    return count;
}

/// Count sterile neutrino states.
pub fn countSterileStates() usize {
    var count: usize = 0;
    for (FERMION_STATES) |f| {
        if (!f.is_sm) count += 1;
    }
    return count;
}

/// Get the unique electric charges (scaled by 6).
pub fn getUniqueCharges(buf: []i8) usize {
    var idx: usize = 0;
    outer: for (FERMION_STATES) |f| {
        for (buf[0..idx]) |q| {
            if (q == f.electric_charge) continue :outer;
        }
        if (idx < buf.len) {
            buf[idx] = f.electric_charge;
            idx += 1;
        }
    }
    std.mem.sort(i8, buf[0..idx], {}, std.sort.asc(i8));
    return idx;
}

/// Verify the unique charges are {-1, -2/3, -1/3, 0, 1/3, 2/3, 1}
/// (scaled by 6: {-6, -4, -2, 0, 2, 4, 6}).
pub fn verifyUniqueCharges() bool {
    var charges: [16]i8 = undefined;
    const count = getUniqueCharges(&charges);
    if (count != 7) return false;
    const expected = [_]i8{ -6, -4, -2, 0, 2, 4, 6 };
    for (expected, 0..) |e, i| {
        if (charges[i] != e) return false;
    }
    return true;
}

/// Verify the charge quantization: all charges are multiples of 1/3.
/// (Scaled by 6: all charges are multiples of 2.)
pub fn verifyChargeQuantization() bool {
    for (FERMION_STATES) |f| {
        if (@rem(f.electric_charge, 2) != 0) return false;
    }
    return true;
}

/// Verify the Gell-Mann–Nishijima formula: Q = T₃ + Y.
/// (Scaled: electric_charge = 3*weak_isospin + hypercharge)
pub fn verifyGellMannNishijima() bool {
    for (FERMION_STATES) |f| {
        const computed = 3 * f.weak_isospin + f.hypercharge;
        if (computed != f.electric_charge) return false;
    }
    return true;
}

/// Verify the anomaly cancellation: sum of Y over all fermions = 0.
pub fn verifyAnomalyCancellation() bool {
    var sum: i32 = 0;
    for (FERMION_STATES) |f| {
        sum += @as(i32, f.hypercharge);
    }
    return sum == 0;
}

/// Verify color structure: 6 quark states have color 1-3, 6 anti-quark states have color 4-6.
pub fn verifyColorStructure() bool {
    var quark_colors: u8 = 0;
    var antiquark_colors: u8 = 0;
    for (FERMION_STATES) |f| {
        if (f.color >= 1 and f.color <= 3) quark_colors += 1;
        if (f.color >= 4 and f.color <= 6) antiquark_colors += 1;
    }
    return quark_colors == 6 and antiquark_colors == 6;
}

/// Verify the mass matrix dimension: 15² = 225.
pub fn verifyMassMatrixDimension() bool {
    return SM_STATES * SM_STATES == 225;
}

/// Verify the E8 connection: 15 × 16 = 240.
pub fn verifyE8Connection() bool {
    return SM_STATES * TOTAL_STATES == 240;
}

/// Verify the shell transition: 16³ - 15³ = 721 = 3(240) + 1.
pub fn verifyShellTransition() bool {
    const closure = TOTAL_STATES * TOTAL_STATES * TOTAL_STATES;
    const interior = SM_STATES * SM_STATES * SM_STATES;
    return closure - interior == 721 and 721 == 3 * 240 + 1;
}

/// Find a fermion by name. Returns the index if found, null otherwise.
pub fn findFermion(name: []const u8) ?usize {
    for (FERMION_STATES, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// Get all fermions with a given electric charge (scaled by 6).
pub fn fermionsWithCharge(charge: i8, buf: []usize) usize {
    var idx: usize = 0;
    for (FERMION_STATES, 0..) |f, i| {
        if (f.electric_charge == charge) {
            if (idx < buf.len) {
                buf[idx] = i;
                idx += 1;
            }
        }
    }
    return idx;
}

// =============================================================================
// Tests
// =============================================================================

test "SO(10) chiral spinor has 16 states" {
    try std.testing.expectEqual(@as(usize, 16), FERMION_STATES.len);
    try std.testing.expect(verifyStateCount());
}

test "16 = 15 SM fermions + 1 sterile neutrino" {
    try std.testing.expectEqual(@as(usize, 15), countSMStates());
    try std.testing.expectEqual(@as(usize, 1), countSterileStates());
}

test "unique electric charges are {-1, -2/3, -1/3, 0, 1/3, 2/3, 1}" {
    try std.testing.expect(verifyUniqueCharges());
}

test "all charges are multiples of 1/3 (charge quantization)" {
    try std.testing.expect(verifyChargeQuantization());
}

test "Gell-Mann–Nishijima formula Q = T₃ + Y holds for all fermions" {
    try std.testing.expect(verifyGellMannNishijima());
}

test "anomaly cancellation: sum of hypercharges = 0" {
    try std.testing.expect(verifyAnomalyCancellation());
}

test "color structure: 6 quarks + 6 antiquarks" {
    try std.testing.expect(verifyColorStructure());
}

test "mass matrix dimension = 225 = 15²" {
    try std.testing.expect(verifyMassMatrixDimension());
}

test "E8 connection: 15 × 16 = 240" {
    try std.testing.expect(verifyE8Connection());
}

test "shell transition: 16³ - 15³ = 721 = 3(240) + 1" {
    try std.testing.expect(verifyShellTransition());
}

test "u quark has charge +2/3" {
    try std.testing.expectEqual(@as(i8, 4), FERMION_STATES[0].electric_charge);
}

test "d quark has charge -1/3" {
    try std.testing.expectEqual(@as(i8, -2), FERMION_STATES[3].electric_charge);
}

test "electron has charge -1" {
    try std.testing.expectEqual(@as(i8, -6), FERMION_STATES[7].electric_charge);
}

test "neutrino has charge 0" {
    try std.testing.expectEqual(@as(i8, 0), FERMION_STATES[6].electric_charge);
}

test "sterile neutrino has charge 0" {
    try std.testing.expectEqual(@as(i8, 0), FERMION_STATES[15].electric_charge);
    try std.testing.expect(!FERMION_STATES[15].is_sm);
}

test "findFermion locates fermions by name" {
    const idx = findFermion("ν_L");
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 6), idx.?);
    try std.testing.expect(findFermion("nonexistent") == null);
}

test "fermionsWithCharge finds all fermions with a given charge" {
    var buf: [16]usize = undefined;
    // Charge +2/3 (scaled: 4) should find 3 u_L quarks
    const count = fermionsWithCharge(4, &buf);
    try std.testing.expectEqual(@as(usize, 3), count);
    // Charge -1 (scaled: -6) should find 1 e_L
    const count2 = fermionsWithCharge(-6, &buf);
    try std.testing.expectEqual(@as(usize, 1), count2);
}

test "so10 uses integer types (no f64)" {
    const f = FERMION_STATES[0];
    try std.testing.expect(@TypeOf(f.electric_charge) == i8);
    try std.testing.expect(@TypeOf(f.weak_isospin) == i8);
    try std.testing.expect(@TypeOf(f.hypercharge) == i8);
}

// =============================================================================
// Framework Cross-Verification (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Verifies the SO(10) spinor dimension is 16 = 15 + 1 (SM fermions + sterile neutrino).
pub fn verifySpinorDecompositionMatchesFramework() bool {
    return FERMION_STATES.len == 16;
}

/// Verifies the SM fermion count is 15 (excluding the sterile neutrino).
pub fn verifySMFermionCountMatchesFramework() bool {
    var sm_count: u32 = 0;
    for (FERMION_STATES) |f| {
        if (f.is_sm) sm_count += 1;
    }
    return sm_count == 15;
}

/// Verifies the 16 = 15 + 1 decomposition: 15 SM fermions + 1 sterile neutrino.
pub fn verify16Equals15Plus1() bool {
    var sm_count: u32 = 0;
    var sterile_count: u32 = 0;
    for (FERMION_STATES) |f| {
        if (f.is_sm) sm_count += 1 else sterile_count += 1;
    }
    return sm_count == 15 and sterile_count == 1 and sm_count + sterile_count == 16;
}

test "framework: SO(10) spinor dimension 16 = 15 + 1" {
    try std.testing.expect(verifySpinorDecompositionMatchesFramework());
    try std.testing.expect(verify16Equals15Plus1());
}

test "framework: SM fermion count is 15" {
    try std.testing.expect(verifySMFermionCountMatchesFramework());
}
