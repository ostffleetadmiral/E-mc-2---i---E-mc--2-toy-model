// ============================================================================
// NEURALEAK LATTICE COUPLER — Coupler Audit Log
// ============================================================================
//
// Provides a coupler audit log for tracking lattice coupling events.
// This is a minimal implementation that records coupling events between
// lattice cells for later analysis.
//
// License: Real Illumation Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");

pub const CouplerAuditLog = struct {
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        timestamp_us: i64,
        cell_a_x: u4,
        cell_a_y: u4,
        cell_a_z: u4,
        cell_b_x: u4,
        cell_b_y: u4,
        cell_b_z: u4,
        coupling_strength: f64,
    };

    pub fn init(allocator: std.mem.Allocator) CouplerAuditLog {
        return .{
            .entries = std.ArrayList(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *CouplerAuditLog) void {
        self.entries.deinit();
    }

    pub fn log(self: *CouplerAuditLog, entry: Entry) !void {
        try self.entries.append(entry);
    }

    pub fn count(self: *const CouplerAuditLog) usize {
        return self.entries.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CouplerAuditLog init creates empty log" {
    var log = CouplerAuditLog.init(std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 0), log.count());
}

test "CouplerAuditLog records entries" {
    var log = CouplerAuditLog.init(std.testing.allocator);
    defer log.deinit();

    try log.log(.{
        .timestamp_us = 1000,
        .cell_a_x = 7,
        .cell_a_y = 7,
        .cell_a_z = 7,
        .cell_b_x = 8,
        .cell_b_y = 7,
        .cell_b_z = 7,
        .coupling_strength = 1.0,
    });

    try std.testing.expectEqual(@as(usize, 1), log.count());
    try std.testing.expectEqual(@as(u4, 7), log.entries.items[0].cell_a_x);
    try std.testing.expectEqual(@as(u4, 8), log.entries.items[0].cell_b_x);
}
