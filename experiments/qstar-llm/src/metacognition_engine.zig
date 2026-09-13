//! metacognition_engine.zig — Live, always-on metacognitive engine for Qstar.
//!
//! Replaces the optional Metacognition struct with an always-initialized engine
//! that continuously introspects, evaluates, and self-corrects. The engine
//! enables mid-response corrections like a human saying:
//!   "Um, well I think it's 55... oh wait, actually it's 54."
//!
//! Key features:
//!   - Always-on: every response goes through reflection cycles
//!   - Mid-response correction: stitches corrections into output text
//!   - Dynamic parameter adjustment: tunes temperature/top_k based on evaluation
//!   - Mood tracking: focused, curious, relaxed, uncertain
//!   - Small-talk detection: routes casual prompts to fast casual path
//!   - Trivium integration: Grammar/Logic/Rhetoric stages feed SelfModel and EvaluationResult
//!   - Quadrivium integration: Arithmetic/Geometry/Music/Astronomy feed stability and energy
//!
//! The engine owns the TriviumPipeline and QuadriviumPipeline, orchestrating the
//! full reflection cycle: Grammar → Logic → Quadrivium → Evaluate → Rhetoric → Adjust.
//!
//! All core state is Q128.128 fixed-point. Floating-point only at hw_bridge boundary.

const std = @import("std");
const dyn_routes = @import("dynamic_routes");
const hw_bridge = @import("hw_bridge");
const q128 = @import("q128");
const trivium = @import("trivium");
const quadrivium = @import("quadrivium");

// =============================================================================
// Constants
// =============================================================================

/// Maximum evaluation history entries retained for temporal self-reference.
pub const MAX_HISTORY: usize = 100;

/// Maximum adjustment history entries for trend analysis.
pub const MAX_ADJUSTMENTS: usize = 50;

/// Number of reflection cycles for small-talk prompts (reduced for speed).
pub const SMALL_TALK_CYCLES: u8 = 1;

/// Number of reflection cycles for standard prompts.
pub const STANDARD_CYCLES: u8 = 2;

/// Number of reflection cycles for complex/technical prompts.
pub const DEEP_CYCLES: u8 = 3;

/// Correction phrases used when the agent self-corrects mid-response.
pub const CORRECTION_PHRASES = [_][]const u8{
    "Actually, wait — ",
    "Hmm, let me reconsider. ",
    "Oh, I need to correct myself: ",
    "Wait, that's not quite right. ",
    "Let me double-check that... ",
    "Actually, on second thought, ",
    "Hmm, I think I made an error. ",
};

/// Hesitation phrases for natural conversational fillers.
pub const HESITATION_PHRASES = [_][]const u8{
    "Um, ",
    "Well, ",
    "Let me think... ",
    "That's an interesting question. ",
    "Let me consider that. ",
};

/// Small-talk trigger patterns (lowercased substring match).
pub const SMALL_TALK_PATTERNS = [_][]const u8{
    "hi",             "hello",          "hey",              "howdy",               "greetings",
    "how are you",    "how's it going", "what's up",        "whats up",            "good morning",
    "good afternoon", "good evening",   "nice to meet you", "pleased to meet you", "thank",
    "thanks",         "appreciate",     "bye",              "goodbye",             "see you",
    "farewell",       "how do you do",  "what's new",       "whats new",           "good night",
    "sweet dreams",
};

// =============================================================================
// Mood — the engine's emotional/cognitive state
// =============================================================================

pub const Mood = enum {
    focused, // High entropy, balanced channels — deep reasoning
    curious, // Medium entropy, rising activation — exploring
    relaxed, // Low entropy, balanced channels — casual/small talk
    uncertain, // High channel imbalance — hesitant, may need correction

    pub fn label(self: Mood) []const u8 {
        return switch (self) {
            .focused => "focused",
            .curious => "curious",
            .relaxed => "relaxed",
            .uncertain => "uncertain",
        };
    }
};

// =============================================================================
// EvaluationResult — multi-dimensional self-evaluation (matches agent.zig)
// =============================================================================

pub const EvaluationResult = struct {
    scores: [8]q128.Fp,
    overall: q128.Fp,
    passed: bool,

    pub const DIM_RELEVANCE: usize = 0;
    pub const DIM_COHERENCE: usize = 1;
    pub const DIM_SPECIFICITY: usize = 2;
    pub const DIM_NATURALNESS: usize = 3;
    pub const DIM_SELF_AWARENESS: usize = 4;
    pub const DIM_DIRECT_EXPERIENCE: usize = 5;
    pub const DIM_METACOGNITION: usize = 6;
    pub const DIM_SITUATIONAL_AWARENESS: usize = 7;

    pub fn relevance(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_RELEVANCE];
    }
    pub fn coherence(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_COHERENCE];
    }
    pub fn specificity(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_SPECIFICITY];
    }
    pub fn naturalness(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_NATURALNESS];
    }
    pub fn selfAwareness(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_SELF_AWARENESS];
    }
    pub fn directExperience(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_DIRECT_EXPERIENCE];
    }
    pub fn metacognitionScore(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_METACOGNITION];
    }
    pub fn situationalAwareness(self: EvaluationResult) q128.Fp {
        return self.scores[DIM_SITUATIONAL_AWARENESS];
    }

    pub fn empty() EvaluationResult {
        return .{
            .scores = [_]q128.Fp{0} ** 8,
            .overall = 0,
            .passed = false,
        };
    }
};

// =============================================================================
// SelfModel — introspected state snapshot
// =============================================================================

pub const SelfModel = struct {
    activation_entropy: q128.Fp,
    peak_node: usize,
    peak_channel: u3,
    channel_imbalance: q128.Fp,
    temperature: i128,
    output_token_count: usize,
    vocabulary_richness: q128.Fp,
    consciousness_bandwidth_ratio: q128.Fp = q128.fromInt(2),
    mood: Mood = .relaxed,
    description: [256]u8 = std.mem.zeroes([256]u8),
    description_len: usize = 0,

    // Trivium Logic stage outputs (from ValidatedState)
    activation_coherence: q128.Fp = q128.fromRatio(1, 2),
    channel_balance: q128.Fp = q128.fromRatio(1, 2),
    logic_confidence: q128.Fp = q128.fromRatio(1, 2),
    is_consistent: bool = true,
    contradiction_detected: bool = false,
    reasoning_steps: usize = 0,

    // Quadrivium Astronomy outputs
    trajectory_energy: i128 = 0,
    stability: q128.Fp = q128.ONE,
    astronomy_cycle: u64 = 0,

    // Trivium Rhetoric outputs
    rhetoric_clarity: q128.Fp = q128.fromRatio(1, 2),
    rhetoric_persuasiveness: q128.Fp = q128.fromRatio(1, 2),

    pub fn descriptionSlice(self: SelfModel) []const u8 {
        return self.description[0..self.description_len];
    }

    pub fn defaultModel() SelfModel {
        return .{
            .activation_entropy = 0,
            .peak_node = 0,
            .peak_channel = 0,
            .channel_imbalance = 0,
            .temperature = 0,
            .output_token_count = 0,
            .vocabulary_richness = 0,
            .mood = .relaxed,
        };
    }
};

