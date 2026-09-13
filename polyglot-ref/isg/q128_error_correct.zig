//! q128_error_correct.zig — Q128.128-based error detection and correction.
//!
//! Uses the deterministic Q128.128 fixed-point engine to compute rolling
//! checksums over byte arrays. The 256-bit precision (10^-39 floor) ensures
//! that even single-bit drift in any byte produces a detectably different
//! checksum, enabling reliable error detection for RGB video frame data
//! that has been through lossy compression (JPEG/MP4).
//!
//! Error correction uses block majority voting: when data bytes are
//! replicated across block_scale×block_scale pixel blocks, the correct
//! value is recovered by taking the majority vote across all pixels
//! in the block. The Q128.128 checksum confirms whether correction
//! was successful.

const std = @import("std");
const Q = @import("q128_128");

pub const MAGIC: [8]u8 = .{ 'F', 'A', 'N', 'O', 'I', 'S', 'G', '1' };
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 80;

/// Serialized header embedded in the first frame's pixel data.
pub const Header = extern struct {
    magic: [8]u8,
    payload_size: u64,
    frame_width: u32,
    frame_height: u32,
    block_scale: u32,
    checksum_hi_lo: u64, // Q128.128 hi.lo (bits 64..127 of hi)
    checksum_hi_hi: u64, // Q128.128 hi.hi (bits 128..255 of hi)
    checksum_lo_lo: u64, // Q128.128 lo.lo (bits 0..63 of lo)
    checksum_lo_hi: u64, // Q128.128 lo.hi (bits 64..127 of lo)
    frame_count: u32,
    version: u32,
    header_crc: u32,
    reserved: u32,
};

comptime {
    if (@sizeOf(Header) != HEADER_SIZE) {
        @compileError("Header size mismatch");
    }
}

/// 256-bit polynomial hash prime (FNV-1a inspired, 256-bit).
const HASH_PRIME: Q.U256 = .{
    .hi = 0x00000000000000000001000000000000,
    .lo = 0x000001b3000000000000000000000001,
};

/// Compute a 256-bit rolling polynomial checksum over a byte array.
///
/// Uses exact 256-bit unsigned integer multiplication (no fixed-point
/// rounding) with a 256-bit prime, ensuring single-bit sensitivity:
///   state = state * HASH_PRIME + byte  (for each byte)
///
/// The 256-bit state space makes collisions astronomically unlikely.
/// This is deterministic across all platforms (integer arithmetic only).
pub fn computeChecksum(data: []const u8) Q.q128 {
    var state: Q.U256 = .{ .hi = 0, .lo = 0 };
    for (data) |byte| {
        const m = Q.mul256_256(state, HASH_PRIME);
        // Take lower 256 bits of the 512-bit product, add byte with carry
        const product_lo: Q.U256 = m.lo;
        const new_lo = product_lo.lo +% @as(u128, byte);
        const carry: u128 = if (new_lo < product_lo.lo) 1 else 0;
        const new_hi = product_lo.hi +% carry;
        state = .{ .hi = new_hi, .lo = new_lo };
    }
    return state;
}

/// Serialize a Q128.128 checksum into the header fields.
pub fn serializeChecksum(h: *Header, cs: Q.q128) void {
    h.checksum_hi_lo = @truncate(cs.hi);
    h.checksum_hi_hi = @truncate(cs.hi >> 64);
    h.checksum_lo_lo = @truncate(cs.lo);
    h.checksum_lo_hi = @truncate(cs.lo >> 64);
}

/// Deserialize a Q128.128 checksum from the header fields.
pub fn deserializeChecksum(h: *const Header) Q.q128 {
    return .{
        .hi = (@as(u128, h.checksum_hi_hi) << 64) | h.checksum_hi_lo,
        .lo = (@as(u128, h.checksum_lo_hi) << 64) | h.checksum_lo_lo,
    };
}

/// CRC32 implementation for header integrity.
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return ~crc;
}

/// Compute the header CRC over all fields except header_crc, reserved, and padding.
pub fn computeHeaderCRC(h: *const Header) u32 {
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..8], &h.magic);
    std.mem.writeInt(u64, buf[8..16], h.payload_size, .little);
    std.mem.writeInt(u32, buf[16..20], h.frame_width, .little);
    std.mem.writeInt(u32, buf[20..24], h.frame_height, .little);
    std.mem.writeInt(u32, buf[24..28], h.block_scale, .little);
    std.mem.writeInt(u64, buf[28..36], h.checksum_hi_lo, .little);
    std.mem.writeInt(u64, buf[36..44], h.checksum_hi_hi, .little);
    std.mem.writeInt(u64, buf[44..52], h.checksum_lo_lo, .little);
    std.mem.writeInt(u64, buf[52..60], h.checksum_lo_hi, .little);
    std.mem.writeInt(u32, buf[60..64], h.frame_count, .little);
    std.mem.writeInt(u32, buf[64..68], h.version, .little);
    return crc32(&buf);
}

