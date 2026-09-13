//! cognitive_cloud.zig — Cognitive Point Cloud Knowledge Graph (CPC-KG)
//!
//! Connects metacognitive state back into the lattice via a point cloud
//! knowledge graph where every concept, evaluation, mood, memory, and lattice
//! state becomes a Point with phase coordinates in 7-channel space.
//!
//! Based on CPCA (point→cloud→logic chain) + MetaKGRAG (Perceive-Evaluate-Adjust)
//! + GUT (rational rotation matrices with det=1).
//!
//! All arithmetic in i128 Q64.64 fixed-point. No floating-point.

const std = @import("std");
const fp = @import("fixed_point");

pub const CHANNEL_COUNT: usize = 7;
pub const E0_NODE_COUNT: usize = 421;

// === Polyglot Payload ===

pub const PayloadFormat = enum {
    text,
    audio_codes,
    lattice_activations,
    token_ids,
    file_ref,
    holographic,
    kg_triplet,
    evaluation,
    episode,
    phase_signature,
};

pub const KGTriplet = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
};

pub const EvalPayload = struct {
    relevance: i128,
    coherence: i128,
    specificity: i128,
    naturalness: i128,
    self_awareness: i128,
    direct_experience: i128,
    metacognition: i128,
    situational_awareness: i128,
    overall: i128,
};

pub const EpisodePayload = struct {
    summary: []const u8,
    topic: []const u8,
    success_score: i128,
    key_insight: []const u8,
};

pub const PolyglotPayload = union(PayloadFormat) {
    text: []const u8,
    audio_codes: [7]i128,
    lattice_activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128,
    token_ids: []const u32,
    file_ref: []const u8,
    holographic: [2]i128,
    kg_triplet: KGTriplet,
    evaluation: EvalPayload,
    episode: EpisodePayload,
    phase_signature: [7]i128,
};

// === Point ===

pub const Point = struct {
    phase: [CHANNEL_COUNT]i128,
    magnitude: i128,
    upsilon: i128,
    lattice_node: u16,
    channel: u3,
    payload: ?PolyglotPayload = null,
    activation: i128,
    id: u64,

    pub fn init(id: u64, node: u16, ch: u3) Point {
        return .{
            .phase = [_]i128{0} ** CHANNEL_COUNT,
            .magnitude = fp.ZERO,
            .upsilon = fp.ZERO,
            .lattice_node = node,
            .channel = ch,
            .activation = fp.ZERO,
            .id = id,
        };
    }

    pub fn setPhase(self: *Point, phases: [CHANNEL_COUNT]i128) void {
        self.phase = phases;
    }

    pub fn setPayload(self: *Point, p: PolyglotPayload) void {
        self.payload = p;
    }

    /// Angular distance (phase separation) between two points.
    pub fn phaseDistance(a: Point, b: Point) i128 {
        var dist: i128 = 0;
        for (0..CHANNEL_COUNT) |ch| {
            const diff = if (a.phase[ch] > b.phase[ch])
                a.phase[ch] - b.phase[ch]
            else
                b.phase[ch] - a.phase[ch];
            dist += diff;
        }
        return dist;
    }

    /// Apply GUT rotation to a channel pair.
    pub fn applyGutRotation(self: *Point, m: fp.GutMatrix, ch_a: usize, ch_b: usize) void {
        if (ch_a >= CHANNEL_COUNT or ch_b >= CHANNEL_COUNT or ch_a == ch_b) return;
        const result = fp.gutApply(m, self.phase[ch_a], self.phase[ch_b]);
        self.phase[ch_a] = result.re;
        self.phase[ch_b] = result.im;
        self.upsilon += fp.ONE;
    }
};

// === LogicChain ===

pub const ChainType = enum {
    causal,
    associative,
    temporal,
    spatial,
    semantic,
    evaluative,
    corrective,
};

