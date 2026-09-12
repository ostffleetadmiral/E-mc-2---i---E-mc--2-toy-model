// License: CC BY-NC-SA 4.0

const fixed = @import("../fixed_point.zig");

pub const Complex = struct {
    re: fixed.Q128,
    im: fixed.Q128,

    pub const zero = Complex{ .re = fixed.Q128.zero, .im = fixed.Q128.zero };
    pub const one = Complex{ .re = fixed.Q128.one, .im = fixed.Q128.zero };

    pub fn add(self: Complex, other: Complex) Complex {
        return .{ .re = self.re.add(other.re), .im = self.im.add(other.im) };
    }

    pub fn scale(self: Complex, scalar: fixed.Q128) Complex {
        return .{ .re = self.re.mul(scalar), .im = self.im.mul(scalar) };
    }

    pub fn normSquared(self: Complex) fixed.Q128 {
        return self.re.mul(self.re).add(self.im.mul(self.im));
    }
};

pub const State = struct {
    amplitudes: []const Complex,

    pub fn init(amplitudes: []const Complex) State {
        return .{ .amplitudes = amplitudes };
    }

    pub fn normSquared(self: State) fixed.Q128 {
        var total = fixed.Q128.zero;
        for (self.amplitudes) |amplitude| total = total.add(amplitude.normSquared());
        return total;
    }

    pub fn basisIndex(self: State) ?usize {
        var found: ?usize = null;
        for (self.amplitudes, 0..) |amplitude, index| {
            if (amplitude.re.raw == fixed.Scale and amplitude.im.raw == 0) found = index;
        }
        return found;
    }
};

test "basis state has unit norm" {
    const values = [_]Complex{ Complex.one, Complex.zero };
    const state = State.init(values[0..]);
    try @import("std").testing.expectEqual(fixed.Scale, state.normSquared().raw);
    try @import("std").testing.expectEqual(@as(usize, 0), state.basisIndex().?);
}

test "Complex add produces correct sum" {
    const a = Complex{ .re = fixed.Q128.fromInteger(3), .im = fixed.Q128.fromInteger(4) };
    const b = Complex{ .re = fixed.Q128.fromInteger(1), .im = fixed.Q128.fromInteger(2) };
    const sum = a.add(b);
    try @import("std").testing.expectEqual(@as(fixed.Raw, 4 * fixed.Scale), sum.re.raw);
    try @import("std").testing.expectEqual(@as(fixed.Raw, 6 * fixed.Scale), sum.im.raw);
}

test "Complex scale produces correct product" {
    const a = Complex{ .re = fixed.Q128.fromInteger(2), .im = fixed.Q128.fromInteger(3) };
    const s = fixed.Q128.fromInteger(4);
    const scaled = a.scale(s);
    try @import("std").testing.expectEqual(@as(fixed.Raw, 8 * fixed.Scale), scaled.re.raw);
    try @import("std").testing.expectEqual(@as(fixed.Raw, 12 * fixed.Scale), scaled.im.raw);
}

test "Complex normSquared is re^2 + im^2" {
    const a = Complex{ .re = fixed.Q128.fromInteger(3), .im = fixed.Q128.fromInteger(4) };
    const ns = a.normSquared();
    // 3^2 + 4^2 = 9 + 16 = 25
    try @import("std").testing.expectEqual(@as(fixed.Raw, 25 * fixed.Scale), ns.raw);
}

test "Complex zero has zero norm" {
    try @import("std").testing.expectEqual(@as(fixed.Raw, 0), Complex.zero.normSquared().raw);
}

test "State with multiple basis states" {
    const values = [_]Complex{ Complex.zero, Complex.one, Complex.zero };
    const state = State.init(values[0..]);
    try @import("std").testing.expectEqual(fixed.Scale, state.normSquared().raw);
    try @import("std").testing.expectEqual(@as(usize, 1), state.basisIndex().?);
}

test "State with all zeros has zero norm" {
    const values = [_]Complex{ Complex.zero, Complex.zero };
    const state = State.init(values[0..]);
    try @import("std").testing.expectEqual(@as(fixed.Raw, 0), state.normSquared().raw);
    try @import("std").testing.expect(state.basisIndex() == null);
}
