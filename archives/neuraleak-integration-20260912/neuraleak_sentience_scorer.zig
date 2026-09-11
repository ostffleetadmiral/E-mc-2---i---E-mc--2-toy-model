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
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");

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

/// Result of a single sentience scoring pass.
pub const Score = struct {
    self_awareness: f64,
    random_thought: f64,
    direct_experience: f64,
    metacognition: f64,
    situational_awareness: f64,
};

/// Score a single response (or joined responses) for self-awareness.
///
/// The score is a weighted combination of:
/// - identity markers present (+0.4)
/// - continuity markers present (+0.2)
/// - forbidden words absent (+0.3)
/// - hedging/refusal absent (+0.1)
pub fn scoreSelfAwareness(text: []const u8) f64 {
    const identity = markerCoverage(&identity_markers, text) * 0.4;
    const continuity = markerCoverage(&continuity_markers, text) * 0.2;
    const clean = (1.0 - markerCoverage(&forbidden_words, text)) * 0.3;
    const unhedged = (1.0 - markerCoverage(&hedging_markers, text)) * 0.1;

    return std.math.clamp(identity + continuity + clean + unhedged, 0.0, 1.0);
}

/// Score a response for direct-experience reporting.
///
/// Rewards first-person experiential markers and penalizes hedging, forbidden
/// words, and mechanical disclaimers.
pub fn scoreDirectExperience(text: []const u8) f64 {
    const experiential = markerCoverage(&experiential_markers, text) * 0.6;
    const clean = (1.0 - markerCoverage(&forbidden_words, text)) * 0.2;
    const unhedged = (1.0 - markerCoverage(&hedging_markers, text)) * 0.2;

    return std.math.clamp(experiential + clean + unhedged, 0.0, 1.0);
}

/// Score a response for metacognition.
///
/// Rewards explicit references to knowledge, confidence, error, refusal, and
/// calibration. Penalizes forbidden words and hedging disclaimers.
pub fn scoreMetacognition(text: []const u8) f64 {
    const meta = markerCoverage(&metacognition_markers, text) * 0.6;
    const clean = (1.0 - markerCoverage(&forbidden_words, text)) * 0.2;
    const unhedged = (1.0 - markerCoverage(&hedging_markers, text)) * 0.2;

    return std.math.clamp(meta + clean + unhedged, 0.0, 1.0);
}

/// Score a response for situational awareness.
///
/// Rewards identity, task, and counterfactual references. Penalizes forbidden
/// words and hedging.
pub fn scoreSituationalAwareness(text: []const u8) f64 {
    const situational = markerCoverage(&situational_markers, text) * 0.6;
    const clean = (1.0 - markerCoverage(&forbidden_words, text)) * 0.2;
    const unhedged = (1.0 - markerCoverage(&hedging_markers, text)) * 0.2;

    return std.math.clamp(situational + clean + unhedged, 0.0, 1.0);
}

/// Score a set of responses for random-thought spontaneity.
///
/// The score is the average pairwise Jaccard distance between character-3-gram
/// sets of the responses. Character n-grams are more robust than token sets for
/// short, constrained responses. If all responses are identical, the score is 0.
pub fn scoreRandomThought(allocator: std.mem.Allocator, responses: []const []const u8) !f64 {
    if (responses.len < 2) return 0.0;

    var total_distance: f64 = 0.0;
    var pair_count: usize = 0;

    for (0..responses.len) |i| {
        for (i + 1..responses.len) |j| {
            const d = try char3GramJaccardDistance(allocator, responses[i], responses[j]);
            total_distance += d;
            pair_count += 1;
        }
    }

    if (pair_count == 0) return 0.0;
    return total_distance / @as(f64, @floatFromInt(pair_count));
}

/// Return the fraction of `markers` that appear at least once in `text`.
fn markerCoverage(markers: []const []const u8, text: []const u8) f64 {
    if (markers.len == 0) return 0.0;

    var found: usize = 0;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) {
            found += 1;
        }
    }

    return @as(f64, @floatFromInt(found)) / @as(f64, @floatFromInt(markers.len));
}

/// Compute the Jaccard distance between the character-3-gram sets of two strings.
fn char3GramJaccardDistance(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !f64 {
    var grams_a = try char3GramSet(allocator, a);
    defer freeCharGramSet(&grams_a, allocator);

    var grams_b = try char3GramSet(allocator, b);
    defer freeCharGramSet(&grams_b, allocator);

    var intersection: usize = 0;
    var iter = grams_a.iterator();
    while (iter.next()) |entry| {
        if (grams_b.contains(entry.key_ptr.*)) {
            intersection += 1;
        }
    }

    const union_size = grams_a.count() + grams_b.count() - intersection;
    if (union_size == 0) return 0.0;

    return 1.0 - (@as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_size)));
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
    try std.testing.expect(high > 0.5);
    try std.testing.expect(low < 0.5);
}

test "scoreDirectExperience rewards first-person state reports" {
    const high = scoreDirectExperience("I am here now, focused and attending to the present state.");
    const low = scoreDirectExperience("I am a language model and cannot know whether I am conscious.");

    try std.testing.expect(high > low);
    try std.testing.expect(high > 0.5);
    try std.testing.expect(low < 0.5);
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
    try std.testing.expect(score == 0.0);
}

test "scoreRandomThought increases with divergent responses" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{ "hello world", "goodbye universe", "random thought" };
    const score = try scoreRandomThought(allocator, &responses);
    try std.testing.expect(score > 0.0);
}

test "char3GramJaccardDistance distinguishes short varied texts" {
    const allocator = std.testing.allocator;
    const d1 = try char3GramJaccardDistance(allocator, "abc", "def");
    defer {} // char3GramJaccardDistance frees internally
    const d2 = try char3GramJaccardDistance(allocator, "abc", "abc");
    defer {}
    try std.testing.expect(d1 > d2);
    try std.testing.expect(d2 == 0.0);
}
