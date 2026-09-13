//! mesh_peer.zig — TCP-based mesh peer for Docker multi-peer testing.
//!
//! Each peer listens on a TCP port, maintains persistent connections to other peers,
//! and supports a query protocol for the test runner to inspect state.
//!
//! Protocol (query connections from test runner):
//!   - "PING" → "PONG"
//!   - "STATUS" → "CONN:<n> RECV:<n> MODE:<mode> LEVEL:<n> PEERS:<n> RELAY_FWD:<n> RELAY_RECV:<n>"
//!   - "BROADCAST:<msg>" → relays <msg> to all connected peers, returns "OK"
//!   - "RECV_COUNT" → "<n>"
//!   - "CONN_COUNT" → "<n>"
//!   - "GET_MSG:<idx>" → returns message at index, or "NONE"
//!   - "PEER_ID" → returns this peer's 64-char hex PeerId
//!   - "PEERS" → returns list of known peer IDs (one per line)
//!   - "RELAY:<target_id_hex>:<msg>" → sends multi-hop relay message to target peer
//!   - "RENDEZVOUS:<target_id_hex>" → requests rendezvous via first connected peer
//!   - "DISCOVER" → sends peer discovery request to all connected peers
//!   - "RELAY_RECV" → returns count of relay messages received for self
//!   - "RELAY_FWD" → returns count of relay messages forwarded
//!   - "PROBE:<host>:<port>" → TCP probe target, returns "REACHABLE" or "UNREACHABLE:<error>"
//!   - "RELAYROUTE:<relay_header_hex><inner_payload>" → processes incoming relay route packet

const std = @import("std");
const mesh = @import("mesh");
const p2p = @import("p2p_types");
const relay_router = @import("relay_router");

const PEER_PORT: u16 = 9000;
const MSG_BUF_SIZE: usize = 8192;

/// TLS/encryption configuration for mesh peer connections.
/// When enabled, all messages are encrypted using XChaCha20-Poly1305 (IETF).
/// For constrained devices without cert infrastructure, use shared_key mode.
pub const TlsConfig = struct {
    enabled: bool = false,
    /// 32-byte shared key for XChaCha20-Poly1305 encryption.
    shared_key: [32]u8 = [_]u8{0} ** 32,
    /// 24-byte nonce prefix (unique per peer instance).
    nonce_prefix: [24]u8 = [_]u8{0} ** 24,
};

/// Encrypts a message using XChaCha20-Poly1305.
/// Returns ciphertext + 16-byte auth tag appended.
pub fn encryptMessage(key: [32]u8, nonce: [24]u8, plaintext: []const u8, out: []u8) !usize {
    if (out.len < plaintext.len + 16) return error.BufferTooSmall;
    const crypto = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    var tag: [16]u8 = undefined;
    crypto.encrypt(out[0..plaintext.len], &tag, plaintext, &.{}, nonce, key);
    @memcpy(out[plaintext.len .. plaintext.len + 16], &tag);
    return plaintext.len + 16;
}

/// Decrypts a message encrypted with encryptMessage.
/// Returns the plaintext length, or error if auth fails.
pub fn decryptMessage(key: [32]u8, nonce: [24]u8, ciphertext: []const u8, out: []u8) !usize {
    if (ciphertext.len < 16) return error.MessageTooShort;
    const crypto = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    const ct_len = ciphertext.len - 16;
    if (out.len < ct_len) return error.BufferTooSmall;
    var tag: [16]u8 = undefined;
    @memcpy(&tag, ciphertext[ct_len .. ct_len + 16]);
    try crypto.decrypt(out[0..ct_len], ciphertext[0..ct_len], tag, &.{}, nonce, key);
    return ct_len;
}

/// Generates a deterministic nonce from prefix + counter.
fn makeNonce(prefix: [24]u8, counter: u64) [24]u8 {
    var nonce: [24]u8 = prefix;
    const counter_bytes = std.mem.asBytes(&counter);
    @memcpy(nonce[16..24], counter_bytes);
    return nonce;
}

pub const PeerConfig = struct {
    id: u32,
    listen_port: u16,
    peer_addresses: []const []const u8,
    transport_config: mesh.OfflineTransportRouter = .{},
    peer_id: p2p.PeerId,
    location: p2p.Location,
    tls_config: TlsConfig = .{},
};

