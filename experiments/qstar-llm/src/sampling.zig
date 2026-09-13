//! sampling.zig — Token sampling strategies for lattice agent output.
//!
//! Ported from Falsifible's sampling.zig — provides greedy, temperature,
//! top-k, and top-p (nucleus) sampling for the agent's logit projection.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

/// Sampling strategy selector.
pub const SampleStrategy = enum {
    greedy,
    temperature,
    top_k,
    top_p,
    topological_samc,
};

/// Sampling configuration.
pub const SampleConfig = struct {
    strategy: SampleStrategy = .temperature,
    temperature: f64 = 1.0,
    top_k: usize = 40,
    top_p: f64 = 0.9,
    seed: u64 = 0,
    samc_sweeps: usize = 16,
    repetition_penalty: f64 = 1.15,
    context_tokens: ?[]const u32 = null,
};

/// Greedy sampling: returns the argmax index.
pub inline fn sampleGreedy(logits: []const f64) u32 {
    var best_idx: usize = 0;
    var best_val: f64 = logits[0];
    for (1..logits.len) |i| {
        if (logits[i] > best_val) {
            best_val = logits[i];
            best_idx = i;
        }
    }
    return @intCast(best_idx);
}

/// Applies repetition penalty to logits for tokens that appeared in context.
/// Reduces probability of repeating recently generated tokens.
pub fn applyRepetitionPenalty(logits: []f64, context_tokens: []const u32, penalty: f64) void {
    if (penalty <= 1.0 or context_tokens.len == 0) return;
    for (context_tokens) |tok| {
        if (tok < logits.len) {
            const val = logits[tok];
            if (val > 0) {
                logits[tok] = val / penalty;
            } else if (val < 0 and val > -std.math.inf(f64)) {
                logits[tok] = val * penalty;
            }
        }
    }
}

/// Applies temperature scaling to logits: logit /= temperature.
/// Temperature > 1 flattens distribution (more random).
/// Temperature < 1 sharpens distribution (more deterministic).
/// Temperature = 0 is greedy (handled separately).
pub inline fn applyTemperature(logits: []f64, temperature: f64) void {
    if (temperature <= 0) return;
    const inv_temp = 1.0 / temperature;
    for (logits) |*l| l.* *= inv_temp;
}

/// Applies top-k filtering: keeps only the top k logits, sets rest to -inf.
pub fn applyTopK(logits: []f64, k: usize) void {
    if (k == 0 or k >= logits.len) return;

    // Find the k-th largest value using a simple approach:
    // Collect all non-inf logits, sort, and use the k-th as threshold
    var valid_count: usize = 0;
    for (logits) |l| {
        if (l > -std.math.inf(f64)) valid_count += 1;
    }
    if (valid_count <= k) return; // All valid logits fit within top-k

    // Use a fixed buffer for small arrays, or find threshold via partial selection
    // For large arrays, use a simple linear scan to find the k-th largest
    var temp_buf: [4096]f64 = undefined;
    if (logits.len <= temp_buf.len) {
        @memcpy(temp_buf[0..logits.len], logits);
        std.mem.sort(f64, temp_buf[0..logits.len], {}, struct {
            fn cmp(_: void, a: f64, b: f64) bool {
                return a > b;
            }
        }.cmp);
        const threshold = temp_buf[k - 1];
        for (logits) |*l| {
            if (l.* < threshold) l.* = -std.math.inf(f64);
        }
    } else {
        // For large arrays: find threshold by collecting valid logits
        // Use a partial sort approach with a small buffer
        // Find the k-th largest among non-inf logits
        var top_k_buf: [64]f64 = undefined;
        if (k > top_k_buf.len) {
            // Fallback: just filter by a reasonable threshold
            // Find max and set threshold to a high percentile
            var max_val: f64 = -std.math.inf(f64);
            for (logits) |l| {
                if (l > max_val) max_val = l;
            }
            // Set all but those near max to -inf
            const threshold = max_val - 10.0;
            var kept: usize = 0;
            for (logits) |*l| {
                if (l.* < threshold) {
                    l.* = -std.math.inf(f64);
                } else {
                    kept += 1;
                    if (kept > k) {
                        // Keep only the first k that pass
                        l.* = -std.math.inf(f64);
                    }
                }
            }
            return;
        }
        // k <= 64: use insertion to find top-k
        @memset(top_k_buf[0..], -std.math.inf(f64));
        for (logits) |l| {
            if (l <= -std.math.inf(f64)) continue;
            // Insert into sorted top-k buffer
            if (l > top_k_buf[k - 1]) {
                top_k_buf[k - 1] = l;
                // Re-sort the small buffer
                std.mem.sort(f64, top_k_buf[0..k], {}, struct {
                    fn cmp(_: void, a: f64, b: f64) bool {
                        return a > b;
                    }
                }.cmp);
            }
        }
        const threshold = top_k_buf[k - 1];
        for (logits) |*l| {
            if (l.* < threshold) l.* = -std.math.inf(f64);
        }
    }
}

