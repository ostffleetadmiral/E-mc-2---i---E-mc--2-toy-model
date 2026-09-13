//! holo_main.zig - fano-codec: two-way holographic codec CLI.
//!
//! Commands:
//!   ratio              run the Module 3 folding simulation and print the
//!                      compression-ratio curve (N = 17..129 measured,
//!                      513 extrapolated)
//!   c <file> <n>       fold a raw complex grid (n^3 x 64 B) -> FHOLO1
//!   d <file.holo>      unfold a hologram -> raw grid on stdout
//!   info <file.holo>   print the hologram header

const std = @import("std");
const holo = @import("holo");

fn usage() void {
    std.debug.print(
        \\fano-codec - FANO-1 holographic codec (FHOLO1)
        \\  ratio            folding simulation + ratio curve
        \\  c <file> <n>     fold a raw n^3 complex grid into a hologram
        \\  d <file.holo>    reconstruct the raw grid
        \\  info <file.holo> print hologram metadata
        \\
    , .{});
}

fn printRatioRow(n: u32, mode: []const u8, holo_bytes: u64, grid_bytes: u64, node_ratio: f64, byte_ratio: f64) void {
    std.debug.print("{d:>5}  {s:<9} {d:>12} {d:>14} {d:>10.0}:1 {d:>12.1}:1\n", .{
        n, mode, holo_bytes_fmt(holo_bytes), grid_bytes_fmt(grid_bytes), node_ratio, byte_ratio,
    });
}

fn holo_bytes_fmt(b: u64) u64 {
    return b;
}

fn grid_bytes_fmt(b: u64) u64 {
    return b;
}

fn cmdRatio(alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== Module 3 folding simulation (16^3 core) ===\n", .{});
    try stdout.print("  N        mode      hologram      raw grid      node ratio        byte ratio\n", .{});

    const sizes = [_]u32{ 17, 33, 65, 129 };
    var prng = std.Random.DefaultPrng.init(0xFACE);
    const rng = prng.random();

    for (sizes) |n| {
        // pure family state (all windings zero): the holographic ideal
        var g = try holo.generateFamily(alloc, n, rng, 0);
        var h = try holo.fold(alloc, &g);
        printRatioRow(n, @tagName(h.mode), h.hologramBytes(), h.gridBytes(), h.nodeRatio(), h.byteRatio());
        _ = try holo.unfold(alloc, &h); // verify reconstructibility
        h.deinit(alloc);
        g.deinit(alloc);

        // structured windings (1% nonzero)
        var g2 = try holo.generateFamily(alloc, n, rng, 1);
        var h2 = try holo.fold(alloc, &g2);
        std.debug.print("      +1% windings: {s} {d:.1}:1 bytes\n", .{ @tagName(h2.mode), h2.byteRatio() });
        h2.deinit(alloc);
        g2.deinit(alloc);

        // arbitrary (random) data: the honest floor
        var gr = try holo.Grid.init(alloc, n);
        for (gr.data) |*v| {
            v.re = .{ .hi = rng.int(u128), .lo = rng.int(u128) };
            v.im = .{ .hi = rng.int(u128), .lo = rng.int(u128) };
        }
        var hr = try holo.fold(alloc, &gr);
        std.debug.print("      random data:  {s} {d:.2}:1 bytes\n", .{ @tagName(hr.mode), hr.byteRatio() });
        hr.deinit(alloc);
        gr.deinit(alloc);
    }

    // analytic extrapolation to 513^3 (the documented target)
    // analytic extrapolation uses the closed-form sizes below
    const n513: u64 = 513;
    const grid_bytes: u64 = n513 * n513 * n513 * 64;
    const holo_bytes: u64 = 64 + 4096 * 64 + 64; // header + core + tiny RLE
    try stdout.print("\nExtrapolation to 513^3 (pure family state):\n", .{});
    try stdout.print("  raw grid:    {d} bytes ({d:.2} GB)\n", .{ grid_bytes, @as(f64, @floatFromInt(grid_bytes)) / (1024.0 * 1024.0 * 1024.0) });
    try stdout.print("  hologram:    {d} bytes ({d:.0} KB)\n", .{ holo_bytes, @as(f64, @floatFromInt(holo_bytes)) / 1024.0 });
    try stdout.print("  node ratio:  {d}:1 (Module 3 target 32,908:1)\n", .{n513 * n513 * n513 / 4096});
    try stdout.print("  byte ratio:  {d:.0}:1\n", .{@as(f64, @floatFromInt(grid_bytes)) / @as(f64, @floatFromInt(holo_bytes))});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        usage();
        return;
    }
    if (std.mem.eql(u8, args[1], "ratio")) {
        try cmdRatio(alloc);
        return;
    }
    if (std.mem.eql(u8, args[1], "c") and args.len >= 4) {
        try cmdCompress(alloc, args[2], args[3]);
        return;
    }
    if (std.mem.eql(u8, args[1], "d") and args.len >= 3) {
        try cmdDecompress(alloc, args[2]);
        return;
    }
    if (std.mem.eql(u8, args[1], "info") and args.len >= 3) {
        try cmdInfo(alloc, args[2]);
        return;
    }
    usage();
}

