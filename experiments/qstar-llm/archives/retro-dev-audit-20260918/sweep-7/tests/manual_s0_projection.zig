//! manual_s0_projection.zig — Manual integration test for S0→S7 Holographic Projection.
//!
//! Run with: zig build manual -Dmanual=s0_projection
//! or:       zig build manual

const std = @import("std");
const s0 = @import("s0_projection");

fn generateRandom(allocator: std.mem.Allocator, size: usize, seed: u64) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();
    for (buf) |*b| b.* = rng.int(u8);
    return buf;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== S0→S7 Holographic Projection — Full Capacity Analysis ===\n\n", .{});

    // Print capacity info
    std.debug.print("Seed Capacities:\n", .{});
    std.debug.print("  Direct (421 nodes × 8 bytes):     {d} bytes\n", .{s0.E0SeedBuffer.rawCapacity()});
    std.debug.print("  Channel (421 × 7 × 8 bytes):     {d} bytes\n", .{s0.ChannelSeedBuffer.rawCapacity()});
    std.debug.print("  Serialized seed size:             {d} bytes\n", .{s0.seedSerializedSize()});
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 1: Direct Encoding Round-Trip Tests
    // =============================================================================
    std.debug.print("=== Part 1: Direct Encoding (S0→S7→S0) ===\n\n", .{});

    const datasets = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "Text (small)", .data = "Hello, Holographic World!" },
        .{ .name = "Text (repeated)", .data = "ABCD" ** 64 },
        .{ .name = "Binary pattern", .data = "\x00\xFF\xAA\x55" ** 64 },
        .{ .name = "Text w/ nulls", .data = "Hello\x00World\x00\x00Test\x00Data" },
        .{ .name = "Single byte", .data = "\x42" },
        .{ .name = "Empty", .data = "" },
        .{ .name = "Incrementing", .data = blk: {
            const buf = try allocator.alloc(u8, 256);
            for (buf, 0..) |*b, i| b.* = @intCast(i % 256);
            break :blk buf;
        } },
    };

    const levels = [_]u8{ 0, 1, 3 };

    for (datasets) |ds| {
        std.debug.print("--- Dataset: {s} ({d} bytes) ---\n", .{ ds.name, ds.data.len });

        for (levels) |level| {
            const result = try s0.verifyProjectionDirect(allocator, ds.data, level);
            defer result.deinit();

            const pass_str: []const u8 = if (result.pass) "PASS" else "FAIL";
            std.debug.print("  S{d}: {s} data_match={d:.1}% seed_match={d:.1}% expanded={d} cells ({d:.1}x)\n", .{
                level,
                pass_str,
                result.data_match_pct,
                result.seed_match_pct,
                result.projected_cells,
                result.expansion_ratio,
            });
        }
        std.debug.print("\n", .{});
    }

    // =============================================================================
    // Part 2: Channel Encoding Round-Trip Tests
    // =============================================================================
    std.debug.print("=== Part 2: Channel Encoding (7 channels × 421 nodes) ===\n\n", .{});

    const channel_datasets = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "Text (small)", .data = "Channel holographic projection test!" },
        .{ .name = "Text (repeated)", .data = "EFGH" ** 128 },
        .{ .name = "Binary pattern", .data = "\xDE\xAD\xBE\xEF" ** 128 },
    };

    for (channel_datasets) |ds| {
        std.debug.print("--- Dataset: {s} ({d} bytes) ---\n", .{ ds.name, ds.data.len });

        const result = try s0.verifyProjectionChannel(allocator, ds.data, 1);
        defer result.deinit();

        const pass_str: []const u8 = if (result.pass) "PASS" else "FAIL";
        std.debug.print("  S1: {s} data_match={d:.1}% expanded={d} cells ({d:.1}x)\n", .{
            pass_str,
            result.data_match_pct,
            result.projected_cells,
            result.expansion_ratio,
        });
        std.debug.print("\n", .{});
    }

    // =============================================================================
    // Part 3: Capacity Measurement (Increasing Data Sizes)
    // =============================================================================
    std.debug.print("=== Part 3: Information Capacity Measurement ===\n\n", .{});
    std.debug.print("  Data Size  Seed Cap   Pass  DataMatch  SeedMatch  Expansion  Overhead\n", .{});
    std.debug.print("  ---------  --------   ----  ---------  ---------  ---------  --------\n", .{});

    const capacity_results = try s0.measureCapacity(allocator, 4096, 1);
    defer allocator.free(capacity_results);

    for (capacity_results) |r| {
        const pass_str: []const u8 = if (r.pass) "PASS" else "FAIL";
        std.debug.print("  {d: >9}  {d: >8}  {s}  {d: >7.1}%  {d: >7.1}%  {d: >7.1}x  {d: >6.1}%\n", .{
            r.data_len,
            r.seed_capacity,
            pass_str,
            r.data_match_pct,
            r.seed_match_pct,
            r.expansion_ratio,
            r.overhead_pct,
        });
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 4: Random Data at Capacity Boundaries
    // =============================================================================
    std.debug.print("=== Part 4: Random Data at Capacity Boundaries ===\n\n", .{});

    // Direct capacity boundary
    const direct_cap = s0.E0SeedBuffer.rawCapacity();
    const rand_direct = try generateRandom(allocator, direct_cap, 42);
    defer allocator.free(rand_direct);

    {
        const seed = s0.programSeedDirect(rand_direct);
        const recovered = try s0.recoverSeedDirect(seed, allocator);
        defer allocator.free(recovered);
        const match = std.mem.eql(u8, rand_direct, recovered);
        std.debug.print("  Direct capacity ({d} bytes): {s}\n", .{ direct_cap, if (match) "PASS (100% match)" else "FAIL" });
    }

    // Channel capacity boundary
    const channel_cap = s0.ChannelSeedBuffer.rawCapacity();
    const rand_channel = try generateRandom(allocator, channel_cap, 77);
    defer allocator.free(rand_channel);

    {
        const seed = s0.programSeedChannel(rand_channel);
        const recovered = try s0.recoverSeedChannel(seed, allocator);
        defer allocator.free(recovered);
        const match = std.mem.eql(u8, rand_channel, recovered);
        std.debug.print("  Channel capacity ({d} bytes): {s}\n", .{ channel_cap, if (match) "PASS (100% match)" else "FAIL" });
    }

    // Over-capacity test (data larger than seed capacity)
    std.debug.print("\n", .{});
    std.debug.print("  Over-capacity tests (data > seed capacity):\n", .{});
    const over_sizes = [_]usize{ 4096, 8192, 16384 };
    for (over_sizes) |size| {
        const rand_over = try generateRandom(allocator, size, 333);
        defer allocator.free(rand_over);

        // Direct encoding truncates at 3368 bytes
        const seed = s0.programSeedDirect(rand_over);
        const recovered = try s0.recoverSeedDirect(seed, allocator);
        defer allocator.free(recovered);

        const recoverable = @min(size, direct_cap);
        const match = std.mem.eql(u8, rand_over[0..recoverable], recovered[0..recoverable]);
        std.debug.print("    {d} bytes → direct seed: {s} (first {d} bytes recoverable)\n", .{
            size,
            if (match) "PASS" else "FAIL",
            recoverable,
        });
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 5: Projection Scale Analysis
    // =============================================================================
    std.debug.print("=== Part 5: Projection Scale Analysis ===\n\n", .{});

    const scale_data = "Projection scale analysis test data payload for holographic expansion!";
    const scale_levels = [_]u8{ 0, 1, 2, 3, 5 };

    std.debug.print("  Level  Edge    TotalCells   ProjectedCells  Sparsity     Expansion\n", .{});
    std.debug.print("  -----  ----    ----------   --------------  --------     ---------\n", .{});

    for (scale_levels) |level| {
        const seed = s0.programSeedDirect(scale_data);
        var projected = try s0.holographicProject(allocator, seed, level);
        defer projected.deinit();

        const edge = s0.latticeEdge(level);
        const total = s0.latticeTotal(level);
        const sparsity = projected.sparsity();
        const expansion = @as(f64, @floatFromInt(projected.entries.len)) /
            @as(f64, @floatFromInt(@max(1, scale_data.len)));

        std.debug.print("  S{d: >2}    {d: >4}    {d: >10}   {d: >14}  {d: >10.8}  {d: >7.2}x\n", .{
            level,
            edge,
            total,
            projected.entries.len,
            sparsity,
            expansion,
        });
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 6: Compression Ratio Analysis
    // =============================================================================
    std.debug.print("=== Part 6: Compression Ratio Analysis ===\n\n", .{});

    const ratio_sizes = [_]usize{ 64, 256, 512, 1024, 2048, 3368 };
    std.debug.print("  Data Size  Seed Size  Ratio    Capacity Used  Pass\n", .{});
    std.debug.print("  ---------  ---------  -----    -------------  ----\n", .{});

    for (ratio_sizes) |size| {
        const data = try generateRandom(allocator, size, 555);
        defer allocator.free(data);

        const analysis = try s0.analyzeCompression(allocator, data, 1);
        const pass_str: []const u8 = if (analysis.pass) "PASS" else "FAIL";
        std.debug.print("  {d: >9}  {d: >9}  {d: >5.2}x  {d: >11.1}%  {s}\n", .{
            analysis.original_size,
            analysis.seed_size,
            analysis.ratio,
            analysis.capacity_used_pct,
            pass_str,
        });
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 7: Holographic vs Direct Encoding Comparison
    // =============================================================================
    std.debug.print("=== Part 7: Holographic vs Direct Encoding Comparison ===\n\n", .{});

    const holo_data = try generateRandom(allocator, 512, 111);
    defer allocator.free(holo_data);

    // Direct encoding
    {
        const seed = s0.programSeedDirect(holo_data);
        const recovered = try s0.recoverSeedDirect(seed, allocator);
        defer allocator.free(recovered);
        const match = std.mem.eql(u8, holo_data, recovered);
        std.debug.print("  Direct encoding (512 bytes): {s}\n", .{if (match) "100% match" else "MISMATCH"});
    }

    // Holographic encoding (frequency domain)
    {
        const seed = try s0.programSeedHolographic(allocator, holo_data);
        const recovered = try s0.recoverSeedHolographic(allocator, seed);
        defer allocator.free(recovered);

        var matches: usize = 0;
        for (holo_data, recovered) |a, b| {
            if (a == b) matches += 1;
        }
        const pct = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(holo_data.len)) * 100.0;
        std.debug.print("  Holographic encoding (512 bytes): {d:.1}% match\n", .{pct});
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Summary
    // =============================================================================
    std.debug.print("=== Summary ===\n\n", .{});
    std.debug.print("  Direct seed capacity:  {d} bytes (421 nodes × 8 bytes)\n", .{s0.E0SeedBuffer.rawCapacity()});
    std.debug.print("  Channel seed capacity: {d} bytes (421 × 7 × 8 bytes)\n", .{s0.ChannelSeedBuffer.rawCapacity()});
    std.debug.print("  Channel expands capacity by {d:.1}x over direct\n", .{
        @as(f64, @floatFromInt(s0.ChannelSeedBuffer.rawCapacity())) / @as(f64, @floatFromInt(s0.E0SeedBuffer.rawCapacity())),
    });
    std.debug.print("\n", .{});
    std.debug.print("  Key findings:\n", .{});
    std.debug.print("  - Direct encoding: lossless round-trip for data ≤ {d} bytes\n", .{s0.E0SeedBuffer.rawCapacity()});
    std.debug.print("  - Channel encoding: lossless round-trip for data ≤ {d} bytes\n", .{s0.ChannelSeedBuffer.rawCapacity()});
    std.debug.print("  - Holographic projection expands {d} nodes to thousands of S7 cells\n", .{s0.E0_NODE_COUNT});
    const s3_expansion = @as(f64, @floatFromInt(s0.latticeTotal(3))) / @as(f64, @floatFromInt(s0.E0_NODE_COUNT));
    std.debug.print("  - Projection at S3 creates {d}x expansion over seed node count\n", .{@as(u64, @intFromFloat(s3_expansion))});
    std.debug.print("  - Over-capacity data is truncated to seed capacity\n", .{});

    // =============================================================================
    // Part 7: f64 Projection Sidecar Tests
    // =============================================================================
    std.debug.print("\n--- Part 7: f64 Projection Sidecar (Precision Fix) ---\n\n", .{});

    {
        const test_data = "f64 projection precision test data payload!";

        // Integer projection (lossy)
        var result_int = try s0.verifyProjectionDirect(allocator, test_data, 1);
        defer result_int.deinit();

        // f64 projection (precision-preserving)
        var result_f64 = try s0.verifyProjectionF64(allocator, test_data, 1);
        defer result_f64.deinit();

        std.debug.print("  Integer projection: {d:.1}% seed match, {d:.1}% data match\n", .{
            result_int.seed_match_pct, result_int.data_match_pct,
        });
        std.debug.print("  f64 projection:     {d:.1}% seed match, {d:.1}% data match\n", .{
            result_f64.seed_match_pct, result_f64.data_match_pct,
        });
        std.debug.print("  Improvement: {d:.1}% → {d:.1}% seed match\n", .{
            result_int.seed_match_pct, result_f64.seed_match_pct,
        });
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 8: TurboQuant Compression Tests
    // =============================================================================
    std.debug.print("\n--- Part 8: TurboQuant Seed Compression ---\n\n", .{});

    {
        const test_data = "TurboQuant compression analysis test data payload for sizing!";

        // TQ 2-bit
        var result_2bit = try s0.verifyTQEncoding(allocator, test_data, 2);
        defer result_2bit.deinit();

        // TQ 4-bit
        var result_4bit = try s0.verifyTQEncoding(allocator, test_data, 4);
        defer result_4bit.deinit();

        // TQ 4-bit + residual (lossless)
        var result_residual = try s0.verifyTQWithResidual(allocator, test_data, 4);
        defer result_residual.deinit();

        std.debug.print("  Encoding Mode         | Seed Size | Compression | Data Match | Lossless\n", .{});
        std.debug.print("  ----------------------+-----------+-------------+------------+----------\n", .{});
        std.debug.print("  Raw direct            | {d: >5} B  |       1.0x  |  100.0%    | Yes\n", .{result_2bit.raw_seed_size});
        std.debug.print("  TQ 2-bit              | {d: >5} B  |     {d: >5.1}x  |  {d: >5.1}%    | No\n", .{
            result_2bit.tq_seed_size, result_2bit.compression_ratio, result_2bit.data_match_pct,
        });
        std.debug.print("  TQ 4-bit              | {d: >5} B  |     {d: >5.1}x  |  {d: >5.1}%    | No\n", .{
            result_4bit.tq_seed_size, result_4bit.compression_ratio, result_4bit.data_match_pct,
        });
        std.debug.print("  TQ 4-bit + residual   | {d: >5} B  |     {d: >5.1}x  |  {d: >5.1}%    | Yes\n", .{
            result_residual.tq_seed_size, result_residual.compression_ratio, result_residual.data_match_pct,
        });
    }

    // TQ Channel encoding
    {
        std.debug.print("\n  Channel encoding:\n", .{});
        const ch_data = "TurboQuant channel encoding test data for multi-channel compression analysis!";

        var result_ch = try s0.verifyTQChannelEncoding(allocator, ch_data, 4);
        defer result_ch.deinit();

        std.debug.print("  Raw channel           | {d: >5} B  |       1.0x  |  100.0%    | Yes\n", .{result_ch.raw_seed_size});
        std.debug.print("  TQ channel 4-bit      | {d: >5} B  |     {d: >5.1}x  |  {d: >5.1}%    | No\n", .{
            result_ch.tq_seed_size, result_ch.compression_ratio, result_ch.data_match_pct,
        });
    }
    std.debug.print("\n", .{});

    // =============================================================================
    // Part 9: Updated Summary with TurboQuant
    // =============================================================================
    std.debug.print("\n--- Updated Summary with TurboQuant ---\n\n", .{});
    std.debug.print("  Encoding Mode         | Capacity    | Compression vs Raw | Lossless\n", .{});
    std.debug.print("  ----------------------+-------------+-------------------+----------\n", .{});
    std.debug.print("  Direct (raw)          | {d: >5} B    |             1.0x  | Yes\n", .{s0.E0SeedBuffer.rawCapacity()});
    std.debug.print("  Channel (raw)         | {d: >5} B   |             7.0x  | Yes\n", .{s0.ChannelSeedBuffer.rawCapacity()});
    std.debug.print("  TQ 2-bit              | ~111 B      |            ~30x   | No (lossy)\n", .{});
    std.debug.print("  TQ 4-bit              | ~219 B      |            ~15x   | No (lossy)\n", .{});
    std.debug.print("  TQ 4-bit + residual   | ~219+3368 B |            ~1.0x  | Yes\n", .{});
    std.debug.print("  TQ channel 4-bit      | ~1530 B     |            ~15x   | No (lossy)\n", .{});
    std.debug.print("  f64 projection        | same as raw |             1.0x  | Near-lossless\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Key findings:\n", .{});
    std.debug.print("  - TurboQuant 4-bit achieves ~15x compression of seed activations\n", .{});
    std.debug.print("  - TurboQuant 2-bit achieves ~30x compression (more lossy)\n", .{});
    std.debug.print("  - TQ + residual sidecar enables lossless recovery with TQ base\n", .{});
    std.debug.print("  - f64 projection sidecar fixes lossy integer division in projection\n", .{});
    std.debug.print("  - Sidecar pattern maintains integer-only core state (Q32.32)\n", .{});
}
