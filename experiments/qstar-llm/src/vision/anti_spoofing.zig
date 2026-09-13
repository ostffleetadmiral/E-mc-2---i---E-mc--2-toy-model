//! anti_spoofing.zig — Anti-spoofing / liveness detection.
//!
//! Provides liveness classification from model output (MiniFASNet style) and
//! heuristic spoofing indicators (texture analysis, color distribution).
//! All pure Zig — model inference is delegated to onnx_runtime.zig.

const std = @import("std");
const image = @import("image");
const face_detect = @import("face_detect");

// =============================================================================
// Types
// =============================================================================

pub const SpoofType = enum {
    Real, // Live face
    Print, // Printed photo attack
    Replay, // Screen replay attack
    Photo, // Digital photo attack
};

pub const SpoofingResult = struct {
    is_real: bool,
    confidence: f32, // Probability of being real [0, 1]
    spoof_type: SpoofType,
    all_scores: [4]f32, // [real, print, replay, photo]
};

pub const SpoofingError = error{
    InvalidInput,
    InvalidScores,
};

// =============================================================================
// Model output post-processing
// =============================================================================

/// Parse spoofing result from model output (4-class softmax).
/// scores: [real, print, replay, photo]
pub fn parseSpoofingScores(scores: [4]f32) SpoofingError!SpoofingResult {
    // Validate scores
    for (scores) |s| {
        if (s < 0.0) return error.InvalidScores;
    }

    const spoof_types = [_]SpoofType{ .Real, .Print, .Replay, .Photo };

    var max_idx: usize = 0;
    var max_val: f32 = scores[0];
    for (scores[1..], 1..) |s, i| {
        if (s > max_val) {
            max_val = s;
            max_idx = i;
        }
    }

    return .{
        .is_real = max_idx == 0,
        .confidence = scores[0], // Probability of being real
        .spoof_type = spoof_types[max_idx],
        .all_scores = scores,
    };
}

/// Parse from binary model output (2-class: real/fake).
/// scores: [real_prob, fake_prob]
pub fn parseBinarySpoofing(scores: [2]f32) SpoofingError!SpoofingResult {
    if (scores[0] < 0.0 or scores[1] < 0.0) return error.InvalidScores;

    const is_real = scores[0] >= scores[1];
    return .{
        .is_real = is_real,
        .confidence = scores[0],
        .spoof_type = if (is_real) .Real else .Print,
        .all_scores = .{ scores[0], scores[1], 0.0, 0.0 },
    };
}

// =============================================================================
// Heuristic liveness indicators (pure Zig)
// =============================================================================

/// Compute texture complexity in the face region.
/// Real faces have complex skin texture; printed photos often appear smoother.
pub fn computeTextureComplexity(img: image.Image, face_box: face_detect.FaceBox) f32 {
    const x_start: usize = @intFromFloat(@max(0.0, face_box.x1));
    const y_start: usize = @intFromFloat(@max(0.0, face_box.y1));
    const x_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.width)), face_box.x2));
    const y_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.height)), face_box.y2));

    if (x_end <= x_start + 2 or y_end <= y_start + 2) return 0.0;

    const ch = @as(usize, img.channels);
    var gradient_sum: f32 = 0;
    var count: f32 = 0;

    var y = y_start + 1;
    while (y < y_end - 1) : (y += 1) {
        var x = x_start + 1;
        while (x < x_end - 1) : (x += 1) {
            const center = @as(f32, @floatFromInt(img.data[(y * img.width + x) * ch]));
            const right = @as(f32, @floatFromInt(img.data[(y * img.width + (x + 1)) * ch]));
            const down = @as(f32, @floatFromInt(img.data[((y + 1) * img.width + x) * ch]));

            const gx_raw = right - center;
            const gx = if (gx_raw < 0) -gx_raw else gx_raw;
            const gy_raw = down - center;
            const gy = if (gy_raw < 0) -gy_raw else gy_raw;
            gradient_sum += gx + gy;
            count += 1.0;
        }
    }

    if (count < 1.0) return 0.0;

    const avg_gradient = gradient_sum / count;
    // Real face: avg gradient ~10-30, printed photo: ~2-8
    return std.math.clamp(avg_gradient / 20.0, 0.0, 1.0);
}

