// License: CC BY-NC-SA 4.0

const std = @import("std");
const triad = @import("verify_triad.zig");
const em = @import("verify_em_chain.zig");
const values = @import("codata_values.zig");
const codon = @import("verify_codon.zig");
const neuraleak = @import("verify_neuraleak.zig");

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

    // Neuraleak f64 validation
    try neuraleak.printSummary(stdout);
    if (!neuraleak.verifyAll()) return error.NeuraleakVerificationFailure;

    // 10D completion f64 validation
    try stdout.print("\n10D Completion f64 validation:\n", .{});
    try stdout.print("  dim_hierarchy: 8→9→10 = {}→{}→{}\n", .{ neuraleak.dim_8d, neuraleak.dim_9d, neuraleak.dim_10d });
    try stdout.print("  SO(10) dim = {d:.0} (10×9/2 = {d:.0})\n", .{ neuraleak.so10_dim, neuraleak.dim_10d * (neuraleak.dim_10d - 1.0) / 2.0 });
    try stdout.print("  chiral_spinor = {d:.0} (one fermion generation)\n", .{neuraleak.so10_spinor});
    try stdout.print("  fermion_decomp = {d:.0} + {d:.0} = {d:.0} (SM + sterile ν)\n", .{ neuraleak.sm_fermions, neuraleak.sterile_neutrino, neuraleak.sm_fermions + neuraleak.sterile_neutrino });
    try stdout.print("  mass_matrix = {d:.0} = 15²\n", .{neuraleak.mass_matrix});
    try stdout.print("  E8_roots = {d:.0} = 15×16\n", .{neuraleak.e8_roots});
    try stdout.print("  shell_transition = {d:.0} = 3(240)+1 (Higgs = +1 = 0D)\n", .{neuraleak.shell_721});
    try stdout.print("  verify10D() = {}\n", .{neuraleak.verify10D()});
    if (!neuraleak.verify10D()) return error.TenDVerificationFailure;
}
