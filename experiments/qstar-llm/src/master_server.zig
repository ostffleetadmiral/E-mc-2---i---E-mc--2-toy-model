//! master_server.zig — Master node autoupdate HTTP server (zero dependencies).
//!
//! Serves the CI/CD-gated quine payloads from the master publish directory
//! (default zig-out/master/) so deployed quine editions (universe.html) can
//! fetch seed_manifest.json and pull updated corpus / WASM payloads.
//!
//! Routes:
//!   GET /seed_manifest.json          → update manifest (version + hashes)
//!   GET /universe.html               → latest quine edition
//!   GET /qstar_corpus.qsc            → full compressed corpus
//!   GET /qstar_corpus_distilled.txt  → distilled text corpus (browser quines)
//!   GET /qstar_llm.wasm              → WASM binary (capabilities/tools)
//!   GET /                            → index listing available payloads
//!
//! WebRTC signaling + relay (browser P2P mirror bridge):
//!   POST /api/signaling/register     → register this quine as a P2P mirror node
//!   GET  /api/signaling/peers        → list registered mirror nodes + payloads
//!   POST /api/signaling/offer        → queue an SDP offer for a target peer
//!   GET  /api/signaling/offers?target=X → pending SDP offers for a peer
//!   POST /api/signaling/answer       → queue an SDP answer for an offer
//!   GET  /api/signaling/answer?offer_id=N → fetch the SDP answer
//!   POST /api/signaling/ice          → queue an ICE candidate for a target
//!   GET  /api/signaling/ice?target=X → pending ICE candidates for a peer
//!   POST /api/relay/<name>           → store a payload in the relay cache
//!   GET  /api/relay/<name>           → fetch a payload from the relay cache
//!
//! Usage: qstar master-serve [port] [--dir <path>]

const std = @import("std");
const dynamic_dns = @import("dynamic_dns");

pub const MasterServerConfig = struct {
    port: u16 = 11436,
    root_dir: []const u8 = "zig-out/master",
    max_request_bytes: usize = 16 * 1024,
    max_relay_bytes: usize = 64 * 1024 * 1024,
    dynamic_dns_config: ?dynamic_dns.DynamicDnsConfig = null,
};

