//! face_detect.zig — Face detection post-processing for SCRFD/RetinaFace/BlazeFace.
//!
//! Provides FaceBox struct, Non-Maximum Suppression (NMS), anchor decoding,
//! and multi-scale detection post-processing. Model inference is delegated to
//! onnx_runtime.zig; this module handles all pure-Zig post-processing logic.
//!
//! Detection models output raw tensors (bbox deltas, confidence scores, landmark
//! offsets) that must be decoded into absolute coordinates and filtered via NMS.

const std = @import("std");
const image = @import("image");

// =============================================================================
// Types
// =============================================================================

pub const FaceBox = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    confidence: f32,
    landmarks: ?[5][2]f32 = null, // 5 keypoints (x, y) or null if not detected

    pub fn width(self: FaceBox) f32 {
        return self.x2 - self.x1;
    }

    pub fn height(self: FaceBox) f32 {
        return self.y2 - self.y1;
    }

    pub fn area(self: FaceBox) f32 {
        return self.width() * self.height();
    }

    pub fn iou(self: FaceBox, other: FaceBox) f32 {
        const ix1 = @max(self.x1, other.x1);
        const iy1 = @max(self.y1, other.y1);
        const ix2 = @min(self.x2, other.x2);
        const iy2 = @min(self.y2, other.y2);

        const iw = ix2 - ix1;
        const ih = iy2 - iy1;
        if (iw <= 0 or ih <= 0) return 0.0;

        const intersection = iw * ih;
        const union_area = self.area() + other.area() - intersection;
        if (union_area <= 0) return 0.0;

        return intersection / union_area;
    }

    pub fn clipToImage(self: *FaceBox, img_width: usize, img_height: usize) void {
        self.x1 = std.math.clamp(self.x1, 0.0, @as(f32, @floatFromInt(img_width)));
        self.y1 = std.math.clamp(self.y1, 0.0, @as(f32, @floatFromInt(img_height)));
        self.x2 = std.math.clamp(self.x2, 0.0, @as(f32, @floatFromInt(img_width)));
        self.y2 = std.math.clamp(self.y2, 0.0, @as(f32, @floatFromInt(img_height)));
    }
};

pub const DetectionConfig = struct {
    score_threshold: f32 = 0.5,
    nms_threshold: f32 = 0.4,
    max_det_count: usize = 300,
    use_landmarks: bool = true,
};

pub const DetectionError = error{
    InvalidInput,
    OutOfMemory,
};

// =============================================================================
// Non-Maximum Suppression
// =============================================================================

/// Sort boxes by confidence (descending) using insertion sort (stable, simple).
fn sortByConfidence(boxes: []FaceBox) void {
    var i: usize = 1;
    while (i < boxes.len) : (i += 1) {
        const key = boxes[i];
        var j: i64 = @as(i64, @intCast(i)) - 1;
        while (j >= 0 and boxes[@intCast(j)].confidence < key.confidence) {
            boxes[@intCast(j + 1)] = boxes[@intCast(j)];
            j -= 1;
        }
        boxes[@intCast(j + 1)] = key;
    }
}

/// Standard NMS: greedily select highest-confidence box, suppress overlapping ones.
/// Returns filtered boxes (caller owns memory).
pub fn nonMaxSuppression(
    allocator: std.mem.Allocator,
    boxes: []const FaceBox,
    iou_threshold: f32,
) DetectionError![]FaceBox {
    if (boxes.len == 0) return allocator.alloc(FaceBox, 0);

    // Copy and sort by confidence descending
    var sorted = try allocator.alloc(FaceBox, boxes.len);
    @memcpy(sorted, boxes);
    sortByConfidence(sorted);

    var keep = try allocator.alloc(bool, sorted.len);
    defer allocator.free(keep);
    @memset(keep, true);

    var count: usize = sorted.len;
    var i: usize = 0;
    while (i < sorted.len) : (i += 1) {
        if (!keep[i]) continue;
        var j = i + 1;
        while (j < sorted.len) : (j += 1) {
            if (!keep[j]) continue;
            if (sorted[i].iou(sorted[j]) > iou_threshold) {
                keep[j] = false;
                count -= 1;
            }
        }
    }

    var result = try allocator.alloc(FaceBox, count);
    var idx: usize = 0;
    for (sorted, 0..) |box, k| {
        if (keep[k]) {
            result[idx] = box;
            idx += 1;
        }
    }

    allocator.free(sorted);
    return result;
}

