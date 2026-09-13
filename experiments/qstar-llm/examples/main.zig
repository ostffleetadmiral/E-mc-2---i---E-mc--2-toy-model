//! Qstar-LLM Example — demonstrates core inference, state persistence, face sync,
//! tool calling, training pipeline, and configuration management.
//!
//! Usage:
//!   zig build run                          — basic inference demo
//!   zig build run -- chat "Hello"          — chat mode with prompt
//!   zig build run -- persist               — state save/load demo
//!   zig build run -- sync                  — distributed face sync demo
//!   zig build run -- tools                 — tool calling engine demo
//!   zig build run -- train                 — self-training pipeline demo
//!   zig build run -- config                — configuration management demo

const std = @import("std");
const agent_mod = @import("agent");
const fp = @import("fixed_point");
const store = @import("state_store");
const face = @import("face_sync");
const tools_mod = @import("tools");
const training = @import("training");
const config_mod = @import("config");
const memory_pool = @import("memory_pool");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "chat")) {
            return runChat(allocator, args);
        } else if (std.mem.eql(u8, args[1], "persist")) {
            return runPersist(allocator);
        } else if (std.mem.eql(u8, args[1], "sync")) {
            return runSync(allocator);
        } else if (std.mem.eql(u8, args[1], "tools")) {
            return runTools(allocator);
        } else if (std.mem.eql(u8, args[1], "train")) {
            return runTrain(allocator);
        } else if (std.mem.eql(u8, args[1], "config")) {
            return runConfig(allocator);
        }
    }

    return runBasic(allocator);
}

fn runBasic(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Qstar-LLM — Lattice-Native Inference Engine\n", .{});
    try stdout.print("============================================\n\n", .{});

    var a = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer a.deinit();

    try stdout.print("State size: {d} bytes\n", .{a.stateSizeBytes()});
    try stdout.print("E0 nodes:   {d}\n", .{agent_mod.E0_NODE_COUNT});
    try stdout.print("Channels:   {d}\n\n", .{agent_mod.CHANNEL_COUNT});

    try stdout.print("Ingesting: \"The lattice is the model.\"\n", .{});
    try a.ingest("The lattice is the model. Every node is a neuron.");
    try a.run(10);
    try stdout.print("Cycles run: {d}\n", .{a.state.cycle});
    try stdout.print("Active nodes: {d}\n", .{a.activeNodeCount()});

    const output = try a.decode(allocator);
    defer allocator.free(output);
    try stdout.print("Decoded output: \"{s}\"\n\n", .{output});

    try stdout.print("Introspection:\n", .{});
    const model = a.introspect();
    try stdout.print("  Entropy:          {d:.4}\n", .{model.activation_entropy});
    try stdout.print("  Peak node:        {d}\n", .{model.peak_node});
    try stdout.print("  Peak channel:     {d}\n", .{model.peak_channel});
    try stdout.print("  Channel imbalance: {d:.4}\n", .{model.channel_imbalance});
    try stdout.print("  Vocab richness:   {d:.4}\n", .{model.vocabulary_richness});
    try stdout.print("  Description:      {s}\n", .{model.descriptionSlice()});
    try stdout.print("\nDone. Try: zig build run -- chat \"Hello\"\n", .{});
    try stdout.print("     or:  zig build run -- tools\n", .{});
    try stdout.print("     or:  zig build run -- train\n", .{});
    try stdout.print("     or:  zig build run -- config\n", .{});
}

fn runChat(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var a = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer a.deinit();

    const prompt = if (args.len > 2) args[2] else "Hello, what are you?";
    try stdout.print("User: {s}\n", .{prompt});

    try a.ingest(prompt);
    try a.run(15);

    const response = try a.generateLongForm(prompt, allocator);
    defer allocator.free(response);
    try stdout.print("Agent: {s}\n", .{response});
}

fn runPersist(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Qstar-LLM — State Persistence Demo\n\n", .{});

    var a = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer a.deinit();

    try a.ingest("Persistence test — saving and loading lattice state.");
    try a.run(10);
    try stdout.print("Agent A — cycle: {d}, active: {d}\n", .{ a.state.cycle, a.activeNodeCount() });

    var st = store.StateStore.init(allocator);
    defer st.deinit();
    try a.saveStateToVFS(&st);
    try stdout.print("State saved to StateStore.\n", .{});

    var b = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer b.deinit();
    try stdout.print("Agent B — cycle: {d} (before load)\n", .{b.state.cycle});

    const loaded = try b.loadStateFromVFS(&st);
    if (loaded) {
        try stdout.print("Agent B — cycle: {d} (after load)\n", .{b.state.cycle});
        try stdout.print("State restored successfully!\n", .{});
    } else {
        try stdout.print("Failed to load state.\n", .{});
    }
}

fn runSync(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Qstar-LLM — Face Sync Demo\n\n", .{});

    var agent_a = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer agent_a.deinit();
    try agent_a.ingest("Distributed inference across lattice peers.");
    try agent_a.run(10);
    try stdout.print("Agent A — cycle: {d}, active: {d}\n", .{ agent_a.state.cycle, agent_a.activeNodeCount() });

    var faces = try agent_a.agentToSharedFaces(allocator, "peer-a");
    try stdout.print("Generated {d} SharedFaces for sync.\n", .{faces.len});

    for (0..7) |ch| {
        for (0..225) |i| {
            faces[ch].remote_states[i] = faces[ch].local_states[i];
        }
    }

    var agent_b = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer agent_b.deinit();
    agent_b.sharedFacesToAgent(&faces);
    try stdout.print("Agent B loaded from SharedFaces — active: {d}\n", .{agent_b.activeNodeCount()});

    for (0..7) |ch| {
        const corr = faces[ch].mobiusCorrelation();
        try stdout.print("  Channel {d} Möbius correlation: {d}\n", .{ ch, corr });
    }

    try stdout.print("\nFace sync complete — 225 nodes synced per channel.\n", .{});
}

