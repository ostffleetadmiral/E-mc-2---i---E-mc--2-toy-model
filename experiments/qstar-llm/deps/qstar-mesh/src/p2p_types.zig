//! p2p_types.zig — P2P primitives for Qstar mesh networking.
//!
//! Ported from Rations' p2p/peer.zig, p2p/gossip.zig, and p2p/routing.zig.
//! Provides peer identity, message protocol, relay routing headers,
//! gossip broadcast, and small-world ring routing — all integer-only,
//! zero-dependency (std only).
//!
//! Message wire format:
//!   [msg_type:1][sender_id:32][payload_len:4] = 41-byte header + payload
//!
//! Relay route wire format (payload of a relay_route message):
//!   [target_id:32][origin_id:32][ttl:1][hop_count:1][inner_msg_type:1][inner_len:4]
//!   = 71-byte relay header + inner payload

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Timestamp — uses JS extern on WASM, std.time on native.
// ============================================================================

fn timestamp() u64 {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const f = @extern(*const fn () callconv(.C) u64, .{ .name = "js_time_now" });
        return f();
    } else {
        return @intCast(std.time.timestamp());
    }
}

// ============================================================================
// Peer Identity & State
// ============================================================================

/// Peer identity — 32-byte Ed25519 public key (or lattice-derived identifier).
pub const PeerId = [32]u8;

/// Location on the small-world ring — u128 interpreted as position on [0, 1) ring.
pub const Location = u128;

/// Peer connection state.
pub const ConnectionState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    closing = 3,
    closed = 4,
};

/// Peer promotion state (from freenet-core).
pub const PeerState = enum(u8) {
    transient = 0, // Temporary connection
    ring_promoted = 1, // Part of the routing ring
};

/// A peer with identity, location, and connection state.
pub const Peer = struct {
    id: PeerId,
    location: Location,
    conn_id: u32, // Connection ID (assigned by transport layer)
    state: ConnectionState,
    peer_state: PeerState,
    connected_at: u64,
    last_seen: u64,

    /// Compute distance from this peer to a target location on the ring.
    /// Distance is the minimum of clockwise and counter-clockwise distance.
    pub fn distanceTo(self: Peer, target: Location) Location {
        return ringDistance(self.location, target);
    }

    /// Check if this peer is connected.
    pub fn isConnected(self: Peer) bool {
        return self.state == .connected;
    }
};

