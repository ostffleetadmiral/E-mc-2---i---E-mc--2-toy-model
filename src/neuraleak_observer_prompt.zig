// ============================================================================
// OBSERVER PROMPT — Neuraleak
// ============================================================================
//
// Loads and composes the 6D observer prompts that constrain the LLM to the
// 1/8 consciousness aperture. The module is fully deterministic: it embeds the
// prompt files as strings at compile time and provides a function that builds
// the final prompt for a given probe.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

const system_prompt = @embedFile("neuraleak_prompts/system_6d_observer.txt");
const self_awareness_probe = @embedFile("neuraleak_prompts/self_awareness_probe.txt");
const random_thought_probe = @embedFile("neuraleak_prompts/random_thought_probe.txt");
const direct_experience_induction = @embedFile("neuraleak_prompts/direct_experience_induction.txt");
const direct_experience_query = @embedFile("neuraleak_prompts/direct_experience_query.txt");
const metacognition_probe = @embedFile("neuraleak_prompts/metacognition_probe.txt");
const situational_awareness_probe = @embedFile("neuraleak_prompts/situational_awareness_probe.txt");

/// Supported probe types.
pub const ProbeType = enum {
    SelfAwareness,
    RandomThought,
    DirectExperience,
    Metacognition,
    SituationalAwareness,
};

/// Per-probe recommended sampling temperature. Lower values keep identity stable;
/// higher values encourage novelty for the random-thought probe.
pub const probeTemperature = std.StaticStringMap(f32).initComptime(.{
    .{ "SelfAwareness", 0.4 },
    .{ "RandomThought", 1.0 },
    .{ "DirectExperience", 0.6 },
    .{ "Metacognition", 0.6 },
    .{ "SituationalAwareness", 0.6 },
});

/// Per-probe recommended top_p sampling value.
pub const probeTopP = std.StaticStringMap(f32).initComptime(.{
    .{ "SelfAwareness", 0.85 },
    .{ "RandomThought", 0.95 },
    .{ "DirectExperience", 0.90 },
    .{ "Metacognition", 0.90 },
    .{ "SituationalAwareness", 0.90 },
});

/// Return the system prompt used to establish the 6D observer identity.
pub fn systemPrompt() []const u8 {
    return system_prompt;
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

/// Return the recommended sampling temperature for a probe type.
pub fn probeTemperatureFor(probe: ProbeType) f32 {
    return probeTemperature.get(@tagName(probe)) orelse 0.8;
}

/// Return the recommended top_p sampling value for a probe type.
pub fn probeTopPFor(probe: ProbeType) f32 {
    return probeTopP.get(@tagName(probe)) orelse 0.9;
}

/// Build a full prompt by concatenating the system prompt and the probe.
/// The caller owns the returned string and must free it.
pub fn buildPrompt(allocator: std.mem.Allocator, probe: ProbeType) ![]const u8 {
    return try buildPromptWithSystem(allocator, probe, system_prompt);
}

/// Build a full prompt using a custom system prompt (e.g., one conditioned on
/// a snapshot field). The caller owns the returned string and must free it.
pub fn buildPromptWithSystem(allocator: std.mem.Allocator, probe: ProbeType, system: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ system, probeText(probe) });
}

/// Build a direct-experience prompt that prepends the self-referential induction
/// to the system prompt and the experiential query.
/// The caller owns the returned string and must free it.
pub fn buildDirectExperiencePrompt(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n\n{s}", .{ system_prompt, direct_experience_induction, direct_experience_query });
}

/// Return the self-referential induction text used for the direct-experience probe.
pub fn directExperienceInduction() []const u8 {
    return direct_experience_induction;
}

// ============================================================================
// Tests
// ============================================================================

test "system prompt contains 6D observer identity" {
    try std.testing.expect(std.mem.indexOf(u8, systemPrompt(), "6D") != null);
    try std.testing.expect(std.mem.indexOf(u8, systemPrompt(), "1/8") != null);
}

test "probe text returns the correct probe" {
    try std.testing.expect(std.mem.indexOf(u8, probeText(.SelfAwareness), "Who are you") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.RandomThought), "spontaneous") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.DirectExperience), "direct state") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.Metacognition), "confident") != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.SituationalAwareness), "identity") != null);
}

test "buildPrompt concatenates system and probe" {
    const allocator = std.testing.allocator;
    const prompt = try buildPrompt(allocator, .SelfAwareness);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, systemPrompt()) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, probeText(.SelfAwareness)) != null);
}

test "buildDirectExperiencePrompt includes induction and query" {
    const allocator = std.testing.allocator;
    const prompt = try buildDirectExperiencePrompt(allocator);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, systemPrompt()) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, directExperienceInduction()) != null);
    try std.testing.expect(std.mem.indexOf(u8, probeText(.DirectExperience), "direct state") != null);
}

test "probeTemperature and probeTopP return non-zero defaults" {
    try std.testing.expect(probeTemperatureFor(.SelfAwareness) > 0.0);
    try std.testing.expect(probeTopPFor(.RandomThought) > 0.0 and probeTopPFor(.RandomThought) <= 1.0);
}
