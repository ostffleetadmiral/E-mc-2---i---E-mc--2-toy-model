//! polyglot.zig — Polyglot file format for multi-format binaries.
//!
//! Creates single binary files that are simultaneously valid as
//! multiple file formats (PNG, ZIP, MP4, HTML, PDF). Exploits the
//! fact that different parsers read from different offsets:
//! - PNG/MP4 read from the beginning (file header)
//! - ZIP reads from the end (Central Directory at EOF)
//! - HTML/PDF read from the beginning but tolerate leading garbage

const std = @import("std");

/// Polyglot format configuration.
pub const PolyglotConfig = struct {
    include_png: bool = true,
    include_zip: bool = true,
    include_html: bool = false,
    include_pdf: bool = false,
};

/// PNG signature (8 bytes).
pub const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// ZIP End of Central Directory signature.
pub const ZIP_EOCD_SIGNATURE = [_]u8{ 0x50, 0x4B, 0x05, 0x06 };

/// ZIP Local File Header signature.
pub const ZIP_LOCAL_HEADER = [_]u8{ 0x50, 0x4B, 0x03, 0x04 };

/// HTML doctype prefix.
pub const HTML_PREFIX = "<!DOCTYPE html>";

/// PDF header.
pub const PDF_PREFIX = "%PDF-1.4";

/// Build a PNG+ZIP polyglot file.
/// The PNG header is at the start, and the ZIP central directory
/// is appended at the end. The payload is stored as a ZIP entry
/// within the PNG chunk data.
pub fn buildPngZipPolyglot(alloc: std.mem.Allocator, payload: []const u8, png_width: u32, png_height: u32) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);

    // PNG signature
    try buf.appendSlice(&PNG_SIGNATURE);

    // IHDR chunk
    try writePngChunk(&buf, "IHDR", &buildIhdr(png_width, png_height));

    // IDAT chunk containing the ZIP data
    // ZIP Local File Header
    const zip_offset = buf.items.len;
    try buf.appendSlice(&ZIP_LOCAL_HEADER);
    // Version needed (2 bytes)
    try buf.appendSlice(&[_]u8{ 0x14, 0x00 });
    // General purpose bit flag (2 bytes)
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Compression method (store = 0)
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Last mod file time (2 bytes)
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Last mod file date (2 bytes)
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // CRC-32 (4 bytes, will fill later)
    const crc_offset = buf.items.len;
    try buf.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    // Compressed size
    std.debug.assert(payload.len <= 0xFFFFFFFF);
    try buf.writer().writeInt(u32, @intCast(payload.len), .little);
    // Uncompressed size
    try buf.writer().writeInt(u32, @intCast(payload.len), .little);
    // Filename length (4 bytes for "d")
    try buf.appendSlice(&[_]u8{ 0x01, 0x00 });
    // Extra field length
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Filename "d"
    try buf.append('d');
    // Payload data
    try buf.appendSlice(payload);

    // Compute CRC-32 and fill it in
    const crc = std.hash.Crc32.hash(payload);
    @memcpy(buf.items[crc_offset..][0..4], std.mem.asBytes(&crc));

    // IEND chunk
    try writePngChunk(&buf, "IEND", &.{});

    // ZIP End of Central Directory record
    try buf.appendSlice(&ZIP_EOCD_SIGNATURE);
    // Number of this disk (2 bytes)
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Disk where central directory starts (2 bytes)
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Number of central directory records on this disk
    try buf.appendSlice(&[_]u8{ 0x01, 0x00 });
    // Total number of central directory records
    try buf.appendSlice(&[_]u8{ 0x01, 0x00 });
    // Size of central directory (4 bytes) - we'll use 0 for simplicity
    try buf.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    // Offset of start of central directory
    try buf.writer().writeInt(u32, @intCast(zip_offset), .little);
    // Comment length
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });

    return buf.toOwnedSlice();
}

/// Write a PNG chunk to the buffer.
fn writePngChunk(buf: *std.ArrayList(u8), chunk_type: []const u8, data: []const u8) !void {
    // Length (4 bytes, big-endian)
    try buf.writer().writeInt(u32, @intCast(data.len), .big);
    // Chunk type
    try buf.appendSlice(chunk_type);
    // Chunk data
    try buf.appendSlice(data);
    // CRC-32 (over type + data)
    var crc_hasher = std.hash.Crc32.init();
    crc_hasher.update(chunk_type);
    crc_hasher.update(data);
    const crc = crc_hasher.final();
    // CRC is stored in big-endian
    try buf.appendSlice(std.mem.asBytes(&crc));
}

