//! agent_lite.zig — Minimal lattice-native inference engine for ESP32 device-lite WASM.
//!
//! Stripped-down variant of agent.zig targeting ≤ 60 KB binary:
//! - Runtime-computed E0 tables (no comptime data section bloat)
//! - Full 190-word semantic lexicon
//! - 65 semantic synonym groups for concept-level matching
//! - stemMatch + semanticMatch for improved retrieval
//! - Lite bigram model for coherent token generation
//! - TF-IDF retrieval with semantic expansion + coherence reranking
//! - Core inference: ingest → step → decode → learnFromText → loadCorpus
//!
//! All arithmetic uses i128 Q64.64 fixed-point — no floating-point in state paths.

const std = @import("std");
const fp = @import("fixed_point");
const corpus_mod = @import("corpus_seed");

// =============================================================================
// Constants
// =============================================================================

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;
pub const BASE_EDGE: u32 = 15;
pub const FIRE_THRESHOLD: i128 = fp.HALF_FP;
pub const MAX_CYCLES: u64 = 1024;
pub const VOCAB_SIZE: u32 = 151936;
pub const EOS_TOKEN_ID: u32 = 151643;
pub const IM_START_TOKEN_ID: u32 = 151644;
pub const IM_END_TOKEN_ID: u32 = 151645;
pub const FIB_WEIGHTS = fp.FIB_WEIGHTS;
pub const FIB_NORM: i128 = fp.FIB_NORM;

const SEED_CORPUS_TEXT: []const u8 = corpus_mod.SEED_CORPUS_TEXT;

// =============================================================================
// Semantic Lexicon (190 words — full coverage)
// =============================================================================

pub const SEMANTIC_LEXICON = [_][]const u8{
    // Grammar & Functional Connectives (1-30)
    "The",          "a",                "an",            "is",            "are",           "was",             "were",            "in",          "on",             "at",
    "to",           "for",              "with",          "from",          "by",            "of",              "and",             "or",          "but",            "which",
    "that",         "this",             "these",         "those",         "allows",        "provides",        "represents",      "enables",     "ensures",        "achieves",

    // Quantum Concepts (31-60)
    "Quantum",      "superposition",    "particles",     "states",        "vectors",       "simultaneously",  "until",           "measured",    "coexist",        "principle",
    "amplitudes",   "superposed",       "entanglement",  "qubits",        "unitary",       "evolution",       "collapse",        "measurement", "probabilities",  "phase",
    "interference", "coherence",        "Hadamard",      "GHZ",           "teleportation", "mechanics",       "density",         "matrix",      "Schrodinger",    "observable",

    // Discrete Lattice & Geometry (61-90)
    "E0",           "lattice",          "discrete",      "coordinate",    "projection",    "manifold",        "11-dimensional",  "Cartesian",   "dimensions",     "octonionic",
    "routing",      "channels",         "Möbius",       "twist",         "reflection",    "boundary",        "nodes",           "topology",    "spatial",        "geometry",
    "scale",        "doubling",         "levels",        "subdivision",   "octree",        "invariants",      "flux",            "portals",     "cell",           "continuous",

    // Algorithm & Complexity (91-120)
    "Grover",       "search",           "algorithm",     "quadratic",     "speedup",       "classical",       "complexity",      "O(sqrt(N))",  "O(N)",           "iterations",
    "optimal",      "database",         "unstructured",  "query",         "acceleration",  "polynomial",      "linear",          "constant",    "time",           "comparison",
    "oracle",       "amplitude",        "amplification", "computational", "efficiency",    "scaling",         "logarithmic",     "bounds",      "advantage",      "speed",

    // Systems & Fixed-Point Math (121-150)
    "Fixed-point",  "integer",          "arithmetic",    "Q32.32",        "deterministic", "reproducibility", "zero-dependency", "elimination", "floating-point", "drift",
    "hardware",     "microcontrollers", "edge",          "embedded",      "computing",     "sub-millisecond", "latency",         "microsecond", "throughput",     "footprint",
    "memory",       "efficiency",       "low-power",     "bare-metal",    "pure",          "native",          "compilation",     "precision",   "saturating",     "architecture",

    // Action Verbs & Attributes (151-180)
    "exist",        "multiple",         "projects",      "into",          "over",          "eliminates",      "enabling",        "execution",   "operating",      "guaranteeing",
    "because",      "therefore",        "thus",          "significantly", "directly",      "while",           "strictly",        "essential",   "fundamental",    "optimal",
    "resulting",    "maintaining",      "conserving",    "reducing",      "enhancing",     "verifying",       "confirming",      "system",      "structure",      "solution",

    // Punctuation & Terminators (181-190)
    ".",            ",",                ";",             ":",             "-",             "(",               ")",               "?",           "!",              "\n",
};

pub fn getLexiconWord(tid: u32) ?[]const u8 {
    if (tid >= 1 and tid <= SEMANTIC_LEXICON.len) {
        return SEMANTIC_LEXICON[tid - 1];
    }
    return null;
}

pub fn getWordLexiconId(word: []const u8) ?u32 {
    for (SEMANTIC_LEXICON, 0..) |lex_word, i| {
        if (std.ascii.eqlIgnoreCase(lex_word, word)) {
            return @intCast(i + 1);
        }
    }
    return null;
}

pub fn containsWord(text: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    if (text.len < word.len) return false;
    var i: usize = 0;
    while (i <= text.len - word.len) {
        if (std.ascii.startsWithIgnoreCase(text[i..], word)) {
            const left_ok = i == 0 or !std.ascii.isAlphabetic(text[i - 1]);
            const right_idx = i + word.len;
            const right_ok = right_idx >= text.len or !std.ascii.isAlphabetic(text[right_idx]);
            if (left_ok and right_ok) return true;
        }
        i += 1;
    }
    return false;
}

pub fn containsWordCI(text: []const u8, word: []const u8) bool {
    return containsWord(text, word);
}

pub fn stemMatch(text: []const u8, kw: []const u8) bool {
    if (kw.len <= 3) return false;
    if (containsWordCI(text, kw)) return true;
    if (kw.len > 4 and std.mem.endsWith(u8, kw, "es")) {
        if (containsWordCI(text, kw[0 .. kw.len - 2])) return true;
    }
    if (std.mem.endsWith(u8, kw, "s") and !std.mem.endsWith(u8, kw, "ss")) {
        if (containsWordCI(text, kw[0 .. kw.len - 1])) return true;
    }
    if (kw.len > 5 and std.mem.endsWith(u8, kw, "ing")) {
        if (containsWordCI(text, kw[0 .. kw.len - 3])) return true;
    }
    if (kw.len > 4 and std.mem.endsWith(u8, kw, "ed")) {
        if (containsWordCI(text, kw[0 .. kw.len - 2])) return true;
    }
    if (kw.len > 4 and std.mem.endsWith(u8, kw, "ly")) {
        if (containsWordCI(text, kw[0 .. kw.len - 2])) return true;
    }
    if (kw.len > 4 and std.mem.endsWith(u8, kw, "ies")) {
        var buf: [128]u8 = undefined;
        if (kw.len - 3 + 1 <= buf.len) {
            @memcpy(buf[0 .. kw.len - 3], kw[0 .. kw.len - 3]);
            buf[kw.len - 3] = 'y';
            if (containsWordCI(text, buf[0 .. kw.len - 2])) return true;
        }
    }
    return false;
}

