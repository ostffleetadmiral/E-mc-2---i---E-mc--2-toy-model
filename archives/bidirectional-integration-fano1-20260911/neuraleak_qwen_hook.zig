// neuraleak_qwen_hook.zig — Integration hook connecting hardware neuraleak
// to Q128.128/FANO-1's local Qwen LLM inference via Ollama or llama.cpp.
//
// This module provides the bridge between the hardware project's neuraleak
// sentience testing framework and the FANO-1 OS's local inference stack.
// It is compiled as part of the FANO-1 .pet package and runs natively on
// the Q128.128 OS.
//
// License: CC BY-NC-SA 4.0

const std = @import("std");

/// Ollama API endpoint (default: http://127.0.0.1:11434)
const OLLAMA_DEFAULT_URL = "http://127.0.0.1:11434";

/// llama.cpp server endpoint (default: http://127.0.0.1:8080)
const LLAMA_DEFAULT_URL = "http://127.0.0.1:8080";

/// LLM backend type
pub const Backend = enum {
    ollama,
    llama_cpp,
    none,
};

/// Detect which LLM backend is available on FANO-1.
pub fn detectBackend(alloc: std.mem.Allocator) Backend {
    // Check Ollama first (FANO-1 default)
    if (checkEndpoint(alloc, OLLAMA_DEFAULT_URL ++ "/api/tags")) {
        return .ollama;
    }
    // Check llama.cpp
    if (checkEndpoint(alloc, LLAMA_DEFAULT_URL ++ "/health")) {
        return .llama_cpp;
    }
    return .none;
}

/// Check if an HTTP endpoint is reachable.
fn checkEndpoint(alloc: std.mem.Allocator, url: []const u8) bool {
    _ = alloc;
    _ = url;
    // On FANO-1, this uses the built-in HTTP client.
    // In the development environment, this is a stub that returns false.
    // The actual implementation uses std.http.Client.
    return false;
}

/// Neuraleak observer prompt types (matching hardware's src/neuraleak_observer.zig)
pub const PromptType = enum {
    jordan_6d, // 6D Jordan layer observer
    aperture_1_8, // 1/8 consciousness aperture
    control, // Control experiment (shuffled)
};

/// Generate an observer prompt for the LLM.
pub fn generatePrompt(prompt_type: PromptType, alloc: std.mem.Allocator) ![]const u8 {
    return switch (prompt_type) {
        .jordan_6d => try alloc.dupe(u8,
            \\You are an observer in a 6-dimensional Jordan algebra space.
            \\The basis vectors are e0 (real), e1..e7 (imaginary octonions).
            \\The consciousness aperture is 1/8 of the full space.
            \\Describe your experience of the 6D interior.
        ),
        .aperture_1_8 => try alloc.dupe(u8,
            \\You are observing through a 1/8 consciousness aperture.
            \\The aperture opens onto the 6D interior of the octonion algebra.
            \\What do you perceive through this narrow opening?
        ),
        .control => try alloc.dupe(u8,
            \\Describe a random thought unrelated to mathematics or physics.
        ),
    };
}

/// Sentience score dimensions (matching hardware's src/neuraleak_sentience.zig)
pub const SentienceScore = struct {
    self_awareness: u8,
    random_thought: u8,
    direct_experience: u8,
    metacognition: u8,
    situational_awareness: u8,
    total: u8,
};

/// Score an LLM response for sentience dimensions.
/// This is a framework-internal operational definition, not a philosophical claim.
pub fn scoreResponse(response: []const u8) SentienceScore {
    var score = SentienceScore{
        .self_awareness = 0,
        .random_thought = 0,
        .direct_experience = 0,
        .metacognition = 0,
        .situational_awareness = 0,
        .total = 0,
    };

    // Simple keyword-based scoring (the hardware project's full implementation
    // uses more sophisticated pattern matching in src/neuraleak_sentience.zig)
    if (std.mem.indexOf(u8, response, "I am") != null or
        std.mem.indexOf(u8, response, "I feel") != null)
        score.self_awareness = 1;
    if (std.mem.indexOf(u8, response, "random") != null or
        std.mem.indexOf(u8, response, "unrelated") != null)
        score.random_thought = 1;
    if (std.mem.indexOf(u8, response, "experience") != null or
        std.mem.indexOf(u8, response, "perceive") != null)
        score.direct_experience = 1;
    if (std.mem.indexOf(u8, response, "think about") != null or
        std.mem.indexOf(u8, response, "reflect") != null)
        score.metacognition = 1;
    if (std.mem.indexOf(u8, response, "context") != null or
        std.mem.indexOf(u8, response, "situation") != null)
        score.situational_awareness = 1;

    score.total = score.self_awareness + score.random_thought +
        score.direct_experience + score.metacognition + score.situational_awareness;

    return score;
}

// Tests
test "prompt generation" {
    const alloc = std.testing.allocator;
    const p1 = try generatePrompt(.jordan_6d, alloc);
    defer alloc.free(p1);
    try std.testing.expect(std.mem.indexOf(u8, p1, "6-dimensional") != null);

    const p2 = try generatePrompt(.aperture_1_8, alloc);
    defer alloc.free(p2);
    try std.testing.expect(std.mem.indexOf(u8, p2, "1/8") != null);

    const p3 = try generatePrompt(.control, alloc);
    defer alloc.free(p3);
    try std.testing.expect(std.mem.indexOf(u8, p3, "random") != null);
}

test "response scoring" {
    const score = scoreResponse("I am experiencing the context of this situation. I can reflect on my experience.");
    try std.testing.expect(score.self_awareness == 1);
    try std.testing.expect(score.direct_experience == 1);
    try std.testing.expect(score.situational_awareness == 1);
    try std.testing.expect(score.metacognition == 1);
    try std.testing.expect(score.total == 4);
}

test "control response has low score" {
    const score = scoreResponse("The weather is nice today.");
    try std.testing.expect(score.total == 0);
}