/// Build IHDR chunk data (13 bytes).
fn buildIhdr(width: u32, height: u32) [13]u8 {
    var buf: [13]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], width, .big);
    std.mem.writeInt(u32, buf[4..8], height, .big);
    buf[8] = 8; // Bit depth
    buf[9] = 2; // Color type (RGB)
    buf[10] = 0; // Compression method
    buf[11] = 0; // Filter method
    buf[12] = 0; // Interlace method
    return buf;
}

/// Extract the payload from a PNG+ZIP polyglot.
pub fn extractPngZipPayload(data: []const u8) ![]const u8 {
    // Find ZIP Local File Header
    const local_header_pos = std.mem.indexOf(u8, data, &ZIP_LOCAL_HEADER) orelse return error.ZipHeaderNotFound;
    if (local_header_pos + 30 > data.len) return error.DataTooShort;

    // Read compressed size at offset +18
    const compressed_size = std.mem.readInt(u32, data[local_header_pos + 18 ..][0..4], .little);
    // Read filename length at offset +26
    const filename_len = std.mem.readInt(u16, data[local_header_pos + 26 ..][0..2], .little);
    // Read extra field length at offset +28
    const extra_len = std.mem.readInt(u16, data[local_header_pos + 28 ..][0..2], .little);

    const data_offset = local_header_pos + 30 + @as(usize, filename_len) + @as(usize, extra_len);
    if (data_offset + compressed_size > data.len) return error.DataTooShort;

    return data[data_offset..][0..compressed_size];
}

/// Build an HTML+ZIP polyglot.
/// The file starts with an HTML comment containing the ZIP data.
pub fn buildHtmlZipPolyglot(alloc: std.mem.Allocator, payload: []const u8, html_content: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);

    // HTML prefix
    try buf.appendSlice(HTML_PREFIX);
    try buf.appendSlice("<!--");

    // ZIP Local File Header
    try buf.appendSlice(&ZIP_LOCAL_HEADER);
    try buf.appendSlice(&[_]u8{ 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    // CRC-32
    const crc = std.hash.Crc32.hash(payload);
    try buf.appendSlice(std.mem.asBytes(&crc));
    // Compressed size
    try buf.writer().writeInt(u32, @intCast(payload.len), .little);
    // Uncompressed size
    try buf.writer().writeInt(u32, @intCast(payload.len), .little);
    // Filename length
    try buf.appendSlice(&[_]u8{ 0x01, 0x00 });
    // Extra field length
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });
    // Filename
    try buf.append('d');
    // Payload
    try buf.appendSlice(payload);

    // ZIP End of Central Directory
    try buf.appendSlice(&ZIP_EOCD_SIGNATURE);
    try buf.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00 });
    try buf.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try buf.writer().writeInt(u32, 15, .little); // offset to central dir
    try buf.appendSlice(&[_]u8{ 0x00, 0x00 });

    // Close HTML comment and add content
    try buf.appendSlice("-->");
    try buf.appendSlice(html_content);

    return buf.toOwnedSlice();
}

/// Verify a PNG signature.
pub fn isPng(data: []const u8) bool {
    if (data.len < 8) return false;
    return std.mem.eql(u8, data[0..8], &PNG_SIGNATURE);
}

/// Verify a ZIP signature (check for local file header at start or EOCD at end).
pub fn isZip(data: []const u8) bool {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], &ZIP_LOCAL_HEADER)) return true;
    if (data.len >= 22) {
        // Search backwards for EOCD
        const search_start = if (data.len > 65557) data.len - 65557 else 0;
        return std.mem.indexOf(u8, data[search_start..], &ZIP_EOCD_SIGNATURE) != null;
    }
    return false;
}