// =============================================================================
// Anchor decoding (for anchor-based detectors like RetinaFace)
// =============================================================================

pub const Anchor = struct {
    cx: f32,
    cy: f32,
    w: f32,
    h: f32,
};

/// Generate anchors for a feature map at a given stride.
pub fn generateAnchors(
    allocator: std.mem.Allocator,
    feat_w: usize,
    feat_h: usize,
    stride: f32,
    scales: []const f32,
    ratios: []const f32,
) DetectionError![]Anchor {
    const num_anchors_per_loc = scales.len * ratios.len;
    var anchors = try allocator.alloc(Anchor, feat_w * feat_h * num_anchors_per_loc);

    var idx: usize = 0;
    var y: usize = 0;
    while (y < feat_h) : (y += 1) {
        var x: usize = 0;
        while (x < feat_w) : (x += 1) {
            const cx = (@as(f32, @floatFromInt(x)) + 0.5) * stride;
            const cy = (@as(f32, @floatFromInt(y)) + 0.5) * stride;

            for (scales) |scale| {
                for (ratios) |ratio| {
                    const w = scale * ratio;
                    const h = scale / ratio;
                    anchors[idx] = .{ .cx = cx, .cy = cy, .w = w, .h = h };
                    idx += 1;
                }
            }
        }
    }

    return anchors;
}

/// Decode bbox deltas from anchor-based detector output.
/// deltas: [dx, dy, dw, dh] per anchor, applied to anchor box.
pub fn decodeBbox(anchor: Anchor, deltas: [4]f32) FaceBox {
    const dx = deltas[0];
    const dy = deltas[1];
    const dw = deltas[2];
    const dh = deltas[3];

    const px = anchor.cx;
    const py = anchor.cy;
    const pw = anchor.w;
    const ph = anchor.h;

    const gx = dx * pw + px;
    const gy = dy * ph + py;
    const gw = @exp(dw) * pw;
    const gh = @exp(dh) * ph;

    return .{
        .x1 = gx - gw * 0.5,
        .y1 = gy - gh * 0.5,
        .x2 = gx + gw * 0.5,
        .y2 = gy + gh * 0.5,
        .confidence = 0.0, // Set by caller
    };
}

/// Decode landmark offsets from anchor-based detector output.
/// offsets: [x1, y1, x2, y2, ..., x5, y5] per anchor.
pub fn decodeLandmarks(anchor: Anchor, offsets: [10]f32) [5][2]f32 {
    var landmarks: [5][2]f32 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        landmarks[i][0] = offsets[i * 2] * anchor.w + anchor.cx;
        landmarks[i][1] = offsets[i * 2 + 1] * anchor.h + anchor.cy;
    }
    return landmarks;
}

// =============================================================================
// SCRFD anchor-free decoding
// =============================================================================

/// SCRFD uses anchor-free decoding: bbox is directly [x1, y1, x2, y2] offset
/// from feature map cell, scaled by stride.
pub fn decodeScrfdBbox(
    feat_x: usize,
    feat_y: usize,
    stride: f32,
    bbox_raw: [4]f32,
) FaceBox {
    return .{
        .x1 = @as(f32, @floatFromInt(feat_x)) * stride + bbox_raw[0] * stride,
        .y1 = @as(f32, @floatFromInt(feat_y)) * stride + bbox_raw[1] * stride,
        .x2 = @as(f32, @floatFromInt(feat_x)) * stride + bbox_raw[2] * stride,
        .y2 = @as(f32, @floatFromInt(feat_y)) * stride + bbox_raw[3] * stride,
        .confidence = 0.0,
    };
}

/// SCRFD landmark decoding: 5 keypoints, each [x, y] offset from feature cell.
pub fn decodeScrfdLandmarks(
    feat_x: usize,
    feat_y: usize,
    stride: f32,
    kpts_raw: [10]f32,
) [5][2]f32 {
    var landmarks: [5][2]f32 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        landmarks[i][0] = @as(f32, @floatFromInt(feat_x)) * stride + kpts_raw[i * 2] * stride;
        landmarks[i][1] = @as(f32, @floatFromInt(feat_y)) * stride + kpts_raw[i * 2 + 1] * stride;
    }
    return landmarks;
}

// =============================================================================
// Multi-scale detection post-processing
// =============================================================================

