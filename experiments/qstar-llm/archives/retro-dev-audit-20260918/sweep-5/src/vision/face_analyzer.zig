//! face_analyzer.zig — Unified face analysis pipeline.
//!
//! Orchestrates detection, recognition, landmark extraction, gaze/headpose,
//! attributes, parsing, quality, and anti-spoofing into a single pipeline.
//! Gracefully degrades when ONNX models are not available (post-processing
//! logic still works with provided raw model outputs).

const std = @import("std");
const image = @import("image");
const face_detect = @import("face_detect");
const face_recognize = @import("face_recognize");
const face_landmark = @import("face_landmark");
const face_track = @import("face_track");
const gaze_headpose = @import("gaze_headpose");
const face_attributes = @import("face_attributes");
const face_parsing = @import("face_parsing");
const face_quality = @import("face_quality");
const anti_spoofing = @import("anti_spoofing");

// =============================================================================
// Types
// =============================================================================

pub const FaceAnalyzerError = error{
    OutOfMemory,
    InvalidInput,
};

/// Complete face analysis result with all optional fields.
pub const Face = struct {
    bbox: face_detect.FaceBox,
    track_id: ?u32 = null,
    landmarks: ?[5][2]f32 = null,
    landmark_result: ?face_landmark.LandmarkResult = null,
    embedding: ?[]f32 = null,
    gaze: ?gaze_headpose.GazeResult = null,
    head_pose: ?gaze_headpose.HeadPoseResult = null,
    demography: ?face_attributes.DemographyResult = null,
    emotion: ?face_attributes.EmotionResult = null,
    face_state: ?face_attributes.FaceStateResult = null,
    quality: ?face_quality.QualityResult = null,
    spoofing: ?anti_spoofing.SpoofingResult = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Face) void {
        if (self.embedding) |emb| self.allocator.free(emb);
        if (self.landmark_result) |*lr| lr.deinit();
    }
};

pub const FaceAnalyzerConfig = struct {
    detect: face_detect.DetectionConfig = .{},
    recognition_threshold: f32 = 0.5,
    embedding_dim: usize = 512,
    landmark_model: face_landmark.LandmarkModel = .PIPNet98,
    use_gaze: bool = true,
    use_headpose: bool = true,
    use_attributes: bool = true,
    use_parsing: bool = false,
    use_quality: bool = true,
    use_anti_spoofing: bool = true,
    use_tracking: bool = true,
};

// =============================================================================
// Face analyzer
// =============================================================================

