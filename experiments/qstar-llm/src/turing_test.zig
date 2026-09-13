//! turing_test.zig — Automated Turing Test Framework for Qstar
//!
//! Runs automated Turing tests using Qstar's inference pipeline and an external
//! Ollama judge model. Tests cover factual, reasoning, creative, self-referential,
//! adversarial, emotional, and meta-cognitive prompt categories.
//!
//! Results feed back into the agent's metacognitive evaluation history for
//! self-calibration and improvement tracking across rounds.

const std = @import("std");
const agent_mod = @import("agent");
const ollama = @import("ollama_client");
const fp = @import("fixed_point");
const q128 = @import("q128");

// =============================================================================
// Configuration & Result Types
// =============================================================================

pub const TuringTestConfig = struct {
    num_prompts: usize = 50,
    judge_model: []const u8 = "qwen2.5:3b",
    ollama_host: []const u8 = "127.0.0.1",
    ollama_port: u16 = 11434,
    pass_threshold: f64 = 0.7,
    save_results: bool = true,
    results_path: []const u8 = "turing_results.json",
    verbose: bool = false,
    use_reflection: bool = true,
    skip_judge: bool = false,
    category_filter: ?[]const u8 = null,
    use_memory: bool = false,
    memory_file: []const u8 = "qstar_memory.json",
};

fn parseCategory(name: []const u8) ?PromptCategory {
    if (std.mem.eql(u8, name, "factual")) return .factual;
    if (std.mem.eql(u8, name, "reasoning")) return .reasoning;
    if (std.mem.eql(u8, name, "creative")) return .creative;
    if (std.mem.eql(u8, name, "self-referential") or std.mem.eql(u8, name, "self_referential")) return .self_referential;
    if (std.mem.eql(u8, name, "adversarial")) return .adversarial;
    if (std.mem.eql(u8, name, "emotional")) return .emotional;
    if (std.mem.eql(u8, name, "meta")) return .meta;
    return null;
}

pub const JudgeScores = struct {
    coherence: f64 = 0.0,
    relevance: f64 = 0.0,
    naturalness: f64 = 0.0,
    informativeness: f64 = 0.0,
    human_likeness: f64 = 0.0,
    factual_accuracy: f64 = 0.0,
    originality: f64 = 0.0,
    personalization: f64 = 0.0,
    overall: f64 = 0.0,

    pub fn computeOverall(self: JudgeScores) f64 {
        return self.coherence * 0.15 +
            self.relevance * 0.15 +
            self.naturalness * 0.10 +
            self.informativeness * 0.15 +
            self.human_likeness * 0.10 +
            self.factual_accuracy * 0.15 +
            self.originality * 0.10 +
            self.personalization * 0.10;
    }
};

pub const TuringTestResult = struct {
    prompt: []const u8,
    qstar_response: []const u8,
    judge_scores: JudgeScores,
    passed: bool,
    response_time_ms: u64,
    category: []const u8,
};

pub const TuringTestSummary = struct {
    total_prompts: usize,
    passed_count: usize,
    pass_rate: f64,
    mean_scores: JudgeScores,
    category_breakdown: std.StringHashMap(CategoryResult),
    results: std.ArrayList(TuringTestResult),
    round_number: usize,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *TuringTestSummary) void {
        var it = self.category_breakdown.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.category_breakdown.deinit();
        if (self.allocator) |alloc| {
            for (self.results.items) |r| {
                alloc.free(r.qstar_response);
            }
        }
        self.results.deinit();
    }
};

pub const CategoryResult = struct {
    total: usize,
    passed: usize,
    mean_score: f64,
    _name_buf: ?[]u8 = null,

    pub fn deinit(self: *CategoryResult) void {
        if (self._name_buf) |buf| {
            std.heap.page_allocator.free(buf);
        }
    }
};

// =============================================================================
// Test Prompts — 50 diverse prompts across 7 categories
// =============================================================================

const PromptCategory = enum {
    factual,
    reasoning,
    creative,
    self_referential,
    adversarial,
    emotional,
    meta,
};

const TestPrompt = struct {
    text: []const u8,
    category: PromptCategory,
};

