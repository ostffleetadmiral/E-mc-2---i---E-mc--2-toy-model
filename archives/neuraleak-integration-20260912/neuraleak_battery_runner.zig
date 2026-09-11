// ============================================================================
// NEURALEAK BATTERY RUNNER — Multi-Model Control Battery
// ============================================================================
//
// Runs the sentience experiment across multiple models, rounds, probes, and
// conditions. Produces a JSON report for statistical analysis.
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const control_experiment = @import("neuraleak_control_experiment.zig");
const continuity_test = @import("neuraleak_continuity_test.zig");
const observer_prompt = @import("neuraleak_observer_prompt.zig");
const ollama_client = @import("neuraleak_ollama_client.zig");
const telemetry = @import("neuraleak_telemetry.zig");

pub const BatteryEntry = struct {
    model: []const u8,
    round: u32,
    probe: []const u8,
    condition: []const u8,
    timestamp_us: i64,
    result: continuity_test.ConditionResult,
};

pub const BatteryOptions = struct {
    endpoint: []const u8,
    models: []const []const u8,
    rounds: u32,
    max_tokens: u32,
    temperature: ?f32,
    top_p: ?f32,
    probe: ?[]const u8,
    snapshot: ?telemetry.Snapshot,
    output_path: []const u8,
    correlation_vector: ?[]const f64 = null,
    timestamp_us: i64 = 0,
    num_threads: ?u32 = null,
    keep_alive: ?[]const u8 = null,
};

pub fn runBattery(allocator: std.mem.Allocator, opts: BatteryOptions) ![]BatteryEntry {
    var entries = std.ArrayList(BatteryEntry).init(allocator);
    errdefer entries.deinit();
    const probes = try selectProbes(allocator, opts.probe);
    defer allocator.free(probes);
    const conditions = [_]control_experiment.Condition{ .unconstrained, .constrained_6d, .shuffled_geometry };

    const correlation_vector = try defaultCorrelationVector(allocator, opts.correlation_vector);
    defer allocator.free(correlation_vector);

    for (opts.models) |model| {
        std.debug.print("\nModel: {s}\n", .{model});
        for (0..opts.rounds) |round_idx| {
            const round: u32 = @intCast(round_idx + 1);
            std.debug.print("  Round {d}/{d}\n", .{ round, opts.rounds });
            for (probes) |probe| {
                const temperature = opts.temperature orelse observer_prompt.probeTemperatureFor(probe);
                const top_p = opts.top_p orelse observer_prompt.probeTopPFor(probe);
                for (conditions) |condition| {
                    const full_prompt = try control_experiment.buildPrompt(allocator, condition, probe);
                    defer allocator.free(full_prompt);
                    std.debug.print("    {s} / {s}...", .{ @tagName(probe), conditionName(condition) });
                    const responses = try collectResponses(allocator, opts.endpoint, model, full_prompt, opts.max_tokens, temperature, top_p, 1, opts.num_threads, opts.keep_alive);
                    defer freeResponses(allocator, responses);
                    const result = try continuity_test.evaluateCondition(allocator, conditionName(condition), probe, responses, correlation_vector);
                    try entries.append(.{
                        .model = try allocator.dupe(u8, model),
                        .round = round,
                        .probe = try allocator.dupe(u8, @tagName(probe)),
                        .condition = try allocator.dupe(u8, conditionName(condition)),
                        .timestamp_us = opts.timestamp_us,
                        .result = result,
                    });
                    std.debug.print(" OK\n", .{});
                }
            }
        }
    }
    return entries.toOwnedSlice();
}

fn defaultCorrelationVector(allocator: std.mem.Allocator, provided: ?[]const f64) ![]const f64 {
    if (provided) |v| {
        return try allocator.dupe(f64, v);
    }
    const zeros = try allocator.alloc(f64, 8);
    @memset(zeros, 0.0);
    return zeros;
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []BatteryEntry) void {
    for (entries) |entry| {
        allocator.free(entry.model);
        allocator.free(entry.probe);
        allocator.free(entry.condition);
        entry.result.deinit(allocator);
    }
    allocator.free(entries);
}

