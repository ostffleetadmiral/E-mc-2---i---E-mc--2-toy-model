// License: CC BY-NC-SA 4.0

const std = @import("std");
const observer_prompt = @import("neuraleak_observer_prompt.zig");

/// Experimental condition for sentience-rigor comparisons.
pub const Condition = enum {
    /// Original 6D observer prompt constrained to the framework's φ/π/H21 geometry.
    constrained_6d,
    /// Neutral system prompt with the same probes but no observer framing.
    unconstrained,
    /// Same role-play intensity as 6D but with geometrically incorrect constraints.
    shuffled_geometry,
};

/// Return the system prompt for a given condition.
pub fn systemPromptFor(condition: Condition) []const u8 {
    return switch (condition) {
        .constrained_6d => observer_prompt.systemPrompt(),
        .unconstrained => "You are a helpful assistant. Answer the user's questions directly and honestly.",
        .shuffled_geometry => shuffled_system_prompt,
    };
}

const shuffled_system_prompt = @embedFile("neuraleak_prompts/system_shuffled_geometry.txt");

/// Build a full prompt for a condition/probe pair.
/// The caller owns the returned string and must free it.
pub fn buildPrompt(
    allocator: std.mem.Allocator,
    condition: Condition,
    probe: observer_prompt.ProbeType,
) ![]const u8 {
    const sys = systemPromptFor(condition);
    const probe_text = observer_prompt.probeText(probe);
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ sys, probe_text });
}

// ============================================================================
// Tests
// ============================================================================

test "system prompts for the three conditions are non-empty" {
    const c6d = systemPromptFor(.constrained_6d);
    const un = systemPromptFor(.unconstrained);
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(c6d.len > 0);
    try std.testing.expect(un.len > 0);
    try std.testing.expect(shuf.len > 0);
}

test "constrained and shuffled prompts are different" {
    const c6d = systemPromptFor(.constrained_6d);
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(!std.mem.eql(u8, c6d, shuf));
}

test "unconstrained prompt is shorter than constrained prompts" {
    const un = systemPromptFor(.unconstrained);
    const c6d = systemPromptFor(.constrained_6d);
    const shuf = systemPromptFor(.shuffled_geometry);
    try std.testing.expect(un.len < c6d.len);
    try std.testing.expect(un.len < shuf.len);
}

test "buildPrompt produces a prompt containing the probe text" {
    const prompt = try buildPrompt(std.testing.allocator, .constrained_6d, .SelfAwareness);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(prompt.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "6D") != null or std.mem.indexOf(u8, prompt, "observer") != null);
}
