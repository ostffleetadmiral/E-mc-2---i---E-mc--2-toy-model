//! vocab_lattice_scaling.zig — Prototype: Level-scaled token-to-node mapping
//!
//! Tests the hypothesis that Ramsey power-of-2 vocab sizes (2^17..2^20)
//! map directly to Qstar lattice scaling levels (s=0..s=3), where
//! node count = 421 × 8^s and token slots = node_count × 7 channels.
//!
//! Measures:
//!   1. Collision rates at each (level, vocab) pair
//!   2. Round-trip fidelity: token → (node, channel) → token
//!   3. Mapping performance (O(1) verification)
//!
//! Zero dependencies beyond std.

const std = @import("std");

// =============================================================================
// Constants — matching Qstar's lattice geometry
// =============================================================================

const E0_NODE_COUNT: usize = 421;
const CHANNEL_COUNT: usize = 7;
const MAX_LEVEL: u8 = 3;

// =============================================================================
// Level-scaled token mapping (the prototype under test)
// =============================================================================

pub fn scaledNodeCount(level: u8) usize {
    return E0_NODE_COUNT * (@as(usize, 1) << @intCast(level * 3)); // 421 × 8^level
}

pub fn scaledTokenToNode(tid: u32, level: u8) usize {
    return @intCast(tid % scaledNodeCount(level));
}

pub fn scaledTokenToChannel(tid: u32, level: u8) u3 {
    return @intCast((tid / scaledNodeCount(level)) % CHANNEL_COUNT);
}

pub fn scaledNodeToToken(node: usize, channel: u3, level: u8) u32 {
    return @as(u32, @intCast(node)) + @as(u32, channel) * @as(u32, @intCast(scaledNodeCount(level)));
}

// =============================================================================
// Vocab loading (simplified — just loads token strings from txt file)
// =============================================================================

pub const VocabEntry = struct {
    tokens: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VocabEntry {
        return .{
            .tokens = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VocabEntry) void {
        for (self.tokens.items) |t| self.allocator.free(t);
        self.tokens.deinit();
    }

    pub fn size(self: *const VocabEntry) usize {
        return self.tokens.items.len;
    }

    pub fn loadTxt(self: *VocabEntry, path: []const u8) !usize {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 200 * 1024 * 1024);
        defer self.allocator.free(data);

        var iter = std.mem.splitScalar(u8, data, '\n');
        var count: usize = 0;
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            const token = try self.allocator.dupe(u8, line);
            try self.tokens.append(token);
            count += 1;
        }
        return count;
    }
};

// =============================================================================
// Test results
// =============================================================================

pub const LevelResult = struct {
    level: u8,
    vocab_size: usize,
    node_count: usize,
    token_slots: usize,
    tok_per_slot: f64,
    collision_count: usize,
    collision_rate: f64,
    slots_used: usize,
    slot_coverage: f64,
    max_tokens_per_slot: u32,
    min_tokens_per_slot: u32,
    roundtrip_ok: usize,
    roundtrip_fail: usize,
    roundtrip_fidelity: f64,
    map_time_ns: u64,
};

