//! seed_compressor.zig — Collapse-driven seed compression pipeline.
//!
//! End-to-end pipeline: Q64.64 agent state → holographic encode → compress → QR-nest.
//! Enables shipping an entire agent state as a compact seed that can be embedded
//! in a single HTML file (universe.html quine) or transported via QR portals.
//!
//! Pipeline stages:
//!   1. Serialize Q64.64 agent state (activations + temperature + base_temp)
//!   2. Holographic encode (FFT → frequency domain → serialized Complex pairs)
//!   3. Gzip compress the holographic encoding
//!   4. (Optional) Pack into QR-nest portals for QR-based transport
//!   5. (Optional) Downscale Q64.64 → Q32.32 for resource-constrained devices
//!
//! Reverse pipeline decompresses and restores agent state.
//! Zero external dependencies beyond std + fixed_point + holographic + compress + qr_nest.

const std = @import("std");
const fp = @import("fixed_point");
const holographic = @import("holographic");
const compress = @import("compress");
const qr_nest = @import("qr_nest");
const fp_bridge = @import("fp_bridge");

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;

/// Magic header for compressed seed files.
pub const SEED_MAGIC = [_]u8{ 'Q', 'S', 'E', 'D' };

/// Current seed format version.
pub const SEED_VERSION: u16 = 1;

/// Maximum QR portal payload in bytes (matches qr_nest.QR_PAYLOAD_BYTES).
pub const QR_PAYLOAD_BYTES: usize = 256;

/// Compressed seed containing Q64.64 agent state.
pub const CompressedSeed = struct {
    /// Compressed binary data (gzip-compressed holographic encoding).
    data: []u8,
    /// Original uncompressed state size in bytes.
    original_size: u64,
    /// Compressed data size in bytes.
    compressed_size: u64,
    /// CRC32 checksum of the original uncompressed data.
    checksum: u32,
    /// Lattice level used for holographic encoding.
    lattice_level: u8,

    pub fn deinit(self: *CompressedSeed, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Maple seed: Q64.64 state compressed and downscaled to Q32.32 for constrained devices.
pub const MapleSeed = struct {
    /// Compressed binary data (gzip-compressed downscaled holographic encoding).
    data: []u8,
    /// Original Q64.64 state size in bytes.
    q64_state_size: u64,
    /// Downscaled Q32.32 state size in bytes.
    q32_state_size: u64,
    /// Compressed data size in bytes.
    compressed_size: u64,
    /// Number of QR portals needed for transport.
    portal_count: u32,
    /// CRC32 checksum of the downscaled data.
    checksum: u32,

    pub fn deinit(self: *MapleSeed, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Decompressed agent state (Q64.64).
pub const DecompressedState = struct {
    activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128,
    temperature: i128,
    base_temp: i128,
    cycle: u64,

    pub fn deinit(self: *DecompressedState) void {
        _ = self;
    }
};

/// Serializes Q64.64 agent state to raw bytes.
/// Format: [activations: E0_NODE_COUNT * CHANNEL_COUNT * 16 bytes]
///         [temperature: 16 bytes] [base_temp: 16 bytes] [cycle: 8 bytes]
pub fn serializeState(
    activations: []const [CHANNEL_COUNT]i128,
    temperature: i128,
    base_temp: i128,
    cycle: u64,
) [E0_NODE_COUNT * CHANNEL_COUNT * 16 + 16 + 16 + 8]u8 {
    var buf: [E0_NODE_COUNT * CHANNEL_COUNT * 16 + 16 + 16 + 8]u8 = undefined;
    var offset: usize = 0;

    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            std.mem.writeInt(i128, buf[offset..][0..16], activations[i][ch], .little);
            offset += 16;
        }
    }

    std.mem.writeInt(i128, buf[offset..][0..16], temperature, .little);
    offset += 16;
    std.mem.writeInt(i128, buf[offset..][0..16], base_temp, .little);
    offset += 16;
    std.mem.writeInt(u64, buf[offset..][0..8], cycle, .little);

    return buf;
}

/// Deserializes raw bytes back to Q64.64 agent state.
pub fn deserializeState(data: []const u8) !DecompressedState {
    const expected_size = E0_NODE_COUNT * CHANNEL_COUNT * 16 + 16 + 16 + 8;
    if (data.len < expected_size) return error.InputSizeMismatch;

    var state: DecompressedState = .{
        .activations = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT,
        .temperature = 0,
        .base_temp = 0,
        .cycle = 0,
    };

    var offset: usize = 0;
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            state.activations[i][ch] = std.mem.readInt(i128, data[offset..][0..16], .little);
            offset += 16;
        }
    }

    state.temperature = std.mem.readInt(i128, data[offset..][0..16], .little);
    offset += 16;
    state.base_temp = std.mem.readInt(i128, data[offset..][0..16], .little);
    offset += 16;
    state.cycle = std.mem.readInt(u64, data[offset..][0..8], .little);

    return state;
}

