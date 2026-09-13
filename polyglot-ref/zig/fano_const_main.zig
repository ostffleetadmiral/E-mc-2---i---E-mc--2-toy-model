//! fano_const_main.zig - fano-const: Mound triad constants CLI.
//!
//! Commands:
//!   list                  print all constants with Q128.128-computed values
//!   get <name>            look up one constant (exact, then substring)
//!   eval <a> <b> <c>      evaluate O(a,b,c) = phi^a + pi^b + phi^c
//!   fit <target> [bound]  search (a,b,c) with O(a,b,c) ≈ target
//!   verify                recompute the whole table against the CSV reference

const std = @import("std");
const Q = @import("q128_128");
const triad = @import("triad");

fn printSci(w: anytype, v: f64) !void {
    try w.print("{e}", .{v});
}

fn cmdList() !void {
    const w = std.io.getStdOut().writer();
    try w.print("{s:<42} {s:>2} {s:>5} {s:>5} {s:>5}  {s:>14}  {s}\n", .{ "name", "s", "a", "b", "c", "O(a,b,c)", "unit" });
    for (&triad.table) |*k| {
        const t = triad.triadSigned(k);
        try w.print("{s:<42} {d:>2} {d:>5} {d:>5} {d:>5}  ", .{ k.name, k.sign, k.a, k.b, k.c });
        try printSci(w, Q.toFloat(t.v));
        if (t.underflow) try w.print("  (underflow)", .{});
        try w.print("  [{s}]\n", .{k.unit});
    }
}

fn cmdGet(name: []const u8) !void {
    const w = std.io.getStdOut().writer();
    const k = triad.lookupByName(name) orelse triad.lookupBySubstring(name) orelse {
        try w.print("not found: {s}\n", .{name});
        return error.NotFound;
    };
    const t = triad.triadSigned(k);
    const f = Q.toFloat(t.v);
    const err = if (k.target != 0) (f - k.target) / k.target * 100.0 else 0.0;
    try w.print("{s}\n  category: {s}   unit: {s}\n", .{ k.name, k.category, k.unit });
    try w.print("  (a,b,c) = ({d}, {d}, {d})  sign = {d}\n", .{ k.a, k.b, k.c, k.sign });
    try w.print("  O(a,b,c) = ", .{});
    try printSci(w, f);
    try w.print(" {s}\n  target   = ", .{k.unit});
    try printSci(w, k.target);
    try w.print("\n  error    = {d:.4}%\n", .{err});
    if (t.underflow) try w.print("  note: term(s) below the 2^-128 epsilon floor\n", .{});
}

fn cmdEval(a: i32, b: i32, c: i32) !void {
    const w = std.io.getStdOut().writer();
    const t = triad.triadValue(a, b, c);
    try w.print("O({d},{d},{d}) = ", .{ a, b, c });
    try printSci(w, Q.toFloat(t.v));
    if (t.underflow) try w.print("  (underflow: term(s) below 2^-128)", .{});
    try w.print("\n  raw hi=0x{x} lo=0x{x}\n", .{ t.v.hi, t.v.lo });
}

fn cmdFit(target: f64, bound: i32) !void {
    const w = std.io.getStdOut().writer();
    const r = triad.fit(target, bound);
    if (!r.found) {
        try w.print("no fit found (target must be > 0)\n", .{});
        return;
    }
    try w.print("best fit: O({d},{d},{d}) = ", .{ r.a, r.b, r.c });
    try printSci(w, r.value);
    try w.print("\n  target {d}  rel_err {d:.4}%\n", .{ target, r.rel_err * 100.0 });
}

fn cmdVerify(alloc: std.mem.Allocator) !void {
    const w = std.io.getStdOut().writer();
    var res = try triad.verifyAll(alloc);
    defer res.deinit(alloc);
    for (res.rows) |row| {
        if (!row.ok or @abs(row.err_pct) > 1.0) {
            try w.print("{s:<42} err={d:>10.4}%{s}{s}\n", .{
                row.name,
                row.err_pct,
                if (row.underflow) "  UNDERFLOW" else "",
                if (!row.ok) "  ARITH-FAIL" else "",
            });
        }
    }
    try w.print("\n{d}/{d} within 1%, {d} underflow, {d} arithmetic failures\n", .{
        res.within_1pct, res.total, res.underflow_count, res.arithmetic_failures,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const w = std.io.getStdOut().writer();

    if (args.len < 2) {
        try w.print(
            \\fano-const - Mound triad constants (O(a,b,c) = phi^a + pi^b + phi^c)
            \\  list                  print all constants
            \\  get <name>            look up one constant
            \\  eval <a> <b> <c>      evaluate the triad operator
            \\  fit <target> [bound]  search (a,b,c) for a target value
            \\  verify                recompute the full table
            \\
        , .{});
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "list")) return cmdList();
    if (std.mem.eql(u8, cmd, "get") and args.len >= 3) return cmdGet(args[2]);
    if (std.mem.eql(u8, cmd, "eval") and args.len >= 5) {
        const a = try std.fmt.parseInt(i32, args[2], 10);
        const b = try std.fmt.parseInt(i32, args[3], 10);
        const c = try std.fmt.parseInt(i32, args[4], 10);
        return cmdEval(a, b, c);
    }
    if (std.mem.eql(u8, cmd, "fit") and args.len >= 3) {
        const target = try std.fmt.parseFloat(f64, args[2]);
        const bound: i32 = if (args.len >= 4) try std.fmt.parseInt(i32, args[3], 10) else 64;
        return cmdFit(target, bound);
    }
    if (std.mem.eql(u8, cmd, "verify")) return cmdVerify(alloc);
    try w.print("unknown command: {s}\n", .{cmd});
    return error.Usage;
}
