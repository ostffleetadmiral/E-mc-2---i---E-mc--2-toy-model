//! vfs_bridge.zig — VFS ↔ WebGPU ↔ Mesh bridge for demand-paged lattice data.
//!
//! Connects LVCE-style demand-paged storage to Qstar's renderer and mesh.
//! Provides LRU cache, page-in/page-out, compression for VFS storage,
//! and integration with E0SeedBuffer (render.zig) and SharedFace (mesh.zig).
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

/// Number of E0 nodes in the base lattice (must match render.zig / lattice.zig).
pub const E0_NODE_COUNT: usize = 421;

/// Default page size: one 15³ cell = 421 E0 nodes × (3×u32 + 1×i64) = 8,420 bytes.
pub const DEFAULT_PAGE_BYTES: usize = E0_NODE_COUNT * 20;

/// Default LRU cache capacity (number of pages).
pub const DEFAULT_CACHE_CAPACITY: usize = 256;

/// VFS magic header for serialized pages.
pub const VFS_MAGIC: [4]u8 = .{ 'V', 'F', 'S', '1' };

/// Page block size along each axis (15 nodes per block at s=0).
pub const BLOCK_EDGE: u32 = 15;

// =============================================================================
// E0Node — flat representation matching render.zig E0SeedNode / compress.zig E0NodeSeed
// =============================================================================

pub const E0Node = struct {
    x: u32,
    y: u32,
    z: u32,
    activation: i64, // Q32.32 fixed-point

    pub fn fromSeedNode(sn: anytype) E0Node {
        return .{ .x = sn.x, .y = sn.y, .z = sn.z, .activation = sn.activation };
    }
};

// =============================================================================
// PageKey — identifies a lattice region by level + block coordinates
// =============================================================================

pub const PageKey = struct {
    level: u8,
    bx: u32,
    by: u32,
    bz: u32,

    pub fn init(level: u8, bx: u32, by: u32, bz: u32) PageKey {
        return .{ .level = level, .bx = bx, .by = by, .bz = bz };
    }

    pub fn hash(self: PageKey) u64 {
        var h: u64 = @as(u64, self.level);
        h = h * 31 +% @as(u64, self.bx);
        h = h * 31 +% @as(u64, self.by);
        h = h * 31 +% @as(u64, self.bz);
        return h;
    }

    pub fn eql(a: PageKey, b: PageKey) bool {
        return a.level == b.level and a.bx == b.bx and a.by == b.by and a.bz == b.bz;
    }
};

// =============================================================================
// LatticePage — a page of E0 nodes for one lattice block
// =============================================================================

pub const LatticePage = struct {
    key: PageKey,
    nodes: [E0_NODE_COUNT]E0Node,
    /// Timestamp of last access (for LRU).
    last_access_ms: u64,
    /// Whether the page has been modified since being paged in.
    dirty: bool = false,

    pub fn init(key: PageKey, now_ms: u64) LatticePage {
        return .{
            .key = key,
            .nodes = [_]E0Node{.{ .x = 0, .y = 0, .z = 0, .activation = 0 }} ** E0_NODE_COUNT,
            .last_access_ms = now_ms,
        };
    }

    /// Serialize the page to bytes for VFS storage.
    /// Format: [magic 4B][level 1B][bx 4B][by 4B][bz 4B][421 × (x:4B, y:4B, z:4B, act:8B)]
    pub fn serialize(self: LatticePage, allocator: std.mem.Allocator) ![]u8 {
        const total = 4 + 1 + 4 + 4 + 4 + E0_NODE_COUNT * 20;
        var buf = try allocator.alloc(u8, total);
        var pos: usize = 0;

        @memcpy(buf[pos..][0..4], &VFS_MAGIC);
        pos += 4;
        buf[pos] = self.key.level;
        pos += 1;
        std.mem.writeInt(u32, buf[pos..][0..4], self.key.bx, .little);
        pos += 4;
        std.mem.writeInt(u32, buf[pos..][0..4], self.key.by, .little);
        pos += 4;
        std.mem.writeInt(u32, buf[pos..][0..4], self.key.bz, .little);
        pos += 4;

        for (self.nodes) |node| {
            std.mem.writeInt(u32, buf[pos..][0..4], node.x, .little);
            pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], node.y, .little);
            pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], node.z, .little);
            pos += 4;
            std.mem.writeInt(i64, buf[pos..][0..8], node.activation, .little);
            pos += 8;
        }

        return buf;
    }

    /// Deserialize a page from VFS bytes.
    pub fn deserialize(data: []const u8, now_ms: u64) !LatticePage {
        if (data.len < 4 + 1 + 4 + 4 + 4) return error.VFSTruncatedHeader;
        if (!std.mem.eql(u8, data[0..4], &VFS_MAGIC)) return error.VFSBadMagic;

        var pos: usize = 4;
        const level = data[pos];
        pos += 1;
        const bx = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const by = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const bz = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var page = LatticePage.init(.{ .level = level, .bx = bx, .by = by, .bz = bz }, now_ms);

        const node_bytes = E0_NODE_COUNT * 20;
        if (data.len < pos + node_bytes) return error.VFSTruncatedNodes;

        for (0..E0_NODE_COUNT) |i| {
            const off = pos + i * 20;
            page.nodes[i] = .{
                .x = std.mem.readInt(u32, data[off..][0..4], .little),
                .y = std.mem.readInt(u32, data[off + 4 ..][0..4], .little),
                .z = std.mem.readInt(u32, data[off + 8 ..][0..4], .little),
                .activation = std.mem.readInt(i64, data[off + 12 ..][0..8], .little),
            };
        }

        return page;
    }
};

// =============================================================================
// VFSCache — LRU cache for lattice pages
// =============================================================================