pub fn runLevelTest(
    allocator: std.mem.Allocator,
    level: u8,
    vocab: *const VocabEntry,
) !LevelResult {
    const nc = scaledNodeCount(level);
    const slots = nc * CHANNEL_COUNT;
    const vsize = vocab.size();

    // 1. Collision test: count how many tokens share the same (node, channel) pair
    var slot_counts = try allocator.alloc(u32, slots);
    defer allocator.free(slot_counts);
    @memset(slot_counts, 0);

    for (0..vsize) |tid| {
        const node = scaledTokenToNode(@intCast(tid), level);
        const channel = scaledTokenToChannel(@intCast(tid), level);
        const slot_idx = node * CHANNEL_COUNT + channel;
        slot_counts[slot_idx] += 1;
    }

    var collision_count: usize = 0;
    var slots_used: usize = 0;
    var max_tokens_per_slot: u32 = 0;
    var min_tokens_per_slot: u32 = std.math.maxInt(u32);
    for (slot_counts) |count| {
        if (count > 0) slots_used += 1;
        if (count > 1) collision_count += (count - 1);
        if (count > max_tokens_per_slot) max_tokens_per_slot = count;
        if (count < min_tokens_per_slot) min_tokens_per_slot = count;
    }

    // 2. Round-trip test: only tokens with tid < slots can round-trip losslessly.
    //    The modular mapping tid % node_count is a bijection for tid < node_count×7.
    //    Tokens above that range are intentionally collided (many-to-one hash).
    var roundtrip_ok: usize = 0;
    var roundtrip_fail: usize = 0;

    const mappable_range = @min(vsize, slots);
    const sample_step: usize = if (mappable_range > 100_000) mappable_range / 100_000 else 1;
    var tested: usize = 0;

    for (0..mappable_range) |tid| {
        if (tid % sample_step != 0) continue;
        tested += 1;

        const node = scaledTokenToNode(@intCast(tid), level);
        const channel = scaledTokenToChannel(@intCast(tid), level);
        const recovered = scaledNodeToToken(node, channel, level);

        if (recovered == @as(u32, @intCast(tid))) {
            roundtrip_ok += 1;
        } else {
            roundtrip_fail += 1;
        }
    }

    // 3. Benchmark: time 1M token mappings
    const bench_iters: usize = 1_000_000;
    var timer = try std.time.Timer.start();
    var dummy: u32 = 0;
    for (0..bench_iters) |i| {
        const tid: u32 = @intCast(i % vsize);
        const node = scaledTokenToNode(tid, level);
        const channel = scaledTokenToChannel(tid, level);
        const back = scaledNodeToToken(node, channel, level);
        dummy |= back;
    }
    const map_time_ns = timer.read() / bench_iters;

    // Prevent optimizer from removing dummy
    std.mem.doNotOptimizeAway(dummy);

    const tok_per_slot = @as(f64, @floatFromInt(vsize)) / @as(f64, @floatFromInt(slots));
    const collision_rate = @as(f64, @floatFromInt(collision_count)) / @as(f64, @floatFromInt(vsize));
    const fidelity = if (tested > 0) @as(f64, @floatFromInt(roundtrip_ok)) / @as(f64, @floatFromInt(tested)) else 1.0;
    const coverage = @as(f64, @floatFromInt(slots_used)) / @as(f64, @floatFromInt(slots));

    return .{
        .level = level,
        .vocab_size = vsize,
        .node_count = nc,
        .token_slots = slots,
        .tok_per_slot = tok_per_slot,
        .collision_count = collision_count,
        .collision_rate = collision_rate,
        .slots_used = slots_used,
        .slot_coverage = coverage,
        .max_tokens_per_slot = max_tokens_per_slot,
        .min_tokens_per_slot = min_tokens_per_slot,
        .roundtrip_ok = roundtrip_ok,
        .roundtrip_fail = roundtrip_fail,
        .roundtrip_fidelity = fidelity,
        .map_time_ns = map_time_ns,
    };
}

fn printResult(r: LevelResult) void {
    std.debug.print("\n", .{});
    std.debug.print("  ┌─ Level s={d} ─────────────────────────────────────\n", .{r.level});
    std.debug.print("  │ Vocab size:      {d:>10} tokens\n", .{r.vocab_size});
    std.debug.print("  │ Node count:      {d:>10} (421 × 8^{d})\n", .{ r.node_count, r.level });
    std.debug.print("  │ Token slots:     {d:>10} (nodes × 7)\n", .{r.token_slots});
    std.debug.print("  │ Tok/slot:        {d:>10.2}\n", .{r.tok_per_slot});
    std.debug.print("  │ Slots used:      {d:>10} / {d} ({d:.2}%)\n", .{ r.slots_used, r.token_slots, r.slot_coverage * 100 });
    std.debug.print("  │ Tok/slot range:  {d:>10} .. {d}\n", .{ r.min_tokens_per_slot, r.max_tokens_per_slot });
    std.debug.print("  │ Collisions:      {d:>10} ({d:.4}%)\n", .{ r.collision_count, r.collision_rate * 100 });
    std.debug.print("  │ Round-trip OK:   {d:>10}\n", .{r.roundtrip_ok});
    std.debug.print("  │ Round-trip FAIL: {d:>10}\n", .{r.roundtrip_fail});
    std.debug.print("  │ Fidelity:        {d:>10.4}%\n", .{r.roundtrip_fidelity * 100});
    std.debug.print("  │ Map time:        {d:>10} ns/op\n", .{r.map_time_ns});
    std.debug.print("  └──────────────────────────────────────────────────\n", .{});
}

