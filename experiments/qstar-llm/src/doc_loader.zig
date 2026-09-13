//! doc_loader.zig — Recursive directory walker + document preprocessor.
//!
//! Walks directories recursively, reads .md/.txt/.tex files, strips
//! markdown/LaTeX formatting, and extracts clean prose sentences.
//! Used by the corpus training pipeline to ingest large document sets.

const std = @import("std");

pub const DocStats = struct {
    files_scanned: usize = 0,
    files_read: usize = 0,
    sentences_extracted: usize = 0,
    bytes_read: usize = 0,
};

pub const DocEntry = struct {
    path: []const u8,
    content: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DocEntry) void {
        self.allocator.free(self.content);
        self.allocator.free(self.path);
    }
};

/// Check if a file extension is supported.
fn isSupportedFile(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".md")) return true;
    if (std.mem.endsWith(u8, name, ".txt")) return true;
    if (std.mem.endsWith(u8, name, ".tex")) return true;
    if (std.mem.endsWith(u8, name, ".tex.md")) return true;
    if (std.mem.endsWith(u8, name, ".zig")) return true;
    if (std.mem.endsWith(u8, name, ".csv")) return true;
    if (std.mem.endsWith(u8, name, ".json")) return true;
    if (std.mem.endsWith(u8, name, ".py")) return true;
    if (std.mem.endsWith(u8, name, ".js")) return true;
    if (std.mem.endsWith(u8, name, ".ts")) return true;
    if (std.mem.endsWith(u8, name, ".rs")) return true;
    if (std.mem.endsWith(u8, name, ".c")) return true;
    if (std.mem.endsWith(u8, name, ".h")) return true;
    if (std.mem.endsWith(u8, name, ".cpp")) return true;
    if (std.mem.endsWith(u8, name, ".hpp")) return true;
    if (std.mem.endsWith(u8, name, ".cs")) return true;
    if (std.mem.endsWith(u8, name, ".go")) return true;
    if (std.mem.endsWith(u8, name, ".java")) return true;
    if (std.mem.endsWith(u8, name, ".rb")) return true;
    if (std.mem.endsWith(u8, name, ".sh")) return true;
    if (std.mem.endsWith(u8, name, ".yml")) return true;
    if (std.mem.endsWith(u8, name, ".yaml")) return true;
    if (std.mem.endsWith(u8, name, ".xml")) return true;
    if (std.mem.endsWith(u8, name, ".html")) return true;
    if (std.mem.endsWith(u8, name, ".css")) return true;
    if (std.mem.endsWith(u8, name, ".toml")) return true;
    if (std.mem.endsWith(u8, name, ".cfg")) return true;
    if (std.mem.endsWith(u8, name, ".ini")) return true;
    if (std.mem.endsWith(u8, name, ".sql")) return true;
    if (std.mem.endsWith(u8, name, ".lua")) return true;
    if (std.mem.endsWith(u8, name, ".php")) return true;
    if (std.mem.endsWith(u8, name, ".swift")) return true;
    if (std.mem.endsWith(u8, name, ".kt")) return true;
    if (std.mem.endsWith(u8, name, ".dart")) return true;
    if (std.mem.endsWith(u8, name, ".scala")) return true;
    if (std.mem.endsWith(u8, name, ".clj")) return true;
    if (std.mem.endsWith(u8, name, ".ex")) return true;
    if (std.mem.endsWith(u8, name, ".exs")) return true;
    if (std.mem.endsWith(u8, name, ".erl")) return true;
    if (std.mem.endsWith(u8, name, ".hs")) return true;
    if (std.mem.endsWith(u8, name, ".ml")) return true;
    if (std.mem.endsWith(u8, name, ".fs")) return true;
    if (std.mem.endsWith(u8, name, ".nim")) return true;
    if (std.mem.endsWith(u8, name, ".v")) return true;
    if (std.mem.endsWith(u8, name, ".d")) return true;
    if (std.mem.endsWith(u8, name, ".asm")) return true;
    if (std.mem.endsWith(u8, name, ".s")) return true;
    return false;
}

/// Recursively collect all supported document file paths in a directory.
pub fn collectFilePaths(allocator: std.mem.Allocator, root_dir: []const u8) !std.ArrayList([]u8) {
    var paths = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }
    try walkDir(allocator, root_dir, &paths);
    return paths;
}

