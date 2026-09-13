//! bootstrap.zig — Zero-config peer discovery via hardcoded E0 lattice seed.
//!
//! Instead of relying on gateway peers, the lattice seed is embedded in the
//! binary. Same seed → same lattice → same face patterns → instant peer
//! recognition. Peers discover each other by broadcasting face-QR patterns.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

/// Number of E0 nodes in the base lattice.
pub const E0_NODE_COUNT: usize = 421;

/// Number of seed nodes used for bootstrap (subset of 421).
pub const SEED_NODE_COUNT: usize = 25;

/// Base grid edge.
pub const BASE_EDGE: u32 = 15;

// =============================================================================
// SeedNode — a single E0 node in the bootstrap seed
// =============================================================================

pub const SeedNode = struct {
    x: u32,
    y: u32,
    z: u32,
    channel: u8,
    activation: f32,
};

// =============================================================================
// BootstrapSeed — 25 hardcoded E0 nodes for zero-config discovery
// =============================================================================

pub const BootstrapSeed = struct {
    nodes: [SEED_NODE_COUNT]SeedNode,
    /// Lattice level this seed targets.
    level: u8 = 5,
    /// CRC32 of the seed data for integrity verification.
    checksum: u32,

    /// The canonical hardcoded seed data.
    pub fn canonical() BootstrapSeed {
        var nodes: [SEED_NODE_COUNT]SeedNode = undefined;
        var i: usize = 0;
        var x: u32 = 0;
        while (x < 15 and i < SEED_NODE_COUNT) : (x += 3) {
            var y: u32 = 0;
            while (y < 15 and i < SEED_NODE_COUNT) : (y += 3) {
                const z: u32 = (x + y) % 15;
                if ((x + y + z) % 3 != 0) continue;
                nodes[i] = .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .channel = @intCast((x + y + z) % 7),
                    .activation = @as(f32, @floatFromInt(i)) * (1.0 / @as(f32, @floatFromInt(SEED_NODE_COUNT))),
                };
                i += 1;
            }
        }
        // Fill remaining slots if we didn't get 25
        while (i < SEED_NODE_COUNT) : (i += 1) {
            nodes[i] = .{
                .x = @intCast(i % 15),
                .y = @intCast((i * 3) % 15),
                .z = @intCast((i * 7) % 15),
                .channel = @intCast(i % 7),
                .activation = 0.5,
            };
        }

        return .{
            .nodes = nodes,
            .level = 5,
            .checksum = computeChecksum(&nodes),
        };
    }

    /// Validate the seed's checksum.
    pub fn validate(self: BootstrapSeed) bool {
        return self.checksum == computeChecksum(&self.nodes);
    }

    /// Generate a Location from the seed (for mesh.zig integration).
    pub fn location(self: BootstrapSeed) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        for (self.nodes) |node| {
            hasher.update(std.mem.asBytes(&node.x));
            hasher.update(std.mem.asBytes(&node.y));
            hasher.update(std.mem.asBytes(&node.z));
            hasher.update(std.mem.asBytes(&node.channel));
        }
        return hasher.final();
    }

    /// Serialize seed to bytes for embedding in universe.html or QR codes.
    pub fn serialize(self: BootstrapSeed, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        // Header: magic + level + checksum
        try buf.appendSlice(&.{ 'Q', 'S', 'E', 'D' });
        try buf.append(self.level);
        try buf.appendSlice(std.mem.asBytes(&self.checksum));

        // Nodes: 25 × (x:4 + y:4 + z:4 + ch:1 + act:4) = 25 × 17 = 425 bytes
        for (self.nodes) |node| {
            try buf.appendSlice(std.mem.asBytes(&node.x));
            try buf.appendSlice(std.mem.asBytes(&node.y));
            try buf.appendSlice(std.mem.asBytes(&node.z));
            try buf.append(node.channel);
            try buf.appendSlice(std.mem.asBytes(&node.activation));
        }

        return try buf.toOwnedSlice();
    }

    /// Deserialize seed from bytes.
    pub fn deserialize(data: []const u8) !BootstrapSeed {
        if (data.len < 4 + 1 + 4) return error.SeedTruncated;
        if (!std.mem.eql(u8, data[0..4], &.{ 'Q', 'S', 'E', 'D' })) return error.SeedBadMagic;

        var pos: usize = 4;
        const level = data[pos];
        pos += 1;
        const checksum = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        const node_size = 4 + 4 + 4 + 1 + 4;
        if (data.len < pos + SEED_NODE_COUNT * node_size) return error.SeedTruncatedNodes;

        var nodes: [SEED_NODE_COUNT]SeedNode = undefined;
        for (0..SEED_NODE_COUNT) |i| {
            const off = pos + i * node_size;
            nodes[i] = .{
                .x = std.mem.readInt(u32, data[off..][0..4], .little),
                .y = std.mem.readInt(u32, data[off + 4 ..][0..4], .little),
                .z = std.mem.readInt(u32, data[off + 8 ..][0..4], .little),
                .channel = data[off + 12],
                .activation = @bitCast(std.mem.readInt(u32, data[off + 13 ..][0..4], .little)),
            };
        }

        return .{
            .nodes = nodes,
            .level = level,
            .checksum = checksum,
        };
    }
};