pub const MasterServer = struct {
    allocator: std.mem.Allocator,
    config: MasterServerConfig,
    signaling: SignalingState,
    listener: ?std.net.Server = null,

    pub fn init(allocator: std.mem.Allocator, config: MasterServerConfig) MasterServer {
        return .{
            .allocator = allocator,
            .config = config,
            .signaling = SignalingState.init(allocator),
        };
    }

    pub fn deinit(self: *MasterServer) void {
        if (self.listener) |*l| l.deinit();
        self.signaling.deinit();
    }

    pub fn start(self: *MasterServer) !void {
        const addr = try std.net.Address.parseIp("0.0.0.0", self.config.port);
        var server = try addr.listen(.{ .reuse_address = true });
        self.listener = server;
        std.debug.print("Master node serving {s} on http://0.0.0.0:{d}\n", .{ self.config.root_dir, self.config.port });
        std.debug.print("Manifest: http://0.0.0.0:{d}/seed_manifest.json\n", .{self.config.port});

        // Update dynamic DNS on startup if configured
        if (self.config.dynamic_dns_config) |dns_config| {
            std.debug.print("Updating dynamic DNS...\n", .{});
            const result = dynamic_dns.updateWithRetry(self.allocator, dns_config) catch |err| {
                std.debug.print("Dynamic DNS update error: {s}\n", .{@errorName(err)});
            };
            dynamic_dns.printResult(result);
        }

        while (true) {
            const conn = server.accept() catch |err| {
                std.debug.print("Accept error: {s}\n", .{@errorName(err)});
                continue;
            };
            const ctx = ConnectionContext{ .server = self, .stream = conn.stream };
            const thread = std.Thread.spawn(.{}, handleConnection, .{ctx}) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    const ConnectionContext = struct {
        server: *MasterServer,
        stream: std.net.Stream,
    };

    fn handleConnection(ctx: ConnectionContext) void {
        defer ctx.stream.close();
        var server = ctx.server;
        var req_buf: [16 * 1024]u8 = undefined;
        const n = ctx.stream.read(&req_buf) catch return;
        if (n == 0) return;
        const req = req_buf[0..n];

        // Parse request line: "METHOD <path> HTTP/1.1"
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
        const request_line = req[0..line_end];
        var it = std.mem.splitScalar(u8, request_line, ' ');
        const method = it.next() orelse return;
        const path = it.next() orelse return;

        // POST bodies are Content-Length framed; read the full body.
        var body: []const u8 = &.{};
        var body_owned: ?[]u8 = null;
        defer if (body_owned) |b| server.allocator.free(b);
        if (std.mem.eql(u8, method, "POST")) {
            const header_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse {
                sendResponse(server, ctx.stream, "400 Bad Request", "text/plain", "missing headers");
                return;
            };
            const content_length = contentLengthOf(req[0..header_end]) orelse {
                sendResponse(server, ctx.stream, "400 Bad Request", "text/plain", "missing content-length");
                return;
            };
            if (content_length > server.config.max_relay_bytes) {
                sendResponse(server, ctx.stream, "413 Payload Too Large", "text/plain", "payload too large");
                return;
            }
            const body_start = header_end + 4;
            if (body_start + content_length <= req.len) {
                body = req[body_start .. body_start + content_length];
            } else {
                const missing = body_start + content_length - req.len;
                const buf = server.allocator.alloc(u8, missing) catch {
                    sendResponse(server, ctx.stream, "500 Internal Server Error", "text/plain", "alloc error");
                    return;
                };
                body_owned = buf;
                var got: usize = 0;
                while (got < missing) {
                    const r = ctx.stream.read(buf[got..]) catch {
                        sendResponse(server, ctx.stream, "400 Bad Request", "text/plain", "body read error");
                        return;
                    };
                    if (r == 0) {
                        sendResponse(server, ctx.stream, "400 Bad Request", "text/plain", "short body");
                        return;
                    }
                    got += r;
                }
                body = buf;
            }
        }

        // WebRTC signaling + relay API routes (browser P2P mirror bridge).
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/api/signaling/peers")) return handlePeers(server, ctx.stream);
            if (std.mem.startsWith(u8, path, "/api/signaling/offers")) return handleOffers(server, ctx.stream, path);
            if (std.mem.startsWith(u8, path, "/api/signaling/answer")) return handleAnswerGet(server, ctx.stream, path);
            if (std.mem.startsWith(u8, path, "/api/signaling/ice")) return handleIceGet(server, ctx.stream, path);
            if (std.mem.startsWith(u8, path, "/api/relay/")) return handleRelayGet(server, ctx.stream, path);
        } else if (std.mem.eql(u8, method, "POST")) {
            if (std.mem.eql(u8, path, "/api/signaling/register")) return handleRegister(server, ctx.stream, body);
            if (std.mem.eql(u8, path, "/api/signaling/offer")) return handleOfferPost(server, ctx.stream, body);
            if (std.mem.eql(u8, path, "/api/signaling/answer")) return handleAnswerPost(server, ctx.stream, body);
            if (std.mem.eql(u8, path, "/api/signaling/ice")) return handleIcePost(server, ctx.stream, body);
            if (std.mem.startsWith(u8, path, "/api/relay/")) return handleRelayPut(server, ctx.stream, path, body);
            sendResponse(server, ctx.stream, "404 Not Found", "text/plain", "not found");
            return;
        } else {
            sendResponse(server, ctx.stream, "405 Method Not Allowed", "text/plain", "method not allowed");
            return;
        }

        // Static payload serving (reject traversal).
        var path_buf: [512]u8 = undefined;
        const clean_path = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        const rel = if (std.mem.eql(u8, clean_path, "/")) "index.html" else clean_path[1..];
        if (std.mem.indexOf(u8, rel, "..") != null) {
            sendResponse(server, ctx.stream, "403 Forbidden", "text/plain", "forbidden");
            return;
        }
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ server.config.root_dir, rel }) catch {
            sendResponse(server, ctx.stream, "404 Not Found", "text/plain", "not found");
            return;
        };

        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            sendResponse(server, ctx.stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        defer file.close();
        const data = file.readToEndAlloc(server.allocator, 400 * 1024 * 1024) catch {
            sendResponse(server, ctx.stream, "500 Internal Server Error", "text/plain", "read error");
            return;
        };
        defer server.allocator.free(data);

        const content_type = contentTypeFor(rel);
        sendResponse(server, ctx.stream, "200 OK", content_type, data);
    }

    fn contentTypeFor(path: []const u8) []const u8 {
        if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".json")) return "application/json";
        if (std.mem.endsWith(u8, path, ".qsc")) return "application/octet-stream";
        if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
        if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
        return "application/octet-stream";
    }

    fn sendResponse(server: *MasterServer, stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
        _ = server;
        var head_buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ status, content_type, body.len }) catch return;
        stream.writeAll(head) catch return;
        stream.writeAll(body) catch return;
    }

    fn sendJson(server: *MasterServer, stream: std.net.Stream, value: anytype) void {
        var out = std.ArrayList(u8).init(server.allocator);
        defer out.deinit();
        std.json.stringify(value, .{}, out.writer()) catch {
            sendResponse(server, stream, "500 Internal Server Error", "text/plain", "serialize error");
            return;
        };
        sendResponse(server, stream, "200 OK", "application/json", out.items);
    }

    fn handlePeers(server: *MasterServer, stream: std.net.Stream) void {
        var buf: [64]PeerInfo = undefined;
        const peers = server.signaling.peersSnapshot(&buf);
        server.sendJson(stream, .{ .peers = peers });
    }

    fn handleRegister(server: *MasterServer, stream: std.net.Stream, body: []const u8) void {
        const parsed = std.json.parseFromSlice(RegisterReq, server.allocator, body, .{}) catch {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad json");
            return;
        };
        defer parsed.deinit();
        server.signaling.register(parsed.value.peer_id, parsed.value.payloads) catch {
            sendResponse(server, stream, "500 Internal Server Error", "text/plain", "state error");
            return;
        };
        server.sendJson(stream, .{ .peer_id = parsed.value.peer_id, .peers = server.signaling.peerCount() });
    }

    fn handleOfferPost(server: *MasterServer, stream: std.net.Stream, body: []const u8) void {
        const parsed = std.json.parseFromSlice(OfferReq, server.allocator, body, .{}) catch {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad json");
            return;
        };
        defer parsed.deinit();
        const offer_id = server.signaling.offer(parsed.value.from, parsed.value.target, parsed.value.sdp) catch |err| {
            const status = if (err == error.UnknownPeer) "404 Not Found" else "500 Internal Server Error";
            sendResponse(server, stream, status, "text/plain", @errorName(err));
            return;
        };
        server.sendJson(stream, .{ .offer_id = offer_id });
    }

    fn handleOffers(server: *MasterServer, stream: std.net.Stream, path: []const u8) void {
        const target = queryParam(path, "target") orelse {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "missing target");
            return;
        };
        var offers = std.ArrayList(SignalOffer).init(server.allocator);
        defer offers.deinit();
        server.signaling.pendingOffers(target, &offers) catch {
            sendResponse(server, stream, "500 Internal Server Error", "text/plain", "state error");
            return;
        };
        server.sendJson(stream, .{ .offers = offers.items });
    }

    fn handleAnswerPost(server: *MasterServer, stream: std.net.Stream, body: []const u8) void {
        const parsed = std.json.parseFromSlice(AnswerReq, server.allocator, body, .{}) catch {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad json");
            return;
        };
        defer parsed.deinit();
        server.signaling.answer(parsed.value.offer_id, parsed.value.from, parsed.value.sdp) catch |err| {
            const status = if (err == error.UnknownOffer) "404 Not Found" else "500 Internal Server Error";
            sendResponse(server, stream, status, "text/plain", @errorName(err));
            return;
        };
        sendResponse(server, stream, "200 OK", "application/json", "{\"ok\":true}");
    }

    fn handleAnswerGet(server: *MasterServer, stream: std.net.Stream, path: []const u8) void {
        const offer_id = std.fmt.parseInt(u64, queryParam(path, "offer_id") orelse "", 10) catch {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad offer_id");
            return;
        };
        server.sendJson(stream, .{ .answer = server.signaling.answerFor(offer_id) });
    }

    fn handleIcePost(server: *MasterServer, stream: std.net.Stream, body: []const u8) void {
        const parsed = std.json.parseFromSlice(IceReq, server.allocator, body, .{}) catch {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad json");
            return;
        };
        defer parsed.deinit();
        server.signaling.addIce(parsed.value.from, parsed.value.target, parsed.value.candidate) catch |err| {
            const status = if (err == error.UnknownPeer) "404 Not Found" else "500 Internal Server Error";
            sendResponse(server, stream, status, "text/plain", @errorName(err));
            return;
        };
        sendResponse(server, stream, "200 OK", "application/json", "{\"ok\":true}");
    }

    fn handleIceGet(server: *MasterServer, stream: std.net.Stream, path: []const u8) void {
        const target = queryParam(path, "target") orelse {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "missing target");
            return;
        };
        var ice = std.ArrayList(IceMsg).init(server.allocator);
        defer ice.deinit();
        server.signaling.iceFor(target, &ice) catch {
            sendResponse(server, stream, "500 Internal Server Error", "text/plain", "state error");
            return;
        };
        server.sendJson(stream, .{ .candidates = ice.items });
    }

    fn handleRelayPut(server: *MasterServer, stream: std.net.Stream, path: []const u8, body: []const u8) void {
        const name = relayName(path) orelse {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad name");
            return;
        };
        if (body.len > server.config.max_relay_bytes) {
            sendResponse(server, stream, "413 Payload Too Large", "text/plain", "payload too large");
            return;
        }
        server.signaling.relayPut(name, body) catch {
            sendResponse(server, stream, "500 Internal Server Error", "text/plain", "state error");
            return;
        };
        sendResponse(server, stream, "200 OK", "application/json", "{\"ok\":true}");
    }

    fn handleRelayGet(server: *MasterServer, stream: std.net.Stream, path: []const u8) void {
        const name = relayName(path) orelse {
            sendResponse(server, stream, "400 Bad Request", "text/plain", "bad name");
            return;
        };
        const bytes = server.signaling.relayGet(name) orelse {
            sendResponse(server, stream, "404 Not Found", "text/plain", "not in relay");
            return;
        };
        sendResponse(server, stream, "200 OK", "application/octet-stream", bytes);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "master_server: content types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", MasterServer.contentTypeFor("universe.html"));
    try std.testing.expectEqualStrings("application/json", MasterServer.contentTypeFor("seed_manifest.json"));
    try std.testing.expectEqualStrings("application/octet-stream", MasterServer.contentTypeFor("qstar_corpus.qsc"));
    try std.testing.expectEqualStrings("application/wasm", MasterServer.contentTypeFor("qstar_llm.wasm"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", MasterServer.contentTypeFor("qstar_corpus_distilled.txt"));
}

test "master_server: default config" {
    const cfg = MasterServerConfig{};
    try std.testing.expectEqual(@as(u16, 11436), cfg.port);
    try std.testing.expectEqualStrings("zig-out/master", cfg.root_dir);
}

// =============================================================================
// WebRTC signaling + relay state (browser P2P mirror bridge)
// =============================================================================

pub const PeerInfo = struct {
    peer_id: []const u8,
    payloads: []const []const u8,
    last_seen_ms: i64,
};

pub const SignalOffer = struct {
    offer_id: u64,
    from: []const u8,
    target: []const u8,
    sdp: []const u8,
};

pub const SignalAnswer = struct {
    offer_id: u64,
    from: []const u8,
    sdp: []const u8,
};

pub const IceMsg = struct {
    from: []const u8,
    target: []const u8,
    candidate: []const u8,
};

const RegisterReq = struct { peer_id: []const u8, payloads: []const []const u8 = &.{} };
const OfferReq = struct { from: []const u8, target: []const u8, sdp: []const u8 };
const AnswerReq = struct { offer_id: u64, from: []const u8, sdp: []const u8 };
const IceReq = struct { from: []const u8, target: []const u8, candidate: []const u8 };

/// Thread-safe in-memory signaling registry + relay cache. All strings and
/// blobs are arena-owned for the lifetime of the master server; every access
/// is guarded by the mutex because connections are handled on spawned threads.
pub const SignalingState = struct {
    // The arena is heap-allocated so its address (and therefore the allocator
    // handed to the maps/lists below) stays stable across struct copies.
    arena: *std.heap.ArenaAllocator,
    child_allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    peers: std.StringHashMap(PeerInfo),
    offers: std.ArrayList(SignalOffer),
    answers: std.ArrayList(SignalAnswer),
    ice: std.ArrayList(IceMsg),
    relay: std.StringHashMap([]const u8),
    next_offer_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) SignalingState {
        const arena = allocator.create(std.heap.ArenaAllocator) catch @panic("signaling arena oom");
        arena.* = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();
        return .{
            .arena = arena,
            .child_allocator = allocator,
            .peers = std.StringHashMap(PeerInfo).init(a),
            .offers = std.ArrayList(SignalOffer).init(a),
            .answers = std.ArrayList(SignalAnswer).init(a),
            .ice = std.ArrayList(IceMsg).init(a),
            .relay = std.StringHashMap([]const u8).init(a),
        };
    }

    pub fn deinit(self: *SignalingState) void {
        self.arena.deinit();
        self.child_allocator.destroy(self.arena);
    }

    pub fn register(self: *SignalingState, peer_id: []const u8, payloads: []const []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = self.arena.allocator();
        const id = try a.dupe(u8, peer_id);
        const pl = try a.alloc([]const u8, payloads.len);
        for (payloads, 0..) |p, i| pl[i] = try a.dupe(u8, p);
        try self.peers.put(id, .{ .peer_id = id, .payloads = pl, .last_seen_ms = std.time.milliTimestamp() });
    }

    pub fn peerCount(self: *SignalingState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.peers.count();
    }

    pub fn peerPayloads(self: *SignalingState, peer_id: []const u8) ?[]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.peers.get(peer_id) orelse return null;
        return p.payloads;
    }

    pub fn peersSnapshot(self: *SignalingState, buf: []PeerInfo) []PeerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.peers.iterator();
        while (it.next()) |e| {
            if (n >= buf.len) break;
            buf[n] = e.value_ptr.*;
            n += 1;
        }
        return buf[0..n];
    }

    pub fn offer(self: *SignalingState, from: []const u8, target: []const u8, sdp: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.peers.contains(target)) return error.UnknownPeer;
        const a = self.arena.allocator();
        const id = self.next_offer_id;
        self.next_offer_id += 1;
        try self.offers.append(.{
            .offer_id = id,
            .from = try a.dupe(u8, from),
            .target = try a.dupe(u8, target),
            .sdp = try a.dupe(u8, sdp),
        });
        return id;
    }

    pub fn pendingOffers(self: *SignalingState, target: []const u8, out: *std.ArrayList(SignalOffer)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.offers.items) |o| {
            if (std.mem.eql(u8, o.target, target)) try out.append(o);
        }
    }

    pub fn answer(self: *SignalingState, offer_id: u64, from: []const u8, sdp: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var found = false;
        for (self.offers.items) |o| {
            if (o.offer_id == offer_id) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownOffer;
        const a = self.arena.allocator();
        try self.answers.append(.{
            .offer_id = offer_id,
            .from = try a.dupe(u8, from),
            .sdp = try a.dupe(u8, sdp),
        });
    }

    pub fn answerFor(self: *SignalingState, offer_id: u64) ?SignalAnswer {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.answers.items) |ans| {
            if (ans.offer_id == offer_id) return ans;
        }
        return null;
    }

    pub fn addIce(self: *SignalingState, from: []const u8, target: []const u8, candidate: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.peers.contains(target)) return error.UnknownPeer;
        const a = self.arena.allocator();
        try self.ice.append(.{
            .from = try a.dupe(u8, from),
            .target = try a.dupe(u8, target),
            .candidate = try a.dupe(u8, candidate),
        });
    }

    pub fn iceFor(self: *SignalingState, target: []const u8, out: *std.ArrayList(IceMsg)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.ice.items) |m| {
            if (std.mem.eql(u8, m.target, target)) try out.append(m);
        }
    }

    pub fn relayPut(self: *SignalingState, name: []const u8, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = self.arena.allocator();
        const key = try a.dupe(u8, name);
        try self.relay.put(key, try a.dupe(u8, bytes));
    }

    pub fn relayGet(self: *SignalingState, name: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.relay.get(name);
    }
};

