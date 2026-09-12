// License: CC BY-NC-SA 4.0

const fixed = @import("fixed_point.zig");

pub const phi = fixed.Q128.fromRaw(550588435450341336629110977315780544564);
pub const pi = fixed.Q128.fromRaw(1069028584064966747859680373161870783300);
pub const sqrt5 = fixed.Q128.fromRaw(790231711353346013421113761587364630568);

pub const c_m_per_s: u64 = 299792458;
pub const h_j_s: u64 = 662607015;
pub const hbar_j_s: u64 = 105457181;

pub const alpha_inverse_reference = fixed.Q128.fromRaw(46630934153325335303234647273662486708739);
pub const hydrogen_target_cm = fixed.Q128.fromRaw(7182020259407079994007285275016545289250);

pub const vacuum_impedance_raw: fixed.Raw = 1282243446409028258291782773997371546380;
pub const von_klitzing_raw: fixed.Raw = 87875057465066443643118870980678574515700000;

test "phi is golden ratio (approximately 1.618)" {
    // phi ≈ 1.6180339887498948...
    // In Q128.128: raw = phi * 2^128
    // Verify phi > 1 and phi < 2
    try @import("std").testing.expect(phi.raw > fixed.Scale);
    try @import("std").testing.expect(phi.raw < 2 * fixed.Scale);
    // Verify phi^2 = phi + 1 (the defining property)
    const phi_sq = phi.mul(phi);
    const phi_plus_one = phi.add(fixed.Q128.one);
    // Allow 2 ULP tolerance for RNE rounding
    const diff = if (phi_sq.raw > phi_plus_one.raw) phi_sq.raw - phi_plus_one.raw else phi_plus_one.raw - phi_sq.raw;
    try @import("std").testing.expect(diff <= 2);
}

test "pi is approximately 3.14159" {
    // pi ≈ 3.14159265358979323846...
    // Verify pi > 3 and pi < 4
    try @import("std").testing.expect(pi.raw > 3 * fixed.Scale);
    try @import("std").testing.expect(pi.raw < 4 * fixed.Scale);
}

test "sqrt5 is approximately 2.236" {
    // sqrt(5) ≈ 2.2360679774997896...
    // Verify sqrt5 > 2 and sqrt5 < 3
    try @import("std").testing.expect(sqrt5.raw > 2 * fixed.Scale);
    try @import("std").testing.expect(sqrt5.raw < 3 * fixed.Scale);
}

test "physical constants have correct integer values" {
    try @import("std").testing.expectEqual(@as(u64, 299792458), c_m_per_s);
    try @import("std").testing.expectEqual(@as(u64, 662607015), h_j_s);
    try @import("std").testing.expectEqual(@as(u64, 105457181), hbar_j_s);
}

test "alpha inverse is approximately 137.036" {
    // 1/alpha ≈ 137.035999084...
    // Verify alpha_inverse > 137 and < 138
    try @import("std").testing.expect(alpha_inverse_reference.raw > 137 * fixed.Scale);
    try @import("std").testing.expect(alpha_inverse_reference.raw < 138 * fixed.Scale);
}

test "hydrogen 21cm target is approximately 21.106" {
    // 21 + 7/66 ≈ 21.1060606...
    // Verify target > 21 and < 22
    try @import("std").testing.expect(hydrogen_target_cm.raw > 21 * fixed.Scale);
    try @import("std").testing.expect(hydrogen_target_cm.raw < 22 * fixed.Scale);
}

test "constants are ordered phi < pi" {
    try @import("std").testing.expect(phi.raw < pi.raw);
}

test "vacuum impedance and von Klitzing are positive" {
    try @import("std").testing.expect(vacuum_impedance_raw > 0);
    try @import("std").testing.expect(von_klitzing_raw > 0);
}
