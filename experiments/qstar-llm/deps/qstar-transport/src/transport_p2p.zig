//! transport_p2p.zig — P2P packet transport with X25519 + ChaCha20Poly1305.
//!
//! Extracted from freenet-core (#15).
//! Packet format, X25519 key exchange, ChaCha20Poly1305 encryption.
//! Uses std.crypto for all crypto primitives.

const std = @import("std");

pub const X25519 = std.crypto.dh.X25519;
pub const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const PACKET_MAGIC: [4]u8 = .{ 'P', '2', 'P', '1' };
pub const HEADER_SIZE: usize = 4 + 1 + 1 + 2 + 12; // magic + type + flags + payload_len + nonce

pub const PacketType = enum(u8) {
    intro = 0,
    symmetric = 1,
    data = 2,
    ack = 3,
};

pub const PacketHeader = struct {
    magic: [4]u8,
    packet_type: PacketType,
    flags: u8,
    payload_len: u16,
    nonce: [16]u8,
};

pub const KeyPair = struct {
    public_key: [X25519.public_length]u8,
    secret_key: [X25519.secret_length]u8,

    pub fn generate() KeyPair {
        var secret_key: [X25519.secret_length]u8 = undefined;
        std.crypto.random.bytes(&secret_key);
        const public_key = X25519.recoverPublicKey(secret_key) catch unreachable;
        return .{ .public_key = public_key, .secret_key = secret_key };
    }

    pub fn sharedSecret(self: KeyPair, peer_public: [X25519.public_length]u8) ![ChaCha20Poly1305.key_length]u8 {
        return X25519.scalarmult(self.secret_key, peer_public) catch error.KeyExchangeFailed;
    }
};

/// Encrypts data using ChaCha20Poly1305 with the given key and nonce.
pub fn encrypt(allocator: std.mem.Allocator, data: []const u8, key: [ChaCha20Poly1305.key_length]u8, nonce: [ChaCha20Poly1305.nonce_length]u8) ![]u8 {
    var ciphertext = try allocator.alloc(u8, data.len + ChaCha20Poly1305.tag_length);
    errdefer allocator.free(ciphertext);

    ChaCha20Poly1305.encrypt(ciphertext[0..data.len], ciphertext[data.len..][0..ChaCha20Poly1305.tag_length], data, &.{}, nonce, key);

    return ciphertext;
}

/// Decrypts data using ChaCha20Poly1305.
pub fn decrypt(allocator: std.mem.Allocator, ciphertext: []const u8, key: [ChaCha20Poly1305.key_length]u8, nonce: [ChaCha20Poly1305.nonce_length]u8) ![]u8 {
    if (ciphertext.len < ChaCha20Poly1305.tag_length) return error.CiphertextTooShort;

    const ct_len = ciphertext.len - ChaCha20Poly1305.tag_length;
    const plaintext = try allocator.alloc(u8, ct_len);
    errdefer allocator.free(plaintext);

    ChaCha20Poly1305.decrypt(plaintext, ciphertext[0..ct_len], ciphertext[ct_len..][0..ChaCha20Poly1305.tag_length].*, &.{}, nonce, key) catch return error.DecryptionFailed;

    return plaintext;
}

/// Encodes data into a P2P packet (unencrypted — for encrypted use encryptP2P).
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(&PACKET_MAGIC);
    try out.append(@intFromEnum(PacketType.data));
    try out.append(0);
    try out.writer().writeInt(u16, @intCast(data.len), .little);

    var nonce: [12]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    try out.appendSlice(&nonce);

    try out.appendSlice(data);

    return out.toOwnedSlice();
}

/// Decodes a P2P packet back to original data.
pub fn decode(allocator: std.mem.Allocator, packet: []const u8) ![]u8 {
    if (packet.len < HEADER_SIZE) return error.PacketTooShort;
    if (!std.mem.eql(u8, packet[0..4], &PACKET_MAGIC)) return error.InvalidMagic;

    const pkt_type: PacketType = @enumFromInt(packet[4]);
    if (pkt_type != .data) return error.WrongPacketType;

    const payload_len = std.mem.readInt(u16, packet[6..8], .little);
    if (packet.len < HEADER_SIZE + payload_len) return error.TruncatedPayload;

    return try allocator.dupe(u8, packet[HEADER_SIZE .. HEADER_SIZE + payload_len]);
}

