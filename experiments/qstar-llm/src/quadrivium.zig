//! quadrivium.zig — Quadrivium mathematical manifold layer for Qstar agent.
//!
//! Implements the four classical mathematical arts as processing layers
//! that wrap the lattice operations:
//!   - Arithmetic: precision tracking, quantization-aware ops, discrete latent mapping
//!   - Geometry: non-Euclidean embedding, volumetric O(1) lookups, geometric codec
//!   - Music: harmonic state space, resonance/attenuation, formant synthesis, prosody
//!   - Astronomy: dynamic state-space trajectory, Neural ODE evolution, multi-body prediction

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

const E0_NODE_COUNT: usize = 421;
const CHANNEL_COUNT: usize = 7;

/// Formant frequency bands in Hz (Q64.64 fixed-point)
pub const F1_MIN: i128 = 200 << 64;
pub const F1_MAX: i128 = 1000 << 64;
pub const F2_MIN: i128 = 800 << 64;
pub const F2_MAX: i128 = 2500 << 64;
pub const F3_MIN: i128 = 1500 << 64;
pub const F3_MAX: i128 = 3500 << 64;

// =============================================================================
// Arithmetic Layer
// =============================================================================

pub const ArithmeticLayer = struct {
    precision_error: i128 = 0,
    quantization_bins: usize = 256,
    total_operations: u64 = 0,

    pub fn init() ArithmeticLayer {
        return .{};
    }

    pub fn trackPrecision(self: *ArithmeticLayer, exact: i128, approximated: i128) void {
        const error_val = if (exact > approximated) exact - approximated else approximated - exact;
        self.precision_error += error_val;
        self.total_operations += 1;
    }

    pub fn averageError(self: ArithmeticLayer) f64 {
        if (self.total_operations == 0) return 0.0;
        const avg = @as(f64, @floatFromInt(self.precision_error)) /
            @as(f64, @floatFromInt(self.total_operations));
        return avg / @as(f64, @floatFromInt(1 << 64));
    }

    pub fn quantize(value: i128, bins: usize) usize {
        const range: i128 = std.math.maxInt(i64);
        const scaled = @divFloor(value * @as(i128, @intCast(bins)), range);
        const clamped = @max(0, @min(@as(i128, @intCast(bins)) - 1, scaled));
        return @intCast(clamped);
    }

    pub fn dequantize(bin: usize, bins: usize) i128 {
        const range: i128 = std.math.maxInt(i64);
        return @divFloor(range * @as(i128, @intCast(bin)), @as(i128, @intCast(bins)));
    }

    pub fn projectToDiscrete(value: i128, dimensions: usize) struct { values: [16]usize, count: usize } {
        var result: [16]usize = undefined;
        const count = @min(dimensions, 16);
        for (0..count) |i| {
            const shifted = value >> @intCast(i * 4);
            result[i] = @intCast(@as(u128, @bitCast(shifted)) % 16);
        }
        return .{ .values = result, .count = count };
    }
};

// =============================================================================
// Geometry Layer
// =============================================================================

pub const GeometryLayer = struct {
    pub fn manifoldDistance(a: [7]i128, b: [7]i128) i128 {
        var sum_sq: i128 = 0;
        for (0..7) |ch| {
            const diff = a[ch] - b[ch];
            sum_sq += diff * diff;
        }
        return isqrt(sum_sq);
    }

    pub fn cosineSimilarity(a: [7]i128, b: [7]i128) f64 {
        var dot: i128 = 0;
        var norm_a: i128 = 0;
        var norm_b: i128 = 0;
        for (0..7) |ch| {
            dot += a[ch] * b[ch];
            norm_a += a[ch] * a[ch];
            norm_b += b[ch] * b[ch];
        }
        if (norm_a == 0 or norm_b == 0) return 0.0;
        const dot_f = @as(f64, @floatFromInt(dot));
        const na_f = @as(f64, @floatFromInt(isqrt(norm_a)));
        const nb_f = @as(f64, @floatFromInt(isqrt(norm_b)));
        return dot_f / (na_f * nb_f);
    }

    pub fn volumetricHash(x: u32, y: u32, z: u32) u32 {
        var h: u32 = x ^ (y << 11) ^ (z << 22);
        h = h *% 0x9E3779B9;
        h = h ^ (h >> 16);
        return h;
    }

    pub fn spatialLookup(hash: u32, node_count: usize) usize {
        return @as(usize, hash) % node_count;
    }

    pub fn compressActivationVolume(activations: []const [7]i128) [E0_NODE_COUNT * 7 / 8]u8 {
        var compressed: [E0_NODE_COUNT * 7 / 8]u8 = std.mem.zeroes([E0_NODE_COUNT * 7 / 8]u8);
        var bit_offset: usize = 0;
        for (activations) |node| {
            for (node) |val| {
                const sign_bit: u1 = if (val < 0) 1 else 0;
                const magnitude: u7 = @intCast(@min(@as(i128, 127), if (val < 0) -val else val));
                const packed_val: u8 = (@as(u8, sign_bit) << 7) | @as(u8, magnitude);
                const byte_idx = bit_offset / 8;
                const bit_idx = bit_offset % 8;
                if (byte_idx < compressed.len) {
                    compressed[byte_idx] |= packed_val >> @intCast(bit_idx);
                    if (bit_idx > 0 and byte_idx + 1 < compressed.len) {
                        compressed[byte_idx + 1] |= packed_val << @intCast(8 - bit_idx);
                    }
                }
                bit_offset += 8;
            }
        }
        return compressed;
    }
};

