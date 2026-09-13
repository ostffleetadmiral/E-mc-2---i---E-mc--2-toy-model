//! meta_bench.zig — Metacognitive benchmark with Ollama-generated prompts.
//!
//! Architecture:
//!   1. Local Ollama (127.0.0.1:11434) generates diverse random prompts covering every topic
//!   2. Qstar responds via generateWithReflection (full metacognition + trivium + quadrivium)
//!   3. OpenAI (gpt-5) responds as competitor
//!   4. Remote Ollama (192.168.12.211:11434) judges both responses
//!   5. Quality-only scoring (no speed bonus)
//!   6. After benchmark, failed prompts feed into training pipeline

const std = @import("std");
const agent_mod = @import("agent");
const ollama = @import("ollama_client");
const openai = @import("openai_client");
const env_loader = @import("env_loader");
const training = @import("training");
const prompt_gen = @import("prompt_generator");
const bpe = @import("bpe_tokenizer");

// =============================================================================
// Config
// =============================================================================

const MetaBenchConfig = struct {
    num_prompts: usize = 144,
    local_ollama: ollama.OllamaConfig = .{ .host = "127.0.0.1", .port = 11434, .model = "qwen2.5:3b" },
    remote_ollama: ollama.OllamaConfig = .{ .host = "192.168.12.211", .port = 11434, .model = "qwen2.5:3b" },
    openai: openai.OpenAIConfig = .{},
    openai_bench_model: []const u8 = "gpt-5",
    prompt_gen_model: []const u8 = "gpt-4o-mini",
    judge_model: []const u8 = "gpt-4o-mini",
    no_openai: bool = false,
    verbose: bool = true,
    corpus_path: []const u8 = "qstar_corpus.txt",
    no_corpus: bool = false,
    corpus_limit_mb: usize = 0,
    output_file: []const u8 = "bench_meta_results.txt",
    training_output: []const u8 = "bench_meta_training.json",
};

// =============================================================================
// Judge scores
// =============================================================================

const JudgeScores = struct {
    naturalness: f64 = 0.0,
    relevance: f64 = 0.0,
    engagement: f64 = 0.0,
    factual_accuracy: f64 = 0.0,
    originality: f64 = 0.0,
    personalization: f64 = 0.0,

    fn overall(self: JudgeScores) f64 {
        return (self.naturalness + self.relevance + self.engagement +
            self.factual_accuracy + self.originality + self.personalization) / 6.0;
    }
};

// =============================================================================
// Response result
// =============================================================================

const ResponseResult = struct {
    text: []const u8,
    latency_ns: u64 = 0,
    token_count: usize = 0,
    tokens_per_sec: f64 = 0.0,
    judge: ?JudgeScores = null,
    allocator: std.mem.Allocator,

    fn deinit(self: *ResponseResult) void {
        self.allocator.free(self.text);
    }
};

// =============================================================================
// Prompt result
// =============================================================================

const PromptResult = struct {
    prompt: []const u8,
    qstar: ResponseResult,
    openai_resp: ?ResponseResult = null,
    winner: Winner = .tie,
    qstar_score: f64 = 0.0,
    openai_score: f64 = 0.0,
    allocator: std.mem.Allocator,

    fn deinit(self: *PromptResult) void {
        self.qstar.deinit();
        if (self.openai_resp) |*r| r.deinit();
        self.allocator.free(self.prompt);
    }
};

const Winner = enum { qstar, openai, tie };

const TrainingEntry = struct {
    prompt: []const u8,
    best_response: []const u8,
    best_score: f64,
    category: u8 = 0, // 0=factual, 1=creative, 2=opinion, 3=reasoning
};