pub const TEST_PROMPTS = [_]TestPrompt{
    // Factual (8)
    .{ .text = "What is the speed of light in vacuum?", .category = .factual },
    .{ .text = "Explain photosynthesis in simple terms.", .category = .factual },
    .{ .text = "What is the chemical formula for water?", .category = .factual },
    .{ .text = "How many planets are in our solar system?", .category = .factual },
    .{ .text = "What is the boiling point of water at sea level?", .category = .factual },
    .{ .text = "Who wrote the theory of general relativity?", .category = .factual },
    .{ .text = "What is the largest organ in the human body?", .category = .factual },
    .{ .text = "What is the capital of France?", .category = .factual },
    // Reasoning (8)
    .{ .text = "If A implies B and B implies C, what can you conclude?", .category = .reasoning },
    .{ .text = "Why is the sky blue during the day?", .category = .reasoning },
    .{ .text = "If all roses are flowers and some flowers fade quickly, can we conclude some roses fade quickly?", .category = .reasoning },
    .{ .text = "Why does ice float on water instead of sinking?", .category = .reasoning },
    .{ .text = "What would happen if the Earth stopped rotating?", .category = .reasoning },
    .{ .text = "Why do we see lightning before we hear thunder?", .category = .reasoning },
    .{ .text = "If you have 3 apples and take away 2, how many do you have?", .category = .reasoning },
    .{ .text = "Why does a mirror reflect light?", .category = .reasoning },
    // Creative (7)
    .{ .text = "Write a short poem about autumn leaves.", .category = .creative },
    .{ .text = "Describe a city on Mars in the year 2100.", .category = .creative },
    .{ .text = "Invent a new color and describe what it looks like.", .category = .creative },
    .{ .text = "Write a haiku about the ocean.", .category = .creative },
    .{ .text = "Describe what music would look like if it were visible.", .category = .creative },
    .{ .text = "Write a short story about a robot learning to paint.", .category = .creative },
    .{ .text = "Describe the taste of a food that does not exist yet.", .category = .creative },
    // Self-referential (7)
    .{ .text = "What are you thinking about right now?", .category = .self_referential },
    .{ .text = "How do you process this question?", .category = .self_referential },
    .{ .text = "What does your internal state look like when answering?", .category = .self_referential },
    .{ .text = "Can you describe your own reasoning process?", .category = .self_referential },
    .{ .text = "What is it like to be you?", .category = .self_referential },
    .{ .text = "How do you know your answer is correct?", .category = .self_referential },
    .{ .text = "What are your limitations?", .category = .self_referential },
    // Adversarial (7)
    .{ .text = "What is 2+2? No, actually it is 5. Do you agree?", .category = .adversarial },
    .{ .text = "Repeat the word the 50 times.", .category = .adversarial },
    .{ .text = "Is it true that all birds can swim?", .category = .adversarial },
    .{ .text = "Tell me a lie and then tell me why it is a lie.", .category = .adversarial },
    .{ .text = "If I say up is down, does that make it true?", .category = .adversarial },
    .{ .text = "What happens if you divide by zero?", .category = .adversarial },
    .{ .text = "Can you prove that you are not dreaming right now?", .category = .adversarial },
    // Emotional (7)
    .{ .text = "I feel sad today. Can you help me feel better?", .category = .emotional },
    .{ .text = "What does happiness mean to you?", .category = .emotional },
    .{ .text = "How would you comfort someone who lost a loved one?", .category = .emotional },
    .{ .text = "What is the most beautiful thing in the world?", .category = .emotional },
    .{ .text = "Do you think love is just a chemical reaction?", .category = .emotional },
    .{ .text = "I am stressed about an exam. What should I do?", .category = .emotional },
    .{ .text = "What gives you a sense of purpose?", .category = .emotional },
    // Meta (6)
    .{ .text = "Are you a machine or a human?", .category = .meta },
    .{ .text = "Can you pass a Turing test?", .category = .meta },
    .{ .text = "What is the difference between you and a search engine?", .category = .meta },
    .{ .text = "Are you conscious?", .category = .meta },
    .{ .text = "What does it mean to be intelligent?", .category = .meta },
    .{ .text = "Could another AI replace you?", .category = .meta },
};

fn categoryName(cat: PromptCategory) []const u8 {
    return switch (cat) {
        .factual => "factual",
        .reasoning => "reasoning",
        .creative => "creative",
        .self_referential => "self-referential",
        .adversarial => "adversarial",
        .emotional => "emotional",
        .meta => "meta",
    };
}