pub const FaceAnalyzer = struct {
    config: FaceAnalyzerConfig,
    allocator: std.mem.Allocator,
    detector: face_detect.FaceDetector,
    tracker: ?face_track.FaceTracker = null,

    pub fn init(allocator: std.mem.Allocator, config: FaceAnalyzerConfig) FaceAnalyzer {
        return .{
            .config = config,
            .allocator = allocator,
            .detector = face_detect.FaceDetector.init(allocator, config.detect),
            .tracker = if (config.use_tracking) face_track.FaceTracker.init(allocator, .{}) else null,
        };
    }

    pub fn deinit(self: *FaceAnalyzer) void {
        if (self.tracker) |*t| t.deinit();
    }

    /// Detect faces in an image (post-processing from raw model output).
    pub fn detectFaces(self: *FaceAnalyzer, raw_detections: []const face_detect.FaceBox, img_width: usize, img_height: usize) FaceAnalyzerError![]face_detect.FaceBox {
        return self.detector.postProcess(raw_detections, img_width, img_height) catch return error.OutOfMemory;
    }

    /// Analyze a single face with all enabled predictors.
    /// This is the pure-Zig post-processing path — raw model outputs are provided by the caller.
    pub fn analyzeFace(
        self: *FaceAnalyzer,
        img: image.Image,
        bbox: face_detect.FaceBox,
        raw_landmarks: ?[]const f32,
        raw_embedding: ?[]const f32,
        raw_gender: ?[2]f32,
        raw_age: ?f32,
        raw_race: ?[5]f32,
        raw_emotion: ?[8]f32,
        raw_face_state: ?[5]f32,
        raw_spoofing: ?[4]f32,
        track_id: ?u32,
    ) FaceAnalyzerError!Face {
        var face = Face{
            .bbox = bbox,
            .track_id = track_id,
            .allocator = self.allocator,
        };

        // Landmarks
        if (raw_landmarks) |lm| {
            const lm_result = face_landmark.pipnetPostProcess(
                self.allocator,
                lm,
                self.config.landmark_model,
                bbox,
                img.width,
                img.height,
            ) catch null;

            if (lm_result) |lr| {
                face.landmark_result = lr;
                // Extract 5 key points
                if (lr.points_2d) |points| {
                    const kp = switch (self.config.landmark_model) {
                        .PIPNet98 => face_landmark.extract5KeyPoints98(points) catch null,
                        .PIPNet68 => face_landmark.extract5KeyPoints68(points) catch null,
                        else => null,
                    };
                    if (kp) |k| {
                        face.landmarks = k;

                        // Gaze & head pose from landmarks
                        if (self.config.use_headpose) {
                            face.head_pose = gaze_headpose.estimateHeadPose(k) catch null;
                        }
                    }
                }
            }
        }

        // Embedding
        if (raw_embedding) |emb| {
            const emb_copy = self.allocator.alloc(f32, emb.len) catch return error.OutOfMemory;
            @memcpy(emb_copy, emb);
            face_recognize.normalizeEmbedding(emb_copy);
            face.embedding = emb_copy;
        }

        // Attributes
        if (self.config.use_attributes) {
            if (raw_gender != null and raw_age != null and raw_race != null) {
                face.demography = face_attributes.predictDemography(
                    raw_gender.?,
                    raw_age.?,
                    null,
                    raw_race.?,
                ) catch null;
            }

            if (raw_emotion) |emo| {
                face.emotion = face_attributes.parseEmotion(emo) catch null;
            }

            if (raw_face_state) |fs| {
                face.face_state = face_attributes.parseFaceState(fs);
            }
        }

        // Quality (heuristic, always available)
        if (self.config.use_quality) {
            face.quality = face_quality.computeQuality(img, bbox);
        }

        // Anti-spoofing
        if (self.config.use_anti_spoofing) {
            if (raw_spoofing) |sp| {
                face.spoofing = anti_spoofing.parseSpoofingScores(sp) catch null;
            } else {
                // Heuristic fallback
                const spoof_detector = anti_spoofing.AntiSpoofing{};
                face.spoofing = spoof_detector.detectHeuristic(img, bbox);
            }
        }

        return face;
    }

    /// Update tracking with detected faces.
    pub fn updateTracking(self: *FaceAnalyzer, detections: []const face_detect.FaceBox) FaceAnalyzerError!void {
        if (self.tracker) |*t| {
            t.update(detections) catch return error.OutOfMemory;
        }
    }

    /// Get active tracked face IDs.
    pub fn getTrackedFaces(self: FaceAnalyzer) FaceAnalyzerError![]face_track.Track {
        if (self.tracker) |t| {
            return t.getActiveTracksOwned() catch return error.OutOfMemory;
        }
        return &[_]face_track.Track{};
    }

    /// Full pipeline: detect → track → analyze each face.
    /// Raw model outputs are provided via the RawOutputs struct.
    pub fn analyze(
        self: *FaceAnalyzer,
        img: image.Image,
        raw_detections: []const face_detect.FaceBox,
        raw_outputs: ?[]const FaceRawOutput,
    ) FaceAnalyzerError![]Face {
        // Step 1: Post-process detections
        const boxes = try self.detectFaces(raw_detections, img.width, img.height);
        defer self.allocator.free(boxes);

        // Step 2: Update tracking
        if (self.config.use_tracking) {
            try self.updateTracking(boxes);
        }

        // Step 3: Analyze each face
        var faces = std.ArrayList(Face).init(self.allocator);
        defer faces.deinit();

        for (boxes, 0..) |bbox, i| {
            // Find matching raw output
            var raw_lm: ?[]const f32 = null;
            var raw_emb: ?[]const f32 = null;
            var raw_gender: ?[2]f32 = null;
            var raw_age: ?f32 = null;
            var raw_race: ?[5]f32 = null;
            var raw_emo: ?[8]f32 = null;
            var raw_fs: ?[5]f32 = null;
            var raw_sp: ?[4]f32 = null;

            if (raw_outputs) |outputs| {
                if (i < outputs.len) {
                    const out = outputs[i];
                    raw_lm = out.landmarks;
                    raw_emb = out.embedding;
                    raw_gender = out.gender_scores;
                    raw_age = out.age;
                    raw_race = out.race_scores;
                    raw_emo = out.emotion_scores;
                    raw_fs = out.face_state_scores;
                    raw_sp = out.spoofing_scores;
                }
            }

            // Find track ID
            var track_id: ?u32 = null;
            if (self.tracker) |t| {
                for (t.tracks.items) |tr| {
                    if (tr.state == .Tracked or tr.state == .New) {
                        if (tr.iou(bbox) > 0.5) {
                            track_id = tr.id;
                            break;
                        }
                    }
                }
            }

            const face = try self.analyzeFace(
                img,
                bbox,
                raw_lm,
                raw_emb,
                raw_gender,
                raw_age,
                raw_race,
                raw_emo,
                raw_fs,
                raw_sp,
                track_id,
            );
            try faces.append(face);
        }

        return faces.toOwnedSlice() catch return error.OutOfMemory;
    }
};

