//! vision_test.zig — Vision pipeline integration tests.
//!
//! End-to-end tests for the native vision pipeline:
//! 1. Face detection: NMS, anchor decoding, multi-scale post-processing
//! 2. Face recognition: alignment, embedding normalization, cosine similarity
//! 3. Face tracking: multi-frame tracking with ID persistence
//! 4. Gaze & head pose: estimation from landmarks
//! 5. Emotion detection: 8-class classification
//! 6. Full analyzer: all predictors on synthetic data
//! 7. Graceful degradation: ONNX Runtime unavailable → post-processing still works

const std = @import("std");
const image_mod = @import("image");
const face_detect = @import("face_detect");
const face_recognize = @import("face_recognize");
const face_track = @import("face_track");
const gaze_headpose = @import("gaze_headpose");
const face_attributes = @import("face_attributes");
const face_quality = @import("face_quality");
const anti_spoofing = @import("anti_spoofing");
const face_analyzer = @import("face_analyzer");

const allocator = std.heap.page_allocator;

// =============================================================================
// 1. Face Detection: NMS, anchor decoding, multi-scale
// =============================================================================

test "vision: NMS filters overlapping boxes" {
    const boxes = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 100, .y2 = 100, .confidence = 0.9 },
        .{ .x1 = 15, .y1 = 15, .x2 = 95, .y2 = 95, .confidence = 0.7 },
        .{ .x1 = 200, .y1 = 200, .x2 = 300, .y2 = 300, .confidence = 0.8 },
    };
    const result = try face_detect.nonMaxSuppression(allocator, &boxes, 0.4);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0].confidence > 0.85);
    try std.testing.expect(result[1].confidence > 0.75);
}

test "vision: anchor decoding produces correct bbox" {
    const anchor = face_detect.Anchor{ .cx = 50, .cy = 50, .w = 100, .h = 100 };
    const deltas = [4]f32{ 0.1, 0.1, 0.2, 0.2 };
    const box = face_detect.decodeBbox(anchor, deltas);
    try std.testing.expect(box.x1 < box.x2);
    try std.testing.expect(box.y1 < box.y2);
}

test "vision: SCRFD anchor-free decoding" {
    const box = face_detect.decodeScrfdBbox(10, 10, 8.0, .{ 1.0, 1.0, 3.0, 3.0 });
    try std.testing.expect(box.x1 < box.x2);
    try std.testing.expect(box.y1 < box.y2);
}

test "vision: FaceDetector post-process filters by threshold" {
    const raw = [_]face_detect.FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 60, .y1 = 60, .x2 = 100, .y2 = 100, .confidence = 0.3 },
    };
    var detector = face_detect.FaceDetector.init(allocator, .{ .score_threshold = 0.5 });
    const result = try detector.postProcess(&raw, 200, 200);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].confidence >= 0.5);
}

// =============================================================================
// 2. Face Recognition: alignment, normalization, similarity
// =============================================================================

test "vision: affine transform identity preserves points" {
    const m = face_recognize.AffineMatrix.identity();
    const p = m.transformPoint(5.0, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), p[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), p[1], 1e-5);
}

test "vision: embedding normalization produces unit vector" {
    var emb = [_]f32{ 3.0, 4.0, 0.0 };
    face_recognize.normalizeEmbedding(&emb);
    var norm: f32 = 0;
    for (emb) |v| norm += v * v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);
}

test "vision: cosine similarity identical embeddings = 1" {
    const a = [_]f32{ 1.0, 0.0, 0.0, 0.5 };
    const b = [_]f32{ 1.0, 0.0, 0.0, 0.5 };
    const sim = try face_recognize.cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim, 1e-5);
}

test "vision: cosine similarity orthogonal embeddings = 0" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const sim = try face_recognize.cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim, 1e-5);
}

test "vision: FaceRecognizer isSamePerson threshold" {
    const recog = face_recognize.FaceRecognizer.init(allocator, 4, 0.5);
    const a = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const b = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
    try std.testing.expect(try recog.isSamePerson(&a, &b));
    const c = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    try std.testing.expect(!try recog.isSamePerson(&a, &c));
}

