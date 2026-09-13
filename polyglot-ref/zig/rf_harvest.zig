//! rf_harvest.zig - RF energy harvesting link budget in Q128.128.
//!
//! Real physics, exact fixed-point: Friis free-space link budget,
//! Johnson-Nyquist noise floor, Greinacher (CW) rectifier DC model, and
//! near-field magnetic loop coupling for CPU-clock EMI scavenging.
//! Research basis: x/rf_research.md (Imperial College 2013 London RF
//! survey; metamaterial harvester state of the art; via-loop interconnect
//! harvesting).

const std = @import("std");
const Q = @import("q128_128");

/// Speed of light, exact.
pub const C_LIGHT: u128 = 299792458;

/// Boltzmann constant, exact SI definition: 1.380649e-23 J/K.
pub const K_B_NUM: u128 = 1380649;
pub const K_B_DEN: u128 = 100_000_000_000_000_000_000_000_000_000;

/// Vacuum permeability (pre-2019 exact): 4*pi*10^-7 H/m.
pub fn mu0() Q.q128 {
    return Q.q128Mul(Q.q128FromRatio(4, 10_000_000), Q.PI_RAW).v;
}

/// 10^(1/10) via Newton iteration on x^10 = 10 (for dBm conversion).
pub fn tenTenth() Q.q128 {
    var x = Q.q128FromRatio(126, 100);
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        // Newton for x^10 = 10: x' = 0.9x + 1/x^9
        const x9 = Q.q128Pow(x, 9);
        const corr = Q.q128DivRound(Q.Q_ONE, x9.v);
        const nx = Q.q128Add(Q.q128Mul(Q.q128FromRatio(9, 10), x).v, corr);
        if (Q.q128Eq(nx, x)) break;
        x = nx;
    }
    return x;
}

/// dBm to watts: P = 10^(dBm/10) * 1e-3.
pub fn dbmToW(dbm: i32) Q.q128 {
    const p = Q.q128Pow(tenTenth(), dbm);
    return Q.q128Mul(p.v, Q.q128FromRatio(1, 1000)).v;
}

/// Wavelength lambda = c / f (meters).
pub fn wavelengthM(f_hz: u128) Q.q128 {
    return Q.q128Div(Q.q128FromI64(299792458), Q.q128FromRatio(f_hz, 1));
}

pub const FriisResult = struct { pr_w: Q.q128, far_field: bool };

/// Friis received power: Pr = Pt * Gt * Gr * (lambda / (4 pi d))^2.
/// Gains are linear ratios; Pt in dBm; d in meters.
pub fn friisReceivedW(pt_dbm: i32, gt: u128, gr: u128, f_hz: u128, d_m: Q.q128) FriisResult {
    const pt = dbmToW(pt_dbm);
    const lam = wavelengthM(f_hz);
    const four_pi = Q.q128Mul(Q.q128FromI64(4), Q.PI_RAW).v;
    const den = Q.q128Mul(four_pi, d_m).v;
    const ratio = Q.q128Div(lam, den);
    const p1 = Q.q128Mul(pt, Q.q128FromRatio(gt, 1)).v;
    const p2 = Q.q128Mul(p1, Q.q128FromRatio(gr, 1)).v;
    return .{
        .pr_w = Q.q128Mul(p2, Q.q128Mul(ratio, ratio).v).v,
        .far_field = Q.q128Cmp(ratio, Q.Q_ONE) < 0,
    };
}

/// Johnson-Nyquist noise floor: P = k * T * B (watts).
pub fn johnsonNoiseW(t_k: Q.q128, bw_hz: Q.q128) Q.q128 {
    const k = Q.q128FromRatio(K_B_NUM, K_B_DEN);
    return Q.q128Mul(Q.q128Mul(k, t_k).v, bw_hz).v;
}

/// Greinacher voltage-doubler DC output: Vdc = 2N (sqrt(2 Pr Rs) - Vd).
pub fn greinacherVdc(pr_w: Q.q128, rs_ohm: Q.q128, n_stages: u32, vd_v: Q.q128) Q.q128 {
    const two_pr_rs = Q.q128Mul(Q.q128FromI64(2), Q.q128Mul(pr_w, rs_ohm).v).v;
    const vp = Q.q128Sqrt(two_pr_rs);
    const per_stage = Q.q128Sub(vp, vd_v);
    if (Q.q128Cmp(per_stage, Q.Q_ZERO) <= 0) return Q.Q_ZERO;
    return Q.q128Mul(Q.q128FromI64(2 * @as(i64, n_stages)), per_stage).v;
}

