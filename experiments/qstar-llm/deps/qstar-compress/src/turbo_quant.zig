//! turbo_quant.zig — TurboQuant-inspired vector quantization sidecar.
//!
//! Ports the core techniques from Google's TurboQuant (as implemented in
//! the turbovec project) to Zig for use as a floating-point sidecar in the
//! Qstar lattice computing system.
//!
//! Pipeline:
//!   1. Normalize — extract L2 norm, store as f64
//!   2. Rotate — deterministic block-Hadamard + permutation (decorrelates coords)
//!   3. Quantize — Lloyd-Max scalar quantization (2-bit or 4-bit)
//!   4. Bit-pack — tight packing of quantized coordinates
//!   5. Length-renormalize — store scale factor to correct quantization bias
//!
//! This is a FLOATING-POINT SIDECAR. Core lattice state remains integer-only
//! (Q32.32). This module is used for compression/projection math only and
//! never feeds back into core state transitions.
//!
//! References:
//!   - TurboQuant: https://arxiv.org/abs/2504.19874 (ICLR 2026)
//!   - RaBitQ: https://arxiv.org/abs/2405.12497 (SIGMOD 2024)

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Number of block-Hadamard rounds (frozen invariant, matching turbovec).
pub const K_ROUNDS: usize = 2;

/// ChaCha-style seed for deterministic permutation (matching turbovec's seed=42).
pub const ROTATION_SEED: u64 = 42;

/// Supported bit widths for quantization.
pub const BitWidth = enum(u8) { two = 2, four = 4 };

/// Number of E0 nodes (matching lattice constants).
pub const E0_NODE_COUNT: usize = 421;

/// Number of channels per node.
pub const CHANNEL_COUNT: usize = 7;

// =============================================================================
// Deterministic PRNG (xorshift64 — simple, deterministic, no deps)
// =============================================================================

/// Deterministic PRNG for reproducible rotations.
/// Uses xorshift64* seeded with a fixed value — identical across all platforms.
pub const Prng = struct {
    state: u64,

    pub fn init(seed: u64) Prng {
        return .{ .state = seed | 1 }; // ensure non-zero
    }

    pub fn next(self: *Prng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// Random u32 in [0, n)
    pub fn range(self: *Prng, n: u32) u32 {
        return @intCast(self.next() % n);
    }

    /// Random ±1 sign flip
    pub fn sign(self: *Prng) f64 {
        return if (self.next() & 1 == 0) 1.0 else -1.0;
    }

    /// Random float in [0, 1)
    pub fn float(self: *Prng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, 1 << 53);
    }
};

// =============================================================================
// Step 1: L2 Normalization
// =============================================================================

/// Extracts the L2 norm from a vector and returns (unit_vector, norm).
/// The unit vector has the same direction but L2 norm = 1.0.
pub fn normalize(allocator: std.mem.Allocator, vec: []const f64) !struct { unit: []f64, norm: f64 } {
    var norm_sq: f64 = 0;
    for (vec) |v| norm_sq += v * v;
    const norm = @sqrt(norm_sq);

    var unit = try allocator.alloc(f64, vec.len);
    if (norm > 0) {
        const inv_norm = 1.0 / norm;
        for (vec, 0..) |v, i| unit[i] = v * inv_norm;
    } else {
        @memset(unit, 0);
    }

    return .{ .unit = unit, .norm = norm };
}

/// Reconstructs the original vector from a unit vector and norm.
pub fn denormalize(allocator: std.mem.Allocator, unit: []const f64, norm: f64) ![]f64 {
    var vec = try allocator.alloc(f64, unit.len);
    for (unit, 0..) |u, i| vec[i] = u * norm;
    return vec;
}

// =============================================================================
// Step 2: Deterministic Block-Hadamard Rotation
// =============================================================================

/// Largest power-of-2 divisor of n (block size for Hadamard).
/// For odd n (like 421), returns 1 (no WHT, just permutation + sign flips).
fn largestPow2Divisor(n: usize) usize {
    if (n == 0) return 1;
    var p: usize = 1;
    var v = n;
    while (v % 2 == 0) {
        p *= 2;
        v /= 2;
    }
    return p;
}

/// In-place normalized Walsh-Hadamard transform on a block of size n (power of 2).
/// Multiplies by 1/sqrt(n) for orthogonality.
fn walshHadamard(data: []f64) void {
    const n = data.len;
    if (n <= 1) return;
    std.debug.assert(n & (n - 1) == 0); // power of 2

    // Bit-reversal permutation
    const bits: u6 = @intCast(std.math.log2_int(usize, n));
    for (0..n) |i| {
        var j: usize = 0;
        var v = i;
        for (0..bits) |_| {
            j <<= 1;
            j |= (v & 1);
            v >>= 1;
        }
        if (j > i) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
    }

    // Butterfly stages — normalize by 1/sqrt(2) per stage so total is 1/sqrt(n)
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len / 2;
        const inv_sqrt_2 = 1.0 / @sqrt(2.0);
        var group: usize = 0;
        while (group < n) : (group += len) {
            for (0..half) |k| {
                const even = data[group + k];
                const odd = data[group + k + half];
                data[group + k] = (even + odd) * inv_sqrt_2;
                data[group + k + half] = (even - odd) * inv_sqrt_2;
            }
        }
    }
}