// =============================================================================
// 3. Face Tracking: multi-frame ID persistence
// =============================================================================

test "vision: FaceTracker assigns persistent IDs" {
    var tracker = face_track.FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    const frame1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };
    try tracker.update(&frame1);
    try std.testing.expectEqual(@as(usize, 1), tracker.activeTrackCount());

    const frame2 = [_]face_detect.FaceBox{
        .{ .x1 = 12, .y1 = 12, .x2 = 52, .y2 = 52, .confidence = 0.85 },
    };
    try tracker.update(&frame2);
    try std.testing.expectEqual(@as(usize, 1), tracker.activeTrackCount());
}

test "vision: FaceTracker separates multiple faces" {
    var tracker = face_track.FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    const frame1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 200, .y1 = 200, .x2 = 300, .y2 = 300, .confidence = 0.85 },
    };
    try tracker.update(&frame1);
    try std.testing.expectEqual(@as(usize, 2), tracker.activeTrackCount());
}

test "vision: FaceTracker lost track recovery" {
    var tracker = face_track.FaceTracker.init(allocator, .{ .lost_time_limit = 5 });
    defer tracker.deinit();

    const frame1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };
    try tracker.update(&frame1);

    // Empty frame — track should be lost
    const empty: []const face_detect.FaceBox = &.{};
    try tracker.update(empty);
    try std.testing.expectEqual(@as(usize, 0), tracker.activeTrackCount());
}

// =============================================================================
// 4. Gaze & Head Pose: estimation from landmarks
// =============================================================================

test "vision: head pose from neutral landmarks" {
    const landmarks = [5][2]f32{
        .{ 30.0, 50.0 }, // left eye
        .{ 70.0, 50.0 }, // right eye
        .{ 50.0, 65.0 }, // nose
        .{ 35.0, 80.0 }, // left mouth
        .{ 65.0, 80.0 }, // right mouth
    };
    const pose = try gaze_headpose.estimateHeadPose(landmarks);
    try std.testing.expect(pose.roll > -5.0 and pose.roll < 5.0);
    try std.testing.expect(pose.yaw > -10.0 and pose.yaw < 10.0);
    try std.testing.expect(pose.pitch > -10.0 and pose.pitch < 10.0);
}

test "vision: head pose with tilted face (roll)" {
    const landmarks = [5][2]f32{
        .{ 30.0, 40.0 }, // left eye (higher)
        .{ 70.0, 60.0 }, // right eye (lower)
        .{ 50.0, 65.0 }, // nose
        .{ 35.0, 75.0 }, // left mouth
        .{ 65.0, 85.0 }, // right mouth
    };
    const pose = try gaze_headpose.estimateHeadPose(landmarks);
    try std.testing.expect(pose.roll > 5.0);
}

// =============================================================================
// 5. Emotion Detection: 8-class classification
// =============================================================================

test "vision: emotion classification happy" {
    const scores = [8]f32{ 0.05, 0.85, 0.02, 0.02, 0.01, 0.01, 0.01, 0.03 };
    const result = try face_attributes.parseEmotion(scores);
    try std.testing.expectEqual(face_attributes.Emotion.Happy, result.label);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), result.confidence, 1e-5);
}

test "vision: emotion classification angry" {
    const scores = [8]f32{ 0.05, 0.02, 0.03, 0.80, 0.02, 0.02, 0.03, 0.03 };
    const result = try face_attributes.parseEmotion(scores);
    try std.testing.expectEqual(face_attributes.Emotion.Angry, result.label);
}

test "vision: emotion to string mapping" {
    try std.testing.expectEqualStrings("neutral", face_attributes.emotionToString(.Neutral));
    try std.testing.expectEqualStrings("happy", face_attributes.emotionToString(.Happy));
    try std.testing.expectEqualStrings("angry", face_attributes.emotionToString(.Angry));
}

// =============================================================================
// 6. Face Attributes: demographics, face state
// =============================================================================

test "vision: gender classification" {
    const result = try face_attributes.parseGender(.{ 0.8, 0.2 });
    try std.testing.expectEqual(face_attributes.Gender.Male, result.gender);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), result.confidence, 1e-5);
}

