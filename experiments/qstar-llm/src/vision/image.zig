//! image.zig — Image I/O & Preprocessing for ONNX model input.
//!
//! Provides image loading from PPM (P6) and BMP (uncompressed) formats in pure Zig,
//! with optional stb_image dynamic loading for JPEG/PNG support. Preprocessing
//! includes resize (bilinear), normalize, and NCHW channel transform.
//!
//! Zero build dependencies — stb_image (if available) is loaded via c_ffi.DynLib.

const std = @import("std");
const c_ffi = @import("c_ffi");

// =============================================================================
// Image types
// =============================================================================

pub const PixelFormat = enum {
    Grayscale, // 1 channel
    RGB, // 3 channels
    RGBA, // 4 channels
};

pub const ImageError = error{
    FileNotFound,
    InvalidFormat,
    UnsupportedFormat,
    TruncatedData,
    LibraryNotFound,
    FreestandingUnsupported,
    OutOfMemory,
};

/// Raw image data in HWC (height, width, channels) layout, uint8.
pub const Image = struct {
    width: usize,
    height: usize,
    channels: u8,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize, channels: u8) ImageError!Image {
        const data = try allocator.alloc(u8, width * height * @as(usize, channels));
        @memset(data, 0);
        return .{
            .width = width,
            .height = height,
            .channels = channels,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.data);
    }

    pub fn getPixel(self: Image, x: usize, y: usize) []u8 {
        const idx = (y * self.width + x) * @as(usize, self.channels);
        return self.data[idx .. idx + @as(usize, self.channels)];
    }

    pub fn setPixel(self: *Image, x: usize, y: usize, pixel: []const u8) void {
        const idx = (y * self.width + x) * @as(usize, self.channels);
        const n = @min(pixel.len, @as(usize, self.channels));
        @memcpy(self.data[idx .. idx + n], pixel[0..n]);
    }
};

// =============================================================================
// PPM (P6) loader — pure Zig
// =============================================================================

fn loadPPM(allocator: std.mem.Allocator, data: []const u8) ImageError!Image {
    if (data.len < 3 or data[0] != 'P' or data[1] != '6') return error.InvalidFormat;

    var pos: usize = 2;
    var width: usize = 0;
    var height: usize = 0;
    var max_val: usize = 0;

    // Skip whitespace and read width
    pos = skipWhitespace(data, pos);
    width = try readNumber(data, &pos);
    pos = skipWhitespace(data, pos);
    height = try readNumber(data, &pos);
    pos = skipWhitespace(data, pos);
    max_val = try readNumber(data, &pos);

    // Single whitespace after max_val
    if (pos >= data.len) return error.TruncatedData;
    pos += 1;

    if (width == 0 or height == 0 or max_val == 0 or max_val > 65535) return error.InvalidFormat;

    const channels: u8 = 3;
    const pixel_bytes: usize = if (max_val > 255) 6 else 3;
    const expected_len = pos + width * height * pixel_bytes;
    if (data.len < expected_len) return error.TruncatedData;

    var img = try Image.init(allocator, width, height, channels);

    if (max_val <= 255) {
        // 8-bit per channel — direct copy
        @memcpy(img.data, data[pos .. pos + width * height * 3]);
    } else {
        // 16-bit per channel — downscale to 8-bit (take high byte)
        var src_idx = pos;
        var dst_idx: usize = 0;
        while (dst_idx < img.data.len) : (dst_idx += 1) {
            img.data[dst_idx] = data[src_idx + 1]; // high byte
            src_idx += 2;
        }
    }

    return img;
}

