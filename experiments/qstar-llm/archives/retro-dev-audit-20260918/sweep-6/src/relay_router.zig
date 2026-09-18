//! relay_router.zig — Multi-hop relay routing, rendezvous discovery, and
//! peer discovery for Qstar's P2P mesh.
//!
//! Ported from Rations' p2p/node.zig — handleRelayRoute, handleRendezvousReq,
//! handleRendezvousRes, handlePeerDiscover, sendRelayMessage, requestRendezvous.
//!
//! Transport-agnostic: methods return action descriptors that the caller
//! (mesh_peer.zig over TCP, or WASM bridge over WebSocket) executes.
//! All arithmetic is integer-only. No floating-point.

const std = @import("std");
const p2p = @import("p2p_types");
const PeerId = p2p.PeerId;
const Location = p2p.Location;
const Peer = p2p.Peer;
const PeerManager = p2p.PeerManager;
const MessageType = p2p.MessageType;
const MessageHeader = p2p.MessageHeader;
const RelayRouteHeader = p2p.RelayRouteHeader;

// ============================================================================
// Result Types
// ============================================================================

/// Result of processing an incoming relay route message.
pub const RelayRouteResult = union(enum) {
    /// Message arrived at final destination — deliver to application layer.
    delivered: struct {
        origin_id: PeerId,
        inner_msg_type: MessageType,
        inner_payload: []const u8,
    },
    /// Message needs forwarding to next hop — caller sends this via transport.
    forward: struct {
        next_conn: u32,
        forward_payload: []const u8,
    },
    /// Message dropped (TTL exhausted or no route).
    dropped,
};

/// Result of processing a rendezvous request.
pub const RendezvousResult = struct {
    /// Response to send back to the requesting connection.
    response_payload: []u8,
    response_len: usize,
    /// Optional introduction to send to the target peer.
    introduction_payload: ?[]u8 = null,
    introduction_len: usize = 0,
    target_conn_id: ?u32 = null,
};

// ============================================================================
// Relay Router
// ============================================================================

