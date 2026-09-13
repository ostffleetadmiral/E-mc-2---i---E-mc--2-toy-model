//! rgb_packer.zig — Pack arbitrary byte streams into 24-bit RGB video frames.
//!
//! Each data byte is stored as a pixel where R=G=B=byte_value. For lossy
//! compression resilience, bytes can be replicated across block_scale×block_scale
//! pixel blocks. The first frame contains a header in its first 80 bytes,
//! followed by data. Subsequent frames contain only data.
//!
//! Frame layout (block_scale=4, 1920×1080):
//!   - 480×270 = 129,600 blocks per frame
//!   - Header occupies first ceil(80/3) = 27 pixels (first 81 bytes, 1 unused)
//!   - Data starts at pixel 27, block (6, 0) approximately
//!   - ~129,593 data bytes per frame (after header overhead)
//!
//! Density @ 1080p60 RGB: 6.22 MB/frame, 373.2 MB/sec raw
//! With 4×4 block scaling: ~23.3 MB/sec error-corrected throughput.

const std = @import("std");
const ec = @import("q128_error_correct.zig");

/// Configuration for the RGB packer.
pub const PackConfig = struct {
    frame_width: u32 = 1920,
    frame_height: u32 = 1080,
    block_scale: u32 = 4,
};

/// Compute how many data bytes fit in one frame (after header for frame 0).
pub fn dataBytesPerFrame(cfg: PackConfig, is_first_frame: bool) usize {
    const blocks_x = cfg.frame_width / cfg.block_scale;
    const blocks_y = cfg.frame_height / cfg.block_scale;
    const total_blocks = blocks_x * blocks_y;
    const header_blocks = if (is_first_frame) ec.HEADER_SIZE else 0;
    return total_blocks - header_blocks;
}

/// Compute total frames needed for a given payload size.
pub fn totalFrames(payload_size: usize, cfg: PackConfig) u32 {
    const first_frame_capacity = dataBytesPerFrame(cfg, true);
    if (payload_size <= first_frame_capacity) return 1;
    const remaining = payload_size - first_frame_capacity;
    const per_frame = dataBytesPerFrame(cfg, false);
    return 1 + @as(u32, @intCast((remaining + per_frame - 1) / per_frame));
}