pub const VFSCache = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    entries: std.AutoHashMap(u64, LatticePage),
    /// Counter for LRU eviction — incremented on each access.
    clock: u64,

    // --- K3-inspired enhancements ---

    /// Pinned page hashes — never evicted while set.
    pinned: std.AutoHashMap(u64, void),

    /// Request histogram: page hash → request count.
    /// Used to identify hot pages for pinning, like k3_cache.hist.
    histogram: std.AutoHashMap(u64, u64),

    /// Access trace: sequence of page hashes in request order.
    /// Like k3_cache.trace, enables offline capacity simulation.
    trace: std.ArrayList(u64),
    trace_enabled: bool = false,

    // Stats (like k3_cache: hits, misses, evictions, prefetch_reads)
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    prefetch_reads: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) VFSCache {
        return .{
            .allocator = allocator,
            .capacity = capacity,
            .entries = std.AutoHashMap(u64, LatticePage).init(allocator),
            .clock = 0,
            .pinned = std.AutoHashMap(u64, void).init(allocator),
            .histogram = std.AutoHashMap(u64, u64).init(allocator),
            .trace = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *VFSCache) void {
        self.entries.deinit();
        self.pinned.deinit();
        self.histogram.deinit();
        self.trace.deinit();
    }

    /// Record a page request in histogram and trace.
    fn recordRequest(self: *VFSCache, h: u64) void {
        // Histogram
        const entry = self.histogram.getOrPut(h) catch return;
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;

        // Trace
        if (self.trace_enabled) {
            self.trace.append(h) catch {};
        }
    }

    /// Get a page from cache by key. Returns null if not present.
    pub fn get(self: *VFSCache, key: PageKey, now_ms: u64) ?*LatticePage {
        const h = key.hash();
        self.recordRequest(h);

        if (self.entries.getPtr(h)) |page| {
            page.last_access_ms = now_ms;
            self.clock +%= 1;
            self.hits += 1;
            return page;
        }
        self.misses += 1;
        return null;
    }

    /// Put a page into cache, evicting LRU page if at capacity.
    /// Skips eviction of pinned pages.
    pub fn put(self: *VFSCache, page: LatticePage) !void {
        if (self.entries.count() >= self.capacity) {
            try self.evictLRU();
        }
        const h = page.key.hash();
        try self.entries.put(h, page);
    }

    /// Prefetch: load a page into cache without recording a hit.
    /// Like k3_cache_prefetch — warms cache so subsequent get() finds it.
    pub fn prefetch(self: *VFSCache, page: LatticePage) !void {
        const h = page.key.hash();
        if (self.entries.contains(h)) return; // Already cached

        if (self.entries.count() >= self.capacity) {
            try self.evictLRU();
        }
        try self.entries.put(h, page);
        self.prefetch_reads += 1;
    }

    /// Pin a page so it is never evicted. Like k3_cache_pin.
    /// Returns true if the page was resident.
    pub fn pin(self: *VFSCache, key: PageKey) bool {
        const h = key.hash();
        if (!self.entries.contains(h)) return false;
        self.pinned.put(h, {}) catch return false;
        return true;
    }

    /// Unpin a page, allowing eviction. Like k3_cache_pin with pin=0.
    pub fn unpin(self: *VFSCache, key: PageKey) void {
        const h = key.hash();
        _ = self.pinned.remove(h);
    }

    /// Check if a page is pinned.
    pub fn isPinned(self: *const VFSCache, key: PageKey) bool {
        return self.pinned.contains(key.hash());
    }

    /// Remove and return the least recently accessed page.
    /// Skips pinned pages during eviction.
    fn evictLRU(self: *VFSCache) !void {
        var min_access: u64 = std.math.maxInt(u64);
        var min_key: u64 = 0;
        var found = false;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            // Skip pinned pages
            if (self.pinned.contains(entry.key_ptr.*)) continue;

            if (entry.value_ptr.last_access_ms < min_access) {
                min_access = entry.value_ptr.last_access_ms;
                min_key = entry.key_ptr.*;
                found = true;
            }
        }

        if (found) {
            _ = self.entries.remove(min_key);
            self.evictions += 1;
        } else if (self.entries.count() > 0) {
            // All pages pinned — force evict the LRU even if pinned
            var it2 = self.entries.iterator();
            while (it2.next()) |entry| {
                if (entry.value_ptr.last_access_ms < min_access) {
                    min_access = entry.value_ptr.last_access_ms;
                    min_key = entry.key_ptr.*;
                    found = true;
                }
            }
            if (found) {
                _ = self.entries.remove(min_key);
                _ = self.pinned.remove(min_key);
                self.evictions += 1;
            }
        }
    }

    /// Number of pages currently cached.
    pub fn count(self: *const VFSCache) usize {
        return self.entries.count();
    }

    /// Number of pinned pages.
    pub fn pinnedCount(self: *const VFSCache) usize {
        return self.pinned.count();
    }

    /// Check if cache is at capacity.
    pub fn isFull(self: *const VFSCache) bool {
        return self.entries.count() >= self.capacity;
    }

    /// Clear all cached pages (and pins).
    pub fn clear(self: *VFSCache) void {
        self.entries.clearRetainingCapacity();
        self.pinned.clearRetainingCapacity();
    }

    /// Reset all stats to zero.
    pub fn resetStats(self: *VFSCache) void {
        self.hits = 0;
        self.misses = 0;
        self.evictions = 0;
        self.prefetch_reads = 0;
    }

    /// Effective hit rate: (hits - prefetch_reads) / requests.
    /// Like k3_cache: prefetch_reads counted separately so hit rate isn't inflated.
    pub fn effectiveHitRate(self: *const VFSCache) f64 {
        const total_requests = self.hits + self.misses;
        if (total_requests == 0) return 0.0;
        const effective_hits = if (self.hits > self.prefetch_reads) self.hits - self.prefetch_reads else 0;
        return @as(f64, @floatFromInt(effective_hits)) / @as(f64, @floatFromInt(total_requests));
    }

    /// Get the request count for a specific page from the histogram.
    pub fn requestCount(self: *const VFSCache, key: PageKey) u64 {
        return self.histogram.get(key.hash()) orelse 0;
    }

    /// A hot page entry from the request histogram.
    pub const HotPage = struct { hash: u64, count: u64 };

    /// Find the top-N hottest pages by request count.
    /// Returns an array of HotPage sorted by count descending.
    pub fn hotPages(self: *VFSCache, n: usize) ![]HotPage {
        const result = try self.allocator.alloc(HotPage, n);
        var filled: usize = 0;

        var it = self.histogram.iterator();
        while (it.next()) |entry| {
            // Insertion sort into result
            var i: usize = 0;
            while (i < filled and result[i].count >= entry.value_ptr.*) : (i += 1) {}
            if (i < n) {
                // Shift down
                var j: usize = filled;
                while (j > i) : (j -= 1) {
                    if (j < n) result[j] = result[j - 1];
                }
                result[i] = .{ .hash = entry.key_ptr.*, .count = entry.value_ptr.* };
                if (filled < n) filled += 1;
            }
        }

        return result[0..filled];
    }

    /// Enable or disable access trace recording.
    pub fn setTraceEnabled(self: *VFSCache, enabled: bool) void {
        self.trace_enabled = enabled;
    }

    /// Get the access trace (page hashes in request order).
    pub fn getTrace(self: *const VFSCache) []const u64 {
        return self.trace.items;
    }

    /// Clear the access trace.
    pub fn clearTrace(self: *VFSCache) void {
        self.trace.clearRetainingCapacity();
    }

    /// Cache statistics summary.
    pub fn stats(self: *const VFSCache) struct {
        hits: u64,
        misses: u64,
        evictions: u64,
        prefetch_reads: u64,
        effective_hit_rate: f64,
        pinned: usize,
        unique_pages: usize,
    } {
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .prefetch_reads = self.prefetch_reads,
            .effective_hit_rate = self.effectiveHitRate(),
            .pinned = self.pinned.count(),
            .unique_pages = self.histogram.count(),
        };
    }
};

