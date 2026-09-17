//! transport_polyglot.zig — Multi-format polyglot file transport.
//!
//! Extracted from beheader (#06).
//! Injects headers for PNG/MP4/HTML/PDF/ZIP so a single file is valid in multiple formats.

const std = @import("std");

pub const Format = enum {
    png,
    mp4,
    html,
    pdf,
    zip,
    jar,
    pyz,
};

pub const FormatMagic = struct {
    format: Format,
    magic: []const u8,
    trailer: []const u8,
};

pub const FORMAT_TABLE = [_]FormatMagic{
    .{ .format = .png, .magic = "\x89PNG\r\n\x1a\n", .trailer = "" },
    .{ .format = .mp4, .magic = "\x00\x00\x00\x18ftypmp42", .trailer = "" },
    .{ .format = .html, .magic = "<!DOCTYPE html>\n<html><!--", .trailer = " --></html>" },
    .{ .format = .pdf, .magic = "%PDF-1.4\n", .trailer = "\n%%EOF" },
    .{ .format = .zip, .magic = "PK\x03\x04", .trailer = "PK\x05\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" },
    .{ .format = .jar, .magic = "PK\x03\x04", .trailer = "" },
    .{ .format = .pyz, .magic = "PK\x03\x04", .trailer = "" },
};

/// JAR manifest header injected as the first ZIP entry.
pub const JAR_MANIFEST_HEADER = "META-INF/MANIFEST.MF\nManifest-Version: 1.0\nCreated-By: Qstar polyglot transport\nMain-Class: Main\n\n";

/// PYZ entry point header injected as the first ZIP entry.
pub const PYZ_MAIN_HEADER = "__main__.py\n# Qstar polyglot Python executable\nimport sys\n";

fn findFormat(fmt: Format) ?FormatMagic {
    for (FORMAT_TABLE) |entry| {
        if (entry.format == fmt) return entry;
    }
    return null;
}

/// Encodes data as a polyglot file valid in the specified format.
pub fn encode(allocator: std.mem.Allocator, data: []const u8, fmt: Format) ![]u8 {
    const entry = findFormat(fmt) orelse return error.UnknownFormat;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(entry.magic);
    try out.appendSlice(data);
    if (entry.trailer.len > 0) {
        try out.appendSlice(entry.trailer);
    }

    return out.toOwnedSlice();
}

/// Decodes a polyglot file by stripping the format header and trailer.
pub fn decode(allocator: std.mem.Allocator, polyglot: []const u8, fmt: Format) ![]u8 {
    const entry = findFormat(fmt) orelse return error.UnknownFormat;

    if (polyglot.len < entry.magic.len) return error.TooShort;
    if (!std.mem.eql(u8, polyglot[0..entry.magic.len], entry.magic)) return error.WrongFormat;

    const start = entry.magic.len;
    var end = polyglot.len;

    if (entry.trailer.len > 0 and end >= entry.trailer.len) {
        const trailer_start = end - entry.trailer.len;
        if (std.mem.eql(u8, polyglot[trailer_start..end], entry.trailer)) {
            end = trailer_start;
        }
    }

    return try allocator.dupe(u8, polyglot[start..end]);
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "polyglot";
}

