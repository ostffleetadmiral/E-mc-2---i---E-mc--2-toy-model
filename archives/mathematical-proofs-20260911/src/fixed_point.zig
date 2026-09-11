const std = @import("std");

pub const Raw = i256;
pub const Wide = i512;
pub const FractionalBits: u8 = 128;
pub const Scale: Raw = @as(Raw, 1) << FractionalBits;

pub const Error = error{ DivisionByZero, Overflow };

pub const Q128 = struct {
    raw: Raw,

    pub const zero = Q128{ .raw = 0 };
    pub const one = Q128{ .raw = Scale };

    pub fn fromInteger(value: i256) Q128 {
        return .{ .raw = value * Scale };
    }

    pub fn fromRaw(raw: Raw) Q128 {
        return .{ .raw = raw };
    }

    pub fn add(self: Q128, other: Q128) Q128 {
        return .{ .raw = self.raw + other.raw };
    }

    pub fn sub(self: Q128, other: Q128) Q128 {
        return .{ .raw = self.raw - other.raw };
    }

    pub fn neg(self: Q128) Q128 {
        return .{ .raw = -self.raw };
    }

    pub fn mul(self: Q128, other: Q128) Q128 {
        const product: Wide = @as(Wide, self.raw) * @as(Wide, other.raw);
        return .{ .raw = @truncate(product >> FractionalBits) };
    }

    pub fn div(self: Q128, other: Q128) Error!Q128 {
        if (other.raw == 0) return error.DivisionByZero;
        const numerator: Wide = @as(Wide, self.raw) << FractionalBits;
        return .{ .raw = @truncate(@divTrunc(numerator, @as(Wide, other.raw))) };
    }

    pub fn pow(self: Q128, exponent: i32) Error!Q128 {
        if (exponent == 0) return one;
        if (exponent < 0) {
            const positive = try self.pow(-exponent);
            return try one.div(positive);
        }
        var result = one;
        var base = self;
        var n: u32 = @intCast(exponent);
        while (n > 0) : (n >>= 1) {
            if ((n & 1) == 1) result = result.mul(base);
            if (n > 1) base = base.mul(base);
        }
        return result;
    }

    pub fn abs(self: Q128) Q128 {
        return if (self.raw < 0) self.neg() else self;
    }

    pub fn relativeErrorPercent(actual: Q128, expected: Q128) Error!Q128 {
        const difference = actual.sub(expected).abs();
        return try difference.div(expected.abs());
    }

    pub fn toInteger(self: Q128) i256 {
        return @divTrunc(self.raw, Scale);
    }
};

pub fn exactPow2(exponent: u16) u512 {
    return @as(u512, 1) << @as(u9, @intCast(exponent));
}

test "Q128.128 integer round trip" {
    const value = Q128.fromInteger(-123456);
    try std.testing.expectEqual(@as(i256, -123456), value.toInteger());
}

test "Q128.128 multiplication and division" {
    const six = Q128.fromInteger(6);
    const seven = Q128.fromInteger(7);
    const product = six.mul(seven);
    try std.testing.expectEqual(@as(i256, 42), product.toInteger());
    const quotient = try seven.div(six);
    try std.testing.expect(quotient.raw > Scale);
    try std.testing.expect(quotient.raw < Scale * 2);
}

test "Q128.128 powers" {
    const two = Q128.fromInteger(2);
    try std.testing.expectEqual(@as(i256, 32), (try two.pow(5)).toInteger());
    try std.testing.expectEqual(@as(i256, 0), (try two.pow(-5)).toInteger());
}