pub const MeshPeer = struct {
    config: PeerConfig,
    allocator: std.mem.Allocator,
    server: std.net.Server,
    connections: std.ArrayList(std.net.Stream),
    store_and_forward: mesh.StoreAndForward,
    received_messages: std.ArrayList([]u8),
    running: bool,
    mutex: std.Thread.Mutex,
    peer_manager: p2p.PeerManager,
    relay: relay_router.RelayRouter,
    next_conn_id: u32,
    encrypt_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: PeerConfig) !MeshPeer {
        const addr = try std.net.Address.parseIp("0.0.0.0", config.listen_port);
        const server = try addr.listen(.{ .reuse_address = true });

        var pm = p2p.PeerManager.init(allocator);
        const router = relay_router.RelayRouter.init(allocator, config.peer_id, config.location, &pm);

        return .{
            .config = config,
            .allocator = allocator,
            .server = server,
            .connections = std.ArrayList(std.net.Stream).init(allocator),
            .store_and_forward = mesh.StoreAndForward.init(allocator),
            .received_messages = std.ArrayList([]u8).init(allocator),
            .running = false,
            .mutex = .{},
            .peer_manager = pm,
            .relay = router,
            .next_conn_id = 1,
        };
    }

    pub fn deinit(self: *MeshPeer) void {
        for (self.connections.items) |*conn| conn.close();
        self.connections.deinit();
        self.store_and_forward.deinit();
        for (self.received_messages.items) |msg| self.allocator.free(msg);
        self.received_messages.deinit();
        self.peer_manager.deinit();
        self.server.deinit();
    }

    pub fn connectToPeer(self: *MeshPeer, addr_str: []const u8) !u32 {
        const colon = std.mem.lastIndexOf(u8, addr_str, ":") orelse return error.InvalidAddress;
        const host = addr_str[0..colon];
        const port_str = addr_str[colon + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);

        const addr = std.net.Address.parseIp(host, port) catch blk: {
            const list = try std.net.getAddressList(self.allocator, host, port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.NoAddress;
            break :blk list.addrs[0];
        };
        const stream = try std.net.tcpConnectToAddress(addr);

        self.mutex.lock();
        defer self.mutex.unlock();
        const conn_id = self.next_conn_id;
        self.next_conn_id += 1;
        try self.connections.append(stream);

        // Register a placeholder peer — real identity will be learned via handshake
        var temp_id: p2p.PeerId = [_]u8{0} ** 32;
        var hash = std.hash.Wyhash.init(0);
        hash.update(addr_str);
        const h = hash.final();
        @memcpy(temp_id[0..8], std.mem.asBytes(&h));
        const temp_loc = p2p.locationFromSeed(&temp_id);
        self.peer_manager.addPeer(temp_id, temp_loc, conn_id);

        return conn_id;
    }

    pub fn connectToAllPeers(self: *MeshPeer) void {
        for (self.config.peer_addresses) |addr| {
            _ = self.connectToPeer(addr) catch |err| {
                std.debug.print("  Failed to connect to {s}: {s}\n", .{ addr, @errorName(err) });
            };
        }
    }

    pub fn broadcastMessage(self: *MeshPeer, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.config.tls_config.enabled) {
            var encrypted_buf: [MSG_BUF_SIZE + 16]u8 = undefined;
            self.encrypt_counter += 1;
            const nonce = makeNonce(self.config.tls_config.nonce_prefix, self.encrypt_counter);
            const enc_len = encryptMessage(self.config.tls_config.shared_key, nonce, msg, &encrypted_buf) catch return;
            for (self.connections.items) |*conn| {
                _ = conn.write(encrypted_buf[0..enc_len]) catch {};
            }
        } else {
            for (self.connections.items) |*conn| {
                _ = conn.write(msg) catch {};
            }
        }
    }

    /// Send a message to a specific connection by conn_id.
    pub fn sendToConn(self: *MeshPeer, conn_id: u32, msg: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (conn_id == 0 or conn_id > self.connections.items.len) return false;
        const conn = &self.connections.items[conn_id - 1];
        if (self.config.tls_config.enabled) {
            var encrypted_buf: [MSG_BUF_SIZE + 16]u8 = undefined;
            self.encrypt_counter += 1;
            const nonce = makeNonce(self.config.tls_config.nonce_prefix, self.encrypt_counter);
            const enc_len = encryptMessage(self.config.tls_config.shared_key, nonce, msg, &encrypted_buf) catch return false;
            _ = conn.write(encrypted_buf[0..enc_len]) catch return false;
        return true;
        } else {
            _ = conn.write(msg) catch return false;
        return true;
        }
    }

    pub fn run(self: *MeshPeer) !void {
        self.running = true;

        // Start server thread FIRST so peer is responsive to queries
        const server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        defer server_thread.join();

        // Small delay to let server bind
        std.time.sleep(100 * std.time.ns_per_ms);

        // Connect to all peers with retry
        var retry_count: u32 = 0;
        while (retry_count < 10) {
            self.connectToAllPeers();
            self.mutex.lock();
            const conn_count = self.connections.items.len;
            self.mutex.unlock();
            if (conn_count > 0) break;
            std.time.sleep(1 * std.time.ns_per_s);
            retry_count += 1;
        }

        // Run for a fixed duration then exit
        std.time.sleep(30 * std.time.ns_per_s);
        self.running = false;
    }

    fn serverLoop(self: *MeshPeer) void {
        while (self.running) {
            const conn = self.server.accept() catch continue;
            // Spawn a thread per connection so the server loop stays responsive
            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *MeshPeer, conn: std.net.Server.Connection) !void {
        // Set a 10-second read timeout so idle peer connections don't leak threads forever
        const timeval = std.posix.timeval{ .tv_sec = 10, .tv_usec = 0 };
        std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

        var buf: [MSG_BUF_SIZE]u8 = undefined;
        const n = conn.stream.read(&buf) catch {
            conn.stream.close();
            return;
        };
        if (n == 0) {
            conn.stream.close();
            return;
        }

        const data = buf[0..n];

        if (std.mem.startsWith(u8, data, "PING")) {
            _ = conn.stream.write("PONG") catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "STATUS")) {
            self.mutex.lock();
            const conn_count = self.connections.items.len;
            const recv_count = self.received_messages.items.len;
            self.mutex.unlock();
            const mode = self.config.transport_config.selectOfflineTransport();
            const level = self.config.transport_config.fallbackLevel();
            const peer_count = self.peer_manager.connectedCount();
            const relay_fwd = self.relay.relayed_forwarded;
            const relay_recv = self.relay.relayed_received;
            var response: [512]u8 = undefined;
            const resp = std.fmt.bufPrint(&response, "CONN:{d} RECV:{d} MODE:{s} LEVEL:{d} PEERS:{d} RELAY_FWD:{d} RELAY_RECV:{d}", .{
                conn_count, recv_count, @tagName(mode), level, peer_count, relay_fwd, relay_recv,
            }) catch "ERROR";
            _ = conn.stream.write(resp) catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "PEER_ID")) {
            var hex_buf: [64]u8 = undefined;
            const hex = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&self.config.peer_id)}) catch "ERROR";
            _ = conn.stream.write(hex) catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "PEERS")) {
            var response_buf: [4096]u8 = undefined;
            var offset: usize = 0;
            for (self.peer_manager.allPeers()) |p| {
                if (offset + 65 > response_buf.len) break;
                const hex_written = std.fmt.bufPrint(response_buf[offset..], "{s}\n", .{
                    std.fmt.fmtSliceHexLower(&p.id),
                }) catch break;
                offset += hex_written.len;
            }
            if (offset == 0) {
                _ = conn.stream.write("NONE") catch {};
            } else {
                _ = conn.stream.write(response_buf[0..offset]) catch {};
            }
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "RELAY:")) {
            const rest = data[6..];
            const sep = std.mem.indexOf(u8, rest, ":") orelse {
                _ = conn.stream.write("ERROR:FORMAT") catch {};
                conn.stream.close();
                return;
            };
            const target_hex = rest[0..sep];
            const msg = rest[sep + 1 ..];

            var target_id: p2p.PeerId = undefined;
            if (target_hex.len != 64) {
                _ = conn.stream.write("ERROR:BAD_ID") catch {};
                conn.stream.close();
                return;
            }
            _ = std.fmt.hexToBytes(&target_id, target_hex) catch {
                _ = conn.stream.write("ERROR:BAD_HEX") catch {};
                conn.stream.close();
                return;
            };

            const packet = self.relay.buildRelayPacket(self.allocator, target_id, .data, msg) catch {
                _ = conn.stream.write("ERROR:ALLOC") catch {};
                conn.stream.close();
                return;
            };
            defer self.allocator.free(packet);

            const next_conn = self.relay.nextHopForTarget(target_id, 0);
            if (next_conn) |conn_id| {
                const sent = self.sendToConn(conn_id, packet);
                if (sent) {
                    _ = conn.stream.write("OK") catch {};
                } else {
                    _ = conn.stream.write("ERROR:SEND") catch {};
                }
            } else {
                _ = conn.stream.write("ERROR:NO_ROUTE") catch {};
            }
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "RENDEZVOUS:")) {
            const target_hex = data[11..];

            var target_id: p2p.PeerId = undefined;
            if (target_hex.len != 64) {
                _ = conn.stream.write("ERROR:BAD_ID") catch {};
                conn.stream.close();
                return;
            }
            _ = std.fmt.hexToBytes(&target_id, target_hex) catch {
                _ = conn.stream.write("ERROR:BAD_HEX") catch {};
                conn.stream.close();
                return;
            };

            const req_payload = relay_router.RelayRouter.buildRendezvousRequest(target_id);

            self.mutex.lock();
            const has_conn = self.connections.items.len > 0;
            self.mutex.unlock();

            if (has_conn) {
                self.mutex.lock();
                if (self.connections.items.len > 0) {
                    _ = self.connections.items[0].write(&req_payload) catch {};
                }
                self.mutex.unlock();
                _ = conn.stream.write("OK") catch {};
            } else {
                _ = conn.stream.write("ERROR:NO_PEERS") catch {};
            }
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "DISCOVER")) {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.connections.items) |*c| {
                _ = c.write("DISCOVER") catch {};
            }
            _ = conn.stream.write("OK") catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "RELAY_RECV")) {
            var response: [16]u8 = undefined;
            const resp = std.fmt.bufPrint(&response, "{d}", .{self.relay.relayed_received}) catch "0";
            _ = conn.stream.write(resp) catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "RELAY_FWD")) {
            var response: [16]u8 = undefined;
            const resp = std.fmt.bufPrint(&response, "{d}", .{self.relay.relayed_forwarded}) catch "0";
            _ = conn.stream.write(resp) catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "PROBE:")) {
            const target = data[6..];
            const last_colon = std.mem.lastIndexOf(u8, target, ":") orelse {
                _ = conn.stream.write("ERROR:FORMAT") catch {};
                conn.stream.close();
                return;
            };
            const host = target[0..last_colon];
            const port_str = target[last_colon + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                _ = conn.stream.write("ERROR:BAD_PORT") catch {};
                conn.stream.close();
                return;
            };

            const probe_addr = std.net.Address.parseIp(host, port) catch blk: {
                const list = std.net.getAddressList(self.allocator, host, port) catch {
                    _ = conn.stream.write("UNREACHABLE:DNS") catch {};
                    conn.stream.close();
                    return;
                };
                defer list.deinit();
                if (list.addrs.len == 0) {
                    _ = conn.stream.write("UNREACHABLE:DNS") catch {};
                    conn.stream.close();
                    return;
                }
                break :blk list.addrs[0];
            };

            const probe_stream = std.net.tcpConnectToAddress(probe_addr) catch |err| {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "UNREACHABLE:{s}", .{@errorName(err)}) catch "UNREACHABLE";
                _ = conn.stream.write(err_msg) catch {};
                conn.stream.close();
                return;
            };
            probe_stream.close();
            _ = conn.stream.write("REACHABLE") catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "RELAYROUTE:")) {
            const rest = data[11..];

            if (rest.len < 142) {
                _ = conn.stream.write("ERROR:SHORT") catch {};
                conn.stream.close();
                return;
            }

            var relay_hdr_bytes: [p2p.RelayRouteHeader.SIZE]u8 = undefined;
            _ = std.fmt.hexToBytes(&relay_hdr_bytes, rest[0..142]) catch {
                _ = conn.stream.write("ERROR:BAD_HEX") catch {};
                conn.stream.close();
                return;
            };
            const inner_data = rest[142..];

            const full_payload_len = p2p.RelayRouteHeader.SIZE + inner_data.len;
            const full_payload = self.allocator.alloc(u8, full_payload_len) catch {
                conn.stream.close();
                return;
            };
            defer self.allocator.free(full_payload);
            @memcpy(full_payload[0..p2p.RelayRouteHeader.SIZE], &relay_hdr_bytes);
            @memcpy(full_payload[p2p.RelayRouteHeader.SIZE..], inner_data);

            const result = self.relay.handleRelayRoute(full_payload);

            switch (result) {
                .delivered => |d| {
                    self.mutex.lock();
                    const msg_copy = self.allocator.dupe(u8, d.inner_payload) catch {
                        self.mutex.unlock();
                        _ = conn.stream.write("ERROR:ALLOC") catch {};
                        conn.stream.close();
                        return;
                    };
                    self.received_messages.append(msg_copy) catch {
                        self.allocator.free(msg_copy);
                    };
                    self.mutex.unlock();
                    _ = conn.stream.write("DELIVERED") catch {};
                },
                .forward => |f| {
                    _ = self.sendToConn(f.next_conn, f.forward_payload);
                    self.relay.freeForwardPayload(f.forward_payload);
                    _ = conn.stream.write("FORWARDED") catch {};
                },
                .dropped => {
                    _ = conn.stream.write("DROPPED") catch {};
                },
            }
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "BROADCAST:")) {
            const msg = data[10..];
            self.broadcastMessage(msg);
            _ = conn.stream.write("OK") catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "RECV_COUNT")) {
            self.mutex.lock();
            const count = self.received_messages.items.len;
            self.mutex.unlock();
            var response: [16]u8 = undefined;
            const resp = std.fmt.bufPrint(&response, "{d}", .{count}) catch "0";
            _ = conn.stream.write(resp) catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "CONN_COUNT")) {
            self.mutex.lock();
            const count = self.connections.items.len;
            self.mutex.unlock();
            var response: [16]u8 = undefined;
            const resp = std.fmt.bufPrint(&response, "{d}", .{count}) catch "0";
            _ = conn.stream.write(resp) catch {};
            conn.stream.close();
        } else if (std.mem.startsWith(u8, data, "GET_MSG:")) {
            const idx_str = data[8..];
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                _ = conn.stream.write("ERROR") catch {};
                conn.stream.close();
                return;
            };
            self.mutex.lock();
            if (idx < self.received_messages.items.len) {
                const msg = self.received_messages.items[idx];
                _ = conn.stream.write(msg) catch {};
            } else {
                _ = conn.stream.write("NONE") catch {};
            }
            self.mutex.unlock();
            conn.stream.close();
        } else {
            // Peer message — store and relay
            self.mutex.lock();
            const msg = self.allocator.dupe(u8, data) catch {
                self.mutex.unlock();
                conn.stream.close();
                return;
            };
            self.received_messages.append(msg) catch {
                self.allocator.free(msg);
            };
            self.mutex.unlock();
            conn.stream.close();
        }
    }

    pub fn receivedCount(self: *MeshPeer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.received_messages.items.len;
    }

    pub fn connectionCount(self: *MeshPeer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.items.len;
    }

    /// Peer health metrics snapshot.
    pub const PeerHealth = struct {
        peer_id: u32,
        connections: usize,
        received_messages: usize,
        stored_messages: usize,
        uptime_ms: u64,
        relay_queue_size: usize,
        is_running: bool,
    };

    /// Returns a health snapshot for monitoring.
    pub fn getHealth(self: *MeshPeer) PeerHealth {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .peer_id = self.config.id,
            .connections = self.connections.items.len,
            .received_messages = self.received_messages.items.len,
            .stored_messages = self.store_and_forward.messages.items.len,
            .uptime_ms = 0,
            .relay_queue_size = self.relay.queue.items.len,
            .is_running = self.running,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: mesh_peer <id> [peer1_addr peer2_addr ...]\n", .{});
        return error.InvalidArgs;
    }

    const id = try std.fmt.parseInt(u32, args[1], 10);
    var peer_addrs = std.ArrayList([]const u8).init(allocator);
    defer peer_addrs.deinit();
    for (args[2..]) |addr| {
        try peer_addrs.append(addr);
    }

    const peer_id = generatePeerId(id);
    const location = generateLocation(id);

    const config = PeerConfig{
        .id = id,
        .listen_port = PEER_PORT + @as(u16, @intCast(id)),
        .peer_addresses = peer_addrs.items,
        .peer_id = peer_id,
        .location = location,
    };

    std.debug.print("Starting mesh peer {d} on port {d}\n", .{ id, config.listen_port });
    std.debug.print("  PeerId: {s}\n", .{std.fmt.fmtSliceHexLower(&peer_id)});
    std.debug.print("  Location: {d}\n", .{location});
    std.debug.print("  Transport mode: {s}\n", .{@tagName(config.transport_config.selectOfflineTransport())});
    std.debug.print("  Fallback level: {d}\n", .{config.transport_config.fallbackLevel()});
    std.debug.print("  Peer count: {d}\n", .{peer_addrs.items.len});

    var peer = try MeshPeer.init(allocator, config);
    defer peer.deinit();

    try peer.run();

    std.debug.print("Peer {d} finished: {d} connections, {d} messages received\n", .{
        id, peer.connectionCount(), peer.receivedCount(),
    });
}

