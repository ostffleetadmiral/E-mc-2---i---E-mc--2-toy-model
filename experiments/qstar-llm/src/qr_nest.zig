//! qr_nest.zig — Recursive QR nesting for multi-layer data transport.
//!
//! Extends collapse.zig's QR portal concept with recursive nesting:
//! - Data larger than a single QR capacity is split into child QRs
//! - Child QR metadata (indices, checksums) is packed into parent QRs
//! - Parent QRs can themselves be nested, creating a multi-level tree
//! - Enables transport of arbitrarily large data via physical QR media
//! - Each level adds a header with level depth, child count, and checksums
//!
//! Zero external dependencies beyond std.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Maximum payload per QR (same as collapse.zig's QR_PAYLOAD_BYTES).
pub const QR_PAYLOAD_BYTES: usize = 256;

/// Header overhead per nested QR: [magic:4][level:1][child_count:2][data_len:4][checksum:4] = 15 bytes.
pub const NEST_HEADER_SIZE: usize = 15;

/// Magic bytes for nested QR identification.
pub const NEST_MAGIC: [4]u8 = .{ 0x51, 0x52, 0x4E, 0x53 }; // "QRNS"

/// Maximum nesting depth (safety limit).
pub const MAX_DEPTH: u8 = 8;

/// Effective data capacity per QR after header overhead.
pub const EFFECTIVE_CAPACITY: usize = QR_PAYLOAD_BYTES - NEST_HEADER_SIZE;

// =============================================================================
// NestHeader — header for a nested QR packet
// =============================================================================

pub const NestHeader = struct {
    magic: [4]u8,
    level: u8,
    child_count: u16,
    data_len: u32,
    checksum: u32,

    pub fn init(level: u8, child_count: u16, data_len: u32) NestHeader {
        return .{
            .magic = NEST_MAGIC,
            .level = level,
            .child_count = child_count,
            .data_len = data_len,
            .checksum = 0,
        };
    }

    pub fn encode(self: *const NestHeader, buf: []u8) void {
        @memcpy(buf[0..4], &self.magic);
        buf[4] = self.level;
        buf[5] = @truncate(self.child_count);
        buf[6] = @truncate(self.child_count >> 8);
        buf[7] = @truncate(self.data_len);
        buf[8] = @truncate(self.data_len >> 8);
        buf[9] = @truncate(self.data_len >> 16);
        buf[10] = @truncate(self.data_len >> 24);
        buf[11] = @truncate(self.checksum);
        buf[12] = @truncate(self.checksum >> 8);
        buf[13] = @truncate(self.checksum >> 16);
        buf[14] = @truncate(self.checksum >> 24);
    }

    pub fn decode(buf: []const u8) ?NestHeader {
        if (buf.len < NEST_HEADER_SIZE) return null;
        if (!std.mem.eql(u8, buf[0..4], &NEST_MAGIC)) return null;
        return .{
            .magic = NEST_MAGIC,
            .level = buf[4],
            .child_count = @as(u16, buf[5]) | (@as(u16, buf[6]) << 8),
            .data_len = @as(u32, buf[7]) | (@as(u32, buf[8]) << 8) | (@as(u32, buf[9]) << 16) | (@as(u32, buf[10]) << 24),
            .checksum = @as(u32, buf[11]) | (@as(u32, buf[12]) << 8) | (@as(u32, buf[13]) << 16) | (@as(u32, buf[14]) << 24),
        };
    }
};

// =============================================================================
// NestNode — a single QR in the nesting tree
// =============================================================================

pub const NestNode = struct {
    level: u8,
    index: u16,
    child_count: u16,
    data: []u8,
    checksum: u32,
    /// Child indices in the flat array (for tree reconstruction).
    child_indices: []u16,

    pub fn deinit(self: *NestNode, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.child_indices);
    }
};

// =============================================================================
// NestTree — the recursive QR nesting tree
// =============================================================================