/// Generates a deterministic Fisher-Yates permutation of [0, n).
fn makePermutation(allocator: std.mem.Allocator, n: usize, seed: u64) ![]usize {
    var perm = try allocator.alloc(usize, n);
    for (0..n) |i| perm[i] = i;

    var prng = Prng.init(seed);
    var i: usize = n;
    while (i > 1) {
        i -= 1;
        const j = prng.range(@intCast(i + 1));
        const tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }

    return perm;
}

/// Generates deterministic ±1 sign flips for n coordinates.
fn makeSignFlips(allocator: std.mem.Allocator, n: usize, seed: u64) ![]f64 {
    const signs = try allocator.alloc(f64, n);
    var prng = Prng.init(seed);
    for (signs) |*s| s.* = prng.sign();
    return signs;
}

/// Applies one round of the block-Hadamard rotation:
/// 1. Global permutation
/// 2. Sign flips
/// 3. In-block normalized Walsh-Hadamard
fn rotateRound(allocator: std.mem.Allocator, data: []f64, round: u32) !void {
    const n = data.len;
    const block_size = largestPow2Divisor(n);
    const perm_seed = ROTATION_SEED + round * 1000;
    const perm = try makePermutation(allocator, n, perm_seed);
    defer allocator.free(perm);

    var temp = try allocator.alloc(f64, n);
    defer allocator.free(temp);
    for (0..n) |i| temp[i] = data[perm[i]];
    @memcpy(data, temp);

    // 2. Sign flips
    const sign_seed = ROTATION_SEED + round * 1000 + 500;
    const signs = try makeSignFlips(allocator, n, sign_seed);
    defer allocator.free(signs);
    for (0..n) |i| data[i] *= signs[i];

    // 3. In-block Walsh-Hadamard
    var offset: usize = 0;
    while (offset < n) : (offset += block_size) {
        const end = @min(offset + block_size, n);
        const block = data[offset..end];
        if (block.len > 1) {
            walshHadamard(block);
        }
    }
}

/// Applies the full K-round rotation to a vector (in-place).
/// After rotation, each coordinate independently follows a near-Gaussian distribution.
pub fn rotate(allocator: std.mem.Allocator, data: []f64) !void {
    for (0..K_ROUNDS) |round| {
        try rotateRound(allocator, data, @intCast(round));
    }
}

/// Applies the inverse rotation (transpose of the rotation).
/// Since each component (permutation, sign flip, Walsh-Hadamard) is orthogonal,
/// the inverse is: reverse order, inverse each component.
pub fn inverseRotate(allocator: std.mem.Allocator, data: []f64) !void {
    var round: i32 = @as(i32, @intCast(K_ROUNDS)) - 1;
    while (round >= 0) : (round -= 1) {
        try inverseRotateRound(allocator, data, @intCast(round));
    }
}

fn inverseRotateRound(allocator: std.mem.Allocator, data: []f64, round: u32) !void {
    const n = data.len;
    const block_size = largestPow2Divisor(n);

    // 3. Inverse Walsh-Hadamard (self-inverse with normalization)
    var offset: usize = 0;
    while (offset < n) : (offset += block_size) {
        const end = @min(offset + block_size, n);
        const block = data[offset..end];
        if (block.len > 1) {
            walshHadamard(block);
        }
    }

    // 2. Inverse sign flips (same signs — multiply again)
    const sign_seed = ROTATION_SEED + round * 1000 + 500;
    const signs = try makeSignFlips(allocator, n, sign_seed);
    defer allocator.free(signs);
    for (0..n) |i| data[i] *= signs[i];

    // 1. Inverse permutation
    const perm_seed = ROTATION_SEED + round * 1000;
    const perm = try makePermutation(allocator, n, perm_seed);
    defer allocator.free(perm);

    var temp = try allocator.alloc(f64, n);
    defer allocator.free(temp);
    for (0..n) |i| temp[perm[i]] = data[i];
    @memcpy(data, temp);
}

// =============================================================================
// Step 3: Lloyd-Max Scalar Quantization
// =============================================================================

/// Lloyd-Max codebook: boundaries and centroids for a given bit width.
pub const Codebook = struct {
    bits: u8,
    /// n_levels - 1 boundaries between buckets
    boundaries: []f64,
    /// n_levels centroids (reconstruction values)
    centroids: []f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Codebook) void {
        self.allocator.free(self.boundaries);
        self.allocator.free(self.centroids);
    }

    pub fn nLevels(self: Codebook) usize {
        return @as(usize, 1) << @intCast(self.bits);
    }
};

/// Computes the standard normal N(0, 1/d) PDF for a given dimension d.
/// After rotation, coordinates follow approximately this distribution.
fn normalPdf(x: f64, dim: usize) f64 {
    const sigma = 1.0 / @sqrt(@as(f64, @floatFromInt(dim)));
    const coeff = 1.0 / (sigma * @sqrt(2.0 * std.math.pi));
    return coeff * @exp(-0.5 * (x / sigma) * (x / sigma));
}

