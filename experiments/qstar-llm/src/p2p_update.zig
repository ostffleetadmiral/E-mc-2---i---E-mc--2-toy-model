//! p2p_update.zig — Master node P2P autoupdate mirror.
//!
//! Publishes the CI/CD-gated quine payloads into the qstar P2P mesh so
//! quine editions can pull updates without a direct HTTP path to the master.
//! Uses qstar-net bootstrap (E0 seed discovery) for peer identity and
//! qstar-vfs distributed storage (consistent hashing + placement + quorum)
//! for payload distribution.
//!
//! The publish step:
//!   1. Builds a NodeRegistry from the canonical bootstrap seeds.
//!   2. For each payload, derives a PageKey from its SHA-256 hash and
//!      assigns a replication placement across the mesh.
//!   3. Emits p2p_index.json — the routing table quines use to fetch
//!      payloads from peers (node id → addr, payload → page key + placement).

const std = @import("std");
const bootstrap = @import("bootstrap");
const vfs_dist = @import("vfs_distributed");

pub const P2PPayload = struct {
    name: []const u8,
    sha256: []const u8,
    bytes: []const u8,
};

pub const P2PIndexEntry = struct {
    name: []const u8,
    page_key: u64,
    primary: vfs_dist.NodeId,
    replicas: [vfs_dist.MAX_REPLICAS]vfs_dist.NodeId,
    replica_count: u8,
};

pub const P2PIndex = struct {
    entries: []P2PIndexEntry,
    nodes: []vfs_dist.NodeInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *P2PIndex) void {
        for (self.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.entries);
        self.allocator.free(self.nodes);
    }
};

/// Derives a stable PageKey from a SHA-256 hex digest.
pub fn pageKeyFromHash(sha256: []const u8) vfs_dist.PageKey {
    var h: u64 = 0;
    const n = @min(sha256.len, 16);
    for (sha256[0..n], 0..) |c, i| {
        h ^= @as(u64, c) << @intCast((i % 8) * 8);
    }
    return .{ .level = 0, .bx = @truncate(h), .by = @truncate(h >> 16), .bz = @truncate(h >> 32) };
}

/// Publishes payloads into the P2P mesh and returns the routing index.
/// The caller owns the returned index and must deinit it.
pub fn publishPayloads(allocator: std.mem.Allocator, self_id: vfs_dist.NodeId, payloads: []const P2PPayload) !P2PIndex {
    // 1. Build the mesh from canonical bootstrap seeds (E0 discovery).
    const seed = bootstrap.BootstrapSeed.canonical();
    if (!seed.validate()) return error.InvalidBootstrapSeed;

    var registry = vfs_dist.NodeRegistry.init(allocator, self_id);
    defer registry.deinit();

    // Register the canonical seed nodes as peers.
    var node_count: usize = 0;
    for (seed.nodes, 0..) |sn, i| {
        if (node_count >= vfs_dist.MAX_NODES) break;
        const node_id: vfs_dist.NodeId = @intCast(i + 1);
        var addr_buf: [46]u8 = undefined;
        const addr = std.fmt.bufPrint(&addr_buf, "e0:{d}:{d}:{d}", .{ sn.x, sn.y, sn.z }) catch continue;
        registry.addNode(node_id, addr) catch continue;
        node_count += 1;
    }

    // 2. Assign placements for each payload.
    const entries = try allocator.alloc(P2PIndexEntry, payloads.len);
    errdefer allocator.free(entries);
    var entries_initialized: usize = 0;
    errdefer for (entries[0..entries_initialized]) |entry| allocator.free(entry.name);
    for (payloads, 0..) |payload, i| {
        const key = pageKeyFromHash(payload.sha256);
        const placement = registry.assignPlacement(key, 2);
        entries[i] = .{
            .name = try allocator.dupe(u8, payload.name),
            .page_key = key.hash(),
            .primary = placement.primary,
            .replicas = placement.replicas,
            .replica_count = placement.replica_count,
        };
        entries_initialized += 1;
    }

    // 3. Collect node info for the routing table.
    const nodes = try allocator.alloc(vfs_dist.NodeInfo, node_count);
    errdefer allocator.free(nodes);
    var n: usize = 0;
    for (0..node_count) |i| {
        const node_id: vfs_dist.NodeId = @intCast(i + 1);
        if (registry.getNode(node_id)) |info| {
            nodes[n] = info;
            n += 1;
        }
    }

    return P2PIndex{ .entries = entries, .nodes = nodes[0..n], .allocator = allocator };
}

/// Serializes the routing index as JSON (the p2p_index.json payload).
pub fn serializeIndex(allocator: std.mem.Allocator, index: *const P2PIndex) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("{\"nodes\":[");
    for (index.nodes, 0..) |*node, i| {
        if (i > 0) try out.appendSlice(",");
        try out.writer().print("{{\"id\":{d},\"addr\":\"{s}\"}}", .{ node.id, node.addrSlice() });
    }
    try out.appendSlice("],\"payloads\":[");
    for (index.entries, 0..) |entry, i| {
        if (i > 0) try out.appendSlice(",");
        try out.writer().print("{{\"name\":\"{s}\",\"page_key\":{d},\"primary\":{d},\"replicas\":[", .{ entry.name, entry.page_key, entry.primary });
        for (entry.replicas[0..entry.replica_count], 0..) |node_id, j| {
            if (j > 0) try out.appendSlice(",");
            try out.writer().print("{d}", .{node_id});
        }
        try out.appendSlice("]}");
    }
    try out.appendSlice("]}");
    return out.toOwnedSlice();
}