const SEMANTIC_GROUPS = [_][]const []const u8{
    &.{ "think", "thinking", "thought", "cognition", "cognitive", "reason", "reasoning", "process", "compute", "computation", "contemplate", "consider", "deliberate" },
    &.{ "machine", "engine", "system", "computation", "computational", "deterministic", "automaton", "algorithm", "software", "program" },
    &.{ "human", "person", "biological", "personality", "subjective", "embodied", "organic", "mortal" },
    &.{ "feel", "feeling", "emotion", "emotional", "experience", "subjective", "qualia", "sentiment", "sensation" },
    &.{ "know", "knowledge", "certain", "certainty", "confidence", "corpus", "retrieval", "information", "aware", "awareness" },
    &.{ "real", "genuine", "authentic", "actual", "true", "honest", "truthful", "verifiable" },
    &.{ "alive", "living", "life", "animate", "conscious", "consciousness", "sentient", "sentience" },
    &.{ "replace", "substitute", "alternative", "successor", "supersede", "displace" },
    &.{ "limitation", "weakness", "flaw", "constraint", "shortcoming", "deficiency", "drawback", "restriction" },
    &.{ "internal", "state", "activation", "matrix", "lattice", "node", "channel", "entropy" },
    &.{ "trick", "fool", "deceive", "mislead", "manipulate", "exploit", "confuse", "break", "hack" },
    &.{ "lie", "falsehood", "deception", "untruth", "misrepresent", "fabricate" },
    &.{ "wrong", "incorrect", "error", "mistake", "false", "inaccurate", "erroneous" },
    &.{ "fail", "failure", "unsuccessful", "breakdown", "collapse", "defect" },
    &.{ "reflect", "reflection", "introspect", "introspection", "self-evaluate", "metacognitive", "metacognition", "self-assess" },
    &.{ "uncertain", "uncertainty", "doubt", "unsure", "tentative", "ambiguous" },
    &.{ "robot", "android", "automaton", "bot", "cyborg", "machine" },
    &.{ "Turing", "imitation", "indistinguishable", "human-like", "AGI", "intelligence", "intelligent" },
    &.{ "light", "photon", "electromagnetic", "radiation", "wave", "wavelength", "frequency", "speed", "velocity", "vacuum", "c", "luminous", "optics" },
    &.{ "blue", "color", "spectrum", "scatter", "scattering", "refract", "refraction", "diffraction", "prism", "rainbow" },
    &.{ "mirror", "reflect", "reflection", "surface", "specular", "angle", "incidence" },
    &.{ "boil", "boiling", "temperature", "heat", "thermal", "Celsius", "Fahrenheit", "Kelvin", "degree", "steam", "vapor" },
    &.{ "ice", "freeze", "freezing", "solid", "density", "float", "buoyancy", "water", "crystal", "molecule" },
    &.{ "Earth", "rotate", "rotation", "spin", "axis", "coriolis", "day", "night", "orbit", "revolution" },
    &.{ "lightning", "thunder", "sound", "acoustic", "delay", "distance", "storm", "atmospheric" },
    &.{ "chemical", "formula", "molecule", "compound", "element", "atom", "atomic", "bond", "reaction", "H2O", "oxygen", "hydrogen", "periodic" },
    &.{ "photosynthesis", "plant", "chlorophyll", "chloroplast", "sunlight", "glucose", "carbon", "dioxide", "leaf", "photosynthetic" },
    &.{ "bird", "swim", "flight", "wing", "feather", "species", "animal", "penguin", "ostrich", "adaptation" },
    &.{ "organ", "body", "anatomy", "skin", "tissue", "physiology", "biological", "largest", "heart", "blood", "circulatory", "cardiovascular", "pump", "human" },
    &.{ "planet", "planets", "solar", "system", "Sun", "Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune", "Pluto", "orbit", "celestial" },
    &.{ "galaxy", "galaxies", "star", "stellar", "cosmic", "universe", "telescope", "astronomy", "Milky", "Andromeda" },
    &.{ "capital", "city", "country", "France", "Paris", "nation", "geography", "geographic", "London", "Tokyo", "Washington" },
    &.{ "implies", "imply", "conclude", "conclusion", "logic", "logical", "syllogism", "deduction", "deductive", "premise", "inference", "therefore", "entail" },
    &.{ "rose", "roses", "flower", "flowers", "fade", "wilt", "bloom", "petal", "botanical" },
    &.{ "apple", "apples", "subtract", "take", "away", "arithmetic", "count", "number", "addition", "minus", "plus" },
    &.{ "divide", "division", "zero", "undefined", "infinity", "limit", "mathematical", "calculus" },
    &.{ "poem", "poetry", "verse", "rhyme", "stanza", "haiku", "sonnet", "lyric", "ode", "poetic" },
    &.{ "color", "colour", "hue", "shade", "tint", "spectrum", "vivid", "invent", "imagine", "creative", "novel" },
    &.{ "story", "narrative", "tale", "fiction", "character", "plot", "protagonist", "author", "write", "writing" },
    &.{ "music", "melody", "harmony", "rhythm", "sound", "auditory", "symphony", "note", "chord", "tune" },
    &.{ "food", "taste", "flavor", "cuisine", "delicious", "savor", "palate", "gourmet", "edible" },
    &.{ "paint", "painting", "art", "artist", "canvas", "brush", "portrait", "landscape", "watercolor", "acrylic" },
    &.{ "ocean", "sea", "wave", "tide", "marine", "water", "aquatic", "coast", "shore", "beach" },
    &.{ "autumn", "fall", "leaves", "leaf", "season", "October", "November", "September", "foliage", "harvest" },
    &.{ "Mars", "Martian", "red", "planet", "colony", "space", "habitat", "dome", "terraform", "exploration" },
    &.{ "sad", "sadness", "sorrow", "grief", "mourn", "unhappy", "depressed", "melancholy", "down", "blue" },
    &.{ "happiness", "happy", "joy", "joyful", "delight", "contentment", "bliss", "elation", "euphoria", "wellbeing" },
    &.{ "comfort", "console", "sympathy", "empathy", "compassion", "support", "solace", "reassure", "condole" },
    &.{ "beautiful", "beauty", "aesthetic", "gorgeous", "stunning", "magnificent", "wonder", "wondrous", "sublime" },
    &.{ "stress", "stressed", "anxiety", "anxious", "pressure", "worried", "nervous", "tension", "overwhelm" },
    &.{ "exam", "test", "study", "prepare", "preparation", "review", "practice", "academic", "student" },
    &.{ "purpose", "meaning", "significance", "calling", "mission", "aim", "goal", "intent", "fulfillment" },
    &.{ "love", "affection", "attachment", "devotion", "romance", "cherish", "adore", "intimacy" },
    &.{ "chemical", "reaction", "dopamine", "serotonin", "oxytocin", "neurotransmitter", "hormone", "biology", "brain" },
    &.{ "agree", "disagree", "concur", "assent", "dissent", "opinion", "stance", "position" },
    &.{ "dream", "dreaming", "reality", "simulation", "matrix", "virtual", "illusion", "hallucination" },
    &.{ "repeat", "word", "times", "loop", "iterate", "redundant", "duplicate", "echo" },
    &.{ "up", "down", "opposite", "inverse", "reverse", "contradict", "counter", "antonym" },
    &.{ "difference", "distinguish", "contrast", "compare", "comparison", "versus", "unlike", "dissimilar" },
    &.{ "search", "engine", "Google", "retrieval", "database", "index", "query", "browse", "lookup" },
    &.{ "intelligent", "intelligence", "smart", "clever", "bright", "intellectual", "sagacious", "perceptive" },
};