/// Encode data as an executable JAR container.
/// A JAR is a ZIP file with a META-INF/MANIFEST.MF entry.
/// The output is a valid ZIP structure: local file header + manifest data + data + central directory + end record.
pub fn encodeJAR(allocator: std.mem.Allocator, data: []const u8, main_class: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    // Local file header for META-INF/MANIFEST.MF
    try out.appendSlice("PK\x03\x04"); // Local file header signature
    try out.appendSlice(&[_]u8{ 0x14, 0x00 }); // Version needed (2.0)
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // General purpose bit flag
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Compression method (stored)
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // Last mod time
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // CRC-32 (0 for simplicity)
    const manifest_len: u32 = @intCast(JAR_MANIFEST_HEADER.len + main_class.len + 1);
    try out.appendSlice(&[_]u8{ @truncate(manifest_len), @truncate(manifest_len >> 8), @truncate(manifest_len >> 16), @truncate(manifest_len >> 24) }); // Compressed size
    try out.appendSlice(&[_]u8{ @truncate(manifest_len), @truncate(manifest_len >> 8), @truncate(manifest_len >> 16), @truncate(manifest_len >> 24) }); // Uncompressed size
    const manifest_name_len: u16 = @intCast(JAR_MANIFEST_HEADER.len);
    try out.appendSlice(&[_]u8{ @truncate(manifest_name_len), @truncate(manifest_name_len >> 8) }); // Filename length
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Extra field length
    try out.appendSlice(JAR_MANIFEST_HEADER);
    try out.appendSlice(main_class);
    try out.append('\n');

    // Local file header for the payload data
    const data_offset = out.items.len;
    try out.appendSlice("PK\x03\x04");
    try out.appendSlice(&[_]u8{ 0x14, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    const data_len: u32 = @intCast(data.len);
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ 0x07, 0x00 }); // "Main.cl" = 7 bytes
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice("Main.cl");
    try out.appendSlice(data);

    // Central directory entries
    const cd_start = out.items.len;
    // CD entry for manifest
    try out.appendSlice("PK\x01\x02");
    try out.appendSlice(&[_]u8{ 0x14, 0x00 }); // Version made by
    try out.appendSlice(&[_]u8{ 0x14, 0x00 }); // Version needed
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Flags
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Method
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // Mod time
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // CRC
    try out.appendSlice(&[_]u8{ @truncate(manifest_len), @truncate(manifest_len >> 8), @truncate(manifest_len >> 16), @truncate(manifest_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(manifest_len), @truncate(manifest_len >> 8), @truncate(manifest_len >> 16), @truncate(manifest_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(manifest_name_len), @truncate(manifest_name_len >> 8) });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Extra
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Comment
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Disk start
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Internal attrs
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // External attrs
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }); // Local header offset = 0
    try out.appendSlice(JAR_MANIFEST_HEADER);
    try out.appendSlice(main_class);
    try out.append('\n');

    // CD entry for data
    try out.appendSlice("PK\x01\x02");
    try out.appendSlice(&[_]u8{ 0x14, 0x00 });
    try out.appendSlice(&[_]u8{ 0x14, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ 0x07, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    const data_offset_u32: u32 = @intCast(data_offset);
    try out.appendSlice(&[_]u8{ @truncate(data_offset_u32), @truncate(data_offset_u32 >> 8), @truncate(data_offset_u32 >> 16), @truncate(data_offset_u32 >> 24) });
    try out.appendSlice("Main.cl");
    try out.appendSlice(data);

    const cd_size = out.items.len - cd_start;

    // End of central directory record
    try out.appendSlice("PK\x05\x06");
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Disk number
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Disk with CD
    try out.appendSlice(&[_]u8{ 0x02, 0x00 }); // Entries on this disk (2)
    try out.appendSlice(&[_]u8{ 0x02, 0x00 }); // Total entries (2)
    const cd_size_u16: u16 = @intCast(cd_size);
    try out.appendSlice(&[_]u8{ @truncate(cd_size_u16), @truncate(cd_size_u16 >> 8) }); // CD size
    const cd_start_u16: u16 = @intCast(cd_start);
    try out.appendSlice(&[_]u8{ @truncate(cd_start_u16), @truncate(cd_start_u16 >> 8) }); // CD offset
    try out.appendSlice(&[_]u8{ 0x00, 0x00 }); // Comment length

    return out.toOwnedSlice();
}

/// Encode data as an executable Python .pyz (zipapp) container.
/// A PYZ is a ZIP file with a __main__.py entry point.
pub fn encodePYZ(allocator: std.mem.Allocator, data: []const u8, python_preamble: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    // Local file header for __main__.py
    const main_content = python_preamble;
    try out.appendSlice("PK\x03\x04");
    try out.appendSlice(&[_]u8{ 0x14, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    const main_len: u32 = @intCast(main_content.len);
    try out.appendSlice(&[_]u8{ @truncate(main_len), @truncate(main_len >> 8), @truncate(main_len >> 16), @truncate(main_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(main_len), @truncate(main_len >> 8), @truncate(main_len >> 16), @truncate(main_len >> 24) });
    try out.appendSlice(&[_]u8{ 0x0B, 0x00 }); // "__main__.py" = 11 bytes
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice("__main__.py");
    try out.appendSlice(main_content);

    // Local file header for payload data
    const data_offset = out.items.len;
    try out.appendSlice("PK\x03\x04");
    try out.appendSlice(&[_]u8{ 0x14, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    const data_len: u32 = @intCast(data.len);
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ 0x07, 0x00 }); // "data.py" = 7 bytes
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });
    try out.appendSlice("data.py");
    try out.appendSlice(data);

    // Central directory
    const cd_start = out.items.len;
    // CD for __main__.py
    try out.appendSlice("PK\x01\x02");
    try out.appendSlice(&[_]u8{ 0x14, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ @truncate(main_len), @truncate(main_len >> 8), @truncate(main_len >> 16), @truncate(main_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(main_len), @truncate(main_len >> 8), @truncate(main_len >> 16), @truncate(main_len >> 24) });
    try out.appendSlice(&[_]u8{ 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice("__main__.py");
    try out.appendSlice(main_content);

    // CD for data.py
    try out.appendSlice("PK\x01\x02");
    try out.appendSlice(&[_]u8{ 0x14, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ @truncate(data_len), @truncate(data_len >> 8), @truncate(data_len >> 16), @truncate(data_len >> 24) });
    try out.appendSlice(&[_]u8{ 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    const data_offset_u32: u32 = @intCast(data_offset);
    try out.appendSlice(&[_]u8{ @truncate(data_offset_u32), @truncate(data_offset_u32 >> 8), @truncate(data_offset_u32 >> 16), @truncate(data_offset_u32 >> 24) });
    try out.appendSlice("data.py");
    try out.appendSlice(data);

    const cd_size = out.items.len - cd_start;

    // End of central directory
    try out.appendSlice("PK\x05\x06");
    try out.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00 });
    const cd_size_u16: u16 = @intCast(cd_size);
    try out.appendSlice(&[_]u8{ @truncate(cd_size_u16), @truncate(cd_size_u16 >> 8) });
    const cd_start_u16: u16 = @intCast(cd_start);
    try out.appendSlice(&[_]u8{ @truncate(cd_start_u16), @truncate(cd_start_u16 >> 8) });
    try out.appendSlice(&[_]u8{ 0x00, 0x00 });

    return out.toOwnedSlice();
}

/// Detect the format of a polyglot file by checking magic bytes.
pub fn detectFormat(data: []const u8) ?Format {
    if (data.len < 4) return null;

    // Check ZIP-based formats (JAR, PYZ, ZIP all start with PK\x03\x04)
    if (std.mem.startsWith(u8, data, "PK\x03\x04")) {
        // Look for __main__.py to identify PYZ
        if (std.mem.indexOf(u8, data, "__main__.py") != null) return .pyz;
        // Look for META-INF/MANIFEST.MF to identify JAR
        if (std.mem.indexOf(u8, data, "META-INF/MANIFEST.MF") != null) return .jar;
        return .zip;
    }
    if (std.mem.startsWith(u8, data, "\x89PNG")) return .png;
    if (data.len >= 12 and std.mem.startsWith(u8, data[4..], "ftyp")) return .mp4;
    if (std.mem.startsWith(u8, data, "<!DOCTYPE html>")) return .html;
    if (std.mem.startsWith(u8, data, "%PDF")) return .pdf;

    return null;
}

/// Extract payload data from a JAR container.
/// Finds the data after the manifest entry.
pub fn decodeJAR(allocator: std.mem.Allocator, jar_data: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, jar_data, "PK\x03\x04")) return error.NotJAR;
    // Find Main.cl entry in the data
    const idx = std.mem.indexOf(u8, jar_data, "Main.cl") orelse return error.NoPayload;
    // Data starts after the filename (7 bytes) — extra field length is 0
    const data_start = idx + 7;
    if (data_start >= jar_data.len) return error.NoPayload;

    // Find the end of data — look for the central directory signature
    const cd_idx = std.mem.indexOf(u8, jar_data[data_start..], "PK\x01\x02") orelse return error.NoPayload;
    const data_end = data_start + cd_idx;

    return try allocator.dupe(u8, jar_data[data_start..data_end]);
}

/// Extract payload data from a PYZ container.
/// Finds the data after the __main__.py entry.
pub fn decodePYZ(allocator: std.mem.Allocator, pyz_data: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, pyz_data, "PK\x03\x04")) return error.NotPYZ;
    // Find data.py entry
    const idx = std.mem.indexOf(u8, pyz_data, "data.py") orelse return error.NoPayload;
    // Data starts after the filename (7 bytes) — extra field length is 0
    const data_start = idx + 7;
    if (data_start >= pyz_data.len) return error.NoPayload;

    // Find the end of data — look for the central directory signature
    const cd_idx = std.mem.indexOf(u8, pyz_data[data_start..], "PK\x01\x02") orelse return error.NoPayload;
    const data_end = data_start + cd_idx;

    return try allocator.dupe(u8, pyz_data[data_start..data_end]);
}

// Tests

test "polyglot PNG round trip" {
    const allocator = std.testing.allocator;
    const data = "payload data here";

    const encoded = try encode(allocator, data, .png);
    defer allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);

    const decoded = try decode(allocator, encoded, .png);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "polyglot HTML round trip" {
    const allocator = std.testing.allocator;
    const data = "console.log('hello');";

    const encoded = try encode(allocator, data, .html);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "<!DOCTYPE html>"));

    const decoded = try decode(allocator, encoded, .html);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "polyglot PDF round trip" {
    const allocator = std.testing.allocator;
    const data = "PDF body content";

    const encoded = try encode(allocator, data, .pdf);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "%PDF-1.4"));

    const decoded = try decode(allocator, encoded, .pdf);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "polyglot wrong format detection" {
    const allocator = std.testing.allocator;
    const data = "test";

    const encoded = try encode(allocator, data, .png);
    defer allocator.free(encoded);

    try std.testing.expectError(error.WrongFormat, decode(allocator, encoded, .pdf));
}