fn computeChecksum(nodes: *const [SEED_NODE_COUNT]SeedNode) u32 {
    var hasher = std.hash.Crc32.init();
    for (nodes) |node| {
        hasher.update(std.mem.asBytes(&node.x));
        hasher.update(std.mem.asBytes(&node.y));
        hasher.update(std.mem.asBytes(&node.z));
        hasher.update(std.mem.asBytes(&node.channel));
        hasher.update(std.mem.asBytes(&node.activation));
    }
    return hasher.final();
}

// =============================================================================
// FaceQR — encode lattice face state as QR-ready bytes
// =============================================================================

/// A face QR payload: identifies a lattice face by its E0 state.
pub const FaceQR = struct {
    /// Seed location hash.
    seed_hash: u64,
    /// Face axis (0=pos_x, 1=neg_x, 2=pos_y, 3=neg_y, 4=pos_z, 5=neg_z).
    face_axis: u8,
    /// 15×15 = 225 face cell activations, quantized to u8.
    face_data: [225]u8,
    /// CRC32 of face_data for integrity.
    checksum: u32,

    /// Generate a FaceQR from a bootstrap seed and face axis.
    pub fn fromSeed(seed: BootstrapSeed, axis: u8) FaceQR {
        var face_data: [225]u8 = undefined;
        // Initialize face data with a seed-dependent pattern
        var hasher = std.hash.Fnv1a_32.init();
        hasher.update(std.mem.asBytes(&seed.location()));
        hasher.update(std.mem.asBytes(&axis));
        const base_hash = hasher.final();

        for (0..225) |i| {
            const fx = i % 15;
            const fz = i / 15;
            // Base pattern from hash ensures uniqueness per seed
            var val: u8 = @intCast((base_hash +% @as(u32, @intCast(i))) % 256);
            // Override with seed node activations where nodes exist
            for (seed.nodes) |node| {
                if (node.x == fx and node.z == fz) {
                    // Incorporate y and channel for uniqueness
                    const combined: u32 = @as(u32, @intFromFloat(node.activation * 200.0)) +
                        @as(u32, node.channel) * 30 +
                        node.y * 15;
                    val = @intCast(combined % 256);
                    break;
                }
            }
            face_data[i] = val;
        }

        var crc_hasher = std.hash.Crc32.init();
        crc_hasher.update(&face_data);
        const cs = crc_hasher.final();

        return .{
            .seed_hash = seed.location(),
            .face_axis = axis,
            .face_data = face_data,
            .checksum = cs,
        };
    }

    /// Serialize to bytes for QR encoding.
    pub fn serialize(self: FaceQR, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        try buf.appendSlice(std.mem.asBytes(&self.seed_hash));
        try buf.append(self.face_axis);
        try buf.appendSlice(&self.face_data);
        try buf.appendSlice(std.mem.asBytes(&self.checksum));

        return try buf.toOwnedSlice();
    }

    /// Deserialize from bytes.
    pub fn deserialize(data: []const u8) !FaceQR {
        const header = 8 + 1;
        if (data.len < header + 225 + 4) return error.FaceQRTruncated;

        var pos: usize = 0;
        const seed_hash = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        const face_axis = data[pos];
        pos += 1;

        var face_data: [225]u8 = undefined;
        @memcpy(&face_data, data[pos..][0..225]);
        pos += 225;

        const checksum = std.mem.readInt(u32, data[pos..][0..4], .little);

        return .{
            .seed_hash = seed_hash,
            .face_axis = face_axis,
            .face_data = face_data,
            .checksum = checksum,
        };
    }

    /// Validate the checksum.
    pub fn validate(self: FaceQR) bool {
        var hasher = std.hash.Crc32.init();
        hasher.update(&self.face_data);
        return hasher.final() == self.checksum;
    }
};