// =============================================================================
// VFSLatticeStore — in-memory VFS backing store (zero-disk)
// =============================================================================

pub const StoredPage = struct {
    compressed: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: StoredPage) void {
        self.allocator.free(self.compressed);
    }
};

pub const VFSLatticeStore = struct {
    allocator: std.mem.Allocator,
    pages: std.AutoHashMap(u64, StoredPage),
    /// Total bytes stored (compressed).
    total_stored_bytes: usize = 0,
    /// Total bytes that would be needed uncompressed.
    total_uncompressed_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) VFSLatticeStore {
        return .{
            .allocator = allocator,
            .pages = std.AutoHashMap(u64, StoredPage).init(allocator),
        };
    }

    pub fn deinit(self: *VFSLatticeStore) void {
        var it = self.pages.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pages.deinit();
    }

    /// Store a page (serialized → gzip compressed).
    pub fn store(self: *VFSLatticeStore, key: PageKey, page: LatticePage) !void {
        const h = key.hash();

        // Free existing page if present
        if (self.pages.fetchRemove(h)) |kv| {
            kv.value.deinit();
        }

        const serialized = try page.serialize(self.allocator);
        defer self.allocator.free(serialized);

        // Gzip compress the serialized page
        const compressed = try gzipCompress(self.allocator, serialized);
        errdefer self.allocator.free(compressed);

        try self.pages.put(h, .{
            .compressed = compressed,
            .allocator = self.allocator,
        });

        self.total_stored_bytes += compressed.len;
        self.total_uncompressed_bytes += serialized.len;
    }

    /// Retrieve a page (gzip decompress → deserialize).
    pub fn retrieve(self: *VFSLatticeStore, key: PageKey, now_ms: u64) !?LatticePage {
        const h = key.hash();
        const stored = self.pages.get(h) orelse return null;

        const decompressed = try gzipDecompress(self.allocator, stored.compressed);
        defer self.allocator.free(decompressed);

        return try LatticePage.deserialize(decompressed, now_ms);
    }

    /// Check if a page exists in the store.
    pub fn has(self: *const VFSLatticeStore, key: PageKey) bool {
        return self.pages.contains(key.hash());
    }

    /// Remove a page from the store.
    pub fn remove(self: *VFSLatticeStore, key: PageKey) bool {
        const h = key.hash();
        if (self.pages.fetchRemove(h)) |kv| {
            kv.value.deinit();
            return true;
        }
        return false;
    }

    /// Number of pages in the store.
    pub fn pageCount(self: *const VFSLatticeStore) usize {
        return self.pages.count();
    }

    /// Compression ratio achieved (uncompressed / stored).
    pub fn compressionRatio(self: *const VFSLatticeStore) f64 {
        if (self.total_stored_bytes == 0) return 1.0;
        return @as(f64, @floatFromInt(self.total_uncompressed_bytes)) /
            @as(f64, @floatFromInt(self.total_stored_bytes));
    }
};

// =============================================================================
// VFSBridge — main bridge connecting VFS to renderer and mesh
// =============================================================================

