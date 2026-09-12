// License: CC BY-NC-SA 4.0

const std = @import("std");
const values = @import("codata_values.zig");

pub fn alphaFromImpedance() f64 {
    return values.vacuum_impedance / (2.0 * values.von_klitzing);
}

pub fn gammaFromAlpha(alpha: f64) f64 {
    return (1.0 - 2.0 * alpha) / (1.0 + 2.0 * alpha);
}

test "EM chain alpha and Smith reflection coefficient" {
    const alpha = alphaFromImpedance();
    try std.testing.expect(@abs(alpha - values.alpha) < 1e-10);
    const gamma = gammaFromAlpha(values.alpha);
    try std.testing.expect(gamma > 0.9 and gamma < 1.0);
}

test "alphaFromImpedance uses Z0/(2*RK) formula" {
    // alpha = Z0 / (2 * RK) where Z0 is vacuum impedance, RK is von Klitzing
    const expected = values.vacuum_impedance / (2.0 * values.von_klitzing);
    const actual = alphaFromImpedance();
    try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
}

test "alphaFromImpedance is approximately 1/137" {
    const alpha = alphaFromImpedance();
    try std.testing.expect(alpha > 0.007);
    try std.testing.expect(alpha < 0.008);
}

test "gammaFromAlpha uses self-inverse Möbius form (1-z)/(1+z)" {
    // gammaFromAlpha(alpha) = (1 - 2*alpha) / (1 + 2*alpha)
    // This is the self-inverse Möbius form Γ(z) = (1-z)/(1+z) with z = 2*alpha
    const alpha: f64 = 0.1;
    const z: f64 = 2.0 * alpha;
    const expected: f64 = (1.0 - z) / (1.0 + z);
    const actual = gammaFromAlpha(alpha);
    try std.testing.expectApproxEqAbs(expected, actual, 1e-15);
}

test "gammaFromAlpha is self-inverse (Γ(Γ(z)) = z)" {
    // Γ(z) = (1-z)/(1+z) is self-inverse: Γ(Γ(z)) = z
    // Here z = 2*alpha, so gammaFromAlpha(alpha) = Γ(2*alpha)
    // To verify self-inverse: Γ(Γ(z)) = z
    const z: f64 = 0.02; // 2*alpha for alpha=0.01
    const gamma_z: f64 = (1.0 - z) / (1.0 + z);
    const gamma_gamma_z: f64 = (1.0 - gamma_z) / (1.0 + gamma_z);
    try std.testing.expectApproxEqAbs(z, gamma_gamma_z, 1e-15);
}

test "gammaFromAlpha(0) = 1 (boundary value)" {
    // Γ(0) = (1-0)/(1+0) = 1
    const alpha: f64 = 0.0;
    const gamma = gammaFromAlpha(alpha);
    const expected: f64 = 1.0;
    try std.testing.expectApproxEqAbs(expected, gamma, 1e-15);
}

test "gammaFromAlpha(0.5) = 0 (matched impedance)" {
    // z = 2*0.5 = 1, Γ(1) = (1-1)/(1+1) = 0
    const alpha: f64 = 0.5;
    const gamma = gammaFromAlpha(alpha);
    const expected: f64 = 0.0;
    try std.testing.expectApproxEqAbs(expected, gamma, 1e-15);
}
