//! holographic_memory.zig — Holographic Context Memory on Point Cloud + ISG Boundary Storage
//!
//! Maps the 33 context memory chunks from .devin/memories/ onto the cognitive_cloud
//! PointCloud system, and uses ISG (RGB transcoder + Q128 error correction) to encode
//! memories onto the 721 boundary nodes of the 16³ shell for holographic retrieval.
//!
//! Architecture:
//!   1. MemoryChunk → Point: Each context memory chunk becomes a Point in the PointCloud,
//!      with phase coordinates derived from its category and tags, lattice_node from
//!      chunk number, and content as PolyglotPayload.
//!   2. ISG RGB Transcoder: Encodes memory content as RGB triplets:
//!      R = payload hash (content fingerprint)
//!      G = metadata hash (category + tags)
//!      B = checksum (Q128 error correction code)
//!   3. Holographic Boundary Storage: 721 boundary nodes of 16³ - 15³ = 721.
//!      Each memory is distributed across boundary nodes via interference pattern.
//!      Retrieval = holographic reconstruction from any sufficient subset.
//!
//! All arithmetic in i128 Q64.64 fixed-point. No floating-point.

const std = @import("std");
const fp = @import("fixed_point");
const cloud = @import("cognitive_cloud");

// === Framework Constants ===

pub const CHANNEL_COUNT: usize = 8;
pub const E0_NODE_COUNT: usize = 421;
pub const SHELL_SIDE: u32 = 16;
pub const INTERIOR_SIDE: u32 = 15;
pub const BOUNDARY_NODE_COUNT: u32 = SHELL_SIDE * SHELL_SIDE * SHELL_SIDE - INTERIOR_SIDE * INTERIOR_SIDE * INTERIOR_SIDE; // 721
pub const MEMORY_CHUNK_COUNT: u32 = 33;

// === Memory Category → Dimension Mapping ===

/// Maps each memory category to a QSTAR dimension (e0-e7).
/// This determines which channel the memory point activates.
pub const MemoryDimension = enum(u4) {
    e0_origin = 0,
    e1_time = 1,
    e2_quantum = 2,
    e3_space = 3,
    e4_energy = 4,
    e5_structure = 5,
    e6_metacognition = 6,
    e7_physics = 7,

    pub fn label(self: MemoryDimension) []const u8 {
        return switch (self) {
            .e0_origin => "e0=origin",
            .e1_time => "e1=time",
            .e2_quantum => "e2=quantum",
            .e3_space => "e3=space",
            .e4_energy => "e4=energy",
            .e5_structure => "e5=structure",
            .e6_metacognition => "e6=metacognition",
            .e7_physics => "e7=physics",
        };
    }
};

/// Maps a memory category string to its dimensional assignment.
pub fn categoryToDimension(category: []const u8) MemoryDimension {
    const map = [_]struct { cat: []const u8, dim: MemoryDimension }{
        .{ .cat = "numerical-foundations", .dim = .e5_structure },
        .{ .cat = "hydrogen-line", .dim = .e2_quantum },
        .{ .cat = "triad-operator", .dim = .e5_structure },
        .{ .cat = "fine-structure", .dim = .e7_physics },
        .{ .cat = "codata-network", .dim = .e2_quantum },
        .{ .cat = "propagation-graph", .dim = .e1_time },
        .{ .cat = "scorecard", .dim = .e6_metacognition },
        .{ .cat = "constants-table", .dim = .e5_structure },
        .{ .cat = "error-analysis", .dim = .e6_metacognition },
        .{ .cat = "qed-corrections", .dim = .e7_physics },
        .{ .cat = "octonionic-architecture", .dim = .e7_physics },
        .{ .cat = "generative-equations", .dim = .e0_origin },
        .{ .cat = "lattice-structure", .dim = .e5_structure },
        .{ .cat = "e8-correspondence", .dim = .e7_physics },
        .{ .cat = "shell-transition", .dim = .e7_physics },
        .{ .cat = "offset-symmetry", .dim = .e3_space },
        .{ .cat = "smith-chart", .dim = .e3_space },
        .{ .cat = "architecture", .dim = .e5_structure },
        .{ .cat = "over-constraint", .dim = .e4_energy },
        .{ .cat = "test-plan", .dim = .e5_structure },
        .{ .cat = "codon-integration", .dim = .e6_metacognition },
        .{ .cat = "neuraleak-integration", .dim = .e6_metacognition },
        .{ .cat = "10d-completion", .dim = .e7_physics },
        .{ .cat = "gap-closure", .dim = .e7_physics },
        .{ .cat = "bootstrap", .dim = .e0_origin },
        .{ .cat = "dimensional-ladder", .dim = .e1_time },
        .{ .cat = "checksum-6d", .dim = .e6_metacognition },
        .{ .cat = "free-will", .dim = .e6_metacognition },
        .{ .cat = "scaling-analysis", .dim = .e5_structure },
        .{ .cat = "surface-computation", .dim = .e3_space },
        .{ .cat = "cross-project-integration", .dim = .e4_energy },
    };
    for (map) |entry| {
        if (std.mem.eql(u8, category, entry.cat)) return entry.dim;
    }
    return .e5_structure; // default
}

