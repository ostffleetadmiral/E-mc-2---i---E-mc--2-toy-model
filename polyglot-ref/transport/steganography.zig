//! steganography.zig — Multi-image LSB steganography for air-gap transport.
//!
//! Splits payload files across collections of innocent cover images
//! using Least Significant Bit (LSB) encoding. Each pixel channel
//! stores 1 bit of payload data. A 1920x1080 RGB image can hide
//! ~6.2 MB of data across all channels.

const std = @import("std");

/// LSB steganography encoder/decoder.
pub const LsbStego = struct {
    pub fn init() LsbStego {
        return .{};
    }

    /// Calculate the capacity of an image in bytes (1 bit per channel).
    pub fn capacity(_: LsbStego, width: u32, height: u32, channels: u3) usize {
        const total_pixels = @as(usize, width) * @as(usize, height);
        const total_channels = total_pixels * @as(usize, channels);
        return total_channels / 8;
    }

    /// Embed data into image pixel data using LSB (1 bit per channel).
    pub fn embed(_: LsbStego, pixels: []u8, data: []const u8) !void {
        const max_bits = pixels.len;
        const data_bits = data.len * 8;
        if (data_bits > max_bits) return error.PayloadTooLarge;

        // Store payload length in first 4 bytes (32 bits) of pixel data
        var pixel_idx: usize = 0;
        const length_bytes = [_]u8{
            @intCast((data.len >> 0) & 0xFF),
            @intCast((data.len >> 8) & 0xFF),
            @intCast((data.len >> 16) & 0xFF),
            @intCast((data.len >> 24) & 0xFF),
        };

        // Embed length header
        for (length_bytes) |byte| {
            var bit: usize = 0;
            while (bit < 8) : (bit += 1) {
                if (pixel_idx >= pixels.len) return error.ImageTooSmall;
                const bit_val: u8 = (byte >> @intCast(bit)) & 1;
                pixels[pixel_idx] = (pixels[pixel_idx] & 0xFE) | bit_val;
                pixel_idx += 1;
            }
        }

        // Embed payload data
        for (data) |byte| {
            var bit: usize = 0;
            while (bit < 8) : (bit += 1) {
                if (pixel_idx >= pixels.len) return error.ImageTooSmall;
                const bit_val: u8 = (byte >> @intCast(bit)) & 1;
                pixels[pixel_idx] = (pixels[pixel_idx] & 0xFE) | bit_val;
                pixel_idx += 1;
            }
        }
    }

    /// Extract data from image pixel data using LSB.
    pub fn extract(_: LsbStego, pixels: []const u8) ![]u8 {
        var pixel_idx: usize = 0;

        // Extract length header (4 bytes = 32 bits)
        var length: u32 = 0;
        var i: u6 = 0;
        while (i < 32) : (i += 1) {
            if (pixel_idx >= pixels.len) return error.ImageTooSmall;
            const bit: u32 = @as(u32, pixels[pixel_idx] & 1) << @intCast(i);
            length |= bit;
            pixel_idx += 1;
        }

        if (length == 0) return &.{};
        const data_len = @as(usize, length);
        if (pixel_idx + data_len * 8 > pixels.len) return error.CorruptedData;

        // Extract payload data
        const buf = try std.heap.page_allocator.alloc(u8, data_len);
        for (0..data_len) |byte_idx| {
            var byte: u8 = 0;
            var bit: usize = 0;
            while (bit < 8) : (bit += 1) {
                if (pixel_idx >= pixels.len) return error.CorruptedData;
                byte |= @as(u8, pixels[pixel_idx] & 1) << @intCast(bit);
                pixel_idx += 1;
            }
            buf[byte_idx] = byte;
        }
        return buf;
    }

    /// Split a payload across multiple images.
    pub fn splitPayload(alloc: std.mem.Allocator, data: []const u8, chunk_size: usize) ![][]u8 {
        const num_chunks = (data.len + chunk_size - 1) / chunk_size;
        var chunks = try alloc.alloc([]u8, num_chunks);
        for (0..num_chunks) |i| {
            const start = i * chunk_size;
            const end = @min(start + chunk_size, data.len);
            chunks[i] = try alloc.dupe(u8, data[start..end]);
        }
        return chunks;
    }

    /// Reassemble a payload from multiple chunks.
    pub fn reassemblePayload(alloc: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
        var total: usize = 0;
        for (chunks) |chunk| total += chunk.len;
        var buf = try alloc.alloc(u8, total);
        var offset: usize = 0;
        for (chunks) |chunk| {
            @memcpy(buf[offset..][0..chunk.len], chunk);
            offset += chunk.len;
        }
        return buf;
    }
};

/// Image container for steganography.
pub const CoverImage = struct {
    width: u32,
    height: u32,
    channels: u3, // 3 = RGB, 4 = RGBA
    pixels: []u8,

    pub fn capacity(self: CoverImage, stego: LsbStego) usize {
        return stego.capacity(self.width, self.height, self.channels);
    }

    pub fn embed(self: *CoverImage, stego: LsbStego, data: []const u8) !void {
        try stego.embed(self.pixels, data);
    }

    pub fn extract(self: *const CoverImage, stego: LsbStego) ![]u8 {
        return stego.extract(self.pixels);
    }
};

