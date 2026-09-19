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
    /// Minimum number of independent references a sentence must clear the
    /// threshold on. Degrades gracefully to the number actually resolved
    /// (min(min_sources, refs)).
    min_sources: u8 = 2,
    /// Judge 1-in-N kept sentences via Ollama (0 disables spot-checks).
    judge_rate: u8 = 10,
    /// Numeric consistency: a number appearing in a claim must appear in at
    /// least one reference, else the sentence is forced through the judge
    /// (or dropped when judging is unavailable). Catches hallucinated
    /// dates/quantities that word-overlap cannot.
    numeric_check: bool = true,
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
    /// Sentences that cleared the threshold on at least one reference but
    /// fewer than min_sources — corroboration-inconclusive; spotCheck
    /// routes them through the judge instead of dropping silently.
    borderline: std.ArrayList([]u8),
    kept: usize,
    dropped: usize,
    judged_ok: usize,
    judged_fail: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VerifiedText) void {
        self.allocator.free(self.text);
        for (self.borderline.items) |s| self.allocator.free(s);
        self.borderline.deinit();
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
    errdefer {
        var kit = set.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        set.deinit();
    }
    var it = std.mem.tokenizeAny(u8, reference, " \t\n\r.,;:!?\"'()[]{}0123456789");
    while (it.next()) |tok| {
        if (tok.len < MIN_CONTENT_WORD or tok.len > 64) continue;
        if (!allAlpha(tok)) continue;
        const lower = try std.ascii.allocLowerString(allocator, tok);
        const gop = try set.getOrPut(lower);
        if (gop.found_existing) allocator.free(lower);
    }
    return set;
}

/// Per-reference verification state: a content-word set per reference plus
/// a comma-stripped copy used for numeric matching. Shared between
/// verifyTextMulti and spotCheck so the sets are built once per topic.
pub const RefContext = struct {
    sets: []std.StringHashMap(void),
    normalized: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RefContext) void {
        for (self.sets) |*set| {
            var kit = set.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            set.deinit();
        }
        self.allocator.free(self.sets);
        for (self.normalized) |n| self.allocator.free(n);
        self.allocator.free(self.normalized);
    }
};

/// Builds a RefContext from resolved reference texts. Empty/short refs are
/// skipped so `ctx.count` reflects usable sources only.
pub fn buildRefContext(
    allocator: std.mem.Allocator,
    references: []const []const u8,
) !RefContext {
    var sets = std.ArrayList(std.StringHashMap(void)).init(allocator);
    defer sets.deinit();
    var normalized = std.ArrayList([]u8).init(allocator);
    defer normalized.deinit();

    for (references) |ref| {
        if (ref.len == 0) continue;
        var set = try buildReferenceSet(allocator, ref);
        errdefer {
            var kit = set.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            set.deinit();
        }
        try sets.append(set);
        try normalized.append(try normalizeNumeric(allocator, ref));
    }

    return .{
        .sets = try sets.toOwnedSlice(),
        .normalized = try normalized.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Strips commas so "2,000" and "2000" compare equal for numeric checks.
fn normalizeNumeric(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len);
    defer out.deinit();
    for (text) |c| {
        if (c != ',') try out.append(c);
    }
    return out.toOwnedSlice();
}

/// Extracts normalized digit tokens from a claim: "1,000" -> "1000",
/// "$5.5B" -> "5.5". Caller owns the list; slices point into a scratch
/// buffer owned by the caller via out.items — actually returns owned dupes.
fn extractClaimNumbers(allocator: std.mem.Allocator, sentence: []const u8) !std.ArrayList([]u8) {
    var nums = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (nums.items) |n| allocator.free(n);
        nums.deinit();
    }
    var it = std.mem.tokenizeAny(u8, sentence, " \t\n\r\"'()[]{};:");
    var buf: [64]u8 = undefined;
    while (it.next()) |tok| {
        if (tok.len > buf.len) continue;
        var n: usize = 0;
        var has_digit = false;
        for (tok) |c| {
            if (std.ascii.isDigit(c) or c == '.') {
                buf[n] = c;
                n += 1;
                if (std.ascii.isDigit(c)) has_digit = true;
            } else if (c == ',') {
                continue; // strip thousands separators
            }
        }
        if (!has_digit) continue;
        if (n > 0 and buf[n - 1] == '.') n -= 1; // trailing period
        if (n > 0 and buf[0] == '.') {
            std.mem.copyForwards(u8, buf[0 .. n - 1], buf[1..n]);
            n -= 1; // leading period
        }
        if (n == 0) continue;
        const num = std.mem.trim(u8, buf[0..n], ".");
        if (num.len == 0) continue;
        try nums.append(try allocator.dupe(u8, num));
    }
    return nums;
}

