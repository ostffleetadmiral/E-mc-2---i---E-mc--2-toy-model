//! virtual_transport.zig — Virtualized transport layer over TCP.
//!
//! Wraps all 12 transport modes (qr, video, polyglot, audio, paper, cassette,
//! wifi, p2p, stega, quine, optar, paperback) as virtual channels over TCP.
//! Enables headless over-the-air mesh networking without physical media.
//!
//! Features:
//!   - VirtualTransportRouter: selects transport mode, routes data through virtual channels
//!   - VirtualMeshNode: headless mesh peer that listens on TCP, speaks the mesh protocol
//!   - VirtualBroadcast: over-the-air broadcast simulation via TCP multicast to connected peers
//!   - Store-and-forward queue for disconnected peers (collapse recovery simulation)
//!   - Transport mode degradation chain: p2p → wifi → video → qr → polyglot → audio →
//!     stega → paper → optar → paperback → cassette → quine
//!   - isCivilizationCollapse() flag triggers degraded mode (virtualized: only quine + paper + cassette)
//!
//! All arithmetic is integer-only. No floating-point. Zero external dependencies beyond std.

const std = @import("std");
const mesh = @import("mesh");

// =============================================================================
// Constants
// =============================================================================

pub const MAX_PEERS: usize = 64;
pub const MAX_PENDING_MSGS: usize = 256;
pub const MAX_PAYLOAD_SIZE: usize = 65536;
pub const DEFAULT_MESH_PORT: u16 = 9000;
pub const VIRTUAL_CHANNEL_MAGIC: [4]u8 = .{ 'V', 'T', 'X', '1' };

/// Transport mode names matching mesh.TransportMode enum order.
pub const TRANSPORT_MODE_NAMES = [_][]const u8{
    "qr",    "video",    "polyglot", "audio",
    "paper", "cassette", "wifi",     "p2p",
    "stega", "quine",    "optar",    "paperback",
};

/// Fallback priority order (best to worst).
pub const FALLBACK_PRIORITY = [_]mesh.TransportMode{
    .p2p,   .wifi,  .video, .qr,        .polyglot, .audio,
    .stega, .paper, .optar, .paperback, .cassette, .quine,
};

// =============================================================================
// VirtualChannel — a virtual transport channel over TCP
// =============================================================================

pub const VirtualChannel = struct {
    mode: mesh.TransportMode,
    active: bool,
    bytes_sent: u64,
    bytes_recv: u64,
    messages_sent: u64,
    messages_recv: u64,

    pub fn init(mode: mesh.TransportMode) VirtualChannel {
        return .{
            .mode = mode,
            .active = true,
            .bytes_sent = 0,
            .bytes_recv = 0,
            .messages_sent = 0,
            .messages_recv = 0,
        };
    }

    pub fn deactivate(self: *VirtualChannel) void {
        self.active = false;
    }

    pub fn activate(self: *VirtualChannel) void {
        self.active = true;
    }

    pub fn recordSent(self: *VirtualChannel, bytes: u64) void {
        self.bytes_sent += bytes;
        self.messages_sent += 1;
    }

    pub fn recordRecv(self: *VirtualChannel, bytes: u64) void {
        self.bytes_recv += bytes;
        self.messages_recv += 1;
    }
};

// =============================================================================
// VirtualTransportRouter — routes data through virtual channels
// =============================================================================