pub const LogicChain = struct {
    source_id: u64,
    target_id: u64,
    rotation: fp.GutMatrix,
    step_n: i128,
    chain_type: ChainType,
    weight: i128,

    pub fn init(source: u64, target: u64, n: i128, ct: ChainType) LogicChain {
        return .{
            .source_id = source,
            .target_id = target,
            .rotation = fp.gutRotation(n),
            .step_n = n,
            .chain_type = ct,
            .weight = n,
        };
    }

    pub fn adjustStep(self: *LogicChain, new_n: i128) void {
        self.step_n = new_n;
        self.rotation = fp.gutRotation(new_n);
        self.weight = new_n;
    }

    pub fn compose(self: LogicChain, other: LogicChain) fp.GutMatrix {
        return fp.gutMatMul(self.rotation, other.rotation);
    }
};

// === PointCloud ===

pub const PointCloud = struct {
    points: std.ArrayList(Point),
    centroid_phase: [CHANNEL_COUNT]i128,
    concept_label: []const u8,
    logic_chains: std.ArrayList(LogicChain),
    total_magnitude: i128,
    id: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, label: []const u8) PointCloud {
        return .{
            .points = std.ArrayList(Point).init(allocator),
            .centroid_phase = [_]i128{0} ** CHANNEL_COUNT,
            .concept_label = label,
            .logic_chains = std.ArrayList(LogicChain).init(allocator),
            .total_magnitude = fp.ZERO,
            .id = id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PointCloud) void {
        self.points.deinit();
        self.logic_chains.deinit();
    }

    pub fn addPoint(self: *PointCloud, p: Point) !void {
        try self.points.append(p);
        self.total_magnitude += p.magnitude;
        self.recomputeCentroid();
    }

    pub fn addChain(self: *PointCloud, chain: LogicChain) !void {
        try self.logic_chains.append(chain);
    }

    fn recomputeCentroid(self: *PointCloud) void {
        if (self.points.items.len == 0) {
            self.centroid_phase = [_]i128{0} ** CHANNEL_COUNT;
            return;
        }
        for (0..CHANNEL_COUNT) |ch| {
            var sum: i128 = 0;
            for (self.points.items) |p| sum += p.phase[ch];
            self.centroid_phase[ch] = fp.div(sum, fp.fromInt(@intCast(self.points.items.len)));
        }
    }

    pub fn nearestPoint(self: *const PointCloud, target: Point) ?*const Point {
        if (self.points.items.len == 0) return null;
        var best: usize = 0;
        var best_dist = Point.phaseDistance(self.points.items[0], target);
        for (1..self.points.items.len) |i| {
            const d = Point.phaseDistance(self.points.items[i], target);
            if (d < best_dist) {
                best_dist = d;
                best = i;
            }
        }
        return &self.points.items[best];
    }

    pub fn pointCount(self: *const PointCloud) usize {
        return self.points.items.len;
    }
};

// === PointCloudGraph ===