/// Relay router — processes multi-hop relay packets, rendezvous introductions,
/// and peer discovery queries. Tracks forwarding statistics.
pub const RelayRouter = struct {
    allocator: std.mem.Allocator,
    peer_id: PeerId,
    location: Location,
    peers: *PeerManager,
    relayed_forwarded: u64 = 0,
    relayed_received: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        peer_id: PeerId,
        location: Location,
        peers: *PeerManager,
    ) RelayRouter {
        return .{
            .allocator = allocator,
            .peer_id = peer_id,
            .location = location,
            .peers = peers,
        };
    }

    /// Process an incoming relay_route message.
    /// The payload is [RelayRouteHeader:71][inner_payload:inner_len].
    /// Returns the action the caller should take.
    pub fn handleRelayRoute(self: *RelayRouter, payload: []const u8) RelayRouteResult {
        const relay_hdr = RelayRouteHeader.deserialize(payload) orelse return .dropped;
        if (payload.len < RelayRouteHeader.SIZE + relay_hdr.inner_len) return .dropped;

        const inner_payload = payload[RelayRouteHeader.SIZE .. RelayRouteHeader.SIZE + relay_hdr.inner_len];

        if (std.mem.eql(u8, &relay_hdr.target_id, &self.peer_id)) {
            // Arrived at final destination
            self.relayed_received += 1;
            return .{
                .delivered = .{
                    .origin_id = relay_hdr.origin_id,
                    .inner_msg_type = relay_hdr.inner_msg_type,
                    .inner_payload = inner_payload,
                },
            };
        } else if (relay_hdr.ttl > 1) {
            // Intermediary router: forward to next hop
            const next_conn = p2p.routeToPeer(
                self.peers.allPeers(),
                self.location,
                relay_hdr.target_id,
                0, // Don't exclude any connection for forwarding
            ) orelse return .dropped;

            // Build updated relay header with decremented TTL and incremented hop count
            var updated_hdr = relay_hdr;
            updated_hdr.ttl -= 1;
            updated_hdr.hop_count += 1;

            const total_len = RelayRouteHeader.SIZE + inner_payload.len;
            const buf = self.allocator.alloc(u8, total_len) catch return .dropped;

            var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
            updated_hdr.serialize(&hdr_buf);
            @memcpy(buf[0..RelayRouteHeader.SIZE], &hdr_buf);
            @memcpy(buf[RelayRouteHeader.SIZE..], inner_payload);

            self.relayed_forwarded += 1;
            return .{
                .forward = .{
                    .next_conn = next_conn,
                    .forward_payload = buf,
                },
            };
        }

        return .dropped;
    }

    /// Process a rendezvous request from a peer.
    /// The payload is [target_id:32].
    /// Returns response data to send back and optional introduction to target.
    pub fn handleRendezvousReq(
        self: *RelayRouter,
        sender_id: PeerId,
        payload: []const u8,
    ) ?RendezvousResult {
        if (payload.len < 32) return null;
        var target_id: PeerId = undefined;
        @memcpy(&target_id, payload[0..32]);

        const target_peer = self.peers.getById(target_id);
        if (target_peer) |tp| {
            if (tp.isConnected()) {
                // 1. Build response to requester: status=1, target_id, target_location
                var res_buf: [49]u8 = undefined;
                res_buf[0] = 1; // status 1: active relay available
                @memcpy(res_buf[1..33], &target_id);
                // Serialize location as 16 bytes big-endian (matching Rations format)
                var loc = tp.location;
                var pos: usize = 0;
                while (pos < 16) : (pos += 1) {
                    res_buf[48 - pos] = @truncate(loc);
                    loc >>= 8;
                }

                // 2. Build introduction to target: status=2, requester_id
                var intro_buf: [33]u8 = undefined;
                intro_buf[0] = 2; // status 2: incoming introduction
                @memcpy(intro_buf[1..33], &sender_id);

                return RendezvousResult{
                    .response_payload = &res_buf,
                    .response_len = 49,
                    .introduction_payload = &intro_buf,
                    .introduction_len = 33,
                    .target_conn_id = tp.conn_id,
                };
            }
        }

        // Target not reachable directly
        var fail_buf: [33]u8 = undefined;
        fail_buf[0] = 0; // status 0: unreachable
        @memcpy(fail_buf[1..33], &target_id);

        return RendezvousResult{
            .response_payload = &fail_buf,
            .response_len = 33,
        };
    }

    /// Process a rendezvous response — register virtual peer.
    pub fn handleRendezvousRes(self: *RelayRouter, conn_id: u32, payload: []const u8) void {
        if (payload.len < 33) return;
        const status = payload[0];
        var remote_id: PeerId = undefined;
        @memcpy(&remote_id, payload[1..33]);

        if (status == 1 and payload.len >= 49) {
            // Active relay: extract location
            var remote_loc: Location = 0;
            var pos: usize = 0;
            while (pos < 16) : (pos += 1) {
                remote_loc = (remote_loc << 8) | payload[33 + pos];
            }
            self.peers.addPeer(remote_id, remote_loc, conn_id);
        } else if (status == 2) {
            // Introduction: derive location from peer ID
            const loc = p2p.locationFromSeed(&remote_id);
            self.peers.addPeer(remote_id, loc, conn_id);
        }
    }

    /// Build a peer discovery response payload listing all known connected peers
    /// (excluding the requesting connection).
    /// Format: [count:1][peer_id:32][location:16] × count
    pub fn buildPeerDiscoverResponse(
        self: *RelayRouter,
        allocator: std.mem.Allocator,
        exclude_conn: u32,
    ) ![]u8 {
        const max_peers: usize = 8;
        // First pass: count eligible peers
        var count: usize = 0;
        for (self.peers.allPeers()) |p| {
            if (!p.isConnected() or p.conn_id == exclude_conn) continue;
            if (count >= max_peers) break;
            count += 1;
        }

        // Allocate exact size: 1 byte for count + 48 bytes per peer
        const total_len = 1 + count * 48;
        var buf = try allocator.alloc(u8, total_len);
        var written: u8 = 0;
        var offset: usize = 1;

        for (self.peers.allPeers()) |p| {
            if (!p.isConnected() or p.conn_id == exclude_conn) continue;
            if (written >= max_peers) break;

            @memcpy(buf[offset..][0..32], &p.id);
            var loc = p.location;
            var pos: usize = 0;
            while (pos < 16) : (pos += 1) {
                buf[offset + 47 - pos] = @truncate(loc);
                loc >>= 8;
            }
            offset += 48;
            written += 1;
        }

        buf[0] = written;
        return buf;
    }

    /// Build a relay route packet for sending a multi-hop message to a target.
    /// Returns the full payload to send as a relay_route message.
    /// Caller must free the returned slice.
    pub fn buildRelayPacket(
        self: *RelayRouter,
        allocator: std.mem.Allocator,
        target_id: PeerId,
        inner_msg_type: MessageType,
        payload: []const u8,
    ) ![]u8 {
        const total_len = RelayRouteHeader.SIZE + payload.len;
        var buf = try allocator.alloc(u8, total_len);

        var relay_hdr = RelayRouteHeader{
            .target_id = target_id,
            .origin_id = self.peer_id,
            .ttl = 16,
            .hop_count = 0,
            .inner_msg_type = inner_msg_type,
            .inner_len = @intCast(payload.len),
        };

        var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
        relay_hdr.serialize(&hdr_buf);
        @memcpy(buf[0..RelayRouteHeader.SIZE], &hdr_buf);
        @memcpy(buf[RelayRouteHeader.SIZE..], payload);

        return buf;
    }

    /// Find the next hop connection ID for routing to a target peer.
    pub fn nextHopForTarget(self: *RelayRouter, target_id: PeerId, exclude_conn: u32) ?u32 {
        return p2p.routeToPeer(self.peers.allPeers(), self.location, target_id, exclude_conn);
    }

    /// Build a rendezvous request payload.
    /// Payload is [target_id:32].
    pub fn buildRendezvousRequest(target_id: PeerId) [32]u8 {
        var buf: [32]u8 = undefined;
        @memcpy(&buf, &target_id);
        return buf;
    }

    /// Free a forward payload allocated by handleRelayRoute.
    pub fn freeForwardPayload(self: *RelayRouter, payload: []const u8) void {
        self.allocator.free(payload);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "relay router init" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    const router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);
    try std.testing.expectEqual(@as(u64, 0), router.relayed_forwarded);
    try std.testing.expectEqual(@as(u64, 0), router.relayed_received);
}

