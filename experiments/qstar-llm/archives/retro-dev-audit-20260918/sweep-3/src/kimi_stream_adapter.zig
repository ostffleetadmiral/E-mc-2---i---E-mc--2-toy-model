//! Kimi-inspired bounded streaming primitives.
//!
//! This is an architecture adapter, not a Qwen3 implementation of Kimi K3.
//! It models the reusable cache/trunk invariants: pinned entries, inflight
//! reservations, sequential trunk rings, and publish-after-success semantics.

const std = @import("std");

pub const CacheState = enum { empty, inflight, resident };

pub const CacheSlot = struct {
    key: i32 = -1,
    state: CacheState = .empty,
    pinned: bool = false,
    used_at: u64 = 0,
    bytes: usize = 0,
};

pub const ExpertCache = struct {
    slots: []CacheSlot,
    clock: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ExpertCache {
        const slots = try allocator.alloc(CacheSlot, capacity);
        @memset(slots, .{});
        return .{ .slots = slots };
    }

    pub fn deinit(self: *ExpertCache, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }

    fn find(self: *ExpertCache, key: i32) ?usize {
        for (self.slots, 0..) |slot, i| {
            if (slot.state == .resident and slot.key == key) return i;
        }
        return null;
    }

    fn victim(self: *ExpertCache) ?usize {
        var best: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.slots, 0..) |slot, i| {
            if (slot.state == .inflight or slot.pinned) continue;
            if (slot.state == .empty) return i;
            if (slot.used_at < oldest) {
                oldest = slot.used_at;
                best = i;
            }
        }
        return best;
    }

    pub fn reserve(self: *ExpertCache, key: i32, pin: bool) ?usize {
        if (self.find(key)) |i| {
            self.hits += 1;
            self.clock += 1;
            self.slots[i].used_at = self.clock;
            return i;
        }
        self.misses += 1;
        const i = self.victim() orelse return null;
        if (self.slots[i].state == .resident) self.evictions += 1;
        self.slots[i] = .{ .key = key, .state = .inflight, .pinned = pin, .used_at = self.clock };
        return i;
    }

    pub fn publish(self: *ExpertCache, slot: usize, bytes: usize, success: bool) bool {
        if (slot >= self.slots.len or self.slots[slot].state != .inflight) return false;
        if (!success) {
            self.slots[slot] = .{};
            return false;
        }
        self.clock += 1;
        self.slots[slot].state = .resident;
        self.slots[slot].used_at = self.clock;
        self.slots[slot].bytes = bytes;
        return true;
    }

    pub fn residentCount(self: ExpertCache) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.state == .resident) count += 1;
        }
        return count;
    }
};

pub const TrunkRing = struct {
    layer_to_slot: []i32,
    slot_to_layer: []i32,
    next_slot: usize = 0,
    pinned_layers: usize,

    pub fn init(allocator: std.mem.Allocator, layers: usize, ring_slots: usize, pinned_layers: usize) !TrunkRing {
        const layer_to_slot = try allocator.alloc(i32, layers);
        @memset(layer_to_slot, -1);
        const slot_to_layer = try allocator.alloc(i32, ring_slots);
        @memset(slot_to_layer, -1);
        return .{ .layer_to_slot = layer_to_slot, .slot_to_layer = slot_to_layer, .pinned_layers = @min(pinned_layers, layers) };
    }

    pub fn deinit(self: *TrunkRing, allocator: std.mem.Allocator) void {
        allocator.free(self.layer_to_slot);
        allocator.free(self.slot_to_layer);
    }

    pub fn slotFor(self: *TrunkRing, layer: usize) ?usize {
        if (layer >= self.layer_to_slot.len) return null;
        if (layer < self.pinned_layers) return layer;
        const slot = self.layer_to_slot[layer];
        return if (slot >= 0) @intCast(slot) else null;
    }

    pub fn bind(self: *TrunkRing, layer: usize) ?usize {
        if (self.slotFor(layer)) |slot| return slot;
        if (layer < self.pinned_layers or self.slot_to_layer.len == 0) return null;
        const slot = self.next_slot;
        self.next_slot = (self.next_slot + 1) % self.slot_to_layer.len;
        const old_layer = self.slot_to_layer[slot];
        if (old_layer >= 0) self.layer_to_slot[@intCast(old_layer)] = -1;
        self.slot_to_layer[slot] = @intCast(layer);
        self.layer_to_slot[layer] = @intCast(slot);
        return slot;
    }
};

test "expert cache does not publish failed reads" {
    var cache = try ExpertCache.init(std.testing.allocator, 2);
    defer cache.deinit(std.testing.allocator);
    const slot = cache.reserve(7, false).?;
    try std.testing.expect(!cache.publish(slot, 100, false));
    try std.testing.expectEqual(@as(usize, 0), cache.residentCount());
    try std.testing.expect(cache.reserve(8, false) != null);
}

test "expert cache protects inflight and pinned slots" {
    var cache = try ExpertCache.init(std.testing.allocator, 2);
    defer cache.deinit(std.testing.allocator);
    const pinned = cache.reserve(1, true).?;
    _ = cache.publish(pinned, 10, true);
    const inflight = cache.reserve(2, false).?;
    try std.testing.expect(cache.reserve(3, false) == null);
    _ = cache.publish(inflight, 10, true);
    try std.testing.expect(cache.reserve(3, false) != null);
}

test "trunk ring pins prefix and reuses streaming slots" {
    var ring = try TrunkRing.init(std.testing.allocator, 4, 2, 1);
    defer ring.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ring.bind(0).?);
    const a = ring.bind(1).?;
    const b = ring.bind(2).?;
    const c = ring.bind(3).?;
    try std.testing.expect(a != b);
    try std.testing.expect(c == a);
    try std.testing.expect(ring.slotFor(1) == null);
}