/// Computes the Lloyd-Max codebook for a given bit width and dimension.
/// Uses the normal distribution N(0, 1/d) as the target (post-rotation).
pub fn computeCodebook(allocator: std.mem.Allocator, bits: u8, dim: usize) !Codebook {
    const n_levels = @as(usize, 1) << @intCast(bits);
    const centroids = try allocator.alloc(f64, n_levels);
    errdefer allocator.free(centroids);

    const sigma = 1.0 / @sqrt(@as(f64, @floatFromInt(dim)));
    const spread = 3.0 * sigma;

    // Initialize centroids evenly within ±3σ
    for (centroids, 0..) |*c, i| {
        c.* = -spread + 2.0 * spread * @as(f64, @floatFromInt(i)) /
            @as(f64, @floatFromInt(n_levels - 1));
    }

    // Lloyd-Max iterations
    const max_iter: usize = 200;
    const tol: f64 = 1e-10;

    var new_centroids = try allocator.alloc(f64, n_levels);
    defer allocator.free(new_centroids);

    var edges = try allocator.alloc(f64, n_levels + 1);
    defer allocator.free(edges);

    for (0..max_iter) |_| {
        // Boundaries = midpoints between consecutive centroids
        edges[0] = -std.math.inf(f64);
        edges[n_levels] = std.math.inf(f64);
        for (1..n_levels) |i| {
            edges[i] = (centroids[i - 1] + centroids[i]) / 2.0;
        }

        for (0..n_levels) |i| {
            const lo = edges[i];
            const hi = edges[i + 1];

            // Numerical integration of x * pdf(x) from lo to hi
            // Using midpoint rule with 1000 samples
            const n_samples: usize = 1000;
            const range_val = hi - lo;
            if (range_val <= 0 or std.math.isInf(range_val)) {
                // For unbounded edges, use ±5σ as practical limits
                const practical_lo = if (std.math.isInf(lo)) -5.0 * sigma else lo;
                const practical_hi = if (std.math.isInf(hi)) 5.0 * sigma else hi;
                const practical_range = practical_hi - practical_lo;
                if (practical_range <= 0) {
                    new_centroids[i] = centroids[i];
                    continue;
                }
                const dx = practical_range / @as(f64, @floatFromInt(n_samples));
                var sum_xpdf: f64 = 0;
                var sum_pdf: f64 = 0;
                for (0..n_samples) |j| {
                    const x = practical_lo + dx * (@as(f64, @floatFromInt(j)) + 0.5);
                    const p = normalPdf(x, dim);
                    sum_xpdf += x * p;
                    sum_pdf += p;
                }
                if (sum_pdf < 1e-15) {
                    new_centroids[i] = centroids[i];
                } else {
                    new_centroids[i] = sum_xpdf / sum_pdf;
                }
            } else {
                const dx = range_val / @as(f64, @floatFromInt(n_samples));
                var sum_xpdf: f64 = 0;
                var sum_pdf: f64 = 0;
                for (0..n_samples) |j| {
                    const x = lo + dx * (@as(f64, @floatFromInt(j)) + 0.5);
                    const p = normalPdf(x, dim);
                    sum_xpdf += x * p;
                    sum_pdf += p;
                }
                if (sum_pdf < 1e-15) {
                    new_centroids[i] = centroids[i];
                } else {
                    new_centroids[i] = sum_xpdf / sum_pdf;
                }
            }
        }

        // Check convergence
        var max_change: f64 = 0;
        for (centroids, new_centroids) |old, new| {
            const change = @abs(old - new);
            if (change > max_change) max_change = change;
        }

        @memcpy(centroids, new_centroids);

        if (max_change < tol) break;
    }

    // Compute final boundaries
    var boundaries = try allocator.alloc(f64, n_levels - 1);
    for (1..n_levels) |i| {
        boundaries[i - 1] = (centroids[i - 1] + centroids[i]) / 2.0;
    }

    return .{
        .bits = bits,
        .boundaries = boundaries,
        .centroids = centroids,
        .allocator = allocator,
    };
}

/// Quantizes a single value using the codebook. Returns the bucket index.
pub fn quantizeValue(cb: Codebook, value: f64) u8 {
    for (cb.boundaries, 0..) |boundary, i| {
        if (value < boundary) {
            return @intCast(i);
        }
    }
    return @intCast(cb.nLevels() - 1);
}

/// Reconstructs a value from a bucket index using the centroid.
pub fn reconstructValue(cb: Codebook, bucket: u8) f64 {
    return cb.centroids[bucket];
}

/// Quantizes a vector of values using the codebook. Returns bucket indices.
pub fn quantizeVector(allocator: std.mem.Allocator, cb: Codebook, data: []const f64) ![]u8 {
    var buckets = try allocator.alloc(u8, data.len);
    for (data, 0..) |v, i| {
        buckets[i] = quantizeValue(cb, v);
    }
    return buckets;
}

/// Reconstructs a vector from bucket indices.
pub fn reconstructVector(allocator: std.mem.Allocator, cb: Codebook, buckets: []const u8) ![]f64 {
    var data = try allocator.alloc(f64, buckets.len);
    for (buckets, 0..) |b, i| {
        data[i] = reconstructValue(cb, b);
    }
    return data;
}

// =============================================================================
// Step 4: Bit-Packing
// =============================================================================

