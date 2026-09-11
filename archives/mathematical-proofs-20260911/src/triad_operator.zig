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
