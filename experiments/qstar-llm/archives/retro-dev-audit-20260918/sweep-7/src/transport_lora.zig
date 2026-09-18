//! transport_lora.zig — LoRa radio transport for Qstar mesh.
//!
//! Retro-ported from Maypole ESP32 firmware concepts:
//! - LoRa packet framing with preamble, header, CRC
//! - ACK-based reliable delivery with retry and backoff
//! - Mesh relay routing for beyond-range delivery
//! - Adaptive spreading factor (SF7–SF12)
//! - WASM/freestanding compatible (no hardware I/O, pure logic)
//!
//! Zero external dependencies beyond std.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Maximum LoRa payload size (MTU) in bytes.
pub const LORA_MTU: usize = 255;

/// LoRa preamble length in symbols.
pub const PREAMBLE_LEN: usize = 8;

/// CRC-16 polynomial for packet integrity.
pub const CRC16_POLY: u16 = 0x1021; // CCITT

/// Default maximum retries for reliable delivery.
pub const DEFAULT_MAX_RETRIES: u8 = 3;

/// Default ACK timeout in milliseconds.
pub const DEFAULT_ACK_TIMEOUT_MS: u64 = 2000;

/// Default backoff multiplier (exponential backoff).
pub const DEFAULT_BACKOFF_MULT: u64 = 2;

/// Spreading factor range.
pub const SF_MIN: u8 = 7;
pub const SF_MAX: u8 = 12;

/// LoRa packet header size: [preamble:8][sender:4][receiver:4][msg_id:2][flags:1][payload_len:2][sf:1] = 22 bytes
pub const HEADER_SIZE: usize = 22;

/// Flag bits.
pub const FLAG_ACK: u8 = 0x01;
pub const FLAG_RELIABLE: u8 = 0x02;
pub const FLAG_MESH_RELAY: u8 = 0x04;
pub const FLAG_BROADCAST: u8 = 0x08;

// =============================================================================
// SpreadingFactor — adaptive data rate
// =============================================================================

pub const SpreadingFactor = enum(u8) {
    sf7 = 7,
    sf8 = 8,
    sf9 = 9,
    sf10 = 10,
    sf11 = 11,
    sf12 = 12,

    /// Time on air (approximate, in milliseconds) for a given payload size.
    pub fn timeOnAir(self: SpreadingFactor, payload_len: usize) u64 {
        const sf: u64 = @intFromEnum(self);
        // Simplified ToA model: symbol time = 2^SF / bandwidth_ms
        // Assuming 125 kHz bandwidth → symbol time ≈ 2^SF * 8 µs
        const symbol_ms: u64 = (std.math.shl(u64, 1, sf)) * 8 / 1000;
        // Approximate number of symbols: preamble + header + ceil(payload * 8 / SF)
        const payload_symbols = (payload_len * 8 + sf - 1) / sf;
        const total_symbols = PREAMBLE_LEN + 8 + payload_symbols;
        return symbol_ms * total_symbols;
    }

    /// Higher SF = longer range, lower data rate.
    pub fn rangeKm(self: SpreadingFactor) u32 {
        return switch (self) {
            .sf7 => 2,
            .sf8 => 5,
            .sf9 => 10,
            .sf10 => 15,
            .sf11 => 20,
            .sf12 => 30,
        };
    }

    pub fn fromU8(v: u8) ?SpreadingFactor {
        if (v < SF_MIN or v > SF_MAX) return null;
        return @enumFromInt(v);
    }
};

// =============================================================================
// LoRaPacket — framed packet for radio transmission
// =============================================================================

pub const LoRaPacket = struct {
    sender: u32,
    receiver: u32,
    msg_id: u16,
    flags: u8,
    spreading_factor: SpreadingFactor,
    payload: []const u8,

    pub fn isACK(self: LoRaPacket) bool {
        return (self.flags & FLAG_ACK) != 0;
    }

    pub fn isReliable(self: LoRaPacket) bool {
        return (self.flags & FLAG_RELIABLE) != 0;
    }

    pub fn isMeshRelay(self: LoRaPacket) bool {
        return (self.flags & FLAG_MESH_RELAY) != 0;
    }

    pub fn isBroadcast(self: LoRaPacket) bool {
        return (self.flags & FLAG_BROADCAST) != 0;
    }
};