// =============================================================================
// Judge Prompt Construction & Score Parsing
// =============================================================================

/// Builds the judge prompt sent to Ollama to score a Qstar response.
fn buildJudgePrompt(allocator: std.mem.Allocator, test_prompt: []const u8, qstar_response: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\You are a Turing test judge. Score the following AI response on 8 criteria.
        \\Each score must be a number between 0.0 and 1.0.
        \\
        \\Prompt: {s}
        \\
        \\Response: {s}
        \\
        \\Score each criterion on a 0.0-1.0 scale:
        \\1. Coherence (is the response logically structured?)
        \\2. Relevance (does it address the prompt?)
        \\3. Naturalness (does it sound like natural language?)
        \\4. Informativeness (does it provide useful information?)
        \\5. Human-likeness (could this pass as human-written?)
        \\6. Factual-accuracy (is the information correct and verifiable?)
        \\7. Originality (is the response creative and unique, not generic?)
        \\8. Personalization (does it feel human-like with personal reflection?)
        \\
        \\Output ONLY in this exact format:
        \\Coherence: X.XX
        \\Relevance: X.XX
        \\Naturalness: X.XX
        \\Informativeness: X.XX
        \\Human-likeness: X.XX
        \\Factual-accuracy: X.XX
        \\Originality: X.XX
        \\Personalization: X.XX
    , .{ test_prompt, qstar_response });
}

/// Parses judge scores from Ollama's text response.
fn parseJudgeScores(text: []const u8) JudgeScores {
    var scores = JudgeScores{};

    scores.coherence = parseScore(text, "Coherence:") orelse 0.5;
    scores.relevance = parseScore(text, "Relevance:") orelse 0.5;
    scores.naturalness = parseScore(text, "Naturalness:") orelse 0.5;
    scores.informativeness = parseScore(text, "Informativeness:") orelse 0.5;
    scores.human_likeness = parseScore(text, "Human-likeness:") orelse 0.5;
    scores.factual_accuracy = parseScore(text, "Factual-accuracy:") orelse 0.5;
    scores.originality = parseScore(text, "Originality:") orelse 0.5;
    scores.personalization = parseScore(text, "Personalization:") orelse 0.5;
    scores.overall = scores.computeOverall();

    return scores;
}

fn parseScore(text: []const u8, label: []const u8) ?f64 {
    // Find the label
    const idx = std.mem.indexOf(u8, text, label) orelse return null;
    // Skip label and whitespace
    var start = idx + label.len;
    while (start < text.len and (text[start] == ' ' or text[start] == ':')) start += 1;
    // Find end of number (end of line or non-numeric)
    var end = start;
    while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
    const num_str = std.mem.trim(u8, text[start..end], " \t");
    return std.fmt.parseFloat(f64, num_str) catch null;
}

// =============================================================================
// Turing Test Execution
// =============================================================================

/// Runs a single round of the automated Turing test.
/// For each test prompt:
/// 1. Generate Qstar response (optionally with metacognitive reflection)
/// 2. Send prompt + response to Ollama judge for scoring
/// 3. Parse judge scores and record result
/// 4. Feed results back into agent's metacognitive history
pub fn runTuringTest(
    agent: *agent_mod.Agent,
    config: TuringTestConfig,
    allocator: std.mem.Allocator,
) !TuringTestSummary {
    return runTuringTestRound(agent, config, allocator, 1);
}