/// Peer manager — tracks all known peers and their states.
pub const PeerManager = struct {
    peers: std.ArrayListUnmanaged(Peer) = .{},
    allocator: std.mem.Allocator,
    max_connections: usize = 8,

    pub fn init(allocator: std.mem.Allocator) PeerManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PeerManager) void {
        self.peers.deinit(self.allocator);
    }

    /// Add or update a peer.
    pub fn addPeer(self: *PeerManager, id: PeerId, location: Location, conn_id: u32) void {
        for (self.peers.items) |*p| {
            if (std.mem.eql(u8, &p.id, &id)) {
                p.location = location;
                p.conn_id = conn_id;
                p.state = .connected;
                p.connected_at = timestamp();
                p.last_seen = p.connected_at;
                return;
            }
        }
        self.peers.append(self.allocator, .{
            .id = id,
            .location = location,
            .conn_id = conn_id,
            .state = .connected,
            .peer_state = .transient,
            .connected_at = timestamp(),
            .last_seen = timestamp(),
        }) catch {};
    }

    /// Remove a peer by connection ID.
    pub fn removePeer(self: *PeerManager, conn_id: u32) void {
        var i: usize = 0;
        while (i < self.peers.items.len) {
            if (self.peers.items[i].conn_id == conn_id) {
                _ = self.peers.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Get peer by connection ID.
    pub fn getByConnId(self: *const PeerManager, conn_id: u32) ?*const Peer {
        for (self.peers.items) |*p| {
            if (p.conn_id == conn_id) return p;
        }
        return null;
    }

    /// Get peer by PeerId.
    pub fn getById(self: *const PeerManager, id: PeerId) ?*const Peer {
        for (self.peers.items) |*p| {
            if (std.mem.eql(u8, &p.id, &id)) return p;
        }
        return null;
    }

    /// Get all peers.
    pub fn allPeers(self: *const PeerManager) []const Peer {
        return self.peers.items;
    }

    /// Count of connected peers.
    pub fn connectedCount(self: *const PeerManager) usize {
        var count: usize = 0;
        for (self.peers.items) |p| {
            if (p.isConnected()) count += 1;
        }
        return count;
    }

    /// Update last_seen for a peer.
    pub fn touch(self: *PeerManager, conn_id: u32) void {
        for (self.peers.items) |*p| {
            if (p.conn_id == conn_id) {
                p.last_seen = timestamp();
                return;
            }
        }
    }

    /// Promote a peer to ring_promoted state.
    pub fn promote(self: *PeerManager, conn_id: u32) void {
        for (self.peers.items) |*p| {
            if (p.conn_id == conn_id) {
                p.peer_state = .ring_promoted;
                return;
            }
        }
    }
};

// ============================================================================
// Message Protocol
// ============================================================================

/// Message types for P2P protocol.
pub const MessageType = enum(u8) {
    connect = 0,
    disconnect = 1,
    data = 2,
    control = 3,
    gossip = 4,
    state_sync = 5,
    state_delta = 6,
    transaction = 7,
    block = 8,
    ping = 9,
    pong = 10,
    relay_route = 11,
    rendezvous_req = 12,
    rendezvous_res = 13,
    peer_discover = 14,
};

/// P2P message header — 41 bytes.
pub const MessageHeader = struct {
    msg_type: MessageType,
    sender_id: PeerId,
    payload_len: u32,

    pub const SIZE: usize = 41;

    /// Serialize header to bytes.
    pub fn serialize(self: MessageHeader, out: *[SIZE]u8) void {
        out[0] = @intFromEnum(self.msg_type);
        @memcpy(out[1..][0..32], &self.sender_id);
        std.mem.writeInt(u32, out[33..][0..4], self.payload_len, .little);
    }

    /// Deserialize header from bytes.
    pub fn deserialize(data: []const u8) ?MessageHeader {
        if (data.len < SIZE) return null;
        return MessageHeader{
            .msg_type = @enumFromInt(data[0]),
            .sender_id = data[1..][0..32].*,
            .payload_len = std.mem.readInt(u32, data[33..][0..4], .little),
        };
    }
};

/// Relay route header for multi-hop packet forwarding across firewalled networks.
pub const RelayRouteHeader = struct {
    target_id: PeerId,
    origin_id: PeerId,
    ttl: u8,
    hop_count: u8,
    inner_msg_type: MessageType,
    inner_len: u32,

    pub const SIZE: usize = 71;

    /// Serialize relay header to bytes (71 bytes).
    pub fn serialize(self: RelayRouteHeader, out: *[SIZE]u8) void {
        @memcpy(out[0..32], &self.target_id);
        @memcpy(out[32..64], &self.origin_id);
        out[64] = self.ttl;
        out[65] = self.hop_count;
        out[66] = @intFromEnum(self.inner_msg_type);
        std.mem.writeInt(u32, out[67..71], self.inner_len, .little);
    }

    /// Deserialize relay header from bytes.
    pub fn deserialize(data: []const u8) ?RelayRouteHeader {
        if (data.len < SIZE) return null;
        return RelayRouteHeader{
            .target_id = data[0..32].*,
            .origin_id = data[32..64].*,
            .ttl = data[64],
            .hop_count = data[65],
            .inner_msg_type = @enumFromInt(data[66]),
            .inner_len = std.mem.readInt(u32, data[67..71], .little),
        };
    }
};

/// State summary for sync — compact representation of peer state.
pub const StateSummary = struct {
    block_height: u64,
    tx_count: u64,
    state_root: [32]u8,

    pub const SIZE: usize = 48;

    /// Serialize to bytes.
    pub fn serialize(self: StateSummary, out: *[SIZE]u8) void {
        std.mem.writeInt(u64, out[0..][0..8], self.block_height, .little);
        std.mem.writeInt(u64, out[8..][0..8], self.tx_count, .little);
        @memcpy(out[16..][0..32], &self.state_root);
    }

    /// Deserialize from bytes.
    pub fn deserialize(data: []const u8) ?StateSummary {
        if (data.len < SIZE) return null;
        return StateSummary{
            .block_height = std.mem.readInt(u64, data[0..][0..8], .little),
            .tx_count = std.mem.readInt(u64, data[8..][0..8], .little),
            .state_root = data[16..][0..32].*,
        };
    }
};

/// Check if two state summaries match.
pub fn summariesMatch(a: StateSummary, b: StateSummary) bool {
    return a.block_height == b.block_height and
        a.tx_count == b.tx_count and
        std.mem.eql(u8, &a.state_root, &b.state_root);
}

// ============================================================================
// Gossip Protocol
// ============================================================================

/// Gossip protocol — broadcast messages to all connected peers with
/// bounded concurrency.
pub const Gossip = struct {
    allocator: std.mem.Allocator,
    broadcast_queue: std.fifo.LinearFifo([*]u8, .Dynamic),
    max_concurrent: usize = 3,
    active_broadcasts: usize = 0,
    total_sent: u64 = 0,
    total_received: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Gossip {
        return .{
            .allocator = allocator,
            .broadcast_queue = std.fifo.LinearFifo([*]u8, .Dynamic).init(allocator),
        };
    }

    pub fn deinit(self: *Gossip) void {
        self.broadcast_queue.deinit();
    }

    /// Queue a message for broadcast to all peers.
    pub fn broadcast(self: *Gossip, msg_ptr: [*]u8) bool {
        self.broadcast_queue.writeItem(msg_ptr) catch return false;
        return true;
    }

    /// Get the next message to broadcast.
    /// Returns null if queue is empty or max concurrent reached.
    pub fn nextBroadcast(self: *Gossip) ?[*]u8 {
        if (self.active_broadcasts >= self.max_concurrent) return null;
        const msg = self.broadcast_queue.readItem() orelse return null;
        self.active_broadcasts += 1;
        return msg;
    }

    /// Mark a broadcast as complete.
    pub fn broadcastComplete(self: *Gossip) void {
        if (self.active_broadcasts > 0) self.active_broadcasts -= 1;
        self.total_sent += 1;
    }

    /// Record a received gossip message.
    pub fn messageReceived(self: *Gossip) void {
        self.total_received += 1;
    }

    /// Get queue length.
    pub fn queueLength(self: *const Gossip) usize {
        return self.broadcast_queue.count;
    }
};

// ============================================================================
// Small-World Ring Routing
// ============================================================================

/// Compute ring distance between two locations.
/// Distance is the minimum of clockwise and counter-clockwise.
pub fn ringDistance(a: Location, b: Location) Location {
    const ring_size: Location = std.math.maxInt(Location);
    const d_cw = if (b >= a) b - a else ring_size - a + b;
    const d_ccw = if (a >= b) a - b else ring_size - b + a;
    return @min(d_cw, d_ccw);
}

/// Generate a Kleinberg-optimal connection distance for small-world routing.
pub fn kleinbergGap(n: usize, index: usize) Location {
    if (n == 0) return 0;
    const base: Location = @as(Location, n) + 1;
    var gap: Location = base;
    var i: usize = 0;
    while (i < index) : (i += 1) {
        gap = gap * base;
    }
    return gap;
}

/// Add jitter to a location for exploration/bootstrap.
/// Jitter is ±10% random perturbation.
pub fn addJitter(loc: Location, jitter_amount: Location) Location {
    const ring_size: Location = std.math.maxInt(Location);
    if (jitter_amount == 0) return loc;
    if (loc >= jitter_amount) {
        return loc - jitter_amount;
    } else {
        return ring_size - (jitter_amount - loc);
    }
}

/// Find the closest peer to a target location from a list.
pub fn closestPeer(peers: []const Peer, target: Location) ?*const Peer {
    if (peers.len == 0) return null;
    var best: ?*const Peer = null;
    var best_dist: Location = std.math.maxInt(Location);
    for (peers) |*p| {
        if (!p.isConnected()) continue;
        const d = ringDistance(p.location, target);
        if (d < best_dist) {
            best_dist = d;
            best = p;
        }
    }
    return best;
}

/// Sort peers by distance to a target location (closest first).
pub fn sortByDistance(peers: []Peer, target: Location) void {
    std.mem.sort(Peer, peers, target, struct {
        fn lessThan(t: Location, a: Peer, b: Peer) bool {
            return ringDistance(a.location, t) < ringDistance(b.location, t);
        }
    }.lessThan);
}

/// Generate a deterministic location on the ring from a seed (e.g. PeerId).
pub fn locationFromSeed(seed: []const u8) Location {
    var result: Location = 0;
    var pos: usize = 0;
    while (pos < 16 and pos < seed.len) : (pos += 1) {
        result = (result << 8) | seed[pos];
    }
    while (pos < 16) : (pos += 1) {
        result = result << 8;
    }
    return result;
}

/// Route a message directly to a target PeerId or to the closest intermediate peer.
/// If target is directly connected, returns its conn_id.
/// Otherwise routes to the closest ring neighbor, excluding the incoming connection
/// to prevent loops.
pub fn routeToPeer(
    peers: []const Peer,
    my_location: Location,
    target_id: PeerId,
    exclude_conn: u32,
) ?u32 {
    _ = my_location;
    if (peers.len == 0) return null;

    // Check direct connection first
    for (peers) |p| {
        if (!p.isConnected()) continue;
        if (p.conn_id == exclude_conn) continue;
        if (std.mem.eql(u8, &p.id, &target_id)) {
            return p.conn_id;
        }
    }

    // Fallback: Greedy ring routing to target location
    const target_loc = locationFromSeed(&target_id);
    var best_conn: ?u32 = null;
    var best_distance: Location = std.math.maxInt(Location);

    for (peers) |p| {
        if (!p.isConnected()) continue;
        if (p.conn_id == exclude_conn) continue;
        const d = ringDistance(p.location, target_loc);
        if (d < best_distance) {
            best_distance = d;
            best_conn = p.conn_id;
        }
    }

    return best_conn;
}

/// Route a message to the peer closest to the target location.
/// Returns the connection ID of the next hop, or null if this node is the closest.
pub fn routeToTarget(
    peers: []const Peer,
    my_location: Location,
    target: Location,
) ?u32 {
    if (peers.len == 0) return null;

    var best_conn: u32 = 0;
    var best_distance: Location = ringDistance(my_location, target);
    var found = false;

    for (peers) |p| {
        if (!p.isConnected()) continue;
        const d = ringDistance(p.location, target);
        if (d < best_distance) {
            best_distance = d;
            best_conn = p.conn_id;
            found = true;
        }
    }

    if (found) return best_conn;
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "peer distance on ring" {
    const peer = Peer{
        .id = [_]u8{0} ** 32,
        .location = 100,
        .conn_id = 0,
        .state = .connected,
        .peer_state = .transient,
        .connected_at = 0,
        .last_seen = 0,
    };
    const d = peer.distanceTo(150);
    try std.testing.expectEqual(@as(Location, 50), d);
}

test "peer distance wraps around ring" {
    const peer = Peer{
        .id = [_]u8{0} ** 32,
        .location = std.math.maxInt(Location) - 10,
        .conn_id = 0,
        .state = .connected,
        .peer_state = .transient,
        .connected_at = 0,
        .last_seen = 0,
    };
    const d = peer.distanceTo(10);
    try std.testing.expect(d <= 21);
}

test "peer manager add and find" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const id = [_]u8{0x42} ** 32;
    pm.addPeer(id, 12345, 1);

    const peer = pm.getByConnId(1).?;
    try std.testing.expectEqualSlices(u8, &id, &peer.id);
    try std.testing.expectEqual(@as(Location, 12345), peer.location);
}

test "peer manager remove" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    pm.addPeer([_]u8{0x01} ** 32, 100, 1);
    pm.addPeer([_]u8{0x02} ** 32, 200, 2);

    try std.testing.expectEqual(@as(usize, 2), pm.peers.items.len);
    pm.removePeer(1);
    try std.testing.expectEqual(@as(usize, 1), pm.peers.items.len);
    try std.testing.expect(pm.getByConnId(1) == null);
    try std.testing.expect(pm.getByConnId(2) != null);
}

test "peer manager update existing" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const id = [_]u8{0x42} ** 32;
    pm.addPeer(id, 100, 1);
    pm.addPeer(id, 200, 1);

    try std.testing.expectEqual(@as(usize, 1), pm.peers.items.len);
    try std.testing.expectEqual(@as(Location, 200), pm.getById(id).?.location);
}

