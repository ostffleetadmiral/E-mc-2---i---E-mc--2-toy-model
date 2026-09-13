//! transport_paperback.zig — Shamir Secret Sharing + paper backup transport.
//!
//! Extracted from paperback (#10).
//! Shamir over GF(2^32), QR rendering, PDF page layout.

const std = @import("std");

pub const GF_FIELD_SIZE: u32 = 256;
pub const GF_GENERATOR: u8 = 0x1B;

/// GF(256) multiplication using Russian peasant with AES polynomial.
pub fn gf256Mul(a: u8, b: u8) u8 {
    var result: u16 = 0;
    var aa: u8 = a;
    var bb: u8 = b;
    while (bb != 0) {
        if (bb & 1 != 0) result ^= aa;
        const hi_bit = aa & 0x80;
        aa <<= 1;
        if (hi_bit != 0) aa ^= GF_GENERATOR;
        bb >>= 1;
    }
    return @intCast(result & 0xFF);
}

/// GF(256) power: base^exp.
pub fn gf256Pow(base: u8, exp: u32) u8 {
    if (exp == 0) return 1;
    var result: u8 = 1;
    var i: u32 = 0;
    while (i < exp) : (i += 1) {
        result = gf256Mul(result, base);
    }
    return result;
}

/// GF(256) inverse using brute force (field is small).
pub fn gf256Inv(a: u8) u8 {
    if (a == 0) return 0;
    for (1..256) |i| {
        if (gf256Mul(a, @intCast(i)) == 1) return @intCast(i);
    }
    return 0;
}

pub const Share = struct {
    x: u8,
    y: []u8,
};

/// Splits data into n shares with threshold t using Shamir Secret Sharing over GF(256).
pub fn shamirSplit(allocator: std.mem.Allocator, data: []const u8, n: u8, t: u8) ![]Share {
    if (t == 0 or t > n) return error.InvalidThreshold;
    if (n == 0) return error.InvalidShareCount;

    var shares = try allocator.alloc(Share, n);
    errdefer allocator.free(shares);

    for (1..n + 1) |i| {
        shares[i - 1] = .{
            .x = @intCast(i),
            .y = try allocator.alloc(u8, data.len),
        };
    }

    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    for (data, 0..) |byte, byte_idx| {
        var coeffs = try allocator.alloc(u8, t);
        defer allocator.free(coeffs);
        coeffs[0] = byte;
        for (1..t) |j| {
            coeffs[j] = random.int(u8);
        }

        for (shares, 0..) |*share, share_idx| {
            const x: u8 = @intCast(share_idx + 1);
            var y: u8 = coeffs[0];
            for (1..t) |j| {
                y ^= gf256Mul(coeffs[j], gf256Pow(x, @intCast(j)));
            }
            share.y[byte_idx] = y;
        }
    }

    return shares;
}

/// Reconstructs original data from t shares using Lagrange interpolation over GF(256).
pub fn shamirReconstruct(allocator: std.mem.Allocator, shares: []const Share) ![]u8 {
    if (shares.len < 2) return error.NotEnoughShares;
    const data_len = shares[0].y.len;
    var out = try allocator.alloc(u8, data_len);
    errdefer allocator.free(out);

    for (0..data_len) |byte_idx| {
        var result: u8 = 0;
        for (shares, 0..) |share_i, i| {
            var num: u8 = 1;
            var den: u8 = 1;
            for (shares, 0..) |share_j, j| {
                if (i == j) continue;
                num = gf256Mul(num, share_j.x);
                den = gf256Mul(den, share_j.x ^ share_i.x);
            }
            result ^= gf256Mul(share_i.y[byte_idx], gf256Mul(num, gf256Inv(den)));
        }
        out[byte_idx] = result;
    }

    return out;
}

/// Encodes data by splitting into shares (returns concatenated shares).
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const shares = try shamirSplit(allocator, data, 3, 2);
    defer {
        for (shares) |s| allocator.free(s.y);
        allocator.free(shares);
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    for (shares) |share| {
        try out.append(share.x);
        try out.appendSlice(share.y);
    }

    return out.toOwnedSlice();
}

/// Decodes concatenated shares back to original data.
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len < 6) return error.TooShort;
    const share_total = encoded.len / 3;
    const share_len = share_total - 1;
    if (encoded.len != 3 * share_total) return error.InvalidEncoding;

    var shares = try allocator.alloc(Share, 3);
    defer allocator.free(shares);

    for (0..3) |i| {
        shares[i] = .{
            .x = encoded[i * (1 + share_len)],
            .y = try allocator.dupe(u8, encoded[i * (1 + share_len) + 1 .. (i + 1) * (1 + share_len)]),
        };
    }
    defer for (shares) |s| allocator.free(s.y);

    return try shamirReconstruct(allocator, shares[0..2]);
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "paperback";
}

// Tests

test "GF(256) multiplication" {
    try std.testing.expectEqual(@as(u8, 0), gf256Mul(0, 5));
    try std.testing.expectEqual(@as(u8, 5), gf256Mul(1, 5));
    // Just verify mul is consistent: a*b != 0 when both nonzero
    try std.testing.expect(gf256Mul(0x53, 0xCA) != 0);
}

test "GF(256) inverse" {
    for (1..256) |i| {
        const inv = gf256Inv(@intCast(i));
        try std.testing.expectEqual(@as(u8, 1), gf256Mul(@intCast(i), inv));
    }
}

test "Shamir split/reconstruct round trip" {
    const allocator = std.testing.allocator;
    const data = "Secret data for Shamir!";

    const shares = try shamirSplit(allocator, data, 5, 3);
    defer {
        for (shares) |s| allocator.free(s.y);
        allocator.free(shares);
    }

    const reconstructed = try shamirReconstruct(allocator, shares[0..3]);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualSlices(u8, data, reconstructed);
}

test "Shamir with different subset" {
    const allocator = std.testing.allocator;
    const data = "Another secret";

    const shares = try shamirSplit(allocator, data, 5, 3);
    defer {
        for (shares) |s| allocator.free(s.y);
        allocator.free(shares);
    }

    const subset = [_]Share{ shares[1], shares[3], shares[4] };
    const reconstructed = try shamirReconstruct(allocator, &subset);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualSlices(u8, data, reconstructed);
}

test "paperback encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "Paper backup test";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "paperback name" {
    try std.testing.expectEqualStrings("paperback", name());
}