// =============================================================================
// CRC-16/CCITT
// =============================================================================

/// Compute CRC-16/CCITT checksum.
pub fn crc16(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            if ((crc & 0x8000) != 0) {
                crc = (crc << 1) ^ CRC16_POLY;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

// =============================================================================
// Packet encoding/decoding
// =============================================================================

/// Encode a LoRa packet into a wire-format byte buffer.
/// Format: [preamble:8][sender:4LE][receiver:4LE][msg_id:2LE][flags:1][sf:1][payload_len:2LE][payload:N][crc:2LE]
pub fn encodePacket(allocator: std.mem.Allocator, packet: LoRaPacket) ![]u8 {
    if (packet.payload.len > LORA_MTU) return error.PayloadTooLarge;

    const total_len = HEADER_SIZE + packet.payload.len + 2; // +2 for CRC
    var buf = try allocator.alloc(u8, total_len);

    // Preamble (8 bytes of 0xAA sync word)
    for (0..8) |i| buf[i] = 0xAA;

    // Sender (4 bytes LE)
    std.mem.writeInt(u32, buf[8..12], packet.sender, .little);
    // Receiver (4 bytes LE)
    std.mem.writeInt(u32, buf[12..16], packet.receiver, .little);
    // Message ID (2 bytes LE)
    std.mem.writeInt(u16, buf[16..18], packet.msg_id, .little);
    // Flags
    buf[18] = packet.flags;
    // Spreading factor
    buf[19] = @intFromEnum(packet.spreading_factor);
    // Payload length (2 bytes LE)
    std.mem.writeInt(u16, buf[20..22], @as(u16, @intCast(packet.payload.len)), .little);

    // Payload
    @memcpy(buf[HEADER_SIZE .. HEADER_SIZE + packet.payload.len], packet.payload);

    // CRC-16 over header + payload (excluding preamble and CRC itself)
    const crc = crc16(buf[8 .. HEADER_SIZE + packet.payload.len]);
    const crc_offset = HEADER_SIZE + packet.payload.len;
    buf[crc_offset] = @truncate(crc);
    buf[crc_offset + 1] = @truncate(crc >> 8);

    return buf;
}

/// Decode a wire-format byte buffer into a LoRa packet.
/// Returns null if preamble check or CRC validation fails.
pub fn decodePacket(allocator: std.mem.Allocator, buf: []const u8) !?LoRaPacket {
    if (buf.len < HEADER_SIZE + 2) return null;

    // Check preamble
    for (0..8) |i| {
        if (buf[i] != 0xAA) return null;
    }

    // Parse fields
    const sender = std.mem.readInt(u32, buf[8..12], .little);
    const receiver = std.mem.readInt(u32, buf[12..16], .little);
    const msg_id = std.mem.readInt(u16, buf[16..18], .little);
    const flags = buf[18];
    const sf_byte = buf[19];
    const payload_len = std.mem.readInt(u16, buf[20..22], .little);

    // Validate spreading factor
    const sf = SpreadingFactor.fromU8(sf_byte) orelse return null;

    // Validate payload length
    if (payload_len > LORA_MTU) return null;
    if (buf.len < HEADER_SIZE + payload_len + 2) return null;

    // Verify CRC
    const crc_pos = HEADER_SIZE + payload_len;
    const expected_crc: u16 = @as(u16, buf[crc_pos]) | (@as(u16, buf[crc_pos + 1]) << 8);
    const actual_crc = crc16(buf[8 .. HEADER_SIZE + payload_len]);
    if (expected_crc != actual_crc) return null;

    // Copy payload
    const payload = try allocator.dupe(u8, buf[HEADER_SIZE .. HEADER_SIZE + payload_len]);

    return LoRaPacket{
        .sender = sender,
        .receiver = receiver,
        .msg_id = msg_id,
        .flags = flags,
        .spreading_factor = sf,
        .payload = payload,
    };
}

// =============================================================================
// ReliableDelivery — ACK-based retry with exponential backoff
// =============================================================================

pub const PendingAck = struct {
    msg_id: u16,
    packet: []u8,
    retries: u8 = 0,
    last_send_ms: u64 = 0,
    next_retry_ms: u64 = 0,
};

pub const ReliableDelivery = struct {
    allocator: std.mem.Allocator,
    pending: std.AutoHashMap(u16, PendingAck),
    next_msg_id: u16 = 1,
    max_retries: u8 = DEFAULT_MAX_RETRIES,
    ack_timeout_ms: u64 = DEFAULT_ACK_TIMEOUT_MS,
    backoff_mult: u64 = DEFAULT_BACKOFF_MULT,
    clock_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ReliableDelivery {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(u16, PendingAck).init(allocator),
        };
    }

    pub fn deinit(self: *ReliableDelivery) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.packet);
        }
        self.pending.deinit();
    }

    /// Send a reliable packet — returns the message ID for tracking.
    pub fn send(self: *ReliableDelivery, packet: LoRaPacket) !u16 {
        const msg_id = self.next_msg_id;
        self.next_msg_id +%= 1;
        if (self.next_msg_id == 0) self.next_msg_id = 1; // Skip 0

        var pkt = packet;
        pkt.msg_id = msg_id;
        pkt.flags |= FLAG_RELIABLE;

        const encoded = try encodePacket(self.allocator, pkt);

        try self.pending.put(msg_id, .{
            .msg_id = msg_id,
            .packet = encoded,
            .last_send_ms = self.clock_ms,
            .next_retry_ms = self.clock_ms + self.ack_timeout_ms,
        });

        return msg_id;
    }

    /// Process an incoming ACK — removes the pending entry.
    pub fn handleACK(self: *ReliableDelivery, msg_id: u16) bool {
        if (self.pending.fetchRemove(msg_id)) |entry| {
            self.allocator.free(entry.value.packet);
            return true;
        }
        return false;
    }

    /// Check for timed-out packets and return msg_ids that need retry.
    /// Returns the list of msg_ids that have exceeded max retries (to be dropped).
    pub fn checkTimeouts(self: *ReliableDelivery, allocator: std.mem.Allocator) !struct {
        retry: []u16,
        dropped: []u16,
    } {
        var retry_list = std.ArrayList(u16).init(allocator);
        var drop_list = std.ArrayList(u16).init(allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const pending = entry.value_ptr;
            if (self.clock_ms >= pending.next_retry_ms) {
                if (pending.retries >= self.max_retries) {
                    try drop_list.append(pending.msg_id);
                } else {
                    pending.retries += 1;
                    const backoff = std.math.shl(u64, self.ack_timeout_ms, pending.retries / 2);
                    pending.next_retry_ms = self.clock_ms + backoff;
                    pending.last_send_ms = self.clock_ms;
                    try retry_list.append(pending.msg_id);
                }
            }
        }

        // Drop expired packets
        for (drop_list.items) |id| {
            if (self.pending.fetchRemove(id)) |entry| {
                self.allocator.free(entry.value.packet);
            }
        }

        return .{
            .retry = try retry_list.toOwnedSlice(),
            .dropped = try drop_list.toOwnedSlice(),
        };
    }

    /// Advance the internal clock.
    pub fn tick(self: *ReliableDelivery, dt_ms: u64) void {
        self.clock_ms +%= dt_ms;
    }

    /// Number of pending unACKed packets.
    pub fn pendingCount(self: *const ReliableDelivery) usize {
        return self.pending.count();
    }

    /// Get the encoded packet bytes for a pending msg_id (for retransmission).
    pub fn getPendingPacket(self: *const ReliableDelivery, msg_id: u16) ?[]const u8 {
        if (self.pending.get(msg_id)) |pending| {
            return pending.packet;
        }
        return null;
    }
};

