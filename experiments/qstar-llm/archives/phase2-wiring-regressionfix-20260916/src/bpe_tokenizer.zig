//! bpe_tokenizer.zig — GPT-2 BPE tokenizer for Qstar agent.
//!
//! Adapted from Falsifible's tokenizer.zig — provides byte-level BPE
//! encoding/decoding without requiring GGUF metadata. Vocab and merges
//! are loaded at runtime from embedded data or can be constructed from
//! a minimal built-in vocabulary for testing.
//!
//! Architecture:
//!   - Byte-to-unicode mapping (GPT-2 standard)
//!   - BPE merge algorithm with rank-based pair selection
//!   - Special token handling (<|im_start|>, <|im_end|>, etc.)
//!   - Encode: text -> token IDs
//!   - Decode: token IDs -> text
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.os.tag == .freestanding;

// =============================================================================
// Constants
// =============================================================================

/// Special token IDs (matching Qwen1.5 tokenizer config).
pub const EOS_TOKEN_ID: u32 = 151643;
pub const IM_START_TOKEN_ID: u32 = 151644;
pub const IM_END_TOKEN_ID: u32 = 151645;

/// Special token strings.
pub const EOS_TOKEN = "<|endoftext|>";
pub const IM_START_TOKEN = "<|im_start|>";
pub const IM_END_TOKEN = "<|im_end|>";

// =============================================================================
// Byte-to-Unicode Mapping (GPT-2 standard)
// =============================================================================

/// Build the GPT-2 byte-to-unicode mapping.
/// Bytes 33-126, 161-172, 174-255 map to themselves; others map to 256+offset.
fn byteToUnicode() [256]u21 {
    var map: [256]u21 = undefined;
    var idx: u21 = 0;
    for (0..256) |i| {
        if ((i >= 33 and i <= 126) or (i >= 161 and i <= 172) or (i >= 174 and i <= 255)) {
            map[i] = @intCast(i);
        } else {
            map[i] = 256 + idx;
            idx += 1;
        }
    }
    return map;
}

/// Reverse mapping: unicode codepoint -> original byte.
/// Indexed by codepoint (0-511). valid[cp] = true if cp maps to a byte.
var g_unicode_to_byte: [512]u8 = undefined;
var g_unicode_to_byte_valid: [512]bool = undefined;
var g_unicode_to_byte_init: bool = false;

fn ensureUnicodeToByte() void {
    if (g_unicode_to_byte_init) return;
    const btu = byteToUnicode();
    for (0..256) |i| {
        const cp = btu[i];
        if (cp < 512) {
            g_unicode_to_byte[cp] = @intCast(i);
            g_unicode_to_byte_valid[cp] = true;
        }
    }
    g_unicode_to_byte_init = true;
}

// =============================================================================
// Tokenizer
// =============================================================================

/// Returns standard relative path for a given Ramsey vocab level (0..3).
pub inline fn getRamseyVocabPathForLevel(level: u8) ?[]const u8 {
    return switch (level) {
        0 => ".foundations/RamseyLLM/vocabs/vocab-128k.txt",
        1 => ".foundations/RamseyLLM/vocabs/vocab-256k.txt",
        2 => ".foundations/RamseyLLM/vocabs/vocab-512k.txt",
        3 => ".foundations/RamseyLLM/vocabs/vocab-1m.txt",
        else => null,
    };
}

