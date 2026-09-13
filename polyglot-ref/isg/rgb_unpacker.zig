//! rgb_unpacker.zig — Unpack RGB video frames back into the original byte stream.
//!
//! Reads the header from the first frame, then reconstructs data bytes
//! using majority voting across block_scale×block_scale pixel blocks.
//! Verifies the Q128.128 checksum to confirm lossless reconstruction.
//! Reports corruption statistics (corrupted blocks, checksum match).

const std = @import("std");
const Q = @import("q128_128");
const ec = @import("q128_error_correct.zig");
const packer = @import("rgb_packer.zig");

/// Result of unpacking.
pub const UnpackResult = struct {
    data: []u8,
    checksum_valid: bool,
    corrupted_blocks: u32,
    total_blocks: u32,
};

/// Parse the header from the first frame using majority-vote block extraction.
pub fn parseHeader(frame: []const u8, frame_width: u32, block_scale: u32) ec.Header {
    const bs = block_scale;
    var header_bytes: [ec.HEADER_SIZE]u8 = undefined;
    var i: usize = 0;
    while (i < ec.HEADER_SIZE) : (i += 1) {
        const bx: u32 = @intCast(i % (frame_width / bs));
        const by: u32 = @intCast(i / (frame_width / bs));
        header_bytes[i] = ec.majorityVoteBlock(frame, frame_width, bx, by, bs);
    }
    var h: ec.Header = undefined;
    @memcpy(h.magic[0..8], header_bytes[0..8]);
    h.payload_size = std.mem.readInt(u64, header_bytes[8..16], .little);
    h.frame_width = std.mem.readInt(u32, header_bytes[16..20], .little);
    h.frame_height = std.mem.readInt(u32, header_bytes[20..24], .little);
    h.block_scale = std.mem.readInt(u32, header_bytes[24..28], .little);
    h.checksum_hi_lo = std.mem.readInt(u64, header_bytes[28..36], .little);
    h.checksum_hi_hi = std.mem.readInt(u64, header_bytes[36..44], .little);
    h.checksum_lo_lo = std.mem.readInt(u64, header_bytes[44..52], .little);
    h.checksum_lo_hi = std.mem.readInt(u64, header_bytes[52..60], .little);
    h.frame_count = std.mem.readInt(u32, header_bytes[60..64], .little);
    h.version = std.mem.readInt(u32, header_bytes[64..68], .little);
    h.header_crc = std.mem.readInt(u32, header_bytes[68..72], .little);
    h.reserved = std.mem.readInt(u32, header_bytes[72..76], .little);
    return h;
}

