// ============================================================================
// NEURALEAK MATRIX BRIDGE — Text → 15³ Scalar Field
// ============================================================================
//
// Maps an LLM response string into a 15³ scalar field. The bridge is lossy by
// design: it converts symbolic text into a numeric pattern that can be fed into
// the framework's ConsciousnessEngine and BreakoutEngine.
//
// The encoding hashes contiguous alphabetic tokens to matrix coordinates and
// accumulates a small weight per token. The resulting matrix is then normalized
// so that the coherence score reflects the density of information, not the raw
// length of the response.
//
// All values use i64 micro-units (SCALE = 10^6) to avoid floating point.
//
// Cross-wiring: The 15³ = 3375 cells connect to the framework's interior
// lattice (chunk 16: 16³ - 15³ = 721 = 3(240) + 1).
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const Matrix15 = @import("neuraleak_matrix15.zig").Matrix15;
const SCALE: i64 = @import("neuraleak_matrix15.zig").SCALE;

/// Map `text` into `matrix`.
pub fn encodeText(matrix: *Matrix15, text: []const u8) void {
    var token_start: ?usize = null;
    var token_count: usize = 0;

    for (text, 0..) |c, i| {
        const is_alpha = std.ascii.isAlphabetic(c);

        if (is_alpha and token_start == null) {
            token_start = i;
        } else if (!is_alpha and token_start != null) {
            const token = text[token_start.?..i];
            addToken(matrix, token);
            token_count += 1;
            token_start = null;
        }
    }

    if (token_start != null) {
        const token = text[token_start.?..text.len];
        addToken(matrix, token);
        token_count += 1;
    }

    if (token_count > 0) {
        // Normalize: divide each cell by token_count
        // In integer arithmetic: multiply by SCALE, divide by token_count
        const count_i64: i64 = @intCast(token_count);
        for (0..matrix.data.len) |idx| {
            // Each cell currently holds SCALE (one unit per token hit).
            // We want: cell / token_count, in micro-units.
            // cell is in micro-units, so: (cell * 1) / token_count
            // But cell = SCALE * hits, so result = SCALE * hits / token_count
            matrix.data[idx] = @divTrunc(matrix.data[idx], count_i64);
        }
    }
}

/// Hash a token to a 15³ coordinate and add a unit weight to that cell.
fn addToken(matrix: *Matrix15, token: []const u8) void {
    var hash: u64 = 0xcbf29ce484222325;

    for (token) |c| {
        hash ^= c;
        hash *%= 0x100000001b3;
    }

    const x = @as(u4, @intCast(hash % 15));
    hash /= 15;
    const y = @as(u4, @intCast(hash % 15));
    hash /= 15;
    const z = @as(u4, @intCast(hash % 15));

    const idx = Matrix15.index(x, y, z);
    matrix.data[idx] += SCALE; // Add 1.0 in micro-units
}

/// Return the L2 norm of the matrix data (in micro-units).
pub fn norm(matrix: *const Matrix15) i64 {
    return matrix.l2Norm();
}

// ============================================================================
// Tests
// ============================================================================

test "encodeText produces a non-zero matrix from text" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    encodeText(&matrix, "hello world hello again");
    try std.testing.expect(norm(&matrix) > 0);
}

test "encodeText normalizes by token count" {
    var matrix_a = try Matrix15.init(std.testing.allocator);
    defer matrix_a.deinit();
    var matrix_b = try Matrix15.init(std.testing.allocator);
    defer matrix_b.deinit();

    encodeText(&matrix_a, "hello");
    encodeText(&matrix_b, "hello hello hello hello");

    // Both should have the same norm after normalization
    // (single token "hello" maps to same cell, normalized by count)
    const norm_a = norm(&matrix_a);
    const norm_b = norm(&matrix_b);
    // Allow small integer rounding difference (within 1 micro-unit)
    const diff: i64 = if (norm_a > norm_b) norm_a - norm_b else norm_b - norm_a;
    try std.testing.expect(diff <= 1);
}

test "encodeText leaves empty text as zero" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    encodeText(&matrix, "12345 !!!");
    try std.testing.expect(norm(&matrix) == 0);
}

test "matrix bridge uses integer types (no f64)" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    encodeText(&matrix, "test");
    try std.testing.expect(@TypeOf(norm(&matrix)) == i64);
}