/// Tokenizer struct for BPE tokenization.
pub const Tokenizer = struct {
    allocator: std.mem.Allocator,
    vocab: std.StringHashMap(u32),
    id_to_token: std.AutoHashMap(u32, []const u8),
    merge_ranks: std.StringHashMap(u32),
    special_tokens: std.StringHashMap(u32),
    eos_token_id: u32,
    bos_token_id: u32,

    pub fn init(allocator: std.mem.Allocator) Tokenizer {
        return .{
            .allocator = allocator,
            .vocab = std.StringHashMap(u32).init(allocator),
            .id_to_token = std.AutoHashMap(u32, []const u8).init(allocator),
            .merge_ranks = std.StringHashMap(u32).init(allocator),
            .special_tokens = std.StringHashMap(u32).init(allocator),
            .eos_token_id = EOS_TOKEN_ID,
            .bos_token_id = EOS_TOKEN_ID,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        // Free owned token strings (stored as keys in vocab)
        var it = self.vocab.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.vocab.deinit();
        self.id_to_token.deinit();
        // Free owned merge strings (stored as keys in merge_ranks)
        var mit = self.merge_ranks.iterator();
        while (mit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.merge_ranks.deinit();
        self.special_tokens.deinit();
    }

    /// Adds a token to the vocabulary with the given ID.
    /// The token string is duped and owned by the tokenizer.
    pub fn addToken(self: *Tokenizer, token: []const u8, id: u32) !void {
        if (self.vocab.get(token)) |_| {
            return;
        }
        const owned = try self.allocator.dupe(u8, token);
        try self.vocab.put(owned, id);
        try self.id_to_token.put(id, owned);
        if (std.mem.indexOf(u8, owned, "<|") != null) {
            try self.special_tokens.put(owned, id);
        }
    }

    /// Adds a merge rule: "a b" -> rank.
    /// The merge string is duped and owned by the tokenizer.
    pub fn addMerge(self: *Tokenizer, merge: []const u8, rank: u32) !void {
        const owned = try self.allocator.dupe(u8, merge);
        try self.merge_ranks.put(owned, rank);
    }

    fn openAnyFile(file_path: []const u8) !std.fs.File {
        if (is_wasm) return error.NotAvailableInWasm;
        if (std.fs.path.isAbsolute(file_path)) {
            return std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        } else {
            return std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        }
    }

    /// Returns standard relative path for a given Ramsey vocab level (0..3).
    pub inline fn getRamseyVocabPathForLevel(level: u8) ?[]const u8 {
        return switch (level) {
            0 => ".foundations/RamseyLLM/vocabs/vocab-128k.txt",
            1 => ".foundations/RamseyLLM/vocabs/vocab-256k.txt",
            2 => ".foundations/RamseyLLM/vocabs/vocab-512k.txt",
            3 => ".foundations/RamseyLLM/vocabs/vocab-1m.txt",
            else => null,
        };
    }

    /// Loads Ramsey vocabulary given either a level (0..3), name ("128k", "256k", "512k", "1m"),
    /// or explicit file path.
    pub fn loadRamseyVocab(self: *Tokenizer, specifier: []const u8, max_tokens: ?usize) !usize {
        if (is_wasm) return error.NotAvailableInWasm;
        const resolved_path: []const u8 = if (std.mem.eql(u8, specifier, "0") or std.mem.eql(u8, specifier, "128k") or std.mem.eql(u8, specifier, "ramsey-128k"))
            ".foundations/RamseyLLM/vocabs/vocab-128k.txt"
        else if (std.mem.eql(u8, specifier, "1") or std.mem.eql(u8, specifier, "256k") or std.mem.eql(u8, specifier, "ramsey-256k"))
            ".foundations/RamseyLLM/vocabs/vocab-256k.txt"
        else if (std.mem.eql(u8, specifier, "2") or std.mem.eql(u8, specifier, "512k") or std.mem.eql(u8, specifier, "ramsey-512k"))
            ".foundations/RamseyLLM/vocabs/vocab-512k.txt"
        else if (std.mem.eql(u8, specifier, "3") or std.mem.eql(u8, specifier, "1m") or std.mem.eql(u8, specifier, "ramsey-1m"))
            ".foundations/RamseyLLM/vocabs/vocab-1m.txt"
        else
            specifier;

        return self.loadFromTxtFile(resolved_path, max_tokens);
    }

    /// Loads vocabulary from a line-by-line text file.
    pub fn loadFromTxtFile(self: *Tokenizer, file_path: []const u8, max_tokens: ?usize) !usize {
        if (is_wasm) return error.NotAvailableInWasm;
        const file = try openAnyFile(file_path);
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

    /// Loads BPE merge rules from a merges.txt file (GPT-2 format).
    /// Each line after "#version" header is a merge rule "tokenA tokenB" with rank = line number.
    pub fn loadMergesFromFile(self: *Tokenizer, file_path: []const u8, max_merges: ?usize) !usize {
        const file = try openAnyFile(file_path);
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        var line_it = std.mem.splitScalar(u8, buffer, '\n');
        var rank: u32 = 0;
        var count: usize = 0;

        // Skip the "#version: ..." header line
        const first_line = line_it.first();
        if (!std.mem.startsWith(u8, first_line, "#version")) {
            // Not a header, process as merge
            if (first_line.len > 0) {
                try self.addMerge(first_line, rank);
                rank += 1;
                count += 1;
            }
        }

        while (line_it.next()) |line| {
            if (max_merges) |limit| {
                if (count >= limit) break;
            }
            if (line.len == 0) continue;

            try self.addMerge(line, rank);
            rank += 1;
            count += 1;
        }

        return count;
    }

    /// Loads vocabulary from a JSON dictionary file.
    pub fn loadFromJsonFile(self: *Tokenizer, file_path: []const u8, max_tokens: ?usize) !usize {
        const file = try openAnyFile(file_path);
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

    /// Encodes text into BPE token IDs.
    pub fn encode(self: *const Tokenizer, text: []const u8) ![]u32 {
        var result = std.ArrayList(u32).init(self.allocator);
        errdefer result.deinit();

        const btu = byteToUnicode();

        var remaining = text;
        while (remaining.len > 0) {
            // Check for special token at current position
            var found_special: ?u32 = null;
            var special_len: usize = 0;
            var it = self.special_tokens.iterator();
            while (it.next()) |entry| {
                const tok_str = entry.key_ptr.*;
                if (std.mem.startsWith(u8, remaining, tok_str)) {
                    found_special = entry.value_ptr.*;
                    special_len = tok_str.len;
                    break;
                }
            }

            if (found_special) |tok_id| {
                try result.append(tok_id);
                remaining = remaining[special_len..];
                continue;
            }

            // Find next special token or end of string
            var chunk_end = remaining.len;
            var sit = self.special_tokens.iterator();
            while (sit.next()) |entry| {
                const tok_str = entry.key_ptr.*;
                if (std.mem.indexOf(u8, remaining[1..], tok_str)) |pos| {
                    const candidate = pos + 1;
                    if (candidate < chunk_end) chunk_end = candidate;
                }
            }

            const chunk = remaining[0..chunk_end];
            remaining = remaining[chunk_end..];

            try self.encodeChunk(chunk, &result, &btu);
        }

        return result.toOwnedSlice();
    }

    fn encodeChunk(self: *const Tokenizer, chunk: []const u8, result: *std.ArrayList(u32), btu: *const [256]u21) !void {
        var i: usize = 0;
        while (i < chunk.len) {
            const start = i;
            if (chunk[i] == ' ') {
                i += 1;
                while (i < chunk.len and chunk[i] != ' ' and !isOtherWhitespace(chunk[i]) and !isPunct(chunk[i])) i += 1;
            } else if (isOtherWhitespace(chunk[i])) {
                while (i < chunk.len and isOtherWhitespace(chunk[i])) i += 1;
            } else if (isPunct(chunk[i])) {
                i += 1;
            } else {
                while (i < chunk.len and chunk[i] != ' ' and !isOtherWhitespace(chunk[i]) and !isPunct(chunk[i])) i += 1;
            }

            const word_bytes = chunk[start..i];

            var word_buf = std.ArrayList(u8).init(self.allocator);
            defer word_buf.deinit();

            for (word_bytes) |b| {
                const cp = btu[b];
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch {
                    try word_buf.append(b);
                    continue;
                };
                try word_buf.appendSlice(buf[0..n]);
            }

            const bpe_tokens = try self.bpe(word_buf.items);
            defer {
                for (bpe_tokens) |bt| self.allocator.free(bt);
                self.allocator.free(bpe_tokens);
            }

            for (bpe_tokens) |bt| {
                if (self.vocab.get(bt)) |id| {
                    try result.append(id);
                }
            }
        }
    }

    fn bpe(self: *const Tokenizer, word: []const u8) ![][]const u8 {
        if (word.len == 0) return &.{};

        if (self.vocab.get(word) != null) {
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, word);
            return result;
        }

        var symbols = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (symbols.items) |s| {
                if (s.len > 0) self.allocator.free(s);
            }
            symbols.deinit();
        }

        var byte_idx: usize = 0;
        while (byte_idx < word.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(word[byte_idx]) catch 1;
            const end = @min(byte_idx + cp_len, word.len);
            try symbols.append(try self.allocator.dupe(u8, word[byte_idx..end]));
            byte_idx = end;
        }

        if (symbols.items.len == 1) {
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = symbols.items[0];
            symbols.items[0] = &.{};
            return result;
        }

        while (symbols.items.len > 1) {
            var best_rank: u32 = std.math.maxInt(u32);
            var best_idx: usize = 0;

            for (0..symbols.items.len - 1) |idx| {
                const pair_buf = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ symbols.items[idx], symbols.items[idx + 1] });
                defer self.allocator.free(pair_buf);

                const rank = self.merge_ranks.get(pair_buf) orelse std.math.maxInt(u32);
                if (rank < best_rank) {
                    best_rank = rank;
                    best_idx = idx;
                }
            }

            if (best_rank == std.math.maxInt(u32)) break;

            const merged = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ symbols.items[best_idx], symbols.items[best_idx + 1] });
            self.allocator.free(symbols.items[best_idx]);
            self.allocator.free(symbols.items[best_idx + 1]);
            symbols.items[best_idx] = merged;
            _ = symbols.orderedRemove(best_idx + 1);
        }

        const result = try self.allocator.alloc([]const u8, symbols.items.len);
        for (symbols.items, 0..) |s, i| {
            result[i] = s;
            symbols.items[i] = &.{};
        }
        return result;
    }

    /// Decodes token IDs back to text.
    pub fn decode(self: *const Tokenizer, token_ids: []const u32) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        ensureUnicodeToByte();

        for (token_ids) |id| {
            const token_str = self.id_to_token.get(id) orelse continue;

            if (self.special_tokens.get(token_str) != null) {
                try result.appendSlice(token_str);
                continue;
            }

            var view = std.unicode.Utf8View.init(token_str) catch {
                try result.appendSlice(token_str);
                continue;
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp < 256) {
                    try result.append(@intCast(cp));
                } else if (cp < 512 and g_unicode_to_byte_valid[cp]) {
                    try result.append(g_unicode_to_byte[cp]);
                } else {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                    try result.appendSlice(buf[0..n]);
                }
            }
        }

        return result.toOwnedSlice();
    }

    /// Creates a minimal tokenizer with byte-level tokens (256 bytes + special tokens).
    /// Useful for testing and as a fallback when no BPE vocab is loaded.
    pub fn initByteLevel(allocator: std.mem.Allocator) !Tokenizer {
        var tok = Tokenizer.init(allocator);
        const btu = byteToUnicode();

        for (0..256) |i| {
            const cp = btu[i];
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try tok.addToken(buf[0..n], @intCast(i));
        }

        try tok.addToken(EOS_TOKEN, EOS_TOKEN_ID);
        try tok.addToken(IM_START_TOKEN, IM_START_TOKEN_ID);
        try tok.addToken(IM_END_TOKEN, IM_END_TOKEN_ID);

        return tok;
    }

    /// Loads a full Qwen1.5 BPE tokenizer from vocab.json and merges.txt files.
    /// model_dir should contain vocab.json and merges.txt.
    /// Returns a fully initialized tokenizer with ~151K tokens and merge rules.
    pub fn loadQwenTokenizer(allocator: std.mem.Allocator, model_dir: []const u8) !Tokenizer {
        var tok = Tokenizer.init(allocator);

        var vocab_path = std.ArrayList(u8).init(allocator);
        defer vocab_path.deinit();
        try vocab_path.appendSlice(model_dir);
        try vocab_path.appendSlice("/vocab.json");

        var merges_path = std.ArrayList(u8).init(allocator);
        defer merges_path.deinit();
        try merges_path.appendSlice(model_dir);
        try merges_path.appendSlice("/merges.txt");

        const vocab_count = try tok.loadFromJsonFile(vocab_path.items, null);

        const merge_count = try tok.loadMergesFromFile(merges_path.items, null);

        // Ensure special tokens are registered
        if (tok.vocab.get(EOS_TOKEN) == null) {
            try tok.addToken(EOS_TOKEN, EOS_TOKEN_ID);
        }
        if (tok.vocab.get(IM_START_TOKEN) == null) {
            try tok.addToken(IM_START_TOKEN, IM_START_TOKEN_ID);
        }
        if (tok.vocab.get(IM_END_TOKEN) == null) {
            try tok.addToken(IM_END_TOKEN, IM_END_TOKEN_ID);
        }

        _ = vocab_count;
        _ = merge_count;
        return tok;
    }
};

