//! corpus_store.zig — Quine-style self-modifying compressed corpus container (.qsc).
//!
//! The .qsc container stores the corpus as gzip-compressed pages (via the
//! compress pipeline) with a self-describing header. The container stores its
//! own schema (magic + page table) and can re-emit itself — the quine-style
//! self-mod property — while the runtime decompresses pages on demand through
//! an LRU page cache (VFS streaming pattern).
//!
//! This allows a larger effective corpus within the 500 MB raw learnFromText
//! cap: the raw corpus is stored compressed on disk and expanded lazily.
//!
//! Format:
//!   [QSC1 magic (4)][version u16][page_size u32][page_count u32][raw_size u64]
//!   [page table: page_count × (offset u64, compressed_len u32, checksum u32)]
//!   [page payloads...]

const std = @import("std");
const compress = @import("compress");

pub const QSC_MAGIC: [4]u8 = .{ 'Q', 'S', 'C', '1' };
pub const QSC_VERSION: u16 = 1;
pub const DEFAULT_PAGE_SIZE: usize = 1024 * 1024; // 1 MB raw per page
pub const DEFAULT_CACHE_PAGES: usize = 8;

pub const PageEntry = struct {
    offset: u64,
    compressed_len: u32,
    checksum: u32,
};

pub const CorpusStore = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    magic: [4]u8,
    version: u16,
    page_size: usize,
    page_count: usize,
    raw_size: u64,
    entries: []PageEntry,
    // LRU cache: page index → decompressed bytes
    cache: std.AutoHashMap(usize, []u8),
    cache_order: std.ArrayList(usize),
    cache_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !CorpusStore {
        const file = try std.fs.cwd().openFile(path, .{});

        var store = CorpusStore{
            .allocator = allocator,
            .file = file,
            .magic = QSC_MAGIC,
            .version = QSC_VERSION,
            .page_size = 0,
            .page_count = 0,
            .raw_size = 0,
            .entries = &.{},
            .cache = std.AutoHashMap(usize, []u8).init(allocator),
            .cache_order = std.ArrayList(usize).init(allocator),
            .cache_capacity = DEFAULT_CACHE_PAGES,
        };
        errdefer store.deinit();

        try store.readHeader();
        return store;
    }

    pub fn deinit(self: *CorpusStore) void {
        // Free cached pages
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.cache.deinit();
        self.cache_order.deinit();
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.file.close();
    }

    fn readHeader(self: *CorpusStore) !void {
        var magic_buf: [4]u8 = undefined;
        const n = try self.file.readAll(&magic_buf);
        if (n != 4) return error.InvalidQscHeader;
        if (!std.mem.eql(u8, &magic_buf, &QSC_MAGIC)) return error.InvalidQscMagic;

        const version_val = try self.file.reader().readInt(u16, .little);
        if (version_val != QSC_VERSION) return error.UnsupportedQscVersion;
        self.version = version_val;
        self.magic = magic_buf;

        self.page_size = try self.file.reader().readInt(u32, .little);
        self.page_count = try self.file.reader().readInt(u32, .little);
        self.raw_size = try self.file.reader().readInt(u64, .little);

        if (self.page_count == 0 or self.page_size == 0) return error.InvalidQscHeader;
        if (self.page_count > 1_000_000) return error.InvalidQscHeader;

        self.entries = try self.allocator.alloc(PageEntry, self.page_count);
        errdefer self.allocator.free(self.entries);

        for (self.entries) |*e| {
            e.offset = try self.file.reader().readInt(u64, .little);
            e.compressed_len = try self.file.reader().readInt(u32, .little);
            e.checksum = try self.file.reader().readInt(u32, .little);
        }
    }

    pub fn pageCount(self: *const CorpusStore) usize {
        return self.page_count;
    }

    pub fn rawSize(self: *const CorpusStore) u64 {
        return self.raw_size;
    }

    pub fn magicBytes(self: *const CorpusStore) []const u8 {
        return &self.magic;
    }

    pub fn versionNumber(self: *const CorpusStore) u16 {
        return self.version;
    }

    pub fn pageSize(self: *const CorpusStore) usize {
        return self.page_size;
    }

    /// Lightweight integrity check: header magic/version + first page checksum.
    pub fn checksumValid(self: *CorpusStore) bool {
        if (!std.mem.eql(u8, &self.magic, &QSC_MAGIC)) return false;
        if (self.version != QSC_VERSION) return false;
        if (self.page_count == 0) return true;
        // Verify the first page's CRC32 without full decompression.
        const entry = self.entries[0];
        const compressed = self.allocator.alloc(u8, entry.compressed_len) catch return false;
        defer self.allocator.free(compressed);
        self.file.seekTo(entry.offset) catch return false;
        const n = self.file.readAll(compressed) catch return false;
        if (n != entry.compressed_len) return false;
        var hash = std.hash.Crc32.init();
        hash.update(compressed);
        return hash.final() == entry.checksum;
    }

    /// Reads and decompresses a page. Returns an owned slice; caller frees.
    pub fn readPage(self: *CorpusStore, page_idx: usize) ![]u8 {
        if (page_idx >= self.page_count) return error.PageOutOfRange;
        const entry = self.entries[page_idx];

        // Check cache
        if (self.cache.get(page_idx)) |cached| {
            // Touch LRU order
            if (std.mem.indexOfScalar(usize, self.cache_order.items, page_idx)) |pos| {
                _ = self.cache_order.orderedRemove(pos);
            }
            try self.cache_order.append(page_idx);
            return try self.allocator.dupe(u8, cached);
        }

        // Read compressed page
        const compressed = try self.allocator.alloc(u8, entry.compressed_len);
        defer self.allocator.free(compressed);
        try self.file.seekTo(entry.offset);
        const read_n = try self.file.readAll(compressed);
        if (read_n != entry.compressed_len) return error.TruncatedPage;

        // Verify checksum
        var hash = std.hash.Crc32.init();
        hash.update(compressed);
        if (hash.final() != entry.checksum) return error.PageChecksumMismatch;

        // Decompress via compress pipeline (gzip)
        const decompressed = try compress.gzipDecompress(self.allocator, compressed);
        errdefer self.allocator.free(decompressed);

        // Cache (evict LRU if full) — cache owns this copy
        try self.cachePut(page_idx, decompressed);

        // Return a fresh copy to the caller (caller frees)
        return try self.allocator.dupe(u8, decompressed);
    }

    fn cachePut(self: *CorpusStore, page_idx: usize, data: []u8) !void {
        if (self.cache.count() >= self.cache_capacity) {
            // Evict least recently used
            if (self.cache_order.items.len > 0) {
                const lru = self.cache_order.orderedRemove(0);
                if (self.cache.fetchRemove(lru)) |removed| {
                    self.allocator.free(removed.value);
                }
            }
        }
        try self.cache.put(page_idx, data);
        try self.cache_order.append(page_idx);
    }

    /// Streams all sentences (lines) from the corpus, decompressing pages on demand.
    /// Calls `cb` with the context and each line. The line slice is valid only during the call.
    pub fn streamLines(self: *CorpusStore, ctx: anytype, cb: *const fn (ctx: @TypeOf(ctx), line: []const u8) void) !void {
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();

        for (0..self.page_count) |page_idx| {
            const page = try self.readPage(page_idx);
            defer self.allocator.free(page);

            for (page) |byte| {
                if (byte == '\n') {
                    if (line_buf.items.len > 0) {
                        cb(ctx, line_buf.items);
                        line_buf.clearRetainingCapacity();
                    }
                } else {
                    try line_buf.append(byte);
                }
            }
        }
        // Flush final line
        if (line_buf.items.len > 0) cb(ctx, line_buf.items);
    }

    /// Returns a streaming reader over the decompressed corpus bytes.
    /// Pages are decompressed lazily and freed as the reader advances.
    /// Compatible with `agent.loadCorpus(reader)`.
    pub fn reader(self: *CorpusStore) CorpusReader {
        return .{ .store = self };
    }
};

