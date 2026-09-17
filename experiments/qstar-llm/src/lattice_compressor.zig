//! lattice_compressor.zig — S7→S0 / S0→S7 lattice state compression.
//!
//! Uses TurboQuant vector quantization to compress the 421×7 i64 lattice
//! activations into a compact seed. The compression is lossy but bounded.
//!
//! S7 = full 7-channel lattice state (421 nodes × 7 channels × i64)
//! S0 = compressed seed (TurboQuant codebook indices + scale + norm)
//!
//! Floating-point is used ONLY in this sidecar module. The core lattice
//! state remains i64.

const std = @import("std");
const tq = @import("turbo_quant");

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;
pub const LATTICE_STATE_SIZE: usize = E0_NODE_COUNT * CHANNEL_COUNT;

pub const BITS_2: u8 = 2;
pub const BITS_4: u8 = 4;

pub const CompressionResult = struct {
    seed: tq.TQSeed,
    original_bytes: usize,
    compressed_bytes: usize,
    ratio: f64,
    max_error: f64,
    mean_error: f64,

    pub fn deinit(self: *CompressionResult) void {
        self.seed.deinit();
    }
};

/// Computes a CRC32 checksum of the original i64 activation data.
fn computeChecksum(activations: []const i64) u32 {
    var hasher = std.hash.Crc32.init();
    for (activations) |a| {
        hasher.update(std.mem.asBytes(&a));
    }
    return hasher.final();
}

/// Compresses the full 7-channel lattice state (S7) into a compact seed (S0).
pub fn compressLatticeState(
    allocator: std.mem.Allocator,
    activations: []const i64,
    bits: u8,
) !CompressionResult {
    if (activations.len != LATTICE_STATE_SIZE) return error.InvalidStateSize;

    const f64_data = try tq.i64ToF64(allocator, activations);
    defer allocator.free(f64_data);

    const original_bytes = activations.len * @sizeOf(i64);
    const checksum = computeChecksum(activations);

    const seed = try tq.tqEncode(allocator, f64_data, bits, activations.len, checksum);

    // Decode to measure error
    const reconstructed = try tq.tqDecode(allocator, seed);
    defer allocator.free(reconstructed);

    const recon_i64 = try tq.f64ToI64(allocator, reconstructed);
    defer allocator.free(recon_i64);

    var max_error: f64 = 0;
    var sum_error: f64 = 0;
    for (activations, recon_i64) |orig, recon| {
        const err = @as(f64, @floatFromInt(@abs(orig - recon)));
        if (err > max_error) max_error = err;
        sum_error += err;
    }
    const mean_error = sum_error / @as(f64, @floatFromInt(activations.len));

    const compressed_bytes = seed.sizeBytes();
    const ratio = @as(f64, @floatFromInt(original_bytes)) / @as(f64, @floatFromInt(compressed_bytes));

    return .{
        .seed = seed,
        .original_bytes = original_bytes,
        .compressed_bytes = compressed_bytes,
        .ratio = ratio,
        .max_error = max_error,
        .mean_error = mean_error,
    };
}

/// Compresses the full 7-channel lattice state using channel-aware encoding.
pub fn compressLatticeStateChannelAware(
    allocator: std.mem.Allocator,
    activations: []const i64,
    bits: u8,
) !CompressionResult {
    if (activations.len != LATTICE_STATE_SIZE) return error.InvalidStateSize;

    // Convert slice to array for tqEncodeChannel
    var arr: [E0_NODE_COUNT * CHANNEL_COUNT]i64 = undefined;
    @memcpy(&arr, activations[0..LATTICE_STATE_SIZE]);

    const original_bytes = activations.len * @sizeOf(i64);
    const checksum = computeChecksum(activations);

    const seed = try tq.tqEncodeChannel(allocator, arr, bits, activations.len, checksum);

    // Decode to measure error (returns [LATTICE_STATE_SIZE]i64)
    const reconstructed = try tq.tqDecodeChannel(allocator, seed);

    var max_error: f64 = 0;
    var sum_error: f64 = 0;
    for (activations, &reconstructed) |orig, recon| {
        const err = @as(f64, @floatFromInt(@abs(orig - recon)));
        if (err > max_error) max_error = err;
        sum_error += err;
    }
    const mean_error = sum_error / @as(f64, @floatFromInt(activations.len));

    const compressed_bytes = seed.sizeBytes();
    const ratio = @as(f64, @floatFromInt(original_bytes)) / @as(f64, @floatFromInt(compressed_bytes));

    return .{
        .seed = seed,
        .original_bytes = original_bytes,
        .compressed_bytes = compressed_bytes,
        .ratio = ratio,
        .max_error = max_error,
        .mean_error = mean_error,
    };
}