pub const VFSBridge = struct {
    allocator: std.mem.Allocator,
    store: VFSLatticeStore,
    cache: VFSCache,
    /// Current simulation time (ms).
    clock_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) VFSBridge {
        return .{
            .allocator = allocator,
            .store = VFSLatticeStore.init(allocator),
            .cache = VFSCache.init(allocator, DEFAULT_CACHE_CAPACITY),
        };
    }

    pub fn deinit(self: *VFSBridge) void {
        self.store.deinit();
        self.cache.deinit();
    }

    /// Advance the internal clock.
    pub fn tick(self: *VFSBridge, dt_ms: u64) void {
        self.clock_ms +%= dt_ms;
    }

    /// Page in a lattice region from VFS store to cache.
    /// Returns a pointer to the cached page, or error if not in store.
    pub fn pageIn(self: *VFSBridge, key: PageKey) !*LatticePage {
        // Check cache first
        if (self.cache.get(key, self.clock_ms)) |page| {
            return page;
        }

        // Page in from store
        const page = try self.store.retrieve(key, self.clock_ms) orelse return error.VFSPageNotFound;

        // Insert into cache
        try self.cache.put(page);
        return self.cache.get(key, self.clock_ms).?;
    }

    /// Page out a dirty page from cache to VFS store.
    pub fn pageOut(self: *VFSBridge, key: PageKey) !void {
        const h = key.hash();
        const page = self.cache.entries.get(h) orelse return error.VFSPageNotCached;
        if (!page.dirty) return; // No changes to write

        try self.store.store(key, page);
        // Mark as clean
        if (self.cache.entries.getPtr(h)) |p| {
            p.dirty = false;
        }
    }

    /// Write a page directly to the VFS store (bypass cache).
    pub fn writeDirect(self: *VFSBridge, key: PageKey, page: LatticePage) !void {
        try self.store.store(key, page);
    }

    /// Read a page directly from the VFS store (bypass cache).
    pub fn readDirect(self: *VFSBridge, key: PageKey) !?LatticePage {
        return try self.store.retrieve(key, self.clock_ms);
    }

    /// Mark a cached page as dirty (modified).
    pub fn markDirty(self: *VFSBridge, key: PageKey) void {
        const h = key.hash();
        if (self.cache.entries.getPtr(h)) |page| {
            page.dirty = true;
        }
    }

    /// Flush all dirty pages to the VFS store.
    pub fn flush(self: *VFSBridge) !void {
        var it = self.cache.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.dirty) {
                try self.store.store(entry.value_ptr.key, entry.value_ptr.*);
                entry.value_ptr.dirty = false;
            }
        }
    }

    /// Convert cached page to E0SeedBuffer format for render.zig integration.
    /// The caller must handle the conversion since render.zig types are separate.
    pub fn pageToE0Nodes(self: *VFSBridge, key: PageKey) ![E0_NODE_COUNT]E0Node {
        const page = try self.pageIn(key);
        var result: [E0_NODE_COUNT]E0Node = undefined;
        for (0..E0_NODE_COUNT) |i| {
            result[i] = page.nodes[i];
        }
        return result;
    }

    /// Convert a SharedFace's 225 f64 states to a partial page and store it.
    /// This bridges mesh.zig SharedFace sync into VFS persistence.
    pub fn storeSharedFaceStates(
        self: *VFSBridge,
        key: PageKey,
        local_states: []const f64,
        remote_states: []const f64,
    ) !void {
        var page = LatticePage.init(key, self.clock_ms);
        // Map 225 face states into E0 node activations.
        // 225 = 15×15 face cells. Map each to an E0 node by index.
        const n = @min(local_states.len, E0_NODE_COUNT);
        for (0..n) |i| {
            // Position nodes along the face plane (y=0 for +x face)
            const fx: u32 = @intCast(i % 15);
            const fz: u32 = @intCast(i / 15);
            page.nodes[i] = .{
                .x = fx,
                .y = 0,
                .z = fz,
                .activation = @as(i64, @intFromFloat(local_states[i] * @as(f64, @floatFromInt(fp.ONE)))),
            };
        }
        // Store remote states in remaining nodes (if any)
        const remaining = E0_NODE_COUNT - n;
        const rn = @min(remote_states.len, remaining);
        for (0..rn) |i| {
            const fx: u32 = @intCast(i % 15);
            const fz: u32 = @intCast(i / 15);
            page.nodes[n + i] = .{
                .x = fx,
                .y = 1,
                .z = fz,
                .activation = @as(i64, @intFromFloat(remote_states[i] * @as(f64, @floatFromInt(fp.ONE)))),
            };
        }
        page.dirty = true;
        try self.cache.put(page);
        try self.pageOut(key);
    }

    /// Retrieve SharedFace states from a VFS page.
    /// Returns local and remote state arrays (225 each).
    pub fn retrieveSharedFaceStates(
        self: *VFSBridge,
        key: PageKey,
    ) !struct { local: [225]f64, remote: [225]f64 } {
        const page = try self.pageIn(key);
        var local: [225]f64 = [_]f64{0} ** 225;
        var remote: [225]f64 = [_]f64{0} ** 225;

        for (0..225) |i| {
            if (i < E0_NODE_COUNT and page.nodes[i].y == 0) {
                local[i] = @as(f64, @floatFromInt(page.nodes[i].activation)) / @as(f64, @floatFromInt(fp.ONE));
            }
        }
        for (0..225) |i| {
            const idx = 225 + i;
            if (idx < E0_NODE_COUNT and page.nodes[idx].y == 1) {
                remote[i] = @as(f64, @floatFromInt(page.nodes[idx].activation)) / @as(f64, @floatFromInt(fp.ONE));
            }
        }

        return .{ .local = local, .remote = remote };
    }

    /// Prefetch a page from VFS store into cache without a formal get().
    /// Like k3_trunk_prefetch — warms the cache so the next pageIn() is a hit.
    pub fn prefetch(self: *VFSBridge, key: PageKey) !void {
        // Already cached? No-op.
        if (self.cache.get(key, self.clock_ms) != null) return;

        // Page in from store, insert via prefetch (doesn't count as hit)
        const page = try self.store.retrieve(key, self.clock_ms) orelse return error.VFSPageNotFound;
        try self.cache.prefetch(page);
    }

    /// Pin a cached page so it is never evicted.
    /// Returns true if the page was resident.
    pub fn pinPage(self: *VFSBridge, key: PageKey) bool {
        return self.cache.pin(key);
    }

    /// Unpin a cached page, allowing eviction.
    pub fn unpinPage(self: *VFSBridge, key: PageKey) void {
        self.cache.unpin(key);
    }

    /// Pin the top-N hottest pages based on request histogram.
    /// Like k3_cache_pin for hot expert sets.
    pub fn pinHotPages(self: *VFSBridge, n: usize) !usize {
        const hot = try self.cache.hotPages(n);
        defer self.allocator.free(hot);

        var pinned_count: usize = 0;
        for (hot) |entry| {
            // Find the page key from the hash by checking cache entries
            var it = self.cache.entries.iterator();
            while (it.next()) |cache_entry| {
                if (cache_entry.key_ptr.* == entry.hash) {
                    _ = self.cache.entries.getPtr(entry.hash) orelse continue;
                    self.cache.pinned.put(entry.hash, {}) catch continue;
                    pinned_count += 1;
                    break;
                }
            }
        }
        return pinned_count;
    }

    /// Enable or disable access trace recording.
    pub fn setTraceEnabled(self: *VFSBridge, enabled: bool) void {
        self.cache.setTraceEnabled(enabled);
    }

    /// Get the access trace (page hashes in request order).
    pub fn getTrace(self: *const VFSBridge) []const u64 {
        return self.cache.getTrace();
    }

    /// Reset cache statistics.
    pub fn resetCacheStats(self: *VFSBridge) void {
        self.cache.resetStats();
    }

    /// Cache statistics with K3-inspired metrics.
    pub fn cacheStats(self: *const VFSBridge) struct {
        cached: usize,
        stored: usize,
        cache_capacity: usize,
        compression_ratio: f64,
        stored_bytes: usize,
        hits: u64,
        misses: u64,
        evictions: u64,
        prefetch_reads: u64,
        effective_hit_rate: f64,
        pinned: usize,
        unique_pages: usize,
    } {
        const cs = self.cache.stats();
        return .{
            .cached = self.cache.count(),
            .stored = self.store.pageCount(),
            .cache_capacity = self.cache.capacity,
            .compression_ratio = self.store.compressionRatio(),
            .stored_bytes = self.store.total_stored_bytes,
            .hits = cs.hits,
            .misses = cs.misses,
            .evictions = cs.evictions,
            .prefetch_reads = cs.prefetch_reads,
            .effective_hit_rate = cs.effective_hit_rate,
            .pinned = cs.pinned,
            .unique_pages = cs.unique_pages,
        };
    }

    /// Generate a page key from absolute lattice coordinates.
    pub fn keyForCoords(level: u8, x: u32, y: u32, z: u32) PageKey {
        return .{
            .level = level,
            .bx = x / BLOCK_EDGE,
            .by = y / BLOCK_EDGE,
            .bz = z / BLOCK_EDGE,
        };
    }

    /// Populate a page with E0 node data from a flat activation array.
    /// Each E0 node at (x,y,z) where (x+y+z)%3==0 gets an activation.
    pub fn pageFromActivations(
        key: PageKey,
        activations: []const i64,
        now_ms: u64,
    ) LatticePage {
        var page = LatticePage.init(key, now_ms);
        var idx: usize = 0;
        var x: u32 = 0;
        while (x < 15 and idx < E0_NODE_COUNT) : (x += 1) {
            var y: u32 = 0;
            while (y < 15 and idx < E0_NODE_COUNT) : (y += 1) {
                var z: u32 = 0;
                while (z < 15 and idx < E0_NODE_COUNT) : (z += 1) {
                    if ((x + y + z) % 3 != 0) continue;
                    const act = if (idx < activations.len) activations[idx] else 0;
                    page.nodes[idx] = .{
                        .x = x,
                        .y = y,
                        .z = z,
                        .activation = act,
                    };
                    idx += 1;
                }
            }
        }
        return page;
    }

    /// Extract activations from a page as a flat i64 array.
    pub fn pageToActivations(self: *VFSBridge, key: PageKey, out: []i64) !void {
        const page = try self.pageIn(key);
        const n = @min(out.len, E0_NODE_COUNT);
        for (0..n) |i| {
            out[i] = page.nodes[i].activation;
        }
    }

    // =========================================================================
    // Agent State Persistence (Gap 4: VFS ↔ Agent integration)
    // =========================================================================

    /// Special level used for agent state pages (avoids collision with lattice levels 0-7).
    pub const AGENT_STATE_LEVEL: u8 = 255;

    /// Saves agent state to VFS. Stores 7 channel pages + 1 metadata page.
    /// Agent state = [421][7]i64 activations + cycle + temperature + base_temp + output_tokens.
    /// i64 activations are split into low32 (x) and high32 (y) of E0Node for bit-exact storage.
    pub fn saveAgentState(
        self: *VFSBridge,
        activations: []const [7]i64,
        cycle: u64,
        temperature: i64,
        base_temp: i64,
        output_tokens: []const u32,
    ) !void {
        // Save 7 channel pages
        for (0..7) |ch| {
            const key = PageKey{
                .level = AGENT_STATE_LEVEL,
                .bx = @intCast(ch),
                .by = 0,
                .bz = 0,
            };
            var page = LatticePage.init(key, self.clock_ms);
            for (0..E0_NODE_COUNT) |i| {
                const val: i64 = activations[i][ch];
                const val_bits: u64 = @as(u64, @bitCast(val));
                const low: u32 = @intCast(val_bits & 0xFFFFFFFF);
                const high: u32 = @intCast(val_bits >> 32);
                page.nodes[i] = .{
                    .x = low,
                    .y = high,
                    .z = @intCast(i % 15),
                    .activation = 0,
                };
            }
            try self.store.store(key, page);
        }

        // Save metadata page (bx=7)
        const meta_key = PageKey{
            .level = AGENT_STATE_LEVEL,
            .bx = 7,
            .by = 0,
            .bz = 0,
        };
        var meta_page = LatticePage.init(meta_key, self.clock_ms);
        // Encode cycle into first 2 nodes (x=low32, y=high32)
        const cycle_low: u32 = @intCast(cycle & 0xFFFFFFFF);
        const cycle_high: u32 = @intCast(cycle >> 32);
        meta_page.nodes[0] = .{ .x = cycle_low, .y = cycle_high, .z = 0, .activation = 0 };
        // Encode temperature and base_temp as i64 split across x,y of nodes 1 and 2
        const temp_bits: u64 = @as(u64, @bitCast(temperature));
        const temp_low: u32 = @intCast(temp_bits & 0xFFFFFFFF);
        const temp_high: u32 = @intCast(temp_bits >> 32);
        meta_page.nodes[1] = .{ .x = temp_low, .y = temp_high, .z = 0, .activation = 0 };
        const bt_bits: u64 = @as(u64, @bitCast(base_temp));
        const bt_low: u32 = @intCast(bt_bits & 0xFFFFFFFF);
        const bt_high: u32 = @intCast(bt_bits >> 32);
        meta_page.nodes[2] = .{ .x = bt_low, .y = bt_high, .z = 0, .activation = 0 };
        // Encode output_tokens count in node 3, and tokens in subsequent nodes
        const token_count: u32 = @intCast(@min(output_tokens.len, E0_NODE_COUNT - 4));
        meta_page.nodes[3] = .{ .x = token_count, .y = 0, .z = 0, .activation = 0 };
        for (0..token_count) |i| {
            meta_page.nodes[4 + i] = .{
                .x = output_tokens[i],
                .y = 0,
                .z = 0,
                .activation = 0,
            };
        }
        try self.store.store(meta_key, meta_page);
    }

    /// Loads agent state from VFS. Returns the restored state components.
    /// Returns null if no saved state exists.
    pub fn loadAgentState(
        self: *VFSBridge,
        out_activations: *[E0_NODE_COUNT][7]i64,
    ) !?struct {
        cycle: u64,
        temperature: i64,
        base_temp: i64,
        output_tokens: []u32,
    } {
        // Check if metadata page exists
        const meta_key = PageKey{
            .level = AGENT_STATE_LEVEL,
            .bx = 7,
            .by = 0,
            .bz = 0,
        };
        const meta_page = try self.store.retrieve(meta_key, self.clock_ms) orelse return null;

        // Load 7 channel pages
        for (0..7) |ch| {
            const key = PageKey{
                .level = AGENT_STATE_LEVEL,
                .bx = @intCast(ch),
                .by = 0,
                .bz = 0,
            };
            const page = try self.store.retrieve(key, self.clock_ms) orelse return null;
            for (0..E0_NODE_COUNT) |i| {
                const low: u64 = @as(u64, page.nodes[i].x);
                const high: u64 = @as(u64, page.nodes[i].y);
                out_activations[i][ch] = @bitCast(low | (high << 32));
            }
        }

        // Decode metadata
        const cycle: u64 = @as(u64, meta_page.nodes[0].x) | (@as(u64, meta_page.nodes[0].y) << 32);
        const temp_bits: u64 = @as(u64, meta_page.nodes[1].x) | (@as(u64, meta_page.nodes[1].y) << 32);
        const temperature: i64 = @bitCast(temp_bits);
        const bt_bits: u64 = @as(u64, meta_page.nodes[2].x) | (@as(u64, meta_page.nodes[2].y) << 32);
        const base_temp: i64 = @bitCast(bt_bits);
        const token_count: usize = meta_page.nodes[3].x;

        // Allocate and fill output tokens
        const tokens = try self.allocator.alloc(u32, token_count);
        for (0..token_count) |i| {
            if (4 + i < E0_NODE_COUNT) {
                tokens[i] = meta_page.nodes[4 + i].x;
            } else {
                tokens[i] = 0;
            }
        }

        return .{
            .cycle = cycle,
            .temperature = temperature,
            .base_temp = base_temp,
            .output_tokens = tokens,
        };
    }

    /// Check if a saved agent state exists in VFS.
    pub fn hasAgentState(self: *const VFSBridge) bool {
        const meta_key = PageKey{
            .level = AGENT_STATE_LEVEL,
            .bx = 7,
            .by = 0,
            .bz = 0,
        };
        return self.store.has(meta_key);
    }

    /// Clear saved agent state from VFS.
    pub fn clearAgentState(self: *VFSBridge) void {
        for (0..8) |i| {
            const key = PageKey{
                .level = AGENT_STATE_LEVEL,
                .bx = @intCast(i),
                .by = 0,
                .bz = 0,
            };
            _ = self.store.remove(key);
        }
    }
};

