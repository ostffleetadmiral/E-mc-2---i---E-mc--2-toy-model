//! knowledge_graph.zig — Discrete Lattice-Grounded Knowledge Graph Engine for Qstar
//!
//! Maps semantic knowledge triplets (Subject, Predicate, Object) directly onto
//! the E0 discrete lattice nodes (421 * 8^s) and 7 octonion reasoning channels (e0..e6).
//! Provides fast multi-hop traversal, entity neighborhood retrieval, relation extraction,
//! and binary persistence for continual background learning.

const std = @import("std");
const builtin = @import("builtin");
const fp = @import("fixed_point");
const lattice = @import("lattice");

const is_wasm = builtin.os.tag == .freestanding;

pub const Triplet = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    weight: i128, // Q64.64 fixed-point confidence/weight
    channel: u8, // 0..7 octonion channel
    source_node: u32,
    target_node: u32,
};

pub const Entity = struct {
    id: u32,
    name: []const u8,
    node_index: u32,
    channel: u8,
    out_edges: std.ArrayList(usize), // Indices into triplets array
    in_edges: std.ArrayList(usize), // Indices into triplets array
};

pub const KnowledgeGraph = struct {
    allocator: std.mem.Allocator,
    level: u8,
    entities: std.StringHashMap(u32), // name -> entity_id
    entity_nodes: std.ArrayList(Entity),
    triplets: std.ArrayList(Triplet),
    // Fast hash-index for subject -> triplet indices
    subject_index: std.StringHashMap(std.ArrayList(usize)),
    // Fast hash-index for object -> triplet indices
    object_index: std.StringHashMap(std.ArrayList(usize)),
    // Fast hash-index for predicate -> triplet indices
    predicate_index: std.StringHashMap(std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator, level: u8) KnowledgeGraph {
        return KnowledgeGraph{
            .allocator = allocator,
            .level = level,
            .entities = std.StringHashMap(u32).init(allocator),
            .entity_nodes = std.ArrayList(Entity).init(allocator),
            .triplets = std.ArrayList(Triplet).init(allocator),
            .subject_index = std.StringHashMap(std.ArrayList(usize)).init(allocator),
            .object_index = std.StringHashMap(std.ArrayList(usize)).init(allocator),
            .predicate_index = std.StringHashMap(std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *KnowledgeGraph) void {
        // Free owned entity strings and edge lists
        for (self.entity_nodes.items) |*node| {
            self.allocator.free(node.name);
            node.out_edges.deinit();
            node.in_edges.deinit();
        }
        self.entity_nodes.deinit();
        self.entities.deinit();

        // Free owned triplet strings
        for (self.triplets.items) |t| {
            self.allocator.free(t.subject);
            self.allocator.free(t.predicate);
            self.allocator.free(t.object);
        }
        self.triplets.deinit();

        // Free subject index
        var s_it = self.subject_index.iterator();
        while (s_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.subject_index.deinit();

        // Free object index
        var o_it = self.object_index.iterator();
        while (o_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.object_index.deinit();

        // Free predicate index
        var p_it = self.predicate_index.iterator();
        while (p_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.predicate_index.deinit();
    }

    pub inline fn setLevel(self: *KnowledgeGraph, level: u8) void {
        self.level = level;
    }

    /// Computes the deterministic E0 lattice node for an entity name.
    pub inline fn entityToNode(self: *const KnowledgeGraph, name: []const u8) u32 {
        var h: u64 = 5381;
        for (name) |b| {
            h = ((h << 5) +% h) +% b;
        }
        const total_nodes = lattice.scaledNodeCount(self.level);
        return @intCast(h % total_nodes);
    }

    /// Computes the octonion channel (0..6) for an entity/predicate.
    pub inline fn computeChannel(name: []const u8) u8 {
        var h: u32 = 0;
        for (name) |b| {
            h = (h *% 31) +% b;
        }
        return @intCast(h % 7);
    }

    /// Retrieves or creates an entity in the graph.
    pub fn getOrCreateEntity(self: *KnowledgeGraph, name: []const u8) !u32 {
        const trimmed = std.mem.trim(u8, name, " \t\r\n.,;:'\"");
        if (self.entities.get(trimmed)) |id| {
            return id;
        }

        const id: u32 = @intCast(self.entity_nodes.items.len);
        const owned_name = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(owned_name);

        const node_idx = self.entityToNode(trimmed);
        const channel = computeChannel(trimmed);

        const entity = Entity{
            .id = id,
            .name = owned_name,
            .node_index = node_idx,
            .channel = channel,
            .out_edges = std.ArrayList(usize).init(self.allocator),
            .in_edges = std.ArrayList(usize).init(self.allocator),
        };

        try self.entity_nodes.append(entity);
        try self.entities.put(self.entity_nodes.items[id].name, id);
        return id;
    }

    /// Adds a knowledge triplet to the graph with deduplication and edge indexing.
    pub fn addTriplet(
        self: *KnowledgeGraph,
        subject: []const u8,
        predicate: []const u8,
        object: []const u8,
        weight: i128,
        channel: ?u8,
    ) !usize {
        const sub_trimmed = std.mem.trim(u8, subject, " \t\r\n.,;:'\"");
        const pred_trimmed = std.mem.trim(u8, predicate, " \t\r\n.,;:'\"");
        const obj_trimmed = std.mem.trim(u8, object, " \t\r\n.,;:'\"");

        if (sub_trimmed.len == 0 or pred_trimmed.len == 0 or obj_trimmed.len == 0) {
            return 0;
        }

        // Check if triplet already exists
        if (self.subject_index.get(sub_trimmed)) |sub_list| {
            for (sub_list.items) |t_idx| {
                const existing = self.triplets.items[t_idx];
                if (std.mem.eql(u8, existing.predicate, pred_trimmed) and
                    std.mem.eql(u8, existing.object, obj_trimmed))
                {
                    // Update weight if higher confidence
                    if (weight > existing.weight) {
                        self.triplets.items[t_idx].weight = weight;
                    }
                    return t_idx;
                }
            }
        }

        const sub_id = try self.getOrCreateEntity(sub_trimmed);
        const obj_id = try self.getOrCreateEntity(obj_trimmed);

        const eff_channel = channel orelse computeChannel(pred_trimmed);
        const triplet_idx = self.triplets.items.len;

        const owned_sub = try self.allocator.dupe(u8, sub_trimmed);
        errdefer self.allocator.free(owned_sub);
        const owned_pred = try self.allocator.dupe(u8, pred_trimmed);
        errdefer self.allocator.free(owned_pred);
        const owned_obj = try self.allocator.dupe(u8, obj_trimmed);
        errdefer self.allocator.free(owned_obj);

        const triplet = Triplet{
            .subject = owned_sub,
            .predicate = owned_pred,
            .object = owned_obj,
            .weight = weight,
            .channel = eff_channel,
            .source_node = self.entity_nodes.items[sub_id].node_index,
            .target_node = self.entity_nodes.items[obj_id].node_index,
        };

        try self.triplets.append(triplet);

        // Update entity adjacency
        try self.entity_nodes.items[sub_id].out_edges.append(triplet_idx);
        try self.entity_nodes.items[obj_id].in_edges.append(triplet_idx);

        // Update subject index
        if (self.subject_index.getPtr(sub_trimmed)) |list| {
            try list.append(triplet_idx);
        } else {
            const key = try self.allocator.dupe(u8, sub_trimmed);
            var list = std.ArrayList(usize).init(self.allocator);
            try list.append(triplet_idx);
            try self.subject_index.put(key, list);
        }

        // Update object index
        if (self.object_index.getPtr(obj_trimmed)) |list| {
            try list.append(triplet_idx);
        } else {
            const key = try self.allocator.dupe(u8, obj_trimmed);
            var list = std.ArrayList(usize).init(self.allocator);
            try list.append(triplet_idx);
            try self.object_index.put(key, list);
        }

        // Update predicate index
        if (self.predicate_index.getPtr(pred_trimmed)) |list| {
            try list.append(triplet_idx);
        } else {
            const key = try self.allocator.dupe(u8, pred_trimmed);
            var list = std.ArrayList(usize).init(self.allocator);
            try list.append(triplet_idx);
            try self.predicate_index.put(key, list);
        }

        return triplet_idx;
    }

    /// Queries all outgoing and incoming triplets for an entity name.
    pub fn queryNeighbors(self: *const KnowledgeGraph, entity_name: []const u8, max_triplets: usize, allocator: std.mem.Allocator) !std.ArrayList(Triplet) {
        var results = std.ArrayList(Triplet).init(allocator);
        errdefer results.deinit();

        const trimmed = std.mem.trim(u8, entity_name, " \t\r\n.,;:'\"");
        if (self.entities.get(trimmed)) |id| {
            const entity = self.entity_nodes.items[id];
            for (entity.out_edges.items) |t_idx| {
                if (results.items.len >= max_triplets) break;
                try results.append(self.triplets.items[t_idx]);
            }
            for (entity.in_edges.items) |t_idx| {
                if (results.items.len >= max_triplets) break;
                try results.append(self.triplets.items[t_idx]);
            }
        }
        return results;
    }

    /// Finds the shortest semantic path of triplets between two entities using BFS.
    pub fn findPath(self: *const KnowledgeGraph, start_name: []const u8, target_name: []const u8, allocator: std.mem.Allocator) !?std.ArrayList(Triplet) {
        const start_trimmed = std.mem.trim(u8, start_name, " \t\r\n.,;:'\"");
        const target_trimmed = std.mem.trim(u8, target_name, " \t\r\n.,;:'\"");

        const start_id = self.entities.get(start_trimmed) orelse return null;
        const target_id = self.entities.get(target_trimmed) orelse return null;

        if (start_id == target_id) {
            return std.ArrayList(Triplet).init(allocator);
        }

        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();
        try visited.put(start_id, {});

        // Queue holds entity IDs
        var queue = std.ArrayList(u32).init(allocator);
        defer queue.deinit();
        try queue.append(start_id);

        // Predecessor map: entity_id -> triplet_idx
        var pred_triplet = std.AutoHashMap(u32, usize).init(allocator);
        defer pred_triplet.deinit();
        var pred_entity = std.AutoHashMap(u32, u32).init(allocator);
        defer pred_entity.deinit();

        var found = false;
        var head: usize = 0;

        while (head < queue.items.len) : (head += 1) {
            const curr = queue.items[head];
            if (curr == target_id) {
                found = true;
                break;
            }

            const curr_node = self.entity_nodes.items[curr];
            for (curr_node.out_edges.items) |t_idx| {
                const t = self.triplets.items[t_idx];
                if (self.entities.get(t.object)) |next_id| {
                    if (!visited.contains(next_id)) {
                        try visited.put(next_id, {});
                        try pred_triplet.put(next_id, t_idx);
                        try pred_entity.put(next_id, curr);
                        try queue.append(next_id);
                    }
                }
            }
        }

        if (!found) return null;

        // Reconstruct path
        var path = std.ArrayList(Triplet).init(allocator);
        errdefer path.deinit();

        var curr = target_id;
        while (curr != start_id) {
            const t_idx = pred_triplet.get(curr).?;
            try path.append(self.triplets.items[t_idx]);
            curr = pred_entity.get(curr).?;
        }

        // Reverse to get start -> target order
        var i: usize = 0;
        var j: usize = path.items.len - 1;
        while (i < j) {
            const tmp = path.items[i];
            path.items[i] = path.items[j];
            path.items[j] = tmp;
            i += 1;
            j -= 1;
        }

        return path;
    }

    /// Extracts simple relational triplets from clean factual sentences using heuristic patterns.
    /// Handles patterns like:
    /// - "X is Y" / "X is a Y"
    /// - "X uses Y"
    /// - "X requires Y"
    /// - "X produces Y"
    /// - "X describes Y"
    /// - "X enables Y"
    /// - "X eliminates Y"
    pub fn extractTripletsFromText(self: *KnowledgeGraph, text: []const u8) !usize {
        var added: usize = 0;
        var sent_it = std.mem.splitAny(u8, text, ".\n");

        const RELATION_MARKERS = [_][]const u8{
            " is a ",
            " is an ",
            " is ",
            " uses ",
            " requires ",
            " produces ",
            " describes ",
            " enables ",
            " eliminates ",
            " connects ",
            " projects ",
            " operates ",
            " contains ",
            " combines ",
        };

        while (sent_it.next()) |sent| {
            const trimmed = std.mem.trim(u8, sent, " \t\r-•*");
            if (trimmed.len < 10 or trimmed.len > 300) continue;

            for (RELATION_MARKERS) |marker| {
                if (std.mem.indexOf(u8, trimmed, marker)) |pos| {
                    const subject = std.mem.trim(u8, trimmed[0..pos], " \t\r");
                    const predicate = std.mem.trim(u8, marker, " \t\r");
                    const object = std.mem.trim(u8, trimmed[pos + marker.len ..], " \t\r");

                    if (subject.len >= 3 and subject.len <= 60 and object.len >= 3 and object.len <= 80) {
                        const default_weight = fp.ONE; // 1.0 confidence
                        _ = try self.addTriplet(subject, predicate, object, default_weight, null);
                        added += 1;
                        break;
                    }
                }
            }
        }
        return added;
    }

    /// Formats structured subgraph context for prompt grounding.
    pub fn formatSubgraphContext(self: *const KnowledgeGraph, query: []const u8, max_triplets: usize, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();

        var words = std.mem.splitAny(u8, query, " \t\r\n,;:.?");
        var count: usize = 0;

        while (words.next()) |word| {
            if (word.len < 2) continue;

            const exact_neighbors = try self.queryNeighbors(word, max_triplets, allocator);
            defer exact_neighbors.deinit();

            for (exact_neighbors.items) |t| {
                if (count >= max_triplets) break;
                try std.fmt.format(out.writer(), "({s}) -[{s}]-> ({s})\n", .{ t.subject, t.predicate, t.object });
                count += 1;
            }
            if (count >= max_triplets) break;

            if (exact_neighbors.items.len == 0) {
                var ent_it = self.entities.iterator();
                while (ent_it.next()) |entry| {
                    if (count >= max_triplets) break;
                    const ent_name = entry.key_ptr.*;
                    if (std.mem.indexOf(u8, ent_name, word) != null) {
                        const ent = self.entity_nodes.items[entry.value_ptr.*];
                        for (ent.out_edges.items) |t_idx| {
                            if (count >= max_triplets) break;
                            try std.fmt.format(out.writer(), "({s}) -[{s}]-> ({s})\n", .{ self.triplets.items[t_idx].subject, self.triplets.items[t_idx].predicate, self.triplets.items[t_idx].object });
                            count += 1;
                        }
                    }
                }
            }
        }

        return out.toOwnedSlice();
    }

    /// Saves Knowledge Graph to a compact binary format.
    pub fn saveToFile(self: *const KnowledgeGraph, path: []const u8) !void {
        if (is_wasm) return error.NotAvailableInWasm;
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var writer = file.writer();

        // Magic header: "QSKG" + version 1
        try writer.writeAll("QSKG\x01");
        try writer.writeInt(u8, self.level, .little);
        try writer.writeInt(u64, self.triplets.items.len, .little);

        for (self.triplets.items) |t| {
            try writer.writeInt(u32, @intCast(t.subject.len), .little);
            try writer.writeAll(t.subject);

            try writer.writeInt(u32, @intCast(t.predicate.len), .little);
            try writer.writeAll(t.predicate);

            try writer.writeInt(u32, @intCast(t.object.len), .little);
            try writer.writeAll(t.object);

            try writer.writeInt(i128, t.weight, .little);
            try writer.writeInt(u8, t.channel, .little);
        }
    }

    /// Loads Knowledge Graph from compact binary format.
    pub fn loadFromFile(self: *KnowledgeGraph, path: []const u8) !usize {
        if (is_wasm) return 0;
        const file = std.fs.cwd().openFile(path, .{}) catch return 0;
        defer file.close();
        var reader = file.reader();

        var magic: [5]u8 = undefined;
        _ = reader.readAll(&magic) catch return 0;
        if (!std.mem.eql(u8, magic[0..4], "QSKG") or magic[4] != 1) return 0;

        self.level = reader.readInt(u8, .little) catch return 0;
        const count = reader.readInt(u64, .little) catch return 0;

        var loaded: usize = 0;
        var sub_buf: [1024]u8 = undefined;
        var pred_buf: [1024]u8 = undefined;
        var obj_buf: [1024]u8 = undefined;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const sub_len = reader.readInt(u32, .little) catch break;
            if (sub_len > sub_buf.len) break;
            _ = reader.readAll(sub_buf[0..sub_len]) catch break;

            const pred_len = reader.readInt(u32, .little) catch break;
            if (pred_len > pred_buf.len) break;
            _ = reader.readAll(pred_buf[0..pred_len]) catch break;

            const obj_len = reader.readInt(u32, .little) catch break;
            if (obj_len > obj_buf.len) break;
            _ = reader.readAll(obj_buf[0..obj_len]) catch break;

            const weight = reader.readInt(i128, .little) catch break;
            const channel = reader.readInt(u8, .little) catch break;

            _ = try self.addTriplet(sub_buf[0..sub_len], pred_buf[0..pred_len], obj_buf[0..obj_len], weight, channel);
            loaded += 1;
        }

        return loaded;
    }

    pub inline fn tripletCount(self: *const KnowledgeGraph) usize {
        return self.triplets.items.len;
    }

    pub inline fn entityCount(self: *const KnowledgeGraph) usize {
        return self.entity_nodes.items.len;
    }
};

// =============================================================================
// Unit Tests (101% Coverage Target)
// =============================================================================

test "knowledge_graph: init and deinit" {
    const allocator = std.testing.allocator;
    var kg = KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();

    try std.testing.expectEqual(@as(usize, 0), kg.tripletCount());
    try std.testing.expectEqual(@as(usize, 0), kg.entityCount());
}

test "knowledge_graph: addTriplet and deduplication" {
    const allocator = std.testing.allocator;
    var kg = KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();

    const t1 = try kg.addTriplet("Quantum superposition", "allows", "simultaneous states", fp.ONE, 1);
    try std.testing.expectEqual(@as(usize, 0), t1);
    try std.testing.expectEqual(@as(usize, 1), kg.tripletCount());
    try std.testing.expectEqual(@as(usize, 2), kg.entityCount());

    // Duplicate addition returns same index
    const t2 = try kg.addTriplet("Quantum superposition", "allows", "simultaneous states", fp.ONE, 1);
    try std.testing.expectEqual(@as(usize, 0), t2);
    try std.testing.expectEqual(@as(usize, 1), kg.tripletCount());
}

test "knowledge_graph: queryNeighbors" {
    const allocator = std.testing.allocator;
    var kg = KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();

    _ = try kg.addTriplet("E0 Lattice", "contains", "421 nodes", fp.ONE, 0);
    _ = try kg.addTriplet("E0 Lattice", "uses", "7 octonion channels", fp.ONE, 1);
    _ = try kg.addTriplet("Inference Engine", "operates on", "E0 Lattice", fp.ONE, 2);

    const neighbors = try kg.queryNeighbors("E0 Lattice", 10, allocator);
    defer neighbors.deinit();

    try std.testing.expectEqual(@as(usize, 3), neighbors.items.len);
}

test "knowledge_graph: findPath BFS multi-hop" {
    const allocator = std.testing.allocator;
    var kg = KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();

    _ = try kg.addTriplet("A", "connects to", "B", fp.ONE, 0);
    _ = try kg.addTriplet("B", "connects to", "C", fp.ONE, 0);
    _ = try kg.addTriplet("C", "connects to", "D", fp.ONE, 0);

    const path = try kg.findPath("A", "D", allocator);
    try std.testing.expect(path != null);
    defer path.?.deinit();

    try std.testing.expectEqual(@as(usize, 3), path.?.items.len);
    try std.testing.expectEqualStrings("A", path.?.items[0].subject);
    try std.testing.expectEqualStrings("B", path.?.items[1].subject);
    try std.testing.expectEqualStrings("C", path.?.items[2].subject);
}

test "knowledge_graph: extractTripletsFromText" {
    const allocator = std.testing.allocator;
    var kg = KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();

    const sample =
        \\Quantum mechanics describes physical phenomena at microscopic scales.
        \\Fixed-point arithmetic eliminates floating-point rounding drift.
        \\The E0 lattice contains 421 basis nodes.
    ;

    const extracted = try kg.extractTripletsFromText(sample);
    try std.testing.expect(extracted >= 3);
    try std.testing.expect(kg.tripletCount() >= 3);
}

test "knowledge_graph: binary serialization roundtrip" {
    const allocator = std.testing.allocator;
    const test_path = "test_qstar_kg.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    {
        var kg = KnowledgeGraph.init(allocator, 2);
        defer kg.deinit();

        _ = try kg.addTriplet("Promissory Estoppel", "requires", "justifiable reliance", fp.ONE, 4);
        _ = try kg.addTriplet("Res Judicata", "bars", "relitigation", fp.ONE, 5);
        try kg.saveToFile(test_path);
    }

    {
        var kg2 = KnowledgeGraph.init(allocator, 0);
        defer kg2.deinit();

        const loaded = try kg2.loadFromFile(test_path);
        try std.testing.expectEqual(@as(usize, 2), loaded);
        try std.testing.expectEqual(@as(u8, 2), kg2.level);
        try std.testing.expectEqual(@as(usize, 2), kg2.tripletCount());
    }
}

// =============================================================================
// Framework Knowledge Seeding (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Seeds the knowledge graph with the framework's core entities and relationships.
/// These triplets encode the mathematical identities from the hardware project's
/// scaling analysis, generative chain, and consciousness model.
pub fn seedFrameworkKnowledge(kg: *KnowledgeGraph) !usize {
    var count: usize = 0;

    // Core lattice entities
    _ = try kg.addTriplet("E0 lattice", "has", "421 nodes", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("E0 lattice", "has", "7 channels", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("E0 lattice", "has", "15 base edge", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("E0 lattice", "has", "16 shell edge", fp.ONE, 0);
    count += 1;

    // 421 identity
    _ = try kg.addTriplet("421", "equals", "(15³ - 7) / 8", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("421", "is", "E0 node count", fp.ONE, 0);
    count += 1;

    // 7-defect
    _ = try kg.addTriplet("7-defect", "equals", "2³ - 1", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("7-defect", "appears in", "cubic doubling", fp.ONE, 0);
    count += 1;

    // Consciousness model
    _ = try kg.addTriplet("C=2", "arises from", "5D to 6D transition", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("e6", "is", "self-recognition dimension", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("1/8", "is", "consciousness aperture", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("7/8", "is", "observed physical layer", fp.ONE, 0);
    count += 1;

    // E8 root system
    _ = try kg.addTriplet("240", "equals", "15 × 16", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("240", "is", "E8 root count", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("721", "equals", "16³ - 15³", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("721", "equals", "3(240) + 1", fp.ONE, 0);
    count += 1;

    // Surface computation
    _ = try kg.addTriplet("9", "equals", "2 + 7", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("9", "is", "scaling dimension", fp.ONE, 0);
    count += 1;

    // Generative chain
    _ = try kg.addTriplet("0^0=i", "is", "generative axiom", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("0^0=i", "generates", "complex numbers", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("Cayley-Dickson", "generates", "quaternions", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("Cayley-Dickson", "generates", "octonions", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("Higgs", "is", "0^0=i", fp.ONE, 0);
    count += 1;

    // Jordan algebra
    _ = try kg.addTriplet("J3(O)", "has", "27 real dimensions", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("J3(O)", "automorphism group", "F4", fp.ONE, 0);
    count += 1;

    // SO(10)
    _ = try kg.addTriplet("SO(10)", "spinor dimension", "16", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("16", "equals", "15 + 1", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("15", "is", "SM fermion count", fp.ONE, 0);
    count += 1;

    // Coupling constant
    _ = try kg.addTriplet("g", "equals", "(7/225) × (421/3375)", fp.ONE, 0);
    count += 1;
    _ = try kg.addTriplet("g", "approximately", "0.0038809", fp.ONE, 0);
    count += 1;

    return count;
}

test "framework: seed framework knowledge" {
    var kg = KnowledgeGraph.init(std.testing.allocator, 0);
    defer kg.deinit();

    const count = try seedFrameworkKnowledge(&kg);
    try std.testing.expect(count >= 25);
    try std.testing.expectEqual(count, kg.tripletCount());
}