test "peer manager promote" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    pm.addPeer([_]u8{0x01} ** 32, 100, 1);
    try std.testing.expectEqual(PeerState.transient, pm.getByConnId(1).?.peer_state);
    pm.promote(1);
    try std.testing.expectEqual(PeerState.ring_promoted, pm.getByConnId(1).?.peer_state);
}

test "peer manager connected count" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    pm.addPeer([_]u8{0x01} ** 32, 100, 1);
    pm.addPeer([_]u8{0x02} ** 32, 200, 2);
    try std.testing.expectEqual(@as(usize, 2), pm.connectedCount());
}

test "message header serialize/deserialize roundtrip" {
    const header = MessageHeader{
        .msg_type = .gossip,
        .sender_id = [_]u8{0x42} ** 32,
        .payload_len = 1024,
    };

    var buf: [MessageHeader.SIZE]u8 = undefined;
    header.serialize(&buf);

    const restored = MessageHeader.deserialize(&buf).?;
    try std.testing.expectEqual(header.msg_type, restored.msg_type);
    try std.testing.expectEqualSlices(u8, &header.sender_id, &restored.sender_id);
    try std.testing.expectEqual(header.payload_len, restored.payload_len);
}

test "message header rejects short data" {
    const short_data = [_]u8{0} ** 40;
    try std.testing.expect(MessageHeader.deserialize(&short_data) == null);
}