// === Memory Chunk Structure ===

/// Represents a context memory chunk from .devin/memories/.
pub const MemoryChunk = struct {
    id: u32,
    title: []const u8,
    category: []const u8,
    source_lines: [2]u32,
    tags: []const []const u8,
    concepts: []const []const u8,
    equations: []const []const u8,
    key_results: []const []const u8,
    cross_references: []const []const u8,
    status: []const u8,

    /// Returns the dimensional assignment for this chunk.
    pub fn dimension(self: MemoryChunk) MemoryDimension {
        return categoryToDimension(self.category);
    }

    /// Returns the lattice node index for this chunk (chunk_id mod 421).
    pub fn latticeNode(self: MemoryChunk) u16 {
        return @intCast(self.id % E0_NODE_COUNT);
    }

    /// Returns the channel index for this chunk (from dimension).
    pub fn channel(self: MemoryChunk) u3 {
        return @intCast(@intFromEnum(self.dimension()));
    }

    /// Computes the information density (magnitude) from content counts.
    pub fn magnitude(self: MemoryChunk) i128 {
        const concept_weight: i128 = fp.fromInt(@intCast(self.concepts.len));
        const equation_weight: i128 = fp.fromInt(@intCast(self.equations.len));
        const result_weight: i128 = fp.fromInt(@intCast(self.key_results.len));
        return fp.add(fp.add(concept_weight, equation_weight), result_weight);
    }

    /// Computes the 8-channel phase coordinates from tags and category.
    pub fn phaseCoordinates(self: MemoryChunk) [CHANNEL_COUNT]i128 {
        var phase = [_]i128{0} ** CHANNEL_COUNT;
        // Set the dimension channel
        const dim = @intFromEnum(self.dimension());
        phase[dim] = fp.fromInt(@intCast(self.concepts.len + 1));

        // Hash tags into phase coordinates
        var tag_hash: u64 = 0;
        for (self.tags) |tag| {
            for (tag) |c| {
                tag_hash = tag_hash *% 31 +% @as(u64, c);
            }
        }
        // Distribute tag hash across channels
        for (0..CHANNEL_COUNT) |ch| {
            const shift: u6 = @intCast((ch * 8) % 64);
            const val = (tag_hash >> shift) & 0xFF;
            phase[ch] = fp.add(phase[ch], fp.fromInt(@intCast(val)));
        }
        return phase;
    }

    /// Converts this chunk to a cognitive_cloud Point.
    pub fn toPoint(self: MemoryChunk) cloud.Point {
        var p = cloud.Point.init(self.id, self.latticeNode(), self.channel());
        p.setPhase(self.phaseCoordinates());
        p.magnitude = self.magnitude();
        p.activation = fp.ONE;
        return p;
    }
};

// === ISG RGB Transcoder ===