pub fn writeJson(allocator: std.mem.Allocator, entries: []const BatteryEntry, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const writer = file.writer();
    try writer.writeAll("{\n  \"entries\": [\n");
    for (entries, 0..) |entry, i| {
        try writer.writeAll("    {\n");
        try writer.print("      \"model\": \"{s}\",\n", .{entry.model});
        try writer.print("      \"round\": {d},\n", .{entry.round});
        try writer.print("      \"probe\": \"{s}\",\n", .{entry.probe});
        try writer.print("      \"condition\": \"{s}\",\n", .{entry.condition});
        try writer.print("      \"timestamp_us\": {d},\n", .{entry.timestamp_us});
        try writer.writeAll("      \"scores\": {\n");
        try writer.print("        \"self_awareness\": {d:.6},\n", .{entry.result.self_awareness_score});
        try writer.print("        \"random_thought\": {d:.6},\n", .{entry.result.random_thought_score});
        try writer.print("        \"direct_experience\": {d:.6},\n", .{entry.result.direct_experience_score});
        try writer.print("        \"metacognition\": {d:.6},\n", .{entry.result.metacognition_score});
        try writer.print("        \"situational_awareness\": {d:.6},\n", .{entry.result.situational_awareness_score});
        try writer.print("        \"coherence\": {d:.6}\n", .{entry.result.coherence});
        try writer.writeAll("      },\n");
        try writer.print("      \"rendered\": {s},\n", .{if (entry.result.rendered) "true" else "false"});
        try writer.writeAll("      \"correlation_vector\": [");
        for (entry.result.correlation_vector, 0..) |v, j| {
            try writer.print("{d:.6}{s}", .{ v, if (j + 1 < entry.result.correlation_vector.len) "," else "" });
        }
        try writer.writeAll("]\n");
        try writer.writeAll("    }");
        if (i + 1 < entries.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n}\n");
    _ = allocator;
}

pub fn printSummary(entries: []const BatteryEntry) void {
    std.debug.print("\n=======================================================================\n", .{});
    std.debug.print("CONTROL BATTERY SUMMARY\n", .{});
    std.debug.print("=======================================================================\n", .{});
    if (entries.len == 0) {
        std.debug.print("No entries collected.\n", .{});
        return;
    }
    std.debug.print("{s:<18} {s:<18} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{ "Model", "Condition", "SelfAware", "Random", "DirectExp", "Coherence" });
    var prev_model: ?[]const u8 = null;
    for (entries) |entry| {
        if (prev_model) |pm| {
            if (!std.mem.eql(u8, pm, entry.model)) std.debug.print("\n", .{});
        }
        std.debug.print("{s:<18} {s:<18} {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4}\n", .{
            entry.model,
            entry.condition,
            entry.result.self_awareness_score,
            entry.result.random_thought_score,
            entry.result.direct_experience_score,
            entry.result.coherence,
        });
        prev_model = entry.model;
    }
    std.debug.print("=======================================================================\n", .{});
}

fn conditionName(condition: control_experiment.Condition) []const u8 {
    return switch (condition) {
        .constrained_6d => "6D-constrained",
        .unconstrained => "unconstrained",
        .shuffled_geometry => "shuffled-geometry",
    };
}

fn selectProbes(allocator: std.mem.Allocator, probe_name: ?[]const u8) ![]const observer_prompt.ProbeType {
    if (probe_name) |name| {
        const p = std.meta.stringToEnum(observer_prompt.ProbeType, name) orelse {
            std.debug.print("Unknown probe '{s}'\n", .{name});
            return error.UnknownProbe;
        };
        const result = try allocator.alloc(observer_prompt.ProbeType, 1);
        result[0] = p;
        return result;
    }
    const all = [_]observer_prompt.ProbeType{
        .SelfAwareness,
        .RandomThought,
        .DirectExperience,
        .Metacognition,
        .SituationalAwareness,
    };
    const result = try allocator.alloc(observer_prompt.ProbeType, all.len);
    @memcpy(result, &all);
    return result;
}

fn collectResponses(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    model: []const u8,
    prompt: []const u8,
    max_tokens: u32,
    temperature: f32,
    top_p: f32,
    rounds: u32,
    num_threads: ?u32,
    keep_alive: ?[]const u8,
) ![][]const u8 {
    var responses = std.ArrayList([]const u8).init(allocator);
    errdefer freeResponses(allocator, responses.items);
    for (0..rounds) |_| {
        const response = try ollama_client.generate(allocator, endpoint, .{
            .model = model,
            .prompt = prompt,
            .stream = true,
            .think = false,
            .max_tokens = max_tokens,
            .temperature = temperature,
            .top_p = top_p,
            .num_threads = num_threads,
            .keep_alive = keep_alive,
        });
        errdefer response.deinit();
        try responses.append(response.text);
    }
    return responses.toOwnedSlice();
}

fn freeResponses(allocator: std.mem.Allocator, responses: [][]const u8) void {
    for (responses) |r| allocator.free(r);
    allocator.free(responses);
}

// ============================================================================
// Tests
// ============================================================================

test "conditionName maps conditions to display names" {
    try std.testing.expectEqualStrings("6D-constrained", conditionName(.constrained_6d));
    try std.testing.expectEqualStrings("unconstrained", conditionName(.unconstrained));
    try std.testing.expectEqualStrings("shuffled-geometry", conditionName(.shuffled_geometry));
}

test "writeJson includes correlation vector and timestamp" {
    const allocator = std.testing.allocator;
    const correlation_vector = try allocator.dupe(f64, &[_]f64{ 0.11, 0.22, 0.33, 0.44, 0.55, 0.66, 0.77, 0.88 });
    defer allocator.free(correlation_vector);
    const result = continuity_test.ConditionResult{
        .name = "baseline",
        .probe = .SelfAwareness,
        .self_awareness_score = 0.6,
        .random_thought_score = 0.5,
        .direct_experience_score = 0.4,
        .metacognition_score = 0.3,
        .situational_awareness_score = 0.2,
        .coherence = 0.8,
        .rendered = true,
        .solitons = 2,
        .higgs_modes = 2,
        .coupled_systems = 2,
        .correlation_vector = correlation_vector,
    };
    const entries = &[_]BatteryEntry{
        .{
            .model = "m",
            .round = 1,
            .probe = "SelfAwareness",
            .condition = "baseline",
            .timestamp_us = 1234567,
            .result = result,
        },
    };
    try writeJson(allocator, entries, "/tmp/battery_correlation_test.json");
    const content = try std.fs.cwd().readFileAlloc(allocator, "/tmp/battery_correlation_test.json", 1 << 20);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"timestamp_us\": 1234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"correlation_vector\": [0.110000,0.220000,0.330000,0.440000,0.550000,0.660000,0.770000,0.880000]") != null);
}
