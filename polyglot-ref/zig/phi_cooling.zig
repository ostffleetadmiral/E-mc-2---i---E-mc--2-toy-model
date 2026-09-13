//! phi_cooling.zig - golden-ratio annealing schedule in Q128.128.
//!
//! Port of the QSTAR lattice agent's phiCooling (archived f64 version:
//! lattice_optimized_20260826.zig — T(level) = T0 * phi^(-level)) to exact
//! fixed-point. The EU v11 analysis flagged the inter-level coupling
//! constant g = delta * rho = (7/225) * (421/3375) as empirical; it is
//! grounded here as an exact ratio and fitted onto the (phi, pi) triad
//! lattice via triad.fit.

const std = @import("std");
const Q = @import("q128_128");
const triad = @import("triad");

pub const Cooled = struct {
    v: Q.q128,
    /// Level so deep that phi^(-level) fell below the 2^-128 floor.
    underflow: bool,
    /// T0 * phi^(-level) exceeded the Q128.128 dynamic range.
    overflow: bool,
};

/// T(level) = T0 * phi^(-level), exact integer fixed-point (no f64 drift).
pub fn phiCoolingQ(level: u32, base_temp: Q.q128) Cooled {
    const p = Q.q128Pow(Q.PHI_RAW, -@as(i32, @intCast(level)));
    const m = Q.q128Mul(base_temp, p.v);
    return .{ .v = m.v, .underflow = p.underflow, .overflow = m.overflow };
}

/// Defect density of the 15^3 Fano matrix: 7 / 225.
pub const DEFECT_DENSITY_NUM: u128 = 7;
pub const DEFECT_DENSITY_DEN: u128 = 225;

/// Active (e0) node density: 421 / 3375.
pub const ACTIVE_DENSITY_NUM: u128 = 421;
pub const ACTIVE_DENSITY_DEN: u128 = 3375;

/// EU v11 inter-scale coupling constant g = delta * rho, exact in Q128.128.
pub fn couplingConstant() Q.q128 {
    // g = (7/225) * (421/3375) = 2947 / 759375
    return Q.q128FromRatio(DEFECT_DENSITY_NUM * ACTIVE_DENSITY_NUM, DEFECT_DENSITY_DEN * ACTIVE_DENSITY_DEN);
}

/// Fit the coupling constant onto the (phi, pi) triad lattice.
pub fn fitCoupling(bound: i32) triad.FitResult {
    return triad.fit(Q.toFloat(couplingConstant()), bound);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "phiCoolingQ matches archived f64 reference" {
    // Reference: base_temp * pow(f64, PHI, -level) from
    // .Archives/lattice_optimized_20260826.zig phiCooling().
    var level: u32 = 0;
    while (level <= 64) : (level += 1) {
        const got = phiCoolingQ(level, Q.q128FromF64(100.0));
        const want = 100.0 * std.math.pow(f64, 1.6180339887498948482, -@as(f64, @floatFromInt(level)));
        const gf = Q.toFloat(got.v);
        try testing.expect(!got.underflow);
        try testing.expect(@abs(gf - want) / want < 1e-12);
    }
}

test "phiCoolingQ level 0 is identity" {
    const t = phiCoolingQ(0, Q.q128FromI64(7));
    try testing.expect(!t.underflow);
    try testing.expect(Q.q128Eq(t.v, Q.q128FromI64(7)));
}

test "phiCoolingQ deep level underflows" {
    // phi^-200 is below the epsilon floor.
    const c = phiCoolingQ(200, Q.Q_ONE);
    try testing.expect(c.underflow);
    try testing.expect(Q.q128Eq(c.v, Q.Q_ZERO));
}

test "coupling constant exact ratio" {
    const g = couplingConstant();
    try testing.expect(@abs(Q.toFloat(g) - 2947.0 / 759375.0) < 1e-18);
    try testing.expect(@abs(Q.toFloat(g) - 0.0038809) < 1e-6);
}