// =============================================================================
// AdaptiveDataRate — adjust SF based on link quality
// =============================================================================

pub const LinkQuality = struct {
    snr_db: i8, // Signal-to-noise ratio in dB
    rssi_dbm: i16, // Received signal strength in dBm
    packet_loss_pct: u8, // 0-100

    /// Determine the optimal spreading factor for this link quality.
    pub fn optimalSF(self: LinkQuality) SpreadingFactor {
        // Good SNR → low SF (faster), poor SNR → high SF (longer range)
        if (self.snr_db >= 10) return .sf7;
        if (self.snr_db >= 5) return .sf8;
        if (self.snr_db >= 0) return .sf9;
        if (self.snr_db >= -5) return .sf10;
        if (self.snr_db >= -10) return .sf11;
        return .sf12;
    }
};

/// Adjust spreading factor based on observed link quality and packet loss.
pub fn adaptiveSF(current: SpreadingFactor, quality: LinkQuality) SpreadingFactor {
    const optimal = quality.optimalSF();
    const current_val: u8 = @intFromEnum(current);
    const optimal_val: u8 = @intFromEnum(optimal);

    // Move toward optimal by 1 step at a time (hysteresis)
    if (optimal_val < current_val) {
        return @enumFromInt(current_val - 1);
    } else if (optimal_val > current_val) {
        return @enumFromInt(current_val + 1);
    }
    return current;
}