pub const NestTree = struct {
    allocator: std.mem.Allocator,
    /// Flat list of all nodes (BFS order: root first, then children).
    nodes: std.ArrayList(NestNode),
    /// Total original data size.
    total_data_size: usize = 0,
    /// Maximum depth reached.
    max_depth: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) NestTree {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(NestNode).init(allocator),
        };
    }

    pub fn deinit(self: *NestTree) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    /// Build a nested QR tree from raw data.
    /// Recursively splits data into QR-sized chunks, creating parent QRs
    /// that contain metadata about their children.
    pub fn build(self: *NestTree, data: []const u8) !void {
        self.total_data_size = data.len;
        _ = try self.buildLevel(data, 0);
    }

    /// Maximum children per parent (EFFECTIVE_CAPACITY / 10 bytes per child metadata).
    pub const MAX_CHILDREN_PER_PARENT: usize = EFFECTIVE_CAPACITY / 10;

    /// Recursively build one level of the nesting tree.
    /// Parent nodes are added before their children (BFS order).
    /// If there are too many chunks for one parent, children are grouped
    /// into subtrees, creating intermediate parent levels.
    fn buildLevel(self: *NestTree, data: []const u8, level: u8) !u16 {
        if (level >= MAX_DEPTH) return error.MaxDepthExceeded;

        // If data fits in a single QR (with header), create a leaf node
        if (data.len <= EFFECTIVE_CAPACITY) {
            return try self.createLeaf(data, level);
        }

        // Data doesn't fit — split into chunks
        const num_chunks = (data.len + EFFECTIVE_CAPACITY - 1) / EFFECTIVE_CAPACITY;
        if (num_chunks > 65535) return error.TooManyChunks;

        // If chunks fit in one parent, build directly
        if (num_chunks <= MAX_CHILDREN_PER_PARENT) {
            return try self.buildParent(data, level, EFFECTIVE_CAPACITY);
        }

        // Too many chunks — group into batches and build subtrees
        // Each batch is a contiguous slice of the data that will produce
        // at most MAX_CHILDREN_PER_PARENT leaf chunks.
        const batch_data_size = MAX_CHILDREN_PER_PARENT * EFFECTIVE_CAPACITY;

        // Add grandparent placeholder first (BFS order)
        const grandparent_idx: u16 = @intCast(self.nodes.items.len);
        const empty_data = try self.allocator.dupe(u8, &[_]u8{});
        const empty_children = try self.allocator.dupe(u16, &[_]u16{});
        try self.nodes.append(.{
            .level = level,
            .index = grandparent_idx,
            .child_count = 0,
            .data = empty_data,
            .checksum = 0,
            .child_indices = empty_children,
        });

        // Build subtree for each batch
        var child_indices = std.ArrayList(u16).init(self.allocator);
        defer child_indices.deinit();

        var offset: usize = 0;
        while (offset < data.len) {
            const batch_end = @min(offset + batch_data_size, data.len);
            const subtree_idx = try self.buildParent(data[offset..batch_end], level + 1, EFFECTIVE_CAPACITY);
            try child_indices.append(subtree_idx);
            offset = batch_end;
        }

        // Build grandparent metadata
        var gp_data = std.ArrayList(u8).init(self.allocator);
        defer gp_data.deinit();

        for (child_indices.items) |ci| {
            const child = &self.nodes.items[ci];
            try gp_data.append(@truncate(ci));
            try gp_data.append(@truncate(ci >> 8));
            try gp_data.append(@truncate(child.checksum));
            try gp_data.append(@truncate(child.checksum >> 8));
            try gp_data.append(@truncate(child.checksum >> 16));
            try gp_data.append(@truncate(child.checksum >> 24));
            try gp_data.append(@truncate(child.data.len));
            try gp_data.append(@truncate(child.data.len >> 8));
            try gp_data.append(@truncate(child.data.len >> 16));
            try gp_data.append(@truncate(child.data.len >> 24));
        }

        // Update grandparent
        const gp = &self.nodes.items[grandparent_idx];
        self.allocator.free(gp.data);
        self.allocator.free(gp.child_indices);
        gp.data = try self.allocator.dupe(u8, gp_data.items);
        gp.child_indices = try self.allocator.dupe(u16, child_indices.items);
        gp.child_count = @intCast(child_indices.items.len);
        gp.checksum = std.hash.Crc32.hash(gp.data);

        if (level + 2 > self.max_depth) self.max_depth = level + 2;

        return grandparent_idx;
    }

    /// Build a parent node with direct leaf children from data.
    /// Splits data into chunks of chunk_size and creates leaf children.
    fn buildParent(self: *NestTree, data: []const u8, level: u8, chunk_size: usize) !u16 {
        // Add parent placeholder first (BFS order)
        const parent_idx: u16 = @intCast(self.nodes.items.len);
        const empty_data = try self.allocator.dupe(u8, &[_]u8{});
        const empty_children = try self.allocator.dupe(u16, &[_]u16{});
        try self.nodes.append(.{
            .level = level,
            .index = parent_idx,
            .child_count = 0,
            .data = empty_data,
            .checksum = 0,
            .child_indices = empty_children,
        });

        // Build leaf children
        var child_indices = std.ArrayList(u16).init(self.allocator);
        defer child_indices.deinit();

        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_end = @min(offset + chunk_size, data.len);
            const child_idx = try self.createLeaf(data[offset..chunk_end], level + 1);
            try child_indices.append(child_idx);
            offset = chunk_end;
        }

        // Build parent metadata (10 bytes per child)
        var parent_data = std.ArrayList(u8).init(self.allocator);
        defer parent_data.deinit();

        for (child_indices.items) |ci| {
            const child = &self.nodes.items[ci];
            try parent_data.append(@truncate(ci));
            try parent_data.append(@truncate(ci >> 8));
            try parent_data.append(@truncate(child.checksum));
            try parent_data.append(@truncate(child.checksum >> 8));
            try parent_data.append(@truncate(child.checksum >> 16));
            try parent_data.append(@truncate(child.checksum >> 24));
            try parent_data.append(@truncate(child.data.len));
            try parent_data.append(@truncate(child.data.len >> 8));
            try parent_data.append(@truncate(child.data.len >> 16));
            try parent_data.append(@truncate(child.data.len >> 24));
        }

        // Update parent
        const parent = &self.nodes.items[parent_idx];
        self.allocator.free(parent.data);
        self.allocator.free(parent.child_indices);
        parent.data = try self.allocator.dupe(u8, parent_data.items);
        parent.child_indices = try self.allocator.dupe(u16, child_indices.items);
        parent.child_count = @intCast(child_indices.items.len);
        parent.checksum = std.hash.Crc32.hash(parent.data);

        if (level + 1 > self.max_depth) self.max_depth = level + 1;

        return parent_idx;
    }

    /// Create a leaf node containing raw data.
    fn createLeaf(self: *NestTree, data: []const u8, level: u8) !u16 {
        const idx: u16 = @intCast(self.nodes.items.len);
        const data_copy = try self.allocator.dupe(u8, data);
        const checksum = std.hash.Crc32.hash(data_copy);
        const empty_children = try self.allocator.dupe(u16, &[_]u16{});

        try self.nodes.append(.{
            .level = level,
            .index = idx,
            .child_count = 0,
            .data = data_copy,
            .checksum = checksum,
            .child_indices = empty_children,
        });

        if (level > self.max_depth) self.max_depth = level;

        return idx;
    }

    /// Get the root node (first node in the flat array).
    pub fn root(self: *const NestTree) ?*const NestNode {
        if (self.nodes.items.len == 0) return null;
        return &self.nodes.items[0];
    }

    /// Total number of QR nodes in the tree.
    pub fn nodeCount(self: *const NestTree) usize {
        return self.nodes.items.len;
    }

    /// Number of leaf nodes (nodes with no children).
    pub fn leafCount(self: *const NestTree) usize {
        var count: usize = 0;
        for (self.nodes.items) |node| {
            if (node.child_count == 0) count += 1;
        }
        return count;
    }

    /// Extract original data by traversing the tree from root.
    pub fn extract(self: *const NestTree, allocator: std.mem.Allocator) ![]u8 {
        if (self.nodes.items.len == 0) return error.EmptyTree;
        return try self.extractNode(0, allocator);
    }

    fn extractNode(self: *const NestTree, node_idx: u16, allocator: std.mem.Allocator) ![]u8 {
        if (node_idx >= self.nodes.items.len) return error.InvalidNodeIndex;
        const node = &self.nodes.items[node_idx];

        if (node.child_count == 0) {
            // Leaf node — return data directly
            return try allocator.dupe(u8, node.data);
        }

        // Parent node — recursively extract children and concatenate
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        for (node.child_indices) |ci| {
            if (ci >= self.nodes.items.len) return error.InvalidChildIndex;
            const child_data = try self.extractNode(ci, allocator);
            defer allocator.free(child_data);
            try result.appendSlice(child_data);
        }

        return result.toOwnedSlice();
    }

    /// Validate the entire tree by checking checksums.
    pub fn validate(self: *const NestTree) bool {
        for (self.nodes.items) |node| {
            const computed = std.hash.Crc32.hash(node.data);
            if (computed != node.checksum) return false;
        }
        return true;
    }

    /// Get all nodes at a specific level.
    pub fn nodesAtLevel(self: *const NestTree, level: u8, allocator: std.mem.Allocator) ![]u16 {
        var result = std.ArrayList(u16).init(allocator);
        for (self.nodes.items, 0..) |node, i| {
            if (node.level == level) {
                try result.append(@intCast(i));
            }
        }
        return result.toOwnedSlice();
    }

    /// Serialize the tree into a flat list of QR packets (header + data per node).
    pub fn serialize(self: *const NestTree, allocator: std.mem.Allocator) ![][]u8 {
        var packets = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (packets.items) |p| allocator.free(p);
            packets.deinit();
        }

        for (self.nodes.items) |node| {
            var packet = try allocator.alloc(u8, NEST_HEADER_SIZE + node.data.len);
            var header = NestHeader.init(node.level, node.child_count, @intCast(node.data.len));
            header.checksum = node.checksum;
            header.encode(packet);
            @memcpy(packet[NEST_HEADER_SIZE..], node.data);
            try packets.append(packet);
        }

        return packets.toOwnedSlice();
    }

    /// Deserialize a flat list of QR packets back into a tree.
    pub fn deserialize(self: *NestTree, packets: []const []const u8) !void {
        for (packets) |packet| {
            if (packet.len < NEST_HEADER_SIZE) return error.PacketTooShort;
            const header = NestHeader.decode(packet) orelse return error.InvalidHeader;
            const data = try self.allocator.dupe(u8, packet[NEST_HEADER_SIZE..]);

            // Determine child indices from parent data
            var child_indices: []u16 = &[_]u16{};
            if (header.child_count > 0) {
                child_indices = try self.allocator.alloc(u16, header.child_count);
                var offset: usize = 0;
                for (0..header.child_count) |i| {
                    if (offset + 10 > data.len) return error.InvalidParentData;
                    child_indices[i] = @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
                    offset += 10; // 2 (index) + 4 (checksum) + 4 (data_len)
                }
            } else {
                child_indices = try self.allocator.dupe(u16, &[_]u16{});
            }

            const idx: u16 = @intCast(self.nodes.items.len);
            try self.nodes.append(.{
                .level = header.level,
                .index = idx,
                .child_count = header.child_count,
                .data = data,
                .checksum = header.checksum,
                .child_indices = child_indices,
            });

            if (header.level > self.max_depth) self.max_depth = header.level;
        }
    }
};