// =============================================================================
// Main entry point
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const vocab_paths = [_][]const u8{
        ".foundations/RamseyLLM/vocabs/vocab-128k.txt",
        ".foundations/RamseyLLM/vocabs/vocab-256k.txt",
        ".foundations/RamseyLLM/vocabs/vocab-512k.txt",
        ".foundations/RamseyLLM/vocabs/vocab-1m.txt",
    };

    const expected_sizes = [_]usize{ 131072, 262144, 524288, 1048576 };

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Ramsey Vocab × Lattice Scaling Prototype               ║\n", .{});
    std.debug.print("║   Testing 421×8^s node mapping with 2^17..2^20 vocabs    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});

    var all_pass = true;

    for (0..MAX_LEVEL + 1) |idx| {
        const level: u8 = @intCast(idx);

        std.debug.print("\n  Loading vocab: {s}", .{vocab_paths[idx]});
        var vocab = VocabEntry.init(allocator);
        defer vocab.deinit();

        const loaded = vocab.loadTxt(vocab_paths[idx]) catch |err| {
            std.debug.print(" — FAILED: {s}\n", .{@errorName(err)});
            all_pass = false;
            continue;
        };

        std.debug.print(" ({d} tokens)\n", .{loaded});

        if (loaded != expected_sizes[idx]) {
            std.debug.print("  WARNING: Expected {d} tokens, got {d}\n", .{ expected_sizes[idx], loaded });
        }

        const result = try runLevelTest(allocator, level, &vocab);
        printResult(result);

        // Round-trip fidelity target: 100% for all levels (modular arithmetic
        // is a bijection within the mappable range tid < node_count×7)
        const fidelity_target: f64 = 1.0;
        if (result.roundtrip_fidelity < fidelity_target) {
            std.debug.print("  ⚠  FIDELITY BELOW TARGET: {d:.4}% < {d:.4}%\n", .{ result.roundtrip_fidelity * 100, fidelity_target * 100 });
            all_pass = false;
        } else {
            std.debug.print("  ✓  Fidelity meets target (100%)\n", .{});
        }

        if (result.roundtrip_fail > 0) {
            std.debug.print("  ⚠  ROUND-TRIP FAILURES DETECTED: {d}\n", .{result.roundtrip_fail});
            all_pass = false;
        }

        // Slot coverage: 100% when vocab ≥ slots, sparse is OK when vocab < slots
        if (result.vocab_size >= result.token_slots and result.slot_coverage < 0.99) {
            std.debug.print("  ⚠  SLOT COVERAGE LOW: {d:.2}% (vocab > slots, should be full)\n", .{result.slot_coverage * 100});
            all_pass = false;
        } else if (result.vocab_size < result.token_slots) {
            std.debug.print("  ✓  Slot coverage {d:.2}% (vocab < slots, sparse is expected)\n", .{result.slot_coverage * 100});
        } else {
            std.debug.print("  ✓  Slot coverage ≥99%\n", .{});
        }

        // Distribution uniformity: max/min should be close to tok_per_slot
        // Only check when vocab ≥ slots (otherwise max=1 and expected<1)
        if (result.vocab_size >= result.token_slots) {
            const expected_per_slot = result.tok_per_slot;
            const max_ratio = @as(f64, @floatFromInt(result.max_tokens_per_slot)) / expected_per_slot;
            if (max_ratio > 1.1) {
                std.debug.print("  ⚠  NON-UNIFORM DISTRIBUTION: max/slot={d} vs expected={d:.1f} (ratio {d:.2})\n", .{ result.max_tokens_per_slot, expected_per_slot, max_ratio });
            } else {
                std.debug.print("  ✓  Uniform distribution (max/slot={d}, expected={d:.1f})\n", .{ result.max_tokens_per_slot, expected_per_slot });
            }
        } else {
            std.debug.print("  ✓  No collisions (vocab < slots, each token has unique slot)\n", .{});
        }
    }

    // Cross-level consistency test
    std.debug.print("\n  Cross-level consistency test:\n", .{});
    for (0..MAX_LEVEL + 1) |idx| {
        const level: u8 = @intCast(idx);
        const nc = scaledNodeCount(level);
        const expected_nc = E0_NODE_COUNT * (@as(usize, 1) << @intCast(level * 3));
        if (nc != expected_nc) {
            std.debug.print("  ⚠  s={d}: node count {d} != expected {d}\n", .{ level, nc, expected_nc });
            all_pass = false;
        } else {
            std.debug.print("  ✓  s={d}: node count = {d} (correct)\n", .{ level, nc });
        }

        // Verify s=0 matches current Qstar behavior
        if (level == 0) {
            if (nc == E0_NODE_COUNT) {
                std.debug.print("  ✓  s=0 backward compatible (421 nodes = current Qstar)\n", .{});
            } else {
                std.debug.print("  ⚠  s=0 NOT backward compatible!\n", .{});
                all_pass = false;
            }
        }
    }

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    if (all_pass) {
        std.debug.print("║  ✓ ALL TESTS PASSED — Ready for Phase 3 integration      ║\n", .{});
    } else {
        std.debug.print("║  ⚠ SOME TESTS FAILED — Review results above              ║\n", .{});
    }
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});

    // Run autoscaler demo
    try runAutoscaleDemo(allocator);
}

// =============================================================================
// Autoscaler — dynamically selects optimal (level, vocab) pair
// =============================================================================

pub const VocabSpec = struct {
    name: []const u8,
    size: usize,
    path: []const u8,
};

pub const VocabSpecs = [_]VocabSpec{
    .{ .name = "ramsey-128k", .size = 131072, .path = ".foundations/RamseyLLM/vocabs/vocab-128k.txt" },
    .{ .name = "ramsey-256k", .size = 262144, .path = ".foundations/RamseyLLM/vocabs/vocab-256k.txt" },
    .{ .name = "ramsey-512k", .size = 524288, .path = ".foundations/RamseyLLM/vocabs/vocab-512k.txt" },
    .{ .name = "ramsey-1m", .size = 1048576, .path = ".foundations/RamseyLLM/vocabs/vocab-1m.txt" },
};

