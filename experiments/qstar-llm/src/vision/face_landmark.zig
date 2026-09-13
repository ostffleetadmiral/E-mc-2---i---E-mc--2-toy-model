//! face_landmark.zig — Facial landmark detection post-processing.
//!
//! Supports PIPNet (98-point, 68-point) and FaceMesh (468-point, 478-point 3D)
//! landmark models. Model inference is delegated to onnx_runtime.zig; this module
//! handles all pure-Zig post-processing: point extraction, coordinate normalization,
//! face crop boundary handling, and 3D mesh operations.

const std = @import("std");
const face_detect = @import("face_detect");

// =============================================================================
// Types
// =============================================================================

pub const LandmarkModel = enum {
    PIPNet98, // 98 2D points
    PIPNet68, // 68 2D points
    FaceMesh468, // 468 3D points
    FaceMesh478, // 478 3D points (468 + 10 iris points)
};

pub const LandmarkError = error{
    InvalidInput,
    OutOfMemory,
    PointCountMismatch,
};

/// A 2D landmark point (x, y) in pixel coordinates.
pub const Point2D = struct {
    x: f32,
    y: f32,
};

/// A 3D landmark point (x, y, z) where z is relative depth.
pub const Point3D = struct {
    x: f32,
    y: f32,
    z: f32,
};

/// Result of landmark detection — holds either 2D or 3D points.
pub const LandmarkResult = struct {
    model: LandmarkModel,
    points_2d: ?[]Point2D = null,
    points_3d: ?[]Point3D = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LandmarkResult) void {
        if (self.points_2d) |p| self.allocator.free(p);
        if (self.points_3d) |p| self.allocator.free(p);
    }

    pub fn count(self: LandmarkResult) usize {
        return switch (self.model) {
            .PIPNet98 => 98,
            .PIPNet68 => 68,
            .FaceMesh468 => 468,
            .FaceMesh478 => 478,
        };
    }

    pub fn is3D(self: LandmarkResult) bool {
        return self.model == .FaceMesh468 or self.model == .FaceMesh478;
    }
};

// =============================================================================
// PIPNet post-processing
// =============================================================================

/// PIPNet outputs coordinates in normalized [0, 1] space relative to the input crop.
/// Convert to absolute pixel coordinates within the original image.
pub fn pipnetPostProcess(
    allocator: std.mem.Allocator,
    raw_points: []const f32, // [N*2] normalized (x, y) pairs
    model: LandmarkModel,
    face_box: face_detect.FaceBox,
    img_width: usize,
    img_height: usize,
) LandmarkError!LandmarkResult {
    const n: usize = switch (model) {
        .PIPNet98 => 98,
        .PIPNet68 => 68,
        else => return error.InvalidInput,
    };

    if (raw_points.len < n * 2) return error.PointCountMismatch;

    var points = try allocator.alloc(Point2D, n);
    const box_w = face_box.width();
    const box_h = face_box.height();

    for (0..n) |i| {
        const nx = raw_points[i * 2];
        const ny = raw_points[i * 2 + 1];

        // Map from [0,1] in crop space to absolute image coordinates
        var px = face_box.x1 + nx * box_w;
        var py = face_box.y1 + ny * box_h;

        // Clamp to image bounds
        px = std.math.clamp(px, 0.0, @as(f32, @floatFromInt(img_width)));
        py = std.math.clamp(py, 0.0, @as(f32, @floatFromInt(img_height)));

        points[i] = .{ .x = px, .y = py };
    }

    return .{
        .model = model,
        .points_2d = points,
        .allocator = allocator,
    };
}

// =============================================================================
// FaceMesh post-processing
// =============================================================================

