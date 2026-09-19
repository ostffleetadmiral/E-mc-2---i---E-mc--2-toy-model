//! Web fact-checking for generated/training text.
//!
//! Verifies teacher-generated sentences against a fetched reference source
//! before they enter the corpus. Three layers, in cost order:
//!
//!   1. Groundedness filter — deterministic integer scoring: fraction of a
//!      sentence's content words (alpha tokens, len >= 4) present in the
//!      reference text. Per-mille threshold, no floats in the decision path.
//!   2. Ollama judge spot-check — a bounded 1-in-N YES/NO verdict against a
//!      reference excerpt, applied to a sample of kept sentences.
//!   3. Reference resolution — local cache (datasets/factcheck_refs/),
//!      Wikipedia API (opensearch + extracts), then a headless-Playwright
//!      child process (scripts/web_fetch.py) for pages the API misses.
//!
//! All filesystem/process/HTTP paths are pruned on freestanding targets.
//! The groundedness score is a framework-internal grounding heuristic —
//! it measures support by the fetched reference, not absolute truth.

const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    enabled: bool = true,
    /// Per-mille groundedness threshold (550 = 55% of content words must
    /// appear in the reference text).
    threshold_mille: u16 = 550,
    /// Judge 1-in-N kept sentences via Ollama (0 disables spot-checks).
    judge_rate: u8 = 10,
    /// Directory holding pre-fetched/cached reference texts.
    cache_dir: []const u8 = "datasets/factcheck_refs",
    /// When no reference can be resolved: keep sentences (true) or drop them.
    keep_on_no_reference: bool = true,
    /// Playwright child-process timeout.
    playwright_timeout_ms: u32 = 45_000,
    verbose: bool = false,
};

pub const VerifiedText = struct {
    text: []u8,
    kept: usize,
    dropped: usize,
    judged_ok: usize,
    judged_fail: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VerifiedText) void {
        self.allocator.free(self.text);
    }
};

const MIN_CONTENT_WORD: usize = 4;

/// Scores `sentence` against `ref_set`: per-mille of content words covered.
/// A sentence with zero content words scores 0 (unverifiable by overlap).
pub fn groundednessScore(sentence: []const u8, ref_set: *const std.StringHashMap(void)) u16 {
    var total: usize = 0;
    var covered: usize = 0;
    var it = std.mem.tokenizeAny(u8, sentence, " \t\n\r.,;:!?\"'()[]{}0123456789");
    var buf: [64]u8 = undefined;
    while (it.next()) |tok| {
        if (tok.len < MIN_CONTENT_WORD) continue;
        if (!allAlpha(tok)) continue;
        total += 1;
        if (tok.len <= buf.len) {
            const lower = std.ascii.lowerString(&buf, tok);
            if (ref_set.contains(lower)) covered += 1;
        }
    }
    if (total == 0) return 0;
    return @intCast(covered * 1000 / total);
}

