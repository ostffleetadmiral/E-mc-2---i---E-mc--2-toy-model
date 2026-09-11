const std = @import("std");

pub fn triad(a: i32, b: i32, c: i32) f64 {
    return std.math.pow(f64, (1.0 + std.math.sqrt(5.0)) / 2.0, @floatFromInt(a)) +
        std.math.pow(f64, std.math.pi, @floatFromInt(b)) +
        std.math.pow(f64, (1.0 + std.math.sqrt(5.0)) / 2.0, @floatFromInt(c));
}

test "hydrogen triad sidecar value" {
    const value = triad(5, 2, -4);
    try std.testing.expectApproxEqAbs(@as(f64, 21.10567237858915), value, 1e-12);
}

test "naive alpha inverse sidecar failure" {
    const value = triad(3, 2, 10);
    try std.testing.expect(@abs(value - 137.035999177) > 0.01);
}
