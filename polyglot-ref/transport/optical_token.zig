//! optical_token.zig — Hyper-compressed URL-less routing tokens.
//!
//! Encodes state vectors into <100 byte optical tokens that can be
//! rendered as QR codes or Paper Tunes visual waveforms. Tokens are
//! self-contained: no database lookup needed to boot a node.

const std = @import("std");
const Q = @import("q128_128");

/// Token type.
pub const TokenType = enum(u4) {
    boot = 0, // Boot a new node
    sync = 1, // Sync state between nodes
    contract = 2, // Deploy a contract
    message = 3, // Encrypted message
    payment = 4, // Payment authorization
};

/// Serialized token (max 100 bytes, stack-safe).
pub const SerializedToken = struct {
    data: [100]u8 = [_]u8{0} ** 100,
    len: usize = 0,

    pub fn slice(self: *const SerializedToken) []const u8 {
        return self.data[0..self.len];
    }
};

/// Optical token (max 100 bytes).
pub const OpticalToken = struct {
    version: u4 = 1,
    token_type: TokenType,
    flags: u4 = 0,
    timestamp: u32,
    payload_hash: [16]u8, // Blake2b-128
    payload: []const u8, // Compressed payload (max 78 bytes after header)

    /// Serialize to a stack-safe bounded buffer.
    pub fn serialize(self: OpticalToken) SerializedToken {
        var st = SerializedToken{};
        st.data[0] = (@as(u8, self.version) << 4) | @as(u8, @intFromEnum(self.token_type));
        st.data[1] = self.flags;
        std.mem.writeInt(u32, st.data[2..6], self.timestamp, .little);
        @memcpy(st.data[6..22], &self.payload_hash);
        const payload_len = @min(self.payload.len, 78);
        @memcpy(st.data[22..][0..payload_len], self.payload[0..payload_len]);
        st.len = 22 + payload_len;
        return st;
    }

    /// Deserialize from bytes.
    pub fn deserialize(buf: []const u8) !OpticalToken {
        if (buf.len < 22) return error.TokenTooShort;
        if (buf.len > 100) return error.TokenTooLong;
        const version = buf[0] >> 4;
        if (version != 1) return error.UnsupportedVersion;
        const token_type: TokenType = @enumFromInt(buf[0] & 0x0F);
        const flags = buf[1];
        const timestamp = std.mem.readInt(u32, buf[2..6], .little);
        var payload_hash: [16]u8 = undefined;
        @memcpy(&payload_hash, buf[6..22]);
        const payload = buf[22..];
        return .{
            .version = @truncate(version),
            .token_type = token_type,
            .flags = @truncate(flags),
            .timestamp = timestamp,
            .payload_hash = payload_hash,
            .payload = payload,
        };
    }

    /// Compute the token hash (Blake2b-128).
    pub fn hash(self: OpticalToken) [16]u8 {
        const st = self.serialize();
        var h: [16]u8 = undefined;
        std.crypto.hash.blake2.Blake2b128.hash(st.slice(), &h, .{});
        return h;
    }

    /// Verify payload integrity.
    pub fn verify(self: OpticalToken) bool {
        var h: [16]u8 = undefined;
        std.crypto.hash.blake2.Blake2b128.hash(self.payload, &h, .{});
        return std.mem.eql(u8, &h, &self.payload_hash);
    }
};

/// Create a boot token for a new node.
/// Caller must keep node_id alive for the token's lifetime.
pub fn createBootToken(node_id: *const [16]u8, timestamp: u32) OpticalToken {
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(node_id, &payload_hash, .{});
    return .{
        .token_type = .boot,
        .timestamp = timestamp,
        .payload_hash = payload_hash,
        .payload = node_id,
    };
}

/// Create a sync token for state synchronization.
/// Caller must keep state_hash alive for the token's lifetime.
pub fn createSyncToken(state_hash: *const [16]u8, timestamp: u32) OpticalToken {
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(state_hash, &payload_hash, .{});
    return .{
        .token_type = .sync,
        .timestamp = timestamp,
        .payload_hash = payload_hash,
        .payload = state_hash,
    };
}

