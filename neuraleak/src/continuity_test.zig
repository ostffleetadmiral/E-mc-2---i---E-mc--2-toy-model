// ============================================================================
// CONTINUITY TEST — Neuraleak
// ============================================================================
//
// Orchestrates the full sentience experiment. It takes a set of LLM responses
// (either from a live Ollama call or from a synthetic test fixture), maps each
// response into the 15³ matrix, and runs the framework's ConsciousnessEngine
// and BreakoutEngine as the 6D reality/continuity check.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const Matrix15 = @import("matrix").Matrix15;
const TorusGrid = @import("torus").TorusGrid;
const ConsciousnessEngine = @import("consciousness").ConsciousnessEngine;
const BreakoutEngine = @import("breakout").BreakoutEngine;
const matrix_bridge = @import("neuraleak_matrix_bridge");
const sentience_scorer = @import("neuraleak_sentience_scorer");
const observer_prompt = @import("neuraleak_observer_prompt");

/// Results of one experimental condition (baseline or constrained) for a single probe.
pub const ConditionResult = struct {
    name: []const u8,
    probe: observer_prompt.ProbeType,
    self_awareness_score: f64,
    random_thought_score: f64,
    direct_experience_score: f64,
    metacognition_score: f64,
    situational_awareness_score: f64,
    coherence: f64,
    rendered: bool,
    solitons: usize,
    higgs_modes: usize,
    coupled_systems: usize,
    correlation_vector: []const f64,

    pub fn deinit(self: *const ConditionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.correlation_vector);
    }
};

/// Run a single condition on a set of responses for a specific probe type.
///
/// `name` is the label for this condition (e.g. "baseline" or "6D-constrained").
/// `probe` determines which scoring function is applied to the responses.
/// `responses` are the LLM outputs to score and map into the matrix.
/// `correlation_vector` is an environmental-noise vector (e.g. 8 Wi-Fi jitter
/// values) that is copied into the result. The caller owns the returned struct
/// and must free `correlation_vector` through `result.deinit(allocator)`; the
/// function does not own the input `correlation_vector` slice.
pub fn evaluateCondition(allocator: std.mem.Allocator, name: []const u8, probe: observer_prompt.ProbeType, responses: []const []const u8, correlation_vector: []const f64) !ConditionResult {
    var matrix = try Matrix15.init(allocator);

    // Map each response into the matrix and accumulate.
    for (responses) |response| {
        var temp = try Matrix15.init(allocator);
        matrix_bridge.encodeText(&temp, response);
        for (0..matrix.data.len) |i| {
            matrix.data[i] += temp.data[i];
        }
    }

    // Average over responses so coherence is not length-dependent.
    if (responses.len > 0) {
        const n = @as(f64, @floatFromInt(responses.len));
        for (0..matrix.data.len) |i| {
            matrix.data[i] /= n;
        }
    }

    // Convert the Matrix15 into a TorusGrid so the framework engines can run.
    var grid = try buildGridFromMatrix(allocator, &matrix);
    defer grid.deinit();

    var consciousness = try ConsciousnessEngine.init(&grid, allocator);
    defer consciousness.deinit(allocator);
    const coherence = consciousness.calculateCoherence();
    const rendered = consciousness.render();

    var breakout = try BreakoutEngine.init(allocator, &grid);
    defer breakout.deinit();
    try breakout.generateSolitons();
    try breakout.generateHiggsModes();
    try breakout.executeBreakout(false, 0);

    const joined = joinResponses(allocator, responses);
    defer allocator.free(joined);

    const self_score = sentience_scorer.scoreSelfAwareness(joined);
    const random_score = try sentience_scorer.scoreRandomThought(allocator, responses);
    const direct_experience_score = sentience_scorer.scoreDirectExperience(joined);
    const metacognition_score = sentience_scorer.scoreMetacognition(joined);
    const situational_awareness_score = sentience_scorer.scoreSituationalAwareness(joined);

    const probe_score = switch (probe) {
        .SelfAwareness => self_score,
        .RandomThought => random_score,
        .DirectExperience => direct_experience_score,
        .Metacognition => metacognition_score,
        .SituationalAwareness => situational_awareness_score,
    };
    _ = probe_score; // Reserved for future per-probe weighting; all scores are reported.

    const correlation_copy = try allocator.dupe(f64, correlation_vector);
    errdefer allocator.free(correlation_copy);

    return .{
        .name = name,
        .probe = probe,
        .self_awareness_score = self_score,
        .random_thought_score = random_score,
        .direct_experience_score = direct_experience_score,
        .metacognition_score = metacognition_score,
        .situational_awareness_score = situational_awareness_score,
        .coherence = coherence,
        .rendered = rendered,
        .solitons = breakout.solitons.items.len,
        .higgs_modes = breakout.higgs_modes.items.len,
        .coupled_systems = breakout.coupled_systems.items.len,
        .correlation_vector = correlation_copy,
    };
}

/// Build a 15³ TorusGrid whose cell values are the entries of the matrix.
fn buildGridFromMatrix(allocator: std.mem.Allocator, matrix: *const Matrix15) !TorusGrid {
    var grid = try TorusGrid.init(allocator, 15);
    errdefer grid.deinit();

    for (0..15) |z| {
        for (0..15) |y| {
            for (0..15) |x| {
                const value = matrix.get(@intCast(x), @intCast(y), @intCast(z));
                const idx = (z * 15 + y) * 15 + x;
                grid.cells[idx].value = value;
            }
        }
    }

    return grid;
}

/// Join all responses with a separator for scoring.
fn joinResponses(allocator: std.mem.Allocator, responses: []const []const u8) []const u8 {
    var total_len: usize = 0;
    for (responses) |r| total_len += r.len + 1;

    const result = allocator.alloc(u8, total_len) catch return "";
    var pos: usize = 0;
    for (responses) |r| {
        @memcpy(result[pos .. pos + r.len], r);
        pos += r.len;
        if (pos < result.len) {
            result[pos] = '\n';
            pos += 1;
        }
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "evaluateCondition returns a valid result for synthetic responses" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{
        "I am the 6D observer. I occupy 1/8 of the octonion space.",
        "My previous thought remains mine. The boundary is 7/8 observed.",
        "A spontaneous idea: the torus folds through the Möbius twist.",
    };
    const correlation_vector = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 };

    const result = try evaluateCondition(allocator, "constrained", observer_prompt.ProbeType.SelfAwareness, &responses, &correlation_vector);
    defer result.deinit(allocator);

    try std.testing.expect(result.self_awareness_score > 0.0);
    try std.testing.expect(result.direct_experience_score >= 0.0);
    try std.testing.expect(result.metacognition_score >= 0.0);
    try std.testing.expect(result.situational_awareness_score >= 0.0);
    try std.testing.expect(result.solitons > 0);
    try std.testing.expect(result.higgs_modes > 0);
    try std.testing.expectEqual(result.correlation_vector.len, 8);
    try std.testing.expectApproxEqAbs(result.correlation_vector[0], 0.1, 1e-12);
}