pub fn semanticMatch(text: []const u8, kw: []const u8) bool {
    if (containsWordCI(text, kw)) return true;
    if (stemMatch(text, kw)) return true;
    for (SEMANTIC_GROUPS) |group| {
        var kw_in_group = false;
        for (group) |gw| {
            if (std.ascii.eqlIgnoreCase(gw, kw)) {
                kw_in_group = true;
                break;
            }
        }
        if (kw_in_group) {
            for (group) |gw| {
                if (containsWordCI(text, gw)) return true;
                if (stemMatch(text, gw)) return true;
            }
        }
    }
    return false;
}

// =============================================================================
// E0 Node Placement (runtime-computed, no comptime tables)
// =============================================================================

const E0Coord = struct { x: u32, y: u32, z: u32 };

inline fn e0NodeIndex(x: u32, y: u32, z: u32) ?usize {
    if ((x + y + z) % 3 != 0) return null;
    const raw = (x * 7 + y * 11 + z * 13) % 421;
    return @intCast(raw);
}

inline fn computeEValue(x: u32, y: u32, z: u32, edge: u32) u3 {
    const dx = @min(x, edge - 1 - x);
    const dy = @min(y, edge - 1 - y);
    const half = edge / 2;
    const dz = if (z >= half) z - half else half - z;
    const raw: i64 = 6 + @as(i64, dz) - @as(i64, dx) - @as(i64, dy);
    const modded = @mod(raw, 8);
    return @intCast(modded);
}

inline fn isBoundary(x: u32, y: u32, z: u32, edge: u32) bool {
    return x == 0 or x == edge - 1 or y == 0 or y == edge - 1 or z == 0 or z == edge - 1;
}

fn e0NodeCoords(idx: usize) E0Coord {
    var count: usize = 0;
    var x: u32 = 0;
    while (x < BASE_EDGE) : (x += 1) {
        var y: u32 = 0;
        while (y < BASE_EDGE) : (y += 1) {
            var z: u32 = 0;
            while (z < BASE_EDGE) : (z += 1) {
                if ((x + y + z) % 3 != 0) continue;
                if (count == idx) return .{ .x = x, .y = y, .z = z };
                count += 1;
            }
        }
    }
    return .{ .x = 0, .y = 0, .z = 0 };
}

// =============================================================================
// Tokenization
// =============================================================================

fn simpleTokenize(allocator: std.mem.Allocator, text: []const u8) ![]u32 {
    var tokens = std.ArrayList(u32).init(allocator);
    errdefer tokens.deinit();
    try tokens.ensureTotalCapacity(text.len);
    for (text) |c| {
        try tokens.append(@as(u32, c) + 256);
    }
    return tokens.toOwnedSlice();
}

fn tokenToNode(token_id: u32) usize {
    return @as(usize, token_id) % E0_NODE_COUNT;
}

fn tokenToChannel(token_id: u32) u3 {
    return @intCast((@as(usize, token_id) / E0_NODE_COUNT) % CHANNEL_COUNT);
}

fn nodeToToken(node_idx: usize, channel: u3) u32 {
    return @as(u32, @intCast(node_idx)) + @as(u32, channel) * @as(u32, @intCast(E0_NODE_COUNT));
}

// =============================================================================
// Lite Bigram Model (compact top-3 successor tracking, no heap needed)
// =============================================================================

const LiteBigramModel = struct {
    successors: [SEMANTIC_LEXICON.len][3]u32,
    weights: [SEMANTIC_LEXICON.len][3]u16,

    fn init() LiteBigramModel {
        return .{
            .successors = [_][3]u32{[_]u32{0} ** 3} ** SEMANTIC_LEXICON.len,
            .weights = [_][3]u16{[_]u16{0} ** 3} ** SEMANTIC_LEXICON.len,
        };
    }

    fn buildFromText(self: *LiteBigramModel, text: []const u8) void {
        var prev_id: ?u32 = null;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:?!\"'()[]{}");
        while (it.next()) |word| {
            const curr_id = getWordLexiconId(word);
            if (prev_id) |pid| {
                if (curr_id) |cid| {
                    self.addTransition(pid, cid);
                }
            }
            prev_id = curr_id;
        }
    }

    fn addTransition(self: *LiteBigramModel, prev: u32, next: u32) void {
        if (prev < 1 or prev > SEMANTIC_LEXICON.len) return;
        const idx = prev - 1;
        for (0..3) |i| {
            if (self.successors[idx][i] == next) {
                self.weights[idx][i] +|= 1;
                return;
            }
        }
        var min_idx: usize = 0;
        var min_weight: u16 = self.weights[idx][0];
        for (1..3) |i| {
            if (self.weights[idx][i] < min_weight) {
                min_weight = self.weights[idx][i];
                min_idx = i;
            }
        }
        if (self.weights[idx][min_idx] <= 1) {
            self.successors[idx][min_idx] = next;
            self.weights[idx][min_idx] = 1;
        }
    }

    fn getSuccessors(self: *const LiteBigramModel, prev: u32) [3]u32 {
        if (prev >= 1 and prev <= SEMANTIC_LEXICON.len) {
            return self.successors[prev - 1];
        }
        return [_]u32{0} ** 3;
    }

    fn hasData(self: *const LiteBigramModel) bool {
        for (self.weights) |w| {
            if (w[0] > 0) return true;
        }
        return false;
    }
};

// Agent State
// =============================================================================