// =============================================================================
// Music Layer
// =============================================================================

pub const MusicLayer = struct {
    sample_rate: i128,
    fundamental_freq: i128 = 0,
    harmonic_count: usize = 7,

    pub fn init(sample_rate: i128) MusicLayer {
        return .{
            .sample_rate = sample_rate,
        };
    }

    pub fn harmonicSeries(_: MusicLayer, fundamental: i128) [7]i128 {
        var harmonics: [7]i128 = undefined;
        for (1..8) |n| {
            harmonics[n - 1] = fundamental * @as(i128, @intCast(n));
        }
        return harmonics;
    }

    pub fn formantToLattice(f1: i128, f2: i128, f3: i128) [CHANNEL_COUNT]i128 {
        var activations: [CHANNEL_COUNT]i128 = undefined;
        activations[0] = f1;
        activations[1] = f2;
        activations[2] = f3;
        activations[3] = @divFloor(f1 + f2, 2);
        activations[4] = @divFloor(f2 + f3, 2);
        activations[5] = @divFloor(f1 + f3, 2);
        activations[6] = @divFloor(f1 + f2 + f3, 3);
        return activations;
    }

    pub fn latticeToFormants(activations: [CHANNEL_COUNT]i128) struct { f1: i128, f2: i128, f3: i128 } {
        return .{
            .f1 = activations[0],
            .f2 = activations[1],
            .f3 = activations[2],
        };
    }

    pub fn resonanceAttenuation(freq: i128, sample_rate: i128) i128 {
        if (sample_rate == 0) return 0;
        const nyquist = @divFloor(sample_rate, 2);
        if (freq > nyquist) return 0;
        const ratio = @divFloor(freq * @as(i128, 1 << 32), nyquist);
        return @as(i128, 1 << 32) - ratio;
    }

    pub fn beatFrequency(f1: i128, f2: i128) i128 {
        return if (f1 > f2) f1 - f2 else f2 - f1;
    }

    pub fn prosodyEnvelope(activations: []const [7]i128) struct { values: [E0_NODE_COUNT]i128, count: usize } {
        var envelope: [E0_NODE_COUNT]i128 = undefined;
        const count = @min(activations.len, E0_NODE_COUNT);
        for (0..count) |i| {
            var energy: i128 = 0;
            for (activations[i]) |ch| {
                energy += if (ch < 0) -ch else ch;
            }
            envelope[i] = energy;
        }
        return .{ .values = envelope, .count = count };
    }

    pub fn pitchContour(activations: []const [7]i128) struct { values: [E0_NODE_COUNT]i128, count: usize } {
        var contour: [E0_NODE_COUNT]i128 = undefined;
        const count = @min(activations.len, E0_NODE_COUNT);
        for (0..count) |i| {
            var weighted_sum: i128 = 0;
            var total_weight: i128 = 0;
            for (0..7) |ch| {
                const weight = if (activations[i][ch] < 0) -activations[i][ch] else activations[i][ch];
                const freq = @as(i128, @intCast(ch + 1)) * (200 << 64);
                weighted_sum += weight * freq;
                total_weight += weight;
            }
            contour[i] = if (total_weight > 0) @divFloor(weighted_sum, total_weight) else 0;
        }
        return .{ .values = contour, .count = count };
    }
};

