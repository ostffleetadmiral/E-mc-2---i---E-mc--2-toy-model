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
