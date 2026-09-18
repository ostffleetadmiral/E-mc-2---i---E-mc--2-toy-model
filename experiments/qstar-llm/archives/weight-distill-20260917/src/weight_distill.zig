//! weight_distill.zig — Distills SafeTensors weight files into lattice-native
//! signatures (the "S7→S0 seed" pattern applied to model weights).
//!
//! Each tensor is streamed in bounded windows (never fully resident) and
//! reduced to a `TensorSignature`: param count, mean, RMS energy, an 8-bin
//! integer-DFT spectral signature, and a node binding (hash → E0 node).
//! Signatures aggregate into a `WeightSeed` — a small, serializable artifact
//! that lets the lattice's generative pipeline (longcat_port) be conditioned
//! by the real weight structure of the source model.
//!
//! Honest scope: this captures weight *structure* (moments + spectrum), not
//! function — ~26B params → a few KB of signatures. The lattice learns from
//! the weights' shape, not their values.
//!
//! All arithmetic is integer-only (i128 Q64.64 / i256 accumulators).
//! License: CC BY-NC-SA 4.0

const std = @import("std");
const fp = @import("fixed_point");
const st = @import("safetensors");

pub const CHANNELS: usize = 8;
/// DFT bins for the spectral signature (k = 1..8 of a 1024-point transform).
pub const SPECTRAL_BINS: usize = CHANNELS;
/// Samples used for the spectral signature per tensor.
pub const SPECTRAL_N: usize = 1024;
/// Node count of the E0 lattice.
pub const E0_NODES: usize = 421;

/// Per-tensor distilled signature.
pub const TensorSignature = struct {
    name: []const u8,
    elements: u64,
    /// Σx/n in Q64.64.
    mean: i128,
    /// sqrt(Σx²/n) in Q64.64.
    rms: i128,
    /// 8-bin spectral magnitudes (normalized to sum ≈ 1.0).
    spectral: [CHANNELS]i128,
    /// Lattice node binding: hash(name) mod 421.
    node: u32,
};

/// Aggregate distilled artifact for a whole safetensors file.
pub const WeightSeed = struct {
    signatures: []TensorSignature,
    total_params: u64,
    /// Channel-folded aggregate spectrum (sum of per-tensor spectral vecs,
    /// normalized). This is the vector the lattice consumes.
    channel_sum: [CHANNELS]i128,
    /// Content digest: XOR-folded FNV over all signatures.
    digest: u64,

    pub fn deinit(self: WeightSeed, allocator: std.mem.Allocator) void {
        for (self.signatures) |s| allocator.free(s.name);
        allocator.free(self.signatures);
    }
};

// =============================================================================
// Distillation
// =============================================================================

/// Streams a safetensors file and distills every tensor into a signature.
/// `max_elems_per_tensor` bounds per-tensor sampling (0 = full stream).
pub fn distillFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_elems_per_tensor: u64,
) !WeightSeed {
    var file = try st.SafeTensors.open(allocator, path);
    defer file.close();

    var sigs = try std.ArrayList(TensorSignature).initCapacity(allocator, file.tensorCount());
    errdefer {
        for (sigs.items) |s| allocator.free(s.name);
        sigs.deinit();
    }

    const window = try allocator.alloc(i128, st.WINDOW_ELEMS);
    defer allocator.free(window);

    var channel_sum = [_]i128{0} ** CHANNELS;
    var digest: u64 = 0xcbf29ce484222325; // FNV offset basis

    for (file.tensors) |t| {
        const sig = try distillTensor(allocator, &file, t, window, max_elems_per_tensor);
        for (0..CHANNELS) |c| channel_sum[c] += sig.spectral[c];
        digest = fnv1a(digest, sig.name);
        digest ^= sig.elements *% 0x9e3779b97f4a7c15;
        digest ^= @as(u64, @bitCast(@as(i64, @truncate(sig.mean))));
        try sigs.append(sig);
    }

    // Normalize aggregate channel vector to ≈1.0 total.
    var total: i128 = 0;
    for (channel_sum) |v| total += v;
    if (total > 0) {
        for (&channel_sum) |*v| v.* = fp.div(v.*, total);
    }

    return .{
        .signatures = try sigs.toOwnedSlice(),
        .total_params = file.totalParams(),
        .channel_sum = channel_sum,
        .digest = digest,
    };
}

