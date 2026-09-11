// License: CC BY-NC-SA 4.0

const std = @import("std");

pub const Unit = u3;
pub const Product = struct { unit: Unit, sign: i2 };

const triples = [_][3]Unit{
    .{ 1, 2, 3 }, .{ 1, 4, 5 }, .{ 1, 7, 6 }, .{ 2, 4, 6 },
    .{ 2, 5, 7 }, .{ 3, 4, 7 }, .{ 3, 6, 5 },
};

fn oriented(a: Unit, b: Unit, c: Unit) ?Product {
    if (a == b or a == c or b == c) return null;
    for (triples) |triple| {
        if (a == triple[0] and b == triple[1] and c == triple[2]) return .{ .unit = c, .sign = 1 };
        if (b == triple[0] and c == triple[1] and a == triple[2]) return .{ .unit = a, .sign = 1 };
        if (c == triple[0] and a == triple[1] and b == triple[2]) return .{ .unit = b, .sign = 1 };
        if (b == triple[0] and a == triple[1] and c == triple[2]) return .{ .unit = c, .sign = -1 };
        if (c == triple[0] and b == triple[1] and a == triple[2]) return .{ .unit = a, .sign = -1 };
        if (a == triple[0] and c == triple[1] and b == triple[2]) return .{ .unit = b, .sign = -1 };
    }
    return null;
}

pub fn multiply(a: Unit, b: Unit) Product {
    if (a == 0) return .{ .unit = b, .sign = 1 };
    if (b == 0) return .{ .unit = a, .sign = 1 };
    if (a == b) return .{ .unit = 0, .sign = -1 };
    for (triples) |triple| {
        if (a == triple[0] and b == triple[1]) return .{ .unit = triple[2], .sign = 1 };
        if (a == triple[1] and b == triple[2]) return .{ .unit = triple[0], .sign = 1 };
        if (a == triple[2] and b == triple[0]) return .{ .unit = triple[1], .sign = 1 };
        if (b == triple[0] and a == triple[1]) return .{ .unit = triple[2], .sign = -1 };
        if (b == triple[1] and a == triple[2]) return .{ .unit = triple[0], .sign = -1 };
        if (b == triple[2] and a == triple[0]) return .{ .unit = triple[1], .sign = -1 };
    }
    unreachable;
}

pub fn isAlternative(a: Unit, b: Unit, c: Unit) bool {
    const left_first = multiply(a, b);
    const left_second = multiply(left_first.unit, c);
    const right_first = multiply(b, c);
    const right_second = multiply(a, right_first.unit);
    return left_second.unit == right_second.unit and left_first.sign * left_second.sign == right_first.sign * right_second.sign;
}

pub fn isNonAssociative() bool {
    const left_first = multiply(1, 2);
    const left = multiply(left_first.unit, 4);
    const right_first = multiply(2, 4);
    const right = multiply(1, right_first.unit);
    return left.unit == right.unit and left_first.sign * left.sign != right_first.sign * right.sign;
}

test "octonion identity and imaginary squares" {
    try std.testing.expectEqual(@as(Unit, 4), multiply(0, 4).unit);
    try std.testing.expectEqual(@as(i2, -1), multiply(4, 4).sign);
}

test "octonion has seven oriented triads" {
    for (triples) |triple| {
        const result = multiply(triple[0], triple[1]);
        try std.testing.expectEqual(triple[2], result.unit);
        try std.testing.expectEqual(@as(i2, 1), result.sign);
    }
}

test "octonion multiplication is non-associative" {
    try std.testing.expect(isNonAssociative());
}