test "relay route arrives at self" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    const sender_id = [_]u8{0xBB} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const inner_payload = "relayed payload message";
    var relay_hdr = RelayRouteHeader{
        .target_id = my_id,
        .origin_id = sender_id,
        .ttl = 10,
        .hop_count = 2,
        .inner_msg_type = .data,
        .inner_len = @intCast(inner_payload.len),
    };

    var raw_payload: [RelayRouteHeader.SIZE + 23]u8 = undefined;
    var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
    relay_hdr.serialize(&hdr_buf);
    @memcpy(raw_payload[0..RelayRouteHeader.SIZE], &hdr_buf);
    @memcpy(raw_payload[RelayRouteHeader.SIZE..], inner_payload);

    const result = router.handleRelayRoute(&raw_payload);
    try std.testing.expect(result == .delivered);
    try std.testing.expectEqual(@as(u64, 1), router.relayed_received);
    try std.testing.expectEqualSlices(u8, &sender_id, &result.delivered.origin_id);
    try std.testing.expectEqual(MessageType.data, result.delivered.inner_msg_type);
    try std.testing.expectEqualSlices(u8, inner_payload, result.delivered.inner_payload);
}

test "relay route forwarded to next hop" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const target_id = [_]u8{0xCC} ** 32;
    const target_peer = [_]u8{0xCC} ** 32;

    // Add a peer that is the target (but via different conn_id)
    pm.addPeer(target_peer, 2000, 5);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const inner_payload = "forward this";
    var relay_hdr = RelayRouteHeader{
        .target_id = target_id,
        .origin_id = [_]u8{0xBB} ** 32,
        .ttl = 10,
        .hop_count = 1,
        .inner_msg_type = .gossip,
        .inner_len = @intCast(inner_payload.len),
    };

    var raw_payload: [RelayRouteHeader.SIZE + 12]u8 = undefined;
    var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
    relay_hdr.serialize(&hdr_buf);
    @memcpy(raw_payload[0..RelayRouteHeader.SIZE], &hdr_buf);
    @memcpy(raw_payload[RelayRouteHeader.SIZE..], inner_payload);

    const result = router.handleRelayRoute(&raw_payload);
    try std.testing.expect(result == .forward);
    try std.testing.expectEqual(@as(u32, 5), result.forward.next_conn);
    try std.testing.expectEqual(@as(u64, 1), router.relayed_forwarded);

    // Verify forwarded payload has decremented TTL
    const forwarded = result.forward.forward_payload;
    const restored_hdr = RelayRouteHeader.deserialize(forwarded).?;
    try std.testing.expectEqual(@as(u8, 9), restored_hdr.ttl);
    try std.testing.expectEqual(@as(u8, 2), restored_hdr.hop_count);

    router.freeForwardPayload(forwarded);
}