/// Raw model outputs for a single face (all optional).
pub const FaceRawOutput = struct {
    landmarks: ?[]const f32 = null,
    embedding: ?[]const f32 = null,
    gender_scores: ?[2]f32 = null,
    age: ?f32 = null,
    race_scores: ?[5]f32 = null,
    emotion_scores: ?[8]f32 = null,
    face_state_scores: ?[5]f32 = null,
    spoofing_scores: ?[4]f32 = null,
};

// =============================================================================
// Tests
// =============================================================================

test "Face init and deinit" {
    const allocator = std.testing.allocator;
    var face = Face{
        .bbox = .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 },
        .allocator = allocator,
    };
    defer face.deinit();

    try std.testing.expect(face.bbox.confidence == 0.9);
    try std.testing.expect(face.track_id == null);
    try std.testing.expect(face.embedding == null);
}

test "Face with embedding" {
    const allocator = std.testing.allocator;
    const emb = try allocator.alloc(f32, 3);
    emb[0] = 1.0; emb[1] = 0.0; emb[2] = 0.0;

    var face = Face{
        .bbox = .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 },
        .embedding = emb,
        .allocator = allocator,
    };
    defer face.deinit();

    try std.testing.expect(face.embedding != null);
    try std.testing.expect(face.embedding.?.len == 3);
}

test "FaceAnalyzer init and deinit" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    try std.testing.expect(analyzer.config.use_quality);
    try std.testing.expect(analyzer.config.use_anti_spoofing);
}

test "FaceAnalyzer detectFaces post-processes" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    const raw = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 200, .y1 = 200, .x2 = 240, .y2 = 240, .confidence = 0.3 }, // Below threshold
    };

    const boxes = try analyzer.detectFaces(&raw, 300, 300);
    defer allocator.free(boxes);

    try std.testing.expect(boxes.len == 1);
    try std.testing.expect(boxes[0].confidence == 0.9);
}

test "FaceAnalyzer analyzeFace with quality and spoofing" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const bbox = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 40, .confidence = 0.9 };

    var face = try analyzer.analyzeFace(img, bbox, null, null, null, null, null, null, null, null, 1);
    defer face.deinit();

    try std.testing.expect(face.track_id == 1);
    try std.testing.expect(face.quality != null);
    try std.testing.expect(face.spoofing != null);
    try std.testing.expect(face.embedding == null);
    try std.testing.expect(face.landmarks == null);
}

test "FaceAnalyzer analyzeFace with embedding" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const bbox = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 40, .confidence = 0.9 };
    const emb = [_]f32{ 0.5, 0.5, 0.5, 0.5 };

    var face = try analyzer.analyzeFace(img, bbox, null, &emb, null, null, null, null, null, null, null);
    defer face.deinit();

    try std.testing.expect(face.embedding != null);
    try std.testing.expect(face.embedding.?.len == 4);
    // Should be L2 normalized
    var norm: f32 = 0;
    for (face.embedding.?) |v| norm += v * v;
    try std.testing.expectApproxEqAbs(@sqrt(norm), 1.0, 0.01);
}

test "FaceAnalyzer analyzeFace with attributes" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const bbox = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 40, .confidence = 0.9 };

    var face = try analyzer.analyzeFace(
        img, bbox, null, null,
        .{ 0.8, 0.2 }, // Gender: male
        30.0, // Age
        .{ 0.1, 0.1, 0.7, 0.05, 0.05 }, // Race: Asian
        .{ 0.1, 0.8, 0.02, 0.02, 0.02, 0.01, 0.01, 0.02 }, // Emotion: happy
        .{ 0.9, 0.1, 0.05, 0.02, 0.3 }, // Face state
        .{ 0.85, 0.05, 0.05, 0.05 }, // Spoofing: real
        null,
    );
    defer face.deinit();

    try std.testing.expect(face.demography != null);
    try std.testing.expect(face.demography.?.gender == .Male);
    try std.testing.expect(face.emotion != null);
    try std.testing.expect(face.emotion.?.label == .Happy);
    try std.testing.expect(face.spoofing != null);
    try std.testing.expect(face.spoofing.?.is_real);
}

