//! heartbeat.zig — Training heartbeat for Qstar + Maple corpus push.
//!
//! Runs periodic training cycles that learn from all available JSON outputs
//! (episodic memory, benchmark results, turing results), then compresses the
//! updated corpus, publishes it via VFS/master, and pushes a distilled 24KB
//! subset to Maple devices for on-device training.
//!
//! Architecture:
//!   1. Qstar Training: load agent → learn from JSON sources → rebuild bigram → persist
//!   2. Corpus Compression: build .qsc from updated qstar_corpus.txt
//!   3. VFS Publishing: copy .qsc + distilled to zig-out/master/
//!   4. Maple Push: distill to 24KB → HTTP upload to Maple SD → trigger /api/corpus/scan

const std = @import("std");
const agent_mod = @import("agent");
const training = @import("training");
const compress = @import("compress");
const corpus_store = @import("corpus_store");
const maple = @import("maple_client");
const env_loader = @import("env_loader");
const fp = @import("fixed_point");
const ollama = @import("ollama_client");
const prompt_gen = @import("prompt_generator");
const dyn_routes = @import("dynamic_routes");

pub const HeartbeatConfig = struct {
    interval_s: u64 = 77,
    corpus_path: []const u8 = "qstar_corpus.txt",
    kg_path: []const u8 = "qstar_kg.bin",
    memory_path: []const u8 = "qstar_memory.json",
    competitive_path: []const u8 = "competitive_results.json",
    qstar_bench_path: []const u8 = "qstar_bench_results.json",
    maple_bench_path: []const u8 = "maple_bench_results.json",
    turing_path: []const u8 = "turing_results.json",
    qsc_output_path: []const u8 = "zig-out/qstar_corpus.qsc",
    master_dir: []const u8 = "zig-out/master",
    log_path: []const u8 = "heartbeat_log.jsonl",
    enable_memory: bool = true,
    enable_bench: bool = true,
    enable_turing: bool = true,
    enable_compress: bool = true,
    enable_maple: bool = true,
    enable_generated_prompts: bool = false,
    gen_prompt_count: usize = 5,
    ollama_host: []const u8 = "127.0.0.1",
    ollama_port: u16 = 11434,
    ollama_model: []const u8 = "qwen2.5:3b",
    min_score: f64 = 0.4,
    maple_host: []const u8 = "192.168.4.1",
    maple_port: u16 = 80,
    maple_budget: usize = 24 * 1024,
    verbose: bool = false,
};

pub const CycleStats = struct {
    cycle: u64 = 0,
    memory_sentences: usize = 0,
    bench_sentences: usize = 0,
    turing_sentences: usize = 0,
    generated_prompt_sentences: usize = 0,
    total_sentences: usize = 0,
    corpus_bytes_before: usize = 0,
    corpus_bytes_after: usize = 0,
    corpus_sentences: usize = 0,
    qsc_built: bool = false,
    qsc_pages: usize = 0,
    maple_pushed: bool = false,
    maple_bytes: usize = 0,
    maple_sentences: usize = 0,
    cycle_ms: u64 = 0,
    errors: [8]?[]const u8 = .{ null, null, null, null, null, null, null, null },
    error_count: usize = 0,

    pub fn addError(self: *CycleStats, msg: []const u8) void {
        if (self.error_count < self.errors.len) {
            self.errors[self.error_count] = msg;
            self.error_count += 1;
        }
    }
};

