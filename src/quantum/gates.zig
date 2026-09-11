// License: CC BY-NC-SA 4.0

const fixed = @import("../fixed_point.zig");
const state = @import("state.zig");

pub const sqrt_half = fixed.Q128.fromRaw(240615969168004511545033772477625056650);

pub fn hadamard(input: [2]state.Complex) [2]state.Complex {
    return .{ input[0].add(input[1]).scale(sqrt_half), input[0].add(input[1].scale(fixed.Q128.fromInteger(-1))).scale(sqrt_half) };
}

pub fn pauliX(input: [2]state.Complex) [2]state.Complex {
    return .{ input[1], input[0] };
}

pub fn phaseI(input: [2]state.Complex) [2]state.Complex {
    return .{ input[0], .{ .re = input[1].im.neg(), .im = input[1].re } };
}

test "Hadamard preserves norm approximately in fixed point" {
    const input = [2]state.Complex{ state.Complex.one, state.Complex.zero };
    const output = hadamard(input);
    const norm = output[0].normSquared().add(output[1].normSquared());
    const difference = if (norm.raw > fixed.Scale) norm.raw - fixed.Scale else fixed.Scale - norm.raw;
    try @import("std").testing.expect(difference < fixed.Scale / 1000000000000);
}

test "Pauli X swaps basis amplitudes" {
    const output = pauliX([2]state.Complex{ state.Complex.one, state.Complex.zero });
    try @import("std").testing.expectEqual(fixed.Scale, output[1].re.raw);
}