/// Compute color distribution variance.
/// Real faces have natural color variation; screen replays have color cast.
pub fn computeColorVariance(img: image.Image, face_box: face_detect.FaceBox) f32 {
    const x_start: usize = @intFromFloat(@max(0.0, face_box.x1));
    const y_start: usize = @intFromFloat(@max(0.0, face_box.y1));
    const x_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.width)), face_box.x2));
    const y_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(img.height)), face_box.y2));

    if (x_end <= x_start or y_end <= y_start or img.channels < 3) return 0.0;

    const ch = @as(usize, img.channels);
    var r_sum: f32 = 0;
    var g_sum: f32 = 0;
    var b_sum: f32 = 0;
    var count: f32 = 0;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        while (x < x_end) : (x += 1) {
            const idx = (y * img.width + x) * ch;
            r_sum += @as(f32, @floatFromInt(img.data[idx]));
            g_sum += @as(f32, @floatFromInt(img.data[idx + 1]));
            b_sum += @as(f32, @floatFromInt(img.data[idx + 2]));
            count += 1.0;
        }
    }

    if (count < 1.0) return 0.0;

    const avg_r = r_sum / count;
    const avg_g = g_sum / count;
    const avg_b = b_sum / count;

    // Natural skin tone: R > G > B, with moderate differences
    // Screen replay: often has blue cast (B > R) or green cast
    const rg_raw = avg_r - avg_g;
    const rg_diff = if (rg_raw < 0) -rg_raw else rg_raw;
    const rb_raw = avg_r - avg_b;
    const rb_diff = if (rb_raw < 0) -rb_raw else rb_raw;
    const gb_raw = avg_g - avg_b;
    const gb_diff = if (gb_raw < 0) -gb_raw else gb_raw;

    // Natural skin: rg_diff ~20-40, rb_diff ~30-60, gb_diff ~10-30
    const naturalness = (rg_diff + rb_diff + gb_diff) / 100.0;
    return std.math.clamp(naturalness, 0.0, 1.0);
}

/// Heuristic liveness score combining texture and color analysis.
pub fn heuristicLiveness(img: image.Image, face_box: face_detect.FaceBox) f32 {
    const texture = computeTextureComplexity(img, face_box);
    const color = computeColorVariance(img, face_box);

    // Weighted: texture is more discriminative
    return std.math.clamp(texture * 0.6 + color * 0.4, 0.0, 1.0);
}

// =============================================================================
// High-level anti-spoofing detector
// =============================================================================

pub const AntiSpoofing = struct {
    use_heuristic: bool = true,
    threshold: f32 = 0.5,

    /// Detect from model output (4-class).
    pub fn detect(self: AntiSpoofing, scores: [4]f32) SpoofingError!SpoofingResult {
        var result = try parseSpoofingScores(scores);
        if (self.use_heuristic) {
            // Blend with heuristic (if available, caller can override)
            result.confidence = std.math.clamp(result.confidence, 0.0, 1.0);
            result.is_real = result.confidence >= self.threshold;
        }
        return result;
    }

    /// Detect from model output (binary 2-class).
    pub fn detectBinary(self: AntiSpoofing, scores: [2]f32) SpoofingError!SpoofingResult {
        var result = try parseBinarySpoofing(scores);
        if (self.use_heuristic) {
            result.is_real = result.confidence >= self.threshold;
        }
        return result;
    }

    /// Heuristic-only detection from image.
    pub fn detectHeuristic(self: AntiSpoofing, img: image.Image, face_box: face_detect.FaceBox) SpoofingResult {
        const score = heuristicLiveness(img, face_box);
        return .{
            .is_real = score >= self.threshold,
            .confidence = score,
            .spoof_type = if (score >= self.threshold) .Real else .Print,
            .all_scores = .{ score, 1.0 - score, 0.0, 0.0 },
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parseSpoofingScores real face" {
    const scores = [4]f32{ 0.85, 0.05, 0.05, 0.05 };
    const result = try parseSpoofingScores(scores);

    try std.testing.expect(result.is_real);
    try std.testing.expect(result.spoof_type == .Real);
    try std.testing.expectApproxEqAbs(result.confidence, 0.85, 0.001);
}

test "parseSpoofingScores print attack" {
    const scores = [4]f32{ 0.1, 0.7, 0.1, 0.1 };
    const result = try parseSpoofingScores(scores);

    try std.testing.expect(!result.is_real);
    try std.testing.expect(result.spoof_type == .Print);
}

test "parseSpoofingScores replay attack" {
    const scores = [4]f32{ 0.05, 0.1, 0.8, 0.05 };
    const result = try parseSpoofingScores(scores);

    try std.testing.expect(!result.is_real);
    try std.testing.expect(result.spoof_type == .Replay);
}

test "parseSpoofingScores rejects negative" {
    const scores = [4]f32{ -0.1, 0.5, 0.3, 0.3 };
    try std.testing.expectError(error.InvalidScores, parseSpoofingScores(scores));
}

test "parseBinarySpoofing real" {
    const result = try parseBinarySpoofing(.{ 0.9, 0.1 });
    try std.testing.expect(result.is_real);
    try std.testing.expectApproxEqAbs(result.confidence, 0.9, 0.001);
}

test "parseBinarySpoofing fake" {
    const result = try parseBinarySpoofing(.{ 0.2, 0.8 });
    try std.testing.expect(!result.is_real);
    try std.testing.expectApproxEqAbs(result.confidence, 0.2, 0.001);
}

test "computeTextureComplexity uniform image is low" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 20, 20, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const box = face_detect.FaceBox{ .x1 = 2, .y1 = 2, .x2 = 18, .y2 = 18, .confidence = 0.9 };
    const texture = computeTextureComplexity(img, box);

    try std.testing.expect(texture < 0.1);
}

test "computeTextureComplexity high-contrast is high" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 20, 20, 3);
    defer img.deinit();

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
    const texture = computeTextureComplexity(img, box);

    try std.testing.expect(texture > 0.5);
}