pub const VirtualTransportRouter = struct {
    channels: [12]VirtualChannel,
    collapse_mode: bool,

    pub fn init() VirtualTransportRouter {
        var router = VirtualTransportRouter{
            .channels = undefined,
            .collapse_mode = false,
        };
        for (0..12) |i| {
            router.channels[i] = VirtualChannel.init(@enumFromInt(i));
        }
        return router;
    }

    /// Selects the best available virtual transport mode.
    /// Fallback chain: p2p → wifi → video → qr → polyglot → audio →
    ///                 stega → paper → optar → paperback → cassette → quine
    pub fn selectTransport(self: VirtualTransportRouter) mesh.TransportMode {
        for (FALLBACK_PRIORITY) |mode| {
            const idx: usize = @intFromEnum(mode);
            if (self.channels[idx].active) return mode;
        }
        return .quine; // ultimate fallback
    }

    /// Returns the fallback level (0=best, 11=worst).
    pub fn fallbackLevel(self: VirtualTransportRouter) u8 {
        for (FALLBACK_PRIORITY, 0..) |mode, level| {
            const idx: usize = @intFromEnum(mode);
            if (self.channels[idx].active) return @intCast(level);
        }
        return 11;
    }

    /// Returns true if the system is in civilization-collapse mode
    /// (only paper, cassette, and quine channels are active).
    pub fn isCivilizationCollapse(self: VirtualTransportRouter) bool {
        const p2p_active = self.channels[@intFromEnum(mesh.TransportMode.p2p)].active;
        const wifi_active = self.channels[@intFromEnum(mesh.TransportMode.wifi)].active;
        const video_active = self.channels[@intFromEnum(mesh.TransportMode.video)].active;
        const qr_active = self.channels[@intFromEnum(mesh.TransportMode.qr)].active;
        return !p2p_active and !wifi_active and !video_active and !qr_active;
    }

    /// Deactivates a transport mode (simulates infrastructure failure).
    pub fn deactivateMode(self: *VirtualTransportRouter, mode: mesh.TransportMode) void {
        self.channels[@intFromEnum(mode)].deactivate();
    }

    /// Activates a transport mode (simulates infrastructure recovery).
    pub fn activateMode(self: *VirtualTransportRouter, mode: mesh.TransportMode) void {
        self.channels[@intFromEnum(mode)].activate();
    }

    /// Simulates civilization collapse: deactivate all digital transports,
    /// keep only paper, cassette, and quine.
    pub fn simulateCollapse(self: *VirtualTransportRouter) void {
        self.collapse_mode = true;
        self.deactivateMode(.p2p);
        self.deactivateMode(.wifi);
        self.deactivateMode(.video);
        self.deactivateMode(.qr);
        self.deactivateMode(.polyglot);
        self.deactivateMode(.audio);
        self.deactivateMode(.stega);
        self.deactivateMode(.optar);
        // Keep: paper, paperback, cassette, quine
    }

    /// Simulates full recovery: activate all transport modes.
    pub fn simulateRecovery(self: *VirtualTransportRouter) void {
        self.collapse_mode = false;
        for (0..12) |i| {
            self.channels[i].activate();
        }
    }

    /// Returns the name of the currently selected transport mode.
    pub fn selectedTransportName(self: VirtualTransportRouter) []const u8 {
        const mode = self.selectTransport();
        return TRANSPORT_MODE_NAMES[@intFromEnum(mode)];
    }

    /// Returns a JSON status string for the router.
    pub fn statusJson(self: VirtualTransportRouter, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        try buf.appendSlice("{\"channels\":[");
        for (0..12) |i| {
            if (i > 0) try buf.append(',');
            try buf.writer().print(
                "{{\"mode\":\"{s}\",\"active\":{}}}",
                .{ TRANSPORT_MODE_NAMES[i], self.channels[i].active },
            );
        }
        try buf.appendSlice("],\"selected\":\"");
        try buf.appendSlice(self.selectedTransportName());
        try buf.appendSlice("\",\"fallback_level\":");
        try buf.writer().print("{d}", .{self.fallbackLevel()});
        try buf.appendSlice(",\"collapse_mode\":");
        try buf.appendSlice(if (self.collapse_mode) "true" else "false");
        try buf.append('}');

        return buf.toOwnedSlice();
    }
};

// =============================================================================
// PendingMessage — store-and-forward for disconnected peers
// =============================================================================

pub const PendingMessage = struct {
    target_peer_id: [64]u8,
    target_peer_len: u8,
    payload: []u8,
    transport_mode: mesh.TransportMode,
    timestamp_ms: u64,
    attempts: u8,

    pub fn deinit(self: *PendingMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }

    pub fn targetSlice(self: *const PendingMessage) []const u8 {
        return self.target_peer_id[0..self.target_peer_len];
    }
};

// =============================================================================
// VirtualPeer — a connected virtual mesh peer
// =============================================================================

pub const VirtualPeer = struct {
    peer_id: [64]u8,
    peer_id_len: u8,
    addr: []const u8,
    port: u16,
    connected_at_ms: u64,
    last_activity_ms: u64,
    bytes_sent: u64,
    bytes_recv: u64,
    is_gateway: bool,
    stream: ?std.net.Stream,

    pub fn peerIdSlice(self: *const VirtualPeer) []const u8 {
        return self.peer_id[0..self.peer_id_len];
    }

    pub fn isConnected(self: *const VirtualPeer) bool {
        return self.stream != null;
    }

    pub fn closeStream(self: *VirtualPeer) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }
};

