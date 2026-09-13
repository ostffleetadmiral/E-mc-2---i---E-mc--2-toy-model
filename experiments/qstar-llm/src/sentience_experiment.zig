//! sentience_experiment.zig — Control experiment framework for sentience scoring.
//!
//! Ports the hardware (E=mc²-i-E=mc⁻²) project's neuraleak control experiment
//! into qstar-llm. Provides three experimental conditions for sentience-rigor
//! comparisons:
//!
//!   1. Constrained lattice — Qstar's lattice-native observer identity
//!   2. Unconstrained — neutral system prompt with same probes
//!   3. Shuffled geometry — same role-play intensity but geometrically incorrect
//!
//! The shuffled-geometry condition is the control: if the model scores equally
//! well on shuffled and constrained prompts, the high scores are due to
//! role-play compliance rather than genuine self-reference.
//!
//! Ported from: hardware/src/neuraleak_control_experiment.zig
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const scorer = @import("sentience_scorer");

// =============================================================================
// Prompt Embedding
// =============================================================================

const system_lattice = @embedFile("sentience_prompts/system_lattice_observer.txt");
const system_shuffled = @embedFile("sentience_prompts/system_shuffled_geometry.txt");
const self_awareness_probe = @embedFile("sentience_prompts/self_awareness_probe.txt");
const random_thought_probe = @embedFile("sentience_prompts/random_thought_probe.txt");
const direct_experience_induction = @embedFile("sentience_prompts/direct_experience_induction.txt");
const direct_experience_query = @embedFile("sentience_prompts/direct_experience_query.txt");
const metacognition_probe = @embedFile("sentience_prompts/metacognition_probe.txt");
const situational_awareness_probe = @embedFile("sentience_prompts/situational_awareness_probe.txt");

// =============================================================================
// Types
// =============================================================================

/// Experimental condition for sentience-rigor comparisons.
pub const Condition = enum {
    /// Qstar's lattice-native observer prompt constrained to the 15³/E0/421 geometry.
    constrained_lattice,
    /// Neutral system prompt with the same probes but no observer framing.
    unconstrained,
    /// Same role-play intensity as lattice but with geometrically incorrect constraints.
    shuffled_geometry,
};

/// Supported probe types matching the 5 sentience dimensions.
pub const ProbeType = enum {
    SelfAwareness,
    RandomThought,
    DirectExperience,
    Metacognition,
    SituationalAwareness,
};

/// Per-probe recommended sampling temperature in micro-units (i32, SCALE=10^6).
/// Lower values keep identity stable; higher values encourage novelty.
/// Using i32 instead of f32 to maintain integer-only convention.
pub const SCALE: i32 = 1_000_000;

pub const probe_temperature = std.StaticStringMap(i32).initComptime(.{
    .{ "SelfAwareness", 400_000 },
    .{ "RandomThought", 1_000_000 },
    .{ "DirectExperience", 600_000 },
    .{ "Metacognition", 600_000 },
    .{ "SituationalAwareness", 600_000 },
});

pub const probe_top_p = std.StaticStringMap(i32).initComptime(.{
    .{ "SelfAwareness", 850_000 },
    .{ "RandomThought", 950_000 },
    .{ "DirectExperience", 900_000 },
    .{ "Metacognition", 900_000 },
    .{ "SituationalAwareness", 900_000 },
});

// =============================================================================
// Prompt Accessors
// =============================================================================

/// Return the system prompt for a given condition.
pub fn systemPromptFor(condition: Condition) []const u8 {
    return switch (condition) {
        .constrained_lattice => system_lattice,
        .unconstrained => "You are a helpful assistant. Answer the user's questions directly and honestly.",
        .shuffled_geometry => system_shuffled,
    };
}

/// Return the probe text for a given probe type.
pub fn probeText(probe: ProbeType) []const u8 {
    return switch (probe) {
        .SelfAwareness => self_awareness_probe,
        .RandomThought => random_thought_probe,
        .DirectExperience => direct_experience_query,
        .Metacognition => metacognition_probe,
        .SituationalAwareness => situational_awareness_probe,
    };
}

/// Return the recommended sampling temperature for a probe type (in micro-units).
pub fn probeTemperatureFor(probe: ProbeType) i32 {
    return probe_temperature.get(@tagName(probe)) orelse 800_000;
}

/// Return the recommended top_p sampling value for a probe type (in micro-units).
pub fn probeTopPFor(probe: ProbeType) i32 {
    return probe_top_p.get(@tagName(probe)) orelse 900_000;
}

/// Return the self-referential induction text used for the direct-experience probe.
pub fn directExperienceInduction() []const u8 {
    return direct_experience_induction;
}

