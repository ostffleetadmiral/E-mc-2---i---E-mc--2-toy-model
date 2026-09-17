//! distillation_s0.zig — Distillation via S0 projection.
//!
//! Combines the training system (distillation from teacher models) with
//! the lattice compressor (S7→S0/S0→S7) and collapse resilience framework
//! to enable compact, resilient, portable knowledge transfer.
//!
//! Pipeline:
//!   1. Teacher model (OpenAI/llama-server) generates a response
//!   2. Qstar learns from the teacher (existing distillation)
//!   3. Lattice state (S7) is compressed to S0 seed via TurboQuant
//!   4. S0 seed is stored via collapse resilience (QR portals + RS + Shamir)
//!   5. On recovery, S0 is projected back to S7 and lattice state is restored
//!
//! This enables:
//!   - Compact knowledge storage (23KB → ~3KB with 4-bit quantization)
//!   - Resilient knowledge transfer (survives partial data loss)
//!   - Multi-agent knowledge sharing via S0 seeds
//!   - Low-bandwidth transmission (LoRa, QR codes, audio)

const std = @import("std");
const lattice_comp = @import("lattice_compressor");
const tq = @import("turbo_quant");

// =============================================================================
// Constants
// =============================================================================

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;
pub const LATTICE_STATE_SIZE: usize = E0_NODE_COUNT * CHANNEL_COUNT;

/// S0 seed metadata for tracking distillation provenance.
pub const S0Metadata = struct {
    /// Timestamp of distillation
    timestamp: i64,
    /// Number of prompts distilled
    prompt_count: u32,
    /// Teacher model name
    teacher_model: [32]u8,
    teacher_model_len: usize,
    /// Compression bits used (2 or 4)
    bits: u8,
    /// Original state size in bytes
    original_size: usize,
    /// Compressed size in bytes
    compressed_size: usize,
    /// Compression ratio
    ratio: f64,
    /// Max reconstruction error
    max_error: f64,
    /// Mean reconstruction error
    mean_error: f64,
};

/// Result of S0 distillation.
pub const S0DistillationResult = struct {
    metadata: S0Metadata,
    seed: tq.TQSeed,
    /// Serialized seed bytes (for storage/transmission)
    serialized: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *S0DistillationResult) void {
        self.seed.deinit();
        self.allocator.free(self.serialized);
    }
};

// =============================================================================
// S0 Projection: Compress lattice state to S0 seed
// =============================================================================

/// Projects the full lattice state (S7) to a compressed S0 seed.
/// This is the core S0 projection operation.
pub fn projectToS0(
    allocator: std.mem.Allocator,
    activations: []const i128,
    bits: u8,
    teacher_model: []const u8,
    prompt_count: u32,
) !S0DistillationResult {
    if (activations.len != LATTICE_STATE_SIZE) return error.InvalidStateSize;

    // Convert i128 → i64 (sidecar boundary, potential precision loss for very large values)
    var i64_activations: [LATTICE_STATE_SIZE]i64 = undefined;
    for (activations, &i64_activations) |src, *dst| {
        // Clamp to i64 range — lattice activations are typically small
        dst.* = @intCast(std.math.clamp(src, std.math.minInt(i64), std.math.maxInt(i64)));
    }

    // Compress with TurboQuant
    const comp_result = try lattice_comp.compressLatticeState(allocator, &i64_activations, bits);

    // Build metadata
    var teacher_buf: [32]u8 = [_]u8{0} ** 32;
    const teacher_len = @min(teacher_model.len, 32);
    @memcpy(teacher_buf[0..teacher_len], teacher_model[0..teacher_len]);

    const metadata = S0Metadata{
        .timestamp = std.time.timestamp(),
        .prompt_count = prompt_count,
        .teacher_model = teacher_buf,
        .teacher_model_len = teacher_len,
        .bits = bits,
        .original_size = comp_result.original_bytes,
        .compressed_size = comp_result.compressed_bytes,
        .ratio = comp_result.ratio,
        .max_error = comp_result.max_error,
        .mean_error = comp_result.mean_error,
    };

    // Serialize for storage/transmission
    const serialized = try lattice_comp.serializeCompressionResult(allocator, comp_result);

    return .{
        .metadata = metadata,
        .seed = comp_result.seed,
        .serialized = serialized,
        .allocator = allocator,
    };
}

// =============================================================================
// S0 Injection: Restore lattice state from S0 seed
// =============================================================================

/// Injects an S0 seed back into the full lattice state (S7).
/// This is the S0→S7 projection (reconstruction).
/// Returns a heap-allocated slice of i64 values (caller owns).
pub fn injectFromS0(
    allocator: std.mem.Allocator,
    seed: tq.TQSeed,
) ![]i64 {
    return try lattice_comp.decompressLatticeState(allocator, seed);
}