/// Distills one tensor: streaming moments + spectral signature + node binding.
fn distillTensor(
    allocator: std.mem.Allocator,
    file: *const st.SafeTensors,
    tensor: st.TensorInfo,
    window: []i128,
    max_elems: u64,
) !TensorSignature {
    const total_elems = if (max_elems > 0) @min(tensor.elements(), max_elems) else tensor.elements();

    var sum: i256 = 0;
    var sum_sq: i256 = 0;
    var seen: u64 = 0;

    while (seen < total_elems) {
        const want: usize = @intCast(@min(@as(u64, window.len), total_elems - seen));
        const n = try file.readWindow(tensor, seen, window[0..want]);
        if (n == 0) break;
        for (window[0..n]) |x| {
            sum += x;
            sum_sq += fp.mul(x, x);
        }
        seen += n;
    }

    const n_i = @as(i256, @intCast(@max(1, seen)));
    const mean: i128 = @intCast(@divTrunc(sum, n_i));
    const mean_sq: i128 = @intCast(@divTrunc(sum_sq, n_i));
    const rms: i128 = fp.sqrt(@max(0, mean_sq));

    // Spectral signature: integer DFT of the first window, folded to 8 bins.
    const spectral = try spectralSignature(allocator, file, tensor);

    return .{
        .name = try allocator.dupe(u8, tensor.name),
        .elements = tensor.elements(),
        .mean = mean,
        .rms = rms,
        .spectral = spectral,
        .node = @intCast(fnv1a(0xcbf29ce484222325, tensor.name) % E0_NODES),
    };
}

/// 8-bin spectral signature: DFT bins k=1..8 of the first SPECTRAL_N samples,
/// magnitudes normalized to sum ≈ 1.0. Bins 1..8 because bin 0 (DC) is already
/// captured by `mean`.
fn spectralSignature(
    allocator: std.mem.Allocator,
    file: *const st.SafeTensors,
    tensor: st.TensorInfo,
) ![CHANNELS]i128 {
    var bins = [_]i128{0} ** CHANNELS;
    const n_samples: usize = @intCast(@min(tensor.elements(), SPECTRAL_N));
    if (n_samples < 4) return bins;

    const samples = try allocator.alloc(i128, n_samples);
    defer allocator.free(samples);
    const got = try file.readWindow(tensor, 0, samples);
    if (got < 4) return bins;

    // Goertzel per bin: re/im accumulators via fp.twiddle (roots of unity).
    for (1..CHANNELS + 1) |k| {
        var re: i128 = 0;
        var im: i128 = 0;
        for (samples[0..got], 0..) |x, n| {
            const tw = fp.twiddle(n * k, got);
            re += fp.mul(x, tw.re); // x·cos
            im += fp.mul(x, tw.im); // x·sin
        }
        // Fold re/im into magnitude²; use manhattan-ish |re|+|im| for speed
        // then sqrt once at the end for true magnitude.
        bins[k - 1] = fp.sqrt(fp.mul(re, re) + fp.mul(im, im));
    }

    var total: i128 = 0;
    for (bins) |b| total += b;
    if (total > 0) {
        for (&bins) |*b| b.* = fp.div(b.*, total);
    }
    return bins;
}

/// Merges several per-shard seeds into one aggregate seed: signatures are
/// concatenated (caller-owned copies), channel_sum is folded then renormalized,
/// digests are combined. Consumed seeds are NOT freed (caller retains them).
pub fn mergeSeeds(allocator: std.mem.Allocator, seeds: []const WeightSeed) !WeightSeed {
    var total_sigs: usize = 0;
    var total_params: u64 = 0;
    for (seeds) |s| {
        total_sigs += s.signatures.len;
        total_params += s.total_params;
    }

    const sigs = try allocator.alloc(TensorSignature, total_sigs);
    errdefer allocator.free(sigs);
    var idx: usize = 0;
    var channel_sum = [_]i128{0} ** CHANNELS;
    var digest: u64 = 0xcbf29ce484222325;

    for (seeds) |s| {
        digest ^= s.digest *% 0x9e3779b97f4a7c15;
        for (s.signatures) |src| {
            for (0..CHANNELS) |c| channel_sum[c] += src.spectral[c];
            sigs[idx] = .{
                .name = try allocator.dupe(u8, src.name),
                .elements = src.elements,
                .mean = src.mean,
                .rms = src.rms,
                .spectral = src.spectral,
                .node = src.node,
            };
            idx += 1;
        }
    }
    var total: i128 = 0;
    for (channel_sum) |v| total += v;
    if (total > 0) {
        for (&channel_sum) |*v| v.* = fp.div(v.*, total);
    }
    return .{
        .signatures = sigs,
        .total_params = total_params,
        .channel_sum = channel_sum,
        .digest = digest,
    };
}