/// Pack a byte array into RGB video frames.
///
/// Returns an array of frames, each frame_width × frame_height × 3 bytes.
/// The first frame contains the header in its first 80 bytes.
/// Each data byte is replicated across a block_scale×block_scale block
/// of pixels, with R=G=B=byte_value.
pub fn pack(
    alloc: std.mem.Allocator,
    data: []const u8,
    cfg: PackConfig,
) ![][]u8 {
    const frame_count = totalFrames(data.len, cfg);
    const checksum = ec.computeChecksum(data);

    // Allocate frame array
    var frames = try alloc.alloc([]u8, frame_count);
    errdefer alloc.free(frames);

    const frame_size = @as(usize, cfg.frame_width) * cfg.frame_height * 3;
    const bs = cfg.block_scale;
    const blocks_x = cfg.frame_width / bs;
    const blocks_y = cfg.frame_height / bs;

    // Initialize all frames to black, tracking how many are allocated
    var frames_initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < frames_initialized) : (i += 1) alloc.free(frames[i]);
    }
    for (frames) |*frame| {
        frame.* = try alloc.alloc(u8, frame_size);
        frames_initialized += 1;
        @memset(frame.*, 0);
    }

    // Write header into first frame
    var h: ec.Header = undefined;
    ec.buildHeader(
        &h,
        @intCast(data.len),
        cfg.frame_width,
        cfg.frame_height,
        cfg.block_scale,
        frame_count,
        checksum,
    );

    // Serialize header into first frame's pixel data
    var header_bytes: [ec.HEADER_SIZE]u8 = undefined;
    @memcpy(header_bytes[0..8], &h.magic);
    std.mem.writeInt(u64, header_bytes[8..16], h.payload_size, .little);
    std.mem.writeInt(u32, header_bytes[16..20], h.frame_width, .little);
    std.mem.writeInt(u32, header_bytes[20..24], h.frame_height, .little);
    std.mem.writeInt(u32, header_bytes[24..28], h.block_scale, .little);
    std.mem.writeInt(u64, header_bytes[28..36], h.checksum_hi_lo, .little);
    std.mem.writeInt(u64, header_bytes[36..44], h.checksum_hi_hi, .little);
    std.mem.writeInt(u64, header_bytes[44..52], h.checksum_lo_lo, .little);
    std.mem.writeInt(u64, header_bytes[52..60], h.checksum_lo_hi, .little);
    std.mem.writeInt(u32, header_bytes[60..64], h.frame_count, .little);
    std.mem.writeInt(u32, header_bytes[64..68], h.version, .little);
    std.mem.writeInt(u32, header_bytes[68..72], h.header_crc, .little);
    std.mem.writeInt(u32, header_bytes[72..76], h.reserved, .little);
    std.mem.writeInt(u32, header_bytes[76..80], @as(u32, 0), .little); // padding

    // Write header bytes into first frame using block-based encoding
    // (same as data: each byte replicated across a block_scale×block_scale block)
    var header_byte_idx: usize = 0;
    while (header_byte_idx < ec.HEADER_SIZE) : (header_byte_idx += 1) {
        const bi = header_byte_idx; // 1 block per header byte
        const bx: u32 = @intCast(bi % blocks_x);
        const by: u32 = @intCast(bi / blocks_x);
        const byte_val = header_bytes[header_byte_idx];
        var dy: u32 = 0;
        while (dy < bs) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < bs) : (dx += 1) {
                const px = bx * bs + dx;
                const py = by * bs + dy;
                const offset = (@as(usize, py) * cfg.frame_width + px) * 3;
                frames[0][offset] = byte_val;
                frames[0][offset + 1] = byte_val;
                frames[0][offset + 2] = byte_val;
            }
        }
    }

    // Pack data bytes into blocks
    var data_idx: usize = 0;
    var frame_idx: usize = 0;

    // For first frame, skip header blocks (1 block per header byte)
    const header_blocks = ec.HEADER_SIZE;
    const first_frame_skip = header_blocks;

    while (data_idx < data.len) {
        const frame = frames[frame_idx];
        const total_blocks = blocks_x * blocks_y;
        const start_block = if (frame_idx == 0) first_frame_skip else 0;

        var bi: usize = start_block;
        while (bi < total_blocks and data_idx < data.len) : (bi += 1) {
            const bx: u32 = @intCast(bi % blocks_x);
            const by: u32 = @intCast(bi / blocks_x);
            const byte_val = data[data_idx];

            // Fill block_scale×block_scale block with byte_val in all RGB channels
            var dy: u32 = 0;
            while (dy < bs) : (dy += 1) {
                var dx: u32 = 0;
                while (dx < bs) : (dx += 1) {
                    const px = bx * bs + dx;
                    const py = by * bs + dy;
                    const offset = (@as(usize, py) * cfg.frame_width + px) * 3;
                    frame[offset] = byte_val;
                    frame[offset + 1] = byte_val;
                    frame[offset + 2] = byte_val;
                }
            }

            data_idx += 1;
        }

        frame_idx += 1;
    }

    return frames;
}

