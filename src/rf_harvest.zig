// License: CC BY-NC-SA 4.0

//! rf_harvest.zig - RF energy harvesting link budget in Q128.128.
//!
//! Real physics, exact fixed-point: Friis free-space link budget,
//! Johnson-Nyquist noise floor, Greinacher (CW) rectifier DC model, and
//! near-field magnetic loop coupling for CPU-clock EMI scavenging.
//! Research basis: x/rf_research.md (Imperial College 2013 London RF
//! survey; metamaterial harvester state of the art; via-loop interconnect
//! harvesting).
//!
//! Ported from the Q128.128 (FANO-1) project's rf_harvest.zig to the
//! hardware project's fixed_point.zig / constants.zig API.  No floating
//! point is used in any core computation or test assertion.

const std = @import("std");
const fixed = @import("fixed_point.zig");
const constants = @import("constants.zig");

const Q128 = fixed.Q128;
const Raw = fixed.Raw;
const Wide = fixed.Wide;
const Scale = fixed.Scale;

/// Speed of light, exact (m/s).
pub const C_LIGHT: u128 = 299792458;

/// Boltzmann constant, exact SI definition: 1.380649e-23 J/K.
/// Stored as a rational 1380649 / 10^29 so it can be constructed with
/// fromRatio without any floating-point literal.
pub const K_B_NUM: u128 = 1380649;
pub const K_B_DEN: u128 = 100_000_000_000_000_000_000_000_000_000;

/// Vacuum permeability (pre-2019 exact): mu0 = 4*pi*10^-7 H/m.
pub fn mu0() fixed.Error!Q128 {
    return (try Q128.fromRatio(4, 10_000_000)).mul(constants.pi);
}

/// 10^(1/10) via Newton iteration on x^10 = 10 (for dBm conversion).
/// Iteration: x' = 0.9*x + 1/x^9  (Newton update for x^10 = 10).
pub fn tenTenth() fixed.Error!Q128 {
    var x = try Q128.fromRatio(126, 100);
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const x9 = try x.pow(9);
        const corr = try Q128.one.div(x9);
        const nx = (try Q128.fromRatio(9, 10)).mul(x).add(corr);
        if (nx.eq(x)) break;
        x = nx;
    }
    return x;
}

/// dBm to watts: P = 10^(dBm/10) * 1e-3.
pub fn dbmToW(dbm: i32) fixed.Error!Q128 {
    const p = try (try tenTenth()).pow(dbm);
    return p.mul(try Q128.fromRatio(1, 1000));
}

/// Wavelength lambda = c / f (meters).
pub fn wavelengthM(f_hz: u128) fixed.Error!Q128 {
    return try Q128.fromI64(299792458).div(
        try Q128.fromRatio(@as(i256, @intCast(f_hz)), 1),
    );
}

pub const FriisResult = struct { pr_w: Q128, far_field: bool };

/// Friis received power: Pr = Pt * Gt * Gr * (lambda / (4 pi d))^2.
/// Gains are linear ratios; Pt in dBm; d in meters.
pub fn friisReceivedW(
    pt_dbm: i32,
    gt: u128,
    gr: u128,
    f_hz: u128,
    d_m: Q128,
) fixed.Error!FriisResult {
    const pt = try dbmToW(pt_dbm);
    const lam = try wavelengthM(f_hz);
    const four_pi = Q128.fromI64(4).mul(constants.pi);
    const den = four_pi.mul(d_m);
    const ratio = try lam.div(den);
    const p1 = pt.mul(try Q128.fromRatio(@as(i256, @intCast(gt)), 1));
    const p2 = p1.mul(try Q128.fromRatio(@as(i256, @intCast(gr)), 1));
    return .{
        .pr_w = p2.mul(ratio.mul(ratio)),
        .far_field = Q128.cmp(ratio, Q128.one) < 0,
    };
}

/// Johnson-Nyquist noise floor: P = k * T * B (watts).
pub fn johnsonNoiseW(t_k: Q128, bw_hz: Q128) fixed.Error!Q128 {
    const k = try Q128.fromRatio(
        @as(i256, @intCast(K_B_NUM)),
        @as(i256, @intCast(K_B_DEN)),
    );
    return k.mul(t_k).mul(bw_hz);
}