/// FaceMesh outputs 468 or 478 3D points. x, y are normalized [0,1] relative to
// input image, z is relative depth (smaller = closer to camera).
pub fn facemeshPostProcess(
    allocator: std.mem.Allocator,
    raw_points: []const f32, // [N*3] normalized (x, y, z) triples
    model: LandmarkModel,
    img_width: usize,
    img_height: usize,
) LandmarkError!LandmarkResult {
    const n: usize = switch (model) {
        .FaceMesh468 => 468,
        .FaceMesh478 => 478,
        else => return error.InvalidInput,
    };

    if (raw_points.len < n * 3) return error.PointCountMismatch;

    var points = try allocator.alloc(Point3D, n);
    const img_w_f = @as(f32, @floatFromInt(img_width));
    const img_h_f = @as(f32, @floatFromInt(img_height));

    for (0..n) |i| {
        const nx = raw_points[i * 3];
        const ny = raw_points[i * 3 + 1];
        const nz = raw_points[i * 3 + 2];

        points[i] = .{
            .x = nx * img_w_f,
            .y = ny * img_h_f,
            .z = nz * img_w_f, // z is scaled by width (approximate depth)
        };
    }

    return .{
        .model = model,
        .points_3d = points,
        .allocator = allocator,
    };
}

// =============================================================================
// Landmark utilities
// =============================================================================

/// Compute the bounding box of a set of 2D landmarks.
pub fn landmarkBounds2D(points: []const Point2D) struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 } {
    if (points.len == 0) return .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };

    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;

    for (points[1..]) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }

    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

/// Compute the center of a set of 2D landmarks.
pub fn landmarkCenter2D(points: []const Point2D) Point2D {
    if (points.len == 0) return .{ .x = 0, .y = 0 };

    var cx: f32 = 0;
    var cy: f32 = 0;
    for (points) |p| {
        cx += p.x;
        cy += p.y;
    }

    return .{ .x = cx / @as(f32, @floatFromInt(points.len)), .y = cy / @as(f32, @floatFromInt(points.len)) };
}

/// Extract the 5 key landmarks (eyes, nose, mouth corners) from a 98-point PIPNet result.
/// PIPNet 98-point layout: points 60-67 are left eye, 68-76 are right eye,
/// 86-91 is nose, 88-95 is mouth outer, 96-97 is inner mouth.
pub fn extract5KeyPoints98(points: []const Point2D) LandmarkError![5][2]f32 {
    if (points.len < 98) return error.PointCountMismatch;

    // Left eye center (average of eye contour points 60-67)
    var lex: f32 = 0;
    var ley: f32 = 0;
    for (60..68) |i| {
        lex += points[i].x;
        ley += points[i].y;
    }
    lex /= 8.0;
    ley /= 8.0;

    // Right eye center (average of eye contour points 68-76)
    var rex: f32 = 0;
    var rey: f32 = 0;
    for (68..77) |i| {
        rex += points[i].x;
        rey += points[i].y;
    }
    rex /= 9.0;
    rey /= 9.0;

    // Nose tip (point 86)
    const nose_x = points[86].x;
    const nose_y = points[86].y;

    // Left mouth corner (point 88)
    const lmx = points[88].x;
    const lmy = points[88].y;

    // Right mouth corner (point 96 or 92)
    const rmx = points[92].x;
    const rmy = points[92].y;

    return .{
        .{ lex, ley }, // Left eye
        .{ rex, rey }, // Right eye
        .{ nose_x, nose_y }, // Nose
        .{ lmx, lmy }, // Left mouth
        .{ rmx, rmy }, // Right mouth
    };
}

/// Extract the 5 key landmarks from a 68-point PIPNet result.
/// 68-point layout: 0-16 jaw, 17-21 left eyebrow, 22-26 right eyebrow,
/// 27-30 nose bridge, 31-35 nose bottom, 36-41 left eye, 42-47 right eye,
/// 48-67 mouth.
pub fn extract5KeyPoints68(points: []const Point2D) LandmarkError![5][2]f32 {
    if (points.len < 68) return error.PointCountMismatch;

    // Left eye center (average of points 36-41)
    var lex: f32 = 0;
    var ley: f32 = 0;
    for (36..42) |i| {
        lex += points[i].x;
        ley += points[i].y;
    }
    lex /= 6.0;
    ley /= 6.0;

    // Right eye center (average of points 42-47)
    var rex: f32 = 0;
    var rey: f32 = 0;
    for (42..48) |i| {
        rex += points[i].x;
        rey += points[i].y;
    }
    rex /= 6.0;
    rey /= 6.0;

    // Nose tip (point 30)
    const nose_x = points[30].x;
    const nose_y = points[30].y;

    // Left mouth corner (point 48)
    const lmx = points[48].x;
    const lmy = points[48].y;

    // Right mouth corner (point 54)
    const rmx = points[54].x;
    const rmy = points[54].y;

    return .{
        .{ lex, ley },
        .{ rex, rey },
        .{ nose_x, nose_y },
        .{ lmx, lmy },
        .{ rmx, rmy },
    };
}