/// Packs an array of n-bit values into a byte array.
/// 2-bit: 4 values per byte
/// 4-bit: 2 values per byte
pub fn bitPack(allocator: std.mem.Allocator, values: []const u8, bits: u8) ![]u8 {
    const values_per_byte = 8 / @as(usize, @intCast(bits));
    const packed_size = (values.len + values_per_byte - 1) / values_per_byte;
    var packed_data = try allocator.alloc(u8, packed_size);
    @memset(packed_data, 0);

    const mask = (@as(u8, 1) << @intCast(bits)) - 1;
    for (values, 0..) |v, i| {
        const byte_idx = i / values_per_byte;
        const slot_idx = i % values_per_byte;
        const shift: u3 = @intCast(slot_idx * @as(usize, @intCast(bits)));
        packed_data[byte_idx] |= (v & mask) << shift;
    }

    return packed_data;
}

/// Unpacks an array of n-bit values from a byte array.
pub fn bitUnpack(allocator: std.mem.Allocator, packed_data: []const u8, bits: u8, count: usize) ![]u8 {
    var values = try allocator.alloc(u8, count);
    const values_per_byte = 8 / @as(usize, @intCast(bits));
    const mask = (@as(u8, 1) << @intCast(bits)) - 1;

    for (0..count) |i| {
        const byte_idx = i / values_per_byte;
        const slot_idx = i % values_per_byte;
        const shift: u3 = @intCast(slot_idx * @as(usize, @intCast(bits)));
        values[i] = (packed_data[byte_idx] >> shift) & mask;
    }

    return values;
}

/// Packed size in bytes for n values at the given bit width.
pub fn packedSize(n: usize, bits: u8) usize {
    const values_per_byte = 8 / @as(usize, @intCast(bits));
    return (n + values_per_byte - 1) / values_per_byte;
}

// =============================================================================
// Step 5: Length-Renormalization (RaBitQ-style correction)
// =============================================================================

/// Computes the length-renormalization scale factor.
/// scale = ||v|| / <u, x_hat>
/// where u is the rotated unit vector and x_hat is the centroid reconstruction.
pub fn computeScale(unit_rotated: []const f64, reconstructed: []const f64, norm: f64) f64 {
    var dot: f64 = 0;
    for (unit_rotated, reconstructed) |u, x| dot += u * x;
    if (@abs(dot) < 1e-15) return norm;
    return norm / dot;
}

/// Applies the scale factor during reconstruction.
pub fn applyScale(reconstructed: []f64, scale: f64) void {
    for (reconstructed) |*r| r.* *= scale;
}

// =============================================================================
// Full TurboQuant Encode/Decode Pipeline
// =============================================================================

/// TurboQuant encoded seed — compact representation.
pub const TQSeed = struct {
    /// Bit-packed quantized coordinates
    packed_codes: []u8,
    /// Length-renormalization scale factor
    scale: f64,
    /// Original L2 norm
    norm: f64,
    /// Bit width used
    bits: u8,
    /// Number of dimensions (nodes)
    dim: usize,
    /// Original data length (for recovery)
    original_len: usize,
    /// CRC32 checksum of original data
    checksum: u32,
    /// TQ+ calibration shifts (per-coordinate)
    calib_shifts: ?[]f64,
    /// TQ+ calibration scales (per-coordinate)
    calib_scales: ?[]f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: TQSeed) void {
        self.allocator.free(self.packed_codes);
        if (self.calib_shifts) |s| self.allocator.free(s);
        if (self.calib_scales) |s| self.allocator.free(s);
    }

    /// Total size in bytes (for capacity measurement).
    pub fn sizeBytes(self: TQSeed) usize {
        var total: usize = self.packed_codes.len + @sizeOf(f64) * 2 + @sizeOf(u8) + @sizeOf(usize) * 2 + @sizeOf(u32);
        if (self.calib_shifts) |s| total += s.len * @sizeOf(f64);
        if (self.calib_scales) |s| total += s.len * @sizeOf(f64);
        return total;
    }
};

/// Encodes a vector of f64 values using the full TurboQuant pipeline.
/// Input: raw activation values as f64.
/// Output: compact TQSeed with bit-packed quantized codes + scale.
pub fn tqEncode(
    allocator: std.mem.Allocator,
    data: []const f64,
    bits: u8,
    original_len: usize,
    checksum: u32,
) !TQSeed {
    const dim = data.len;

    // Step 1: Normalize
    const norm_result = try normalize(allocator, data);
    defer allocator.free(norm_result.unit);
    const norm = norm_result.norm;
    const unit = norm_result.unit;

    // Step 2: Rotate (copy first since rotate is in-place)
    const rotated = try allocator.alloc(f64, dim);
    defer allocator.free(rotated);
    @memcpy(rotated, unit);
    try rotate(allocator, rotated);

    // Step 3: Compute codebook
    var cb = try computeCodebook(allocator, bits, dim);
    defer cb.deinit();

    // Step 4: Quantize
    const buckets = try quantizeVector(allocator, cb, rotated);
    defer allocator.free(buckets);

    // Step 5: Reconstruct for scale computation
    const reconstructed = try reconstructVector(allocator, cb, buckets);
    defer allocator.free(reconstructed);

    // Step 6: Compute length-renormalization scale
    const scale = computeScale(rotated, reconstructed, norm);

    // Step 7: Bit-pack
    const packed_codes = try bitPack(allocator, buckets, bits);

    return .{
        .packed_codes = packed_codes,
        .scale = scale,
        .norm = norm,
        .bits = bits,
        .dim = dim,
        .original_len = original_len,
        .checksum = checksum,
        .calib_shifts = null,
        .calib_scales = null,
        .allocator = allocator,
    };
}