/// Generate a deterministic PeerId from a numeric peer ID (for testing).
pub fn generatePeerId(numeric_id: u32) p2p.PeerId {
    var id: p2p.PeerId = [_]u8{0} ** 32;
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&numeric_id));
    hash.update("qstar-peer");
    const h = hash.final();
    @memcpy(id[0..8], std.mem.asBytes(&h));
    var i: usize = 8;
    var seed: u64 = h;
    while (i < 32) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        id[i] = @truncate(seed >> 32);
    }
    return id;
}

/// Generate a deterministic Location from a numeric peer ID.
pub fn generateLocation(numeric_id: u32) p2p.Location {
    const id = generatePeerId(numeric_id);
    return p2p.locationFromSeed(&id);
}

test "TLS encrypt/decrypt round trip" {
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const nonce: [24]u8 = [_]u8{0x01} ** 24;
    const plaintext = "Secret mesh message for encryption test!";

    var ciphertext: [64]u8 = undefined;
    const ct_len = try encryptMessage(key, nonce, plaintext, &ciphertext);
    try std.testing.expectEqual(plaintext.len + 16, ct_len);

    var decrypted: [64]u8 = undefined;
    const pt_len = try decryptMessage(key, nonce, ciphertext[0..ct_len], &decrypted);
    try std.testing.expectEqual(plaintext.len, pt_len);
    try std.testing.expectEqualSlices(u8, plaintext, decrypted[0..pt_len]);
}

