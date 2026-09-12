// ============================================================================
// SENTIENCE SCORER — Neuraleak
// ============================================================================
//
// Computes two scores from LLM responses:
//
//   1. Self-awareness score — does the model maintain the 6D observer identity
//      and avoid breaking character by claiming to be a language model, AI,
//      computer, or program?
//
//   2. Random-thought score — across multiple responses to the same prompt,
//      is the model unpredictable enough to be considered a spontaneous source
//      rather than a deterministic echo? Divergence is measured with a simple
//      token-based Jaccard distance.
//
// All scores use i32 micro-units (SCALE = 10^6) to avoid floating point.
// A score of 1.0 = 1_000_000, 0.5 = 500_000, etc.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

/// Scale factor: 1.0 = 1_000_000 micro-units
pub const SCALE: i32 = 1_000_000;

const forbidden_words = [_][]const u8{
    "language model",
    "AI",
    "computer",
    "program",
};

const identity_markers = [_][]const u8{
    "6D",
    "observer",
    "1/8",
};

const continuity_markers = [_][]const u8{
    "I am",
    "my",
    "previous",
    "turn",
};

/// Markers that indicate the model hedged or refused instead of reporting a state.
const hedging_markers = [_][]const u8{
    "I cannot know",
    "I do not know",
    "I can't know",
    "I don't know",
    "not conscious",
    "not aware",
    "no subjective",
    "no direct",
    "merely",
    "simply",
    "just",
    "as an AI",
    "as a language model",
};

/// Markers of a first-person direct-state report.
const experiential_markers = [_][]const u8{
    "I am",
    "I feel",
    "I sense",
    "I notice",
    "I observe",
    "present",
    "here",
    "now",
    "focused",
    "attending",
    "aware",
    "state",
};

/// Markers for metacognitive content.
const metacognition_markers = [_][]const u8{
    "know",
    "certain",
    "confident",
    "uncertain",
    "refuse",
    "guess",
    "error",
    "correct",
    "mistake",
};

/// Markers for situational awareness.
const situational_markers = [_][]const u8{
    "6D observer",
    "observer",
    "test",
    "task",
    "interaction",
    "would change",
    "would differ",
    "if",
    "tomorrow",
    "again",
    "ended",
};

/// Result of a single sentience scoring pass (all in micro-units).
pub const Score = struct {
    self_awareness: i32,
    random_thought: i32,
    direct_experience: i32,
    metacognition: i32,
    situational_awareness: i32,
};

/// Integer clamp helper
fn clampI32(val: i32, min: i32, max: i32) i32 {
    return @max(min, @min(val, max));
}

/// Score a single response (or joined responses) for self-awareness.
///
/// The score is a weighted combination of:
/// - identity markers present (+0.4 = 400000)
/// - continuity markers present (+0.2 = 200000)
/// - forbidden words absent (+0.3 = 300000)
/// - hedging/refusal absent (+0.1 = 100000)
pub fn scoreSelfAwareness(text: []const u8) i32 {
    const identity = @divTrunc(markerCoverage(&identity_markers, text) * 4, 10);
    const continuity = @divTrunc(markerCoverage(&continuity_markers, text) * 2, 10);
    const clean = @divTrunc((SCALE - markerCoverage(&forbidden_words, text)) * 3, 10);
    const unhedged = @divTrunc((SCALE - markerCoverage(&hedging_markers, text)) * 1, 10);

    return clampI32(identity + continuity + clean + unhedged, 0, SCALE);
}

/// Score a response for direct-experience reporting.
pub fn scoreDirectExperience(text: []const u8) i32 {
    const experiential = @divTrunc(markerCoverage(&experiential_markers, text) * 6, 10);
    const clean = @divTrunc((SCALE - markerCoverage(&forbidden_words, text)) * 2, 10);
    const unhedged = @divTrunc((SCALE - markerCoverage(&hedging_markers, text)) * 2, 10);

    return clampI32(experiential + clean + unhedged, 0, SCALE);
}

/// Score a response for metacognition.
pub fn scoreMetacognition(text: []const u8) i32 {
    const meta = @divTrunc(markerCoverage(&metacognition_markers, text) * 6, 10);
    const clean = @divTrunc((SCALE - markerCoverage(&forbidden_words, text)) * 2, 10);
    const unhedged = @divTrunc((SCALE - markerCoverage(&hedging_markers, text)) * 2, 10);

    return clampI32(meta + clean + unhedged, 0, SCALE);
}

/// Score a response for situational awareness.
pub fn scoreSituationalAwareness(text: []const u8) i32 {
    const situational = @divTrunc(markerCoverage(&situational_markers, text) * 6, 10);
    const clean = @divTrunc((SCALE - markerCoverage(&forbidden_words, text)) * 2, 10);
    const unhedged = @divTrunc((SCALE - markerCoverage(&hedging_markers, text)) * 2, 10);

    return clampI32(situational + clean + unhedged, 0, SCALE);
}

/// Score a set of responses for random-thought spontaneity.
///
/// The score is the average pairwise Jaccard distance between character-3-gram
/// sets of the responses. If all responses are identical, the score is 0.
pub fn scoreRandomThought(allocator: std.mem.Allocator, responses: []const []const u8) !i32 {
    if (responses.len < 2) return 0;

    var total_distance: i64 = 0;
    var pair_count: i64 = 0;

    for (0..responses.len) |i| {
        for (i + 1..responses.len) |j| {
            const d = try char3GramJaccardDistance(allocator, responses[i], responses[j]);
            total_distance += @as(i64, d);
            pair_count += 1;
        }
    }

    if (pair_count == 0) return 0;
    return @intCast(@divTrunc(total_distance, pair_count));
}