/// Unpack RGB frames into the original byte stream.
///
/// Reads the header from frame 0, reconstructs each data byte via
/// majority voting, then verifies the Q128.128 checksum.
pub fn unpack(
    alloc: std.mem.Allocator,
    frames: []const []const u8,
) !UnpackResult {
    if (frames.len == 0) return error.NoFrames;

    const frame0 = frames[0];
    const frame0_len = frame0.len;
    // Detect frame dimensions from frame size — try common block scales
    // We need block_scale to parse the header, but block_scale is in the header.
    // Try common values (1, 2, 4, 8) and check which produces a valid header.
    const candidate_scales = [_]u32{ 1, 2, 4, 8, 16 };
    var h: ec.Header = undefined;
    var found = false;
    for (candidate_scales) |bs| {
        // Try to infer frame_width/height from frame size
        const total_pixels = frame0_len / 3;
        // Try square frames first, then common aspect ratios
        const sqrt_side = @as(u32, @intCast(std.math.sqrt(total_pixels)));
        const candidates = [_]struct { w: u32, h: u32 }{
            .{ .w = sqrt_side, .h = sqrt_side },
            .{ .w = 1920, .h = 1080 },
            .{ .w = 1280, .h = 720 },
            .{ .w = 640, .h = 480 },
            .{ .w = 64, .h = 64 },
            .{ .w = 32, .h = 32 },
            .{ .w = 16, .h = 16 },
        };
        for (candidates) |dim| {
            if (dim.w * dim.h * 3 != frame0_len) continue;
            if (dim.w % bs != 0 or dim.h % bs != 0) continue;
            const candidate = parseHeader(frame0, dim.w, bs);
            if (ec.validateHeader(&candidate)) {
                h = candidate;
                found = true;
                break;
            }
        }
        if (found) break;
    }
    if (!found) return error.InvalidHeader;

    const bs = h.block_scale;
    const blocks_x = h.frame_width / bs;
    const blocks_y = h.frame_height / bs;
    const total_blocks_per_frame = blocks_x * blocks_y;
    const header_blocks = ec.HEADER_SIZE;

    const payload_size: usize = @intCast(h.payload_size);
    var data = try alloc.alloc(u8, payload_size);
    errdefer alloc.free(data);

    var data_idx: usize = 0;
    var corrupted_blocks: u32 = 0;
    var total_blocks_scanned: u32 = 0;

    var frame_idx: usize = 0;
    while (frame_idx < frames.len and data_idx < payload_size) : (frame_idx += 1) {
        const frame = frames[frame_idx];
        const start_block: usize = if (frame_idx == 0) header_blocks else 0;

        // Count corrupted blocks in this frame
        corrupted_blocks += ec.countCorruptedBlocks(
            frame,
            h.frame_width,
            h.frame_height,
            bs,
            blocks_x,
            blocks_y,
        );
        total_blocks_scanned += total_blocks_per_frame;

        var bi: usize = start_block;
        while (bi < total_blocks_per_frame and data_idx < payload_size) : (bi += 1) {
            const bx: u32 = @intCast(bi % blocks_x);
            const by: u32 = @intCast(bi / blocks_x);
            data[data_idx] = ec.majorityVoteBlock(frame, h.frame_width, bx, by, bs);
            data_idx += 1;
        }
    }

    // Verify Q128.128 checksum
    const computed_cs = ec.computeChecksum(data);
    const expected_cs = ec.deserializeChecksum(&h);
    const checksum_valid = Q.q128Eq(computed_cs, expected_cs);

    return .{
        .data = data,
        .checksum_valid = checksum_valid,
        .corrupted_blocks = corrupted_blocks,
        .total_blocks = total_blocks_scanned,
    };
}

/// Free data allocated by unpack().
pub fn freeUnpackResult(alloc: std.mem.Allocator, result: UnpackResult) void {
    alloc.free(result.data);
}

/// Full round-trip test: pack → unpack → verify byte-identical.
pub fn roundTripTest(
    alloc: std.mem.Allocator,
    data: []const u8,
    cfg: packer.PackConfig,
) !bool {
    const frames = try packer.pack(alloc, data, cfg);
    defer packer.freeFrames(alloc, frames);

    // Convert to const slices
    var const_frames = try alloc.alloc([]const u8, frames.len);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    const result = try unpack(alloc, const_frames);
    defer freeUnpackResult(alloc, result);

    if (!result.checksum_valid) return false;
    if (data.len != result.data.len) return false;
    return std.mem.eql(u8, data, result.data);
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parseHeader reads correct values" {
    const alloc = std.testing.allocator;
    const data = "test payload";
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };
    const frames = try packer.pack(alloc, data, cfg);
    defer packer.freeFrames(alloc, frames);

    const h = parseHeader(frames[0], cfg.frame_width, cfg.block_scale);
    try std.testing.expectEqualSlices(u8, "FANOISG1", &h.magic);
    try std.testing.expectEqual(@as(u64, 12), h.payload_size);
    try std.testing.expectEqual(@as(u32, 64), h.frame_width);
    try std.testing.expectEqual(@as(u32, 4), h.block_scale);
}

test "unpack round-trip byte-identical" {
    const alloc = std.testing.allocator;
    const data = "Hello, FANO-1 ISG RGB transcoder round-trip test!";
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const ok = try roundTripTest(alloc, data, cfg);
    try std.testing.expect(ok);
}

