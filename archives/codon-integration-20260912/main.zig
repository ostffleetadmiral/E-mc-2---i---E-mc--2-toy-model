const std = @import("std");
const triad = @import("verify_triad.zig");
const em = @import("verify_em_chain.zig");
const values = @import("codata_values.zig");
const codon = @import("verify_codon.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const hydrogen = triad.triad(5, 2, -4);
    const alpha = em.alphaFromImpedance();
    try stdout.print("hydrogen triad: {d:.15}\n", .{hydrogen});
    try stdout.print("alpha from Z0/RK: {d:.15}\n", .{alpha});
    try stdout.print("alpha reference: {d:.15}\n", .{values.alpha});
    if (@abs(alpha - values.alpha) >= 1e-10) return error.SidecarVerificationFailure;

    // Codon f64 validation
    try codon.printSummary(stdout);
    if (!codon.verifyAll()) return error.CodonVerificationFailure;
}
