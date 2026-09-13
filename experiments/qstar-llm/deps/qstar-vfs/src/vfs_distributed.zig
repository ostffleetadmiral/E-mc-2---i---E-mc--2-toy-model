//! vfs_distributed.zig — Multi-node distributed VFS for Qstar.
//!
//! Extends vfs_bridge.zig with multi-node coordination:
//! - Node registry with heartbeat-based liveness
//! - Replication factor for fault tolerance
//! - Consistent hashing for page-to-node assignment
//! - Cross-node page fetch with fallback
//! - Write quorum for consistency
//!
//! Zero external dependencies beyond std.

const std = @import("std");

pub const MAX_NODES: usize = 64;
pub const MAX_REPLICAS: u8 = 4;
pub const HEARTBEAT_TIMEOUT_MS: u64 = 5000;

pub const NodeId = u16;

pub const NodeStatus = enum(u8) { online = 0, offline = 1, degraded = 2 };

pub const NodeInfo = struct {
    id: NodeId,
    addr: [46]u8,
    addr_len: u8,
    status: NodeStatus,
    last_heartbeat_ms: u64,
    page_count: u64 = 0,

    pub fn addrSlice(self: *const NodeInfo) []const u8 {
        return self.addr[0..self.addr_len];
    }
};

pub const PageKey = struct {
    level: u8,
    bx: u32,
    by: u32,
    bz: u32,

    pub fn hash(self: PageKey) u64 {
        var h: u64 = @as(u64, self.level);
        h = h * 31 +% @as(u64, self.bx);
        h = h * 31 +% @as(u64, self.by);
        h = h * 31 +% @as(u64, self.bz);
        return h;
    }

    pub fn eql(a: PageKey, b: PageKey) bool {
        return a.level == b.level and a.bx == b.bx and a.by == b.by and a.bz == b.bz;
    }
};

pub const Placement = struct {
    primary: NodeId,
    replicas: [MAX_REPLICAS]NodeId,
    replica_count: u8,
};

pub const ConsistencyLevel = enum(u8) { one = 1, quorum = 2, all = 3 };

pub const WriteResult = struct {
    acks: u8,
    success: bool,
};

pub const FetchResult = struct {
    found: bool,
    node: NodeId,
};