fn cmdCompress(alloc: std.mem.Allocator, path: []const u8, n_str: []const u8) !void {
    const n = try std.fmt.parseInt(u32, n_str, 10);
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 33);
    defer alloc.free(raw);
    const cells = @as(usize, n) * n * n;
    if (raw.len != cells * 64) {
        std.debug.print("error: expected {d} bytes (n^3 x 64), got {d}\n", .{ cells * 64, raw.len });
        return error.BadInput;
    }
    var g = try holo.Grid.init(alloc, n);
    defer g.deinit(alloc);
    var off: usize = 0;
    for (g.data) |*v| {
        v.* = try readCxFile(raw, off);
        off += 64;
    }
    var h = try holo.fold(alloc, &g);
    const bytes = try holo.serialize(alloc, &h);
    const out_path = try std.fmt.allocPrint(alloc, "{s}.holo", .{path});
    defer alloc.free(out_path);
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = bytes });
    std.debug.print("{s} -> {s}: {d} -> {d} bytes ({d:.1}:1, {s}, defect={d})\n", .{
        path, out_path, h.gridBytes(), h.hologramBytes(), h.byteRatio(), @tagName(h.mode), h.defect,
    });
}

fn readCxFile(buf: []const u8, off: usize) !holo.Cx {
    if (off + 64 > buf.len) return error.BadInput;
    return .{
        .re = .{
            .hi = std.mem.readInt(u128, buf[off..][0..16], .little),
            .lo = std.mem.readInt(u128, buf[off + 16 ..][0..16], .little),
        },
        .im = .{
            .hi = std.mem.readInt(u128, buf[off + 32 ..][0..16], .little),
            .lo = std.mem.readInt(u128, buf[off + 48 ..][0..16], .little),
        },
    };
}

fn writeCxFile(buf: []u8, off: usize, v: holo.Cx) void {
    std.mem.writeInt(u128, buf[off..][0..16], v.re.hi, .little);
    std.mem.writeInt(u128, buf[off + 16 ..][0..16], v.re.lo, .little);
    std.mem.writeInt(u128, buf[off + 32 ..][0..16], v.im.hi, .little);
    std.mem.writeInt(u128, buf[off + 48 ..][0..16], v.im.lo, .little);
}

fn cmdDecompress(alloc: std.mem.Allocator, path: []const u8) !void {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 33);
    defer alloc.free(raw);
    const h = try holo.deserialize(alloc, raw);
    const g = try holo.unfold(alloc, &h);
    const out = try alloc.alloc(u8, g.data.len * 64);
    defer alloc.free(out);
    var off: usize = 0;
    for (g.data) |v| {
        writeCxFile(out, off, v);
        off += 64;
    }
    const out_path = if (std.mem.endsWith(u8, path, ".holo"))
        try std.fmt.allocPrint(alloc, "{s}.unfold", .{path[0 .. path.len - 5]})
    else
        try std.fmt.allocPrint(alloc, "{s}.unfold", .{path});
    defer alloc.free(out_path);
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out });
    std.debug.print("{s} -> {s}: {d} bytes reconstructed\n", .{ path, out_path, out.len });
}

fn cmdInfo(alloc: std.mem.Allocator, path: []const u8) !void {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 1 << 33);
    defer alloc.free(raw);
    var h = try holo.deserialize(alloc, raw);
    std.debug.print("FHOLO1: n={d} ladder={d} levels={d} mode={s} defect={d}\n", .{
        h.n, h.ladder, h.levels, @tagName(h.mode), h.defect,
    });
    std.debug.print("  grid {d} B -> hologram {d} B = {d:.1}:1\n", .{ h.gridBytes(), h.hologramBytes(), h.byteRatio() });
}
