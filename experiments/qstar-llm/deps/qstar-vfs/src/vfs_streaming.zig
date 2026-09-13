//! vfs_streaming.zig — Ring-buffer streaming for sequential lattice level traversal.
//!
//! Inspired by kimi-k3-in-c's trunk streaming (k3_trunk.h):
//! - LRU is the worst policy for cyclic sequential scans (L0→L8→L0→...)
//! - Instead, pin a prefix of levels and stream the rest through a ring buffer
//! - Pin K levels → hit rate is exactly K/N, deterministically
//! - Every extra gigabyte of RAM buys its fair share
//!
//! This module provides the streaming ring for lattice level traversal,
//! complementing the LRU cache in vfs_bridge.zig which handles
//! data-dependent (non-sequential) access patterns.
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const vfs = @import("vfs_bridge");

// =============================================================================
// Constants
// =============================================================================

/// Number of lattice levels (L0 through L8).
pub const LATTICE_LEVELS: u8 = 9;

/// Default ring buffer size (number of streaming slots).
pub const DEFAULT_RING_SLOTS: usize = 3;

// =============================================================================
// StreamingSlot — one slot in the ring buffer
// =============================================================================

pub const StreamingSlot = struct {
    /// Which level is currently loaded in this slot (or null if empty).
    level: ?u8 = null,
    /// The page data loaded in this slot.
    page: vfs.LatticePage,
    /// Whether this slot's read has completed.
    loaded: bool = false,

    pub fn empty() StreamingSlot {
        return .{
            .level = null,
            .page = vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 0),
            .loaded = false,
        };
    }
};

// =============================================================================
// StreamingRing — ring buffer for sequential level traversal
// =============================================================================

pub const StreamingRing = struct {
    allocator: std.mem.Allocator,
    /// Number of pinned levels (0..pin_count-1 are always resident).
    pin_count: u8,
    /// Pinned level data (one allocation per pinned level).
    pinned: []?vfs.LatticePage,
    /// Ring buffer slots for streaming levels.
    ring: []StreamingSlot,
    /// Next ring slot to reuse (round-robin).
    ring_head: usize = 0,
    /// Which level each ring slot holds (for quick lookup).
    level_of: [256]?u8 = [_]?u8{null} ** 256,
    /// Stats (like k3_trunk: hits, misses, bytes_read).
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    /// Create a streaming ring with pin_count pinned levels and ring_slots streaming slots.
    /// Budget determines how many levels can be pinned: pin_count = min(requested, budget/slot_size).
    pub fn init(
        allocator: std.mem.Allocator,
        pin_count: u8,
        ring_slots: usize,
    ) !StreamingRing {
        const actual_pins = @min(pin_count, LATTICE_LEVELS);
        const actual_slots = @max(ring_slots, 1);

        const pinned = try allocator.alloc(?vfs.LatticePage, actual_pins);
        for (pinned) |*p| p.* = null;

        const ring = try allocator.alloc(StreamingSlot, actual_slots);
        for (ring) |*s| s.* = StreamingSlot.empty();

        return .{
            .allocator = allocator,
            .pin_count = actual_pins,
            .pinned = pinned,
            .ring = ring,
        };
    }

    pub fn deinit(self: *StreamingRing) void {
        self.allocator.free(self.pinned);
        self.allocator.free(self.ring);
    }

    /// Check if a level is pinned.
    pub fn isPinned(self: *const StreamingRing, level: u8) bool {
        return level < self.pin_count;
    }

    /// Load a pinned level. Must be called before get() for pinned levels.
    pub fn loadPinned(self: *StreamingRing, level: u8, page: vfs.LatticePage) !void {
        if (level >= self.pin_count) return error.LevelNotPinned;
        self.pinned[level] = page;
    }

    /// Get a page from the ring or pinned set.
    /// Returns a pointer to the page, or null if not resident.
    pub fn get(self: *StreamingRing, level: u8) ?*const vfs.LatticePage {
        // Check pinned first
        if (level < self.pin_count) {
            if (self.pinned[level]) |*page| {
                self.hits += 1;
                return page;
            }
            self.misses += 1;
            return null;
        }

        // Check ring slots
        if (self.level_of[level]) |_| {
            for (self.ring) |*slot| {
                if (slot.level == level and slot.loaded) {
                    self.hits += 1;
                    return &slot.page;
                }
            }
        }

        self.misses += 1;
        return null;
    }

    /// Load a level into the next ring slot (evicts the oldest ring entry).
    /// Like k3_trunk_prefetch — loads layer L+1 while computing on layer L.
    pub fn loadIntoRing(self: *StreamingRing, level: u8, page: vfs.LatticePage) !void {
        if (level < self.pin_count) {
            try self.loadPinned(level, page);
            return;
        }

        // Check if already in ring
        for (self.ring) |*slot| {
            if (slot.level == level and slot.loaded) {
                slot.page = page; // Update
                return;
            }
        }

        // Evict ring_head slot and load new page
        const slot = &self.ring[self.ring_head];
        if (slot.level) |old_level| {
            self.level_of[old_level] = null;
            self.evictions += 1;
        }

        slot.level = level;
        slot.page = page;
        slot.loaded = true;
        self.level_of[level] = level;

        // Advance ring head
        self.ring_head = (self.ring_head + 1) % self.ring.len;
    }

    /// Prefetch the next level into the ring while current is being processed.
    /// Like k3_trunk_prefetch: safe because the next level is always known
    /// in a fixed-order sequential scan.
    pub fn prefetchNext(self: *StreamingRing, current_level: u8, page: vfs.LatticePage) !void {
        const next_level = current_level + 1;
        if (next_level >= LATTICE_LEVELS) return; // No next level
        if (next_level < self.pin_count) return; // Will be pinned
        try self.loadIntoRing(next_level, page);
    }

    /// Hit rate for the streaming ring.
    /// With pin_count pinned levels and N total levels, hit rate = pin_count / N.
    pub fn hitRate(self: *const StreamingRing) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    /// Reset stats.
    pub fn resetStats(self: *StreamingRing) void {
        self.hits = 0;
        self.misses = 0;
        self.evictions = 0;
    }

    /// Number of ring slots currently occupied.
    pub fn ringOccupancy(self: *const StreamingRing) usize {
        var count: usize = 0;
        for (self.ring) |slot| {
            if (slot.loaded) count += 1;
        }
        return count;
    }

    /// Number of pinned levels currently loaded.
    pub fn pinnedLoaded(self: *const StreamingRing) usize {
        var count: usize = 0;
        for (self.pinned) |p| {
            if (p != null) count += 1;
        }
        return count;
    }
};

