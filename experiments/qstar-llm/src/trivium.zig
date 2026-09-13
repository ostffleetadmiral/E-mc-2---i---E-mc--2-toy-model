//! trivium.zig — Trivium cognitive architecture for Qstar agent.
//!
//! Implements the three classical liberal arts as processing stages
//! in the inference pipeline:
//!   - Grammar: input parsing, concept extraction, modality routing
//!   - Logic: reasoning validation, constraint satisfaction, coherence checking
//!   - Rhetoric: output generation policy, tone adaptation, format selection
//!
//! Each stage wraps existing agent functionality with structured metadata
//! and hooks for the metacognition engine to inspect and adjust.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

const MAX_CONCEPTS: usize = 32;
const MAX_DOMAINS: usize = 8;
const MAX_REASONING_STEPS: usize = 16;

// =============================================================================
// Modality
// =============================================================================

pub const Modality = enum {
    text,
    audio,

    pub fn label(self: Modality) []const u8 {
        return switch (self) {
            .text => "text",
            .audio => "audio",
        };
    }
};

// =============================================================================
// Complexity Level
// =============================================================================

pub const Complexity = enum {
    trivial,
    simple,
    moderate,
    complex,
    deep,

    pub fn label(self: Complexity) []const u8 {
        return switch (self) {
            .trivial => "trivial",
            .simple => "simple",
            .moderate => "moderate",
            .complex => "complex",
            .deep => "deep",
        };
    }

    pub fn fromPrompt(prompt: []const u8) Complexity {
        const word_count = countWords(prompt);
        const has_code = std.mem.indexOf(u8, prompt, "```") != null;
        const has_math = std.mem.indexOfAny(u8, prompt, "∫∑∂∇√∞≠≤≥") != null;
        const has_multi_clause = countOccurrences(prompt, ",") >= 3;
        const has_question_markers = countOccurrences(prompt, "?") >= 2;

        if (word_count < 5) return .trivial;
        if (has_code or has_math) return .deep;
        if (word_count > 20 and (has_multi_clause or has_question_markers)) return .complex;
        if (word_count > 15) return .moderate;
        if (word_count > 5) return .simple;
        return .trivial;
    }
};

// =============================================================================
// Tone
// =============================================================================

pub const Tone = enum {
    formal,
    casual,
    technical,
    conversational,
    creative,

    pub fn label(self: Tone) []const u8 {
        return switch (self) {
            .formal => "formal",
            .casual => "casual",
            .technical => "technical",
            .conversational => "conversational",
            .creative => "creative",
        };
    }

    pub fn detectFromPrompt(prompt: []const u8) Tone {
        const has_technical = std.mem.indexOfAny(u8, prompt, "∫∑∂∇√∞≠≤≥αβγδεζηθλμπσφψω") != null or
            std.mem.indexOf(u8, prompt, "algorithm") != null or
            std.mem.indexOf(u8, prompt, "function") != null or
            std.mem.indexOf(u8, prompt, "equation") != null or
            std.mem.indexOf(u8, prompt, "theorem") != null or
            std.mem.indexOf(u8, prompt, "proof") != null;
        const has_creative = std.mem.indexOf(u8, prompt, "poem") != null or
            std.mem.indexOf(u8, prompt, "story") != null or
            std.mem.indexOf(u8, prompt, "imagine") != null or
            std.mem.indexOf(u8, prompt, "describe") != null;
        const has_casual = std.mem.indexOf(u8, prompt, "hey") != null or
            std.mem.indexOf(u8, prompt, "hi ") != null or
            std.mem.indexOf(u8, prompt, "what's up") != null or
            std.mem.indexOf(u8, prompt, "how are you") != null;
        const has_formal = std.mem.indexOf(u8, prompt, "please") != null or
            std.mem.indexOf(u8, prompt, "kindly") != null or
            std.mem.indexOf(u8, prompt, "would you") != null or
            std.mem.indexOf(u8, prompt, "could you") != null;

        if (has_creative) return .creative;
        if (has_technical) return .technical;
        if (has_casual) return .casual;
        if (has_formal) return .formal;
        return .conversational;
    }
};

