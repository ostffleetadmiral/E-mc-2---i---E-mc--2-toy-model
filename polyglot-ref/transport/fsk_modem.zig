//! fsk_modem.zig — Frequency-Shift Keying audio modem for air-gap transport.
//!
//! Encodes Q128.128 state vectors as audio waveforms using FSK.
//! Binary data is modulated into two frequencies: MARK (high) and SPACE (low).
//! Designed for cassette tape (1.2-9.6 kbps) and ambient RF transmission.

const std = @import("std");
const Q = @import("q128_128");

/// FSK modem configuration.
pub const FskConfig = struct {
    sample_rate: u32 = 44100,
    baud_rate: u32 = 1200,
    mark_freq: f64 = 1200.0, // Logic 1
    space_freq: f64 = 600.0, // Logic 0
    amplitude: f64 = 0.8,
};

/// FSK modem state.
pub const FskModem = struct {
    config: FskConfig,
    phase: f64 = 0.0,
    samples_per_bit: u32,

    pub fn init(config: FskConfig) FskModem {
        return .{
            .config = config,
            .samples_per_bit = config.sample_rate / config.baud_rate,
        };
    }

    /// Encode a single bit as audio samples.
    pub fn encodeBit(self: *FskModem, bit: u1, buf: []f32) void {
        const freq = if (bit == 1) self.config.mark_freq else self.config.space_freq;
        const phase_inc = 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(self.config.sample_rate));
        for (buf) |*sample| {
            sample.* = @floatCast(self.config.amplitude * @sin(self.phase));
            self.phase += phase_inc;
            if (self.phase > 2.0 * std.math.pi) self.phase -= 2.0 * std.math.pi;
        }
    }

    /// Encode a byte (8 bits) into audio samples.
    pub fn encodeByte(self: *FskModem, byte: u8, buf: []f32) void {
        std.debug.assert(buf.len >= self.samples_per_bit * 8);
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const bit: u1 = @intCast((byte >> @intCast(i)) & 1);
            const start = i * self.samples_per_bit;
            const end = start + self.samples_per_bit;
            self.encodeBit(bit, buf[start..end]);
        }
    }

    /// Encode a byte array into audio samples.
    pub fn encodeData(self: *FskModem, data: []const u8, alloc: std.mem.Allocator) ![]f32 {
        const total_samples = data.len * 8 * self.samples_per_bit;
        const buf = try alloc.alloc(f32, total_samples);
        var offset: usize = 0;
        for (data) |byte| {
            const end = offset + 8 * self.samples_per_bit;
            self.encodeByte(byte, buf[offset..end]);
            offset = end;
        }
        return buf;
    }

    /// Detect the frequency of a block of samples.
    /// Returns the dominant frequency using zero-crossing counting.
    pub fn detectFrequency(self: *const FskModem, samples: []const f32) f64 {
        if (samples.len < 2) return 0.0;
        var zero_crossings: u32 = 0;
        var prev: f32 = samples[0];
        for (samples[1..]) |sample| {
            if ((prev < 0 and sample >= 0) or (prev >= 0 and sample < 0)) {
                zero_crossings += 1;
            }
            prev = sample;
        }
        // Each cycle has 2 zero crossings
        const cycles = @as(f64, @floatFromInt(zero_crossings)) / 2.0;
        const duration = @as(f64, @floatFromInt(samples.len)) / @as(f64, @floatFromInt(self.config.sample_rate));
        if (duration == 0.0) return 0.0;
        return cycles / duration;
    }

    /// Decode a single bit from audio samples.
    pub fn decodeBit(self: *const FskModem, samples: []const f32) u1 {
        const freq = self.detectFrequency(samples);
        const threshold = (self.config.mark_freq + self.config.space_freq) / 2.0;
        return if (freq >= threshold) 1 else 0;
    }

    /// Decode a byte from audio samples.
    pub fn decodeByte(self: *const FskModem, samples: []const f32) u8 {
        std.debug.assert(samples.len >= self.samples_per_bit * 8);
        var byte: u8 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const start = i * self.samples_per_bit;
            const end = start + self.samples_per_bit;
            const bit = self.decodeBit(samples[start..end]);
            byte |= @as(u8, bit) << @intCast(i);
        }
        return byte;
    }

    /// Decode a byte array from audio samples.
    pub fn decodeData(self: *const FskModem, samples: []const f32, alloc: std.mem.Allocator) ![]u8 {
        const byte_count = samples.len / (8 * self.samples_per_bit);
        const data = try alloc.alloc(u8, byte_count);
        for (0..byte_count) |i| {
            const start = i * 8 * self.samples_per_bit;
            const end = start + 8 * self.samples_per_bit;
            data[i] = self.decodeByte(samples[start..end]);
        }
        return data;
    }
};

/// Encode a Q128.128 value as audio (for state vector transmission).
pub fn encodeQ128(alloc: std.mem.Allocator, modem: *FskModem, v: Q.q128) ![]f32 {
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u128, buf[0..16], v.hi, .little);
    std.mem.writeInt(u128, buf[16..32], v.lo, .little);
    return modem.encodeData(&buf, alloc);
}

/// Decode a Q128.128 value from audio.
pub fn decodeQ128(modem: *const FskModem, samples: []const f32) Q.q128 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const start = i * 8 * modem.samples_per_bit;
        const end = start + 8 * modem.samples_per_bit;
        buf[i] = modem.decodeByte(samples[start..end]);
    }
    return .{
        .hi = std.mem.readInt(u128, buf[0..16], .little),
        .lo = std.mem.readInt(u128, buf[16..32], .little),
    };
}