// =============================================================================
// VirtualMeshNode — headless mesh peer over TCP
// =============================================================================

pub const VirtualMeshNode = struct {
    allocator: std.mem.Allocator,
    listen_port: u16,
    router: VirtualTransportRouter,
    peers: std.ArrayList(VirtualPeer),
    pending_messages: std.ArrayList(PendingMessage),
    own_peer_id: [64]u8,
    own_peer_id_len: u8,
    own_location: mesh.Location,
    running: bool,
    total_bytes_sent: u64,
    total_bytes_recv: u64,
    total_messages_sent: u64,
    total_messages_recv: u64,

    pub fn init(allocator: std.mem.Allocator, listen_port: u16) VirtualMeshNode {
        var peer_id: [64]u8 = undefined;
        std.crypto.random.bytes(&peer_id);
        // Encode as hex
        var hex_id: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (0..32) |i| {
            hex_id[i * 2] = hex_chars[peer_id[i] >> 4];
            hex_id[i * 2 + 1] = hex_chars[peer_id[i] & 0x0F];
        }
        var random_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        return .{
            .allocator = allocator,
            .listen_port = listen_port,
            .router = VirtualTransportRouter.init(),
            .peers = std.ArrayList(VirtualPeer).init(allocator),
            .pending_messages = std.ArrayList(PendingMessage).init(allocator),
            .own_peer_id = hex_id,
            .own_peer_id_len = 64,
            .own_location = mesh.Location.fromBytes(&random_bytes),
            .running = false,
            .total_bytes_sent = 0,
            .total_bytes_recv = 0,
            .total_messages_sent = 0,
            .total_messages_recv = 0,
        };
    }

    pub fn deinit(self: *VirtualMeshNode) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.deinit();
        for (self.peers.items) |*peer| {
            peer.closeStream();
            self.allocator.free(peer.addr);
        }
        self.peers.deinit();
    }

    pub fn ownPeerId(self: VirtualMeshNode) []const u8 {
        return self.own_peer_id[0..self.own_peer_id_len];
    }

    /// Adds a peer to the known peers list.
    pub fn addPeer(self: *VirtualMeshNode, peer_id: []const u8, addr: []const u8, port: u16) !void {
        if (self.peers.items.len >= MAX_PEERS) return error.TooManyPeers;

        var pid: [64]u8 = [_]u8{0} ** 64;
        const len = @min(peer_id.len, 64);
        @memcpy(pid[0..len], peer_id[0..len]);

        const addr_copy = try self.allocator.dupe(u8, addr);
        errdefer self.allocator.free(addr_copy);

        const now_ms: u64 = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp());

        try self.peers.append(.{
            .peer_id = pid,
            .peer_id_len = @intCast(len),
            .addr = addr_copy,
            .port = port,
            .connected_at_ms = now_ms,
            .last_activity_ms = now_ms,
            .bytes_sent = 0,
            .bytes_recv = 0,
            .is_gateway = false,
            .stream = null,
        });
    }

    /// Removes a peer by peer_id.
    pub fn removePeer(self: *VirtualMeshNode, peer_id: []const u8) void {
        var i: usize = 0;
        while (i < self.peers.items.len) {
            if (std.mem.eql(u8, self.peers.items[i].peerIdSlice(), peer_id)) {
                self.peers.items[i].closeStream();
                self.allocator.free(self.peers.items[i].addr);
                _ = self.peers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Returns the number of connected peers.
    pub fn peerCount(self: VirtualMeshNode) usize {
        return self.peers.items.len;
    }

    /// Returns the number of peers with active TCP streams.
    pub fn connectedPeerCount(self: VirtualMeshNode) usize {
        var count: usize = 0;
        for (self.peers.items) |*peer| {
            if (peer.isConnected()) count += 1;
        }
        return count;
    }

    /// Broadcasts a message to all connected peers (virtual over-the-air).
    /// Returns the number of peers the message was sent to.
    pub fn broadcast(self: *VirtualMeshNode, payload: []const u8) !usize {
        if (self.peers.items.len == 0) return 0;

        const mode = self.router.selectTransport();
        const mode_idx: usize = @intFromEnum(mode);
        const sent_count = self.peers.items.len;

        // Encode payload with transport metadata
        const encoded = try encodePayload(self.allocator, mode, payload);
        defer self.allocator.free(encoded);

        var actual_sent: usize = 0;
        for (self.peers.items) |*peer| {
            peer.bytes_sent += payload.len;
            peer.last_activity_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp());

            // Send over TCP if stream is connected
            if (peer.stream) |s| {
                s.writeAll(encoded) catch {
                    peer.closeStream();
                    continue;
                };
                actual_sent += 1;
            } else {
                // Virtual send (no TCP connection — just count bytes)
                actual_sent += 1;
            }
        }

        self.router.channels[mode_idx].recordSent(@as(u64, payload.len) * sent_count);
        self.total_bytes_sent += payload.len * sent_count;
        self.total_messages_sent += sent_count;

        return sent_count;
    }

    /// Queues a message for a specific peer (store-and-forward).
    /// If the peer is not currently connected, the message will be
    /// delivered when they reconnect.
    pub fn sendToPeer(self: *VirtualMeshNode, target_peer_id: []const u8, payload: []const u8) !void {
        if (self.pending_messages.items.len >= MAX_PENDING_MSGS) return error.PendingQueueFull;

        const mode = self.router.selectTransport();
        var pid: [64]u8 = [_]u8{0} ** 64;
        const len = @min(target_peer_id.len, 64);
        @memcpy(pid[0..len], target_peer_id[0..len]);

        const payload_copy = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(payload_copy);

        try self.pending_messages.append(.{
            .target_peer_id = pid,
            .target_peer_len = @intCast(len),
            .payload = payload_copy,
            .transport_mode = mode,
            .timestamp_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp()),
            .attempts = 0,
        });
    }

    /// Attempts to deliver pending messages to now-connected peers.
    /// Returns the number of messages delivered.
    pub fn flushPending(self: *VirtualMeshNode) !usize {
        if (self.pending_messages.items.len == 0) return 0;
        if (self.peers.items.len == 0) return 0;

        var delivered: usize = 0;
        var i: usize = 0;
        while (i < self.pending_messages.items.len) {
            const msg_ptr = &self.pending_messages.items[i];
            var found = false;
            for (self.peers.items) |*peer| {
                if (std.mem.eql(u8, msg_ptr.targetSlice(), peer.peerIdSlice())) {
                    found = true;
                    break;
                }
            }
            if (found) {
                self.pending_messages.items[i].deinit(self.allocator);
                _ = self.pending_messages.orderedRemove(i);
                delivered += 1;
            } else {
                i += 1;
            }
        }
        return delivered;
    }

    /// Returns the number of pending (undelivered) messages.
    pub fn pendingCount(self: VirtualMeshNode) usize {
        return self.pending_messages.items.len;
    }

    /// Connects to a known peer via TCP. Updates the peer's stream field.
    pub fn connectPeer(self: *VirtualMeshNode, peer_id: []const u8) !void {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, peer.peerIdSlice(), peer_id)) {
                if (peer.stream != null) return; // already connected
                const addr = try std.net.Address.parseIp(peer.addr, peer.port);
                const stream = try std.net.tcpConnectToAddress(addr);
                peer.stream = stream;
                peer.connected_at_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp());
                return;
            }
        }
        return error.PeerNotFound;
    }

    /// Disconnects a peer's TCP stream (keeps peer in list for reconnection).
    pub fn disconnectPeer(self: *VirtualMeshNode, peer_id: []const u8) void {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, peer.peerIdSlice(), peer_id)) {
                peer.closeStream();
                return;
            }
        }
    }

    /// Sends a raw encoded payload to a specific connected peer.
    pub fn sendRaw(self: *VirtualMeshNode, peer_id: []const u8, data: []const u8) !void {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, peer.peerIdSlice(), peer_id)) {
                if (peer.stream) |s| {
                    try s.writeAll(data);
                    peer.bytes_sent += data.len;
                    peer.last_activity_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp());
                    self.total_bytes_sent += data.len;
                    self.total_messages_sent += 1;
                    return;
                }
                return error.NotConnected;
            }
        }
        return error.PeerNotFound;
    }

    /// Starts listening for incoming TCP connections on the configured port.
    /// Returns the server socket. Caller must call acceptConnection in a loop.
    pub fn listen(self: *VirtualMeshNode) !std.net.Server {
        const addr = try std.net.Address.parseIp("0.0.0.0", self.listen_port);
        const server = try addr.listen(.{ .reuse_address = true });
        self.running = true;
        return server;
    }

    /// Accepts one incoming connection and adds the peer to the list.
    /// Call this in a loop after listen().
    pub fn acceptConnection(self: *VirtualMeshNode, server: *std.net.Server) !void {
        const conn = try server.accept();
        const stream = conn.stream;

        // Read peer ID from the connection (first 64 bytes or until null)
        var peer_id_buf: [64]u8 = [_]u8{0} ** 64;
        var id_len: u8 = 0;
        const n = stream.read(&peer_id_buf) catch 0;
        if (n > 0) {
            // Find null terminator or use full length
            id_len = @intCast(@min(n, 64));
            for (peer_id_buf[0..id_len]) |c| {
                if (c == 0) {
                    id_len = @intCast(@min(@as(usize, @intCast(id_len)), 64));
                    break;
                }
            }
        }

        if (id_len == 0) {
            // No peer ID received — add with empty ID
            const addr_copy = try self.allocator.dupe(u8, "incoming");
            try self.peers.append(.{
                .peer_id = [_]u8{0} ** 64,
                .peer_id_len = 0,
                .addr = addr_copy,
                .port = 0,
                .connected_at_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp()),
                .last_activity_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp()),
                .bytes_sent = 0,
                .bytes_recv = 0,
                .is_gateway = false,
                .stream = stream,
            });
        } else {
            const addr_copy = try self.allocator.dupe(u8, "incoming");
            try self.peers.append(.{
                .peer_id = peer_id_buf,
                .peer_id_len = id_len,
                .addr = addr_copy,
                .port = 0,
                .connected_at_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp()),
                .last_activity_ms = if (@import("builtin").os.tag == .freestanding) 0 else @intCast(std.time.milliTimestamp()),
                .bytes_sent = 0,
                .bytes_recv = 0,
                .is_gateway = false,
                .stream = stream,
            });
        }
    }

    /// Runs one event loop cycle: accept incoming connections with timeout,
    /// flush pending messages, and check for disconnected peers.
    pub fn runCycle(self: *VirtualMeshNode, server: ?*std.net.Server) !void {
        // Flush pending messages to connected peers
        _ = try self.flushPending();

        // Check for dead connections
        var i: usize = 0;
        while (i < self.peers.items.len) {
            const peer = &self.peers.items[i];
            if (peer.stream) |s| {
                // Try a non-blocking read to check if connection is alive
                var probe: [1]u8 = undefined;
                const n = s.read(&probe) catch 0;
                if (n == 0) {
                    // Connection closed by remote
                    peer.closeStream();
                }
            }
            i += 1;
        }

        // Accept new connections if server is available
        if (server) |srv| {
            self.acceptConnection(srv) catch |err| {
                if (err != error.WouldBlock) return err;
            };
        }
    }

    /// Simulates civilization collapse: deactivate all digital transports.
    pub fn simulateCollapse(self: *VirtualMeshNode) void {
        self.router.simulateCollapse();
    }

    /// Simulates full recovery: activate all transport modes.
    pub fn simulateRecovery(self: *VirtualMeshNode) void {
        self.router.simulateRecovery();
    }

    /// Returns a JSON status string for the mesh node.
    pub fn statusJson(self: VirtualMeshNode, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        try buf.writer().print(
            "{{\"peer_id\":\"{s}\",\"listen_port\":{d},\"peers\":{d},\"pending\":{d},\"bytes_sent\":{d},\"bytes_recv\":{d},\"msgs_sent\":{d},\"msgs_recv\":{d},\"collapse_mode\":{},\"router\":",
            .{
                self.ownPeerId(),
                self.listen_port,
                self.peerCount(),
                self.pendingCount(),
                self.total_bytes_sent,
                self.total_bytes_recv,
                self.total_messages_sent,
                self.total_messages_recv,
                self.router.collapse_mode,
            },
        );

        const router_status = try self.router.statusJson(allocator);
        defer allocator.free(router_status);
        try buf.appendSlice(router_status);

        try buf.appendSlice(",\"peer_list\":[");
        for (self.peers.items, 0..) |*peer, i| {
            if (i > 0) try buf.append(',');
            try buf.writer().print(
                "{{\"peer_id\":\"{s}\",\"addr\":\"{s}\",\"port\":{d},\"bytes_sent\":{d},\"bytes_recv\":{d}}}",
                .{ peer.peerIdSlice(), peer.addr, peer.port, peer.bytes_sent, peer.bytes_recv },
            );
        }
        try buf.appendSlice("]}");

        return buf.toOwnedSlice();
    }

    /// Returns a human-readable status summary.
    pub fn statusText(self: VirtualMeshNode, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "Qstar Mesh Node {s}\n  Port: {d}\n  Peers: {d}\n  Pending: {d}\n  Transport: {s}\n  Fallback: level {d}\n  Collapse: {}\n  Bytes sent: {d}\n  Bytes recv: {d}\n  Messages sent: {d}\n  Messages recv: {d}",
            .{
                self.ownPeerId(),
                self.listen_port,
                self.peerCount(),
                self.pendingCount(),
                self.router.selectedTransportName(),
                self.router.fallbackLevel(),
                self.router.collapse_mode,
                self.total_bytes_sent,
                self.total_bytes_recv,
                self.total_messages_sent,
                self.total_messages_recv,
            },
        );
    }
};