/// Create a dummy cover image filled with noise.
pub fn createCoverImage(alloc: std.mem.Allocator, width: u32, height: u32, channels: u3) !CoverImage {
    const size = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try alloc.alloc(u8, size);
    std.crypto.random.bytes(pixels);
    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .pixels = pixels,
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "LsbStego capacity calculation" {
    const stego = LsbStego.init();
    // 10x10 RGB image = 300 channels, 1 bit each = 300 bits / 8 = 37 bytes
    const cap = stego.capacity(10, 10, 3);
    try std.testing.expectEqual(@as(usize, 37), cap);
}

test "LsbStego capacity with larger image" {
    const stego = LsbStego.init();
    // 100x100 RGB = 30000 channels / 8 = 3750 bytes
    const cap = stego.capacity(100, 100, 3);
    try std.testing.expectEqual(@as(usize, 3750), cap);
}

test "LsbStego embed and extract round-trip" {
    const alloc = std.testing.allocator;
    var image = try createCoverImage(alloc, 32, 32, 3);
    defer alloc.free(image.pixels);

    const stego = LsbStego.init();
    const data = "Hello, FANO-1!";
    try image.embed(stego, data);

    const extracted = try image.extract(stego);
    defer std.heap.page_allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, data, extracted);
}

test "LsbStego embed and extract binary data" {
    const alloc = std.testing.allocator;
    var image = try createCoverImage(alloc, 64, 64, 3);
    defer alloc.free(image.pixels);

    const stego = LsbStego.init();
    const data = [_]u8{ 0x00, 0xFF, 0x42, 0x55, 0xAA, 0x01, 0x80, 0x7F };
    try image.embed(stego, &data);

    const extracted = try image.extract(stego);
    defer std.heap.page_allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &data, extracted);
}

test "LsbStego rejects payload too large" {
    const alloc = std.testing.allocator;
    var image = try createCoverImage(alloc, 2, 2, 3);
    defer alloc.free(image.pixels);

    const stego = LsbStego.init();
    // 2x2x3 = 12 bytes = 96 bits, but 32 bits for header, so 64 bits = 8 bytes max
    const data = [_]u8{0} ** 100;
    try std.testing.expectError(error.PayloadTooLarge, image.embed(stego, &data));
}

test "LsbStego empty payload" {
    const alloc = std.testing.allocator;
    var image = try createCoverImage(alloc, 8, 8, 3);
    defer alloc.free(image.pixels);

    const stego = LsbStego.init();
    try image.embed(stego, &.{});

    const extracted = try image.extract(stego);
    defer std.heap.page_allocator.free(extracted);
    try std.testing.expectEqual(@as(usize, 0), extracted.len);
}

test "LsbStego preserves image dimensions" {
    const alloc = std.testing.allocator;
    var image = try createCoverImage(alloc, 16, 16, 3);
    defer alloc.free(image.pixels);

    const stego = LsbStego.init();
    const data = "test";
    try image.embed(stego, data);

    // Image dimensions should be unchanged
    try std.testing.expectEqual(@as(u32, 16), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
}

test "splitPayload and reassemblePayload round-trip" {
    const alloc = std.testing.allocator;
    const data = "The quick brown fox jumps over the lazy dog";
    const chunks = try LsbStego.splitPayload(alloc, data, 10);
    defer {
        for (chunks) |chunk| alloc.free(chunk);
        alloc.free(chunks);
    }

    // Should have 5 chunks (43 bytes / 10 = 5 chunks)
    try std.testing.expectEqual(@as(usize, 5), chunks.len);

    const reassembled = try LsbStego.reassemblePayload(alloc, chunks);
    defer alloc.free(reassembled);
    try std.testing.expectEqualSlices(u8, data, reassembled);
}

test "splitPayload with exact division" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    const chunks = try LsbStego.splitPayload(alloc, &data, 2);
    defer {
        for (chunks) |chunk| alloc.free(chunk);
        alloc.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
}

test "splitPayload single chunk" {
    const alloc = std.testing.allocator;
    const data = "small";
    const chunks = try LsbStego.splitPayload(alloc, data, 100);
    defer {
        for (chunks) |chunk| alloc.free(chunk);
        alloc.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualSlices(u8, data, chunks[0]);
}

test "CoverImage capacity" {
    const stego = LsbStego.init();
    const image = CoverImage{
        .width = 100,
        .height = 100,
        .channels = 3,
        .pixels = &.{},
    };
    const cap = image.capacity(stego);
    try std.testing.expectEqual(@as(usize, 3750), cap);
}

test "LsbStego with larger image round-trip" {
    const alloc = std.testing.allocator;
    var image = try createCoverImage(alloc, 64, 64, 3);
    defer alloc.free(image.pixels);

    const stego = LsbStego.init();
    const data = "Double capacity test!";
    try image.embed(stego, data);

    const extracted = try image.extract(stego);
    defer std.heap.page_allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, data, extracted);
}