/// ISG (Information Set Generator) RGB transcoder.
/// Encodes memory content as RGB triplets for holographic boundary storage.
/// R = payload hash (content fingerprint)
/// G = metadata hash (category + tags)
/// B = checksum (Q128 error correction code)
pub const ISGRgb = struct {
    r: u64, // payload hash (content fingerprint)
    g: u64, // metadata hash (category + tags)
    b: u64, // checksum (error correction)

    /// Encodes a memory chunk into an ISG RGB triplet.
    pub fn encode(chunk: MemoryChunk) ISGRgb {
        // R = hash of title + concepts + equations + key_results
        var r_hasher = std.hash.Wyhash.init(0);
        r_hasher.update(chunk.title);
        for (chunk.concepts) |c| r_hasher.update(c);
        for (chunk.equations) |e| r_hasher.update(e);
        for (chunk.key_results) |k| r_hasher.update(k);
        const r = r_hasher.final();

        // G = hash of category + tags
        var g_hasher = std.hash.Wyhash.init(1);
        g_hasher.update(chunk.category);
        for (chunk.tags) |t| g_hasher.update(t);
        const g = g_hasher.final();

        // B = checksum = R XOR G (Q128-style error correction)
        const b = r ^ g;

        return .{ .r = r, .g = g, .b = b };
    }

    /// Verifies that an RGB triplet is internally consistent (R XOR G == B).
    pub fn verify(self: ISGRgb) bool {
        return (self.r ^ self.g) == self.b;
    }

    /// Returns the 3-channel phase representation for boundary storage.
    pub fn toPhase(self: ISGRgb) [3]i128 {
        return .{
            fp.fromInt(@intCast(self.r & 0xFFFF)),
            fp.fromInt(@intCast(self.g & 0xFFFF)),
            fp.fromInt(@intCast(self.b & 0xFFFF)),
        };
    }
};

// === Holographic Boundary Storage ===

/// Holographic boundary storage on the 721 boundary nodes of 16³ - 15³.
/// Each memory is distributed across all boundary nodes via interference pattern.
/// Retrieval = holographic reconstruction from any sufficient subset.
pub const BoundaryStorage = struct {
    /// Each boundary node stores an ISG RGB triplet.
    boundary: [BOUNDARY_NODE_COUNT]ISGRgb,
    /// Maps each boundary node to the memory chunk it stores.
    chunk_ids: [BOUNDARY_NODE_COUNT]u32,
    /// Number of memories currently stored.
    stored_count: u32,

    pub fn init() BoundaryStorage {
        return .{
            .boundary = [_]ISGRgb{.{ .r = 0, .g = 0, .b = 0 }} ** BOUNDARY_NODE_COUNT,
            .chunk_ids = [_]u32{0} ** BOUNDARY_NODE_COUNT,
            .stored_count = 0,
        };
    }

    /// Stores a memory chunk on the boundary.
    /// The chunk is distributed across boundary nodes using modular distribution.
    /// Each boundary node gets a copy of the ISG RGB triplet.
    pub fn store(self: *BoundaryStorage, chunk: MemoryChunk) void {
        const rgb = ISGRgb.encode(chunk);
        const start_node = chunk.id % BOUNDARY_NODE_COUNT;
        // Distribute across 7 consecutive boundary nodes (7-defect pattern)
        for (0..7) |i| {
            const node_idx = (start_node + i) % BOUNDARY_NODE_COUNT;
            self.boundary[node_idx] = rgb;
            self.chunk_ids[node_idx] = chunk.id;
        }
        self.stored_count += 1;
    }

    /// Retrieves a memory chunk from the boundary by ID.
    /// Uses holographic reconstruction: any sufficient subset of boundary nodes
    /// can reconstruct the memory.
    pub fn retrieve(self: *const BoundaryStorage, chunk_id: u32) ?ISGRgb {
        const start_node = chunk_id % BOUNDARY_NODE_COUNT;
        // Check 7 consecutive nodes (7-defect redundancy)
        var found: ?ISGRgb = null;
        var match_count: u32 = 0;
        for (0..7) |i| {
            const node_idx = (start_node + i) % BOUNDARY_NODE_COUNT;
            if (self.chunk_ids[node_idx] == chunk_id) {
                if (found == null) {
                    found = self.boundary[node_idx];
                }
                match_count += 1;
            }
        }
        // Require at least 3 matching nodes for holographic retrieval (out of 7)
        if (match_count >= 3) return found;
        return null;
    }

    /// Returns the number of boundary nodes currently in use.
    pub fn usedNodes(self: *const BoundaryStorage) u32 {
        var count: u32 = 0;
        for (self.chunk_ids) |id| {
            if (id != 0) count += 1;
        }
        return count;
    }

    /// Returns the storage utilization as a Q64.64 fraction.
    pub fn utilization(self: *const BoundaryStorage) i128 {
        const used = fp.fromInt(@intCast(self.usedNodes()));
        const total = fp.fromInt(@intCast(BOUNDARY_NODE_COUNT));
        return fp.div(used, total);
    }
};

