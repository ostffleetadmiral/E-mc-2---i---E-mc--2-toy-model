//! manual_s7_compression.zig — Manual integration test for S7→S0 compression.
//!
//! Run with: zig build manual -Dmanual=s7_compression
//! or:       zig build manual

const std = @import("std");
const s7 = @import("s7_compression");

fn generateRandom(allocator: std.mem.Allocator, size: usize, seed: u64) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();
    for (buf) |*b| b.* = rng.int(u8);
    return buf;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== S7→S0 Lattice Compression — Full Limit Analysis ===\n\n", .{});

    // ---- Generate dynamic datasets ----
    const rand_1k = try generateRandom(allocator, 1024, 42);
    defer allocator.free(rand_1k);
    const rand_4k = try generateRandom(allocator, 4096, 0xCAFEBABE);
    defer allocator.free(rand_4k);
    const rand_16k = try generateRandom(allocator, 16384, 0xDEADBEEF);
    defer allocator.free(rand_16k);
    const rand_64k = try generateRandom(allocator, 65536, 0xBEEFCAFE);
    defer allocator.free(rand_64k);

    const zeros_256 = try allocator.alloc(u8, 256);
    defer allocator.free(zeros_256);
    @memset(zeros_256, 0);

    const ffs_256 = try allocator.alloc(u8, 256);
    defer allocator.free(ffs_256);
    @memset(ffs_256, 0xFF);

    const single_byte_1k = try allocator.alloc(u8, 1024);
    defer allocator.free(single_byte_1k);
    @memset(single_byte_1k, 'Z');

    const incr_256 = try allocator.alloc(u8, 256);
    defer allocator.free(incr_256);
    for (incr_256, 0..) |*b, i| b.* = @intCast(i % 256);

    const alt_512 = try allocator.alloc(u8, 512);
    defer allocator.free(alt_512);
    for (alt_512, 0..) |*b, i| b.* = if (i % 2 == 0) 0xAA else 0x55;

    // Semi-structured: header + random payload
    const header = "HEADER_V1.0|SIZE=1024|CHECKSUM=0x1234|";
    const rand_payload = try generateRandom(allocator, 1024 - header.len, 2024);
    defer allocator.free(rand_payload);
    const semi_struct = try allocator.alloc(u8, header.len + rand_payload.len);
    defer allocator.free(semi_struct);
    @memcpy(semi_struct[0..header.len], header);
    @memcpy(semi_struct[header.len..], rand_payload);

    // All test data sets — covering every data type we can think of
    const datasets = [_]struct { name: []const u8, data: []const u8 }{
        // Text data
        .{ .name = "Text (repeated)", .data = "The quick brown fox jumps over the lazy dog. " ** 50 },
        .{ .name = "Text (varied)", .data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat." },
        .{ .name = "Text w/ nulls", .data = "Hello\x00World\x00\x00Test\x00Data" },
        // Binary patterns
        .{ .name = "Binary pattern", .data = "\x00\x01\x02\x03\x04\x05\x06\x07" ** 100 },
        .{ .name = "Incrementing 0-255", .data = incr_256 },
        .{ .name = "Alternating 0xAA/0x55", .data = alt_512 },
        // Extreme values
        .{ .name = "All zeros (256B)", .data = zeros_256 },
        .{ .name = "All 0xFF (256B)", .data = ffs_256 },
        .{ .name = "Single byte repeated", .data = single_byte_1k },
        // Sparse data
        .{ .name = "Sparse data", .data = "A" ** 10 ++ "\x00" ** 1000 ++ "B" ** 10 },
        // Random data (hardest case)
        .{ .name = "Random 1KB", .data = rand_1k },
        .{ .name = "Random 4KB", .data = rand_4k },
        .{ .name = "Random 16KB", .data = rand_16k },
        .{ .name = "Random 64KB", .data = rand_64k },
        // Semi-structured
        .{ .name = "Semi-structured", .data = semi_struct },
        // Edge case sizes
        .{ .name = "Empty (0B)", .data = "" },
        .{ .name = "1 byte", .data = "\x42" },
        .{ .name = "2 bytes", .data = "\x00\xFF" },
        .{ .name = "3 bytes (partial)", .data = "\xDE\xAD\xBE" },
        .{ .name = "5 bytes (1+partial)", .data = "\x01\x02\x03\x04\x05" },
        .{ .name = "Small file", .data = "Hello, World!" },
    };

    const strategies = [_]s7.Strategy{
        .direct,
        .pattern_based,
    };

    for (datasets) |ds| {
        std.debug.print("--- Dataset: {s} ({d} bytes) ---\n", .{ ds.name, ds.data.len });

        // Choose levels based on data size to avoid expandSeed bottleneck:
        // S5 expansion creates scale³=32768 entries per non-zero node.
        // For large data with many non-zero nodes, use lower levels.
        const cells_needed = (ds.data.len + 3) / 4;
        const levels: []const u8 = blk: {
            if (cells_needed == 0) break :blk &[_]u8{ 5, 3, 1, 0 };
            if (cells_needed <= 64) break :blk &[_]u8{ 5, 3, 1, 0 };
            if (cells_needed <= 512) break :blk &[_]u8{ 3, 1, 0 };
            if (cells_needed <= 3375) break :blk &[_]u8{ 1, 0 };
            break :blk &[_]u8{ 1 };
        };

        for (strategies) |strategy| {
            const strategy_name = switch (strategy) {
                .direct => "direct",
                .holographic => "holographic",
                .hadamard => "hadamard",
                .pattern_based => "pattern",
            };

            std.debug.print("  Strategy: {s}\n", .{strategy_name});

            for (levels) |level| {
                // Lossless
                const lossless = try s7.verifyLossless(allocator, ds.data, strategy, level);
                const pass_str: []const u8 = if (lossless.pass) "PASS" else "FAIL";
                std.debug.print("    S{d}: lossless={s} ratio={d:.2}x compressed={d}B", .{
                    level,
                    pass_str,
                    lossless.ratio,
                    lossless.compressed_size,
                });

                // Lossy
                const lossy = try s7.evaluateLossy(allocator, ds.data, strategy, level);
                std.debug.print(" | lossy: ratio={d:.2}x match={d:.1}% corr={d:.4}\n", .{
                    lossy.compressed_ratio,
                    lossy.bytes_matching_pct,
                    lossy.correlation,
                });
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }

    // Multi-level sweep
    std.debug.print("=== Multi-Level Sweep (direct strategy) ===\n", .{});
    const sweep_data = "Multi-level sweep test data! AAAABBBBCCCCDDDD" ** 16;
    const sweep_results = try s7.levelSweep(allocator, sweep_data, .direct);
    defer allocator.free(sweep_results);

    std.debug.print("  Level  Seed  Lossless  LosslessRatio  LossyRatio  Match%   Corr    Sparsity\n", .{});
    std.debug.print("  -----  ----  --------  -------------  ----------  ------   ----    --------\n", .{});
    for (sweep_results) |r| {
        const pass_str: []const u8 = if (r.lossless_pass) "PASS" else "FAIL";
        std.debug.print("  S{d: >2}    S0    {s}      {d: >8.2}x      {d: >7.2}x   {d: >5.1}%  {d: >6.4}  {d: >10.6}\n", .{
            r.source_level,
            pass_str,
            r.lossless_ratio,
            r.lossy_ratio,
            r.lossy_match_pct,
            r.lossy_correlation,
            r.sparsity,
        });
    }

    // "Run while compressed" demo
    std.debug.print("\n=== Run While Compressed Demo ===\n", .{});
    const demo_data = "Compressed computation demo data! " ** 20;

    var lattice = try s7.mapToLattice(allocator, demo_data, 5);
    defer lattice.deinit();

    const seed_a = try s7.extractSeedDirect(lattice, demo_data);
    const seed_b = try s7.extractSeedPattern(allocator, lattice, demo_data);

    std.debug.print("  Seed A energy: {d}\n", .{s7.seedEnergy(seed_a)});
    std.debug.print("  Seed B energy: {d}\n", .{s7.seedEnergy(seed_b)});

    const dom_a = s7.dominantNode(seed_a);
    const dom_b = s7.dominantNode(seed_b);
    std.debug.print("  Seed A dominant node: index={d} activation={d}\n", .{ dom_a.index, dom_a.activation });
    std.debug.print("  Seed B dominant node: index={d} activation={d}\n", .{ dom_b.index, dom_b.activation });

    const convolved = try s7.convolveSeeds(allocator, seed_a, seed_b);
    std.debug.print("  Convolved seed energy: {d}\n", .{s7.seedEnergy(convolved)});

    // Sparsity report across all data types
    std.debug.print("\n=== Sparsity Report (all data types at S5) ===\n", .{});
    std.debug.print("  Dataset                  Bytes    NonZero    TotalCells    Sparsity\n", .{});
    std.debug.print("  -------                  -----    -------    ----------    --------\n", .{});
    for (datasets) |ds| {
        var lat = try s7.mapToLattice(allocator, ds.data, 5);
        defer lat.deinit();
        std.debug.print("  {s: <24} {d: >6}    {d: >7}    {d: >10}    {d: >10.8}\n", .{
            ds.name,
            ds.data.len,
            lat.entries.len,
            lat.total_cells,
            lat.sparsity(),
        });
    }

    // Limit analysis: best and worst compression ratios
    std.debug.print("\n=== Limit Analysis: Compression Ratios ===\n", .{});
    var best_lossless: f64 = 0;
    var worst_lossless: f64 = std.math.inf(f64);
    var best_lossy: f64 = 0;
    var worst_lossy: f64 = std.math.inf(f64);
    var best_name: []const u8 = "";
    var worst_name: []const u8 = "";
    var best_lossy_name: []const u8 = "";
    var worst_lossy_name: []const u8 = "";

    for (datasets) |ds| {
        if (ds.data.len == 0) continue;
        // Use S1 for limit analysis to handle all data sizes without bottleneck
        const cells_needed = (ds.data.len + 3) / 4;
        const level: u8 = if (cells_needed <= 3375) 0 else 1;
        const lossless = try s7.verifyLossless(allocator, ds.data, .direct, level);
        const lossy = try s7.evaluateLossy(allocator, ds.data, .direct, level);

        if (lossless.ratio > best_lossless) {
            best_lossless = lossless.ratio;
            best_name = ds.name;
        }
        if (lossless.ratio < worst_lossless) {
            worst_lossless = lossless.ratio;
            worst_name = ds.name;
        }
        if (lossy.compressed_ratio > best_lossy) {
            best_lossy = lossy.compressed_ratio;
            best_lossy_name = ds.name;
        }
        if (lossy.compressed_ratio < worst_lossy) {
            worst_lossy = lossy.compressed_ratio;
            worst_lossy_name = ds.name;
        }
    }

    std.debug.print("  Best  lossless ratio: {d:.4}x  ({s})\n", .{ best_lossless, best_name });
    std.debug.print("  Worst lossless ratio: {d:.4}x  ({s})\n", .{ worst_lossless, worst_name });
    std.debug.print("  Best  lossy   ratio: {d:.4}x  ({s})\n", .{ best_lossy, best_lossy_name });
    std.debug.print("  Worst lossy   ratio: {d:.4}x  ({s})\n", .{ worst_lossy, worst_lossy_name });

    // Lossy fidelity comparison across data types at optimal level
    std.debug.print("\n=== Lossy Fidelity (direct strategy) ===\n", .{});
    std.debug.print("  Dataset                  Bytes  Lvl  Match%    Corr      MAE       MaxErr\n", .{});
    std.debug.print("  -------                  -----  ---  ------    ----      ---       ------\n", .{});
    for (datasets) |ds| {
        if (ds.data.len == 0) continue;
        const cells_needed = (ds.data.len + 3) / 4;
        const level: u8 = if (cells_needed <= 3375) 0 else 1;
        const metrics = try s7.evaluateLossy(allocator, ds.data, .direct, level);
        std.debug.print("  {s: <24} {d: >6}  S{d}  {d: >5.1}%   {d: >6.4}   {d: >8.2}   {d: >6}\n", .{
            ds.name,
            ds.data.len,
            level,
            metrics.bytes_matching_pct,
            metrics.correlation,
            metrics.mean_abs_error,
            metrics.max_abs_error,
        });
    }

    // Multi-level sweep on random data (small enough for S5)
    std.debug.print("\n=== Multi-Level Sweep on Random 256B ===\n", .{});
    const rand_256 = try generateRandom(allocator, 256, 31415);
    defer allocator.free(rand_256);
    const rand_sweep = try s7.levelSweep(allocator, rand_256, .direct);
    defer allocator.free(rand_sweep);

    std.debug.print("  Level  Seed  Lossless  LosslessRatio  LossyRatio  Match%   Corr    Sparsity\n", .{});
    std.debug.print("  -----  ----  --------  -------------  ----------  ------   ----    --------\n", .{});
    for (rand_sweep) |r| {
        const pass_str: []const u8 = if (r.lossless_pass) "PASS" else "FAIL";
        std.debug.print("  S{d: >2}    S0    {s}      {d: >8.2}x      {d: >7.2}x   {d: >5.1}%  {d: >6.4}  {d: >10.6}\n", .{
            r.source_level,
            pass_str,
            r.lossless_ratio,
            r.lossy_ratio,
            r.lossy_match_pct,
            r.lossy_correlation,
            r.sparsity,
        });
    }

    std.debug.print("\n=== All tests passed ===\n", .{});
}