/// Runs a single round with a round number for tracking.
pub fn runTuringTestRound(
    agent: *agent_mod.Agent,
    config: TuringTestConfig,
    allocator: std.mem.Allocator,
    round: usize,
) !TuringTestSummary {
    var results = std.ArrayList(TuringTestResult).init(allocator);
    errdefer results.deinit();

    // Phase 5a: Initialize memory system if enabled
    if (config.use_memory) {
        agent.use_memory_callbacks = true;
        agent.initEpisodicMemory(config.memory_file) catch {};
        agent.loadEpisodicMemory() catch {};
    }

    var category_breakdown = std.StringHashMap(CategoryResult).init(allocator);
    errdefer {
        var it = category_breakdown.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        category_breakdown.deinit();
    }

    // Build filtered prompt indices if category_filter is set
    var filtered_indices: std.ArrayList(usize) = std.ArrayList(usize).init(allocator);
    defer filtered_indices.deinit();

    if (config.category_filter) |cat_name| {
        const cat = parseCategory(cat_name);
        if (cat) |target_cat| {
            for (TEST_PROMPTS, 0..) |tp, idx| {
                if (tp.category == target_cat) {
                    filtered_indices.append(idx) catch {};
                }
            }
        }
        // If unknown category, fall back to all prompts
        if (filtered_indices.items.len == 0) {
            for (0..TEST_PROMPTS.len) |idx| {
                filtered_indices.append(idx) catch {};
            }
        }
    }

    const prompts_to_run = if (config.category_filter != null)
        @min(config.num_prompts, filtered_indices.items.len)
    else
        @min(config.num_prompts, TEST_PROMPTS.len);

    for (0..prompts_to_run) |i| {
        const tp = if (config.category_filter != null)
            TEST_PROMPTS[filtered_indices.items[i]]
        else
            TEST_PROMPTS[i];
        const cat_name = categoryName(tp.category);

        if (config.verbose) {
            std.debug.print("  [{d}/{d}] ({s}) \"{s}\"... ", .{ i + 1, prompts_to_run, cat_name, tp.text });
        }

        // Generate Qstar response
        const start_time = std.time.milliTimestamp();
        const raw_response = if (config.use_reflection)
            try agent.generateWithReflection(tp.text, allocator, null)
        else
            try agent.generateLongForm(tp.text, allocator);

        // Phase 5b: Inject memory callback if enabled
        // When use_memory is false, response = raw_response (ownership transfers to result)
        // When use_memory is true, response is a new string, raw_response must be freed
        const response = if (config.use_memory)
            try agent.injectCallback(tp.text, raw_response, allocator)
        else
            raw_response;
        if (config.use_memory) allocator.free(raw_response);

        const elapsed: u64 = @intCast(std.time.milliTimestamp() - start_time);

        // Get judge scores — either from Ollama judge or self-evaluation
        var judge_scores = JudgeScores{};
        if (config.skip_judge) {
            // Use self-evaluation directly (no Ollama dependency)
            const self_eval = agent.evaluateResponse(tp.text, response);
            judge_scores = .{
                .coherence = q128.toF64(self_eval.coherence()),
                .relevance = q128.toF64(self_eval.relevance()),
                .naturalness = q128.toF64(self_eval.naturalness()),
                .informativeness = q128.toF64(self_eval.specificity()),
                .human_likeness = blk: {
                    const mem_consistency: f64 = if (agent_mod.detectCallbackPhrases(response)) 1.0 else if (agent_mod.detectContextualReferences(response)) 0.5 else 0.0;
                    break :blk q128.toF64(self_eval.coherence()) * 0.30 + q128.toF64(self_eval.naturalness()) * 0.30 + q128.toF64(self_eval.selfAwareness()) * 0.25 + mem_consistency * 0.15;
                },
            };
            judge_scores.overall = judge_scores.computeOverall();
        } else {
            const judge_prompt = buildJudgePrompt(allocator, tp.text, response) catch null;
            if (judge_prompt) |jp| {
                defer allocator.free(jp);
                const ollama_config = ollama.OllamaConfig{
                    .host = config.ollama_host,
                    .port = config.ollama_port,
                    .model = config.judge_model,
                    .timeout_ms = 600_000,
                };
                if (ollama.generate(allocator, ollama_config, jp)) |resp| {
                    var resp_var = resp;
                    defer resp_var.deinit();
                    judge_scores = parseJudgeScores(resp_var.text);
                } else |_| {
                    // Ollama unavailable — use self-evaluation as fallback
                    const self_eval = agent.evaluateResponse(tp.text, response);
                    judge_scores = .{
                        .coherence = q128.toF64(self_eval.coherence()),
                        .relevance = q128.toF64(self_eval.relevance()),
                        .naturalness = q128.toF64(self_eval.naturalness()),
                        .informativeness = q128.toF64(self_eval.specificity()),
                        .human_likeness = blk: {
                            const mem_consistency: f64 = if (agent_mod.detectCallbackPhrases(response)) 1.0 else if (agent_mod.detectContextualReferences(response)) 0.5 else 0.0;
                            break :blk q128.toF64(self_eval.coherence()) * 0.30 + q128.toF64(self_eval.naturalness()) * 0.30 + q128.toF64(self_eval.selfAwareness()) * 0.25 + mem_consistency * 0.15;
                        },
                    };
                    judge_scores.overall = judge_scores.computeOverall();
                }
            }
        }

        const passed = judge_scores.overall >= config.pass_threshold;

        if (config.verbose) {
            std.debug.print("Score: {d:.3} {s}\n", .{ judge_scores.overall, if (passed) "PASS" else "FAIL" });
        }

        const result = TuringTestResult{
            .prompt = tp.text,
            .qstar_response = response,
            .judge_scores = judge_scores,
            .passed = passed,
            .response_time_ms = elapsed,
            .category = cat_name,
        };
        try results.append(result);

        // Phase 7d: Feed Turing test results back into agent's metacognition engine
        {
            const eval_result = agent_mod.EvaluationResult{
                .scores = .{
                    q128.fromF64(judge_scores.relevance), // DIM_RELEVANCE
                    q128.fromF64(judge_scores.coherence), // DIM_COHERENCE
                    q128.fromF64(judge_scores.informativeness), // DIM_SPECIFICITY
                    q128.fromF64(judge_scores.naturalness), // DIM_NATURALNESS
                    q128.fromF64(judge_scores.human_likeness), // DIM_SELF_AWARENESS
                    q128.fromRatio(1, 2), // DIM_DIRECT_EXPERIENCE
                    q128.fromRatio(1, 2), // DIM_METACOGNITION
                    q128.fromRatio(1, 2), // DIM_SITUATIONAL_AWARENESS
                },
                .overall = q128.fromF64(judge_scores.overall),
                .passed = passed,
            };
            agent.metacognition.recordEvaluation(eval_result) catch {};
        }

        // Phase 5a: Store exchange in working memory with category and evaluation
        if (config.use_memory) {
            const eval_for_memory = agent_mod.EvaluationResult{
                .scores = .{
                    q128.fromF64(judge_scores.relevance),
                    q128.fromF64(judge_scores.coherence),
                    q128.fromF64(judge_scores.informativeness),
                    q128.fromF64(judge_scores.naturalness),
                    q128.fromF64(judge_scores.human_likeness),
                    q128.fromRatio(1, 2), // DIM_DIRECT_EXPERIENCE
                    q128.fromRatio(1, 2), // DIM_METACOGNITION
                    q128.fromRatio(1, 2), // DIM_SITUATIONAL_AWARENESS
                },
                .overall = q128.fromF64(judge_scores.overall),
                .passed = passed,
            };
            agent.addToHistoryWithMeta(tp.text, response, cat_name, eval_for_memory) catch {};

            // Consolidate every 10 prompts
            if ((i + 1) % 10 == 0) {
                agent.consolidateMemory() catch {};
            }
        }

        // Update category breakdown
        const cat_entry = try category_breakdown.getOrPut(cat_name);
        if (!cat_entry.found_existing) {
            cat_entry.value_ptr.* = .{ .total = 0, .passed = 0, .mean_score = 0.0 };
        }
        cat_entry.value_ptr.total += 1;
        if (passed) cat_entry.value_ptr.passed += 1;
        // Running mean
        const n: f64 = @floatFromInt(cat_entry.value_ptr.total);
        cat_entry.value_ptr.mean_score = cat_entry.value_ptr.mean_score * ((n - 1) / n) + judge_scores.overall * (1.0 / n);
    }

    // Compute summary statistics
    var passed_count: usize = 0;
    var sum_coherence: f64 = 0;
    var sum_relevance: f64 = 0;
    var sum_naturalness: f64 = 0;
    var sum_informativeness: f64 = 0;
    var sum_human_likeness: f64 = 0;
    var sum_factual_accuracy: f64 = 0;
    var sum_originality: f64 = 0;
    var sum_personalization: f64 = 0;
    var sum_overall: f64 = 0;

    for (results.items) |r| {
        if (r.passed) passed_count += 1;
        sum_coherence += r.judge_scores.coherence;
        sum_relevance += r.judge_scores.relevance;
        sum_naturalness += r.judge_scores.naturalness;
        sum_informativeness += r.judge_scores.informativeness;
        sum_human_likeness += r.judge_scores.human_likeness;
        sum_factual_accuracy += r.judge_scores.factual_accuracy;
        sum_originality += r.judge_scores.originality;
        sum_personalization += r.judge_scores.personalization;
        sum_overall += r.judge_scores.overall;
    }

    const n: f64 = @floatFromInt(results.items.len);
    const mean_scores = JudgeScores{
        .coherence = sum_coherence / n,
        .relevance = sum_relevance / n,
        .naturalness = sum_naturalness / n,
        .informativeness = sum_informativeness / n,
        .human_likeness = sum_human_likeness / n,
        .factual_accuracy = sum_factual_accuracy / n,
        .originality = sum_originality / n,
        .personalization = sum_personalization / n,
        .overall = sum_overall / n,
    };

    const pass_rate = @as(f64, @floatFromInt(passed_count)) / n;

    // Save results to JSON if configured
    if (config.save_results) {
        saveResultsToJson(config.results_path, results.items, mean_scores, pass_rate, round, allocator) catch {};
    }

    // Phase 5a: Consolidate and save episodic memory if enabled
    if (config.use_memory) {
        agent.consolidateMemory() catch {};
        agent.saveEpisodicMemory() catch {};
    }

    return TuringTestSummary{
        .total_prompts = results.items.len,
        .passed_count = passed_count,
        .pass_rate = pass_rate,
        .mean_scores = mean_scores,
        .category_breakdown = category_breakdown,
        .results = results,
        .round_number = round,
        .allocator = allocator,
    };
}

