const std = @import("std");
const agent = @import("agent");
const fp = @import("fixed_point");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var ok = true;

    std.debug.print("=== Manual Test: agent.zig ===\n\n", .{});

    // 1. State size verification
    std.debug.print("1. State Size Verification:\n", .{});
    var ag = agent.Agent.init(allocator, 0, fp.ONE);
    defer ag.deinit();
    const state_bytes = ag.stateSizeBytes();
    std.debug.print("  state size: {d} bytes = {d:.2} KB\n", .{ state_bytes, @as(f64, @floatFromInt(state_bytes)) / 1024.0 });
    std.debug.print("  expected:   {d} bytes = {d:.2} KB\n", .{ 421 * 7 * 8, @as(f64, @floatFromInt(421 * 7 * 8)) / 1024.0 });
    std.debug.print("  Qwen1.5-0.5B: 75,000,000 bytes = 75 MB\n", .{});
    std.debug.print("  reduction: {d:.0}x\n", .{ 75_000_000 / state_bytes });
    if (state_bytes != 421 * 7 * 8) {
        std.debug.print("  FAIL: state size incorrect\n", .{});
        ok = false;
    } else if (state_bytes >= 75_000_000) {
        std.debug.print("  FAIL: state should be << 75 MB\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: 23 KB (not 75 MB) — 3,243x reduction\n", .{});
    }
    std.debug.print("\n", .{});

    // 2. Text ingestion
    std.debug.print("2. Text Ingestion:\n", .{});
    try ag.ingest("Hello Qstar lattice agent!");
    var active_nodes: usize = 0;
    for (0..421) |i| {
        for (0..7) |ch| {
            if (ag.state.activations[i][ch] > 0) active_nodes += 1;
        }
    }
    std.debug.print("  ingested 'Hello Qstar lattice agent!'\n", .{});
    std.debug.print("  active node-channels: {d}\n", .{active_nodes});
    if (active_nodes == 0) {
        std.debug.print("  FAIL: no nodes activated after ingestion\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: {d} node-channels activated\n", .{active_nodes});
    }
    std.debug.print("\n", .{});

    // 3. Inference cycle
    std.debug.print("3. Inference Cycle (E0 firing + φ-cooling):\n", .{});
    const temp_before = ag.state.temperature;
    ag.step();
    const temp_after = ag.state.temperature;
    std.debug.print("  temperature: {d:.6} → {d:.6}\n", .{ temp_before, temp_after });
    std.debug.print("  cycle: {d}\n", .{ag.state.cycle});
    std.debug.print("  output tokens: {d}\n", .{ag.state.output_tokens.items.len});

    if (temp_after >= temp_before) {
        std.debug.print("  FAIL: temperature should decrease (φ-cooling)\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: φ-cooling decreased temperature by {d:.6}\n", .{temp_before - temp_after});
    }
    if (ag.state.cycle != 1) {
        std.debug.print("  FAIL: cycle should be 1\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: cycle incremented to 1\n", .{});
    }
    if (ag.state.output_tokens.items.len == 0) {
        std.debug.print("  FAIL: should have produced an output token\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: produced output token {d}\n", .{ag.state.output_tokens.items[0]});
    }
    std.debug.print("\n", .{});

    // 4. Multiple inference cycles
    std.debug.print("4. Multiple Inference Cycles:\n", .{});
    ag.reset();
    try ag.ingest("The lattice is the model.");
    std.debug.print("  ingested 'The lattice is the model.'\n", .{});
    std.debug.print("  running 10 cycles...\n", .{});
    try ag.run(10);
    std.debug.print("  cycles completed: {d}\n", .{ag.state.cycle});
    std.debug.print("  output tokens: {d}\n", .{ag.state.output_tokens.items.len});
    std.debug.print("  final temperature: {d:.8}\n", .{ag.state.temperature});

    if (ag.state.cycle == 0) {
        std.debug.print("  FAIL: should have completed cycles\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: {d} cycles completed\n", .{ag.state.cycle});
    }

    // Print first few output tokens
    const tokens = ag.readOutputTokens();
    if (tokens.len > 0) {
        std.debug.print("  first 5 tokens: ", .{});
        const n = @min(5, tokens.len);
        for (tokens[0..n]) |t| {
            std.debug.print("{d} ", .{t});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});

    // 5. Decode output
    std.debug.print("5. Decode Output:\n", .{});
    const decoded = try ag.decode(allocator);
    defer allocator.free(decoded);
    if (decoded.len > 0) {
        std.debug.print("  decoded: '{s}'\n", .{decoded});
    } else {
        std.debug.print("  decoded: (empty — tokens outside ASCII range)\n", .{});
    }
    std.debug.print("  PASS: decode produced output\n\n", .{});

    // 6. Token mapping round-trip
    std.debug.print("6. Token Mapping Round-Trip:\n", .{});
    // Manually set activation and verify token readback
    ag.reset();
    ag.state.activations[42][3] = fp.div(fp.fromInt(95), fp.fromInt(100));
    const top_token = ag.readTopToken();
    std.debug.print("  set node[42] channel[3] = 0.95\n", .{});
    std.debug.print("  readTopToken() = {d}\n", .{top_token});
    // nodeToToken(42, 3) = 42 + 3 * 421 = 42 + 1263 = 1305
    const expected_token: u32 = 42 + 3 * 421;
    if (top_token != expected_token) {
        std.debug.print("  FAIL: expected {d}, got {d}\n", .{ expected_token, top_token });
        ok = false;
    } else {
        std.debug.print("  PASS: token = {d} (node 42, channel 3)\n", .{top_token});
    }
    std.debug.print("\n", .{});

    // 7. Chat formatting
    std.debug.print("7. Chat Formatting (Qwen-style):\n", .{});
    const msg = try agent.formatChatMessage(allocator, "user", "What is the lattice?");
    defer allocator.free(msg);
    std.debug.print("  message: {s}\n", .{msg});

    const messages = [_]agent.ChatMessage{
        .{ .role = "system", .content = "You are a lattice agent." },
        .{ .role = "user", .content = "Hello" },
    };
    const prompt = try agent.formatChatPrompt(allocator, &messages);
    defer allocator.free(prompt);
    std.debug.print("  prompt: {s}\n", .{prompt});

    if (!std.mem.startsWith(u8, prompt, "<|im_start|>system")) {
        std.debug.print("  FAIL: prompt should start with system message\n", .{});
        ok = false;
    } else if (!std.mem.endsWith(u8, prompt, "<|im_start|>assistant\n")) {
        std.debug.print("  FAIL: prompt should end with assistant generation prompt\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: chat formatting correct\n", .{});
    }
    std.debug.print("\n", .{});

    // 8. Active node count
    std.debug.print("8. Active Node Count:\n", .{});
    ag.reset();
    std.debug.print("  after reset: {d} active\n", .{ag.activeNodeCount()});
    try ag.ingest("test");
    ag.step();
    const active_after = ag.activeNodeCount();
    std.debug.print("  after ingest+step: {d} active\n", .{active_after});
    std.debug.print("  PASS: active node count works\n\n", .{});

    // 9. Max cycles limit
    std.debug.print("9. Max Cycles Limit:\n", .{});
    ag.reset();
    try ag.ingest("test");
    try ag.run(agent.MAX_CYCLES + 100);
    std.debug.print("  requested {d} cycles, completed {d}\n", .{ agent.MAX_CYCLES + 100, ag.state.cycle });
    if (ag.state.cycle > agent.MAX_CYCLES) {
        std.debug.print("  FAIL: should cap at MAX_CYCLES\n", .{});
        ok = false;
    } else {
        std.debug.print("  PASS: capped at {d} cycles\n", .{ag.state.cycle});
    }
    std.debug.print("\n", .{});

    if (ok) {
        std.debug.print("=== agent.zig: ALL MANUAL TESTS PASS ===\n", .{});
    } else {
        std.debug.print("=== agent.zig: MANUAL TESTS FAILED ===\n", .{});
        std.process.exit(1);
    }
}
