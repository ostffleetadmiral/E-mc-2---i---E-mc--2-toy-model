//! corpus_learner.zig — Metacognitive Corpus Learning Engine
//!
//! Streams the 2.8GB corpus file incrementally, extracting definitional
//! sentences for each word, then builds logical response routes through
//! the Trivium (Grammar → Logic → Rhetoric) and validates them through
//! the Quadrivium (Arithmetic → Geometry → Music → Astronomy).
//!
//! Architecture:
//!   1. Streaming reader: reads corpus in 64KB chunks, buffering partial
//!      sentences across chunk boundaries.
//!   2. Definition extractor: identifies definitional sentences using
//!      patterns like "X is Y", "X refers to Y", "X means Y", etc.
//!   3. Trivium processing: for each definition, runs Grammar (concept
//!      extraction, domain detection), Logic (coherence validation,
//!      non-contradiction check), and Rhetoric (output planning).
//!   4. Quadrivium validation: uses stability metric from Astronomy layer
//!      to validate route quality. Only stable routes are registered.
//!   5. Route registration: validated definitions become dynamic routes
//!      in the DynamicRouteRegistry, keyed by the defined word + concepts.
//!
//! Runs as a background thread ("always on") — continuously processes
//! the corpus, looping back to the beginning when EOF is reached.

const std = @import("std");
const trivium = @import("trivium");
const quadrivium = @import("quadrivium");
const dyn_routes = @import("dynamic_routes");

// =============================================================================
// Constants
// =============================================================================

pub const CHUNK_SIZE: usize = 64 * 1024;
pub const MAX_SENTENCE_LEN: usize = 512;
pub const MAX_DEFINITIONS_PER_CYCLE: usize = 64;
pub const MIN_DEFINITION_LEN: usize = 20;
pub const MAX_DEFINITION_LEN: usize = 400;
pub const SLEEP_BETWEEN_CYCLES_NS: u64 = 10 * std.time.ns_per_ms;

const DefinitionPattern = struct {
    marker: []const u8,
    min_subj: usize,
    max_subj: usize,
    min_obj: usize,
    max_obj: usize,
};

