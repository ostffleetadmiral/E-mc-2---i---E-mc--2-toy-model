//! Operational separation between implicit candidate processing and explicit review.
//!
//! This module describes execution and persistence boundaries. It does not make
//! claims about phenomenal consciousness.

const std = @import("std");
const q128 = @import("q128");

pub const Lane = enum { subconscious, conscious };
pub const Provenance = enum { lattice, retrieval, external, training };

pub const Candidate = struct {
    id: u64,
    confidence: q128.Fp,
    novelty: q128.Fp,
    provenance: Provenance,
    verified: bool = false,
    contradicts_known: bool = false,
};

pub const PromotionPolicy = struct {
    minimum_confidence: q128.Fp = q128.fromRatio(3, 4),
    minimum_novelty: q128.Fp = q128.fromRatio(1, 10),
    require_verification: bool = true,
};

pub const PromotionDecision = struct {
    accepted: bool,
    reason: []const u8,
};

pub const ImplicitStore = struct {
    items: std.ArrayList(Candidate),
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) ImplicitStore {
        return .{ .items = std.ArrayList(Candidate).init(allocator), .capacity = capacity };
    }

    pub fn deinit(self: *ImplicitStore) void {
        self.items.deinit();
    }

    pub fn observe(self: *ImplicitStore, candidate: Candidate) !void {
        if (self.capacity == 0) return;
        if (self.items.items.len >= self.capacity) {
            var weakest: usize = 0;
            for (self.items.items[1..], 1..) |item, i| {
                if (q128.cmp(item.confidence, self.items.items[weakest].confidence) < 0) weakest = i;
            }
            if (q128.cmp(candidate.confidence, self.items.items[weakest].confidence) <= 0) return;
            _ = self.items.orderedRemove(weakest);
        }
        try self.items.append(candidate);
    }
};

pub const ExplicitStore = struct {
    items: std.ArrayList(Candidate),
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) ExplicitStore {
        return .{ .items = std.ArrayList(Candidate).init(allocator), .capacity = capacity };
    }

    pub fn deinit(self: *ExplicitStore) void {
        self.items.deinit();
    }

    pub fn contains(self: ExplicitStore, id: u64) bool {
        for (self.items.items) |item| if (item.id == id) return true;
        return false;
    }

    pub fn record(self: *ExplicitStore, candidate: Candidate) !void {
        if (self.capacity == 0) return;
        if (self.contains(candidate.id)) return;
        if (self.items.items.len >= self.capacity) _ = self.items.orderedRemove(0);
        try self.items.append(candidate);
    }
};

fn readValue(comptime T: type, data: []const u8, index: *usize) !T {
    if (data.len -| index.* < @sizeOf(T)) return error.InvalidLaneState;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), data[index.* .. index.* + @sizeOf(T)]);
    index.* += @sizeOf(T);
    return value;
}