// =============================================================================
// Helper functions
// =============================================================================

fn isPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn isOtherWhitespace(c: u8) bool {
    return c == '\n' or c == '\t' or c == '\r';
}

// =============================================================================
// Tests
// =============================================================================

test "byte-to-unicode mapping" {
    const btu = byteToUnicode();
    try std.testing.expectEqual(@as(u21, 33), btu[33]);
    try std.testing.expectEqual(@as(u21, 126), btu[126]);
    try std.testing.expectEqual(@as(u21, 256), btu[0]); // byte 0 maps to 256
    try std.testing.expectEqual(@as(u21, 288), btu[32]); // space maps to 288
    try std.testing.expect(btu[10] >= 256); // newline
}

test "tokenizer init and deinit" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();
    try std.testing.expectEqual(@as(u32, EOS_TOKEN_ID), tok.eos_token_id);
}

test "initByteLevel with page allocator" {
    var tok = try Tokenizer.initByteLevel(std.heap.page_allocator);
    defer tok.deinit();
    try std.testing.expect(tok.vocab.count() >= 256);
}

test "initByteLevel with testing allocator" {
    var tok = try Tokenizer.initByteLevel(std.testing.allocator);
    defer tok.deinit();
    try std.testing.expect(tok.vocab.count() >= 256);
}