fn allAlpha(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

/// Builds a lowercased content-word set from reference text.
pub fn buildReferenceSet(allocator: std.mem.Allocator, reference: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();
    var it = std.mem.tokenizeAny(u8, reference, " \t\n\r.,;:!?\"'()[]{}0123456789");
    while (it.next()) |tok| {
        if (tok.len < MIN_CONTENT_WORD or tok.len > 64) continue;
        if (!allAlpha(tok)) continue;
        const lower = try std.ascii.allocLowerString(allocator, tok);
        try set.put(lower, {});
    }
    return set;
}

/// Filters `text` to sentences grounded in `reference`. Rejoins kept
/// sentences with ". " terminators. When `reference` is null/empty the
/// keep_on_no_reference policy applies.
pub fn verifyText(
    allocator: std.mem.Allocator,
    text: []const u8,
    reference: ?[]const u8,
    cfg: Config,
) !VerifiedText {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var kept: usize = 0;
    var dropped: usize = 0;

    const ref = reference orelse "";
    if (ref.len == 0) {
        if (cfg.keep_on_no_reference) {
            try out.appendSlice(text);
            return .{ .text = try out.toOwnedSlice(), .kept = 1, .dropped = 0, .judged_ok = 0, .judged_fail = 0, .allocator = allocator };
        }
        return .{ .text = try out.toOwnedSlice(), .kept = 0, .dropped = 1, .judged_ok = 0, .judged_fail = 0, .allocator = allocator };
    }

    var ref_set = try buildReferenceSet(allocator, ref);
    defer {
        var kit = ref_set.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        ref_set.deinit();
    }

    var sent_it = std.mem.splitAny(u8, text, ".\n");
    while (sent_it.next()) |sent| {
        const trimmed = std.mem.trim(u8, sent, " \t\r");
        if (trimmed.len < 15 or trimmed.len > 500) continue;
        const score = groundednessScore(trimmed, &ref_set);
        if (score >= cfg.threshold_mille) {
            kept += 1;
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(trimmed);
            try out.append('.');
        } else {
            dropped += 1;
            if (cfg.verbose) {
                std.debug.print("    [fc] dropped ({d}/1000): {s}\n", .{ score, trimmed[0..@min(trimmed.len, 80)] });
            }
        }
    }

    return .{ .text = try out.toOwnedSlice(), .kept = kept, .dropped = dropped, .judged_ok = 0, .judged_fail = 0, .allocator = allocator };
}

/// Builds the YES/NO judge prompt for a sentence against a reference
/// excerpt. Caller owns the returned slice.
pub fn buildJudgePrompt(
    allocator: std.mem.Allocator,
    sentence: []const u8,
    reference: []const u8,
) ![]u8 {
    const excerpt_len = @min(reference.len, 4000);
    return std.fmt.allocPrint(
        allocator,
        "Reference text:\n{s}\n\nClaim: {s}\n\nIs the claim supported by the reference text? Answer only YES or NO.",
        .{ reference[0..excerpt_len], sentence },
    );
}

/// Parses a judge model's response. The first YES/NO token wins; a
/// response with neither counts as supported (no evidence to reject).
pub fn judgeVerdict(response: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, response, " \t\n\r.,;:!?\"'()[]{}");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(tok, "no")) return false;
    }
    return true;
}

/// Judge callback: returns true when the sentence is supported by the
/// reference. `ctx` is caller-owned (e.g. a *const ollama.OllamaConfig).
pub const JudgeFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, sentence: []const u8, reference: []const u8) bool;

/// Samples `judge_rate`-in-N kept sentences through the judge; rejected
/// sentences are removed from `verified.text`. Rebuilds the text in place.
pub fn spotCheck(
    allocator: std.mem.Allocator,
    verified: *VerifiedText,
    judge_fn: JudgeFn,
    judge_ctx: *anyopaque,
    reference: []const u8,
    cfg: Config,
) !void {
    if (cfg.judge_rate == 0 or verified.text.len == 0) return;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var idx: usize = 0;
    var sent_it = std.mem.splitAny(u8, verified.text, ".\n");
    while (sent_it.next()) |sent| {
        const trimmed = std.mem.trim(u8, sent, " \t\r");
        if (trimmed.len == 0) continue;
        idx += 1;
        if (cfg.judge_rate > 1 and idx % cfg.judge_rate != 0) {
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(trimmed);
            try out.append('.');
            continue;
        }
        if (judge_fn(judge_ctx, allocator, trimmed, reference)) {
            verified.judged_ok += 1;
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(trimmed);
            try out.append('.');
        } else {
            verified.judged_fail += 1;
            if (cfg.verbose) {
                std.debug.print("    [fc] judge rejected: {s}\n", .{trimmed[0..@min(trimmed.len, 80)]});
            }
        }
    }
    allocator.free(verified.text);
    verified.text = try out.toOwnedSlice();
    verified.kept = verified.judged_ok + (idx - verified.judged_ok - verified.judged_fail);
}