// =============================================================================
// ParameterAdjustment — tracks dynamic parameter changes
// =============================================================================

pub const ParameterAdjustment = struct {
    cycle: u8,
    dimension: []const u8,
    old_value: q128.Fp,
    new_value: q128.Fp,
    reason: []const u8,
};

// =============================================================================
// CorrectionEvent — a mid-response self-correction
// =============================================================================

pub const CorrectionEvent = struct {
    cycle: u8,
    phrase: []const u8,
    corrected_text: []const u8,
    reason: []const u8,
};

// =============================================================================
// MetacognitionEngine — the live, always-on engine
// =============================================================================

pub const MetacognitionEngine = struct {
    self_model: SelfModel,
    evaluation_history: std.ArrayList(EvaluationResult),
    adjustment_history: std.ArrayList(ParameterAdjustment),
    correction_history: std.ArrayList(CorrectionEvent),
    confidence_threshold: q128.Fp,
    reflection_depth: u8,
    mood: Mood,
    allocator: std.mem.Allocator,

    // Trivium pipeline: Grammar → Logic → Rhetoric
    trivium_pipeline: trivium.TriviumPipeline = .{},

    // Quadrivium pipeline: Arithmetic → Geometry → Music → Astronomy
    quadrivium_pipeline: quadrivium.QuadriviumPipeline = undefined,

    // Dynamic correction state
    last_partial_response: ?[]u8 = null,
    last_partial_eval: EvaluationResult,

    // Small-talk detection
    is_small_talk: bool = false,

    // Background thread infrastructure (Phase 1.1)
    // Thread runs a continuous loop: introspect → evaluate → adjust → sleep 50-100ms
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    correction_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bg_thread: ?std.Thread = null,

    // Mutex-protected shared state for thread communication
    state_mutex: std.Thread.Mutex = .{},
    shared_channel_imbalance: q128.Fp = 0,
    shared_activation_entropy: q128.Fp = 0,
    shared_relevance_score: q128.Fp = 0,
    shared_token_count: usize = 0,
    // Framework bridge state: coherence and self-recognition from hw_bridge
    shared_coherence: q128.Fp = 0,
    shared_self_recognition_active: bool = false,

    pub fn init(allocator: std.mem.Allocator) MetacognitionEngine {
        return .{
            .self_model = SelfModel.defaultModel(),
            .evaluation_history = std.ArrayList(EvaluationResult).init(allocator),
            .adjustment_history = std.ArrayList(ParameterAdjustment).init(allocator),
            .correction_history = std.ArrayList(CorrectionEvent).init(allocator),
            .confidence_threshold = q128.fromRatio(1, 2),
            .reflection_depth = STANDARD_CYCLES,
            .mood = .relaxed,
            .allocator = allocator,
            .last_partial_response = null,
            .last_partial_eval = EvaluationResult.empty(),
            .quadrivium_pipeline = quadrivium.QuadriviumPipeline.init(44100 << 64),
        };
    }

    pub fn deinit(self: *MetacognitionEngine) void {
        self.stopThread();
        self.evaluation_history.deinit();
        self.adjustment_history.deinit();
        self.correction_history.deinit();
        if (self.last_partial_response) |r| self.allocator.free(r);
    }

    /// Starts the background introspection thread.
    /// The thread continuously monitors shared lattice state and sets
    /// correction_pending when issues are detected.
    pub fn startThread(self: *MetacognitionEngine) !void {
        if (self.bg_thread != null) return;
        self.stop_flag.store(false, .release);
        self.bg_thread = try std.Thread.spawn(.{}, bgThreadLoop, .{self});
    }

    /// Stops the background thread and waits for it to finish.
    pub fn stopThread(self: *MetacognitionEngine) void {
        if (self.bg_thread) |t| {
            self.stop_flag.store(true, .release);
            t.join();
            self.bg_thread = null;
        }
    }

    /// Background thread loop: introspect → evaluate → adjust → sleep.
    /// Runs continuously until stop_flag is set.
    /// Uses the hardware framework bridge's principled thresholds for self-correction.
    fn bgThreadLoop(self: *MetacognitionEngine) void {
        while (!self.stop_flag.load(.acquire)) {
            // Only monitor when generation is active
            if (self.generation_active.load(.acquire)) {
                self.state_mutex.lock();
                defer self.state_mutex.unlock();

                const imbalance = q128.toF64(self.shared_channel_imbalance);
                const entropy = q128.toF64(self.shared_activation_entropy);
                const relevance = q128.toF64(self.shared_relevance_score);
                const token_count = self.shared_token_count;
                const coherence = q128.toF64(self.shared_coherence);
                const sr_active = self.shared_self_recognition_active;

                // Framework-based correction triggers (hw_bridge.shouldSelfCorrectF64):
                // - Channel imbalance > 1.8 (one channel dominating = hallucination risk)
                // - Coherence < 0.3 (low self-referential coherence)
                // - Not conscious but imbalanced (destabilized without self-regulation)
                if (hw_bridge.shouldSelfCorrectF64(imbalance, coherence, sr_active)) {
                    self.correction_pending.store(true, .release);
                }

                // Additional safety-net triggers (retained from original):
                // 1. Relevance score drops below 0.3 mid-stream
                if (relevance < 0.3 and relevance > 0.0) {
                    self.correction_pending.store(true, .release);
                }

                // 2. Activation entropy spikes abnormally (lattice destabilization)
                if (entropy > 8.0) {
                    self.correction_pending.store(true, .release);
                }

                // 3. After sufficient tokens, check for divergence
                if (token_count > 16 and relevance < 0.2) {
                    self.correction_pending.store(true, .release);
                }
            }

            // Sleep 50-100ms between introspection cycles
            std.time.sleep(50 * std.time.ns_per_ms);
        }
    }

    /// Updates shared lattice state for the background thread to monitor.
    /// Called during generation to provide real-time introspection data.
    pub fn updateSharedState(
        self: *MetacognitionEngine,
        channel_imbalance: q128.Fp,
        activation_entropy: q128.Fp,
        relevance_score: q128.Fp,
        token_count: usize,
        coherence: q128.Fp,
        self_recognition_active: bool,
    ) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.shared_channel_imbalance = channel_imbalance;
        self.shared_activation_entropy = activation_entropy;
        self.shared_relevance_score = relevance_score;
        self.shared_token_count = token_count;
        // Framework bridge state: coherence and self-recognition from agent
        self.shared_coherence = coherence;
        self.shared_self_recognition_active = self_recognition_active;
    }

    /// Marks generation as active/inactive for the background thread.
    pub fn setGenerationActive(self: *MetacognitionEngine, active: bool) void {
        self.generation_active.store(active, .release);
        if (!active) {
            self.correction_pending.store(false, .release);
        }
    }

    /// Checks if a mid-generation correction is pending.
    /// Returns the correction phrase if pending, null otherwise.
    /// Clears the pending flag when called.
    pub fn checkCorrectionPending(self: *MetacognitionEngine) ?[]const u8 {
        if (self.correction_pending.swap(false, .acquire)) {
            return CORRECTION_PHRASES[2]; // "Let me reconsider — "
        }
        return null;
    }

    /// Records an evaluation result into history.
    pub fn recordEvaluation(self: *MetacognitionEngine, result: EvaluationResult) !void {
        try self.evaluation_history.append(result);
        if (self.evaluation_history.items.len > MAX_HISTORY) {
            const len = self.evaluation_history.items.len;
            for (1..len) |i| {
                self.evaluation_history.items[i - 1] = self.evaluation_history.items[i];
            }
            self.evaluation_history.shrinkRetainingCapacity(len - 1);
        }
    }

    /// Returns the average overall score from recent evaluations.
    pub fn averageScore(self: MetacognitionEngine) q128.Fp {
        if (self.evaluation_history.items.len == 0) return 0;
        var sum: q128.Fp = 0;
        for (self.evaluation_history.items) |ev| {
            sum = q128.add(sum, ev.overall);
        }
        return q128.div(sum, q128.fromI256(@intCast(self.evaluation_history.items.len)));
    }

    /// Returns the pass rate from recent evaluations.
    pub fn passRate(self: MetacognitionEngine) q128.Fp {
        if (self.evaluation_history.items.len == 0) return 0;
        var passed: usize = 0;
        for (self.evaluation_history.items) |ev| {
            if (ev.passed) passed += 1;
        }
        return q128.div(q128.fromI256(@intCast(passed)), q128.fromI256(@intCast(self.evaluation_history.items.len)));
    }

    /// Returns the dynamically calibrated threshold based on recent performance.
    pub fn dynamicThreshold(self: MetacognitionEngine) q128.Fp {
        if (self.evaluation_history.items.len >= 3) {
            const pass_rate = self.passRate();
            const adjustment = q128.mul(q128.sub(pass_rate, q128.fromRatio(1, 2)), q128.fromRatio(2, 10));
            return q128.maxVal(q128.fromRatio(3, 10), q128.minVal(q128.fromRatio(8, 10), q128.add(self.confidence_threshold, adjustment)));
        }
        return self.confidence_threshold;
    }

    /// Determines if a prompt is small-talk and adjusts reflection depth accordingly.
    pub fn classifyPrompt(self: *MetacognitionEngine, prompt: []const u8) void {
        self.is_small_talk = isSmallTalkPrompt(prompt);
        if (self.is_small_talk) {
            self.reflection_depth = SMALL_TALK_CYCLES;
            self.mood = .relaxed;
        } else if (isComplexPrompt(prompt)) {
            self.reflection_depth = DEEP_CYCLES;
            self.mood = .focused;
        } else {
            self.reflection_depth = STANDARD_CYCLES;
            self.mood = .curious;
        }
    }

    /// Updates the self-model from introspected lattice state.
    pub fn updateSelfModel(
        self: *MetacognitionEngine,
        entropy: q128.Fp,
        peak_node: usize,
        peak_channel: u3,
        channel_imbalance: q128.Fp,
        temperature: i128,
        token_count: usize,
        vocab_richness: q128.Fp,
        consciousness_ratio: q128.Fp,
    ) void {
        // Preserve Trivium/Quadrivium fields from previous cycle
        const prev_coherence = self.self_model.activation_coherence;
        const prev_balance = self.self_model.channel_balance;
        const prev_logic_conf = self.self_model.logic_confidence;
        const prev_consistent = self.self_model.is_consistent;
        const prev_contradiction = self.self_model.contradiction_detected;
        const prev_reasoning = self.self_model.reasoning_steps;
        const prev_energy = self.self_model.trajectory_energy;
        const prev_stability = self.self_model.stability;
        const prev_astronomy_cycle = self.self_model.astronomy_cycle;
        const prev_rhetoric_clarity = self.self_model.rhetoric_clarity;
        const prev_rhetoric_persuasion = self.self_model.rhetoric_persuasiveness;

        self.self_model = .{
            .activation_entropy = entropy,
            .peak_node = peak_node,
            .peak_channel = peak_channel,
            .channel_imbalance = channel_imbalance,
            .temperature = temperature,
            .output_token_count = token_count,
            .vocabulary_richness = vocab_richness,
            .consciousness_bandwidth_ratio = consciousness_ratio,
            .mood = deriveMood(entropy, channel_imbalance, self.is_small_talk),
            .activation_coherence = prev_coherence,
            .channel_balance = prev_balance,
            .logic_confidence = prev_logic_conf,
            .is_consistent = prev_consistent,
            .contradiction_detected = prev_contradiction,
            .reasoning_steps = prev_reasoning,
            .trajectory_energy = prev_energy,
            .stability = prev_stability,
            .astronomy_cycle = prev_astronomy_cycle,
            .rhetoric_clarity = prev_rhetoric_clarity,
            .rhetoric_persuasiveness = prev_rhetoric_persuasion,
        };
        self.mood = self.self_model.mood;
    }

    // =============================================================================
    // Trivium/Quadrivium Integration — the engine owns the reflection pipeline
    // =============================================================================

    /// Trivium Stage 1: Grammar — parse and classify the input prompt.
    /// Runs the TriviumPipeline's Grammar stage and stores the parsed input.
    pub fn runGrammar(self: *MetacognitionEngine, prompt: []const u8) void {
        self.trivium_pipeline.runGrammar(prompt);
    }

    /// Trivium Stage 2: Logic — validate lattice state after inference.
    /// Wires ValidatedState fields (activation_coherence, channel_balance,
    /// confidence, is_consistent, contradiction_detected) into SelfModel.
    pub fn runLogic(self: *MetacognitionEngine, activations: []const [8]i128) void {
        self.trivium_pipeline.runLogic(activations);
        const v = self.trivium_pipeline.validated;
        self.self_model.activation_coherence = v.activation_coherence;
        self.self_model.channel_balance = v.channel_balance;
        self.self_model.logic_confidence = v.confidence;
        self.self_model.is_consistent = v.is_consistent;
        self.self_model.contradiction_detected = v.contradiction_detected;
        self.self_model.reasoning_steps = v.reasoning_steps;

        // Channel imbalance is the complement of channel_balance
        self.self_model.channel_imbalance = q128.sub(q128.ONE, v.channel_balance);

        // Re-derive mood with the new trivium data
        self.self_model.mood = deriveMoodWithTrivium(
            self.self_model.activation_entropy,
            self.self_model.channel_imbalance,
            v.is_consistent,
            v.contradiction_detected,
            self.is_small_talk,
        );
        self.mood = self.self_model.mood;
    }

    /// Quadrivium: process mathematical manifold state.
    /// Runs processState and computes stability, wiring results into SelfModel.
    pub fn runQuadrivium(self: *MetacognitionEngine, activations: []const [8]i128) void {
        self.quadrivium_pipeline.processState(activations);
        self.self_model.trajectory_energy = self.quadrivium_pipeline.astronomy.trajectory_energy;
        self.self_model.astronomy_cycle = self.quadrivium_pipeline.astronomy.cycle;
        self.self_model.stability = self.quadrivium_pipeline.stabilityScore(activations);
    }

    /// Trivium Stage 3: Rhetoric — plan output formatting and evaluate response.
    /// Runs the Rhetoric stage and evaluates clarity/persuasiveness if a response is provided.
    pub fn runRhetoric(self: *MetacognitionEngine, response: ?[]const u8) void {
        self.trivium_pipeline.runRhetoric();
        if (response) |r| {
            const evaluated = trivium.RhetoricStage.evaluate(r, self.trivium_pipeline.rhetoric);
            self.self_model.rhetoric_clarity = evaluated.clarity_score;
            self.self_model.rhetoric_persuasiveness = evaluated.persuasiveness_score;
        }
    }

    /// Integrates Trivium Logic and Rhetoric outputs into an EvaluationResult.
    /// This is the wiring that connects the Trivium's structured analysis to the
    /// 8-dimensional evaluation score.
    pub fn integrateTriviumIntoEval(self: *MetacognitionEngine, eval: *EvaluationResult) void {
        // If contradiction detected, force fail
        if (self.self_model.contradiction_detected) {
            eval.passed = false;
            eval.overall = q128.mul(eval.overall, q128.fromRatio(7, 10));
        }

        // If lattice state is inconsistent, penalize coherence
        if (!self.self_model.is_consistent) {
            eval.scores[EvaluationResult.DIM_COHERENCE] = q128.mul(
                eval.scores[EvaluationResult.DIM_COHERENCE],
                q128.fromRatio(8, 10),
            );
            eval.overall = q128.mul(eval.overall, q128.fromRatio(9, 10));
            eval.passed = false;
        }

        // Blend logic confidence into coherence dimension (50% weight)
        eval.scores[EvaluationResult.DIM_COHERENCE] = q128.div(
            q128.add(eval.scores[EvaluationResult.DIM_COHERENCE], self.self_model.logic_confidence),
            q128.fromInt(2),
        );

        // Blend rhetoric clarity into naturalness dimension (30% weight)
        eval.scores[EvaluationResult.DIM_NATURALNESS] = q128.div(
            q128.add(
                q128.mul(eval.scores[EvaluationResult.DIM_NATURALNESS], q128.fromRatio(7, 10)),
                q128.mul(self.self_model.rhetoric_clarity, q128.fromRatio(3, 10)),
            ),
            q128.ONE,
        );

        // Blend rhetoric persuasiveness into specificity dimension (20% weight)
        eval.scores[EvaluationResult.DIM_SPECIFICITY] = q128.div(
            q128.add(
                q128.mul(eval.scores[EvaluationResult.DIM_SPECIFICITY], q128.fromRatio(8, 10)),
                q128.mul(self.self_model.rhetoric_persuasiveness, q128.fromRatio(2, 10)),
            ),
            q128.ONE,
        );

        // Recompute overall from blended scores
        recomputeOverall(eval);
    }

    /// Integrates Quadrivium stability and energy into an EvaluationResult.
    /// Stability below 0.3 penalizes overall score; stability above 0.8 boosts it.
    pub fn integrateQuadriviumIntoEval(self: *MetacognitionEngine, eval: *EvaluationResult) void {
        const stability = self.self_model.stability;

        if (stability < q128.fromRatio(3, 10)) {
            // Low stability: penalize overall by 20%
            eval.overall = q128.mul(eval.overall, q128.fromRatio(8, 10));
            eval.passed = false;
        } else if (stability > q128.fromRatio(8, 10)) {
            // High stability: boost coherence by 10%
            eval.scores[EvaluationResult.DIM_COHERENCE] = q128.minVal(
                q128.ONE,
                q128.add(
                    eval.scores[EvaluationResult.DIM_COHERENCE],
                    q128.fromRatio(1, 10),
                ),
            );
        }

        // Recompute overall after stability adjustment
        recomputeOverall(eval);
    }

    /// Non-contradiction check via Trivium LogicStage.
    pub fn checkNonContradiction(self: *MetacognitionEngine, prompt: []const u8, response: []const u8) bool {
        _ = self;
        return trivium.LogicStage.checkNonContradiction(prompt, response);
    }

    /// Returns the Trivium pipeline's parsed input (Grammar stage output).
    pub fn parsedInput(self: MetacognitionEngine) trivium.ParsedInput {
        return self.trivium_pipeline.parsed;
    }

    /// Returns the Trivium pipeline's validated state (Logic stage output).
    pub fn validatedState(self: MetacognitionEngine) trivium.ValidatedState {
        return self.trivium_pipeline.validated;
    }

    /// Returns the Trivium pipeline's rhetoric output (Rhetoric stage output).
    pub fn rhetoricOutput(self: MetacognitionEngine) trivium.RhetoricOutput {
        return self.trivium_pipeline.rhetoric;
    }

    /// Returns the Quadrivium pipeline's stability score.
    pub fn stabilityScore(self: *MetacognitionEngine, activations: []const [8]i128) q128.Fp {
        return self.quadrivium_pipeline.stabilityScore(activations);
    }

    /// Determines whether a correction should be injected between reflection cycles.
    /// Returns the correction phrase if a correction is warranted, null otherwise.
    pub fn shouldCorrect(
        self: *MetacognitionEngine,
        prev_eval: EvaluationResult,
        curr_eval: EvaluationResult,
    ) ?[]const u8 {
        // No previous response to correct against
        if (self.last_partial_response == null) return null;

        // Correction triggers:
        // 1. Relevance improved significantly (new response is more on-topic)
        if (q128.sub(curr_eval.relevance(), prev_eval.relevance()) > q128.fromRatio(2, 10)) {
            return CORRECTION_PHRASES[0];
        }

        // 2. Coherence improved significantly (new response is more logical)
        if (q128.sub(curr_eval.coherence(), prev_eval.coherence()) > q128.fromRatio(2, 10)) {
            return CORRECTION_PHRASES[1];
        }

        // 3. Previous response had very low relevance but new one is better
        if (prev_eval.relevance() < q128.fromRatio(3, 10) and curr_eval.relevance() > prev_eval.relevance()) {
            return CORRECTION_PHRASES[2];
        }

        // 4. Channel imbalance was high (hallucination risk) and improved
        if (self.self_model.channel_imbalance > q128.fromRatio(7, 10) and curr_eval.overall > prev_eval.overall) {
            return CORRECTION_PHRASES[3];
        }

        // 5. Specificity improved significantly (new response is more precise)
        if (q128.sub(curr_eval.specificity(), prev_eval.specificity()) > q128.fromRatio(25, 100)) {
            return CORRECTION_PHRASES[4];
        }

        // 6. Overall score jumped significantly
        if (q128.sub(curr_eval.overall, prev_eval.overall) > q128.fromRatio(15, 100)) {
            return CORRECTION_PHRASES[5];
        }

        return null;
    }

    /// Records a correction event for future analysis.
    pub fn recordCorrection(
        self: *MetacognitionEngine,
        cycle: u8,
        phrase: []const u8,
        corrected_text: []const u8,
        reason: []const u8,
    ) !void {
        try self.correction_history.append(.{
            .cycle = cycle,
            .phrase = phrase,
            .corrected_text = corrected_text,
            .reason = reason,
        });
    }

    /// Stores a partial response for correction comparison.
    pub fn storePartialResponse(self: *MetacognitionEngine, response: []const u8) !void {
        if (self.last_partial_response) |old| self.allocator.free(old);
        self.last_partial_response = try self.allocator.dupe(u8, response);
        self.last_partial_eval = self.evaluation_history.items[self.evaluation_history.items.len -| 1];
    }

    /// Builds a corrected response by stitching the previous partial response
    /// with a correction phrase and the new, better response.
    /// Format: "{previous_partial} {correction_phrase}{new_response}"
    /// If previous partial is too long, only keeps the first sentence.
    pub fn buildCorrectedResponse(
        self: *MetacognitionEngine,
        allocator: std.mem.Allocator,
        correction_phrase: []const u8,
        new_response: []const u8,
    ) ![]u8 {
        const prev = self.last_partial_response orelse return try allocator.dupe(u8, new_response);

        // Extract the first sentence of the previous response
        // (the "um, I think it's 55" part before the correction)
        var prev_slice: []const u8 = prev;
        if (std.mem.indexOf(u8, prev, ". ")) |dot_pos| {
            prev_slice = prev[0 .. dot_pos + 1];
        } else if (prev.len > 200) {
            prev_slice = prev[0..200];
        }

        // Build: "{prev_first_sentence} {correction_phrase}{new_response}"
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        try result.appendSlice(prev_slice);
        try result.append(' ');
        try result.appendSlice(correction_phrase);
        try result.appendSlice(new_response);
        return result.toOwnedSlice();
    }

    /// Returns parameter adjustment suggestions based on the weakest evaluation dimension.
    /// Returns: (dimension_name, old_temp, new_temp, old_top_k, new_top_k, reason)
    pub fn suggestAdjustment(
        self: *MetacognitionEngine,
        eval: EvaluationResult,
        current_temp: q128.Fp,
        current_top_k: usize,
        cycle: u8,
    ) ?ParameterAdjustment {
        var adj: ?ParameterAdjustment = null;

        if (eval.relevance() < q128.fromRatio(3, 10)) {
            adj = .{
                .cycle = cycle,
                .dimension = "relevance",
                .old_value = current_temp,
                .new_value = q128.minVal(q128.fromInt(3), q128.add(current_temp, q128.fromRatio(3, 10))),
                .reason = "Low relevance: increasing temperature for diverse retrieval",
            };
        } else if (eval.coherence() < q128.fromRatio(3, 10)) {
            adj = .{
                .cycle = cycle,
                .dimension = "coherence",
                .old_value = current_temp,
                .new_value = q128.maxVal(q128.fromRatio(1, 2), q128.sub(current_temp, q128.fromRatio(3, 10))),
                .reason = "Low coherence: reducing temperature for focused output",
            };
        } else if (eval.specificity() < q128.fromRatio(3, 10)) {
            adj = .{
                .cycle = cycle,
                .dimension = "specificity",
                .old_value = q128.fromI256(@intCast(current_top_k)),
                .new_value = q128.fromI256(@intCast(@min(20, current_top_k + 2))),
                .reason = "Low specificity: increasing top_k for broader vocabulary",
            };
        } else if (eval.naturalness() < q128.fromRatio(2, 10)) {
            adj = .{
                .cycle = cycle,
                .dimension = "naturalness",
                .old_value = current_temp,
                .new_value = q128.add(q128.fromRatio(12, 10), q128.mul(q128.fromI256(@intCast(cycle)), q128.fromRatio(2, 10))),
                .reason = "Low naturalness: varying temperature for conversational tone",
            };
        }

        if (adj) |a| {
            self.adjustment_history.append(a) catch {};
            if (self.adjustment_history.items.len > MAX_ADJUSTMENTS) {
                const len = self.adjustment_history.items.len;
                for (1..len) |i| {
                    self.adjustment_history.items[i - 1] = self.adjustment_history.items[i];
                }
                self.adjustment_history.shrinkRetainingCapacity(len - 1);
            }
        }

        return adj;
    }

    /// Returns a hesitation phrase for natural conversational fillers.
    /// Used at the start of responses in relaxed/uncertain mood.
    pub fn hesitationPhrase(self: MetacognitionEngine) ?[]const u8 {
        return switch (self.mood) {
            .relaxed => HESITATION_PHRASES[0], // "Um, "
            .uncertain => HESITATION_PHRASES[1], // "Well, "
            .curious => HESITATION_PHRASES[2], // "Let me think... "
            .focused => null, // No hesitation when focused
        };
    }

    /// Returns whether the engine should use a casual response style.
    pub fn isCasualMode(self: MetacognitionEngine) bool {
        return self.is_small_talk or self.mood == .relaxed;
    }

    /// Returns a human-readable status string for debugging/logging.
    pub fn statusString(self: MetacognitionEngine, buf: []u8) []const u8 {
        return std.fmt.bufPrint(
            buf,
            "Mood={s}, Entropy={d:.2}, Imbalance={d:.3}, Coherence={d:.2}, Balance={d:.2}, Stability={d:.2}, Threshold={d:.2}, PassRate={d:.2}, Evals={d}, Corrections={d}",
            .{
                self.mood.label(),
                q128.toF64(self.self_model.activation_entropy),
                q128.toF64(self.self_model.channel_imbalance),
                q128.toF64(self.self_model.activation_coherence),
                q128.toF64(self.self_model.channel_balance),
                q128.toF64(self.self_model.stability),
                q128.toF64(self.dynamicThreshold()),
                q128.toF64(self.passRate()),
                self.evaluation_history.items.len,
                self.correction_history.items.len,
            },
        ) catch &.{};
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Checks if a prompt is small-talk (casual greeting/chitchat).
fn isSmallTalkPrompt(prompt: []const u8) bool {
    var lower_buf: [256]u8 = undefined;
    const prompt_lower = toLower(prompt, &lower_buf);
    const trimmed = std.mem.trim(u8, prompt_lower, " \t\n\r");

    // Short prompts are more likely small-talk
    if (trimmed.len > 60) return false;

    for (SMALL_TALK_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, trimmed, pattern) != null) {
            // Check if the prompt is primarily a small-talk phrase
            // (the pattern should be a significant portion of the prompt)
            if (trimmed.len <= pattern.len + 15) return true;
        }
    }
    return false;
}