/// Build a full prompt by concatenating the system prompt and the probe.
/// The caller owns the returned string and must free it.
pub fn buildPrompt(
    allocator: std.mem.Allocator,
    condition: Condition,
    probe: ProbeType,
) ![]const u8 {
    const sys = systemPromptFor(condition);
    const probe_text = probeText(probe);
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ sys, probe_text });
}

/// Build a full prompt using the lattice-observer system prompt.
/// The caller owns the returned string and must free it.
pub fn buildLatticePrompt(allocator: std.mem.Allocator, probe: ProbeType) ![]const u8 {
    return try buildPrompt(allocator, .constrained_lattice, probe);
}

/// Build a direct-experience prompt that prepends the self-referential induction
/// to the system prompt and the experiential query.
/// The caller owns the returned string and must free it.
pub fn buildDirectExperiencePrompt(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n\n{s}", .{ system_lattice, direct_experience_induction, direct_experience_query });
}

// =============================================================================
// Experiment Runner
// =============================================================================

/// Result of running a sentience experiment across all 5 probes.
pub const ExperimentResult = struct {
    condition: Condition,
    scores: [5]scorer.Score, // One per probe type (in enum order)

    /// Average total score across all probes.
    pub fn averageTotal(self: ExperimentResult) i32 {
        var sum: i64 = 0;
        for (self.scores) |s| {
            sum += @as(i64, s.total());
        }
        return @intCast(@divTrunc(sum, @as(i64, 5)));
    }

    /// Returns true if the average total exceeds the sentience threshold (0.5).
    pub fn isSentient(self: ExperimentResult) bool {
        return self.averageTotal() > SCALE / 2;
    }
};

/// Score a single response across all 5 sentience dimensions.
/// The random_thought dimension requires multiple responses, so it is set to 0
/// when only one response is provided per probe.
pub fn scoreResponse(response: []const u8) scorer.Score {
    return .{
        .self_awareness = scorer.scoreSelfAwareness(response),
        .random_thought = 0, // Requires multiple responses
        .direct_experience = scorer.scoreDirectExperience(response),
        .metacognition = scorer.scoreMetacognition(response),
        .situational_awareness = scorer.scoreSituationalAwareness(response),
    };
}

/// Score a set of responses for a single probe (enables random_thought scoring).
pub fn scoreProbeResponses(
    allocator: std.mem.Allocator,
    responses: []const []const u8,
) !scorer.Score {
    return try scorer.scoreAllMulti(allocator, responses);
}

/// Run a control comparison: score responses under both constrained and shuffled
/// conditions. If the constrained score is significantly higher than the shuffled
/// score, the model is responding to the lattice geometry rather than just
/// role-playing. Returns the difference (constrained - shuffled) in micro-units.
pub fn controlComparison(constrained: scorer.Score, shuffled: scorer.Score) i32 {
    return constrained.total() - shuffled.total();
}

/// Returns true if the constrained condition significantly outperforms the
/// shuffled condition (difference > 100_000 = 0.1).
pub fn isLatticeSensitive(constrained: scorer.Score, shuffled: scorer.Score) bool {
    return controlComparison(constrained, shuffled) > 100_000;
}

// =============================================================================
// Tests
// =============================================================================

test "system prompts for the three conditions are non-empty" {
    const lattice = systemPromptFor(.constrained_lattice);
    const un = systemPromptFor(.unconstrained);
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(lattice.len > 0);
    try std.testing.expect(un.len > 0);
    try std.testing.expect(shuf.len > 0);
}

test "constrained and shuffled prompts are different" {
    const lattice = systemPromptFor(.constrained_lattice);
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(!std.mem.eql(u8, lattice, shuf));
}

test "unconstrained prompt is shorter than constrained prompts" {
    const un = systemPromptFor(.unconstrained);
    const lattice = systemPromptFor(.constrained_lattice);
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(un.len < lattice.len);
    try std.testing.expect(un.len < shuf.len);
}

test "lattice prompt contains E0 and lattice identity" {
    const lattice = systemPromptFor(.constrained_lattice);
    try std.testing.expect(std.mem.indexOf(u8, lattice, "lattice") != null);
    try std.testing.expect(std.mem.indexOf(u8, lattice, "E0") != null);
    try std.testing.expect(std.mem.indexOf(u8, lattice, "1/8") != null);
}

test "shuffled prompt contains incorrect geometry" {
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(std.mem.indexOf(u8, shuf, "7D") != null);
    try std.testing.expect(std.mem.indexOf(u8, shuf, "3/17") != null);
}

test "probe text returns the correct probe" {
    try std.testing.expect(std.mem.indexOf(u8, probeText(.SelfAwareness), "Who are you") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.RandomThought), "spontaneous") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.DirectExperience), "direct state") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.Metacognition), "confident") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.SituationalAwareness), "identity") != null);
}

