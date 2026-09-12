// License: CC BY-NC-SA 4.0

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

test "triad(0,0,0) = 3 (phi^0 + pi^0 + phi^0 = 1+1+1)" {
    const value = triad(0, 0, 0);
    const expected: f64 = 3.0;
    try std.testing.expectApproxEqAbs(expected, value, 1e-15);
}

test "triad is symmetric in a and c" {
    const left = triad(3, 2, 5);
    const right = triad(5, 2, 3);
    try std.testing.expectApproxEqAbs(left, right, 1e-12);
}

test "triad(1,0,0) = phi + 2" {
    const phi: f64 = (1.0 + std.math.sqrt(5.0)) / 2.0;
    const value = triad(1, 0, 0);
    const expected: f64 = phi + 2.0;
    try std.testing.expectApproxEqAbs(expected, value, 1e-12);
}

test "triad(0,1,0) = pi + 2" {
    const value = triad(0, 1, 0);
    const expected: f64 = std.math.pi + 2.0;
    try std.testing.expectApproxEqAbs(expected, value, 1e-12);
}

test "triad(-1,0,0) = 1/phi + 2" {
    const phi: f64 = (1.0 + std.math.sqrt(5.0)) / 2.0;
    const value = triad(-1, 0, 0);
    const expected: f64 = 1.0 / phi + 2.0;
    try std.testing.expectApproxEqAbs(expected, value, 1e-12);
}
