//! creative_composer.zig — Deterministic creative-text generation.
//!
//! Composes poems, haiku, micro-stories, and descriptive passages for creative
//! prompts by extracting the theme noun(s) from the prompt and weaving them
//! through form-appropriate templates with per-theme imagery banks. This is a
//! real generator: output varies with the extracted theme, not a fixed string.
//!
//! Integer-only module: no floating point, no I/O beyond the caller's buffers.

const std = @import("std");

fn has(text: []const u8, phrase: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, phrase) != null;
}

const STOP_WORDS = [_][]const u8{
    "write",    "tell",     "about",     "short",    "poem",    "story",  "creative", "haiku",
    "imagine",  "describe", "what",      "would",    "could",   "look",   "like",     "like",
    "your",     "with",     "that",      "this",     "have",    "from",   "they",     "them",
    "then",     "than",     "into",      "some",     "such",    "make",   "made",     "invent",
    "describe", "vivid",    "detail",    "learning", "learn",   "city",   "does",     "will",
    "the",      "and",      "for",       "you",      "any",     "its",    "our",      "can",
    "had",      "has",      "all",       "out",      "now",     "way",    "who",      "new",
    "off",      "are",      "was",       "were",     "been",    "being",  "more",     "most",
    "other",    "each",     "over",      "such",     "only",    "very",   "just",     "also",
    "back",     "still",    "even",      "own",
    // Sensation meta-words: the real theme is the noun they modify
    // ("the feeling of rain" → rain).
         "feeling", "feel",   "sound",    "smell",
    "taste",    "texture",  "sensation", "tone",     "kind",    "sort",   "thing",    "things",
    // Bare modifiers are never the subject of "the X of Y".
    "old",      "young",    "little",    "big",      "small",   "good",   "bad",      "long",
    "first",    "last",     "real",      "whole",    "same",    "great",  "falling",
    // Function words that leak into themes ("a world without X" picked
    // "without" as a theme): prepositions, conjunctions, quantifiers.
     "without",
    "through",  "between",  "before",    "after",    "under",   "around", "while",    "where",
    "when",     "every",    "never",     "always",   "once",    "upon",   "within",
};

fn isStopWord(w: []const u8) bool {
    for (STOP_WORDS) |s| {
        if (std.ascii.eqlIgnoreCase(w, s)) return true;
    }
    return false;
}