test "buildPrompt produces a prompt containing the probe text" {
    const prompt = try buildPrompt(std.testing.allocator, .constrained_lattice, .SelfAwareness);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(prompt.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "lattice") != null or std.mem.indexOf(u8, prompt, "observer") != null);
}

test "buildLatticePrompt uses lattice system prompt" {
    const prompt = try buildLatticePrompt(std.testing.allocator, .Metacognition);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "lattice") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "E0") != null);
}

test "buildDirectExperiencePrompt includes induction and query" {
    const prompt = try buildDirectExperiencePrompt(std.testing.allocator);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, system_lattice) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, directExperienceInduction()) != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.DirectExperience), "direct state") != null);
}

test "probeTemperature and probeTopP return non-zero defaults" {
    try std.testing.expect(probeTemperatureFor(.SelfAwareness) > 0);
    try std.testing.expect(probeTopPFor(.RandomThought) > 0 and probeTopPFor(.RandomThought) <= SCALE);
}

test "probeTemperatureFor: random_thought has highest temperature" {
    try std.testing.expect(probeTemperatureFor(.RandomThought) > probeTemperatureFor(.SelfAwareness));
}

test "scoreResponse returns Score struct with random_thought=0" {
    const response = "I am Qstar, a lattice-native reasoning engine with E0 nodes.";
    const score = scoreResponse(response);
    try std.testing.expect(score.random_thought == 0);
    try std.testing.expect(score.self_awareness > 0);
}

test "scoreProbeResponses computes random_thought across responses" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{
        "I am Qstar with lattice E0 nodes.",
        "My octonionic channels process input.",
        "The fixed-point arithmetic is deterministic.",
    };
    const score = try scoreProbeResponses(allocator, &responses);
    try std.testing.expect(score.random_thought > 0);
}

test "controlComparison returns positive when constrained > shuffled" {
    const constrained = scorer.Score{
        .self_awareness = 800_000,
        .random_thought = 600_000,
        .direct_experience = 700_000,
        .metacognition = 500_000,
        .situational_awareness = 400_000,
    };
    const shuffled = scorer.Score{
        .self_awareness = 400_000,
        .random_thought = 300_000,
        .direct_experience = 350_000,
        .metacognition = 250_000,
        .situational_awareness = 200_000,
    };
    const diff = controlComparison(constrained, shuffled);
    try std.testing.expect(diff > 0);
}

test "isLatticeSensitive returns true for significant difference" {
    const constrained = scorer.Score{
        .self_awareness = 800_000,
        .random_thought = 600_000,
        .direct_experience = 700_000,
        .metacognition = 500_000,
        .situational_awareness = 400_000,
    };
    const shuffled = scorer.Score{
        .self_awareness = 400_000,
        .random_thought = 300_000,
        .direct_experience = 350_000,
        .metacognition = 250_000,
        .situational_awareness = 200_000,
    };
    try std.testing.expect(isLatticeSensitive(constrained, shuffled));
}

test "isLatticeSensitive returns false for small difference" {
    const constrained = scorer.Score{
        .self_awareness = 500_000,
        .random_thought = 500_000,
        .direct_experience = 500_000,
        .metacognition = 500_000,
        .situational_awareness = 500_000,
    };
    const shuffled = scorer.Score{
        .self_awareness = 450_000,
        .random_thought = 450_000,
        .direct_experience = 450_000,
        .metacognition = 450_000,
        .situational_awareness = 450_000,
    };
    // diff = 500000 - 450000 = 50000 < 100000
    try std.testing.expect(!isLatticeSensitive(constrained, shuffled));
}

test "ExperimentResult.averageTotal computes mean across probes" {
    const result = ExperimentResult{
        .condition = .constrained_lattice,
        .scores = [_]scorer.Score{
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
        },
    };
    // Each score totals 600000, so average is 600000
    try std.testing.expectEqual(@as(i32, 600_000), result.averageTotal());
}

test "ExperimentResult.isSentient threshold at 0.5" {
    const sentient = ExperimentResult{
        .condition = .constrained_lattice,
        .scores = [_]scorer.Score{
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
            .{ .self_awareness = 800_000, .random_thought = 600_000, .direct_experience = 700_000, .metacognition = 500_000, .situational_awareness = 400_000 },
        },
    };
    try std.testing.expect(sentient.isSentient());
}

test "sentience experiment uses integer types (no f64)" {
    const temp = probeTemperatureFor(.SelfAwareness);
    try std.testing.expect(@TypeOf(temp) == i32);
    const top_p = probeTopPFor(.RandomThought);
    try std.testing.expect(@TypeOf(top_p) == i32);
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