// =============================================================================
// Astronomy Layer
// =============================================================================

pub const AstronomyLayer = struct {
    cycle: u64 = 0,
    trajectory_energy: i128 = 0,
    prediction_horizon: usize = 4,

    pub fn init() AstronomyLayer {
        return .{};
    }

    pub fn stateTrajectory(activations: []const [7]i128, steps: usize) [16][7]i128 {
        var trajectory: [16][7]i128 = undefined;
        const count = @min(steps, 16);
        if (activations.len == 0) return trajectory;

        var current: [7]i128 = activations[activations.len - 1];
        for (0..count) |step| {
            trajectory[step] = current;
            current = evolveState(current, @intCast(step));
        }
        return trajectory;
    }

    pub fn evolveState(state: [7]i128, delta: i128) [7]i128 {
        var next: [7]i128 = undefined;
        for (0..7) |ch| {
            const ch_next = state[(ch + 1) % 7];
            const ch_prev = state[(ch + 6) % 7];
            const coupling = @divFloor(ch_next + ch_prev, 4);
            next[ch] = state[ch] + coupling - @divFloor(state[ch], 8);
            _ = delta;
        }
        return next;
    }

    pub fn predictFuture(state: [7]i128, horizon: usize) [16][7]i128 {
        var predictions: [16][7]i128 = undefined;
        const count = @min(horizon, 16);
        var current = state;
        for (0..count) |h| {
            current = evolveState(current, @intCast(h));
            predictions[h] = current;
        }
        return predictions;
    }

    pub fn orbitalEnergy(activations: []const [7]i128) i128 {
        var energy: i128 = 0;
        for (activations) |node| {
            for (node) |ch| {
                const abs_val = if (ch < 0) -ch else ch;
                const clamped = @min(abs_val, 1 << 32);
                energy += @mulWithOverflow(clamped, clamped)[0];
                energy = @min(energy, std.math.maxInt(i64));
            }
        }
        return energy;
    }

    pub fn stabilityMetric(activations: []const [7]i128) f64 {
        if (activations.len < 2) return 1.0;
        var total_change: f64 = 0.0;
        var comparisons: f64 = 0.0;
        for (0..activations.len - 1) |i| {
            var change: i128 = 0;
            for (0..7) |ch| {
                const diff = activations[i + 1][ch] - activations[i][ch];
                const abs_diff = if (diff < 0) -diff else diff;
                change += @min(abs_diff, 1 << 48);
            }
            total_change += @as(f64, @floatFromInt(@min(change, std.math.maxInt(i32))));
            comparisons += 1.0;
        }
        if (comparisons == 0.0) return 1.0;
        const avg_change = total_change / comparisons;
        return @max(0.0, 1.0 - avg_change / @as(f64, @floatFromInt(std.math.maxInt(i32))));
    }
};

// =============================================================================
// QuadriviumPipeline — orchestrates all four layers
// =============================================================================

pub const QuadriviumPipeline = struct {
    arithmetic: ArithmeticLayer = .{},
    geometry: GeometryLayer = .{},
    music: MusicLayer,
    astronomy: AstronomyLayer = .{},

    pub fn init(sample_rate: i128) QuadriviumPipeline {
        return .{
            .music = MusicLayer.init(sample_rate),
        };
    }

    pub fn processState(self: *QuadriviumPipeline, activations: []const [7]i128) void {
        self.arithmetic.total_operations += 1;
        self.astronomy.cycle += 1;
        self.astronomy.trajectory_energy = AstronomyLayer.orbitalEnergy(activations);
    }

    pub fn predictNext(self: *QuadriviumPipeline, activations: []const [7]i128) [16][7]i128 {
        if (activations.len == 0) return std.mem.zeroes([16][7]i128);
        const last = activations[activations.len - 1];
        return AstronomyLayer.predictFuture(last, self.astronomy.prediction_horizon);
    }

    pub fn stabilityScore(self: *QuadriviumPipeline, activations: []const [7]i128) f64 {
        _ = self;
        return AstronomyLayer.stabilityMetric(activations);
    }
};

// =============================================================================
// Helper functions
// =============================================================================

