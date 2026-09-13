//! competitive_train.zig — Competitive training pipeline to beat LLM providers.
//!
//! 5-Phase Training Regimen:
//!   Phase 1: Curriculum Generation — category-balanced, difficulty-graded prompts
//!   Phase 2: Teacher Distillation — OpenAI teacher responses, 3-channel semantic learning
//!   Phase 3: Self-Improvement Loop — on-policy distillation (Qstar vs teacher, judge, learn)
//!   Phase 4: Knowledge Consolidation — route maintenance, fact promotion, KG enrichment
//!   Phase 5: Adversarial Self-Play — generate prompts targeting weak categories
//!
//! Usage: zig build competitive-train -- --num-prompts 200

const std = @import("std");
const agent_mod = @import("agent");
const openai = @import("openai_client");
const env_loader = @import("env_loader");
const training = @import("training");
const bpe = @import("bpe_tokenizer");

const Config = struct {
    num_prompts: usize = 100,
    num_adversarial: usize = 50,
    openai: openai.OpenAIConfig = .{},
    prompt_gen_model: []const u8 = "gpt-4o-mini",
    teacher_model: []const u8 = "gpt-4o-mini",
    judge_model: []const u8 = "gpt-4o-mini",
    corpus_path: []const u8 = "qstar_corpus.txt",
    kg_path: []const u8 = "qstar_kg.bin",
    routes_path: []const u8 = "datasets/dynamic_routes.bin",
    no_corpus: bool = false,
    corpus_limit_mb: usize = 0,
    verbose: bool = true,
    skip_adversarial: bool = false,
};

const BENCH_CATEGORIES = [_][]const u8{
    "naturalness",
    "relevance",
    "engagement",
    "factual_accuracy",
    "originality",
    "personalization",
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
        } else if (std.mem.eql(u8, arg, "--num-adversarial") and i + 1 < std.os.argv.len) {
            i += 1;
            config.num_adversarial = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 50;
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
        } else if (std.mem.eql(u8, arg, "--skip-adversarial")) {
            config.skip_adversarial = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            config.verbose = false;
        }
    }
}