/// Checks if a prompt is complex/technical (requires deeper reflection).
fn isComplexPrompt(prompt: []const u8) bool {
    const technical_markers = [_][]const u8{
        "explain",     "analyze",      "compare",   "contrast",           "derive",
        "prove",       "calculate",    "design",    "architecture",       "algorithm",
        "complexity",  "optimize",     "implement", "theorem",            "proof",
        "quantum",     "relativity",   "topology",  "manifold",           "eigenvalue",
        "polynomial",  "differential", "integral",  "recursive",          "concurrent",
        "distributed", "cryptograph",  "entropy",   "information theory",
    };

    var lower_buf: [512]u8 = undefined;
    const prompt_lower = toLower(prompt, &lower_buf);

    var matches: usize = 0;
    for (technical_markers) |marker| {
        if (std.mem.indexOf(u8, prompt_lower, marker) != null) {
            matches += 1;
        }
    }

    // Multiple technical markers or long prompt → complex
    return matches >= 2 or prompt.len > 200;
}

/// Derives mood from activation entropy and channel balance.
fn deriveMood(entropy: q128.Fp, channel_imbalance: q128.Fp, is_small_talk: bool) Mood {
    if (is_small_talk) return .relaxed;

    if (channel_imbalance > q128.fromRatio(7, 10)) return .uncertain;
    if (entropy > q128.fromInt(4)) return .focused;
    if (entropy > q128.fromInt(2)) return .curious;
    return .relaxed;
}