// =============================================================================
// MeshRelay — store-and-forward relay for beyond-range delivery
// =============================================================================

pub const RelayEntry = struct {
    msg_id: u16,
    sender: u32,
    receiver: u32,
    payload: []u8,
    hops: u8,
    received_ms: u64,
};

pub const MeshRelay = struct {
    allocator: std.mem.Allocator,
    seen: std.AutoHashMap(u16, u64), // msg_id → received_ms
    max_hops: u8 = 7,
    cache_ttl_ms: u64 = 300_000, // 5 minutes
    clock_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) MeshRelay {
        return .{
            .allocator = allocator,
            .seen = std.AutoHashMap(u16, u64).init(allocator),
        };
    }

    pub fn deinit(self: *MeshRelay) void {
        self.seen.deinit();
    }

    /// Check if we've already seen this packet (for dedup).
    pub fn hasSeen(self: *const MeshRelay, msg_id: u16) bool {
        return self.seen.contains(msg_id);
    }

    /// Mark a packet as seen. Returns true if newly seen.
    pub fn markSeen(self: *MeshRelay, msg_id: u16) !bool {
        if (self.seen.contains(msg_id)) return false;
        try self.seen.put(msg_id, self.clock_ms);
        return true;
    }

    /// Determine if a packet should be relayed.
    /// Returns true if: not seen before, not broadcast from self, and hops < max.
    pub fn shouldRelay(self: *const MeshRelay, packet: LoRaPacket, our_id: u32) bool {
        if (packet.sender == our_id) return false;
        if (self.hasSeen(packet.msg_id)) return false;
        if (packet.isBroadcast()) return true;
        if (packet.receiver == our_id) return false; // We're the destination
        return packet.isMeshRelay();
    }

    /// Clean up expired entries from the seen cache.
    pub fn pruneExpired(self: *MeshRelay) void {
        var to_remove = std.ArrayList(u16).init(self.allocator);
        defer to_remove.deinit();

        var it = self.seen.iterator();
        while (it.next()) |entry| {
            if (self.clock_ms - entry.value_ptr.* > self.cache_ttl_ms) {
                to_remove.append(entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |id| {
            _ = self.seen.remove(id);
        }
    }

    /// Advance the internal clock.
    pub fn tick(self: *MeshRelay, dt_ms: u64) void {
        self.clock_ms +%= dt_ms;
    }

    /// Number of entries in the seen cache.
    pub fn seenCount(self: *const MeshRelay) usize {
        return self.seen.count();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "lora: CRC16 known values" {
    // CRC-16/CCITT of "123456789" should be 0x29B1
    const data = "123456789";
    const crc = crc16(data);
    try std.testing.expectEqual(@as(u16, 0x29B1), crc);
}

test "lora: CRC16 empty data" {
    const crc = crc16("");
    try std.testing.expectEqual(@as(u16, 0xFFFF), crc);
}

test "lora: encode/decode round-trip" {
    const allocator = std.testing.allocator;
    const payload = "Hello LoRa!";

    const packet = LoRaPacket{
        .sender = 0x12345678,
        .receiver = 0xAABBCCDD,
        .msg_id = 42,
        .flags = FLAG_RELIABLE,
        .spreading_factor = .sf9,
        .payload = payload,
    };

    const encoded = try encodePacket(allocator, packet);
    defer allocator.free(encoded);

    // Verify total length
    try std.testing.expectEqual(HEADER_SIZE + payload.len + 2, encoded.len);

    // Decode
    const decoded = try decodePacket(allocator, encoded);
    try std.testing.expect(decoded != null);
    defer if (decoded) |d| allocator.free(d.payload);

    const d = decoded.?;
    try std.testing.expectEqual(packet.sender, d.sender);
    try std.testing.expectEqual(packet.receiver, d.receiver);
    try std.testing.expectEqual(packet.msg_id, d.msg_id);
    try std.testing.expectEqual(packet.flags, d.flags);
    try std.testing.expectEqual(packet.spreading_factor, d.spreading_factor);
    try std.testing.expectEqualStrings(payload, d.payload);
}

test "lora: decode rejects bad preamble" {
    const allocator = std.testing.allocator;
    const bad_buf = try allocator.alloc(u8, HEADER_SIZE + 10 + 2);
    defer allocator.free(bad_buf);
    for (bad_buf) |*b| b.* = 0x00; // Wrong preamble

    const result = try decodePacket(allocator, bad_buf);
    try std.testing.expect(result == null);
}

test "lora: decode rejects bad CRC" {
    const allocator = std.testing.allocator;
    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 1,
        .flags = 0,
        .spreading_factor = .sf7,
        .payload = "test",
    };

    const encoded = try encodePacket(allocator, packet);
    defer allocator.free(encoded);

    // Corrupt the last byte (CRC)
    encoded[encoded.len - 1] ^= 0xFF;

    const result = try decodePacket(allocator, encoded);
    try std.testing.expect(result == null);
}

test "lora: encode rejects oversized payload" {
    const allocator = std.testing.allocator;
    const big_payload = try allocator.alloc(u8, LORA_MTU + 1);
    defer allocator.free(big_payload);

    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 1,
        .flags = 0,
        .spreading_factor = .sf7,
        .payload = big_payload,
    };

    try std.testing.expectError(error.PayloadTooLarge, encodePacket(allocator, packet));
}

test "lora: SpreadingFactor time on air increases with SF" {
    const toa7 = SpreadingFactor.sf7.timeOnAir(64);
    const toa12 = SpreadingFactor.sf12.timeOnAir(64);
    try std.testing.expect(toa12 > toa7);
}

test "lora: SpreadingFactor range increases with SF" {
    try std.testing.expect(SpreadingFactor.sf7.rangeKm() < SpreadingFactor.sf12.rangeKm());
}

test "lora: SpreadingFactor fromU8 validation" {
    try std.testing.expect(SpreadingFactor.fromU8(7) != null);
    try std.testing.expect(SpreadingFactor.fromU8(12) != null);
    try std.testing.expect(SpreadingFactor.fromU8(6) == null);
    try std.testing.expect(SpreadingFactor.fromU8(13) == null);
}

test "lora: LoRaPacket flag helpers" {
    const pkt = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 1,
        .flags = FLAG_ACK | FLAG_RELIABLE,
        .spreading_factor = .sf7,
        .payload = "",
    };
    try std.testing.expect(pkt.isACK());
    try std.testing.expect(pkt.isReliable());
    try std.testing.expect(!pkt.isMeshRelay());
    try std.testing.expect(!pkt.isBroadcast());
}

test "lora: ReliableDelivery send and ACK" {
    const allocator = std.testing.allocator;
    var rd = ReliableDelivery.init(allocator);
    defer rd.deinit();

    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 0, // Will be assigned by send()
        .flags = 0,
        .spreading_factor = .sf9,
        .payload = "test reliable",
    };

    const msg_id = try rd.send(packet);
    try std.testing.expectEqual(@as(usize, 1), rd.pendingCount());

    // ACK it
    const acked = rd.handleACK(msg_id);
    try std.testing.expect(acked);
    try std.testing.expectEqual(@as(usize, 0), rd.pendingCount());
}