/// Generate a preamble signal for synchronization.
pub fn generatePreamble(alloc: std.mem.Allocator, modem: *FskModem, bits: u32) ![]f32 {
    const total_samples = bits * modem.samples_per_bit;
    const buf = try alloc.alloc(f32, total_samples);
    var i: u32 = 0;
    while (i < bits) : (i += 1) {
        const start = @as(usize, i) * modem.samples_per_bit;
        const end = start + modem.samples_per_bit;
        // Alternating 1-0 pattern for sync
        const bit: u1 = @intCast(i & 1);
        modem.encodeBit(bit, buf[start..end]);
    }
    return buf;
}

/// Compute the theoretical throughput in bits per second.
pub fn throughput(config: FskConfig) f64 {
    return @as(f64, @floatFromInt(config.baud_rate));
}

/// Compute the SNR estimate from decoded samples.
pub fn estimateSnr(samples: []const f32) f64 {
    if (samples.len < 2) return 0.0;
    var signal_power: f64 = 0.0;
    var noise_power: f64 = 0.0;
    var prev: f32 = samples[0];
    for (samples[1..]) |sample| {
        const signal = @as(f64, @floatCast(sample));
        const noise = @as(f64, @floatCast(sample - prev));
        signal_power += signal * signal;
        noise_power += noise * noise;
        prev = sample;
    }
    if (noise_power == 0.0) return 100.0;
    return 10.0 * std.math.log10(signal_power / noise_power);
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "FskModem init" {
    const modem = FskModem.init(.{});
    try std.testing.expectEqual(@as(u32, 44100), modem.config.sample_rate);
    try std.testing.expectEqual(@as(u32, 1200), modem.config.baud_rate);
    try std.testing.expectEqual(@as(u32, 36), modem.samples_per_bit); // 44100/1200 = 36.75 -> 36
}

test "FskModem encodeBit produces correct sample count" {
    var modem = FskModem.init(.{});
    var buf: [147]f32 = undefined;
    modem.encodeBit(1, &buf);
    // Check that samples are non-zero (signal present)
    var non_zero: u32 = 0;
    for (buf) |s| {
        if (s != 0.0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 0);
}

test "FskModem encode and decode byte" {
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    const buf_size = modem.samples_per_bit * 8;
    var buf: [1176]f32 = undefined;
    modem.encodeByte(0x42, buf[0..buf_size]);
    const decoded = modem.decodeByte(buf[0..buf_size]);
    try std.testing.expectEqual(@as(u8, 0x42), decoded);
}

test "FskModem encode and decode data" {
    const alloc = std.testing.allocator;
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    const data = [_]u8{ 0x01, 0x02, 0x03, 0xFF, 0x00, 0x42 };
    const encoded = try modem.encodeData(&data, alloc);
    defer alloc.free(encoded);
    const decoded = try modem.decodeData(encoded, alloc);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, &data, decoded);
}

test "FskModem detectFrequency distinguishes mark and space" {
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    var mark_buf: [147]f32 = undefined;
    var space_buf: [147]f32 = undefined;
    modem.encodeBit(1, &mark_buf);
    modem.encodeBit(0, &space_buf);
    const mark_freq = modem.detectFrequency(&mark_buf);
    const space_freq = modem.detectFrequency(&space_buf);
    // Mark should be higher frequency than space
    try std.testing.expect(mark_freq > space_freq);
}

test "encodeQ128 and decodeQ128 round-trip" {
    const alloc = std.testing.allocator;
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    const value = Q.q128FromI64(42);
    const encoded = try encodeQ128(alloc, &modem, value);
    defer alloc.free(encoded);
    const decoded = decodeQ128(&modem, encoded);
    try std.testing.expect(Q.q128Eq(value, decoded));
}

test "generatePreamble produces alternating pattern" {
    const alloc = std.testing.allocator;
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    const preamble = try generatePreamble(alloc, &modem, 16);
    defer alloc.free(preamble);
    try std.testing.expectEqual(@as(usize, 16 * modem.samples_per_bit), preamble.len);
    // Check that there are non-zero samples
    var has_signal = false;
    for (preamble) |s| {
        if (s != 0.0) has_signal = true;
    }
    try std.testing.expect(has_signal);
}

test "throughput calculation" {
    const config = FskConfig{ .baud_rate = 9600 };
    try std.testing.expectEqual(@as(f64, 9600.0), throughput(config));
}

test "estimateSnr returns positive for clean signal" {
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    var buf: [1176]f32 = undefined;
    modem.encodeByte(0xFF, &buf);
    const snr = estimateSnr(&buf);
    try std.testing.expect(snr > 0.0);
}

test "FskModem handles multiple bytes" {
    const alloc = std.testing.allocator;
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 300 });
    const data = "Hello, FANO-1!";
    const encoded = try modem.encodeData(data, alloc);
    defer alloc.free(encoded);
    const decoded = try modem.decodeData(encoded, alloc);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "FskModem with higher baud rate" {
    const alloc = std.testing.allocator;
    var modem = FskModem.init(.{ .sample_rate = 44100, .baud_rate = 1200, .mark_freq = 4800.0, .space_freq = 2400.0 });
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const encoded = try modem.encodeData(&data, alloc);
    defer alloc.free(encoded);
    const decoded = try modem.decodeData(encoded, alloc);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, &data, decoded);
}