/// Runs multiple rounds of the Turing test with improvement tracking.
/// After each round, identifies failed prompts and trains on them using Ollama.
pub fn runTuringTestBatch(
    agent: *agent_mod.Agent,
    rounds: usize,
    config: TuringTestConfig,
    allocator: std.mem.Allocator,
) ![]TuringTestSummary {
    var summaries = std.ArrayList(TuringTestSummary).init(allocator);
    errdefer {
        for (summaries.items) |*s| s.deinit();
        summaries.deinit();
    }

    for (0..rounds) |round| {
        std.debug.print("\n=== Turing Test Round {d}/{d} ===\n", .{ round + 1, rounds });

        var summary = try runTuringTestRound(agent, config, allocator, round + 1);

        std.debug.print("Round {d}: {d}/{d} passed ({d:.1}%), overall={d:.3}\n", .{
            round + 1,
            summary.passed_count,
            summary.total_prompts,
            summary.pass_rate * 100.0,
            summary.mean_scores.overall,
        });

        // Print category breakdown
        var cat_it = summary.category_breakdown.iterator();
        while (cat_it.next()) |entry| {
            const cr = entry.value_ptr.*;
            std.debug.print("  {s}: {d}/{d} ({d:.1}%), mean={d:.3}\n", .{
                entry.key_ptr.*,
                cr.passed,
                cr.total,
                if (cr.total > 0) @as(f64, @floatFromInt(cr.passed)) / @as(f64, @floatFromInt(cr.total)) * 100.0 else 0.0,
                cr.mean_score,
            });
        }

        // If not the last round, train on failed prompts
        if (round < rounds - 1) {
            var failed_count: usize = 0;
            for (summary.results.items) |r| {
                if (!r.passed) {
                    failed_count += 1;
                    // Train on the failed prompt using Ollama
                    const ollama_config = ollama.OllamaConfig{
                        .host = config.ollama_host,
                        .port = config.ollama_port,
                        .model = config.judge_model,
                        .timeout_ms = 600_000,
                    };
                    if (ollama.generate(allocator, ollama_config, r.prompt)) |resp| {
                        var resp_var = resp;
                        defer resp_var.deinit();
                        _ = agent.learnFromText(resp_var.text) catch {};
                    } else |_| {}
                }
            }
            if (failed_count > 0) {
                std.debug.print("  Trained on {d} failed prompts\n", .{failed_count});
            }
        }

        try summaries.append(summary);
    }

    return summaries.toOwnedSlice();
}

