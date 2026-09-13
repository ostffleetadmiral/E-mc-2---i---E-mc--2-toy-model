//! external_db.zig — Schema-Agnostic External Knowledge & Structured Database Connector for Qstar
//!
//! Provides bridges to query local structured datasets, key-value stores, JSON document
//! stores, and graph triplet queries for real-time agent ground-truth augmentation.

const std = @import("std");
const kg_mod = @import("knowledge_graph");

pub const ExternalDb = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExternalDb {
        return ExternalDb{ .allocator = allocator };
    }

    /// Queries structured key-value entries from formatted document databases.
    pub fn queryKeyValue(self: *const ExternalDb, db_text: []const u8, target_key: []const u8) !?[]const u8 {
        var lines = std.mem.splitScalar(u8, db_text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                const key = std.mem.trim(u8, trimmed[0..colon], " \t\r\"'");
                if (std.ascii.eqlIgnoreCase(key, target_key)) {
                    const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r\"'");
                    return try self.allocator.dupe(u8, val);
                }
            }
        }
        return null;
    }

    /// Queries a structured JSON dataset and returns matching elements as formatted JSON string.
    pub fn queryJsonRecords(self: *const ExternalDb, json_text: []const u8, key_term: []const u8) ![]const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        var matches: usize = 0;
        var lines = std.mem.splitScalar(u8, json_text, '\n');

        try out.appendSlice("{\"status\":\"success\",\"matches\":[");

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r,");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, key_term) != null) {
                if (matches > 0) try out.append(',');
                try out.appendSlice(trimmed);
                matches += 1;
                if (matches >= 10) break;
            }
        }

        try out.appendSlice("]}");
        return out.toOwnedSlice();
    }

    /// Executes a declarative graph query across a KnowledgeGraph instance.
    pub fn queryGraphPattern(
        self: *const ExternalDb,
        kg: *const kg_mod.KnowledgeGraph,
        subject: ?[]const u8,
        predicate: ?[]const u8,
        object: ?[]const u8,
    ) ![]const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        try out.appendSlice("{\"triplets\":[");
        var count: usize = 0;

        for (kg.triplets.items) |t| {
            var match = true;
            if (subject) |s| {
                if (s.len > 0 and std.mem.indexOf(u8, t.subject, s) == null) match = false;
            }
            if (predicate) |p| {
                if (p.len > 0 and std.mem.indexOf(u8, t.predicate, p) == null) match = false;
            }
            if (object) |o| {
                if (o.len > 0 and std.mem.indexOf(u8, t.object, o) == null) match = false;
            }

            if (match) {
                if (count > 0) try out.append(',');
                try std.fmt.format(out.writer(), "{{\"subject\":\"{s}\",\"predicate\":\"{s}\",\"object\":\"{s}\",\"weight\":{d},\"channel\":{d}}}", .{
                    t.subject,
                    t.predicate,
                    t.object,
                    t.weight,
                    t.channel,
                });
                count += 1;
                if (count >= 25) break;
            }
        }

        try out.appendSlice("],\"count\":");
        try std.fmt.format(out.writer(), "{d}}}", .{count});
        return out.toOwnedSlice();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "external_db: queryKeyValue" {
    const allocator = std.testing.allocator;
    const db = ExternalDb.init(allocator);

    const data =
        \\# Config database
        \\server_port: 8080
        \\model_name: qstar_e0
        \\lattice_nodes: 421
    ;

    const val = try db.queryKeyValue(data, "model_name");
    try std.testing.expect(val != null);
    defer allocator.free(val.?);
    try std.testing.expectEqualStrings("qstar_e0", val.?);
}

test "external_db: queryGraphPattern" {
    const allocator = std.testing.allocator;
    const db = ExternalDb.init(allocator);
    var kg = kg_mod.KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();

    _ = try kg.addTriplet("BlacksLaw", "defines", "Promissory Estoppel", 1000, 1);
    _ = try kg.addTriplet("BlacksLaw", "defines", "Stare Decisis", 1000, 1);
    _ = try kg.addTriplet("Webster", "defines", "Syzygy", 1000, 2);

    const json = try db.queryGraphPattern(&kg, "BlacksLaw", null, null);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Promissory Estoppel") != null);
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