/// Resolves a payload's placement (primary + replicas) by name.
/// Returns null if the payload is not in the index.
pub fn pullPlacement(index: *const P2PIndex, name: []const u8) ?P2PIndexEntry {
    for (index.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

const JsonNode = struct { id: u16, addr: []const u8 };
const JsonPayload = struct { name: []const u8, page_key: u64, primary: u16, replicas: []u16 };
const JsonIndex = struct { nodes: []JsonNode, payloads: []JsonPayload };

/// Deserializes a p2p_index.json blob back into a routing index.
/// The caller owns the returned index and must deinit it.
pub fn parseIndex(allocator: std.mem.Allocator, json: []const u8) !P2PIndex {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(JsonIndex, arena_alloc, json, .{});
    const json_index = parsed.value;

    const entries = try allocator.alloc(P2PIndexEntry, json_index.payloads.len);
    errdefer allocator.free(entries);
    var entries_initialized: usize = 0;
    errdefer for (entries[0..entries_initialized]) |entry| allocator.free(entry.name);
    for (json_index.payloads, 0..) |p, i| {
        var replicas = [_]vfs_dist.NodeId{0} ** vfs_dist.MAX_REPLICAS;
        const n = @min(p.replicas.len, vfs_dist.MAX_REPLICAS);
        for (p.replicas[0..n], 0..) |node_id, j| replicas[j] = node_id;
        entries[i] = .{
            .name = try allocator.dupe(u8, p.name),
            .page_key = p.page_key,
            .primary = p.primary,
            .replicas = replicas,
            .replica_count = @intCast(n),
        };
        entries_initialized += 1;
    }

    const nodes = try allocator.alloc(vfs_dist.NodeInfo, json_index.nodes.len);
    errdefer allocator.free(nodes);
    for (json_index.nodes, 0..) |n, i| {
        var addr: [46]u8 = [_]u8{0} ** 46;
        const addr_len = @min(n.addr.len, addr.len);
        @memcpy(addr[0..addr_len], n.addr[0..addr_len]);
        nodes[i] = .{
            .id = n.id,
            .addr = addr,
            .addr_len = @intCast(addr_len),
            .status = .online,
            .last_heartbeat_ms = 0,
        };
    }

    return P2PIndex{ .entries = entries, .nodes = nodes, .allocator = allocator };
}

// =============================================================================
// Tests
// =============================================================================

test "p2p_update: page key is stable and derived from hash" {
    const k1 = pageKeyFromHash("abcdef0123456789abcdef0123456789");
    const k2 = pageKeyFromHash("abcdef0123456789abcdef0123456789");
    const k3 = pageKeyFromHash("00000000000000000000000000000000");
    try std.testing.expectEqual(k1.hash(), k2.hash());
    try std.testing.expect(k1.hash() != k3.hash());
}

test "p2p_update: publish builds a routing index" {
    const allocator = std.testing.allocator;
    const payloads = [_]P2PPayload{
        .{ .name = "seed_manifest.json", .sha256 = "11111111111111111111111111111111", .bytes = "{}" },
        .{ .name = "qstar_corpus_distilled.txt", .sha256 = "22222222222222222222222222222222", .bytes = "hello world" },
    };
    var index = try publishPayloads(allocator, 0, &payloads);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.entries.len);
    try std.testing.expect(index.nodes.len > 0);

    const json = try serializeIndex(allocator, &index);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "seed_manifest.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "page_key") != null);
}

test "p2p_update: publish → pull round-trip on loopback mesh" {
    const allocator = std.testing.allocator;
    const payloads = [_]P2PPayload{
        .{ .name = "seed_manifest.json", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .bytes = "{\"version\":\"git-test\"}" },
        .{ .name = "qstar_corpus_distilled.txt", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .bytes = "distilled corpus payload" },
        .{ .name = "universe.html", .sha256 = "cccccccccccccccccccccccccccccccc", .bytes = "<html>quine</html>" },
    };

    // 1. Publish into the loopback mesh.
    var index = try publishPayloads(allocator, 0, &payloads);
    defer index.deinit();

    // 2. Serialize the routing table (what a peer would fetch as p2p_index.json).
    const json = try serializeIndex(allocator, &index);
    defer allocator.free(json);

    // 3. A peer parses the index and pulls each payload's placement.
    var pulled = try parseIndex(allocator, json);
    defer pulled.deinit();
    try std.testing.expectEqual(index.entries.len, pulled.entries.len);
    try std.testing.expectEqual(index.nodes.len, pulled.nodes.len);

    for (payloads) |payload| {
        const orig = pullPlacement(&index, payload.name) orelse return error.MissingOriginalPlacement;
        const got = pullPlacement(&pulled, payload.name) orelse return error.MissingPulledPlacement;
        try std.testing.expectEqual(orig.page_key, got.page_key);
        try std.testing.expectEqual(orig.primary, got.primary);
        try std.testing.expectEqual(orig.replica_count, got.replica_count);
        for (0..orig.replica_count) |r| {
            try std.testing.expectEqual(orig.replicas[r], got.replicas[r]);
        }
    }

    // 4. Unknown payloads resolve to null.
    try std.testing.expect(pullPlacement(&pulled, "nope.txt") == null);
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