/// True when every number in `sentence` appears in at least one normalized
/// reference. Sentences without numbers always pass.
fn numbersCovered(sentence: []const u8, ctx: *const RefContext, allocator: std.mem.Allocator) bool {
    var nums = extractClaimNumbers(allocator, sentence) catch return true;
    defer {
        for (nums.items) |n| allocator.free(n);
        nums.deinit();
    }
    for (nums.items) |num| {
        var found = false;
        for (ctx.normalized) |ref| {
            if (std.mem.indexOf(u8, ref, num) != null) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Filters `text` to sentences corroborated across `references`: a sentence
/// must clear the groundedness threshold on at least
/// min(cfg.min_sources, available refs) independent references. When no
/// reference resolves, the keep_on_no_reference policy applies.
pub fn verifyTextMulti(
    allocator: std.mem.Allocator,
    text: []const u8,
    ctx: *const RefContext,
    cfg: Config,
) !VerifiedText {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var kept: usize = 0;
    var dropped: usize = 0;

    var borderline = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (borderline.items) |s| allocator.free(s);
        borderline.deinit();
    }

    if (ctx.sets.len == 0) {
        if (cfg.keep_on_no_reference) {
            try out.appendSlice(text);
            return .{ .text = try out.toOwnedSlice(), .borderline = borderline, .kept = 1, .dropped = 0, .judged_ok = 0, .judged_fail = 0, .allocator = allocator };
        }
        return .{ .text = try out.toOwnedSlice(), .borderline = borderline, .kept = 0, .dropped = 1, .judged_ok = 0, .judged_fail = 0, .allocator = allocator };
    }

    const needed: usize = @max(1, @min(@as(usize, cfg.min_sources), ctx.sets.len));

    var sent_it = std.mem.splitAny(u8, text, ".\n");
    while (sent_it.next()) |sent| {
        const trimmed = std.mem.trim(u8, sent, " \t\r");
        if (trimmed.len < 15 or trimmed.len > 500) continue;
        var pass: usize = 0;
        var best: u16 = 0;
        for (ctx.sets) |*set| {
            const score = groundednessScore(trimmed, set);
            if (score > best) best = score;
            if (score >= cfg.threshold_mille) pass += 1;
        }
        if (pass >= needed) {
            kept += 1;
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(trimmed);
            try out.append('.');
        } else if (pass >= 1 and needed > 1) {
            // Corroborated by some but not enough sources — borderline;
            // spotCheck routes these through the judge.
            try borderline.append(try allocator.dupe(u8, trimmed));
            if (cfg.verbose) {
                std.debug.print("    [fc] borderline ({d}/{d} refs, best {d}/1000): {s}\n", .{ pass, ctx.sets.len, best, trimmed[0..@min(trimmed.len, 80)] });
            }
        } else {
            dropped += 1;
            if (cfg.verbose) {
                std.debug.print("    [fc] dropped ({d}/{d} refs, best {d}/1000): {s}\n", .{ pass, ctx.sets.len, best, trimmed[0..@min(trimmed.len, 80)] });
            }
        }
    }

    return .{ .text = try out.toOwnedSlice(), .borderline = borderline, .kept = kept, .dropped = dropped, .judged_ok = 0, .judged_fail = 0, .allocator = allocator };
}

/// Single-reference convenience wrapper over verifyTextMulti.
pub fn verifyText(
    allocator: std.mem.Allocator,
    text: []const u8,
    reference: ?[]const u8,
    cfg: Config,
) !VerifiedText {
    const ref = reference orelse "";
    if (ref.len == 0) {
        var empty_refs = [_][]const u8{};
        var ctx = try buildRefContext(allocator, &empty_refs);
        defer ctx.deinit();
        return verifyTextMulti(allocator, text, &ctx, cfg);
    }
    var refs = [_][]const u8{ref};
    var cfg1 = cfg;
    if (cfg1.min_sources == 0) cfg1.min_sources = 1;
    var ctx = try buildRefContext(allocator, &refs);
    defer ctx.deinit();
    return verifyTextMulti(allocator, text, &ctx, cfg1);
}

/// Builds the YES/NO judge prompt for a sentence against reference
/// excerpts (concatenated, bounded to 4000 chars total). Caller owns the
/// returned slice.
pub fn buildJudgePrompt(
    allocator: std.mem.Allocator,
    sentence: []const u8,
    references: []const []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try out.appendSlice("Reference text:\n");
    var budget: usize = 4000;
    for (references, 0..) |ref, i| {
        if (budget == 0) break;
        if (i > 0) try out.appendSlice("\n---\n");
        const take = @min(ref.len, budget);
        try out.appendSlice(ref[0..take]);
        budget -= take;
    }
    try out.writer().print("\n\nClaim: {s}\n\nIs the claim supported by the reference text? Answer only YES or NO.", .{sentence});
    return out.toOwnedSlice();
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
/// references. `ctx` is caller-owned (e.g. a *const ollama.OllamaConfig).
pub const JudgeFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, sentence: []const u8, references: []const []const u8) bool;

/// Samples `judge_rate`-in-N kept sentences through the judge; rejected
/// sentences are removed from `verified.text`. When `cfg.numeric_check`
/// is on, sentences containing a number absent from every reference are
/// forced through the judge regardless of sampling (dropped outright when
/// no judge is available). Rebuilds the text in place.
pub fn spotCheck(
    allocator: std.mem.Allocator,
    verified: *VerifiedText,
    judge_fn: JudgeFn,
    judge_ctx: *anyopaque,
    references: []const []const u8,
    ctx: *const RefContext,
    cfg: Config,
) !void {
    if (verified.text.len == 0 and verified.borderline.items.len == 0) return;
    if (cfg.judge_rate == 0 and !cfg.numeric_check and verified.borderline.items.len == 0) return;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var idx: usize = 0;
    var main_ok: usize = 0;
    var main_fail: usize = 0;
    var sent_it = std.mem.splitAny(u8, verified.text, ".\n");
    while (sent_it.next()) |sent| {
        const trimmed = std.mem.trim(u8, sent, " \t\r");
        if (trimmed.len == 0) continue;
        idx += 1;

        // Numeric consistency: a claim's numbers must appear in some
        // reference. A miss forces a judge call regardless of sampling.
        var numeric_ok = true;
        if (cfg.numeric_check and ctx.sets.len > 0) {
            numeric_ok = numbersCovered(trimmed, ctx, allocator);
            if (!numeric_ok and cfg.judge_rate == 0) {
                main_fail += 1;
                if (cfg.verbose) {
                    std.debug.print("    [fc] numeric-miss dropped (no judge): {s}\n", .{trimmed[0..@min(trimmed.len, 80)]});
                }
                continue;
            }
        }

        const sampled = cfg.judge_rate > 0 and (cfg.judge_rate == 1 or idx % cfg.judge_rate == 0);
        if (!sampled and numeric_ok) {
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(trimmed);
            try out.append('.');
            continue;
        }
        if (judge_fn(judge_ctx, allocator, trimmed, references)) {
            main_ok += 1;
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(trimmed);
            try out.append('.');
        } else {
            main_fail += 1;
            if (cfg.verbose) {
                std.debug.print("    [fc] judge rejected: {s}\n", .{trimmed[0..@min(trimmed.len, 80)]});
            }
        }
    }
    // Borderline sentences (some-source corroboration) get a forced
    // judge verdict — semantic agreement can substitute for word overlap
    // across stylistically different references.
    var border_ok: usize = 0;
    var border_fail: usize = 0;
    for (verified.borderline.items) |sent| {
        if (cfg.judge_rate == 0) {
            border_fail += 1;
            continue;
        }
        if (judge_fn(judge_ctx, allocator, sent, references)) {
            border_ok += 1;
            if (out.items.len > 0) try out.append(' ');
            try out.appendSlice(sent);
            try out.append('.');
        } else {
            border_fail += 1;
            if (cfg.verbose) {
                std.debug.print("    [fc] judge rejected borderline: {s}\n", .{sent[0..@min(sent.len, 80)]});
            }
        }
    }
    for (verified.borderline.items) |s| allocator.free(s);
    verified.borderline.clearRetainingCapacity();

    allocator.free(verified.text);
    verified.text = try out.toOwnedSlice();
    verified.judged_ok += main_ok + border_ok;
    verified.judged_fail += main_fail + border_fail;
    verified.kept = (idx - main_fail) + border_ok;
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

/// Resolves up to `max_refs` independent reference texts for a topic.
/// Sources, in order: English Wikipedia extract, Simple English Wikipedia
/// extract (independent editorial text), then — only if no API source
/// resolved — a headless Playwright fetch. Each source is cached
/// separately under `<slug>.<key>.txt` (en also reads the legacy
/// `<slug>.txt`). Caller owns the list and each item.
pub fn fetchReferences(
    allocator: std.mem.Allocator,
    topic: []const u8,
    cfg: Config,
    max_refs: usize,
) !std.ArrayList([]u8) {
    var refs = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (refs.items) |r| allocator.free(r);
        refs.deinit();
    }
    if (builtin.os.tag == .freestanding) return refs;

    const slug = try slugify(allocator, topic);
    defer allocator.free(slug);
    if (slug.len == 0) return refs;

    const sources = [_]struct { key: []const u8, host: []const u8 }{
        .{ .key = "en", .host = "en.wikipedia.org" },
        .{ .key = "simple", .host = "simple.wikipedia.org" },
    };

    for (sources) |src| {
        if (refs.items.len >= max_refs) break;
        const cache_path = try std.fmt.allocPrint(allocator, "{s}/{s}.{s}.txt", .{ cfg.cache_dir, slug, src.key });
        defer allocator.free(cache_path);

        // Cache hit (en also reads the legacy <slug>.txt)
        if (loadCached(allocator, cache_path)) |cached| {
            try refs.append(cached);
            continue;
        }
        if (std.mem.eql(u8, src.key, "en")) {
            const legacy = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ cfg.cache_dir, slug });
            defer allocator.free(legacy);
            if (loadCached(allocator, legacy)) |cached| {
                try refs.append(cached);
                continue;
            }
        }

        var ref: ?[]u8 = wikipediaReference(allocator, topic, cfg, src.host) catch null;
        if (ref) |r| {
            if (r.len < 200) {
                allocator.free(r);
                ref = null;
            }
        }
        if (ref) |r| {
            cacheWrite(cfg.cache_dir, cache_path, r);
            try refs.append(r);
        }
    }

    // Playwright fallback — only when no API source resolved at all.
    if (refs.items.len == 0) {
        const web_path = try std.fmt.allocPrint(allocator, "{s}/{s}.web.txt", .{ cfg.cache_dir, slug });
        defer allocator.free(web_path);
        if (loadCached(allocator, web_path)) |cached| {
            try refs.append(cached);
        } else if (playwrightReference(allocator, topic, cfg) catch null) |r| {
            if (r.len >= 200) {
                cacheWrite(cfg.cache_dir, web_path, r);
                try refs.append(r);
            } else {
                allocator.free(r);
            }
        }
    }
    return refs;
}