/// Get specific facial region points from FaceMesh 468-point model.
/// Returns indices for common regions.
pub const FaceMeshRegions = struct {
    pub const left_eye: []const usize = &.{ 33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246 };
    pub const right_eye: []const usize = &.{ 263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466 };
    pub const lips_outer: []const usize = &.{ 61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185 };
    pub const nose: []const usize = &.{ 168, 6, 197, 195, 5, 4, 1, 19, 94, 2 };
    pub const left_iris: []const usize = &.{ 468, 469, 470, 471, 472 };
    pub const right_iris: []const usize = &.{ 473, 474, 475, 476, 477 };
};

// =============================================================================
// Landmark detector (high-level interface)
// =============================================================================

pub const LandmarkDetector = struct {
    model: LandmarkModel,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, model: LandmarkModel) LandmarkDetector {
        return .{ .model = model, .allocator = allocator };
    }

    pub fn detectLandmarks(
        self: LandmarkDetector,
        raw_output: []const f32,
        face_box: face_detect.FaceBox,
        img_width: usize,
        img_height: usize,
    ) LandmarkError!LandmarkResult {
        return switch (self.model) {
            .PIPNet98, .PIPNet68 => pipnetPostProcess(self.allocator, raw_output, self.model, face_box, img_width, img_height),
            .FaceMesh468, .FaceMesh478 => facemeshPostProcess(self.allocator, raw_output, self.model, img_width, img_height),
        };
    }

    pub fn extractKeyPoints(self: LandmarkDetector, result: LandmarkResult) LandmarkError![5][2]f32 {
        if (result.points_2d == null) return error.InvalidInput;
        const points = result.points_2d.?;
        return switch (self.model) {
            .PIPNet98 => extract5KeyPoints98(points),
            .PIPNet68 => extract5KeyPoints68(points),
            else => error.InvalidInput,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "LandmarkResult count for each model" {
    const allocator = std.testing.allocator;

    var r98 = LandmarkResult{ .model = .PIPNet98, .allocator = allocator };
    try std.testing.expect(r98.count() == 98);

    var r68 = LandmarkResult{ .model = .PIPNet68, .allocator = allocator };
    try std.testing.expect(r68.count() == 68);

    var r468 = LandmarkResult{ .model = .FaceMesh468, .allocator = allocator };
    try std.testing.expect(r468.count() == 468);

    var r478 = LandmarkResult{ .model = .FaceMesh478, .allocator = allocator };
    try std.testing.expect(r478.count() == 478);
}

test "LandmarkResult is3D" {
    const allocator = std.testing.allocator;
    var r2d = LandmarkResult{ .model = .PIPNet98, .allocator = allocator };
    try std.testing.expect(!r2d.is3D());

    var r3d = LandmarkResult{ .model = .FaceMesh468, .allocator = allocator };
    try std.testing.expect(r3d.is3D());
}

test "pipnetPostProcess 98 points" {
    const allocator = std.testing.allocator;
    var raw: [196]f32 = undefined;
    for (0..98) |i| {
        raw[i * 2] = @as(f32, @floatFromInt(i)) / 98.0; // x: 0..1
        raw[i * 2 + 1] = @as(f32, @floatFromInt(i)) / 98.0; // y: 0..1
    }

    const face_box = face_detect.FaceBox{ .x1 = 10, .y1 = 20, .x2 = 110, .y2 = 120, .confidence = 0.9 };
    var result = try pipnetPostProcess(allocator, &raw, .PIPNet98, face_box, 200, 200);
    defer result.deinit();

    try std.testing.expect(result.points_2d != null);
    try std.testing.expect(result.points_2d.?.len == 98);

    // First point: (10 + 0 * 100, 20 + 0 * 100) = (10, 20)
    try std.testing.expectApproxEqAbs(result.points_2d.?[0].x, 10.0, 0.01);
    try std.testing.expectApproxEqAbs(result.points_2d.?[0].y, 20.0, 0.01);
}

test "pipnetPostProcess 68 points" {
    const allocator = std.testing.allocator;
    var raw: [136]f32 = undefined;
    for (0..68) |i| {
        raw[i * 2] = 0.5;
        raw[i * 2 + 1] = 0.5;
    }

    const face_box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 100, .confidence = 0.9 };
    var result = try pipnetPostProcess(allocator, &raw, .PIPNet68, face_box, 100, 100);
    defer result.deinit();

    try std.testing.expect(result.points_2d.?.len == 68);
    // All points at center: (50, 50)
    try std.testing.expectApproxEqAbs(result.points_2d.?[0].x, 50.0, 0.01);
}

test "pipnetPostProcess rejects wrong model" {
    const allocator = std.testing.allocator;
    const raw = [_]f32{0} ** 196;
    const face_box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    try std.testing.expectError(error.InvalidInput, pipnetPostProcess(allocator, &raw, .FaceMesh468, face_box, 100, 100));
}

test "pipnetPostProcess rejects insufficient raw data" {
    const allocator = std.testing.allocator;
    const raw = [_]f32{0.5, 0.5}; // Only 1 point, need 98
    const face_box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 };
    try std.testing.expectError(error.PointCountMismatch, pipnetPostProcess(allocator, &raw, .PIPNet98, face_box, 100, 100));
}