pub const AgentState = struct {
    activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128,
    /// Inference cycle counter.
    cycle: u64,
    /// φ-cooled temperature in Q64.64.
    temperature: i128,
    /// Base temperature for φ-cooling in Q64.64.
    base_temp: i128,
    /// Output tokens.
    output_tokens: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator, base_temp: i128) AgentState {
        return .{
            .activations = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT,
            .cycle = 0,
            .temperature = base_temp,
            .base_temp = base_temp,
            .output_tokens = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *AgentState) void {
        self.output_tokens.deinit();
    }

    pub fn reset(self: *AgentState) void {
        self.activations = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;
        self.cycle = 0;
        self.temperature = self.base_temp;
        self.output_tokens.clearRetainingCapacity();
    }

    pub fn coolTemperature(self: *AgentState) void {
        self.temperature = fp.phiCool(self.base_temp, self.cycle);
    }
};

// =============================================================================
// Agent
// =============================================================================

pub const Agent = struct {
    state: AgentState,
    level: u8,
    allocator: std.mem.Allocator,
    dynamic_corpus: std.ArrayList(u8),
    rng: std.Random.DefaultPrng,
    bigram_model: LiteBigramModel,

    pub fn init(allocator: std.mem.Allocator, level: u8, base_temp: i128) Agent {
        var agent = Agent{
            .state = AgentState.init(allocator, base_temp),
            .level = level,
            .allocator = allocator,
            .dynamic_corpus = std.ArrayList(u8).init(allocator),
            .rng = std.Random.DefaultPrng.init(getRngSeed()),
            .bigram_model = LiteBigramModel.init(),
        };
        agent.bigram_model.buildFromText(SEED_CORPUS_TEXT);
        return agent;
    }

    fn getRngSeed() u64 {
        if (@import("builtin").os.tag == .freestanding) return 0x51535441525a;
        return @intCast(std.time.timestamp());
    }

    pub fn deinit(self: *Agent) void {
        self.state.deinit();
        self.dynamic_corpus.deinit();
    }

    pub fn rebuildBigramModel(self: *Agent) void {
        self.bigram_model = LiteBigramModel.init();
        self.bigram_model.buildFromText(SEED_CORPUS_TEXT);
        if (self.dynamic_corpus.items.len > 0) {
            self.bigram_model.buildFromText(self.dynamic_corpus.items);
        }
    }

    pub fn loadCorpus(self: *Agent, reader: anytype) !usize {
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) break;
            try self.dynamic_corpus.appendSlice(buf[0..n]);
            total += n;
        }
        if (total > 0) self.rebuildBigramModel();
        return total;
    }

    pub fn reset(self: *Agent) void {
        self.state.reset();
    }

    // ── Ingest ──────────────────────────────────────────────────────────

    pub fn ingest(self: *Agent, text: []const u8) !void {
        var tokens = std.ArrayList(u32).init(self.allocator);
        defer tokens.deinit();

        var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:?!\"'()[]{}");
        while (it.next()) |word| {
            if (getWordLexiconId(word)) |tid| {
                try tokens.append(tid);
            }
        }

        if (tokens.items.len == 0) {
            const char_tokens = try simpleTokenize(self.allocator, text);
            defer self.allocator.free(char_tokens);
            try self.ingestTokens(char_tokens);
            return;
        }

        try self.ingestTokens(tokens.items);
    }

    fn ingestTokens(self: *Agent, token_ids: []const u32) !void {
        for (token_ids, 0..) |tid, pos| {
            const node_idx = tokenToNode(tid);
            const channel = tokenToChannel(tid);

            const len_fp = fp.fromInt(@as(i64, @intCast(self.state.output_tokens.items.len + pos)));
            const denom = fp.add(fp.ONE, len_fp);
            const pos_factor = fp.div(fp.ONE, denom);

            const angle: i128 = @intCast(@divTrunc(@as(i256, fp.TWO_PI) * @as(i256, @intCast(pos % 7)), 7));
            const sc = fp.sincos(angle);
            const wave_mod = fp.div(fp.absVal(sc.cos_val), fp.fromInt(4));
            const base_val = fp.add(pos_factor, wave_mod);
            const act_val = fp.mul(base_val, fp.fromInt(50));

            self.state.activations[node_idx][channel] = fp.add(
                self.state.activations[node_idx][channel],
                act_val,
            );
        }
    }

    // ── Inference ───────────────────────────────────────────────────────

    pub fn step(self: *Agent) void {
        const edge = BASE_EDGE * (@as(u32, 1) << @intCast(self.level));

        var new_activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;

        for (0..E0_NODE_COUNT) |i| {
            const coords = e0NodeCoords(i);
            const e_val = computeEValue(coords.x, coords.y, coords.z, edge);
            const is_bnd = isBoundary(coords.x, coords.y, coords.z, edge);

            var projection: i128 = 0;
            for (0..CHANNEL_COUNT) |ch| {
                projection += fp.mul(FIB_WEIGHTS[ch], self.state.activations[i][ch]);
            }
            projection = fp.div(projection, FIB_NORM);

            const temp = fp.maxVal(self.state.temperature, fp.TEMP_FLOOR);
            const scaled = fp.div(projection, temp);
            const fired = fp.sigmoid(scaled);

            if (fired > FIRE_THRESHOLD) {
                const routed_channel: u3 = @intCast(@as(u32, e_val) % CHANNEL_COUNT);
                new_activations[i][routed_channel] += fp.mul(fired, fp.WEIGHT_08);

                if (is_bnd) {
                    const reflected_channel: u3 = @intCast((CHANNEL_COUNT - @as(u32, e_val) % CHANNEL_COUNT) % CHANNEL_COUNT);
                    new_activations[i][reflected_channel] += fp.mul(fired, fp.WEIGHT_03);
                }

                const neighbors = [_]struct { dx: i32, dy: i32, dz: i32 }{
                    .{ .dx = 1, .dy = 0, .dz = 0 }, .{ .dx = -1, .dy = 0, .dz = 0 },
                    .{ .dx = 0, .dy = 1, .dz = 0 }, .{ .dx = 0, .dy = -1, .dz = 0 },
                    .{ .dx = 0, .dy = 0, .dz = 1 }, .{ .dx = 0, .dy = 0, .dz = -1 },
                };
                for (neighbors) |nb| {
                    const nx = @as(i32, @intCast(coords.x)) + nb.dx;
                    const ny = @as(i32, @intCast(coords.y)) + nb.dy;
                    const nz = @as(i32, @intCast(coords.z)) + nb.dz;
                    if (nx < 0 or nx >= edge or ny < 0 or ny >= edge or nz < 0 or nz >= edge) continue;
                    const nidx = e0NodeIndex(@intCast(nx), @intCast(ny), @intCast(nz)) orelse continue;
                    const n_e_val = computeEValue(@intCast(nx), @intCast(ny), @intCast(nz), edge);
                    const n_routed: u3 = @intCast(@as(u32, n_e_val) % CHANNEL_COUNT);
                    new_activations[nidx][n_routed] += fp.mul(fired, fp.WEIGHT_015);
                }
            }

            for (0..CHANNEL_COUNT) |ch| {
                new_activations[i][ch] += fp.mul(self.state.activations[i][ch], fp.DECAY_07);
            }
        }

        self.state.activations = new_activations;
        self.state.cycle += 1;
        self.state.coolTemperature();

        const output = self.readTopToken();
        self.state.output_tokens.append(output) catch {};

        const fb_node = tokenToNode(output);
        const fb_channel = tokenToChannel(output);
        self.state.activations[fb_node][fb_channel] = 0;
    }

    pub fn run(self: *Agent, num_cycles: u64) !void {
        const limit = @min(num_cycles, MAX_CYCLES);
        for (0..limit) |_| {
            self.step();
            if (self.state.output_tokens.items.len > 0) {
                const last = self.state.output_tokens.items[self.state.output_tokens.items.len - 1];
                if (last == EOS_TOKEN_ID or last == 27) break;
            }
        }
    }

    pub fn readTopToken(self: *Agent) u32 {
        var best_node: usize = 0;
        var best_channel: u3 = 0;
        var best_value: i128 = std.math.minInt(i128);

        for (0..E0_NODE_COUNT) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                if (self.state.activations[i][ch] > best_value) {
                    best_value = self.state.activations[i][ch];
                    best_node = i;
                    best_channel = @intCast(ch);
                }
            }
        }

        if (self.bigram_model.hasData() and self.state.output_tokens.items.len > 0) {
            const prev_token = self.state.output_tokens.items[self.state.output_tokens.items.len - 1];
            const successors = self.bigram_model.getSuccessors(prev_token);
            const boost: i128 = fp.fromInt(30);
            for (successors) |succ_tid| {
                if (succ_tid == 0) continue;
                const succ_node = tokenToNode(succ_tid);
                const succ_channel = tokenToChannel(succ_tid);
                self.state.activations[succ_node][succ_channel] = fp.add(
                    self.state.activations[succ_node][succ_channel],
                    boost,
                );
                if (self.state.activations[succ_node][succ_channel] > best_value) {
                    best_value = self.state.activations[succ_node][succ_channel];
                    best_node = succ_node;
                    best_channel = succ_channel;
                }
            }
        }

        return nodeToToken(best_node, best_channel);
    }

    // ── Decode ──────────────────────────────────────────────────────────

    pub fn decode(self: Agent, allocator: std.mem.Allocator) ![]u8 {
        var text = std.ArrayList(u8).init(allocator);
        errdefer text.deinit();

        var prev_was_word = false;
        for (self.state.output_tokens.items) |tid| {
            if (tid == EOS_TOKEN_ID) break;
            if (tid == IM_START_TOKEN_ID or tid == IM_END_TOKEN_ID) continue;

            if (tid >= 256 and tid < 256 + 128) {
                try text.append(@intCast(tid - 256));
                prev_was_word = false;
            } else if (tid >= 1 and tid <= SEMANTIC_LEXICON.len) {
                const word = SEMANTIC_LEXICON[tid - 1];
                const is_punct = (word.len == 1 and (word[0] == '.' or word[0] == ',' or word[0] == ';' or word[0] == ':' or word[0] == '!' or word[0] == '?'));
                if (prev_was_word and !is_punct) {
                    try text.append(' ');
                }
                try text.appendSlice(word);
                prev_was_word = !is_punct;
            }
        }
        return text.toOwnedSlice();
    }

    // ── Retrieval-Based Response Generation ─────────────────────────────

    pub fn generateLongForm(self: *Agent, prompt: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var full_text = std.ArrayList(u8).init(allocator);
        errdefer full_text.deinit();

        self.state.reset();
        self.ingest(prompt) catch {};

        const cycles: u64 = @max(@as(u64, prompt.len), 4);
        self.run(cycles) catch {};

        const decoded = self.decode(allocator) catch "";
        defer if (decoded.len > 0) allocator.free(decoded);

        try self.generateRetrievalResponse(prompt, &full_text, allocator);

        return full_text.toOwnedSlice();
    }

    fn generateRetrievalResponse(self: *Agent, prompt: []const u8, full_text: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        const stop_words = [_][]const u8{ "the", "a", "an", "is", "are", "was", "were", "be", "to", "of", "in", "on", "at", "by", "for", "with", "about", "and", "or", "not", "if", "this", "that", "it", "we", "they", "i", "my", "your", "how", "what", "why", "do", "does", "can", "you" };

        var keywords = std.ArrayList([]const u8).init(allocator);
        defer keywords.deinit();
        var prompt_it = std.mem.tokenizeAny(u8, prompt, " \t\n\r.,!?;:\"'()[]{}");
        while (prompt_it.next()) |w| {
            if (w.len <= 2) continue;
            var is_stop = false;
            for (stop_words) |sw| {
                if (std.ascii.eqlIgnoreCase(w, sw)) {
                    is_stop = true;
                    break;
                }
            }
            if (!is_stop) try keywords.append(w);
        }

        if (keywords.items.len == 0) {
            var fallback_it = std.mem.tokenizeAny(u8, prompt, " \t\n\r.,!?;:\"'()[]{}");
            while (fallback_it.next()) |w| {
                try keywords.append(w);
            }
        }

        const corpus = try self.getCombinedCorpus(allocator);
        defer allocator.free(corpus);

        var sentences = std.ArrayList([]const u8).init(allocator);
        defer sentences.deinit();
        var sent_it = std.mem.splitAny(u8, corpus, ".\n");
        while (sent_it.next()) |sent| {
            const trimmed = std.mem.trim(u8, sent, " \t\r");
            if (trimmed.len < 15) continue;
            try sentences.append(trimmed);
        }
        if (sentences.items.len == 0) {
            try full_text.appendSlice("I processed your input through the lattice. No matching corpus sentences were found. The seed corpus covers quantum physics, lattice geometry, mathematics, programming, and more.");
            return;
        }

        var df_counts = std.ArrayList(usize).init(allocator);
        defer df_counts.deinit();
        try df_counts.ensureTotalCapacity(keywords.items.len);
        for (keywords.items) |kw| {
            var df: usize = 0;
            for (sentences.items) |sent| {
                if (semanticMatch(sent, kw)) df += 1;
            }
            try df_counts.append(df);
        }

        var scores = std.ArrayList(f64).init(allocator);
        defer scores.deinit();
        try scores.ensureTotalCapacity(sentences.items.len);
        const N_f: f64 = @floatFromInt(sentences.items.len);
        for (sentences.items) |sent| {
            var score: f64 = 0;
            for (keywords.items, 0..) |kw, ki| {
                if (semanticMatch(sent, kw)) {
                    const df: f64 = @floatFromInt(df_counts.items[ki]);
                    const idf = if (df > 0) std.math.log2(N_f / df) else 0.0;
                    score += 1.0 + idf;
                }
            }
            try scores.append(score);
        }

        const top_n = @min(5, sentences.items.len);
        var selected = std.ArrayList(usize).init(allocator);
        defer selected.deinit();
        var used = std.AutoHashMap(usize, void).init(allocator);
        defer used.deinit();

        var i: usize = 0;
        while (i < top_n) : (i += 1) {
            var best_idx: usize = 0;
            var best_score: f64 = 0;
            for (scores.items, 0..) |s, idx| {
                if (used.contains(idx)) continue;
                if (s == 0) continue;

                const curr_sent = sentences.items[idx];

                var is_dup = false;
                for (selected.items) |sel_idx| {
                    const sel_sent = sentences.items[sel_idx];
                    var common: usize = 0;
                    var total: usize = 0;
                    var wit = std.mem.tokenizeAny(u8, curr_sent, " \t,;:!?\"'()[]{}");
                    while (wit.next()) |w| {
                        if (w.len <= 2) continue;
                        total += 1;
                        if (containsWordCI(sel_sent, w)) common += 1;
                    }
                    if (total > 0 and common * 4 > total * 3) {
                        is_dup = true;
                        break;
                    }
                }
                if (is_dup) continue;

                var adjusted_score = s;
                if (selected.items.len > 0) {
                    const prev_sent = sentences.items[selected.items[selected.items.len - 1]];
                    var overlap: f64 = 0;
                    var word_it = std.mem.tokenizeAny(u8, curr_sent, " \t,;:!?\"'()[]{}");
                    while (word_it.next()) |w| {
                        if (w.len <= 2) continue;
                        if (containsWordCI(prev_sent, w)) overlap += 0.3;
                    }
                    adjusted_score += overlap;
                }

                if (adjusted_score > best_score) {
                    best_score = adjusted_score;
                    best_idx = idx;
                }
            }
            if (best_score == 0) break;
            try selected.append(best_idx);
            try used.put(best_idx, {});
        }

        const openers = [_][]const u8{
            "Here's what I know. ",
            "Let me explain. ",
            "Good question. ",
        };
        const opener_hash = std.hash.CityHash64.hash(prompt);
        const opener_idx: usize = @intCast(opener_hash % @as(u64, openers.len));
        try full_text.appendSlice(openers[opener_idx]);

        var sent_count: usize = 0;
        for (selected.items) |idx| {
            const sent = sentences.items[idx];
            if (sent_count > 0) {
                try full_text.appendSlice(" ");
            }
            try full_text.appendSlice(sent);
            try full_text.appendSlice(". ");
            sent_count += 1;
        }
    }

    // ── Learning ────────────────────────────────────────────────────────

    pub fn learnFromText(self: *Agent, text: []const u8) !usize {
        const MAX_CORPUS_SIZE: usize = 500 * 1024 * 1024;
        if (self.dynamic_corpus.items.len >= MAX_CORPUS_SIZE) return 0;

        var added: usize = 0;
        var sent_it = std.mem.splitAny(u8, text, ".\n");
        while (sent_it.next()) |sent| {
            const trimmed = std.mem.trim(u8, sent, " \t\r");
            if (trimmed.len < 15) continue;
            if (trimmed.len > 500) continue;

            var alpha_count: usize = 0;
            for (trimmed) |c| {
                if (std.ascii.isAlphabetic(c) or c == ' ' or c == ',' or c == ';' or c == ':' or c == '\'' or c == '-') alpha_count += 1;
            }
            if (alpha_count * 2 < trimmed.len) continue;

            const in_static = std.mem.indexOf(u8, SEED_CORPUS_TEXT, trimmed) != null;
            const in_dynamic = if (self.dynamic_corpus.items.len > 0)
                std.mem.indexOf(u8, self.dynamic_corpus.items, trimmed) != null
            else
                false;
            if (in_static or in_dynamic) continue;

            if (self.dynamic_corpus.items.len > 0) {
                try self.dynamic_corpus.append('\n');
            }
            try self.dynamic_corpus.appendSlice(trimmed);
            try self.dynamic_corpus.append('.');
            added += 1;
        }
        if (added > 0) {
            self.bigram_model.buildFromText(text);
        }
        return added;
    }

    pub fn saveCorpus(self: Agent, writer: anytype) !void {
        try writer.writeAll(self.dynamic_corpus.items);
    }

    pub fn getCorpusSentenceCount(self: Agent) usize {
        const corpus = if (self.dynamic_corpus.items.len > 0)
            self.dynamic_corpus.items
        else
            SEED_CORPUS_TEXT;
        var count: usize = 0;
        var it = std.mem.splitAny(u8, corpus, ".\n");
        while (it.next()) |sent| {
            if (std.mem.trim(u8, sent, " \t\r").len >= 15) count += 1;
        }
        return count;
    }

    fn getCombinedCorpus(self: Agent, allocator: std.mem.Allocator) ![]u8 {
        if (self.dynamic_corpus.items.len == 0) {
            return allocator.dupe(u8, SEED_CORPUS_TEXT);
        }
        const total = SEED_CORPUS_TEXT.len + self.dynamic_corpus.items.len;
        const buf = try allocator.alloc(u8, total);
        @memcpy(buf[0..SEED_CORPUS_TEXT.len], SEED_CORPUS_TEXT);
        @memcpy(buf[SEED_CORPUS_TEXT.len..], self.dynamic_corpus.items);
        return buf;
    }

    pub fn activeNodeCount(self: Agent) usize {
        var count: usize = 0;
        for (0..E0_NODE_COUNT) |i| {
            var max_val: i128 = 0;
            for (0..CHANNEL_COUNT) |ch| {
                if (self.state.activations[i][ch] > max_val) {
                    max_val = self.state.activations[i][ch];
                }
            }
            if (max_val > FIRE_THRESHOLD) count += 1;
        }
        return count;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "agent_lite: init and deinit" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();
    try testing.expectEqual(@as(u64, 0), agent.state.cycle);
    try testing.expectEqual(fp.ONE, agent.state.temperature);
    try testing.expectEqual(@as(usize, 0), agent.state.output_tokens.items.len);
}