// =============================================================================
// Output Format
// =============================================================================

pub const OutputFormat = enum {
    plain_text,
    markdown,
    structured,
    code_block,

    pub fn detectFromPrompt(prompt: []const u8) OutputFormat {
        if (std.mem.indexOf(u8, prompt, "```") != null or
            std.mem.indexOf(u8, prompt, "code") != null)
            return .code_block;
        if (std.mem.indexOf(u8, prompt, "list") != null or
            std.mem.indexOf(u8, prompt, "steps") != null or
            std.mem.indexOf(u8, prompt, "bullet") != null)
            return .structured;
        if (std.mem.indexOf(u8, prompt, "format") != null or
            std.mem.indexOf(u8, prompt, "markdown") != null)
            return .markdown;
        return .plain_text;
    }
};

// =============================================================================
// ParsedInput (Grammar Stage Output)
// =============================================================================

pub const ParsedInput = struct {
    raw_prompt: []const u8,
    concepts: [MAX_CONCEPTS][]const u8 = undefined,
    concept_count: usize = 0,
    domain: Domain = .general,
    complexity: Complexity = .simple,
    modality: Modality = .text,
    tone: Tone = .conversational,
    has_question: bool = false,
    has_code: bool = false,
    has_math: bool = false,
    estimated_response_length: usize = 256,

    pub fn domainLabel(self: ParsedInput) []const u8 {
        return self.domain.label();
    }
};

// =============================================================================
// Domain
// =============================================================================

pub const Domain = enum {
    general,
    mathematics,
    physics,
    chemistry,
    biology,
    computer_science,
    philosophy,
    history,
    literature,
    music,
    astronomy,
    linguistics,
    economics,
    psychology,

    pub fn label(self: Domain) []const u8 {
        return switch (self) {
            .general => "general",
            .mathematics => "mathematics",
            .physics => "physics",
            .chemistry => "chemistry",
            .biology => "biology",
            .computer_science => "computer_science",
            .philosophy => "philosophy",
            .history => "history",
            .literature => "literature",
            .music => "music",
            .astronomy => "astronomy",
            .linguistics => "linguistics",
            .economics => "economics",
            .psychology => "psychology",
        };
    }

    pub fn detectFromPrompt(prompt: []const u8) Domain {
        const keywords = struct {
            const math = [_][]const u8{ "equation", "theorem", "proof", "integral", "derivative", "algebra", "geometry", "calculus", "matrix", "vector", "polynomial", "prime", "function", "logarithm", "exponential" };
            const physics = [_][]const u8{ "energy", "force", "momentum", "velocity", "acceleration", "gravity", "quantum", "relativity", "particle", "wave", "thermodynamic", "entropy", "photon", "electron", "magnetic" };
            const chemistry = [_][]const u8{ "molecule", "atom", "chemical", "reaction", "compound", "element", "bond", "acid", "base", "oxidation", "reduction", "organic", "catalyst", "polymer" };
            const biology = [_][]const u8{ "cell", "DNA", "protein", "enzyme", "evolution", "gene", "organism", "tissue", "membrane", "metabolism", "photosynthesis", "ecosystem", "neuron", "hormone" };
            const cs = [_][]const u8{ "algorithm", "data structure", "programming", "code", "function", "compiler", "database", "network", "software", "hardware", "binary", "hash", "tree", "graph", "sort", "search", "complexity", "recursion" };
            const philosophy = [_][]const u8{ "consciousness", "ethics", "moral", "existence", "reality", "truth", "knowledge", "epistemology", "metaphysics", "logic", "virtue", "justice", "free will", "determinism" };
            const history = [_][]const u8{ "century", "ancient", "medieval", "revolution", "war", "empire", "civilization", "dynasty", "historical", "archaeological", "Renaissance", "colonial" };
            const literature = [_][]const u8{ "novel", "poem", "author", "character", "plot", "metaphor", "simile", "theme", "narrative", "prose", "verse", "sonnet", "haiku" };
            const music = [_][]const u8{ "music", "melody", "harmony", "rhythm", "chord", "scale", "note", "tempo", "octave", "frequency", "instrument", "symphony" };
            const astronomy = [_][]const u8{ "star", "planet", "galaxy", "orbit", "telescope", "constellation", "nebula", "black hole", "cosmos", "universe", "solar system", "asteroid", "comet" };
            const linguistics = [_][]const u8{ "language", "grammar", "syntax", "phonology", "morphology", "semantics", "pragmatics", "linguistic", "phoneme", "morpheme" };
            const economics = [_][]const u8{ "economy", "market", "trade", "supply", "demand", "inflation", "GDP", "fiscal", "monetary", "investment", "currency", "tariff" };
            const psychology = [_][]const u8{ "psychology", "cognitive", "behavior", "emotion", "perception", "memory", "learning", "consciousness", "subconscious", "therapy", "disorder" };
        };

        if (matchAny(prompt, &keywords.math)) return .mathematics;
        if (matchAny(prompt, &keywords.physics)) return .physics;
        if (matchAny(prompt, &keywords.chemistry)) return .chemistry;
        if (matchAny(prompt, &keywords.biology)) return .biology;
        if (matchAny(prompt, &keywords.cs)) return .computer_science;
        if (matchAny(prompt, &keywords.philosophy)) return .philosophy;
        if (matchAny(prompt, &keywords.history)) return .history;
        if (matchAny(prompt, &keywords.literature)) return .literature;
        if (matchAny(prompt, &keywords.music)) return .music;
        if (matchAny(prompt, &keywords.astronomy)) return .astronomy;
        if (matchAny(prompt, &keywords.linguistics)) return .linguistics;
        if (matchAny(prompt, &keywords.economics)) return .economics;
        if (matchAny(prompt, &keywords.psychology)) return .psychology;
        return .general;
    }
};