/// Decodes a TQSeed back to f64 values.
pub fn tqDecode(allocator: std.mem.Allocator, seed: TQSeed) ![]f64 {
    // Step 1: Unpack quantized codes
    const buckets = try bitUnpack(allocator, seed.packed_codes, seed.bits, seed.dim);
    defer allocator.free(buckets);

    // Step 2: Compute codebook
    var cb = try computeCodebook(allocator, seed.bits, seed.dim);
    defer cb.deinit();

    // Step 3: Reconstruct from centroids
    const reconstructed = try reconstructVector(allocator, cb, buckets);
    defer allocator.free(reconstructed);

    // Step 4: Apply TQ+ calibration (if present)
    if (seed.calib_shifts != null and seed.calib_scales != null) {
        const shifts = seed.calib_shifts.?;
        const scales = seed.calib_scales.?;
        for (reconstructed, 0..) |*r, i| {
            r.* = (r.* - shifts[i]) / scales[i];
        }
    }

    // Step 5: Inverse rotate
    try inverseRotate(allocator, reconstructed);

    // Step 6: Apply length-renormalization scale
    applyScale(reconstructed, seed.scale);

    // Step 7: Return result (caller owns memory)
    const result = try allocator.alloc(f64, seed.dim);
    @memcpy(result, reconstructed);
    return result;
}

// =============================================================================
// TQ+ Calibration (per-coordinate shift/scale)
// =============================================================================

/// Calibration parameters fitted from a sample of rotated vectors.
pub const Calibration = struct {
    shifts: []f64,
    scales: []f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Calibration) void {
        self.allocator.free(self.shifts);
        self.allocator.free(self.scales);
    }
};

/// Fits TQ+ calibration from a sample of rotated unit vectors.
/// For each coordinate, computes shift and scale to map empirical
/// quantiles onto the codebook's outermost centroids.
pub fn fitCalibration(
    allocator: std.mem.Allocator,
    rotated_samples: []const []const f64,
    cb: Codebook,
) !Calibration {
    const dim = rotated_samples[0].len;
    var shifts = try allocator.alloc(f64, dim);
    var scales = try allocator.alloc(f64, dim);

    const n_samples = rotated_samples.len;
    const n_levels = cb.nLevels();

    for (0..dim) |d| {
        // Collect all values for this coordinate
        var values = try allocator.alloc(f64, n_samples);
        defer allocator.free(values);
        for (rotated_samples, 0..) |sample, i| {
            values[i] = sample[d];
        }

        // Sort to find quantiles
        std.mem.sort(f64, values, {}, std.sort.asc(f64));

        // Empirical quantile at the codebook's outermost centroid probability level
        const p_low = 0.5 / @as(f64, @floatFromInt(n_levels));
        const p_high = 1.0 - p_low;

        const idx_low = @as(usize, @intFromFloat(p_low * @as(f64, @floatFromInt(n_samples - 1))));
        const idx_high = @as(usize, @intFromFloat(p_high * @as(f64, @floatFromInt(n_samples - 1))));

        const emp_low = values[idx_low];
        const emp_high = values[idx_high];

        // Codebook's outermost centroids
        const cb_low = cb.centroids[0];
        const cb_high = cb.centroids[n_levels - 1];

        // Fit: (emp - shift) * scale = cb_target
        // We want: emp_low → cb_low, emp_high → cb_high
        // scale = (cb_high - cb_low) / (emp_high - emp_low)
        // shift = emp_low - cb_low / scale
        if (@abs(emp_high - emp_low) < 1e-15) {
            scales[d] = 1.0;
            shifts[d] = 0.0;
        } else {
            scales[d] = (cb_high - cb_low) / (emp_high - emp_low);
            shifts[d] = emp_low - cb_low / scales[d];
        }
    }

    return .{ .shifts = shifts, .scales = scales, .allocator = allocator };
}

// =============================================================================
// Channel-Mode TurboQuant (7 channels × 421 nodes)
// =============================================================================

/// Encodes 7 channels of activations as a single TQ seed with larger dimension.
/// Treats the 421×7 = 2947 values as one vector for rotation + quantization.
pub fn tqEncodeChannel(
    allocator: std.mem.Allocator,
    activations: [E0_NODE_COUNT * CHANNEL_COUNT]i64,
    bits: u8,
    original_len: usize,
    checksum: u32,
) !TQSeed {
    const total_dim = E0_NODE_COUNT * CHANNEL_COUNT;

    // Convert i64 activations to f64
    var data = try allocator.alloc(f64, total_dim);
    defer allocator.free(data);
    for (activations, 0..) |a, i| {
        data[i] = @as(f64, @floatFromInt(a));
    }

    return try tqEncode(allocator, data, bits, original_len, checksum);
}

/// Decodes a channel TQ seed back to i64 activations.
pub fn tqDecodeChannel(allocator: std.mem.Allocator, seed: TQSeed) ![E0_NODE_COUNT * CHANNEL_COUNT]i64 {
    const recovered = try tqDecode(allocator, seed);
    defer allocator.free(recovered);

    var result: [E0_NODE_COUNT * CHANNEL_COUNT]i64 = undefined;
    for (recovered, 0..) |v, i| {
        result[i] = @intFromFloat(@round(v));
    }
    return result;
}