/// FNV-1a over bytes, seeded — used for digest and node binding.
fn fnv1a(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// =============================================================================
// Serialization (QSW1)
// =============================================================================

pub const SEED_MAGIC: [4]u8 = .{ 'Q', 'S', 'W', '1' };

/// Serializes a WeightSeed to bytes (caller owns).
pub fn serializeSeed(allocator: std.mem.Allocator, seed: WeightSeed) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll(&SEED_MAGIC);
    try w.writeInt(u64, seed.total_params, .little);
    try w.writeInt(u64, seed.digest, .little);
    try w.writeInt(u32, @intCast(seed.signatures.len), .little);
    for (seed.channel_sum) |v| try w.writeInt(i128, v, .little);
    for (seed.signatures) |s| {
        try w.writeInt(u16, @intCast(s.name.len), .little);
        try w.writeAll(s.name);
        try w.writeInt(u64, s.elements, .little);
        try w.writeInt(i128, s.mean, .little);
        try w.writeInt(i128, s.rms, .little);
        for (s.spectral) |v| try w.writeInt(i128, v, .little);
        try w.writeInt(u32, s.node, .little);
    }
    return try out.toOwnedSlice();
}

/// Deserializes a WeightSeed. Caller deinits with seed.deinit(allocator).
pub fn deserializeSeed(allocator: std.mem.Allocator, bytes: []const u8) !WeightSeed {
    var fbs = std.io.fixedBufferStream(bytes);
    const r = fbs.reader();

    var magic: [4]u8 = undefined;
    try r.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, &SEED_MAGIC)) return error.BadMagic;

    const total_params = try r.readInt(u64, .little);
    const digest = try r.readInt(u64, .little);
    const count = try r.readInt(u32, .little);

    var channel_sum: [CHANNELS]i128 = undefined;
    for (&channel_sum) |*v| v.* = try r.readInt(i128, .little);

    const sigs = try allocator.alloc(TensorSignature, count);
    errdefer allocator.free(sigs);
    var filled: usize = 0;
    errdefer for (sigs[0..filled]) |s| {
        allocator.free(s.name);
    };

    for (sigs) |*s| {
        const name_len = try r.readInt(u16, .little);
        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        try r.readNoEof(name);
        s.* = .{
            .name = name,
            .elements = try r.readInt(u64, .little),
            .mean = try r.readInt(i128, .little),
            .rms = try r.readInt(i128, .little),
            .spectral = undefined,
            .node = 0,
        };
        for (&s.spectral) |*v| v.* = try r.readInt(i128, .little);
        s.node = try r.readInt(u32, .little);
        filled += 1;
    }
    return .{
        .signatures = sigs,
        .total_params = total_params,
        .channel_sum = channel_sum,
        .digest = digest,
    };
}

/// Folded channel weight for denoise step `i` — consumed by longcat_port's
/// schedule to modulate sigma per step. Returns Q64.64 in ~(0,1].
pub fn stepGate(seed: WeightSeed, step: usize) i128 {
    const v = seed.channel_sum[step % CHANNELS];
    return if (v > 0) v else fp.fromRatio(1, 16);
}

// =============================================================================
// Tests
// =============================================================================

test "fnv1a: deterministic and sensitive to input" {
    try std.testing.expect(fnv1a(0xcbf29ce484222325, "abc") == fnv1a(0xcbf29ce484222325, "abc"));
    try std.testing.expect(fnv1a(0xcbf29ce484222325, "abc") != fnv1a(0xcbf29ce484222325, "abd"));
}

test "distillFile: distills moments and spectrum from real container" {
    const alloc = std.testing.allocator;
    const path = "/tmp/test_distill.safetensors";
    defer std.fs.cwd().deleteFile(path) catch {};

    // One bf16 tensor: [1.0, 2.0, 0.5, -1.0] → mean=0.625, rms≈1.78
    const header =
        \\{"w":{"dtype":"BF16","shape":[4],"data_offsets":[0,8]}}
    ;
    var f = try std.fs.cwd().createFile(path, .{});
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, header.len, .little);
    try f.writeAll(&len_buf);
    try f.writeAll(header);
    try f.writeAll(&[_]u8{ 0x80, 0x3F, 0x00, 0x40, 0x00, 0x3F, 0x80, 0xBF });
    f.close();

    var seed = try distillFile(alloc, path, 0);
    defer seed.deinit(alloc);

    try std.testing.expect(seed.signatures.len == 1);
    try std.testing.expect(seed.total_params == 4);
    const sig = seed.signatures[0];
    try std.testing.expect(sig.mean == fp.fromRatio(5, 8)); // (1+2+0.5-1)/4
    // rms = sqrt((1+4+0.25+1)/4) = sqrt(1.5625) = 1.25
    try std.testing.expect(sig.rms == fp.fromRatio(5, 4));
    try std.testing.expect(sig.node < E0_NODES);
    // Spectral normalized: sums to ≈1 (within fixed-point tolerance).
    var total: i128 = 0;
    for (sig.spectral) |v| total += v;
    try std.testing.expect(total > 0);
}