// =============================================================================
// PeerDiscovery — discover peers via face-QR pattern matching
// =============================================================================

pub const DiscoveredPeer = struct {
    addr: []const u8,
    seed_hash: u64,
    face_axis: u8,
    match_score: f32,
};

pub const PeerDiscovery = struct {
    allocator: std.mem.Allocator,
    own_seed: BootstrapSeed,
    discovered: std.ArrayList(DiscoveredPeer),
    /// Known peer addresses (simulated mDNS / lattice routing).
    known_addrs: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, seed: BootstrapSeed) PeerDiscovery {
        return .{
            .allocator = allocator,
            .own_seed = seed,
            .discovered = std.ArrayList(DiscoveredPeer).init(allocator),
            .known_addrs = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PeerDiscovery) void {
        self.discovered.deinit();
        self.known_addrs.deinit();
    }

    /// Generate face-QR payloads for all 6 faces of the lattice.
    pub fn generateFaceQRs(self: *PeerDiscovery) ![6]FaceQR {
        var faces: [6]FaceQR = undefined;
        for (0..6) |axis| {
            faces[axis] = FaceQR.fromSeed(self.own_seed, @intCast(axis));
        }
        return faces;
    }

    /// Check if a received face-QR matches our seed.
    pub fn matchFaceQR(self: *PeerDiscovery, received: FaceQR, peer_addr: []const u8) !bool {
        const own_hash = self.own_seed.location();

        // Same seed hash → same lattice → compatible peers
        if (received.seed_hash == own_hash) {
            // Check if we already discovered this peer
            for (self.discovered.items) |peer| {
                if (std.mem.eql(u8, peer.addr, peer_addr)) return true;
            }

            try self.discovered.append(.{
                .addr = peer_addr,
                .seed_hash = received.seed_hash,
                .face_axis = received.face_axis,
                .match_score = 1.0,
            });
            return true;
        }

        // Different seed → check if face data is compatible (partial match)
        const own_face = FaceQR.fromSeed(self.own_seed, received.face_axis);
        var matching_cells: usize = 0;
        for (0..225) |i| {
            if (own_face.face_data[i] == received.face_data[i]) matching_cells += 1;
        }
        const score = @as(f32, @floatFromInt(matching_cells)) / 225.0;

        if (score > 0.8) {
            try self.discovered.append(.{
                .addr = peer_addr,
                .seed_hash = received.seed_hash,
                .face_axis = received.face_axis,
                .match_score = score,
            });
            return true;
        }

        return false;
    }

    /// Number of discovered peers.
    pub fn peerCount(self: *const PeerDiscovery) usize {
        return self.discovered.items.len;
    }

    /// Get a discovered peer by index.
    pub fn getPeer(self: *const PeerDiscovery, idx: usize) ?DiscoveredPeer {
        if (idx >= self.discovered.items.len) return null;
        return self.discovered.items[idx];
    }
};

