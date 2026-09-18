//! memory_pool.zig — Fixed-size block pool allocator for hot-path reuse.
//!
//! Provides O(1) alloc/free for fixed-size blocks, avoiding allocator overhead
//! in hot loops like agent inference cycles and compression chunk processing.

const std = @import("std");

/// A pool of fixed-size memory blocks. Alloc/free are O(1).
/// Thread-unsafe — use one pool per thread or wrap with a mutex.
pub const BlockPool = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    blocks: []u8,
    free_list: []usize,
    free_count: usize,
    capacity: usize,

    /// Creates a pool with `capacity` blocks of `block_size` bytes each.
    pub fn init(allocator: std.mem.Allocator, block_size: usize, capacity: usize) !BlockPool {
        const blocks = try allocator.alloc(u8, block_size * capacity);
        errdefer allocator.free(blocks);
        const free_list = try allocator.alloc(usize, capacity);
        errdefer allocator.free(free_list);

        // Initialize free list: each entry points to the next free block
        for (free_list, 0..) |*entry, i| {
            entry.* = i;
        }

        return .{
            .allocator = allocator,
            .block_size = block_size,
            .blocks = blocks,
            .free_list = free_list,
            .free_count = capacity,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *BlockPool) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.free_list);
    }

    /// Allocates one block. Returns error.OutOfMemory if pool is exhausted.
    pub fn alloc(self: *BlockPool) ![]u8 {
        if (self.free_count == 0) return error.OutOfMemory;
        self.free_count -= 1;
        const block_idx = self.free_list[self.free_count];
        const offset = block_idx * self.block_size;
        return self.blocks[offset .. offset + self.block_size];
    }

    /// Frees a block back to the pool. The slice must be from a previous alloc.
    pub fn free(self: *BlockPool, block: []u8) void {
        std.debug.assert(block.len == self.block_size);
        const ptr_val = @intFromPtr(block.ptr);
        const base_val = @intFromPtr(self.blocks.ptr);
        const offset = ptr_val - base_val;
        std.debug.assert(offset % self.block_size == 0);
        const block_idx = offset / self.block_size;
        std.debug.assert(block_idx < self.capacity);
        self.free_list[self.free_count] = block_idx;
        self.free_count += 1;
    }

    /// Returns the number of available blocks.
    pub inline fn available(self: *const BlockPool) usize {
        return self.free_count;
    }

    /// Resets the pool, marking all blocks as free.
    pub fn reset(self: *BlockPool) void {
        for (self.free_list, 0..) |*entry, i| {
            entry.* = i;
        }
        self.free_count = self.capacity;
    }
};

/// Arena-style bump allocator for temporary allocations within a cycle.
/// Reset after each inference cycle to reuse memory without freeing individual blocks.
pub const BumpArena = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    offset: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize) !BumpArena {
        const buffer = try allocator.alloc(u8, size);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .offset = 0,
        };
    }

    pub fn deinit(self: *BumpArena) void {
        self.allocator.free(self.buffer);
    }

    pub fn alloc(self: *BumpArena, comptime T: type, count: usize) ![]T {
        const size = @sizeOf(T) * count;
        const alignment = @alignOf(T);
        // Align offset
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        if (aligned_offset + size > self.buffer.len) return error.OutOfMemory;
        self.offset = aligned_offset + size;
        const ptr: [*]T = @ptrCast(@alignCast(self.buffer[aligned_offset..].ptr));
        return ptr[0..count];
    }

    pub inline fn reset(self: *BumpArena) void {
        self.offset = 0;
    }

    pub inline fn used(self: *const BumpArena) usize {
        return self.offset;
    }

    pub inline fn capacity(self: *const BumpArena) usize {
        return self.buffer.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BlockPool alloc/free basic" {
    var pool = try BlockPool.init(std.testing.allocator, 256, 4);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), pool.available());

    const block1 = try pool.alloc();
    try std.testing.expectEqual(@as(usize, 256), block1.len);
    try std.testing.expectEqual(@as(usize, 3), pool.available());

    pool.free(block1);
    try std.testing.expectEqual(@as(usize, 4), pool.available());
}

test "BlockPool exhaustion" {
    var pool = try BlockPool.init(std.testing.allocator, 64, 2);
    defer pool.deinit();

    _ = try pool.alloc();
    _ = try pool.alloc();
    try std.testing.expectError(error.OutOfMemory, pool.alloc());
}

test "BlockPool reset" {
    var pool = try BlockPool.init(std.testing.allocator, 128, 4);
    defer pool.deinit();

    _ = try pool.alloc();
    _ = try pool.alloc();
    try std.testing.expectEqual(@as(usize, 2), pool.available());

    pool.reset();
    try std.testing.expectEqual(@as(usize, 4), pool.available());
}

test "BlockPool reuse after free" {
    var pool = try BlockPool.init(std.testing.allocator, 32, 2);
    defer pool.deinit();

    const block1 = try pool.alloc();
    block1[0] = 0xAB;
    pool.free(block1);

    const block2 = try pool.alloc();
    try std.testing.expectEqual(@as(u8, 0xAB), block2[0]);
    pool.free(block2);
}

test "BumpArena basic alloc" {
    var arena = try BumpArena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    const slice = try arena.alloc(u32, 100);
    try std.testing.expectEqual(@as(usize, 100), slice.len);

    try std.testing.expect(arena.used() >= 400);
    try std.testing.expect(arena.used() <= 4096);
}

test "BumpArena reset and reuse" {
    var arena = try BumpArena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    _ = try arena.alloc(u64, 100);
    const used_after = arena.used();
    try std.testing.expect(used_after > 0);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());

    _ = try arena.alloc(u64, 100);
    try std.testing.expectEqual(used_after, arena.used());
}

test "BumpArena exhaustion" {
    var arena = try BumpArena.init(std.testing.allocator, 64);
    defer arena.deinit();

    _ = try arena.alloc(u32, 10); // 40 bytes
    try std.testing.expectError(error.OutOfMemory, arena.alloc(u32, 10)); // would exceed 64
}

test "BumpArena alignment" {
    var arena = try BumpArena.init(std.testing.allocator, 256);
    defer arena.deinit();

    _ = try arena.alloc(u8, 1); // 1 byte, offset=1
    const aligned = try arena.alloc(u64, 1); // should be 8-byte aligned
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 8);
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