/// Full encrypted P2P encode: packet format + ChaCha20Poly1305.
pub fn encryptP2P(allocator: std.mem.Allocator, data: []const u8, key: [ChaCha20Poly1305.key_length]u8) ![]u8 {
    var nonce: [ChaCha20Poly1305.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const ciphertext = try encrypt(allocator, data, key, nonce);
    defer allocator.free(ciphertext);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(&PACKET_MAGIC);
    try out.append(@intFromEnum(PacketType.symmetric));
    try out.append(0);
    try out.writer().writeInt(u16, @intCast(ciphertext.len), .little);
    try out.appendSlice(&nonce);
    try out.appendSlice(ciphertext);

    return out.toOwnedSlice();
}

/// Full encrypted P2P decode.
pub fn decryptP2P(allocator: std.mem.Allocator, packet: []const u8, key: [ChaCha20Poly1305.key_length]u8) ![]u8 {
    if (packet.len < HEADER_SIZE) return error.PacketTooShort;
    if (!std.mem.eql(u8, packet[0..4], &PACKET_MAGIC)) return error.InvalidMagic;

    const pkt_type: PacketType = @enumFromInt(packet[4]);
    if (pkt_type != .symmetric) return error.WrongPacketType;

    const payload_len = std.mem.readInt(u16, packet[6..8], .little);
    if (packet.len < HEADER_SIZE + payload_len) return error.TruncatedPayload;

    var nonce: [ChaCha20Poly1305.nonce_length]u8 = undefined;
    @memcpy(&nonce, packet[8..20]);

    return try decrypt(allocator, packet[HEADER_SIZE .. HEADER_SIZE + payload_len], key, nonce);
}

pub fn capacity() usize {
    return 1;
}

pub fn name() []const u8 {
    return "p2p";
}

// Tests

test "key exchange produces matching shared secrets" {
    const alice = KeyPair.generate();
    const bob = KeyPair.generate();

    const alice_shared = try alice.sharedSecret(bob.public_key);
    const bob_shared = try bob.sharedSecret(alice.public_key);

    try std.testing.expectEqualSlices(u8, &alice_shared, &bob_shared);
}

test "encrypt/decrypt round trip" {
    const allocator = std.testing.allocator;
    const data = "Secret P2P message!";
    var key: [ChaCha20Poly1305.key_length]u8 = undefined;
    var nonce: [ChaCha20Poly1305.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&key);
    std.crypto.random.bytes(&nonce);

    const ciphertext = try encrypt(allocator, data, key, nonce);
    defer allocator.free(ciphertext);

    const plaintext = try decrypt(allocator, ciphertext, key, nonce);
    defer allocator.free(plaintext);

    try std.testing.expectEqualSlices(u8, data, plaintext);
}

test "p2p encode/decode round trip" {
    const allocator = std.testing.allocator;
    const data = "P2P transport test";

    const encoded = try encode(allocator, data);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "p2p encrypted round trip" {
    const allocator = std.testing.allocator;
    const data = "Encrypted P2P test";
    var key: [ChaCha20Poly1305.key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    const encoded = try encryptP2P(allocator, data, key);
    defer allocator.free(encoded);

    const decoded = try decryptP2P(allocator, encoded, key);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "p2p wrong key fails" {
    const allocator = std.testing.allocator;
    const data = "test";
    var key1: [ChaCha20Poly1305.key_length]u8 = undefined;
    var key2: [ChaCha20Poly1305.key_length]u8 = undefined;
    std.crypto.random.bytes(&key1);
    std.crypto.random.bytes(&key2);

    const encoded = try encryptP2P(allocator, data, key1);
    defer allocator.free(encoded);

    try std.testing.expectError(error.DecryptionFailed, decryptP2P(allocator, encoded, key2));
}

test "p2p name" {
    try std.testing.expectEqualStrings("p2p", name());
}