/// Decompresses a seed (S0) back into the full 7-channel lattice state (S7).
pub fn decompressLatticeState(
    allocator: std.mem.Allocator,
    seed: tq.TQSeed,
) ![]i64 {
    const f64_data = try tq.tqDecode(allocator, seed);
    defer allocator.free(f64_data);
    return try tq.f64ToI64(allocator, f64_data);
}

/// Decompresses a channel-aware seed (S0) back into the full 7-channel lattice state (S7).
pub fn decompressLatticeStateChannelAware(
    allocator: std.mem.Allocator,
    seed: tq.TQSeed,
) ![E0_NODE_COUNT * CHANNEL_COUNT]i64 {
    return try tq.tqDecodeChannel(allocator, seed);
}

/// Serializes a compression result to a byte buffer for storage/transport.
pub fn serializeCompressionResult(
    allocator: std.mem.Allocator,
    result: CompressionResult,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const magic = [_]u8{ 'L', 'C', 'M', 'P' };
    try buf.appendSlice(&magic);
    try buf.append(1); // version
    try buf.append(result.seed.bits);
    try buf.appendSlice(std.mem.asBytes(&result.original_bytes));
    try buf.appendSlice(std.mem.asBytes(&result.compressed_bytes));
    try buf.appendSlice(std.mem.asBytes(&result.seed.norm));
    try buf.appendSlice(std.mem.asBytes(&result.seed.scale));
    try buf.appendSlice(std.mem.asBytes(&result.seed.dim));
    try buf.appendSlice(std.mem.asBytes(&result.seed.original_len));
    try buf.appendSlice(std.mem.asBytes(&result.seed.checksum));
    try buf.appendSlice(std.mem.asBytes(&result.seed.packed_codes.len));
    try buf.appendSlice(result.seed.packed_codes);

    return try buf.toOwnedSlice();
}

/// Deserializes a compression result from a byte buffer.
pub fn deserializeCompressionResult(
    allocator: std.mem.Allocator,
    data: []const u8,
) !CompressionResult {
    if (data.len < 46) return error.CorruptedData;
    if (!std.mem.eql(u8, data[0..4], "LCMP")) return error.InvalidMagic;
    if (data[4] != 1) return error.UnsupportedVersion;

    const bits = data[5];
    var offset: usize = 6;

    var original_bytes: usize = undefined;
    @memcpy(std.mem.asBytes(&original_bytes), data[offset..][0..@sizeOf(usize)]);
    offset += @sizeOf(usize);

    var compressed_bytes: usize = undefined;
    @memcpy(std.mem.asBytes(&compressed_bytes), data[offset..][0..@sizeOf(usize)]);
    offset += @sizeOf(usize);

    var norm: f64 = undefined;
    @memcpy(std.mem.asBytes(&norm), data[offset..][0..@sizeOf(f64)]);
    offset += @sizeOf(f64);

    var scale: f64 = undefined;
    @memcpy(std.mem.asBytes(&scale), data[offset..][0..@sizeOf(f64)]);
    offset += @sizeOf(f64);

    var dim: usize = undefined;
    @memcpy(std.mem.asBytes(&dim), data[offset..][0..@sizeOf(usize)]);
    offset += @sizeOf(usize);

    var original_len: usize = undefined;
    @memcpy(std.mem.asBytes(&original_len), data[offset..][0..@sizeOf(usize)]);
    offset += @sizeOf(usize);

    var checksum: u32 = undefined;
    @memcpy(std.mem.asBytes(&checksum), data[offset..][0..@sizeOf(u32)]);
    offset += @sizeOf(u32);

    var packed_len: usize = undefined;
    @memcpy(std.mem.asBytes(&packed_len), data[offset..][0..@sizeOf(usize)]);
    offset += @sizeOf(usize);

    if (offset + packed_len > data.len) return error.CorruptedData;
    const packed_codes = try allocator.dupe(u8, data[offset..][0..packed_len]);

    const seed = tq.TQSeed{
        .packed_codes = packed_codes,
        .scale = scale,
        .norm = norm,
        .bits = bits,
        .dim = dim,
        .original_len = original_len,
        .checksum = checksum,
        .calib_shifts = null,
        .calib_scales = null,
        .allocator = allocator,
    };

    const ratio = @as(f64, @floatFromInt(original_bytes)) / @as(f64, @floatFromInt(compressed_bytes));

    return .{
        .seed = seed,
        .original_bytes = original_bytes,
        .compressed_bytes = compressed_bytes,
        .ratio = ratio,
        .max_error = 0,
        .mean_error = 0,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "lattice_compressor: S7→S0→S7 round trip with 2-bit quantization" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (&activations, 0..) |*a, i| {
        const node = i / CHANNEL_COUNT;
        const ch = i % CHANNEL_COUNT;
        a.* = @as(i64, @intCast(node)) * 1000 + @as(i64, @intCast(ch)) * 100 - 500;
    }

    var result = try compressLatticeState(allocator, &activations, BITS_2);
    defer result.deinit();

    try std.testing.expect(result.compressed_bytes > 0);
    try std.testing.expect(result.compressed_bytes < result.original_bytes);
    try std.testing.expect(result.ratio > 1.0);

    const decompressed = try decompressLatticeState(allocator, result.seed);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, LATTICE_STATE_SIZE), decompressed.len);
}

