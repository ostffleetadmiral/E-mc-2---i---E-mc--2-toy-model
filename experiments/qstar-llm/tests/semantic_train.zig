//! semantic_train.zig — Semantic training pipeline using OpenAI as teacher.
//!
//! Architecture:
//!   1. Generate diverse long-form prompts via OpenAI (gpt-4o-mini)
//!   2. For each prompt, fetch OpenAI teacher response (detailed, 200-500 words)
//!   3. Qstar learns semantically from the teacher response:
//!      a. Corpus ingestion (learnFromText)
//!      b. KG triplet extraction (extractKnowledgeFromText)
//!      c. Dynamic route creation (registerDynamicRoute)
//!   4. Save updated corpus, KG, and dynamic routes to disk
//!
//! Usage: zig build semantic-train -- --num-prompts 100

const std = @import("std");
const agent_mod = @import("agent");
const openai = @import("openai_client");
const env_loader = @import("env_loader");
const training = @import("training");
const bpe = @import("bpe_tokenizer");

const Config = struct {
    num_prompts: usize = 100,
    openai: openai.OpenAIConfig = .{},
    prompt_gen_model: []const u8 = "gpt-4o-mini",
    teacher_model: []const u8 = "gpt-4o-mini",
    corpus_path: []const u8 = "qstar_corpus.txt",
    kg_path: []const u8 = "qstar_kg.bin",
    routes_path: []const u8 = "datasets/dynamic_routes.bin",
    no_corpus: bool = false,
    corpus_limit_mb: usize = 0,
    verbose: bool = true,
};

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

fn loadConfig(allocator: std.mem.Allocator) Config {
    var loader = env_loader.EnvLoader.init(allocator);
    defer loader.deinit();
    loader.loadFile(".env") catch {};
    var config = Config{};
    const page = std.heap.page_allocator;
    if (loader.get("OPENAI_API_KEY")) |k| config.openai.api_key = page.dupe(u8, k) catch "";
    if (loader.get("OPENAI_TRAIN_API_KEY")) |k| config.openai.api_key = page.dupe(u8, k) catch config.openai.api_key;
    if (loader.get("OPENAI_MODEL")) |m| {
        config.openai.model = page.dupe(u8, m) catch "gpt-4o-mini";
        config.teacher_model = page.dupe(u8, m) catch "gpt-4o-mini";
    }
    return config;
}

fn parseArgs(config: *Config) void {
    var i: usize = 1;
    while (i < std.os.argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(std.os.argv[i], 0);
        if (std.mem.eql(u8, arg, "--num-prompts") and i + 1 < std.os.argv.len) {
            i += 1;
            config.num_prompts = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 100;
        } else if (std.mem.eql(u8, arg, "--teacher-model") and i + 1 < std.os.argv.len) {
            i += 1;
            config.teacher_model = std.heap.page_allocator.dupe(u8, std.mem.sliceTo(std.os.argv[i], 0)) catch config.teacher_model;
        } else if (std.mem.eql(u8, arg, "--prompt-model") and i + 1 < std.os.argv.len) {
            i += 1;
            config.prompt_gen_model = std.heap.page_allocator.dupe(u8, std.mem.sliceTo(std.os.argv[i], 0)) catch config.prompt_gen_model;
        } else if (std.mem.eql(u8, arg, "--corpus") and i + 1 < std.os.argv.len) {
            i += 1;
            config.corpus_path = std.heap.page_allocator.dupe(u8, std.mem.sliceTo(std.os.argv[i], 0)) catch config.corpus_path;
        } else if (std.mem.eql(u8, arg, "--no-corpus")) {
            config.no_corpus = true;
        } else if (std.mem.eql(u8, arg, "--corpus-limit-mb") and i + 1 < std.os.argv.len) {
            i += 1;
            config.corpus_limit_mb = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            config.verbose = false;
        }
    }
}