test "FaceAnalyzer analyzeFace with landmarks and headpose" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{ .landmark_model = .PIPNet98 });
    defer analyzer.deinit();

    var img = try image.Image.init(allocator, 100, 100, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const bbox = face_detect.FaceBox{ .x1 = 20, .y1 = 20, .x2 = 80, .y2 = 80, .confidence = 0.9 };

    // 98 landmarks (196 floats) with varied positions for head pose estimation
    // Points 60-67 (left eye), 68-76 (right eye), 86 (nose), 88 (left mouth), 92 (right mouth)
    var raw_lm: [196]f32 = undefined;
    for (0..98) |i| {
        raw_lm[i * 2] = 0.5; // Default: center
        raw_lm[i * 2 + 1] = 0.5;
    }
    // Set key points for 5-point extraction
    // Left eye (60-67): x=0.3, y=0.4
    for (60..68) |i| { raw_lm[i * 2] = 0.3; raw_lm[i * 2 + 1] = 0.4; }
    // Right eye (68-76): x=0.7, y=0.4
    for (68..77) |i| { raw_lm[i * 2] = 0.7; raw_lm[i * 2 + 1] = 0.4; }
    // Nose (86): x=0.5, y=0.6
    raw_lm[86 * 2] = 0.5; raw_lm[86 * 2 + 1] = 0.6;
    // Left mouth (88): x=0.35, y=0.8
    raw_lm[88 * 2] = 0.35; raw_lm[88 * 2 + 1] = 0.8;
    // Right mouth (92): x=0.65, y=0.8
    raw_lm[92 * 2] = 0.65; raw_lm[92 * 2 + 1] = 0.8;

    var face = try analyzer.analyzeFace(img, bbox, &raw_lm, null, null, null, null, null, null, null, null);
    defer face.deinit();

    try std.testing.expect(face.landmark_result != null);
    try std.testing.expect(face.landmark_result.?.points_2d != null);
    try std.testing.expect(face.landmark_result.?.points_2d.?.len == 98);
    try std.testing.expect(face.landmarks != null);
    try std.testing.expect(face.head_pose != null);
}

test "FaceAnalyzer updateTracking" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{ .use_tracking = true });
    defer analyzer.deinit();

    const dets = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };

    try analyzer.updateTracking(&dets);
    try std.testing.expect(analyzer.tracker != null);
    try std.testing.expect(analyzer.tracker.?.totalTrackCount() == 1);
}

test "FaceAnalyzer full pipeline analyze" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{ .use_tracking = true });
    defer analyzer.deinit();

    var img = try image.Image.init(allocator, 100, 100, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const raw_dets = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };

    const faces = try analyzer.analyze(img, &raw_dets, null);
    defer {
        for (faces) |*f| {
            var ff = f.*;
            ff.deinit();
        }
        allocator.free(faces);
    }

    try std.testing.expect(faces.len >= 1);
    try std.testing.expect(faces[0].quality != null);
    try std.testing.expect(faces[0].spoofing != null);
}

test "FaceAnalyzer graceful degradation without models" {
    const allocator = std.testing.allocator;
    var analyzer = FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    var img = try image.Image.init(allocator, 50, 50, 3);
    defer img.deinit();
    @memset(img.data, 128);

    const bbox = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 40, .y2 = 40, .confidence = 0.9 };

    // No raw outputs at all — should still produce quality and heuristic spoofing
    var face = try analyzer.analyzeFace(img, bbox, null, null, null, null, null, null, null, null, null);
    defer face.deinit();

    try std.testing.expect(face.quality != null);
    try std.testing.expect(face.spoofing != null);
    try std.testing.expect(face.embedding == null);
    try std.testing.expect(face.demography == null);
    try std.testing.expect(face.emotion == null);
}

test "FaceAnalyzerConfig defaults" {
    const config = FaceAnalyzerConfig{};
    try std.testing.expect(config.use_gaze);
    try std.testing.expect(config.use_headpose);
    try std.testing.expect(config.use_attributes);
    try std.testing.expect(config.use_quality);
    try std.testing.expect(config.use_anti_spoofing);
    try std.testing.expect(config.use_tracking);
    try std.testing.expect(!config.use_parsing);
}

test "FaceRawOutput all optional fields default to null" {
    const output = FaceRawOutput{};
    try std.testing.expect(output.landmarks == null);
    try std.testing.expect(output.embedding == null);
    try std.testing.expect(output.gender_scores == null);
    try std.testing.expect(output.age == null);
    try std.testing.expect(output.race_scores == null);
    try std.testing.expect(output.emotion_scores == null);
    try std.testing.expect(output.face_state_scores == null);
    try std.testing.expect(output.spoofing_scores == null);
}