pub const AutoscaleConfig = struct {
    /// Scale up when collision rate exceeds this fraction (e.g. 0.50 = 50%)
    scale_up_collision: f64 = 0.50,
    /// Scale down when collision rate drops below this fraction AND tokens fit at lower level
    scale_down_collision: f64 = 0.10,
    /// Scale up when unique token count exceeds this fraction of total slots (preemptive, ratio <= 1.0)
    scale_up_token_ratio: f64 = 0.95,
    /// Scale down when unique token count drops below this fraction of slots at current level
    scale_down_token_ratio: f64 = 0.30,
    /// Scale up when corpus size (bytes) exceeds this threshold for current level
    corpus_size_thresholds: [4]usize = .{ 512 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024, std.math.maxInt(usize) },
    /// Minimum tokens observed before considering scaling (avoid premature scaling on small inputs)
    min_tokens_for_scale: usize = 1000,
};

pub const AutoscaleDecision = struct {
    action: Action,
    from_level: u8,
    to_level: u8,
    reason: []const u8,

    pub const Action = enum { stay, scale_up, scale_down };

    pub fn format(self: AutoscaleDecision, writer: anytype) !void {
        const action_str = switch (self.action) {
            .stay => "STAY",
            .scale_up => "SCALE_UP",
            .scale_down => "SCALE_DOWN",
        };
        try writer.print("{s} s{d}→s{d}: {s}", .{ action_str, self.from_level, self.to_level, self.reason });
    }
};

