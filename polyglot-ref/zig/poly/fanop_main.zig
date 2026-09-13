//! fanop_main.zig - the `fano-poly` CLI entry point.
//!
//!   fano-poly build <proj>.fanop   parse + codegen + `zig build`
//!   fano-poly run   <proj>.fanop   build + run the generated executable
//!   fano-poly repl                 interactive py/js polyglot REPL
//!
//! The FANO Zig tree (containing poly/ and q128_128.zig) is located via
//! the build option `fano_zig_root` baked in at fano-poly build time, and
//! forwarded to the generated project through FANO_ZIG_ROOT so its
//! build.zig can reuse the poly runtime.

const std = @import("std");
const fanop = @import("fanop.zig");
const poly = @import("poly");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        return usage();
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "build")) {
        if (args.len != 3) return usage();
        try buildProject(alloc, args[2]);
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (args.len != 3) return usage();
        try runProject(alloc, args[2]);
    } else if (std.mem.eql(u8, cmd, "repl")) {
        try repl(alloc);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return usage();
    } else {
        std.debug.print("fano-poly: unknown command '{s}'\n", .{cmd});
        return usage();
    }
}

fn usage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\fano-poly - FANO-1 polyglot project front end
        \\
        \\Usage:
        \\  fano-poly build <proj>.fanop   Parse, codegen and `zig build` the project.
        \\  fano-poly run   <proj>.fanop   Build, then run the generated executable.
        \\  fano-poly repl                  Interactive py/js polyglot REPL.
        \\
        \\A .fanop file is a set of language-tagged function blocks
        \\(py/js/zig) sharing the canonical i256 ABI. See fanop.zig.
        \\
    );
}

fn buildProject(alloc: std.mem.Allocator, path: []const u8) !void {
    const src = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 24);
    defer alloc.free(src);
    const proj = try fanop.parse(alloc, src);
    defer freeProject(alloc, proj);

    // Output directory next to the source file.
    const out_dir = try std.fmt.allocPrint(alloc, "{s}.out", .{path});
    defer alloc.free(out_dir);
    std.fs.cwd().deleteTree(out_dir) catch {};
    try fanop.codegen(alloc, proj, build_options.fano_zig_root, out_dir);

    // Invoke `zig build` in the generated project, forwarding the FANO
    // Zig root so the generated build.zig can locate the poly runtime.
    const zig = std.process.getEnvVarOwned(alloc, "ZIG") catch try alloc.dupe(u8, "zig");
    defer alloc.free(zig);
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append(zig);
    try argv.append("build");
    var child = std.process.Child.init(argv.items, alloc);
    child.cwd = out_dir;
    child.env_map = try buildEnv(alloc);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("fano-poly: zig build failed (exit {d}) in {s}\n", .{ code, out_dir });
            return error.BuildFailed;
        },
        else => return error.BuildFailed,
    }
    std.debug.print("fano-poly: built {s} -> {s}\n", .{ path, out_dir });
}

fn runProject(alloc: std.mem.Allocator, path: []const u8) !void {
    const src = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 24);
    defer alloc.free(src);
    const proj = try fanop.parse(alloc, src);
    defer freeProject(alloc, proj);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}.out", .{path});
    defer alloc.free(out_dir);
    std.fs.cwd().deleteTree(out_dir) catch {};
    try fanop.codegen(alloc, proj, build_options.fano_zig_root, out_dir);

    const zig = std.process.getEnvVarOwned(alloc, "ZIG") catch try alloc.dupe(u8, "zig");
    defer alloc.free(zig);
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append(zig);
    try argv.append("build");
    try argv.append("run");
    var child = std.process.Child.init(argv.items, alloc);
    child.cwd = out_dir;
    child.env_map = try buildEnv(alloc);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.RunFailed,
        else => return error.RunFailed,
    }
}

fn repl(alloc: std.mem.Allocator) !void {
    try poly.Python.init();
    var engine = try poly.QuickJS.init();
    defer engine.deinit();
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    try stdout.writeAll("fano-poly repl - py> / js> expressions over the i256 ABI. Ctrl-D to exit.\n");
    var line = std.ArrayList(u8).init(alloc);
    defer line.deinit();
    while (true) {
        try stdout.writeAll("poly> ");
        line.clearRetainingCapacity();
        stdin.streamUntilDelimiter(line.writer(), '\n', 1 << 16) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const text = std.mem.trim(u8, line.items, " \t\r\n");
        if (text.len == 0) continue;
        // `py <expr>` or `js <expr>` selects the guest; bare expressions
        // default to Python.
        if (std.mem.startsWith(u8, text, "py ")) {
            const expr = text[3..];
            printI256(try poly.Python.evalI256(expr));
        } else if (std.mem.startsWith(u8, text, "js ")) {
            const expr = text[3..];
            printI256(try engine.evalI256(expr));
        } else if (std.mem.eql(u8, text, "help")) {
            try stdout.writeAll("  py <expr>   evaluate a Python int expression\n  js <expr>   evaluate a JS BigInt expression\n  <expr>      default = Python\n");
        } else {
            printI256(poly.Python.evalI256(text) catch |err| {
                std.debug.print("  error: {s}\n", .{@errorName(err)});
                continue;
            });
        }
    }
    try stdout.writeAll("\n");
}

fn printI256(v: poly.I256) void {
    var buf: [128]u8 = undefined;
    const dec = poly.i256ToDecimal(std.heap.page_allocator, v) catch return;
    defer std.heap.page_allocator.free(dec);
    _ = std.fmt.bufPrint(&buf, "  = {s}\n", .{dec}) catch unreachable;
    std.debug.print("  = {s}\n", .{dec});
}

fn buildEnv(alloc: std.mem.Allocator) !*std.process.EnvMap {
    const env = try alloc.create(std.process.EnvMap);
    env.* = try std.process.getEnvMap(alloc);
    try env.put("FANO_ZIG_ROOT", build_options.fano_zig_root);
    return env;
}

fn freeProject(alloc: std.mem.Allocator, proj: fanop.Project) void {
    alloc.free(proj.name);
    for (proj.blocks) |b| {
        alloc.free(b.name);
        for (b.params) |p| alloc.free(p);
        alloc.free(b.params);
        alloc.free(b.body);
    }
    alloc.free(proj.blocks);
}

const BuildFailed = error{BuildFailed};
const RunFailed = error{RunFailed};