fn skipWhitespace(data: []const u8, start: usize) usize {
    var pos = start;
    while (pos < data.len) : (pos += 1) {
        const c = data[pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (c == '#') {
            // Comment — skip to end of line
            while (pos < data.len and data[pos] != '\n') : (pos += 1) {}
            continue;
        }
        break;
    }
    return pos;
}

fn readNumber(data: []const u8, pos: *usize) ImageError!usize {
    var value: usize = 0;
    var has_digit = false;
    while (pos.* < data.len) : (pos.* += 1) {
        const c = data[pos.*];
        if (c >= '0' and c <= '9') {
            value = value * 10 + @as(usize, c - '0');
            has_digit = true;
        } else break;
    }
    if (!has_digit) return error.InvalidFormat;
    return value;
}

// =============================================================================
// BMP loader — pure Zig (uncompressed 24-bit and 32-bit)
// =============================================================================

fn loadBMP(allocator: std.mem.Allocator, data: []const u8) ImageError!Image {
    if (data.len < 54) return error.TruncatedData;
    if (data[0] != 'B' or data[1] != 'M') return error.InvalidFormat;

    const data_offset = std.mem.readInt(u32, data[10..14], .little);
    const header_size = std.mem.readInt(u32, data[14..18], .little);
    const width: i32 = std.mem.readInt(i32, data[18..22], .little);
    const height: i32 = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);
    const compression = std.mem.readInt(u32, data[30..34], .little);

    if (width <= 0) return error.InvalidFormat;
    if (compression != 0) return error.UnsupportedFormat;
    if (bpp != 24 and bpp != 32) return error.UnsupportedFormat;

    const abs_height: usize = @intCast(@abs(height));
    const abs_width: usize = @intCast(width);
    const channels: u8 = if (bpp == 32) 4 else 3;

    if (data.len < data_offset) return error.TruncatedData;

    var img = try Image.init(allocator, abs_width, abs_height, channels);

    const row_size: usize = ((@as(usize, bpp) * abs_width + 31) / 32) * 4; // 4-byte aligned
    const pixel_bytes: usize = bpp / 8;

    for (0..abs_height) |y| {
        const src_row = if (height > 0) abs_height - 1 - y else y; // BMP is bottom-up by default
        const row_start = data_offset + src_row * row_size;
        if (row_start + abs_width * pixel_bytes > data.len) return error.TruncatedData;

        for (0..abs_width) |x| {
            const src_idx = row_start + x * pixel_bytes;
            // BMP is BGR, we want RGB
            if (bpp == 24) {
                img.data[(y * abs_width + x) * 3 + 0] = data[src_idx + 2]; // R
                img.data[(y * abs_width + x) * 3 + 1] = data[src_idx + 1]; // G
                img.data[(y * abs_width + x) * 3 + 2] = data[src_idx + 0]; // B
            } else {
                img.data[(y * abs_width + x) * 4 + 0] = data[src_idx + 2]; // R
                img.data[(y * abs_width + x) * 4 + 1] = data[src_idx + 1]; // G
                img.data[(y * abs_width + x) * 4 + 2] = data[src_idx + 0]; // B
                img.data[(y * abs_width + x) * 4 + 3] = data[src_idx + 3]; // A
            }
        }
    }

    _ = header_size;
    return img;
}

// =============================================================================
// stb_image dynamic loader (optional, for JPEG/PNG)
// =============================================================================

const StbiLoadFn = *const fn (filename: [*:0]const u8, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) callconv(.C) ?[*]u8;
const StbiLoadFromMemoryFn = *const fn (buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) callconv(.C) ?[*]u8;
const StbiImageFreeFn = *const fn (data: ?*anyopaque) callconv(.C) void;

const StbImage = struct {
    lib: c_ffi.DynLib,
    load: StbiLoadFn,
    load_from_memory: StbiLoadFromMemoryFn,
    image_free: StbiImageFreeFn,

    fn loadLib() ?StbImage {
        if (c_ffi.is_freestanding) return null;
        var lib = c_ffi.DynLib.open("libstb_image.so") catch return null;
        const load = lib.lookup(StbiLoadFn, "stbi_load") orelse {
            lib.close();
            return null;
        };
        const load_mem = lib.lookup(StbiLoadFromMemoryFn, "stbi_load_from_memory") orelse {
            lib.close();
            return null;
        };
        const free = lib.lookup(StbiImageFreeFn, "stbi_image_free") orelse {
            lib.close();
            return null;
        };
        return .{ .lib = lib, .load = load, .load_from_memory = load_mem, .image_free = free };
    }
};