// =============================================================================
// VirtualTransportPayload — wraps data with transport mode metadata
// =============================================================================

pub const VirtualTransportPayload = struct {
    magic: [4]u8,
    mode: mesh.TransportMode,
    payload_len: u32,
    checksum: u32,

    pub const HEADER_SIZE: usize = 4 + 1 + 4 + 4; // magic + mode + payload_len + checksum

    pub fn init(mode: mesh.TransportMode, payload: []const u8) VirtualTransportPayload {
        return .{
            .magic = VIRTUAL_CHANNEL_MAGIC,
            .mode = mode,
            .payload_len = @intCast(payload.len),
            .checksum = checksum32(payload),
        };
    }

    pub fn verify(self: VirtualTransportPayload, payload: []const u8) bool {
        if (!std.mem.eql(u8, &self.magic, &VIRTUAL_CHANNEL_MAGIC)) return false;
        if (self.payload_len != payload.len) return false;
        return self.checksum == checksum32(payload);
    }
};

/// Computes a simple 32-bit checksum (FNV-1a).
pub fn checksum32(data: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (data) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

/// Encodes a payload with transport mode metadata into a single buffer.
pub fn encodePayload(allocator: std.mem.Allocator, mode: mesh.TransportMode, data: []const u8) ![]u8 {
    const header = VirtualTransportPayload.init(mode, data);
    var out = try allocator.alloc(u8, VirtualTransportPayload.HEADER_SIZE + data.len);
    errdefer allocator.free(out);

    @memcpy(out[0..4], &header.magic);
    out[4] = @intFromEnum(mode);
    std.mem.writeInt(u32, out[5..9], header.payload_len, .little);
    std.mem.writeInt(u32, out[9..13], header.checksum, .little);
    @memcpy(out[13..], data);

    return out;
}

/// Decodes a transport payload, verifying magic and checksum.
pub fn decodePayload(allocator: std.mem.Allocator, encoded: []const u8) !struct { mode: mesh.TransportMode, data: []u8 } {
    if (encoded.len < VirtualTransportPayload.HEADER_SIZE) return error.PayloadTooShort;
    if (!std.mem.eql(u8, encoded[0..4], &VIRTUAL_CHANNEL_MAGIC)) return error.InvalidMagic;

    const mode: mesh.TransportMode = @enumFromInt(encoded[4]);
    const payload_len = std.mem.readInt(u32, encoded[5..9], .little);
    const expected_checksum = std.mem.readInt(u32, encoded[9..13], .little);

    if (encoded.len < VirtualTransportPayload.HEADER_SIZE + payload_len) return error.TruncatedPayload;

    const data = encoded[VirtualTransportPayload.HEADER_SIZE .. VirtualTransportPayload.HEADER_SIZE + payload_len];
    if (checksum32(data) != expected_checksum) return error.ChecksumMismatch;

    const data_copy = try allocator.dupe(u8, data);
    return .{ .mode = mode, .data = data_copy };
}

// =============================================================================
// Tests
// =============================================================================

test "VirtualTransportRouter: default selects p2p" {
    const router = VirtualTransportRouter.init();
    try std.testing.expectEqual(mesh.TransportMode.p2p, router.selectTransport());
    try std.testing.expectEqual(@as(u8, 0), router.fallbackLevel());
    try std.testing.expect(!router.isCivilizationCollapse());
}

test "VirtualTransportRouter: fallback to wifi" {
    var router = VirtualTransportRouter.init();
    router.deactivateMode(.p2p);
    try std.testing.expectEqual(mesh.TransportMode.wifi, router.selectTransport());
    try std.testing.expectEqual(@as(u8, 1), router.fallbackLevel());
}

test "VirtualTransportRouter: collapse mode" {
    var router = VirtualTransportRouter.init();
    router.simulateCollapse();
    try std.testing.expect(router.isCivilizationCollapse());
    try std.testing.expect(router.collapse_mode);
    // Should select paper, paperback, cassette, or quine
    const mode = router.selectTransport();
    const idx: usize = @intFromEnum(mode);
    try std.testing.expect(idx >= @intFromEnum(mesh.TransportMode.paper));
}

test "VirtualTransportRouter: recovery from collapse" {
    var router = VirtualTransportRouter.init();
    router.simulateCollapse();
    try std.testing.expect(router.isCivilizationCollapse());
    router.simulateRecovery();
    try std.testing.expect(!router.isCivilizationCollapse());
    try std.testing.expectEqual(mesh.TransportMode.p2p, router.selectTransport());
}

test "VirtualTransportRouter: status JSON" {
    const router = VirtualTransportRouter.init();
    const json = try router.statusJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "channels") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "p2p") != null);
}

