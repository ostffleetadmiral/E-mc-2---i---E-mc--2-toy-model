//! gaze_headpose.zig — Gaze estimation and head pose extraction.
//!
//! Provides gaze direction (pitch, yaw in radians) and 6D head pose
//! (pitch, yaw, roll in degrees) from facial landmarks or model output.
//! All math is pure Zig — model inference is delegated to onnx_runtime.zig.

const std = @import("std");
const face_detect = @import("face_detect");
const face_landmark = @import("face_landmark");

// =============================================================================
// Types
// =============================================================================

pub const GazeResult = struct {
    pitch: f32, // Vertical gaze angle in radians [-π/2, π/2]
    yaw: f32, // Horizontal gaze angle in radians [-π/2, π/2]
};

pub const HeadPoseResult = struct {
    pitch: f32, // Nod angle in degrees [-90, 90]
    yaw: f32, // Turn angle in degrees [-90, 90]
    roll: f32, // Tilt angle in degrees [-180, 180]
};

pub const GazeError = error{
    InvalidLandmarks,
    InvalidInput,
};

// =============================================================================
// Head pose estimation from 2D landmarks (PnP approximation)
// =============================================================================

/// Estimate head pose (pitch, yaw, roll) from 2D landmarks using a geometric approach.
/// Uses the ratio of facial feature distances to infer rotation angles.
pub fn estimateHeadPose(landmarks: [5][2]f32) GazeError!HeadPoseResult {
    // landmarks: [left_eye, right_eye, nose, left_mouth, right_mouth]
    const left_eye = landmarks[0];
    const right_eye = landmarks[1];
    const nose = landmarks[2];
    const left_mouth = landmarks[3];
    const right_mouth = landmarks[4];

    // Roll: angle of the line between eyes
    const dx_eyes = right_eye[0] - left_eye[0];
    const dy_eyes = right_eye[1] - left_eye[1];
    const roll = std.math.atan2(dy_eyes, dx_eyes) * 180.0 / std.math.pi;

    // Yaw: based on nose position relative to eye midpoint
    const eye_mid_x = (left_eye[0] + right_eye[0]) * 0.5;
    const eye_mid_y = (left_eye[1] + right_eye[1]) * 0.5;
    const eye_dist = @sqrt(dx_eyes * dx_eyes + dy_eyes * dy_eyes);
    if (eye_dist < 1e-6) return error.InvalidLandmarks;

    const nose_offset_x = (nose[0] - eye_mid_x) / eye_dist;
    // Clamp to reasonable range and map to degrees
    const yaw = std.math.clamp(nose_offset_x * 90.0, -90.0, 90.0);

    // Pitch: based on nose position relative to eye-mouth midpoint
    const mouth_mid_y = (left_mouth[1] + right_mouth[1]) * 0.5;
    const face_height = mouth_mid_y - eye_mid_y;
    if (face_height < 1e-6) return error.InvalidLandmarks;

    const nose_offset_y = (nose[1] - eye_mid_y) / face_height;
    // Neutral face: nose at ~0.6 of face height. Deviation indicates pitch.
    const pitch = std.math.clamp((nose_offset_y - 0.6) * 90.0, -90.0, 90.0);

    return .{
        .pitch = pitch,
        .yaw = yaw,
        .roll = roll,
    };
}

// =============================================================================
// Gaze estimation from iris/eye landmarks
// =============================================================================

