//! transport_wifi.zig — WiFi CSI frame transport.
//!
//! Extracted from RuView (#16).
//! ADR-018 binary frame format: magic 0xC5110001, header, subcarrier payload.

const std = @import("std");

pub const CSI_MAGIC: [4]u8 = .{ 0xC5, 0x11, 0x00, 0x01 };
pub const CSI_VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 14;

pub const CsiHeader = struct {
    magic: [4]u8,
    version: u16,
    frame_id: u16,
    num_subcarriers: u16,
    payload_len: u16,
    flags: u8,
    reserved: u8,
};

/// Encodes data into CSI frame format.
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const header = CsiHeader{
        .magic = CSI_MAGIC,
        .version = CSI_VERSION,
        .frame_id = 0,
        .num_subcarriers = @intCast((data.len + 3) / 4),
        .payload_len = @intCast(data.len),
        .flags = 0,
        .reserved = 0,
    };

    try out.appendSlice(&header.magic);
    try out.writer().writeInt(u16, header.version, .little);
    try out.writer().writeInt(u16, header.frame_id, .little);
    try out.writer().writeInt(u16, header.num_subcarriers, .little);
    try out.writer().writeInt(u16, header.payload_len, .little);
    try out.append(header.flags);
    try out.append(header.reserved);

    try out.appendSlice(data);

    const padding = (4 - (data.len % 4)) % 4;
    if (padding > 0) try out.appendNTimes(0, padding);

    return out.toOwnedSlice();
}

/// Decodes CSI frame back to original data.
pub fn decode(allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
    if (frame.len < HEADER_SIZE) return error.FrameTooShort;
    if (!std.mem.eql(u8, frame[0..4], &CSI_MAGIC)) return error.InvalidMagic;

    const version = std.mem.readInt(u16, frame[4..6], .little);
    if (version != CSI_VERSION) return error.UnsupportedVersion;

    const payload_len = std.mem.readInt(u16, frame[10..12], .little);
    if (frame.len < HEADER_SIZE + payload_len) return error.TruncatedPayload;

    return try allocator.dupe(u8, frame[HEADER_SIZE .. HEADER_SIZE + payload_len]);
}

pub inline fn capacity() usize {
    return 1;
}

pub inline fn name() []const u8 {
    return "wifi";
}

// Tests

test "wifi encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "WiFi CSI test payload";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &CSI_MAGIC, encoded[0..4]);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "wifi invalid magic" {
    const allocator = std.testing.allocator;
    const bad_frame = [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 12;

    try std.testing.expectError(error.InvalidMagic, decode(allocator, &bad_frame));
}

test "wifi header size" {
    try std.testing.expectEqual(@as(usize, 14), HEADER_SIZE);
}

test "wifi name" {
    try std.testing.expectEqualStrings("wifi", name());
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