// =============================================================================
// Utility: Convert between i64 activations and f64 vectors
// =============================================================================

/// Converts an array of i64 activations to f64 values.
pub fn i64ToF64(allocator: std.mem.Allocator, data: []const i64) ![]f64 {
    var result = try allocator.alloc(f64, data.len);
    for (data, 0..) |v, i| result[i] = @as(f64, @floatFromInt(v));
    return result;
}

/// Converts an array of f64 values to i64 activations (with rounding).
pub fn f64ToI64(allocator: std.mem.Allocator, data: []const f64) ![]i64 {
    var result = try allocator.alloc(i64, data.len);
    for (data, 0..) |v, i| result[i] = @intFromFloat(@round(v));
    return result;
}

// =============================================================================
// Unit Tests
// =============================================================================

test "Prng is deterministic" {
    var p1 = Prng.init(42);
    var p2 = Prng.init(42);
    for (0..100) |_| {
        try std.testing.expectEqual(p1.next(), p2.next());
    }
}

test "normalize: unit vector has L2 norm 1" {
    const allocator = std.testing.allocator;
    const vec = [_]f64{ 3.0, 4.0, 0.0 };
    const result = try normalize(allocator, &vec);
    defer allocator.free(result.unit);

    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.norm, 1e-10);

    var norm_sq: f64 = 0;
    for (result.unit) |u| norm_sq += u * u;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), @sqrt(norm_sq), 1e-10);
}

test "normalize: zero vector" {
    const allocator = std.testing.allocator;
    const vec = [_]f64{ 0.0, 0.0, 0.0 };
    const result = try normalize(allocator, &vec);
    defer allocator.free(result.unit);

    try std.testing.expectEqual(@as(f64, 0.0), result.norm);
    for (result.unit) |u| try std.testing.expectEqual(@as(f64, 0.0), u);
}

test "denormalize: round-trip" {
    const allocator = std.testing.allocator;
    const vec = [_]f64{ 3.0, 4.0 };
    const result = try normalize(allocator, &vec);
    defer allocator.free(result.unit);

    const recovered = try denormalize(allocator, result.unit, result.norm);
    defer allocator.free(recovered);

    for (vec, recovered) |orig, rec| {
        try std.testing.expectApproxEqAbs(orig, rec, 1e-10);
    }
}

test "largestPow2Divisor" {
    try std.testing.expectEqual(@as(usize, 1), largestPow2Divisor(0));
    try std.testing.expectEqual(@as(usize, 1), largestPow2Divisor(1));
    try std.testing.expectEqual(@as(usize, 1), largestPow2Divisor(3));
    try std.testing.expectEqual(@as(usize, 4), largestPow2Divisor(4));
    try std.testing.expectEqual(@as(usize, 2), largestPow2Divisor(10));
    try std.testing.expectEqual(@as(usize, 1), largestPow2Divisor(421));
    try std.testing.expectEqual(@as(usize, 64), largestPow2Divisor(64));
    try std.testing.expectEqual(@as(usize, 256), largestPow2Divisor(256));
}

test "walshHadamard: preserves L2 norm (orthogonal)" {
    var data = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var norm_sq_before: f64 = 0;
    for (data) |d| norm_sq_before += d * d;

    walshHadamard(&data);

    var norm_sq_after: f64 = 0;
    for (data) |d| norm_sq_after += d * d;

    try std.testing.expectApproxEqAbs(norm_sq_before, norm_sq_after, 1e-10);
}

test "walshHadamard: self-inverse" {
    var data = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    const original = data;
    walshHadamard(&data);
    walshHadamard(&data);

    for (original, data) |orig, transformed| {
        try std.testing.expectApproxEqAbs(orig, transformed, 1e-10);
    }
}

test "makePermutation: is a valid permutation" {
    const allocator = std.testing.allocator;
    const n: usize = 100;
    const perm = try makePermutation(allocator, n, 42);
    defer allocator.free(perm);

    var seen = [_]bool{false} ** 100;
    for (perm) |p| {
        try std.testing.expect(p < n);
        try std.testing.expect(!seen[p]);
        seen[p] = true;
    }
}

test "makePermutation: deterministic with same seed" {
    const allocator = std.testing.allocator;
    const perm1 = try makePermutation(allocator, 50, 123);
    defer allocator.free(perm1);
    const perm2 = try makePermutation(allocator, 50, 123);
    defer allocator.free(perm2);

    try std.testing.expectEqualSlices(usize, perm1, perm2);
}

test "makeSignFlips: all ±1" {
    const allocator = std.testing.allocator;
    const signs = try makeSignFlips(allocator, 100, 42);
    defer allocator.free(signs);

    for (signs) |s| {
        try std.testing.expect(s == 1.0 or s == -1.0);
    }
}

test "rotate: preserves L2 norm" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(f64, 256);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @as(f64, @floatFromInt(i)) / 100.0;

    var norm_sq_before: f64 = 0;
    for (data) |d| norm_sq_before += d * d;

    try rotate(allocator, data);

    var norm_sq_after: f64 = 0;
    for (data) |d| norm_sq_after += d * d;

    try std.testing.expectApproxEqAbs(norm_sq_before, norm_sq_after, 1e-6);
}

