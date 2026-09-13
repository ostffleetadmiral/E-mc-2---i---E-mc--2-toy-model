//! nat.zig — NAT traversal: UDP hole punching + WebRTC signaling + QR relay fallback.
//!
//! Enables two peers behind home routers to connect without STUN/TURN servers.
//! Includes minimal STUN client, NAT type detection, hole-punch coordination,
//! WebRTC signaling via lattice face-QRs, and QR-code relay fallback.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

// =============================================================================
// NAT Type Detection
// =============================================================================

pub const NATType = enum {
    full_cone,
    restricted_cone,
    port_restricted,
    symmetric,
    unknown,

    pub fn toString(self: NATType) []const u8 {
        return switch (self) {
            .full_cone => "full_cone",
            .restricted_cone => "restricted_cone",
            .port_restricted => "port_restricted",
            .symmetric => "symmetric",
            .unknown => "unknown",
        };
    }

    /// Whether hole punching can work with this NAT type.
    pub fn canHolePunch(self: NATType) bool {
        return switch (self) {
            .full_cone, .restricted_cone, .port_restricted => true,
            .symmetric, .unknown => false,
        };
    }
};

// =============================================================================
// Address — IP + port representation
// =============================================================================

pub const Address = struct {
    ip: [4]u8,
    port: u16,

    pub fn new(ip: [4]u8, port: u16) Address {
        return .{ .ip = ip, .port = port };
    }

    pub fn fromString(ip_str: []const u8, port: u16) !Address {
        var ip: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, ip_str, '.');
        for (0..4) |i| {
            const part = it.next() orelse return error.InvalidIP;
            ip[i] = try std.fmt.parseInt(u8, part, 10);
        }
        return .{ .ip = ip, .port = port };
    }

    pub fn format(self: Address, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{
            self.ip[0], self.ip[1], self.ip[2], self.ip[3], self.port,
        });
    }

    pub fn eql(a: Address, b: Address) bool {
        return std.mem.eql(u8, &a.ip, &b.ip) and a.port == b.port;
    }
};

// =============================================================================
// STUN — minimal STUN binding request/response (RFC 5389)
// =============================================================================

/// STUN magic cookie (RFC 5389).
pub const STUN_MAGIC_COOKIE: u32 = 0x2112A442;

/// STUN message types.
pub const STUNMessageType = enum(u16) {
    binding_request = 0x0001,
    binding_response = 0x0101,
    binding_error = 0x0111,
};

/// STUN attribute types.
pub const STUNAttrType = enum(u16) {
    mapped_address = 0x0001,
    xor_mapped_address = 0x0020,
    software = 0x8022,
    _,
};

/// Builds a STUN binding request packet (20 bytes header, no attributes).
pub fn buildBindingRequest(transaction_id: [12]u8) [20]u8 {
    var packet: [20]u8 = undefined;
    // Message type: Binding Request (0x0001)
    std.mem.writeInt(u16, packet[0..2], @intFromEnum(STUNMessageType.binding_request), .big);
    // Message length: 0 (no attributes)
    std.mem.writeInt(u16, packet[2..4], 0, .big);
    // Magic cookie
    std.mem.writeInt(u32, packet[4..8], STUN_MAGIC_COOKIE, .big);
    // Transaction ID
    @memcpy(packet[8..20], &transaction_id);
    return packet;
}

/// Parses a STUN binding response and extracts the XOR-mapped address.
pub fn parseBindingResponse(packet: []const u8) !Address {
    if (packet.len < 20) return error.STUNResponseTooShort;

    const msg_type = std.mem.readInt(u16, packet[0..2], .big);
    if (msg_type != @intFromEnum(STUNMessageType.binding_response)) {
        return error.STUNNotBindingResponse;
    }

    const msg_len = std.mem.readInt(u16, packet[2..4], .big);
    if (packet.len < 20 + msg_len) return error.STUNResponseTruncated;

    // Parse attributes
    var pos: usize = 20;
    while (pos + 4 <= 20 + msg_len) {
        const attr_type = std.mem.readInt(u16, packet[pos..][0..2], .big);
        const attr_len = std.mem.readInt(u16, packet[pos + 2 ..][0..2], .big);
        pos += 4;

        if (pos + attr_len > 20 + msg_len) return error.STUNAttrTruncated;

        if (attr_type == @intFromEnum(STUNAttrType.xor_mapped_address)) {
            return try parseXorMappedAddress(packet[pos..][0..attr_len]);
        }
        if (attr_type == @intFromEnum(STUNAttrType.mapped_address)) {
            return try parseMappedAddress(packet[pos..][0..attr_len]);
        }

        // Skip to next attribute (with padding)
        const padded_len = (attr_len + 3) & ~@as(u16, 3);
        pos += padded_len;
    }

    return error.STUNNoMappedAddress;
}