// =============================================================================
// LevelStream — sequential level iterator with prefetch
// =============================================================================

pub const LevelStream = struct {
    ring: StreamingRing,
    /// Current level being processed.
    current: u8 = 0,
    /// Whether the stream has been initialized.
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, pin_count: u8, ring_slots: usize) !LevelStream {
        return .{
            .ring = try StreamingRing.init(allocator, pin_count, ring_slots),
        };
    }

    pub fn deinit(self: *LevelStream) void {
        self.ring.deinit();
    }

    /// Advance to the next level. Returns the level number, or null if done.
    pub fn next(self: *LevelStream) ?u8 {
        if (!self.initialized) {
            self.initialized = true;
            self.current = 0;
            return 0;
        }
        self.current += 1;
        if (self.current >= LATTICE_LEVELS) return null;
        return self.current;
    }

    /// Load a page for the current level.
    pub fn load(self: *LevelStream, page: vfs.LatticePage) !void {
        try self.ring.loadIntoRing(self.current, page);
    }

    /// Get the current level's page.
    pub fn getCurrent(self: *LevelStream) ?*const vfs.LatticePage {
        return self.ring.get(self.current);
    }

    /// Prefetch the next level's page while processing current.
    pub fn prefetchNext(self: *LevelStream, next_page: vfs.LatticePage) !void {
        try self.ring.prefetchNext(self.current, next_page);
    }

    /// Reset the stream to level 0.
    pub fn reset(self: *LevelStream) void {
        self.current = 0;
        self.initialized = false;
        self.ring.resetStats();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StreamingRing: init with pinned levels" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 3, 2);
    defer ring.deinit();

    try std.testing.expectEqual(@as(u8, 3), ring.pin_count);
    try std.testing.expectEqual(@as(usize, 2), ring.ring.len);
    try std.testing.expect(ring.isPinned(0));
    try std.testing.expect(ring.isPinned(1));
    try std.testing.expect(ring.isPinned(2));
    try std.testing.expect(!ring.isPinned(3));
}