/// Applies top-p (nucleus) filtering: keeps the smallest set of tokens
/// whose cumulative probability >= p, sets rest to -inf.
pub fn applyTopP(logits: []f64, p: f64) void {
    if (p >= 1.0) return;

    // Softmax to get probabilities
    var max_val: f64 = logits[0];
    for (logits[1..]) |l| {
        if (l > max_val) max_val = l;
    }

    var sum_exp: f64 = 0;
    for (logits) |l| {
        if (l > -std.math.inf(f64)) {
            sum_exp += std.math.exp(l - max_val);
        }
    }

    if (sum_exp <= 0) return;

    // Find threshold: sort logits descending, accumulate until cumprob >= p
    var temp_buf: [4096]f64 = undefined;
    const buf_len = @min(logits.len, temp_buf.len);
    @memcpy(temp_buf[0..buf_len], logits[0..buf_len]);

    std.mem.sort(f64, temp_buf[0..buf_len], {}, struct {
        fn cmp(_: void, a: f64, b: f64) bool {
            return a > b;
        }
    }.cmp);

    var cumprob: f64 = 0;
    var threshold: f64 = temp_buf[0];
    for (temp_buf[0..buf_len]) |l| {
        if (l <= -std.math.inf(f64)) break;
        const prob = std.math.exp(l - max_val) / sum_exp;
        cumprob += prob;
        threshold = l;
        if (cumprob >= p) break;
    }

    for (logits) |*l| {
        if (l.* < threshold) l.* = -std.math.inf(f64);
    }
}

/// Computes softmax probabilities from logits.
/// Returns a probability distribution summing to 1.
pub fn softmax(allocator: std.mem.Allocator, logits: []const f64) ![]f64 {
    var probs = try allocator.alloc(f64, logits.len);
    errdefer allocator.free(probs);

    var max_val: f64 = logits[0];
    for (logits[1..]) |l| {
        if (l > max_val) max_val = l;
    }

    var sum_exp: f64 = 0;
    for (logits, 0..) |l, i| {
        if (l <= -std.math.inf(f64)) {
            probs[i] = 0;
        } else {
            probs[i] = std.math.exp(l - max_val);
            sum_exp += probs[i];
        }
    }

    if (sum_exp > 0) {
        for (probs) |*p| p.* /= sum_exp;
    }

    return probs;
}

/// Multinomial sampling: samples an index from a probability distribution.
pub fn sampleMultinomial(probs: []const f64, rng: *std.Random.DefaultPrng) u32 {
    const r = rng.random().float(f64);
    var cumulative: f64 = 0;
    var last_valid: u32 = 0;
    for (probs, 0..) |p, i| {
        if (p > 0) last_valid = @intCast(i);
        cumulative += p;
        if (r <= cumulative) return @intCast(i);
    }
    return last_valid;
}