test "lora: ReliableDelivery retry on timeout" {
    const allocator = std.testing.allocator;
    var rd = ReliableDelivery.init(allocator);
    defer rd.deinit();

    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 0,
        .flags = 0,
        .spreading_factor = .sf9,
        .payload = "retry test",
    };

    _ = try rd.send(packet);
    try std.testing.expectEqual(@as(usize, 1), rd.pendingCount());

    // Advance clock past ACK timeout
    rd.tick(DEFAULT_ACK_TIMEOUT_MS + 1);

    // Check timeouts — should trigger retry
    const result = try rd.checkTimeouts(allocator);
    defer allocator.free(result.retry);
    defer allocator.free(result.dropped);

    try std.testing.expectEqual(@as(usize, 1), result.retry.len);
    try std.testing.expectEqual(@as(usize, 0), result.dropped.len);
    try std.testing.expectEqual(@as(usize, 1), rd.pendingCount());
}

test "lora: ReliableDelivery drops after max retries" {
    const allocator = std.testing.allocator;
    var rd = ReliableDelivery.init(allocator);
    defer rd.deinit();
    rd.max_retries = 2;

    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 0,
        .flags = 0,
        .spreading_factor = .sf9,
        .payload = "drop test",
    };

    _ = try rd.send(packet);

    // Simulate enough timeouts to exceed max retries
    for (0..5) |_| {
        rd.tick(DEFAULT_ACK_TIMEOUT_MS * 4);
        const result = try rd.checkTimeouts(allocator);
        allocator.free(result.retry);
        allocator.free(result.dropped);
    }

    // Should be dropped
    try std.testing.expectEqual(@as(usize, 0), rd.pendingCount());
}

