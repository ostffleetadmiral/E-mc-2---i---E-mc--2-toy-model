//! sampling.zig — Token sampling strategies for lattice agent output.
//!
//! Ported from Falsifible's sampling.zig — provides greedy, temperature,
//! top-k, and top-p (nucleus) sampling for the agent's logit projection.
//!
//! All arithmetic uses Q128.128 fixed-point (i256 raw, 128 fractional bits).
//! No f64 in state paths. The -inf sentinel for filtered logits is q128.MIN_VAL.
//!
//! Zero external dependencies beyond std and q128.

const std = @import("std");
const q128 = @import("q128");

/// Sentinel value for filtered-out logits (replaces -inf).
pub const NEG_INF: q128.Fp = q128.MIN_VAL;

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
    temperature: q128.Fp = q128.ONE,
    top_k: usize = 40,
    top_p: q128.Fp = q128.fromRatio(9, 10),
    seed: u64 = 0,
    samc_sweeps: usize = 16,
    repetition_penalty: q128.Fp = q128.fromRatio(115, 100),
    context_tokens: ?[]const u32 = null,
};

/// Greedy sampling: returns the argmax index.
pub inline fn sampleGreedy(logits: []const q128.Fp) u32 {
    var best_idx: usize = 0;
    var best_val: q128.Fp = logits[0];
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
pub fn applyRepetitionPenalty(logits: []q128.Fp, context_tokens: []const u32, penalty: q128.Fp) void {
    if (penalty <= q128.ONE or context_tokens.len == 0) return;
    for (context_tokens) |tok| {
        if (tok < logits.len) {
            const val = logits[tok];
            if (val > 0) {
                logits[tok] = q128.div(val, penalty);
            } else if (val < 0 and val > NEG_INF) {
                logits[tok] = q128.mul(val, penalty);
            }
        }
    }
}

/// Applies temperature scaling to logits: logit /= temperature.
/// Temperature > 1 flattens distribution (more random).
/// Temperature < 1 sharpens distribution (more deterministic).
/// Temperature = 0 is greedy (handled separately).
pub inline fn applyTemperature(logits: []q128.Fp, temperature: q128.Fp) void {
    if (temperature <= 0) return;
    const inv_temp = q128.div(q128.ONE, temperature);
    for (logits) |*l| l.* = q128.mul(l.*, inv_temp);
}

/// Applies top-k filtering: keeps only the top k logits, sets rest to NEG_INF.
pub fn applyTopK(logits: []q128.Fp, k: usize) void {
    if (k == 0 or k >= logits.len) return;

    // Count valid (non-NEG_INF) logits
    var valid_count: usize = 0;
    for (logits) |l| {
        if (l > NEG_INF) valid_count += 1;
    }
    if (valid_count <= k) return;

    // Use a fixed buffer for small arrays
    var temp_buf: [4096]q128.Fp = undefined;
    if (logits.len <= temp_buf.len) {
        @memcpy(temp_buf[0..logits.len], logits);
        std.mem.sort(q128.Fp, temp_buf[0..logits.len], {}, struct {
            fn cmp(_: void, a: q128.Fp, b: q128.Fp) bool {
                return a > b;
            }
        }.cmp);
        const threshold = temp_buf[k - 1];
        for (logits) |*l| {
            if (l.* < threshold) l.* = NEG_INF;
        }
    } else {
        // For large arrays: find threshold by collecting valid logits
        var top_k_buf: [64]q128.Fp = undefined;
        if (k > top_k_buf.len) {
            // Fallback: filter by a reasonable threshold
            var max_val: q128.Fp = NEG_INF;
            for (logits) |l| {
                if (l > max_val) max_val = l;
            }
            const threshold = q128.sub(max_val, q128.fromInt(10));
            var kept: usize = 0;
            for (logits) |*l| {
                if (l.* < threshold) {
                    l.* = NEG_INF;
                } else {
                    kept += 1;
                    if (kept > k) {
                        l.* = NEG_INF;
                    }
                }
            }
            return;
        }
        // k <= 64: use insertion to find top-k
        @memset(top_k_buf[0..], NEG_INF);
        for (logits) |l| {
            if (l <= NEG_INF) continue;
            if (l > top_k_buf[k - 1]) {
                top_k_buf[k - 1] = l;
                std.mem.sort(q128.Fp, top_k_buf[0..k], {}, struct {
                    fn cmp(_: void, a: q128.Fp, b: q128.Fp) bool {
                        return a > b;
                    }
                }.cmp);
            }
        }
        const threshold = top_k_buf[k - 1];
        for (logits) |*l| {
            if (l.* < threshold) l.* = NEG_INF;
        }
    }
}

/// Applies top-p (nucleus) filtering: keeps the smallest set of tokens
/// whose cumulative probability >= p, sets rest to NEG_INF.
pub fn applyTopP(logits: []q128.Fp, p: q128.Fp) void {
    if (p >= q128.ONE) return;

    // Softmax to get probabilities
    var max_val: q128.Fp = logits[0];
    for (logits[1..]) |l| {
        if (l > max_val) max_val = l;
    }

    var sum_exp: q128.Fp = 0;
    for (logits) |l| {
        if (l > NEG_INF) {
            sum_exp = q128.add(sum_exp, q128.exp(q128.sub(l, max_val)));
        }
    }

    if (sum_exp <= 0) return;

    // Find threshold: sort logits descending, accumulate until cumprob >= p
    var temp_buf: [4096]q128.Fp = undefined;
    const buf_len = @min(logits.len, temp_buf.len);
    @memcpy(temp_buf[0..buf_len], logits[0..buf_len]);

    std.mem.sort(q128.Fp, temp_buf[0..buf_len], {}, struct {
        fn cmp(_: void, a: q128.Fp, b: q128.Fp) bool {
            return a > b;
        }
    }.cmp);

    var cumprob: q128.Fp = 0;
    var threshold: q128.Fp = temp_buf[0];
    for (temp_buf[0..buf_len]) |l| {
        if (l <= NEG_INF) break;
        const prob = q128.div(q128.exp(q128.sub(l, max_val)), sum_exp);
        cumprob = q128.add(cumprob, prob);
        threshold = l;
        if (cumprob >= p) break;
    }

    for (logits) |*l| {
        if (l.* < threshold) l.* = NEG_INF;
    }
}

/// Computes softmax probabilities from logits.
/// Returns a probability distribution summing to 1.
pub fn softmax(allocator: std.mem.Allocator, logits: []const q128.Fp) ![]q128.Fp {
    var probs = try allocator.alloc(q128.Fp, logits.len);
    errdefer allocator.free(probs);

    var max_val: q128.Fp = logits[0];
    for (logits[1..]) |l| {
        if (l > max_val) max_val = l;
    }

    var sum_exp: q128.Fp = 0;
    for (logits, 0..) |l, i| {
        if (l <= NEG_INF) {
            probs[i] = 0;
        } else {
            probs[i] = q128.exp(q128.sub(l, max_val));
            sum_exp = q128.add(sum_exp, probs[i]);
        }
    }

    if (sum_exp > 0) {
        for (probs) |*p| p.* = q128.div(p.*, sum_exp);
    }

    return probs;
}

/// Generate a random Q128 value in [0, 1).
fn randomQ128(rng: *std.Random.DefaultPrng) q128.Fp {
    // Generate a random u128 and use it as the fractional part
    const rand_u128 = rng.random().int(u128);
    return @as(q128.Fp, @intCast(rand_u128));
}

/// Multinomial sampling: samples an index from a probability distribution.
pub fn sampleMultinomial(probs: []const q128.Fp, rng: *std.Random.DefaultPrng) u32 {
    const r = randomQ128(rng);
    var cumulative: q128.Fp = 0;
    var last_valid: u32 = 0;
    for (probs, 0..) |p, i| {
        if (p > 0) last_valid = @intCast(i);
        cumulative = q128.add(cumulative, p);
        if (r <= cumulative) return @intCast(i);
    }
    return last_valid;
}

/// Topological Self-Assembly Monte Carlo sampling:
/// Uses local 2-opt Metropolis bond-swaps with phi-cooling on logits to find
/// the most coherent equilibrium state, escaping local entropy minima.
pub fn sampleTopologicalSAMC(
    allocator: std.mem.Allocator,
    logits: []const q128.Fp,
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

    var temp: q128.Fp = q128.ONE;
    const phi_inv = q128.INV_PHI;

    for (0..sweeps) |_| {
        for (0..logits.len) |_| {
            const i = rand.uintLessThan(usize, logits.len);
            const j = rand.uintLessThan(usize, logits.len);
            if (i == j) continue;

            const idx_i = indices[i];
            const idx_j = indices[j];

            // Coherence energy: minimize discrepancy between neighboring order
            const h_old = q128.neg(logits[idx_i]);
            const h_new = q128.neg(logits[idx_j]);
            const delta_h = q128.sub(h_new, h_old);

            var accept = false;
            if (delta_h <= 0) {
                accept = true;
            } else if (temp > 0) {
                const prob = q128.exp(q128.div(q128.neg(delta_h), temp));
                if (randomQ128(&prng) <= prob) {
                    accept = true;
                }
            }

            if (accept) {
                indices[i] = idx_j;
                indices[j] = idx_i;
            }
        }
        temp = q128.mul(temp, phi_inv);
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
    logits: []const q128.Fp,
    config: SampleConfig,
) !u32 {
    if (config.strategy == .greedy or config.temperature == 0) {
        if (config.context_tokens) |ctx| {
            if (ctx.len > 0 and config.repetition_penalty > q128.ONE) {
                const logits_copy = try allocator.alloc(q128.Fp, logits.len);
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
            if (ctx.len > 0 and config.repetition_penalty > q128.ONE) {
                const logits_copy = try allocator.alloc(q128.Fp, logits.len);
                defer allocator.free(logits_copy);
                @memcpy(logits_copy, logits);
                applyRepetitionPenalty(logits_copy, ctx, config.repetition_penalty);
                return try sampleTopologicalSAMC(allocator, logits_copy, config.seed, config.samc_sweeps);
            }
        }
        return try sampleTopologicalSAMC(allocator, logits, config.seed, config.samc_sweeps);
    }

    // Copy logits for mutation
    const logits_copy = try allocator.alloc(q128.Fp, logits.len);
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
    const logits = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(9, 10), q128.fromRatio(2, 10) };
    const result = sampleGreedy(&logits);
    try std.testing.expectEqual(@as(u32, 3), result);
}

test "temperature scaling flattens distribution" {
    var logits = [_]q128.Fp{ q128.fromInt(1), q128.fromInt(2), q128.fromInt(3) };
    applyTemperature(&logits, q128.fromInt(2));
    try std.testing.expect(q128.fromRatio(1, 2) == logits[0]);
    try std.testing.expect(q128.ONE == logits[1]);
    try std.testing.expect(q128.fromRatio(3, 2) == logits[2]);
}

test "temperature scaling sharpens distribution" {
    var logits = [_]q128.Fp{ q128.fromInt(1), q128.fromInt(2), q128.fromInt(3) };
    applyTemperature(&logits, q128.fromRatio(1, 2));
    try std.testing.expect(q128.fromInt(2) == logits[0]);
    try std.testing.expect(q128.fromInt(4) == logits[1]);
    try std.testing.expect(q128.fromInt(6) == logits[2]);
}

test "top-k filtering keeps top k" {
    var logits = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(9, 10), q128.fromRatio(2, 10) };
    applyTopK(&logits, 2);
    try std.testing.expect(logits[3] > NEG_INF);
    try std.testing.expect(logits[1] > NEG_INF);
    try std.testing.expect(logits[0] == NEG_INF);
    try std.testing.expect(logits[2] == NEG_INF);
    try std.testing.expect(logits[4] == NEG_INF);
}

test "softmax produces valid distribution" {
    const allocator = std.testing.allocator;
    const logits = [_]q128.Fp{ q128.fromInt(1), q128.fromInt(2), q128.fromInt(3) };
    const probs = try softmax(allocator, &logits);
    defer allocator.free(probs);

    var sum: q128.Fp = 0;
    for (probs) |p| sum = q128.add(sum, p);
    // Sum should be close to 1 (within a few ULP due to fixed-point rounding)
    const diff = if (sum > q128.ONE) sum - q128.ONE else q128.ONE - sum;
    try std.testing.expect(diff <= 4);
    try std.testing.expect(probs[2] > probs[1]);
    try std.testing.expect(probs[1] > probs[0]);
}

test "multinomial sampling returns valid index" {
    const probs = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(2, 10), q128.fromRatio(7, 10) };
    var rng = std.Random.DefaultPrng.init(42);
    const idx = sampleMultinomial(&probs, &rng);
    try std.testing.expect(idx < 3);
}