// =============================================================================
// BootstrapResult — result of bootstrap from seed
// =============================================================================

pub const BootstrapResult = struct {
    seed_valid: bool,
    face_qrs_generated: usize,
    peers_discovered: usize,
    location_hash: u64,
};

/// Bootstrap from a hardcoded seed. Generates face-QRs and prepares for discovery.
pub fn bootstrapFromSeed(
    allocator: std.mem.Allocator,
    seed: BootstrapSeed,
) !BootstrapResult {
    if (!seed.validate()) {
        return .{
            .seed_valid = false,
            .face_qrs_generated = 0,
            .peers_discovered = 0,
            .location_hash = 0,
        };
    }

    var discovery = PeerDiscovery.init(allocator, seed);
    defer discovery.deinit();

    _ = try discovery.generateFaceQRs();
    const loc = seed.location();

    return .{
        .seed_valid = true,
        .face_qrs_generated = 6,
        .peers_discovered = 0,
        .location_hash = loc,
    };
}

/// Generate a face-QR for a specific face axis from the canonical seed.
pub fn generateFaceQR(axis: u8) !FaceQR {
    const seed = BootstrapSeed.canonical();
    return FaceQR.fromSeed(seed, axis);
}

/// Check if two seeds produce compatible lattices (same location hash).
pub fn seedsCompatible(a: BootstrapSeed, b: BootstrapSeed) bool {
    return a.location() == b.location();
}

// =============================================================================
// Tests
// =============================================================================

test "bootstrap: canonical seed has 25 nodes" {
    const seed = BootstrapSeed.canonical();
    try std.testing.expectEqual(@as(usize, 25), seed.nodes.len);
}

test "bootstrap: canonical seed validates" {
    const seed = BootstrapSeed.canonical();
    try std.testing.expect(seed.validate());
}

test "bootstrap: seed serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    const seed = BootstrapSeed.canonical();
    const serialized = try seed.serialize(allocator);
    defer allocator.free(serialized);

    const restored = try BootstrapSeed.deserialize(serialized);
    try std.testing.expect(restored.validate());
    try std.testing.expectEqual(seed.level, restored.level);
    try std.testing.expectEqual(seed.checksum, restored.checksum);

    for (0..25) |i| {
        try std.testing.expectEqual(seed.nodes[i].x, restored.nodes[i].x);
        try std.testing.expectEqual(seed.nodes[i].y, restored.nodes[i].y);
        try std.testing.expectEqual(seed.nodes[i].z, restored.nodes[i].z);
        try std.testing.expectEqual(seed.nodes[i].channel, restored.nodes[i].channel);
        try std.testing.expectApproxEqAbs(seed.nodes[i].activation, restored.nodes[i].activation, 1e-6);
    }
}

test "bootstrap: seed location is deterministic" {
    const seed1 = BootstrapSeed.canonical();
    const seed2 = BootstrapSeed.canonical();
    try std.testing.expectEqual(seed1.location(), seed2.location());
}

test "bootstrap: face QR generation and validation" {
    const seed = BootstrapSeed.canonical();
    const face = FaceQR.fromSeed(seed, 0);

    try std.testing.expect(face.validate());
    try std.testing.expectEqual(seed.location(), face.seed_hash);
    try std.testing.expectEqual(@as(u8, 0), face.face_axis);
}

test "bootstrap: face QR serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    const seed = BootstrapSeed.canonical();
    const face = FaceQR.fromSeed(seed, 2);

    const serialized = try face.serialize(allocator);
    defer allocator.free(serialized);

    const restored = try FaceQR.deserialize(serialized);
    try std.testing.expect(restored.validate());
    try std.testing.expectEqual(face.seed_hash, restored.seed_hash);
    try std.testing.expectEqual(face.face_axis, restored.face_axis);
    try std.testing.expectEqual(face.checksum, restored.checksum);
}