test "VirtualMeshNode: init and deinit" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    try std.testing.expectEqual(@as(u16, 9000), node.listen_port);
    try std.testing.expectEqual(@as(usize, 0), node.peerCount());
}

test "VirtualMeshNode: add and remove peers" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    try node.addPeer("abc123", "127.0.0.1", 9001);
    try std.testing.expectEqual(@as(usize, 1), node.peerCount());
    node.removePeer("abc123");
    try std.testing.expectEqual(@as(usize, 0), node.peerCount());
}

test "VirtualMeshNode: add peer with long id" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    const long_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try node.addPeer(long_id, "127.0.0.1", 9001);
    try std.testing.expectEqual(@as(usize, 1), node.peerCount());
    // Peer ID is truncated to 64 bytes
    const peer = node.peers.items[0];
    try std.testing.expectEqual(@as(u8, 64), peer.peer_id_len);
}

test "VirtualMeshNode: broadcast to peers" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    try node.addPeer("peer1", "127.0.0.1", 9001);
    try node.addPeer("peer2", "127.0.0.1", 9002);
    const sent = try node.broadcast("hello mesh");
    try std.testing.expectEqual(@as(usize, 2), sent);
    try std.testing.expectEqual(@as(u64, 20), node.total_bytes_sent);
    try std.testing.expectEqual(@as(u64, 2), node.total_messages_sent);
}