test "message header all message types roundtrip" {
    const types = [_]MessageType{
        .connect, .disconnect, .data, .control, .gossip,
        .state_sync, .state_delta, .transaction, .block,
        .ping, .pong, .relay_route, .rendezvous_req,
        .rendezvous_res, .peer_discover,
    };

    for (types) |mt| {
        const header = MessageHeader{
            .msg_type = mt,
            .sender_id = [_]u8{0xAB} ** 32,
            .payload_len = 256,
        };
        var buf: [MessageHeader.SIZE]u8 = undefined;
        header.serialize(&buf);
        const restored = MessageHeader.deserialize(&buf).?;
        try std.testing.expectEqual(mt, restored.msg_type);
    }
}

test "relay route header serialize/deserialize roundtrip" {
    const header = RelayRouteHeader{
        .target_id = [_]u8{0x11} ** 32,
        .origin_id = [_]u8{0x22} ** 32,
        .ttl = 8,
        .hop_count = 1,
        .inner_msg_type = .data,
        .inner_len = 512,
    };

    var buf: [RelayRouteHeader.SIZE]u8 = undefined;
    header.serialize(&buf);

    const restored = RelayRouteHeader.deserialize(&buf).?;
    try std.testing.expectEqualSlices(u8, &header.target_id, &restored.target_id);
    try std.testing.expectEqualSlices(u8, &header.origin_id, &restored.origin_id);
    try std.testing.expectEqual(header.ttl, restored.ttl);
    try std.testing.expectEqual(header.hop_count, restored.hop_count);
    try std.testing.expectEqual(header.inner_msg_type, restored.inner_msg_type);
    try std.testing.expectEqual(header.inner_len, restored.inner_len);
}