test "StreamingRing: pinned level load and get" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 2, 2);
    defer ring.deinit();

    const page = vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 100);
    try ring.loadPinned(0, page);

    const got = ring.get(0);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 100), got.?.last_access_ms);
    try std.testing.expectEqual(@as(u64, 1), ring.hits);
}

test "StreamingRing: ring level load and get" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 1, 3);
    defer ring.deinit();

    // Load level 5 into ring
    const page5 = vfs.LatticePage.init(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 200);
    try ring.loadIntoRing(5, page5);

    const got = ring.get(5);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u8, 5), got.?.key.level);
}

test "StreamingRing: ring eviction is round-robin" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 0, 2);
    defer ring.deinit();

    // Load levels 5, 6, 7 — with 2 slots, level 5 should be evicted
    const page5 = vfs.LatticePage.init(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 100);
    const page6 = vfs.LatticePage.init(.{ .level = 6, .bx = 0, .by = 0, .bz = 0 }, 200);
    const page7 = vfs.LatticePage.init(.{ .level = 7, .bx = 0, .by = 0, .bz = 0 }, 300);

    try ring.loadIntoRing(5, page5);
    try ring.loadIntoRing(6, page6);
    try ring.loadIntoRing(7, page7);

    // Level 5 should be evicted (round-robin)
    try std.testing.expect(ring.get(5) == null);
    // Levels 6 and 7 should still be resident
    try std.testing.expect(ring.get(6) != null);
    try std.testing.expect(ring.get(7) != null);

    try std.testing.expect(ring.evictions > 0);
}

test "StreamingRing: prefetchNext loads next level" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 0, 3);
    defer ring.deinit();

    // Load current level 3
    const page3 = vfs.LatticePage.init(.{ .level = 3, .bx = 0, .by = 0, .bz = 0 }, 100);
    try ring.loadIntoRing(3, page3);

    // Prefetch level 4
    const page4 = vfs.LatticePage.init(.{ .level = 4, .bx = 0, .by = 0, .bz = 0 }, 200);
    try ring.prefetchNext(3, page4);

    // Level 4 should be resident
    try std.testing.expect(ring.get(4) != null);
}

test "StreamingRing: prefetchNext at last level is no-op" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 0, 3);
    defer ring.deinit();

    const page8 = vfs.LatticePage.init(.{ .level = 8, .bx = 0, .by = 0, .bz = 0 }, 100);
    try ring.loadIntoRing(8, page8);

    // Prefetching past level 8 should be a no-op
    const page_next = vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 200);
    try ring.prefetchNext(8, page_next);

    // No new level loaded
    try std.testing.expectEqual(@as(usize, 1), ring.ringOccupancy());
}

test "StreamingRing: hit rate calculation" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 3, 2);
    defer ring.deinit();

    // Load 3 pinned levels
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const page = vfs.LatticePage.init(.{ .level = i, .bx = 0, .by = 0, .bz = 0 }, 100);
        try ring.loadPinned(i, page);
    }

    // Access pinned levels — all hits
    _ = ring.get(0);
    _ = ring.get(1);
    _ = ring.get(2);
    // Access non-pinned — miss
    _ = ring.get(5);

    // Hit rate = 3 hits / 4 requests = 0.75
    const rate = ring.hitRate();
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), rate, 0.001);
}

test "StreamingRing: ring occupancy" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 0, 3);
    defer ring.deinit();

    try std.testing.expectEqual(@as(usize, 0), ring.ringOccupancy());

    try ring.loadIntoRing(3, vfs.LatticePage.init(.{ .level = 3, .bx = 0, .by = 0, .bz = 0 }, 100));
    try std.testing.expectEqual(@as(usize, 1), ring.ringOccupancy());

    try ring.loadIntoRing(4, vfs.LatticePage.init(.{ .level = 4, .bx = 0, .by = 0, .bz = 0 }, 200));
    try std.testing.expectEqual(@as(usize, 2), ring.ringOccupancy());

    try ring.loadIntoRing(5, vfs.LatticePage.init(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 300));
    try std.testing.expectEqual(@as(usize, 3), ring.ringOccupancy());
}

test "StreamingRing: pinned loaded count" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 3, 2);
    defer ring.deinit();

    try std.testing.expectEqual(@as(usize, 0), ring.pinnedLoaded());

    try ring.loadPinned(0, vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 100));
    try ring.loadPinned(1, vfs.LatticePage.init(.{ .level = 1, .bx = 0, .by = 0, .bz = 0 }, 200));
    try std.testing.expectEqual(@as(usize, 2), ring.pinnedLoaded());
}