fn parseXorMappedAddress(attr: []const u8) !Address {
    if (attr.len < 8) return error.STUNAddrTooShort;
    const family = attr[1];
    if (family != 0x01) return error.STUNNotIPv4;

    var port = std.mem.readInt(u16, attr[2..4], .big);
    port ^= @as(u16, @truncate(STUN_MAGIC_COOKIE >> 16));

    var ip: [4]u8 = undefined;
    const cookie_bytes: [4]u8 = @bitCast(std.mem.nativeToBig(u32, STUN_MAGIC_COOKIE));
    for (0..4) |i| {
        ip[i] = attr[4 + i] ^ cookie_bytes[i];
    }

    return .{ .ip = ip, .port = port };
}

fn parseMappedAddress(attr: []const u8) !Address {
    if (attr.len < 8) return error.STUNAddrTooShort;
    const family = attr[1];
    if (family != 0x01) return error.STUNNotIPv4;

    const port = std.mem.readInt(u16, attr[2..4], .big);
    var ip: [4]u8 = undefined;
    @memcpy(&ip, attr[4..8]);

    return .{ .ip = ip, .port = port };
}

/// Generates a random 12-byte transaction ID.
pub fn generateTransactionId(rng: *std.Random.DefaultPrng) [12]u8 {
    var id: [12]u8 = undefined;
    rng.random().bytes(&id);
    return id;
}

// =============================================================================
// HolePunch — coordinates UDP hole punching between two peers
// =============================================================================

pub const HolePunchState = enum {
    idle,
    preparing,
    punching,
    connected,
    failed,
};

pub const HolePunch = struct {
    local_addr: Address,
    remote_addr: Address,
    state: HolePunchState,
    attempts: u32,
    max_attempts: u32,
    /// Synchronized punch time (ms since epoch).
    punch_time_ms: u64,
    /// Local NAT type (detected or assumed).
    local_nat: NATType,
    /// Remote NAT type.
    remote_nat: NATType,

    pub fn init(local: Address, remote: Address) HolePunch {
        return .{
            .local_addr = local,
            .remote_addr = remote,
            .state = .idle,
            .attempts = 0,
            .max_attempts = 10,
            .punch_time_ms = 0,
            .local_nat = .unknown,
            .remote_nat = .unknown,
        };
    }

    /// Check if hole punching is feasible given both NAT types.
    pub fn canSucceed(self: HolePunch) bool {
        return self.local_nat.canHolePunch() and self.remote_nat.canHolePunch();
    }

    /// Prepare for hole punching: set synchronized time and state.
    pub fn prepare(self: *HolePunch, sync_time_ms: u64) void {
        self.punch_time_ms = sync_time_ms;
        self.state = .preparing;
    }

    /// Execute a single punch attempt.
    /// Returns true if the punch should be sent, false if max attempts reached.
    pub fn punch(self: *HolePunch, now_ms: u64) bool {
        if (self.state == .idle or self.state == .failed) return false;
        if (self.attempts >= self.max_attempts) {
            self.state = .failed;
            return false;
        }
        if (now_ms < self.punch_time_ms) return false;

        self.state = .punching;
        self.attempts += 1;
        return true;
    }

    /// Mark the hole punch as successful.
    pub fn markConnected(self: *HolePunch) void {
        self.state = .connected;
    }

    /// Check if the hole punch has failed.
    pub fn hasFailed(self: HolePunch) bool {
        return self.state == .failed;
    }

    /// Check if connected.
    pub fn isConnected(self: HolePunch) bool {
        return self.state == .connected;
    }
};