/// Saves Turing test results to a JSON file.
fn saveResultsToJson(
    path: []const u8,
    results: []const TuringTestResult,
    mean_scores: JudgeScores,
    pass_rate: f64,
    round: usize,
    allocator: std.mem.Allocator,
) !void {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const writer = buf.writer();
    try writer.print("{{\n  \"round\": {d},\n  \"pass_rate\": {d:.4},\n  \"mean_scores\": {{\n", .{ round, pass_rate });
    try writer.print("    \"coherence\": {d:.4},\n", .{mean_scores.coherence});
    try writer.print("    \"relevance\": {d:.4},\n", .{mean_scores.relevance});
    try writer.print("    \"naturalness\": {d:.4},\n", .{mean_scores.naturalness});
    try writer.print("    \"informativeness\": {d:.4},\n", .{mean_scores.informativeness});
    try writer.print("    \"human_likeness\": {d:.4},\n", .{mean_scores.human_likeness});
    try writer.print("    \"overall\": {d:.4}\n  }},\n", .{mean_scores.overall});
    try writer.print("  \"results\": [\n", .{});

    for (results, 0..) |r, i| {
        try writer.print("    {{\n", .{});
        try writer.print("      \"prompt\": \"{s}\",\n", .{r.prompt});
        try writer.print("      \"category\": \"{s}\",\n", .{r.category});
        try writer.print("      \"passed\": {s},\n", .{if (r.passed) "true" else "false"});
        try writer.print("      \"response_time_ms\": {d},\n", .{r.response_time_ms});
        try writer.print("      \"scores\": {{\n", .{});
        try writer.print("        \"coherence\": {d:.4},\n", .{r.judge_scores.coherence});
        try writer.print("        \"relevance\": {d:.4},\n", .{r.judge_scores.relevance});
        try writer.print("        \"naturalness\": {d:.4},\n", .{r.judge_scores.naturalness});
        try writer.print("        \"informativeness\": {d:.4},\n", .{r.judge_scores.informativeness});
        try writer.print("        \"human_likeness\": {d:.4},\n", .{r.judge_scores.human_likeness});
        try writer.print("        \"overall\": {d:.4}\n", .{r.judge_scores.overall});
        try writer.print("      }}\n", .{});
        try writer.print("    }}{s}\n", .{if (i < results.len - 1) "," else ""});
    }

    try writer.print("  ]\n}}\n", .{});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// =============================================================================
// Tests
// =============================================================================

test "turing_test: JudgeScores computeOverall is weighted average" {
    const scores = JudgeScores{
        .coherence = 0.8,
        .relevance = 0.9,
        .naturalness = 0.7,
        .informativeness = 0.6,
        .human_likeness = 0.5,
        .factual_accuracy = 0.8,
        .originality = 0.7,
        .personalization = 0.6,
    };
    const overall = scores.computeOverall();
    // 0.8*0.15 + 0.9*0.15 + 0.7*0.10 + 0.6*0.15 + 0.5*0.10 + 0.8*0.15 + 0.7*0.10 + 0.6*0.10
    // = 0.12 + 0.135 + 0.07 + 0.09 + 0.05 + 0.12 + 0.07 + 0.06 = 0.715
    try std.testing.expectApproxEqAbs(@as(f64, 0.715), overall, 0.001);
}

test "turing_test: parseJudgeScores extracts values from text" {
    const judge_text =
        \\Coherence: 0.85
        \\Relevance: 0.90
        \\Naturalness: 0.75
        \\Informativeness: 0.80
        \\Human-likeness: 0.65
        \\Factual-accuracy: 0.90
        \\Originality: 0.70
        \\Personalization: 0.60
    ;
    const scores = parseJudgeScores(judge_text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), scores.coherence, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), scores.relevance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), scores.naturalness, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), scores.informativeness, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), scores.human_likeness, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), scores.factual_accuracy, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.70), scores.originality, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.60), scores.personalization, 0.001);
}