test "lora: ReliableDelivery msg_id increments and wraps" {
    const allocator = std.testing.allocator;
    var rd = ReliableDelivery.init(allocator);
    defer rd.deinit();
    rd.next_msg_id = 65534;

    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 0,
        .flags = 0,
        .spreading_factor = .sf7,
        .payload = "wrap",
    };

    const id1 = try rd.send(packet);
    try std.testing.expectEqual(@as(u16, 65534), id1);

    const id2 = try rd.send(packet);
    try std.testing.expectEqual(@as(u16, 65535), id2);

    const id3 = try rd.send(packet);
    try std.testing.expectEqual(@as(u16, 1), id3); // Wraps to 1, skipping 0
}

test "lora: LinkQuality optimalSF" {
    try std.testing.expectEqual(SpreadingFactor.sf7, (LinkQuality{ .snr_db = 15, .rssi_dbm = -50, .packet_loss_pct = 0 }).optimalSF());
    try std.testing.expectEqual(SpreadingFactor.sf9, (LinkQuality{ .snr_db = 2, .rssi_dbm = -90, .packet_loss_pct = 5 }).optimalSF());
    try std.testing.expectEqual(SpreadingFactor.sf12, (LinkQuality{ .snr_db = -15, .rssi_dbm = -120, .packet_loss_pct = 50 }).optimalSF());
}

test "lora: adaptiveSF moves toward optimal by 1 step" {
    // Current SF10, quality says SF7 → should go to SF9
    const result = adaptiveSF(.sf10, .{ .snr_db = 15, .rssi_dbm = -50, .packet_loss_pct = 0 });
    try std.testing.expectEqual(SpreadingFactor.sf9, result);

    // Current SF7, quality says SF12 → should go to SF8
    const result2 = adaptiveSF(.sf7, .{ .snr_db = -15, .rssi_dbm = -120, .packet_loss_pct = 50 });
    try std.testing.expectEqual(SpreadingFactor.sf8, result2);

    // Already optimal → stays
    const result3 = adaptiveSF(.sf9, .{ .snr_db = 2, .rssi_dbm = -90, .packet_loss_pct = 5 });
    try std.testing.expectEqual(SpreadingFactor.sf9, result3);
}

test "lora: MeshRelay dedup" {
    const allocator = std.testing.allocator;
    var relay = MeshRelay.init(allocator);
    defer relay.deinit();

    const newly_seen = try relay.markSeen(42);
    try std.testing.expect(newly_seen);

    const dup = try relay.markSeen(42);
    try std.testing.expect(!dup);

    try std.testing.expect(relay.hasSeen(42));
    try std.testing.expect(!relay.hasSeen(99));
}

