//! face_recognize.zig — Face recognition: alignment, embedding extraction, similarity.
//!
//! Provides face alignment via affine transform from 5 landmarks (ArcFace style),
//! embedding extraction (delegated to onnx_runtime.zig), L2 normalization, and
//! cosine similarity computation. All alignment and math is pure Zig.

const std = @import("std");
const image = @import("image");

// =============================================================================
// Types
// =============================================================================

pub const RecognitionError = error{
    InvalidLandmarks,
    InvalidEmbedding,
    DimensionMismatch,
    OutOfMemory,
    FileNotFound,
    InvalidFormat,
    UnsupportedFormat,
    TruncatedData,
    LibraryNotFound,
    FreestandingUnsupported,
};

/// Standard ArcFace reference landmarks for 112x112 aligned face.
/// These are the target positions that 5 source landmarks should be warped to.
pub const ARCFACE_REF_LANDMARKS = [5][2]f32{
    .{ 38.2946, 51.6963 },
    .{ 73.5318, 51.5014 },
    .{ 56.0252, 71.7366 },
    .{ 41.5493, 92.3655 },
    .{ 70.7299, 92.2041 },
};

pub const ARCFACE_TARGET_SIZE: usize = 112;

// =============================================================================
// Affine transform (2D similarity transform)
// =============================================================================

/// 2D affine transform matrix: [a, b, tx, c, d, ty]
/// Maps (x, y) → (a*x + b*y + tx, c*x + d*y + ty)
pub const AffineMatrix = struct {
    a: f32,
    b: f32,
    tx: f32,
    c: f32,
    d: f32,
    ty: f32,

    pub fn identity() AffineMatrix {
        return .{ .a = 1.0, .b = 0.0, .tx = 0.0, .c = 0.0, .d = 1.0, .ty = 0.0 };
    }

    pub fn transformPoint(self: AffineMatrix, x: f32, y: f32) [2]f32 {
        return .{
            self.a * x + self.b * y + self.tx,
            self.c * x + self.d * y + self.ty,
        };
    }
};

/// Compute affine transform from source landmarks to target landmarks
/// using least-squares estimation (Umeyama algorithm for 5 points).
/// Solves: find M (2x2), T such that target ≈ M * source + T
/// M = C_cross * C_src^(-1), where C_src = Σ src*src^T, C_cross = Σ dst*src^T
pub fn estimateAffine(
    src: [5][2]f32,
    dst: [5][2]f32,
) RecognitionError!AffineMatrix {
    // Compute centroids
    var src_cx: f32 = 0;
    var src_cy: f32 = 0;
    var dst_cx: f32 = 0;
    var dst_cy: f32 = 0;

    for (src) |p| {
        src_cx += p[0];
        src_cy += p[1];
    }
    for (dst) |p| {
        dst_cx += p[0];
        dst_cy += p[1];
    }

    src_cx /= 5.0;
    src_cy /= 5.0;
    dst_cx /= 5.0;
    dst_cy /= 5.0;

    // Source covariance matrix C_src = [[Σsx², Σsx*sy], [Σsx*sy, Σsy²]]
    var src_xx: f32 = 0;
    var src_xy: f32 = 0;
    var src_yy: f32 = 0;

    // Cross-covariance C_cross = [[Σdx*sx, Σdx*sy], [Σdy*sx, Σdy*sy]]
    var cross_00: f32 = 0;
    var cross_01: f32 = 0;
    var cross_10: f32 = 0;
    var cross_11: f32 = 0;

    for (0..5) |i| {
        const sx = src[i][0] - src_cx;
        const sy = src[i][1] - src_cy;
        const dx = dst[i][0] - dst_cx;
        const dy = dst[i][1] - dst_cy;

        src_xx += sx * sx;
        src_xy += sx * sy;
        src_yy += sy * sy;

        cross_00 += dx * sx;
        cross_01 += dx * sy;
        cross_10 += dy * sx;
        cross_11 += dy * sy;
    }

    // det(C_src) = src_xx * src_yy - src_xy²
    const det_src = src_xx * src_yy - src_xy * src_xy;
    const abs_det = if (det_src < 0) -det_src else det_src;
    if (abs_det < 1e-10) return error.InvalidLandmarks;

    // C_src^(-1) = 1/det * [[src_yy, -src_xy], [-src_xy, src_xx]]
    const inv_xx = src_yy / det_src;
    const inv_xy = -src_xy / det_src;
    const inv_yy = src_xx / det_src;

    // M = C_cross * C_src^(-1)
    const a = cross_00 * inv_xx + cross_01 * inv_xy;
    const b = cross_00 * inv_xy + cross_01 * inv_yy;
    const c = cross_10 * inv_xx + cross_11 * inv_xy;
    const d = cross_10 * inv_xy + cross_11 * inv_yy;

    // Translation: T = dst_centroid - M * src_centroid
    const tx = dst_cx - (a * src_cx + b * src_cy);
    const ty = dst_cy - (c * src_cx + d * src_cy);

    return .{ .a = a, .b = b, .tx = tx, .c = c, .d = d, .ty = ty };
}