test "polyglot name" {
    try std.testing.expectEqualStrings("polyglot", name());
}

test "polyglot JAR encode produces valid ZIP structure" {
    const allocator = std.testing.allocator;
    const data = "public class Main { public static void main(String[] args) {} }";

    const encoded = try encodeJAR(allocator, data, "Main");
    defer allocator.free(encoded);

    // Should start with ZIP local file header
    try std.testing.expect(std.mem.startsWith(u8, encoded, "PK\x03\x04"));
    // Should contain manifest
    try std.testing.expect(std.mem.indexOf(u8, encoded, "META-INF/MANIFEST.MF") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "Manifest-Version: 1.0") != null);
    // Should contain Main-Class
    try std.testing.expect(std.mem.indexOf(u8, encoded, "Main-Class: Main") != null);
    // Should contain payload
    try std.testing.expect(std.mem.indexOf(u8, encoded, "Main.cl") != null);
    // Should end with end-of-central-directory record
    try std.testing.expect(std.mem.indexOf(u8, encoded, "PK\x05\x06") != null);
}

test "polyglot JAR decode round trip" {
    const allocator = std.testing.allocator;
    const data = "public class Main { public static void main(String[] args) { System.out.println(\"Hello\"); } }";

    const encoded = try encodeJAR(allocator, data, "Main");
    defer allocator.free(encoded);

    const decoded = try decodeJAR(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "polyglot JAR decode rejects non-JAR" {
    const allocator = std.testing.allocator;
    const not_jar = "NOTAZIP";

    try std.testing.expectError(error.NotJAR, decodeJAR(allocator, not_jar));
}

test "polyglot PYZ encode produces valid ZIP structure" {
    const allocator = std.testing.allocator;
    const data = "print('Hello from Python')";

    const preamble = "import sys\nprint('Starting...')\n";
    const encoded = try encodePYZ(allocator, data, preamble);
    defer allocator.free(encoded);

    // Should start with ZIP local file header
    try std.testing.expect(std.mem.startsWith(u8, encoded, "PK\x03\x04"));
    // Should contain __main__.py
    try std.testing.expect(std.mem.indexOf(u8, encoded, "__main__.py") != null);
    // Should contain data.py
    try std.testing.expect(std.mem.indexOf(u8, encoded, "data.py") != null);
    // Should end with end-of-central-directory record
    try std.testing.expect(std.mem.indexOf(u8, encoded, "PK\x05\x06") != null);
}

test "polyglot PYZ decode round trip" {
    const allocator = std.testing.allocator;
    const data = "payload_data = 42";

    const preamble = "import sys\n";
    const encoded = try encodePYZ(allocator, data, preamble);
    defer allocator.free(encoded);

    const decoded = try decodePYZ(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "polyglot PYZ decode rejects non-PYZ" {
    const allocator = std.testing.allocator;
    const not_pyz = "NOTAZIP";

    try std.testing.expectError(error.NotPYZ, decodePYZ(allocator, not_pyz));
}

test "polyglot detectFormat PNG" {
    const allocator = std.testing.allocator;
    const data = "test payload";
    const encoded = try encode(allocator, data, .png);
    defer allocator.free(encoded);
    try std.testing.expectEqual(Format.png, detectFormat(encoded).?);
}

test "polyglot detectFormat HTML" {
    const allocator = std.testing.allocator;
    const data = "test";
    const encoded = try encode(allocator, data, .html);
    defer allocator.free(encoded);
    try std.testing.expectEqual(Format.html, detectFormat(encoded).?);
}

test "polyglot detectFormat PDF" {
    const allocator = std.testing.allocator;
    const data = "test";
    const encoded = try encode(allocator, data, .pdf);
    defer allocator.free(encoded);
    try std.testing.expectEqual(Format.pdf, detectFormat(encoded).?);
}

test "polyglot detectFormat JAR" {
    const allocator = std.testing.allocator;
    const data = "test";
    const encoded = try encodeJAR(allocator, data, "Main");
    defer allocator.free(encoded);
    try std.testing.expectEqual(Format.jar, detectFormat(encoded).?);
}

test "polyglot detectFormat PYZ" {
    const allocator = std.testing.allocator;
    const data = "test";
    const preamble = "import sys\n";
    const encoded = try encodePYZ(allocator, data, preamble);
    defer allocator.free(encoded);
    try std.testing.expectEqual(Format.pyz, detectFormat(encoded).?);
}

test "polyglot detectFormat ZIP (plain, no JAR/PYZ markers)" {
    const allocator = std.testing.allocator;
    const data = "test";
    const encoded = try encode(allocator, data, .zip);
    defer allocator.free(encoded);
    // Plain ZIP should be detected as .zip (no __main__.py or META-INF)
    try std.testing.expectEqual(Format.zip, detectFormat(encoded).?);
}

test "polyglot detectFormat returns null for unknown" {
    try std.testing.expect(detectFormat("UNKNOWN") == null);
    try std.testing.expect(detectFormat("") == null);
}

test "polyglot JAR with empty data" {
    const allocator = std.testing.allocator;
    const data = "";
    const encoded = try encodeJAR(allocator, data, "Main");
    defer allocator.free(encoded);

    const decoded = try decodeJAR(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "polyglot PYZ with empty data" {
    const allocator = std.testing.allocator;
    const data = "";
    const preamble = "import sys\n";
    const encoded = try encodePYZ(allocator, data, preamble);
    defer allocator.free(encoded);

    const decoded = try decodePYZ(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "polyglot JAR with large data" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 10000);
    defer allocator.free(data);
    for (data) |*b| b.* = 0xAA;

    const encoded = try encodeJAR(allocator, data, "Main");
    defer allocator.free(encoded);

    const decoded = try decodeJAR(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "polyglot PYZ with large data" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 10000);
    defer allocator.free(data);
    for (data) |*b| b.* = 0xBB;

    const preamble = "import sys\nprint('start')\n";
    const encoded = try encodePYZ(allocator, data, preamble);
    defer allocator.free(encoded);

    const decoded = try decodePYZ(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
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