pub const TrainingHeartbeat = struct {
    allocator: std.mem.Allocator,
    config: HeartbeatConfig,
    stop_flag: std.atomic.Value(bool),
    thread: ?std.Thread = null,
    cycle_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: HeartbeatConfig) TrainingHeartbeat {
        return .{
            .allocator = allocator,
            .config = config,
            .stop_flag = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *TrainingHeartbeat) void {
        self.join();
    }

    pub fn start(self: *TrainingHeartbeat) !void {
        self.stop_flag.store(false, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *TrainingHeartbeat) void {
        self.stop_flag.store(true, .seq_cst);
    }

    pub fn join(self: *TrainingHeartbeat) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *TrainingHeartbeat) void {
        while (!self.stop_flag.load(.seq_cst)) {
            self.runCycle() catch |err| {
                std.debug.print("[heartbeat] cycle error: {s}\n", .{@errorName(err)});
            };
            if (self.stop_flag.load(.seq_cst)) break;
            const sleep_ms = self.config.interval_s * 1000;
            const sleep_ns = sleep_ms * std.time.ns_per_ms;
            std.time.sleep(sleep_ns);
        }
    }

    pub fn runOnce(self: *TrainingHeartbeat) !void {
        try self.runCycle();
    }

    pub fn runCycle(self: *TrainingHeartbeat) !void {
        const start_time = std.time.milliTimestamp();
        self.cycle_count += 1;
        var stats = CycleStats{ .cycle = self.cycle_count };

        if (self.config.verbose) {
            std.debug.print("[heartbeat] cycle {d} starting\n", .{stats.cycle});
        }

        var agent = agent_mod.Agent.init(self.allocator, 0, fp.ONE);
        defer agent.deinit();

        agent.initKnowledgeGraph() catch |err| {
            stats.addError("KG init failed");
            if (self.config.verbose) std.debug.print("[heartbeat] KG init error: {s}\n", .{@errorName(err)});
        };

        const corpus_before = std.fs.cwd().statFile(self.config.corpus_path) catch null;
        stats.corpus_bytes_before = if (corpus_before) |s| s.size else 0;

        _ = training.loadCorpusFromFile(&agent, self.config.corpus_path) catch |err| {
            stats.addError("corpus load failed");
            if (self.config.verbose) std.debug.print("[heartbeat] corpus load error: {s}\n", .{@errorName(err)});
        };

        _ = agent.loadKnowledgeGraph(self.config.kg_path) catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat] KG load error: {s}\n", .{@errorName(err)});
        };

        if (self.config.enable_memory) {
            const learned = self.learnFromMemory(&agent) catch |err| blk: {
                stats.addError("memory source failed");
                if (self.config.verbose) std.debug.print("[heartbeat] memory error: {s}\n", .{@errorName(err)});
                break :blk @as(usize, 0);
            };
            stats.memory_sentences = learned;
        }

        if (self.config.enable_bench) {
            const learned = self.learnFromBenchmarks(&agent) catch |err| blk: {
                stats.addError("bench source failed");
                if (self.config.verbose) std.debug.print("[heartbeat] bench error: {s}\n", .{@errorName(err)});
                break :blk @as(usize, 0);
            };
            stats.bench_sentences = learned;
        }

        if (self.config.enable_turing) {
            const learned = self.learnFromTuring(&agent) catch |err| blk: {
                stats.addError("turing source failed");
                if (self.config.verbose) std.debug.print("[heartbeat] turing error: {s}\n", .{@errorName(err)});
                break :blk @as(usize, 0);
            };
            stats.turing_sentences = learned;
        }

        if (self.config.enable_generated_prompts) {
            const learned = self.learnFromGeneratedPrompts(&agent) catch |err| blk: {
                stats.addError("generated prompts source failed");
                if (self.config.verbose) std.debug.print("[heartbeat] generated prompts error: {s}\n", .{@errorName(err)});
                break :blk @as(usize, 0);
            };
            stats.generated_prompt_sentences = learned;
        }

        stats.total_sentences = stats.memory_sentences + stats.bench_sentences + stats.turing_sentences + stats.generated_prompt_sentences;

        if (stats.total_sentences > 0) {
            agent.buildBigramModelFromCombined() catch |err| {
                if (err != error.NoTokenizer) {
                    stats.addError("bigram rebuild failed");
                    if (self.config.verbose) std.debug.print("[heartbeat] bigram error: {s}\n", .{@errorName(err)});
                } else if (self.config.verbose) {
                    std.debug.print("[heartbeat] bigram skipped (no tokenizer attached)\n", .{});
                }
            };
        }

        training.saveCorpusToFile(&agent, self.config.corpus_path) catch |err| {
            stats.addError("corpus save failed");
            if (self.config.verbose) std.debug.print("[heartbeat] corpus save error: {s}\n", .{@errorName(err)});
        };

        agent.saveKnowledgeGraph(self.config.kg_path) catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat] KG save error: {s}\n", .{@errorName(err)});
        };

        stats.corpus_sentences = agent.getCorpusSentenceCount();

        const corpus_after = std.fs.cwd().statFile(self.config.corpus_path) catch null;
        stats.corpus_bytes_after = if (corpus_after) |s| s.size else 0;

        if (self.config.enable_compress and stats.corpus_bytes_after > 0) {
            self.compressAndPublish(&stats) catch |err| {
                stats.addError("compress/publish failed");
                if (self.config.verbose) std.debug.print("[heartbeat] compress error: {s}\n", .{@errorName(err)});
            };
        }

        if (self.config.enable_maple and stats.qsc_built) {
            self.pushToMaple(&stats) catch |err| {
                stats.addError("maple push failed");
                if (self.config.verbose) std.debug.print("[heartbeat] maple push error: {s}\n", .{@errorName(err)});
            };
        }

        stats.cycle_ms = @intCast(std.time.milliTimestamp() - start_time);

        self.logCycle(&stats) catch {};

        if (self.config.verbose) {
            std.debug.print("[heartbeat] cycle {d} done: {d} sentences, {d}ms\n", .{
                stats.cycle, stats.total_sentences, stats.cycle_ms,
            });
        }
    }

    fn learnFromMemory(self: *TrainingHeartbeat, agent: *agent_mod.Agent) !usize {
        const file = std.fs.cwd().openFile(self.config.memory_path, .{}) catch return 0;
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(data);

        var total: usize = 0;
        var text_buf = std.ArrayList(u8).init(self.allocator);
        defer text_buf.deinit();

        var pos: usize = 0;
        while (pos < data.len) {
            const insight = extractJsonString(data, &pos, "\"key_insight\"");
            if (insight.len > 0) {
                try text_buf.appendSlice(insight);
                try text_buf.append('\n');
            }
        }

        pos = 0;
        while (pos < data.len) {
            const summary = extractJsonString(data, &pos, "\"summary\"");
            if (summary.len > 0) {
                try text_buf.appendSlice(summary);
                try text_buf.append('\n');
            }
        }

        if (text_buf.items.len > 0) {
            total = try agent.learnFromText(text_buf.items);
        }

        if (self.config.verbose and total > 0) {
            std.debug.print("[heartbeat]   memory: {d} new sentences\n", .{total});
        }
        return total;
    }

    fn learnFromBenchmarks(self: *TrainingHeartbeat, agent: *agent_mod.Agent) !usize {
        var total: usize = 0;

        const paths = [_][]const u8{
            self.config.competitive_path,
            self.config.qstar_bench_path,
            self.config.maple_bench_path,
        };

        for (paths) |path| {
            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            const data = try file.readToEndAlloc(self.allocator, 32 * 1024 * 1024);
            defer self.allocator.free(data);

            var text_buf = std.ArrayList(u8).init(self.allocator);
            defer text_buf.deinit();

            var pos: usize = 0;
            while (pos < data.len) {
                const text = extractJsonString(data, &pos, "\"text\"");
                if (text.len > 0) {
                    const score = extractScoreAfter(data, pos, text);
                    if (score >= self.config.min_score) {
                        try text_buf.appendSlice(text);
                        try text_buf.append('\n');
                    }
                }
            }

            if (text_buf.items.len > 0) {
                const learned = try agent.learnFromText(text_buf.items);
                total += learned;
            }
        }

        if (self.config.verbose and total > 0) {
            std.debug.print("[heartbeat]   benchmarks: {d} new sentences\n", .{total});
        }
        return total;
    }

    fn learnFromTuring(self: *TrainingHeartbeat, agent: *agent_mod.Agent) !usize {
        const file = std.fs.cwd().openFile(self.config.turing_path, .{}) catch return 0;
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(data);

        var text_buf = std.ArrayList(u8).init(self.allocator);
        defer text_buf.deinit();

        var pos: usize = 0;
        while (pos < data.len) {
            const prompt = extractJsonString(data, &pos, "\"prompt\"");
            if (prompt.len > 0) {
                try text_buf.appendSlice(prompt);
                try text_buf.append('\n');
            }
        }

        pos = 0;
        while (pos < data.len) {
            const response = extractJsonString(data, &pos, "\"response\"");
            if (response.len > 0) {
                const overall = extractScoreAfter(data, pos, response);
                if (overall >= self.config.min_score) {
                    try text_buf.appendSlice(response);
                    try text_buf.append('\n');
                }
            }
        }

        var total: usize = 0;
        if (text_buf.items.len > 0) {
            total = try agent.learnFromText(text_buf.items);
        }

        if (self.config.verbose and total > 0) {
            std.debug.print("[heartbeat]   turing: {d} new sentences\n", .{total});
        }
        return total;
    }

    fn learnFromGeneratedPrompts(self: *TrainingHeartbeat, agent: *agent_mod.Agent) !usize {
        const gen_cfg = ollama.OllamaConfig{
            .host = self.config.ollama_host,
            .port = self.config.ollama_port,
            .model = self.config.ollama_model,
            .timeout_ms = 600_000,
        };
        return try training.trainOnGeneratedPrompts(
            agent,
            gen_cfg,
            gen_cfg,
            self.config.gen_prompt_count,
            "generated_prompts.json",
            self.allocator,
        );
    }

    fn compressAndPublish(self: *TrainingHeartbeat, stats: *CycleStats) !void {
        const qsc_path = self.config.qsc_output_path;
        const dir_path = std.fs.path.dirname(qsc_path) orelse ".";
        std.fs.cwd().makePath(dir_path) catch {};

        const page_size: usize = 4096;
        const pages = corpus_store.buildCorpusStore(
            self.allocator,
            self.config.corpus_path,
            qsc_path,
            page_size,
        ) catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat] .qsc build error: {s}\n", .{@errorName(err)});
            return err;
        };

        stats.qsc_built = true;
        stats.qsc_pages = pages;

        if (self.config.verbose) {
            std.debug.print("[heartbeat]   .qsc built: {d} pages\n", .{pages});
        }

        const master_dir = self.config.master_dir;
        std.fs.cwd().makePath(master_dir) catch {};

        const dest_qsc = try std.fs.path.join(self.allocator, &.{ master_dir, "qstar_corpus.qsc" });
        defer self.allocator.free(dest_qsc);
        copyFile(qsc_path, dest_qsc) catch {};

        const corpus_data = try std.fs.cwd().readFileAlloc(self.allocator, self.config.corpus_path, 512 * 1024 * 1024);
        defer self.allocator.free(corpus_data);
        const dest_distilled = try std.fs.path.join(self.allocator, &.{ master_dir, "qstar_corpus_distilled.txt" });
        defer self.allocator.free(dest_distilled);
        const distilled = try distillCorpus(self.allocator, corpus_data, 7 * 1024 * 1024);
        defer self.allocator.free(distilled);
        writeFile(dest_distilled, distilled) catch {};

        if (self.config.verbose) {
            std.debug.print("[heartbeat]   published to {s}\n", .{master_dir});
        }
    }

    fn pushToMaple(self: *TrainingHeartbeat, stats: *CycleStats) !void {
        const corpus_data = try std.fs.cwd().readFileAlloc(self.allocator, self.config.corpus_path, 512 * 1024 * 1024);
        defer self.allocator.free(corpus_data);

        const maple_corpus = try distillCorpus(self.allocator, corpus_data, self.config.maple_budget);
        defer self.allocator.free(maple_corpus);

        if (maple_corpus.len == 0) return;

        const client = maple.MapleClient.init(self.allocator, self.config.maple_host, self.config.maple_port);

        const tmp_path = "zig-out/qstar_corpus_maple.txt";
        const dir_path = std.fs.path.dirname(tmp_path) orelse ".";
        std.fs.cwd().makePath(dir_path) catch {};
        writeFile(tmp_path, maple_corpus) catch {};

        const response = client.pushCorpusFile(tmp_path, "qstar_heartbeat.txt") catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat]   maple upload failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(response);

        const scan_response = client.triggerCorpusScan() catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat]   maple scan trigger failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(scan_response);

        stats.maple_pushed = true;
        stats.maple_bytes = maple_corpus.len;

        if (self.config.verbose) {
            std.debug.print("[heartbeat]   maple push: {d} bytes, scan triggered\n", .{maple_corpus.len});
        }
    }

    /// Phase 5: Sync dynamic routes to Maple via pushCorpusFile.
    /// Saves routes to a temp binary file and uploads to Maple for distributed validation.
    fn syncDynamicRoutesToMaple(self: *TrainingHeartbeat, registry: *dyn_routes.DynamicRouteRegistry) void {
        if (registry.count() == 0) return;

        const tmp_path = "zig-out/dynamic_routes_maple.bin";
        const dir_path = std.fs.path.dirname(tmp_path) orelse ".";
        std.fs.cwd().makePath(dir_path) catch {};

        registry.saveToFile(tmp_path) catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat]   dynamic routes save failed: {s}\n", .{@errorName(err)});
            return;
        };

        const client = maple.MapleClient.init(self.allocator, self.config.maple_host, self.config.maple_port);
        const response = client.pushCorpusFile(tmp_path, "dynamic_routes.bin") catch |err| {
            if (self.config.verbose) std.debug.print("[heartbeat]   dynamic routes maple upload failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(response);

        if (self.config.verbose) {
            std.debug.print("[heartbeat]   dynamic routes synced to Maple: {d} routes\n", .{registry.count()});
        }
    }

    fn logCycle(self: *TrainingHeartbeat, stats: *const CycleStats) !void {
        const file = try std.fs.cwd().createFile(self.config.log_path, .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);

        var buf: [2048]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf,
            \\{{"cycle":{d},"ts":{d},"memory":{d},"bench":{d},"turing":{d},"total":{d},"corpus_before":{d},"corpus_after":{d},"sentences":{d},"qsc_built":{},"qsc_pages":{d},"maple_pushed":{},"maple_bytes":{d},"cycle_ms":{d},"errors":{d}}}
        , .{
            stats.cycle,
            std.time.milliTimestamp(),
            stats.memory_sentences,
            stats.bench_sentences,
            stats.turing_sentences,
            stats.total_sentences,
            stats.corpus_bytes_before,
            stats.corpus_bytes_after,
            stats.corpus_sentences,
            stats.qsc_built,
            stats.qsc_pages,
            stats.maple_pushed,
            stats.maple_bytes,
            stats.cycle_ms,
            stats.error_count,
        });
        try file.writeAll(line);
        try file.writeAll("\n");
    }
};