/// Warp an image using an affine transform. Output is dst_width x dst_height.
pub fn warpAffine(
    allocator: std.mem.Allocator,
    src: image.Image,
    matrix: AffineMatrix,
    dst_width: usize,
    dst_height: usize,
) RecognitionError!image.Image {
    var dst = try image.Image.init(allocator, dst_width, dst_height, src.channels);

    // Inverse transform: for each dst pixel, find src pixel
    // Inverse of [a b; c d] is 1/det * [d -b; -c a]
    const det = matrix.a * matrix.d - matrix.b * matrix.c;
    const abs_det = if (det < 0) -det else det;
    if (abs_det < 1e-10) return error.InvalidLandmarks;

    const inv_a = matrix.d / det;
    const inv_b = -matrix.b / det;
    const inv_c = -matrix.c / det;
    const inv_d = matrix.a / det;

    const ch = @as(usize, src.channels);

    for (0..dst_height) |y| {
        for (0..dst_width) |x| {
            const fx = @as(f32, @floatFromInt(x));
            const fy = @as(f32, @floatFromInt(y));

            // Inverse transform: src_x = inv_a*(fx - tx) + inv_b*(fy - ty)
            const src_x = inv_a * (fx - matrix.tx) + inv_b * (fy - matrix.ty);
            const src_y = inv_c * (fx - matrix.tx) + inv_d * (fy - matrix.ty);

            // Bilinear interpolation
            const x0: i64 = @intFromFloat(@floor(src_x));
            const y0: i64 = @intFromFloat(@floor(src_y));
            const x1 = x0 + 1;
            const y1 = y0 + 1;

            const wx = src_x - @as(f32, @floatFromInt(x0));
            const wy = src_y - @as(f32, @floatFromInt(y0));

            for (0..ch) |c_i| {
                var val: f32 = 0;
                var weight: f32 = 0;

                if (x0 >= 0 and x0 < @as(i64, @intCast(src.width)) and
                    y0 >= 0 and y0 < @as(i64, @intCast(src.height)))
                {
                    const px = src.data[@as(usize, @intCast(y0)) * src.width * ch +
                        @as(usize, @intCast(x0)) * ch + c_i];
                    val += @as(f32, @floatFromInt(px)) * (1.0 - wx) * (1.0 - wy);
                    weight += (1.0 - wx) * (1.0 - wy);
                }
                if (x1 >= 0 and x1 < @as(i64, @intCast(src.width)) and
                    y0 >= 0 and y0 < @as(i64, @intCast(src.height)))
                {
                    const px = src.data[@as(usize, @intCast(y0)) * src.width * ch +
                        @as(usize, @intCast(x1)) * ch + c_i];
                    val += @as(f32, @floatFromInt(px)) * wx * (1.0 - wy);
                    weight += wx * (1.0 - wy);
                }
                if (x0 >= 0 and x0 < @as(i64, @intCast(src.width)) and
                    y1 >= 0 and y1 < @as(i64, @intCast(src.height)))
                {
                    const px = src.data[@as(usize, @intCast(y1)) * src.width * ch +
                        @as(usize, @intCast(x0)) * ch + c_i];
                    val += @as(f32, @floatFromInt(px)) * (1.0 - wx) * wy;
                    weight += (1.0 - wx) * wy;
                }
                if (x1 >= 0 and x1 < @as(i64, @intCast(src.width)) and
                    y1 >= 0 and y1 < @as(i64, @intCast(src.height)))
                {
                    const px = src.data[@as(usize, @intCast(y1)) * src.width * ch +
                        @as(usize, @intCast(x1)) * ch + c_i];
                    val += @as(f32, @floatFromInt(px)) * wx * wy;
                    weight += wx * wy;
                }

                if (weight > 0) {
                    dst.data[y * dst_width * ch + x * ch + c_i] =
                        @intFromFloat(std.math.clamp(val / weight, 0.0, 255.0));
                }
            }
        }
    }

    return dst;
}