// =============================================================================
// ValidatedState (Logic Stage Output)
// =============================================================================

pub const ValidatedState = struct {
    confidence: f64 = 0.5,
    is_consistent: bool = true,
    contradiction_detected: bool = false,
    reasoning_steps: usize = 0,
    activation_coherence: f64 = 0.5,
    channel_balance: f64 = 0.5,
    validation_notes: [256]u8 = std.mem.zeroes([256]u8),
    notes_len: usize = 0,

    pub fn notesSlice(self: ValidatedState) []const u8 {
        return self.validation_notes[0..self.notes_len];
    }

    pub fn isAcceptable(self: ValidatedState) bool {
        return self.is_consistent and !self.contradiction_detected and self.confidence >= 0.3;
    }
};

// =============================================================================
// RhetoricOutput (Rhetoric Stage Output)
// =============================================================================

pub const RhetoricOutput = struct {
    format: OutputFormat = .plain_text,
    tone: Tone = .conversational,
    persuasiveness_score: f64 = 0.5,
    clarity_score: f64 = 0.5,
    target_length: usize = 256,
    use_markdown: bool = false,
    should_add_context: bool = false,
    should_add_examples: bool = false,
};

// =============================================================================
// GrammarStage
// =============================================================================

pub const GrammarStage = struct {
    pub fn parse(prompt: []const u8) ParsedInput {
        var result = ParsedInput{
            .raw_prompt = prompt,
            .domain = Domain.detectFromPrompt(prompt),
            .complexity = Complexity.fromPrompt(prompt),
            .modality = detectModality(prompt),
            .tone = Tone.detectFromPrompt(prompt),
            .has_question = std.mem.indexOf(u8, prompt, "?") != null,
            .has_code = std.mem.indexOf(u8, prompt, "```") != null,
            .has_math = std.mem.indexOfAny(u8, prompt, "∫∑∂∇√∞≠≤≥") != null,
        };

        extractConcepts(prompt, &result);
        result.estimated_response_length = estimateResponseLength(result.complexity, result.domain);

        return result;
    }

    pub fn parseAudio(prompt: []const u8, audio_codes: []const u12) ParsedInput {
        var result = parse(prompt);
        result.modality = .audio;
        _ = audio_codes;
        return result;
    }

    fn detectModality(prompt: []const u8) Modality {
        if (std.mem.indexOf(u8, prompt, "[audio]") != null or
            std.mem.indexOf(u8, prompt, "[voice]") != null)
            return .audio;
        return .text;
    }

    fn extractConcepts(prompt: []const u8, result: *ParsedInput) void {
        var it = std.mem.tokenizeAny(u8, prompt, " \t\n\r.,!?;:\"'()[]{}");
        const stop_words = [_][]const u8{ "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "must", "can", "to", "of", "in", "on", "at", "by", "for", "with", "about", "as", "into", "like", "through", "after", "over", "between", "out", "against", "during", "without", "before", "under", "around", "among", "and", "but", "or", "not", "no", "nor", "so", "yet", "both", "either", "neither", "each", "every", "all", "any", "few", "many", "most", "some", "such", "only", "own", "same", "than", "too", "very", "just", "now", "then", "here", "there", "when", "where", "why", "how", "what", "who", "which", "whose", "whom", "this", "that", "these", "those", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "its", "our", "their" };

        outer: while (it.next()) |word| {
            if (word.len <= 2) continue;
            for (stop_words) |sw| {
                if (std.ascii.eqlIgnoreCase(word, sw)) continue :outer;
            }
            if (result.concept_count >= MAX_CONCEPTS) break;
            result.concepts[result.concept_count] = word;
            result.concept_count += 1;
        }
    }

    fn estimateResponseLength(complexity: Complexity, domain: Domain) usize {
        const base: usize = switch (complexity) {
            .trivial => 64,
            .simple => 128,
            .moderate => 256,
            .complex => 512,
            .deep => 768,
        };
        const domain_multiplier: usize = switch (domain) {
            .mathematics, .physics, .computer_science => 2,
            .philosophy, .history => 3,
            else => 1,
        };
        return base * domain_multiplier;
    }
};

// =============================================================================
// LogicStage
// =============================================================================

pub const LogicStage = struct {
    pub fn validate(
        activations: []const [7]i128,
        parsed: ParsedInput,
    ) ValidatedState {
        var state = ValidatedState{};

        state.activation_coherence = computeActivationCoherence(activations);
        state.channel_balance = computeChannelBalance(activations);
        state.confidence = (state.activation_coherence + state.channel_balance) / 2.0;
        state.is_consistent = state.activation_coherence >= 0.3;
        state.contradiction_detected = state.channel_balance < 0.15;
        state.reasoning_steps = countReasoningSteps(activations);

        if (state.contradiction_detected) {
            const note = "Channel imbalance detected — one channel dominating";
            const len = @min(note.len, state.validation_notes.len);
            @memcpy(state.validation_notes[0..len], note[0..len]);
            state.notes_len = len;
        } else if (!state.is_consistent) {
            const note = "Low activation coherence — lattice state fragmented";
            const len = @min(note.len, state.validation_notes.len);
            @memcpy(state.validation_notes[0..len], note[0..len]);
            state.notes_len = len;
        }

        _ = parsed;
        return state;
    }

    pub fn checkNonContradiction(prompt: []const u8, response: []const u8) bool {
        if (prompt.len == 0 or response.len == 0) return true;
        const negation_markers = [_][]const u8{ "not ", "never", "no ", "cannot", "can't", "don't", "doesn't", "isn't", "aren't", "wasn't", "weren't" };
        var prompt_negations: usize = 0;
        var response_negations: usize = 0;
        for (negation_markers) |marker| {
            if (std.ascii.indexOfIgnoreCase(prompt, marker) != null) prompt_negations += 1;
            if (std.ascii.indexOfIgnoreCase(response, marker) != null) response_negations += 1;
        }
        if (prompt_negations > 0 and response_negations == 0) {
            var prompt_it = std.mem.tokenizeAny(u8, prompt, " \t\n\r.,!?;:\"'()[]{}");
            var prompt_keywords: [16][]const u8 = undefined;
            var pkw_count: usize = 0;
            while (prompt_it.next()) |w| {
                if (w.len > 4 and pkw_count < 16) {
                    prompt_keywords[pkw_count] = w;
                    pkw_count += 1;
                }
            }
            var response_matches: usize = 0;
            for (prompt_keywords[0..pkw_count]) |kw| {
                if (std.ascii.indexOfIgnoreCase(response, kw) != null) response_matches += 1;
            }
            return response_matches < pkw_count;
        }
        return true;
    }

    fn computeActivationCoherence(activations: []const [7]i128) f64 {
        if (activations.len == 0) return 0.0;
        var active_count: usize = 0;
        var total_energy: i128 = 0;
        for (activations) |node| {
            var node_energy: i128 = 0;
            for (node) |ch| {
                const abs_val = if (ch < 0) -ch else ch;
                node_energy += abs_val;
            }
            if (node_energy > 0) active_count += 1;
            total_energy += node_energy;
        }
        if (total_energy == 0) return 0.0;
        const density = @as(f64, @floatFromInt(active_count)) / @as(f64, @floatFromInt(activations.len));
        return @min(1.0, density * 1.5);
    }

    fn computeChannelBalance(activations: []const [7]i128) f64 {
        if (activations.len == 0) return 0.0;
        var channel_sums: [7]i128 = .{ 0, 0, 0, 0, 0, 0, 0 };
        for (activations) |node| {
            for (0..7) |ch| {
                channel_sums[ch] += if (node[ch] < 0) -node[ch] else node[ch];
            }
        }
        var total: i128 = 0;
        var max_channel: i128 = 0;
        for (channel_sums) |s| {
            total += s;
            if (s > max_channel) max_channel = s;
        }
        if (total == 0) return 0.0;
        const max_ratio = @as(f64, @floatFromInt(max_channel)) / @as(f64, @floatFromInt(total));
        return @max(0.0, 1.0 - max_ratio);
    }

    fn countReasoningSteps(activations: []const [7]i128) usize {
        if (activations.len == 0) return 0;
        var transitions: usize = 0;
        for (0..activations.len - 1) |i| {
            var diff: i128 = 0;
            for (0..7) |ch| {
                const a = activations[i][ch];
                const b = activations[i + 1][ch];
                diff += if (a > b) a - b else b - a;
            }
            if (diff > 100) transitions += 1;
        }
        return transitions;
    }
};

// =============================================================================
// RhetoricStage
// =============================================================================

pub const RhetoricStage = struct {
    pub fn plan(parsed: ParsedInput) RhetoricOutput {
        var output = RhetoricOutput{
            .format = OutputFormat.detectFromPrompt(parsed.raw_prompt),
            .tone = parsed.tone,
            .target_length = parsed.estimated_response_length,
        };

        output.use_markdown = output.format == .markdown or output.format == .structured;
        output.should_add_examples = parsed.complexity == .complex or parsed.complexity == .deep;
        output.should_add_context = parsed.domain != .general and parsed.complexity != .trivial;

        return output;
    }

    pub fn evaluate(response: []const u8, rhetoric_plan: RhetoricOutput) RhetoricOutput {
        var result = rhetoric_plan;
        result.clarity_score = scoreClarity(response);
        result.persuasiveness_score = scorePersuasiveness(response);
        return result;
    }

    pub fn shouldReformat(response: []const u8, target: OutputFormat) bool {
        switch (target) {
            .code_block => return std.mem.indexOf(u8, response, "```") == null,
            .structured => return std.mem.indexOf(u8, response, "\n- ") == null and std.mem.indexOf(u8, response, "\n* ") == null,
            .markdown => return std.mem.indexOf(u8, response, "##") == null and std.mem.indexOf(u8, response, "**") == null,
            .plain_text => return false,
        }
    }

    fn scoreClarity(response: []const u8) f64 {
        if (response.len == 0) return 0.0;
        var sentences: usize = 0;
        var it = std.mem.splitScalar(u8, response, '.');
        while (it.next()) |s| {
            if (s.len > 10) sentences += 1;
        }
        if (sentences == 0) return 0.0;
        var words: usize = 0;
        var wit = std.mem.tokenizeAny(u8, response, " \t\n\r");
        while (wit.next()) |_| words += 1;
        if (words == 0) return 0.0;
        const avg_sentence_len = @as(f64, @floatFromInt(words)) / @as(f64, @floatFromInt(sentences));
        if (avg_sentence_len <= 0.0) return 0.0;
        const ideal: f64 = 15.0;
        if (avg_sentence_len >= ideal) {
            return @max(0.0, ideal / avg_sentence_len);
        } else {
            return @min(1.0, avg_sentence_len / ideal);
        }
    }

    fn scorePersuasiveness(response: []const u8) f64 {
        if (response.len == 0) return 0.0;
        const persuasive_markers = [_][]const u8{ "because", "therefore", "thus", "consequently", "as a result", "this means", "this is why", "the key", "importantly", "essentially", "fundamentally", "in practice" };
        var count: usize = 0;
        for (persuasive_markers) |marker| {
            if (std.ascii.indexOfIgnoreCase(response, marker) != null) count += 1;
        }
        return @min(1.0, @as(f64, @floatFromInt(count)) * 0.15);
    }
};

// =============================================================================
// TriviumPipeline — orchestrates all three stages
// =============================================================================

pub const TriviumPipeline = struct {
    parsed: ParsedInput = undefined,
    validated: ValidatedState = .{},
    rhetoric: RhetoricOutput = .{},
    stage_completed: StageFlags = .{},

    pub const StageFlags = struct {
        grammar: bool = false,
        logic: bool = false,
        rhetoric: bool = false,
    };

    pub fn runGrammar(self: *TriviumPipeline, prompt: []const u8) void {
        self.parsed = GrammarStage.parse(prompt);
        self.stage_completed.grammar = true;
    }

    pub fn runLogic(self: *TriviumPipeline, activations: []const [7]i128) void {
        if (!self.stage_completed.grammar) return;
        self.validated = LogicStage.validate(activations, self.parsed);
        self.stage_completed.logic = true;
    }

    pub fn runRhetoric(self: *TriviumPipeline) void {
        if (!self.stage_completed.grammar) return;
        self.rhetoric = RhetoricStage.plan(self.parsed);
        self.stage_completed.rhetoric = true;
    }

    pub fn runAll(self: *TriviumPipeline, prompt: []const u8, activations: []const [7]i128) void {
        self.runGrammar(prompt);
        self.runLogic(activations);
        self.runRhetoric();
    }

    pub fn isComplete(self: TriviumPipeline) bool {
        return self.stage_completed.grammar and self.stage_completed.logic and self.stage_completed.rhetoric;
    }

    pub fn summary(self: TriviumPipeline, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "Grammar(domain={s}, complexity={s}) -> Logic(confidence={d:.2}, consistent={}) -> Rhetoric(tone={s}, format={s})", .{
            self.parsed.domain.label(),
            self.parsed.complexity.label(),
            self.validated.confidence,
            self.validated.is_consistent,
            self.rhetoric.tone.label(),
            @tagName(self.rhetoric.format),
        }) catch buf[0..0];
    }
};

