// License: CC BY-NC-SA 4.0

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
        // Exact 512-bit product, then round-to-nearest-even (RNE).
        // Error bound: |x*y - fl(x*y)| <= 2^(-129) (half ulp).
        // Ported from Q128.128 (FANO-1) q128_128.zig q128Mul.
        const product: Wide = @as(Wide, self.raw) * @as(Wide, other.raw);
        const truncated: Raw = @truncate(product >> FractionalBits);
        // Extract the discarded low bits (bits 0..127)
        const low_mask: Wide = (@as(Wide, 1) << FractionalBits) - 1;
        const discarded: Wide = product & low_mask;
        const halfway: Wide = @as(Wide, 1) << (FractionalBits - 1);
        // RNE: round up if discarded > halfway,
        // or if discarded == halfway and the truncated LSB is odd (round to even)
        if (discarded > halfway) {
            return .{ .raw = truncated +% 1 };
        } else if (discarded == halfway) {
            if ((truncated & 1) != 0) {
                return .{ .raw = truncated +% 1 };
            }
        }
        return .{ .raw = truncated };
    }

    pub fn div(self: Q128, other: Q128) Error!Q128 {
        if (other.raw == 0) return error.DivisionByZero;
        const numerator: Wide = @as(Wide, self.raw) << FractionalBits;
        return .{ .raw = @truncate(@divTrunc(numerator, @as(Wide, other.raw))) };
    }

    /// Create a Q128 from a rational num/den using round-half-away-from-zero.
    /// Matches Q128.128 (FANO-1) q128FromRatio semantics.
    pub fn fromRatio(num: i256, den: i256) Error!Q128 {
        if (den == 0) return error.DivisionByZero;
        const sign: i256 = if ((num < 0) != (den < 0)) -1 else 1;
        const abs_num: i256 = if (num < 0) -num else num;
        const abs_den: i256 = if (den < 0) -den else den;
        const scaled_num: Wide = @as(Wide, abs_num) << FractionalBits;
        const quotient: Wide = @divTrunc(scaled_num, @as(Wide, abs_den));
        const remainder: Wide = @mod(scaled_num, @as(Wide, abs_den));
        // Round-half-away-from-zero: if remainder >= den/2, round up
        const half_den: Wide = @as(Wide, abs_den) >> 1;
        var result: Wide = quotient;
        if (remainder > half_den or (remainder == half_den and remainder != 0)) {
            result +%= 1;
        }
        const raw: Raw = @truncate(if (sign < 0) -result else result);
        return .{ .raw = raw };
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

    /// Compare two Q128 values: -1 if a < b, 0 if equal, 1 if a > b.
    pub fn cmp(a: Q128, b: Q128) i8 {
        if (a.raw < b.raw) return -1;
        if (a.raw > b.raw) return 1;
        return 0;
    }

    /// Equality check.
    pub fn eq(a: Q128, b: Q128) bool {
        return a.raw == b.raw;
    }

    /// Create from a signed 64-bit integer (convenience for constants).
    pub fn fromI64(value: i64) Q128 {
        return fromInteger(@as(i256, value));
    }

    /// Integer square root of a u256 value (binary search).
    fn isqrtU256(n: u256) u256 {
        if (n == 0) return 0;
        var lo: u256 = 0;
        var hi: u256 = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (mid == 0) return 0;
            // Check mid*mid <= n without overflow
            const sq_hi = mid >> 128;
            const sq_lo = mid & ((@as(u256, 1) << 128) - 1);
            // mid*mid = (hi*2^128 + lo)^2 = hi^2*2^256 + 2*hi*lo*2^128 + lo^2
            // If hi > 0, mid^2 > 2^256 which overflows u256, so mid is too big
            if (sq_hi != 0) {
                hi = mid;
                continue;
            }
            const sq = sq_lo * sq_lo;
            if (sq <= n) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo - 1;
    }

    /// Square root using Newton's method on the fixed-point value.
    /// For x >= 0, returns floor(sqrt(x)) in Q128.128.
    /// Error: result^2 <= x < (result + 1 ULP)^2
    pub fn sqrt(self: Q128) Error!Q128 {
        if (self.raw < 0) return error.Overflow;
        if (self.raw == 0) return zero;
        // sqrt(x * 2^128) = sqrt(x) * 2^64
        // So we compute isqrt(self.raw) which gives floor(sqrt(self.raw))
        // and the result represents sqrt(value) with 64 fractional bits
        // of precision. But we need 128 fractional bits.
        // Instead: result.raw = isqrt(self.raw << 128) won't work (too wide).
        // Use Newton's method directly on i256:
        // x_{n+1} = (x_n + self/x_n) / 2
        if (self.raw == Scale) return one; // sqrt(1) = 1
        // Initial guess: 2^(bitlen/2)
        const n: u256 = @intCast(self.raw);
        var bitlen: u8 = 0;
        var tmp = n;
        while (tmp > 0) : (tmp >>= 1) bitlen += 1;
        // Initial guess: 2^(ceil(bitlen/2)) * 2^64 (to get fractional bits)
        var x: u256 = @as(u256, 1) << @intCast((bitlen / 2) + 64);
        const max_iters: u32 = 200;
        var i: u32 = 0;
        while (i < max_iters) : (i += 1) {
            // x_new = (x + n*Scale/x) / 2
            // But n*Scale overflows. Instead: x_new = (x + n/x_scale) / 2
            // where we track x in raw units and n in raw units
            // Newton for sqrt(s) where s = self.raw:
            //   x_{n+1} = (x_n + s/x_n) / 2  (all in raw units, but this gives
            //   floor(sqrt(s)) not sqrt(s*2^128))
            // We need: result.raw = floor(sqrt(s * 2^128))
            // Newton: x_{n+1} = (x_n + s*2^128/x_n) / 2
            // s*2^128 overflows i256. Use u512:
            const s_scaled: u512 = @as(u512, n) << 128;
            const x_u512: u512 = @as(u512, x);
            if (x_u512 == 0) break;
            const quotient = s_scaled / x_u512;
            const x_new = (x_u512 + quotient) / 2;
            const x_new_trunc: u256 = @truncate(x_new);
            if (x_new_trunc == x) break;
            x = x_new_trunc;
        }
        return .{ .raw = @intCast(x) };
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

test "RNE multiply rounds half to even (up when LSB odd)" {
    // a = 3 * 2^127 (represents 1.5), b = fromRaw(1) (represents 2^-128)
    // product = 3 * 2^127 = 2^128 + 2^127
    // truncated = 1, discarded = 2^127 = halfway, LSB = 1 (odd) -> round up to 2
    const a = Q128.fromRaw(3 * (@as(Raw, 1) << 127));
    const b = Q128.fromRaw(1);
    const product = a.mul(b);
    try std.testing.expectEqual(@as(Raw, 2), product.raw);
}

test "RNE multiply rounds half to even (down when LSB even)" {
    // a = 5 * 2^127 (represents 2.5), b = fromRaw(1) (represents 2^-128)
    // product = 5 * 2^127 = 2 * 2^128 + 2^127
    // truncated = 2, discarded = 2^127 = halfway, LSB = 0 (even) -> round down to 2
    const a = Q128.fromRaw(5 * (@as(Raw, 1) << 127));
    const b = Q128.fromRaw(1);
    const product = a.mul(b);
    try std.testing.expectEqual(@as(Raw, 2), product.raw);
}

test "RNE multiply rounds up when above halfway" {
    // a = 3 * 2^127 + 1, b = fromRaw(1)
    // product = 3 * 2^127 + 1
    // truncated = 1, discarded = 2^127 + 1 > halfway -> round up to 2
    const a = Q128.fromRaw(3 * (@as(Raw, 1) << 127) + 1);
    const b = Q128.fromRaw(1);
    const product = a.mul(b);
    try std.testing.expectEqual(@as(Raw, 2), product.raw);
}

test "RNE multiply rounds down when below halfway" {
    // a = 2^127 - 1, b = fromRaw(1)
    // product = 2^127 - 1
    // truncated = 0, discarded = 2^127 - 1 < halfway -> round down to 0
    const a = Q128.fromRaw((@as(Raw, 1) << 127) - 1);
    const b = Q128.fromRaw(1);
    const product = a.mul(b);
    try std.testing.expectEqual(@as(Raw, 0), product.raw);
}

test "RNE multiply negative rounds correctly" {
    // a = -(3 * 2^127), b = fromRaw(1)
    // product = -(3 * 2^127) = -(2^128 + 2^127)
    // In two's complement: truncated = -2 (floor of -1.5), discarded = 2^127
    // discarded == halfway, LSB of -2 is 0 (even) -> stay at -2
    const a = Q128.fromRaw(-@as(Raw, 3 * (@as(Raw, 1) << 127)));
    const b = Q128.fromRaw(1);
    const product = a.mul(b);
    // -1.5 * 2^-128 rounds to -2 * 2^-128 under RNE (even)
    try std.testing.expectEqual(-@as(Raw, 2), product.raw);
}

test "fromRatio basic" {
    const half = try Q128.fromRatio(1, 2);
    try std.testing.expectEqual(Scale / 2, half.raw);
    const third = try Q128.fromRatio(1, 3);
    // 1/3: Scale mod 3 = 1 (since 2^128 mod 3 = 1), half_den = 1
    // remainder == half_den, round half-away -> round up
    try std.testing.expectEqual(@divTrunc(Scale, 3) + 1, third.raw);
}

test "fromRatio negative" {
    const neg_half = try Q128.fromRatio(-1, 2);
    try std.testing.expectEqual(-Scale / 2, neg_half.raw);
}

test "fromRatio zero numerator" {
    // fromRatio(0, n) must return 0 for any nonzero denominator.
    // Previously, fromRatio(0, 1) returned 1 due to a rounding bug
    // where remainder == half_den (both 0) triggered an incorrect round-up.
    const zero_over_one = try Q128.fromRatio(0, 1);
    try std.testing.expectEqual(@as(Raw, 0), zero_over_one.raw);
    const zero_over_seven = try Q128.fromRatio(0, 7);
    try std.testing.expectEqual(@as(Raw, 0), zero_over_seven.raw);
    const zero_over_neg = try Q128.fromRatio(0, -3);
    try std.testing.expectEqual(@as(Raw, 0), zero_over_neg.raw);
}

test "fromI64 round trip" {
    const value = Q128.fromI64(-42);
    try std.testing.expectEqual(@as(i256, -42), value.toInteger());
    const large = Q128.fromI64(1000000000);
    try std.testing.expectEqual(@as(i256, 1000000000), large.toInteger());
}

test "cmp ordering" {
    const a = Q128.fromInteger(5);
    const b = Q128.fromInteger(10);
    const c = Q128.fromInteger(5);
    try std.testing.expectEqual(@as(i8, -1), Q128.cmp(a, b));
    try std.testing.expectEqual(@as(i8, 1), Q128.cmp(b, a));
    try std.testing.expectEqual(@as(i8, 0), Q128.cmp(a, c));
}

test "eq equality" {
    const a = Q128.fromInteger(7);
    const b = Q128.fromInteger(7);
    const c = Q128.fromInteger(8);
    try std.testing.expect(Q128.eq(a, b));
    try std.testing.expect(!Q128.eq(a, c));
    try std.testing.expect(Q128.eq(Q128.zero, Q128.zero));
}

test "abs negation" {
    const neg = Q128.fromInteger(-100);
    const pos = Q128.fromInteger(100);
    try std.testing.expectEqual(pos.raw, neg.abs().raw);
    try std.testing.expectEqual(pos.raw, pos.abs().raw);
    try std.testing.expectEqual(@as(Raw, 0), Q128.zero.abs().raw);
}

test "toInteger truncation toward zero" {
    // 7/3 = 2.333... should truncate to 2
    const seven = Q128.fromInteger(7);
    const three = Q128.fromInteger(3);
    const quotient = try seven.div(three);
    try std.testing.expectEqual(@as(i256, 2), quotient.toInteger());
    // -7/3 = -2.333... should truncate to -2 (toward zero)
    const neg_seven = Q128.fromInteger(-7);
    const neg_quotient = try neg_seven.div(three);
    try std.testing.expectEqual(@as(i256, -2), neg_quotient.toInteger());
}

test "relativeErrorPercent computes ratio" {
    const actual = Q128.fromInteger(11);
    const expected = Q128.fromInteger(10);
    const err = try Q128.relativeErrorPercent(actual, expected);
    // (11-10)/10 = 1/10 = 0.1
    // div uses truncation, so result may differ from fromRatio by 1 ULP
    // Verify it's close to 1/10 within 1 ULP
    const one_tenth = try Q128.fromRatio(1, 10);
    const diff = if (err.raw > one_tenth.raw) err.raw - one_tenth.raw else one_tenth.raw - err.raw;
    try std.testing.expect(diff <= 1);
}

test "neg produces additive inverse" {
    const a = Q128.fromInteger(42);
    const neg_a = a.neg();
    try std.testing.expectEqual(@as(Raw, 0), a.add(neg_a).raw);
    const zero_neg = Q128.zero.neg();
    try std.testing.expectEqual(@as(Raw, 0), zero_neg.raw);
}

test "mul commutativity" {
    const a = Q128.fromInteger(7);
    const b = Q128.fromInteger(13);
    try std.testing.expectEqual(a.mul(b).raw, b.mul(a).raw);
}

test "mul identity" {
    const a = Q128.fromInteger(99);
    try std.testing.expectEqual(a.raw, a.mul(Q128.one).raw);
    try std.testing.expectEqual(@as(Raw, 0), a.mul(Q128.zero).raw);
}

test "div division by zero returns error" {
    const a = Q128.fromInteger(42);
    const result = a.div(Q128.zero);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "fromRatio division by zero returns error" {
    const result = Q128.fromRatio(1, 0);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "sqrt of one is one" {
    const result = try Q128.one.sqrt();
    try std.testing.expectEqual(Q128.one.raw, result.raw);
}

test "sqrt of zero is zero" {
    const result = try Q128.zero.sqrt();
    try std.testing.expectEqual(Q128.zero.raw, result.raw);
}

test "sqrt of negative returns error" {
    const neg = Q128.fromInteger(-4);
    const result = neg.sqrt();
    try std.testing.expectError(error.Overflow, result);
}

test "sqrt of four is two" {
    const four = Q128.fromInteger(4);
    const result = try four.sqrt();
    try std.testing.expectEqual(Q128.fromInteger(2).raw, result.raw);
}

test "pow zero is one" {
    const a = Q128.fromInteger(42);
    try std.testing.expectEqual(Q128.one.raw, (try a.pow(0)).raw);
}

test "pow one is identity" {
    const a = Q128.fromInteger(42);
    try std.testing.expectEqual(a.raw, (try a.pow(1)).raw);
}

test "pow negative exponent" {
    const two = Q128.fromInteger(2);
    const result = try two.pow(-1);
    // 2^(-1) = 1/2 = Scale/2
    try std.testing.expectEqual(@as(Raw, Scale / 2), result.raw);
}

test "add zero identity" {
    const a = Q128.fromInteger(42);
    try std.testing.expectEqual(a.raw, a.add(Q128.zero).raw);
}

test "sub zero identity" {
    const a = Q128.fromInteger(42);
    try std.testing.expectEqual(a.raw, a.sub(Q128.zero).raw);
}

test "fromRatio one half is exact" {
    const half = try Q128.fromRatio(1, 2);
    try std.testing.expectEqual(Scale / 2, half.raw);
}

test "fromRatio two thirds rounds" {
    // 2/3: Scale mod 3 = 1, half_den = 1, remainder = 2*Scale mod 3 = 2
    // 2 > 1, so round up
    const two_thirds = try Q128.fromRatio(2, 3);
    const expected = @divTrunc(2 * Scale, 3) + 1;
    try std.testing.expectEqual(expected, two_thirds.raw);
}

test "fromRatio negative denominator normalizes sign" {
    const neg_half = try Q128.fromRatio(1, -2);
    try std.testing.expectEqual(-Scale / 2, neg_half.raw);
    const pos_half = try Q128.fromRatio(-1, -2);
    try std.testing.expectEqual(Scale / 2, pos_half.raw);
}

test "mul distributivity over add" {
    // a*(b+c) == a*b + a*c
    const a = Q128.fromInteger(3);
    const b = Q128.fromInteger(5);
    const c = Q128.fromInteger(7);
    const left = a.mul(b.add(c));
    const right = a.mul(b).add(a.mul(c));
    try std.testing.expectEqual(left.raw, right.raw);
}

test "fromInteger large value" {
    const large = Q128.fromInteger(@as(i256, 1) << 100);
    try std.testing.expectEqual(@as(i256, 1) << 100, large.toInteger());
}

test "exactPow2 produces correct values" {
    try std.testing.expectEqual(@as(u512, 1), exactPow2(0));
    try std.testing.expectEqual(@as(u512, 2), exactPow2(1));
    try std.testing.expectEqual(@as(u512, 256), exactPow2(8));
    try std.testing.expectEqual(@as(u512, 1) << 16, exactPow2(16));
}