/// Align a face using 5 landmarks to ArcFace 112x112 target.
pub fn alignFace(
    allocator: std.mem.Allocator,
    src: image.Image,
    landmarks: [5][2]f32,
) RecognitionError!image.Image {
    const matrix = try estimateAffine(landmarks, ARCFACE_REF_LANDMARKS);
    return warpAffine(allocator, src, matrix, ARCFACE_TARGET_SIZE, ARCFACE_TARGET_SIZE);
}

// =============================================================================
// Embedding operations
// =============================================================================

/// L2 normalize an embedding vector in-place.
pub fn normalizeEmbedding(emb: []f32) void {
    var norm: f32 = 0;
    for (emb) |v| norm += v * v;
    norm = @sqrt(norm);
    if (norm < 1e-10) {
        @memset(emb, 0);
        return;
    }
    for (emb) |*v| v.* /= norm;
}

/// Compute cosine similarity between two embeddings.
/// Both should be L2-normalized for best results (then it's just dot product).
pub fn cosineSimilarity(emb_a: []const f32, emb_b: []const f32) RecognitionError!f32 {
    if (emb_a.len != emb_b.len) return error.DimensionMismatch;

    var dot: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;

    for (emb_a, emb_b) |a, b| {
        dot += a * b;
        norm_a += a * a;
        norm_b += b * b;
    }

    norm_a = @sqrt(norm_a);
    norm_b = @sqrt(norm_b);

    if (norm_a < 1e-10 or norm_b < 1e-10) return 0.0;

    return dot / (norm_a * norm_b);
}

/// Compute Euclidean distance between two embeddings.
pub fn euclideanDistance(emb_a: []const f32, emb_b: []const f32) RecognitionError!f32 {
    if (emb_a.len != emb_b.len) return error.DimensionMismatch;

    var sum: f32 = 0;
    for (emb_a, emb_b) |a, b| {
        const diff = a - b;
        sum += diff * diff;
    }

    return @sqrt(sum);
}

// =============================================================================
// Face recognizer (high-level interface)
// =============================================================================

pub const FaceRecognizer = struct {
    embedding_dim: usize = 512,
    similarity_threshold: f32 = 0.5,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, embedding_dim: usize, similarity_threshold: f32) FaceRecognizer {
        return .{
            .embedding_dim = embedding_dim,
            .similarity_threshold = similarity_threshold,
            .allocator = allocator,
        };
    }

    /// Align a face image from landmarks.
    pub fn alignImage(self: FaceRecognizer, src: image.Image, landmarks: [5][2]f32) RecognitionError!image.Image {
        return alignFace(self.allocator, src, landmarks);
    }

    /// Check if two embeddings represent the same person.
    pub fn isSamePerson(self: FaceRecognizer, emb_a: []const f32, emb_b: []const f32) RecognitionError!bool {
        const sim = try cosineSimilarity(emb_a, emb_b);
        return sim >= self.similarity_threshold;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AffineMatrix identity transform" {
    const m = AffineMatrix.identity();
    const result = m.transformPoint(5.0, 10.0);
    try std.testing.expectApproxEqAbs(result[0], 5.0, 0.001);
    try std.testing.expectApproxEqAbs(result[1], 10.0, 0.001);
}

