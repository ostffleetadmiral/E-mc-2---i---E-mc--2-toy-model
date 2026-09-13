//! scale_main.zig - CLI for the FANO-1 scale/expansion calculator.

const std = @import("std");
const st = @import("scale_table.zig");

pub fn main() !void {
    const w = std.io.getStdOut().writer();
    try w.print("=" ** 72 ++ "\n", .{});
    try w.print("  FANO-1 SCALE & EXPANSION TABLE\n", .{});
    try w.print("=" ** 72 ++ "\n", .{});
    try st.printTable(w);
    try w.print("\n", .{});
    try st.printBlocks(w);
    try w.print("\n" ++ "=" ** 72 ++ "\n", .{});
    try w.print("  Node size: 32 bytes (16 real + 16 imaginary)\n", .{});
    try w.print("  Entangled scaling: 8^(N-1) (binary shell steps)\n", .{});
    try w.print("  Non-entangled scaling: 2^(N-1) (Fano steps)\n", .{});
    try w.print("=" ** 72 ++ "\n", .{});
}