/// Process detections from multiple feature pyramid levels.
/// Concatenates, filters by score threshold, clips to image bounds, and applies NMS.
pub fn postProcessMultiScale(
    allocator: std.mem.Allocator,
    detections: []const FaceBox,
    config: DetectionConfig,
    img_width: usize,
    img_height: usize,
) DetectionError![]FaceBox {
    // Filter by score threshold
    var filtered = std.ArrayList(FaceBox).init(allocator);
    defer filtered.deinit();

    for (detections) |det| {
        if (det.confidence >= config.score_threshold) {
            var box = det;
            box.clipToImage(img_width, img_height);
            if (box.width() > 0 and box.height() > 0) {
                try filtered.append(box);
            }
        }
    }

    // Apply NMS
    var nms_result = try nonMaxSuppression(allocator, filtered.items, config.nms_threshold);

    // Limit to max_det_count
    if (nms_result.len > config.max_det_count) {
        const trimmed = try allocator.realloc(nms_result, config.max_det_count);
        nms_result = trimmed;
    }

    return nms_result;
}

// =============================================================================
// Face detector (high-level interface)
// =============================================================================

pub const FaceDetector = struct {
    config: DetectionConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: DetectionConfig) FaceDetector {
        return .{ .config = config, .allocator = allocator };
    }

    /// Post-process raw model outputs into final face boxes.
    /// This is the pure-Zig post-processing path; model inference is handled by the caller.
    pub fn postProcess(
        self: FaceDetector,
        detections: []const FaceBox,
        img_width: usize,
        img_height: usize,
    ) DetectionError![]FaceBox {
        return postProcessMultiScale(self.allocator, detections, self.config, img_width, img_height);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FaceBox area and iou" {
    const box1 = FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    const box2 = FaceBox{ .x1 = 5, .y1 = 5, .x2 = 15, .y2 = 15, .confidence = 0.8 };
    const box3 = FaceBox{ .x1 = 20, .y1 = 20, .x2 = 30, .y2 = 30, .confidence = 0.7 };

    try std.testing.expect(box1.area() == 100.0);
    try std.testing.expect(box2.area() == 100.0);

    // IoU of box1 and box2: intersection = 5*5=25, union = 100+100-25=175
    try std.testing.expectApproxEqAbs(box1.iou(box2), 25.0 / 175.0, 0.001);

    // Non-overlapping boxes have IoU = 0
    try std.testing.expect(box1.iou(box3) == 0.0);
}

test "FaceBox clipToImage" {
    var box = FaceBox{ .x1 = -10, .y1 = -5, .x2 = 200, .y2 = 150, .confidence = 0.9 };
    box.clipToImage(100, 80);
    try std.testing.expect(box.x1 == 0.0);
    try std.testing.expect(box.y1 == 0.0);
    try std.testing.expect(box.x2 == 100.0);
    try std.testing.expect(box.y2 == 80.0);
}

test "NMS removes overlapping boxes" {
    const allocator = std.testing.allocator;
    const boxes = [_]FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 },
        .{ .x1 = 1, .y1 = 1, .x2 = 11, .y2 = 11, .confidence = 0.8 },
        .{ .x1 = 50, .y1 = 50, .x2 = 60, .y2 = 60, .confidence = 0.7 },
    };

    const result = try nonMaxSuppression(allocator, &boxes, 0.3);
    defer allocator.free(result);

    // Box 0 and 1 overlap heavily (IoU > 0.3), so only box 0 should survive.
    // Box 2 doesn't overlap, so it should also survive.
    try std.testing.expect(result.len == 2);
    try std.testing.expect(result[0].confidence == 0.9); // Highest confidence first
    try std.testing.expect(result[1].confidence == 0.7);
}

test "NMS with no overlap keeps all" {
    const allocator = std.testing.allocator;
    const boxes = [_]FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 },
        .{ .x1 = 100, .y1 = 100, .x2 = 110, .y2 = 110, .confidence = 0.8 },
        .{ .x1 = 200, .y1 = 200, .x2 = 210, .y2 = 210, .confidence = 0.7 },
    };

    const result = try nonMaxSuppression(allocator, &boxes, 0.5);
    defer allocator.free(result);

    try std.testing.expect(result.len == 3);
}