// =============================================================================
// Reference resolution
// =============================================================================

/// Lowercase filesystem-safe slug: alnum runs joined by '_', max 80 chars.
pub fn slugify(allocator: std.mem.Allocator, topic: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var prev_us = false;
    for (topic) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(std.ascii.toLower(c));
            prev_us = false;
        } else if (!prev_us and out.items.len > 0) {
            try out.append('_');
            prev_us = true;
        }
        if (out.items.len >= 80) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    return out.toOwnedSlice();
}

/// Resolves reference text for a topic. Order: cache file, Wikipedia API
/// (opensearch + extract), Playwright child fetch. Successful results are
/// written to the cache directory. Returns null when nothing resolves.
pub fn fetchReference(
    allocator: std.mem.Allocator,
    topic: []const u8,
    cfg: Config,
) !?[]u8 {
    if (builtin.os.tag == .freestanding) return null;

    const slug = try slugify(allocator, topic);
    defer allocator.free(slug);
    if (slug.len == 0) return null;

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ cfg.cache_dir, slug });
    defer allocator.free(cache_path);

    // 1. Cache hit
    if (std.fs.cwd().openFile(cache_path, .{})) |f| {
        defer f.close();
        const text = f.readToEndAlloc(allocator, 2 * 1024 * 1024) catch null;
        if (text) |t| {
            if (t.len > 200) return t;
            allocator.free(t);
        }
    } else |_| {}

    // 2. Wikipedia API: opensearch -> extract
    var ref: ?[]u8 = wikipediaReference(allocator, topic, cfg) catch null;
    if (ref) |r| {
        if (r.len < 200) {
            allocator.free(r);
            ref = null;
        }
    }

    // 3. Playwright headless fetch (JS-rendered / API-missed pages)
    if (ref == null) {
        ref = playwrightReference(allocator, topic, cfg) catch null;
    }

    if (ref) |r| {
        std.fs.cwd().makePath(cfg.cache_dir) catch {};
        if (std.fs.cwd().createFile(cache_path, .{})) |f| {
            defer f.close();
            f.writeAll(r) catch {};
        } else |_| {}
        return r;
    }
    return null;
}

/// Wikipedia opensearch -> plaintext extract. Question-form topics are
/// stripped of leading question/auxiliary words first (opensearch matches
/// titles literally); an empty opensearch result falls back to the
/// full-text `list=search` API before giving up.
fn wikipediaReference(allocator: std.mem.Allocator, topic: []const u8, cfg: Config) !?[]u8 {
    _ = cfg;
    const stripped = try stripQuestionWords(allocator, topic);
    defer allocator.free(stripped);
    const query_text = if (stripped.len > 0) stripped else topic;

    const query = try urlEncode(allocator, query_text);
    defer allocator.free(query);

    const search_url = try std.fmt.allocPrint(allocator, "https://en.wikipedia.org/w/api.php?action=opensearch&search={s}&limit=1&namespace=0&format=json", .{query});
    defer allocator.free(search_url);

    const search_body = try httpGet(allocator, search_url);
    defer allocator.free(search_body);

    // Response shape: ["query",["Title"],["desc"],["url"]]
    var title: ?[]const u8 = extractOpensearchTitle(search_body);

    if (title == null) {
        // Full-text search fallback — handles natural-language queries that
        // literal title matching misses.
        const sr_url = try std.fmt.allocPrint(allocator, "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch={s}&srlimit=1&format=json", .{query});
        defer allocator.free(sr_url);
        const sr_body = try httpGet(allocator, sr_url);
        defer allocator.free(sr_body);
        title = extractSearchTitle(sr_body);
    }

    const resolved = title orelse return null;
    const title_enc = try urlEncode(allocator, resolved);
    defer allocator.free(title_enc);

    const extract_url = try std.fmt.allocPrint(allocator, "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&format=json&redirects=1&titles={s}", .{title_enc});
    defer allocator.free(extract_url);

    const body = try httpGet(allocator, extract_url);
    defer allocator.free(body);
    return try extractJsonExtract(allocator, body);
}