fn walkDir(allocator: std.mem.Allocator, dir_path: []const u8, paths: *std.ArrayList([]u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name[0] == '.') continue; // Skip hidden files/dirs
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        if (entry.kind == .directory) {
            walkDir(allocator, full_path, paths) catch |err| {
                std.debug.print("  Warning: cannot read dir {s}: {s}\n", .{ full_path, @errorName(err) });
                allocator.free(full_path);
            };
            allocator.free(full_path);
        } else if (entry.kind == .file and isSupportedFile(entry.name)) {
            try paths.append(full_path);
        } else {
            allocator.free(full_path);
        }
    }
}

/// Read a file fully into an allocated buffer.
pub inline fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 50_000_000) return error.FileTooLarge; // 50MB limit
    const buf = try allocator.alloc(u8, stat.size);
    _ = try file.readAll(buf);
    return buf;
}

/// Strip markdown formatting and extract clean text.
/// Removes: code blocks, inline code, headers markers, YAML front matter,
/// HTML tags, markdown links (keep text), image references, URLs.
pub fn stripMarkdown(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    var in_code_block = false;
    var in_yaml = false;
    var yaml_checked = false;

    while (i < raw.len) {
        // YAML front matter detection (first thing in file)
        if (!yaml_checked) {
            yaml_checked = true;
            if (i + 2 < raw.len and raw[i] == '-' and raw[i + 1] == '-' and raw[i + 2] == '-') {
                in_yaml = true;
                i += 3;
                continue;
            }
        }
        if (in_yaml) {
            if (i + 2 < raw.len and raw[i] == '-' and raw[i + 1] == '-' and raw[i + 2] == '-') {
                in_yaml = false;
                i += 3;
                // Skip rest of line
                while (i < raw.len and raw[i] != '\n') i += 1;
                if (i < raw.len) i += 1;
                continue;
            }
            i += 1;
            continue;
        }

        // Code block toggle (``` or ~~~)
        if (i + 2 < raw.len and (raw[i] == '`' or raw[i] == '~') and raw[i + 1] == raw[i] and raw[i + 2] == raw[i]) {
            in_code_block = !in_code_block;
            // Skip to end of line
            while (i < raw.len and raw[i] != '\n') i += 1;
            if (i < raw.len) i += 1;
            continue;
        }
        if (in_code_block) {
            if (raw[i] == '\n') {
                try out.append('\n');
            }
            i += 1;
            continue;
        }

        // Inline code (backticks)
        if (raw[i] == '`') {
            i += 1;
            while (i < raw.len and raw[i] != '`') i += 1;
            if (i < raw.len) i += 1;
            try out.append(' ');
            continue;
        }

        // Header markers (#, ##, etc.) — skip the # chars, keep text
        if (raw[i] == '#' and (i == 0 or raw[i - 1] == '\n')) {
            while (i < raw.len and raw[i] == '#') i += 1;
            if (i < raw.len and raw[i] == ' ') i += 1;
            continue;
        }

        // Bold/italic markers (*, **, _, __)
        if (raw[i] == '*' or raw[i] == '_') {
            i += 1;
            if (i < raw.len and raw[i] == raw[i - 1]) i += 1;
            continue;
        }

        // Markdown links [text](url) — keep text, drop url
        if (raw[i] == '[') {
            // Find closing ]
            var j = i + 1;
            while (j < raw.len and raw[j] != ']') j += 1;
            if (j < raw.len and j + 1 < raw.len and raw[j + 1] == '(') {
                // Extract link text
                try out.appendSlice(raw[i + 1 .. j]);
                try out.append(' ');
                // Skip to closing )
                j += 2;
                while (j < raw.len and raw[j] != ')') j += 1;
                if (j < raw.len) j += 1;
                i = j;
                continue;
            }
        }

        // Image references ![alt](url) — skip entirely
        if (raw[i] == '!' and i + 1 < raw.len and raw[i + 1] == '[') {
            var j = i + 2;
            while (j < raw.len and raw[j] != ']') j += 1;
            if (j < raw.len and j + 1 < raw.len and raw[j + 1] == '(') {
                while (j < raw.len and raw[j] != ')') j += 1;
                if (j < raw.len) j += 1;
                i = j;
                continue;
            }
        }

        // HTML tags <...>
        if (raw[i] == '<') {
            while (i < raw.len and raw[i] != '>') i += 1;
            if (i < raw.len) i += 1;
            continue;
        }

        // Blockquote markers >
        if (raw[i] == '>' and (i == 0 or raw[i - 1] == '\n')) {
            i += 1;
            if (i < raw.len and raw[i] == ' ') i += 1;
            continue;
        }

        // List markers (-, *, +, digit.)
        if ((raw[i] == '-' or raw[i] == '*' or raw[i] == '+') and i + 1 < raw.len and raw[i + 1] == ' ' and (i == 0 or raw[i - 1] == '\n')) {
            i += 2;
            continue;
        }

        // LaTeX commands \word — keep the word, drop the backslash
        if (raw[i] == '\\') {
            i += 1;
            // Skip LaTeX command name
            while (i < raw.len and (std.ascii.isAlphabetic(raw[i]) or raw[i] == '@')) i += 1;
            // Skip optional braces/args
            if (i < raw.len and raw[i] == '{') {
                var depth: usize = 1;
                i += 1;
                while (i < raw.len and depth > 0) {
                    if (raw[i] == '{') depth += 1;
                    if (raw[i] == '}') depth -= 1;
                    if (depth > 0) try out.append(raw[i]);
                    i += 1;
                }
            }
            try out.append(' ');
            continue;
        }

        // Table separator lines (|---|---|)
        if (raw[i] == '|' and (i == 0 or raw[i - 1] == '\n')) {
            var j = i;
            while (j < raw.len and raw[j] != '\n') {
                if (raw[j] != '|' and raw[j] != '-' and raw[j] != ' ' and raw[j] != ':') break;
                j += 1;
            }
            if (j < raw.len and raw[j] == '\n') {
                i = j + 1;
                continue;
            }
        }

        // Pipe characters in tables → space
        if (raw[i] == '|') {
            try out.append(' ');
            i += 1;
            continue;
        }

        // Horizontal rules (---, ***)
        if (raw[i] == '-' and i + 2 < raw.len and raw[i + 1] == '-' and raw[i + 2] == '-' and (i == 0 or raw[i - 1] == '\n')) {
            while (i < raw.len and raw[i] != '\n') i += 1;
            if (i < raw.len) i += 1;
            try out.append('\n');
            continue;
        }

        try out.append(raw[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

/// Extract clean prose sentences from preprocessed text.
/// A sentence is text between sentence-ending punctuation (. ! ?) or newlines,
/// with length >= min_len and alpha ratio >= min_alpha_ratio.
pub fn extractSentences(
    allocator: std.mem.Allocator,
    text: []const u8,
    min_len: usize,
    min_alpha_ratio: f64,
    out_sentences: *std.ArrayList([]const u8),
) !void {
    var start: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        // Sentence boundary
        if (text[i] == '.' or text[i] == '!' or text[i] == '?' or text[i] == '\n') {
            const sent_raw = text[start..i];
            const trimmed = std.mem.trim(u8, sent_raw, " \t\r\n");

            if (trimmed.len >= min_len) {
                // Check alpha ratio
                var alpha_count: usize = 0;
                for (trimmed) |c| {
                    if (std.ascii.isAlphabetic(c) or c == ' ' or c == ',' or c == ';' or c == ':' or c == '\'' or c == '-') alpha_count += 1;
                }
                const ratio = @as(f64, @floatFromInt(alpha_count)) / @as(f64, @floatFromInt(trimmed.len));
                if (ratio >= min_alpha_ratio) {
                    try out_sentences.append(trimmed);
                }
            }

            start = i + 1;
        }
        i += 1;
    }

    // Handle trailing text
    if (start < text.len) {
        const sent_raw = text[start..];
        const trimmed = std.mem.trim(u8, sent_raw, " \t\r\n");
        if (trimmed.len >= min_len) {
            var alpha_count: usize = 0;
            for (trimmed) |c| {
                if (std.ascii.isAlphabetic(c) or c == ' ' or c == ',' or c == ';' or c == ':' or c == '\'' or c == '-') alpha_count += 1;
            }
            const ratio = @as(f64, @floatFromInt(alpha_count)) / @as(f64, @floatFromInt(trimmed.len));
            if (ratio >= min_alpha_ratio) {
                try out_sentences.append(trimmed);
            }
        }
    }
    _ = allocator;
}

/// Process a single file: read, strip markdown, extract sentences, return as joined text.
/// Caller must free the returned slice.
pub fn processFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try readFile(allocator, path);
    defer allocator.free(raw);

    const cleaned = try stripMarkdown(allocator, raw);
    defer allocator.free(cleaned);

    var sentences = std.ArrayList([]const u8).init(allocator);
    defer sentences.deinit();

    try extractSentences(allocator, cleaned, 15, 0.5, &sentences);

    // Join sentences with ". " and add trailing "."
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (sentences.items, 0..) |sent, idx| {
        if (idx > 0) try result.appendSlice(". ");
        try result.appendSlice(sent);
    }
    if (result.items.len > 0) try result.append('.');

    return result.toOwnedSlice();
}

/// Process all files in a directory, calling the callback for each file's extracted text.
pub fn processDirectory(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    callback: *const fn (path: []const u8, text: []const u8, userdata: ?*anyopaque) void,
    userdata: ?*anyopaque,
) !DocStats {
    var stats = DocStats{};

    var paths = try collectFilePaths(allocator, root_dir);
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    stats.files_scanned = paths.items.len;

    for (paths.items) |path| {
        const text = processFile(allocator, path) catch |err| {
            std.debug.print("  Warning: cannot process {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer allocator.free(text);

        stats.files_read += 1;
        stats.bytes_read += text.len;

        callback(path, text, userdata);

        if (stats.files_read % 50 == 0) {
            std.debug.print("  Processed {d}/{d} files...\n", .{ stats.files_read, stats.files_scanned });
        }
    }

    return stats;
}

// =============================================================================
// Tests
// =============================================================================

test "doc_loader: isSupportedFile recognizes extensions" {
    try std.testing.expect(isSupportedFile("readme.md"));
    try std.testing.expect(isSupportedFile("notes.txt"));
    try std.testing.expect(isSupportedFile("paper.tex"));
    try std.testing.expect(!isSupportedFile("image.png"));
    try std.testing.expect(isSupportedFile("data.json"));
    try std.testing.expect(isSupportedFile("data.csv"));
    try std.testing.expect(isSupportedFile("script.py"));
    try std.testing.expect(!isSupportedFile("binary.bin"));
}

test "doc_loader: stripMarkdown removes code blocks" {
    const allocator = std.testing.allocator;
    const input = "Before\n```zig\nconst x = 1;\n```\nAfter";
    const result = try stripMarkdown(allocator, input);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "After") != null);
}

test "doc_loader: stripMarkdown removes header markers" {
    const allocator = std.testing.allocator;
    const input = "# Title\n## Subtitle\nSome text";
    const result = try stripMarkdown(allocator, input);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "#") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Subtitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Some text") != null);
}

test "doc_loader: stripMarkdown extracts link text" {
    const allocator = std.testing.allocator;
    const input = "See [this link](http://example.com) for details";
    const result = try stripMarkdown(allocator, input);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "this link") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "http://example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "for details") != null);
}

test "doc_loader: extractSentences filters by min length and alpha ratio" {
    const allocator = std.testing.allocator;
    var sentences = std.ArrayList([]const u8).init(allocator);
    defer sentences.deinit();

    const text = "This is a valid sentence with enough words. Short. Another good sentence here with words.";
    try extractSentences(allocator, text, 15, 0.5, &sentences);

    try std.testing.expect(sentences.items.len >= 2);
    for (sentences.items) |s| {
        try std.testing.expect(s.len >= 15);
    }
}

test "doc_loader: DocStats default values" {
    const stats = DocStats{};
    try std.testing.expectEqual(@as(usize, 0), stats.files_scanned);
    try std.testing.expectEqual(@as(usize, 0), stats.files_read);
    try std.testing.expectEqual(@as(usize, 0), stats.sentences_extracted);
    try std.testing.expectEqual(@as(usize, 0), stats.bytes_read);
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