// =============================================================================
// Gzip helpers (self-contained using std.compress.gzip)
// =============================================================================

fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var compressor = try std.compress.gzip.compressor(out.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();

    return try out.toOwnedSlice();
}

fn gzipDecompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var in_stream = std.io.fixedBufferStream(data);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try std.compress.gzip.decompress(in_stream.reader(), out.writer());

    return try out.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "VFS: page serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    var page = LatticePage.init(.{ .level = 5, .bx = 1, .by = 2, .bz = 3 }, 1000);
    for (0..E0_NODE_COUNT) |i| {
        page.nodes[i] = .{
            .x = @intCast(i % 15),
            .y = @intCast((i / 15) % 15),
            .z = @intCast((i / 225) % 15),
            .activation = fp.fromInt(@as(i64, @intCast(i))),
        };
    }

    const serialized = try page.serialize(allocator);
    defer allocator.free(serialized);

    const restored = try LatticePage.deserialize(serialized, 2000);
    try std.testing.expectEqual(page.key.level, restored.key.level);
    try std.testing.expectEqual(page.key.bx, restored.key.bx);
    try std.testing.expectEqual(page.key.by, restored.key.by);
    try std.testing.expectEqual(page.key.bz, restored.key.bz);

    for (0..E0_NODE_COUNT) |i| {
        try std.testing.expectEqual(page.nodes[i].x, restored.nodes[i].x);
        try std.testing.expectEqual(page.nodes[i].y, restored.nodes[i].y);
        try std.testing.expectEqual(page.nodes[i].z, restored.nodes[i].z);
        try std.testing.expectEqual(page.nodes[i].activation, restored.nodes[i].activation);
    }
}