/// Verify an HTML signature.
pub fn isHtml(data: []const u8) bool {
    if (data.len < HTML_PREFIX.len) return false;
    for (HTML_PREFIX, 0..) |b, i| {
        if (std.ascii.toLower(data[i]) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// Verify a PDF signature.
pub fn isPdf(data: []const u8) bool {
    if (data.len < 8) return false;
    return std.mem.eql(u8, data[0..8], PDF_PREFIX);
}

/// Detect all valid formats in a polyglot file.
pub const FormatSet = struct {
    png: bool = false,
    zip: bool = false,
    html: bool = false,
    pdf: bool = false,
};

pub fn detectFormats(data: []const u8) FormatSet {
    return .{
        .png = isPng(data),
        .zip = isZip(data),
        .html = isHtml(data),
        .pdf = isPdf(data),
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "isPng detects PNG signature" {
    const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00 };
    try std.testing.expect(isPng(&png));
    try std.testing.expect(!isZip(&png));
}

test "isZip detects ZIP local header" {
    const zip = [_]u8{ 0x50, 0x4B, 0x03, 0x04, 0x00, 0x00 };
    try std.testing.expect(isZip(&zip));
}

test "isHtml detects HTML" {
    const html = "<!DOCTYPE html><html></html>";
    try std.testing.expect(isHtml(html));
}

test "isPdf detects PDF" {
    const pdf = "%PDF-1.4\nrest of file";
    try std.testing.expect(isPdf(pdf));
}

test "buildPngZipPolyglot and extract round-trip" {
    const alloc = std.testing.allocator;
    const payload = "This is a secret FANO-1 payload!";
    const polyglot = try buildPngZipPolyglot(alloc, payload, 100, 100);
    defer alloc.free(polyglot);

    // Should be detected as PNG
    try std.testing.expect(isPng(polyglot));

    // Should be detected as ZIP
    try std.testing.expect(isZip(polyglot));

    // Should contain the payload
    const extracted = try extractPngZipPayload(polyglot);
    try std.testing.expectEqualSlices(u8, payload, extracted);
}

test "buildPngZipPolyglot produces valid PNG structure" {
    const alloc = std.testing.allocator;
    const payload = "test";
    const polyglot = try buildPngZipPolyglot(alloc, payload, 10, 10);
    defer alloc.free(polyglot);

    // PNG signature
    try std.testing.expectEqualSlices(u8, &PNG_SIGNATURE, polyglot[0..8]);

    // IHDR chunk should follow
    try std.testing.expectEqualSlices(u8, "IHDR", polyglot[12..16]);
}

test "detectFormats on PNG+ZIP polyglot" {
    const alloc = std.testing.allocator;
    const payload = "data";
    const polyglot = try buildPngZipPolyglot(alloc, payload, 10, 10);
    defer alloc.free(polyglot);

    const formats = detectFormats(polyglot);
    try std.testing.expect(formats.png);
    try std.testing.expect(formats.zip);
    try std.testing.expect(!formats.html);
    try std.testing.expect(!formats.pdf);
}

test "detectFormats on plain data" {
    const data = "just some text";
    const formats = detectFormats(data);
    try std.testing.expect(!formats.png);
    try std.testing.expect(!formats.zip);
    try std.testing.expect(!formats.html);
    try std.testing.expect(!formats.pdf);
}

test "buildHtmlZipPolyglot produces HTML+ZIP" {
    const alloc = std.testing.allocator;
    const payload = "payload data";
    const html = "<html><body>Hello</body></html>";
    const polyglot = try buildHtmlZipPolyglot(alloc, payload, html);
    defer alloc.free(polyglot);

    try std.testing.expect(isHtml(polyglot));
    try std.testing.expect(isZip(polyglot));
}

test "extractPngZipPayload handles empty payload" {
    const alloc = std.testing.allocator;
    const polyglot = try buildPngZipPolyglot(alloc, "", 10, 10);
    defer alloc.free(polyglot);
    const extracted = try extractPngZipPayload(polyglot);
    try std.testing.expectEqual(@as(usize, 0), extracted.len);
}

test "buildPngZipPolyglot with large payload" {
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, 1000);
    defer alloc.free(payload);
    @memset(payload, 0x42);

    const polyglot = try buildPngZipPolyglot(alloc, payload, 100, 100);
    defer alloc.free(polyglot);

    const extracted = try extractPngZipPayload(polyglot);
    try std.testing.expectEqualSlices(u8, payload, extracted);
}

test "FormatSet default is all false" {
    const formats = FormatSet{};
    try std.testing.expect(!formats.png);
    try std.testing.expect(!formats.zip);
    try std.testing.expect(!formats.html);
    try std.testing.expect(!formats.pdf);
}