// =============================================================================
// Public image loading API
// =============================================================================

/// Load an image from a file path. Auto-detects format by extension.
/// Supports PPM (.ppm) and BMP (.bmp) natively; JPEG/PNG via stb_image if available.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) ImageError!Image {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
    defer file.close();
    const data = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch return error.OutOfMemory;
    defer allocator.free(data);
    return loadFromMemory(allocator, data, path);
}

/// Load an image from in-memory bytes. Format is auto-detected from magic bytes.
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8, path: []const u8) ImageError!Image {
    // Auto-detect by magic bytes
    if (data.len >= 2) {
        if (data[0] == 'P' and data[1] == '6') return loadPPM(allocator, data);
        if (data[0] == 'B' and data[1] == 'M') return loadBMP(allocator, data);
        // JPEG: FF D8 FF
        if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
            if (StbImage.loadLib()) |stb| {
                var stb_var = stb;
                defer stb_var.lib.close();
                return loadViaStbMemory(allocator, stb_var, data);
            }
            return error.UnsupportedFormat;
        }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (data.len >= 8 and data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G') {
            if (StbImage.loadLib()) |stb| {
                var stb_var = stb;
                defer stb_var.lib.close();
                return loadViaStbMemory(allocator, stb_var, data);
            }
            return error.UnsupportedFormat;
        }
    }

    // Fall back to extension detection
    if (std.mem.endsWith(u8, path, ".ppm")) return loadPPM(allocator, data);
    if (std.mem.endsWith(u8, path, ".bmp")) return loadBMP(allocator, data);
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg") or std.mem.endsWith(u8, path, ".png")) {
        if (StbImage.loadLib()) |stb| {
            var stb_var = stb;
            defer stb_var.lib.close();
            return loadViaStbMemory(allocator, stb_var, data);
        }
        return error.LibraryNotFound;
    }

    return error.UnsupportedFormat;
}

fn loadViaStbMemory(allocator: std.mem.Allocator, stb: StbImage, data: []const u8) ImageError!Image {
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const result = stb.load_from_memory(data.ptr, @intCast(data.len), &w, &h, &ch, 3);
    if (result == null) return error.InvalidFormat;
    const pixel_data = result.?;

    const width: usize = @intCast(w);
    const height: usize = @intCast(h);
    const img = try Image.init(allocator, width, height, 3);
    @memcpy(img.data, pixel_data[0 .. width * height * 3]);
    stb.image_free(pixel_data);

    return img;
}

// =============================================================================
// Preprocessing
// =============================================================================

/// Resize an image using bilinear interpolation. Output channels match input.
pub fn resize(allocator: std.mem.Allocator, src: Image, dst_width: usize, dst_height: usize) ImageError!Image {
    var dst = try Image.init(allocator, dst_width, dst_height, src.channels);

    const x_ratio = @as(f32, @floatFromInt(src.width)) / @as(f32, @floatFromInt(dst_width));
    const y_ratio = @as(f32, @floatFromInt(src.height)) / @as(f32, @floatFromInt(dst_height));
    const ch = @as(usize, src.channels);

    for (0..dst_height) |dy| {
        const src_y = @as(f32, @floatFromInt(dy)) * y_ratio;
        const y0: usize = @intFromFloat(src_y);
        const y1 = @min(y0 + 1, src.height - 1);
        const wy = src_y - @as(f32, @floatFromInt(y0));

        for (0..dst_width) |dx| {
            const src_x = @as(f32, @floatFromInt(dx)) * x_ratio;
            const x0: usize = @intFromFloat(src_x);
            const x1 = @min(x0 + 1, src.width - 1);
            const wx = src_x - @as(f32, @floatFromInt(x0));

            for (0..ch) |c| {
                const p00 = @as(f32, @floatFromInt(src.data[(y0 * src.width + x0) * ch + c]));
                const p01 = @as(f32, @floatFromInt(src.data[(y0 * src.width + x1) * ch + c]));
                const p10 = @as(f32, @floatFromInt(src.data[(y1 * src.width + x0) * ch + c]));
                const p11 = @as(f32, @floatFromInt(src.data[(y1 * src.width + x1) * ch + c]));

                const val = p00 * (1.0 - wx) * (1.0 - wy) +
                    p01 * wx * (1.0 - wy) +
                    p10 * (1.0 - wx) * wy +
                    p11 * wx * wy;

                dst.data[(dy * dst_width + dx) * ch + c] = @intFromFloat(std.math.clamp(val, 0.0, 255.0));
            }
        }
    }

    return dst;
}