test "encode only no decode" {
    const allocator = std.testing.allocator;
    var tok = try Tokenizer.initByteLevel(allocator);
    defer tok.deinit();

    const token_ids = try tok.encode("Hi");
    defer allocator.free(token_ids);
    try std.testing.expect(token_ids.len > 0);
}

test "decode only" {
    const allocator = std.testing.allocator;
    var tok = try Tokenizer.initByteLevel(allocator);
    defer tok.deinit();

    const ids = [_]u32{ 72, 105 }; // 'H', 'i' byte values
    const decoded = try tok.decode(&ids);
    defer allocator.free(decoded);
}

test "byte-level tokenizer encode/decode round-trip" {
    const allocator = std.testing.allocator;
    var tok = try Tokenizer.initByteLevel(allocator);
    defer tok.deinit();

    const text = "Hello";
    const token_ids = try tok.encode(text);
    defer allocator.free(token_ids);

    try std.testing.expect(token_ids.len > 0);

    const decoded = try tok.decode(token_ids);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "special token handling" {
    const allocator = std.testing.allocator;
    var tok = try Tokenizer.initByteLevel(allocator);
    defer tok.deinit();

    const text = "<|im_start|>user\nHello<|im_end|>";
    const token_ids = try tok.encode(text);
    defer allocator.free(token_ids);

    var found_start = false;
    var found_end = false;
    for (token_ids) |id| {
        if (id == IM_START_TOKEN_ID) found_start = true;
        if (id == IM_END_TOKEN_ID) found_end = true;
    }
    try std.testing.expect(found_start);
    try std.testing.expect(found_end);
}

test "BPE merge reduces token count" {
    const allocator = std.testing.allocator;
    var tok = Tokenizer.init(allocator);
    defer tok.deinit();

    const btu = byteToUnicode();
    for (0..256) |i| {
        const cp = btu[i];
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try tok.addToken(buf[0..n], @intCast(i));
    }

    try tok.addToken("ab", 256);

    const a_cp = btu['a'];
    const b_cp = btu['b'];
    var a_buf: [4]u8 = undefined;
    var b_buf: [4]u8 = undefined;
    const a_len = std.unicode.utf8Encode(a_cp, &a_buf) catch 1;
    const b_len = std.unicode.utf8Encode(b_cp, &b_buf) catch 1;
    const merge_str = try std.fmt.allocPrint(allocator, "{s}{s}", .{ a_buf[0..a_len], b_buf[0..b_len] });
    defer allocator.free(merge_str);
    try tok.addMerge(merge_str, 0);

    const token_ids = try tok.encode("ab");
    defer allocator.free(token_ids);

    try std.testing.expectEqual(@as(usize, 1), token_ids.len);
    try std.testing.expectEqual(@as(u32, 256), token_ids[0]);
}

test "decode with special tokens preserves them" {
    const allocator = std.testing.allocator;
    var tok = try Tokenizer.initByteLevel(allocator);
    defer tok.deinit();

    const ids = [_]u32{ IM_START_TOKEN_ID, IM_END_TOKEN_ID };
    const decoded = try tok.decode(&ids);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("<|im_start|><|im_end|>", decoded);
}

test "loadFromTxtFile loads production vocabulary subset" {
    const allocator = std.testing.allocator;
    var tok = Tokenizer.init(allocator);
    defer tok.deinit();

    const count = tok.loadFromTxtFile(".foundations/RamseyLLM/vocabs/vocab-128k.txt", 50) catch |err| {
        if (err == error.FileNotFound) return; // Skip if vocab file not present
        return err;
    };
    try std.testing.expect(count > 0);
    try std.testing.expect(tok.vocab.count() > 0);
}

test "getRamseyVocabPathForLevel returns correct paths" {
    try std.testing.expectEqualStrings(".foundations/RamseyLLM/vocabs/vocab-128k.txt", getRamseyVocabPathForLevel(0).?);
    try std.testing.expectEqualStrings(".foundations/RamseyLLM/vocabs/vocab-256k.txt", getRamseyVocabPathForLevel(1).?);
    try std.testing.expectEqualStrings(".foundations/RamseyLLM/vocabs/vocab-512k.txt", getRamseyVocabPathForLevel(2).?);
    try std.testing.expectEqualStrings(".foundations/RamseyLLM/vocabs/vocab-1m.txt", getRamseyVocabPathForLevel(3).?);
    try std.testing.expectEqual(null, getRamseyVocabPathForLevel(4));
}

test "loadRamseyVocab loads correctly using specifiers" {
    const allocator = std.testing.allocator;
    var tok = Tokenizer.init(allocator);
    defer tok.deinit();

    const count = tok.loadRamseyVocab("128k", 100) catch |err| {
        if (err == error.FileNotFound) return; // Skip if vocab file not present
        return err;
    };
    try std.testing.expectEqual(@as(usize, 100), count);
    try std.testing.expectEqual(@as(usize, 100), tok.vocab.count());
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