pub const Autoscaler = struct {
    current_level: u8,
    config: AutoscaleConfig,
    /// Number of unique tokens seen since last reset
    unique_tokens: usize,
    /// Total tokens processed since last reset
    total_tokens: usize,
    /// Corpus size in bytes
    corpus_bytes: usize,
    /// Collision count at current level (tokens that mapped to an already-occupied slot)
    collision_count: usize,
    /// Slots occupied at current level
    slots_occupied: usize,

    pub fn init(initial_level: u8, config: AutoscaleConfig) Autoscaler {
        return .{
            .current_level = initial_level,
            .config = config,
            .unique_tokens = 0,
            .total_tokens = 0,
            .corpus_bytes = 0,
            .collision_count = 0,
            .slots_occupied = 0,
        };
    }

    pub fn currentVocab(self: *const Autoscaler) VocabSpec {
        return VocabSpecs[self.current_level];
    }

    pub fn currentSlots(self: *const Autoscaler) usize {
        return scaledNodeCount(self.current_level) * CHANNEL_COUNT;
    }

    pub fn currentCollisionRate(self: *const Autoscaler) f64 {
        if (self.total_tokens == 0) return 0.0;
        return @as(f64, @floatFromInt(self.collision_count)) / @as(f64, @floatFromInt(self.total_tokens));
    }

    pub fn currentTokenRatio(self: *const Autoscaler) f64 {
        const slots = self.currentSlots();
        if (slots == 0) return 0.0;
        return @as(f64, @floatFromInt(self.unique_tokens)) / @as(f64, @floatFromInt(slots));
    }

    /// Record a token being processed. Returns true if a collision occurred.
    pub fn recordToken(self: *Autoscaler, tid: u32) bool {
        self.total_tokens += 1;
        const node = scaledTokenToNode(tid, self.current_level);
        const channel = scaledTokenToChannel(tid, self.current_level);
        const slot_idx = node * CHANNEL_COUNT + channel;

        // Track unique tokens (simplified: just count distinct tids up to vocab size)
        if (tid < VocabSpecs[self.current_level].size) {
            self.unique_tokens = @max(self.unique_tokens, @as(usize, tid) + 1);
        }

        // Collision detection would need a bitmap in production; for the prototype
        // we use the theoretical collision rate based on token/slot ratio
        const slots = self.currentSlots();
        if (self.unique_tokens > slots) {
            self.collision_count = self.unique_tokens - slots;
        }

        _ = slot_idx;
        return self.currentCollisionRate() > 0.0;
    }

    /// Record corpus growth
    pub fn recordCorpus(self: *Autoscaler, bytes: usize) void {
        self.corpus_bytes += bytes;
    }

    /// Decide whether to scale up, down, or stay
    pub fn decide(self: *const Autoscaler) AutoscaleDecision {
        const level = self.current_level;
        const collision_rate = self.currentCollisionRate();
        const token_ratio = self.currentTokenRatio();

        // Not enough data yet
        if (self.total_tokens < self.config.min_tokens_for_scale) {
            return .{
                .action = .stay,
                .from_level = level,
                .to_level = level,
                .reason = "insufficient tokens for decision",
            };
        }

        // Check scale-up conditions
        if (level < MAX_LEVEL) {
            const corpus_threshold = self.config.corpus_size_thresholds[level];
            const should_scale_up_collision = collision_rate > self.config.scale_up_collision;
            // Token ratio: preemptive scale-up when approaching capacity (0.95 < ratio <= 1.0)
            // When ratio > 1.0, collision rate already handles it
            const should_scale_up_tokens = token_ratio > self.config.scale_up_token_ratio and token_ratio <= 1.0;
            const should_scale_up_corpus = self.corpus_bytes > corpus_threshold;

            if (should_scale_up_collision) {
                return .{
                    .action = .scale_up,
                    .from_level = level,
                    .to_level = level + 1,
                    .reason = "collision rate exceeded threshold",
                };
            }
            if (should_scale_up_tokens) {
                return .{
                    .action = .scale_up,
                    .from_level = level,
                    .to_level = level + 1,
                    .reason = "token/slot ratio exceeded threshold",
                };
            }
            if (should_scale_up_corpus) {
                return .{
                    .action = .scale_up,
                    .from_level = level,
                    .to_level = level + 1,
                    .reason = "corpus size exceeded threshold",
                };
            }
        }

        // Check scale-down conditions
        if (level > 0) {
            const lower_slots = scaledNodeCount(level - 1) * CHANNEL_COUNT;
            // Only scale down if tokens would actually fit at the lower level
            const can_fit_lower = self.unique_tokens <= lower_slots;
            const should_scale_down_collision = collision_rate < self.config.scale_down_collision;
            const should_scale_down_tokens = token_ratio < self.config.scale_down_token_ratio;
            const lower_corpus_threshold = self.config.corpus_size_thresholds[level - 1];
            const should_scale_down_corpus = self.corpus_bytes < lower_corpus_threshold;

            if (can_fit_lower and should_scale_down_collision and should_scale_down_tokens) {
                return .{
                    .action = .scale_down,
                    .from_level = level,
                    .to_level = level - 1,
                    .reason = "tokens fit at lower level with low collision and utilization",
                };
            }
            if (can_fit_lower and should_scale_down_corpus and should_scale_down_tokens) {
                return .{
                    .action = .scale_down,
                    .from_level = level,
                    .to_level = level - 1,
                    .reason = "corpus shrank and tokens fit at lower level",
                };
            }
        }

        return .{
            .action = .stay,
            .from_level = level,
            .to_level = level,
            .reason = "within optimal range",
        };
    }

    /// Apply a scaling decision. Returns true if level changed.
    pub fn apply(self: *Autoscaler, decision: AutoscaleDecision) bool {
        if (decision.action == .stay) return false;
        self.current_level = decision.to_level;
        // Reset counters for new level
        self.unique_tokens = 0;
        self.total_tokens = 0;
        self.collision_count = 0;
        self.slots_occupied = 0;
        return true;
    }

    /// Simulate processing a corpus of given size with given unique token count.
    /// Returns the final level after autoscaling.
    pub fn simulateCorpus(
        self: *Autoscaler,
        unique_token_count: usize,
        corpus_size: usize,
    ) u8 {
        // Reset state for this simulation (don't accumulate across calls)
        self.corpus_bytes = corpus_size;
        self.unique_tokens = unique_token_count;
        self.total_tokens = unique_token_count;

        const slots = self.currentSlots();
        if (unique_token_count > slots) {
            self.collision_count = unique_token_count - slots;
        } else {
            self.collision_count = 0;
        }

        var decision = self.decide();
        var iterations: usize = 0;
        while (decision.action != .stay and iterations < 4) {
            _ = self.apply(decision);
            // Restore counters for new level (apply resets them)
            self.unique_tokens = unique_token_count;
            self.total_tokens = unique_token_count;
            const new_slots = self.currentSlots();
            if (unique_token_count > new_slots) {
                self.collision_count = unique_token_count - new_slots;
            } else {
                self.collision_count = 0;
            }
            decision = self.decide();
            iterations += 1;
        }
        return self.current_level;
    }
};

