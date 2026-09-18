//! face_quality.zig — Face quality assessment.
//!
//! Provides face quality scoring from model output (eDifFIQA style) and
//! heuristic quality metrics computed from image properties (blur detection,
//! occlusion estimation, illumination check). All pure Zig.

const std = @import("std");
const image = @import("image");
const face_detect = @import("face_detect");

// =============================================================================
// Types
// =============================================================================

pub const QualityResult = struct {
    score: f32, // Overall quality [0, 1], higher = better
    sharpness: f32, // Blur metric [0, 1]
    illumination: f32, // Lighting quality [0, 1]
    occlusion: f32, // Estimated occlusion [0, 1], lower = less occluded
    face_size_ratio: f32, // Face size relative to image [0, 1]
};

pub const QualityError = error{
    InvalidInput,
};

// =============================================================================
// Heuristic quality metrics (pure Zig, no model required)
// =============================================================================

/// Compute image sharpness using Laplacian variance.
/// Higher variance = sharper image. Returns [0, 1] normalized score.
pub fn computeSharpness(img: image.Image, face_box: face_detect.FaceBox) f32 {
    const x_start: usize = @intFromFloat(@max(0.0, face_box.x1));
    const y_start: usize = @intFromFloat(@max(0.0, face_box.y1));
    const x_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.width)), face_box.x2));
    const y_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.height)), face_box.y2));

    if (x_end <= x_start + 2 or y_end <= y_start + 2) return 0.0;

    const ch = @as(usize, img.channels);
    var laplacian_sum: f32 = 0;
    var laplacian_sq_sum: f32 = 0;
    var count: f32 = 0;

    // Compute Laplacian: L(x,y) = -4*I(x,y) + I(x-1,y) + I(x+1,y) + I(x,y-1) + I(x,y+1)
    var y = y_start + 1;
    while (y < y_end - 1) : (y += 1) {
        var x = x_start + 1;
        while (x < x_end - 1) : (x += 1) {
            const center = @as(f32, @floatFromInt(img.data[(y * img.width + x) * ch]));
            const left = @as(f32, @floatFromInt(img.data[(y * img.width + (x - 1)) * ch]));
            const right = @as(f32, @floatFromInt(img.data[(y * img.width + (x + 1)) * ch]));
            const up = @as(f32, @floatFromInt(img.data[((y - 1) * img.width + x) * ch]));
            const down = @as(f32, @floatFromInt(img.data[((y + 1) * img.width + x) * ch]));

            const lap = -4.0 * center + left + right + up + down;
            laplacian_sum += lap;
            laplacian_sq_sum += lap * lap;
            count += 1.0;
        }
    }

    if (count < 1.0) return 0.0;

    const variance = (laplacian_sq_sum / count) - (laplacian_sum / count) * (laplacian_sum / count);

    // Normalize: typical sharp face has variance > 500, blurry < 50
    const normalized = variance / 500.0;
    return std.math.clamp(normalized, 0.0, 1.0);
}

/// Compute illumination quality from average brightness of the face region.
/// Optimal: ~128 (mid-gray). Too dark or too bright = low quality.
pub fn computeIllumination(img: image.Image, face_box: face_detect.FaceBox) f32 {
    const x_start: usize = @intFromFloat(@max(0.0, face_box.x1));
    const y_start: usize = @intFromFloat(@max(0.0, face_box.y1));
    const x_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.width)), face_box.x2));
    const y_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.height)), face_box.y2));

    if (x_end <= x_start or y_end <= y_start) return 0.0;

    const ch = @as(usize, img.channels);
    var sum: f64 = 0;
    var count: f64 = 0;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        while (x < x_end) : (x += 1) {
            const idx = (y * img.width + x) * ch;
            // Average across channels
            var pixel_sum: f32 = 0;
            for (0..ch) |c| {
                pixel_sum += @as(f32, @floatFromInt(img.data[idx + c]));
            }
            sum += @as(f64, pixel_sum) / @as(f64, @floatFromInt(ch));
            count += 1;
        }
    }

    if (count < 1.0) return 0.0;

    const avg_brightness = @as(f32, @floatCast(sum / count));

    // Optimal at 128, with a Gaussian-like falloff
    const dev = avg_brightness - 128.0;
    const deviation = if (dev < 0) -dev else dev;
    const score = 1.0 - deviation / 128.0;
    return std.math.clamp(score, 0.0, 1.0);
}