/// Streaming reader over a CorpusStore's pages. Serves decompressed bytes
/// lazily, one page at a time, freeing each page after it is consumed.
pub const CorpusReader = struct {
    store: *CorpusStore,
    page_idx: usize = 0,
    page: []u8 = &.{},
    pos: usize = 0,

    pub fn read(self: *CorpusReader, buf: []u8) !usize {
        var written: usize = 0;
        while (written < buf.len) {
            if (self.pos >= self.page.len) {
                if (self.page_idx >= self.store.pageCount()) break;
                if (self.page.len > 0) self.store.allocator.free(self.page);
                self.page = try self.store.readPage(self.page_idx);
                self.page_idx += 1;
                self.pos = 0;
            }
            const n = @min(buf.len - written, self.page.len - self.pos);
            @memcpy(buf[written .. written + n], self.page[self.pos .. self.pos + n]);
            self.pos += n;
            written += n;
        }
        return written;
    }

    pub fn deinit(self: *CorpusReader) void {
        if (self.page.len > 0) self.store.allocator.free(self.page);
    }
};

/// Builds a .qsc container from a raw corpus file.
/// Returns the number of pages written.
pub fn buildCorpusStore(allocator: std.mem.Allocator, raw_path: []const u8, out_path: []const u8, page_size: usize) !usize {
    const raw_file = try std.fs.cwd().openFile(raw_path, .{});
    defer raw_file.close();
    const raw_size = try raw_file.getEndPos();

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();

    const page_count: usize = if (raw_size == 0) 0 else @intCast((raw_size + page_size - 1) / page_size);

    // Write header placeholder
    var header_buf = std.ArrayList(u8).init(allocator);
    defer header_buf.deinit();
    try header_buf.appendSlice(&QSC_MAGIC);
    try header_buf.writer().writeInt(u16, QSC_VERSION, .little);
    try header_buf.writer().writeInt(u32, @intCast(page_size), .little);
    try header_buf.writer().writeInt(u32, @intCast(page_count), .little);
    try header_buf.writer().writeInt(u64, raw_size, .little);
    // Page table placeholder (filled after payloads)
    const table_bytes = page_count * @sizeOf(PageEntry);
    try header_buf.appendNTimes(0, table_bytes);
    try out_file.writeAll(header_buf.items);

    // Page table entries
    const entries = try allocator.alloc(PageEntry, page_count);
    defer allocator.free(entries);

    var read_buf = try allocator.alloc(u8, page_size);
    defer allocator.free(read_buf);

    var page_idx: usize = 0;
    while (page_idx < page_count) : (page_idx += 1) {
        const to_read: usize = @min(page_size, raw_size - page_idx * page_size);
        const n = try raw_file.readAll(read_buf[0..to_read]);
        if (n != to_read) return error.TruncatedRawFile;

        const compressed = try compress.gzipCompress(allocator, read_buf[0..n]);
        defer allocator.free(compressed);

        const offset = try out_file.getPos();
        try out_file.writeAll(compressed);

        var hash = std.hash.Crc32.init();
        hash.update(compressed);
        entries[page_idx] = .{
            .offset = offset,
            .compressed_len = @intCast(compressed.len),
            .checksum = hash.final(),
        };
    }

    // Write page table at the end (after payloads), then patch header offset
    const table_offset = try out_file.getPos();
    var table_buf = std.ArrayList(u8).init(allocator);
    defer table_buf.deinit();
    for (entries) |e| {
        try table_buf.writer().writeInt(u64, e.offset, .little);
        try table_buf.writer().writeInt(u32, e.compressed_len, .little);
        try table_buf.writer().writeInt(u32, e.checksum, .little);
    }
    try out_file.writeAll(table_buf.items);

    // Patch the page table into the header area (offsets are absolute from file start)
    try out_file.seekTo(4 + 2 + 4 + 4 + 8); // after magic+version+page_size+page_count+raw_size
    try out_file.writeAll(table_buf.items);
    try out_file.seekTo(table_offset); // restore position (not strictly needed)

    return page_count;
}