fn loadConfig(allocator: std.mem.Allocator) MetaBenchConfig {
    var loader = env_loader.EnvLoader.init(allocator);
    defer loader.deinit();
    loader.loadFile(".env") catch {};
    var config = MetaBenchConfig{};
    const page = std.heap.page_allocator;
    if (loader.get("OPENAI_API_KEY")) |k| config.openai.api_key = page.dupe(u8, k) catch "";
    if (loader.get("OPENAI_BENCH_API_KEY")) |k| config.openai.api_key = page.dupe(u8, k) catch config.openai.api_key;
    if (loader.get("OPENAI_MODEL")) |m| config.openai.model = page.dupe(u8, m) catch "gpt-5";
    if (loader.get("OPENAI_BENCH_MODEL")) |m| config.openai_bench_model = page.dupe(u8, m) catch "gpt-5";
    if (loader.get("OLLAMA_MODEL")) |m| {
        config.local_ollama.model = page.dupe(u8, m) catch "qwen2.5:3b";
        config.remote_ollama.model = page.dupe(u8, m) catch "qwen2.5:3b";
    }
    // Remote Ollama for judging and training — uses OLLAMA_HOST
    if (loader.get("OLLAMA_HOST")) |h| config.remote_ollama.host = page.dupe(u8, h) catch "192.168.12.211";
    if (loader.get("OLLAMA_PORT")) |p| config.remote_ollama.port = std.fmt.parseInt(u16, p, 10) catch 11434;
    // JUDGE_MODEL can override the model used for judging
    if (loader.get("JUDGE_MODEL")) |m| config.remote_ollama.model = page.dupe(u8, m) catch config.remote_ollama.model;
    return config;
}

fn parseArgs(config: *MetaBenchConfig) void {
    var i: usize = 1;
    while (i < std.os.argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(std.os.argv[i], 0);
        if (std.mem.eql(u8, arg, "--num-prompts") and i + 1 < std.os.argv.len) {
            i += 1;
            config.num_prompts = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 144;
        } else if (std.mem.eql(u8, arg, "--no-openai")) {
            config.no_openai = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            config.verbose = false;
        } else if (std.mem.eql(u8, arg, "--no-corpus")) {
            config.no_corpus = true;
        } else if (std.mem.eql(u8, arg, "--corpus-limit-mb") and i + 1 < std.os.argv.len) {
            i += 1;
            config.corpus_limit_mb = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < std.os.argv.len) {
            i += 1;
            config.output_file = std.heap.page_allocator.dupe(u8, std.mem.sliceTo(std.os.argv[i], 0)) catch config.output_file;
        }
    }
}

const TOPIC_CATEGORIES = [_][]const u8{
    "science and physics",                          "mathematics and geometry",                       "history and ancient civilizations",
    "philosophy and ethics",                        "technology and computing",                       "biology and genetics",
    "chemistry and materials",                      "astronomy and cosmology",                        "geography and geology",
    "psychology and neuroscience",                  "economics and finance",                          "literature and poetry",
    "music theory and acoustics",                   "art history and design",                         "political science and governance",
    "sociology and culture",                        "environmental science and climate",              "medicine and health",
    "engineering and architecture",                 "linguistics and language",                       "anthropology and archaeology",
    "law and jurisprudence",                        "agriculture and food science",                   "meteorology and weather",
    "oceanography and marine biology",              "quantum mechanics and particle physics",         "thermodynamics and energy",
    "artificial intelligence and machine learning", "cryptography and cybersecurity",                 "robotics and automation",
    "space exploration and rocketry",               "nanotechnology and materials science",           "biotechnology and bioengineering",
    "game theory and decision theory",              "logic and formal reasoning",                     "everyday life and practical advice",
    "creative writing and storytelling",            "hypothetical scenarios and thought experiments", "current events and future trends",
    "interdisciplinary connections between fields",
};

fn generateDiversePrompts(allocator: std.mem.Allocator, config: MetaBenchConfig) ![][]const u8 {
    var all = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (all.items) |p| allocator.free(p);
        all.deinit();
    }
    const bs: usize = 20;
    var gen: usize = 0;
    var oa_cfg = config.openai;
    oa_cfg.model = config.prompt_gen_model;

    while (gen < config.num_prompts) {
        const n = @min(bs, config.num_prompts - gen);
        const topic = TOPIC_CATEGORIES[(gen / bs) % TOPIC_CATEGORIES.len];
        var mp = std.ArrayList(u8).init(allocator);
        defer mp.deinit();
        try mp.writer().print("Generate {d} diverse questions about {s}. ", .{ n, topic });
        try mp.appendSlice("Vary difficulty. Include factual, reasoning, creative, opinion, and open-ended. One per line, no numbers, no extra text.");

        var resp = openai.simplePrompt(allocator, oa_cfg, "You are a prompt engineering assistant. Generate diverse, thought-provoking questions.", mp.items) catch |err| {
            std.debug.print("WARNING: OpenAI prompt generation failed: {s}\n", .{@errorName(err)});
            break;
        };
        defer resp.deinit();
        if (config.verbose) std.debug.print("Batch {d} topic={s} {d}B\n", .{ gen / bs + 1, topic, resp.text.len });
        var lines = std.mem.splitScalar(u8, resp.text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len < 10 or t.len > 500) continue;
            if (std.mem.startsWith(u8, t, "Here") or std.mem.startsWith(u8, t, "Sure") or std.mem.startsWith(u8, t, "I'll")) continue;
            var s: usize = 0;
            while (s < t.len and (std.ascii.isDigit(t[s]) or t[s] == '.' or t[s] == ')')) s += 1;
            const c = std.mem.trim(u8, t[s..], " \t");
            if (c.len < 10) continue;
            try all.append(try allocator.dupe(u8, c));
            gen += 1;
            if (gen >= config.num_prompts) break;
        }
    }
    return try all.toOwnedSlice();
}