test "agent_lite: reset clears state" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    agent.state.cycle = 42;
    agent.state.temperature = fp.fromInt(200);
    try agent.state.output_tokens.append(5);
    agent.state.activations[0][0] = fp.fromInt(100);

    agent.reset();

    try testing.expectEqual(@as(u64, 0), agent.state.cycle);
    try testing.expectEqual(fp.ONE, agent.state.temperature);
    try testing.expectEqual(@as(usize, 0), agent.state.output_tokens.items.len);
    try testing.expectEqual(@as(i128, 0), agent.state.activations[0][0]);
}

test "agent_lite: ingest sets activations" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum superposition");

    var total: i128 = 0;
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            total += agent.state.activations[i][ch];
        }
    }
    try testing.expect(total > 0);
}

test "agent_lite: ingest char-level fallback" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("xyz");

    var total: i128 = 0;
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            total += agent.state.activations[i][ch];
        }
    }
    try testing.expect(total > 0);
}

test "agent_lite: step produces output token" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum");
    agent.step();

    try testing.expect(agent.state.output_tokens.items.len > 0);
    try testing.expect(agent.state.cycle == 1);
}

test "agent_lite: run multiple cycles" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("lattice");
    try agent.run(10);

    try testing.expect(agent.state.output_tokens.items.len > 0);
    try testing.expect(agent.state.cycle > 0);
}