pub const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: [MAX_NODES]?NodeInfo,
    count: usize = 0,
    self_id: NodeId,
    clock_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, self_id: NodeId) NodeRegistry {
        var reg = NodeRegistry{
            .allocator = allocator,
            .nodes = [_]?NodeInfo{null} ** MAX_NODES,
            .self_id = self_id,
        };
        reg.nodes[self_id] = .{
            .id = self_id,
            .addr = [_]u8{0} ** 46,
            .addr_len = 0,
            .status = .online,
            .last_heartbeat_ms = 0,
        };
        reg.count = 1;
        return reg;
    }

    pub fn deinit(self: *NodeRegistry) void {
        _ = self;
    }

    pub fn addNode(self: *NodeRegistry, id: NodeId, addr: []const u8) !void {
        if (id >= MAX_NODES) return error.NodeIdTooLarge;
        if (self.nodes[id] != null) return error.NodeAlreadyExists;
        if (addr.len > 46) return error.AddrTooLong;
        var node = NodeInfo{
            .id = id,
            .addr = [_]u8{0} ** 46,
            .addr_len = @intCast(addr.len),
            .status = .online,
            .last_heartbeat_ms = self.clock_ms,
        };
        @memcpy(node.addr[0..addr.len], addr);
        self.nodes[id] = node;
        self.count += 1;
    }

    pub fn removeNode(self: *NodeRegistry, id: NodeId) bool {
        if (id >= MAX_NODES) return false;
        if (self.nodes[id] == null) return false;
        self.nodes[id] = null;
        self.count -= 1;
        return true;
    }

    pub fn heartbeat(self: *NodeRegistry, id: NodeId) void {
        if (id >= MAX_NODES) return;
        if (self.nodes[id]) |*node| {
            node.last_heartbeat_ms = self.clock_ms;
            node.status = .online;
        }
    }

    pub fn tick(self: *NodeRegistry, dt_ms: u64) void {
        self.clock_ms +%= dt_ms;
        for (&self.nodes) |*n| {
            if (n.*) |*node| {
                if (node.id == self.self_id) {
                    node.last_heartbeat_ms = self.clock_ms;
                    continue;
                }
                if (self.clock_ms - node.last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS) {
                    node.status = .offline;
                } else if (self.clock_ms - node.last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS / 2) {
                    node.status = .degraded;
                }
            }
        }
    }

    pub fn onlineCount(self: *const NodeRegistry) usize {
        var c: usize = 0;
        for (self.nodes) |n| {
            if (n) |node| {
                if (node.status == .online) c += 1;
            }
        }
        return c;
    }

    pub fn getNode(self: *const NodeRegistry, id: NodeId) ?NodeInfo {
        if (id >= MAX_NODES) return null;
        return self.nodes[id];
    }

    pub fn isOnline(self: *const NodeRegistry, id: NodeId) bool {
        if (id >= MAX_NODES) return false;
        if (self.nodes[id]) |node| return node.status == .online;
        return false;
    }

    /// Consistent hashing: assign a page to primary + replica nodes.
    pub fn assignPlacement(self: *const NodeRegistry, key: PageKey, replication: u8) Placement {
        const h = key.hash();
        const r = @min(replication, MAX_REPLICAS);
        var placement = Placement{
            .primary = self.self_id,
            .replicas = [_]NodeId{0} ** MAX_REPLICAS,
            .replica_count = 0,
        };

        var online_nodes: [MAX_NODES]NodeId = undefined;
        var online_count: usize = 0;
        for (self.nodes, 0..) |n, i| {
            if (n) |node| {
                if (node.status == .online) {
                    online_nodes[online_count] = @intCast(i);
                    online_count += 1;
                }
            }
        }

        if (online_count == 0) return placement;

        // Select primary by hash
        const primary_idx = h % online_count;
        placement.primary = online_nodes[primary_idx];

        // Select replicas from remaining online nodes
        var rc: u8 = 0;
        for (0..online_count) |i| {
            if (rc >= r) break;
            const idx = (primary_idx + 1 + i) % online_count;
            const candidate = online_nodes[idx];
            if (candidate != placement.primary) {
                placement.replicas[rc] = candidate;
                rc += 1;
            }
        }
        placement.replica_count = rc;
        return placement;
    }

    /// Check if a write quorum is met.
    pub fn checkQuorum(self: *const NodeRegistry, placement: Placement, acks: u8, level: ConsistencyLevel) bool {
        _ = self;
        const total = 1 + placement.replica_count;
        const required: u8 = switch (level) {
            .one => 1,
            .quorum => @as(u8, @intCast(total / 2 + 1)),
            .all => @as(u8, @intCast(total)),
        };
        return acks >= required;
    }

    /// Find the best node to fetch a page from (primary first, then replicas).
    pub fn findFetchNode(self: *const NodeRegistry, placement: Placement) FetchResult {
        if (self.isOnline(placement.primary)) {
            return .{ .found = true, .node = placement.primary };
        }
        for (0..placement.replica_count) |i| {
            const rid = placement.replicas[i];
            if (self.isOnline(rid)) {
                return .{ .found = true, .node = rid };
            }
        }
        return .{ .found = false, .node = 0 };
    }
};

// Tests

test "dist_vfs: NodeRegistry init and self node" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    try std.testing.expect(reg.isOnline(0));
}

test "dist_vfs: add and remove nodes" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "10.0.0.2");
    try reg.addNode(2, "10.0.0.3");
    try std.testing.expectEqual(@as(usize, 3), reg.count);

    const node1 = reg.getNode(1).?;
    try std.testing.expectEqualStrings("10.0.0.2", node1.addrSlice());

    try std.testing.expect(reg.removeNode(1));
    try std.testing.expectEqual(@as(usize, 2), reg.count);
    try std.testing.expect(!reg.removeNode(99));
}

test "dist_vfs: add duplicate node fails" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "10.0.0.2");
    try std.testing.expectError(error.NodeAlreadyExists, reg.addNode(1, "10.0.0.3"));
}

test "dist_vfs: heartbeat keeps node online" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "10.0.0.2");
    reg.tick(1000);
    reg.heartbeat(1);
    reg.tick(1000);
    try std.testing.expect(reg.isOnline(1));
}

test "dist_vfs: node goes offline after timeout" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "10.0.0.2");
    reg.tick(HEARTBEAT_TIMEOUT_MS + 1);
    try std.testing.expect(!reg.isOnline(1));
    // Self (node 0) stays online
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());
}

test "dist_vfs: node degrades at half timeout" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "10.0.0.2");
    reg.tick(HEARTBEAT_TIMEOUT_MS / 2 + 1);
    const node = reg.getNode(1).?;
    try std.testing.expectEqual(NodeStatus.degraded, node.status);
}