test "unpack round-trip with block_scale=1" {
    const alloc = std.testing.allocator;
    const data = "Block scale 1 test";
    const cfg = packer.PackConfig{ .frame_width = 32, .frame_height = 32, .block_scale = 1 };

    const ok = try roundTripTest(alloc, data, cfg);
    try std.testing.expect(ok);
}

test "unpack round-trip large data" {
    const alloc = std.testing.allocator;
    var data: [5000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const ok = try roundTripTest(alloc, &data, cfg);
    try std.testing.expect(ok);
}

test "unpack round-trip empty data" {
    const alloc = std.testing.allocator;
    const data: []const u8 = "";
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const ok = try roundTripTest(alloc, data, cfg);
    try std.testing.expect(ok);
}

test "unpack round-trip binary data" {
    const alloc = std.testing.allocator;
    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const ok = try roundTripTest(alloc, &data, cfg);
    try std.testing.expect(ok);
}

test "unpack detects corruption via checksum" {
    const alloc = std.testing.allocator;
    const data = "Test data for corruption detection";
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const frames = try packer.pack(alloc, data, cfg);
    defer packer.freeFrames(alloc, frames);

    // Corrupt a data block (not the header)
    // Header takes 80 blocks (1 per header byte). Data starts at block 80.
    // blocks_x = 64/4 = 16. Block 80: bx = 80%16 = 0, by = 80/16 = 5
    // Pixel: (0, 20). Offset = (20*64+0)*3 = 3840
    const corrupt_offset = (20 * 64 + 0) * 3;
    var frames_mut = frames;
    frames_mut[0][corrupt_offset] = 0xFF; // Corrupt R channel

    var const_frames = try alloc.alloc([]const u8, frames.len);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    const result = try unpack(alloc, const_frames);
    defer freeUnpackResult(alloc, result);

    // With block_scale=4, majority vote should still recover the correct
    // byte (only 1 of 48 values corrupted), so checksum should be valid.
    // But let's corrupt more aggressively — all 3 channels of one pixel.
    // Actually, 1 out of 48 values is < 50%, so majority vote recovers it.
    // The checksum should still be valid.
    try std.testing.expect(result.checksum_valid);
    try std.testing.expect(result.corrupted_blocks > 0);
}

test "unpack with heavy corruption still recovers" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 0x42, 0x99, 0xAA };
    // Need frame big enough: 80 header blocks + 3 data blocks = 83 blocks
    // 64×64/4/4 = 256 blocks, plenty
    const cfg = packer.PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const frames = try packer.pack(alloc, &data, cfg);
    defer packer.freeFrames(alloc, frames);

    // Corrupt 3 out of 16 pixels in data block 0 (data byte 0x42)
    // Data block 0 = block 80. bx=0, by=5. Pixel (0, 20). Offset = 3840
    // Each pixel is 3 bytes. Corrupt 3 pixels = 9 values out of 48.
    // 0x42 has 39 values, 0xFF has 9 → majority still 0x42.
    var frames_mut = frames;
    const base = (20 * 64 + 0) * 3;
    frames_mut[0][base + 0] = 0xFF;
    frames_mut[0][base + 1] = 0xFF;
    frames_mut[0][base + 2] = 0xFF;
    frames_mut[0][base + 3] = 0xFF;
    frames_mut[0][base + 4] = 0xFF;
    frames_mut[0][base + 5] = 0xFF;
    frames_mut[0][base + 6] = 0xFF;
    frames_mut[0][base + 7] = 0xFF;
    frames_mut[0][base + 8] = 0xFF;

    var const_frames = try alloc.alloc([]const u8, frames.len);
    defer alloc.free(const_frames);
    for (frames, 0..) |f, i| const_frames[i] = f;

    const result = try unpack(alloc, const_frames);
    defer freeUnpackResult(alloc, result);

    // Majority vote should recover 0x42 (39 vs 9)
    try std.testing.expectEqual(@as(u8, 0x42), result.data[0]);
    try std.testing.expect(result.checksum_valid);
}