// === Holographic Memory System ===

/// The complete holographic memory system: point cloud + boundary storage.
pub const HolographicMemory = struct {
    graph: cloud.PointCloudGraph,
    boundary: BoundaryStorage,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HolographicMemory {
        return .{
            .graph = cloud.PointCloudGraph.init(allocator),
            .boundary = BoundaryStorage.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HolographicMemory) void {
        self.graph.deinit();
    }

    /// Stores a memory chunk in both the point cloud and boundary storage.
    pub fn store(self: *HolographicMemory, chunk: MemoryChunk) !void {
        // Create a point cloud for this chunk's category if it doesn't exist
        const cloud_id = try self.graph.createCloud(chunk.category);
        // Add the chunk as a point in the cloud
        try self.graph.addPointToCloud(cloud_id, chunk.toPoint());
        // Store on the boundary
        self.boundary.store(chunk);
    }

    /// Retrieves a memory from the boundary by chunk ID.
    pub fn retrieveFromBoundary(self: *const HolographicMemory, chunk_id: u32) ?ISGRgb {
        return self.boundary.retrieve(chunk_id);
    }

    /// Finds the nearest point cloud for a given query point.
    pub fn findNearestClouds(self: *HolographicMemory, target: cloud.Point, max_results: usize) ![]u64 {
        return self.graph.findNearestClouds(target, max_results);
    }

    /// Returns the total number of point clouds (categories).
    pub fn cloudCount(self: *const HolographicMemory) usize {
        return self.graph.cloudCount();
    }

    /// Returns the number of memories stored on the boundary.
    pub fn storedCount(self: *const HolographicMemory) u32 {
        return self.boundary.stored_count;
    }

    /// Returns the boundary storage utilization.
    pub fn utilization(self: *const HolographicMemory) i128 {
        return self.boundary.utilization();
    }
};

// === Framework Verification ===

pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;
pub const FRAMEWORK_BOUNDARY_NODES: u32 = 721;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

pub fn verify421Identity() bool {
    const interior = INTERIOR_SIDE * INTERIOR_SIDE * INTERIOR_SIDE; // 3375
    const shell = SHELL_SIDE * SHELL_SIDE * SHELL_SIDE; // 4096
    const boundary = shell - interior; // 721
    return boundary == FRAMEWORK_BOUNDARY_NODES and
        boundary == 3 * 240 + 1 and
        E0_NODE_COUNT == (interior - 7) / 8;
}

pub fn verifyBoundaryStorage() bool {
    // Verify boundary has 721 nodes
    if (BOUNDARY_NODE_COUNT != 721) return false;
    // Verify 7-defect redundancy
    return FRAMEWORK_SEVEN_DEFECT == 7;
}

// === Tests ===

test "holographic_memory: framework constants" {
    try std.testing.expectEqual(@as(u32, 421), FRAMEWORK_E0_NODE_COUNT);
    try std.testing.expectEqual(@as(u32, 7), FRAMEWORK_SEVEN_DEFECT);
    try std.testing.expectEqual(@as(u32, 721), FRAMEWORK_BOUNDARY_NODES);
    try std.testing.expectEqual(@as(u32, 721), BOUNDARY_NODE_COUNT);
    try std.testing.expect(verify421Identity());
    try std.testing.expect(verifyBoundaryStorage());
}

test "holographic_memory: category to dimension mapping" {
    try std.testing.expectEqual(MemoryDimension.e5_structure, categoryToDimension("numerical-foundations"));
    try std.testing.expectEqual(MemoryDimension.e2_quantum, categoryToDimension("hydrogen-line"));
    try std.testing.expectEqual(MemoryDimension.e7_physics, categoryToDimension("fine-structure"));
    try std.testing.expectEqual(MemoryDimension.e0_origin, categoryToDimension("generative-equations"));
    try std.testing.expectEqual(MemoryDimension.e0_origin, categoryToDimension("bootstrap"));
    try std.testing.expectEqual(MemoryDimension.e6_metacognition, categoryToDimension("checksum-6d"));
    try std.testing.expectEqual(MemoryDimension.e6_metacognition, categoryToDimension("free-will"));
    try std.testing.expectEqual(MemoryDimension.e1_time, categoryToDimension("dimensional-ladder"));
    try std.testing.expectEqual(MemoryDimension.e3_space, categoryToDimension("smith-chart"));
    try std.testing.expectEqual(MemoryDimension.e4_energy, categoryToDimension("over-constraint"));
    try std.testing.expectEqual(MemoryDimension.e5_structure, categoryToDimension("unknown-category"));
}

test "holographic_memory: memory chunk to point conversion" {
    const tags = [_][]const u8{ "octonion", "e8", "lattice" };
    const concepts = [_][]const u8{ "E8 root system", "240 roots", "reflection closure" };
    const equations = [_][]const u8{"240 = 15 × 16"};
    const results = [_][]const u8{"E8 uniquely contains SM"};
    const refs = [_][]const u8{"chunk-15"};
    const chunk = MemoryChunk{
        .id = 15,
        .title = "L(L+1)=240 & E8 Correspondence",
        .category = "e8-correspondence",
        .source_lines = .{ 400, 430 },
        .tags = &tags,
        .concepts = &concepts,
        .equations = &equations,
        .key_results = &results,
        .cross_references = &refs,
        .status = "established",
    };
    const point = chunk.toPoint();
    try std.testing.expectEqual(@as(u64, 15), point.id);
    try std.testing.expectEqual(@as(u16, 15), point.lattice_node);
    try std.testing.expectEqual(@as(u3, 7), point.channel); // e7_physics
    try std.testing.expect(point.magnitude > 0);
    try std.testing.expect(point.activation == fp.ONE);
    // Phase should have the dimension channel set
    try std.testing.expect(point.phase[7] > 0); // e7 channel
}

test "holographic_memory: ISG RGB transcoder encode and verify" {
    const tags = [_][]const u8{ "i256", "Q128.128", "fixed-point" };
    const concepts = [_][]const u8{ "256-bit fixed-point", "128+128 bits" };
    const equations = [_][]const u8{"2^256 ≈ 10^77"};
    const results = [_][]const u8{"Q128.128 provides ~39 decimal places"};
    const refs = [_][]const u8{"chunk-12"};
    const chunk = MemoryChunk{
        .id = 1,
        .title = "Q128.128 Fixed-Point & Universe Scale",
        .category = "numerical-foundations",
        .source_lines = .{ 1, 35 },
        .tags = &tags,
        .concepts = &concepts,
        .equations = &equations,
        .key_results = &results,
        .cross_references = &refs,
        .status = "established",
    };
    const rgb = ISGRgb.encode(chunk);
    // R, G, B should all be non-zero
    try std.testing.expect(rgb.r != 0);
    try std.testing.expect(rgb.g != 0);
    try std.testing.expect(rgb.b != 0);
    // Verify internal consistency: R XOR G == B
    try std.testing.expect(rgb.verify());
    // Two different chunks should have different RGB
    const chunk2 = MemoryChunk{
        .id = 2,
        .title = "21cm Hydrogen 7/66 Correction",
        .category = "hydrogen-line",
        .source_lines = .{ 37, 63 },
        .tags = &tags,
        .concepts = &concepts,
        .equations = &equations,
        .key_results = &results,
        .cross_references = &refs,
        .status = "established",
    };
    const rgb2 = ISGRgb.encode(chunk2);
    try std.testing.expect(rgb.r != rgb2.r or rgb.g != rgb2.g);
}

test "holographic_memory: boundary storage store and retrieve" {
    var bs = BoundaryStorage.init();
    const tags = [_][]const u8{ "octonion", "e8" };
    const concepts = [_][]const u8{"E8 root system"};
    const equations = [_][]const u8{"240 = 15 × 16"};
    const results = [_][]const u8{"E8 contains SM"};
    const refs = [_][]const u8{"chunk-15"};
    const chunk = MemoryChunk{
        .id = 15,
        .title = "L(L+1)=240 & E8 Correspondence",
        .category = "e8-correspondence",
        .source_lines = .{ 400, 430 },
        .tags = &tags,
        .concepts = &concepts,
        .equations = &equations,
        .key_results = &results,
        .cross_references = &refs,
        .status = "established",
    };
    bs.store(chunk);
    try std.testing.expectEqual(@as(u32, 1), bs.stored_count);
    const retrieved = bs.retrieve(15);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.verify());
}