pub const CognitiveLanes = struct {
    implicit: ImplicitStore,
    explicit: ExplicitStore,
    policy: PromotionPolicy,

    pub fn init(allocator: std.mem.Allocator, implicit_capacity: usize, explicit_capacity: usize) CognitiveLanes {
        return .{
            .implicit = ImplicitStore.init(allocator, implicit_capacity),
            .explicit = ExplicitStore.init(allocator, explicit_capacity),
            .policy = .{},
        };
    }

    pub fn deinit(self: *CognitiveLanes) void {
        self.implicit.deinit();
        self.explicit.deinit();
    }

    /// Serializes both lane stores with a versioned header and CRC32.
    pub fn serialize(self: CognitiveLanes, allocator: std.mem.Allocator) ![]u8 {
        var payload = std.ArrayList(u8).init(allocator);
        errdefer payload.deinit();
        try payload.appendSlice("CLNS");
        try payload.append(1);
        const implicit_count: u32 = @intCast(self.implicit.items.items.len);
        const explicit_count: u32 = @intCast(self.explicit.items.items.len);
        try payload.appendSlice(std.mem.asBytes(&implicit_count));
        try payload.appendSlice(std.mem.asBytes(&explicit_count));
        for ([_][]const Candidate{ self.implicit.items.items, self.explicit.items.items }) |items| {
            for (items) |candidate| {
                try payload.appendSlice(std.mem.asBytes(&candidate.id));
                try payload.appendSlice(std.mem.asBytes(&candidate.confidence));
                try payload.appendSlice(std.mem.asBytes(&candidate.novelty));
                try payload.append(@intFromEnum(candidate.provenance));
                try payload.append(@intFromBool(candidate.verified));
                try payload.append(@intFromBool(candidate.contradicts_known));
            }
        }
        const checksum = std.hash.Crc32.hash(payload.items);
        try payload.appendSlice(std.mem.asBytes(&checksum));
        return payload.toOwnedSlice();
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !CognitiveLanes {
        if (data.len < 13 or !std.mem.eql(u8, data[0..4], "CLNS") or data[4] != 1) return error.InvalidLaneState;
        const stored_checksum = std.mem.bytesToValue(u32, data[data.len - @sizeOf(u32) ..]);
        if (std.hash.Crc32.hash(data[0 .. data.len - @sizeOf(u32)]) != stored_checksum) return error.InvalidLaneChecksum;
        var index: usize = 5;
        const implicit_count = try readValue(u32, data, &index);
        const explicit_count = try readValue(u32, data, &index);
        var lanes = CognitiveLanes.init(allocator, implicit_count, explicit_count);
        errdefer lanes.deinit();
        const total = @as(usize, implicit_count) + @as(usize, explicit_count);
        for (0..total) |i| {
            const id = try readValue(u64, data, &index);
            const confidence = try readValue(q128.Fp, data, &index);
            const novelty = try readValue(q128.Fp, data, &index);
            const provenance_value = try readValue(u8, data, &index);
            const verified = try readValue(u8, data, &index);
            const contradicts = try readValue(u8, data, &index);
            if (provenance_value > @intFromEnum(Provenance.training) or verified > 1 or contradicts > 1) return error.InvalidLaneState;
            const candidate = Candidate{
                .id = id,
                .confidence = confidence,
                .novelty = novelty,
                .provenance = @enumFromInt(provenance_value),
                .verified = verified != 0,
                .contradicts_known = contradicts != 0,
            };
            if (i < implicit_count) try lanes.implicit.items.append(candidate) else try lanes.explicit.items.append(candidate);
        }
        if (index != data.len - @sizeOf(u32)) return error.InvalidLaneState;
        return lanes;
    }

    pub fn saveToFile(self: CognitiveLanes, allocator: std.mem.Allocator, path: []const u8) !void {
        const data = try self.serialize(allocator);
        defer allocator.free(data);
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !CognitiveLanes {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(data);
        return deserialize(allocator, data);
    }

    pub fn submitImplicit(self: *CognitiveLanes, candidate: Candidate) !void {
        try self.implicit.observe(candidate);
    }

    pub fn review(self: CognitiveLanes, candidate: Candidate) PromotionDecision {
        if (candidate.contradicts_known) return .{ .accepted = false, .reason = "contradicts_known_state" };
        if (self.policy.require_verification and !candidate.verified) return .{ .accepted = false, .reason = "unverified" };
        if (q128.cmp(candidate.confidence, self.policy.minimum_confidence) < 0) return .{ .accepted = false, .reason = "low_confidence" };
        if (q128.cmp(candidate.novelty, self.policy.minimum_novelty) < 0) return .{ .accepted = false, .reason = "insufficient_novelty" };
        return .{ .accepted = true, .reason = "promoted" };
    }

    pub fn promote(self: *CognitiveLanes, candidate: Candidate) !PromotionDecision {
        const decision = self.review(candidate);
        if (decision.accepted) try self.explicit.record(candidate);
        return decision;
    }

    pub fn laneFor(self: CognitiveLanes, candidate: Candidate) Lane {
        return if (self.review(candidate).accepted) .conscious else .subconscious;
    }

    /// Replays the strongest implicit candidates through the explicit gate.
    /// This is bounded so repeated benchmark/training passes cannot grow state
    /// without limit or promote unverified candidates.
    pub fn consolidate(self: *CognitiveLanes, max_promotions: usize) !usize {
        var promoted: usize = 0;
        var index: usize = 0;
        while (index < self.implicit.items.items.len and promoted < max_promotions) : (index += 1) {
            const decision = try self.promote(self.implicit.items.items[index]);
            if (decision.accepted) promoted += 1;
        }
        return promoted;
    }
};

test "implicit store retains strongest bounded candidates" {
    var lanes = CognitiveLanes.init(std.testing.allocator, 2, 2);
    defer lanes.deinit();
    try lanes.submitImplicit(.{ .id = 1, .confidence = q128.fromRatio(1, 2), .novelty = q128.ONE, .provenance = .lattice });
    try lanes.submitImplicit(.{ .id = 2, .confidence = q128.fromRatio(9, 10), .novelty = q128.ONE, .provenance = .retrieval });
    try lanes.submitImplicit(.{ .id = 3, .confidence = q128.fromRatio(8, 10), .novelty = q128.ONE, .provenance = .external });
    try std.testing.expectEqual(@as(usize, 2), lanes.implicit.items.items.len);
    try std.testing.expectEqual(@as(u64, 2), lanes.implicit.items.items[0].id);
}

test "promotion requires verification and thresholds" {
    var lanes = CognitiveLanes.init(std.testing.allocator, 4, 4);
    defer lanes.deinit();
    const candidate = Candidate{ .id = 7, .confidence = q128.fromRatio(9, 10), .novelty = q128.fromRatio(2, 10), .provenance = .external };
    const rejected = try lanes.promote(candidate);
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqualStrings("unverified", rejected.reason);

    var verified = candidate;
    verified.verified = true;
    const accepted = try lanes.promote(verified);
    try std.testing.expect(accepted.accepted);
    try std.testing.expect(lanes.explicit.contains(7));
}

test "lane state serializes with checksum" {
    var lanes = CognitiveLanes.init(std.testing.allocator, 4, 4);
    defer lanes.deinit();
    try lanes.submitImplicit(.{ .id = 11, .confidence = q128.fromRatio(4, 5), .novelty = q128.ONE, .provenance = .retrieval });
    const data = try lanes.serialize(std.testing.allocator);
    defer std.testing.allocator.free(data);
    var restored = try CognitiveLanes.deserialize(std.testing.allocator, data);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.implicit.items.items.len);
    try std.testing.expectEqual(@as(u64, 11), restored.implicit.items.items[0].id);

    data[data.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidLaneChecksum, CognitiveLanes.deserialize(std.testing.allocator, data));
}

test "consolidation is bounded and gated" {
    var lanes = CognitiveLanes.init(std.testing.allocator, 4, 4);
    defer lanes.deinit();
    try lanes.submitImplicit(.{ .id = 20, .confidence = q128.ONE, .novelty = q128.ONE, .provenance = .training, .verified = true });
    try lanes.submitImplicit(.{ .id = 21, .confidence = q128.ONE, .novelty = q128.ONE, .provenance = .external, .verified = false });
    try std.testing.expectEqual(@as(usize, 1), try lanes.consolidate(1));
    try std.testing.expect(lanes.explicit.contains(20));
}

test "contradictions never promote" {
    var lanes = CognitiveLanes.init(std.testing.allocator, 4, 4);
    defer lanes.deinit();
    const decision = try lanes.promote(.{
        .id = 9,
        .confidence = q128.ONE,
        .novelty = q128.ONE,
        .provenance = .training,
        .verified = true,
        .contradicts_known = true,
    });
    try std.testing.expect(!decision.accepted);
    try std.testing.expectEqualStrings("contradicts_known_state", decision.reason);
}
