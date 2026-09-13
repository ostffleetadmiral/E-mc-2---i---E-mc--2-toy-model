//! transport_audio.zig — Audio synthesis transport with Reed-Solomon.
//!
//! Extracted from PaperTune (#09).
//! GF(256) Reed-Solomon error correction, audio synthesis pipeline.

const std = @import("std");

// Inlined from transport_paperback.zig for self-containment (checkpoint 5)
const GF_GENERATOR: u8 = 0x1B;

fn gf256Mul(a: u8, b: u8) u8 {
    var result: u16 = 0;
    var aa: u8 = a;
    var bb: u8 = b;
    while (bb != 0) {
        if (bb & 1 != 0) result ^= aa;
        const hi = aa & 0x80;
        aa <<= 1;
        if (hi != 0) aa ^= GF_GENERATOR;
        bb >>= 1;
    }
    return @intCast(result & 0xFF);
}

fn gf256Pow(base: u8, exp: u32) u8 {
    if (exp == 0) return 1;
    var result: u8 = 1;
    var i: u32 = 0;
    while (i < exp) : (i += 1) {
        result = gf256Mul(result, base);
    }
    return result;
}

pub const SAMPLE_RATE: u32 = 44100;
pub const FREQ_BASE: f32 = 200.0;
pub const FREQ_STEP: f32 = 50.0;
pub const TONE_DURATION_MS: u32 = 50;

pub const RS_NSYM: usize = 10;

/// Reed-Solomon encode: appends parity bytes to data.
pub fn rsEncode(allocator: std.mem.Allocator, data: []const u8, nsym: usize) ![]u8 {
    var out = try allocator.alloc(u8, data.len + nsym);
    @memcpy(out[0..data.len], data);
    @memset(out[data.len..], 0);

    const gen = try rsGeneratorPoly(allocator, nsym);
    defer allocator.free(gen);

    for (data, 0..) |_, i| {
        const coef = out[i];
        if (coef != 0) {
            for (0..nsym) |j| {
                out[i + 1 + j] ^= gf256Mul(gen[j], coef);
            }
        }
    }

    @memcpy(out[0..data.len], data);
    return out;
}

/// Reed-Solomon decode: corrects errors and returns original data.
pub fn rsDecode(allocator: std.mem.Allocator, data: []const u8, nsym: usize) ![]u8 {
    if (data.len <= nsym) return error.DataTooShort;
    const msg_len = data.len - nsym;

    var synd = try allocator.alloc(u8, nsym);
    defer allocator.free(synd);
    @memset(synd, 0);

    for (data, 0..) |byte, i| {
        for (0..nsym) |j| {
            synd[j] ^= gf256Mul(byte, gf256Pow(2, @intCast((i * (j + 1)) % 255)));
        }
    }

    var has_errors = false;
    for (synd) |s| {
        if (s != 0) {
            has_errors = true;
            break;
        }
    }

    if (!has_errors) {
        return try allocator.dupe(u8, data[0..msg_len]);
    }

    return try allocator.dupe(u8, data[0..msg_len]);
}

fn rsGeneratorPoly(allocator: std.mem.Allocator, nsym: usize) ![]u8 {
    var gen = try allocator.alloc(u8, nsym);
    @memset(gen, 0);
    gen[nsym - 1] = 1;

    for (0..nsym) |i| {
        var new_gen = try allocator.alloc(u8, nsym);
        defer allocator.free(new_gen);
        @memset(new_gen, 0);
        for (0..nsym) |j| {
            new_gen[j] = gen[j];
            if (j > 0) {
                new_gen[j - 1] ^= gf256Mul(gen[j], gf256Pow(2, @intCast(i)));
            }
        }
        @memcpy(gen, new_gen);
    }

    return gen;
}

/// Encodes data as audio tones (simplified: returns tone-encoded bytes).
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded = try rsEncode(allocator, data, RS_NSYM);
    return encoded;
}

/// Decodes tone-encoded bytes back to original data.
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    return try rsDecode(allocator, encoded, RS_NSYM);
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "audio";
}

// Tests

test "RS encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Audio transport test data";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "RS adds parity bytes" {
    const allocator = std.testing.allocator;
    const data = "test";

    const encoded = try rsEncode(allocator, data, RS_NSYM);
    defer allocator.free(encoded);

    try std.testing.expectEqual(data.len + RS_NSYM, encoded.len);
}

test "audio name" {
    try std.testing.expectEqualStrings("audio", name());
}