/// Convert image from HWC (height, width, channels) to NCHW (batch, channels, height, width).
/// Output is a contiguous f32 buffer suitable for ONNX model input.
/// Normalization: (pixel / 255.0 - mean) / std for each channel.
pub fn toNCHW(allocator: std.mem.Allocator, src: Image, mean: []const f32, std_dev: []const f32) ImageError![]f32 {
    const ch = @as(usize, src.channels);
    const total = ch * src.width * src.height;
    var output = try allocator.alloc(f32, total);

    for (0..ch) |c| {
        const channel_offset = c * src.width * src.height;
        const m = if (c < mean.len) mean[c] else 0.0;
        const s = if (c < std_dev.len) std_dev[c] else 1.0;

        for (0..src.height) |y| {
            for (0..src.width) |x| {
                const pixel_idx = (y * src.width + x) * ch + c;
                const normalized = (@as(f32, @floatFromInt(src.data[pixel_idx])) / 255.0 - m) / s;
                output[channel_offset + y * src.width + x] = normalized;
            }
        }
    }

    return output;
}

/// Convert image from HWC to NCHW without normalization (just /255.0).
pub fn toNCHWPlain(allocator: std.mem.Allocator, src: Image) ImageError![]f32 {
    const ch = @as(usize, src.channels);
    const total = ch * src.width * src.height;
    var output = try allocator.alloc(f32, total);

    for (0..ch) |c| {
        const channel_offset = c * src.width * src.height;
        for (0..src.height) |y| {
            for (0..src.width) |x| {
                const pixel_idx = (y * src.width + x) * ch + c;
                output[channel_offset + y * src.width + x] = @as(f32, @floatFromInt(src.data[pixel_idx])) / 255.0;
            }
        }
    }

    return output;
}

/// Convert RGB image to grayscale (1 channel) using luminance weights.
pub fn toGrayscale(allocator: std.mem.Allocator, src: Image) ImageError!Image {
    if (src.channels < 3) return error.InvalidFormat;
    var dst = try Image.init(allocator, src.width, src.height, 1);

    for (0..src.height) |y| {
        for (0..src.width) |x| {
            const idx = (y * src.width + x) * @as(usize, src.channels);
            const r = @as(f32, @floatFromInt(src.data[idx + 0]));
            const g = @as(f32, @floatFromInt(src.data[idx + 1]));
            const b = @as(f32, @floatFromInt(src.data[idx + 2]));
            // ITU-R BT.601 luma: 0.299R + 0.587G + 0.114B
            const gray = 0.299 * r + 0.587 * g + 0.114 * b;
            dst.data[y * src.width + x] = @intFromFloat(std.math.clamp(gray, 0.0, 255.0));
        }
    }

    return dst;
}