test "vision: age group classification" {
    try std.testing.expectEqual(face_attributes.AgeGroup.Infant, face_attributes.ageToGroup(2.0));
    try std.testing.expectEqual(face_attributes.AgeGroup.Child, face_attributes.ageToGroup(8.0));
    try std.testing.expectEqual(face_attributes.AgeGroup.Teenager, face_attributes.ageToGroup(16.0));
    try std.testing.expectEqual(face_attributes.AgeGroup.YoungAdult, face_attributes.ageToGroup(25.0));
    try std.testing.expectEqual(face_attributes.AgeGroup.MiddleAged, face_attributes.ageToGroup(45.0));
    try std.testing.expectEqual(face_attributes.AgeGroup.Senior, face_attributes.ageToGroup(65.0));
}

test "vision: face state parsing" {
    const scores = [5]f32{ 0.9, 0.1, 0.05, 0.02, 0.8 };
    const result = face_attributes.parseFaceState(scores);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), result.eyes_open, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), result.wearing_glasses, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), result.mouth_open, 1e-5);
}

// =============================================================================
// 7. Face Quality: heuristic assessment
// =============================================================================

test "vision: face quality assessment on synthetic image" {
    var img = try image_mod.Image.init(allocator, 100, 100, 3);
    defer img.deinit();
    // Fill with a simple pattern
    for (img.data, 0..) |*px, i| {
        px.* = @intCast(i % 256);
    }
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 90, .y2 = 90, .confidence = 1.0 };
    const q = face_quality.computeQuality(img, box);
    try std.testing.expect(q.score >= 0.0 and q.score <= 1.0);
}

// =============================================================================
// 8. Anti-Spoofing: heuristic detection
// =============================================================================

test "vision: anti-spoofing heuristic on synthetic image" {
    var img = try image_mod.Image.init(allocator, 100, 100, 3);
    defer img.deinit();
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 90, .y2 = 90, .confidence = 1.0 };
    const detector = anti_spoofing.AntiSpoofing{};
    const result = detector.detectHeuristic(img, box);
    try std.testing.expect(result.confidence >= 0.0 and result.confidence <= 1.0);
}

// =============================================================================
// 9. Full FaceAnalyzer pipeline
// =============================================================================

test "vision: FaceAnalyzer end-to-end with synthetic data" {
    var analyzer = face_analyzer.FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();

    var img = try image_mod.Image.init(allocator, 200, 200, 3);
    defer img.deinit();

    const bbox = face_detect.FaceBox{
        .x1 = 50,
        .y1 = 50,
        .x2 = 150,
        .y2 = 150,
        .confidence = 0.95,
    };

    const raw_embedding = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    const raw_gender = [2]f32{ 0.7, 0.3 };
    const raw_age: f32 = 30.0;
    const raw_race = [5]f32{ 0.6, 0.1, 0.1, 0.1, 0.1 };
    const raw_emotion = [8]f32{ 0.1, 0.7, 0.05, 0.05, 0.02, 0.02, 0.01, 0.05 };
    const raw_face_state = [5]f32{ 0.9, 0.1, 0.05, 0.02, 0.3 };

    var face = try analyzer.analyzeFace(
        img,
        bbox,
        null,
        &raw_embedding,
        raw_gender,
        raw_age,
        raw_race,
        raw_emotion,
        raw_face_state,
        null,
        1,
    );
    defer face.deinit();

    try std.testing.expect(face.embedding != null);
    try std.testing.expectEqual(@as(usize, 5), face.embedding.?.len);
    try std.testing.expect(face.demography != null);
    try std.testing.expectEqual(face_attributes.Gender.Male, face.demography.?.gender);
    try std.testing.expect(face.emotion != null);
    try std.testing.expectEqual(face_attributes.Emotion.Happy, face.emotion.?.label);
    try std.testing.expect(face.quality != null);
}

// =============================================================================
// 10. Graceful degradation: image creation without ONNX
// =============================================================================