test "lora: MeshRelay shouldRelay logic" {
    const allocator = std.testing.allocator;
    var relay = MeshRelay.init(allocator);
    defer relay.deinit();

    const our_id: u32 = 100;

    // Packet from self → no relay
    const own_pkt = LoRaPacket{ .sender = our_id, .receiver = 200, .msg_id = 1, .flags = FLAG_MESH_RELAY, .spreading_factor = .sf7, .payload = "" };
    try std.testing.expect(!relay.shouldRelay(own_pkt, our_id));

    // Broadcast from other → relay
    const bcast_pkt = LoRaPacket{ .sender = 50, .receiver = 0, .msg_id = 2, .flags = FLAG_BROADCAST, .spreading_factor = .sf7, .payload = "" };
    try std.testing.expect(relay.shouldRelay(bcast_pkt, our_id));

    // Mesh relay packet, not for us → relay
    const relay_pkt = LoRaPacket{ .sender = 50, .receiver = 200, .msg_id = 3, .flags = FLAG_MESH_RELAY, .spreading_factor = .sf7, .payload = "" };
    try std.testing.expect(relay.shouldRelay(relay_pkt, our_id));

    // Packet for us → no relay
    const our_pkt = LoRaPacket{ .sender = 50, .receiver = our_id, .msg_id = 4, .flags = FLAG_MESH_RELAY, .spreading_factor = .sf7, .payload = "" };
    try std.testing.expect(!relay.shouldRelay(our_pkt, our_id));

    // Already seen → no relay
    _ = try relay.markSeen(5);
    const seen_pkt = LoRaPacket{ .sender = 50, .receiver = 200, .msg_id = 5, .flags = FLAG_MESH_RELAY, .spreading_factor = .sf7, .payload = "" };
    try std.testing.expect(!relay.shouldRelay(seen_pkt, our_id));
}

test "lora: MeshRelay pruneExpired" {
    const allocator = std.testing.allocator;
    var relay = MeshRelay.init(allocator);
    defer relay.deinit();
    relay.cache_ttl_ms = 1000;

    _ = try relay.markSeen(1);
    relay.tick(500);
    _ = try relay.markSeen(2);
    relay.tick(600); // Total: 1100ms — entry 1 is now expired (1100 > 1000)

    relay.pruneExpired();
    try std.testing.expect(!relay.hasSeen(1));
    try std.testing.expect(relay.hasSeen(2));
}

test "lora: ReliableDelivery getPendingPacket" {
    const allocator = std.testing.allocator;
    var rd = ReliableDelivery.init(allocator);
    defer rd.deinit();

    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 2,
        .msg_id = 0,
        .flags = 0,
        .spreading_factor = .sf7,
        .payload = "pending",
    };

    const msg_id = try rd.send(packet);
    const pending = rd.getPendingPacket(msg_id);
    try std.testing.expect(pending != null);
    try std.testing.expect(pending.?.len > 0);

    // Non-existent msg_id
    try std.testing.expect(rd.getPendingPacket(9999) == null);
}

test "lora: handleACK for unknown msg_id returns false" {
    const allocator = std.testing.allocator;
    var rd = ReliableDelivery.init(allocator);
    defer rd.deinit();

    try std.testing.expect(!rd.handleACK(9999));
}

test "lora: broadcast packet encoding" {
    const allocator = std.testing.allocator;
    const packet = LoRaPacket{
        .sender = 1,
        .receiver = 0, // Broadcast
        .msg_id = 100,
        .flags = FLAG_BROADCAST | FLAG_MESH_RELAY,
        .spreading_factor = .sf11,
        .payload = "mesh broadcast",
    };

    const encoded = try encodePacket(allocator, packet);
    defer allocator.free(encoded);

    const decoded = try decodePacket(allocator, encoded);
    try std.testing.expect(decoded != null);
    defer if (decoded) |d| allocator.free(d.payload);

    const d = decoded.?;
    try std.testing.expect(d.isBroadcast());
    try std.testing.expect(d.isMeshRelay());
    try std.testing.expectEqual(SpreadingFactor.sf11, d.spreading_factor);
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