fn runTools(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Qstar-LLM — Tool Calling Engine Demo\n\n", .{});

    var reg = tools_mod.ToolRegistry.init(allocator);
    defer reg.deinit();

    try reg.register(tools_mod.ToolDefinition{
        .name = "calculate",
        .description = "Performs arithmetic calculations.",
        .parameters = &.{
            .{ .name = "operation", .param_type = .string, .description = "add, sub, mul, div, sqrt, exp, log" },
            .{ .name = "a", .param_type = .number, .description = "First operand" },
            .{ .name = "b", .param_type = .number, .description = "Second operand" },
        },
    });
    try reg.register(tools_mod.ToolDefinition{
        .name = "time_now",
        .description = "Returns the current UTC time.",
        .parameters = &.{},
    });
    try reg.register(tools_mod.ToolDefinition{
        .name = "word_count",
        .description = "Counts words in text.",
        .parameters = &.{
            .{ .name = "text", .param_type = .string, .description = "Text to count" },
        },
    });

    try stdout.print("Registered 3 tools.\n\n", .{});

    const calc_result = try reg.execute(.{
        .id = "call1",
        .name = "calculate",
        .arguments_json = "{\"operation\":\"mul\",\"a\":42,\"b\":13}",
    });
    defer allocator.free(calc_result);
    try stdout.print("calculate(mul, 42, 13) = {s}\n", .{calc_result});

    const time_result = try reg.execute(.{ .id = "call2", .name = "time_now", .arguments_json = "{}" });
    defer allocator.free(time_result);
    try stdout.print("time_now() = {s}\n", .{time_result});

    const wc_result = try reg.execute(.{
        .id = "call3",
        .name = "word_count",
        .arguments_json = "{\"text\":\"The lattice is the model every node is a neuron\"}",
    });
    defer allocator.free(wc_result);
    try stdout.print("word_count(\"The lattice is the model...\") = {s}\n", .{wc_result});

    try stdout.print("\nTool calling demo complete.\n", .{});
}

fn runTrain(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Qstar-LLM — Self-Training Pipeline Demo\n\n", .{});

    var a = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer a.deinit();

    try stdout.print("Agent initialized — corpus size: {d}\n", .{a.dynamic_corpus.items.len});

    const prompts = [_][]const u8{
        "The lattice is the model. Every node is a neuron.",
        "Knowledge is power. Understanding is the key to wisdom.",
        "Science is the systematic study of the natural world.",
    };

    const config = training.TrainingConfig{
        .verbose = true,
    };

    const result = try training.trainBatch(&a, &prompts, config, allocator);
    try stdout.print("\nTraining complete:\n", .{});
    try stdout.print("  Prompts processed: {d}\n", .{result.prompts_processed});
    try stdout.print("  Sentences learned: {d}\n", .{result.sentences_learned});
    try stdout.print("  Corpus size before: {d}\n", .{result.corpus_size_before});
    try stdout.print("  Corpus size after:  {d}\n", .{result.corpus_size_after});

    try stdout.print("\nGenerating response after training...\n", .{});
    try a.ingest("What is the lattice?");
    try a.run(15);
    const response = try a.generateLongForm("What is the lattice?", allocator);
    defer allocator.free(response);
    try stdout.print("Agent: {s}\n", .{response});

    try stdout.print("\nTraining demo complete.\n", .{});
}

fn runConfig(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Qstar-LLM — Configuration & Memory Pool Demo\n\n", .{});

    const cfg = config_mod.Config{
        .lattice_level = 3,
        .use_dedup = false,
        .agent_level = 2,
        .agent_max_cycles = 512,
        .mesh_port = 8080,
    };

    const json = try cfg.toJson(allocator);
    defer allocator.free(json);
    try stdout.print("Config JSON:\n{s}\n\n", .{json});

    const parsed = try config_mod.Config.fromJson(allocator, json);
    try stdout.print("Parsed config:\n", .{});
    try stdout.print("  Lattice level:  {d}\n", .{parsed.lattice_level});
    try stdout.print("  Agent level:    {d}\n", .{parsed.agent_level});
    try stdout.print("  Max cycles:     {d}\n", .{parsed.agent_max_cycles});
    try stdout.print("  Mesh port:      {d}\n", .{parsed.mesh_port});

    try stdout.print("\n--- Memory Pool Demo ---\n\n", .{});
    var pool = try memory_pool.BlockPool.init(allocator, 256, 16);
    defer pool.deinit();

    const block_a = try pool.alloc();
    const block_b = try pool.alloc();
    try stdout.print("Allocated two 256-byte blocks from pool.\n", .{});
    try stdout.print("  Block A ptr: {*}\n", .{block_a.ptr});
    try stdout.print("  Block B ptr: {*}\n", .{block_b.ptr});

    @memcpy(block_a[0..5], "hello");
    pool.free(block_a);
    pool.free(block_b);
    try stdout.print("Freed both blocks back to pool.\n", .{});

    pool.reset();
    try stdout.print("Pool reset.\n", .{});

    try stdout.print("\nConfig demo complete.\n", .{});
}