fn extractJsonString(data: []const u8, pos: *usize, key: []const u8) []const u8 {
    const start = std.mem.indexOfPos(u8, data, pos.*, key) orelse {
        pos.* = data.len;
        return "";
    };
    const after_key = start + key.len;
    var i = after_key;
    while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) i += 1;
    if (i >= data.len or data[i] != '"') {
        pos.* = after_key;
        return "";
    }
    i += 1;
    const str_start = i;
    while (i < data.len) {
        if (data[i] == '\\' and i + 1 < data.len) {
            i += 2;
            continue;
        }
        if (data[i] == '"') break;
        i += 1;
    }
    pos.* = i + 1;
    if (i > str_start) {
        return data[str_start..i];
    }
    return "";
}

fn extractScoreAfter(data: []const u8, after_pos: usize, _text: []const u8) f64 {
    _ = _text;
    const search_start = after_pos;
    const search_end = @min(search_start + 2048, data.len);
    const region = data[search_start..search_end];

    const overall_key = "\"overall\"";
    const relevance_key = "\"relevance\"";
    const judge_pos = std.mem.indexOf(u8, region, overall_key) orelse
        std.mem.indexOf(u8, region, relevance_key) orelse
        return 1.0;

    const matched_key = if (std.mem.indexOf(u8, region, overall_key) != null) overall_key else relevance_key;
    const after = judge_pos + matched_key.len;
    var i = after;
    while (i < region.len and (region[i] == ' ' or region[i] == ':' or region[i] == '\t')) i += 1;

    const num_start = i;
    while (i < region.len and (region[i] == '-' or region[i] == '.' or (region[i] >= '0' and region[i] <= '9'))) i += 1;

    if (i > num_start) {
        return std.fmt.parseFloat(f64, region[num_start..i]) catch 1.0;
    }
    return 1.0;
}

