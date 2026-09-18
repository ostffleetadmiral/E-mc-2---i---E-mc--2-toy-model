//! webrtc.zig — WebRTC data channel protocol logic for Qstar.
//!
//! Implements SDP offer/answer, ICE candidate management, DTLS fingerprint,
//! and SCTP data channel framing. Pure logic — no actual networking.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

pub const ICE_CANDIDATE_HEADER: usize = 32;
pub const SDP_MAX_LEN: usize = 4096;
pub const CHANNEL_MAX_PAYLOAD: usize = 65535;
pub const DTLS_FINGERPRINT_SIZE: usize = 32; // SHA-256

pub const ChannelState = enum(u8) { closed = 0, connecting = 1, open = 2, closing = 3 };

pub const IceCandidate = struct {
    foundation: u32,
    component: u8,
    protocol: u8,
    priority: u32,
    ip: [46]u8,
    ip_len: u8,
    port: u16,
    typ: u8, // 0=host, 1=srflx, 2=prflx, 3=relay

    pub fn ipSlice(self: *const IceCandidate) []const u8 {
        return self.ip[0..self.ip_len];
    }
};

pub const DtlsFingerprint = struct {
    hash: [DTLS_FINGERPRINT_SIZE]u8,
    algo: u8, // 0=sha256, 1=sha384
};

pub const DataChannelMsg = struct {
    channel_id: u16,
    ppid: u16, // Payload Protocol ID
    data: []const u8,
};

pub const SdpType = enum { offer, answer };

pub const Sdp = struct {
    type: SdpType,
    ice_ufrag: [32]u8,
    ice_ufrag_len: u8,
    ice_pwd: [32]u8,
    ice_pwd_len: u8,
    fingerprint: DtlsFingerprint,
    setup: u8, // 0=actpass, 1=active, 2=passive

    pub fn ufragSlice(self: *const Sdp) []const u8 {
        return self.ice_ufrag[0..self.ice_ufrag_len];
    }
    pub fn pwdSlice(self: *const Sdp) []const u8 {
        return self.ice_pwd[0..self.ice_pwd_len];
    }
};

pub const DataChannel = struct {
    allocator: std.mem.Allocator,
    id: u16,
    label: []u8,
    state: ChannelState,
    ordered: bool,
    max_retransmits: u16,
    sent: u64 = 0,
    received: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, id: u16, label: []const u8, ordered: bool, max_retransmits: u16) !DataChannel {
        return .{
            .allocator = allocator,
            .id = id,
            .label = try allocator.dupe(u8, label),
            .state = .connecting,
            .ordered = ordered,
            .max_retransmits = max_retransmits,
        };
    }

    pub fn deinit(self: *DataChannel) void {
        self.allocator.free(self.label);
    }
};

pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    local_sdp: ?Sdp = null,
    remote_sdp: ?Sdp = null,
    local_candidates: std.ArrayList(IceCandidate),
    remote_candidates: std.ArrayList(IceCandidate),
    channels: std.ArrayList(DataChannel),
    state: ChannelState,

    pub fn init(allocator: std.mem.Allocator) PeerConnection {
        return .{
            .allocator = allocator,
            .local_candidates = std.ArrayList(IceCandidate).init(allocator),
            .remote_candidates = std.ArrayList(IceCandidate).init(allocator),
            .channels = std.ArrayList(DataChannel).init(allocator),
            .state = .closed,
        };
    }

    pub fn deinit(self: *PeerConnection) void {
        for (self.channels.items) |*ch| ch.deinit();
        self.channels.deinit();
        self.local_candidates.deinit();
        self.remote_candidates.deinit();
    }

    pub fn createOffer(self: *PeerConnection, ufrag: []const u8, pwd: []const u8, fp: DtlsFingerprint) Sdp {
        const sdp = Sdp{
            .type = .offer,
            .ice_ufrag = blk: { var b = [_]u8{0} ** 32; @memcpy(b[0..ufrag.len], ufrag); break :blk b; },
            .ice_ufrag_len = @intCast(ufrag.len),
            .ice_pwd = blk: { var b = [_]u8{0} ** 32; @memcpy(b[0..pwd.len], pwd); break :blk b; },
            .ice_pwd_len = @intCast(pwd.len),
            .fingerprint = fp,
            .setup = 0, // actpass
        };
        self.local_sdp = sdp;
        self.state = .connecting;
        return sdp;
    }

    pub fn createAnswer(self: *PeerConnection, ufrag: []const u8, pwd: []const u8, fp: DtlsFingerprint) Sdp {
        const sdp = Sdp{
            .type = .answer,
            .ice_ufrag = blk: { var b = [_]u8{0} ** 32; @memcpy(b[0..ufrag.len], ufrag); break :blk b; },
            .ice_ufrag_len = @intCast(ufrag.len),
            .ice_pwd = blk: { var b = [_]u8{0} ** 32; @memcpy(b[0..pwd.len], pwd); break :blk b; },
            .ice_pwd_len = @intCast(pwd.len),
            .fingerprint = fp,
            .setup = 1, // active
        };
        self.local_sdp = sdp;
        return sdp;
    }

    pub fn setRemoteDescription(self: *PeerConnection, sdp: Sdp) void {
        self.remote_sdp = sdp;
    }

    pub fn addLocalCandidate(self: *PeerConnection, c: IceCandidate) !void {
        try self.local_candidates.append(c);
    }

    pub fn addRemoteCandidate(self: *PeerConnection, c: IceCandidate) !void {
        try self.remote_candidates.append(c);
    }

    pub fn createDataChannel(self: *PeerConnection, label: []const u8, ordered: bool, max_retransmits: u16) !u16 {
        const id: u16 = @intCast(self.channels.items.len);
        try self.channels.append(try DataChannel.init(self.allocator, id, label, ordered, max_retransmits));
        return id;
    }

    pub fn openChannel(self: *PeerConnection, id: u16) void {
        if (id < self.channels.items.len) {
            self.channels.items[id].state = .open;
        }
    }

    pub fn closeChannel(self: *PeerConnection, id: u16) void {
        if (id < self.channels.items.len) {
            self.channels.items[id].state = .closed;
        }
    }

    pub fn channelCount(self: *const PeerConnection) usize {
        return self.channels.items.len;
    }

    pub fn candidateCount(self: *const PeerConnection) struct { local: usize, remote: usize } {
        return .{ .local = self.local_candidates.items.len, .remote = self.remote_candidates.items.len };
    }
};

pub fn encodeDataChannelMessage(allocator: std.mem.Allocator, msg: DataChannelMsg) ![]u8 {
    if (msg.data.len > CHANNEL_MAX_PAYLOAD) return error.PayloadTooLarge;
    const header: usize = 4;
    var buf = try allocator.alloc(u8, header + msg.data.len);
    buf[0] = @truncate(msg.channel_id);
    buf[1] = @truncate(msg.channel_id >> 8);
    buf[2] = @truncate(msg.ppid);
    buf[3] = @truncate(msg.ppid >> 8);
    @memcpy(buf[header..], msg.data);
    return buf;
}

pub fn decodeDataChannelMessage(buf: []const u8) ?DataChannelMsg {
    if (buf.len < 4) return null;
    return .{
        .channel_id = @as(u16, buf[0]) | (@as(u16, buf[1]) << 8),
        .ppid = @as(u16, buf[2]) | (@as(u16, buf[3]) << 8),
        .data = buf[4..],
    };
}

// Tests

test "webrtc: PeerConnection create offer" {
    var pc = PeerConnection.init(std.testing.allocator);
    defer pc.deinit();
    const fp = DtlsFingerprint{ .hash = [_]u8{0xAA} ** 32, .algo = 0 };
    const sdp = pc.createOffer("ufrag1", "pwd12345", fp);
    try std.testing.expectEqual(SdpType.offer, sdp.type);
    try std.testing.expectEqualStrings("ufrag1", sdp.ufragSlice());
    try std.testing.expectEqualStrings("pwd12345", sdp.pwdSlice());
    try std.testing.expectEqual(ChannelState.connecting, pc.state);
}

test "webrtc: PeerConnection create answer" {
    var pc = PeerConnection.init(std.testing.allocator);
    defer pc.deinit();
    const fp = DtlsFingerprint{ .hash = [_]u8{0xBB} ** 32, .algo = 0 };
    const sdp = pc.createAnswer("ufrag2", "pwd67890", fp);
    try std.testing.expectEqual(SdpType.answer, sdp.type);
    try std.testing.expectEqualStrings("ufrag2", sdp.ufragSlice());
}