test "AffineMatrix transformPoint" {
    const m = AffineMatrix{ .a = 2.0, .b = 0.0, .tx = 1.0, .c = 0.0, .d = 2.0, .ty = 1.0 };
    const result = m.transformPoint(3.0, 4.0);
    // (2*3 + 0*4 + 1, 0*3 + 2*4 + 1) = (7, 9)
    try std.testing.expectApproxEqAbs(result[0], 7.0, 0.001);
    try std.testing.expectApproxEqAbs(result[1], 9.0, 0.001);
}

test "estimateAffine with identity-like input" {
    // If src == dst, transform should be identity
    const src = [5][2]f32{
        .{ 10.0, 20.0 },
        .{ 30.0, 20.0 },
        .{ 20.0, 40.0 },
        .{ 15.0, 50.0 },
        .{ 25.0, 50.0 },
    };
    const dst = src;

    const m = try estimateAffine(src, dst);
    try std.testing.expectApproxEqAbs(m.a, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(m.d, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(m.b, 0.0, 0.01);
    try std.testing.expectApproxEqAbs(m.c, 0.0, 0.01);
}

test "estimateAffine with translation" {
    const src = [5][2]f32{
        .{ 10.0, 20.0 },
        .{ 30.0, 20.0 },
        .{ 20.0, 40.0 },
        .{ 15.0, 50.0 },
        .{ 25.0, 50.0 },
    };
    // Dst is src shifted by (5, 10)
    var dst: [5][2]f32 = undefined;
    for (src, 0..) |p, i| {
        dst[i] = .{ p[0] + 5.0, p[1] + 10.0 };
    }

    const m = try estimateAffine(src, dst);
    try std.testing.expectApproxEqAbs(m.a, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(m.d, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(m.tx, 5.0, 0.01);
    try std.testing.expectApproxEqAbs(m.ty, 10.0, 0.01);
}

test "estimateAffine with scaling" {
    const src = [5][2]f32{
        .{ 10.0, 20.0 },
        .{ 30.0, 20.0 },
        .{ 20.0, 40.0 },
        .{ 15.0, 50.0 },
        .{ 25.0, 50.0 },
    };
    // Dst is src scaled by 2x around origin
    var dst: [5][2]f32 = undefined;
    for (src, 0..) |p, i| {
        dst[i] = .{ p[0] * 2.0, p[1] * 2.0 };
    }

    const m = try estimateAffine(src, dst);
    try std.testing.expectApproxEqAbs(m.a, 2.0, 0.01);
    try std.testing.expectApproxEqAbs(m.d, 2.0, 0.01);
}

test "estimateAffine rejects degenerate landmarks" {
    // All points at same location → zero variance
    const src = [5][2]f32{
        .{ 10.0, 10.0 },
        .{ 10.0, 10.0 },
        .{ 10.0, 10.0 },
        .{ 10.0, 10.0 },
        .{ 10.0, 10.0 },
    };
    const dst = ARCFACE_REF_LANDMARKS;

    try std.testing.expectError(error.InvalidLandmarks, estimateAffine(src, dst));
}

test "warpAffine identity produces same image" {
    const allocator = std.testing.allocator;
    var src = try image.Image.init(allocator, 4, 4, 3);
    defer src.deinit();
    for (0..48) |i| src.data[i] = @intCast(i % 256);

    const m = AffineMatrix.identity();
    var dst = try warpAffine(allocator, src, m, 4, 4);
    defer dst.deinit();

    // With identity transform, output should match input (approximately, due to interpolation)
    for (0..48) |i| {
        try std.testing.expect(dst.data[i] == src.data[i]);
    }
}

test "warpAffine with translation shifts image" {
    const allocator = std.testing.allocator;
    var src = try image.Image.init(allocator, 4, 4, 3);
    defer src.deinit();
    // Set pixel at (1,0) to white
    src.data[(0 * 4 + 1) * 3 + 0] = 255;

    // Translate by (1, 0): src_x = fx - 1
    const m = AffineMatrix{ .a = 1.0, .b = 0.0, .tx = 1.0, .c = 0.0, .d = 1.0, .ty = 0.0 };
    var dst = try warpAffine(allocator, src, m, 4, 4);
    defer dst.deinit();

    // Pixel at (2,0) in dst should now be white (shifted from (1,0))
    try std.testing.expect(dst.data[(0 * 4 + 2) * 3 + 0] == 255);
}

test "normalizeEmbedding produces unit vector" {
    var emb = [_]f32{ 3.0, 4.0 };
    normalizeEmbedding(&emb);

    var norm: f32 = 0;
    for (emb) |v| norm += v * v;
    try std.testing.expectApproxEqAbs(@sqrt(norm), 1.0, 0.001);
}

test "normalizeEmbedding handles zero vector" {
    var emb = [_]f32{ 0.0, 0.0, 0.0 };
    normalizeEmbedding(&emb);
    for (emb) |v| try std.testing.expect(v == 0.0);
}

test "cosineSimilarity identical vectors returns 1" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    const sim = try cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(sim, 1.0, 0.001);
}

test "cosineSimilarity orthogonal vectors returns 0" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0 };
    const sim = try cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(sim, 0.0, 0.001);
}

test "cosineSimilarity opposite vectors returns -1" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ -1.0, -2.0, -3.0 };
    const sim = try cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(sim, -1.0, 0.001);
}