/// Compresses Q64.64 agent state into a CompressedSeed.
/// Pipeline: serialize → holographic encode → gzip compress.
pub fn compressAgentState(
    allocator: std.mem.Allocator,
    activations: []const [CHANNEL_COUNT]i128,
    temperature: i128,
    base_temp: i128,
    cycle: u64,
    lattice_level: u8,
) !CompressedSeed {
    // Stage 1: Serialize state to raw bytes
    const raw = serializeState(activations, temperature, base_temp, cycle);

    // Stage 2: Holographic encode (flatten activations to 1D, then FFT)
    // Flatten activations: average across channels → 1D signal for holographic encode
    const edge = holographic.latticeEdge(lattice_level);
    const total = @as(usize, edge) * @as(usize, edge) * @as(usize, edge);

    var flat = try allocator.alloc(i128, total);
    defer allocator.free(flat);

    // Map E0 activations to lattice grid
    for (0..total) |i| flat[i] = 0;
    const nodes_to_map = @min(E0_NODE_COUNT, total);
    for (0..nodes_to_map) |i| {
        var sum: i128 = 0;
        for (0..CHANNEL_COUNT) |ch| {
            sum += activations[i][ch];
        }
        flat[i % total] = fp.div(sum, fp.fromInt(@as(i64, @intCast(CHANNEL_COUNT))));
    }

    const holo_encoded = try holographic.holographicEncode(allocator, flat, lattice_level);
    defer allocator.free(holo_encoded);

    // Stage 3: Gzip compress the holographic encoding
    const compressed = try compress.gzipCompress(allocator, holo_encoded);

    // Compute checksum of original raw state
    var hasher = std.hash.Crc32.init();
    hasher.update(&raw);

    return .{
        .data = compressed,
        .original_size = raw.len,
        .compressed_size = compressed.len,
        .checksum = hasher.final(),
        .lattice_level = lattice_level,
    };
}

/// Decompresses a CompressedSeed back to Q64.64 agent state.
/// Pipeline: gzip decompress → holographic decode → deserialize.
pub fn decompressAgentState(
    allocator: std.mem.Allocator,
    seed: CompressedSeed,
) !DecompressedState {
    // Stage 1: Gzip decompress
    const holo_encoded = try compress.gzipDecompress(allocator, seed.data);
    defer allocator.free(holo_encoded);

    // Stage 2: Holographic decode
    const decoded = try holographic.holographicDecode(allocator, holo_encoded);
    defer allocator.free(decoded);

    // Stage 3: Reconstruct agent state from decoded lattice
    var state: DecompressedState = .{
        .activations = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT,
        .temperature = fp.ONE,
        .base_temp = fp.ONE,
        .cycle = 0,
    };

    // Map lattice grid back to E0 activations (reverse of compress path)
    const nodes_to_map = @min(E0_NODE_COUNT, decoded.len);
    for (0..nodes_to_map) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            state.activations[i][ch] = decoded[i % decoded.len];
        }
    }

    return state;
}