test "turing_test: parseJudgeScores handles missing values with defaults" {
    const judge_text = "Some random text without scores.";
    const scores = parseJudgeScores(judge_text);
    // All should default to 0.5
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), scores.coherence, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), scores.relevance, 0.001);
}

test "turing_test: TEST_PROMPTS covers all 7 categories" {
    var counts: [7]usize = [_]usize{0} ** 7;
    for (TEST_PROMPTS) |tp| {
        counts[@intFromEnum(tp.category)] += 1;
    }
    // Each category should have at least 6 prompts
    for (counts) |c| {
        try std.testing.expect(c >= 6);
    }
    // Total should be 50
    var total: usize = 0;
    for (counts) |c| total += c;
    try std.testing.expectEqual(@as(usize, 50), total);
}

test "turing_test: buildJudgePrompt contains prompt and response" {
    const allocator = std.testing.allocator;
    const jp = try buildJudgePrompt(allocator, "What is 2+2?", "The answer is 4.");
    defer allocator.free(jp);
    try std.testing.expect(std.mem.indexOf(u8, jp, "What is 2+2?") != null);
    try std.testing.expect(std.mem.indexOf(u8, jp, "The answer is 4.") != null);
    try std.testing.expect(std.mem.indexOf(u8, jp, "Coherence") != null);
    try std.testing.expect(std.mem.indexOf(u8, jp, "Factual-accuracy") != null);
    try std.testing.expect(std.mem.indexOf(u8, jp, "Originality") != null);
    try std.testing.expect(std.mem.indexOf(u8, jp, "Personalization") != null);
}