/// Derives mood from activation entropy, channel balance, and Trivium logic state.
/// Contradiction detected → uncertain; inconsistent lattice → uncertain.
fn deriveMoodWithTrivium(
    entropy: q128.Fp,
    channel_imbalance: q128.Fp,
    is_consistent: bool,
    contradiction_detected: bool,
    is_small_talk: bool,
) Mood {
    if (is_small_talk) return .relaxed;
    if (contradiction_detected) return .uncertain;
    if (!is_consistent) return .uncertain;
    if (channel_imbalance > q128.fromRatio(7, 10)) return .uncertain;
    if (entropy > q128.fromInt(4)) return .focused;
    if (entropy > q128.fromInt(2)) return .curious;
    return .relaxed;
}

/// Recomputes the overall score from the 8 dimension scores using the same
/// weighted average as agent.zig's evaluateResponse.
fn recomputeOverall(eval: *EvaluationResult) void {
    const weights = [_]q128.Fp{
        q128.fromRatio(20, 100), // relevance
        q128.fromRatio(18, 100), // coherence
        q128.fromRatio(10, 100), // specificity
        q128.fromRatio(10, 100), // naturalness
        q128.fromRatio(12, 100), // self_awareness
        q128.fromRatio(10, 100), // direct_experience
        q128.fromRatio(10, 100), // metacognition
        q128.fromRatio(10, 100), // situational_awareness
    };
    var overall: q128.Fp = 0;
    for (eval.scores, weights) |s, w| {
        overall = q128.add(overall, q128.mul(s, w));
    }
    eval.overall = overall;
}