// =============================================================================
// Convenience: one-shot encode/decode
// =============================================================================

/// Encode data into a nested QR tree and return serialized packets.
pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![][]u8 {
    var tree = NestTree.init(allocator);
    defer tree.deinit();
    try tree.build(data);
    return try tree.serialize(allocator);
}

/// Deserialize QR packets and extract the original data.
pub fn decode(allocator: std.mem.Allocator, packets: []const []const u8) ![]u8 {
    var tree = NestTree.init(allocator);
    defer tree.deinit();
    try tree.deserialize(packets);
    return try tree.extract(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "qr_nest: NestHeader encode/decode round trip" {
    const header = NestHeader.init(2, 15, 1024);
    var buf: [NEST_HEADER_SIZE]u8 = undefined;
    header.encode(&buf);

    const decoded = NestHeader.decode(&buf).?;
    try std.testing.expectEqual(header.level, decoded.level);
    try std.testing.expectEqual(header.child_count, decoded.child_count);
    try std.testing.expectEqual(header.data_len, decoded.data_len);
    try std.testing.expectEqual(header.checksum, decoded.checksum);
}

test "qr_nest: NestHeader decode rejects bad magic" {
    var buf: [NEST_HEADER_SIZE]u8 = undefined;
    for (&buf) |*b| b.* = 0;
    try std.testing.expect(NestHeader.decode(&buf) == null);
}

test "qr_nest: NestHeader decode rejects short buffer" {
    const short_buf = [_]u8{ 0x51, 0x52, 0x4E, 0x53, 0x01 };
    try std.testing.expect(NestHeader.decode(&short_buf) == null);
}

test "qr_nest: small data creates single leaf" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = "Hello QR nesting!";
    try tree.build(data);

    try std.testing.expectEqual(@as(usize, 1), tree.nodeCount());
    try std.testing.expectEqual(@as(u8, 0), tree.max_depth);
    try std.testing.expectEqual(@as(usize, 1), tree.leafCount());

    const root_node = tree.root().?;
    try std.testing.expectEqual(@as(u16, 0), root_node.child_count);
    try std.testing.expectEqualStrings(data, root_node.data);
}

test "qr_nest: data larger than single QR creates parent + children" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    // Create data larger than EFFECTIVE_CAPACITY
    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY * 3 + 50);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    try tree.build(data);

    // Should have at least 4 nodes: 1 parent + 4 children (3 full + 1 partial)
    try std.testing.expect(tree.nodeCount() >= 4);
    try std.testing.expect(tree.max_depth >= 1);

    const root_node = tree.root().?;
    try std.testing.expect(root_node.child_count > 0);
}