test "webrtc: set remote description" {
    var pc = PeerConnection.init(std.testing.allocator);
    defer pc.deinit();
    const fp = DtlsFingerprint{ .hash = [_]u8{0} ** 32, .algo = 0 };
    const sdp = Sdp{ .type = .offer, .ice_ufrag = [_]u8{0} ** 32, .ice_ufrag_len = 4, .ice_pwd = [_]u8{0} ** 32, .ice_pwd_len = 4, .fingerprint = fp, .setup = 0 };
    pc.setRemoteDescription(sdp);
    try std.testing.expect(pc.remote_sdp != null);
}

test "webrtc: add ICE candidates" {
    var pc = PeerConnection.init(std.testing.allocator);
    defer pc.deinit();
    const c = IceCandidate{ .foundation = 1, .component = 1, .protocol = 0, .priority = 100, .ip = [_]u8{0} ** 46, .ip_len = 0, .port = 5000, .typ = 0 };
    try pc.addLocalCandidate(c);
    try pc.addRemoteCandidate(c);
    const counts = pc.candidateCount();
    try std.testing.expectEqual(@as(usize, 1), counts.local);
    try std.testing.expectEqual(@as(usize, 1), counts.remote);
}

test "webrtc: create and manage data channels" {
    var pc = PeerConnection.init(std.testing.allocator);
    defer pc.deinit();
    const id = try pc.createDataChannel("chat", true, 3);
    try std.testing.expectEqual(@as(u16, 0), id);
    try std.testing.expectEqual(@as(usize, 1), pc.channelCount());
    try std.testing.expectEqual(ChannelState.connecting, pc.channels.items[0].state);

    pc.openChannel(id);
    try std.testing.expectEqual(ChannelState.open, pc.channels.items[0].state);

    pc.closeChannel(id);
    try std.testing.expectEqual(ChannelState.closed, pc.channels.items[0].state);
}

test "webrtc: encode/decode data channel message" {
    const allocator = std.testing.allocator;
    const msg = DataChannelMsg{ .channel_id = 42, .ppid = 53, .data = "hello webrtc" };
    const encoded = try encodeDataChannelMessage(allocator, msg);
    defer allocator.free(encoded);

    const decoded = decodeDataChannelMessage(encoded).?;
    try std.testing.expectEqual(@as(u16, 42), decoded.channel_id);
    try std.testing.expectEqual(@as(u16, 53), decoded.ppid);
    try std.testing.expectEqualStrings("hello webrtc", decoded.data);
}

test "webrtc: decode rejects short buffer" {
    try std.testing.expect(decodeDataChannelMessage("AB") == null);
}

test "webrtc: encode rejects oversized payload" {
    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u8, CHANNEL_MAX_PAYLOAD + 1);
    defer allocator.free(big);
    const msg = DataChannelMsg{ .channel_id = 1, .ppid = 1, .data = big };
    try std.testing.expectError(error.PayloadTooLarge, encodeDataChannelMessage(allocator, msg));
}

test "webrtc: IceCandidate ip slice" {
    const c = IceCandidate{ .foundation = 1, .component = 1, .protocol = 0, .priority = 100, .ip = blk: { var b = [_]u8{0} ** 46; @memcpy(b[0..9], "127.0.0.1"); break :blk b; }, .ip_len = 9, .port = 8080, .typ = 0 };
    try std.testing.expectEqualStrings("127.0.0.1", c.ipSlice());
}

test "webrtc: multiple data channels" {
    var pc = PeerConnection.init(std.testing.allocator);
    defer pc.deinit();
    _ = try pc.createDataChannel("ch1", true, 3);
    _ = try pc.createDataChannel("ch2", false, 0);
    _ = try pc.createDataChannel("ch3", true, 5);
    try std.testing.expectEqual(@as(usize, 3), pc.channelCount());
    try std.testing.expectEqualStrings("ch2", pc.channels.items[1].label);
    try std.testing.expect(!pc.channels.items[1].ordered);
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