/// Estimate gaze direction from eye landmarks.
/// Uses the ratio of iris position within the eye bounding box.
pub fn estimateGaze(
    left_eye_points: []const face_landmark.Point2D,
    right_eye_points: []const face_landmark.Point2D,
    left_iris: ?face_landmark.Point2D,
    right_iris: ?face_landmark.Point2D,
) GazeError!GazeResult {
    if (left_eye_points.len < 4 or right_eye_points.len < 4) return error.InvalidLandmarks;

    // Compute eye bounding boxes
    const left_bounds = face_landmark.landmarkBounds2D(left_eye_points);
    const right_bounds = face_landmark.landmarkBounds2D(right_eye_points);

    const left_w = left_bounds.max_x - left_bounds.min_x;
    const left_h = left_bounds.max_y - left_bounds.min_y;
    const right_w = right_bounds.max_x - right_bounds.min_x;
    const right_h = right_bounds.max_y - right_bounds.min_y;

    if (left_w < 1e-6 or right_w < 1e-6) return error.InvalidLandmarks;

    // Use iris position if available, otherwise use eye center
    var left_gaze_x: f32 = 0.5;
    var left_gaze_y: f32 = 0.5;
    if (left_iris) |iris| {
        left_gaze_x = (iris.x - left_bounds.min_x) / left_w;
        left_gaze_y = (iris.y - left_bounds.min_y) / left_h;
    }

    var right_gaze_x: f32 = 0.5;
    var right_gaze_y: f32 = 0.5;
    if (right_iris) |iris| {
        right_gaze_x = (iris.x - right_bounds.min_x) / right_w;
        right_gaze_y = (iris.y - right_bounds.min_y) / right_h;
    }

    // Average gaze direction from both eyes
    // Normalize: 0.5 = center (looking straight), 0 = left/up, 1 = right/down
    const avg_gaze_x = (left_gaze_x + right_gaze_x) * 0.5;
    const avg_gaze_y = (left_gaze_y + right_gaze_y) * 0.5;

    // Map [0, 1] to angle in radians
    // gaze_x = 0.5 → yaw = 0, gaze_x = 0 → yaw = -π/3, gaze_x = 1 → yaw = π/3
    const yaw = (avg_gaze_x - 0.5) * 2.0 * (std.math.pi / 3.0);
    // gaze_y = 0.5 → pitch = 0, gaze_y = 0 → pitch = -π/3 (up), gaze_y = 1 → pitch = π/3 (down)
    const pitch = (avg_gaze_y - 0.5) * 2.0 * (std.math.pi / 3.0);

    return .{
        .pitch = std.math.clamp(pitch, -std.math.pi / 2.0, std.math.pi / 2.0),
        .yaw = std.math.clamp(yaw, -std.math.pi / 2.0, std.math.pi / 2.0),
    };
}

// =============================================================================
// High-level estimators
// =============================================================================

pub const HeadPoseEstimator = struct {
    pub fn estimate(self: HeadPoseEstimator, landmarks: [5][2]f32) GazeError!HeadPoseResult {
        _ = self;
        return estimateHeadPose(landmarks);
    }
};

pub const GazeEstimator = struct {
    pub fn estimate(
        self: GazeEstimator,
        left_eye_points: []const face_landmark.Point2D,
        right_eye_points: []const face_landmark.Point2D,
        left_iris: ?face_landmark.Point2D,
        right_iris: ?face_landmark.Point2D,
    ) GazeError!GazeResult {
        _ = self;
        return estimateGaze(left_eye_points, right_eye_points, left_iris, right_iris);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "estimateHeadPose neutral face" {
    // Symmetric face looking straight ahead
    const landmarks = [5][2]f32{
        .{ 30.0, 50.0 }, // Left eye
        .{ 70.0, 50.0 }, // Right eye
        .{ 50.0, 60.0 }, // Nose (center, slightly below eyes)
        .{ 35.0, 80.0 }, // Left mouth
        .{ 65.0, 80.0 }, // Right mouth
    };

    const pose = try estimateHeadPose(landmarks);

    // Roll should be ~0 (horizontal eyes)
    try std.testing.expectApproxEqAbs(pose.roll, 0.0, 1.0);
    // Yaw should be ~0 (nose centered)
    try std.testing.expectApproxEqAbs(pose.yaw, 0.0, 5.0);
}

test "estimateHeadPose with roll tilt" {
    // Eyes tilted 45 degrees
    const landmarks = [5][2]f32{
        .{ 30.0, 60.0 }, // Left eye (lower)
        .{ 70.0, 40.0 }, // Right eye (higher)
        .{ 50.0, 60.0 },
        .{ 35.0, 80.0 },
        .{ 65.0, 80.0 },
    };

    const pose = try estimateHeadPose(landmarks);
    // Roll should be positive (right eye higher than left)
    try std.testing.expect(pose.roll < 0.0); // dy_eyes = 40-60 = -20, so atan2(-20, 40) < 0
}

test "estimateHeadPose with yaw (looking right)" {
    // Nose shifted to the right
    const landmarks = [5][2]f32{
        .{ 30.0, 50.0 },
        .{ 70.0, 50.0 },
        .{ 65.0, 60.0 }, // Nose shifted right
        .{ 35.0, 80.0 },
        .{ 65.0, 80.0 },
    };

    const pose = try estimateHeadPose(landmarks);
    // Yaw should be positive (looking right)
    try std.testing.expect(pose.yaw > 0.0);
}

test "estimateHeadPose rejects degenerate landmarks" {
    // All points at same location
    const landmarks = [5][2]f32{
        .{ 50.0, 50.0 },
        .{ 50.0, 50.0 },
        .{ 50.0, 50.0 },
        .{ 50.0, 50.0 },
        .{ 50.0, 50.0 },
    };

    try std.testing.expectError(error.InvalidLandmarks, estimateHeadPose(landmarks));
}

test "estimateGaze looking straight (centered iris)" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 },
        .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 },
    };
    const iris = face_landmark.Point2D{ .x = 20, .y = 25 }; // Center

    const gaze = try estimateGaze(&eye_points, &eye_points, iris, iris);

    // Looking straight → pitch ≈ 0, yaw ≈ 0
    try std.testing.expectApproxEqAbs(gaze.pitch, 0.0, 0.1);
    try std.testing.expectApproxEqAbs(gaze.yaw, 0.0, 0.1);
}