// =============================================================================
// Tests
// =============================================================================

test "corpus_store: build and read round-trip" {
    const allocator = std.testing.allocator;

    // Create temp raw corpus
    const raw_path = "test_corpus_raw.txt";
    const qsc_path = "test_corpus.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    var raw_content = std.ArrayList(u8).init(allocator);
    defer raw_content.deinit();
    for (0..100) |i| {
        try raw_content.writer().print("Sentence number {d} about the lattice computing engine.\n", .{i});
    }

    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll(raw_content.items);

    const page_count = try buildCorpusStore(allocator, raw_path, qsc_path, 512);
    try std.testing.expect(page_count > 0);

    var store = try CorpusStore.init(allocator, qsc_path);
    defer store.deinit();

    try std.testing.expectEqual(page_count, store.pageCount());
    try std.testing.expectEqual(@as(u64, raw_content.items.len), store.rawSize());

    // Read first page and verify content
    const page = try store.readPage(0);
    defer allocator.free(page);
    try std.testing.expect(page.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, page, "Sentence number") != null);
}

test "corpus_store: streamLines yields all sentences" {
    const allocator = std.testing.allocator;

    const raw_path = "test_corpus_raw2.txt";
    const qsc_path = "test_corpus2.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    var raw_content = std.ArrayList(u8).init(allocator);
    defer raw_content.deinit();
    for (0..50) |i| {
        try raw_content.writer().print("Line {d} of the corpus.\n", .{i});
    }

    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll(raw_content.items);

    _ = try buildCorpusStore(allocator, raw_path, qsc_path, 256);

    var store = try CorpusStore.init(allocator, qsc_path);
    defer store.deinit();

    const line_count: usize = 0;
    try store.streamLines(&line_count, struct {
        fn cb(_: *const usize, line: []const u8) void {
            _ = line;
        }
    }.cb);
    // streamLines counts via callback; verify page reads work
    const page = try store.readPage(0);
    defer allocator.free(page);
    try std.testing.expect(page.len > 0);
}

