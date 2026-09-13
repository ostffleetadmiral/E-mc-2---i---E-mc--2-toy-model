//! fixed_compat.zig - Compatibility layer providing the hardware project's
//! fixed_point.zig API on top of Q128.128's q128_128.zig engine.
//!
//! This allows modules ported from the E=mc²-i-E=mc⁻² toy-model to compile
//! and run against the FANO-1 Q128.128 engine with minimal changes.
//!
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const Q = @import("q128_128");

pub const Raw = Q.q128;
pub const Wide = Q.U512;
pub const FractionalBits: u8 = 128;
pub const Scale: Raw = Q.Q_ONE;

pub const Error = error{ DivisionByZero, Overflow };

pub const Q128 = struct {
    raw: Raw,

    pub const zero = Q128{ .raw = Q.Q_ZERO };
    pub const one = Q128{ .raw = Q.Q_ONE };

    pub fn fromInteger(value: i64) Q128 {
        return .{ .raw = Q.q128FromI64(value) };
    }

    pub fn fromRaw(raw: Raw) Q128 {
        return .{ .raw = raw };
    }

    /// Create from a signed integer by scaling to Q128.128.
    /// Handles the case where the hardware code does `fromRaw(i256_value)`.
    pub fn fromRawI256(value: i256) Q128 {
        // Convert i256 to q128 by interpreting as two's complement
        const bits: u256 = @bitCast(value);
        const hi: u128 = @truncate(bits >> 128);
        const lo: u128 = @truncate(bits);
        return .{ .raw = .{ .hi = hi, .lo = lo } };
    }

    pub fn fromI64(value: i64) Q128 {
        return fromInteger(value);
    }

    pub fn fromRatio(num: i64, den: i64) Error!Q128 {
        if (den == 0) return error.DivisionByZero;
        const is_neg = (num < 0) != (den < 0);
        const abs_num: u128 = @intCast(if (num < 0) -num else num);
        const abs_den: u128 = @intCast(if (den < 0) -den else den);
        var r = Q.q128FromRatio(abs_num, abs_den);
        if (is_neg) r = Q.q128Neg(r);
        return .{ .raw = r };
    }

    pub fn add(self: Q128, other: Q128) Q128 {
        return .{ .raw = Q.q128Add(self.raw, other.raw) };
    }

    pub fn sub(self: Q128, other: Q128) Q128 {
        return .{ .raw = Q.q128Sub(self.raw, other.raw) };
    }

    pub fn neg(self: Q128) Q128 {
        return .{ .raw = Q.q128Neg(self.raw) };
    }

    pub fn mul(self: Q128, other: Q128) Q128 {
        return .{ .raw = Q.q128Mul(self.raw, other.raw).v };
    }

    pub fn div(self: Q128, other: Q128) Error!Q128 {
        if (Q.q128Eq(other.raw, Q.Q_ZERO)) return error.DivisionByZero;
        return .{ .raw = Q.q128Div(self.raw, other.raw) };
    }

    pub fn pow(self: Q128, exponent: i32) Error!Q128 {
        const r = Q.q128Pow(self.raw, exponent);
        if (r.overflow) return error.Overflow;
        return .{ .raw = r.v };
    }

    pub fn abs(self: Q128) Q128 {
        return if (Q.q128Cmp(self.raw, Q.Q_ZERO) < 0) self.neg() else self;
    }

    pub fn sqrt(self: Q128) Error!Q128 {
        return .{ .raw = Q.q128Sqrt(self.raw) };
    }

    pub fn cmp(a: Q128, b: Q128) i8 {
        return Q.q128Cmp(a.raw, b.raw);
    }

    pub fn eq(a: Q128, b: Q128) bool {
        return Q.q128Eq(a.raw, b.raw);
    }

    pub fn relativeErrorPercent(actual: Q128, expected: Q128) Error!Q128 {
        const difference = actual.sub(expected).abs();
        return try difference.div(expected.abs());
    }

    pub fn toInteger(self: Q128) i64 {
        return Q.toI64(self.raw);
    }
};

/// Compatibility constants matching hardware's constants.zig
pub const constants = struct {
    pub const phi = Q128{ .raw = Q.PHI_RAW };
    pub const pi = Q128{ .raw = Q.PI_RAW };
    pub const sqrt5 = Q128.fromRawI256(790231711353346013421113761587364630568);
    pub const c_m_per_s: u64 = 299792458;
    pub const h_j_s: u64 = 662607015;
    pub const hbar_j_s: u64 = 105457181;
    pub const alpha_inverse_reference = Q128.fromRawI256(46630934153325335303234647273662486708739);
    pub const hydrogen_target_cm = Q128.fromRawI256(7182020259407079994007285275016545289250);
    pub const vacuum_impedance_raw: Raw = .{ .hi = 3, .lo = 0x9C2E0A4E52CEB4F5A5E5B8E6C7D4A3B2 };
    pub const von_klitzing_raw: Raw = .{ .hi = 1856, .lo = 0x2C6E6E0A8B8B8B8B8B8B8B8B8B8B8B8B };
};