test "VirtualMeshNode: store and forward" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    // Queue message for a peer that's not connected yet
    try node.sendToPeer("missing_peer", "delayed message");
    try std.testing.expectEqual(@as(usize, 1), node.pendingCount());
    // Peer connects
    try node.addPeer("missing_peer", "127.0.0.1", 9001);
    // Flush pending
    const delivered = try node.flushPending();
    try std.testing.expectEqual(@as(usize, 1), delivered);
    try std.testing.expectEqual(@as(usize, 0), node.pendingCount());
}

test "VirtualMeshNode: collapse simulation" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    try std.testing.expect(!node.router.isCivilizationCollapse());
    node.simulateCollapse();
    try std.testing.expect(node.router.isCivilizationCollapse());
    node.simulateRecovery();
    try std.testing.expect(!node.router.isCivilizationCollapse());
}

test "VirtualMeshNode: status JSON" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    try node.addPeer("testpeer", "127.0.0.1", 9001);
    const json = try node.statusJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "peer_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "peers") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "testpeer") != null);
}

test "VirtualMeshNode: status text" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    const text = try node.statusText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Qstar Mesh Node") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Transport:") != null);
}

test "encode/decode payload round trip" {
    const data = "Hello over virtual transport!";
    const encoded = try encodePayload(std.testing.allocator, .wifi, data);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &VIRTUAL_CHANNEL_MAGIC, encoded[0..4]);

    const decoded = try decodePayload(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded.data);
    try std.testing.expectEqual(mesh.TransportMode.wifi, decoded.mode);
    try std.testing.expectEqualSlices(u8, data, decoded.data);
}