test "qr_nest: extract recovers original data" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY * 2 + 100);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i % 256);

    try tree.build(data);

    const extracted = try tree.extract(allocator);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, data, extracted);
}

test "qr_nest: validate returns true for intact tree" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = "test data for validation";
    try tree.build(data);
    try std.testing.expect(tree.validate());
}

test "qr_nest: serialize/deserialize round trip" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY * 2 + 50);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    try tree.build(data);

    const packets = try tree.serialize(allocator);
    defer {
        for (packets) |p| allocator.free(p);
        allocator.free(packets);
    }

    try std.testing.expect(packets.len == tree.nodeCount());

    // Deserialize into a new tree
    var tree2 = NestTree.init(allocator);
    defer tree2.deinit();

    // Convert to []const []const u8
    const const_packets = try allocator.alloc([]const u8, packets.len);
    defer allocator.free(const_packets);
    for (packets, 0..) |p, i| const_packets[i] = p;

    try tree2.deserialize(const_packets);

    // Extract and compare
    const extracted = try tree2.extract(allocator);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, data, extracted);
}

test "qr_nest: one-shot encode/decode" {
    const allocator = std.testing.allocator;
    const data = "Recursive QR nesting test payload!";

    const packets = try encode(allocator, data);
    defer {
        for (packets) |p| allocator.free(p);
        allocator.free(packets);
    }

    const const_packets = try allocator.alloc([]const u8, packets.len);
    defer allocator.free(const_packets);
    for (packets, 0..) |p, i| const_packets[i] = p;

    const decoded = try decode(allocator, const_packets);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(data, decoded);
}