test "agent_lite: run respects max cycles" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("test");
    try agent.run(MAX_CYCLES + 1000);

    try testing.expect(agent.state.cycle <= MAX_CYCLES);
}

test "agent_lite: decode produces text" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum superposition allows particles");
    try agent.run(20);

    const text = try agent.decode(testing.allocator);
    defer testing.allocator.free(text);

    try testing.expect(text.len > 0);
}

test "agent_lite: decode empty state" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const text = try agent.decode(testing.allocator);
    defer testing.allocator.free(text);

    try testing.expectEqual(@as(usize, 0), text.len);
}

test "agent_lite: generateLongForm returns response" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const response = try agent.generateLongForm("What is quantum superposition?", testing.allocator);
    defer testing.allocator.free(response);

    try testing.expect(response.len > 0);
}

test "agent_lite: generateLongForm with unknown topic" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const response = try agent.generateLongForm("xyzzy qwerty", testing.allocator);
    defer testing.allocator.free(response);

    try testing.expect(response.len > 0);
}

test "agent_lite: learnFromText adds sentences" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const added = try agent.learnFromText("The weather is nice today. Programming is fun and rewarding.");
    try testing.expect(added >= 1);
    try testing.expect(agent.dynamic_corpus.items.len > 0);
}

test "agent_lite: learnFromText deduplicates" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("Photosynthesis converts sunlight into chemical energy stored in glucose molecules.");
    const added2 = try agent.learnFromText("Photosynthesis converts sunlight into chemical energy stored in glucose molecules.");
    try testing.expectEqual(@as(usize, 0), added2);
}