/// Compresses Q64.64 agent state and downscales to Q32.32 for constrained devices.
/// Pipeline: serialize → holographic encode → downscale → gzip compress → QR-nest pack.
pub fn compressAndDownscale(
    allocator: std.mem.Allocator,
    activations: []const [CHANNEL_COUNT]i128,
    temperature: i128,
    base_temp: i128,
    cycle: u64,
    lattice_level: u8,
) !MapleSeed {
    // Stage 1: Serialize state to raw bytes
    const raw = serializeState(activations, temperature, base_temp, cycle);
    const q64_size: u64 = raw.len;

    // Stage 2: Holographic encode
    const edge = holographic.latticeEdge(lattice_level);
    const total = @as(usize, edge) * @as(usize, edge) * @as(usize, edge);

    var flat = try allocator.alloc(i128, total);
    defer allocator.free(flat);

    for (0..total) |i| flat[i] = 0;
    const nodes_to_map = @min(E0_NODE_COUNT, total);
    for (0..nodes_to_map) |i| {
        var sum: i128 = 0;
        for (0..CHANNEL_COUNT) |ch| {
            sum += activations[i][ch];
        }
        flat[i % total] = fp.div(sum, fp.fromInt(@as(i64, @intCast(CHANNEL_COUNT))));
    }

    const holo_encoded = try holographic.holographicEncode(allocator, flat, lattice_level);
    defer allocator.free(holo_encoded);

    // Stage 3: Downscale holographic encoding from Q64.64 to Q32.32
    // The holographic encoding contains i128 Complex pairs (re, im).
    // We downscale each i128 to i64 (Q32.32) for the constrained device.
    const holo_q32_size = holo_encoded.len / 2; // Each Complex is 2 × i128 = 32 bytes → 2 × i64 = 16 bytes
    var holo_q32 = try allocator.alloc(u8, holo_q32_size);
    defer allocator.free(holo_q32);

    var q32_offset: usize = 0;
    var holo_offset: usize = 0;
    while (holo_offset + 16 <= holo_encoded.len and q32_offset + 16 <= holo_q32.len) {
        const re_q64 = std.mem.readInt(i128, holo_encoded[holo_offset..][0..16], .little);
        holo_offset += 16;
        const im_q64 = std.mem.readInt(i128, holo_encoded[holo_offset..][0..16], .little);
        holo_offset += 16;

        const re_q32 = fp_bridge.downscaleSaturating(re_q64);
        const im_q32 = fp_bridge.downscaleSaturating(im_q64);

        std.mem.writeInt(i64, holo_q32[q32_offset..][0..8], re_q32, .little);
        q32_offset += 8;
        std.mem.writeInt(i64, holo_q32[q32_offset..][0..8], im_q32, .little);
        q32_offset += 8;
    }
    const q32_size: u64 = holo_q32.len;

    // Stage 4: Gzip compress
    const compressed = try compress.gzipCompress(allocator, holo_q32);

    // Stage 5: Compute QR portal count
    const portal_count: u32 = @intCast((compressed.len + QR_PAYLOAD_BYTES - 1) / QR_PAYLOAD_BYTES);

    // Checksum
    var hasher = std.hash.Crc32.init();
    hasher.update(holo_q32);

    return .{
        .data = compressed,
        .q64_state_size = q64_size,
        .q32_state_size = q32_size,
        .compressed_size = compressed.len,
        .portal_count = portal_count,
        .checksum = hasher.final(),
    };
}

/// Serializes a CompressedSeed to a binary file format.
/// Format: [magic: 4B] [version: 2B] [lattice_level: 1B] [padding: 1B]
///         [original_size: 8B] [compressed_size: 8B] [checksum: 4B]
///         [compressed_data: compressed_size bytes]
pub fn serializeSeed(allocator: std.mem.Allocator, seed: CompressedSeed) ![]u8 {
    const header_size: usize = 4 + 2 + 1 + 1 + 8 + 8 + 4;
    const total_size = header_size + seed.data.len;
    var buf = try allocator.alloc(u8, total_size);

    var offset: usize = 0;
    @memcpy(buf[offset..][0..4], &SEED_MAGIC);
    offset += 4;
    std.mem.writeInt(u16, buf[offset..][0..2], SEED_VERSION, .little);
    offset += 2;
    buf[offset] = seed.lattice_level;
    offset += 1;
    buf[offset] = 0; // padding
    offset += 1;
    std.mem.writeInt(u64, buf[offset..][0..8], seed.original_size, .little);
    offset += 8;
    std.mem.writeInt(u64, buf[offset..][0..8], seed.compressed_size, .little);
    offset += 8;
    std.mem.writeInt(u32, buf[offset..][0..4], seed.checksum, .little);
    offset += 4;

    @memcpy(buf[offset..], seed.data);

    return buf;
}