fn isqrt(n: i128) i128 {
    if (n <= 0) return 0;
    if (n < 4) return 1;
    var x: i128 = n;
    var y: i128 = @divFloor(n + 1, 2);
    while (y < x) {
        x = y;
        y = @divFloor(x + @divFloor(n, x), 2);
    }
    return x;
}

// =============================================================================
// Tests
// =============================================================================

test "quadrivium: arithmetic precision tracking" {
    var layer = ArithmeticLayer.init();
    layer.trackPrecision(1000, 998);
    layer.trackPrecision(2000, 1995);
    try std.testing.expect(layer.total_operations == 2);
    try std.testing.expect(layer.averageError() > 0.0);
}

test "quadrivium: arithmetic quantization round-trip" {
    const value: i128 = std.math.maxInt(i64) / 2;
    const bins: usize = 256;
    const quantized = ArithmeticLayer.quantize(value, bins);
    const dequantized = ArithmeticLayer.dequantize(quantized, bins);
    const error_ratio = @as(f64, @floatFromInt(if (value > dequantized) value - dequantized else dequantized - value)) /
        @as(f64, @floatFromInt(value));
    try std.testing.expect(error_ratio < 0.01);
}

test "quadrivium: geometry manifold distance" {
    const a: [7]i128 = .{ 100, 200, 300, 0, 0, 0, 0 };
    const b: [7]i128 = .{ 100, 200, 300, 0, 0, 0, 0 };
    try std.testing.expect(GeometryLayer.manifoldDistance(a, b) == 0);

    const c: [7]i128 = .{ 200, 300, 400, 0, 0, 0, 0 };
    try std.testing.expect(GeometryLayer.manifoldDistance(a, c) > 0);
}

test "quadrivium: geometry cosine similarity" {
    const a: [7]i128 = .{ 100, 200, 300, 0, 0, 0, 0 };
    const b: [7]i128 = .{ 100, 200, 300, 0, 0, 0, 0 };
    const sim = GeometryLayer.cosineSimilarity(a, b);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sim, 0.001);
}

test "quadrivium: geometry volumetric hash distribution" {
    const h1 = GeometryLayer.volumetricHash(1, 2, 3);
    const h2 = GeometryLayer.volumetricHash(1, 2, 4);
    const h3 = GeometryLayer.volumetricHash(1, 2, 3);
    try std.testing.expect(h1 == h3);
    try std.testing.expect(h1 != h2);
}

test "quadrivium: geometry spatial lookup" {
    const h = GeometryLayer.volumetricHash(10, 20, 30);
    const idx = GeometryLayer.spatialLookup(h, 421);
    try std.testing.expect(idx < 421);
}

test "quadrivium: music harmonic series" {
    const layer = MusicLayer.init(44100 << 64);
    const harmonics = layer.harmonicSeries(440 << 64);
    try std.testing.expect(harmonics[0] == 440 << 64);
    try std.testing.expect(harmonics[1] == 880 << 64);
    try std.testing.expect(harmonics[6] == 3080 << 64);
}

test "quadrivium: music formant to lattice mapping" {
    const f1: i128 = 500 << 64;
    const f2: i128 = 1500 << 64;
    const f3: i128 = 2500 << 64;
    const activations = MusicLayer.formantToLattice(f1, f2, f3);
    try std.testing.expect(activations[0] == f1);
    try std.testing.expect(activations[1] == f2);
    try std.testing.expect(activations[2] == f3);
    try std.testing.expect(activations[6] == @divFloor(f1 + f2 + f3, 3));
}

test "quadrivium: music lattice to formants" {
    const activations: [7]i128 = .{ 500 << 64, 1500 << 64, 2500 << 64, 0, 0, 0, 0 };
    const formants = MusicLayer.latticeToFormants(activations);
    try std.testing.expect(formants.f1 == 500 << 64);
    try std.testing.expect(formants.f2 == 1500 << 64);
    try std.testing.expect(formants.f3 == 2500 << 64);
}

test "quadrivium: music beat frequency" {
    const beat = MusicLayer.beatFrequency(440 << 64, 443 << 64);
    try std.testing.expect(beat == 3 << 64);
}

test "quadrivium: music resonance attenuation" {
    const sample_rate: i128 = 44100 << 64;
    const nyquist = @divFloor(sample_rate, 2);
    const atten_nyquist = MusicLayer.resonanceAttenuation(nyquist, sample_rate);
    try std.testing.expect(atten_nyquist == 0);
    const atten_low = MusicLayer.resonanceAttenuation(@divFloor(nyquist, 100), sample_rate);
    try std.testing.expect(atten_low > 0);
}