/// Harvested energy: E = P * t (joules).
pub fn harvestJ(pr_w: Q.q128, seconds: Q.q128) Q.q128 {
    return Q.q128Mul(pr_w, seconds).v;
}

/// Capacitor voltage from stored energy: V = sqrt(2E/C).
pub fn capacitorV(e_j: Q.q128, c_f: Q.q128) Q.q128 {
    const two_e = Q.q128Mul(Q.q128FromI64(2), e_j).v;
    return Q.q128Sqrt(Q.q128Div(two_e, c_f));
}

/// Near-field loop EMF (Faraday): emf = mu0 * f * I * A / r for a small
/// loop of area A at distance r from a conductor carrying I at frequency f.
pub fn nearFieldLoopEmf(i_a: Q.q128, f_hz: u128, area_m2: Q.q128, r_m: Q.q128) Q.q128 {
    const a = Q.q128Mul(mu0(), Q.q128FromRatio(f_hz, 1)).v;
    const b = Q.q128Mul(a, i_a).v;
    const c = Q.q128Mul(b, area_m2).v;
    return Q.q128Div(c, r_m);
}

/// Matched-load power from the loop EMF: P = emf^2 / (8 R).
pub fn nearFieldLoopPowerW(emf_v: Q.q128, r_ohm: Q.q128) Q.q128 {
    const e2 = Q.q128Mul(emf_v, emf_v).v;
    const den = Q.q128Mul(Q.q128FromI64(8), r_ohm).v;
    return Q.q128Div(e2, den);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "tenTenth converges to 10^(1/10)" {
    const t = tenTenth();
    const t10 = Q.q128Pow(t, 10);
    try testing.expect(@abs(Q.toFloat(t10.v) - 10.0) < 1e-8);
}

test "dbm to watts" {
    try testing.expect(@abs(Q.toFloat(dbmToW(0)) - 1e-3) < 1e-12);
    try testing.expect(@abs(Q.toFloat(dbmToW(30)) - 1.0) < 1e-9);
    try testing.expect(@abs(Q.toFloat(dbmToW(-30)) - 1e-6) < 1e-15);
}

test "wavelength 2.45 GHz" {
    const lam = Q.toFloat(wavelengthM(2_450_000_000));
    try testing.expect(@abs(lam - 0.1223643) < 1e-6);
}

test "friis 1 mW isotropic at 1 m, 2.45 GHz" {
    const pr = Q.toFloat(friisReceivedW(0, 1, 1, 2_450_000_000, Q.q128FromI64(1)).pr_w);
    // Pr = 1e-3 * (0.1224/(4 pi))^2 = 9.49e-8 W (~ -70.2 dBm)
    try testing.expect(@abs(pr - 9.49e-8) < 1e-10);
}

test "johnson noise 290 K 1 MHz" {
    const p = Q.toFloat(johnsonNoiseW(Q.q128FromI64(290), Q.q128FromRatio(1_000_000, 1)));
    // k*T*B = 1.380649e-23 * 290 * 1e6 = 4.00388e-15 W
    try testing.expect(@abs(p - 4.0038821e-15) / 4.0038821e-15 < 1e-9);
}

test "greinacher rectifier" {
    const pr = Q.q128FromRatio(1, 1000); // 1 mW
    const rs = Q.q128FromI64(50);
    const vd = Q.q128FromRatio(15, 100);
    const vdc = Q.toFloat(greinacherVdc(pr, rs, 2, vd));
    // Vp = sqrt(2 * 1e-3 * 50) = 0.31623; Vdc = 4*(0.31623-0.15) = 0.6649
    try testing.expect(@abs(vdc - 0.6649) < 1e-3);
}

test "capacitor voltage" {
    const v = Q.toFloat(capacitorV(Q.q128FromI64(1), Q.q128FromI64(1)));
    try testing.expect(@abs(v - 1.4142135623730951) < 1e-6);
}

test "near-field loop coupling" {
    // 20 mA at 3 GHz, 1 cm^2 loop at 2 cm: EMF ~ 0.377 V.
    const i = Q.q128FromRatio(2, 100);
    const area = Q.q128FromRatio(1, 10000);
    const r = Q.q128FromRatio(2, 100);
    const emf = Q.toFloat(nearFieldLoopEmf(i, 3_000_000_000, area, r));
    try testing.expect(@abs(emf - 0.377) < 0.01);
    // P = emf^2 / (8 * 100 ohm) ~ 0.18 mW
    const p = Q.toFloat(nearFieldLoopPowerW(Q.q128FromRatio(377, 1000), Q.q128FromI64(100)));
    try testing.expect(p > 1e-4 and p < 1e-3);
}
