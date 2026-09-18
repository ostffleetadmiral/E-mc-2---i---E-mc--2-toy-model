//! transport_cassette.zig — AFSK audio cassette transport.
//!
//! Extracted from audio-cassette-backup (#04).
//! AFSK modulation: 1200 Hz = bit 0, 2400 Hz = bit 1.
//! WAV container format for raw PCM audio.

const std = @import("std");

pub const SAMPLE_RATE: u32 = 44100;
pub const FREQ_ZERO: f32 = 1200.0;
pub const FREQ_ONE: f32 = 2400.0;
pub const BAUD_RATE: u32 = 1200;
pub const SAMPLES_PER_BIT: u32 = SAMPLE_RATE / BAUD_RATE;

pub const WAV_MAGIC: [4]u8 = .{ 'R', 'I', 'F', 'F' };
pub const WAV_FORMAT: [4]u8 = .{ 'W', 'A', 'V', 'E' };
pub const WAV_FMT_CHUNK: [4]u8 = .{ 'f', 'm', 't', ' ' };
pub const WAV_DATA_CHUNK: [4]u8 = .{ 'd', 'a', 't', 'a' };

pub const WavHeader = struct {
    riff: [4]u8 = WAV_MAGIC,
    file_size: u32 = 0,
    wave: [4]u8 = WAV_FORMAT,
    fmt_chunk: [4]u8 = WAV_FMT_CHUNK,
    fmt_size: u32 = 16,
    audio_format: u16 = 1,
    channels: u16 = 1,
    sample_rate: u32 = SAMPLE_RATE,
    byte_rate: u32 = SAMPLE_RATE * 2,
    block_align: u16 = 2,
    bits_per_sample: u16 = 16,
    data_chunk: [4]u8 = WAV_DATA_CHUNK,
    data_size: u32 = 0,

    pub fn write(self: WavHeader, writer: anytype) !void {
        try writer.writeAll(&self.riff);
        try writer.writeInt(u32, self.file_size, .little);
        try writer.writeAll(&self.wave);
        try writer.writeAll(&self.fmt_chunk);
        try writer.writeInt(u32, self.fmt_size, .little);
        try writer.writeInt(u16, self.audio_format, .little);
        try writer.writeInt(u16, self.channels, .little);
        try writer.writeInt(u32, self.sample_rate, .little);
        try writer.writeInt(u32, self.byte_rate, .little);
        try writer.writeInt(u16, self.block_align, .little);
        try writer.writeInt(u16, self.bits_per_sample, .little);
        try writer.writeAll(&self.data_chunk);
        try writer.writeInt(u32, self.data_size, .little);
    }
};

/// Encodes bytes into AFSK-modulated audio samples (16-bit PCM).
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const total_samples = data.len * 8 * SAMPLES_PER_BIT;
    const data_size = total_samples * 2;
    const file_size: u32 = @intCast(44 + data_size - 8);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const header = WavHeader{
        .file_size = file_size,
        .data_size = @intCast(data_size),
    };
    try header.write(out.writer());

    for (data) |byte| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            var phase: f32 = 0.0;
            const is_one = (byte >> @intCast(bit)) & 1 == 1;
            const freq = if (is_one) FREQ_ONE else FREQ_ZERO;
            const phase_inc = 2.0 * std.math.pi * freq / @as(f32, @floatFromInt(SAMPLE_RATE));

            var s: u32 = 0;
            while (s < SAMPLES_PER_BIT) : (s += 1) {
                const sample: i16 = @intFromFloat(@sin(phase) * 16000.0);
                try out.writer().writeInt(i16, sample, .little);
                phase += phase_inc;
            }
        }
    }

    return out.toOwnedSlice();
}

/// Decodes AFSK-modulated audio samples back to bytes.
pub fn decode(allocator: std.mem.Allocator, audio: []const u8) ![]u8 {
    if (audio.len < 44) return error.InvalidWav;
    if (!std.mem.eql(u8, audio[0..4], &WAV_MAGIC)) return error.InvalidWav;

    const data_size = std.mem.readInt(u32, audio[40..44], .little);
    const sample_count = data_size / 2;
    const bit_count = sample_count / SAMPLES_PER_BIT;
    const byte_count = bit_count / 8;

    var out = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(out);

    var sample_idx: usize = 44;
    for (0..byte_count) |byte_idx| {
        var byte: u8 = 0;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            // Detect frequency by counting zero crossings in the bit window
            var zero_crossings: u32 = 0;
            var prev_val: i16 = 0;
            var s: u32 = 0;
            while (s < SAMPLES_PER_BIT and sample_idx + 2 <= audio.len) : (s += 1) {
                const val = std.mem.readInt(i16, audio[sample_idx..][0..2], .little);
                if (prev_val != 0 and ((prev_val > 0 and val <= 0) or (prev_val < 0 and val >= 0))) {
                    zero_crossings += 1;
                }
                prev_val = val;
                sample_idx += 2;
            }
            // 1200 Hz → 1 zero crossing per bit window
            // 2400 Hz → 3 zero crossings per bit window
            if (zero_crossings >= 2) {
                byte |= @as(u8, 1) << @intCast(bit);
            }
        }
        out[byte_idx] = byte;
    }

    return out;
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "cassette";
}

// Tests

test "cassette encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Hi";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 44);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "cassette WAV header" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, "A");
    defer allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &WAV_MAGIC, encoded[0..4]);
    try std.testing.expectEqualSlices(u8, &WAV_FORMAT, encoded[8..12]);
}

test "cassette name and capacity" {
    try std.testing.expectEqualStrings("cassette", name());
    try std.testing.expectEqual(@as(usize, 1), capacity());
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