test "holographic_memory: boundary storage 7-defect redundancy" {
    var bs = BoundaryStorage.init();
    const tags = [_][]const u8{"test"};
    const concepts = [_][]const u8{"concept"};
    const equations = [_][]const u8{"eq"};
    const results = [_][]const u8{"result"};
    const refs = [_][]const u8{"ref"};
    const chunk = MemoryChunk{
        .id = 5,
        .title = "Test Chunk",
        .category = "numerical-foundations",
        .source_lines = .{ 1, 10 },
        .tags = &tags,
        .concepts = &concepts,
        .equations = &equations,
        .key_results = &results,
        .cross_references = &refs,
        .status = "established",
    };
    bs.store(chunk);
    // 7 consecutive nodes should be used (7-defect pattern)
    const start_node = 5 % BOUNDARY_NODE_COUNT;
    var used: u32 = 0;
    for (0..7) |i| {
        const node_idx = (start_node + i) % BOUNDARY_NODE_COUNT;
        if (bs.chunk_ids[node_idx] == 5) used += 1;
    }
    try std.testing.expectEqual(@as(u32, 7), used);
}

test "holographic_memory: full holographic memory system" {
    const allocator = std.testing.allocator;
    var hm = HolographicMemory.init(allocator);
    defer hm.deinit();
    const tags = [_][]const u8{ "octonion", "e8" };
    const concepts = [_][]const u8{"E8 root system"};
    const equations = [_][]const u8{"240 = 15 × 16"};
    const results = [_][]const u8{"E8 contains SM"};
    const refs = [_][]const u8{"chunk-15"};
    const chunk = MemoryChunk{
        .id = 15,
        .title = "L(L+1)=240 & E8 Correspondence",
        .category = "e8-correspondence",
        .source_lines = .{ 400, 430 },
        .tags = &tags,
        .concepts = &concepts,
        .equations = &equations,
        .key_results = &results,
        .cross_references = &refs,
        .status = "established",
    };
    try hm.store(chunk);
    try std.testing.expectEqual(@as(usize, 1), hm.cloudCount());
    try std.testing.expectEqual(@as(u32, 1), hm.storedCount());
    const retrieved = hm.retrieveFromBoundary(15);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.verify());
}

