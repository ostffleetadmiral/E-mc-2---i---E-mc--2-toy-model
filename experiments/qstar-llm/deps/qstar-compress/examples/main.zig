//! Qstar-Compress Example — gzip + dedup + lattice transform + TurboQuant.

const std = @import("std");
const compress = @import("compress");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-Compress — Lattice Compression + TurboQuant\n", .{});
    try stdout.print("==================================================\n\n", .{});

    // Create test data with redundancy
    var data_buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < data_buf.len) {
        data_buf[i] = @intCast(i % 256);
        i += 1;
    }
    const data = data_buf[0..];

    // Gzip
    try stdout.print("Gzip Compression:\n", .{});
    const gz = try compress.gzipCompress(allocator, data);
    defer allocator.free(gz);
    try stdout.print("  Input: {d} bytes\n", .{data.len});
    try stdout.print("  Compressed: {d} bytes ({d:.1}x)\n", .{ gz.len, @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(gz.len)) });
    const gz_dec = try compress.gzipDecompress(allocator, gz);
    defer allocator.free(gz_dec);
    try stdout.print("  Round-trip: {}\n", .{std.mem.eql(u8, data, gz_dec)});

    // Dedup
    try stdout.print("\nSelf-Similarity Dedup:\n", .{});
    const dedup = try compress.deduplicate(allocator, data);
    defer dedup.deinit();
    try stdout.print("  Templates found: {d}\n", .{dedup.templates.len});

    // Full pipeline
    try stdout.print("\nFull Compression Pipeline:\n", .{});
    const config = compress.CompressConfig{
        .use_dedup = true,
        .use_turboquant = false,
    };
    const container = try compress.compress(allocator, data, config);
    defer container.deinit();
    try stdout.print("  Container size: {d} bytes\n", .{container.rmsy_bytes.len});
    try stdout.print("  Expansion factor: {d}x\n", .{compress.EXPANSION_FACTOR});

    const restored = try compress.decompress(allocator, container);
    defer allocator.free(restored);
    try stdout.print("  Round-trip: {}\n", .{std.mem.eql(u8, data, restored)});

    try stdout.print("\nDone.\n", .{});
}
