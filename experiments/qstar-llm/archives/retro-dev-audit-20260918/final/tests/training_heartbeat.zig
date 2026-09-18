const std = @import("std");
const heartbeat = @import("heartbeat");
const env_loader = @import("env_loader");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = heartbeat.HeartbeatConfig{};
    var run_once = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--once")) {
            run_once = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-memory")) {
            config.enable_memory = false;
        } else if (std.mem.eql(u8, arg, "--no-bench")) {
            config.enable_bench = false;
        } else if (std.mem.eql(u8, arg, "--no-turing")) {
            config.enable_turing = false;
        } else if (std.mem.eql(u8, arg, "--no-maple")) {
            config.enable_maple = false;
        } else if (std.mem.eql(u8, arg, "--no-compress")) {
            config.enable_compress = false;
        } else if (std.mem.eql(u8, arg, "--interval") and i + 1 < args.len) {
            i += 1;
            config.interval_s = std.fmt.parseInt(u64, args[i], 10) catch config.interval_s;
        } else if (std.mem.eql(u8, arg, "--min-score") and i + 1 < args.len) {
            i += 1;
            config.min_score = std.fmt.parseFloat(f64, args[i]) catch config.min_score;
        } else if (std.mem.eql(u8, arg, "--maple-host") and i + 1 < args.len) {
            i += 1;
            config.maple_host = args[i];
        } else if (std.mem.eql(u8, arg, "--maple-port") and i + 1 < args.len) {
            i += 1;
            config.maple_port = std.fmt.parseInt(u16, args[i], 10) catch config.maple_port;
        } else if (std.mem.eql(u8, arg, "--maple-budget") and i + 1 < args.len) {
            i += 1;
            config.maple_budget = std.fmt.parseInt(usize, args[i], 10) catch config.maple_budget;
        } else if (std.mem.eql(u8, arg, "--corpus") and i + 1 < args.len) {
            i += 1;
            config.corpus_path = args[i];
        } else if (std.mem.eql(u8, arg, "--gen-prompts") and i + 1 < args.len) {
            i += 1;
            config.enable_generated_prompts = true;
            config.gen_prompt_count = std.fmt.parseInt(usize, args[i], 10) catch 5;
        } else if (std.mem.eql(u8, arg, "--ollama-host") and i + 1 < args.len) {
            i += 1;
            config.ollama_host = args[i];
        } else if (std.mem.eql(u8, arg, "--ollama-port") and i + 1 < args.len) {
            i += 1;
            config.ollama_port = std.fmt.parseInt(u16, args[i], 10) catch config.ollama_port;
        } else if (std.mem.eql(u8, arg, "--ollama-model") and i + 1 < args.len) {
            i += 1;
            config.ollama_model = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printUsage();
            return;
        }
    }

    heartbeat.loadMapleConfigFromEnv(allocator, &config);

    std.debug.print("[heartbeat] config: interval={d}s once={} memory={} bench={} turing={} compress={} maple={} maple_host={s}:{d} maple_budget={d} gen_prompts={}({d})\n", .{
        config.interval_s,
        run_once,
        config.enable_memory,
        config.enable_bench,
        config.enable_turing,
        config.enable_compress,
        config.enable_maple,
        config.maple_host,
        config.maple_port,
        config.maple_budget,
        config.enable_generated_prompts,
        config.gen_prompt_count,
    });

    var hb = heartbeat.TrainingHeartbeat.init(allocator, config);
    defer hb.deinit();

    if (run_once) {
        try hb.runOnce();
        std.process.exit(0);
    }

    std.debug.print("[heartbeat] starting daemon mode (interval={d}s)\n", .{config.interval_s});
    try hb.start();

    std.debug.print("[heartbeat] running. Press Ctrl+C to stop.\n", .{});
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

fn printUsage() void {
    const usage =
        \\Usage: training-heartbeat [options]
        \\
        \\Options:
        \\  --interval N       Cycle interval in seconds (default: 77)
        \\  --once             Run single cycle and exit (for cron usage)
        \\  --no-memory        Disable episodic memory source
        \\  --no-bench         Disable benchmark results source
        \\  --no-turing        Disable turing results source
        \\  --no-maple         Skip Maple push step
        \\  --no-compress      Skip compression/VFS publish step
        \\  --min-score F      Minimum judge composite score (default: 0.4)
        \\  --maple-host H     Maple device host (default: from .env MAPLE_HOST)
        \\  --maple-port P     Maple device port (default: from .env MAPLE_PORT)
        \\  --maple-budget N   Maple corpus budget in bytes (default: 24576)
        \\  --corpus PATH      Path to corpus file (default: qstar_corpus.txt)
        \\  --gen-prompts N    Enable Ollama-generated prompt training (N prompts per cycle, default: 5)
        \\  --ollama-host H    Ollama host for generated prompts (default: from .env OLLAMA_HOST)
        \\  --ollama-port P    Ollama port for generated prompts (default: from .env OLLAMA_PORT)
        \\  --ollama-model M   Ollama model for generated prompts (default: from .env OLLAMA_MODEL)
        \\  --verbose          Print per-source learning stats
        \\  --help, -h         Show this help message
        \\
    ;
    std.debug.print("{s}", .{usage});
}