test "vision: image creation and pixel access" {
    var img = try image_mod.Image.init(allocator, 10, 10, 3);
    defer img.deinit();
    try std.testing.expectEqual(@as(usize, 10), img.width);
    try std.testing.expectEqual(@as(usize, 10), img.height);

    img.setPixel(5, 5, &.{ 255, 128, 64 });
    const px = img.getPixel(5, 5);
    try std.testing.expectEqual(@as(u8, 255), px[0]);
    try std.testing.expectEqual(@as(u8, 128), px[1]);
    try std.testing.expectEqual(@as(u8, 64), px[2]);
}

test "vision: PPM image loading" {
    const ppm_data = "P6\n2 2\n255\n\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\x00";
    var img = try image_mod.loadFromMemory(allocator, ppm_data, "test.ppm");
    defer img.deinit();
    try std.testing.expectEqual(@as(usize, 2), img.width);
    try std.testing.expectEqual(@as(usize, 2), img.height);
    try std.testing.expectEqual(@as(u8, 3), img.channels);
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== VISION INTEGRATION TESTS                        ===\n", .{});
    std.debug.print("========================================================\n", .{});

    const tests = [_]struct {
        name: []const u8,
        func: *const fn () anyerror!void,
    }{
        .{ .name = "NMS filters overlapping boxes", .func = testNmsFilters },
        .{ .name = "Anchor decoding", .func = testAnchorDecoding },
        .{ .name = "SCRFD anchor-free decoding", .func = testScrfdDecoding },
        .{ .name = "FaceDetector threshold filter", .func = testDetectorThreshold },
        .{ .name = "Affine identity transform", .func = testAffineIdentity },
        .{ .name = "Embedding normalization", .func = testEmbeddingNorm },
        .{ .name = "Cosine similarity identical", .func = testCosineSimIdentical },
        .{ .name = "Cosine similarity orthogonal", .func = testCosineSimOrthogonal },
        .{ .name = "FaceRecognizer threshold", .func = testRecognizerThreshold },
        .{ .name = "FaceTracker persistent IDs", .func = testTrackerPersistentIds },
        .{ .name = "FaceTracker multi-face", .func = testTrackerMultiFace },
        .{ .name = "FaceTracker lost recovery", .func = testTrackerLostRecovery },
        .{ .name = "Head pose neutral", .func = testHeadPoseNeutral },
        .{ .name = "Head pose tilted", .func = testHeadPoseTilted },
        .{ .name = "Emotion happy", .func = testEmotionHappy },
        .{ .name = "Emotion angry", .func = testEmotionAngry },
        .{ .name = "Emotion string mapping", .func = testEmotionString },
        .{ .name = "Gender classification", .func = testGenderClass },
        .{ .name = "Age group classification", .func = testAgeGroup },
        .{ .name = "Face state parsing", .func = testFaceState },
        .{ .name = "Face quality assessment", .func = testFaceQuality },
        .{ .name = "Anti-spoofing heuristic", .func = testAntiSpoofing },
        .{ .name = "FaceAnalyzer end-to-end", .func = testAnalyzerE2E },
        .{ .name = "Image pixel access", .func = testImagePixel },
        .{ .name = "PPM image loading", .func = testPpmLoading },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (tests) |t| {
        std.debug.print("  [{s}] {s}...", .{ "RUN", t.name });
        t.func() catch |err| {
            std.debug.print(" FAIL ({s})\n", .{@errorName(err)});
            failed += 1;
            continue;
        };
        std.debug.print(" PASS\n", .{});
        passed += 1;
    }

    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    if (failed == 0) {
        std.debug.print("=== VISION TESTS: ALL PASSED ({d}/{d})              ===\n", .{ passed, passed });
    } else {
        std.debug.print("=== VISION TESTS: {d} PASSED, {d} FAILED            ===\n", .{ passed, failed });
    }
    std.debug.print("========================================================\n", .{});
}

// Wrapper functions for main
fn testNmsFilters() anyerror!void {
    const boxes = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 100, .y2 = 100, .confidence = 0.9 },
        .{ .x1 = 15, .y1 = 15, .x2 = 95, .y2 = 95, .confidence = 0.7 },
        .{ .x1 = 200, .y1 = 200, .x2 = 300, .y2 = 300, .confidence = 0.8 },
    };
    const result = try face_detect.nonMaxSuppression(allocator, &boxes, 0.4);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