// =============================================================================
// Helper functions
// =============================================================================

fn countWords(text: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
    while (it.next()) |_| count += 1;
    return count;
}

fn countOccurrences(text: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        if (std.mem.indexOfPos(u8, text, start, needle)) |pos| {
            count += 1;
            start = pos + needle.len;
        } else {
            break;
        }
    }
    return count;
}

fn matchAny(text: []const u8, keywords: []const []const u8) bool {
    for (keywords) |kw| {
        if (std.ascii.indexOfIgnoreCase(text, kw) != null) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "trivium: grammar stage parses text prompt" {
    const prompt = "Explain how quicksort works with an example";
    const parsed = GrammarStage.parse(prompt);
    try std.testing.expect(parsed.modality == .text);
    try std.testing.expect(parsed.domain == .computer_science);
    try std.testing.expect(parsed.has_question == false);
    try std.testing.expect(parsed.concept_count > 0);
    try std.testing.expect(parsed.complexity != .trivial);
}

test "trivium: grammar stage detects audio modality" {
    const prompt = "[audio] Transcribe this recording";
    const parsed = GrammarStage.parse(prompt);
    try std.testing.expect(parsed.modality == .audio);
}

test "trivium: grammar stage detects math domain" {
    const prompt = "What is the integral of x squared?";
    const parsed = GrammarStage.parse(prompt);
    try std.testing.expect(parsed.domain == .mathematics);
}

test "trivium: grammar stage detects biology domain" {
    const prompt = "How does DNA replication work in cells?";
    const parsed = GrammarStage.parse(prompt);
    try std.testing.expect(parsed.domain == .biology);
}

test "trivium: logic stage validates activation coherence" {
    const activations = [_][7]i128{
        .{ 100, 200, 50, 0, 0, 0, 0 },
        .{ 150, 180, 30, 10, 0, 0, 0 },
        .{ 120, 190, 40, 5, 0, 0, 0 },
    };
    const parsed = GrammarStage.parse("test prompt");
    const state = LogicStage.validate(&activations, parsed);
    try std.testing.expect(state.activation_coherence > 0.0);
    try std.testing.expect(state.channel_balance > 0.0);
    try std.testing.expect(state.confidence > 0.0);
}

test "trivium: logic stage detects channel imbalance" {
    const activations = [_][7]i128{
        .{ 1000, 0, 0, 0, 0, 0, 0 },
        .{ 2000, 0, 0, 0, 0, 0, 0 },
        .{ 1500, 0, 0, 0, 0, 0, 0 },
    };
    const parsed = GrammarStage.parse("test prompt");
    const state = LogicStage.validate(&activations, parsed);
    try std.testing.expect(state.channel_balance < 0.3);
    try std.testing.expect(state.contradiction_detected);
}

test "trivium: logic stage non-contradiction check" {
    try std.testing.expect(LogicStage.checkNonContradiction("Is the sky blue?", "Yes, the sky is blue."));
    try std.testing.expect(!LogicStage.checkNonContradiction("Why is the sky not green?", "The sky is green because of magic."));
}

test "trivium: rhetoric stage plans output format" {
    const parsed = GrammarStage.parse("Write a function to sort an array in Python with code");
    const plan = RhetoricStage.plan(parsed);
    try std.testing.expect(plan.format == .code_block);
    try std.testing.expect(plan.tone == .technical);
}

test "trivium: rhetoric stage evaluates clarity" {
    const response = "Quicksort is a divide and conquer algorithm. It picks a pivot element. It partitions the array around the pivot. It recursively sorts the sub-arrays.";
    const plan = RhetoricOutput{};
    const result = RhetoricStage.evaluate(response, plan);
    try std.testing.expect(result.clarity_score > 0.3);
}

test "trivium: rhetoric stage detects structured format need" {
    try std.testing.expect(RhetoricStage.shouldReformat("Just plain text here.", .structured) == true);
    try std.testing.expect(RhetoricStage.shouldReformat("Item 1\n- Point A\n- Point B", .structured) == false);
}

test "trivium: full pipeline runs all stages" {
    var pipeline = TriviumPipeline{};
    const activations = [_][7]i128{
        .{ 100, 200, 50, 30, 10, 5, 0 },
        .{ 150, 180, 30, 20, 15, 10, 5 },
    };
    pipeline.runAll("Explain the algorithm for binary search", &activations);
    try std.testing.expect(pipeline.isComplete());
    try std.testing.expect(pipeline.parsed.domain == .computer_science);
    try std.testing.expect(pipeline.validated.confidence > 0.0);
    try std.testing.expect(pipeline.rhetoric.tone == .technical);
}

test "trivium: pipeline summary produces readable string" {
    var pipeline = TriviumPipeline{};
    const activations = [_][7]i128{
        .{ 100, 200, 50, 30, 10, 5, 0 },
    };
    pipeline.runAll("What is photosynthesis?", &activations);
    var buf: [256]u8 = undefined;
    const s = pipeline.summary(&buf);
    try std.testing.expect(s.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, s, "Grammar") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Logic") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Rhetoric") != null);
}