test "VFS: page key hash uniqueness" {
    const k1 = PageKey.init(5, 1, 2, 3);
    const k2 = PageKey.init(5, 1, 2, 4);
    const k3 = PageKey.init(5, 1, 2, 3);

    try std.testing.expect(k1.hash() != k2.hash());
    try std.testing.expect(k1.hash() == k3.hash());
    try std.testing.expect(PageKey.eql(k1, k3));
    try std.testing.expect(!PageKey.eql(k1, k2));
}

test "VFS: cache put/get/evict" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 3);
    defer cache.deinit();

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const page = LatticePage.init(.{ .level = 5, .bx = i, .by = 0, .bz = 0 }, @as(u64, i) * 100);
        try cache.put(page);
    }
    try std.testing.expectEqual(@as(usize, 3), cache.count());

    // Access page 0 to make it more recently used
    _ = cache.get(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 500);

    // Add a 4th page — should evict the LRU (page 1, last accessed at 100)
    const page4 = LatticePage.init(.{ .level = 5, .bx = 3, .by = 0, .bz = 0 }, 600);
    try cache.put(page4);
    try std.testing.expectEqual(@as(usize, 3), cache.count());

    // Page 0 should still be cached (was accessed at 500)
    try std.testing.expect(cache.get(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 700) != null);
    // Page 1 should have been evicted
    try std.testing.expect(cache.get(.{ .level = 5, .bx = 1, .by = 0, .bz = 0 }, 700) == null);
}

test "VFS: store/retrieve round-trip with compression" {
    const allocator = std.testing.allocator;
    var store = VFSLatticeStore.init(allocator);
    defer store.deinit();

    var page = LatticePage.init(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 1000);
    for (0..E0_NODE_COUNT) |i| {
        page.nodes[i] = .{
            .x = @intCast(i % 15),
            .y = @intCast((i / 15) % 15),
            .z = @intCast((i / 225) % 15),
            .activation = fp.fromInt(@as(i64, @intCast(i))),
        };
    }

    try store.store(page.key, page);
    try std.testing.expect(store.has(page.key));

    const restored = try store.retrieve(page.key, 2000);
    try std.testing.expect(restored != null);

    for (0..E0_NODE_COUNT) |i| {
        try std.testing.expectEqual(page.nodes[i].x, restored.?.nodes[i].x);
        try std.testing.expectEqual(page.nodes[i].y, restored.?.nodes[i].y);
        try std.testing.expectEqual(page.nodes[i].z, restored.?.nodes[i].z);
        try std.testing.expectEqual(page.nodes[i].activation, restored.?.nodes[i].activation);
    }
}

test "VFS: compression ratio > 1 for redundant data" {
    const allocator = std.testing.allocator;
    var store = VFSLatticeStore.init(allocator);
    defer store.deinit();

    // Page with all-zero activations — highly compressible
    const page = LatticePage.init(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 1000);
    // All nodes zero (default) — should compress well
    try store.store(page.key, page);

    const ratio = store.compressionRatio();
    try std.testing.expect(ratio > 1.0);
}

test "VFS: bridge page-in/page-out" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const key = PageKey{ .level = 5, .bx = 1, .by = 1, .bz = 1 };
    var page = LatticePage.init(key, 0);
    page.nodes[0].activation = fp.div(fp.fromInt(3), fp.fromInt(4));
    page.nodes[100].activation = fp.div(fp.fromInt(1), fp.fromInt(2));
    page.nodes[420].activation = fp.ONE;

    // Write directly to store
    try bridge.writeDirect(key, page);

    // Page in from store to cache
    const cached = try bridge.pageIn(key);
    try std.testing.expectEqual(fp.div(fp.fromInt(3), fp.fromInt(4)), cached.nodes[0].activation);
    try std.testing.expectEqual(fp.div(fp.fromInt(1), fp.fromInt(2)), cached.nodes[100].activation);
    try std.testing.expectEqual(fp.ONE, cached.nodes[420].activation);

    // Modify and mark dirty
    cached.nodes[0].activation = fp.div(fp.fromInt(99), fp.fromInt(100));
    bridge.markDirty(key);

    // Page out to store
    try bridge.pageOut(key);

    // Clear cache and page in again — should get modified value
    bridge.cache.clear();
    const cached2 = try bridge.pageIn(key);
    try std.testing.expectEqual(fp.div(fp.fromInt(99), fp.fromInt(100)), cached2.nodes[0].activation);
}