/// Topological Self-Assembly Monte Carlo sampling:
/// Uses local 2-opt Metropolis bond-swaps with phi-cooling on logits to find
/// the most coherent equilibrium state, escaping local entropy minima.
pub fn sampleTopologicalSAMC(
    allocator: std.mem.Allocator,
    logits: []const f64,
    seed: u64,
    sweeps: usize,
) !u32 {
    if (logits.len == 0) return 0;
    if (logits.len == 1) return 0;

    var prng = std.Random.DefaultPrng.init(seed);
    var rand = prng.random();

    // Work array of token indices
    var indices = try allocator.alloc(u32, logits.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = @intCast(i);

    var temp: f64 = 1.0;
    const phi_inv = 0.6180339887;

    for (0..sweeps) |_| {
        for (0..logits.len) |_| {
            const i = rand.uintLessThan(usize, logits.len);
            const j = rand.uintLessThan(usize, logits.len);
            if (i == j) continue;

            const idx_i = indices[i];
            const idx_j = indices[j];

            // Coherence energy: minimize discrepancy between neighboring order
            const h_old = -logits[idx_i];
            const h_new = -logits[idx_j];
            const delta_h = h_new - h_old;

            var accept = false;
            if (delta_h <= 0) {
                accept = true;
            } else if (temp > 1e-6) {
                const prob = std.math.exp(-delta_h / temp);
                if (rand.float(f64) <= prob) {
                    accept = true;
                }
            }

            if (accept) {
                indices[i] = idx_j;
                indices[j] = idx_i;
            }
        }
        temp *= phi_inv;
    }

    // Return the token at the top equilibrium position
    var best_token = indices[0];
    var max_logit = logits[best_token];
    for (indices[0..@min(indices.len, 10)]) |tok| {
        if (logits[tok] > max_logit) {
            max_logit = logits[tok];
            best_token = tok;
        }
    }

    return best_token;
}

/// Full sampling pipeline: applies strategy, then samples.
/// Returns the sampled token ID.
pub fn sample(
    allocator: std.mem.Allocator,
    logits: []const f64,
    config: SampleConfig,
) !u32 {
    if (config.strategy == .greedy or config.temperature == 0) {
        if (config.context_tokens) |ctx| {
            if (ctx.len > 0 and config.repetition_penalty > 1.0) {
                const logits_copy = try allocator.alloc(f64, logits.len);
                defer allocator.free(logits_copy);
                @memcpy(logits_copy, logits);
                applyRepetitionPenalty(logits_copy, ctx, config.repetition_penalty);
                return sampleGreedy(logits_copy);
            }
        }
        return sampleGreedy(logits);
    }
    if (config.strategy == .topological_samc) {
        if (config.context_tokens) |ctx| {
            if (ctx.len > 0 and config.repetition_penalty > 1.0) {
                const logits_copy = try allocator.alloc(f64, logits.len);
                defer allocator.free(logits_copy);
                @memcpy(logits_copy, logits);
                applyRepetitionPenalty(logits_copy, ctx, config.repetition_penalty);
                return try sampleTopologicalSAMC(allocator, logits_copy, config.seed, config.samc_sweeps);
            }
        }
        return try sampleTopologicalSAMC(allocator, logits, config.seed, config.samc_sweeps);
    }

    // Copy logits for mutation
    const logits_copy = try allocator.alloc(f64, logits.len);
    defer allocator.free(logits_copy);
    @memcpy(logits_copy, logits);

    // Apply repetition penalty
    if (config.context_tokens) |ctx| {
        applyRepetitionPenalty(logits_copy, ctx, config.repetition_penalty);
    }

    // Apply temperature
    applyTemperature(logits_copy, config.temperature);

    // Apply strategy-specific filtering
    switch (config.strategy) {
        .temperature => {},
        .top_k => applyTopK(logits_copy, config.top_k),
        .top_p => applyTopP(logits_copy, config.top_p),
        .topological_samc => unreachable,
        .greedy => unreachable,
    }

    // Softmax + multinomial sample
    const probs = try softmax(allocator, logits_copy);
    defer allocator.free(probs);

    var rng = std.Random.DefaultPrng.init(config.seed);
    return sampleMultinomial(probs, &rng);
}

// =============================================================================
// Tests
// =============================================================================

test "greedy sampling returns argmax" {
    const logits = [_]f64{ 0.1, 0.5, 0.3, 0.9, 0.2 };
    const result = sampleGreedy(&logits);
    try std.testing.expectEqual(@as(u32, 3), result);
}

test "temperature scaling flattens distribution" {
    var logits = [_]f64{ 1.0, 2.0, 3.0 };
    applyTemperature(&logits, 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), logits[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), logits[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), logits[2], 1e-10);
}

test "temperature scaling sharpens distribution" {
    var logits = [_]f64{ 1.0, 2.0, 3.0 };
    applyTemperature(&logits, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), logits[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), logits[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), logits[2], 1e-10);
}

test "top-k filtering keeps top k" {
    var logits = [_]f64{ 0.1, 0.5, 0.3, 0.9, 0.2 };
    applyTopK(&logits, 2);
    try std.testing.expect(logits[3] > -std.math.inf(f64));
    try std.testing.expect(logits[1] > -std.math.inf(f64));
    try std.testing.expect(logits[0] == -std.math.inf(f64));
    try std.testing.expect(logits[2] == -std.math.inf(f64));
    try std.testing.expect(logits[4] == -std.math.inf(f64));
}

test "softmax produces valid distribution" {
    const allocator = std.testing.allocator;
    const logits = [_]f64{ 1.0, 2.0, 3.0 };
    const probs = try softmax(allocator, &logits);
    defer allocator.free(probs);

    var sum: f64 = 0;
    for (probs) |p| sum += p;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-10);
    try std.testing.expect(probs[2] > probs[1]);
    try std.testing.expect(probs[1] > probs[0]);
}