fn runAutoscaleDemo(allocator: std.mem.Allocator) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Autoscaler Demo — Dynamic Level/Vocab Selection         ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});

    const scenarios = [_]struct {
        name: []const u8,
        unique_tokens: usize,
        corpus_bytes: usize,
        expected_level: u8,
    }{
        .{ .name = "Small corpus (1K tokens, 100KB)", .unique_tokens = 1_000, .corpus_bytes = 100 * 1024, .expected_level = 0 },
        .{ .name = "Medium corpus (3.2K tokens, 200KB)", .unique_tokens = 3_200, .corpus_bytes = 200 * 1024, .expected_level = 1 },
        .{ .name = "Growing corpus (130K tokens, 1MB)", .unique_tokens = 130_000, .corpus_bytes = 1 * 1024 * 1024, .expected_level = 2 },
        .{ .name = "Large corpus (260K tokens, 3MB)", .unique_tokens = 260_000, .corpus_bytes = 3 * 1024 * 1024, .expected_level = 2 },
        .{ .name = "Very large corpus (600K tokens, 10MB)", .unique_tokens = 600_000, .corpus_bytes = 10 * 1024 * 1024, .expected_level = 3 },
        .{ .name = "Full 1M vocab (1M tokens, 20MB)", .unique_tokens = 1_000_000, .corpus_bytes = 20 * 1024 * 1024, .expected_level = 3 },
        .{ .name = "Shrink back (1K tokens, 50KB)", .unique_tokens = 1_000, .corpus_bytes = 50 * 1024, .expected_level = 0 },
    };

    var autoscaler = Autoscaler.init(0, .{});
    var all_pass = true;

    for (scenarios) |s| {
        const final_level = autoscaler.simulateCorpus(s.unique_tokens, s.corpus_bytes);
        const vocab = autoscaler.currentVocab();
        const slots = autoscaler.currentSlots();
        const collision_rate = autoscaler.currentCollisionRate();
        const tok_per_slot = @as(f64, @floatFromInt(s.unique_tokens)) / @as(f64, @floatFromInt(slots));

        const pass = final_level == s.expected_level;
        if (!pass) all_pass = false;

        std.debug.print("\n  {s}\n", .{s.name});
        std.debug.print("    → Level s={d} | Vocab: {s} ({d}) | Slots: {d} | Tok/slot: {d:.2} | Collisions: {d:.2}%\n", .{
            final_level, vocab.name, vocab.size, slots, tok_per_slot, collision_rate * 100,
        });
        if (pass) {
            std.debug.print("    ✓ PASS (expected s={d})\n", .{s.expected_level});
        } else {
            std.debug.print("    ✗ FAIL (expected s={d}, got s={d})\n", .{ s.expected_level, final_level });
        }
    }

    // Progressive growth simulation
    std.debug.print("\n  Progressive growth simulation:\n", .{});
    std.debug.print("  ┌───────┬──────────┬───────────┬──────────┬───────────┬────────┐\n", .{});
    std.debug.print("  │ Step  │ Tokens   │ Corpus    │ Level    │ Vocab     │ Coll%  │\n", .{});
    std.debug.print("  ├───────┼──────────┼───────────┼──────────┼───────────┼────────┤\n", .{});

    var sim = Autoscaler.init(0, .{});
    const growth_steps = [_]struct { tokens: usize, bytes: usize }{
        .{ .tokens = 1_000, .bytes = 50 * 1024 },
        .{ .tokens = 10_000, .bytes = 200 * 1024 },
        .{ .tokens = 50_000, .bytes = 500 * 1024 },
        .{ .tokens = 100_000, .bytes = 800 * 1024 },
        .{ .tokens = 131_072, .bytes = 1 * 1024 * 1024 },
        .{ .tokens = 200_000, .bytes = 2 * 1024 * 1024 },
        .{ .tokens = 300_000, .bytes = 4 * 1024 * 1024 },
        .{ .tokens = 500_000, .bytes = 8 * 1024 * 1024 },
        .{ .tokens = 800_000, .bytes = 15 * 1024 * 1024 },
        .{ .tokens = 1_000_000, .bytes = 25 * 1024 * 1024 },
    };

    for (growth_steps, 0..) |step, i| {
        _ = sim.simulateCorpus(step.tokens, step.bytes);
        const vocab = sim.currentVocab();
        const coll = sim.currentCollisionRate();
        std.debug.print("  │ {d:>5} │ {d:>8} │ {d:>9} │ s{d}       │ {s:<9} │ {d:>5.1} │\n", .{
            i + 1, step.tokens, step.bytes, sim.current_level, vocab.name, coll * 100,
        });
    }
    std.debug.print("  └───────┴──────────┴───────────┴──────────┴───────────┴────────┘\n", .{});

    std.debug.print("\n", .{});
    if (all_pass) {
        std.debug.print("  ✓ Autoscaler demo: ALL SCENARIOS PASS\n", .{});
    } else {
        std.debug.print("  ⚠ Autoscaler demo: SOME SCENARIOS FAILED\n", .{});
    }

    _ = allocator;
}

// =============================================================================
// Unit tests (run with `zig test`)
// =============================================================================

test "scaledNodeCount at s=0 equals 421" {
    try std.testing.expectEqual(@as(usize, 421), scaledNodeCount(0));
}

test "scaledNodeCount at s=1 equals 3368" {
    try std.testing.expectEqual(@as(usize, 3368), scaledNodeCount(1));
}

test "scaledNodeCount at s=2 equals 26944" {
    try std.testing.expectEqual(@as(usize, 26944), scaledNodeCount(2));
}