/// Greinacher voltage-doubler DC output: Vdc = 2N (sqrt(2 Pr Rs) - Vd).
pub fn greinacherVdc(
    pr_w: Q128,
    rs_ohm: Q128,
    n_stages: u32,
    vd_v: Q128,
) fixed.Error!Q128 {
    const two_pr_rs = Q128.fromI64(2).mul(pr_w.mul(rs_ohm));
    const vp = try two_pr_rs.sqrt();
    const per_stage = vp.sub(vd_v);
    if (Q128.cmp(per_stage, Q128.zero) <= 0) return Q128.zero;
    return Q128.fromI64(2 * @as(i64, n_stages)).mul(per_stage);
}

/// Harvested energy: E = P * t (joules).
/// Pure multiply — no division or root, so no error union.
pub fn harvestJ(pr_w: Q128, seconds: Q128) Q128 {
    return pr_w.mul(seconds);
}

/// Capacitor voltage from stored energy: V = sqrt(2E/C).
pub fn capacitorV(e_j: Q128, c_f: Q128) fixed.Error!Q128 {
    const two_e = Q128.fromI64(2).mul(e_j);
    return try (try two_e.div(c_f)).sqrt();
}

/// Near-field loop EMF (Faraday): emf = mu0 * f * I * A / R for a small
/// loop of area A at distance R from a conductor carrying I at frequency f.
pub fn nearFieldLoopEmf(
    i_a: Q128,
    f_hz: u128,
    area_m2: Q128,
    r_m: Q128,
) fixed.Error!Q128 {
    const a = (try mu0()).mul(
        try Q128.fromRatio(@as(i256, @intCast(f_hz)), 1),
    );
    const b = a.mul(i_a);
    const c = b.mul(area_m2);
    return try c.div(r_m);
}

/// Matched-load power from the loop EMF: P = emf^2 / (8 R).
pub fn nearFieldLoopPowerW(emf_v: Q128, r_ohm: Q128) fixed.Error!Q128 {
    const e2 = emf_v.mul(emf_v);
    const den = Q128.fromI64(8).mul(r_ohm);
    return try e2.div(den);
}

// ---------------------------------------------------------------------
// Tests — all assertions use exact integer comparisons, no f64.
// ---------------------------------------------------------------------

const testing = std.testing;

test "tenTenth converges to 10^(1/10)" {
    const t = try tenTenth();
    const t10 = try t.pow(10);
    const target = Q128.fromInteger(10);
    const diff: Raw = if (t10.raw > target.raw)
        t10.raw - target.raw
    else
        target.raw - t10.raw;
    // After 60 Newton iterations the residual is at most a few ULPs.
    try testing.expect(diff < @as(Raw, 10000));
}

test "dbm to watts: 0 dBm = 1 milliwatt (exact)" {
    // 10^(0/10) * 1e-3 = 1e-3 W.  In raw units this is Scale / 1000.
    // fromRatio(1, 1000) with round-half-away: remainder = 456 < 500,
    // so no rounding occurs and raw == Scale / 1000 exactly.
    const w = try dbmToW(0);
    try testing.expectEqual(@as(Raw, Scale / 1000), w.raw);
}

test "dbm to watts: 30 dBm ≈ 1 W" {
    // 10^(30/10) * 1e-3 = 1 W → raw ≈ Scale.
    const w = try dbmToW(30);
    const diff: Raw = if (w.raw > Scale) w.raw - Scale else Scale - w.raw;
    try testing.expect(diff < @as(Raw, 100000));
}

test "dbm to watts: -30 dBm ≈ 1 microwatt" {
    // 10^(-30/10) * 1e-3 = 1e-6 W → raw ≈ Scale / 1_000_000.
    const w = try dbmToW(-30);
    const target: Raw = Scale / 1_000_000;
    const diff: Raw = if (w.raw > target) w.raw - target else target - w.raw;
    try testing.expect(diff < @as(Raw, 1_000_000));
}