/// Free frames allocated by pack().
pub fn freeFrames(alloc: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |frame| alloc.free(frame);
    alloc.free(frames);
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "dataBytesPerFrame first frame accounts for header" {
    const cfg = PackConfig{ .frame_width = 100, .frame_height = 100, .block_scale = 4 };
    const first = dataBytesPerFrame(cfg, true);
    const subsequent = dataBytesPerFrame(cfg, false);
    // 100×100 = 10000 pixels, 10000/4/4 = 625 blocks
    // Header takes 80 blocks (1 per header byte)
    try std.testing.expectEqual(@as(usize, 625 - 80), first);
    try std.testing.expectEqual(@as(usize, 625), subsequent);
}

test "totalFrames for small payload" {
    const cfg = PackConfig{ .frame_width = 100, .frame_height = 100, .block_scale = 4 };
    const frames = totalFrames(100, cfg);
    try std.testing.expectEqual(@as(u32, 1), frames);
}

test "totalFrames for large payload" {
    const cfg = PackConfig{ .frame_width = 100, .frame_height = 100, .block_scale = 4 };
    // 625 blocks per subsequent frame, 545 per first frame
    // 5000 bytes → 545 + 625 + ... need ceil((5000-545)/625)+1
    const frames = totalFrames(5000, cfg);
    const expected: u32 = 1 + @as(u32, @intCast((5000 - 545 + 625 - 1) / 625));
    try std.testing.expectEqual(expected, frames);
}

test "pack and verify header" {
    const alloc = std.testing.allocator;
    const data = "Hello, FANO-1 ISG RGB transcoder!";
    const cfg = PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const frames = try pack(alloc, data, cfg);
    defer freeFrames(alloc, frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqual(@as(usize, 64 * 64 * 3), frames[0].len);

    // Verify header magic — first block has 'F' (0x46) in all RGB channels
    try std.testing.expectEqual(@as(u8, 'F'), frames[0][0]);
    try std.testing.expectEqual(@as(u8, 'F'), frames[0][1]);
    try std.testing.expectEqual(@as(u8, 'F'), frames[0][2]);
    // Second block has 'A'
    try std.testing.expectEqual(@as(u8, 'A'), frames[0][12]);
    try std.testing.expectEqual(@as(u8, 'A'), frames[0][13]);
    try std.testing.expectEqual(@as(u8, 'A'), frames[0][14]);
}

test "pack produces correct block structure" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 0x42, 0xFF, 0x00 };
    // Use 32×32 frame with block_scale=4: 8×8=64 blocks total
    // Header takes 80 blocks, so we need at least 83 blocks → need bigger frame
    // 32×32/4/4 = 64 blocks — not enough for 80 header + 3 data = 83
    // Use 64×64 with block_scale=4: 16×16=256 blocks, plenty for 80+3
    const cfg = PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };

    const frames = try pack(alloc, &data, cfg);
    defer freeFrames(alloc, frames);

    // Header takes 80 blocks (1 per header byte). Data starts at block 80.
    // Block 80 is at pixel (80*4 % 64, 80*4 / 64) = (320 % 64, 320/64) = (0, 5)
    // Wait: blocks_x = 64/4 = 16. Block 80: bx = 80 % 16 = 0, by = 80 / 16 = 5
    // Pixel: (0*4, 5*4) = (0, 20). Offset = (20*64 + 0)*3 = 3840
    const data_block_offset = (20 * 64 + 0) * 3;
    try std.testing.expectEqual(@as(u8, 0x42), frames[0][data_block_offset]);
    try std.testing.expectEqual(@as(u8, 0x42), frames[0][data_block_offset + 1]);
    try std.testing.expectEqual(@as(u8, 0x42), frames[0][data_block_offset + 2]);

    // Check that the entire 4×4 block is filled with 0x42
    var dy: u32 = 0;
    while (dy < 4) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < 4) : (dx += 1) {
            const offset = (@as(usize, 20 + dy) * 64 + dx) * 3;
            try std.testing.expectEqual(@as(u8, 0x42), frames[0][offset]);
            try std.testing.expectEqual(@as(u8, 0x42), frames[0][offset + 1]);
            try std.testing.expectEqual(@as(u8, 0x42), frames[0][offset + 2]);
        }
    }
}

test "pack with block_scale=1 (no scaling)" {
    const alloc = std.testing.allocator;
    const data = "AB";
    const cfg = PackConfig{ .frame_width = 128, .frame_height = 1, .block_scale = 1 };

    const frames = try pack(alloc, data, cfg);
    defer freeFrames(alloc, frames);

    // With block_scale=1, header takes 80 blocks = 80 pixels (240 bytes)
    // Data starts at pixel 80, offset 240
    try std.testing.expectEqual(@as(u8, 'A'), frames[0][240]);
    try std.testing.expectEqual(@as(u8, 'A'), frames[0][241]);
    try std.testing.expectEqual(@as(u8, 'A'), frames[0][242]);
    try std.testing.expectEqual(@as(u8, 'B'), frames[0][243]);
}

test "pack large data across multiple frames" {
    const alloc = std.testing.allocator;
    var data: [2000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    const cfg = PackConfig{ .frame_width = 64, .frame_height = 64, .block_scale = 4 };
    const frames = try pack(alloc, &data, cfg);
    defer freeFrames(alloc, frames);

    try std.testing.expect(frames.len > 1);
}
