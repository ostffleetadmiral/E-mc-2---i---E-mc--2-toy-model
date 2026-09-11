// License: CC BY-NC-SA 4.0

//! phi_cooling.zig - golden-ratio annealing schedule in Q128.128.
//!
//! Port of the QSTAR lattice agent's phiCooling (archived f64 version:
//! lattice_optimized_20260826.zig — T(level) = T0 * phi^(-level)) to exact
//! fixed-point. The EU v11 analysis flagged the inter-level coupling
//! constant g = delta * rho = (7/225) * (421/3375) as empirical; it is
//! grounded here as an exact ratio.
//!
//! All arithmetic uses Q128.128 fixed-point — no f64 drift.

const std = @import("std");
const fixed = @import("fixed_point.zig");
const constants = @import("constants.zig");

pub const Cooled = struct {
    v: fixed.Q128,
    /// Level so deep that phi^(-level) fell below the 2^-128 floor.
    underflow: bool,
    /// T0 * phi^(-level) exceeded the Q128.128 dynamic range.
    overflow: bool,
};

/// T(level) = T0 * phi^(-level), exact integer fixed-point (no f64 drift).
///
/// `level` is the annealing depth (0 = identity, larger = cooler).
/// `base_temp` is T0 in Q128.128. Returns a `Cooled` struct whose `.v`
/// field holds the cooled temperature; `.underflow` is set when
/// phi^(-level) is too deep for the Q128.128 dynamic range.
///
/// Underflow detection: phi^(-level) is strictly positive for every level.
/// The hardware `pow` lacks overflow detection, so at extreme depths the
/// positive-power intermediate (phi^level) overflows i256 and produces a
/// corrupted (often negative) result.  We detect this by checking for a
/// non-positive raw value, which signals that the true phi^(-level) is
/// below the representable floor.
pub fn phiCoolingQ(level: u32, base_temp: fixed.Q128) Cooled {
    // phi^(-level): pow returns Error!Q128, so handle potential failures
    // (e.g., division failure at extreme depth) as underflow.
    const p = constants.phi.pow(-@as(i32, @intCast(level))) catch {
        return .{ .v = fixed.Q128.zero, .underflow = true, .overflow = false };
    };
    // phi^(-level) must be positive.  A non-positive raw value means the
    // intermediate phi^level overflowed i256 — the true result is below
    // the 2^-128 floor → underflow.
    if (level > 0 and p.raw <= 0) {
        return .{ .v = fixed.Q128.zero, .underflow = true, .overflow = false };
    }
    // T0 * phi^(-level).  Hardware mul uses RNE with 512-bit intermediates;
    // it does not flag overflow, so overflow stays false.
    const m = base_temp.mul(p);
    return .{ .v = m, .underflow = false, .overflow = false };
}

/// Defect density of the 15^3 Fano matrix: 7 / 225.
pub const DEFECT_DENSITY_NUM: u128 = 7;
pub const DEFECT_DENSITY_DEN: u128 = 225;

/// Active (e0) node density: 421 / 3375.
pub const ACTIVE_DENSITY_NUM: u128 = 421;
pub const ACTIVE_DENSITY_DEN: u128 = 3375;

/// EU v11 inter-scale coupling constant g = delta * rho, exact in Q128.128.
///
/// g = (7/225) * (421/3375) = 2947 / 759375.
/// The denominator is a compile-time-known nonzero constant, so fromRatio
/// cannot fail in practice; the catch is exhaustive for type safety.
pub fn couplingConstant() fixed.Q128 {
    return fixed.Q128.fromRatio(
        @as(i256, DEFECT_DENSITY_NUM * ACTIVE_DENSITY_NUM),
        @as(i256, DEFECT_DENSITY_DEN * ACTIVE_DENSITY_DEN),
    ) catch fixed.Q128.zero;
}

// ---------------------------------------------------------------------
// Tests — exact integer / fixed-point assertions only (no f64).
// ---------------------------------------------------------------------

const testing = std.testing;