test "wavelength 2.45 GHz is in [0.122, 0.123) m" {
    const lam = try wavelengthM(2_450_000_000);
    try testing.expect(lam.raw > Scale * 122 / 1000);
    try testing.expect(lam.raw < Scale * 123 / 1000);
}

test "friis 1 mW isotropic at 1 m, 2.45 GHz" {
    // Pr = 1e-3 * (0.1224/(4 pi))^2 ≈ 9.49e-8 W.
    const result = try friisReceivedW(0, 1, 1, 2_450_000_000, Q128.fromI64(1));
    // 9.49e-8 is between 1e-8 and 1e-7.
    try testing.expect(result.pr_w.raw > Scale / 100_000_000);
    try testing.expect(result.pr_w.raw < Scale / 10_000_000);
    // lambda / (4 pi d) < 1 → far field.
    try testing.expect(result.far_field);
}

test "johnson noise 290 K 1 MHz" {
    // k*T*B = 1.380649e-23 * 290 * 1e6 ≈ 4.004e-15 W.
    // raw ≈ 4.004e-15 * Scale ≈ 1.362e24.
    const p = try johnsonNoiseW(
        Q128.fromI64(290),
        try Q128.fromRatio(1_000_000, 1),
    );
    try testing.expect(p.raw > @as(Raw, 1_300_000_000_000_000_000_000_000));
    try testing.expect(p.raw < @as(Raw, 1_400_000_000_000_000_000_000_000));
}

test "greinacher rectifier" {
    // Pr = 1 mW, Rs = 50 Ω, N = 2, Vd = 0.15 V.
    // Vp = sqrt(2 * 1e-3 * 50) ≈ 0.31623; Vdc = 4*(0.31623-0.15) ≈ 0.6649 V.
    const pr = try Q128.fromRatio(1, 1000);
    const rs = Q128.fromI64(50);
    const vd = try Q128.fromRatio(15, 100);
    const vdc = try greinacherVdc(pr, rs, 2, vd);
    // 0.6 < Vdc < 0.7
    try testing.expect(vdc.raw > Scale * 6 / 10);
    try testing.expect(vdc.raw < Scale * 7 / 10);
}

test "harvest energy exact identity: E = P * t" {
    const p = Q128.fromI64(7);
    const t = Q128.fromI64(11);
    try testing.expectEqual(harvestJ(p, t).raw, p.mul(t).raw);
}

test "capacitor voltage sqrt(2)" {
    // V = sqrt(2*1/1) = sqrt(2).  Check v^2 is close to 2 * Scale^2
    // using 512-bit (Wide) integer arithmetic.
    const v = try capacitorV(Q128.fromI64(1), Q128.fromI64(1));
    const v_sq: Wide = @as(Wide, v.raw) * @as(Wide, v.raw);
    const target: Wide = @as(Wide, 2) * @as(Wide, Scale) * @as(Wide, Scale);
    const diff: Wide = if (v_sq > target) v_sq - target else target - v_sq;
    // sqrt returns floor(sqrt(s * 2^128)), so the squared error is at
    // most ~2*v ≈ 2*sqrt(2)*Scale.  10*Scale is a generous tolerance.
    try testing.expect(diff < @as(Wide, 10) * @as(Wide, Scale));
}

test "near-field loop coupling" {
    // 20 mA at 3 GHz, 1 cm^2 loop at 2 cm: EMF ≈ 0.377 V.
    const i_val = try Q128.fromRatio(2, 100);
    const area = try Q128.fromRatio(1, 10000);
    const r = try Q128.fromRatio(2, 100);
    const emf = try nearFieldLoopEmf(i_val, 3_000_000_000, area, r);
    // 0.3 < EMF < 0.4
    try testing.expect(emf.raw > Scale * 3 / 10);
    try testing.expect(emf.raw < Scale * 4 / 10);

    // P = emf^2 / (8 * 100 Ω) ≈ 0.178 mW → between 1e-4 and 1e-3 W.
    const p = try nearFieldLoopPowerW(
        try Q128.fromRatio(377, 1000),
        Q128.fromI64(100),
    );
    try testing.expect(p.raw > Scale / 10_000);
    try testing.expect(p.raw < Scale / 1_000);
}