/// Converts a string to lowercase in-place using a provided buffer.
fn toLower(input: []const u8, buf: []u8) []const u8 {
    const len = @min(input.len, buf.len);
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(input[i]);
    }
    return buf[0..len];
}

// =============================================================================
// RouteGenerator — autonomously creates dynamic routes from corpus and KG
// =============================================================================

pub const RouteGenerator = struct {
    allocator: std.mem.Allocator,
    registry: *dyn_routes.DynamicRouteRegistry,
    routes_created: u64 = 0,
    routes_skipped: u64 = 0,

    // Stopwords for keyword extraction
    const STOPWORDS = [_][]const u8{
        "the",   "a",       "an",   "is",   "are",  "was",   "were",  "be",    "been",  "being",
        "have",  "has",     "had",  "do",   "does", "did",   "will",  "would", "could", "should",
        "may",   "might",   "must", "can",  "of",   "to",    "in",    "for",   "on",    "at",
        "by",    "with",    "from", "as",   "into", "about", "than",  "that",  "this",  "these",
        "those", "it",      "its",  "they", "them", "their", "there", "where", "when",  "what",
        "which", "who",     "whom", "and",  "or",   "but",   "not",   "no",    "if",    "then",
        "so",    "because", "how",  "why",  "all",  "each",  "every", "both",  "few",   "more",
        "most",  "other",   "some", "such", "only", "own",   "same",  "very",  "just",  "also",
        "too",   "here",    "now",
    };

    pub fn init(allocator: std.mem.Allocator, registry: *dyn_routes.DynamicRouteRegistry) RouteGenerator {
        return .{
            .allocator = allocator,
            .registry = registry,
        };
    }

    fn isStopword(word: []const u8) bool {
        for (STOPWORDS) |sw| {
            if (std.ascii.eqlIgnoreCase(sw, word)) return true;
        }
        return false;
    }

    /// Extracts up to `max_kws` significant keywords from a sentence.
    /// Skips stopwords, short words, and punctuation.
    pub fn extractKeywords(sentence: []const u8, out: [][]const u8, max_kws: usize) usize {
        var count: usize = 0;
        var word_it = std.mem.tokenizeAny(u8, sentence, " \t\n\r,.;:!?\"'()[]{}-");
        while (word_it.next()) |word| {
            if (count >= max_kws) break;
            if (word.len < 4) continue;
            if (isStopword(word)) continue;
            out[count] = word;
            count += 1;
        }
        return count;
    }

    /// Extracts routes from corpus text by scanning for high-information sentences.
    /// A sentence is considered high-information if it:
    ///   - Has 15-300 characters
    ///   - Contains at least 2 significant keywords
    ///   - Does not already match an existing route
    pub fn extractFromCorpus(self: *RouteGenerator, corpus_text: []const u8) !usize {
        var created: usize = 0;
        var sent_it = std.mem.splitAny(u8, corpus_text, ".\n");
        while (sent_it.next()) |sent| {
            const trimmed = std.mem.trim(u8, sent, " \t\r-*");
            if (trimmed.len < 15 or trimmed.len > 300) continue;

            var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
            const kw_count = extractKeywords(trimmed, &kws, dyn_routes.MAX_KEYWORDS);
            if (kw_count < 2) continue;

            // Check if this sentence already matches an existing route
            if (self.registry.match(trimmed) != null) continue;

            const kws_slice = kws[0..kw_count];
            _ = self.registry.register(
                kws_slice,
                trimmed,
                dyn_routes.DEFAULT_CORPUS_CONFIDENCE_BP,
                .factual,
                .corpus_extracted,
            ) catch |err| {
                if (err == error.RegistryFull) break;
                continue;
            };
            created += 1;
            self.routes_created += 1;
        }
        return created;
    }

    /// Synthesizes a route from KG triplet data.
    /// Takes subject/predicate/object and creates a verbalized response.
    pub fn synthesizeFromTriplet(
        self: *RouteGenerator,
        subject: []const u8,
        predicate: []const u8,
        object: []const u8,
    ) !void {
        var response_buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "{s} {s} {s}.", .{
            subject, predicate, object,
        }) catch return;

        var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
        kws[0] = subject;
        kws[1] = object;
        const kw_count: usize = if (subject.len >= 4 and object.len >= 4) 2 else 1;

        _ = try self.registry.register(
            kws[0..kw_count],
            response,
            dyn_routes.DEFAULT_KG_CONFIDENCE_BP,
            .factual,
            .kg_synthesized,
        );
        self.routes_created += 1;
    }

    /// Evaluates a response and registers it as a route if the score is high enough.
    /// Called after each generateWithReflection cycle.
    pub fn evaluateAndRegister(
        self: *RouteGenerator,
        prompt: []const u8,
        response: []const u8,
        eval_score: q128.Fp,
    ) !void {
        const score_f64 = q128.toF64(eval_score);
        const score_bp: u16 = @intFromFloat(@min(1.0, @max(0.0, score_f64)) * @as(f64, dyn_routes.BP_PER_UNIT));

        if (score_bp >= dyn_routes.HIGH_CONFIDENCE_BP) {
            var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
            const kw_count = extractKeywords(prompt, &kws, dyn_routes.MAX_KEYWORDS);
            if (kw_count == 0) {
                self.routes_skipped += 1;
                return;
            }

            _ = self.registry.register(
                kws[0..kw_count],
                response,
                score_bp,
                .factual,
                .self_evaluated,
            ) catch |err| {
                if (err == error.RegistryFull) {
                    self.registry.pruneLowConfidence();
                    _ = self.registry.register(
                        kws[0..kw_count],
                        response,
                        score_bp,
                        .factual,
                        .self_evaluated,
                    ) catch {
                        self.routes_skipped += 1;
                        return;
                    };
                } else {
                    self.routes_skipped += 1;
                    return;
                }
            };
            self.routes_created += 1;
        } else {
            self.routes_skipped += 1;
        }
    }

    /// Returns stats as a formatted string.
    pub fn statsString(self: RouteGenerator, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "Routes created: {d}, skipped: {d}", .{
            self.routes_created,
            self.routes_skipped,
        }) catch &.{};
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MetacognitionEngine: init and deinit" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expectEqual(q128.fromRatio(1, 2), engine.confidence_threshold);
    try std.testing.expectEqual(@as(u8, STANDARD_CYCLES), engine.reflection_depth);
    try std.testing.expectEqual(Mood.relaxed, engine.mood);
    try std.testing.expectEqual(false, engine.stop_flag.load(.acquire));
    try std.testing.expectEqual(false, engine.correction_pending.load(.acquire));
    try std.testing.expectEqual(false, engine.generation_active.load(.acquire));
}