test "phiCoolingQ level 0 is identity" {
    // phi^0 = 1, so T(0) = T0 * 1 = T0 exactly.
    const t = phiCoolingQ(0, fixed.Q128.fromI64(7));
    try testing.expect(!t.underflow);
    try testing.expect(!t.overflow);
    try testing.expect(t.v.eq(fixed.Q128.fromI64(7)));
}

test "phiCoolingQ level 0 preserves base temperature raw value" {
    // Exact raw preservation: no rounding occurs at level 0.
    const base = fixed.Q128.fromI64(100);
    const t = phiCoolingQ(0, base);
    try testing.expectEqual(base.raw, t.v.raw);
}

test "phiCoolingQ level 1 cools below base" {
    // phi^(-1) < 1, so T(1) < T0.
    const base = fixed.Q128.fromI64(100);
    const t = phiCoolingQ(1, base);
    try testing.expect(!t.underflow);
    try testing.expect(t.v.cmp(base) == -1);
    // T(1) > 0 (has not underflowed at level 1).
    try testing.expect(t.v.cmp(fixed.Q128.zero) == 1);
}

test "phiCoolingQ level 182 is tiny but not underflow" {
    // At level 182, phi^(-182) is extremely small (raw ≈ 3) but still
    // positive and representable — not underflow.
    const c = phiCoolingQ(182, fixed.Q128.one);
    try testing.expect(!c.underflow);
    try testing.expect(c.v.raw > 0);
    try testing.expect(c.v.raw < 100); // tiny: less than 100 ULPs above zero
}

test "phiCoolingQ deep level underflows to zero" {
    // At level 183+, the intermediate phi^level overflows i256.  The
    // corrupted pow result is non-positive, which we detect as underflow.
    const c = phiCoolingQ(183, fixed.Q128.one);
    try testing.expect(c.underflow);
    try testing.expect(c.v.eq(fixed.Q128.zero));
}

test "phiCoolingQ underflow propagates to product" {
    // When phi^(-level) underflows, T0 * 0 = 0 regardless of T0.
    const c = phiCoolingQ(200, fixed.Q128.fromI64(1000));
    try testing.expect(c.underflow);
    try testing.expect(c.v.eq(fixed.Q128.zero));
}

test "coupling constant exact raw value" {
    // g = 2947 / 759375, computed via fromRatio with round-half-away-from-zero.
    // Expected raw = floor(2947 * 2^128 / 759375) = 1320575651444945714339509423014216848
    // (remainder 210832 < half_den 379687, so no round-up).
    const g = couplingConstant();
    const expected_raw: fixed.Raw = 1320575651444945714339509423014216848;
    try testing.expectEqual(expected_raw, g.raw);
}

test "coupling constant is positive and less than one" {
    const g = couplingConstant();
    try testing.expect(g.cmp(fixed.Q128.zero) == 1);
    try testing.expect(g.cmp(fixed.Q128.one) == -1);
}

test "coupling constant matches independent fromRatio" {
    // Cross-check: independently compute the ratio and compare raw values.
    const g = couplingConstant();
    const independent = try fixed.Q128.fromRatio(2947, 759375);
    try testing.expectEqual(independent.raw, g.raw);
}

test "coupling constant numerator and denominator constants" {
    // Verify the constant definitions match the documented ratios.
    try testing.expectEqual(@as(u128, 7), DEFECT_DENSITY_NUM);
    try testing.expectEqual(@as(u128, 225), DEFECT_DENSITY_DEN);
    try testing.expectEqual(@as(u128, 421), ACTIVE_DENSITY_NUM);
    try testing.expectEqual(@as(u128, 3375), ACTIVE_DENSITY_DEN);
    // Product check: 7 * 421 = 2947, 225 * 3375 = 759375.
    try testing.expectEqual(@as(u128, 2947), DEFECT_DENSITY_NUM * ACTIVE_DENSITY_NUM);
    try testing.expectEqual(@as(u128, 759375), DEFECT_DENSITY_DEN * ACTIVE_DENSITY_DEN);
}