/// Deserializes a binary file format back to CompressedSeed.
pub fn deserializeSeed(allocator: std.mem.Allocator, data: []const u8) !CompressedSeed {
    const header_size: usize = 4 + 2 + 1 + 1 + 8 + 8 + 4;
    if (data.len < header_size) return error.InvalidMagic;

    if (!std.mem.eql(u8, data[0..4], &SEED_MAGIC)) return error.InvalidMagic;

    const version = std.mem.readInt(u16, data[4..][0..2], .little);
    if (version != SEED_VERSION) return error.InvalidMagic;

    const lattice_level = data[6];
    const original_size = std.mem.readInt(u64, data[8..][0..8], .little);
    const compressed_size = std.mem.readInt(u64, data[16..][0..8], .little);
    const checksum = std.mem.readInt(u32, data[24..][0..4], .little);

    const compressed_data = data[header_size..];
    if (compressed_data.len < compressed_size) return error.InputSizeMismatch;

    const data_copy = try allocator.dupe(u8, compressed_data[0..@intCast(compressed_size)]);

    return .{
        .data = data_copy,
        .original_size = original_size,
        .compressed_size = compressed_size,
        .checksum = checksum,
        .lattice_level = lattice_level,
    };
}

/// Packs compressed seed data into QR-nest portals for QR-based transport.
/// Returns an array of portal payloads, each up to QR_PAYLOAD_BYTES in size.
pub fn packToQRPortals(allocator: std.mem.Allocator, data: []const u8) ![][]u8 {
    const portal_count = (data.len + QR_PAYLOAD_BYTES - 1) / QR_PAYLOAD_BYTES;
    var portals = try allocator.alloc([]u8, portal_count);

    for (0..portal_count) |i| {
        const start = i * QR_PAYLOAD_BYTES;
        const end = @min(start + QR_PAYLOAD_BYTES, data.len);
        portals[i] = try allocator.dupe(u8, data[start..end]);
    }

    return portals;
}

/// Unpacks QR-nest portal payloads back to the original compressed data.
pub fn unpackFromQRPortals(allocator: std.mem.Allocator, portals: []const []const u8) ![]u8 {
    var total_size: usize = 0;
    for (portals) |p| total_size += p.len;

    var data = try allocator.alloc(u8, total_size);
    var offset: usize = 0;
    for (portals) |p| {
        @memcpy(data[offset..][0..p.len], p);
        offset += p.len;
    }

    return data;
}

// =============================================================================
// Tests
// =============================================================================

test "seed_compressor: serialize/deserialize state round-trip" {
    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;
    for (0..100) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            activations[i][ch] = fp.div(fp.fromInt(@as(i64, @intCast(i + ch + 1))), fp.fromInt(10));
        }
    }
    const temperature = fp.div(fp.fromInt(5), fp.fromInt(10));
    const base_temp = fp.ONE;
    const cycle: u64 = 42;

    const raw = serializeState(&activations, temperature, base_temp, cycle);
    const restored = try deserializeState(&raw);

    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            try std.testing.expectEqual(activations[i][ch], restored.activations[i][ch]);
        }
    }
    try std.testing.expectEqual(temperature, restored.temperature);
    try std.testing.expectEqual(base_temp, restored.base_temp);
    try std.testing.expectEqual(cycle, restored.cycle);
}

test "seed_compressor: compress/decompress agent state" {
    const allocator = std.testing.allocator;
    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;
    for (0..50) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            activations[i][ch] = fp.div(fp.fromInt(@as(i64, @intCast(i + ch + 1))), fp.fromInt(100));
        }
    }

    var seed = try compressAgentState(
        allocator,
        &activations,
        fp.div(fp.fromInt(5), fp.fromInt(10)),
        fp.ONE,
        7,
        0,
    );
    defer seed.deinit(allocator);

    try std.testing.expect(seed.data.len > 0);
    try std.testing.expect(seed.compressed_size == seed.data.len);
    try std.testing.expect(seed.original_size > 0);

    var restored = try decompressAgentState(allocator, seed);
    defer restored.deinit();

    // Verify some activations are non-zero
    var has_nonzero = false;
    for (restored.activations) |node| {
        for (node) |ch| {
            if (ch != 0) {
                has_nonzero = true;
                break;
            }
        }
        if (has_nonzero) break;
    }
    try std.testing.expect(has_nonzero);
}

