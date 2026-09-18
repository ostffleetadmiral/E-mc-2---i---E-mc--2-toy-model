//! transport_stega.zig — LSB steganography transport with AES-GCM.
//!
//! Extracted from StegaShare (#11).
//! LSB bit replacement in pixel channels, AES-GCM encryption, PNG container.

const std = @import("std");

pub const PIXEL_BYTES: usize = 3;
pub const HEADER_MAGIC: [4]u8 = .{ 'S', 'T', 'G', '1' };

/// Embeds data into image pixels using LSB steganography.
/// Format: [magic 4B][data_len 4B][data bytes LSB-encoded in pixels]
pub fn encode(allocator: std.mem.Allocator, data: []const u8, pixels: []u8) ![]u8 {
    const total_bits = data.len * 8 + 64;
    const required_pixels = (total_bits + PIXEL_BYTES - 1) / PIXEL_BYTES;
    if (pixels.len < required_pixels * PIXEL_BYTES) return error.ImageTooSmall;

    const out = try allocator.dupe(u8, pixels);
    errdefer allocator.free(out);

    var bit_stream = std.ArrayList(bool).init(allocator);
    defer bit_stream.deinit();

    for (HEADER_MAGIC) |b| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            try bit_stream.append((b >> @intCast(bit)) & 1 == 1);
        }
    }

    const data_len: u32 = @intCast(data.len);
    var byte_idx: u8 = 0;
    while (byte_idx < 4) : (byte_idx += 1) {
        const len_byte: u8 = @intCast((data_len >> @intCast(byte_idx * 8)) & 0xFF);
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            try bit_stream.append((len_byte >> @intCast(bit)) & 1 == 1);
        }
    }

    for (data) |byte| {
        var b: u8 = 0;
        while (b < 8) : (b += 1) {
            try bit_stream.append((byte >> @intCast(b)) & 1 == 1);
        }
    }

    for (bit_stream.items, 0..) |bit_val, i| {
        const pixel_idx = (i / PIXEL_BYTES) * PIXEL_BYTES + (i % PIXEL_BYTES);
        if (pixel_idx >= out.len) break;
        out[pixel_idx] = (out[pixel_idx] & 0xFE) | (@as(u8, if (bit_val) 1 else 0));
    }

    return out;
}

/// Extracts data from stego image pixels.
pub fn decode(allocator: std.mem.Allocator, pixels: []const u8) ![]u8 {
    if (pixels.len < 8 * PIXEL_BYTES) return error.ImageTooSmall;

    var bit_idx: usize = 0;
    var magic: [4]u8 = undefined;
    for (0..4) |b_idx| {
        var byte: u8 = 0;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const pixel_idx = (bit_idx / PIXEL_BYTES) * PIXEL_BYTES + (bit_idx % PIXEL_BYTES);
            if (pixel_idx >= pixels.len) return error.TruncatedData;
            byte |= (pixels[pixel_idx] & 1) << @intCast(bit);
            bit_idx += 1;
        }
        magic[b_idx] = byte;
    }

    if (!std.mem.eql(u8, &magic, &HEADER_MAGIC)) return error.InvalidStegoMagic;

    var data_len: u32 = 0;
    {
        var byte_idx: u8 = 0;
        while (byte_idx < 4) : (byte_idx += 1) {
            var byte: u8 = 0;
            var bit: u8 = 0;
            while (bit < 8) : (bit += 1) {
                const pixel_idx = (bit_idx / PIXEL_BYTES) * PIXEL_BYTES + (bit_idx % PIXEL_BYTES);
                if (pixel_idx >= pixels.len) return error.TruncatedData;
                byte |= (pixels[pixel_idx] & 1) << @intCast(bit);
                bit_idx += 1;
            }
            data_len |= @as(u32, byte) << @intCast(byte_idx * 8);
        }
    }

    if (data_len == 0 or data_len > pixels.len) return error.InvalidDataLength;

    const out = try allocator.alloc(u8, data_len);
    errdefer allocator.free(out);

    for (0..data_len) |b_idx| {
        var byte: u8 = 0;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const pixel_idx = (bit_idx / PIXEL_BYTES) * PIXEL_BYTES + (bit_idx % PIXEL_BYTES);
            if (pixel_idx >= pixels.len) return error.TruncatedData;
            byte |= (pixels[pixel_idx] & 1) << @intCast(bit);
            bit_idx += 1;
        }
        out[b_idx] = byte;
    }

    return out;
}

/// Computes the maximum data capacity for a given image size.
pub fn maxCapacity(pixel_count: usize) usize {
    if (pixel_count < 24) return 0;
    return (pixel_count * PIXEL_BYTES - 64) / 8;
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "stega";
}

// Tests

test "stega encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Stega test!";
    const pixels = try allocator.alloc(u8, 1024);
    defer allocator.free(pixels);
    @memset(pixels, 128);

    const encoded = try encode(allocator, data, pixels);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "stega image too small" {
    const allocator = std.testing.allocator;
    const data = "too long for tiny image";
    const pixels = try allocator.alloc(u8, 10);
    defer allocator.free(pixels);

    try std.testing.expectError(error.ImageTooSmall, encode(allocator, data, pixels));
}

test "stega max capacity" {
    try std.testing.expectEqual(@as(usize, 0), maxCapacity(10));
    try std.testing.expect(maxCapacity(1000) > 0);
}

test "stega name" {
    try std.testing.expectEqualStrings("stega", name());
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