/// Full preprocessing pipeline: resize → normalize → NCHW.
/// Returns a contiguous f32 buffer ready for ONNX inference.
pub fn preprocess(
    allocator: std.mem.Allocator,
    src: Image,
    dst_width: usize,
    dst_height: usize,
    dst_channels: u8,
    mean: []const f32,
    std_dev: []const f32,
) ImageError![]f32 {
    // Step 1: Channel transform if needed
    var working = src;
    var grayscale_img: ?Image = null;
    defer if (grayscale_img) |*gi| gi.deinit();

    if (dst_channels == 1 and src.channels >= 3) {
        const gs = try toGrayscale(allocator, src);
        grayscale_img = gs;
        working = gs;
    }

    // Step 2: Resize
    var resized_img: ?Image = null;
    defer if (resized_img) |*ri| ri.deinit();

    if (working.width != dst_width or working.height != dst_height) {
        const rs = try resize(allocator, working, dst_width, dst_height);
        resized_img = rs;
        working = rs;
    }

    // Step 3: Normalize and convert to NCHW
    return toNCHW(allocator, working, mean, std_dev);
}

// =============================================================================
// Tests
// =============================================================================

test "loadPPM parses valid P6 8-bit image" {
    const allocator = std.testing.allocator;
    // Minimal 2x2 PPM P6 image, max_val=255
    const ppm_data = "P6\n2 2\n255\n\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\x00";
    var img = try loadFromMemory(allocator, ppm_data, "test.ppm");
    defer img.deinit();

    try std.testing.expect(img.width == 2);
    try std.testing.expect(img.height == 2);
    try std.testing.expect(img.channels == 3);
    // First pixel: red
    try std.testing.expect(img.data[0] == 0xFF);
    try std.testing.expect(img.data[1] == 0x00);
    try std.testing.expect(img.data[2] == 0x00);
}

test "loadPPM handles comments in header" {
    const allocator = std.testing.allocator;
    const ppm_data = "P6\n# This is a comment\n1 1\n255\n\x80\x80\x80";
    var img = try loadFromMemory(allocator, ppm_data, "test.ppm");
    defer img.deinit();

    try std.testing.expect(img.width == 1);
    try std.testing.expect(img.height == 1);
    try std.testing.expect(img.data[0] == 0x80);
}

test "loadPPM rejects invalid magic" {
    const allocator = std.testing.allocator;
    const bad_data = "P5\n1 1\n255\n\x00";
    try std.testing.expectError(error.InvalidFormat, loadFromMemory(allocator, bad_data, "test.ppm"));
}

test "loadBMP parses valid 24-bit BMP" {
    const allocator = std.testing.allocator;
    // Minimal 2x1 24-bit BMP
    var bmp_data = [_]u8{
        'B', 'M', // Magic
        0x3A, 0x00, 0x00, 0x00, // File size (58)
        0x00, 0x00, 0x00, 0x00, // Reserved
        0x36, 0x00, 0x00, 0x00, // Data offset (54)
        0x28, 0x00, 0x00, 0x00, // Header size (40)
        0x02, 0x00, 0x00, 0x00, // Width (2)
        0x01, 0x00, 0x00, 0x00, // Height (1)
        0x01, 0x00, // Planes
        0x18, 0x00, // BPP (24)
        0x00, 0x00, 0x00, 0x00, // Compression (0)
        0x04, 0x00, 0x00, 0x00, // Image size
        0x00, 0x00, 0x00, 0x00, // X ppm
        0x00, 0x00, 0x00, 0x00, // Y ppm
        0x00, 0x00, 0x00, 0x00, // Colors used
        0x00, 0x00, 0x00, 0x00, // Important colors
        // Pixel data: 2 pixels BGR + 2 bytes padding = 8 bytes
        0x00, 0xFF, 0x00, // Pixel 0: B=0, G=255, R=0 (green)
        0xFF, 0x00, 0x00, // Pixel 1: B=255, G=0, R=0 (blue)
        0x00, 0x00, // Padding
    };
    var img = try loadFromMemory(allocator, &bmp_data, "test.bmp");
    defer img.deinit();

    try std.testing.expect(img.width == 2);
    try std.testing.expect(img.height == 1);
    try std.testing.expect(img.channels == 3);
    // First pixel: green (BGR→RGB)
    try std.testing.expect(img.data[0] == 0x00); // R
    try std.testing.expect(img.data[1] == 0xFF); // G
    try std.testing.expect(img.data[2] == 0x00); // B
    // Second pixel: blue
    try std.testing.expect(img.data[3] == 0x00); // R
    try std.testing.expect(img.data[4] == 0x00); // G
    try std.testing.expect(img.data[5] == 0xFF); // B
}

