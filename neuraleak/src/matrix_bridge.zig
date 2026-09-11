// ============================================================================
// MATRIX15 BRIDGE — Neuraleak
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
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const Matrix15 = @import("matrix").Matrix15;

/// Map `text` into `matrix`.
///
/// The algorithm tokenizes `text` into alphabetic runs, hashes each token to a
/// 15³ coordinate, and accumulates `1.0` at that cell. After all tokens are
/// processed, the matrix is divided by the total number of tokens so the
/// magnitude is independent of response length. If `text` contains no tokens,
/// the matrix is left at zero.
///
/// `matrix` must be an initialised (zeroed) Matrix15.
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

    const idx = matrix.index(x, y, z);
    matrix.data[idx] += 1.0;
}

/// Return the L2 norm of the matrix data.
pub fn norm(matrix: *const Matrix15) f64 {
    var sum: f64 = 0.0;
    for (matrix.data) |v| {
        sum += v * v;
    }
    return std.math.sqrt(sum);
}

// ============================================================================
// Tests
// ============================================================================

test "encodeText produces a non-zero matrix from text" {
    var matrix = try Matrix15.init(std.testing.allocator);

    encodeText(&matrix, "hello world hello again");

    try std.testing.expect(norm(&matrix) > 0.0);
}

test "encodeText normalizes by token count" {
    var matrix_a = try Matrix15.init(std.testing.allocator);
    var matrix_b = try Matrix15.init(std.testing.allocator);

    encodeText(&matrix_a, "hello");
    encodeText(&matrix_b, "hello hello hello hello");

    // Norms should be identical because the same token repeated is normalized.
    try std.testing.expectApproxEqAbs(norm(&matrix_a), norm(&matrix_b), 1e-9);
}

test "encodeText leaves empty text as zero" {
    var matrix = try Matrix15.init(std.testing.allocator);

    encodeText(&matrix, "12345 !!!");
    try std.testing.expect(norm(&matrix) == 0.0);
}