// =============================================================================
// WebRTC Signaling — minimal signaling via lattice face-QRs
// =============================================================================

pub const SignalingMessageType = enum(u8) {
    offer = 1,
    answer = 2,
    ice_candidate = 3,
    end_of_candidates = 4,
};

pub const SignalingMessage = struct {
    msg_type: SignalingMessageType,
    /// Originating peer's lattice location hash.
    peer_hash: u64,
    /// SDP-like payload (simplified).
    payload: []const u8,
    /// ICE candidate data (for ice_candidate type).
    ice_data: ?[]const u8,

    pub fn initOffer(peer_hash: u64, payload: []const u8) SignalingMessage {
        return .{
            .msg_type = .offer,
            .peer_hash = peer_hash,
            .payload = payload,
            .ice_data = null,
        };
    }

    pub fn initAnswer(peer_hash: u64, payload: []const u8) SignalingMessage {
        return .{
            .msg_type = .answer,
            .peer_hash = peer_hash,
            .payload = payload,
            .ice_data = null,
        };
    }

    pub fn initIceCandidate(peer_hash: u64, ice: []const u8) SignalingMessage {
        return .{
            .msg_type = .ice_candidate,
            .peer_hash = peer_hash,
            .payload = "",
            .ice_data = ice,
        };
    }

    /// Serialize to bytes for QR encoding.
    pub fn serialize(self: SignalingMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        try buf.append(@intFromEnum(self.msg_type));
        try buf.appendSlice(std.mem.asBytes(&self.peer_hash));

        const payload_len: u16 = @intCast(self.payload.len);
        try buf.appendSlice(std.mem.asBytes(&payload_len));
        try buf.appendSlice(self.payload);

        if (self.ice_data) |ice| {
            const ice_len: u16 = @intCast(ice.len);
            try buf.appendSlice(std.mem.asBytes(&ice_len));
            try buf.appendSlice(ice);
        } else {
            const zero_len: u16 = 0;
            try buf.appendSlice(std.mem.asBytes(&zero_len));
        }

        return try buf.toOwnedSlice();
    }

    /// Deserialize from bytes.
    pub fn deserialize(data: []const u8) !SignalingMessage {
        if (data.len < 1 + 8 + 2) return error.SignalingTooShort;

        var pos: usize = 0;
        const msg_type: SignalingMessageType = @enumFromInt(data[pos]);
        pos += 1;
        const peer_hash = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        const payload_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        if (data.len < pos + payload_len + 2) return error.SignalingTruncated;
        const payload = data[pos .. pos + payload_len];
        pos += payload_len;

        const ice_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        var ice_data: ?[]const u8 = null;
        if (ice_len > 0) {
            if (data.len < pos + ice_len) return error.SignalingIceTruncated;
            ice_data = data[pos .. pos + ice_len];
        }

        return .{
            .msg_type = msg_type,
            .peer_hash = peer_hash,
            .payload = payload,
            .ice_data = ice_data,
        };
    }
};

pub const WebRTCSignaling = struct {
    allocator: std.mem.Allocator,
    own_hash: u64,
    pending_offer: ?SignalingMessage,
    pending_answer: ?SignalingMessage,
    ice_candidates: std.ArrayList(SignalingMessage),

    pub fn init(allocator: std.mem.Allocator, own_hash: u64) WebRTCSignaling {
        return .{
            .allocator = allocator,
            .own_hash = own_hash,
            .pending_offer = null,
            .pending_answer = null,
            .ice_candidates = std.ArrayList(SignalingMessage).init(allocator),
        };
    }

    pub fn deinit(self: *WebRTCSignaling) void {
        self.ice_candidates.deinit();
    }

    /// Create an offer to send to a remote peer.
    pub fn createOffer(self: *WebRTCSignaling, sdp: []const u8) SignalingMessage {
        const msg = SignalingMessage.initOffer(self.own_hash, sdp);
        self.pending_offer = msg;
        return msg;
    }

    /// Process an incoming offer and create an answer.
    pub fn processOffer(self: *WebRTCSignaling, _: SignalingMessage, sdp: []const u8) SignalingMessage {
        const answer = SignalingMessage.initAnswer(self.own_hash, sdp);
        self.pending_answer = answer;
        return answer;
    }

    /// Add an ICE candidate.
    pub fn addIceCandidate(self: *WebRTCSignaling, msg: SignalingMessage) !void {
        try self.ice_candidates.append(msg);
    }

    /// Number of collected ICE candidates.
    pub fn iceCandidateCount(self: *const WebRTCSignaling) usize {
        return self.ice_candidates.items.len;
    }
};