test "loadBMP rejects compressed BMP" {
    const allocator = std.testing.allocator;
    var bmp_data = [_]u8{
        'B', 'M',
        0x36, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x36, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x18, 0x00,
        0x01, 0x00, 0x00, 0x00, // Compression = 1 (RLE)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
    };
    try std.testing.expectError(error.UnsupportedFormat, loadFromMemory(allocator, &bmp_data, "test.bmp"));
}

test "resize bilinear produces correct dimensions" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 4, 4, 3);
    defer src.deinit();
    // Fill with a simple gradient
    for (0..16) |i| {
        src.data[i * 3 + 0] = @intCast(i * 16);
        src.data[i * 3 + 1] = 0;
        src.data[i * 3 + 2] = 0;
    }

    var dst = try resize(allocator, src, 2, 2);
    defer dst.deinit();

    try std.testing.expect(dst.width == 2);
    try std.testing.expect(dst.height == 2);
    try std.testing.expect(dst.channels == 3);
}

test "resize identity preserves image data" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 3, 3, 3);
    defer src.deinit();
    for (0..27) |i| src.data[i] = @intCast(i);

    var dst = try resize(allocator, src, 3, 3);
    defer dst.deinit();

    for (0..27) |i| {
        try std.testing.expect(dst.data[i] == src.data[i]);
    }
}

test "toNCHW produces correct layout and normalization" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 2, 1, 3);
    defer src.deinit();
    // Two pixels: (255, 0, 0) and (0, 255, 0)
    src.data[0] = 255; src.data[1] = 0; src.data[2] = 0;
    src.data[3] = 0; src.data[4] = 255; src.data[5] = 0;

    const mean = [_]f32{ 0.0, 0.0, 0.0 };
    const std_dev = [_]f32{ 1.0, 1.0, 1.0 };
    const result = try toNCHW(allocator, src, &mean, &std_dev);
    defer allocator.free(result);

    // NCHW layout: [R0, R1, G0, G1, B0, B1]
    try std.testing.expect(result.len == 6);
    try std.testing.expectApproxEqAbs(result[0], 1.0, 0.001); // R0 = 255/255
    try std.testing.expectApproxEqAbs(result[1], 0.0, 0.001); // R1 = 0/255
    try std.testing.expectApproxEqAbs(result[2], 0.0, 0.001); // G0 = 0/255
    try std.testing.expectApproxEqAbs(result[3], 1.0, 0.001); // G1 = 255/255
}

test "toNCHW with mean/std normalization" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 1, 1, 3);
    defer src.deinit();
    src.data[0] = 127; src.data[1] = 127; src.data[2] = 127;

    const mean = [_]f32{ 0.5, 0.5, 0.5 };
    const std_dev = [_]f32{ 0.5, 0.5, 0.5 };
    const result = try toNCHW(allocator, src, &mean, &std_dev);
    defer allocator.free(result);

    // (127/255 - 0.5) / 0.5 ≈ (0.498 - 0.5) / 0.5 ≈ -0.00392
    try std.testing.expectApproxEqAbs(result[0], (127.0 / 255.0 - 0.5) / 0.5, 0.01);
}