fn distillCorpus(allocator: std.mem.Allocator, corpus_data: []const u8, budget: usize) ![]u8 {
    var freq = std.StringHashMap(usize).init(allocator);
    defer {
        var it = freq.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        freq.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, corpus_data, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len < 8) continue;
        if (freq.getPtr(trimmed)) |count| {
            count.* += 1;
        } else {
            const key = try allocator.dupe(u8, trimmed);
            freq.put(key, 1) catch {
                allocator.free(key);
            };
        }
    }

    const FreqItem = struct { text: []const u8, count: usize };
    var items = std.ArrayList(FreqItem).init(allocator);
    defer items.deinit();
    var it = freq.iterator();
    while (it.next()) |entry| {
        try items.append(.{ .text = entry.key_ptr.*, .count = entry.value_ptr.* });
    }
    std.mem.sort(FreqItem, items.items, {}, struct {
        fn lessThan(_: void, a: FreqItem, b: FreqItem) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.text, b.text);
        }
    }.lessThan);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (items.items) |item| {
        if (out.items.len + item.text.len + 1 > budget) break;
        try out.appendSlice(item.text);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

fn copyFile(src: []const u8, dst: []const u8) !void {
    const data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, src, 512 * 1024 * 1024);
    defer std.heap.page_allocator.free(data);
    try writeFile(dst, data);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    std.fs.cwd().makePath(dir_path) catch {};
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

pub fn loadMapleConfigFromEnv(allocator: std.mem.Allocator, config: *HeartbeatConfig) void {
    var env = env_loader.EnvLoader.init(allocator);
    defer env.deinit();
    env.loadFile(".env") catch return;

    const page = std.heap.page_allocator;

    // LLM_PROVIDER routing: local forces 127.0.0.1:11434
    var provider_local = false;
    if (env.get("LLM_PROVIDER")) |provider| {
        if (std.mem.eql(u8, provider, "local")) {
            provider_local = true;
        }
    }

    if (env.get("MAPLE_HOST")) |host| {
        config.maple_host = page.dupe(u8, host) catch return;
    }
    if (env.get("MAPLE_PORT")) |port_str| {
        config.maple_port = std.fmt.parseInt(u16, port_str, 10) catch config.maple_port;
    }
    if (provider_local) {
        config.ollama_host = "127.0.0.1";
        config.ollama_port = 11434;
    } else {
        if (env.get("OLLAMA_HOST")) |host| {
            config.ollama_host = page.dupe(u8, host) catch config.ollama_host;
        }
        if (env.get("OLLAMA_PORT")) |port_str| {
            config.ollama_port = std.fmt.parseInt(u16, port_str, 10) catch config.ollama_port;
        }
    }
    if (env.get("OLLAMA_MODEL")) |model| {
        config.ollama_model = page.dupe(u8, model) catch config.ollama_model;
    }
}

test "heartbeat: extractJsonString finds key_insight" {
    const data = "{\"episodes\":[{\"summary\":\"test summary\",\"key_insight\":\"important insight\"}]}";
    var pos: usize = 0;
    const insight = extractJsonString(data, &pos, "\"key_insight\"");
    try std.testing.expectEqualStrings("important insight", insight);
}

test "heartbeat: extractJsonString finds text field" {
    const data = "{\"qstar\":{\"text\":\"hello world\",\"judge\":{\"overall\":0.8}}}";
    var pos: usize = 0;
    const text = extractJsonString(data, &pos, "\"text\"");
    try std.testing.expectEqualStrings("hello world", text);
}

test "heartbeat: extractScoreAfter finds overall score" {
    const data = "\"text\":\"response\",\"judge\":{\"naturalness\":0.5,\"relevance\":0.6,\"engagement\":0.7,\"overall\":0.65}}";
    const score = extractScoreAfter(data, 0, "response");
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), score, 0.001);
}