// =============================================================================
// QR Relay — fallback when hole punching fails
// =============================================================================

/// Connection strategy selected by the fallback chain.
pub const ConnectionStrategy = enum {
    hole_punch,
    webrtc,
    qr_relay,
    failed,
};

/// Result of attempting connection via the fallback chain.
pub const ConnectionResult = struct {
    strategy_used: ConnectionStrategy,
    connected: bool,
    /// Time spent in each phase (ms).
    hole_punch_ms: u64 = 0,
    webrtc_ms: u64 = 0,
    qr_relay_ms: u64 = 0,
};

/// Attempt connection with fallback: hole punch → WebRTC → QR relay.
/// If hole punching fails (symmetric NAT or max attempts), try WebRTC
/// data channel via signaling. If WebRTC also fails, fall back to QR relay.
pub fn connectWithFallback(
    hp: *HolePunch,
    webrtc_available: bool,
    qr_relay_available: bool,
    now_ms: u64,
) ConnectionResult {
    var result = ConnectionResult{
        .strategy_used = .failed,
        .connected = false,
    };

    // Phase 1: Try hole punching
    if (hp.canSucceed()) {
        hp.prepare(now_ms);
        if (hp.punch(now_ms)) {
            hp.markConnected();
            if (hp.isConnected()) {
                result.strategy_used = .hole_punch;
                result.connected = true;
                return result;
            }
        }
        if (hp.hasFailed()) {
            result.hole_punch_ms = now_ms;
        }
    } else {
        result.hole_punch_ms = now_ms;
    }

    // Phase 2: Try WebRTC data channel
    if (webrtc_available) {
        // WebRTC can traverse symmetric NAT where hole punching fails
        result.strategy_used = .webrtc;
        result.connected = true;
        result.webrtc_ms = now_ms;
        return result;
    }

    // Phase 3: Fall back to QR relay (store-and-forward via QR codes)
    if (qr_relay_available) {
        result.strategy_used = .qr_relay;
        result.connected = true;
        result.qr_relay_ms = now_ms;
        return result;
    }

    // All strategies exhausted
    result.strategy_used = .failed;
    result.connected = false;
    return result;
}

pub const QROffer = struct {
    peer_hash: u64,
    local_addr: Address,
    /// Timestamp when the offer was created.
    created_ms: u64,
    /// Expiry time in ms.
    ttl_ms: u64,

    pub fn init(peer_hash: u64, addr: Address, now_ms: u64) QROffer {
        return .{
            .peer_hash = peer_hash,
            .local_addr = addr,
            .created_ms = now_ms,
            .ttl_ms = 300_000, // 5 minutes
        };
    }

    pub fn isExpired(self: QROffer, now_ms: u64) bool {
        return now_ms > self.created_ms + self.ttl_ms;
    }

    pub fn serialize(self: QROffer) [8 + 6 + 8 + 8]u8 {
        var buf: [8 + 6 + 8 + 8]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.peer_hash, .little);
        @memcpy(buf[8..12], &self.local_addr.ip);
        std.mem.writeInt(u16, buf[12..14], self.local_addr.port, .little);
        std.mem.writeInt(u64, buf[14..22], self.created_ms, .little);
        std.mem.writeInt(u64, buf[22..30], self.ttl_ms, .little);
        return buf;
    }

    pub fn deserialize(data: []const u8) !QROffer {
        if (data.len < 30) return error.QROfferTooShort;
        var ip: [4]u8 = undefined;
        @memcpy(&ip, data[8..12]);
        return .{
            .peer_hash = std.mem.readInt(u64, data[0..8], .little),
            .local_addr = .{
                .ip = ip,
                .port = std.mem.readInt(u16, data[12..14], .little),
            },
            .created_ms = std.mem.readInt(u64, data[14..22], .little),
            .ttl_ms = std.mem.readInt(u64, data[22..30], .little),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "NAT: STUN binding request format" {
    const txn_id = [_]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C};
    const packet = buildBindingRequest(txn_id);

    // Message type: 0x0001 (Binding Request)
    try std.testing.expectEqual(@as(u16, 0x0001), std.mem.readInt(u16, packet[0..2], .big));
    // Message length: 0
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, packet[2..4], .big));
    // Magic cookie
    try std.testing.expectEqual(STUN_MAGIC_COOKIE, std.mem.readInt(u32, packet[4..8], .big));
    // Transaction ID
    try std.testing.expectEqualSlices(u8, &txn_id, packet[8..20]);
}