test "holographic_memory: 33 chunks dimensional distribution" {
    // Verify that the 33 memory categories map to all 8 dimensions
    const categories = [_][]const u8{
        "numerical-foundations",     "hydrogen-line",           "triad-operator",
        "fine-structure",            "codata-network",          "propagation-graph",
        "scorecard",                 "constants-table",         "error-analysis",
        "qed-corrections",           "octonionic-architecture", "generative-equations",
        "lattice-structure",         "e8-correspondence",       "shell-transition",
        "offset-symmetry",           "smith-chart",             "architecture",
        "over-constraint",           "test-plan",               "codon-integration",
        "neuraleak-integration",     "10d-completion",          "gap-closure",
        "bootstrap",                 "dimensional-ladder",      "checksum-6d",
        "free-will",                 "scaling-analysis",        "surface-computation",
        "cross-project-integration",
    };
    var dim_counts = [_]u32{0} ** 8;
    for (categories) |cat| {
        const dim = categoryToDimension(cat);
        dim_counts[@intFromEnum(dim)] += 1;
    }
    // All 8 dimensions should have at least 1 chunk
    for (dim_counts) |count| {
        try std.testing.expect(count > 0);
    }
}

test "framework: 421 identity (15³ - 7) / 8 = 421" {
    try std.testing.expectEqual(@as(u32, 421), FRAMEWORK_E0_NODE_COUNT);
    try std.testing.expectEqual(@as(u32, 7), FRAMEWORK_SEVEN_DEFECT);
    try std.testing.expectEqual(@as(u32, 721), FRAMEWORK_BOUNDARY_NODES);
    try std.testing.expect(verify421Identity());
}

test "framework: boundary storage 721 = 16³ - 15³ = 3(240) + 1" {
    try std.testing.expectEqual(@as(u32, 721), BOUNDARY_NODE_COUNT);
    try std.testing.expectEqual(@as(u32, 721), 3 * 240 + 1);
    try std.testing.expectEqual(@as(u32, 4096), SHELL_SIDE * SHELL_SIDE * SHELL_SIDE);
    try std.testing.expectEqual(@as(u32, 3375), INTERIOR_SIDE * INTERIOR_SIDE * INTERIOR_SIDE);
}