test "trivium: complexity classification" {
    try std.testing.expect(Complexity.fromPrompt("hi") == .trivial);
    try std.testing.expect(Complexity.fromPrompt("What is the square root of 144?") == .simple);
    try std.testing.expect(Complexity.fromPrompt("Explain the proof of Fermat's Last Theorem and its implications for number theory, including the role of elliptic curves, modular forms, and Galois representations in the proof? What does this mean?") == .complex);
}

test "trivium: tone detection" {
    try std.testing.expect(Tone.detectFromPrompt("Hey, what's up?") == .casual);
    try std.testing.expect(Tone.detectFromPrompt("Write a poem about autumn") == .creative);
    try std.testing.expect(Tone.detectFromPrompt("Explain the algorithm for binary search") == .technical);
    try std.testing.expect(Tone.detectFromPrompt("Could you please explain the theory of relativity?") == .formal);
}

test "trivium: domain detection covers all domains" {
    try std.testing.expect(Domain.detectFromPrompt("What is a prime number?") == .mathematics);
    try std.testing.expect(Domain.detectFromPrompt("How does gravity work?") == .physics);
    try std.testing.expect(Domain.detectFromPrompt("What is the chemical formula for water?") == .chemistry);
    try std.testing.expect(Domain.detectFromPrompt("How do neurons fire?") == .biology);
    try std.testing.expect(Domain.detectFromPrompt("What is consciousness?") == .philosophy);
    try std.testing.expect(Domain.detectFromPrompt("Tell me about the Renaissance") == .history);
    try std.testing.expect(Domain.detectFromPrompt("Write a haiku about nature") == .literature);
    try std.testing.expect(Domain.detectFromPrompt("What is a musical chord?") == .music);
    try std.testing.expect(Domain.detectFromPrompt("How do stars form?") == .astronomy);
    try std.testing.expect(Domain.detectFromPrompt("What is supply and demand?") == .economics);
}