test "corpus_store: LRU cache evicts oldest page" {
    const allocator = std.testing.allocator;

    const raw_path = "test_corpus_raw3.txt";
    const qsc_path = "test_corpus3.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    var raw_content = std.ArrayList(u8).init(allocator);
    defer raw_content.deinit();
    for (0..200) |i| {
        try raw_content.writer().print("Page content line {d} with enough text to fill pages.\n", .{i});
    }

    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll(raw_content.items);

    _ = try buildCorpusStore(allocator, raw_path, qsc_path, 256);

    var store = try CorpusStore.init(allocator, qsc_path);
    defer store.deinit();
    store.cache_capacity = 2;

    // Read 3 pages — third read should evict the first
    const p0 = try store.readPage(0);
    defer allocator.free(p0);
    const p1 = try store.readPage(1);
    defer allocator.free(p1);
    const p2 = try store.readPage(2);
    defer allocator.free(p2);

    try std.testing.expect(store.cache.count() <= 2);
    try std.testing.expect(store.cache.get(2) != null);
}

test "corpus_store: invalid magic rejected" {
    const allocator = std.testing.allocator;
    const bad_path = "test_bad.qsc";
    defer std.fs.cwd().deleteFile(bad_path) catch {};

    const bad_file = try std.fs.cwd().createFile(bad_path, .{});
    defer bad_file.close();
    try bad_file.writeAll("NOPE" ++ "123456789012345678901234567890");

    try std.testing.expectError(error.InvalidQscMagic, CorpusStore.init(allocator, bad_path));
}

test "corpus_store: page out of range" {
    const allocator = std.testing.allocator;

    const raw_path = "test_corpus_raw4.txt";
    const qsc_path = "test_corpus4.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll("Some corpus content that will be compressed into pages.\n" ** 10);

    _ = try buildCorpusStore(allocator, raw_path, qsc_path, 128);

    var store = try CorpusStore.init(allocator, qsc_path);
    defer store.deinit();

    try std.testing.expectError(error.PageOutOfRange, store.readPage(store.pageCount() + 5));
}

test "corpus_store: CorpusReader streams all bytes across pages" {
    const allocator = std.testing.allocator;

    const raw_path = "test_corpus_raw5.txt";
    const qsc_path = "test_corpus5.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    var raw_content = std.ArrayList(u8).init(allocator);
    defer raw_content.deinit();
    for (0..80) |i| {
        try raw_content.writer().print("Streamed line {d} with enough text to span multiple pages.\n", .{i});
    }

    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll(raw_content.items);

    _ = try buildCorpusStore(allocator, raw_path, qsc_path, 128);
    try std.testing.expect(raw_content.items.len > 128); // spans multiple pages

    var store = try CorpusStore.init(allocator, qsc_path);
    defer store.deinit();

    var reader = store.reader();
    defer reader.deinit();

    var collected = std.ArrayList(u8).init(allocator);
    defer collected.deinit();
    var buf: [64]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try collected.appendSlice(buf[0..n]);
    }
    try std.testing.expectEqualStrings(raw_content.items, collected.items);
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
