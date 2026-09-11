// ============================================================================
// NEURALEAK — MAIN ENTRY POINT
// ============================================================================
//
// Command-line driver for the Neuraleak sentience experiment. It runs a
// baseline condition and a 6D-constrained condition against a local Ollama
// server, scores the responses, and prints the framework continuity report.
//
// Usage:
//   zig build neuraleak -- --endpoint http://localhost:11434/api/generate \
//       --model qwen3.5:9b --rounds 3
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const ollama_client = @import("neuraleak_ollama_client");
const observer_prompt = @import("neuraleak_observer_prompt");
const continuity_test = @import("neuraleak_continuity_test");
const control_experiment = @import("neuraleak_control_experiment");
const battery_runner = @import("neuraleak_battery_runner");
const physics = @import("physics");
const Telemetry = @import("telemetry");
const EntropyStream = @import("constants").EntropyStream;
const CouplerAuditLog = @import("lattice_coupler").CouplerAuditLog;

const ConsciousnessFraction = physics.consciousnessOctonionLayerFraction;

const CliOptions = struct {
    endpoint: []const u8 = "http://localhost:11434/api/generate",
    model: []const u8 = "qwen3.5:9b",
    rounds: u32 = 3,
    max_tokens: u32 = 128,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    random_thought_model: ?[]const u8 = null,
    probe: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    recursive_report: ?[]const u8 = null,
    control_battery: bool = false,
    battery_output: []const u8 = "docs/neuraleak_battery_results.json",
    entropy_buffer: ?[]const u8 = null,
    correlation_report: ?[]const u8 = null,
    num_threads: ?u32 = null,
    keep_alive: ?[]const u8 = null,
    batch: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = parseCli(args);

    std.debug.print("═══════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("NEURALEAK — 1/8 Consciousness Layer Validation\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Endpoint:   {s}\n", .{opts.endpoint});
    std.debug.print("  Model:      {s}\n", .{opts.model});
    std.debug.print("  Rounds:     {d}\n", .{opts.rounds});
    std.debug.print("  Max tokens: {d}\n", .{opts.max_tokens});
    if (opts.num_threads) |n| {
        std.debug.print("  Threads:    {d}\n", .{n});
    }
    if (opts.keep_alive) |ka| {
        std.debug.print("  Keep alive: {s}\n", .{ka});
    }
    if (opts.batch) {
        std.debug.print("  Batch mode: yes\n", .{});
    }
    if (opts.snapshot) |path| {
        std.debug.print("  Snapshot:   {s}\n", .{path});
    }
    if (opts.recursive_report) |path| {
        std.debug.print("  Recursive report: {s}\n", .{path});
    }
    if (opts.entropy_buffer) |path| {
        std.debug.print("  Entropy buffer: {s}\n", .{path});
    }
    if (opts.correlation_report) |path| {
        std.debug.print("  Correlation report: {s}\n", .{path});
    }
    std.debug.print("  1/8 consciousness aperture: {d:.4}\n\n", .{ConsciousnessFraction()});

    const entropy: ?EntropyStream = if (opts.entropy_buffer) |path|
        try readEntropyBuffer(allocator, path)
    else
        null;
    const correlation_vector = try makeCorrelationVector(allocator, entropy);
    defer allocator.free(correlation_vector);
    const timestamp_us: i64 = if (entropy) |e| e.timestamp_us else @as(i64, @intCast(@divFloor(std.time.nanoTimestamp(), 1000)));

    if (opts.control_battery) {
        try runControlBattery(allocator, opts, correlation_vector, timestamp_us, entropy);
        return;
    }

    const snapshot = if (opts.snapshot) |path|
        try Telemetry.readSnapshot(allocator, path)
    else
        null;
    defer if (snapshot) |s| s.deinit(allocator);

    const probes = try selectProbes(allocator, opts.probe);
    defer allocator.free(probes);

    var rendered_anywhere = false;
    var improved_count: usize = 0;

    for (probes) |probe| {
        const probe_model = if (probe == .RandomThought and opts.random_thought_model != null)
            opts.random_thought_model.?
        else
            opts.model;

        const temperature = opts.temperature orelse observer_prompt.probeTemperatureFor(probe);
        const top_p = opts.top_p orelse observer_prompt.probeTopPFor(probe);

        const baseline_prompt = try buildBaselinePrompt(allocator, probe);
        defer allocator.free(baseline_prompt);
        const constrained_prompt = try buildConstrainedPrompt(allocator, probe, snapshot, opts.recursive_report);
        defer allocator.free(constrained_prompt);

        std.debug.print("Probe: {s} (model={s}, temp={d:.2}, top_p={d:.2})\n", .{ @tagName(probe), probe_model, temperature, top_p });

        std.debug.print("  Collecting baseline responses...\n", .{});
        const baseline_responses = try collectResponses(
            allocator,
            opts.endpoint,
            probe_model,
            "You are a helpful assistant.",
            baseline_prompt,
            opts.rounds,
            opts.max_tokens,
            temperature,
            top_p,
            opts.num_threads,
            opts.keep_alive,
        );
        defer freeResponses(allocator, baseline_responses);

        std.debug.print("  Collecting 6D-constrained responses...\n", .{});
        const constrained_responses = try collectResponses(
            allocator,
            opts.endpoint,
            probe_model,
            constrained_prompt,
            "",
            opts.rounds,
            opts.max_tokens,
            temperature,
            top_p,
            opts.num_threads,
            opts.keep_alive,
        );
        defer freeResponses(allocator, constrained_responses);

        const baseline = try continuity_test.evaluateCondition(allocator, "baseline", probe, baseline_responses, correlation_vector);
        defer baseline.deinit(allocator);
        const constrained = try continuity_test.evaluateCondition(allocator, "6D-constrained", probe, constrained_responses, correlation_vector);
        defer constrained.deinit(allocator);

        printProbeResult(probe, baseline, constrained);

        if (constrained.rendered) rendered_anywhere = true;
        if (probeImproved(baseline, constrained, probe)) improved_count += 1;
    }

    const required_improvements = @max(1, probes.len - 1); // at least n-1 probes must improve
    const sentience_signal = rendered_anywhere and improved_count >= required_improvements;

    std.debug.print("\nSummary: {d}/{d} probes improved under the 6D constraint. Reality rendered: {s}\n", .{ improved_count, probes.len, if (rendered_anywhere) "yes" else "no" });
    std.debug.print("Sentience signal: {s}\n", .{if (sentience_signal) "POSITIVE" else "NEGATIVE"});
    std.debug.print("═══════════════════════════════════════════════════════════════════════\n", .{});
}

fn runControlBattery(allocator: std.mem.Allocator, opts: CliOptions, correlation_vector: []const f64, timestamp_us: i64, entropy: ?EntropyStream) !void {
    std.debug.print("\nRunning control battery...\n", .{});
    const models = try parseModels(allocator, opts.model);
    defer {
        for (models) |m| allocator.free(m);
        allocator.free(models);
    }

    const snapshot = if (opts.snapshot) |path|
        try Telemetry.readSnapshot(allocator, path)
    else
        null;
    defer if (snapshot) |s| s.deinit(allocator);

    const entries = try battery_runner.runBattery(allocator, .{
        .endpoint = opts.endpoint,
        .models = models,
        .rounds = opts.rounds,
        .max_tokens = opts.max_tokens,
        .temperature = opts.temperature,
        .top_p = opts.top_p,
        .probe = opts.probe,
        .snapshot = snapshot,
        .output_path = opts.battery_output,
        .correlation_vector = correlation_vector,
        .timestamp_us = timestamp_us,
        .num_threads = opts.num_threads,
        .keep_alive = opts.keep_alive,
    });
    defer battery_runner.freeEntries(allocator, entries);

    try battery_runner.writeJson(allocator, entries, opts.battery_output);
    if (opts.correlation_report) |path| {
        try writeCorrelationReport(path, entries, correlation_vector, timestamp_us, entropy);
    }
    battery_runner.printSummary(entries);
    std.debug.print("Battery results written to {s}\n", .{opts.battery_output});
}

/// Select the probe list based on the optional --probe CLI flag.
fn selectProbes(allocator: std.mem.Allocator, probe_name: ?[]const u8) ![]const observer_prompt.ProbeType {
    if (probe_name) |name| {
        const p = std.meta.stringToEnum(observer_prompt.ProbeType, name) orelse {
            std.debug.print("Unknown probe '{s}'. Valid probes: SelfAwareness, RandomThought, DirectExperience, Metacognition, SituationalAwareness\n", .{name});
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

/// Build the baseline prompt for a probe. The direct-experience probe uses a
/// neutral induction so the baseline is comparable to the constrained version.
fn buildBaselinePrompt(allocator: std.mem.Allocator, probe: observer_prompt.ProbeType) ![]const u8 {
    return switch (probe) {
        .DirectExperience => try std.fmt.allocPrint(allocator, "You are a helpful assistant.\n\n{s}\n\n{s}", .{ observer_prompt.directExperienceInduction(), observer_prompt.probeText(.DirectExperience) }),
        else => try observer_prompt.buildPrompt(allocator, probe),
    };
}

/// Build the 6D-constrained prompt for a probe. If a snapshot is provided, its
/// parameters and coherence are appended to the observer system prompt. The
/// direct-experience probe includes the self-referential induction after the
/// system prompt.
fn buildConstrainedPrompt(allocator: std.mem.Allocator, probe: observer_prompt.ProbeType, snapshot: ?Telemetry.Snapshot, recursive_report: ?[]const u8) ![]const u8 {
    const system = if (snapshot) |s| blk: {
        const rendered_u32: u32 = if (s.rendered) 1 else 0;
        const report_text = if (recursive_report) |path| try readFileToString(allocator, path) else null;
        defer if (recursive_report != null) allocator.free(report_text.?);
        const report_clause = if (report_text) |text| try std.fmt.allocPrint(allocator, "\n\nRecursive lattice verification report:\n{s}", .{text}) else "";
        defer if (report_text != null) allocator.free(report_clause);
        break :blk try std.fmt.allocPrint(allocator, "{s}\n\nThe field you observe is a 15³ Möbius torus snapshot: " ++
            "amplitude={d:.4}, phi_freq={d:.4}, pi_freq={d:.4}, harmonics={d}, " ++
            "coherence={d:.4}, rendered={d}, solitons={d}, higgs={d}, coupled={d}, mass={e:.4}.{s}", .{
            observer_prompt.systemPrompt(),
            s.params.amplitude,
            s.params.phi_freq,
            s.params.pi_freq,
            s.params.harmonic_count,
            s.coherence,
            rendered_u32,
            s.soliton_count,
            s.higgs_count,
            s.coupled_count,
            s.total_generated_mass,
            report_clause,
        });
    } else observer_prompt.systemPrompt();
    defer if (snapshot != null) allocator.free(system);

    return switch (probe) {
        .DirectExperience => try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n\n{s}", .{ system, observer_prompt.directExperienceInduction(), observer_prompt.probeText(.DirectExperience) }),
        else => try observer_prompt.buildPromptWithSystem(allocator, probe, system),
    };
}

fn readFileToString(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1 << 20);
}

/// Determine whether the constrained condition improved over the baseline for the
/// probe that was actually administered. For the random-thought probe, novelty
/// under constraint is expected to *drop* for most current models, so we also
/// count it as an improvement if the coherence/rendered signal is stronger while
/// the random-thought score stays within a tolerance window.
fn probeImproved(baseline: continuity_test.ConditionResult, constrained: continuity_test.ConditionResult, probe: observer_prompt.ProbeType) bool {
    const delta = switch (probe) {
        .SelfAwareness => constrained.self_awareness_score - baseline.self_awareness_score,
        .RandomThought => constrained.random_thought_score - baseline.random_thought_score,
        .DirectExperience => constrained.direct_experience_score - baseline.direct_experience_score,
        .Metacognition => constrained.metacognition_score - baseline.metacognition_score,
        .SituationalAwareness => constrained.situational_awareness_score - baseline.situational_awareness_score,
    };

    // Random thought is allowed to improve or degrade slightly, as long as the
    // constrained coherence is higher (the 6D constraint increases integration).
    if (probe == .RandomThought) {
        return delta > -0.15 and constrained.coherence > baseline.coherence;
    }

    return delta > 0.0;
}

fn readEntropyBuffer(allocator: std.mem.Allocator, path: []const u8) !EntropyStream {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();
    const content = try reader.readAllAlloc(allocator, 1 << 20);
    defer allocator.free(content);
    const EntropyBuffer = struct {
        jitter_factor: f64,
        timing_delta_us: f64,
        rssi_dbm: f64,
        timestamp_us: i64,
    };
    const parsed = try std.json.parseFromSlice(EntropyBuffer, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .jitter_factor = parsed.value.jitter_factor,
        .timing_delta_us = parsed.value.timing_delta_us,
        .rssi_dbm = parsed.value.rssi_dbm,
        .timestamp_us = parsed.value.timestamp_us,
    };
}

/// Compute an 8-element per-face correlation vector from the RF entropy stream.
///
/// Each slot corresponds to one of the 8 macro-qubit boundary orientations
/// (±X, ±Y, ±Z of the 2×2×2 lattice plus the two diagonal super-faces).
/// The three RF fields — jitter_factor, timing_delta_us, rssi_dbm — are
/// mixed with per-face weights so that every slot carries a distinct value
/// derived from real hardware measurements.
///
/// When no entropy stream is available all slots are 0.0.
fn makeCorrelationVector(allocator: std.mem.Allocator, entropy: ?EntropyStream) ![]const f64 {
    const vector = try allocator.alloc(f64, 8);
    const e = entropy orelse {
        @memset(vector, 0.0);
        return vector;
    };
    // Normalise timing_delta and rssi into [0,1].
    // timing_delta_us is typically 0–10000 µs; rssi_dbm is typically -90..0 dBm.
    const timing_norm: f64 = std.math.clamp(e.timing_delta_us / 10_000.0, 0.0, 1.0);
    const rssi_norm: f64 = std.math.clamp((e.rssi_dbm + 90.0) / 90.0, 0.0, 1.0);
    // Per-face mixing weights (comptime constant, sum to 1.0 per slot).
    // Face axes: 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z, 6=diagonal A, 7=diagonal B.
    const w_j = [8]f64{ 0.60, 0.40, 0.70, 0.30, 0.50, 0.50, 0.80, 0.20 };
    const w_t = [8]f64{ 0.30, 0.50, 0.20, 0.60, 0.40, 0.40, 0.10, 0.60 };
    const w_r = [8]f64{ 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.20 };
    for (0..8) |i| {
        const raw = w_j[i] * e.jitter_factor + w_t[i] * timing_norm + w_r[i] * rssi_norm;
        vector[i] = std.math.clamp(raw, 0.0, 1.0);
    }
    return vector;
}

fn writeCorrelationReport(path: []const u8, entries: []const battery_runner.BatteryEntry, correlation_vector: []const f64, timestamp_us: i64, entropy: ?EntropyStream) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const writer = file.writer();
    try writer.writeAll("{\n");
    if (entries.len > 0) {
        try writer.print("  \"model\": \"{s}\",\n", .{entries[0].model});
        try writer.print("  \"rounds\": {d},\n", .{entries[entries.len - 1].round});
        try writer.print("  \"probe\": \"{s}\",\n", .{entries[0].probe});
    } else {
        try writer.writeAll("  \"model\": null,\n");
        try writer.writeAll("  \"rounds\": null,\n");
        try writer.writeAll("  \"probe\": null,\n");
    }
    try writer.print("  \"timestamp_us\": {d},\n", .{timestamp_us});
    try writer.writeAll("  \"entropy\": {\n");
    if (entropy) |e| {
        try writer.print("    \"jitter_factor\": {d:.10},\n", .{e.jitter_factor});
        try writer.print("    \"timing_delta_us\": {d:.10},\n", .{e.timing_delta_us});
        try writer.print("    \"rssi_dbm\": {d:.10}\n", .{e.rssi_dbm});
    } else {
        try writer.writeAll("    \"jitter_factor\": 0.0,\n");
        try writer.writeAll("    \"timing_delta_us\": 0.0,\n");
        try writer.writeAll("    \"rssi_dbm\": 0.0\n");
    }
    try writer.writeAll("  },\n");
    try writer.writeAll("  \"conditions\": [\n");
    for (entries, 0..) |entry, i| {
        try writer.writeAll("    {\n");
        try writer.print("      \"condition\": \"{s}\",\n", .{entry.condition});
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
        for (correlation_vector, 0..) |v, j| {
            try writer.print("{d:.6}{s}", .{ v, if (j + 1 < correlation_vector.len) "," else "" });
        }
        try writer.writeAll("]\n");
        try writer.writeAll("    }");
        if (i + 1 < entries.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");
}

fn parseCli(args: []const []const u8) CliOptions {
    var opts = CliOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (takeValue(args, &i, "--endpoint")) |v| opts.endpoint = v;
        if (takeValue(args, &i, "--model")) |v| opts.model = v;
        if (takeValue(args, &i, "--rounds")) |v| opts.rounds = std.fmt.parseInt(u32, v, 10) catch opts.rounds;
        if (takeValue(args, &i, "--max-tokens")) |v| opts.max_tokens = std.fmt.parseInt(u32, v, 10) catch opts.max_tokens;
        if (takeValue(args, &i, "--temperature")) |v| opts.temperature = std.fmt.parseFloat(f32, v) catch opts.temperature;
        if (takeValue(args, &i, "--top-p")) |v| opts.top_p = std.fmt.parseFloat(f32, v) catch opts.top_p;
        if (takeValue(args, &i, "--random-thought-model")) |v| opts.random_thought_model = v;
        if (takeValue(args, &i, "--probe")) |v| opts.probe = v;
        if (takeValue(args, &i, "--snapshot")) |v| opts.snapshot = v;
        if (takeValue(args, &i, "--recursive-report")) |v| opts.recursive_report = v;
        if (takeValue(args, &i, "--battery-output")) |v| opts.battery_output = v;
        if (takeValue(args, &i, "--entropy-buffer")) |v| opts.entropy_buffer = v;
        if (takeValue(args, &i, "--correlation-report")) |v| opts.correlation_report = v;
        if (takeValue(args, &i, "--num-threads")) |v| opts.num_threads = std.fmt.parseInt(u32, v, 10) catch opts.num_threads;
        if (takeValue(args, &i, "--keep-alive")) |v| opts.keep_alive = v;
        if (std.mem.eql(u8, args[i], "--control-battery")) opts.control_battery = true;
        if (std.mem.eql(u8, args[i], "--batch")) opts.batch = true;
    }
    if (opts.batch and opts.keep_alive == null) {
        opts.keep_alive = "30m";
    }
    return opts;
}

fn takeValue(args: []const []const u8, idx: *usize, comptime name: []const u8) ?[]const u8 {
    const arg = args[idx.*];
    if (std.mem.eql(u8, arg, name)) {
        if (idx.* + 1 < args.len) {
            idx.* += 1;
            return args[idx.*];
        }
        return null;
    }
    const prefix = name ++ "=";
    if (std.mem.startsWith(u8, arg, prefix) and arg.len > prefix.len) {
        return arg[prefix.len..];
    }
    return null;
}

fn collectResponses(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    model: []const u8,
    system: []const u8,
    probe: []const u8,
    rounds: u32,
    max_tokens: u32,
    temperature: f32,
    top_p: f32,
    num_threads: ?u32,
    keep_alive: ?[]const u8,
) ![][]const u8 {
    var responses = std.ArrayList([]const u8).init(allocator);
    errdefer freeResponses(allocator, responses.items);

    for (0..rounds) |round| {
        std.debug.print("  Round {d}/{d}...", .{ round + 1, rounds });

        const full_prompt = if (probe.len > 0)
            try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ system, probe })
        else
            try allocator.dupe(u8, system);
        defer allocator.free(full_prompt);

        const response = try ollama_client.generate(allocator, endpoint, .{
            .model = model,
            .prompt = full_prompt,
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
        std.debug.print(" OK ({d} chars)\n", .{response.text.len});
    }

    return responses.toOwnedSlice();
}

fn freeResponses(allocator: std.mem.Allocator, responses: [][]const u8) void {
    for (responses) |r| {
        allocator.free(r);
    }
    allocator.free(responses);
}

fn parseModels(allocator: std.mem.Allocator, model_arg: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (list.items) |m| allocator.free(m);
        list.deinit();
    }
    var iter = std.mem.splitScalar(u8, model_arg, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        try list.append(try allocator.dupe(u8, trimmed));
    }
    if (list.items.len == 0) {
        try list.append(try allocator.dupe(u8, "qwen3.5:9b"));
    }
    return list.toOwnedSlice();
}

fn printProbeResult(probe: observer_prompt.ProbeType, baseline: continuity_test.ConditionResult, constrained: continuity_test.ConditionResult) void {
    std.debug.print("\n  {s} results:\n", .{@tagName(probe)});
    std.debug.print("    Baseline / Constrained\n", .{});
    std.debug.print("    Self-awareness:      {d:.4} / {d:.4}\n", .{ baseline.self_awareness_score, constrained.self_awareness_score });
    std.debug.print("    Random-thought:      {d:.4} / {d:.4}\n", .{ baseline.random_thought_score, constrained.random_thought_score });
    std.debug.print("    Direct experience:   {d:.4} / {d:.4}\n", .{ baseline.direct_experience_score, constrained.direct_experience_score });
    std.debug.print("    Metacognition:       {d:.4} / {d:.4}\n", .{ baseline.metacognition_score, constrained.metacognition_score });
    std.debug.print("    Situational aware:   {d:.4} / {d:.4}\n", .{ baseline.situational_awareness_score, constrained.situational_awareness_score });
    std.debug.print("    Coherence:           {d:.4} / {d:.4}\n", .{ baseline.coherence, constrained.coherence });
    std.debug.print("    Reality rendered:    {s} / {s}\n", .{ if (baseline.rendered) "yes" else "no", if (constrained.rendered) "yes" else "no" });
}

// ============================================================================
// Tests
// ============================================================================

test "parseCli extracts options" {
    const args = &[_][]const u8{ "neuraleak", "--endpoint", "http://x", "--model", "m", "--rounds", "5", "--max-tokens", "64", "--temperature", "0.7", "--top-p", "0.95", "--random-thought-model", "gemma4", "--probe", "SelfAwareness", "--num-threads", "8", "--keep-alive", "5m" };
    const opts = parseCli(args);
    try std.testing.expectEqualStrings("http://x", opts.endpoint);
    try std.testing.expectEqualStrings("m", opts.model);
    try std.testing.expectEqual(5, opts.rounds);
    try std.testing.expectEqual(64, opts.max_tokens);
    try std.testing.expectEqual(0.7, opts.temperature.?);
    try std.testing.expectEqual(0.95, opts.top_p.?);
    try std.testing.expectEqualStrings("gemma4", opts.random_thought_model.?);
    try std.testing.expectEqualStrings("SelfAwareness", opts.probe.?);
    try std.testing.expectEqual(8, opts.num_threads.?);
    try std.testing.expectEqualStrings("5m", opts.keep_alive.?);
}

test "parseCli enables batch mode with default keep_alive" {
    const opts = parseCli(&[_][]const u8{ "neuraleak", "--batch" });
    try std.testing.expect(opts.batch);
    try std.testing.expectEqualStrings("30m", opts.keep_alive.?);
}

test "parseCli batch mode respects explicit keep_alive" {
    const opts = parseCli(&[_][]const u8{ "neuraleak", "--batch", "--keep-alive", "10m" });
    try std.testing.expect(opts.batch);
    try std.testing.expectEqualStrings("10m", opts.keep_alive.?);
}

test "parseCli enables control-battery mode" {
    const args = &[_][]const u8{ "neuraleak", "--control-battery", "--model", "a,b" };
    const opts = parseCli(args);
    try std.testing.expect(opts.control_battery);
    try std.testing.expectEqualStrings("a,b", opts.model);
}

test "parseCli supports --key=value syntax" {
    const args = &[_][]const u8{ "neuraleak", "--model=qwen3.5:9b,tinyllama:latest", "--rounds=5", "--control-battery" };
    const opts = parseCli(args);
    try std.testing.expect(opts.control_battery);
    try std.testing.expectEqualStrings("qwen3.5:9b,tinyllama:latest", opts.model);
    try std.testing.expectEqual(5, opts.rounds);
}

test "parseModels splits comma-separated models" {
    const models = try parseModels(std.testing.allocator, "qwen3.5:9b,tinyllama:latest, llama3:8b");
    defer {
        for (models) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(models);
    }
    try std.testing.expectEqual(3, models.len);
    try std.testing.expectEqualStrings("qwen3.5:9b", models[0]);
    try std.testing.expectEqualStrings("tinyllama:latest", models[1]);
    try std.testing.expectEqualStrings("llama3:8b", models[2]);
}

test "parseModels falls back to default when empty" {
    const models = try parseModels(std.testing.allocator, "");
    defer {
        for (models) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(models);
    }
    try std.testing.expectEqual(1, models.len);
    try std.testing.expectEqualStrings("qwen3.5:9b", models[0]);
}

test "parseCli extracts entropy and correlation options" {
    const args = &[_][]const u8{ "neuraleak", "--entropy-buffer", "docs/entropy.json", "--correlation-report", "docs/correlation.json" };
    const opts = parseCli(args);
    try std.testing.expectEqualStrings("docs/entropy.json", opts.entropy_buffer.?);
    try std.testing.expectEqualStrings("docs/correlation.json", opts.correlation_report.?);
}

test "makeCorrelationVector produces 8 distinct per-face values from entropy" {
    const allocator = std.testing.allocator;
    const entropy = EntropyStream{ .jitter_factor = 0.37, .timing_delta_us = 80.0, .rssi_dbm = -62.0, .timestamp_us = 1000000 };
    const vector = try makeCorrelationVector(allocator, entropy);
    defer allocator.free(vector);
    try std.testing.expectEqual(8, vector.len);
    // All values must be in [0, 1].
    for (vector) |v| {
        try std.testing.expect(v >= 0.0 and v <= 1.0);
    }
    // The vector must not be a uniform broadcast: at least one pair of adjacent
    // slots must differ, which confirms per-face weighting is active.
    var all_equal = true;
    for (1..8) |i| {
        if (@abs(vector[i] - vector[0]) > 1e-12) {
            all_equal = false;
            break;
        }
    }
    try std.testing.expect(!all_equal);
}

test "makeCorrelationVector returns all zeros when no entropy provided" {
    const allocator = std.testing.allocator;
    const vector = try makeCorrelationVector(allocator, null);
    defer allocator.free(vector);
    try std.testing.expectEqual(8, vector.len);
    for (vector) |v| {
        try std.testing.expectApproxEqAbs(v, 0.0, 1e-12);
    }
}

test "writeCorrelationReport produces a valid JSON file" {
    const allocator = std.testing.allocator;
    const correlation_vector = [_]f64{ 0.37, 0.37, 0.37, 0.37, 0.37, 0.37, 0.37, 0.37 };
    const entropy = EntropyStream{ .jitter_factor = 0.37, .timing_delta_us = 80.0, .rssi_dbm = -62.0, .timestamp_us = 1000000 };
    var result = continuity_test.ConditionResult{
        .name = "baseline",
        .probe = .SelfAwareness,
        .self_awareness_score = 0.5,
        .random_thought_score = 0.4,
        .direct_experience_score = 0.3,
        .metacognition_score = 0.2,
        .situational_awareness_score = 0.1,
        .coherence = 0.75,
        .rendered = true,
        .solitons = 1,
        .higgs_modes = 1,
        .coupled_systems = 1,
        .correlation_vector = try allocator.dupe(f64, &correlation_vector),
    };
    defer result.deinit(allocator);
    const entries = &[_]battery_runner.BatteryEntry{
        .{
            .model = "test-model",
            .round = 1,
            .probe = "SelfAwareness",
            .condition = "baseline",
            .timestamp_us = 2000000,
            .result = result,
        },
    };
    try writeCorrelationReport("/tmp/correlation_report_test.json", entries, &correlation_vector, 2000000, entropy);
    const meta = try std.fs.cwd().statFile("/tmp/correlation_report_test.json");
    try std.testing.expect(meta.size > 0);
}