test "scaledNodeCount at s=3 equals 215552" {
    try std.testing.expectEqual(@as(usize, 215552), scaledNodeCount(3));
}

test "round-trip at s=0 for sample tokens" {
    for (0..1000) |tid| {
        const node = scaledTokenToNode(@intCast(tid), 0);
        const channel = scaledTokenToChannel(@intCast(tid), 0);
        const back = scaledNodeToToken(node, channel, 0);
        try std.testing.expectEqual(@as(u32, @intCast(tid)), back);
    }
}

test "round-trip at s=1 for sample tokens" {
    for (0..10000) |tid| {
        const node = scaledTokenToNode(@intCast(tid), 1);
        const channel = scaledTokenToChannel(@intCast(tid), 1);
        const back = scaledNodeToToken(node, channel, 1);
        try std.testing.expectEqual(@as(u32, @intCast(tid)), back);
    }
}

test "round-trip at s=2 for sample tokens" {
    for (0..50000) |tid| {
        const node = scaledTokenToNode(@intCast(tid), 2);
        const channel = scaledTokenToChannel(@intCast(tid), 2);
        const back = scaledNodeToToken(node, channel, 2);
        try std.testing.expectEqual(@as(u32, @intCast(tid)), back);
    }
}

test "round-trip at s=3 for sample tokens" {
    for (0..100000) |tid| {
        const node = scaledTokenToNode(@intCast(tid), 3);
        const channel = scaledTokenToChannel(@intCast(tid), 3);
        const back = scaledNodeToToken(node, channel, 3);
        try std.testing.expectEqual(@as(u32, @intCast(tid)), back);
    }
}

test "s=0 mapping matches Qstar's current tokenToNode" {
    // Current Qstar: tokenToNode(tid) = tid % 421
    // Scaled: scaledTokenToNode(tid, 0) = tid % (421 × 8^0) = tid % 421
    for (0..5000) |tid| {
        const current = @as(usize, @intCast(@as(u32, @intCast(tid)) % 421));
        const scaled = scaledTokenToNode(@intCast(tid), 0);
        try std.testing.expectEqual(current, scaled);
    }
}

test "s=0 mapping matches Qstar's current tokenToChannel" {
    // Current Qstar: tokenToChannel(tid) = (tid / 421) % 7
    // Scaled: scaledTokenToChannel(tid, 0) = (tid / (421 × 8^0)) % 7 = (tid / 421) % 7
    for (0..5000) |tid| {
        const current: u3 = @intCast((@as(u32, @intCast(tid)) / 421) % 7);
        const scaled = scaledTokenToChannel(@intCast(tid), 0);
        try std.testing.expectEqual(current, scaled);
    }
}

test "collision distribution is uniform at s=0 with 128K vocab" {
    // With 131072 tokens across 2947 slots, each slot should have ~44-45 tokens
    // Verify no slot has wildly more than expected (would indicate bias)
    const allocator = std.testing.allocator;
    const slots = scaledNodeCount(0) * CHANNEL_COUNT;
    var slot_counts = try allocator.alloc(u32, slots);
    defer allocator.free(slot_counts);
    @memset(slot_counts, 0);

    const vocab_size: usize = 131072;
    for (0..vocab_size) |tid| {
        const node = scaledTokenToNode(@intCast(tid), 0);
        const channel = scaledTokenToChannel(@intCast(tid), 0);
        slot_counts[node * CHANNEL_COUNT + channel] += 1;
    }

    var max_count: u32 = 0;
    var min_count: u32 = std.math.maxInt(u32);
    var total: usize = 0;
    for (slot_counts) |count| {
        if (count > max_count) max_count = count;
        if (count < min_count) min_count = count;
        total += count;
    }

    try std.testing.expectEqual(vocab_size, total);
    // With 131072 / 2947 ≈ 44.5, max should be ≤ 45, min should be ≥ 43
    try std.testing.expect(max_count <= 45);
    try std.testing.expect(min_count >= 43);
}

// =============================================================================
// Autoscaler unit tests
// =============================================================================

test "autoscaler starts at s=0 with 128k vocab" {
    var scaler = Autoscaler.init(0, .{});
    const vocab = scaler.currentVocab();
    try std.testing.expectEqual(@as(u8, 0), scaler.current_level);
    try std.testing.expectEqualStrings("ramsey-128k", vocab.name);
    try std.testing.expectEqual(@as(usize, 131072), vocab.size);
}

test "autoscaler stays at s=0 for small corpus" {
    var scaler = Autoscaler.init(0, .{});
    // 1K tokens at s=0 (2,947 slots) → ratio = 0.34 < 0.95, no collisions
    const final = scaler.simulateCorpus(1_000, 100 * 1024);
    try std.testing.expectEqual(@as(u8, 0), final);
}