/// Compute face size ratio relative to the full image.
pub fn computeFaceSizeRatio(face_box: face_detect.FaceBox, img_width: usize, img_height: usize) f32 {
    const face_area = face_box.area();
    const img_area = @as(f32, @floatFromInt(img_width * img_height));
    if (img_area < 1.0) return 0.0;
    return std.math.clamp(face_area / img_area, 0.0, 1.0);
}

/// Estimate occlusion from face box aspect ratio and size.
/// Very small or very distorted faces are likely occluded.
pub fn computeOcclusion(face_box: face_detect.FaceBox) f32 {
    const w = face_box.width();
    const h = face_box.height();
    if (w < 1.0 or h < 1.0) return 1.0;

    const aspect = w / h;
    // Ideal face aspect ratio: ~0.8 (slightly taller than wide)
    const aspect_diff = aspect - 0.8;
    const aspect_deviation = (if (aspect_diff < 0) -aspect_diff else aspect_diff) / 0.8;

    // Very small faces are more likely occluded
    const size_score: f32 = if (w < 30.0 or h < 30.0) 0.5 else 0.0;

    return std.math.clamp(aspect_deviation * 0.5 + size_score, 0.0, 1.0);
}

/// Compute overall quality score from heuristic metrics.
pub fn computeQuality(
    img: image.Image,
    face_box: face_detect.FaceBox,
) QualityResult {
    const sharpness = computeSharpness(img, face_box);
    const illumination = computeIllumination(img, face_box);
    const occlusion = computeOcclusion(face_box);
    const face_size_ratio = computeFaceSizeRatio(face_box, img.width, img.height);

    // Weighted combination
    const score = sharpness * 0.4 + illumination * 0.25 + (1.0 - occlusion) * 0.25 + face_size_ratio * 0.1;

    return .{
        .score = std.math.clamp(score, 0.0, 1.0),
        .sharpness = sharpness,
        .illumination = illumination,
        .occlusion = occlusion,
        .face_size_ratio = face_size_ratio,
    };
}

/// Parse quality from model output (single sigmoid value).
pub fn parseQualityScore(raw_score: f32) f32 {
    return std.math.clamp(raw_score, 0.0, 1.0);
}

// =============================================================================
// High-level assessor
// =============================================================================

pub const QualityAssessor = struct {
    use_heuristic: bool = true,

    pub fn assess(self: QualityAssessor, img: image.Image, face_box: face_detect.FaceBox) QualityResult {
        if (self.use_heuristic) {
            return computeQuality(img, face_box);
        }
        return .{
            .score = 0.0,
            .sharpness = 0.0,
            .illumination = 0.0,
            .occlusion = 1.0,
            .face_size_ratio = 0.0,
        };
    }

    pub fn assessFromModel(self: QualityAssessor, raw_score: f32, img: image.Image, face_box: face_detect.FaceBox) QualityResult {
        _ = self;
        const heuristic = computeQuality(img, face_box);
        return .{
            .score = parseQualityScore(raw_score),
            .sharpness = heuristic.sharpness,
            .illumination = heuristic.illumination,
            .occlusion = heuristic.occlusion,
            .face_size_ratio = heuristic.face_size_ratio,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "computeSharpness on uniform image returns 0" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 20, 20, 3);
    defer img.deinit();
    @memset(img.data, 128); // Uniform gray

    const box = face_detect.FaceBox{ .x1 = 2, .y1 = 2, .x2 = 18, .y2 = 18, .confidence = 0.9 };
    const sharpness = computeSharpness(img, box);

    // Uniform image has zero Laplacian variance
    try std.testing.expectApproxEqAbs(sharpness, 0.0, 0.01);
}

test "computeSharpness on high-contrast image returns high" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 20, 20, 3);
    defer img.deinit();

    // Create a checkerboard pattern (high frequency = sharp)
    for (0..20) |y| {
        for (0..20) |x| {
            const val: u8 = if ((x + y) % 2 == 0) 0 else 255;
            const idx = (y * 20 + x) * 3;
            img.data[idx] = val;
            img.data[idx + 1] = val;
            img.data[idx + 2] = val;
        }
    }

    const box = face_detect.FaceBox{ .x1 = 2, .y1 = 2, .x2 = 18, .y2 = 18, .confidence = 0.9 };
    const sharpness = computeSharpness(img, box);

    try std.testing.expect(sharpness > 0.5);
}