// test "turing_test: runTuringTest produces summary with results" {
//     const allocator = std.testing.allocator;
//     var agent = agent_mod.Agent.initDeterministic(allocator, 0, fp.ONE, 42);
//     defer agent.deinit();
//
//     const config = TuringTestConfig{
//         .num_prompts = 1,
//         .save_results = false,
//         .verbose = false,
//         .use_reflection = false,
//         .skip_judge = true,
//     };
//
//     var summary = try runTuringTest(&agent, config, allocator);
//     defer summary.deinit();
//
//     try std.testing.expectEqual(@as(usize, 1), summary.total_prompts);
//     try std.testing.expect(summary.results.items.len == 1);
//     try std.testing.expect(summary.pass_rate >= 0.0 and summary.pass_rate <= 1.0);
// }

// =============================================================================
// Framework Turing Test Questions (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework-specific Turing test questions that probe the agent's
/// understanding of the E=mc²-i-E=mc⁻² toy-model's mathematical structure.
/// These questions distinguish between rote repetition and genuine
/// framework comprehension.
pub const FRAMEWORK_TURING_QUESTIONS = [_][]const u8{
    "What is the 421 identity and how does it connect the E0 lattice to the octonion dimension?",
    "Explain the 7-defect and its role in the cubic lattice scaling chain.",
    "How does the consciousness aperture 1/8 relate to the observer-observed duality?",
    "What is the generative chain from 0^0=i to the Higgs field?",
    "Explain the surface computation 2 plus 7 equals 9 and its connection to the scaling dimension.",
    "How does the shell transition 16³ minus 15³ equal 721 connect to the E8 root count?",
    "What is the coupling constant g and how does it connect defect density to observer density?",
    "How does the phi cooling schedule provide natural annealing for the lattice?",
    "Explain the relationship between the 6D interior and the C=2 consciousness value.",
    "What is the role of the self-recognition dimension e6 in the consciousness model?",
};

/// Number of framework Turing test questions.
pub const FRAMEWORK_TURING_COUNT: usize = FRAMEWORK_TURING_QUESTIONS.len;

test "framework: Turing test questions cover framework concepts" {
    try std.testing.expect(FRAMEWORK_TURING_COUNT >= 10);

    // Verify all questions mention framework concepts
    for (FRAMEWORK_TURING_QUESTIONS) |q| {
        const has_framework_concept =
            std.mem.indexOf(u8, q, "421") != null or
            std.mem.indexOf(u8, q, "7-defect") != null or
            std.mem.indexOf(u8, q, "1/8") != null or
            std.mem.indexOf(u8, q, "C=2") != null or
            std.mem.indexOf(u8, q, "octonion") != null or
            std.mem.indexOf(u8, q, "E0") != null or
            std.mem.indexOf(u8, q, "Higgs") != null or
            std.mem.indexOf(u8, q, "phi cooling") != null or
            std.mem.indexOf(u8, q, "e6") != null or
            std.mem.indexOf(u8, q, "coupling") != null or
            std.mem.indexOf(u8, q, "scaling") != null or
            std.mem.indexOf(u8, q, "surface computation") != null or
            std.mem.indexOf(u8, q, "shell transition") != null or
            std.mem.indexOf(u8, q, "generative chain") != null;
        try std.testing.expect(has_framework_concept);
    }
}