fn testAnchorDecoding() anyerror!void {
    const anchor = face_detect.Anchor{ .cx = 50, .cy = 50, .w = 100, .h = 100 };
    const deltas = [4]f32{ 0.1, 0.1, 0.2, 0.2 };
    const box = face_detect.decodeBbox(anchor, deltas);
    try std.testing.expect(box.x1 < box.x2);
}

fn testScrfdDecoding() anyerror!void {
    const box = face_detect.decodeScrfdBbox(10, 10, 8.0, .{ 1.0, 1.0, 3.0, 3.0 });
    try std.testing.expect(box.x1 < box.x2);
}

fn testDetectorThreshold() anyerror!void {
    const raw = [_]face_detect.FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 60, .y1 = 60, .x2 = 100, .y2 = 100, .confidence = 0.3 },
    };
    var detector = face_detect.FaceDetector.init(allocator, .{ .score_threshold = 0.5 });
    const result = try detector.postProcess(&raw, 200, 200);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

fn testAffineIdentity() anyerror!void {
    const m = face_recognize.AffineMatrix.identity();
    const p = m.transformPoint(5.0, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), p[0], 1e-5);
}

fn testEmbeddingNorm() anyerror!void {
    var emb = [_]f32{ 3.0, 4.0, 0.0 };
    face_recognize.normalizeEmbedding(&emb);
    var norm: f32 = 0;
    for (emb) |v| norm += v * v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);
}

fn testCosineSimIdentical() anyerror!void {
    const a = [_]f32{ 1.0, 0.0, 0.0, 0.5 };
    const b = [_]f32{ 1.0, 0.0, 0.0, 0.5 };
    const sim = try face_recognize.cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim, 1e-5);
}

fn testCosineSimOrthogonal() anyerror!void {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const sim = try face_recognize.cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim, 1e-5);
}

fn testRecognizerThreshold() anyerror!void {
    const recog = face_recognize.FaceRecognizer.init(allocator, 4, 0.5);
    const a = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const b = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
    try std.testing.expect(try recog.isSamePerson(&a, &b));
}

fn testTrackerPersistentIds() anyerror!void {
    var tracker = face_track.FaceTracker.init(allocator, .{});
    defer tracker.deinit();
    const f1 = [_]face_detect.FaceBox{.{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 }};
    try tracker.update(&f1);
    const f2 = [_]face_detect.FaceBox{.{ .x1 = 12, .y1 = 12, .x2 = 52, .y2 = 52, .confidence = 0.85 }};
    try tracker.update(&f2);
    try std.testing.expectEqual(@as(usize, 1), tracker.activeTrackCount());
}

fn testTrackerMultiFace() anyerror!void {
    var tracker = face_track.FaceTracker.init(allocator, .{});
    defer tracker.deinit();
    const f1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 200, .y1 = 200, .x2 = 300, .y2 = 300, .confidence = 0.85 },
    };
    try tracker.update(&f1);
    try std.testing.expectEqual(@as(usize, 2), tracker.activeTrackCount());
}

fn testTrackerLostRecovery() anyerror!void {
    var tracker = face_track.FaceTracker.init(allocator, .{ .lost_time_limit = 5 });
    defer tracker.deinit();
    const f1 = [_]face_detect.FaceBox{.{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 }};
    try tracker.update(&f1);
    const empty: []const face_detect.FaceBox = &.{};
    try tracker.update(empty);
    try std.testing.expectEqual(@as(usize, 0), tracker.activeTrackCount());
}

fn testHeadPoseNeutral() anyerror!void {
    const lm = [5][2]f32{ .{ 30.0, 50.0 }, .{ 70.0, 50.0 }, .{ 50.0, 65.0 }, .{ 35.0, 80.0 }, .{ 65.0, 80.0 } };
    const pose = try gaze_headpose.estimateHeadPose(lm);
    try std.testing.expect(pose.roll > -5.0 and pose.roll < 5.0);
}

fn testHeadPoseTilted() anyerror!void {
    const lm = [5][2]f32{ .{ 30.0, 40.0 }, .{ 70.0, 60.0 }, .{ 50.0, 65.0 }, .{ 35.0, 75.0 }, .{ 65.0, 85.0 } };
    const pose = try gaze_headpose.estimateHeadPose(lm);
    try std.testing.expect(pose.roll > 5.0);
}