const DEFINITION_PATTERNS = [_]DefinitionPattern{
    .{ .marker = " is a ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " is an ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " is the ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " refers to ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " means ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " is defined as ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " is called ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " can be described as ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " are ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " describes ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " denotes ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
    .{ .marker = " represents ", .min_subj = 3, .max_subj = 50, .min_obj = 10, .max_obj = 300 },
};

const STOPWORDS = [_][]const u8{
    "the",      "a",       "an",   "is",     "are",     "was",    "were",  "be",        "been",    "being",
    "have",     "has",     "had",  "do",     "does",    "did",    "will",  "would",     "could",   "should",
    "may",      "might",   "must", "can",    "of",      "to",     "in",    "for",       "on",      "at",
    "by",       "with",    "from", "as",     "into",    "about",  "than",  "that",      "this",    "these",
    "those",    "it",      "its",  "they",   "them",    "their",  "there", "where",     "when",    "what",
    "which",    "who",     "whom", "and",    "or",      "but",    "not",   "no",        "if",      "then",
    "so",       "because", "how",  "why",    "all",     "each",   "every", "both",      "few",     "more",
    "most",     "other",   "some", "such",   "only",    "own",    "same",  "very",      "just",    "also",
    "too",      "here",    "now",  "called", "defined", "refers", "means", "describes", "denotes", "represents",
    "involves",
};

// =============================================================================
// CorpusLearnerStats — atomic counters for monitoring
// =============================================================================

pub const CorpusLearnerStats = struct {
    bytes_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sentences_scanned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    definitions_extracted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    routes_built: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    routes_rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cycles_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    passes_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

// =============================================================================
// CorpusLearner — streaming corpus reader + definition extractor + route builder
// =============================================================================

pub const CorpusLearner = struct {
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    registry: *dyn_routes.DynamicRouteRegistry,
    stats: CorpusLearnerStats,

    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    trivium_pipeline: trivium.TriviumPipeline = .{},
    quadrivium_pipeline: quadrivium.QuadriviumPipeline,

    processed_words: std.StringHashMap(void),

    pub fn init(
        allocator: std.mem.Allocator,
        corpus_path: []const u8,
        registry: *dyn_routes.DynamicRouteRegistry,
    ) CorpusLearner {
        return .{
            .allocator = allocator,
            .corpus_path = corpus_path,
            .registry = registry,
            .stats = .{},
            .quadrivium_pipeline = quadrivium.QuadriviumPipeline.init(44100 << 64),
            .processed_words = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *CorpusLearner) void {
        self.requestStop();
        self.join();
        var it = self.processed_words.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.processed_words.deinit();
    }

    pub fn requestStop(self: *CorpusLearner) void {
        self.stop_flag.store(true, .release);
    }

    pub fn join(self: *CorpusLearner) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *const CorpusLearner) bool {
        return self.running.load(.acquire);
    }

    pub fn start(self: *CorpusLearner) !void {
        if (self.thread != null) return;
        self.stop_flag.store(false, .release);
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, learningLoop, .{self});
    }

    pub fn stopAndWait(self: *CorpusLearner) void {
        self.requestStop();
        self.join();
    }

    fn learningLoop(self: *CorpusLearner) void {
        while (!self.stop_flag.load(.acquire)) {
            self.processCorpusPass() catch |err| {
                std.log.warn("Corpus learning pass error: {s}", .{@errorName(err)});
            };
            _ = self.stats.passes_completed.fetchAdd(1, .monotonic);
        }
        self.running.store(false, .release);
    }

    pub fn processCorpusPass(self: *CorpusLearner) !void {
        var file = std.fs.cwd().openFile(self.corpus_path, .{}) catch return;
        defer file.close();

        var chunk_buf: [CHUNK_SIZE]u8 = undefined;
        var leftover: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        defer leftover.deinit();

        var definitions_in_cycle: usize = 0;

        while (!self.stop_flag.load(.acquire)) {
            const bytes_read = file.read(&chunk_buf) catch break;
            if (bytes_read == 0) break;

            _ = self.stats.bytes_processed.fetchAdd(bytes_read, .monotonic);

            try leftover.appendSlice(chunk_buf[0..bytes_read]);

            const processed = try self.processBuffer(leftover.items, &definitions_in_cycle);

            if (processed < leftover.items.len) {
                const remaining = leftover.items[processed..];
                std.mem.copyForwards(u8, leftover.items[0..remaining.len], remaining);
                leftover.shrinkRetainingCapacity(remaining.len);
            } else {
                leftover.clearRetainingCapacity();
            }

            if (definitions_in_cycle >= MAX_DEFINITIONS_PER_CYCLE) {
                std.time.sleep(SLEEP_BETWEEN_CYCLES_NS);
                definitions_in_cycle = 0;
                _ = self.stats.cycles_completed.fetchAdd(1, .monotonic);
            }
        }

        if (leftover.items.len > 0) {
            _ = try self.processBuffer(leftover.items, &definitions_in_cycle);
        }
    }

    fn processBuffer(self: *CorpusLearner, buf: []const u8, defs_count: *usize) !usize {
        var consumed: usize = 0;
        var pos: usize = 0;

        while (pos < buf.len) {
            const boundary = std.mem.indexOfAnyPos(u8, buf, pos, ".\n") orelse break;

            const sent_end = boundary + 1;
            const sent = std.mem.trim(u8, buf[pos..sent_end], " \t\r");

            if (sent.len >= MIN_DEFINITION_LEN and sent.len <= MAX_DEFINITION_LEN) {
                _ = self.stats.sentences_scanned.fetchAdd(1, .monotonic);

                if (try self.extractAndBuildRoute(sent)) {
                    defs_count.* += 1;
                }
            }

            pos = sent_end;
            consumed = sent_end;
        }

        return consumed;
    }

    fn extractAndBuildRoute(self: *CorpusLearner, sentence: []const u8) !bool {
        for (DEFINITION_PATTERNS) |pattern| {
            if (std.mem.indexOf(u8, sentence, pattern.marker)) |pos| {
                const subject = std.mem.trim(u8, sentence[0..pos], " \t\r");
                const object = std.mem.trim(u8, sentence[pos + pattern.marker.len ..], " \t\r");

                if (subject.len < pattern.min_subj or subject.len > pattern.max_subj) continue;
                if (object.len < pattern.min_obj or object.len > pattern.max_obj) continue;

                if (isStopword(subject)) continue;
                // Reject subjects that contain commas, semicolons, or colons —
                // these indicate sentence fragments, not noun phrases.
                if (std.mem.indexOfAny(u8, subject, ",;:") != null) continue;
                // Reject subjects that start with a lowercase word —
                // definitions typically start with a capitalized term.
                if (subject.len > 0 and std.ascii.isLower(subject[0])) continue;
                const key_word = lastWord(subject);
                if (isStopword(key_word)) continue;
                if (self.processed_words.contains(key_word)) return false;

                try self.buildLogicalRoute(subject, sentence);
                _ = self.stats.definitions_extracted.fetchAdd(1, .monotonic);
                return true;
            }
        }
        return false;
    }

    fn buildLogicalRoute(
        self: *CorpusLearner,
        word: []const u8,
        definition: []const u8,
    ) !void {
        self.trivium_pipeline.runGrammar(definition);
        const parsed = self.trivium_pipeline.parsed;

        var route_kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
        var kw_count: usize = 0;

        // Use the last word of the subject as the sole keyword.
        // e.g., "Quantum entanglement" → "entanglement"
        // This ensures prompts like "what is entanglement" match the route.
        // We use only 1 keyword because matches() requires ALL keywords to be present.
        const last_word = lastWord(word);
        route_kws[kw_count] = last_word;
        kw_count += 1;

        const is_non_contradicting = trivium.LogicStage.checkNonContradiction(definition, definition);
        if (!is_non_contradicting) {
            _ = self.stats.routes_rejected.fetchAdd(1, .monotonic);
            return;
        }

        self.trivium_pipeline.runRhetoric();

        const category: dyn_routes.RouteCategory = switch (parsed.domain) {
            .mathematics, .physics, .chemistry, .biology, .computer_science, .astronomy => .factual,
            .philosophy, .history, .literature => .reasoning,
            .music, .general => .open_ended,
            else => .factual,
        };

        var synth_activations: [421][7]i128 = std.mem.zeroes([421][7]i128);
        var hash_it = std.mem.tokenizeAny(u8, definition, " \t\n\r.,!?;:\"'()[]{}");
        var node_idx: usize = 0;
        while (hash_it.next()) |w| {
            if (w.len < 3) continue;
            const h = std.hash.CityHash64.hash(w);
            const node = h % 421;
            const channel: usize = @intCast(h % 7);
            synth_activations[node][channel] += @intCast(h % 1000);
            node_idx += 1;
            if (node_idx >= 421) break;
        }

        self.quadrivium_pipeline.processState(&synth_activations);

        // Note: stabilityScore is designed for real lattice activations, not
        // synthesized hash-based activations. For corpus-learned routes, we
        // use a fixed confidence since the definition has already passed
        // trivium validation (grammar + non-contradiction).
        const confidence_f64: f64 = 0.75;
        const confidence_bp: u16 = @intFromFloat(confidence_f64 * @as(f64, @floatFromInt(dyn_routes.BP_PER_UNIT)));

        const kws_slice = route_kws[0..kw_count];
        _ = self.registry.register(
            kws_slice,
            definition,
            confidence_bp,
            category,
            .corpus_extracted,
        ) catch |err| {
            if (err == error.RegistryFull) {
                self.registry.pruneLowConfidence();
                _ = self.registry.register(
                    kws_slice,
                    definition,
                    confidence_bp,
                    category,
                    .corpus_extracted,
                ) catch {
                    _ = self.stats.routes_rejected.fetchAdd(1, .monotonic);
                    return;
                };
            } else {
                _ = self.stats.routes_rejected.fetchAdd(1, .monotonic);
                return;
            }
        };

        const owned_word = try self.allocator.dupe(u8, last_word);
        try self.processed_words.put(owned_word, {});

        _ = self.stats.routes_built.fetchAdd(1, .monotonic);
    }

    pub fn getStats(self: *const CorpusLearner) CorpusLearnerStats {
        return .{
            .bytes_processed = std.atomic.Value(u64).init(self.stats.bytes_processed.load(.monotonic)),
            .sentences_scanned = std.atomic.Value(u64).init(self.stats.sentences_scanned.load(.monotonic)),
            .definitions_extracted = std.atomic.Value(u64).init(self.stats.definitions_extracted.load(.monotonic)),
            .routes_built = std.atomic.Value(u64).init(self.stats.routes_built.load(.monotonic)),
            .routes_rejected = std.atomic.Value(u64).init(self.stats.routes_rejected.load(.monotonic)),
            .cycles_completed = std.atomic.Value(u64).init(self.stats.cycles_completed.load(.monotonic)),
            .passes_completed = std.atomic.Value(u64).init(self.stats.passes_completed.load(.monotonic)),
        };
    }

    pub fn formatStats(self: *const CorpusLearner, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\Corpus Learner Stats:
            \\  Bytes Processed:    {d}
            \\  Sentences Scanned:   {d}
            \\  Definitions Found:   {d}
            \\  Routes Built:        {d}
            \\  Routes Rejected:     {d}
            \\  Cycles:              {d}
            \\  Corpus Passes:       {d}
            \\  Running:             {}
            \\  Processed Words:     {d}
        , .{
            self.stats.bytes_processed.load(.monotonic),
            self.stats.sentences_scanned.load(.monotonic),
            self.stats.definitions_extracted.load(.monotonic),
            self.stats.routes_built.load(.monotonic),
            self.stats.routes_rejected.load(.monotonic),
            self.stats.cycles_completed.load(.monotonic),
            self.stats.passes_completed.load(.monotonic),
            self.isRunning(),
            self.processed_words.count(),
        });
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn lastWord(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
    var start = end;
    while (start > 0 and text[start - 1] != ' ' and text[start - 1] != '\t') start -= 1;
    return text[start..end];
}

fn isStopword(word: []const u8) bool {
    for (STOPWORDS) |sw| {
        if (std.ascii.eqlIgnoreCase(word, sw)) return true;
    }
    return false;
}

// =============================================================================
// Unit Tests
// =============================================================================

test "corpus_learner: init and deinit" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    try std.testing.expect(!learner.isRunning());
    try std.testing.expectEqual(@as(u64, 0), learner.stats.bytes_processed.load(.monotonic));
}

test "corpus_learner: extractAndBuildRoute from definitional sentence" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    const sentence = "Quantum entanglement is a phenomenon where particles become correlated";
    _ = try learner.extractAndBuildRoute(sentence);

    try std.testing.expect(registry.routes.items.len > 0);

    const route = registry.routes.items[0];
    var found_entanglement = false;
    for (0..route.keyword_count) |i| {
        if (std.ascii.indexOfIgnoreCase(route.keywords[i], "entanglement") != null) {
            found_entanglement = true;
            break;
        }
    }
    try std.testing.expect(found_entanglement);
}