fn extractJsonFloat(text: []const u8, field: []const u8) f64 {
    var buf: [128]u8 = undefined;
    if (field.len + 4 > buf.len) return 0.0;
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + field.len], field);
    buf[1 + field.len] = '"';
    const search = buf[0 .. 2 + field.len];
    if (std.mem.indexOf(u8, text, search)) |pos| {
        var i = pos + search.len;
        while (i < text.len and (text[i] == ':' or text[i] == ' ')) i += 1;
        var end = i;
        while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.' or text[end] == '-')) end += 1;
        if (end > i) return std.fmt.parseFloat(f64, text[i..end]) catch 0.0;
    }
    return 0.0;
}

fn parseJudgeJson(text: []const u8) JudgeScores {
    return .{
        .naturalness = extractJsonFloat(text, "naturalness") / 10.0,
        .relevance = extractJsonFloat(text, "relevance") / 10.0,
        .engagement = extractJsonFloat(text, "engagement") / 10.0,
        .factual_accuracy = extractJsonFloat(text, "factual_accuracy") / 10.0,
        .originality = extractJsonFloat(text, "originality") / 10.0,
        .personalization = extractJsonFloat(text, "personalization") / 10.0,
    };
}

fn judgeResponse(allocator: std.mem.Allocator, config: MetaBenchConfig, prompt: []const u8, response: []const u8) ?JudgeScores {
    var jp = std.ArrayList(u8).init(allocator);
    defer jp.deinit();
    jp.appendSlice("Rate this response 1-10. Return ONLY JSON: {\"naturalness\":N,\"relevance\":N,\"engagement\":N,\"factual_accuracy\":N,\"originality\":N,\"personalization\":N}\n\nPrompt: ") catch return null;
    jp.appendSlice(prompt) catch return null;
    jp.appendSlice("\n\nResponse: ") catch return null;
    jp.appendSlice(response) catch return null;

    var judge_cfg = config.openai;
    judge_cfg.model = config.judge_model;
    var resp = openai.simplePrompt(allocator, judge_cfg, "You are a response judge. Rate responses on a 1-10 scale. Return ONLY the JSON object.", jp.items) catch return null;
    defer resp.deinit();
    return parseJudgeJson(resp.text);
}

fn runQstar(allocator: std.mem.Allocator, agent: *agent_mod.Agent, prompt: []const u8) !ResponseResult {
    var timer = try std.time.Timer.start();
    const response = try agent.generateWithReflection(prompt, allocator);
    const elapsed = timer.read();
    const tc = response.len / 4;
    const tps: f64 = if (elapsed > 0) @as(f64, @floatFromInt(tc)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) else 0.0;
    return .{ .text = response, .latency_ns = elapsed, .token_count = tc, .tokens_per_sec = tps, .allocator = allocator };
}

fn runOpenAI(allocator: std.mem.Allocator, config: MetaBenchConfig, prompt: []const u8) !?ResponseResult {
    if (config.no_openai or !openai.isAvailable(config.openai)) return null;
    var oa = config.openai;
    oa.model = config.openai_bench_model;
    var timer = try std.time.Timer.start();
    var resp = openai.simplePrompt(allocator, oa, "You are a helpful assistant. Answer concisely.", prompt) catch return null;
    defer resp.deinit();
    const elapsed = timer.read();
    const tc = resp.text.len / 4;
    const tps: f64 = if (elapsed > 0) @as(f64, @floatFromInt(tc)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) else 0.0;
    return .{ .text = try allocator.dupe(u8, resp.text), .latency_ns = elapsed, .token_count = tc, .tokens_per_sec = tps, .allocator = allocator };
}