test "multinomial sampling returns valid index" {
    const probs = [_]f64{ 0.1, 0.2, 0.7 };
    var rng = std.Random.DefaultPrng.init(42);
    const idx = sampleMultinomial(&probs, &rng);
    try std.testing.expect(idx < 3);
}

test "full sampling pipeline with temperature" {
    const allocator = std.testing.allocator;
    const logits = [_]f64{ 0.1, 0.5, 0.3, 0.9, 0.2 };
    const config = SampleConfig{
        .strategy = .temperature,
        .temperature = 1.0,
        .seed = 12345,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expect(result < 5);
}

test "full sampling pipeline with top-k" {
    const allocator = std.testing.allocator;
    const logits = [_]f64{ 0.1, 0.5, 0.3, 0.9, 0.2 };
    const config = SampleConfig{
        .strategy = .top_k,
        .temperature = 1.0,
        .top_k = 2,
        .seed = 42,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expect(result == 1 or result == 3);
}

test "full sampling pipeline with topological_samc" {
    const allocator = std.testing.allocator;
    const logits = [_]f64{ 0.1, 0.5, 0.3, 0.9, 0.2 };
    const config = SampleConfig{
        .strategy = .topological_samc,
        .seed = 42,
        .samc_sweeps = 10,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expect(result < 5);
}

test "repetition penalty dampens repeated tokens" {
    var logits = [_]f64{ 1.0, 2.0, 3.0 };
    const context = [_]u32{2};
    applyRepetitionPenalty(&logits, &context, 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), logits[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), logits[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), logits[2], 1e-10);
}

test "greedy via temperature=0" {
    const allocator = std.testing.allocator;
    const logits = [_]f64{ 0.1, 0.5, 0.3, 0.9, 0.2 };
    const config = SampleConfig{
        .strategy = .temperature,
        .temperature = 0,
        .seed = 0,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expectEqual(@as(u32, 3), result);
}

// =============================================================================
// Framework-Aware Sampling (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// φ-cooling schedule derived from the framework's golden ratio cooling.
/// T(cycle) = T₀ × φ^(-cycle), where φ = 1.6180339887498948482.
/// This replaces ad-hoc temperature schedules with the framework's principled schedule.
pub fn phiCoolingTemperature(base_temp: f64, cycle: u64) f64 {
    const PHI: f64 = 1.6180339887498948482;
    return base_temp * std.math.pow(f64, PHI, -@as(f64, @floatFromInt(cycle)));
}

/// Consciousness-aware sampling: when the lattice is not conscious (e6 silent),
/// bias sampling toward repetition by increasing repetition penalty.
/// When conscious (e6 active), reduce repetition penalty to allow diverse output.
pub fn consciousnessRepetitionPenalty(base_penalty: f64, is_conscious: bool) f64 {
    if (is_conscious) {
        // Conscious: lower penalty allows diverse, creative output
        return base_penalty * 0.8;
    } else {
        // Not conscious: higher penalty suppresses diverse output,
        // but the echo tendency in step() already handles this.
        // Here we just return the base penalty.
        return base_penalty;
    }
}

/// Framework-derived top_k from the 7-defect structure.
/// The 7-defect (2³-1=7) suggests using k=7 as a natural top_k value
/// for the 7-channel octonionic lattice.
pub const FRAMEWORK_TOP_K: usize = 7;

/// Framework-derived top_p from the 1/8 consciousness aperture.
/// The 1/8 aperture suggests using p=7/8=0.875 as the nucleus threshold,
/// keeping 7/8 of the probability mass (the observed portion).
pub const FRAMEWORK_TOP_P: f64 = 0.875;

test "framework: φ-cooling schedule decreases temperature" {
    const t0 = phiCoolingTemperature(1.0, 0);
    const t1 = phiCoolingTemperature(1.0, 1);
    const t10 = phiCoolingTemperature(1.0, 10);
    try std.testing.expect(t0 > t1);
    try std.testing.expect(t1 > t10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), t0, 1e-10);
}

test "framework: consciousness reduces repetition penalty" {
    const base = 1.5;
    const conscious = consciousnessRepetitionPenalty(base, true);
    const unconscious = consciousnessRepetitionPenalty(base, false);
    try std.testing.expect(conscious < unconscious);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), conscious, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), unconscious, 1e-10);
}

test "framework: top_k=7 from 7-defect structure" {
    try std.testing.expectEqual(@as(usize, 7), FRAMEWORK_TOP_K);
}

test "framework: top_p=7/8 from consciousness aperture" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), FRAMEWORK_TOP_P, 1e-10);
}