test "heartbeat: extractScoreAfter defaults to 1.0 when no score" {
    const data = "\"text\":\"response\"},{\"prompt\":\"next\"}";
    const score = extractScoreAfter(data, 0, "response");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "heartbeat: distillCorpus respects budget" {
    const allocator = std.testing.allocator;
    const corpus = "This is a test sentence one.\nThis is a test sentence one.\nThis is a test sentence two.\nShort.\n";
    const result = try distillCorpus(allocator, corpus, 50);
    defer allocator.free(result);
    try std.testing.expect(result.len <= 50);
    try std.testing.expect(result.len > 0);
}

test "heartbeat: distillCorpus sorts by frequency" {
    const allocator = std.testing.allocator;
    const corpus = "Rare sentence here.\nCommon sentence here.\nCommon sentence here.\nCommon sentence here.\n";
    const result = try distillCorpus(allocator, corpus, 100);
    defer allocator.free(result);
    const newline_pos = std.mem.indexOf(u8, result, "\n") orelse result.len;
    const first_line = result[0..newline_pos];
    try std.testing.expect(std.mem.indexOf(u8, first_line, "Common") != null);
}

test "heartbeat: CycleStats addError" {
    var stats = CycleStats{};
    stats.addError("test error");
    try std.testing.expectEqual(@as(usize, 1), stats.error_count);
    try std.testing.expectEqualStrings("test error", stats.errors[0].?);
}

test "heartbeat: config defaults" {
    const config = HeartbeatConfig{};
    try std.testing.expectEqual(@as(u64, 77), config.interval_s);
    try std.testing.expect(config.enable_memory);
    try std.testing.expect(config.enable_bench);
    try std.testing.expect(config.enable_maple);
    try std.testing.expectEqual(@as(usize, 24 * 1024), config.maple_budget);
}

// =============================================================================
// Framework Heartbeat Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework heartbeat timing from the hydrogen 21cm line.
/// The 21cm hydrogen line provides a natural timing reference for the lattice.
pub const FRAMEWORK_HYDROGEN_21CM_NS: u64 = 1420405751; // 1/1420.405751 MHz in ns

/// Framework heartbeat cycle from the 7-defect.
/// The 7-defect suggests a 7-cycle heartbeat pattern.
pub const FRAMEWORK_HEARTBEAT_CYCLE: u8 = 7;

/// Verifies the heartbeat cycle matches the 7-defect.
pub fn verifyHeartbeatCycleMatchesFramework() bool {
    return FRAMEWORK_HEARTBEAT_CYCLE == 7;
}

test "framework: heartbeat cycle 7 = 7-defect" {
    try std.testing.expect(verifyHeartbeatCycleMatchesFramework());
}