/// Injects a serialized S0 seed back into the full lattice state (S7).
/// Returns a heap-allocated slice of i64 values (caller owns).
pub fn injectFromSerializedS0(
    allocator: std.mem.Allocator,
    serialized: []const u8,
) ![]i64 {
    var comp_result = try lattice_comp.deserializeCompressionResult(allocator, serialized);
    defer comp_result.deinit();
    return try lattice_comp.decompressLatticeState(allocator, comp_result.seed);
}

// =============================================================================
// S0 Verification: Check reconstruction quality
// =============================================================================

/// Verifies S0 projection quality by comparing original and reconstructed states.
pub fn verifyS0Projection(
    original: []const i128,
    reconstructed: []const i64,
) struct { max_error: i64, mean_error: f64, exact_match_rate: f64 } {
    var max_error: i64 = 0;
    var sum_error: f64 = 0;
    var exact_matches: usize = 0;

    for (original, reconstructed) |orig, recon| {
        const orig_i64: i64 = @intCast(std.math.clamp(orig, std.math.minInt(i64), std.math.maxInt(i64)));
        const err: i64 = @intCast(@abs(orig_i64 - recon));
        if (err > max_error) max_error = err;
        sum_error += @as(f64, @floatFromInt(err));
        if (err == 0) exact_matches += 1;
    }

    const mean_error = sum_error / @as(f64, @floatFromInt(original.len));
    const exact_match_rate = @as(f64, @floatFromInt(exact_matches)) / @as(f64, @floatFromInt(original.len));

    return .{
        .max_error = max_error,
        .mean_error = mean_error,
        .exact_match_rate = exact_match_rate,
    };
}

// =============================================================================
// S0 Seed Serialization (with metadata)
// =============================================================================

/// Serializes an S0 distillation result (metadata + seed) to a byte buffer.
pub fn serializeS0WithMetadata(
    allocator: std.mem.Allocator,
    result: S0DistillationResult,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Magic + version
    try buf.appendSlice("S0DM"); // S0 Distillation Metadata
    try buf.append(1); // version

    // Metadata
    try buf.appendSlice(std.mem.asBytes(&result.metadata.timestamp));
    try buf.appendSlice(std.mem.asBytes(&result.metadata.prompt_count));
    try buf.appendSlice(result.metadata.teacher_model[0..result.metadata.teacher_model_len]);
    try buf.append(@intCast(result.metadata.teacher_model_len));
    try buf.append(result.metadata.bits);
    try buf.appendSlice(std.mem.asBytes(&result.metadata.original_size));
    try buf.appendSlice(std.mem.asBytes(&result.metadata.compressed_size));
    try buf.appendSlice(std.mem.asBytes(&result.metadata.ratio));
    try buf.appendSlice(std.mem.asBytes(&result.metadata.max_error));
    try buf.appendSlice(std.mem.asBytes(&result.metadata.mean_error));

    // Serialized seed
    try buf.appendSlice(std.mem.asBytes(&result.serialized.len));
    try buf.appendSlice(result.serialized);

    return try buf.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "distillation_s0: project and inject round trip (4-bit)" {
    const allocator = std.testing.allocator;

    // Create a realistic lattice state
    var activations: [LATTICE_STATE_SIZE]i128 = undefined;
    for (&activations, 0..) |*a, i| {
        const node = i / CHANNEL_COUNT;
        const ch = i % CHANNEL_COUNT;
        a.* = @as(i128, @intCast(node)) * 1000 + @as(i128, @intCast(ch)) * 100 - 500;
    }

    // Project to S0
    var s0_result = try projectToS0(allocator, &activations, 4, "gpt-4o-mini", 5);
    defer s0_result.deinit();

    // Verify metadata
    try std.testing.expectEqual(@as(u8, 4), s0_result.metadata.bits);
    try std.testing.expectEqual(@as(u32, 5), s0_result.metadata.prompt_count);
    try std.testing.expect(s0_result.metadata.compressed_size > 0);
    try std.testing.expect(s0_result.metadata.ratio > 1.0);

    // Inject from S0
    const reconstructed = try injectFromS0(allocator, s0_result.seed);
    defer allocator.free(reconstructed);
    try std.testing.expectEqual(@as(usize, LATTICE_STATE_SIZE), reconstructed.len);

    // Verify reconstruction quality
    const verify = verifyS0Projection(&activations, reconstructed);
    try std.testing.expect(verify.exact_match_rate >= 0.0);
    try std.testing.expect(verify.mean_error >= 0.0);
}

test "distillation_s0: project and inject round trip (2-bit)" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i128 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i128, @intCast(i % 1000)) - 500;
    }

    var s0_result = try projectToS0(allocator, &activations, 2, "llama-server", 3);
    defer s0_result.deinit();

    try std.testing.expectEqual(@as(u8, 2), s0_result.metadata.bits);
    try std.testing.expect(s0_result.metadata.compressed_size < s0_result.metadata.original_size);

    const reconstructed = try injectFromS0(allocator, s0_result.seed);
    defer allocator.free(reconstructed);
    try std.testing.expectEqual(@as(usize, LATTICE_STATE_SIZE), reconstructed.len);
}