const QUESTION_WORDS = [_][]const u8{
    "what",   "is",   "are",  "was",  "were",  "does",  "do",    "did",   "a",   "an",    "the",
    "how",    "why",  "who",  "whom", "whose", "when",  "where", "which", "can", "could", "would",
    "should", "many", "much", "tell", "me",    "about",
};

/// Removes leading question/auxiliary tokens and trailing punctuation.
/// Returns a slice rejoined with single spaces; caller owns it.
fn stripQuestionWords(allocator: std.mem.Allocator, topic: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var it = std.mem.tokenizeAny(u8, topic, " \t\r\n");
    var started = false;
    while (it.next()) |tok| {
        if (!started) {
            var lower_buf: [32]u8 = undefined;
            if (tok.len <= lower_buf.len) {
                const lower = std.ascii.lowerString(&lower_buf, tok);
                if (isQuestionWord(lower)) continue;
            }
            started = true;
        }
        if (out.items.len > 0) try out.append(' ');
        for (tok) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '\'') try out.append(c);
        }
    }
    return out.toOwnedSlice();
}

fn isQuestionWord(tok: []const u8) bool {
    for (QUESTION_WORDS) |qw| {
        if (std.mem.eql(u8, tok, qw)) return true;
    }
    return false;
}

/// Pulls the first "title":"X" out of a `list=search` response.
fn extractSearchTitle(body: []const u8) ?[]const u8 {
    const anchor = std.mem.indexOf(u8, body, "\"search\":[") orelse return null;
    const key = "\"title\":\"";
    const key_pos = std.mem.indexOfPos(u8, body, anchor, key) orelse return null;
    const start = key_pos + key.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    if (end == start) return null;
    return body[start..end];
}

/// Headless Playwright fetch via scripts/web_fetch.py. The script resolves
/// a topic to a Wikipedia page (or DDG fallback) and prints innerText.
fn playwrightReference(allocator: std.mem.Allocator, topic: []const u8, cfg: Config) !?[]u8 {
    _ = cfg;
    const stripped = try stripQuestionWords(allocator, topic);
    defer allocator.free(stripped);
    const query = if (stripped.len > 0) stripped else topic;
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "python3", "scripts/web_fetch.py", query },
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (text.len < 200) return null;
    return try allocator.dupe(u8, text);
}

/// Minimal URL query-string encoder.
fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(c);
        } else if (c == ' ') {
            try out.appendSlice("%20");
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 4 * 1024 * 1024,
    });
    if (result.status != .ok) return error.HttpError;
    return try body.toOwnedSlice();
}

/// Pulls the first title out of an opensearch JSON response
/// (["query",["Title",...],...]). Minimal scan, no full JSON parse.
fn extractOpensearchTitle(body: []const u8) ?[]const u8 {
    // Shape: ["query",["Title",...],["desc"],["url"]] — first title is the
    // first element of the second array.
    const m = std.mem.indexOf(u8, body, "\",[\"") orelse return null;
    const start = m + 4;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    if (end == start) return null;
    return body[start..end];
}

/// Extracts the "extract" field value from a Wikipedia query response.
/// The JSON may contain escaped sequences; we unescape \n, \", \\.
fn extractJsonExtract(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const key = "\"extract\":\"";
    const key_pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = key_pos + key.len;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < body.len) {
            i += 1;
            switch (body[i]) {
                'n' => try out.append('\n'),
                't' => try out.append('\t'),
                '"' => try out.append('"'),
                '\\' => try out.append('\\'),
                '/' => try out.append('/'),
                'u' => {
                    // \uXXXX — keep ASCII range, skip others
                    if (i + 4 < body.len) {
                        const cp = std.fmt.parseInt(u32, body[i + 1 .. i + 5], 16) catch 0;
                        if (cp < 128) try out.append(@intCast(cp));
                        i += 4;
                    }
                },
                else => try out.append(body[i]),
            }
        } else {
            try out.append(c);
        }
    }
    if (out.items.len == 0) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "groundednessScore counts covered content words" {
    const allocator = std.testing.allocator;
    var set = try buildReferenceSet(allocator, "The axolotl is a species of salamander native to Mexico. It remains aquatic throughout its life.");
    defer {
        var kit = set.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        set.deinit();
    }
    // Exact-form match (no stemming): axolotl/aquatic/salamander/mexico.
    const grounded = groundednessScore("The axolotl remains an aquatic salamander in Mexico.", &set);
    try std.testing.expect(grounded >= 600);
    const ungrounded = groundednessScore("Quantum entanglement violates classical Bell inequalities.", &set);
    try std.testing.expect(ungrounded < 200);
}

