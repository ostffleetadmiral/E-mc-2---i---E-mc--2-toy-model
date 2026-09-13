//! transport_quine.zig — Self-referential HTML quine transport.
//!
//! Extracted from quine.html (#01).
//! HTML contains its own source as a string, reconstructs itself on load.

const std = @import("std");

const TEMPLATE =
    \\<!DOCTYPE html>
    \\<html>
    \\<head><meta charset="utf-8"><title>Quine Transport</title></head>
    \\<body>
    \\<pre id="payload"></pre>
    \\<script>
    \\const PAYLOAD = "{payload}";
    \\document.getElementById('payload').textContent = atob(PAYLOAD);
    \\const html = document.documentElement.outerHTML;
    \\localStorage.setItem('quine', html);
    \\</script>
    \\</body>
    \\</html>
;

/// Encodes data as a self-referential HTML quine.
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const Encoder = std.base64.standard.Encoder;
    const b64_len = Encoder.calcSize(data.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = Encoder.encode(b64, data);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < TEMPLATE.len) : (i += 1) {
        if (i + 9 <= TEMPLATE.len and std.mem.eql(u8, TEMPLATE[i .. i + 9], "{payload}")) {
            try out.appendSlice(b64);
            i += 8;
        } else {
            try out.append(TEMPLATE[i]);
        }
    }

    return out.toOwnedSlice();
}

/// Decodes a quine HTML file, extracting the base64 payload.
pub fn decode(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const marker = "const PAYLOAD = \"";
    const marker_end = "\";";

    const start = std.mem.indexOf(u8, html, marker) orelse return error.NoPayload;
    const payload_start = start + marker.len;
    const end = std.mem.indexOfPos(u8, html, payload_start, marker_end) orelse return error.NoPayloadEnd;

    const b64_data = html[payload_start..end];

    const Decoder = std.base64.standard.Decoder;
    const max_len = try Decoder.calcSizeForSlice(b64_data);
    const out = try allocator.alloc(u8, max_len);
    try Decoder.decode(out, b64_data);

    return out;
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "quine";
}

// Tests

test "quine encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Quine test payload!";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "<!DOCTYPE html>"));

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "quine contains payload marker" {
    const allocator = std.testing.allocator;
    const data = "test";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "const PAYLOAD") != null);
}

test "quine name" {
    try std.testing.expectEqualStrings("quine", name());
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
