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

test "octonion e0 is identity for all units" {
    var i: Unit = 0;
    while (i < 7) : (i += 1) {
        const left = multiply(0, i);
        try std.testing.expectEqual(i, left.unit);
        try std.testing.expectEqual(@as(i2, 1), left.sign);
        const right = multiply(i, 0);
        try std.testing.expectEqual(i, right.unit);
        try std.testing.expectEqual(@as(i2, 1), right.sign);
    }
    // Test i=7 separately (u3 max)
    const left7 = multiply(0, 7);
    try std.testing.expectEqual(@as(Unit, 7), left7.unit);
    const right7 = multiply(7, 0);
    try std.testing.expectEqual(@as(Unit, 7), right7.unit);
}

test "octonion imaginary squares are -1" {
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        const result = multiply(i, i);
        try std.testing.expectEqual(@as(Unit, 0), result.unit);
        try std.testing.expectEqual(@as(i2, -1), result.sign);
    }
    const result7 = multiply(7, 7);
    try std.testing.expectEqual(@as(Unit, 0), result7.unit);
    try std.testing.expectEqual(@as(i2, -1), result7.sign);
}

test "octonion anti-commutativity for imaginary units" {
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        var j: Unit = 1;
        while (j < 7) : (j += 1) {
            if (i == j) continue;
            const ij = multiply(i, j);
            const ji = multiply(j, i);
            try std.testing.expectEqual(ij.unit, ji.unit);
            try std.testing.expectEqual(ij.sign, -ji.sign);
        }
    }
    // Test i=7, j=1..6
    var j: Unit = 1;
    while (j < 7) : (j += 1) {
        const ij = multiply(7, j);
        const ji = multiply(j, 7);
        try std.testing.expectEqual(ij.unit, ji.unit);
        try std.testing.expectEqual(ij.sign, -ji.sign);
    }
}

test "octonion alternativity" {
    // The octonions are alternative: e_i(e_i e_j) = (e_i e_i) e_j
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        var j: Unit = 1;
        while (j < 7) : (j += 1) {
            try std.testing.expect(isAlternative(i, i, j));
        }
        try std.testing.expect(isAlternative(i, i, 7));
    }
    try std.testing.expect(isAlternative(7, 7, 1));
}

test "octonion full multiplication table has 64 entries" {
    var count: u16 = 0;
    var i: Unit = 0;
    while (i < 7) : (i += 1) {
        var j: Unit = 0;
        while (j < 7) : (j += 1) {
            _ = multiply(i, j);
            count += 1;
        }
        _ = multiply(i, 7);
        count += 1;
    }
    var j: Unit = 0;
    while (j < 7) : (j += 1) {
        _ = multiply(7, j);
        count += 1;
    }
    _ = multiply(7, 7);
    count += 1;
    try std.testing.expectEqual(@as(u16, 64), count);
}

test "octonion oriented triad detection" {
    // (1,2,3) is a valid oriented triad
    const result = oriented(1, 2, 3);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(Unit, 3), result.?.unit);
    try std.testing.expectEqual(@as(i2, 1), result.?.sign);
    // Reversed orientation gives negative sign
    const reversed = oriented(2, 1, 3);
    try std.testing.expect(reversed != null);
    try std.testing.expectEqual(@as(i2, -1), reversed.?.sign);
    // Duplicate units return null
    try std.testing.expect(oriented(1, 1, 3) == null);
}

test "octonion Moufang identity (flexible law)" {
    // Octonions satisfy the flexible law: (e_i e_j) e_i = e_i (e_j e_i)
    var i: Unit = 1;
    while (i < 7) : (i += 1) {
        var j: Unit = 1;
        while (j < 7) : (j += 1) {
            const left_first = multiply(i, j);
            const left = multiply(left_first.unit, i);
            const right_first = multiply(j, i);
            const right = multiply(i, right_first.unit);
            try std.testing.expectEqual(left.unit, right.unit);
            try std.testing.expectEqual(left_first.sign * left.sign, right_first.sign * right.sign);
        }
    }
}