test "verifyText keeps grounded and drops ungrounded sentences" {
    const allocator = std.testing.allocator;
    const reference = "Honey is a sweet substance made by bees. It never spoils and has been found edible in ancient tombs.";
    const text = "Honey never spoils over time. The moon is made of green cheese entirely.";
    var v = try verifyText(allocator, text, reference, .{ .threshold_mille = 500 });
    defer v.deinit();
    try std.testing.expect(v.kept == 1);
    try std.testing.expect(v.dropped == 1);
    try std.testing.expect(std.mem.indexOf(u8, v.text, "Honey never spoils") != null);
}

test "verifyText keep_on_no_reference passes text through" {
    const allocator = std.testing.allocator;
    var v = try verifyText(allocator, "Anything at all here.", null, .{});
    defer v.deinit();
    try std.testing.expect(std.mem.indexOf(u8, v.text, "Anything at all") != null);
}

test "judgeVerdict parses YES/NO responses" {
    try std.testing.expect(judgeVerdict("YES"));
    try std.testing.expect(judgeVerdict("Yes, that is correct."));
    try std.testing.expect(!judgeVerdict("NO"));
    try std.testing.expect(!judgeVerdict("No. The claim is unsupported."));
    // Ambiguous responses default to supported.
    try std.testing.expect(judgeVerdict("I think so, maybe."));
    try std.testing.expect(judgeVerdict(""));
}

test "slugify produces filesystem-safe slugs" {
    const allocator = std.testing.allocator;
    const s = try slugify(allocator, "What is the Door to Hell?");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("what_is_the_door_to_hell", s);
}

test "extractOpensearchTitle pulls first result" {
    const body = "[\"honey\",[\"Honey\",\"Honeybee\"],[\"desc\"],[\"url\"]]";
    try std.testing.expectEqualStrings("Honey", extractOpensearchTitle(body).?);
}

test "stripQuestionWords removes leading question tokens" {
    const allocator = std.testing.allocator;
    const s = try stripQuestionWords(allocator, "What is a tardigrade?");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("tardigrade", s);
    const s2 = try stripQuestionWords(allocator, "How does a phonograph record sound?");
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("phonograph record sound", s2);
    const s3 = try stripQuestionWords(allocator, "Axolotl");
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("Axolotl", s3);
}

test "extractSearchTitle pulls title from list=search response" {
    const body = "{\"batchcomplete\":\"\",\"query\":{\"search\":[{\"ns\":0,\"title\":\"Phonograph\",\"snippet\":\"x\"}]}}";
    try std.testing.expectEqualStrings("Phonograph", extractSearchTitle(body).?);
}

test "extractJsonExtract unescapes extract field" {
    const allocator = std.testing.allocator;
    const body = "{\"query\":{\"pages\":{\"1\":{\"extract\":\"Line one.\\nLine two with \\\"quotes\\\".\"}}}}";
    const ex = (try extractJsonExtract(allocator, body)).?;
    defer allocator.free(ex);
    try std.testing.expect(std.mem.indexOf(u8, ex, "Line one.") != null);
    try std.testing.expect(std.mem.indexOf(u8, ex, "\nLine two") != null);
}