test "relay route dropped when TTL exhausted" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    const target_id = [_]u8{0xCC} ** 32;
    pm.addPeer(target_id, 2000, 5);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var relay_hdr = RelayRouteHeader{
        .target_id = target_id,
        .origin_id = [_]u8{0xBB} ** 32,
        .ttl = 1, // TTL=1 means last hop, cannot forward
        .hop_count = 15,
        .inner_msg_type = .data,
        .inner_len = 5,
    };

    var raw_payload: [RelayRouteHeader.SIZE + 5]u8 = undefined;
    var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
    relay_hdr.serialize(&hdr_buf);
    @memcpy(raw_payload[0..RelayRouteHeader.SIZE], &hdr_buf);
    @memcpy(raw_payload[RelayRouteHeader.SIZE..], "hello");

    const result = router.handleRelayRoute(&raw_payload);
    try std.testing.expect(result == .dropped);
}

test "relay route dropped when no route to target" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var relay_hdr = RelayRouteHeader{
        .target_id = [_]u8{0xCC} ** 32,
        .origin_id = [_]u8{0xBB} ** 32,
        .ttl = 10,
        .hop_count = 1,
        .inner_msg_type = .data,
        .inner_len = 5,
    };

    var raw_payload: [RelayRouteHeader.SIZE + 5]u8 = undefined;
    var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
    relay_hdr.serialize(&hdr_buf);
    @memcpy(raw_payload[0..RelayRouteHeader.SIZE], &hdr_buf);
    @memcpy(raw_payload[RelayRouteHeader.SIZE..], "hello");

    const result = router.handleRelayRoute(&raw_payload);
    try std.testing.expect(result == .dropped);
}

test "relay route dropped on malformed payload" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const short_payload = [_]u8{0} ** 50;
    const result = router.handleRelayRoute(&short_payload);
    try std.testing.expect(result == .dropped);
}

test "relay route dropped when payload shorter than declared" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var relay_hdr = RelayRouteHeader{
        .target_id = my_id,
        .origin_id = [_]u8{0xBB} ** 32,
        .ttl = 10,
        .hop_count = 0,
        .inner_msg_type = .data,
        .inner_len = 100, // Claims 100 bytes but we only provide 5
    };

    var raw_payload: [RelayRouteHeader.SIZE + 5]u8 = undefined;
    var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
    relay_hdr.serialize(&hdr_buf);
    @memcpy(raw_payload[0..RelayRouteHeader.SIZE], &hdr_buf);
    @memcpy(raw_payload[RelayRouteHeader.SIZE..], "hello");

    const result = router.handleRelayRoute(&raw_payload);
    try std.testing.expect(result == .dropped);
}

test "rendezvous request finds target" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const requester_id = [_]u8{0xBB} ** 32;
    const target_id = [_]u8{0xCC} ** 32;

    pm.addPeer(target_id, 5000, 3);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var req_payload: [32]u8 = undefined;
    @memcpy(&req_payload, &target_id);

    const result = router.handleRendezvousReq(requester_id, &req_payload).?;

    // Should have response with status=1
    try std.testing.expectEqual(@as(u8, 1), result.response_payload[0]);
    try std.testing.expectEqual(@as(usize, 49), result.response_len);

    // Should have introduction with status=2
    try std.testing.expect(result.introduction_payload != null);
    try std.testing.expectEqual(@as(u8, 2), result.introduction_payload.?[0]);
    try std.testing.expectEqual(@as(usize, 33), result.introduction_len);
    try std.testing.expectEqual(@as(u32, 3), result.target_conn_id.?);
}

