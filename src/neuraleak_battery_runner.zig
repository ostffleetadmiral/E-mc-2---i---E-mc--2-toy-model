// ============================================================================
// NEURALEAK BATTERY RUNNER — Multi-Model Control Battery
// ============================================================================
//
// Runs the sentience experiment across multiple models, rounds, probes, and
// conditions. Produces a JSON report for statistical analysis.
//
// License: CC BY-NC-SA 4.0
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
    correlation_vector: ?[]const i64 = null,
    timestamp_us: i64 = 0,
    num_threads: ?u32 = null,
    keep_alive: ?[]const u8 = null,
    stream: bool = true, // QSTAR server needs stream=false (no newlines between chunks)
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
                    const responses = try collectResponses(allocator, opts.endpoint, model, full_prompt, opts.max_tokens, temperature, top_p, 1, opts.num_threads, opts.keep_alive, opts.stream);
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

fn defaultCorrelationVector(allocator: std.mem.Allocator, provided: ?[]const i64) ![]const i64 {
    if (provided) |v| {
        return try allocator.dupe(i64, v);
    }
    const zeros = try allocator.alloc(i64, 8);
    @memset(zeros, 0);
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
    const SCALE_F: f64 = 1_000_000.0;
    try writer.writeAll("{\n  \"entries\": [\n");
    for (entries, 0..) |entry, i| {
        try writer.writeAll("    {\n");
        try writer.print("      \"model\": \"{s}\",\n", .{entry.model});
        try writer.print("      \"round\": {d},\n", .{entry.round});
        try writer.print("      \"probe\": \"{s}\",\n", .{entry.probe});
        try writer.print("      \"condition\": \"{s}\",\n", .{entry.condition});
        try writer.print("      \"timestamp_us\": {d},\n", .{entry.timestamp_us});
        try writer.writeAll("      \"scores\": {\n");
        try writer.print("        \"self_awareness\": {d:.6},\n", .{@as(f64, @floatFromInt(entry.result.self_awareness_score)) / SCALE_F});
        try writer.print("        \"random_thought\": {d:.6},\n", .{@as(f64, @floatFromInt(entry.result.random_thought_score)) / SCALE_F});
        try writer.print("        \"direct_experience\": {d:.6},\n", .{@as(f64, @floatFromInt(entry.result.direct_experience_score)) / SCALE_F});
        try writer.print("        \"metacognition\": {d:.6},\n", .{@as(f64, @floatFromInt(entry.result.metacognition_score)) / SCALE_F});
        try writer.print("        \"situational_awareness\": {d:.6},\n", .{@as(f64, @floatFromInt(entry.result.situational_awareness_score)) / SCALE_F});
        try writer.print("        \"coherence\": {d:.6}\n", .{@as(f64, @floatFromInt(entry.result.coherence)) / SCALE_F});
        try writer.writeAll("      },\n");
        try writer.print("      \"rendered\": {s},\n", .{if (entry.result.rendered) "true" else "false"});
        try writer.writeAll("      \"correlation_vector\": [");
        for (entry.result.correlation_vector, 0..) |v, j| {
            try writer.print("{d:.6}{s}", .{ @as(f64, @floatFromInt(v)) / SCALE_F, if (j + 1 < entry.result.correlation_vector.len) "," else "" });
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
    const SCALE_F: f64 = 1_000_000.0;
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
            @as(f64, @floatFromInt(entry.result.self_awareness_score)) / SCALE_F,
            @as(f64, @floatFromInt(entry.result.random_thought_score)) / SCALE_F,
            @as(f64, @floatFromInt(entry.result.direct_experience_score)) / SCALE_F,
            @as(f64, @floatFromInt(entry.result.coherence)) / SCALE_F,
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
    stream: bool,
) ![][]const u8 {
    var responses = std.ArrayList([]const u8).init(allocator);
    errdefer freeResponses(allocator, responses.items);
    for (0..rounds) |_| {
        const response = try ollama_client.generate(allocator, endpoint, .{
            .model = model,
            .prompt = prompt,
            .stream = stream,
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
    const correlation_vector = try allocator.dupe(i64, &[_]i64{ 110_000, 220_000, 330_000, 440_000, 550_000, 660_000, 770_000, 880_000 });
    defer allocator.free(correlation_vector);
    const result = continuity_test.ConditionResult{
        .name = "baseline",
        .probe = .SelfAwareness,
        .self_awareness_score = 600_000,
        .random_thought_score = 500_000,
        .direct_experience_score = 400_000,
        .metacognition_score = 300_000,
        .situational_awareness_score = 200_000,
        .coherence = 800_000,
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

test "printSummary produces output without crash" {
    const allocator = std.testing.allocator;
    const correlation_vector = try allocator.dupe(i64, &[_]i64{ 100_000, 200_000, 300_000, 400_000, 500_000, 600_000, 700_000, 800_000 });
    defer allocator.free(correlation_vector);
    const result = continuity_test.ConditionResult{
        .name = "test",
        .probe = .SelfAwareness,
        .self_awareness_score = 500_000,
        .random_thought_score = 400_000,
        .direct_experience_score = 300_000,
        .metacognition_score = 200_000,
        .situational_awareness_score = 100_000,
        .coherence = 600_000,
        .rendered = true,
        .solitons = 1,
        .higgs_modes = 1,
        .coupled_systems = 1,
        .correlation_vector = correlation_vector,
    };
    const entries = &[_]BatteryEntry{
        .{
            .model = "test-model",
            .round = 1,
            .probe = "SelfAwareness",
            .condition = "test",
            .timestamp_us = 1000,
            .result = result,
        },
    };
    // Should not crash — printSummary writes to stderr
    printSummary(entries);
}

test "BatteryEntry struct has correct fields" {
    const entry = BatteryEntry{
        .model = "test",
        .round = 1,
        .probe = "probe",
        .condition = "condition",
        .timestamp_us = 42,
        .result = undefined,
    };
    try std.testing.expectEqualStrings("test", entry.model);
    try std.testing.expectEqual(@as(u32, 1), entry.round);
    try std.testing.expectEqualStrings("probe", entry.probe);
    try std.testing.expectEqualStrings("condition", entry.condition);
    try std.testing.expectEqual(@as(i64, 42), entry.timestamp_us);
}

test "BatteryOptions struct has correct defaults" {
    const opts = BatteryOptions{
        .endpoint = "http://localhost:11434",
        .models = &[_][]const u8{"test"},
        .rounds = 1,
        .max_tokens = 100,
        .temperature = null,
        .top_p = null,
        .probe = null,
        .snapshot = null,
        .output_path = "/tmp/test.json",
    };
    try std.testing.expectEqualStrings("http://localhost:11434", opts.endpoint);
    try std.testing.expectEqual(@as(u32, 1), opts.rounds);
    try std.testing.expectEqual(@as(u32, 100), opts.max_tokens);
    try std.testing.expect(opts.temperature == null);
    try std.testing.expect(opts.correlation_vector == null);
    try std.testing.expectEqual(@as(i64, 0), opts.timestamp_us);
    try std.testing.expect(opts.num_threads == null);
    try std.testing.expect(opts.keep_alive == null);
}