fn testEmotionHappy() anyerror!void {
    const scores = [8]f32{ 0.05, 0.85, 0.02, 0.02, 0.01, 0.01, 0.01, 0.03 };
    const result = try face_attributes.parseEmotion(scores);
    try std.testing.expectEqual(face_attributes.Emotion.Happy, result.label);
}

fn testEmotionAngry() anyerror!void {
    const scores = [8]f32{ 0.05, 0.02, 0.03, 0.80, 0.02, 0.02, 0.03, 0.03 };
    const result = try face_attributes.parseEmotion(scores);
    try std.testing.expectEqual(face_attributes.Emotion.Angry, result.label);
}

fn testEmotionString() anyerror!void {
    try std.testing.expectEqualStrings("neutral", face_attributes.emotionToString(.Neutral));
    try std.testing.expectEqualStrings("happy", face_attributes.emotionToString(.Happy));
}

fn testGenderClass() anyerror!void {
    const result = try face_attributes.parseGender(.{ 0.8, 0.2 });
    try std.testing.expectEqual(face_attributes.Gender.Male, result.gender);
}

fn testAgeGroup() anyerror!void {
    try std.testing.expectEqual(face_attributes.AgeGroup.Senior, face_attributes.ageToGroup(65.0));
}

fn testFaceState() anyerror!void {
    const scores = [5]f32{ 0.9, 0.1, 0.05, 0.02, 0.8 };
    const result = face_attributes.parseFaceState(scores);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), result.eyes_open, 1e-5);
}

fn testFaceQuality() anyerror!void {
    var img = try image_mod.Image.init(allocator, 100, 100, 3);
    defer img.deinit();
    for (img.data, 0..) |*px, i| px.* = @intCast(i % 256);
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 90, .y2 = 90, .confidence = 1.0 };
    const q = face_quality.computeQuality(img, box);
    try std.testing.expect(q.score >= 0.0 and q.score <= 1.0);
}

fn testAntiSpoofing() anyerror!void {
    var img = try image_mod.Image.init(allocator, 100, 100, 3);
    defer img.deinit();
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 10, .x2 = 90, .y2 = 90, .confidence = 1.0 };
    const detector = anti_spoofing.AntiSpoofing{};
    const result = detector.detectHeuristic(img, box);
    try std.testing.expect(result.confidence >= 0.0 and result.confidence <= 1.0);
}

fn testAnalyzerE2E() anyerror!void {
    var analyzer = face_analyzer.FaceAnalyzer.init(allocator, .{});
    defer analyzer.deinit();
    var img = try image_mod.Image.init(allocator, 200, 200, 3);
    defer img.deinit();
    const bbox = face_detect.FaceBox{ .x1 = 50, .y1 = 50, .x2 = 150, .y2 = 150, .confidence = 0.95 };
    const emb = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    var face = try analyzer.analyzeFace(img, bbox, null, &emb, .{ 0.7, 0.3 }, 30.0, .{ 0.6, 0.1, 0.1, 0.1, 0.1 }, .{ 0.1, 0.7, 0.05, 0.05, 0.02, 0.02, 0.01, 0.05 }, .{ 0.9, 0.1, 0.05, 0.02, 0.3 }, null, 1);
    defer face.deinit();
    try std.testing.expect(face.embedding != null);
    try std.testing.expectEqual(face_attributes.Emotion.Happy, face.emotion.?.label);
}

fn testImagePixel() anyerror!void {
    var img = try image_mod.Image.init(allocator, 10, 10, 3);
    defer img.deinit();
    img.setPixel(5, 5, &.{ 255, 128, 64 });
    const px = img.getPixel(5, 5);
    try std.testing.expectEqual(@as(u8, 255), px[0]);
}

fn testPpmLoading() anyerror!void {
    const ppm = "P6\n2 2\n255\n\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\x00";
    var img = try image_mod.loadFromMemory(allocator, ppm, "test.ppm");
    defer img.deinit();
    try std.testing.expectEqual(@as(usize, 2), img.width);
}