pub const PointCloudGraph = struct {
    clouds: std.AutoHashMap(u64, *PointCloud),
    adjacency: std.AutoHashMap(u64, std.ArrayList(LogicChain)),
    spatial_index: std.AutoHashMap(u16, std.ArrayList(u64)),
    next_id: u64,
    upsilon_counter: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PointCloudGraph {
        return .{
            .clouds = std.AutoHashMap(u64, *PointCloud).init(allocator),
            .adjacency = std.AutoHashMap(u64, std.ArrayList(LogicChain)).init(allocator),
            .spatial_index = std.AutoHashMap(u16, std.ArrayList(u64)).init(allocator),
            .next_id = 1,
            .upsilon_counter = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PointCloudGraph) void {
        var cloud_iter = self.clouds.iterator();
        while (cloud_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.clouds.deinit();
        var adj_iter = self.adjacency.iterator();
        while (adj_iter.next()) |entry| entry.value_ptr.deinit();
        self.adjacency.deinit();
        var si_iter = self.spatial_index.iterator();
        while (si_iter.next()) |entry| entry.value_ptr.deinit();
        self.spatial_index.deinit();
    }

    pub fn createCloud(self: *PointCloudGraph, label: []const u8) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        const cloud = try self.allocator.create(PointCloud);
        cloud.* = PointCloud.init(self.allocator, id, label);
        try self.clouds.put(id, cloud);
        return id;
    }

    pub fn getCloud(self: *PointCloudGraph, id: u64) ?*PointCloud {
        return self.clouds.get(id);
    }

    pub fn addPointToCloud(self: *PointCloudGraph, cloud_id: u64, p: Point) !void {
        const cloud = self.getCloud(cloud_id) orelse return error.CloudNotFound;
        try cloud.addPoint(p);
        const entry = try self.spatial_index.getOrPut(p.lattice_node);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        }
        try entry.value_ptr.append(p.id);
    }

    pub fn addChain(self: *PointCloudGraph, source_cloud: u64, chain: LogicChain) !void {
        const entry = try self.adjacency.getOrPut(source_cloud);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(LogicChain).init(self.allocator);
        }
        try entry.value_ptr.append(chain);
    }

    /// Find clouds whose centroid is nearest to a target point's phase.
    pub fn findNearestClouds(self: *PointCloudGraph, target: Point, max_results: usize) ![]u64 {
        var results = std.ArrayList(u64).init(self.allocator);
        defer results.deinit();
        var best_dist: i128 = std.math.maxInt(i128);
        var cloud_iter = self.clouds.iterator();
        while (cloud_iter.next()) |entry| {
            const cloud = entry.value_ptr.*;
            if (cloud.pointCount() == 0) continue;
            var dist: i128 = 0;
            for (0..CHANNEL_COUNT) |ch| {
                const diff = if (cloud.centroid_phase[ch] > target.phase[ch])
                    cloud.centroid_phase[ch] - target.phase[ch]
                else
                    target.phase[ch] - cloud.centroid_phase[ch];
                dist += diff;
            }
            if (dist <= best_dist) {
                best_dist = dist;
                try results.append(cloud.id);
                if (results.items.len > max_results) {
                    _ = results.orderedRemove(0);
                }
            }
        }
        return results.toOwnedSlice();
    }

    /// Find all points anchored to a specific lattice node.
    pub fn pointsAtNode(self: *PointCloudGraph, node: u16) ?[]const u64 {
        if (self.spatial_index.get(node)) |list| return list.items;
        return null;
    }

    /// Increment the GUT flow parameter and check resonance.
    pub fn stepUpsilon(self: *PointCloudGraph) void {
        self.upsilon_counter += 1;
    }

    pub fn isHarmonic(self: *const PointCloudGraph) bool {
        return fp.gutIsHarmonic(self.upsilon_counter);
    }

    pub fn isSuperResonant(self: *const PointCloudGraph) bool {
        return fp.gutIsSuperResonant(self.upsilon_counter);
    }

    pub fn cloudCount(self: *const PointCloudGraph) usize {
        return self.clouds.count();
    }
};

// === Lattice Bridge ===

pub fn injectIntoLattice(cloud: *const PointCloud, activations: *[E0_NODE_COUNT][CHANNEL_COUNT]i128) void {
    for (cloud.points.items) |p| {
        if (p.lattice_node >= E0_NODE_COUNT) continue;
        const node = p.lattice_node;
        const m = fp.gutRotation(p.activation);
        const r01 = fp.gutApply(m, activations[node][0], activations[node][1]);
        activations[node][0] = r01.re;
        activations[node][1] = r01.im;
        const r23 = fp.gutApply(m, activations[node][2], activations[node][3]);
        activations[node][2] = r23.re;
        activations[node][3] = r23.im;
        const r45 = fp.gutApply(m, activations[node][4], activations[node][5]);
        activations[node][4] = r45.re;
        activations[node][5] = r45.im;
        const r06 = fp.gutApply(m, activations[node][0], activations[node][6]);
        activations[node][0] = r06.re;
        activations[node][6] = r06.im;
    }
}

