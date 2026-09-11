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