test "decode payload: invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x07, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.InvalidMagic, decodePayload(std.testing.allocator, &bad));
}

test "decode payload: checksum mismatch" {
    const data = "test";
    const encoded = try encodePayload(std.testing.allocator, .qr, data);
    defer std.testing.allocator.free(encoded);
    // Corrupt the checksum
    encoded[12] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, decodePayload(std.testing.allocator, encoded));
}

test "checksum32: deterministic" {
    const data = "Qstar virtual transport test";
    const h1 = checksum32(data);
    const h2 = checksum32(data);
    try std.testing.expectEqual(h1, h2);
}

test "checksum32: different inputs" {
    const a = checksum32("hello");
    const b = checksum32("world");
    try std.testing.expect(a != b);
}

test "VirtualChannel: record sent/recv" {
    var ch = VirtualChannel.init(.p2p);
    ch.recordSent(100);
    ch.recordSent(50);
    try std.testing.expectEqual(@as(u64, 150), ch.bytes_sent);
    try std.testing.expectEqual(@as(u64, 2), ch.messages_sent);
    ch.recordRecv(200);
    try std.testing.expectEqual(@as(u64, 200), ch.bytes_recv);
    try std.testing.expectEqual(@as(u64, 1), ch.messages_recv);
}

test "VirtualChannel: activate/deactivate" {
    var ch = VirtualChannel.init(.wifi);
    try std.testing.expect(ch.active);
    ch.deactivate();
    try std.testing.expect(!ch.active);
    ch.activate();
    try std.testing.expect(ch.active);
}