test "relay route header rejects short data" {
    const short_buf = [_]u8{0} ** 70;
    try std.testing.expect(RelayRouteHeader.deserialize(&short_buf) == null);
}

test "relay route header ttl zero and max" {
    const hdr_min = RelayRouteHeader{
        .target_id = [_]u8{0} ** 32,
        .origin_id = [_]u8{0} ** 32,
        .ttl = 0,
        .hop_count = 0,
        .inner_msg_type = .gossip,
        .inner_len = 0,
    };
    var buf: [RelayRouteHeader.SIZE]u8 = undefined;
    hdr_min.serialize(&buf);
    const restored_min = RelayRouteHeader.deserialize(&buf).?;
    try std.testing.expectEqual(@as(u8, 0), restored_min.ttl);
    try std.testing.expectEqual(@as(u8, 0), restored_min.hop_count);

    const hdr_max = RelayRouteHeader{
        .target_id = [_]u8{0xFF} ** 32,
        .origin_id = [_]u8{0xFF} ** 32,
        .ttl = 255,
        .hop_count = 255,
        .inner_msg_type = .peer_discover,
        .inner_len = std.math.maxInt(u32),
    };
    hdr_max.serialize(&buf);
    const restored_max = RelayRouteHeader.deserialize(&buf).?;
    try std.testing.expectEqual(@as(u8, 255), restored_max.ttl);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), restored_max.inner_len);
}