test "estimateGaze looking right" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 },
        .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 },
    };
    const iris = face_landmark.Point2D{ .x = 27, .y = 25 }; // Right of center

    const gaze = try estimateGaze(&eye_points, &eye_points, iris, iris);

    // Looking right → yaw > 0
    try std.testing.expect(gaze.yaw > 0.0);
}

test "estimateGaze looking left" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 },
        .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 },
    };
    const iris = face_landmark.Point2D{ .x = 13, .y = 25 }; // Left of center

    const gaze = try estimateGaze(&eye_points, &eye_points, iris, iris);

    // Looking left → yaw < 0
    try std.testing.expect(gaze.yaw < 0.0);
}

test "estimateGaze looking down" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 },
        .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 },
    };
    const iris = face_landmark.Point2D{ .x = 20, .y = 28 }; // Below center

    const gaze = try estimateGaze(&eye_points, &eye_points, iris, iris);

    // Looking down → pitch > 0
    try std.testing.expect(gaze.pitch > 0.0);
}

test "estimateGaze without iris uses eye center" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 },
        .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 },
    };

    const gaze = try estimateGaze(&eye_points, &eye_points, null, null);

    // No iris → defaults to 0.5, 0.5 → looking straight
    try std.testing.expectApproxEqAbs(gaze.pitch, 0.0, 0.01);
    try std.testing.expectApproxEqAbs(gaze.yaw, 0.0, 0.01);
}

test "estimateGaze rejects insufficient eye points" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 },
    };

    try std.testing.expectError(error.InvalidLandmarks, estimateGaze(&eye_points, &eye_points, null, null));
}

test "GazeResult angle range is valid" {
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 },
        .{ .x = 0, .y = 50 }, .{ .x = 100, .y = 50 },
    };
    // Extreme iris positions
    const iris_extreme = face_landmark.Point2D{ .x = 99, .y = 49 };

    const gaze = try estimateGaze(&eye_points, &eye_points, iris_extreme, iris_extreme);

    try std.testing.expect(gaze.pitch >= -std.math.pi / 2.0);
    try std.testing.expect(gaze.pitch <= std.math.pi / 2.0);
    try std.testing.expect(gaze.yaw >= -std.math.pi / 2.0);
    try std.testing.expect(gaze.yaw <= std.math.pi / 2.0);
}

test "HeadPoseEstimator struct" {
    const estimator = HeadPoseEstimator{};
    const landmarks = [5][2]f32{
        .{ 30.0, 50.0 }, .{ 70.0, 50.0 }, .{ 50.0, 60.0 },
        .{ 35.0, 80.0 }, .{ 65.0, 80.0 },
    };
    const pose = try estimator.estimate(landmarks);
    try std.testing.expect(pose.roll >= -180.0 and pose.roll <= 180.0);
}

test "GazeEstimator struct" {
    const estimator = GazeEstimator{};
    const eye_points = [_]face_landmark.Point2D{
        .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 },
        .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 },
    };
    const gaze = try estimator.estimate(&eye_points, &eye_points, null, null);
    try std.testing.expectApproxEqAbs(gaze.yaw, 0.0, 0.01);
}
