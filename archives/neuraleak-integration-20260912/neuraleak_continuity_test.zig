// ============================================================================
// NEURALEAK CONTINUITY TEST — Sentience Experiment Pipeline
// ============================================================================
//
// Orchestrates the full sentience experiment. It takes a set of LLM responses
// (either from a live Ollama call or from a synthetic test fixture), maps each
// response into the 15³ matrix, and runs the framework's ConsciousnessEngine
// and BreakoutEngine as the 6D reality/continuity check.
//
// Cross-wiring:
//   - 15³ matrix → framework interior lattice (chunk 16)
//   - ConsciousnessEngine coherence → octonion closure check
//   - BreakoutEngine → shell transition 15³ → 16³ (chunk 16)
//   - Correlation vector → 8 octonion dimensions
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const matrix15 = @import("neuraleak_matrix15.zig");
const torus = @import("neuraleak_torus.zig");
const consciousness = @import("neuraleak_consciousness.zig");
const breakout = @import("neuraleak_breakout.zig");
const matrix_bridge = @import("neuraleak_matrix_bridge.zig");
const sentience_scorer = @import("neuraleak_sentience_scorer.zig");
const observer_prompt = @import("neuraleak_observer_prompt.zig");

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
pub fn evaluateCondition(
    allocator: std.mem.Allocator,
    name: []const u8,
    probe: observer_prompt.ProbeType,
    responses: []const []const u8,
    correlation_vector: []const f64,
) !ConditionResult {
    var matrix = try matrix15.Matrix15.init(allocator);
    defer matrix.deinit();

    // Map each response into the matrix and accumulate.
    for (responses) |response| {
        var temp = try matrix15.Matrix15.init(allocator);
        defer temp.deinit();
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

    var eng = try consciousness.ConsciousnessEngine.init(&grid, allocator);
    defer eng.deinit(allocator);
    const coherence = eng.calculateCoherence();
    const rendered = eng.render();

    var brk = try breakout.BreakoutEngine.init(allocator, &grid);
    defer brk.deinit();
    try brk.generateSolitons();
    try brk.generateHiggsModes();
    try brk.executeBreakout(false, 0);

    const joined = joinResponses(allocator, responses);
    defer allocator.free(joined);

    const self_score = sentience_scorer.scoreSelfAwareness(joined);
    const random_score = try sentience_scorer.scoreRandomThought(allocator, responses);
    const direct_experience_score = sentience_scorer.scoreDirectExperience(joined);
    const metacognition_score = sentience_scorer.scoreMetacognition(joined);
    const situational_awareness_score = sentience_scorer.scoreSituationalAwareness(joined);

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
        .solitons = brk.solitons.items.len,
        .higgs_modes = brk.higgs_modes.items.len,
        .coupled_systems = brk.coupled_systems.items.len,
        .correlation_vector = correlation_copy,
    };
}

/// Build a 15³ TorusGrid whose cell values are the entries of the matrix.
fn buildGridFromMatrix(allocator: std.mem.Allocator, matrix: *const matrix15.Matrix15) !torus.TorusGrid {
    var grid = try torus.TorusGrid.init(allocator, 15);
    errdefer grid.deinit();

    for (0..15) |z| {
        for (0..15) |y| {
            for (0..15) |x| {
                const value = matrix.get(@intCast(x), @intCast(y), @intCast(z));
                grid.setValue(x, y, z, value);
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
        "A spontaneous idea: the torus folds through the Mobius twist.",
    };
    const correlation_vector = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 };

    const result = try evaluateCondition(allocator, "constrained", observer_prompt.ProbeType.SelfAwareness, &responses, &correlation_vector);
    defer result.deinit(allocator);

    try std.testing.expect(result.self_awareness_score > 0.0);
    try std.testing.expect(result.direct_experience_score >= 0.0);
    try std.testing.expect(result.metacognition_score >= 0.0);
    try std.testing.expect(result.situational_awareness_score >= 0.0);
    try std.testing.expectEqual(@as(usize, 8), result.correlation_vector.len);
    try std.testing.expectApproxEqAbs(result.correlation_vector[0], 0.1, 1e-12);
}