test "MetacognitionEngine: background thread start/stop" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.startThread();
    try std.testing.expect(engine.bg_thread != null);
    engine.stopThread();
    try std.testing.expect(engine.bg_thread == null);
}

test "MetacognitionEngine: mid-generation correction detection" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.startThread();

    // Simulate generation active with poor relevance
    engine.setGenerationActive(true);
    engine.updateSharedState(q128.fromRatio(9, 10), q128.fromInt(9), q128.fromRatio(15, 100), 20, q128.fromRatio(3, 10), false);

    // Wait briefly for thread to detect
    std.time.sleep(150 * std.time.ns_per_ms);

    // Check if correction was detected
    const correction = engine.checkCorrectionPending();
    try std.testing.expect(correction != null);

    engine.setGenerationActive(false);
}

test "MetacognitionEngine: no correction when state is healthy" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.startThread();

    engine.setGenerationActive(true);
    engine.updateSharedState(q128.fromRatio(2, 10), q128.fromInt(3), q128.fromRatio(8, 10), 50, q128.fromRatio(9, 10), true);

    std.time.sleep(100 * std.time.ns_per_ms);

    const correction = engine.checkCorrectionPending();
    try std.testing.expect(correction == null);

    engine.setGenerationActive(false);
}

test "MetacognitionEngine: recordEvaluation and averageScore" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.recordEvaluation(.{ .scores = [_]q128.Fp{q128.fromRatio(1, 2)} ** 8, .overall = q128.fromRatio(6, 10), .passed = true });
    try engine.recordEvaluation(.{ .scores = [_]q128.Fp{q128.fromRatio(4, 10)} ** 8, .overall = q128.fromRatio(4, 10), .passed = false });

    try std.testing.expectEqual(q128.fromRatio(1, 2), engine.averageScore());
    try std.testing.expectEqual(q128.fromRatio(1, 2), engine.passRate());
}