// =============================================================================
// Framework-Aware Complexity Classification (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework complexity levels derived from the 6D interior structure.
/// The 6D interior (e1-e6) provides 6 levels of complexity:
/// e1 (time) = trivial, e2 (quantum) = simple, e3 (space) = moderate,
/// e4 (energy) = complex, e5 (structure) = advanced, e6 (self-recognition) = framework.
pub const FrameworkComplexity = enum(u8) {
    trivial = 0, // Small talk, greetings
    simple = 1, // Basic factual questions
    moderate = 2, // Multi-step reasoning
    complex = 3, // Technical explanations
    advanced = 4, // Multi-domain synthesis
    framework = 5, // E=mc²-i-E=mc⁻² framework queries

    pub fn label(self: FrameworkComplexity) []const u8 {
        return switch (self) {
            .trivial => "trivial",
            .simple => "simple",
            .moderate => "moderate",
            .complex => "complex",
            .advanced => "advanced",
            .framework => "framework",
        };
    }
};

/// Framework keywords for complexity classification.
const FRAMEWORK_COMPLEXITY_KEYWORDS = [_][]const u8{
    "421",        "7-defect",       "1/8",                    "C=2",              "octonion", "E0 lattice",
    "Fano plane", "Jordan algebra", "J3(O)",                  "SO(10)",           "E8",       "generative chain",
    "0^0=i",      "Higgs",          "consciousness aperture", "self-recognition", "e6",       "observer-observed",
};