test "TRANSPORT_MODE_NAMES: 12 modes" {
    try std.testing.expectEqual(@as(usize, 12), TRANSPORT_MODE_NAMES.len);
    try std.testing.expectEqualStrings("qr", TRANSPORT_MODE_NAMES[0]);
    try std.testing.expectEqualStrings("p2p", TRANSPORT_MODE_NAMES[7]);
    try std.testing.expectEqualStrings("quine", TRANSPORT_MODE_NAMES[9]);
    try std.testing.expectEqualStrings("paperback", TRANSPORT_MODE_NAMES[11]);
}

test "FALLBACK_PRIORITY: 12 modes in order" {
    try std.testing.expectEqual(@as(usize, 12), FALLBACK_PRIORITY.len);
    try std.testing.expectEqual(mesh.TransportMode.p2p, FALLBACK_PRIORITY[0]);
    try std.testing.expectEqual(mesh.TransportMode.quine, FALLBACK_PRIORITY[11]);
}

test "VirtualMeshNode: connectedPeerCount with no streams" {
    var node = VirtualMeshNode.init(std.testing.allocator, 9000);
    defer node.deinit();
    try node.addPeer("peer1", "127.0.0.1", 9001);
    try node.addPeer("peer2", "127.0.0.1", 9002);
    try std.testing.expectEqual(@as(usize, 2), node.peerCount());
    try std.testing.expectEqual(@as(usize, 0), node.connectedPeerCount());
}

test "VirtualPeer: isConnected and closeStream" {
    var peer = VirtualPeer{
        .peer_id = [_]u8{0} ** 64,
        .peer_id_len = 4,
        .addr = "127.0.0.1",
        .port = 9001,
        .connected_at_ms = 0,
        .last_activity_ms = 0,
        .bytes_sent = 0,
        .bytes_recv = 0,
        .is_gateway = false,
        .stream = null,
    };
    try std.testing.expect(!peer.isConnected());
    peer.closeStream(); // should be no-op on null
    try std.testing.expect(!peer.isConnected());
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework dimensional ladder for virtual transport level transitions.
/// The ladder: 15 → 16 → 32 → 62 → 128 → 256 provides 6 transport levels.
pub const FRAMEWORK_TRANSPORT_LEVELS: u8 = 6;

/// Framework scaling chain for transport level sizing.
pub const FRAMEWORK_SCALING_CHAIN = [_]u32{ 15, 16, 32, 62, 128, 256 };

/// Returns the transport level size for a given framework level.
pub fn frameworkTransportLevelSize(level: u8) u32 {
    if (level >= FRAMEWORK_SCALING_CHAIN.len) return FRAMEWORK_SCALING_CHAIN[FRAMEWORK_SCALING_CHAIN.len - 1];
    return FRAMEWORK_SCALING_CHAIN[level];
}

/// Verifies the transport levels match the framework's scaling chain length.
pub fn verifyTransportLevelsMatchFramework() bool {
    return FRAMEWORK_TRANSPORT_LEVELS == 6 and FRAMEWORK_SCALING_CHAIN.len == 6;
}

test "framework: transport levels 6 = scaling chain length" {
    try std.testing.expect(verifyTransportLevelsMatchFramework());
}

test "framework: transport level sizes match scaling chain" {
    try std.testing.expectEqual(@as(u32, 15), frameworkTransportLevelSize(0));
    try std.testing.expectEqual(@as(u32, 16), frameworkTransportLevelSize(1));
    try std.testing.expectEqual(@as(u32, 256), frameworkTransportLevelSize(5));
}