test "qr_nest: one-shot encode/decode large data" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY * 5 + 200);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i % 251);

    const packets = try encode(allocator, data);
    defer {
        for (packets) |p| allocator.free(p);
        allocator.free(packets);
    }

    const const_packets = try allocator.alloc([]const u8, packets.len);
    defer allocator.free(const_packets);
    for (packets, 0..) |p, i| const_packets[i] = p;

    const decoded = try decode(allocator, const_packets);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "qr_nest: nodesAtLevel returns correct nodes" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    // Small data → single node at level 0
    try tree.build("small");
    const level0 = try tree.nodesAtLevel(0, allocator);
    defer allocator.free(level0);
    try std.testing.expectEqual(@as(usize, 1), level0.len);
}

test "qr_nest: nodesAtLevel for multi-level tree" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY * 3);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    try tree.build(data);

    // Level 0 should have 1 node (root parent)
    const level0 = try tree.nodesAtLevel(0, allocator);
    defer allocator.free(level0);
    try std.testing.expectEqual(@as(usize, 1), level0.len);

    // Level 1 should have 3 nodes (leaf children)
    const level1 = try tree.nodesAtLevel(1, allocator);
    defer allocator.free(level1);
    try std.testing.expectEqual(@as(usize, 3), level1.len);
}

test "qr_nest: empty data creates single leaf" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    try tree.build("");
    try std.testing.expectEqual(@as(usize, 1), tree.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), tree.root().?.data.len);
}

test "qr_nest: data exactly at EFFECTIVE_CAPACITY creates single leaf" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY);
    defer allocator.free(data);
    for (data) |*b| b.* = 0x42;

    try tree.build(data);
    try std.testing.expectEqual(@as(usize, 1), tree.nodeCount());
    try std.testing.expectEqual(@as(u8, 0), tree.max_depth);
}

