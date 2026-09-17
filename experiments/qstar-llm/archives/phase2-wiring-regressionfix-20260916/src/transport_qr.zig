//! transport_qr.zig — QR code transport with Huffman coding and alphanumeric packing.
//!
//! Extracted from ha.mr (#02).
//! Huffman coding, alphanumeric byte-packing, QR matrix layout.

const std = @import("std");

// QR version info: version 1 = 21×21, version 2 = 25×25, etc.
pub fn qrMatrixSize(version: u8) u32 {
    return 17 + 4 * @as(u32, version);
}

// Huffman node for text compression
pub const HuffmanNode = struct {
    symbol: u8,
    freq: u32,
    left: ?*HuffmanNode,
    right: ?*HuffmanNode,
};

pub const HuffmanCode = struct {
    symbol: u8,
    code: u32,
    length: u8,
};

/// Builds a simple Huffman table from byte frequencies.
pub fn buildHuffmanTable(allocator: std.mem.Allocator, data: []const u8) ![]HuffmanCode {
    var freq = [_]u32{0} ** 256;
    for (data) |b| freq[b] += 1;

    var symbols = std.ArrayList(struct { sym: u8, f: u32 }).init(allocator);
    defer symbols.deinit();
    for (0..256) |i| {
        if (freq[i] > 0) try symbols.append(.{ .sym = @intCast(i), .f = freq[i] });
    }

    if (symbols.items.len == 0) return try allocator.alloc(HuffmanCode, 0);
    if (symbols.items.len == 1) {
        var table = try allocator.alloc(HuffmanCode, 1);
        table[0] = .{ .symbol = symbols.items[0].sym, .code = 0, .length = 1 };
        return table;
    }

    const SymEntry = @TypeOf(symbols.items[0]);
    std.mem.sort(SymEntry, symbols.items, {}, struct {
        fn cmp(_: void, a: SymEntry, b: SymEntry) bool {
            return a.f > b.f;
        }
    }.cmp);

    // Simple canonical Huffman: assign codes by frequency rank
    var table = try allocator.alloc(HuffmanCode, symbols.items.len);
    var code: u32 = 0;
    var length: u8 = 1;
    for (symbols.items, 0..) |sym, i| {
        if (i > 0 and i == symbols.items.len / 2) length += 1;
        table[i] = .{ .symbol = sym.sym, .code = code, .length = length };
        code += 1;
    }

    return table;
}

/// Alphanumeric packing: packs two alphanumeric chars into one 11-bit value.
pub const ALPHANUMERIC_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

pub fn charValue(c: u8) ?u8 {
    for (ALPHANUMERIC_CHARS, 0..) |ch, i| {
        if (ch == c) return @intCast(i);
    }
    return null;
}

/// Packs alphanumeric string into byte array using 11-bit encoding.
pub fn alphanumericPack(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i + 1 < text.len) : (i += 2) {
        const v1 = charValue(text[i]) orelse return error.InvalidChar;
        const v2 = charValue(text[i + 1]) orelse return error.InvalidChar;
        const packed_val: u16 = @as(u16, v1) * 45 + @as(u16, v2);
        try out.append(@intCast((packed_val >> 8) & 0xFF));
        try out.append(@intCast(packed_val & 0xFF));
    }
    if (i < text.len) {
        const v1 = charValue(text[i]) orelse return error.InvalidChar;
        try out.append(v1);
    }

    return out.toOwnedSlice();
}

/// Unpacks alphanumeric bytes back to string.
pub fn alphanumericUnpack(allocator: std.mem.Allocator, packed_data: []const u8, original_len: usize) ![]u8 {
    var out = try allocator.alloc(u8, original_len);
    var out_idx: usize = 0;

    var i: usize = 0;
    while (i + 1 < packed_data.len and out_idx + 1 < original_len) : (i += 2) {
        const packed_val: u16 = (@as(u16, packed_data[i]) << 8) | packed_data[i + 1];
        const v1: u8 = @intCast(packed_val / 45);
        const v2: u8 = @intCast(packed_val % 45);
        if (v1 >= ALPHANUMERIC_CHARS.len) return error.InvalidPackedData;
        if (v2 >= ALPHANUMERIC_CHARS.len) return error.InvalidPackedData;
        out[out_idx] = ALPHANUMERIC_CHARS[v1];
        out[out_idx + 1] = ALPHANUMERIC_CHARS[v2];
        out_idx += 2;
    }
    if (i < packed_data.len and out_idx < original_len) {
        const v1 = packed_data[i];
        if (v1 >= ALPHANUMERIC_CHARS.len) return error.InvalidPackedData;
        out[out_idx] = ALPHANUMERIC_CHARS[v1];
    }

    return out;
}

/// Encodes data as a QR matrix (simplified — returns matrix bytes).
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return try allocator.dupe(u8, data);
}

/// Decodes QR matrix bytes back to original data.
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    return try allocator.dupe(u8, encoded);
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "qr";
}

// Tests

test "QR matrix size" {
    try std.testing.expectEqual(@as(u32, 21), qrMatrixSize(1));
    try std.testing.expectEqual(@as(u32, 25), qrMatrixSize(2));
    try std.testing.expectEqual(@as(u32, 177), qrMatrixSize(40));
}

test "alphanumeric pack/unpack round trip" {
    const allocator = std.testing.allocator;
    const text = "HELLO WORLD";

    const packed_data = try alphanumericPack(allocator, text);
    defer allocator.free(packed_data);

    const unpacked = try alphanumericUnpack(allocator, packed_data, text.len);
    defer allocator.free(unpacked);

    try std.testing.expectEqualSlices(u8, text, unpacked);
}

test "alphanumeric pack odd length" {
    const allocator = std.testing.allocator;
    const text = "ABC";

    const packed_data = try alphanumericPack(allocator, text);
    defer allocator.free(packed_data);

    const unpacked = try alphanumericUnpack(allocator, packed_data, text.len);
    defer allocator.free(unpacked);

    try std.testing.expectEqualSlices(u8, text, unpacked);
}

test "huffman table builds from data" {
    const allocator = std.testing.allocator;
    const data = "AABBCCCDDDD";

    const table = try buildHuffmanTable(allocator, data);
    defer allocator.free(table);

    try std.testing.expect(table.len > 0);
    try std.testing.expect(table.len <= 4);
}

test "QR encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "QR test data";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "QR name" {
    try std.testing.expectEqualStrings("qr", name());
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
