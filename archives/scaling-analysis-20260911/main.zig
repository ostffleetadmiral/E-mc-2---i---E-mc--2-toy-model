const std = @import("std");
const core = @import("proof_core.zig");
const scaling = @import("scaling_analysis.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var passed: u16 = 0;
    for (core.all()) |proof| {
        try stdout.print("chunk-{d:0>2}: {s} ({d} checks, {d} failures)\n", .{ proof.id, if (proof.passed) "PASS" else "FAIL", proof.checks, proof.failures });
        if (proof.passed) passed += 1;
    }
    try stdout.print("summary: {d}/30 proof modules passed\n", .{passed});
    if (passed != 30) return error.ProofFailure;

    // Scaling chain output (chunk-31)
    try stdout.print("\nCubic Scaling Chain (chunk-31):\n", .{});
    const chain = scaling.scalingChain();
    for (chain) |level| {
        try stdout.print("  {d:>3}^3 = {d:>10}  ({s}, {s})\n", .{ level.L, level.volume, level.power_of_2, level.description });
    }
    try stdout.print("  7-defect: 2^3 - 1 = 7 (natural in cubic doubling)\n", .{});
    try stdout.print("  421 = (15^3 - 7) / 8 = (3375 - 7) / 8 = 421\n", .{});
    try stdout.print("  421/3375 = 1/8 - 7/27000 (corrected consciousness fraction)\n", .{});
    try stdout.print("  62 = 64 - 2 = codon_capacity - boundary_dim\n", .{});
}