/// Verify header CRC.
pub fn verifyHeaderCRC(h: *const Header) bool {
    return h.header_crc == computeHeaderCRC(h);
}

/// Build a header from parameters.
pub fn buildHeader(
    h: *Header,
    payload_size: u64,
    frame_width: u32,
    frame_height: u32,
    block_scale: u32,
    frame_count: u32,
    checksum: Q.q128,
) void {
    h.magic = MAGIC;
    h.payload_size = payload_size;
    h.frame_width = frame_width;
    h.frame_height = frame_height;
    h.block_scale = block_scale;
    serializeChecksum(h, checksum);
    h.frame_count = frame_count;
    h.version = VERSION;
    h.reserved = 0;
    h.header_crc = computeHeaderCRC(h);
}

/// Verify a header's magic, version, and CRC.
pub fn validateHeader(h: *const Header) bool {
    if (!std.mem.eql(u8, &h.magic, &MAGIC)) return false;
    if (h.version != VERSION) return false;
    if (!verifyHeaderCRC(h)) return false;
    return true;
}

/// Majority vote across a block of pixels to recover the original byte.
///
/// Each block contains block_scale×block_scale pixels, each with 3 channels
/// (R, G, B) all set to the same data byte. During lossy compression, some
/// channels may drift. We vote across all block_scale×block_scale×3 values
/// to find the most common byte value.
pub fn majorityVoteBlock(
    frame: []const u8,
    frame_width: u32,
    block_x: u32,
    block_y: u32,
    block_scale: u32,
) u8 {
    const bs = block_scale;
    var counts: [256]u32 = .{0} ** 256;

    var dy: u32 = 0;
    while (dy < bs) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < bs) : (dx += 1) {
            const px = block_x * bs + dx;
            const py = block_y * bs + dy;
            const offset = (@as(usize, py) * frame_width + px) * 3;
            // R, G, B channels should all be the same
            counts[frame[offset]] += 1;
            counts[frame[offset + 1]] += 1;
            counts[frame[offset + 2]] += 1;
        }
    }

    var best_val: u8 = 0;
    var best_count: u32 = 0;
    for (counts, 0..) |c, i| {
        if (c > best_count) {
            best_count = c;
            best_val = @intCast(i);
        }
    }
    return best_val;
}

/// Detect which blocks have internal inconsistency (corruption).
/// Returns the count of corrupted blocks.
pub fn countCorruptedBlocks(
    frame: []const u8,
    frame_width: u32,
    frame_height: u32,
    block_scale: u32,
    blocks_x: u32,
    blocks_y: u32,
) u32 {
    _ = frame_height;
    var corrupted: u32 = 0;
    const bs = block_scale;
    var by: u32 = 0;
    while (by < blocks_y) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_x) : (bx += 1) {
            // Check if all pixels in the block have the same RGB value
            const base_px = bx * bs;
            const base_py = by * bs;
            const base_offset = (@as(usize, base_py) * frame_width + base_px) * 3;
            const ref_r = frame[base_offset];
            const ref_g = frame[base_offset + 1];
            const ref_b = frame[base_offset + 2];

            var consistent = true;
            if (ref_r != ref_g or ref_g != ref_b) consistent = false;

            if (consistent) {
                var dy: u32 = 0;
                while (dy < bs and consistent) : (dy += 1) {
                    var dx: u32 = 0;
                    while (dx < bs and consistent) : (dx += 1) {
                        const offset = (@as(usize, base_py + dy) * frame_width + (base_px + dx)) * 3;
                        if (frame[offset] != ref_r or
                            frame[offset + 1] != ref_r or
                            frame[offset + 2] != ref_r)
                        {
                            consistent = false;
                        }
                    }
                }
            }

            if (!consistent) corrupted += 1;
        }
    }
    return corrupted;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "checksum is deterministic" {
    const data = "Hello, FANO-1 ISG!";
    const cs1 = computeChecksum(data);
    const cs2 = computeChecksum(data);
    try std.testing.expect(Q.q128Eq(cs1, cs2));
}

test "checksum differs on single bit change" {
    const data1 = "Hello, FANO-1 ISG!";
    const data2 = "Hello, FANO-1 ISH!"; // last char changed
    const cs1 = computeChecksum(data1);
    const cs2 = computeChecksum(data2);
    try std.testing.expect(!Q.q128Eq(cs1, cs2));
}