test "cosineSimilarity dimension mismatch" {
    const a = [_]f32{ 1.0, 2.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    try std.testing.expectError(error.DimensionMismatch, cosineSimilarity(&a, &b));
}

test "euclideanDistance identical vectors returns 0" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    const dist = try euclideanDistance(&a, &b);
    try std.testing.expectApproxEqAbs(dist, 0.0, 0.001);
}

test "euclideanDistance 3-4-5 triangle" {
    const a = [_]f32{ 0.0, 0.0 };
    const b = [_]f32{ 3.0, 4.0 };
    const dist = try euclideanDistance(&a, &b);
    try std.testing.expectApproxEqAbs(dist, 5.0, 0.001);
}

test "alignFace produces 112x112 output" {
    const allocator = std.testing.allocator;
    var src = try image.Image.init(allocator, 100, 100, 3);
    defer src.deinit();
    for (0..30000) |i| src.data[i] = @intCast(i % 256);

    const landmarks = [5][2]f32{
        .{ 30.0, 40.0 },
        .{ 70.0, 40.0 },
        .{ 50.0, 60.0 },
        .{ 35.0, 75.0 },
        .{ 65.0, 75.0 },
    };

    var aligned = try alignFace(allocator, src, landmarks);
    defer aligned.deinit();

    try std.testing.expect(aligned.width == ARCFACE_TARGET_SIZE);
    try std.testing.expect(aligned.height == ARCFACE_TARGET_SIZE);
}

test "FaceRecognizer isSamePerson above threshold" {
    const allocator = std.testing.allocator;
    const recognizer = FaceRecognizer.init(allocator, 3, 0.5);

    const emb_a = [_]f32{ 1.0, 0.0, 0.0 };
    const emb_b = [_]f32{ 0.9, 0.1, 0.0 };
    // Cosine sim ≈ 0.9 → above 0.5 threshold
    try std.testing.expect(try recognizer.isSamePerson(&emb_a, &emb_b));
}

test "FaceRecognizer isSamePerson below threshold" {
    const allocator = std.testing.allocator;
    const recognizer = FaceRecognizer.init(allocator, 3, 0.5);

    const emb_a = [_]f32{ 1.0, 0.0, 0.0 };
    const emb_b = [_]f32{ -1.0, 0.0, 0.0 };
    // Cosine sim = -1 → below 0.5 threshold
    try std.testing.expect(!try recognizer.isSamePerson(&emb_a, &emb_b));
}

test "ARCFACE_REF_LANDMARKS has 5 points" {
    try std.testing.expect(ARCFACE_REF_LANDMARKS.len == 5);
}

test "ARCFACE_TARGET_SIZE is 112" {
    try std.testing.expect(ARCFACE_TARGET_SIZE == 112);
}