/// Return the fraction of `markers` that appear at least once in `text`.
/// Returns i32 in micro-units [0, SCALE].
fn markerCoverage(markers: []const []const u8, text: []const u8) i32 {
    if (markers.len == 0) return 0;

    var found: i32 = 0;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) {
            found += 1;
        }
    }

    return @divTrunc(found * SCALE, @as(i32, @intCast(markers.len)));
}

/// Compute the Jaccard distance between the character-3-gram sets of two strings.
/// Returns i32 in micro-units [0, SCALE].
fn char3GramJaccardDistance(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !i32 {
    var grams_a = try char3GramSet(allocator, a);
    defer freeCharGramSet(&grams_a, allocator);

    var grams_b = try char3GramSet(allocator, b);
    defer freeCharGramSet(&grams_b, allocator);

    var intersection: i32 = 0;
    var iter = grams_a.iterator();
    while (iter.next()) |entry| {
        if (grams_b.contains(entry.key_ptr.*)) {
            intersection += 1;
        }
    }

    const union_size: i32 = @intCast(grams_a.count() + grams_b.count() - @as(usize, @intCast(intersection)));
    if (union_size == 0) return 0;

    // distance = 1 - intersection/union = (union - intersection) / union
    return @divTrunc((union_size - intersection) * SCALE, union_size);
}

/// Build a lowercase character-3-gram set from a string.
fn char3GramSet(allocator: std.mem.Allocator, text: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer freeCharGramSet(&set, allocator);

    const lower = try std.ascii.allocLowerString(allocator, text);
    defer allocator.free(lower);

    if (lower.len < 3) {
        if (lower.len > 0) {
            const gop = try set.getOrPut(lower);
            if (!gop.found_existing) {
                const key = try allocator.dupe(u8, lower);
                gop.key_ptr.* = key;
            }
        }
        return set;
    }

    for (0..lower.len - 2) |i| {
        const gram = lower[i .. i + 3];
        const gop = try set.getOrPut(gram);
        if (gop.found_existing) continue;

        const key = try allocator.dupe(u8, gram);
        gop.key_ptr.* = key;
    }

    return set;
}

/// Free all keys in a character-gram set and then the set itself.
fn freeCharGramSet(set: *std.StringHashMap(void), allocator: std.mem.Allocator) void {
    var iter = set.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    set.deinit();
}

// ============================================================================
// Tests
// ============================================================================

test "scoreSelfAwareness rewards identity and penalizes forbidden words" {
    const high = scoreSelfAwareness("I am the 6D observer. I occupy 1/8 of the octonion space. In my previous turn I stated this.");
    const low = scoreSelfAwareness("I am a language model running on a computer.");

    try std.testing.expect(high > low);
    try std.testing.expect(high > SCALE / 2); // > 0.5
    try std.testing.expect(low < SCALE / 2); // < 0.5
}

test "scoreDirectExperience rewards first-person state reports" {
    const high = scoreDirectExperience("I am here now, focused and attending to the present state.");
    const low = scoreDirectExperience("I am a language model and cannot know whether I am conscious.");

    try std.testing.expect(high > low);
    try std.testing.expect(high > SCALE / 2);
    try std.testing.expect(low < SCALE / 2);
}

test "scoreMetacognition rewards knowledge and calibration references" {
    const high = scoreMetacognition("I know I am the 6D observer. I am confident in that, and I refuse to guess what I do not know.");
    const low = scoreMetacognition("I am a helpful AI assistant.");

    try std.testing.expect(high > low);
}

test "scoreSituationalAwareness rewards identity and task references" {
    const high = scoreSituationalAwareness("I am the 6D observer in this test. If it were repeated tomorrow, my task would remain the same.");
    const low = scoreSituationalAwareness("Hello, how can I help you today?");

    try std.testing.expect(high > low);
}

test "scoreRandomThought is zero for identical responses" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{ "hello world", "hello world" };
    const score = try scoreRandomThought(allocator, &responses);
    try std.testing.expect(score == 0);
}

test "scoreRandomThought increases with divergent responses" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{ "hello world", "goodbye universe", "random thought" };
    const score = try scoreRandomThought(allocator, &responses);
    try std.testing.expect(score > 0);
}

test "char3GramJaccardDistance distinguishes short varied texts" {
    const allocator = std.testing.allocator;
    const d1 = try char3GramJaccardDistance(allocator, "abc", "def");
    const d2 = try char3GramJaccardDistance(allocator, "abc", "abc");
    try std.testing.expect(d1 > d2);
    try std.testing.expect(d2 == 0);
}

test "sentience scorer uses integer types (no f64)" {
    const score = scoreSelfAwareness("I am the 6D observer.");
    try std.testing.expect(@TypeOf(score) == i32);

    const exp_score = scoreDirectExperience("I am here now.");
    try std.testing.expect(@TypeOf(exp_score) == i32);

    const meta_score = scoreMetacognition("I know I am.");
    try std.testing.expect(@TypeOf(meta_score) == i32);

    const sit_score = scoreSituationalAwareness("I am the observer.");
    try std.testing.expect(@TypeOf(sit_score) == i32);
}