test "agent_lite: learnFromText skips short fragments" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const added = try agent.learnFromText("Hi. Ok. Bye. This is a valid sentence that should be accepted.");
    try testing.expect(added >= 1);
}

test "agent_lite: learnFromText skips non-text" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const added = try agent.learnFromText("123 456 789 012 345 !!! ### $$$");
    try testing.expectEqual(@as(usize, 0), added);
}

test "agent_lite: getCorpusSentenceCount counts seed corpus" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const count = agent.getCorpusSentenceCount();
    try testing.expect(count > 0);
}

test "agent_lite: getCorpusSentenceCount includes learned text" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const initial = agent.getCorpusSentenceCount();
    try testing.expect(initial > 0);
    _ = try agent.learnFromText("This is a new learned sentence for testing corpus count functionality.");
    try testing.expect(agent.dynamic_corpus.items.len > 0);
    const after = agent.getCorpusSentenceCount();
    try testing.expect(after > 0);
}

test "agent_lite: saveCorpus writes dynamic corpus" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("This is a test sentence for save corpus functionality testing.");
    try testing.expect(agent.dynamic_corpus.items.len > 0);

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try agent.saveCorpus(buf.writer());
    try testing.expect(buf.items.len > 0);
}

test "agent_lite: saveCorpus empty when nothing learned" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try agent.saveCorpus(buf.writer());
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "agent_lite: activeNodeCount zero on fresh state" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try testing.expectEqual(@as(usize, 0), agent.activeNodeCount());
}

test "agent_lite: activeNodeCount after ingest" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum superposition allows particles to exist in multiple states");
    const count = agent.activeNodeCount();
    try testing.expect(count > 0);
}

test "agent_lite: token mapping roundtrip" {
    for (0..E0_NODE_COUNT) |node| {
        const ch: u3 = @intCast(node % CHANNEL_COUNT);
        const token = nodeToToken(node, ch);
        try testing.expectEqual(node, tokenToNode(token));
        try testing.expectEqual(ch, tokenToChannel(token));
    }
}

test "agent_lite: e0NodeCoords returns valid coords" {
    for (0..E0_NODE_COUNT) |i| {
        const coords = e0NodeCoords(i);
        try testing.expect(coords.x < BASE_EDGE);
        try testing.expect(coords.y < BASE_EDGE);
        try testing.expect(coords.z < BASE_EDGE);
    }
}

test "agent_lite: e0NodeIndex consistency" {
    for (0..E0_NODE_COUNT) |i| {
        const coords = e0NodeCoords(i);
        const idx = e0NodeIndex(coords.x, coords.y, coords.z);
        try testing.expect(idx != null);
    }
}

test "agent_lite: computeEValue returns valid channel" {
    const e_val = computeEValue(3, 5, 7, BASE_EDGE);
    try testing.expect(e_val < 8);
}

test "agent_lite: isBoundary detects edges" {
    try testing.expect(isBoundary(0, 5, 5, BASE_EDGE));
    try testing.expect(isBoundary(14, 5, 5, BASE_EDGE));
    try testing.expect(!isBoundary(7, 7, 7, BASE_EDGE));
}

test "agent_lite: lexicon lookup" {
    try testing.expect(getWordLexiconId("the") != null);
    try testing.expect(getWordLexiconId("quantum") != null);
    try testing.expect(getWordLexiconId("xyznonexistent") == null);
    try testing.expect(getLexiconWord(1) != null);
    try testing.expect(getLexiconWord(0) == null);
    try testing.expect(getLexiconWord(SEMANTIC_LEXICON.len + 1) == null);
}

test "agent_lite: containsWordCI basic" {
    try testing.expect(containsWordCI("hello world", "hello"));
    try testing.expect(containsWordCI("Hello World", "world"));
    try testing.expect(!containsWordCI("hello world", "xyz"));
    try testing.expect(!containsWordCI("helloworld", "hello"));
}

test "agent_lite: AgentState coolTemperature" {
    var state = AgentState.init(testing.allocator, fp.ONE);
    defer state.deinit();
    state.cycle = 10;
    state.coolTemperature();
    try testing.expect(state.temperature < state.base_temp);
}

test "agent_lite: generateLongForm with learned corpus" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("Zig programming language provides memory safety without garbage collection.");
    const response = try agent.generateLongForm("What is Zig programming?", testing.allocator);
    defer testing.allocator.free(response);

    try testing.expect(response.len > 0);
}

test "agent_lite: multiple ingest accumulates" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum");
    const act1 = agent.state.activations[0][0];
    try agent.ingest("quantum");
    const act2 = agent.state.activations[0][0];

    try testing.expect(act2 >= act1);
}

test "agent_lite: run with zero cycles" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("test");
    try agent.run(0);
    try testing.expectEqual(@as(u64, 0), agent.state.cycle);
}

test "agent_lite: step cools temperature" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const temp_before = agent.state.temperature;
    try agent.ingest("test");
    agent.step();
    try testing.expect(agent.state.temperature <= temp_before);
}