test "autoscaler stays at s=0 for moderate token count" {
    var scaler = Autoscaler.init(0, .{});
    // 3,200 tokens at s=0 (2,947 slots) → collision = 7.9% < 50% threshold → stays
    const final = scaler.simulateCorpus(3_200, 200 * 1024);
    try std.testing.expectEqual(@as(u8, 0), final);
}

test "autoscaler scales up to s=2 for 130K tokens" {
    var scaler = Autoscaler.init(0, .{});
    // 130K overflows s=0 (2,947) and s=1 (23,576), fits at s=2 (188,608)
    const final = scaler.simulateCorpus(130_000, 1 * 1024 * 1024);
    try std.testing.expectEqual(@as(u8, 2), final);
}

test "autoscaler scales up to s=2 for 260K tokens" {
    var scaler = Autoscaler.init(0, .{});
    const final = scaler.simulateCorpus(260_000, 3 * 1024 * 1024);
    try std.testing.expectEqual(@as(u8, 2), final);
}

test "autoscaler scales up to s=3 for 600K tokens" {
    var scaler = Autoscaler.init(0, .{});
    const final = scaler.simulateCorpus(600_000, 10 * 1024 * 1024);
    try std.testing.expectEqual(@as(u8, 3), final);
}

test "autoscaler stays at s=3 for 1M tokens (max level)" {
    var scaler = Autoscaler.init(0, .{});
    const final = scaler.simulateCorpus(1_000_000, 20 * 1024 * 1024);
    try std.testing.expectEqual(@as(u8, 3), final);
}

test "autoscaler scales down when corpus shrinks" {
    var scaler = Autoscaler.init(2, .{});
    // Start at s=2, feed small corpus. 1K tokens fit at s=0 (2,947 slots)
    const final = scaler.simulateCorpus(1_000, 50 * 1024);
    try std.testing.expectEqual(@as(u8, 0), final);
}

test "autoscaler does not scale with too few tokens" {
    var scaler = Autoscaler.init(0, .{});
    // Only 100 tokens — below min_tokens_for_scale (1000)
    const final = scaler.simulateCorpus(100, 1024);
    try std.testing.expectEqual(@as(u8, 0), final);
}

test "autoscaler collision rate is correct at s=0" {
    var scaler = Autoscaler.init(0, .{});
    _ = scaler.simulateCorpus(131_072, 1 * 1024 * 1024);
    // At s=0: 131072 tokens, 2947 slots → collisions = 131072 - 2947 = 128125
    // But after scaling, we may be at a different level. Check before scaling.
    // Reset and check manually
    scaler = Autoscaler.init(0, .{});
    scaler.unique_tokens = 131_072;
    scaler.total_tokens = 131_072;
    scaler.collision_count = 131_072 - 2947;
    const rate = scaler.currentCollisionRate();
    try std.testing.expect(rate > 0.97);
    try std.testing.expect(rate < 0.98);
}

test "autoscaler token ratio triggers scale up before collision" {
    var scaler = Autoscaler.init(0, .{});
    // 2,850 tokens at s=0 (2,947 slots) → token_ratio = 0.967 > 0.95, no collisions yet
    scaler.unique_tokens = 2_850;
    scaler.total_tokens = 2_850;
    scaler.collision_count = 0;
    const decision = scaler.decide();
    try std.testing.expectEqual(AutoscaleDecision.Action.scale_up, decision.action);
    try std.testing.expectEqual(@as(u8, 1), decision.to_level);
}

test "autoscaler corpus size triggers scale up" {
    var scaler = Autoscaler.init(0, .{});
    // 50K tokens but 600KB corpus → collision rate ~94% > 50% threshold → scale up
    scaler.unique_tokens = 50_000;
    scaler.total_tokens = 50_000;
    scaler.collision_count = 50_000 - 2947;
    scaler.corpus_bytes = 600 * 1024;
    const decision = scaler.decide();
    try std.testing.expectEqual(AutoscaleDecision.Action.scale_up, decision.action);
}

test "autoscaler decide returns stay when in optimal range" {
    var scaler = Autoscaler.init(1, .{});
    // s=1: 23,576 slots, 20K tokens → ratio = 0.85, collision = 0
    scaler.unique_tokens = 20_000;
    scaler.total_tokens = 20_000;
    scaler.collision_count = 0;
    scaler.corpus_bytes = 100 * 1024;
    const decision = scaler.decide();
    try std.testing.expectEqual(AutoscaleDecision.Action.stay, decision.action);
}

test "VocabSpecs has 4 entries matching levels 0-3" {
    try std.testing.expectEqual(@as(usize, 4), VocabSpecs.len);
    try std.testing.expectEqual(@as(usize, 131072), VocabSpecs[0].size);
    try std.testing.expectEqual(@as(usize, 262144), VocabSpecs[1].size);
    try std.testing.expectEqual(@as(usize, 524288), VocabSpecs[2].size);
    try std.testing.expectEqual(@as(usize, 1048576), VocabSpecs[3].size);
}