test "bootstrap: two canonical seeds are compatible" {
    const seed1 = BootstrapSeed.canonical();
    const seed2 = BootstrapSeed.canonical();
    try std.testing.expect(seedsCompatible(seed1, seed2));
}

test "bootstrap: discovery matches same-seed peer" {
    const allocator = std.testing.allocator;
    const seed = BootstrapSeed.canonical();
    var discovery = PeerDiscovery.init(allocator, seed);
    defer discovery.deinit();

    // Simulate receiving a face-QR from a peer with the same seed
    const received = FaceQR.fromSeed(seed, 0);
    const matched = try discovery.matchFaceQR(received, "peer1:9000");

    try std.testing.expect(matched);
    try std.testing.expectEqual(@as(usize, 1), discovery.peerCount());
}

test "bootstrap: discovery rejects incompatible seed" {
    const allocator = std.testing.allocator;
    const seed = BootstrapSeed.canonical();
    var discovery = PeerDiscovery.init(allocator, seed);
    defer discovery.deinit();

    // Create a completely different seed with different node positions
    var diff_nodes: [SEED_NODE_COUNT]SeedNode = undefined;
    for (0..SEED_NODE_COUNT) |i| {
        const x: u32 = @intCast((i * 5 + 1) % 15);
        const y: u32 = @intCast((i * 7 + 2) % 15);
        // Find z in 0..14 that satisfies (x+y+z)%3==0
        var z: u32 = 0;
        while (z < 15) : (z += 1) {
            if ((x + y + z) % 3 == 0) break;
        }
        if (z >= 15) z = 0; // fallback
        diff_nodes[i] = .{
            .x = x,
            .y = y,
            .z = z,
            .channel = @intCast((i + 3) % 7),
            .activation = 1.0,
        };
    }
    const diff_seed = BootstrapSeed{
        .nodes = diff_nodes,
        .level = 5,
        .checksum = computeChecksum(&diff_nodes),
    };

    const received = FaceQR.fromSeed(diff_seed, 0);
    const matched = try discovery.matchFaceQR(received, "peer2:9000");

    // Should not match (different hash, low face data overlap)
    try std.testing.expect(!matched);
    try std.testing.expectEqual(@as(usize, 0), discovery.peerCount());
}

test "bootstrap: bootstrapFromSeed returns valid result" {
    const allocator = std.testing.allocator;
    const seed = BootstrapSeed.canonical();
    const result = try bootstrapFromSeed(allocator, seed);

    try std.testing.expect(result.seed_valid);
    try std.testing.expectEqual(@as(usize, 6), result.face_qrs_generated);
    try std.testing.expect(result.location_hash != 0);
}

test "bootstrap: generateFaceQR for all 6 axes" {
    const allocator = std.testing.allocator;
    const seed = BootstrapSeed.canonical();
    var discovery = PeerDiscovery.init(allocator, seed);
    defer discovery.deinit();

    const faces = try discovery.generateFaceQRs();
    for (0..6) |i| {
        try std.testing.expect(faces[i].validate());
        try std.testing.expectEqual(@as(u8, @intCast(i)), faces[i].face_axis);
    }
}

test "bootstrap: seed node positions satisfy E0 constraint" {
    const seed = BootstrapSeed.canonical();
    for (seed.nodes) |node| {
        // E0 nodes must satisfy (x+y+z) % 3 == 0
        try std.testing.expectEqual(@as(u32, 0), (node.x + node.y + node.z) % 3);
    }
}

test "bootstrap: corrupted seed fails validation" {
    var seed = BootstrapSeed.canonical();
    seed.nodes[0].activation = 999.0;
    // Checksum no longer matches
    try std.testing.expect(!seed.validate());
}