test "NMS with empty input returns empty" {
    const allocator = std.testing.allocator;
    const result = try nonMaxSuppression(allocator, &[_]FaceBox{}, 0.5);
    defer allocator.free(result);
    try std.testing.expect(result.len == 0);
}

test "NMS sorts by confidence descending" {
    const allocator = std.testing.allocator;
    const boxes = [_]FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.3 },
        .{ .x1 = 100, .y1 = 100, .x2 = 110, .y2 = 110, .confidence = 0.95 },
        .{ .x1 = 200, .y1 = 200, .x2 = 210, .y2 = 210, .confidence = 0.6 },
    };

    const result = try nonMaxSuppression(allocator, &boxes, 0.1);
    defer allocator.free(result);

    try std.testing.expect(result[0].confidence == 0.95);
    try std.testing.expect(result[1].confidence == 0.6);
    try std.testing.expect(result[2].confidence == 0.3);
}

test "generateAnchors produces correct count" {
    const allocator = std.testing.allocator;
    const scales = [_]f32{ 8.0, 16.0, 32.0 };
    const ratios = [_]f32{ 1.0 };
    const anchors = try generateAnchors(allocator, 10, 10, 8.0, &scales, &ratios);
    defer allocator.free(anchors);

    // 10 * 10 * 3 scales * 1 ratio = 300 anchors
    try std.testing.expect(anchors.len == 300);

    // First anchor at (0.5, 0.5) * stride=8 = (4, 4), scale=8, ratio=1
    try std.testing.expectApproxEqAbs(anchors[0].cx, 4.0, 0.001);
    try std.testing.expectApproxEqAbs(anchors[0].cy, 4.0, 0.001);
    try std.testing.expectApproxEqAbs(anchors[0].w, 8.0, 0.001);
    try std.testing.expectApproxEqAbs(anchors[0].h, 8.0, 0.001);
}

test "decodeBbox from anchor deltas" {
    const anchor = Anchor{ .cx = 50.0, .cy = 50.0, .w = 20.0, .h = 20.0 };
    const deltas = [_]f32{ 0.0, 0.0, 0.0, 0.0 }; // No offset

    const box = decodeBbox(anchor, deltas);
    // With zero deltas: gx=50, gy=50, gw=20, gh=20
    try std.testing.expectApproxEqAbs(box.x1, 40.0, 0.001);
    try std.testing.expectApproxEqAbs(box.y1, 40.0, 0.001);
    try std.testing.expectApproxEqAbs(box.x2, 60.0, 0.001);
    try std.testing.expectApproxEqAbs(box.y2, 60.0, 0.001);
}

test "decodeBbox with offset" {
    const anchor = Anchor{ .cx = 50.0, .cy = 50.0, .w = 20.0, .h = 20.0 };
    const deltas = [_]f32{ 1.0, 1.0, 0.5, 0.5 }; // Shift right/down, grow 50%

    const box = decodeBbox(anchor, deltas);
    // gx = 1*20+50 = 70, gy = 1*20+50 = 70
    // gw = exp(0.5)*20 ≈ 32.97, gh = exp(0.5)*20 ≈ 32.97
    try std.testing.expectApproxEqAbs(box.x1, 70.0 - 32.97 * 0.5, 0.1);
    try std.testing.expectApproxEqAbs(box.y1, 70.0 - 32.97 * 0.5, 0.1);
}

test "decodeLandmarks from anchor offsets" {
    const anchor = Anchor{ .cx = 50.0, .cy = 50.0, .w = 20.0, .h = 20.0 };
    const offsets = [_]f32{ 0.0, 0.0, 0.5, 0.0, -0.5, 0.0, 0.0, 0.5, 0.0, -0.5 };

    const landmarks = decodeLandmarks(anchor, offsets);
    // Point 0: (0*20+50, 0*20+50) = (50, 50)
    try std.testing.expectApproxEqAbs(landmarks[0][0], 50.0, 0.001);
    try std.testing.expectApproxEqAbs(landmarks[0][1], 50.0, 0.001);
    // Point 1: (0.5*20+50, 0*20+50) = (60, 50)
    try std.testing.expectApproxEqAbs(landmarks[1][0], 60.0, 0.001);
}