test "MetacognitionEngine: dynamicThreshold adjusts based on pass rate" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    // High pass rate → raise threshold
    for (0..5) |_| {
        try engine.recordEvaluation(.{ .scores = [_]q128.Fp{q128.fromRatio(8, 10)} ** 8, .overall = q128.fromRatio(8, 10), .passed = true });
    }
    const high_threshold = engine.dynamicThreshold();
    try std.testing.expect(high_threshold > q128.fromRatio(1, 2));

    // Reset with low pass rate → lower threshold
    engine.evaluation_history.clearRetainingCapacity();
    for (0..5) |_| {
        try engine.recordEvaluation(.{ .scores = [_]q128.Fp{q128.fromRatio(2, 10)} ** 8, .overall = q128.fromRatio(2, 10), .passed = false });
    }
    const low_threshold = engine.dynamicThreshold();
    try std.testing.expect(low_threshold < q128.fromRatio(1, 2));
}

test "MetacognitionEngine: classifyPrompt detects small talk" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.classifyPrompt("Hi there!");
    try std.testing.expect(engine.is_small_talk);
    try std.testing.expectEqual(@as(u8, SMALL_TALK_CYCLES), engine.reflection_depth);
    try std.testing.expectEqual(Mood.relaxed, engine.mood);

    engine.classifyPrompt("Explain the algorithm complexity of quicksort");
    try std.testing.expect(!engine.is_small_talk);
    try std.testing.expectEqual(@as(u8, DEEP_CYCLES), engine.reflection_depth);
    try std.testing.expectEqual(Mood.focused, engine.mood);
}

test "MetacognitionEngine: classifyPrompt standard prompt" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.classifyPrompt("What is the capital of France?");
    try std.testing.expect(!engine.is_small_talk);
    try std.testing.expectEqual(@as(u8, STANDARD_CYCLES), engine.reflection_depth);
}

test "MetacognitionEngine: updateSelfModel sets mood" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.updateSelfModel(q128.fromInt(5), 42, 3, q128.fromRatio(3, 10), 100, 50, q128.fromRatio(7, 10), q128.fromInt(2));
    try std.testing.expectEqual(Mood.focused, engine.mood);

    engine.updateSelfModel(q128.ONE, 10, 1, q128.fromRatio(8, 10), 50, 5, q128.fromRatio(3, 10), q128.fromRatio(15, 10));
    try std.testing.expectEqual(Mood.uncertain, engine.mood);
}

test "MetacognitionEngine: shouldCorrect detects improvement" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Store a partial response so correction is possible
    engine.last_partial_response = try std.testing.allocator.dupe(u8, "The temperature is 55.");
    defer {
        if (engine.last_partial_response) |r| std.testing.allocator.free(r);
        engine.last_partial_response = null;
    }

    const prev = EvaluationResult{
        .scores = [_]q128.Fp{ q128.fromRatio(2, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10) },
        .overall = q128.fromRatio(4, 10),
        .passed = false,
    };
    const curr = EvaluationResult{
        .scores = [_]q128.Fp{ q128.fromRatio(6, 10), q128.fromRatio(7, 10), q128.fromRatio(5, 10), q128.fromRatio(6, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10) },
        .overall = q128.fromRatio(6, 10),
        .passed = true,
    };

    const correction = engine.shouldCorrect(prev, curr);
    try std.testing.expect(correction != null);
}