fn loadCached(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const text = f.readToEndAlloc(allocator, 2 * 1024 * 1024) catch return null;
    if (text.len < 200) {
        allocator.free(text);
        return null;
    }
    return text;
}

fn cacheWrite(dir: []const u8, path: []const u8, text: []const u8) void {
    std.fs.cwd().makePath(dir) catch {};
    const f = std.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    f.writeAll(text) catch {};
}

/// Wikipedia opensearch -> plaintext extract. Question-form topics are
/// stripped of leading question/auxiliary words first (opensearch matches
/// titles literally); an empty opensearch result falls back to the
/// full-text `list=search` API before giving up.
fn wikipediaReference(allocator: std.mem.Allocator, topic: []const u8, cfg: Config, host: []const u8) !?[]u8 {
    _ = cfg;
    const stripped = try stripQuestionWords(allocator, topic);
    defer allocator.free(stripped);
    const query_text = if (stripped.len > 0) stripped else topic;

    const query = try urlEncode(allocator, query_text);
    defer allocator.free(query);

    const search_url = try std.fmt.allocPrint(allocator, "https://{s}/w/api.php?action=opensearch&search={s}&limit=1&namespace=0&format=json", .{ host, query });
    defer allocator.free(search_url);

    const search_body = try httpGet(allocator, search_url);
    defer allocator.free(search_body);

    // Response shape: ["query",["Title"],["desc"],["url"]]
    var title: ?[]const u8 = extractOpensearchTitle(search_body);

    if (title == null) {
        // Full-text search fallback — handles natural-language queries that
        // literal title matching misses.
        const sr_url = try std.fmt.allocPrint(allocator, "https://{s}/w/api.php?action=query&list=search&srsearch={s}&srlimit=1&format=json", .{ host, query });
        defer allocator.free(sr_url);
        const sr_body = try httpGet(allocator, sr_url);
        defer allocator.free(sr_body);
        title = extractSearchTitle(sr_body);
    }

    const resolved = title orelse return null;
    const title_enc = try urlEncode(allocator, resolved);
    defer allocator.free(title_enc);

    const extract_url = try std.fmt.allocPrint(allocator, "https://{s}/w/api.php?action=query&prop=extracts&explaintext=1&format=json&redirects=1&titles={s}", .{ host, title_enc });
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

test "verifyTextMulti requires corroboration across min_sources" {
    const allocator = std.testing.allocator;
    const ref_en = "Honey is a sweet substance made by bees. Honey never spoils and has been found edible in ancient Egyptian tombs.";
    const ref_simple = "Honey is a sweet food made by bees. Honey never spoils; jars found in ancient Egyptian tombs were still edible.";
    const refs = [_][]const u8{ ref_en, ref_simple };
    var ctx = try buildRefContext(allocator, &refs);
    defer ctx.deinit();

    const text = "Honey never spoils and was found edible in ancient Egyptian tombs. Quantum entanglement violates classical Bell inequalities completely.";
    var v = try verifyTextMulti(allocator, text, &ctx, .{ .threshold_mille = 500, .min_sources = 2 });
    defer v.deinit();
    try std.testing.expect(v.kept == 1);
    try std.testing.expect(v.dropped == 1);
    try std.testing.expect(std.mem.indexOf(u8, v.text, "Honey never spoils") != null);
}

test "verifyTextMulti degrades to available reference count" {
    const allocator = std.testing.allocator;
    const refs = [_][]const u8{"Honey is a sweet substance made by bees that never spoils over time."};
    var ctx = try buildRefContext(allocator, &refs);
    defer ctx.deinit();
    // min_sources=2 but only one ref resolved -> needed clamps to 1
    var v = try verifyTextMulti(allocator, "Honey never spoils over long periods of storage time.", &ctx, .{ .threshold_mille = 500, .min_sources = 2 });
    defer v.deinit();
    try std.testing.expect(v.kept == 1);
}

test "numbersCovered enforces numeric consistency" {
    const allocator = std.testing.allocator;
    const refs = [_][]const u8{"The tower is 324 metres tall and was completed in 1889, drawing over 7,000,000 visitors."};
    var ctx = try buildRefContext(allocator, &refs);
    defer ctx.deinit();

    try std.testing.expect(numbersCovered("The tower stands 324 metres tall.", &ctx, allocator));
    try std.testing.expect(numbersCovered("It was finished in 1889.", &ctx, allocator));
    // Comma normalization: 7,000,000 in ref must satisfy bare 7000000
    try std.testing.expect(numbersCovered("Over 7000000 people visit each year.", &ctx, allocator));
    // Hallucinated numbers fail
    try std.testing.expect(!numbersCovered("The tower is 500 metres tall.", &ctx, allocator));
    // No numbers -> always passes
    try std.testing.expect(numbersCovered("The tower is very tall.", &ctx, allocator));
}

fn stubJudgeAccept(ctx: *anyopaque, allocator: std.mem.Allocator, sentence: []const u8, references: []const []const u8) bool {
    _ = ctx;
    _ = allocator;
    _ = sentence;
    _ = references;
    return true;
}

fn stubJudgeReject(ctx: *anyopaque, allocator: std.mem.Allocator, sentence: []const u8, references: []const []const u8) bool {
    _ = ctx;
    _ = allocator;
    _ = sentence;
    _ = references;
    return false;
}

test "spotCheck forces numeric misses through the judge" {
    const allocator = std.testing.allocator;
    const refs = [_][]const u8{"The tower is 324 metres tall and was completed in 1889."};
    var ctx = try buildRefContext(allocator, &refs);
    defer ctx.deinit();
    var dummy: usize = 0;

    // judge_rate=0 + numeric miss -> dropped outright
    var v = try verifyTextMulti(allocator, "The tower stands 500 metres tall today.", &ctx, .{ .threshold_mille = 400 });
    defer v.deinit();
    try std.testing.expect(v.kept == 1);
    try spotCheck(allocator, &v, stubJudgeAccept, &dummy, &refs, &ctx, .{ .judge_rate = 0, .numeric_check = true });
    try std.testing.expect(v.judged_fail == 1);
    try std.testing.expect(v.text.len == 0);

    // numeric miss + judge that rescues -> kept
    var v2 = try verifyTextMulti(allocator, "The tower stands 500 metres tall today.", &ctx, .{ .threshold_mille = 400 });
    defer v2.deinit();
    try spotCheck(allocator, &v2, stubJudgeAccept, &dummy, &refs, &ctx, .{ .judge_rate = 10, .numeric_check = true });
    try std.testing.expect(v2.judged_ok == 1);

    // numeric miss + rejecting judge -> dropped
    var v3 = try verifyTextMulti(allocator, "The tower stands 500 metres tall today.", &ctx, .{ .threshold_mille = 400 });
    defer v3.deinit();
    try spotCheck(allocator, &v3, stubJudgeReject, &dummy, &refs, &ctx, .{ .judge_rate = 10, .numeric_check = true });
    try std.testing.expect(v3.judged_fail == 1);
    try std.testing.expect(v3.text.len == 0);
}

test "extractJsonExtract unescapes extract field" {
    const allocator = std.testing.allocator;
    const body = "{\"query\":{\"pages\":{\"1\":{\"extract\":\"Line one.\\nLine two with \\\"quotes\\\".\"}}}}";
    const ex = (try extractJsonExtract(allocator, body)).?;
    defer allocator.free(ex);
    try std.testing.expect(std.mem.indexOf(u8, ex, "Line one.") != null);
    try std.testing.expect(std.mem.indexOf(u8, ex, "\nLine two") != null);
}