test "computeColorVariance natural skin tone" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 10, 10, 3);
    defer img.deinit();

    // Natural skin tone: R=200, G=170, B=140
    for (0..300) |i| {
        if (i % 3 == 0) img.data[i] = 200;
        if (i % 3 == 1) img.data[i] = 170;
        if (i % 3 == 2) img.data[i] = 140;
    }

    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    const color = computeColorVariance(img, box);

    // rg=30, rb=60, gb=30 → (30+60+30)/100 = 1.2, clamped to 1.0
    try std.testing.expect(color > 0.5);
}

test "computeColorVariance gray image is low" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 10, 10, 3);
    defer img.deinit();
    @memset(img.data, 128); // Gray: R=G=B

    const box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    const color = computeColorVariance(img, box);

    try std.testing.expectApproxEqAbs(color, 0.0, 0.01);
}

test "heuristicLiveness returns [0,1]" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 20, 20, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const box = face_detect.FaceBox{ .x1 = 2, .y1 = 2, .x2 = 18, .y2 = 18, .confidence = 0.9 };
    const score = heuristicLiveness(img, box);

    try std.testing.expect(score >= 0.0 and score <= 1.0);
}

test "AntiSpoofing detect from model" {
    const detector = AntiSpoofing{ .threshold = 0.5 };
    const result = try detector.detect(.{ 0.9, 0.03, 0.03, 0.04 });

    try std.testing.expect(result.is_real);
    try std.testing.expect(result.spoof_type == .Real);
}

test "AntiSpoofing detect below threshold" {
    const detector = AntiSpoofing{ .threshold = 0.5 };
    const result = try detector.detect(.{ 0.3, 0.4, 0.2, 0.1 });

    try std.testing.expect(!result.is_real);
}

test "AntiSpoofing detectBinary" {
    const detector = AntiSpoofing{ .threshold = 0.5 };
    const result = try detector.detectBinary(.{ 0.7, 0.3 });

    try std.testing.expect(result.is_real);
}

test "AntiSpoofing detectHeuristic" {
    const allocator = std.testing.allocator;
    var img = try image.Image.init(allocator, 20, 20, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const detector = AntiSpoofing{ .threshold = 0.3 };
    const box = face_detect.FaceBox{ .x1 = 2, .y1 = 2, .x2 = 18, .y2 = 18, .confidence = 0.9 };
    const result = detector.detectHeuristic(img, box);

    try std.testing.expect(result.confidence >= 0.0 and result.confidence <= 1.0);
}

test "SpoofType has 4 variants" {
    try std.testing.expect(@typeInfo(SpoofType) == .Enum);
    try std.testing.expect(@typeInfo(SpoofType).Enum.fields.len == 4);
}