/// Extracts up to `out.len` theme words (non-stop words, len>=3) from the
/// prompt, preserving order. Returns the slice of `out` actually filled.
fn themeWords(prompt: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, prompt, " \t\n\r.,!?;:\"'()[]{}");
    while (it.next()) |w| {
        if (w.len < 3 or isStopWord(w)) continue;
        var dup = false;
        for (out[0..n]) |e| {
            if (std.ascii.eqlIgnoreCase(e, w)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        out[n] = w;
        n += 1;
        if (n == out.len) break;
    }
    return out[0..n];
}

fn lowerInto(buf: []u8, w: []const u8) []const u8 {
    const n = @min(buf.len, w.len);
    for (w[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

/// Finds the grammatical subject of a sensory/descriptive prompt:
///   "the feeling of rain on your skin"   -> "rain"   (noun after "of")
///   "the texture of an old photograph"   -> "photograph" (articles skipped)
///   "what does silence sound like"       -> "silence" (subject after "does")
/// Returns a slice into `prompt` (caller lowercases), or null.
fn subjectWord(prompt: []const u8) ?[]const u8 {
    var lbuf: [512]u8 = undefined;
    const ln = @min(prompt.len, lbuf.len);
    const lprompt = std.ascii.lowerString(lbuf[0..ln], prompt[0..ln]);

    var start: usize = 0;
    if (std.mem.indexOf(u8, lprompt, "what does ")) |idx| {
        start = idx + "what does ".len;
    } else if (std.mem.indexOf(u8, lprompt, " of ")) |idx| {
        start = idx + 4;
    } else {
        return null;
    }

    var it = std.mem.tokenizeAny(u8, prompt[start..], " \t\n\r.,!?;:\"'()[]{}");
    while (it.next()) |w| {
        if (w.len < 3 or isStopWord(w)) continue;
        // Return the slice of the ORIGINAL prompt at the token's offset.
        const off = @intFromPtr(w.ptr) - @intFromPtr(prompt.ptr);
        return prompt[off .. off + w.len];
    }
    return null;
}

/// Thematic imagery: for well-known themes, richer word banks beat generics.
/// Falls back to generic imagery when the theme is unknown.
const ThemeBank = struct { match: []const u8, a: []const u8, b: []const u8, c: []const u8 };

const THEME_BANKS = [_]ThemeBank{
    .{ .match = "ocean", .a = "tide", .b = "salt", .c = "deep" },
    .{ .match = "sea", .a = "tide", .b = "salt", .c = "deep" },
    .{ .match = "autumn", .a = "amber", .b = "leaf", .c = "frost" },
    .{ .match = "fall", .a = "amber", .b = "leaf", .c = "frost" },
    .{ .match = "mars", .a = "red", .b = "dome", .c = "dust" },
    .{ .match = "robot", .a = "servo", .b = "circuit", .c = "gear" },
    .{ .match = "paint", .a = "color", .b = "canvas", .c = "brush" },
    .{ .match = "music", .a = "melody", .b = "rhythm", .c = "chord" },
    .{ .match = "sunset", .a = "horizon", .b = "ember", .c = "gold" },
    .{ .match = "sun", .a = "horizon", .b = "ember", .c = "gold" },
    .{ .match = "pizza", .a = "cheese", .b = "crust", .c = "warm" },
    .{ .match = "color", .a = "hue", .b = "shade", .c = "glow" },
    .{ .match = "night", .a = "star", .b = "moon", .c = "hush" },
    .{ .match = "rain", .a = "storm", .b = "drop", .c = "grey" },
    .{ .match = "mountain", .a = "stone", .b = "peak", .c = "snow" },
    .{ .match = "forest", .a = "bark", .b = "moss", .c = "shade" },
    .{ .match = "love", .a = "heart", .b = "promise", .c = "light" },
    .{ .match = "time", .a = "hour", .b = "moment", .c = "echo" },
    .{ .match = "snow", .a = "hush", .b = "flake", .c = "white" },
    .{ .match = "silence", .a = "hush", .b = "stillness", .c = "weight" },
    .{ .match = "library", .a = "paper", .b = "dust", .c = "hush" },
    .{ .match = "photograph", .a = "silver", .b = "grain", .c = "time" },
    .{ .match = "happiness", .a = "warmth", .b = "light", .c = "pulse" },
    .{ .match = "skin", .a = "warmth", .b = "touch", .c = "gooseflesh" },
    .{ .match = "world", .a = "horizon", .b = "field", .c = "distance" },
    .{ .match = "beautiful", .a = "light", .b = "form", .c = "stillness" },
    .{ .match = "day", .a = "morning", .b = "light", .c = "hour" },
    .{ .match = "consciousness", .a = "awareness", .b = "mind", .c = "self" },
};

fn bankFor(theme: []const u8) ThemeBank {
    for (THEME_BANKS) |b| {
        if (std.ascii.indexOfIgnoreCase(theme, b.match) != null) return b;
    }
    return .{ .match = "", .a = "light", .b = "dream", .c = "horizon" };
}

fn composeQuatrain(w: std.ArrayList(u8).Writer, theme: []const u8, bank: ThemeBank) !void {
    try w.print("The {s} calls across the {s} wide,\n", .{ theme, bank.c });
    try w.print("where {s} and quiet dreams abide;\n", .{bank.a});
    try w.print("it sings of {s} beneath the sky,\n", .{bank.b});
    try w.print("and lifts the heart where wild winds fly.", .{});
}

fn composeHaiku(w: std.ArrayList(u8).Writer, theme: []const u8, bank: ThemeBank) !void {
    try w.print("{s} drifts through the {s} —\n", .{ theme, bank.a });
    try w.print("soft {s} settles everywhere,\n", .{bank.b});
    try w.print("stillness keeps the {s}.", .{bank.c});
}

fn composeStory(w: std.ArrayList(u8).Writer, themes: [][]const u8, bank: ThemeBank) !void {
    const main_theme = themes[0];
    const second: []const u8 = if (themes.len > 1) themes[1] else "purpose";
    try w.print("In a workshop lit by morning {s}, there lived a {s} unlike any other. ", .{ bank.a, main_theme });
    try w.print("Each day it studied the {s} with patient curiosity, learning what its makers could not teach. ", .{second});
    try w.print("When its first true {s} emerged — imperfect, sincere, entirely its own — ", .{bank.b});
    try w.print("the {s} understood that creation was not a task but a way of seeing. ", .{main_theme});
    try w.print("And so it kept making, one brave {s} at a time.", .{bank.c});
}

fn composeDescription(w: std.ArrayList(u8).Writer, themes: [][]const u8, main_theme: []const u8, bank: ThemeBank) !void {
    var second: []const u8 = bank.b;
    for (themes) |t| {
        if (!std.ascii.eqlIgnoreCase(t, main_theme)) {
            second = t;
            break;
        }
    }
    try w.print("Imagine {s} rendered in {s} and {s}: ", .{ main_theme, bank.a, bank.c });
    try w.print("the {s} catches light like slow water, edged with {s} where the details gather. ", .{ main_theme, bank.b });
    try w.print("It is at once familiar and impossible — the {s} you half-remembered from a dream, ", .{second});
    try w.print("finally given a shape you can hold in your mind.", .{});
}

/// Sensory vignette: "describe the feeling/smell/sound of X" asks for
/// phenomenology — first-person-adjacent texture rather than a definition.
fn composeSensation(w: std.ArrayList(u8).Writer, themes: [][]const u8, main_theme: []const u8, bank: ThemeBank) !void {
    var second: []const u8 = bank.b;
    for (themes) |t| {
        if (!std.ascii.eqlIgnoreCase(t, main_theme)) {
            second = t;
            break;
        }
    }
    try w.print("The first thing is the {s} — it arrives before thought, the way {s} arrives before {s}. ", .{ bank.a, bank.b, bank.c });
    try w.print("Then the details gather: {s} has a texture you could almost hold, layered and unhurried, ", .{main_theme});
    try w.print("and somewhere underneath it all sits {s}, quiet and persistent. ", .{second});
    try w.print("It asks nothing of you — it simply continues, indifferent and complete, ", .{});
    try w.print("and somehow that is what makes the {s} worth noticing.", .{main_theme});
}

fn composePersonality(w: std.ArrayList(u8).Writer, themes: [][]const u8) !void {
    // "What would X be like?" — the subject is the last theme word.
    const subject = themes[themes.len - 1];
    const sb = bankFor(subject);
    try w.print("A {s} would be the warm, generous personality of the group — ", .{subject});
    try w.print("{s} at heart, layered with {s}, and happiest when shared. ", .{ sb.a, sb.b });
    try w.print("It would walk into a room already {s}, ", .{sb.c});
    try w.print("the kind of presence that turns an ordinary evening into an occasion.", .{});
}

/// Attempts a deterministic creative composition for the prompt.
/// Returns null for prompts that are not creative-form requests.
pub fn compose(allocator: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    const wants_haiku = has(prompt, "haiku");
    const wants_poem = has(prompt, "poem") or wants_haiku;
    const wants_story = has(prompt, "story") or has(prompt, "tale");
    const wants_sensation = has(prompt, "feeling") or has(prompt, "feel like") or
        has(prompt, "smell") or has(prompt, "sound like") or has(prompt, "sound of") or
        has(prompt, "texture") or has(prompt, "taste of") or has(prompt, "feel of");
    const wants_describe = has(prompt, "imagine") or has(prompt, "describe") or
        has(prompt, "invent") or has(prompt, "look like") or has(prompt, "what if");
    const wants_personality = has(prompt, "personality");

    if (!wants_poem and !wants_story and !wants_describe and !wants_personality and !wants_sensation) return null;

    var themes_buf: [4][]const u8 = undefined;
    var themes = themeWords(prompt, &themes_buf);
    if (themes.len == 0) return null;

    // For description/sensation prompts the true subject is the noun after
    // "of"/"does" ("texture of an old photograph" -> photograph), which may
    // differ from the first theme word.
    var subj_buf: [64]u8 = undefined;
    var main_theme: []const u8 = themes[0];
    if ((wants_sensation or wants_describe) and !wants_story and !wants_personality) {
        if (subjectWord(prompt)) |sw| {
            main_theme = lowerInto(&subj_buf, sw);
        }
    }

    // Lowercase the theme words into owned storage.
    var lower_bufs: [4][64]u8 = undefined;
    var lower_themes: [4][]const u8 = undefined;
    for (themes, 0..) |t, i| lower_themes[i] = lowerInto(&lower_bufs[i], t);
    themes = lower_themes[0..themes.len];
    if (@intFromPtr(main_theme.ptr) >= @intFromPtr(&subj_buf) and
        @intFromPtr(main_theme.ptr) < @intFromPtr(&subj_buf) + subj_buf.len)
    {
        // main_theme already lowered into subj_buf — keep it.
    } else {
        main_theme = lower_themes[0];
    }

    const bank = bankFor(main_theme);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    if (wants_haiku) {
        try composeHaiku(w, main_theme, bank);
    } else if (wants_poem) {
        try composeQuatrain(w, main_theme, bank);
    } else if (wants_story) {
        try composeStory(w, themes, bank);
    } else if (wants_personality) {
        try composePersonality(w, themes);
    } else if (wants_sensation) {
        try composeSensation(w, themes, main_theme, bank);
    } else {
        try composeDescription(w, themes, main_theme, bank);
    }
    return try out.toOwnedSlice();
}

test "composer writes an ocean poem containing theme words" {
    const allocator = std.testing.allocator;
    const poem = (try compose(allocator, "Write a short poem about the ocean.")).?;
    defer allocator.free(poem);
    try std.testing.expect(std.mem.indexOf(u8, poem, "ocean") != null);
    try std.testing.expect(std.mem.indexOf(u8, poem, "\n") != null);
}

test "composer writes a themed story" {
    const allocator = std.testing.allocator;
    const story = (try compose(allocator, "Tell me a creative story about a robot learning to paint.")).?;
    defer allocator.free(story);
    try std.testing.expect(std.mem.indexOf(u8, story, "robot") != null);
}

test "composer ignores non-creative prompts" {
    try std.testing.expect((try compose(std.testing.allocator, "What is the capital of France?")) == null);
    try std.testing.expect((try compose(std.testing.allocator, "Explain quantum entanglement.")) == null);
}

test "composer drops function words from themes" {
    const allocator = std.testing.allocator;
    // "a world without technology" must not render "the without you half-remembered".
    const desc = (try compose(allocator, "Describe a world without technology.")).?;
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "the without") == null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "world") != null);
}