/// Classifies prompt complexity using the framework's 6D structure.
pub fn classifyFrameworkComplexity(prompt: []const u8) FrameworkComplexity {
    // Check for framework keywords first
    for (FRAMEWORK_COMPLEXITY_KEYWORDS) |keyword| {
        if (std.mem.indexOf(u8, prompt, keyword) != null) return .framework;
    }

    // Length-based heuristic
    if (prompt.len < 20) return .trivial;
    if (prompt.len < 50) return .simple;
    if (prompt.len < 100) return .moderate;
    if (prompt.len < 200) return .complex;
    return .advanced;
}

test "framework: classify framework complexity" {
    try std.testing.expectEqual(FrameworkComplexity.framework, classifyFrameworkComplexity("What is the 421 identity?"));
    try std.testing.expectEqual(FrameworkComplexity.framework, classifyFrameworkComplexity("Explain the octonion multiplication table"));
    try std.testing.expectEqual(FrameworkComplexity.framework, classifyFrameworkComplexity("How does the E0 lattice work?"));
    try std.testing.expectEqual(FrameworkComplexity.trivial, classifyFrameworkComplexity("Hi"));
    try std.testing.expectEqual(FrameworkComplexity.simple, classifyFrameworkComplexity("What is 2 plus 2?"));
}