test "full sampling pipeline with temperature" {
    const allocator = std.testing.allocator;
    const logits = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(9, 10), q128.fromRatio(2, 10) };
    const config = SampleConfig{
        .strategy = .temperature,
        .temperature = q128.ONE,
        .seed = 12345,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expect(result < 5);
}

test "full sampling pipeline with top-k" {
    const allocator = std.testing.allocator;
    const logits = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(9, 10), q128.fromRatio(2, 10) };
    const config = SampleConfig{
        .strategy = .top_k,
        .temperature = q128.ONE,
        .top_k = 2,
        .seed = 42,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expect(result == 1 or result == 3);
}

test "full sampling pipeline with topological_samc" {
    const allocator = std.testing.allocator;
    const logits = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(9, 10), q128.fromRatio(2, 10) };
    const config = SampleConfig{
        .strategy = .topological_samc,
        .seed = 42,
        .samc_sweeps = 10,
    };
    const result = try sample(allocator, &logits, config);
    try std.testing.expect(result < 5);
}

test "repetition penalty dampens repeated tokens" {
    var logits = [_]q128.Fp{ q128.fromInt(1), q128.fromInt(2), q128.fromInt(3) };
    const context = [_]u32{2};
    applyRepetitionPenalty(&logits, &context, q128.fromInt(2));
    try std.testing.expect(q128.fromInt(1) == logits[0]);
    try std.testing.expect(q128.fromInt(2) == logits[1]);
    try std.testing.expect(q128.fromRatio(3, 2) == logits[2]);
}