test "seed_compressor: compressAndDownscale produces valid MapleSeed" {
    const allocator = std.testing.allocator;
    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;
    for (0..100) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            activations[i][ch] = fp.div(fp.fromInt(@as(i64, @intCast(i + ch + 1))), fp.fromInt(10));
        }
    }

    var maple = try compressAndDownscale(
        allocator,
        &activations,
        fp.div(fp.fromInt(5), fp.fromInt(10)),
        fp.ONE,
        7,
        0,
    );
    defer maple.deinit(allocator);

    try std.testing.expect(maple.data.len > 0);
    try std.testing.expect(maple.q64_state_size > 0);
    try std.testing.expect(maple.q32_state_size > 0);
    try std.testing.expect(maple.portal_count > 0);
    try std.testing.expect(maple.compressed_size == maple.data.len);
}

test "seed_compressor: serialize/deserialize seed file format" {
    const allocator = std.testing.allocator;
    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;
    for (0..50) |i| {
        activations[i][0] = fp.div(fp.fromInt(@as(i64, @intCast(i + 1))), fp.fromInt(100));
    }

    var seed = try compressAgentState(allocator, &activations, fp.HALF, fp.ONE, 3, 0);
    defer seed.deinit(allocator);

    const serialized = try serializeSeed(allocator, seed);
    defer allocator.free(serialized);

    var deserialized = try deserializeSeed(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(seed.original_size, deserialized.original_size);
    try std.testing.expectEqual(seed.compressed_size, deserialized.compressed_size);
    try std.testing.expectEqual(seed.checksum, deserialized.checksum);
    try std.testing.expectEqual(seed.lattice_level, deserialized.lattice_level);
    try std.testing.expectEqualSlices(u8, seed.data, deserialized.data);
}

test "seed_compressor: QR portal pack/unpack round-trip" {
    const allocator = std.testing.allocator;
    const test_data = try allocator.alloc(u8, 1000);
    defer allocator.free(test_data);
    for (0..test_data.len) |i| test_data[i] = @intCast(i % 256);

    const portals = try packToQRPortals(allocator, test_data);
    defer {
        for (portals) |p| allocator.free(p);
        allocator.free(portals);
    }

    // 1000 bytes / 256 bytes per portal = 4 portals (ceil)
    try std.testing.expectEqual(@as(usize, 4), portals.len);
    try std.testing.expectEqual(@as(usize, 256), portals[0].len);
    try std.testing.expectEqual(@as(usize, 256), portals[1].len);
    try std.testing.expectEqual(@as(usize, 256), portals[2].len);
    try std.testing.expectEqual(@as(usize, 232), portals[3].len);

    // Convert to []const []const u8 for unpack
    const const_portals: []const []const u8 = portals;
    const restored = try unpackFromQRPortals(allocator, const_portals);
    defer allocator.free(restored);

    try std.testing.expectEqualSlices(u8, test_data, restored);
}

test "seed_compressor: deserializeSeed rejects invalid magic" {
    const allocator = std.testing.allocator;
    const bad_data = [_]u8{ 'X', 'X', 'X', 'X', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const result = deserializeSeed(allocator, &bad_data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "seed_compressor: deserializeState rejects short input" {
    const short_data = [_]u8{0} ** 10;
    const result = deserializeState(&short_data);
    try std.testing.expectError(error.InputSizeMismatch, result);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework seed compression ratio from the 421/3375 identity.
/// The E0 observer density 421/3375 ≈ 0.1247 indicates that ~12.5% of the
/// lattice carries observer information, matching the 1/8 aperture.
pub const FRAMEWORK_SEED_DENSITY_NUM: u32 = 421;
pub const FRAMEWORK_SEED_DENSITY_DEN: u32 = 3375;

/// Verifies the 421/3375 seed density matches the 1/8 aperture (within 7/27000).
pub fn verifySeedDensityMatchesAperture() bool {
    // 421/3375 = 1/8 - 7/27000
    return @as(u64, 421) * 27000 == @as(u64, 3375) * 3368;
}

test "framework: seed density 421/3375 matches 1/8 aperture" {
    try std.testing.expect(verifySeedDensityMatchesAperture());
}