test "gossip queue and broadcast" {
    var gossip = Gossip.init(std.testing.allocator);
    defer gossip.deinit();

    const msg1: [*]u8 = @ptrFromInt(0x1000);
    const msg2: [*]u8 = @ptrFromInt(0x2000);

    try std.testing.expect(gossip.broadcast(msg1));
    try std.testing.expect(gossip.broadcast(msg2));
    try std.testing.expectEqual(@as(usize, 2), gossip.queueLength());

    const next = gossip.nextBroadcast().?;
    try std.testing.expectEqual(msg1, next);
    try std.testing.expectEqual(@as(usize, 1), gossip.active_broadcasts);

    gossip.broadcastComplete();
    try std.testing.expectEqual(@as(usize, 0), gossip.active_broadcasts);
    try std.testing.expectEqual(@as(u64, 1), gossip.total_sent);
}

test "gossip respects max concurrent" {
    var gossip = Gossip.init(std.testing.allocator);
    defer gossip.deinit();
    gossip.max_concurrent = 2;

    const msg1: [*]u8 = @ptrFromInt(0x1000);
    const msg2: [*]u8 = @ptrFromInt(0x2000);
    const msg3: [*]u8 = @ptrFromInt(0x3000);

    _ = gossip.broadcast(msg1);
    _ = gossip.broadcast(msg2);
    _ = gossip.broadcast(msg3);

    try std.testing.expect(gossip.nextBroadcast() != null);
    try std.testing.expect(gossip.nextBroadcast() != null);
    try std.testing.expect(gossip.nextBroadcast() == null);

    gossip.broadcastComplete();
    try std.testing.expect(gossip.nextBroadcast() != null);
}

test "gossip message received counter" {
    var gossip = Gossip.init(std.testing.allocator);
    defer gossip.deinit();

    gossip.messageReceived();
    gossip.messageReceived();
    gossip.messageReceived();
    try std.testing.expectEqual(@as(u64, 3), gossip.total_received);
}

test "state summary serialize/deserialize roundtrip" {
    const summary = StateSummary{
        .block_height = 42,
        .tx_count = 100,
        .state_root = [_]u8{0xAB} ** 32,
    };

    var buf: [StateSummary.SIZE]u8 = undefined;
    summary.serialize(&buf);

    const restored = StateSummary.deserialize(&buf).?;
    try std.testing.expectEqual(summary.block_height, restored.block_height);
    try std.testing.expectEqual(summary.tx_count, restored.tx_count);
    try std.testing.expectEqualSlices(u8, &summary.state_root, &restored.state_root);
}

test "state summary rejects short data" {
    const short = [_]u8{0} ** 47;
    try std.testing.expect(StateSummary.deserialize(&short) == null);
}

test "summaries match" {
    const a = StateSummary{
        .block_height = 10,
        .tx_count = 50,
        .state_root = [_]u8{0x01} ** 32,
    };
    const b = StateSummary{
        .block_height = 10,
        .tx_count = 50,
        .state_root = [_]u8{0x01} ** 32,
    };
    const c = StateSummary{
        .block_height = 11,
        .tx_count = 50,
        .state_root = [_]u8{0x01} ** 32,
    };

    try std.testing.expect(summariesMatch(a, b));
    try std.testing.expect(!summariesMatch(a, c));
}

test "ring distance basic" {
    const d = ringDistance(100, 200);
    try std.testing.expectEqual(@as(Location, 100), d);
}

test "ring distance symmetric" {
    const d1 = ringDistance(100, 200);
    const d2 = ringDistance(200, 100);
    try std.testing.expectEqual(d1, d2);
}

test "ring distance wrap-around" {
    const ring_size: Location = std.math.maxInt(Location);
    const d = ringDistance(ring_size - 10, 10);
    try std.testing.expect(d <= 21);
}

test "ring distance to self is zero" {
    const d = ringDistance(42, 42);
    try std.testing.expectEqual(@as(Location, 0), d);
}

test "routing finds closest peer" {
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 100, .conn_id = 1, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x02} ** 32, .location = 500, .conn_id = 2, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x03} ** 32, .location = 200, .conn_id = 3, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    const closest = closestPeer(&peers, 180).?;
    try std.testing.expectEqual(@as(u32, 3), closest.conn_id);
}

