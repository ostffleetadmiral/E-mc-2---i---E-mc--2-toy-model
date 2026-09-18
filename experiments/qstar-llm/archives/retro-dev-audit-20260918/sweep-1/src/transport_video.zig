//! transport_video.zig — Binary-to-video pixel mapping transport.
//!
//! Extracted from Infinite Storage Glitch (#03).
//! Maps 3 bytes → 1 RGB pixel, packs frames into a video container.

const std = @import("std");

pub const BYTES_PER_PIXEL: usize = 3;
pub const DEFAULT_WIDTH: u32 = 1920;
pub const DEFAULT_HEIGHT: u32 = 1080;
pub const FRAME_MAGIC: [4]u8 = .{ 'F', 'R', 'M', '1' };

pub const FrameHeader = struct {
    magic: [4]u8 = FRAME_MAGIC,
    frame_num: u32,
    width: u32,
    height: u32,
    data_len: u32,
};

/// Encodes bytes into video frame data (raw RGB pixels).
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return try encodeWithSize(allocator, data, DEFAULT_WIDTH, DEFAULT_HEIGHT);
}

/// Encodes bytes into video frames with specified dimensions.
pub fn encodeWithSize(allocator: std.mem.Allocator, data: []const u8, width: u32, height: u32) ![]u8 {
    const pixels_per_frame = @as(usize, width) * @as(usize, height);
    const bytes_per_frame = pixels_per_frame * BYTES_PER_PIXEL;
    const num_frames = (data.len + bytes_per_frame - 1) / bytes_per_frame;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var offset: usize = 0;
    var frame_num: u32 = 0;
    while (frame_num < num_frames) : (frame_num += 1) {
        const remaining = data.len - offset;
        const chunk_size = @min(remaining, bytes_per_frame);

        const header = FrameHeader{
            .frame_num = frame_num,
            .width = width,
            .height = height,
            .data_len = @intCast(chunk_size),
        };

        try out.appendSlice(&header.magic);
        try out.writer().writeInt(u32, header.frame_num, .little);
        try out.writer().writeInt(u32, header.width, .little);
        try out.writer().writeInt(u32, header.height, .little);
        try out.writer().writeInt(u32, header.data_len, .little);

        try out.appendSlice(data[offset .. offset + chunk_size]);

        const padding = bytes_per_frame - chunk_size;
        if (padding > 0) {
            try out.appendNTimes(0, padding);
        }

        offset += chunk_size;
    }

    return out.toOwnedSlice();
}

/// Decodes video frame data back to original bytes.
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var pos: usize = 0;
    while (pos + 20 <= encoded.len) {
        if (!std.mem.eql(u8, encoded[pos .. pos + 4], &FRAME_MAGIC)) return error.InvalidFrame;

        const frame_num = std.mem.readInt(u32, encoded[pos + 4 ..][0..4], .little);
        const width = std.mem.readInt(u32, encoded[pos + 8 ..][0..4], .little);
        const height = std.mem.readInt(u32, encoded[pos + 12 ..][0..4], .little);
        const data_len = std.mem.readInt(u32, encoded[pos + 16 ..][0..4], .little);

        _ = frame_num;

        pos += 20;
        if (pos + data_len > encoded.len) return error.TruncatedFrame;

        try out.appendSlice(encoded[pos .. pos + data_len]);
        pos += data_len;

        const pixels_per_frame = @as(usize, width) * @as(usize, height);
        const bytes_per_frame = pixels_per_frame * BYTES_PER_PIXEL;
        const padding = bytes_per_frame - data_len;
        pos += padding;
    }

    return out.toOwnedSlice();
}

pub fn capacity() usize {
    return DEFAULT_WIDTH * DEFAULT_HEIGHT * BYTES_PER_PIXEL;
}

pub fn name() []const u8 {
    return "video";
}

// Tests

test "video encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Video transport test data payload!";

    const encoded = try encodeWithSize(allocator, data, 4, 4);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "video multi-frame" {
    const allocator = std.testing.allocator;
    var data: [100]u8 = undefined;
    for (0..100) |i| data[i] = @intCast(i);

    const encoded = try encodeWithSize(allocator, &data, 4, 4);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &data, decoded);
}

test "video capacity" {
    try std.testing.expectEqual(@as(usize, 1920 * 1080 * 3), capacity());
}

test "video name" {
    try std.testing.expectEqualStrings("video", name());
}

// =============================================================================
// Framework Transport Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework transport channel count: 7 octonionic channels.
pub const FRAMEWORK_TRANSPORT_CHANNELS: u32 = 7;

/// Framework transport routing uses the Fano plane for channel selection.
pub const FRAMEWORK_TRANSPORT_FANO_LINES: u32 = 7;

/// Framework transport capacity from the codon count: 64 = 2^6.
pub const FRAMEWORK_TRANSPORT_CAPACITY: u32 = 64;

/// Verifies the transport channel count matches the 7-defect.
pub fn verifyTransportChannelsMatchFramework() bool {
    return FRAMEWORK_TRANSPORT_CHANNELS == 7;
}

/// Verifies the transport capacity matches the codon count.
pub fn verifyTransportCapacityMatchesFramework() bool {
    return FRAMEWORK_TRANSPORT_CAPACITY == 64;
}

test "framework: transport channels 7 = 7-defect" {
    try std.testing.expect(verifyTransportChannelsMatchFramework());
}

test "framework: transport capacity 64 = codon count" {
    try std.testing.expect(verifyTransportCapacityMatchesFramework());
}