test "VFS: bridge flush all dirty pages" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    // Create and cache 3 pages, mark them dirty
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const key = PageKey{ .level = 5, .bx = i, .by = 0, .bz = 0 };
        var page = LatticePage.init(key, 0);
        page.nodes[0].activation = fp.fromInt(@as(i64, @intCast(i)));
        page.dirty = true;
        try bridge.cache.put(page);
    }

    try std.testing.expectEqual(@as(usize, 3), bridge.cache.count());
    try std.testing.expectEqual(@as(usize, 0), bridge.store.pageCount());

    // Flush all dirty pages
    try bridge.flush();

    try std.testing.expectEqual(@as(usize, 3), bridge.store.pageCount());
}

test "VFS: keyForCoords block mapping" {
    const k1 = VFSBridge.keyForCoords(5, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), k1.bx);
    try std.testing.expectEqual(@as(u32, 0), k1.by);
    try std.testing.expectEqual(@as(u32, 0), k1.bz);

    const k2 = VFSBridge.keyForCoords(5, 15, 30, 45);
    try std.testing.expectEqual(@as(u32, 1), k2.bx);
    try std.testing.expectEqual(@as(u32, 2), k2.by);
    try std.testing.expectEqual(@as(u32, 3), k2.bz);

    const k3 = VFSBridge.keyForCoords(5, 14, 14, 14);
    try std.testing.expectEqual(@as(u32, 0), k3.bx);
    try std.testing.expectEqual(@as(u32, 0), k3.by);
    try std.testing.expectEqual(@as(u32, 0), k3.bz);
}

test "VFS: pageFromActivations and pageToActivations" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    var activations: [E0_NODE_COUNT]i64 = undefined;
    for (0..E0_NODE_COUNT) |i| {
        activations[i] = fp.fromInt(@as(i64, @intCast(i)));
    }

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    const page = VFSBridge.pageFromActivations(key, &activations, 0);
    try bridge.writeDirect(key, page);

    var recovered: [E0_NODE_COUNT]i64 = undefined;
    try bridge.pageToActivations(key, &recovered);

    for (0..E0_NODE_COUNT) |i| {
        try std.testing.expectEqual(activations[i], recovered[i]);
    }
}

test "VFS: SharedFace states store/retrieve" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    var local: [225]f64 = undefined;
    var remote: [225]f64 = undefined;
    for (0..225) |i| {
        local[i] = @as(f64, @floatFromInt(i)) * 0.01;
        remote[i] = @as(f64, @floatFromInt(i)) * 0.02;
    }

    try bridge.storeSharedFaceStates(key, &local, &remote);

    // Clear cache to force read from store
    bridge.cache.clear();

    const result = try bridge.retrieveSharedFaceStates(key);
    for (0..225) |i| {
        try std.testing.expectApproxEqAbs(local[i], result.local[i], 1e-4);
    }
}

test "VFS: cache stats reporting" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    // Store 2 pages
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        const key = PageKey{ .level = 5, .bx = i, .by = 0, .bz = 0 };
        const page = LatticePage.init(key, 0);
        try bridge.writeDirect(key, page);
    }

    // Page in 1 to cache
    _ = try bridge.pageIn(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 });

    const stats = bridge.cacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.cached);
    try std.testing.expectEqual(@as(usize, 2), stats.stored);
    try std.testing.expectEqual(@as(usize, DEFAULT_CACHE_CAPACITY), stats.cache_capacity);
    try std.testing.expect(stats.compression_ratio >= 1.0);
    try std.testing.expect(stats.stored_bytes > 0);
}

test "VFS: page not found error" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const result = bridge.pageIn(.{ .level = 5, .bx = 99, .by = 99, .bz = 99 });
    try std.testing.expectError(error.VFSPageNotFound, result);
}

test "VFS: cache pin prevents eviction" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 3);
    defer cache.deinit();

    // Insert 3 pages
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const page = LatticePage.init(.{ .level = 5, .bx = i, .by = 0, .bz = 0 }, @as(u64, i) * 100);
        try cache.put(page);
    }

    // Pin page 0 (oldest)
    try std.testing.expect(cache.pin(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }));
    try std.testing.expect(cache.isPinned(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }));
    try std.testing.expectEqual(@as(usize, 1), cache.pinnedCount());

    // Access page 1 to make it more recent than page 2
    _ = cache.get(.{ .level = 5, .bx = 1, .by = 0, .bz = 0 }, 500);

    // Add 4th page — should evict page 2 (LRU non-pinned), not page 0 (pinned)
    const page4 = LatticePage.init(.{ .level = 5, .bx = 3, .by = 0, .bz = 0 }, 600);
    try cache.put(page4);

    // Page 0 should still be cached (pinned)
    try std.testing.expect(cache.get(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 700) != null);
    // Page 2 should have been evicted
    try std.testing.expect(cache.get(.{ .level = 5, .bx = 2, .by = 0, .bz = 0 }, 700) == null);
}

test "VFS: cache unpin allows eviction" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 2);
    defer cache.deinit();

    const page0 = LatticePage.init(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 100);
    const page1 = LatticePage.init(.{ .level = 5, .bx = 1, .by = 0, .bz = 0 }, 200);
    try cache.put(page0);
    try cache.put(page1);

    // Pin page 0
    _ = cache.pin(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 });

    // Unpin it
    cache.unpin(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 });
    try std.testing.expect(!cache.isPinned(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }));

    // Now page 0 can be evicted
    const page2 = LatticePage.init(.{ .level = 5, .bx = 2, .by = 0, .bz = 0 }, 300);
    try cache.put(page2);
    try std.testing.expect(cache.get(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 400) == null);
}

test "VFS: cache histogram tracks request counts" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 5);
    defer cache.deinit();

    const key0 = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    const key1 = PageKey{ .level = 5, .bx = 1, .by = 0, .bz = 0 };

    // Request key0 three times, key1 once
    _ = cache.get(key0, 100);
    _ = cache.get(key0, 200);
    _ = cache.get(key0, 300);
    _ = cache.get(key1, 400);

    try std.testing.expectEqual(@as(u64, 3), cache.requestCount(key0));
    try std.testing.expectEqual(@as(u64, 1), cache.requestCount(key1));
    try std.testing.expectEqual(@as(u64, 0), cache.requestCount(.{ .level = 5, .bx = 99, .by = 0, .bz = 0 }));
}