fn generatePrompts(allocator: std.mem.Allocator, config: Config) ![][]const u8 {
    var all = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (all.items) |p| allocator.free(p);
        all.deinit();
    }
    const batch_size: usize = 20;
    var gen: usize = 0;
    var oa_cfg = config.openai;
    oa_cfg.model = config.prompt_gen_model;

    while (gen < config.num_prompts) {
        const n = @min(batch_size, config.num_prompts - gen);
        const topic = TOPIC_CATEGORIES[(gen / batch_size) % TOPIC_CATEGORIES.len];

        var mp = std.ArrayList(u8).init(allocator);
        defer mp.deinit();
        try mp.writer().print("Generate {d} diverse, detailed questions about {s}. ", .{ n, topic });
        try mp.appendSlice("Make them require long-form answers (not one-word). Include factual, reasoning, creative, opinion, and open-ended. One per line, no numbers, no extra text.");

        var resp = openai.simplePrompt(allocator, oa_cfg, "You are a prompt engineering assistant. Generate diverse, thought-provoking questions that require detailed explanations.", mp.items) catch |err| {
            std.debug.print("WARNING: OpenAI prompt generation failed: {s}\n", .{@errorName(err)});
            break;
        };
        defer resp.deinit();
        std.debug.print("  Batch {d} topic={s} {d}B\n", .{ gen / batch_size + 1, topic, resp.text.len });

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Qstar Semantic Training Pipeline ===\n\n", .{});
    var config = loadConfig(allocator);
    parseArgs(&config);

    std.debug.print("Prompts: {d}, PromptGen: OpenAI {s}, Teacher: OpenAI {s}\n", .{
        config.num_prompts, config.prompt_gen_model, config.teacher_model,
    });
    std.debug.print("Corpus: {s}, KG: {s}, Routes: {s}\n\n", .{
        config.corpus_path, config.kg_path, config.routes_path,
    });

    if (config.openai.api_key.len == 0) {
        std.debug.print("ERROR: No OpenAI API key. Set OPENAI_API_KEY in .env\n", .{});
        return;
    }

    // Phase 1: Generate prompts
    std.debug.print("Phase 1: Generating {d} prompts via OpenAI ({s})...\n", .{ config.num_prompts, config.prompt_gen_model });
    const prompts = try generatePrompts(allocator, config);
    defer {
        for (prompts) |p| allocator.free(p);
        allocator.free(prompts);
    }
    if (prompts.len == 0) {
        std.debug.print("No prompts generated. Check OpenAI API key.\n", .{});
        return;
    }
    std.debug.print("  Got {d} prompts.\n\n", .{prompts.len});

    // Phase 2: Init agent
    std.debug.print("Phase 2: Init agent...\n", .{});
    const fp = @import("fixed_point");
    var agent = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer agent.deinit();

    if (!config.no_corpus) {
        if (config.corpus_limit_mb > 0) {
            const file = std.fs.cwd().openFile(config.corpus_path, .{}) catch |err| {
                std.debug.print("WARNING: Could not open corpus: {s}\n", .{@errorName(err)});
                return;
            };
            defer file.close();
            const limit = config.corpus_limit_mb * 1024 * 1024;
            var limited_reader = std.io.limitedReader(file.reader(), limit);
            _ = agent.loadCorpus(limited_reader.reader()) catch |err| {
                std.debug.print("WARNING: Could not load corpus: {s}\n", .{@errorName(err)});
            };
        } else {
            _ = training.loadCorpusFromFile(&agent, config.corpus_path) catch |err| {
                std.debug.print("WARNING: Could not load corpus: {s}\n", .{@errorName(err)});
            };
        }
    }
    if (bpe.Tokenizer.loadQwenTokenizer(allocator, "models/qwen1.5-0.5b-chat")) |tok| {
        agent.attachTokenizer(tok);
        agent.buildBigramModelFromCombined() catch {};
    } else |_| {}
    _ = agent.loadKnowledgeGraph(config.kg_path) catch 0;
    agent.loadDynamicRoutes(config.routes_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("WARNING: Could not load dynamic routes: {s}\n", .{@errorName(err)});
        }
    };
    agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

    std.debug.print("  Corpus: {d} sentences.\n", .{agent.getCorpusSentenceCount()});
    std.debug.print("  Dynamic routes: {d}\n\n", .{agent.dynamicRouteCount()});

    // Phase 3: Semantic training
    std.debug.print("Phase 3: Semantic training ({d} prompts)...\n\n", .{prompts.len});

    var teacher_cfg = config.openai;
    teacher_cfg.model = config.teacher_model;

    var total_sentences: usize = 0;
    var total_triplets: usize = 0;
    var total_routes: usize = 0;

    for (prompts, 0..) |prompt, i| {
        std.debug.print("[{d}/{d}] {s}\n", .{ i + 1, prompts.len, prompt[0..@min(prompt.len, 80)] });

        const result = try training.trainWithOpenAISemantic(&agent, prompt, teacher_cfg, allocator);

        total_sentences += result.sentences_learned;
        total_triplets += result.kg_triplets_extracted;
        if (result.route_created) total_routes += 1;

        std.debug.print("  Teacher: {d}ch | Learned: {d} sentences, {d} KG triplets, route={s}\n", .{
            result.teacher_chars,
            result.sentences_learned,
            result.kg_triplets_extracted,
            if (result.route_created) "yes" else "no",
        });

        // Save corpus every 20 prompts for crash recovery
        if ((i + 1) % 20 == 0) {
            std.debug.print("  [Checkpoint] Saving corpus...\n", .{});
            training.saveCorpusToFile(&agent, config.corpus_path) catch {};
            agent.saveKnowledgeGraph(config.kg_path) catch {};
            std.fs.cwd().makePath("datasets") catch {};
            agent.saveDynamicRoutes(config.routes_path) catch {};
        }
    }

    // Phase 4: Save everything
    std.debug.print("\nPhase 4: Saving trained knowledge...\n", .{});
    std.debug.print("  Saving corpus ({d} sentences)...\n", .{agent.getCorpusSentenceCount()});
    training.saveCorpusToFile(&agent, config.corpus_path) catch |err| {
        std.debug.print("  WARNING: Could not save corpus: {s}\n", .{@errorName(err)});
    };

    std.debug.print("  Saving knowledge graph...\n", .{});
    agent.saveKnowledgeGraph(config.kg_path) catch |err| {
        std.debug.print("  WARNING: Could not save KG: {s}\n", .{@errorName(err)});
    };

    std.debug.print("  Saving {d} dynamic routes...\n", .{agent.dynamicRouteCount()});
    std.fs.cwd().makePath("datasets") catch {};
    agent.saveDynamicRoutes(config.routes_path) catch |err| {
        std.debug.print("  WARNING: Could not save dynamic routes: {s}\n", .{@errorName(err)});
    };

    // Summary
    std.debug.print("\n=== Semantic Training Complete ===\n", .{});
    std.debug.print("Prompts processed: {d}\n", .{prompts.len});
    std.debug.print("Total sentences learned: {d}\n", .{total_sentences});
    std.debug.print("Total KG triplets extracted: {d}\n", .{total_triplets});
    std.debug.print("Total dynamic routes created: {d}\n", .{total_routes});
    std.debug.print("Final corpus size: {d} sentences\n", .{agent.getCorpusSentenceCount()});
    std.debug.print("Final dynamic routes: {d}\n", .{agent.dynamicRouteCount()});

    std.process.exit(0);
}