test "computeIllumination optimal at 128" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 10, 10, 3);
    defer img.deinit();
    @memset(img.data, 128); // Mid-gray

    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    const illum = computeIllumination(img, box);

    try std.testing.expectApproxEqAbs(illum, 1.0, 0.01);
}

test "computeIllumination dark image has low score" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 10, 10, 3);
    defer img.deinit();
    @memset(img.data, 10); // Very dark

    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    const illum = computeIllumination(img, box);

    try std.testing.expect(illum < 0.2);
}

test "computeIllumination bright image has low score" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 10, 10, 3);
    defer img.deinit();
    @memset(img.data, 250); // Very bright

    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    const illum = computeIllumination(img, box);

    try std.testing.expect(illum < 0.2);
}

test "computeFaceSizeRatio" {
    const box = face_detect.FaceBox{ .x1 = 25, .y1 = 25, .x2 = 75, .y2 = 75, .confidence = 0.9 };
    const ratio = computeFaceSizeRatio(box, 100, 100);
    // Face area = 50*50=2500, image area = 10000, ratio = 0.25
    try std.testing.expectApproxEqAbs(ratio, 0.25, 0.001);
}

test "computeOcclusion ideal aspect ratio" {
    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 80, .y2 = 100, .confidence = 0.9 };
    const occ = computeOcclusion(box);
    // Aspect = 0.8, deviation = 0 → low occlusion
    try std.testing.expect(occ < 0.1);
}

test "computeOcclusion distorted face" {
    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 200, .y2 = 50, .confidence = 0.9 };
    const occ = computeOcclusion(box);
    // Aspect = 4.0, very distorted → high occlusion
    try std.testing.expect(occ > 0.5);
}

test "computeQuality returns valid range" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 50, .confidence = 0.9 };
    const result = computeQuality(img, box);

    try std.testing.expect(result.score >= 0.0 and result.score <= 1.0);
    try std.testing.expect(result.sharpness >= 0.0 and result.sharpness <= 1.0);
    try std.testing.expect(result.illumination >= 0.0 and result.illumination <= 1.0);
    try std.testing.expect(result.occlusion >= 0.0 and result.occlusion <= 1.0);
}

test "parseQualityScore clamps to [0,1]" {
    try std.testing.expectApproxEqAbs(parseQualityScore(0.5), 0.5, 0.001);
    try std.testing.expectApproxEqAbs(parseQualityScore(-1.0), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(parseQualityScore(2.0), 1.0, 0.001);
}

test "QualityAssessor assess returns valid result" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const assessor = QualityAssessor{};
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 50, .confidence = 0.9 };
    const result = assessor.assess(img, box);

    try std.testing.expect(result.score >= 0.0 and result.score <= 1.0);
}

test "QualityAssessor assessFromModel combines scores" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const assessor = QualityAssessor{};
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 50, .confidence = 0.9 };
    const result = assessor.assessFromModel(0.85, img, box);

    try std.testing.expectApproxEqAbs(result.score, 0.85, 0.001);
    // Heuristic metrics should still be populated
    try std.testing.expect(result.illumination > 0.5);
}
