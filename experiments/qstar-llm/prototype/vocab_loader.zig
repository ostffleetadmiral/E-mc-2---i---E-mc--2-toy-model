//! vocab_loader.zig — Universal Production Vocabulary Loader & Lattice Indexer
//!
//! Parses real-world vocabulary formats (JSON, line-by-line TXT, vocab files)
//! supporting up to 1,000,000 tokens, and indexes tokens onto the discrete
//! 421 E0 nodes and 7 reasoning channels using harmonic tier projection.

const std = @import("std");

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;
pub const CELLS_PER_TIER: usize = E0_NODE_COUNT * CHANNEL_COUNT; // 2,947

pub const LatticeCoordinate = struct {
    node: u32,
    channel: u3,
    tier: u32,
};

/// Maps an arbitrary token ID (0..1,000,000+) to its discrete lattice coordinate.
pub fn tokenToLatticeCoordinate(token_id: u32) LatticeCoordinate {
    const node: u32 = token_id % @as(u32, @intCast(E0_NODE_COUNT));
    const channel: u3 = @intCast((token_id / @as(u32, @intCast(E0_NODE_COUNT))) % @as(u32, @intCast(CHANNEL_COUNT)));
    const tier: u32 = token_id / @as(u32, @intCast(CELLS_PER_TIER));
    return .{
        .node = node,
        .channel = channel,
        .tier = tier,
    };
}

/// Maps a lattice coordinate back to its unique token ID.
pub fn latticeCoordinateToToken(coord: LatticeCoordinate) u32 {
    return coord.node + (@as(u32, coord.channel) * @as(u32, @intCast(E0_NODE_COUNT))) + (coord.tier * @as(u32, @intCast(CELLS_PER_TIER)));
}

pub const VocabularyFormat = enum {
    json_dict,
    line_by_line_txt,
};

pub const UniversalVocab = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList([]const u8),
    word_to_id: std.StringHashMap(u32),
    id_to_word: std.AutoHashMap(u32, []const u8),
    format: VocabularyFormat,

    pub fn init(allocator: std.mem.Allocator, format: VocabularyFormat) UniversalVocab {
        return .{
            .allocator = allocator,
            .tokens = std.ArrayList([]const u8).init(allocator),
            .word_to_id = std.StringHashMap(u32).init(allocator),
            .id_to_word = std.AutoHashMap(u32, []const u8).init(allocator),
            .format = format,
        };
    }

    pub fn deinit(self: *UniversalVocab) void {
        for (self.tokens.items) |tok| {
            self.allocator.free(tok);
        }
        self.tokens.deinit();
        self.word_to_id.deinit();
        self.id_to_word.deinit();
    }

    /// Adds a token into the vocabulary.
    pub fn addToken(self: *UniversalVocab, token: []const u8, id: u32) !void {
        const owned = try self.allocator.dupe(u8, token);
        try self.tokens.append(owned);
        try self.word_to_id.put(owned, id);
        try self.id_to_word.put(id, owned);
    }

    /// Loads vocabulary from a line-by-line text file.
    pub fn loadFromTxtFile(self: *UniversalVocab, file_path: []const u8, max_tokens: ?usize) !usize {
        const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        var line_it = std.mem.splitScalar(u8, buffer, '\n');
        var token_id: u32 = 0;

        while (line_it.next()) |line| {
            if (max_tokens) |limit| {
                if (token_id >= limit) break;
            }
            if (line.len == 0) continue;

            try self.addToken(line, token_id);
            token_id += 1;
        }

        return token_id;
    }

    /// Loads vocabulary from a JSON dictionary file {"token": id, ...}.
    pub fn loadFromJsonFile(self: *UniversalVocab, file_path: []const u8, max_tokens: ?usize) !usize {
        const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, buffer, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJsonFormat;

        var it = root.object.iterator();
        var count: usize = 0;

        while (it.next()) |entry| {
            if (max_tokens) |limit| {
                if (count >= limit) break;
            }

            const token_str = entry.key_ptr.*;
            const id: u32 = switch (entry.value_ptr.*) {
                .integer => |val| @intCast(val),
                else => @intCast(count),
            };

            try self.addToken(token_str, id);
            count += 1;
        }

        return count;
    }

    /// Get token word string from ID.
    pub fn getWord(self: *const UniversalVocab, id: u32) ?[]const u8 {
        return self.id_to_word.get(id);
    }

    /// Get token ID from word string.
    pub fn getId(self: *const UniversalVocab, word: []const u8) ?u32 {
        return self.word_to_id.get(word);
    }

    /// Total number of tokens in the vocabulary.
    pub fn size(self: *const UniversalVocab) usize {
        return self.tokens.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "vocab_loader: coordinate mapping round-trip" {
    const test_ids = [_]u32{ 0, 42, 420, 421, 2946, 2947, 100000, 151936, 512000, 1000000 };
    for (test_ids) |tid| {
        const coord = tokenToLatticeCoordinate(tid);
        try std.testing.expect(coord.node < E0_NODE_COUNT);
        try std.testing.expect(coord.channel < CHANNEL_COUNT);
        const reconstructed = latticeCoordinateToToken(coord);
        try std.testing.expectEqual(tid, reconstructed);
    }
}

test "vocab_loader: in-memory universal vocab" {
    const allocator = std.testing.allocator;
    var uv = UniversalVocab.init(allocator, .line_by_line_txt);
    defer uv.deinit();

    try uv.addToken("Quantum", 0);
    try uv.addToken("Superposition", 1);
    try uv.addToken("Lattice", 421);

    try std.testing.expectEqual(@as(usize, 3), uv.size());
    try std.testing.expectEqualStrings("Quantum", uv.getWord(0).?);
    try std.testing.expectEqualStrings("Lattice", uv.getWord(421).?);
    try std.testing.expectEqual(@as(u32, 1), uv.getId("Superposition").?);
}

test "vocab_loader: load real txt vocab snippet" {
    const allocator = std.testing.allocator;
    var uv = UniversalVocab.init(allocator, .line_by_line_txt);
    defer uv.deinit();

    const count = try uv.loadFromTxtFile(".foundations/RamseyLLM/vocabs/vocab-128k.txt", 100);
    try std.testing.expect(count > 0);
    try std.testing.expect(uv.size() > 0);
}