/// Encode a Q128.128 value into a compact token payload.
pub fn encodeQ128Payload(v: Q.q128) [32]u8 {
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u128, buf[0..16], v.hi, .little);
    std.mem.writeInt(u128, buf[16..32], v.lo, .little);
    return buf;
}

/// Decode a Q128.128 value from a token payload.
pub fn decodeQ128Payload(payload: []const u8) !Q.q128 {
    if (payload.len < 32) return error.PayloadTooShort;
    return .{
        .hi = std.mem.readInt(u128, payload[0..16], .little),
        .lo = std.mem.readInt(u128, payload[16..32], .little),
    };
}

/// Compress a payload using run-length encoding of zero runs.
pub fn compressPayload(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == 0) {
            var run_len: u8 = 0;
            while (i < data.len and data[i] == 0 and run_len < 255) {
                run_len += 1;
                i += 1;
            }
            try buf.append(0x00);
            try buf.append(run_len);
        } else {
            try buf.append(data[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice();
}

/// Decompress a run-length encoded payload.
pub fn decompressPayload(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == 0x00 and i + 1 < data.len) {
            const run_len = data[i + 1];
            try buf.appendNTimes(0, run_len);
            i += 2;
        } else {
            try buf.append(data[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice();
}

/// Render a token as a QR-code-compatible matrix (simplified).
/// Returns a 21x21 grid (Version 1 QR code size).
pub fn renderQrMatrix(token: OpticalToken) [441]u8 {
    var matrix: [441]u8 = undefined;
    @memset(&matrix, 0);
    const st = token.serialize();
    const serialized = st.slice();

    // Fill data area with token bytes (simplified - not a real QR encoder)
    var idx: usize = 0;
    for (serialized) |byte| {
        var bit: usize = 0;
        while (bit < 8) : (bit += 1) {
            if (idx >= 441) break;
            matrix[idx] = (byte >> @intCast(bit)) & 1;
            idx += 1;
        }
    }

    // Add finder patterns (corners)
    const setFinder = struct {
        fn run(m: *[441]u8, row: usize, col: usize) void {
            for (0..7) |r| {
                for (0..7) |c| {
                    const is_border = r == 0 or r == 6 or c == 0 or c == 6;
                    const is_inner = (r >= 2 and r <= 4 and c >= 2 and c <= 4);
                    m[row * 21 + col + r * 21 + c] = if (is_border or is_inner) 1 else 0;
                }
            }
        }
    };
    setFinder.run(&matrix, 0, 0);
    setFinder.run(&matrix, 0, 14);
    setFinder.run(&matrix, 14, 0);

    return matrix;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "OpticalToken serialize and deserialize round-trip" {
    const payload = [_]u8{ 0x42, 0x43, 0x44, 0x45 };
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(&payload, &payload_hash, .{});
    const token = OpticalToken{
        .token_type = .boot,
        .timestamp = 12345,
        .payload_hash = payload_hash,
        .payload = &payload,
    };
    const st = token.serialize();
    const deserialized = try OpticalToken.deserialize(st.slice());
    try std.testing.expectEqual(TokenType.boot, deserialized.token_type);
    try std.testing.expectEqual(@as(u32, 12345), deserialized.timestamp);
    try std.testing.expectEqualSlices(u8, &payload_hash, &deserialized.payload_hash);
    try std.testing.expectEqualSlices(u8, &payload, deserialized.payload);
}

test "OpticalToken verify" {
    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(&payload, &payload_hash, .{});
    const token = OpticalToken{
        .token_type = .sync,
        .timestamp = 999,
        .payload_hash = payload_hash,
        .payload = &payload,
    };
    try std.testing.expect(token.verify());
}

test "OpticalToken verify rejects tampered payload" {
    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(&payload, &payload_hash, .{});
    const tampered = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0xFF };
    const token = OpticalToken{
        .token_type = .sync,
        .timestamp = 999,
        .payload_hash = payload_hash,
        .payload = &tampered,
    };
    try std.testing.expect(!token.verify());
}

test "createBootToken" {
    const node_id = [_]u8{0x42} ** 16;
    const token = createBootToken(&node_id, 12345);
    try std.testing.expectEqual(TokenType.boot, token.token_type);
    try std.testing.expectEqual(@as(u32, 12345), token.timestamp);
    try std.testing.expect(token.verify());
}

test "createSyncToken" {
    const state_hash = [_]u8{0x55} ** 16;
    const token = createSyncToken(&state_hash, 67890);
    try std.testing.expectEqual(TokenType.sync, token.token_type);
    try std.testing.expectEqual(@as(u32, 67890), token.timestamp);
    try std.testing.expect(token.verify());
}

test "encodeQ128Payload and decodeQ128Payload round-trip" {
    const value = Q.q128FromI64(42);
    const payload = encodeQ128Payload(value);
    const decoded = try decodeQ128Payload(&payload);
    try std.testing.expect(Q.q128Eq(value, decoded));
}

test "compressPayload and decompressPayload round-trip" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x00, 0x00, 0x04 };
    const compressed = try compressPayload(alloc, &data);
    defer alloc.free(compressed);
    const decompressed = try decompressPayload(alloc, compressed);
    defer alloc.free(decompressed);
    try std.testing.expectEqualSlices(u8, &data, decompressed);
}

test "compressPayload reduces size for sparse data" {
    const alloc = std.testing.allocator;
    const data = [_]u8{0x01} ++ [_]u8{0} ** 50 ++ [_]u8{0x02};
    const compressed = try compressPayload(alloc, &data);
    defer alloc.free(compressed);
    try std.testing.expect(compressed.len < data.len);
}

test "compressPayload handles no zeros" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    const compressed = try compressPayload(alloc, &data);
    defer alloc.free(compressed);
    try std.testing.expectEqual(@as(usize, 5), compressed.len);
}

test "OpticalToken deserialize rejects too short" {
    const short_buf = [_]u8{ 0x10, 0x00 };
    try std.testing.expectError(error.TokenTooShort, OpticalToken.deserialize(&short_buf));
}

test "OpticalToken deserialize rejects too long" {
    const long_buf = [_]u8{0} ** 101;
    try std.testing.expectError(error.TokenTooLong, OpticalToken.deserialize(&long_buf));
}

test "OpticalToken hash is deterministic" {
    const payload = [_]u8{ 0x42, 0x43 };
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(&payload, &payload_hash, .{});
    const token = OpticalToken{
        .token_type = .message,
        .timestamp = 100,
        .payload_hash = payload_hash,
        .payload = &payload,
    };
    const h1 = token.hash();
    const h2 = token.hash();
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "renderQrMatrix produces 21x21 grid" {
    const payload = [_]u8{ 0x42, 0x43, 0x44 };
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(&payload, &payload_hash, .{});
    const token = OpticalToken{
        .token_type = .boot,
        .timestamp = 1,
        .payload_hash = payload_hash,
        .payload = &payload,
    };
    const matrix = renderQrMatrix(token);
    // Check finder patterns exist (top-left corner should have 1s)
    try std.testing.expectEqual(@as(u8, 1), matrix[0]); // (0,0)
    try std.testing.expectEqual(@as(u8, 1), matrix[6]); // (0,6)
    try std.testing.expectEqual(@as(u8, 1), matrix[126]); // (6,0)
}

test "OpticalToken max size is 100 bytes" {
    var payload_buf: [78]u8 = undefined;
    @memset(&payload_buf, 0xAB);
    var payload_hash: [16]u8 = undefined;
    std.crypto.hash.blake2.Blake2b128.hash(&payload_buf, &payload_hash, .{});
    const token = OpticalToken{
        .token_type = .message,
        .timestamp = 1,
        .payload_hash = payload_hash,
        .payload = &payload_buf,
    };
    const st = token.serialize();
    try std.testing.expect(st.len <= 100);
}
