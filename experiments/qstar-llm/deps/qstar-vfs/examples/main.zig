//! Qstar-VFS Example — LRU cache, page serialization, store/retrieve.

const std = @import("std");
const vfs = @import("vfs_bridge");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.print("Qstar-VFS — Distributed Virtual File System\n", .{});
    try stdout.print("=============================================\n\n", .{});

    // VFS Bridge
    try stdout.print("VFS Bridge:\n", .{});
    var bridge = vfs.VFSBridge.init(allocator);
    defer bridge.deinit();
    try stdout.print("  E0 nodes per page: {d}\n", .{vfs.E0_NODE_COUNT});
    try stdout.print("  Default page bytes: {d}\n", .{vfs.DEFAULT_PAGE_BYTES});
    try stdout.print("  Default cache capacity: {d}\n", .{vfs.DEFAULT_CACHE_CAPACITY});

    // Create and store a page
    const key = vfs.PageKey.init(0, 1, 2, 3);
    var page = vfs.LatticePage.init(key, 1000);
    try stdout.print("\n  Created page at level={d} ({d},{d},{d})\n", .{ key.level, key.bx, key.by, key.bz });

    // Serialize
    const serialized = try page.serialize(allocator);
    defer allocator.free(serialized);
    try stdout.print("  Serialized: {d} bytes\n", .{serialized.len});

    // Deserialize
    const restored = try vfs.LatticePage.deserialize(serialized, 2000);
    try stdout.print("  Deserialized: level={d}, key=({d},{d},{d})\n", .{
        restored.key.level, restored.key.bx, restored.key.by, restored.key.bz,
    });

    // VFS Cache
    try stdout.print("\nVFS Cache (LRU with pinning):\n", .{});
    var cache = vfs.VFSCache.init(allocator, 256);
    defer cache.deinit();
    try cache.put(page);
    try stdout.print("  Cache count: {d}\n", .{cache.count()});
    try stdout.print("  Cache full: {}\n", .{cache.isFull()});

    const cached = cache.get(key, 3000);
    if (cached) |c| {
        try stdout.print("  Cache hit: level={d}\n", .{c.key.level});
    }

    // Distributed
    try stdout.print("\nVFS Distributed:\n", .{});
    try stdout.print("  Max nodes: {d}\n", .{vfs_distributed.MAX_NODES});
    try stdout.print("  Max replicas: {d}\n", .{vfs_distributed.MAX_REPLICAS});
    try stdout.print("  Heartbeat timeout: {d}ms\n", .{vfs_distributed.HEARTBEAT_TIMEOUT_MS});

    try stdout.print("\nDone.\n", .{});
}

const vfs_distributed = struct {
    pub const MAX_NODES: usize = 64;
    pub const MAX_REPLICAS: u8 = 4;
    pub const HEARTBEAT_TIMEOUT_MS: u64 = 5000;
};