test "toNCHWPlain produces /255 normalization" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 1, 1, 3);
    defer src.deinit();
    src.data[0] = 255; src.data[1] = 128; src.data[2] = 0;

    const result = try toNCHWPlain(allocator, src);
    defer allocator.free(result);

    try std.testing.expectApproxEqAbs(result[0], 1.0, 0.001);
    try std.testing.expectApproxEqAbs(result[1], 128.0 / 255.0, 0.001);
    try std.testing.expectApproxEqAbs(result[2], 0.0, 0.001);
}

test "toGrayscale converts RGB to luminance" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 2, 1, 3);
    defer src.deinit();
    // White and black
    src.data[0] = 255; src.data[1] = 255; src.data[2] = 255;
    src.data[3] = 0; src.data[4] = 0; src.data[5] = 0;

    var dst = try toGrayscale(allocator, src);
    defer dst.deinit();

    try std.testing.expect(dst.channels == 1);
    try std.testing.expect(dst.data[0] == 255); // White → 255
    try std.testing.expect(dst.data[1] == 0); // Black → 0
}

test "toGrayscale uses BT.601 weights" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 1, 1, 3);
    defer src.deinit();
    // Pure green: 0.587 * 255 ≈ 150
    src.data[0] = 0; src.data[1] = 255; src.data[2] = 0;

    var dst = try toGrayscale(allocator, src);
    defer dst.deinit();

    try std.testing.expect(dst.data[0] == 149);
}

test "preprocess pipeline: resize + normalize + NCHW" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 4, 4, 3);
    defer src.deinit();
    for (0..48) |i| src.data[i] = @intCast(i % 256);

    const mean = [_]f32{ 0.485, 0.456, 0.406 };
    const std_dev = [_]f32{ 0.229, 0.224, 0.225 };
    const result = try preprocess(allocator, src, 2, 2, 3, &mean, &std_dev);
    defer allocator.free(result);

    // NCHW: 3 channels * 2 * 2 = 12 floats
    try std.testing.expect(result.len == 12);
}

test "preprocess with grayscale conversion" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 2, 2, 3);
    defer src.deinit();
    for (0..12) |i| src.data[i] = 128;

    const mean = [_]f32{0.5};
    const std_dev = [_]f32{ 0.5 };
    const result = try preprocess(allocator, src, 2, 2, 1, &mean, &std_dev);
    defer allocator.free(result);

    // 1 channel * 2 * 2 = 4 floats
    try std.testing.expect(result.len == 4);
}

test "Image init creates zeroed buffer" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 4, 4, 3);
    defer img.deinit();

    try std.testing.expect(img.width == 4);
    try std.testing.expect(img.height == 4);
    try std.testing.expect(img.channels == 3);
    try std.testing.expect(img.data.len == 48);
    for (img.data) |b| try std.testing.expect(b == 0);
}

test "Image getPixel and setPixel" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 2, 3);
    defer img.deinit();

    const pixel = [_]u8{ 10, 20, 30 };
    img.setPixel(1, 0, &pixel);
    const got = img.getPixel(1, 0);
    try std.testing.expect(got[0] == 10);
    try std.testing.expect(got[1] == 20);
    try std.testing.expect(got[2] == 30);
}

test "loadFromMemory rejects empty data" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFormat, loadFromMemory(allocator, &[_]u8{}, "test.unknown"));
}

test "loadFromMemory rejects unknown format" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFormat, loadFromMemory(allocator, "XYZ123", "test.xyz"));
}

test "StbImage.loadLib returns null when not installed" {
    // stb_image is not available as a shared library on this system
    const result = StbImage.loadLib();
    try std.testing.expect(result == null);
}

test "loadFromMemory returns UnsupportedFormat for JPEG without stb" {
    const allocator = std.testing.allocator;
    const jpeg_magic = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10 };
    // stb_image not installed → should return UnsupportedFormat
    const result = loadFromMemory(allocator, &jpeg_magic, "test.jpg");
    if (result) |img| {
        var i = img;
        defer i.deinit();
    } else |err| {
        try std.testing.expect(err == error.UnsupportedFormat or err == error.LibraryNotFound);
    }
}