fn contentLengthOf(headers: []const u8) ?usize {
    var h = std.mem.splitSequence(u8, headers, "\r\n");
    while (h.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            return std.fmt.parseInt(usize, v, 10) catch null;
        }
    }
    return null;
}

fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.splitScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
    }
    return null;
}

fn relayName(path: []const u8) ?[]const u8 {
    const prefix = "/api/relay/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (name.len == 0) return null;
    if (std.mem.indexOf(u8, name, "/") != null or std.mem.indexOf(u8, name, "..") != null) return null;
    return name;
}

test "master_server: signaling register + peer discovery" {
    var state = SignalingState.init(std.testing.allocator);
    defer state.deinit();
    try state.register("quine-a", &.{ "universe.html", "qstar_corpus_distilled.txt" });
    try state.register("quine-b", &.{});
    try std.testing.expectEqual(@as(usize, 2), state.peerCount());
    const payloads = state.peerPayloads("quine-a") orelse return error.MissingPeer;
    try std.testing.expectEqualStrings("universe.html", payloads[0]);
    try std.testing.expectEqualStrings("qstar_corpus_distilled.txt", payloads[1]);
    try std.testing.expect(state.peerPayloads("nope") == null);
}

test "master_server: offer → answer → ICE round-trip" {
    var state = SignalingState.init(std.testing.allocator);
    defer state.deinit();
    try state.register("quine-a", &.{});
    try state.register("quine-b", &.{});
    const offer_id = try state.offer("quine-a", "quine-b", "sdp-offer-1");
    try std.testing.expect(offer_id > 0);

    var offers = std.ArrayList(SignalOffer).init(std.testing.allocator);
    defer offers.deinit();
    try state.pendingOffers("quine-b", &offers);
    try std.testing.expectEqual(@as(usize, 1), offers.items.len);
    try std.testing.expectEqualStrings("quine-a", offers.items[0].from);
    try std.testing.expectEqualStrings("sdp-offer-1", offers.items[0].sdp);

    try state.answer(offer_id, "quine-b", "sdp-answer-1");
    const ans = state.answerFor(offer_id) orelse return error.MissingAnswer;
    try std.testing.expectEqualStrings("quine-b", ans.from);
    try std.testing.expectEqualStrings("sdp-answer-1", ans.sdp);

    try state.addIce("quine-a", "quine-b", "candidate-1");
    try state.addIce("quine-a", "quine-b", "candidate-2");
    var ice = std.ArrayList(IceMsg).init(std.testing.allocator);
    defer ice.deinit();
    try state.iceFor("quine-b", &ice);
    try std.testing.expectEqual(@as(usize, 2), ice.items.len);
    try std.testing.expectEqualStrings("candidate-1", ice.items[0].candidate);

    try std.testing.expectError(error.UnknownPeer, state.offer("quine-a", "ghost", "sdp"));
    try std.testing.expectError(error.UnknownOffer, state.answer(999, "quine-b", "sdp"));
    try std.testing.expectError(error.UnknownPeer, state.addIce("quine-a", "ghost", "c"));
}

test "master_server: relay put → get round-trip" {
    var state = SignalingState.init(std.testing.allocator);
    defer state.deinit();
    try state.relayPut("qstar_corpus_distilled.txt", "distilled payload bytes");
    const got = state.relayGet("qstar_corpus_distilled.txt") orelse return error.MissingRelayBlob;
    try std.testing.expectEqualStrings("distilled payload bytes", got);
    try std.testing.expect(state.relayGet("missing.txt") == null);
}

test "master_server: relay name sanitization" {
    try std.testing.expectEqualStrings("qstar_corpus.qsc", relayName("/api/relay/qstar_corpus.qsc").?);
    try std.testing.expect(relayName("/api/relay/../etc/passwd") == null);
    try std.testing.expect(relayName("/api/relay/a/b") == null);
    try std.testing.expect(relayName("/api/relay/") == null);
}

test "master_server: query param parsing" {
    try std.testing.expectEqualStrings("quine-b", queryParam("/api/signaling/offers?target=quine-b", "target").?);
    try std.testing.expect(queryParam("/api/signaling/offers", "target") == null);
    try std.testing.expectEqualStrings("7", queryParam("/api/signaling/answer?offer_id=7", "offer_id").?);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
