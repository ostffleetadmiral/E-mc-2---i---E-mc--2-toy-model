//! corpus_index.zig — Inverted index over a .qsc corpus container.
//!
//! Maps word hashes → sorted page-index posting lists so retrieval can
//! page-in only the ~1MB pages that contain prompt keywords instead of
//! scanning the entire 2.9GB corpus. Integer-only; no floating point.
//!
//! Format (QCI1):
//!   [magic 4][version u16][page_count u32][word_count u64]
//!   per word: [hash u64][posting_count u32][page u32]×posting_count

const std = @import("std");
const builtin = @import("builtin");
const corpus_store = @import("corpus_store");

/// File I/O is unavailable on freestanding targets (WASM); fs entry points
/// early-return so the fs code is pruned at analysis time.
const is_freestanding = builtin.os.tag == .freestanding;

pub const QCI_MAGIC: [4]u8 = .{ 'Q', 'C', 'I', '1' };
pub const QCI_VERSION: u16 = 1;

/// Minimum indexed word length; shorter tokens carry no signal.
const MIN_WORD_LEN: usize = 3;
/// Maximum indexed word length; longer tokens are truncated for hashing.
const MAX_WORD_LEN: usize = 48;

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn hashWord(word: []const u8) u64 {
    // Normalize to lowercase before hashing so queries match regardless of case.
    var buf: [MAX_WORD_LEN]u8 = undefined;
    const n = @min(word.len, MAX_WORD_LEN);
    for (word[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.hash.Wyhash.hash(0, buf[0..n]);
}

pub fn hashQueryWord(word: []const u8) u64 {
    return hashWord(word);
}

const ScoredPage = struct { page: u32, hits: u32 };

fn scoredPageDesc(_: void, a: ScoredPage, b: ScoredPage) bool {
    return a.hits > b.hits;
}

pub const CorpusIndex = struct {
    allocator: std.mem.Allocator,
    /// Arena backing all postings storage — one bulk free on deinit and
    /// bump-pointer allocation during build/load (millions of postings).
    /// Heap-allocated so its address stays stable when the struct is moved.
    arena_state: *std.heap.ArenaAllocator,
    /// word hash → sorted, deduplicated list of page indices
    postings: std.AutoHashMap(u64, std.ArrayList(u32)),
    page_count: u32,

    pub fn init(allocator: std.mem.Allocator) CorpusIndex {
        const arena = allocator.create(std.heap.ArenaAllocator) catch unreachable;
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return .{
            .allocator = allocator,
            .arena_state = arena,
            .postings = std.AutoHashMap(u64, std.ArrayList(u32)).init(arena.allocator()),
            .page_count = 0,
        };
    }

    pub fn deinit(self: *CorpusIndex) void {
        self.arena_state.deinit();
        self.allocator.destroy(self.arena_state);
    }

    /// Builds the index by decompressing every page and tokenizing its lines.
    /// Lines split across page boundaries are stitched so each complete line
    /// is attributed to the page where it starts.
    pub fn build(self: *CorpusIndex, store: *corpus_store.CorpusStore) !void {
        if (is_freestanding) return error.FreestandingUnsupported;
        self.page_count = @intCast(store.pageCount());
        var fragment = std.ArrayList(u8).init(self.allocator);
        defer fragment.deinit();

        var page_idx: usize = 0;
        while (page_idx < store.pageCount()) : (page_idx += 1) {
            const page = try store.readPage(page_idx);
            defer self.allocator.free(page);

            // Stitch the trailing fragment from the previous page onto the
            // first line of this page.
            var rest = page;
            if (fragment.items.len > 0) {
                if (std.mem.indexOfScalar(u8, page, '\n')) |nl| {
                    try fragment.appendSlice(page[0..nl]);
                    try self.indexLine(fragment.items, @intCast(page_idx - 1));
                    fragment.clearRetainingCapacity();
                    rest = page[nl + 1 ..];
                } else {
                    // Whole page is a continuation of one very long line.
                    try fragment.appendSlice(page);
                    continue;
                }
            }

            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                const line = rest[0..nl];
                try self.indexLine(line, @intCast(page_idx));
                rest = rest[nl + 1 ..];
            }
            if (rest.len > 0) {
                // Trailing partial line — carries into the next page.
                try fragment.appendSlice(rest);
            }
        }
        // Final fragment with no trailing newline still counts.
        if (fragment.items.len > 0) {
            try self.indexLine(fragment.items, @intCast(store.pageCount() - 1));
        }
    }

    fn indexLine(self: *CorpusIndex, line: []const u8, page_idx: u32) !void {
        var it = std.mem.tokenizeAny(u8, line, " \t\r.,!?;:\"'()[]{}<>|/\\@#$%^&*+=`~");
        while (it.next()) |w| {
            if (w.len < MIN_WORD_LEN) continue;
            const h = hashWord(w);
            const entry = try self.postings.getOrPut(h);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(u32).init(self.arena_state.allocator());
            }
            const list = entry.value_ptr;
            // Pages are indexed in order, so the last entry is >= page_idx;
            // dedupe by checking the tail.
            if (list.items.len == 0 or list.items[list.items.len - 1] != page_idx) {
                try list.append(page_idx);
            }
        }
    }

    /// Scores pages by the number of distinct keyword hashes they contain.
    /// Returns up to `max_pages` page indices, best first.
    pub fn queryPages(
        self: *CorpusIndex,
        keyword_hashes: []const u64,
        max_pages: usize,
    ) ![]u32 {
        var counts = std.AutoHashMap(u32, u32).init(self.allocator);
        defer counts.deinit();

        for (keyword_hashes) |h| {
            const list = self.postings.get(h) orelse continue;
            for (list.items) |p| {
                const entry = try counts.getOrPut(p);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            }
        }

        var scored = std.ArrayList(ScoredPage).init(self.allocator);
        defer scored.deinit();
        var it = counts.iterator();
        while (it.next()) |e| {
            try scored.append(.{ .page = e.key_ptr.*, .hits = e.value_ptr.* });
        }
        std.mem.sort(ScoredPage, scored.items, {}, scoredPageDesc);

        const n = @min(max_pages, scored.items.len);
        var out = try self.allocator.alloc(u32, n);
        for (scored.items[0..n], 0..) |s, i| out[i] = s.page;
        return out;
    }

    pub fn wordCount(self: *const CorpusIndex) usize {
        return self.postings.count();
    }

    pub fn saveToFile(self: *CorpusIndex, path: []const u8) !void {
        if (is_freestanding) return error.FreestandingUnsupported;
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();

        try w.writeAll(&QCI_MAGIC);
        try w.writeInt(u16, QCI_VERSION, .little);
        try w.writeInt(u32, self.page_count, .little);
        try w.writeInt(u64, self.postings.count(), .little);

        var it = self.postings.iterator();
        while (it.next()) |e| {
            try w.writeInt(u64, e.key_ptr.*, .little);
            try w.writeInt(u32, @intCast(e.value_ptr.items.len), .little);
            for (e.value_ptr.items) |p| try w.writeInt(u32, p, .little);
        }
        try bw.flush();
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !CorpusIndex {
        if (is_freestanding) return error.FreestandingUnsupported;
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
        defer allocator.free(data);

        if (data.len < 18) return error.InvalidIndexMagic;
        if (!std.mem.eql(u8, data[0..4], &QCI_MAGIC)) return error.InvalidIndexMagic;
        const version = std.mem.readInt(u16, data[4..6], .little);
        if (version != QCI_VERSION) return error.UnsupportedIndexVersion;
        const page_count = std.mem.readInt(u32, data[6..10], .little);
        const word_count = std.mem.readInt(u64, data[10..18], .little);

        var index = CorpusIndex.init(allocator);
        errdefer index.deinit();
        index.page_count = page_count;
        const ally = index.arena_state.allocator();
        try index.postings.ensureTotalCapacity(@intCast(word_count));

        // In-memory parse: entries are [hash u64][count u32][pages u32 × count]
        // laid out contiguously — each posting list is one arena allocation
        // filled by a single byte-copy, no per-element reader calls.
        var pos: usize = 18;
        var i: u64 = 0;
        while (i < word_count) : (i += 1) {
            if (pos + 12 > data.len) return error.TruncatedIndex;
            const h = std.mem.readInt(u64, data[pos..][0..8], .little);
            const n = std.mem.readInt(u32, data[pos + 8 ..][0..4], .little);
            pos += 12;
            const byte_len = @as(usize, n) * 4;
            if (pos + byte_len > data.len) return error.TruncatedIndex;
            var list = try std.ArrayList(u32).initCapacity(ally, n);
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                list.appendAssumeCapacity(std.mem.readInt(u32, data[pos + @as(usize, j) * 4 ..][0..4], .little));
            }
            pos += byte_len;
            index.postings.putAssumeCapacity(h, list);
        }
        return index;
    }
};

test "corpus_index: hashQueryWord is case-insensitive" {
    try std.testing.expectEqual(hashQueryWord("Photosynthesis"), hashQueryWord("photosynthesis"));
    try std.testing.expectEqual(hashQueryWord("DNA"), hashQueryWord("dna"));
}

test "corpus_index: save/load round-trip" {
    const allocator = std.testing.allocator;
    var index = CorpusIndex.init(allocator);
    defer index.deinit();
    index.page_count = 3;

    var list = std.ArrayList(u32).init(index.arena_state.allocator());
    try list.append(0);
    try list.append(2);
    try index.postings.put(hashQueryWord("photosynthesis"), list);

    const path = "/tmp/qci_test_roundtrip.bin";
    try index.saveToFile(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var loaded = try CorpusIndex.loadFromFile(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 3), loaded.page_count);
    const got = loaded.postings.get(hashQueryWord("photosynthesis")).?;
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, got.items);
}