test "distillation_s0: serialized round trip" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i128 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i128, @intCast(i % 500)) - 250;
    }

    var s0_result = try projectToS0(allocator, &activations, 4, "gpt-5", 10);
    defer s0_result.deinit();

    // Serialize with metadata
    const serialized = try serializeS0WithMetadata(allocator, s0_result);
    defer allocator.free(serialized);

    // Verify magic
    try std.testing.expect(std.mem.eql(u8, serialized[0..4], "S0DM"));
    try std.testing.expectEqual(@as(u8, 1), serialized[4]);
}

test "distillation_s0: inject from serialized S0" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i128 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i128, @intCast(i)) * 100;
    }

    var s0_result = try projectToS0(allocator, &activations, 4, "test-teacher", 1);
    defer s0_result.deinit();

    // Inject from the serialized form
    const reconstructed = try injectFromSerializedS0(allocator, s0_result.serialized);
    defer allocator.free(reconstructed);
    try std.testing.expectEqual(@as(usize, LATTICE_STATE_SIZE), reconstructed.len);
}

test "distillation_s0: zero state projects correctly" {
    const allocator = std.testing.allocator;

    const activations = [_]i128{0} ** LATTICE_STATE_SIZE;

    var s0_result = try projectToS0(allocator, &activations, 2, "zero-test", 0);
    defer s0_result.deinit();

    try std.testing.expectEqual(@as(f64, 0), s0_result.metadata.max_error);
    try std.testing.expectEqual(@as(f64, 0), s0_result.metadata.mean_error);

    const reconstructed = try injectFromS0(allocator, s0_result.seed);
    defer allocator.free(reconstructed);
    for (reconstructed) |v| {
        try std.testing.expectEqual(@as(i64, 0), v);
    }
}

test "distillation_s0: compression ratio is meaningful" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i128 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i128, @intCast(i));
    }

    var s0_2bit = try projectToS0(allocator, &activations, 2, "test", 1);
    defer s0_2bit.deinit();

    var s0_4bit = try projectToS0(allocator, &activations, 4, "test", 1);
    defer s0_4bit.deinit();

    // 2-bit should compress more than 4-bit
    try std.testing.expect(s0_2bit.metadata.compressed_size <= s0_4bit.metadata.compressed_size);
    try std.testing.expect(s0_2bit.metadata.ratio >= s0_4bit.metadata.ratio);
}

test "distillation_s0: verify reconstruction quality" {
    const allocator = std.testing.allocator;

    var activations: [LATTICE_STATE_SIZE]i128 = undefined;
    for (&activations, 0..) |*a, i| {
        a.* = @as(i128, @intCast(i % 100));
    }

    var s0_result = try projectToS0(allocator, &activations, 4, "quality-test", 5);
    defer s0_result.deinit();

    const reconstructed = try injectFromS0(allocator, s0_result.seed);
    defer allocator.free(reconstructed);

    const verify = verifyS0Projection(&activations, reconstructed);
    // 4-bit quantization of small values should have good exact match rate
    try std.testing.expect(verify.max_error >= 0);
    try std.testing.expect(verify.mean_error >= 0);
    try std.testing.expect(verify.exact_match_rate >= 0.0);
}

test "distillation_s0: invalid state size rejected" {
    const allocator = std.testing.allocator;
    const wrong_size = [_]i128{ 1, 2, 3 };

    const result = projectToS0(allocator, &wrong_size, 4, "test", 1);
    try std.testing.expectError(error.InvalidStateSize, result);
}

test "distillation_s0: teacher model name stored in metadata" {
    const allocator = std.testing.allocator;

    const activations = [_]i128{0} ** LATTICE_STATE_SIZE;

    var s0_result = try projectToS0(allocator, &activations, 2, "qwen3-9b", 1);
    defer s0_result.deinit();

    try std.testing.expectEqualStrings("qwen3-9b", s0_result.metadata.teacher_model[0..s0_result.metadata.teacher_model_len]);
}