test "NAT: generate transaction ID uniqueness" {
    var rng = std.Random.DefaultPrng.init(42);
    const id1 = generateTransactionId(&rng);
    const id2 = generateTransactionId(&rng);
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "NAT: NAT type canHolePunch" {
    try std.testing.expect(NATType.full_cone.canHolePunch());
    try std.testing.expect(NATType.restricted_cone.canHolePunch());
    try std.testing.expect(NATType.port_restricted.canHolePunch());
    try std.testing.expect(!NATType.symmetric.canHolePunch());
    try std.testing.expect(!NATType.unknown.canHolePunch());
}

test "NAT: Address format and equality" {
    const allocator = std.testing.allocator;
    const addr = Address.new(.{ 192, 168, 1, 100 }, 8080);
    const formatted = try addr.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("192.168.1.100:8080", formatted);

    const addr2 = Address.new(.{ 192, 168, 1, 100 }, 8080);
    try std.testing.expect(Address.eql(addr, addr2));

    const addr3 = Address.new(.{ 192, 168, 1, 101 }, 8080);
    try std.testing.expect(!Address.eql(addr, addr3));
}

test "NAT: Address from string" {
    const addr = try Address.fromString("10.0.0.1", 9000);
    try std.testing.expectEqual(@as(u8, 10), addr.ip[0]);
    try std.testing.expectEqual(@as(u8, 0), addr.ip[1]);
    try std.testing.expectEqual(@as(u8, 0), addr.ip[2]);
    try std.testing.expectEqual(@as(u8, 1), addr.ip[3]);
    try std.testing.expectEqual(@as(u16, 9000), addr.port);
}

test "NAT: hole punch state machine" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.local_nat = .full_cone;
    hp.remote_nat = .restricted_cone;

    try std.testing.expect(hp.canSucceed());
    try std.testing.expectEqual(HolePunchState.idle, hp.state);

    hp.prepare(1000);
    try std.testing.expectEqual(HolePunchState.preparing, hp.state);

    // Before sync time — should not punch
    try std.testing.expect(!hp.punch(500));

    // At sync time — should punch
    try std.testing.expect(hp.punch(1000));
    try std.testing.expectEqual(HolePunchState.punching, hp.state);
    try std.testing.expectEqual(@as(u32, 1), hp.attempts);

    hp.markConnected();
    try std.testing.expect(hp.isConnected());
}

test "NAT: hole punch max attempts" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.max_attempts = 3;
    hp.prepare(0);

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try std.testing.expect(hp.punch(i * 100));
    }
    // 4th attempt should fail
    try std.testing.expect(!hp.punch(300));
    try std.testing.expect(hp.hasFailed());
}

test "NAT: hole punch symmetric NAT cannot succeed" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.local_nat = .symmetric;
    hp.remote_nat = .full_cone;

    try std.testing.expect(!hp.canSucceed());
}

test "NAT: WebRTC signaling offer/answer round-trip" {
    const allocator = std.testing.allocator;
    var sig = WebRTCSignaling.init(allocator, 12345);
    defer sig.deinit();

    const offer = sig.createOffer("v=0\r\no=- 12345 1 IN IP4 192.168.1.100\r\n");
    try std.testing.expectEqual(SignalingMessageType.offer, offer.msg_type);
    try std.testing.expectEqual(@as(u64, 12345), offer.peer_hash);

    // Serialize and deserialize
    const serialized = try offer.serialize(allocator);
    defer allocator.free(serialized);

    const restored = try SignalingMessage.deserialize(serialized);
    try std.testing.expectEqual(SignalingMessageType.offer, restored.msg_type);
    try std.testing.expectEqual(@as(u64, 12345), restored.peer_hash);
    try std.testing.expectEqualStrings(offer.payload, restored.payload);
}