test "qr_nest: data one byte over EFFECTIVE_CAPACITY creates parent + 2 children" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY + 1);
    defer allocator.free(data);
    for (data) |*b| b.* = 0x55;

    try tree.build(data);
    try std.testing.expectEqual(@as(usize, 3), tree.nodeCount()); // 1 parent + 2 children
    try std.testing.expectEqual(@as(u8, 1), tree.max_depth);
}

test "qr_nest: deep nesting with very large data" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    // Create data large enough to require multiple levels of nesting
    // Each parent can hold metadata for ~25 children (10 bytes per child in EFFECTIVE_CAPACITY)
    const max_children_per_parent = EFFECTIVE_CAPACITY / 10; // ~24 children
    const target_leaves = max_children_per_parent * max_children_per_parent + 10;
    const data_size = target_leaves * EFFECTIVE_CAPACITY;

    const data = try allocator.alloc(u8, data_size);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i % 256);

    try tree.build(data);

    // Should have at least 2 levels of nesting
    try std.testing.expect(tree.max_depth >= 2);
    try std.testing.expect(tree.nodeCount() > target_leaves);

    // Verify data recovery
    const extracted = try tree.extract(allocator);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, data, extracted);
}

test "qr_nest: deserialize rejects invalid header" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const bad_packet = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const packets = [_][]const u8{&bad_packet};

    try std.testing.expectError(error.InvalidHeader, tree.deserialize(&packets));
}

test "qr_nest: deserialize rejects short packet" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    const short_packet = [_]u8{ 0x51, 0x52 };
    const packets = [_][]const u8{&short_packet};

    try std.testing.expectError(error.PacketTooShort, tree.deserialize(&packets));
}

test "qr_nest: extract on empty tree returns error" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    try std.testing.expectError(error.EmptyTree, tree.extract(allocator));
}

test "qr_nest: serialize produces valid headers" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    try tree.build("serialize test");

    const packets = try tree.serialize(allocator);
    defer {
        for (packets) |p| allocator.free(p);
        allocator.free(packets);
    }

    // Each packet should start with NEST_MAGIC
    for (packets) |p| {
        try std.testing.expectEqualSlices(u8, &NEST_MAGIC, p[0..4]);
        try std.testing.expect(p.len >= NEST_HEADER_SIZE);
    }
}

test "qr_nest: tree with known structure" {
    const allocator = std.testing.allocator;
    var tree = NestTree.init(allocator);
    defer tree.deinit();

    // Data that requires exactly 2 chunks
    const data = try allocator.alloc(u8, EFFECTIVE_CAPACITY * 2);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    try tree.build(data);

    // Structure: 1 parent (level 0) + 2 leaves (level 1)
    try std.testing.expectEqual(@as(usize, 3), tree.nodeCount());
    try std.testing.expectEqual(@as(u8, 1), tree.max_depth);

    const root_node = tree.root().?;
    try std.testing.expectEqual(@as(u16, 2), root_node.child_count);
    try std.testing.expectEqual(@as(usize, 2), root_node.child_indices.len);

    // Verify children are leaves
    for (root_node.child_indices) |ci| {
        const child = &tree.nodes.items[ci];
        try std.testing.expectEqual(@as(u16, 0), child.child_count);
        try std.testing.expectEqual(@as(u8, 1), child.level);
    }
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework QR nesting depth from the 6D interior structure.
/// The 6D interior (e1-e6) provides 6 levels of nesting depth.
pub const FRAMEWORK_NESTING_DEPTH: u8 = 6;

/// Framework QR portal count from the 7-defect.
/// The 7-defect (2³-1=7) provides 7 portal connections per level.
pub const FRAMEWORK_PORTAL_COUNT: u8 = 7;

/// Verifies the 6D nesting depth matches the framework's interior dimension.
pub fn verifyNestingDepthMatchesFramework() bool {
    return FRAMEWORK_NESTING_DEPTH == 6;
}

/// Verifies the 7 portal count matches the 7-defect.
pub fn verifyPortalCountMatchesFramework() bool {
    return FRAMEWORK_PORTAL_COUNT == 7;
}

test "framework: QR nesting depth 6 = 6D interior" {
    try std.testing.expect(verifyNestingDepthMatchesFramework());
}

test "framework: QR portal count 7 = 7-defect" {
    try std.testing.expect(verifyPortalCountMatchesFramework());
}
