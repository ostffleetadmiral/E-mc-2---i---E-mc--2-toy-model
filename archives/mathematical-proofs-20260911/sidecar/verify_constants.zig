const std = @import("std");
const values = @import("codata_values.zig");

pub fn relativeError(actual: f64, expected: f64) f64 {
    return @abs(actual - expected) / @abs(expected);
}

test "CODATA alpha relationship" {
    try std.testing.expectApproxEqAbs(values.alpha, 1.0 / values.alpha_inverse, 1e-15);
}

test "classical electron radius and Thomson relation" {
    const derived = (8.0 * std.math.pi / 3.0) * values.electron_classical_radius * values.electron_classical_radius;
    try std.testing.expect(relativeError(derived, values.thomson_cross_section) < 1e-9);
}