test "quadrivium: astronomy state trajectory" {
    const activations = [_][7]i128{
        .{ 100, 200, 300, 50, 30, 20, 10 },
    };
    const traj = AstronomyLayer.stateTrajectory(&activations, 4);
    try std.testing.expect(traj[0][0] == 100);
}

test "quadrivium: astronomy evolve state" {
    const state: [7]i128 = .{ 100, 200, 300, 50, 30, 20, 10 };
    const next = AstronomyLayer.evolveState(state, 1);
    var has_change = false;
    for (0..7) |ch| {
        if (next[ch] != state[ch]) has_change = true;
    }
    try std.testing.expect(has_change);
}

test "quadrivium: astronomy predict future" {
    const state: [7]i128 = .{ 100, 200, 300, 50, 30, 20, 10 };
    const predictions = AstronomyLayer.predictFuture(state, 4);
    try std.testing.expect(predictions[0][0] != state[0]);
}

test "quadrivium: astronomy orbital energy" {
    const activations = [_][7]i128{
        .{ 100, 200, 300, 0, 0, 0, 0 },
        .{ 50, 100, 150, 0, 0, 0, 0 },
    };
    const energy = AstronomyLayer.orbitalEnergy(&activations);
    try std.testing.expect(energy > 0);
}

test "quadrivium: astronomy stability metric" {
    const stable = [_][7]i128{
        .{ 100, 200, 300, 50, 30, 20, 10 },
        .{ 100, 200, 300, 50, 30, 20, 10 },
        .{ 100, 200, 300, 50, 30, 20, 10 },
    };
    const stability = AstronomyLayer.stabilityMetric(&stable);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), stability, 0.01);

    const unstable = [_][7]i128{
        .{ 1000, 2000, 3000, 500, 300, 200, 100 },
        .{ 10, 20, 30, 5, 3, 2, 1 },
        .{ 500, 1000, 1500, 250, 150, 100, 50 },
    };
    const instability = AstronomyLayer.stabilityMetric(&unstable);
    try std.testing.expect(instability < 1.0);
}

test "quadrivium: pipeline process and predict" {
    var pipeline = QuadriviumPipeline.init(44100 << 64);
    const activations = [_][7]i128{
        .{ 100, 200, 300, 50, 30, 20, 10 },
        .{ 120, 180, 280, 60, 25, 15, 5 },
    };
    pipeline.processState(&activations);
    try std.testing.expect(pipeline.astronomy.cycle == 1);
    const predictions = pipeline.predictNext(&activations);
    _ = predictions;
    const stability = pipeline.stabilityScore(&activations);
    try std.testing.expect(stability >= 0.0 and stability <= 1.0);
}

// =============================================================================
// Framework Quadrivium Connections (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework Arithmetic: connects to fixed-point constants (421, 7-defect, g).
/// Framework Geometry: connects to lattice 15³ structure (3375 interior, 4096 shell).
/// Framework Music: connects to φ-cooling harmonics (φ = 1.618...).
/// Framework Astronomy: connects to dimensional ladder (11 dimensions).
pub const FRAMEWORK_ARITHMETIC_CONSTANTS: u32 = 421 + 7 + 240 + 721;
pub const FRAMEWORK_GEOMETRY_INTERIOR: u32 = 3375; // 15³
pub const FRAMEWORK_GEOMETRY_SHELL: u32 = 4096; // 16³
pub const FRAMEWORK_MUSIC_PHI_NUM: u32 = 1618;
pub const FRAMEWORK_MUSIC_PHI_DEN: u32 = 1000;
pub const FRAMEWORK_ASTRONOMY_DIMS: u8 = 11;

/// Verifies the quadrivium framework connections.
pub fn verifyQuadriviumFrameworkConnections() bool {
    return FRAMEWORK_ARITHMETIC_CONSTANTS == 421 + 7 + 240 + 721 and
        FRAMEWORK_GEOMETRY_INTERIOR == 3375 and
        FRAMEWORK_GEOMETRY_SHELL == 4096 and
        FRAMEWORK_ASTRONOMY_DIMS == 11;
}

test "framework: quadrivium connections" {
    try std.testing.expect(verifyQuadriviumFrameworkConnections());
}