test "inverseRotate: round-trip recovers original" {
    const allocator = std.testing.allocator;
    const dim: usize = 64;
    const data = try allocator.alloc(f64, dim);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @as(f64, @floatFromInt(i)) / 10.0;

    const original = try allocator.alloc(f64, dim);
    defer allocator.free(original);
    @memcpy(original, data);

    try rotate(allocator, data);
    try inverseRotate(allocator, data);

    for (original, data) |orig, rec| {
        try std.testing.expectApproxEqAbs(orig, rec, 1e-8);
    }
}

test "computeCodebook: 2-bit has 4 levels" {
    const allocator = std.testing.allocator;
    var cb = try computeCodebook(allocator, 2, 421);
    defer cb.deinit();

    try std.testing.expectEqual(@as(usize, 4), cb.nLevels());
    try std.testing.expectEqual(@as(usize, 3), cb.boundaries.len);
    try std.testing.expectEqual(@as(usize, 4), cb.centroids.len);
}

test "computeCodebook: 4-bit has 16 levels" {
    const allocator = std.testing.allocator;
    var cb = try computeCodebook(allocator, 4, 421);
    defer cb.deinit();

    try std.testing.expectEqual(@as(usize, 16), cb.nLevels());
    try std.testing.expectEqual(@as(usize, 15), cb.boundaries.len);
    try std.testing.expectEqual(@as(usize, 16), cb.centroids.len);
}

test "computeCodebook: centroids are ordered" {
    const allocator = std.testing.allocator;
    var cb = try computeCodebook(allocator, 4, 421);
    defer cb.deinit();

    for (cb.centroids[1..], 0..) |c, i| {
        try std.testing.expect(c > cb.centroids[i]);
    }
}

test "computeCodebook: boundaries are between centroids" {
    const allocator = std.testing.allocator;
    var cb = try computeCodebook(allocator, 2, 100);
    defer cb.deinit();

    for (cb.boundaries, 0..) |b, i| {
        try std.testing.expect(b > cb.centroids[i]);
        try std.testing.expect(b < cb.centroids[i + 1]);
    }
}

test "quantizeValue: assigns correct bucket" {
    const allocator = std.testing.allocator;
    var cb = try computeCodebook(allocator, 2, 100);
    defer cb.deinit();

    try std.testing.expectEqual(@as(u8, 0), quantizeValue(cb, -100.0));
    try std.testing.expectEqual(@as(u8, 3), quantizeValue(cb, 100.0));
    const bucket_zero = quantizeValue(cb, 0.0);
    try std.testing.expect(bucket_zero == 1 or bucket_zero == 2);
}

test "quantizeVector + reconstructVector: round-trip" {
    const allocator = std.testing.allocator;
    const dim: usize = 64;
    var cb = try computeCodebook(allocator, 4, dim);
    defer cb.deinit();

    const data = try allocator.alloc(f64, dim);
    defer allocator.free(data);
    // Use values in the expected range N(0, 1/64) — sigma ≈ 0.125
    for (data, 0..) |*d, i| d.* = @sin(@as(f64, @floatFromInt(i)) * 0.1) * 0.1;

    const buckets = try quantizeVector(allocator, cb, data);
    defer allocator.free(buckets);
    const reconstructed = try reconstructVector(allocator, cb, buckets);
    defer allocator.free(reconstructed);

    // 4-bit quantization with 16 levels should have small error for in-range data
    var max_error: f64 = 0;
    for (data, reconstructed) |orig, rec| {
        const err = @abs(orig - rec);
        if (err > max_error) max_error = err;
    }
    // Error should be bounded by the quantization step size
    try std.testing.expect(max_error < 0.05);
}

test "bitPack + bitUnpack: 2-bit round-trip" {
    const allocator = std.testing.allocator;
    const values = [_]u8{ 0, 1, 2, 3, 3, 2, 1, 0, 0, 1, 2, 3 };
    const packed_data = try bitPack(allocator, &values, 2);
    defer allocator.free(packed_data);

    const unpacked = try bitUnpack(allocator, packed_data, 2, values.len);
    defer allocator.free(unpacked);

    try std.testing.expectEqualSlices(u8, &values, unpacked);
}

test "bitPack + bitUnpack: 4-bit round-trip" {
    const allocator = std.testing.allocator;
    const values = [_]u8{ 0, 5, 10, 15, 3, 7, 12, 8 };
    const packed_data = try bitPack(allocator, &values, 4);
    defer allocator.free(packed_data);

    const unpacked = try bitUnpack(allocator, packed_data, 4, values.len);
    defer allocator.free(unpacked);

    try std.testing.expectEqualSlices(u8, &values, unpacked);
}

test "packedSize: correct for 2-bit" {
    try std.testing.expectEqual(@as(usize, 106), packedSize(421, 2));
}

test "packedSize: correct for 4-bit" {
    try std.testing.expectEqual(@as(usize, 211), packedSize(421, 4));
}

test "computeScale: correct for known values" {
    const unit = [_]f64{ 1.0, 0.0, 0.0 };
    const reconstructed = [_]f64{ 0.9, 0.0, 0.0 };
    const norm: f64 = 5.0;

    const scale = computeScale(&unit, &reconstructed, norm);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 0.9), scale, 1e-10);
}