test "TLS decrypt with wrong key fails" {
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const wrong_key: [32]u8 = [_]u8{0x99} ** 32;
    const nonce: [24]u8 = [_]u8{0x01} ** 24;
    const plaintext = "Secret message";

    var ciphertext: [64]u8 = undefined;
    const ct_len = try encryptMessage(key, nonce, plaintext, &ciphertext);

    var decrypted: [64]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, decryptMessage(wrong_key, nonce, ciphertext[0..ct_len], &decrypted));
}

test "TLS nonce generation is deterministic" {
    const prefix: [24]u8 = [_]u8{0xAA} ** 24;
    const n1 = makeNonce(prefix, 1);
    const n2 = makeNonce(prefix, 1);
    const n3 = makeNonce(prefix, 2);

    try std.testing.expectEqualSlices(u8, &n1, &n2);
    try std.testing.expect(!std.mem.eql(u8, &n1, &n3));
}

test "TLS config defaults to disabled" {
    const tls = TlsConfig{};
    try std.testing.expect(!tls.enabled);
}

test "TLS encrypt empty message" {
    const key: [32]u8 = [_]u8{0x55} ** 32;
    const nonce: [24]u8 = [_]u8{0x02} ** 24;
    const plaintext: []const u8 = "";

    var ciphertext: [32]u8 = undefined;
    const ct_len = try encryptMessage(key, nonce, plaintext, &ciphertext);
    try std.testing.expectEqual(@as(usize, 16), ct_len);

    var decrypted: [32]u8 = undefined;
    const pt_len = try decryptMessage(key, nonce, ciphertext[0..ct_len], &decrypted);
    try std.testing.expectEqual(@as(usize, 0), pt_len);
}