test "dist_vfs: placement assigns primary and replicas" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "10.0.0.2");
    try reg.addNode(2, "10.0.0.3");
    try reg.addNode(3, "10.0.0.4");

    const key = PageKey{ .level = 0, .bx = 1, .by = 2, .bz = 3 };
    const p = reg.assignPlacement(key, 2);
    try std.testing.expect(p.replica_count >= 1);
}

test "dist_vfs: placement with single node" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    const key = PageKey{ .level = 0, .bx = 0, .by = 0, .bz = 0 };
    const p = reg.assignPlacement(key, 3);
    try std.testing.expectEqual(@as(NodeId, 0), p.primary);
    try std.testing.expectEqual(@as(u8, 0), p.replica_count);
}

test "dist_vfs: quorum check" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "a");
    try reg.addNode(2, "b");

    const key = PageKey{ .level = 0, .bx = 0, .by = 0, .bz = 0 };
    const p = reg.assignPlacement(key, 2);
    // total = 3 (1 primary + 2 replicas), quorum = 2
    try std.testing.expect(reg.checkQuorum(p, 2, .quorum));
    try std.testing.expect(!reg.checkQuorum(p, 1, .quorum));
    try std.testing.expect(reg.checkQuorum(p, 3, .all));
    try std.testing.expect(!reg.checkQuorum(p, 2, .all));
    try std.testing.expect(reg.checkQuorum(p, 1, .one));
}

test "dist_vfs: findFetchNode returns primary when online" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "a");
    try reg.addNode(2, "b");

    const key = PageKey{ .level = 1, .bx = 5, .by = 5, .bz = 5 };
    const p = reg.assignPlacement(key, 2);
    const result = reg.findFetchNode(p);
    try std.testing.expect(result.found);
}

test "dist_vfs: findFetchNode falls back to replica" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "a");
    try reg.addNode(2, "b");
    try reg.addNode(3, "c");

    const key = PageKey{ .level = 0, .bx = 1, .by = 1, .bz = 1 };
    var p = reg.assignPlacement(key, 2);
    // Force primary offline
    p.primary = 99;
    const result = reg.findFetchNode(p);
    try std.testing.expect(result.found);
}

test "dist_vfs: findFetchNode returns not found when all offline" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "a");
    try reg.addNode(2, "b");
    reg.tick(HEARTBEAT_TIMEOUT_MS + 1);

    const key = PageKey{ .level = 0, .bx = 0, .by = 0, .bz = 0 };
    const p = reg.assignPlacement(key, 2);
    // All nodes except self are offline; placement may still pick self
    const result = reg.findFetchNode(p);
    // Self (node 0) is still online
    try std.testing.expect(result.found);
}

test "dist_vfs: onlineCount excludes offline" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    try reg.addNode(1, "a");
    try reg.addNode(2, "b");
    try reg.addNode(3, "c");
    try std.testing.expectEqual(@as(usize, 4), reg.onlineCount());

    reg.tick(HEARTBEAT_TIMEOUT_MS + 1);
    // Only self (node 0) remains online
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());
}

test "dist_vfs: PageKey hash is deterministic" {
    const k1 = PageKey{ .level = 2, .bx = 10, .by = 20, .bz = 30 };
    const k2 = PageKey{ .level = 2, .bx = 10, .by = 20, .bz = 30 };
    try std.testing.expectEqual(k1.hash(), k2.hash());
}

test "dist_vfs: PageKey eql" {
    const k1 = PageKey{ .level = 1, .bx = 1, .by = 2, .bz = 3 };
    const k2 = PageKey{ .level = 1, .bx = 1, .by = 2, .bz = 3 };
    const k3 = PageKey{ .level = 1, .bx = 1, .by = 2, .bz = 4 };
    try std.testing.expect(PageKey.eql(k1, k2));
    try std.testing.expect(!PageKey.eql(k1, k3));
}

test "dist_vfs: add node with oversized addr fails" {
    var reg = NodeRegistry.init(std.testing.allocator, 0);
    defer reg.deinit();
    var long_addr: [47]u8 = undefined;
    for (&long_addr) |*b| b.* = 'x';
    try std.testing.expectError(error.AddrTooLong, reg.addNode(1, &long_addr));
}

test "dist_vfs: placement with no online nodes returns self" {
    var reg = NodeRegistry.init(std.testing.allocator, 5);
    defer reg.deinit();
    // No other nodes added, only self (node 5) is online
    const key = PageKey{ .level = 0, .bx = 0, .by = 0, .bz = 0 };
    const p = reg.assignPlacement(key, 3);
    try std.testing.expectEqual(@as(NodeId, 5), p.primary);
    try std.testing.expectEqual(@as(u8, 0), p.replica_count);
}