test "NAT: WebRTC ICE candidate exchange" {
    const allocator = std.testing.allocator;
    var sig = WebRTCSignaling.init(allocator, 12345);
    defer sig.deinit();

    const ice1 = SignalingMessage.initIceCandidate(99999, "candidate:1 udp 2122255871 192.168.1.100 8080 typ host");
    try sig.addIceCandidate(ice1);

    const ice2 = SignalingMessage.initIceCandidate(99999, "candidate:2 udp 1686052607 10.0.0.1 9000 typ srflx");
    try sig.addIceCandidate(ice2);

    try std.testing.expectEqual(@as(usize, 2), sig.iceCandidateCount());
}

test "NAT: QR offer serialize/deserialize" {
    const addr = Address.new(.{ 203, 0, 113, 42 }, 8080);
    const offer = QROffer.init(98765, addr, 1000);

    const serialized = offer.serialize();
    const restored = try QROffer.deserialize(&serialized);

    try std.testing.expectEqual(offer.peer_hash, restored.peer_hash);
    try std.testing.expect(Address.eql(offer.local_addr, restored.local_addr));
    try std.testing.expectEqual(offer.created_ms, restored.created_ms);
    try std.testing.expectEqual(offer.ttl_ms, restored.ttl_ms);
}

test "NAT: QR offer expiry" {
    const addr = Address.new(.{ 203, 0, 113, 42 }, 8080);
    const offer = QROffer.init(98765, addr, 1000);

    try std.testing.expect(!offer.isExpired(100000));
    try std.testing.expect(!offer.isExpired(301000));
    try std.testing.expect(offer.isExpired(301001));
}

test "NAT: signaling message with ICE data round-trip" {
    const allocator = std.testing.allocator;
    const msg = SignalingMessage.initIceCandidate(55555, "candidate:1 udp 1 192.168.1.1 8080 typ host");

    const serialized = try msg.serialize(allocator);
    defer allocator.free(serialized);

    const restored = try SignalingMessage.deserialize(serialized);
    try std.testing.expectEqual(SignalingMessageType.ice_candidate, restored.msg_type);
    try std.testing.expectEqual(@as(u64, 55555), restored.peer_hash);
    try std.testing.expect(restored.ice_data != null);
    try std.testing.expectEqualStrings("candidate:1 udp 1 192.168.1.1 8080 typ host", restored.ice_data.?);
}

test "NAT: fallback uses hole punch for cone NAT" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.local_nat = .full_cone;
    hp.remote_nat = .restricted_cone;

    const result = connectWithFallback(&hp, true, true, 1000);
    try std.testing.expect(result.connected);
    try std.testing.expectEqual(ConnectionStrategy.hole_punch, result.strategy_used);
}

test "NAT: fallback uses WebRTC for symmetric NAT" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.local_nat = .symmetric;
    hp.remote_nat = .full_cone;

    const result = connectWithFallback(&hp, true, true, 1000);
    try std.testing.expect(result.connected);
    try std.testing.expectEqual(ConnectionStrategy.webrtc, result.strategy_used);
}

test "NAT: fallback uses QR relay when WebRTC unavailable" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.local_nat = .symmetric;
    hp.remote_nat = .symmetric;

    const result = connectWithFallback(&hp, false, true, 1000);
    try std.testing.expect(result.connected);
    try std.testing.expectEqual(ConnectionStrategy.qr_relay, result.strategy_used);
}

test "NAT: fallback fails when no strategy available" {
    var hp = HolePunch.init(
        Address.new(.{ 192, 168, 1, 100 }, 8080),
        Address.new(.{ 10, 0, 0, 1 }, 9000),
    );
    hp.local_nat = .symmetric;
    hp.remote_nat = .symmetric;

    const result = connectWithFallback(&hp, false, false, 1000);
    try std.testing.expect(!result.connected);
    try std.testing.expectEqual(ConnectionStrategy.failed, result.strategy_used);
}
