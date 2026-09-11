const std = @import("std");
const core = @import("proof_core.zig");
const fixed = @import("fixed_point.zig");
const octonion = @import("octonion.zig");
const triad = @import("triad_operator.zig");

comptime {
    _ = @import("proofs/chunk01_q128_scale.zig");
    _ = @import("proofs/chunk22_test_plan.zig");
    _ = @import("quantum/state.zig");
    _ = @import("quantum/gates.zig");
    _ = @import("quantum/simulator.zig");
    _ = @import("quantum/measure.zig");
    _ = @import("quantum/octonion_ops.zig");
}

test "all 22 chunks pass" {
    for (core.all()) |proof| {
        try std.testing.expect(proof.passed);
        try std.testing.expect(proof.checks > 0);
    }
}

test "fixed point constants are ordered" {
    const constants = @import("constants.zig");
    try std.testing.expect(constants.pi.raw > constants.phi.raw);
    try std.testing.expect(constants.phi.raw > fixed.Scale);
}

test "triad hydrogen remains in documented interval" {
    const value = try triad.evaluate(5, 2, -4);
    try std.testing.expect(value.raw > 21 * fixed.Scale);
    try std.testing.expect(value.raw < 22 * fixed.Scale);
}

test "octonion multiplication has closure and non-associativity" {
    try std.testing.expectEqual(@as(u3, 0), octonion.multiply(2, 2).unit);
    try std.testing.expect(octonion.isNonAssociative());
}