test "pipnetPostProcess clamps to image bounds" {
    const allocator = std.testing.allocator;
    var raw: [196]f32 = undefined;
    for (0..98) |i| {
        raw[i * 2] = 2.0; // Way outside [0,1]
        raw[i * 2 + 1] = 2.0;
    }

    const face_box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 100, .confidence = 0.9 };
    var result = try pipnetPostProcess(allocator, &raw, .PIPNet98, face_box, 100, 100);
    defer result.deinit();

    // Should be clamped to 100
    try std.testing.expectApproxEqAbs(result.points_2d.?[0].x, 100.0, 0.01);
    try std.testing.expectApproxEqAbs(result.points_2d.?[0].y, 100.0, 0.01);
}

test "facemeshPostProcess 468 points" {
    const allocator = std.testing.allocator;
    var raw: [1404]f32 = undefined; // 468 * 3
    for (0..468) |i| {
        raw[i * 3] = 0.5;
        raw[i * 3 + 1] = 0.5;
        raw[i * 3 + 2] = 0.0;
    }

    var result = try facemeshPostProcess(allocator, &raw, .FaceMesh468, 200, 200);
    defer result.deinit();

    try std.testing.expect(result.points_3d != null);
    try std.testing.expect(result.points_3d.?.len == 468);
    // x = 0.5 * 200 = 100, y = 0.5 * 200 = 100
    try std.testing.expectApproxEqAbs(result.points_3d.?[0].x, 100.0, 0.01);
    try std.testing.expectApproxEqAbs(result.points_3d.?[0].y, 100.0, 0.01);
}

test "facemeshPostProcess 478 points" {
    const allocator = std.testing.allocator;
    var raw: [1434]f32 = undefined; // 478 * 3
    for (0..478) |i| {
        raw[i * 3] = 0.25;
        raw[i * 3 + 1] = 0.75;
        raw[i * 3 + 2] = -0.1;
    }

    var result = try facemeshPostProcess(allocator, &raw, .FaceMesh478, 100, 100);
    defer result.deinit();

    try std.testing.expect(result.points_3d.?.len == 478);
    try std.testing.expectApproxEqAbs(result.points_3d.?[0].x, 25.0, 0.01);
    try std.testing.expectApproxEqAbs(result.points_3d.?[0].y, 75.0, 0.01);
}

test "landmarkBounds2D" {
    const points = [_]Point2D{
        .{ .x = 10, .y = 20 },
        .{ .x = 50, .y = 5 },
        .{ .x = 30, .y = 80 },
    };

    const bounds = landmarkBounds2D(&points);
    try std.testing.expect(bounds.min_x == 10.0);
    try std.testing.expect(bounds.min_y == 5.0);
    try std.testing.expect(bounds.max_x == 50.0);
    try std.testing.expect(bounds.max_y == 80.0);
}

test "landmarkBounds2D empty" {
    const bounds = landmarkBounds2D(&[_]Point2D{});
    try std.testing.expect(bounds.min_x == 0.0);
    try std.testing.expect(bounds.max_x == 0.0);
}