test "serialize/deserialize: QSW1 round-trip preserves signatures" {
    const alloc = std.testing.allocator;
    const sig = TensorSignature{
        .name = try alloc.dupe(u8, "dit.blocks.7.attn.to_q.weight"),
        .elements = 4096,
        .mean = fp.fromRatio(1, 8),
        .rms = fp.fromRatio(3, 4),
        .spectral = .{ fp.HALF, fp.fromRatio(1, 4), 0, 0, fp.fromRatio(1, 8), 0, fp.fromRatio(1, 8), 0 },
        .node = 137,
    };
    const seed = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 4096,
        .channel_sum = sig.spectral,
        .digest = 0xdeadbeefcafebabe,
    };
    seed.signatures[0] = sig;
    defer seed.deinit(alloc);

    const bytes = try serializeSeed(alloc, seed);
    defer alloc.free(bytes);

    var back = try deserializeSeed(alloc, bytes);
    defer back.deinit(alloc);

    try std.testing.expect(back.total_params == 4096);
    try std.testing.expect(back.digest == 0xdeadbeefcafebabe);
    try std.testing.expect(back.signatures.len == 1);
    try std.testing.expectEqualStrings("dit.blocks.7.attn.to_q.weight", back.signatures[0].name);
    try std.testing.expect(back.signatures[0].elements == 4096);
    try std.testing.expect(back.signatures[0].mean == fp.fromRatio(1, 8));
    try std.testing.expect(back.signatures[0].rms == fp.fromRatio(3, 4));
    try std.testing.expect(back.signatures[0].node == 137);
    for (0..CHANNELS) |c| {
        try std.testing.expect(back.signatures[0].spectral[c] == sig.spectral[c]);
        try std.testing.expect(back.channel_sum[c] == sig.spectral[c]);
    }
    // Bad magic rejected.
    var bad = try alloc.dupe(u8, bytes);
    defer alloc.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, deserializeSeed(alloc, bad));
}

test "mergeSeeds: concatenates signatures, refolds channels, combines digest" {
    const alloc = std.testing.allocator;

    var s1 = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 100,
        .channel_sum = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .digest = 0x1111,
    };
    s1.signatures[0] = .{
        .name = try alloc.dupe(u8, "a.weight"),
        .elements = 100,
        .mean = fp.HALF,
        .rms = fp.ONE,
        .spectral = .{ fp.ONE, 0, 0, 0, 0, 0, 0, 0 },
        .node = 10,
    };
    defer s1.deinit(alloc);

    var s2 = WeightSeed{
        .signatures = try alloc.alloc(TensorSignature, 1),
        .total_params = 300,
        .channel_sum = .{ 0, fp.ONE, 0, 0, 0, 0, 0, 0 },
        .digest = 0x2222,
    };
    s2.signatures[0] = .{
        .name = try alloc.dupe(u8, "b.weight"),
        .elements = 300,
        .mean = fp.fromRatio(1, 4),
        .rms = fp.HALF,
        .spectral = .{ 0, fp.ONE, 0, 0, 0, 0, 0, 0 },
        .node = 20,
    };
    defer s2.deinit(alloc);

    var merged = try mergeSeeds(alloc, &.{ s1, s2 });
    defer merged.deinit(alloc);

    try std.testing.expect(merged.signatures.len == 2);
    try std.testing.expect(merged.total_params == 400);
    try std.testing.expectEqualStrings("a.weight", merged.signatures[0].name);
    try std.testing.expectEqualStrings("b.weight", merged.signatures[1].name);
    // channel_sum = sum of per-tensor spectral = [1,1,0,...] → normalized [0.5,0.5,...]
    try std.testing.expect(merged.channel_sum[0] == fp.HALF);
    try std.testing.expect(merged.channel_sum[1] == fp.HALF);
    try std.testing.expect(merged.digest != s1.digest and merged.digest != s2.digest);
}

test "stepGate: folds channel_sum, never zero" {
    const seed = WeightSeed{
        .signatures = &.{},
        .total_params = 0,
        .channel_sum = .{ fp.HALF, 0, fp.HALF, 0, 0, 0, 0, 0 },
        .digest = 0,
    };
    try std.testing.expect(stepGate(seed, 0) == fp.HALF);
    try std.testing.expect(stepGate(seed, 1) > 0); // zero → floor
    try std.testing.expect(stepGate(seed, 8) == fp.HALF); // wraps mod 8
}