test "lattice_compressor: S7→S0→S7 round trip with 4-bit quantization" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i64, @intCast(i % 1000)) - 500;
    }

    var result = try compressLatticeState(allocator, &activations, BITS_4);
    defer result.deinit();

    try std.testing.expect(result.compressed_bytes > 0);
    try std.testing.expect(result.ratio > 1.0);

    const decompressed = try decompressLatticeState(allocator, result.seed);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, LATTICE_STATE_SIZE), decompressed.len);
}

test "lattice_compressor: channel-aware compression round trip" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (&activations, 0..) |*a, i| {
        const node = i / CHANNEL_COUNT;
        const ch = i % CHANNEL_COUNT;
        a.* = @as(i64, @intCast(node)) * 100 + @as(i64, @intCast(ch)) * 10;
    }

    var result = try compressLatticeStateChannelAware(allocator, &activations, BITS_4);
    defer result.deinit();

    try std.testing.expect(result.compressed_bytes > 0);

    const decompressed = try decompressLatticeStateChannelAware(allocator, result.seed);
    try std.testing.expectEqual(@as(usize, LATTICE_STATE_SIZE), decompressed.len);
}

test "lattice_compressor: compression ratio is meaningful" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (&activations, 0..) |*a, i| a.* = @as(i64, @intCast(i));

    var result_2bit = try compressLatticeState(allocator, &activations, BITS_2);
    defer result_2bit.deinit();

    var result_4bit = try compressLatticeState(allocator, &activations, BITS_4);
    defer result_4bit.deinit();

    try std.testing.expectEqual(@as(usize, 23576), result_2bit.original_bytes);
    try std.testing.expect(result_2bit.compressed_bytes <= result_4bit.compressed_bytes);
    try std.testing.expect(result_2bit.ratio >= result_4bit.ratio);
}

test "lattice_compressor: zero state compression" {
    const allocator = std.testing.allocator;

    const activations = [_]i64{0} ** LATTICE_STATE_SIZE;

    var result = try compressLatticeState(allocator, &activations, BITS_2);
    defer result.deinit();

    try std.testing.expect(result.max_error == 0);
    try std.testing.expect(result.mean_error == 0);

    const decompressed = try decompressLatticeState(allocator, result.seed);
    defer allocator.free(decompressed);

    for (decompressed) |v| {
        try std.testing.expectEqual(@as(i64, 0), v);
    }
}

test "lattice_compressor: serialization round trip" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (&activations, 0..) |*a, i| a.* = @as(i64, @intCast(i % 500)) - 250;

    var result = try compressLatticeState(allocator, &activations, BITS_4);
    defer result.deinit();

    const serialized = try serializeCompressionResult(allocator, result);
    defer allocator.free(serialized);

    var deserialized = try deserializeCompressionResult(allocator, serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(result.original_bytes, deserialized.original_bytes);
    try std.testing.expectEqual(result.compressed_bytes, deserialized.compressed_bytes);
    try std.testing.expectEqual(result.seed.bits, deserialized.seed.bits);
    try std.testing.expectEqual(result.seed.norm, deserialized.seed.norm);
    try std.testing.expectEqual(result.seed.scale, deserialized.seed.scale);
    try std.testing.expectEqual(result.seed.checksum, deserialized.seed.checksum);
}

test "lattice_compressor: invalid state size rejected" {
    const allocator = std.testing.allocator;
    const wrong_size = [_]i64{ 1, 2, 3 };

    const result = compressLatticeState(allocator, &wrong_size, BITS_2);
    try std.testing.expectError(error.InvalidStateSize, result);
}

test "lattice_compressor: error bounds are bounded" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i64, @intCast(i)) * 1_000_000;
    }

    var result_4bit = try compressLatticeState(allocator, &activations, BITS_4);
    defer result_4bit.deinit();

    const max_activation: f64 = @as(f64, @floatFromInt(LATTICE_STATE_SIZE)) * 1_000_000;
    const error_ratio = result_4bit.max_error / max_activation;
    try std.testing.expect(error_ratio < 0.2);
}
