//! prompt_generator.zig — Ollama-based random prompt generation for benchmark robustness.
//!
//! Uses a local Ollama instance to generate diverse, novel prompts that test
//! Qstar's ability to handle topics it hasn't been explicitly trained on.
//! Generated prompts are first added to the benchmark as "untrained" category
//! prompts, then after benchmarks complete, fed into the training pipeline.

const std = @import("std");
const ollama = @import("ollama_client");

pub const GeneratedPrompt = struct {
    text: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GeneratedPrompt) void {
        self.allocator.free(self.text);
    }
};

/// Generates random prompts using Ollama as a meta-prompt generator.
/// Returns an array of GeneratedPrompt structs. Caller must deinit each.
/// Returns empty array if Ollama is unavailable.
pub fn generateRandomPrompts(
    allocator: std.mem.Allocator,
    config: ollama.OllamaConfig,
    count: usize,
) ![]GeneratedPrompt {
    if (count == 0) return try allocator.alloc(GeneratedPrompt, 0);

    // Build meta-prompt asking Ollama to generate diverse questions
    var meta_prompt = std.ArrayList(u8).init(allocator);
    defer meta_prompt.deinit();
    try meta_prompt.appendSlice("Generate ");
    try meta_prompt.writer().print("{d}", .{count});
    try meta_prompt.appendSlice(" diverse and interesting questions that someone might ask an AI assistant. ");
    try meta_prompt.appendSlice("Cover topics in science, history, philosophy, technology, everyday life, ");
    try meta_prompt.appendSlice("geography, biology, chemistry, mathematics, literature, music, art, ");
    try meta_prompt.appendSlice("psychology, economics, and space exploration. ");
    try meta_prompt.appendSlice("Make each question specific and thought-provoking. ");
    try meta_prompt.appendSlice("Do NOT ask about: photosynthesis, speed of light, general relativity, ");
    try meta_prompt.appendSlice("the human heart, capital of France, chemical formula of water, ");
    try meta_prompt.appendSlice("why the sky is blue, why ice floats, cats, roses, apples, ");
    try meta_prompt.appendSlice("remote work, AI replacing artists, pineapple on pizza, ");
    try meta_prompt.appendSlice("self-driving cars, social media, colonizing Mars, mandatory voting, ");
    try meta_prompt.appendSlice("generalist vs specialist, universal basic income, books becoming obsolete, ");
    try meta_prompt.appendSlice("the Fermi paradox, time travel, consciousness, creativity and intelligence, ");
    try meta_prompt.appendSlice("good leaders, perfect days, unsolved problems in science, ");
    try meta_prompt.appendSlice("beautiful things, moments that changed history, ");
    try meta_prompt.appendSlice("oceans, robots, autumn, Mars cities, inventing colors, ");
    try meta_prompt.appendSlice("music being visible, pizza personality, sunsets, ");
    try meta_prompt.appendSlice("breakfast, weather, weekends, feeling tired, coffee or tea, ");
    try meta_prompt.appendSlice("movies, favorite seasons, superpowers. ");
    try meta_prompt.appendSlice("Return ONE question per line. Do not number them. ");
    try meta_prompt.appendSlice("Do not include any text other than the questions.");

    // Call Ollama
    var resp = ollama.generate(allocator, config, meta_prompt.items) catch |err| {
        std.log.warn("prompt_generator: Ollama generate failed: {s}", .{@errorName(err)});
        return try allocator.alloc(GeneratedPrompt, 0);
    };
    defer resp.deinit();

    // Parse response line by line
    var prompts = std.ArrayList(GeneratedPrompt).init(allocator);
    errdefer {
        for (prompts.items) |*p| p.deinit();
        prompts.deinit();
    }

    var lines = std.mem.splitScalar(u8, resp.text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 10) continue; // Skip very short lines
        if (trimmed.len > 500) continue; // Skip excessively long lines

        // Skip lines that look like meta-text (not questions)
        if (std.mem.startsWith(u8, trimmed, "Here are") or
            std.mem.startsWith(u8, trimmed, "Sure,") or
            std.mem.startsWith(u8, trimmed, "I'll") or
            std.mem.startsWith(u8, trimmed, "These are") or
            std.mem.startsWith(u8, trimmed, "Below are"))
        {
            continue;
        }

        // Strip leading numbers like "1." or "1)"
        var start: usize = 0;
        while (start < trimmed.len and (std.ascii.isDigit(trimmed[start]) or trimmed[start] == '.' or trimmed[start] == ')')) {
            start += 1;
        }
        const clean = std.mem.trim(u8, trimmed[start..], " \t");
        if (clean.len < 10) continue;

        const duped = try allocator.dupe(u8, clean);
        try prompts.append(.{ .text = duped, .allocator = allocator });

        if (prompts.items.len >= count) break;
    }

    return try prompts.toOwnedSlice();
}