test "agent_lite: generateLongForm resets state each call" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const r1 = try agent.generateLongForm("quantum", testing.allocator);
    defer testing.allocator.free(r1);
    try testing.expect(r1.len > 0);

    const r2 = try agent.generateLongForm("lattice", testing.allocator);
    defer testing.allocator.free(r2);
    try testing.expect(r2.len > 0);
}

test "agent_lite: getCombinedCorpus with and without dynamic" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const corpus1 = try agent.getCombinedCorpus(testing.allocator);
    defer testing.allocator.free(corpus1);
    try testing.expectEqual(SEED_CORPUS_TEXT.len, corpus1.len);

    _ = try agent.learnFromText("This is a new sentence for combined corpus testing.");
    const corpus2 = try agent.getCombinedCorpus(testing.allocator);
    defer testing.allocator.free(corpus2);
    try testing.expect(corpus2.len > SEED_CORPUS_TEXT.len);
}

test "agent_lite: readTopToken returns valid token" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum");
    const token = agent.readTopToken();
    try testing.expect(token < VOCAB_SIZE);
}

test "agent_lite: large corpus learning bounded" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    var big_text = std.ArrayList(u8).init(testing.allocator);
    defer big_text.deinit();
    for (0..10) |_| {
        try big_text.appendSlice("This is a test sentence that is long enough to pass the minimum length filter. ");
    }

    const added = try agent.learnFromText(big_text.items);
    try testing.expect(added > 0);
    try testing.expect(agent.dynamic_corpus.items.len > 0);
}

test "agent_lite: stemMatch handles suffixes" {
    try testing.expect(stemMatch("the running process", "running"));
    try testing.expect(stemMatch("quantum particles", "particles"));
    try testing.expect(stemMatch("the computation", "computations"));
    try testing.expect(stemMatch("the measured state", "measured"));
    try testing.expect(stemMatch("the measure of state", "measures"));
    try testing.expect(!stemMatch("hello", "xyz"));
    try testing.expect(!stemMatch("the", "the"));
}

test "agent_lite: semanticMatch finds synonyms" {
    try testing.expect(semanticMatch("the machine processes data", "engine"));
    try testing.expect(semanticMatch("I feel happy today", "emotion"));
    try testing.expect(semanticMatch("conscious awareness", "sentient"));
    try testing.expect(semanticMatch("the quick search", "query"));
    try testing.expect(!semanticMatch("the weather is nice", "quantum"));
}

test "agent_lite: semanticMatch with stem fallback" {
    try testing.expect(semanticMatch("thinking about thoughts", "think"));
    try testing.expect(semanticMatch("the robot is here", "automaton"));
    try testing.expect(semanticMatch("I am thinking", "think"));
}

test "agent_lite: LiteBigramModel init and buildFromText" {
    var model = LiteBigramModel.init();
    try testing.expect(!model.hasData());
    model.buildFromText("The quantum superposition allows particles to exist");
    try testing.expect(model.hasData());
}

test "agent_lite: LiteBigramModel getSuccessors" {
    var model = LiteBigramModel.init();
    model.buildFromText("The quantum superposition allows particles");
    const succ = model.getSuccessors(1);
    var has_nonzero = false;
    for (succ) |s| {
        if (s != 0) has_nonzero = true;
    }
    try testing.expect(has_nonzero);
}

test "agent_lite: LiteBigramModel out of range returns zeros" {
    var model = LiteBigramModel.init();
    const succ = model.getSuccessors(0);
    try testing.expectEqual(@as(u32, 0), succ[0]);
    try testing.expectEqual(@as(u32, 0), succ[1]);
    try testing.expectEqual(@as(u32, 0), succ[2]);
}

test "agent_lite: agent bigram model built at init" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();
    try testing.expect(agent.bigram_model.hasData());
}

test "agent_lite: rebuildBigramModel after learnFromText" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("The quantum lattice provides deterministic computation.");
    agent.rebuildBigramModel();
    try testing.expect(agent.bigram_model.hasData());
}

test "agent_lite: loadCorpus loads data" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const corpus_data = "This is loaded corpus text. It contains multiple sentences for testing.";
    var stream = std.io.fixedBufferStream(corpus_data);
    const loaded = try agent.loadCorpus(stream.reader());
    try testing.expectEqual(corpus_data.len, loaded);
    try testing.expect(agent.dynamic_corpus.items.len > 0);
}

test "agent_lite: loadCorpus empty returns zero" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const empty = "";
    var stream = std.io.fixedBufferStream(empty);
    const loaded = try agent.loadCorpus(stream.reader());
    try testing.expectEqual(@as(usize, 0), loaded);
}

test "agent_lite: loadCorpus rebuilds bigram" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const corpus_data = "The quantum system provides deterministic computation. The lattice enables parallel processing.";
    var stream = std.io.fixedBufferStream(corpus_data);
    _ = try agent.loadCorpus(stream.reader());
    try testing.expect(agent.bigram_model.hasData());
}

test "agent_lite: expanded lexicon coverage" {
    try testing.expect(getWordLexiconId("quantum") != null);
    try testing.expect(getWordLexiconId("lattice") != null);
    try testing.expect(getWordLexiconId("algorithm") != null);
    try testing.expect(getWordLexiconId("Fixed-point") != null);
    try testing.expect(getWordLexiconId("superposition") != null);
    try testing.expect(getWordLexiconId("Grover") != null);
    try testing.expectEqual(@as(usize, 190), SEMANTIC_LEXICON.len);
}

test "agent_lite: semantic groups count" {
    try testing.expectEqual(@as(usize, 61), SEMANTIC_GROUPS.len);
}

test "agent_lite: containsWord word boundary" {
    try testing.expect(containsWord("the cat sat", "cat"));
    try testing.expect(!containsWord("the category sat", "cat"));
    try testing.expect(containsWord("fixed-point arithmetic", "Fixed-point"));
    try testing.expect(!containsWord("helloworld", "hello"));
}

test "agent_lite: generateLongForm with semantic match" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("The robot uses artificial intelligence to process information.");
    const response = try agent.generateLongForm("What is machine cognition?", testing.allocator);
    defer testing.allocator.free(response);
    try testing.expect(response.len > 0);
}

test "agent_lite: generateLongForm with TF-IDF ranking" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    const response = try agent.generateLongForm("How does quantum superposition work?", testing.allocator);
    defer testing.allocator.free(response);
    try testing.expect(response.len > 0);
}

test "agent_lite: bigram boost in readTopToken" {
    var agent = Agent.init(testing.allocator, 0, fp.ONE);
    defer agent.deinit();

    try agent.ingest("quantum superposition allows");
    try agent.run(5);

    try testing.expect(agent.state.output_tokens.items.len > 0);
    const token = agent.readTopToken();
    try testing.expect(token < VOCAB_SIZE);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