test "greedy via temperature=0" {
    const allocator = std.testing.allocator;
    const logits = [_]q128.Fp{ q128.fromRatio(1, 10), q128.fromRatio(5, 10), q128.fromRatio(3, 10), q128.fromRatio(9, 10), q128.fromRatio(2, 10) };
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
pub fn phiCoolingTemperature(base_temp: q128.Fp, cycle: u64) q128.Fp {
    return q128.mul(base_temp, q128.pow(q128.PHI, -@as(i32, @intCast(cycle))));
}

/// Consciousness-aware sampling: when the lattice is not conscious (e6 silent),
/// bias sampling toward repetition by increasing repetition penalty.
/// When conscious (e6 active), reduce repetition penalty to allow diverse output.
pub fn consciousnessRepetitionPenalty(base_penalty: q128.Fp, is_conscious: bool) q128.Fp {
    if (is_conscious) {
        // Conscious: lower penalty allows diverse, creative output
        return q128.mul(base_penalty, q128.fromRatio(8, 10));
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
pub const FRAMEWORK_TOP_P: q128.Fp = q128.fromRatio(7, 8);

test "framework: φ-cooling schedule decreases temperature" {
    const t0 = phiCoolingTemperature(q128.ONE, 0);
    const t1 = phiCoolingTemperature(q128.ONE, 1);
    const t10 = phiCoolingTemperature(q128.ONE, 10);
    try std.testing.expect(t0 > t1);
    try std.testing.expect(t1 > t10);
    try std.testing.expect(q128.ONE == t0);
}

test "framework: consciousness reduces repetition penalty" {
    const base = q128.fromRatio(15, 10);
    const conscious = consciousnessRepetitionPenalty(base, true);
    const unconscious = consciousnessRepetitionPenalty(base, false);
    try std.testing.expect(conscious < unconscious);
    // Check within 2 ULP tolerance due to fixed-point multiplication rounding
    const expected_conscious = q128.fromRatio(12, 10);
    const diff_c = if (conscious > expected_conscious) conscious - expected_conscious else expected_conscious - conscious;
    try std.testing.expect(diff_c <= 2);
    try std.testing.expect(q128.fromRatio(15, 10) == unconscious);
}

test "framework: top_k=7 from 7-defect structure" {
    try std.testing.expectEqual(@as(usize, 7), FRAMEWORK_TOP_K);
}

test "framework: top_p=7/8 from consciousness aperture" {
    try std.testing.expect(q128.fromRatio(7, 8) == FRAMEWORK_TOP_P);
}