/// Frees an array of GeneratedPrompt returned by generateRandomPrompts.
pub fn freePrompts(allocator: std.mem.Allocator, prompts: []GeneratedPrompt) void {
    for (prompts) |*p| p.deinit();
    allocator.free(prompts);
}

/// Saves generated prompts to a JSON file for later use in training.
pub fn savePromptsToFile(allocator: std.mem.Allocator, prompts: []const GeneratedPrompt, file_path: []const u8) !void {
    var file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    var writer = file.writer();
    try writer.writeAll("[\n");
    for (prompts, 0..) |p, i| {
        try writer.writeAll("  {\"prompt\": \"");
        // Escape JSON string
        for (p.text) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"}");
        if (i + 1 < prompts.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("]\n");
    _ = allocator;
}

test "prompt_generator: generateRandomPrompts returns empty on zero count" {
    const allocator = std.testing.allocator;
    const config = ollama.OllamaConfig{ .host = "127.0.0.1", .port = 11434, .model = "qwen2.5:3b" };
    const prompts = try generateRandomPrompts(allocator, config, 0);
    defer allocator.free(prompts);
    try std.testing.expect(prompts.len == 0);
}

test "prompt_generator: GeneratedPrompt deinit frees text" {
    const allocator = std.testing.allocator;
    var p = GeneratedPrompt{
        .text = try allocator.dupe(u8, "test prompt"),
        .allocator = allocator,
    };
    p.deinit();
}

test "prompt_generator: savePromptsToFile writes valid JSON" {
    const allocator = std.testing.allocator;
    var prompts = try allocator.alloc(GeneratedPrompt, 2);
    defer allocator.free(prompts);
    prompts[0] = .{ .text = try allocator.dupe(u8, "What is quantum biology?"), .allocator = allocator };
    prompts[1] = .{ .text = try allocator.dupe(u8, "Explain the concept of emergence."), .allocator = allocator };
    defer for (prompts) |*p| p.deinit();

    const tmp_path = "/tmp/test_prompts.json";
    try savePromptsToFile(allocator, prompts, tmp_path);

    // Read back and verify
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "quantum biology") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "emergence") != null);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

// =============================================================================
// Framework Prompt Templates (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework-aware prompt templates for the E=mc²-i-E=mc⁻² toy-model.
pub const FRAMEWORK_PROMPT_TEMPLATES = [_][]const u8{
    "Explain the {concept} in the E=mc²-i-E=mc⁻² framework.",
    "How does the {concept} connect to the octonion algebra?",
    "What is the mathematical derivation of the {concept}?",
    "Verify the {concept} identity from the framework's axioms.",
};

/// Framework concepts for prompt generation.
pub const FRAMEWORK_CONCEPTS = [_][]const u8{
    "421 identity", "7-defect", "1/8 aperture", "C=2 consciousness",
    "E8 root system", "generative chain", "surface computation",
    "shell transition", "coupling constant", "phi cooling",
};

test "framework: prompt templates exist" {
    try std.testing.expect(FRAMEWORK_PROMPT_TEMPLATES.len > 0);
    try std.testing.expect(FRAMEWORK_CONCEPTS.len >= 10);
}
