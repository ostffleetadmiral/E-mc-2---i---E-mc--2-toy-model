// License: CC BY-NC-SA 4.0

const fixed = @import("fixed_point.zig");
const constants = @import("constants.zig");

pub const Error = fixed.Error;

pub fn evaluate(a: i32, b: i32, c: i32) Error!fixed.Q128 {
    const first = try constants.phi.pow(a);
    const middle = try constants.pi.pow(b);
    const last = try constants.phi.pow(c);
    return first.add(middle).add(last);
}

pub fn absoluteErrorPercent(actual: fixed.Q128, expected: fixed.Q128) Error!fixed.Q128 {
    return fixed.Q128.relativeErrorPercent(actual, expected);
}

test "hydrogen triad signature" {
    const value = try evaluate(5, 2, -4);
    const target = fixed.Q128.fromRaw(7182020259407079994007285275016545289250);
    const relative = try absoluteErrorPercent(value, target);
    try @import("std").testing.expect(relative.raw < fixed.Scale / 1000);
}

test "naive alpha inverse does not pass" {
    const value = try evaluate(3, 2, 10);
    const target = constants.alpha_inverse_reference;
    const relative = try absoluteErrorPercent(value, target);
    try @import("std").testing.expect(relative.raw > fixed.Scale / 10000);
}

test "triad evaluate(0,0,0) = 3 (phi^0 + pi^0 + phi^0 = 1+1+1)" {
    const value = try evaluate(0, 0, 0);
    try @import("std").testing.expectEqual(fixed.Q128.fromInteger(3).raw, value.raw);
}

test "triad evaluate(1,0,0) = phi + 1 + 1 = phi + 2" {
    const value = try evaluate(1, 0, 0);
    const expected = constants.phi.add(fixed.Q128.fromInteger(2));
    try @import("std").testing.expectEqual(expected.raw, value.raw);
}

test "triad evaluate(0,1,0) = 1 + pi + 1 = pi + 2" {
    const value = try evaluate(0, 1, 0);
    const expected = constants.pi.add(fixed.Q128.fromInteger(2));
    try @import("std").testing.expectEqual(expected.raw, value.raw);
}

test "triad evaluate(0,0,1) = 1 + 1 + phi = phi + 2" {
    const value = try evaluate(0, 0, 1);
    const expected = constants.phi.add(fixed.Q128.fromInteger(2));
    try @import("std").testing.expectEqual(expected.raw, value.raw);
}

test "triad evaluate(-1,0,0) = 1/phi + 1 + 1" {
    const value = try evaluate(-1, 0, 0);
    // phi^(-1) = 1/phi ≈ 0.618...
    // result = 1/phi + 2
    const phi_inv = try fixed.Q128.one.div(constants.phi);
    const expected = phi_inv.add(fixed.Q128.fromInteger(2));
    try @import("std").testing.expectEqual(expected.raw, value.raw);
}

test "triad evaluate is symmetric in a and c" {
    // T(a,b,c) = phi^a + pi^b + phi^c
    // T(a,b,c) = T(c,b,a) because phi^a + phi^c = phi^c + phi^a
    const left = try evaluate(3, 2, 5);
    const right = try evaluate(5, 2, 3);
    try @import("std").testing.expectEqual(left.raw, right.raw);
}

test "triad hydrogen signature is in [21, 22]" {
    const value = try evaluate(5, 2, -4);
    try @import("std").testing.expect(value.raw > 21 * fixed.Scale);
    try @import("std").testing.expect(value.raw < 22 * fixed.Scale);
}