test "MetacognitionEngine: shouldCorrect returns null when no improvement" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.last_partial_response = try std.testing.allocator.dupe(u8, "The answer is 42.");
    defer {
        if (engine.last_partial_response) |r| std.testing.allocator.free(r);
        engine.last_partial_response = null;
    }

    const prev = EvaluationResult{
        .scores = [_]q128.Fp{ q128.fromRatio(7, 10), q128.fromRatio(7, 10), q128.fromRatio(7, 10), q128.fromRatio(7, 10), q128.fromRatio(7, 10), q128.fromRatio(7, 10), q128.fromRatio(7, 10), q128.fromRatio(7, 10) },
        .overall = q128.fromRatio(7, 10),
        .passed = true,
    };
    const curr = prev; // Same eval, no improvement

    const correction = engine.shouldCorrect(prev, curr);
    try std.testing.expect(correction == null);
}

test "MetacognitionEngine: buildCorrectedResponse stitches text" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.last_partial_response = try std.testing.allocator.dupe(u8, "I think it's 55. Some other text.");
    defer {
        if (engine.last_partial_response) |r| std.testing.allocator.free(r);
        engine.last_partial_response = null;
    }

    const corrected = try engine.buildCorrectedResponse(
        std.testing.allocator,
        "Actually, wait — ",
        "it's 54.",
    );
    defer std.testing.allocator.free(corrected);

    try std.testing.expect(std.mem.indexOf(u8, corrected, "I think it's 55.") != null);
    try std.testing.expect(std.mem.indexOf(u8, corrected, "Actually, wait — ") != null);
    try std.testing.expect(std.mem.indexOf(u8, corrected, "it's 54.") != null);
}

test "MetacognitionEngine: suggestAdjustment for low relevance" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    const eval = EvaluationResult{
        .scores = [_]q128.Fp{ q128.fromRatio(2, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10), q128.fromRatio(5, 10) },
        .overall = q128.fromRatio(4, 10),
        .passed = false,
    };

    const adj = engine.suggestAdjustment(eval, q128.fromRatio(15, 10), 10, 0);
    try std.testing.expect(adj != null);
    try std.testing.expectEqualStrings("relevance", adj.?.dimension);
    try std.testing.expect(adj.?.new_value > adj.?.old_value);
}

test "MetacognitionEngine: suggestAdjustment returns null when all good" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    const eval = EvaluationResult{
        .scores = [_]q128.Fp{ q128.fromRatio(8, 10), q128.fromRatio(8, 10), q128.fromRatio(8, 10), q128.fromRatio(8, 10), q128.fromRatio(8, 10), q128.fromRatio(8, 10), q128.fromRatio(8, 10), q128.fromRatio(8, 10) },
        .overall = q128.fromRatio(8, 10),
        .passed = true,
    };

    const adj = engine.suggestAdjustment(eval, q128.fromRatio(15, 10), 10, 0);
    try std.testing.expect(adj == null);
}

test "MetacognitionEngine: hesitationPhrase based on mood" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.mood = .focused;
    try std.testing.expect(engine.hesitationPhrase() == null);

    engine.mood = .relaxed;
    try std.testing.expect(engine.hesitationPhrase() != null);

    engine.mood = .uncertain;
    try std.testing.expect(engine.hesitationPhrase() != null);
}

test "MetacognitionEngine: isCasualMode" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.is_small_talk = true;
    try std.testing.expect(engine.isCasualMode());

    engine.is_small_talk = false;
    engine.mood = .relaxed;
    try std.testing.expect(engine.isCasualMode());

    engine.mood = .focused;
    try std.testing.expect(!engine.isCasualMode());
}

test "MetacognitionEngine: statusString produces output" {
    var engine = MetacognitionEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.recordEvaluation(.{ .scores = [_]q128.Fp{q128.fromRatio(1, 2)} ** 8, .overall = q128.fromRatio(1, 2), .passed = true });

    var buf: [256]u8 = undefined;
    const status = engine.statusString(&buf);
    try std.testing.expect(status.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, status, "Mood=") != null);
}

test "isSmallTalkPrompt: detects greetings" {
    try std.testing.expect(isSmallTalkPrompt("Hi!"));
    try std.testing.expect(isSmallTalkPrompt("Hello there!"));
    try std.testing.expect(isSmallTalkPrompt("How are you?"));
    try std.testing.expect(isSmallTalkPrompt("Thanks!"));
    try std.testing.expect(!isSmallTalkPrompt("What is the algorithm complexity of quicksort?"));
    try std.testing.expect(!isSmallTalkPrompt("Explain quantum entanglement and its implications for computing."));
}

test "isComplexPrompt: detects technical prompts" {
    try std.testing.expect(isComplexPrompt("Explain the algorithm complexity of quicksort and compare it to mergesort"));
    try std.testing.expect(isComplexPrompt("Design a distributed system architecture with cryptographic authentication"));
    try std.testing.expect(!isComplexPrompt("What is France?"));
    try std.testing.expect(!isComplexPrompt("Hi!"));
}

test "RouteGenerator: extractKeywords skips stopwords" {
    var kws: [8][]const u8 = undefined;
    const count = RouteGenerator.extractKeywords("What is the speed of light in vacuum?", &kws, 8);
    try std.testing.expect(count >= 2);
    try std.testing.expectEqualStrings("speed", kws[0]);
    try std.testing.expectEqualStrings("light", kws[1]);
}

test "RouteGenerator: extractFromCorpus creates routes" {
    var reg = dyn_routes.DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var gen = RouteGenerator.init(std.testing.allocator, &reg);
    const corpus = "Photosynthesis converts sunlight into chemical energy. The mitochondria is the powerhouse of the cell. DNA carries genetic information.";
    const created = try gen.extractFromCorpus(corpus);
    try std.testing.expect(created >= 2);
    try std.testing.expect(reg.count() >= 2);
}

test "RouteGenerator: synthesizeFromTriplet creates route" {
    var reg = dyn_routes.DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var gen = RouteGenerator.init(std.testing.allocator, &reg);
    try gen.synthesizeFromTriplet("Earth", "orbits", "Sun");
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    const matched = reg.match("Earth and Sun relationship");
    try std.testing.expect(matched != null);
}

test "RouteGenerator: evaluateAndRegister high score creates route" {
    var reg = dyn_routes.DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var gen = RouteGenerator.init(std.testing.allocator, &reg);
    try gen.evaluateAndRegister("What is photosynthesis process", "Photosynthesis is how plants make food.", q128.fromRatio(85, 100));
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(gen.routes_created == 1);
}

test "RouteGenerator: evaluateAndRegister low score skips" {
    var reg = dyn_routes.DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var gen = RouteGenerator.init(std.testing.allocator, &reg);
    try gen.evaluateAndRegister("What is photosynthesis", "I don't know.", q128.fromRatio(3, 10));
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    try std.testing.expect(gen.routes_skipped == 1);
}

test "RouteGenerator: statsString produces output" {
    var reg = dyn_routes.DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var gen = RouteGenerator.init(std.testing.allocator, &reg);
    try gen.evaluateAndRegister("What is quantum mechanics", "Quantum mechanics is physics.", q128.fromRatio(9, 10));

    var buf: [128]u8 = undefined;
    const stats = gen.statsString(&buf);
    try std.testing.expect(stats.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, stats, "Routes created:") != null);
}