test "decodeScrfdBbox anchor-free decoding" {
    const box = decodeScrfdBbox(10, 20, 8.0, .{ -1.0, -1.0, 1.0, 1.0 });
    // x1 = 10*8 + (-1)*8 = 72
    // y1 = 20*8 + (-1)*8 = 152
    // x2 = 10*8 + 1*8 = 88
    // y2 = 20*8 + 1*8 = 168
    try std.testing.expectApproxEqAbs(box.x1, 72.0, 0.001);
    try std.testing.expectApproxEqAbs(box.y1, 152.0, 0.001);
    try std.testing.expectApproxEqAbs(box.x2, 88.0, 0.001);
    try std.testing.expectApproxEqAbs(box.y2, 168.0, 0.001);
}

test "decodeScrfdLandmarks anchor-free" {
    const landmarks = decodeScrfdLandmarks(10, 20, 8.0, .{ 0.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 1.0, 0.0, -1.0 });
    // Point 0: (10*8 + 0*8, 20*8 + 0*8) = (80, 160)
    try std.testing.expectApproxEqAbs(landmarks[0][0], 80.0, 0.001);
    try std.testing.expectApproxEqAbs(landmarks[0][1], 160.0, 0.001);
    // Point 1: (10*8 + 1*8, 20*8 + 0*8) = (88, 160)
    try std.testing.expectApproxEqAbs(landmarks[1][0], 88.0, 0.001);
}

test "postProcessMultiScale filters by score and clips" {
    const allocator = std.testing.allocator;
    const detections = [_]FaceBox{
        .{ .x1 = -10, .y1 = -10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 40, .confidence = 0.3 }, // Below threshold
        .{ .x1 = 60, .y1 = 60, .x2 = 100, .y2 = 100, .confidence = 0.8 },
    };

    const config = DetectionConfig{ .score_threshold = 0.5, .nms_threshold = 0.3, .max_det_count = 300 };
    const result = try postProcessMultiScale(allocator, &detections, config, 100, 100);
    defer allocator.free(result);

    // Box 1 filtered (score 0.3 < 0.5), boxes 0 and 2 survive (no overlap)
    try std.testing.expect(result.len == 2);
    // Box 0 clipped from -10 to 0
    try std.testing.expect(result[0].x1 == 0.0);
    try std.testing.expect(result[0].y1 == 0.0);
}

test "postProcessMultiScale respects max_det_count" {
    const allocator = std.testing.allocator;
    var detections: [10]FaceBox = undefined;
    for (0..10) |i| {
        detections[i] = .{
            .x1 = @as(f32, @floatFromInt(i * 20)),
            .y1 = @as(f32, @floatFromInt(i * 20)),
            .x2 = @as(f32, @floatFromInt(i * 20 + 10)),
            .y2 = @as(f32, @floatFromInt(i * 20 + 10)),
            .confidence = 0.9,
        };
    }

    const config = DetectionConfig{ .score_threshold = 0.5, .nms_threshold = 0.1, .max_det_count = 5 };
    const result = try postProcessMultiScale(allocator, &detections, config, 500, 500);
    defer allocator.free(result);

    try std.testing.expect(result.len <= 5);
}

test "FaceDetector postProcess integrates pipeline" {
    const allocator = std.testing.allocator;
    const detector = FaceDetector.init(allocator, .{
        .score_threshold = 0.6,
        .nms_threshold = 0.4,
        .max_det_count = 100,
    });

    const detections = [_]FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 12, .y1 = 12, .x2 = 52, .y2 = 52, .confidence = 0.85 }, // Overlaps with first
        .{ .x1 = 100, .y1 = 100, .x2 = 140, .y2 = 140, .confidence = 0.7 },
        .{ .x1 = 200, .y1 = 200, .x2 = 240, .y2 = 240, .confidence = 0.4 }, // Below threshold
    };

    const result = try detector.postProcess(&detections, 300, 300);
    defer allocator.free(result);

    // NMS removes one of the overlapping pair, threshold removes the last
    try std.testing.expect(result.len == 2);
    try std.testing.expect(result[0].confidence == 0.9);
    try std.testing.expect(result[1].confidence == 0.7);
}

test "sortByConfidence sorts descending" {
    var boxes = [_]FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .confidence = 0.3 },
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .confidence = 0.9 },
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1, .confidence = 0.5 },
    };

    sortByConfidence(&boxes);

    try std.testing.expect(boxes[0].confidence == 0.9);
    try std.testing.expect(boxes[1].confidence == 0.5);
    try std.testing.expect(boxes[2].confidence == 0.3);
}