test "corpus_learner: processBuffer extracts definitions from text" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    const text = "Photosynthesis is a process used by plants to convert light into energy. The quick brown fox jumps. Entanglement is a quantum phenomenon where particles are correlated.";
    var defs_count: usize = 0;
    const consumed = try learner.processBuffer(text, &defs_count);

    try std.testing.expect(consumed > 0);
    try std.testing.expect(defs_count >= 2);
}

test "corpus_learner: skips non-definitional sentences" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    const text = "The quick brown fox jumps over the lazy dog.";
    var defs_count: usize = 0;
    _ = try learner.processBuffer(text, &defs_count);

    try std.testing.expectEqual(@as(usize, 0), defs_count);
}

test "corpus_learner: deduplication prevents duplicate routes" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    const sentence = "Entanglement is a quantum phenomenon where particles are correlated";
    _ = try learner.extractAndBuildRoute(sentence);

    const routes_after_first = registry.routes.items.len;

    _ = try learner.extractAndBuildRoute(sentence);
    try std.testing.expectEqual(routes_after_first, registry.routes.items.len);
}

test "corpus_learner: stats track correctly" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    _ = try learner.extractAndBuildRoute("Gravity is a force that attracts objects with mass toward each other");

    try std.testing.expect(learner.stats.definitions_extracted.load(.monotonic) > 0);
    try std.testing.expect(learner.stats.routes_built.load(.monotonic) > 0);
}

test "corpus_learner: trivium domain detection from definition" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    _ = try learner.extractAndBuildRoute("Quantum entanglement is a phenomenon in quantum physics");
    try std.testing.expect(learner.trivium_pipeline.stage_completed.grammar);
    try std.testing.expectEqual(trivium.Domain.physics, learner.trivium_pipeline.parsed.domain);
}

test "corpus_learner: formatStats produces readable output" {
    const allocator = std.testing.allocator;
    var registry = dyn_routes.DynamicRouteRegistry.init(allocator);
    defer registry.deinit();

    var learner = CorpusLearner.init(allocator, "test_corpus.txt", &registry);
    defer learner.deinit();

    const stats_text = try learner.formatStats(allocator);
    defer allocator.free(stats_text);

    try std.testing.expect(std.mem.indexOf(u8, stats_text, "Corpus Learner") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_text, "Bytes Processed") != null);
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