test "VFS: cache hot pages returns sorted by count" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 10);
    defer cache.deinit();

    // Request pages with different frequencies
    _ = cache.get(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 100);
    _ = cache.get(.{ .level = 5, .bx = 1, .by = 0, .bz = 0 }, 200);
    _ = cache.get(.{ .level = 5, .bx = 1, .by = 0, .bz = 0 }, 300);
    _ = cache.get(.{ .level = 5, .bx = 2, .by = 0, .bz = 0 }, 400);
    _ = cache.get(.{ .level = 5, .bx = 2, .by = 0, .bz = 0 }, 500);
    _ = cache.get(.{ .level = 5, .bx = 2, .by = 0, .bz = 0 }, 600);

    const hot = try cache.hotPages(3);
    defer allocator.free(hot);

    try std.testing.expectEqual(@as(usize, 3), hot.len);
    // bx=2 has 3 requests, bx=1 has 2, bx=0 has 1
    try std.testing.expect(hot[0].count >= hot[1].count);
    try std.testing.expect(hot[1].count >= hot[2].count);
}

test "VFS: cache prefetch warms cache" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    var page = LatticePage.init(key, 0);
    page.nodes[0].activation = fp.fromInt(42);
    try bridge.writeDirect(key, page);

    // Prefetch into cache
    try bridge.prefetch(key);
    try std.testing.expectEqual(@as(usize, 1), bridge.cache.count());

    // Now pageIn should be a cache hit (no store access needed)
    const cached = try bridge.pageIn(key);
    try std.testing.expectEqual(fp.fromInt(42), cached.nodes[0].activation);

    // Prefetch reads should be 1, hits should be 1
    const stats = bridge.cacheStats();
    try std.testing.expectEqual(@as(u64, 1), stats.prefetch_reads);
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
}

test "VFS: cache effective hit rate excludes prefetch" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    const page = LatticePage.init(key, 0);
    try bridge.writeDirect(key, page);

    // Prefetch (counts as prefetch_read, not hit)
    try bridge.prefetch(key);

    // pageIn — should be a cache hit
    _ = try bridge.pageIn(key);

    const stats = bridge.cacheStats();
    // Effective hit rate = (hits - prefetch_reads) / (hits + misses) = (1-1)/(1+0) = 0
    // The prefetch warmed the cache, so the hit is "fake"
    try std.testing.expect(stats.effective_hit_rate < 1.0);
}

test "VFS: cache trace records access order" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 5);
    defer cache.deinit();

    cache.setTraceEnabled(true);

    const key0 = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    const key1 = PageKey{ .level = 5, .bx = 1, .by = 0, .bz = 0 };
    const key2 = PageKey{ .level = 5, .bx = 2, .by = 0, .bz = 0 };

    _ = cache.get(key0, 100);
    _ = cache.get(key1, 200);
    _ = cache.get(key2, 300);
    _ = cache.get(key0, 400);

    const trace = cache.getTrace();
    try std.testing.expectEqual(@as(usize, 4), trace.len);
    try std.testing.expectEqual(key0.hash(), trace[0]);
    try std.testing.expectEqual(key1.hash(), trace[1]);
    try std.testing.expectEqual(key2.hash(), trace[2]);
    try std.testing.expectEqual(key0.hash(), trace[3]);
}

test "VFS: bridge pin and unpin page" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    const page = LatticePage.init(key, 0);
    try bridge.writeDirect(key, page);
    _ = try bridge.pageIn(key);

    // Pin
    try std.testing.expect(bridge.pinPage(key));
    try std.testing.expect(bridge.cache.isPinned(key));

    // Unpin
    bridge.unpinPage(key);
    try std.testing.expect(!bridge.cache.isPinned(key));
}

test "VFS: cache reset stats" {
    const allocator = std.testing.allocator;
    var cache = VFSCache.init(allocator, 5);
    defer cache.deinit();

    _ = cache.get(.{ .level = 5, .bx = 0, .by = 0, .bz = 0 }, 100);
    _ = cache.get(.{ .level = 5, .bx = 1, .by = 0, .bz = 0 }, 200);

    try std.testing.expectEqual(@as(u64, 2), cache.misses);

    cache.resetStats();
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
}

test "VFS: store remove page" {
    const allocator = std.testing.allocator;
    var store = VFSLatticeStore.init(allocator);
    defer store.deinit();

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    const page = LatticePage.init(key, 0);
    try store.store(key, page);

    try std.testing.expect(store.has(key));
    try std.testing.expect(store.remove(key));
    try std.testing.expect(!store.has(key));
    try std.testing.expect(!store.remove(key));
}

test "VFS: concurrent page-in simulation (two peers)" {
    const allocator = std.testing.allocator;

    // Peer A's bridge
    var bridge_a = VFSBridge.init(allocator);
    defer bridge_a.deinit();

    // Peer B's bridge
    var bridge_b = VFSBridge.init(allocator);
    defer bridge_b.deinit();

    const key = PageKey{ .level = 5, .bx = 5, .by = 5, .bz = 5 };

    // Peer A writes a page
    var page = LatticePage.init(key, 0);
    page.nodes[0].activation = fp.div(fp.fromInt(42), fp.fromInt(100));
    page.nodes[200].activation = fp.div(fp.fromInt(84), fp.fromInt(100));
    try bridge_a.writeDirect(key, page);

    // Simulate transfer: peer B reads from peer A's store via readDirect
    const page_data = try bridge_a.readDirect(key);
    try std.testing.expect(page_data != null);
    try bridge_b.writeDirect(key, page_data.?);

    // Both peers should have the same data
    const a_page = try bridge_a.pageIn(key);
    const b_page = try bridge_b.pageIn(key);

    try std.testing.expectEqual(a_page.nodes[0].activation, b_page.nodes[0].activation);
    try std.testing.expectEqual(a_page.nodes[200].activation, b_page.nodes[200].activation);
}

test "VFS: page to E0 nodes array" {
    const allocator = std.testing.allocator;
    var bridge = VFSBridge.init(allocator);
    defer bridge.deinit();

    const key = PageKey{ .level = 5, .bx = 0, .by = 0, .bz = 0 };
    var page = LatticePage.init(key, 0);
    page.nodes[0] = .{ .x = 7, .y = 7, .z = 7, .activation = fp.ONE };
    page.nodes[1] = .{ .x = 3, .y = 5, .z = 1, .activation = fp.div(fp.fromInt(1), fp.fromInt(2)) };
    try bridge.writeDirect(key, page);

    const nodes = try bridge.pageToE0Nodes(key);
    try std.testing.expectEqual(@as(u32, 7), nodes[0].x);
    try std.testing.expectEqual(@as(u32, 7), nodes[0].y);
    try std.testing.expectEqual(@as(u32, 7), nodes[0].z);
    try std.testing.expectEqual(fp.ONE, nodes[0].activation);
    try std.testing.expectEqual(fp.div(fp.fromInt(1), fp.fromInt(2)), nodes[1].activation);
}