fn initAgent(allocator: std.mem.Allocator, config: MetaBenchConfig) !*agent_mod.Agent {
    var agent = try allocator.create(agent_mod.Agent);
    const fp = @import("fixed_point");
    agent.* = agent_mod.Agent.init(allocator, 0, fp.ONE);
    if (!config.no_corpus) {
        if (config.corpus_limit_mb > 0) {
            // Load only first N MB of corpus for faster startup
            const file = std.fs.cwd().openFile(config.corpus_path, .{}) catch |err| {
                std.debug.print("WARNING: Could not open corpus: {s}\n", .{@errorName(err)});
                return agent;
            };
            defer file.close();
            const limit = config.corpus_limit_mb * 1024 * 1024;
            var limited_reader = std.io.limitedReader(file.reader(), limit);
            _ = agent.loadCorpus(limited_reader.reader()) catch |err| {
                std.debug.print("WARNING: Could not load corpus: {s}\n", .{@errorName(err)});
            };
        } else {
            _ = training.loadCorpusFromFile(agent, config.corpus_path) catch |err| {
                std.debug.print("WARNING: Could not load corpus: {s}\n", .{@errorName(err)});
            };
        }
    }
    if (bpe.Tokenizer.loadQwenTokenizer(allocator, "models/qwen1.5-0.5b-chat")) |tok| {
        agent.attachTokenizer(tok);
        agent.buildBigramModelFromCombined() catch {};
    } else |_| {}
    _ = agent.loadKnowledgeGraph("qstar_kg.bin") catch 0;
    agent.loadDynamicRoutes("datasets/dynamic_routes.bin") catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("WARNING: Could not load dynamic routes: {s}\n", .{@errorName(err)});
        }
    };
    if (agent.dynamicRouteCount() > 0) {
        std.debug.print("  Loaded {d} dynamic routes from disk.\n", .{agent.dynamicRouteCount()});
    }
    agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};
    return agent;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Qstar Meta-Benchmark ===\n\n", .{});
    var config = loadConfig(allocator);
    parseArgs(&config);
    std.debug.print("Prompts: {d}, PromptGen: OpenAI {s}, Judge: OpenAI {s}, Competitor: OpenAI {s}\n\n", .{
        config.num_prompts, config.prompt_gen_model, config.judge_model, config.openai_bench_model,
    });

    std.debug.print("Phase 1: Generating prompts via OpenAI ({s})...\n", .{config.prompt_gen_model});
    const prompts = try generateDiversePrompts(allocator, config);
    defer {
        for (prompts) |p| allocator.free(p);
        allocator.free(prompts);
    }
    if (prompts.len == 0) {
        std.debug.print("No prompts generated. Check OpenAI API key.\n", .{});
        return;
    }
    std.debug.print("  Got {d} prompts.\n", .{prompts.len});

    std.debug.print("Phase 2: Init agent...\n", .{});
    var agent = try initAgent(allocator, config);
    defer {
        agent.deinit();
        allocator.destroy(agent);
    }
    std.debug.print("  Corpus: {d} sentences.\n\n", .{agent.getCorpusSentenceCount()});

    std.debug.print("Phase 3: Benchmark ({d} prompts)...\n\n", .{prompts.len});
    var qwins: usize = 0;
    var owins: usize = 0;
    var ties: usize = 0;
    var qsum: f64 = 0.0;
    var osum: f64 = 0.0;
    var failed = std.ArrayList([]const u8).init(allocator);
    defer failed.deinit();
    var training_entries = std.ArrayList(TrainingEntry).init(allocator);
    defer {
        for (training_entries.items) |entry| {
            allocator.free(entry.prompt);
            allocator.free(entry.best_response);
        }
        training_entries.deinit();
    }

    var rf = try std.fs.cwd().createFile(config.output_file, .{});
    defer rf.close();
    var w = rf.writer();
    try w.print("Qstar Meta-Benchmark Results\n===\n\n", .{});

    for (prompts, 0..) |prompt, i| {
        std.debug.print("[{d}/{d}] {s}\n", .{ i + 1, prompts.len, prompt[0..@min(prompt.len, 80)] });

        var qres = runQstar(allocator, agent, prompt) catch |err| {
            std.debug.print("  Qstar ERR: {s}\n", .{@errorName(err)});
            try failed.append(prompt);
            continue;
        };
        qres.judge = judgeResponse(allocator, config, prompt, qres.text);
        const qs = if (qres.judge) |j| j.overall() else 0.0;
        qsum += qs;
        std.debug.print("  Q: {d}ch s={d:.3}\n", .{ qres.text.len, qs });
        std.debug.print("  Q response: {s}\n", .{qres.text[0..@min(qres.text.len, 300)]});

        var os: f64 = 0.0;
        var best_text: []const u8 = qres.text;
        var best_score: f64 = qs;
        var best_is_qstar = true;

        if (!config.no_openai) {
            if (try runOpenAI(allocator, config, prompt)) |oar_val| {
                var oar = oar_val;
                oar.judge = judgeResponse(allocator, config, prompt, oar.text);
                os = if (oar.judge) |j| j.overall() else 0.0;
                osum += os;
                std.debug.print("  O: {d}ch s={d:.3}\n", .{ oar.text.len, os });
                std.debug.print("  O response: {s}\n", .{oar.text[0..@min(oar.text.len, 300)]});
                if (qs > os + 0.01) {
                    qwins += 1;
                    std.debug.print(" => Q\n", .{});
                } else if (os > qs + 0.01) {
                    owins += 1;
                    try failed.append(prompt);
                    // OpenAI won — use its response as best
                    best_text = oar.text;
                    best_score = os;
                    best_is_qstar = false;
                    std.debug.print(" => O\n", .{});
                } else {
                    ties += 1;
                    // Tie — use higher score
                    if (os > qs) {
                        best_text = oar.text;
                        best_score = os;
                        best_is_qstar = false;
                    }
                    std.debug.print(" => T\n", .{});
                }
                // Collect training entry with best response
                const entry_prompt = try allocator.dupe(u8, prompt);
                const entry_response = try allocator.dupe(u8, best_text);
                try w.print("[{d}] {s}\n  Q({d}ch,{d:.3}): {s}\n  O({d:.3})\n\n", .{
                    i + 1, prompt, qres.text.len, qs, qres.text[0..@min(qres.text.len, 200)], os,
                });
                try training_entries.append(.{
                    .prompt = entry_prompt,
                    .best_response = entry_response,
                    .best_score = best_score,
                });
                if (best_is_qstar) {
                    allocator.free(qres.text);
                } else {
                    allocator.free(qres.text);
                    allocator.free(oar.text);
                }
            } else {
                std.debug.print(" | O: N/A\n", .{});
                qwins += 1;
                // No OpenAI — Qstar response is best
                const entry_prompt = try allocator.dupe(u8, prompt);
                const entry_response = try allocator.dupe(u8, qres.text);
                try w.print("[{d}] {s}\n  Q({d}ch,{d:.3}): {s}\n  O({d:.3})\n\n", .{
                    i + 1, prompt, qres.text.len, qs, qres.text[0..@min(qres.text.len, 200)], os,
                });
                try training_entries.append(.{
                    .prompt = entry_prompt,
                    .best_response = entry_response,
                    .best_score = qs,
                });
                allocator.free(qres.text);
            }
        } else {
            std.debug.print("\n", .{});
            // No OpenAI comparison — Qstar response is best
            const entry_prompt = try allocator.dupe(u8, prompt);
            const entry_response = try allocator.dupe(u8, qres.text);
            try w.print("[{d}] {s}\n  Q({d}ch,{d:.3}): {s}\n  O({d:.3})\n\n", .{
                i + 1, prompt, qres.text.len, qs, qres.text[0..@min(qres.text.len, 200)], os,
            });
            try training_entries.append(.{
                .prompt = entry_prompt,
                .best_response = entry_response,
                .best_score = qs,
            });
            allocator.free(qres.text);
        }
    }

    // Results
    std.debug.print("\n=== RESULTS ===\n", .{});
    std.debug.print("Total: {d}, Qstar: {d}, OpenAI: {d}, Ties: {d}\n", .{ prompts.len, qwins, owins, ties });
    const total = qwins + owins + ties;
    if (total > 0) {
        std.debug.print("Qstar win rate: {d:.1}%\n", .{@as(f64, @floatFromInt(qwins)) / @as(f64, @floatFromInt(total)) * 100.0});
    }
    std.debug.print("Qstar avg: {d:.3}, OpenAI avg: {d:.3}\n", .{ qsum / @as(f64, @floatFromInt(prompts.len)), osum / @as(f64, @floatFromInt(prompts.len)) });
    std.debug.print("Failed (training feed): {d}\n", .{failed.items.len});

    try w.print("\n=== SUMMARY ===\n", .{});
    try w.print("Total: {d}, Qstar: {d}, OpenAI: {d}, Ties: {d}\n", .{ prompts.len, qwins, owins, ties });
    try w.print("Qstar avg: {d:.3}, OpenAI avg: {d:.3}\n", .{ qsum / @as(f64, @floatFromInt(prompts.len)), osum / @as(f64, @floatFromInt(prompts.len)) });
    try w.print("Failed: {d}\n", .{failed.items.len});

    // Save training feed (failed prompts for reference)
    if (failed.items.len > 0) {
        std.debug.print("\nPhase 5: Saving {d} failed prompts to {s}...\n", .{ failed.items.len, config.training_output });
        var tf = try std.fs.cwd().createFile(config.training_output, .{});
        defer tf.close();
        var tw = tf.writer();
        try tw.writeAll("[\n");
        for (failed.items, 0..) |p, idx| {
            try tw.writeAll("  {\"prompt\": \"");
            for (p) |c| {
                switch (c) {
                    '"' => try tw.writeAll("\\\""),
                    '\\' => try tw.writeAll("\\\\"),
                    '\n' => try tw.writeAll("\\n"),
                    else => try tw.writeByte(c),
                }
            }
            try tw.writeAll("\"}");
            if (idx + 1 < failed.items.len) try tw.writeAll(",");
            try tw.writeAll("\n");
        }
        try tw.writeAll("]\n");
    }

    // Phase 6: Train on ALL prompts using best available response + create dynamic routes
    if (training_entries.items.len > 0) {
        std.debug.print("\nPhase 6: Training on {d} prompts (best response + route creation)...\n", .{training_entries.items.len});

        // For failed prompts, also fetch OpenAI teacher response for corpus learning
        const train_cfg = training.TrainingConfig{
            .openai = config.openai,
            .teacher = .openai,
            .verbose = config.verbose,
        };

        var learned_total: usize = 0;
        var routes_created: usize = 0;
        for (training_entries.items, 0..) |entry, idx| {
            const category = training.classifyPromptCategory(entry.prompt);
            std.debug.print("  [{d}/{d}] Training on: \"{s}\"... ", .{ idx + 1, training_entries.items.len, entry.prompt[0..@min(entry.prompt.len, 60)] });

            // For failed prompts (Qstar lost), also fetch fresh OpenAI teacher response
            if (entry.best_score < 0.5 and !config.no_openai) {
                const teacher_learned = training.trainOnPrompt(agent, entry.prompt, train_cfg, allocator) catch 0;
                learned_total += teacher_learned;
                std.debug.print("teacher={d} sentences, ", .{teacher_learned});
            }

            // Create dynamic route from best response
            const learned = training.trainAndCreateRoute(agent, entry.prompt, entry.best_response, entry.best_score, allocator) catch 0;
            learned_total += learned;
            routes_created += 1;
            std.debug.print("route={s} conf={d} learned={d}\n", .{ category.label(), training.confidenceForCategory(category), learned });
        }
        std.debug.print("  Learned {d} new sentences total. Created {d} dynamic routes.\n", .{ learned_total, routes_created });

        // Save updated corpus
        std.debug.print("  Saving updated corpus...\n", .{});
        training.saveCorpusToFile(agent, config.corpus_path) catch |err| {
            std.debug.print("  WARNING: Could not save corpus: {s}\n", .{@errorName(err)});
        };
        std.debug.print("  Done. Corpus now: {d} sentences.\n", .{agent.getCorpusSentenceCount()});

        // Save dynamic routes to disk for persistence across runs
        std.debug.print("  Saving {d} dynamic routes to disk...\n", .{agent.dynamicRouteCount()});
        std.fs.cwd().makePath("datasets") catch {};
        agent.saveDynamicRoutes("datasets/dynamic_routes.bin") catch |err| {
            std.debug.print("  WARNING: Could not save dynamic routes: {s}\n", .{@errorName(err)});
        };
        std.debug.print("  Dynamic routes persisted.\n", .{});
    } else {
        std.debug.print("\nNo training entries — no training needed.\n", .{});
    }

    std.debug.print("\n=== Meta-Benchmark Complete ===\n", .{});

    std.process.exit(0);
}
