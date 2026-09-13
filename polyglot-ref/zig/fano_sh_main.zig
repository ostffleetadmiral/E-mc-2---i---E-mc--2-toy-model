//! fano_sh_main.zig - the FANO-sh shell entry point.
//!
//!   fano-sh <file>     execute a polyglot file's FANO section
//!   fano-sh            interactive REPL

const std = @import("std");
const fsh = @import("fano_sh");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var env = fsh.Env.init(alloc);
    defer env.deinit();
    const stdout = std.io.getStdOut().writer();

    if (args.len >= 2) {
        const src = try std.fs.cwd().readFileAlloc(alloc, args[1], 1 << 30);
        defer alloc.free(src);
        const pg = fsh.Polyglot.split(src);
        var parser = try fsh.Parser.init(alloc, pg.fano_src);
        var stmts = std.ArrayList(fsh.Stmt).init(alloc);
        defer stmts.deinit();
        try parser.parseProgram(&stmts);
        try env.exec(stmts.items, stdout);
        return;
    }

    // REPL
    const stdin = std.io.getStdIn().reader();
    try stdout.print("FANO-sh 0.1 - Q128.128 polyglot shell (E=mc^2 <-> i <-> E=mc^-2)\n", .{});
    var line_buf = std.ArrayList(u8).init(alloc);
    defer line_buf.deinit();
    while (true) {
        try stdout.print("fano> ", .{});
        line_buf.clearRetainingCapacity();
        stdin.streamUntilDelimiter(line_buf.writer(), '\n', 1 << 16) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const line = line_buf.items;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), "exit")) break;
        var parser = fsh.Parser.init(alloc, line) catch |err| {
            try stdout.print("parse error: {s}\n", .{@errorName(err)});
            continue;
        };
        var stmts = std.ArrayList(fsh.Stmt).init(alloc);
        defer stmts.deinit();
        parser.parseProgram(&stmts) catch |err| {
            try stdout.print("parse error: {s}\n", .{@errorName(err)});
            continue;
        };
        env.exec(stmts.items, stdout) catch |err| {
            try stdout.print("error: {s}\n", .{@errorName(err)});
        };
    }
}
