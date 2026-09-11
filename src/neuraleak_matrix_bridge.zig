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
// Cross-wiring: The 15³ = 3375 cells connect to the framework's interior
// lattice (chunk 16: 16³ - 15³ = 721 = 3(240) + 1).
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const Matrix15 = @import("neuraleak_matrix15.zig").Matrix15;

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
        const scale = 1.0 / @as(f64, @floatFromInt(token_count));
        for (0..matrix.data.len) |idx| {
            matrix.data[idx] *= scale;
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
    matrix.data[idx] += 1.0;
}

/// Return the L2 norm of the matrix data.
pub fn norm(matrix: *const Matrix15) f64 {
    return matrix.l2Norm();
}

// ============================================================================
// Tests
// ============================================================================

test "encodeText produces a non-zero matrix from text" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    encodeText(&matrix, "hello world hello again");
    try std.testing.expect(norm(&matrix) > 0.0);
}

test "encodeText normalizes by token count" {
    var matrix_a = try Matrix15.init(std.testing.allocator);
    defer matrix_a.deinit();
    var matrix_b = try Matrix15.init(std.testing.allocator);
    defer matrix_b.deinit();

    encodeText(&matrix_a, "hello");
    encodeText(&matrix_b, "hello hello hello hello");

    try std.testing.expectApproxEqAbs(norm(&matrix_a), norm(&matrix_b), 1e-9);
}

test "encodeText leaves empty text as zero" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    encodeText(&matrix, "12345 !!!");
    try std.testing.expect(norm(&matrix) == 0.0);
}