test "applyScale: multiplies all values" {
    var data = [_]f64{ 1.0, 2.0, 3.0 };
    applyScale(&data, 2.0);
    try std.testing.expectEqual(@as(f64, 2.0), data[0]);
    try std.testing.expectEqual(@as(f64, 4.0), data[1]);
    try std.testing.expectEqual(@as(f64, 6.0), data[2]);
}

test "tqEncode + tqDecode: 4-bit round-trip is close" {
    const allocator = std.testing.allocator;
    const dim: usize = 64; // power of 2 for proper WHT
    const data = try allocator.alloc(f64, dim);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @as(f64, @floatFromInt(i)) * 0.001; // small values for N(0,1/64)

    var seed = try tqEncode(allocator, data, 4, dim * 8, 0);
    defer seed.deinit();

    const recovered = try tqDecode(allocator, seed);
    defer allocator.free(recovered);

    // Check absolute error — TQ introduces quantization error but scale correction helps
    var max_error: f64 = 0;
    for (data, recovered) |orig, rec| {
        const err = @abs(orig - rec);
        if (err > max_error) max_error = err;
    }
    // Absolute error should be small (values are ~0.001 range)
    try std.testing.expect(max_error < 0.01);
}

test "tqEncode: seed size is much smaller than raw" {
    const allocator = std.testing.allocator;
    const dim: usize = 128; // power of 2 for proper WHT
    const data = try allocator.alloc(f64, dim);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @as(f64, @floatFromInt(i)) * 0.001;

    var seed_2bit = try tqEncode(allocator, data, 2, dim * 8, 0);
    defer seed_2bit.deinit();

    var seed_4bit = try tqEncode(allocator, data, 4, dim * 8, 0);
    defer seed_4bit.deinit();

    const raw_size = dim * @sizeOf(f64); // 128 * 8 = 1024 bytes
    const size_2bit = seed_2bit.sizeBytes();
    const size_4bit = seed_4bit.sizeBytes();

    // 2-bit: 128/4 = 32 bytes packed + overhead ≈ 50 bytes, much smaller than 1024
    try std.testing.expect(size_2bit < raw_size / 10);
    // 4-bit: 128/2 = 64 bytes packed + overhead ≈ 80 bytes, smaller than 1024
    try std.testing.expect(size_4bit < raw_size / 5);
}

test "i64ToF64 + f64ToI64: round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]i64{ 0, 42, -7, 1000000, -999999 };
    const f64_data = try i64ToF64(allocator, &data);
    defer allocator.free(f64_data);
    const recovered = try f64ToI64(allocator, f64_data);
    defer allocator.free(recovered);

    try std.testing.expectEqualSlices(i64, &data, recovered);
}

test "tqEncodeChannel + tqDecodeChannel: round-trip" {
    const allocator = std.testing.allocator;
    var activations: [E0_NODE_COUNT * CHANNEL_COUNT]i64 = undefined;
    for (&activations, 0..) |*a, i| a.* = @intCast(i % 100);

    var seed = try tqEncodeChannel(allocator, activations, 4, 1000, 0);
    defer seed.deinit();

    const recovered = try tqDecodeChannel(allocator, seed);

    // Check that most values are close (quantization introduces some error)
    var close_count: usize = 0;
    for (activations, recovered) |orig, rec| {
        if (@abs(orig - rec) <= 15) close_count += 1;
    }
    // At least 50% should be close (quantization is lossy, especially without WHT)
    try std.testing.expect(close_count > E0_NODE_COUNT * CHANNEL_COUNT * 5 / 10);
}

test "Codebook: 2-bit codebook for dim=421 has small centroids" {
    const allocator = std.testing.allocator;
    var cb = try computeCodebook(allocator, 2, 421);
    defer cb.deinit();

    // For dim=421, sigma = 1/sqrt(421) ≈ 0.0487
    // Centroids should be within ±5σ (practical integration limit)
    const sigma = 1.0 / @sqrt(@as(f64, 421));
    const expected_range = 5.0 * sigma;

    for (cb.centroids) |c| {
        try std.testing.expect(@abs(c) <= expected_range);
    }
}

test "fitCalibration: produces valid shifts and scales" {
    const allocator = std.testing.allocator;
    const dim: usize = 32;
    const n_samples: usize = 100;

    const samples = try allocator.alloc([]f64, n_samples);
    defer {
        for (samples) |s| allocator.free(s);
        allocator.free(samples);
    }
    var prng = Prng.init(99);
    for (samples) |*s| {
        s.* = try allocator.alloc(f64, dim);
        for (s.*) |*v| v.* = (prng.float() - 0.5) * 0.1;
    }

    var const_samples = try allocator.alloc([]const f64, n_samples);
    defer allocator.free(const_samples);
    for (samples, 0..) |s, i| const_samples[i] = s;

    var cb = try computeCodebook(allocator, 4, dim);
    defer cb.deinit();

    var cal = try fitCalibration(allocator, const_samples, cb);
    defer cal.deinit();

    try std.testing.expectEqual(dim, cal.shifts.len);
    try std.testing.expectEqual(dim, cal.scales.len);

    for (cal.scales) |s| try std.testing.expect(s > 0);
}
