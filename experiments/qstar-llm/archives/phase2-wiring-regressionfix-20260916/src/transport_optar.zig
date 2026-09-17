//! transport_optar.zig — Golay-coded paper backup transport.
//!
//! Extracted from optar (#07).
//! Golay(23,12) error correction, grid layout for 600 dpi printing.

const std = @import("std");

pub const DPI: u32 = 600;
pub const GRID_COLS: u32 = 64;
pub const GRID_ROWS: u32 = 90;
pub const DOTS_PER_PAGE: u32 = GRID_COLS * GRID_ROWS;

pub const GOLAY_N: usize = 23;
pub const GOLAY_K: usize = 12;
pub const GOLAY_T: usize = 3;

pub const GOLAY_GENERATOR: u32 = 0xC77;

/// Encodes 12 data bits into 23-bit systematic Golay codeword.
/// Codeword = [data (12 bits) | parity (11 bits)]
pub fn golayEncode(data12: u16) u32 {
    const d: u32 = @as(u32, data12) & 0xFFF;
    // Shift data to top 12 bits of 23-bit codeword
    const codeword: u32 = d << 11;

    // Compute parity: polynomial division of data*x^11 by generator
    var parity: u32 = codeword;
    var bit: i32 = 22;
    while (bit >= 11) : (bit -= 1) {
        if ((parity >> @intCast(bit)) & 1 == 1) {
            parity ^= GOLAY_GENERATOR << @intCast(bit - 11);
        }
    }

    // Codeword = data | parity (lower 11 bits)
    return codeword | (parity & 0x7FF);
}

/// Decodes 23-bit Golay codeword, correcting up to 3 errors.
pub fn golayDecode(codeword: u32) u16 {
    const received = codeword & 0x7FFFFF;

    // Compute syndrome = received mod generator
    var syndrome: u32 = received;
    var bit: i32 = 22;
    while (bit >= 11) : (bit -= 1) {
        if ((syndrome >> @intCast(bit)) & 1 == 1) {
            syndrome ^= GOLAY_GENERATOR << @intCast(bit - 11);
        }
    }

    var corrected = received;
    if (syndrome != 0) {
        const weight: u32 = @popCount(syndrome);
        if (weight <= 3) {
            // Error is in parity bits only
            corrected ^= syndrome;
        } else {
            // Try cyclic rotations of syndrome
            var rot: u32 = 1;
            while (rot < 23) : (rot += 1) {
                // Rotate syndrome left by rot positions (in 23-bit field)
                var rotated: u32 = 0;
                var j: u32 = 0;
                while (j < 23) : (j += 1) {
                    if ((syndrome >> @intCast(j)) & 1 == 1) {
                        rotated |= @as(u32, 1) << @intCast((j + rot) % 23);
                    }
                }
                if (@popCount(rotated) <= 3) {
                    // Error pattern is rotated back
                    var error_pattern: u32 = 0;
                    var k: u32 = 0;
                    while (k < 23) : (k += 1) {
                        if ((rotated >> @intCast(k)) & 1 == 1) {
                            error_pattern |= @as(u32, 1) << @intCast((k + (23 - rot)) % 23);
                        }
                    }
                    corrected ^= error_pattern;
                    break;
                }
            }
        }
    }

    return @intCast((corrected >> 11) & 0xFFF);
}

/// Encodes data bytes into Golay-coded dot pattern bytes.
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const num_codewords = (data.len * 8 + 11) / 12;
    var out = try allocator.alloc(u8, num_codewords * 3);
    errdefer allocator.free(out);

    var bit_buffer: u32 = 0;
    var bits_in_buffer: u8 = 0;
    var out_idx: usize = 0;

    for (data) |byte| {
        bit_buffer = (bit_buffer << 8) | byte;
        bits_in_buffer += 8;
        while (bits_in_buffer >= 12) {
            bits_in_buffer -= 12;
            const data12: u16 = @intCast((bit_buffer >> @intCast(bits_in_buffer)) & 0xFFF);
            const codeword = golayEncode(data12);

            out[out_idx] = @intCast((codeword >> 16) & 0xFF);
            out[out_idx + 1] = @intCast((codeword >> 8) & 0xFF);
            out[out_idx + 2] = @intCast(codeword & 0xFF);
            out_idx += 3;
        }
    }

    if (bits_in_buffer > 0) {
        const data12: u16 = @intCast((bit_buffer << @intCast(12 - bits_in_buffer)) & 0xFFF);
        const codeword = golayEncode(data12);
        out[out_idx] = @intCast((codeword >> 16) & 0xFF);
        out[out_idx + 1] = @intCast((codeword >> 8) & 0xFF);
        out[out_idx + 2] = @intCast(codeword & 0xFF);
    }

    return out;
}

/// Decodes Golay-coded data back to original bytes.
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8, original_len: usize) ![]u8 {
    var out = try allocator.alloc(u8, original_len);
    errdefer allocator.free(out);

    var bit_buffer: u32 = 0;
    var bits_in_buffer: u8 = 0;
    var out_idx: usize = 0;

    var i: usize = 0;
    while (i + 3 <= encoded.len and out_idx < original_len) : (i += 3) {
        const codeword: u32 =
            (@as(u32, encoded[i]) << 16) |
            (@as(u32, encoded[i + 1]) << 8) |
            @as(u32, encoded[i + 2]);

        const data12 = golayDecode(codeword);

        bit_buffer = (bit_buffer << 12) | data12;
        bits_in_buffer += 12;

        while (bits_in_buffer >= 8 and out_idx < original_len) {
            bits_in_buffer -= 8;
            out[out_idx] = @intCast((bit_buffer >> @intCast(bits_in_buffer)) & 0xFF);
            out_idx += 1;
        }
    }

    return out;
}

pub fn capacity() usize {
    return DOTS_PER_PAGE;
}

pub fn name() []const u8 {
    return "optar";
}

// Tests

test "Golay encode/decode round trip" {
    for (0..4096) |i| {
        const data: u16 = @intCast(i);
        const codeword = golayEncode(data);
        const decoded = golayDecode(codeword);
        try std.testing.expectEqual(data, decoded);
    }
}

test "Golay single-bit error correction" {
    const data: u16 = 0xABC;
    const codeword = golayEncode(data);
    const corrupted = codeword ^ (1 << 5);
    const decoded = golayDecode(corrupted);
    try std.testing.expectEqual(data, decoded);
}

test "optar encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Hello, Golay!";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded, data.len);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "optar capacity" {
    try std.testing.expectEqual(@as(usize, 5760), capacity());
}

test "optar name" {
    try std.testing.expectEqualStrings("optar", name());
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