pub fn readFromLattice(activations: *const [E0_NODE_COUNT][CHANNEL_COUNT]i128, node: u16, id: u64) Point {
    var p = Point.init(id, node, 0);
    if (node >= E0_NODE_COUNT) return p;
    var total: i128 = 0;
    for (0..CHANNEL_COUNT) |ch| {
        p.phase[ch] = activations[node][ch];
        total += fp.absVal(activations[node][ch]);
    }
    p.magnitude = fp.div(total, fp.fromInt(@intCast(CHANNEL_COUNT)));
    p.activation = p.magnitude;
    return p;
}

pub fn phaseCoherence(a: *const PointCloud, b: *const PointCloud) i128 {
    if (a.pointCount() == 0 or b.pointCount() == 0) return fp.ZERO;
    var total_dist: i128 = 0;
    for (0..CHANNEL_COUNT) |ch| {
        const diff = if (a.centroid_phase[ch] > b.centroid_phase[ch])
            a.centroid_phase[ch] - b.centroid_phase[ch]
        else
            b.centroid_phase[ch] - a.centroid_phase[ch];
        total_dist += diff;
    }
    return fp.div(fp.ONE, fp.add(fp.ONE, total_dist));
}

// === Tests ===

test "cognitive_cloud: Point init and phase distance" {
    var p1 = Point.init(1, 10, 3);
    var p2 = Point.init(2, 10, 3);
    p1.setPhase([_]i128{ fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4), fp.fromInt(5), fp.fromInt(6), fp.fromInt(7) });
    p2.setPhase([_]i128{ fp.fromInt(1), fp.fromInt(2), fp.fromInt(3), fp.fromInt(4), fp.fromInt(5), fp.fromInt(6), fp.fromInt(7) });
    try std.testing.expectEqual(@as(i128, 0), Point.phaseDistance(p1, p2));
    p2.setPhase([_]i128{ fp.fromInt(2), fp.fromInt(3), fp.fromInt(4), fp.fromInt(5), fp.fromInt(6), fp.fromInt(7), fp.fromInt(8) });
    try std.testing.expect(Point.phaseDistance(p1, p2) > 0);
}

test "cognitive_cloud: Point GUT rotation identity" {
    var p = Point.init(1, 0, 0);
    p.setPhase([_]i128{ fp.fromInt(5), fp.fromInt(3), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0) });
    const m = fp.gutRotation(fp.fromInt(0));
    p.applyGutRotation(m, 0, 1);
    try std.testing.expectEqual(fp.fromInt(5), p.phase[0]);
    try std.testing.expectEqual(fp.fromInt(3), p.phase[1]);
}

test "cognitive_cloud: LogicChain det=1" {
    const chain = LogicChain.init(1, 2, fp.fromInt(3), .causal);
    const det = fp.sub(fp.mul(chain.rotation.a, chain.rotation.d), fp.mul(chain.rotation.b, chain.rotation.c));
    const drift = fp.absVal(fp.sub(det, fp.ONE));
    try std.testing.expect(drift < fp.div(fp.ONE, fp.fromInt(100)));
}

test "cognitive_cloud: LogicChain compose preserves det=1" {
    const c1 = LogicChain.init(1, 2, fp.fromInt(2), .causal);
    const c2 = LogicChain.init(2, 3, fp.fromInt(3), .causal);
    const m = c1.compose(c2);
    const det = fp.sub(fp.mul(m.a, m.d), fp.mul(m.b, m.c));
    const drift = fp.absVal(fp.sub(det, fp.ONE));
    try std.testing.expect(drift < fp.fromInt(1));
}