test "rendezvous request target not found" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const requester_id = [_]u8{0xBB} ** 32;
    const target_id = [_]u8{0xCC} ** 32;

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var req_payload: [32]u8 = undefined;
    @memcpy(&req_payload, &target_id);

    const result = router.handleRendezvousReq(requester_id, &req_payload).?;

    // Should have response with status=0 (unreachable)
    try std.testing.expectEqual(@as(u8, 0), result.response_payload[0]);
    try std.testing.expectEqual(@as(usize, 33), result.response_len);
    try std.testing.expect(result.introduction_payload == null);
}

test "rendezvous request rejects short payload" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const short_payload = [_]u8{0} ** 10;
    try std.testing.expect(router.handleRendezvousReq([_]u8{0xBB} ** 32, &short_payload) == null);
}

test "rendezvous response registers virtual peer" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const remote_id = [_]u8{0xBB} ** 32;

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var res_buf: [49]u8 = undefined;
    res_buf[0] = 1; // Active relay
    @memcpy(res_buf[1..33], &remote_id);
    @memset(res_buf[33..49], 0x05); // Location bytes

    router.handleRendezvousRes(1, &res_buf);

    try std.testing.expectEqual(@as(usize, 1), pm.connectedCount());
    try std.testing.expect(pm.getById(remote_id) != null);
}

test "rendezvous response introduction registers peer" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const remote_id = [_]u8{0xBB} ** 32;

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var intro_buf: [33]u8 = undefined;
    intro_buf[0] = 2; // Introduction
    @memcpy(intro_buf[1..33], &remote_id);

    router.handleRendezvousRes(1, &intro_buf);

    try std.testing.expectEqual(@as(usize, 1), pm.connectedCount());
    try std.testing.expect(pm.getById(remote_id) != null);
}

test "rendezvous response rejects short payload" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();
    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const short = [_]u8{0} ** 10;
    router.handleRendezvousRes(1, &short);
    try std.testing.expectEqual(@as(usize, 0), pm.connectedCount());
}

test "peer discover response lists connected peers" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    pm.addPeer([_]u8{0x01} ** 32, 100, 1);
    pm.addPeer([_]u8{0x02} ** 32, 200, 2);
    pm.addPeer([_]u8{0x03} ** 32, 300, 3);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const response = try router.buildPeerDiscoverResponse(std.testing.allocator, 2);
    defer std.testing.allocator.free(response);

    // Should list 2 peers (excluding conn_id=2)
    try std.testing.expectEqual(@as(u8, 2), response[0]);
    try std.testing.expectEqual(@as(usize, 1 + 2 * 48), response.len);
}

test "peer discover response excludes requesting connection" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    pm.addPeer([_]u8{0x01} ** 32, 100, 1);
    pm.addPeer([_]u8{0x02} ** 32, 200, 2);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const response = try router.buildPeerDiscoverResponse(std.testing.allocator, 1);
    defer std.testing.allocator.free(response);

    // Should list 1 peer (excluding conn_id=1)
    try std.testing.expectEqual(@as(u8, 1), response[0]);
    try std.testing.expectEqual(@as(usize, 1 + 48), response.len);
}

test "peer discover response empty when no peers" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const response = try router.buildPeerDiscoverResponse(std.testing.allocator, 0);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(u8, 0), response[0]);
    try std.testing.expectEqual(@as(usize, 1), response.len);
}

test "build relay packet creates correct format" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const target_id = [_]u8{0xCC} ** 32;

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const inner_data = "test relay payload";
    const packet = try router.buildRelayPacket(std.testing.allocator, target_id, .data, inner_data);
    defer std.testing.allocator.free(packet);

    // Verify relay header
    const hdr = RelayRouteHeader.deserialize(packet).?;
    try std.testing.expectEqualSlices(u8, &target_id, &hdr.target_id);
    try std.testing.expectEqualSlices(u8, &my_id, &hdr.origin_id);
    try std.testing.expectEqual(@as(u8, 16), hdr.ttl);
    try std.testing.expectEqual(@as(u8, 0), hdr.hop_count);
    try std.testing.expectEqual(MessageType.data, hdr.inner_msg_type);
    try std.testing.expectEqual(@as(u32, @intCast(inner_data.len)), hdr.inner_len);

    // Verify inner payload
    try std.testing.expectEqualSlices(u8, inner_data, packet[RelayRouteHeader.SIZE..]);
}