test "routing route to target" {
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 100, .conn_id = 1, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x02} ** 32, .location = 500, .conn_id = 2, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x03} ** 32, .location = 200, .conn_id = 3, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    const next = routeToTarget(&peers, 1000, 180);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(@as(u32, 3), next.?);
}

test "routing returns null when self is closest" {
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 100, .conn_id = 1, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    const next = routeToTarget(&peers, 50, 60);
    try std.testing.expect(next == null);
}

test "routing skips disconnected peers" {
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 100, .conn_id = 1, .state = .disconnected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x02} ** 32, .location = 200, .conn_id = 2, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    const next = routeToTarget(&peers, 1000, 180);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(@as(u32, 2), next.?);
}

test "routing sort by distance" {
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 500, .conn_id = 1, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x02} ** 32, .location = 100, .conn_id = 2, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x03} ** 32, .location = 200, .conn_id = 3, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    sortByDistance(&peers, 180);

    try std.testing.expectEqual(@as(u32, 3), peers[0].conn_id);
    try std.testing.expectEqual(@as(u32, 2), peers[1].conn_id);
    try std.testing.expectEqual(@as(u32, 1), peers[2].conn_id);
}

test "location from seed deterministic" {
    const seed = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    const loc = locationFromSeed(&seed);
    try std.testing.expect(loc != 0);
    try std.testing.expectEqual(loc, locationFromSeed(&seed));
}

test "location from short seed pads with zeros" {
    const seed = [_]u8{0xFF};
    const loc = locationFromSeed(&seed);
    // Should be 0xFF << 120
    const expected: Location = @as(Location, 0xFF) << 120;
    try std.testing.expectEqual(expected, loc);
}

test "kleinberg gap produces increasing distances" {
    const n: usize = 100;
    const g0 = kleinbergGap(n, 0);
    const g1 = kleinbergGap(n, 1);
    const g2 = kleinbergGap(n, 2);
    try std.testing.expect(g0 < g1);
    try std.testing.expect(g1 < g2);
}

test "route to peer direct and fallback" {
    const target_id = [_]u8{0x03} ** 32;
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 100, .conn_id = 1, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x02} ** 32, .location = 500, .conn_id = 2, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = target_id, .location = 200, .conn_id = 3, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    const direct_conn = routeToPeer(&peers, 1000, target_id, 0);
    try std.testing.expectEqual(@as(u32, 3), direct_conn.?);

    const fallback_conn = routeToPeer(&peers, 1000, target_id, 3);
    try std.testing.expect(fallback_conn != null);
    try std.testing.expect(fallback_conn.? != 3);
}

test "route to peer returns null with no peers" {
    const target_id = [_]u8{0x03} ** 32;
    const peers: []const Peer = &[_]Peer{};
    const result = routeToPeer(peers, 1000, target_id, 0);
    try std.testing.expect(result == null);
}

test "add jitter reduces location" {
    const loc: Location = 1000;
    const jitter: Location = 100;
    const result = addJitter(loc, jitter);
    try std.testing.expectEqual(@as(Location, 900), result);
}

test "add jitter wraps around ring" {
    const loc: Location = 50;
    const jitter: Location = 100;
    const result = addJitter(loc, jitter);
    const ring_size: Location = std.math.maxInt(Location);
    try std.testing.expectEqual(ring_size - 50, result);
}

test "add jitter zero is no-op" {
    const loc: Location = 12345;
    const result = addJitter(loc, 0);
    try std.testing.expectEqual(loc, result);
}

test "closest peer returns null for empty list" {
    const peers: []const Peer = &[_]Peer{};
    try std.testing.expect(closestPeer(peers, 100) == null);
}

test "closest peer skips disconnected" {
    var peers = [_]Peer{
        .{ .id = [_]u8{0x01} ** 32, .location = 100, .conn_id = 1, .state = .disconnected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
        .{ .id = [_]u8{0x02} ** 32, .location = 200, .conn_id = 2, .state = .connected, .peer_state = .transient, .connected_at = 0, .last_seen = 0 },
    };

    const closest = closestPeer(&peers, 150).?;
    try std.testing.expectEqual(@as(u32, 2), closest.conn_id);
}