test "cognitive_cloud: PointCloud add and centroid" {
    const allocator = std.testing.allocator;
    var cloud = PointCloud.init(allocator, 1, "test");
    defer cloud.deinit();
    var p1 = Point.init(1, 0, 0);
    p1.setPhase([_]i128{ fp.fromInt(2), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0) });
    p1.magnitude = fp.fromInt(10);
    try cloud.addPoint(p1);
    var p2 = Point.init(2, 1, 1);
    p2.setPhase([_]i128{ fp.fromInt(4), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0), fp.fromInt(0) });
    p2.magnitude = fp.fromInt(20);
    try cloud.addPoint(p2);
    try std.testing.expectEqual(@as(usize, 2), cloud.pointCount());
    try std.testing.expectEqual(fp.fromInt(3), cloud.centroid_phase[0]);
}

test "cognitive_cloud: PointCloudGraph create and add" {
    const allocator = std.testing.allocator;
    var graph = PointCloudGraph.init(allocator);
    defer graph.deinit();
    const id1 = try graph.createCloud("concept_a");
    _ = try graph.createCloud("concept_b");
    try std.testing.expectEqual(@as(usize, 2), graph.cloudCount());
    var p = Point.init(1, 5, 2);
    p.setPhase([_]i128{ fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1) });
    try graph.addPointToCloud(id1, p);
    const cloud = graph.getCloud(id1).?;
    try std.testing.expectEqual(@as(usize, 1), cloud.pointCount());
    const ids = graph.pointsAtNode(5).?;
    try std.testing.expectEqual(@as(usize, 1), ids.len);
}

test "cognitive_cloud: GUT resonance tracking" {
    const allocator = std.testing.allocator;
    var graph = PointCloudGraph.init(allocator);
    defer graph.deinit();
    for (0..6) |_| graph.stepUpsilon();
    try std.testing.expect(!graph.isHarmonic());
    graph.stepUpsilon();
    try std.testing.expect(graph.isHarmonic());
    try std.testing.expect(!graph.isSuperResonant());
}

test "cognitive_cloud: injectIntoLattice identity rotation" {
    const allocator = std.testing.allocator;
    var cloud = PointCloud.init(allocator, 1, "test");
    defer cloud.deinit();
    var p = Point.init(1, 0, 0);
    p.activation = fp.fromInt(0);
    try cloud.addPoint(p);
    var activations = [_][CHANNEL_COUNT]i128{[_]i128{ fp.fromInt(5), fp.fromInt(3), fp.fromInt(7), fp.fromInt(2), fp.fromInt(9), fp.fromInt(1), fp.fromInt(4) }} ** E0_NODE_COUNT;
    injectIntoLattice(&cloud, &activations);
    try std.testing.expectEqual(fp.fromInt(5), activations[0][0]);
    try std.testing.expectEqual(fp.fromInt(3), activations[0][1]);
}

test "cognitive_cloud: readFromLattice extracts phase" {
    var activations = [_][CHANNEL_COUNT]i128{[_]i128{ fp.fromInt(5), fp.fromInt(3), fp.fromInt(7), fp.fromInt(2), fp.fromInt(9), fp.fromInt(1), fp.fromInt(4) }} ** E0_NODE_COUNT;
    const p = readFromLattice(&activations, 0, 42);
    try std.testing.expectEqual(@as(u64, 42), p.id);
    try std.testing.expectEqual(fp.fromInt(5), p.phase[0]);
    try std.testing.expectEqual(fp.fromInt(3), p.phase[1]);
}

test "cognitive_cloud: phaseCoherence identical clouds" {
    const allocator = std.testing.allocator;
    var cloud_a = PointCloud.init(allocator, 1, "a");
    defer cloud_a.deinit();
    var cloud_b = PointCloud.init(allocator, 2, "b");
    defer cloud_b.deinit();
    var p = Point.init(1, 0, 0);
    p.setPhase([_]i128{ fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1), fp.fromInt(1) });
    p.magnitude = fp.fromInt(10);
    try cloud_a.addPoint(p);
    try cloud_b.addPoint(p);
    const coh = phaseCoherence(&cloud_a, &cloud_b);
    try std.testing.expectEqual(fp.ONE, coh);
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
