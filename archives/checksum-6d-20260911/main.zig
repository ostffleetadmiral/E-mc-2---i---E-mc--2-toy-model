const std = @import("std");
const core = @import("proof_core.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var passed: u16 = 0;
    for (core.all()) |proof| {
        try stdout.print("chunk-{d:0>2}: {s} ({d} checks, {d} failures)\n", .{ proof.id, if (proof.passed) "PASS" else "FAIL", proof.checks, proof.failures });
        if (proof.passed) passed += 1;
    }
    try stdout.print("summary: {d}/28 proof modules passed\n", .{passed});
    if (passed != 28) return error.ProofFailure;
}