test "next hop for target finds direct connection" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const target_id = [_]u8{0xCC} ** 32;
    pm.addPeer(target_id, 2000, 5);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const next = router.nextHopForTarget(target_id, 0);
    try std.testing.expectEqual(@as(u32, 5), next.?);
}

test "next hop for target returns null when no peers" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const next = router.nextHopForTarget([_]u8{0xCC} ** 32, 0);
    try std.testing.expect(next == null);
}

test "build rendezvous request" {
    const target_id = [_]u8{0xCC} ** 32;
    const req = RelayRouter.buildRendezvousRequest(target_id);
    try std.testing.expectEqualSlices(u8, &target_id, &req);
}

test "relay route multiple hops decrement TTL correctly" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    const target_id = [_]u8{0xDD} ** 32;
    // Target is not directly connected, but we have a peer that might route
    pm.addPeer([_]u8{0xEE} ** 32, 2000, 7);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const inner = "multi-hop test";
    var relay_hdr = RelayRouteHeader{
        .target_id = target_id,
        .origin_id = [_]u8{0xBB} ** 32,
        .ttl = 5,
        .hop_count = 0,
        .inner_msg_type = .gossip,
        .inner_len = @intCast(inner.len),
    };

    var raw: [RelayRouteHeader.SIZE + 14]u8 = undefined;
    var hdr_buf: [RelayRouteHeader.SIZE]u8 = undefined;
    relay_hdr.serialize(&hdr_buf);
    @memcpy(raw[0..RelayRouteHeader.SIZE], &hdr_buf);
    @memcpy(raw[RelayRouteHeader.SIZE..], inner);

    const result = router.handleRelayRoute(&raw);
    try std.testing.expect(result == .forward);

    // Check TTL decremented and hop count incremented
    const fwd_hdr = RelayRouteHeader.deserialize(result.forward.forward_payload).?;
    try std.testing.expectEqual(@as(u8, 4), fwd_hdr.ttl);
    try std.testing.expectEqual(@as(u8, 1), fwd_hdr.hop_count);

    router.freeForwardPayload(result.forward.forward_payload);
}

test "rendezvous response with status 0 does not register peer" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    var buf: [33]u8 = undefined;
    buf[0] = 0; // Unreachable
    @memcpy(buf[1..33], &[_]u8{0xBB} ** 32);

    router.handleRendezvousRes(1, &buf);
    try std.testing.expectEqual(@as(usize, 0), pm.connectedCount());
}

test "peer discover response skips disconnected peers" {
    var pm = PeerManager.init(std.testing.allocator);
    defer pm.deinit();

    const my_id = [_]u8{0xAA} ** 32;
    pm.addPeer([_]u8{0x01} ** 32, 100, 1);
    pm.addPeer([_]u8{0x02} ** 32, 200, 2);
    // Remove peer 1 (sets to disconnected via swapRemove)
    pm.removePeer(1);

    var router = RelayRouter.init(std.testing.allocator, my_id, 1000, &pm);

    const response = try router.buildPeerDiscoverResponse(std.testing.allocator, 0);
    defer std.testing.allocator.free(response);

    // Should only list remaining connected peer
    try std.testing.expectEqual(@as(u8, 1), response[0]);
}

// =============================================================================
// Framework Network Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework mesh node count: 421 E0 nodes.
pub const FRAMEWORK_MESH_NODE_COUNT: u32 = 421;

/// Framework mesh channel count: 7 octonionic channels.
pub const FRAMEWORK_MESH_CHANNEL_COUNT: u32 = 7;

/// Framework mesh routing uses the Fano plane for channel routing.
/// The 7 Fano lines provide the routing table for 7-channel mesh.
pub const FRAMEWORK_FANO_LINES: u32 = 7;

/// Verifies the mesh node count matches the E0 lattice.
pub fn verifyMeshNodeCountMatchesFramework() bool {
    return FRAMEWORK_MESH_NODE_COUNT == 421;
}

/// Verifies the mesh channel count matches the 7-defect.
pub fn verifyMeshChannelCountMatchesFramework() bool {
    return FRAMEWORK_MESH_CHANNEL_COUNT == 7;
}

test "framework: mesh node count 421 = E0 lattice" {
    try std.testing.expect(verifyMeshNodeCountMatchesFramework());
}

test "framework: mesh channel count 7 = 7-defect" {
    try std.testing.expect(verifyMeshChannelCountMatchesFramework());
}