test "StreamingRing: reset stats" {
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 1, 2);
    defer ring.deinit();

    try ring.loadPinned(0, vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 100));
    _ = ring.get(0);
    _ = ring.get(5); // miss

    try std.testing.expect(ring.hits > 0);
    try std.testing.expect(ring.misses > 0);

    ring.resetStats();
    try std.testing.expectEqual(@as(u64, 0), ring.hits);
    try std.testing.expectEqual(@as(u64, 0), ring.misses);
}

test "LevelStream: sequential traversal" {
    const allocator = std.testing.allocator;
    var stream = try LevelStream.init(allocator, 2, 2);
    defer stream.deinit();

    // First call returns level 0
    const first = stream.next();
    try std.testing.expectEqual(@as(u8, 0), first.?);

    // Load level 0
    try stream.load(vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 100));

    // Advance through all levels
    var level: u8 = 1;
    while (stream.next()) |lvl| {
        try std.testing.expectEqual(level, lvl);
        try stream.load(vfs.LatticePage.init(.{ .level = lvl, .bx = 0, .by = 0, .bz = 0 }, @as(u64, level) * 100));
        level += 1;
    }
    try std.testing.expectEqual(@as(u8, LATTICE_LEVELS), level);
}

test "LevelStream: reset to level 0" {
    const allocator = std.testing.allocator;
    var stream = try LevelStream.init(allocator, 0, 2);
    defer stream.deinit();

    _ = stream.next();
    _ = stream.next();
    _ = stream.next();
    try std.testing.expectEqual(@as(u8, 2), stream.current);

    stream.reset();
    try std.testing.expectEqual(@as(u8, 0), stream.current);
    try std.testing.expect(!stream.initialized);

    const first = stream.next();
    try std.testing.expectEqual(@as(u8, 0), first.?);
}

test "LevelStream: getCurrent returns loaded page" {
    const allocator = std.testing.allocator;
    var stream = try LevelStream.init(allocator, 0, 3);
    defer stream.deinit();

    _ = stream.next(); // level 0
    try stream.load(vfs.LatticePage.init(.{ .level = 0, .bx = 5, .by = 5, .bz = 5 }, 42));

    const page = stream.getCurrent();
    try std.testing.expect(page != null);
    try std.testing.expectEqual(@as(u32, 5), page.?.key.bx);
}

test "LevelStream: prefetchNext while processing current" {
    const allocator = std.testing.allocator;
    var stream = try LevelStream.init(allocator, 0, 3);
    defer stream.deinit();

    _ = stream.next(); // level 0
    try stream.load(vfs.LatticePage.init(.{ .level = 0, .bx = 0, .by = 0, .bz = 0 }, 100));

    // Prefetch level 1 while processing level 0
    try stream.prefetchNext(vfs.LatticePage.init(.{ .level = 1, .bx = 0, .by = 0, .bz = 0 }, 200));

    // Advance to level 1 — should already be in ring
    _ = stream.next(); // level 1
    const page = stream.getCurrent();
    try std.testing.expect(page != null);
    try std.testing.expectEqual(@as(u8, 1), page.?.key.level);
}

test "StreamingRing: deterministic hit rate with pin prefix" {
    // With pin_count=3 and 9 levels, accessing L0..L8 sequentially:
    // L0,L1,L2 are pinned (hits), L3..L8 are ring (misses on first pass).
    // Hit rate = 3/9 = 0.333...
    const allocator = std.testing.allocator;
    var ring = try StreamingRing.init(allocator, 3, 2);
    defer ring.deinit();

    // Load pinned
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        try ring.loadPinned(i, vfs.LatticePage.init(.{ .level = i, .bx = 0, .by = 0, .bz = 0 }, 100));
    }

    // Sequential access L0..L8
    var level: u8 = 0;
    while (level < LATTICE_LEVELS) : (level += 1) {
        if (ring.get(level) == null) {
            // Load into ring
            try ring.loadIntoRing(level, vfs.LatticePage.init(.{ .level = level, .bx = 0, .by = 0, .bz = 0 }, 200));
        }
    }

    // 3 pinned hits, 6 ring misses on first pass
    try std.testing.expectEqual(@as(u64, 3), ring.hits);
    try std.testing.expectEqual(@as(u64, 6), ring.misses);
    const rate = ring.hitRate();
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 9.0), rate, 0.001);
}
