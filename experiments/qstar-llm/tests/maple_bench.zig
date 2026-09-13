const std = @import("std");
const maple_client = @import("maple_client");

const BenchPrompt = struct {
    text: []const u8,
    category: []const u8,
};

const default_prompts = [_]BenchPrompt{
    .{ .text = "hello", .category = "greeting" },
    .{ .text = "what is 2+2", .category = "math" },
    .{ .text = "tell me about the weather", .category = "knowledge" },
    .{ .text = "write a short poem about stars", .category = "creative" },
    .{ .text = "explain recursion in simple terms", .category = "reasoning" },
};

const BenchResult = struct {
    prompt: []const u8,
    category: []const u8,
    response: []const u8,
    latency_ms: u64,
    response_len: usize,
    success: bool,
    error_msg: []const u8 = "",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var maple_host: []const u8 = "qstar001.qstar";
    var maple_port: u16 = 80;
    var iterations: u32 = 3;
    var mesh_mode: bool = false;
    var verbose: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            maple_host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            maple_port = std.fmt.parseInt(u16, args[i], 10) catch 80;
        } else if (std.mem.eql(u8, arg, "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = std.fmt.parseInt(u32, args[i], 10) catch 3;
        } else if (std.mem.eql(u8, arg, "--mesh")) {
            mesh_mode = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== Maple Device Benchmark ===\n", .{});
    try stdout.print("Host: {s}:{d}\n", .{ maple_host, maple_port });
    try stdout.print("Iterations per prompt: {d}\n", .{iterations});
    try stdout.print("Mesh mode: {}\n", .{mesh_mode});
    try stdout.print("\n", .{});

    const client = maple_client.MapleClient.init(allocator, maple_host, maple_port);

    // 1. Fetch device status
    try stdout.print("[1] Fetching device status...\n", .{});
    const status_json = client.getStatus() catch |err| {
        try stdout.print("  ERROR: Failed to connect to Maple device at {s}:{d} ({s})\n", .{ maple_host, maple_port, @errorName(err) });
        try stdout.print("  Make sure the device is powered on and reachable.\n", .{});
        return;
    };
    defer allocator.free(status_json);

    if (verbose) {
        try stdout.print("  Status: {s}\n", .{status_json});
    }
    try stdout.print("  OK - Device reachable\n\n", .{});

    // 2. Run on-device benchmark
    try stdout.print("[2] Running on-device benchmark (/api/bench)...\n", .{});
    const bench_json = client.runBench("hello", iterations) catch |err| {
        try stdout.print("  ERROR: Bench endpoint failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(bench_json);
    try stdout.print("  Result: {s}\n\n", .{bench_json});

    // 3. Run prompt suite
    try stdout.print("[3] Running prompt suite ({d} prompts)...\n", .{default_prompts.len});
    var results = std.ArrayList(BenchResult).init(allocator);
    defer {
        for (results.items) |r| {
            allocator.free(r.response);
            if (r.error_msg.len > 0) allocator.free(r.error_msg);
        }
        results.deinit();
    }

    var total_latency: u64 = 0;
    var success_count: u32 = 0;

    for (default_prompts) |prompt| {
        try stdout.print("  [{s}] \"{s}\"... ", .{ prompt.category, prompt.text });

        const start = std.time.milliTimestamp();
        const response = client.generate(prompt.text) catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            const end = std.time.milliTimestamp();
            try results.append(.{
                .prompt = prompt.text,
                .category = prompt.category,
                .response = try allocator.dupe(u8, ""),
                .latency_ms = @intCast(end - start),
                .response_len = 0,
                .success = false,
                .error_msg = err_msg,
            });
            try stdout.print("FAIL ({s})\n", .{@errorName(err)});
            continue;
        };
        const end = std.time.milliTimestamp();
        const latency: u64 = @intCast(end - start);

        try results.append(.{
            .prompt = prompt.text,
            .category = prompt.category,
            .response = response,
            .latency_ms = latency,
            .response_len = response.len,
            .success = true,
        });

        total_latency += latency;
        success_count += 1;

        if (verbose) {
            try stdout.print("OK ({d}ms, {d} bytes)\n", .{ latency, response.len });
            try stdout.print("    Response: {s:.100}\n", .{response});
        } else {
            try stdout.print("OK ({d}ms, {d} bytes)\n", .{ latency, response.len });
        }
    }

    // 4. Summary
    try stdout.print("\n=== Summary ===\n", .{});
    try stdout.print("Prompts: {d}/{d} succeeded\n", .{ success_count, default_prompts.len });
    if (success_count > 0) {
        try stdout.print("Avg latency: {d} ms\n", .{ total_latency / success_count });
        try stdout.print("Total latency: {d} ms\n", .{total_latency});

        var total_bytes: usize = 0;
        for (results.items) |r| {
            if (r.success) total_bytes += r.response_len;
        }
        try stdout.print("Total response bytes: {d}\n", .{total_bytes});
        try stdout.print("Avg response length: {d:.1} bytes\n", .{ @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(success_count)) });
    }

    // 5. Mesh mode
    if (mesh_mode) {
        try stdout.print("\n=== Mesh Mode ===\n", .{});

        try stdout.print("[4] Fetching mesh nodes...\n", .{});
        const nodes_json = client.getMeshNodes() catch |err| {
            try stdout.print("  ERROR: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(nodes_json);
        try stdout.print("  Nodes: {s}\n", .{nodes_json});

        try stdout.print("[5] Fetching mesh topology...\n", .{});
        const topo_json = client.getMeshTopology() catch |err| {
            try stdout.print("  ERROR: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(topo_json);
        try stdout.print("  Topology: {s}\n", .{topo_json});
    }

    // 6. Category breakdown
    try stdout.print("\n=== Category Breakdown ===\n", .{});
    for (results.items) |r| {
        const status: []const u8 = if (r.success) "OK" else "FAIL";
        try stdout.print("  {s: <12} {s: <20} {d: >6} ms  {d: >6} bytes  [{s}]\n", .{
            r.category,
            r.prompt[0..@min(r.prompt.len, 20)],
            r.latency_ms,
            r.response_len,
            status,
        });
    }

    try stdout.print("\nDone.\n", .{});
}

fn printUsage() void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(
        \\Usage: maple_bench [options]
        \\
        \\Options:
        \\  --host <addr>       Maple device hostname or IP (default: qstar001.qstar)
        \\  --port <num>        Maple device port (default: 80)
        \\  --iterations <n>    Bench iterations per prompt (default: 3)
        \\  --mesh              Enable mesh-aware mode (query mesh nodes + topology)
        \\  -v, --verbose       Show full responses
        \\  -h, --help          Show this help
        \\
    , .{}) catch {};
}

test "default prompts are non-empty" {
    for (default_prompts) |p| {
        try std.testing.expect(p.text.len > 0);
        try std.testing.expect(p.category.len > 0);
    }
}