test "checksum differs on empty vs non-empty" {
    const cs_empty = computeChecksum("");
    const cs_nonempty = computeChecksum("x");
    try std.testing.expect(!Q.q128Eq(cs_empty, cs_nonempty));
}

test "header build and validate" {
    var h: Header = undefined;
    const cs = computeChecksum("test data");
    buildHeader(&h, 9, 1920, 1080, 4, 1, cs);
    try std.testing.expect(validateHeader(&h));
    try std.testing.expectEqual(@as(u64, 9), h.payload_size);
    try std.testing.expectEqual(@as(u32, 1920), h.frame_width);
    try std.testing.expectEqual(@as(u32, 4), h.block_scale);
}

test "header rejects corrupted magic" {
    var h: Header = undefined;
    const cs = computeChecksum("test");
    buildHeader(&h, 4, 100, 100, 1, 1, cs);
    h.magic[0] = 'X';
    try std.testing.expect(!validateHeader(&h));
}

test "header rejects corrupted CRC" {
    var h: Header = undefined;
    const cs = computeChecksum("test");
    buildHeader(&h, 4, 100, 100, 1, 1, cs);
    h.payload_size = 999; // corrupt without re-computing CRC
    try std.testing.expect(!validateHeader(&h));
}

test "checksum round-trip serialize/deserialize" {
    const data = "FANO-1 holographic compression test payload";
    const cs = computeChecksum(data);
    var h: Header = undefined;
    buildHeader(&h, data.len, 100, 100, 1, 1, cs);
    const recovered = deserializeChecksum(&h);
    try std.testing.expect(Q.q128Eq(cs, recovered));
}

test "majority vote recovers correct byte" {
    // Create a 4×4 block where one pixel is corrupted
    const frame_width: u32 = 4;
    var frame: [4 * 4 * 3]u8 = undefined;
    // Fill with value 0x42
    for (&frame) |*b| b.* = 0x42;
    // Corrupt one pixel's R channel
    frame[0] = 0x43;
    try std.testing.expectEqual(@as(u8, 0x42), majorityVoteBlock(&frame, frame_width, 0, 0, 4));
}

test "majority vote with heavy corruption" {
    // 4×4 block = 16 pixels × 3 channels = 48 values
    // 23 values 0x42, 25 values 0xFF — 0xFF wins (corruption > 50%)
    // But 24 vs 24 is a tie. Let's do 25 vs 23.
    const frame_width: u32 = 4;
    var frame: [4 * 4 * 3]u8 = undefined;
    for (&frame) |*b| b.* = 0x42;
    // Corrupt 8 pixels fully (24 values) — still minority
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        frame[i] = 0xFF;
    }
    // 24 values are 0xFF, 24 values are 0x42 — tie, first found wins (0xFF)
    // Actually 0x42 has 24 and 0xFF has 24. Let's make it 23 vs 25.
    // Reset one to 0x42
    frame[23] = 0x42;
    // Now 0xFF has 23, 0x42 has 25
    try std.testing.expectEqual(@as(u8, 0x42), majorityVoteBlock(&frame, frame_width, 0, 0, 4));
}

test "countCorruptedBlocks detects inconsistency" {
    const frame_width: u32 = 8;
    const block_scale: u32 = 4;
    // 2×2 blocks of 4×4 pixels each
    var frame: [8 * 8 * 3]u8 = undefined;
    for (&frame) |*b| b.* = 0x00;
    // Corrupt one pixel in block (0,0)
    frame[3] = 0xFF;
    const corrupted = countCorruptedBlocks(&frame, frame_width, 8, block_scale, 2, 2);
    try std.testing.expectEqual(@as(u32, 1), corrupted);
}

test "countCorruptedBlocks reports 0 for clean blocks" {
    const frame_width: u32 = 8;
    const block_scale: u32 = 4;
    var frame: [8 * 8 * 3]u8 = undefined;
    for (&frame) |*b| b.* = 0x00;
    const corrupted = countCorruptedBlocks(&frame, frame_width, 8, block_scale, 2, 2);
    try std.testing.expectEqual(@as(u32, 0), corrupted);
}

test "large payload checksum stability" {
    // 1MB payload
    var data: [1024 * 1024]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const cs1 = computeChecksum(&data);
    const cs2 = computeChecksum(&data);
    try std.testing.expect(Q.q128Eq(cs1, cs2));
    // Flip one bit
    data[500000] ^= 1;
    const cs3 = computeChecksum(&data);
    try std.testing.expect(!Q.q128Eq(cs1, cs3));
}