/// Phase 1: Generate category-balanced prompts across all benchmark categories.
fn generateCurriculumPrompts(allocator: std.mem.Allocator, config: Config) ![][]const u8 {
    var all = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (all.items) |p| allocator.free(p);
        all.deinit();
    }

    var oa_cfg = config.openai;
    oa_cfg.model = config.prompt_gen_model;

    // Generate prompts for each benchmark category, cycling through topics
    const prompts_per_category = config.num_prompts / BENCH_CATEGORIES.len;
    const remainder = config.num_prompts % BENCH_CATEGORIES.len;

    for (BENCH_CATEGORIES, 0..) |cat, ci| {
        const count = prompts_per_category + (if (ci < remainder) @as(usize, 1) else @as(usize, 0));
        if (count == 0) continue;

        const topic = TOPIC_CATEGORIES[ci % TOPIC_CATEGORIES.len];
        std.debug.print("  Category: {s} ({s}) -> {d} prompts\n", .{ cat, topic, count });

        const cat_prompts = training.generateCategoryPrompts(allocator, oa_cfg, cat, topic, count) catch |err| {
            std.debug.print("    WARNING: Failed for {s}: {s}\n", .{ cat, @errorName(err) });
            continue;
        };
        defer {
            for (cat_prompts) |p| allocator.free(p);
            allocator.free(cat_prompts);
        }

        for (cat_prompts) |p| {
            try all.append(try allocator.dupe(u8, p));
        }
    }

    return try all.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Qstar Competitive Training Pipeline ===\n\n", .{});
    var config = loadConfig(allocator);
    parseArgs(&config);

    std.debug.print("Prompts: {d}, Adversarial: {d}, PromptGen: {s}, Teacher: {s}\n", .{
        config.num_prompts, config.num_adversarial, config.prompt_gen_model, config.teacher_model,
    });
    std.debug.print("Corpus: {s}, KG: {s}, Routes: {s}\n\n", .{
        config.corpus_path, config.kg_path, config.routes_path,
    });

    if (config.openai.api_key.len == 0) {
        std.debug.print("ERROR: No OpenAI API key. Set OPENAI_API_KEY in .env\n", .{});
        return;
    }

    // === Phase 1: Curriculum Generation ===
    std.debug.print("Phase 1: Generating {d} category-balanced prompts...\n", .{config.num_prompts});
    const prompts = try generateCurriculumPrompts(allocator, config);
    defer {
        for (prompts) |p| allocator.free(p);
        allocator.free(prompts);
    }
    if (prompts.len == 0) {
        std.debug.print("No prompts generated. Check OpenAI API key.\n", .{});
        return;
    }
    std.debug.print("  Got {d} prompts.\n\n", .{prompts.len});

    // === Phase 2: Init Agent ===
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

    // === Phase 3: Self-Improvement Loop (On-Policy Distillation) ===
    std.debug.print("Phase 3: Self-improvement loop ({d} prompts)...\n\n", .{prompts.len});

    var teacher_cfg = config.openai;
    teacher_cfg.model = config.teacher_model;

    var total_sentences: usize = 0;
    var total_triplets: usize = 0;
    var total_routes: usize = 0;
    var qwins: usize = 0;
    var teacher_wins: usize = 0;
    var failures = std.ArrayList(training.FailureRecord).init(allocator);
    defer failures.deinit();

    for (prompts, 0..) |prompt, i| {
        std.debug.print("[{d}/{d}] {s}\n", .{ i + 1, prompts.len, prompt[0..@min(prompt.len, 80)] });

        const result = try training.distillOnPolicy(&agent, prompt, teacher_cfg, allocator);

        total_sentences += result.sentences_learned;
        total_triplets += result.kg_triplets;
        if (result.route_created) total_routes += 1;

        if (result.qstar_won) {
            qwins += 1;
        } else {
            teacher_wins += 1;
            try failures.append(.{
                .prompt = prompt,
                .qstar_score = result.qstar_score,
                .openai_score = result.teacher_score,
                .qstar_response_preview = "",
            });
        }

        std.debug.print("  Learned: {d} sentences, {d} KG triplets, route={s}\n", .{
            result.sentences_learned,
            result.kg_triplets,
            if (result.route_created) "yes" else "no",
        });

        // Checkpoint every 20 prompts
        if ((i + 1) % 20 == 0) {
            std.debug.print("  [Checkpoint] Saving...\n", .{});
            training.saveCorpusToFile(&agent, config.corpus_path) catch {};
            agent.saveKnowledgeGraph(config.kg_path) catch {};
            std.fs.cwd().makePath("datasets") catch {};
            agent.saveDynamicRoutes(config.routes_path) catch {};
        }
    }

    const total_battles = qwins + teacher_wins;
    const win_rate: f64 = if (total_battles > 0)
        @as(f64, @floatFromInt(qwins)) / @as(f64, @floatFromInt(total_battles)) * 100.0
    else
        0.0;

    std.debug.print("\n  Phase 3 Results: Qstar wins={d}, Teacher wins={d}, Win rate={d:.1}%\n\n", .{
        qwins, teacher_wins, win_rate,
    });

    // === Phase 4: Knowledge Consolidation ===
    std.debug.print("Phase 4: Knowledge consolidation...\n", .{});

    // Route maintenance: prune, reinforce, promote to fact registry
    const maint = agent.routeMaintenance();
    std.debug.print("  Routes: pruned={d}, reinforced={d}, promoted to facts={d}\n", .{
        maint.pruned, maint.reinforced, maint.promoted,
    });

    // Save everything
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

    // === Phase 5: Adversarial Self-Play ===
    if (!config.skip_adversarial and failures.items.len > 0) {
        std.debug.print("\nPhase 5: Adversarial self-play ({d} failures to analyze)...\n", .{failures.items.len});

        // Analyze failures
        const analysis = try training.analyzeFailures(failures.items, allocator);
        defer analysis.categories.deinit();

        std.debug.print("  Dominant failure: {s}\n", .{analysis.dominant.label()});
        for (analysis.category_counts, 0..) |count, ci| {
            if (count > 0) {
                const cat: training.FailureCategory = @enumFromInt(ci);
                std.debug.print("    {s}: {d}\n", .{ cat.label(), count });
            }
        }

        // Collect weak categories (any with > 0 failures)
        var weak_cats = std.ArrayList(training.FailureCategory).init(allocator);
        defer weak_cats.deinit();
        for (analysis.category_counts, 0..) |count, ci| {
            if (count > 0) {
                try weak_cats.append(@enumFromInt(ci));
            }
        }

        if (weak_cats.items.len > 0 and config.num_adversarial > 0) {
            std.debug.print("  Generating {d} adversarial prompts targeting weak areas...\n", .{config.num_adversarial});
            const adv_prompts = try training.generateAdversarialPrompts(
                allocator,
                config.openai,
                weak_cats.items,
                config.num_adversarial,
            );
            defer {
                for (adv_prompts) |p| allocator.free(p);
                allocator.free(adv_prompts);
            }

            std.debug.print("  Got {d} adversarial prompts. Training on them...\n\n", .{adv_prompts.len});

            // Train on adversarial prompts using semantic training (teacher distillation)
            var adv_sentences: usize = 0;
            var adv_triplets: usize = 0;
            var adv_routes: usize = 0;

            for (adv_prompts, 0..) |ap, ai| {
                std.debug.print("  [ADV {d}/{d}] {s}\n", .{ ai + 1, adv_prompts.len, ap[0..@min(ap.len, 80)] });

                const result = try training.trainWithOpenAISemantic(&agent, ap, teacher_cfg, allocator);
                adv_sentences += result.sentences_learned;
                adv_triplets += result.kg_triplets_extracted;
                if (result.route_created) adv_routes += 1;

                // Checkpoint every 20 adversarial prompts
                if ((ai + 1) % 20 == 0) {
                    training.saveCorpusToFile(&agent, config.corpus_path) catch {};
                    agent.saveKnowledgeGraph(config.kg_path) catch {};
                    agent.saveDynamicRoutes(config.routes_path) catch {};
                }
            }

            total_sentences += adv_sentences;
            total_triplets += adv_triplets;
            total_routes += adv_routes;

            // Final save after adversarial training
            std.debug.print("\n  Saving after adversarial training...\n", .{});
            training.saveCorpusToFile(&agent, config.corpus_path) catch {};
            agent.saveKnowledgeGraph(config.kg_path) catch {};
            std.fs.cwd().makePath("datasets") catch {};
            agent.saveDynamicRoutes(config.routes_path) catch {};
        }
    } else if (config.skip_adversarial) {
        std.debug.print("\nPhase 5: Skipped (--skip-adversarial)\n", .{});
    } else {
        std.debug.print("\nPhase 5: No failures to analyze — Qstar won all battles!\n", .{});
    }

    // === Summary ===
    std.debug.print("\n=== Competitive Training Complete ===\n", .{});
    std.debug.print("Prompts processed: {d}\n", .{prompts.len});
    std.debug.print("Qstar wins: {d}, Teacher wins: {d}, Win rate: {d:.1}%\n", .{ qwins, teacher_wins, win_rate });
    std.debug.print("Total sentences learned: {d}\n", .{total_sentences});
    std.debug.print("Total KG triplets extracted: {d}\n", .{total_triplets});
    std.debug.print("Total dynamic routes created: {d}\n", .{total_routes});
    std.debug.print("Final corpus size: {d} sentences\n", .{agent.getCorpusSentenceCount()});
    std.debug.print("Final dynamic routes: {d}\n", .{agent.dynamicRouteCount()});

    std.process.exit(0);
}