test "landmarkCenter2D" {
    const points = [_]Point2D{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 20 },
        .{ .x = 20, .y = 40 },
    };

    const center = landmarkCenter2D(&points);
    try std.testing.expectApproxEqAbs(center.x, 10.0, 0.001);
    try std.testing.expectApproxEqAbs(center.y, 20.0, 0.001);
}

test "extract5KeyPoints98" {
    var points: [98]Point2D = undefined;
    for (0..98) |i| {
        points[i] = .{ .x = @as(f32, @floatFromInt(i)), .y = @as(f32, @floatFromInt(i)) };
    }

    const kp = try extract5KeyPoints98(&points);
    try std.testing.expect(kp.len == 5);

    // Left eye center = average of points 60-67 = (63.5, 63.5)
    try std.testing.expectApproxEqAbs(kp[0][0], 63.5, 0.01);
    try std.testing.expectApproxEqAbs(kp[0][1], 63.5, 0.01);
}

test "extract5KeyPoints68" {
    var points: [68]Point2D = undefined;
    for (0..68) |i| {
        points[i] = .{ .x = @as(f32, @floatFromInt(i)), .y = @as(f32, @floatFromInt(i)) };
    }

    const kp = try extract5KeyPoints68(&points);
    try std.testing.expect(kp.len == 5);

    // Left eye center = average of points 36-41 = (38.5, 38.5)
    try std.testing.expectApproxEqAbs(kp[0][0], 38.5, 0.01);
    try std.testing.expectApproxEqAbs(kp[0][1], 38.5, 0.01);

    // Nose tip = point 30 = (30, 30)
    try std.testing.expectApproxEqAbs(kp[2][0], 30.0, 0.01);
}

test "extract5KeyPoints98 rejects insufficient points" {
    const points = [_]Point2D{ .{ .x = 0, .y = 0 } } ** 50;
    try std.testing.expectError(error.PointCountMismatch, extract5KeyPoints98(&points));
}

test "FaceMeshRegions has correct indices" {
    try std.testing.expect(FaceMeshRegions.left_eye.len == 16);
    try std.testing.expect(FaceMeshRegions.right_eye.len == 16);
    try std.testing.expect(FaceMeshRegions.lips_outer.len == 20);
    try std.testing.expect(FaceMeshRegions.left_iris.len == 5);
    try std.testing.expect(FaceMeshRegions.right_iris.len == 5);
}

test "LandmarkDetector detectLandmarks PIPNet98" {
    const allocator = std.testing.allocator;
    const detector = LandmarkDetector.init(allocator, .PIPNet98);

    var raw: [196]f32 = undefined;
    for (0..98) |i| {
        raw[i * 2] = 0.5;
        raw[i * 2 + 1] = 0.5;
    }

    const face_box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 100, .confidence = 0.9 };
    var result = try detector.detectLandmarks(&raw, face_box, 100, 100);
    defer result.deinit();

    try std.testing.expect(result.points_2d.?.len == 98);
}

test "LandmarkDetector detectLandmarks FaceMesh468" {
    const allocator = std.testing.allocator;
    const detector = LandmarkDetector.init(allocator, .FaceMesh468);

    var raw: [1404]f32 = undefined;
    for (0..468) |i| {
        raw[i * 3] = 0.5;
        raw[i * 3 + 1] = 0.5;
        raw[i * 3 + 2] = 0.0;
    }

    var result = try detector.detectLandmarks(&raw, .{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 100, .confidence = 0.9 }, 100, 100);
    defer result.deinit();

    try std.testing.expect(result.points_3d.?.len == 468);
}

test "LandmarkDetector extractKeyPoints PIPNet98" {
    const allocator = std.testing.allocator;
    const detector = LandmarkDetector.init(allocator, .PIPNet98);

    var raw: [196]f32 = undefined;
    for (0..98) |i| {
        raw[i * 2] = 0.5;
        raw[i * 2 + 1] = 0.5;
    }

    const face_box = face_detect.FaceBox{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 100, .confidence = 0.9 };
    var result = try detector.detectLandmarks(&raw, face_box, 100, 100);
    defer result.deinit();

    const kp = try detector.extractKeyPoints(result);
    try std.testing.expect(kp.len == 5);
}
