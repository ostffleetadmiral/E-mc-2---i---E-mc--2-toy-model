//! face_attributes.zig — Face attribute prediction: demographics, emotion, face state.
//!
//! Provides classification post-processing for age, gender, race, emotion,
//! and face state (eye/glasses/mask) from model outputs. All post-processing
//! is pure Zig — model inference is delegated to onnx_runtime.zig.

const std = @import("std");

// =============================================================================
// Types
// =============================================================================

pub const Gender = enum { Male, Female };

pub const AgeGroup = enum {
    Infant, // 0-3
    Child, // 4-12
    Teenager, // 13-19
    YoungAdult, // 20-35
    MiddleAged, // 36-55
    Senior, // 56+
};

pub const Race = enum {
    White,
    Black,
    Asian,
    Indian,
    Other,
};

pub const Emotion = enum {
    Neutral,
    Happy,
    Sad,
    Angry,
    Surprised,
    Fearful,
    Disgusted,
    Contemptuous,
};

pub const DemographyResult = struct {
    gender: Gender,
    gender_confidence: f32,
    age: f32,
    age_group: AgeGroup,
    race: Race,
    race_confidence: f32,
};

pub const EmotionResult = struct {
    label: Emotion,
    confidence: f32,
    all_scores: [8]f32, // Scores for all 8 emotion classes
};

pub const FaceStateResult = struct {
    eyes_open: f32, // Probability [0,1]
    wearing_glasses: f32, // Probability [0,1]
    wearing_sunglasses: f32, // Probability [0,1]
    wearing_mask: f32, // Probability [0,1]
    mouth_open: f32, // Probability [0,1]
};

pub const AttributeError = error{
    InvalidInput,
    InvalidScores,
};

// =============================================================================
// Demographics post-processing
// =============================================================================

/// Determine age group from a numeric age value.
pub fn ageToGroup(age: f32) AgeGroup {
    if (age < 4.0) return .Infant;
    if (age < 13.0) return .Child;
    if (age < 20.0) return .Teenager;
    if (age < 36.0) return .YoungAdult;
    if (age < 56.0) return .MiddleAged;
    return .Senior;
}

/// Parse gender from model output (2-class softmax).
/// scores: [male_prob, female_prob]
pub fn parseGender(scores: [2]f32) AttributeError!struct { gender: Gender, confidence: f32 } {
    if (scores[0] < 0.0 or scores[1] < 0.0) return error.InvalidScores;
    if (scores[0] >= scores[1]) {
        return .{ .gender = .Male, .confidence = scores[0] };
    }
    return .{ .gender = .Female, .confidence = scores[1] };
}

/// Parse age from model output (regression value or age bucket index).
/// If age_buckets is provided, maps the index to the bucket center.
pub fn parseAge(raw_age: f32, age_buckets: ?[]const f32) f32 {
    if (age_buckets) |buckets| {
        const idx = @as(usize, @intFromFloat(@max(0.0, raw_age)));
        if (idx < buckets.len) return buckets[idx];
        return buckets[buckets.len - 1];
    }
    return std.math.clamp(raw_age, 0.0, 100.0);
}

/// Parse race from model output (5-class softmax).
/// scores: [white, black, asian, indian, other]
pub fn parseRace(scores: [5]f32) AttributeError!struct { race: Race, confidence: f32 } {
    var max_idx: usize = 0;
    var max_val: f32 = scores[0];
    for (scores[1..], 1..) |s, i| {
        if (s > max_val) {
            max_val = s;
            max_idx = i;
        }
    }
    const races = [_]Race{ .White, .Black, .Asian, .Indian, .Other };
    return .{ .race = races[max_idx], .confidence = max_val };
}

/// Full demography prediction from model outputs.
pub fn predictDemography(
    gender_scores: [2]f32,
    age_raw: f32,
    age_buckets: ?[]const f32,
    race_scores: [5]f32,
) AttributeError!DemographyResult {
    const g = try parseGender(gender_scores);
    const age = parseAge(age_raw, age_buckets);
    const r = try parseRace(race_scores);

    return .{
        .gender = g.gender,
        .gender_confidence = g.confidence,
        .age = age,
        .age_group = ageToGroup(age),
        .race = r.race,
        .race_confidence = r.confidence,
    };
}

// =============================================================================
// Emotion post-processing
// =============================================================================

/// Parse emotion from model output (8-class softmax).
/// scores: [neutral, happy, sad, angry, surprised, fearful, disgusted, contemptuous]
pub fn parseEmotion(scores: [8]f32) AttributeError!EmotionResult {
    var max_idx: usize = 0;
    var max_val: f32 = scores[0];
    for (scores[1..], 1..) |s, i| {
        if (s > max_val) {
            max_val = s;
            max_idx = i;
        }
    }
    const emotions = [_]Emotion{
        .Neutral, .Happy, .Sad, .Angry,
        .Surprised, .Fearful, .Disgusted, .Contemptuous,
    };
    return .{
        .label = emotions[max_idx],
        .confidence = max_val,
        .all_scores = scores,
    };
}

/// Get emotion label as string.
pub fn emotionToString(e: Emotion) []const u8 {
    return switch (e) {
        .Neutral => "neutral",
        .Happy => "happy",
        .Sad => "sad",
        .Angry => "angry",
        .Surprised => "surprised",
        .Fearful => "fearful",
        .Disgusted => "disgusted",
        .Contemptuous => "contemptuous",
    };
}

// =============================================================================
// Face state post-processing
// =============================================================================

/// Parse face state from model output (5 binary probabilities).
/// Each value is a sigmoid output in [0, 1].
pub fn parseFaceState(scores: [5]f32) FaceStateResult {
    return .{
        .eyes_open = std.math.clamp(scores[0], 0.0, 1.0),
        .wearing_glasses = std.math.clamp(scores[1], 0.0, 1.0),
        .wearing_sunglasses = std.math.clamp(scores[2], 0.0, 1.0),
        .wearing_mask = std.math.clamp(scores[3], 0.0, 1.0),
        .mouth_open = std.math.clamp(scores[4], 0.0, 1.0),
    };
}

// =============================================================================
// High-level predictor
// =============================================================================

pub const AttributePredictor = struct {
    age_buckets: ?[]const f32 = null,

    pub fn predictDemographyFromModel(self: AttributePredictor, gender_scores: [2]f32, age_raw: f32, race_scores: [5]f32) AttributeError!DemographyResult {
        return predictDemography(gender_scores, age_raw, self.age_buckets, race_scores);
    }

    pub fn predictEmotion(self: AttributePredictor, scores: [8]f32) AttributeError!EmotionResult {
        _ = self;
        return parseEmotion(scores);
    }

    pub fn predictFaceState(self: AttributePredictor, scores: [5]f32) FaceStateResult {
        _ = self;
        return parseFaceState(scores);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ageToGroup classifies correctly" {
    try std.testing.expect(ageToGroup(2.0) == .Infant);
    try std.testing.expect(ageToGroup(8.0) == .Child);
    try std.testing.expect(ageToGroup(16.0) == .Teenager);
    try std.testing.expect(ageToGroup(25.0) == .YoungAdult);
    try std.testing.expect(ageToGroup(45.0) == .MiddleAged);
    try std.testing.expect(ageToGroup(70.0) == .Senior);
}

test "parseGender male" {
    const result = try parseGender(.{ 0.8, 0.2 });
    try std.testing.expect(result.gender == .Male);
    try std.testing.expectApproxEqAbs(result.confidence, 0.8, 0.001);
}

test "parseGender female" {
    const result = try parseGender(.{ 0.3, 0.7 });
    try std.testing.expect(result.gender == .Female);
    try std.testing.expectApproxEqAbs(result.confidence, 0.7, 0.001);
}

test "parseAge without buckets clamps to [0,100]" {
    try std.testing.expectApproxEqAbs(parseAge(25.5, null), 25.5, 0.001);
    try std.testing.expectApproxEqAbs(parseAge(-5.0, null), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(parseAge(150.0, null), 100.0, 0.001);
}

test "parseAge with buckets" {
    const buckets = [_]f32{ 2.0, 8.0, 16.0, 28.0, 45.0, 65.0 };
    try std.testing.expectApproxEqAbs(parseAge(0.0, &buckets), 2.0, 0.001);
    try std.testing.expectApproxEqAbs(parseAge(3.0, &buckets), 28.0, 0.001);
    try std.testing.expectApproxEqAbs(parseAge(10.0, &buckets), 65.0, 0.001);
}

test "parseRace identifies asian" {
    const scores = [5]f32{ 0.1, 0.05, 0.7, 0.1, 0.05 };
    const result = try parseRace(scores);
    try std.testing.expect(result.race == .Asian);
    try std.testing.expectApproxEqAbs(result.confidence, 0.7, 0.001);
}

test "parseRace identifies white" {
    const scores = [5]f32{ 0.6, 0.1, 0.1, 0.1, 0.1 };
    const result = try parseRace(scores);
    try std.testing.expect(result.race == .White);
}

test "predictDemography full pipeline" {
    const result = try predictDemography(.{ 0.3, 0.7 }, 28.0, null, .{ 0.5, 0.1, 0.2, 0.1, 0.1 });
    try std.testing.expect(result.gender == .Female);
    try std.testing.expectApproxEqAbs(result.age, 28.0, 0.001);
    try std.testing.expect(result.age_group == .YoungAdult);
    try std.testing.expect(result.race == .White);
}

test "parseEmotion identifies happy" {
    const scores = [8]f32{ 0.1, 0.8, 0.02, 0.02, 0.02, 0.01, 0.01, 0.02 };
    const result = try parseEmotion(scores);
    try std.testing.expect(result.label == .Happy);
    try std.testing.expectApproxEqAbs(result.confidence, 0.8, 0.001);
}

test "parseEmotion identifies angry" {
    const scores = [8]f32{ 0.05, 0.05, 0.1, 0.7, 0.02, 0.03, 0.02, 0.03 };
    const result = try parseEmotion(scores);
    try std.testing.expect(result.label == .Angry);
}

test "emotionToString" {
    try std.testing.expect(std.mem.eql(u8, emotionToString(.Happy), "happy"));
    try std.testing.expect(std.mem.eql(u8, emotionToString(.Neutral), "neutral"));
    try std.testing.expect(std.mem.eql(u8, emotionToString(.Surprised), "surprised"));
}

test "parseFaceState clamps to [0,1]" {
    const scores = [5]f32{ 0.9, -0.5, 1.5, 0.3, 0.6 };
    const result = parseFaceState(scores);
    try std.testing.expectApproxEqAbs(result.eyes_open, 0.9, 0.001);
    try std.testing.expectApproxEqAbs(result.wearing_glasses, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(result.wearing_sunglasses, 1.0, 0.001);
    try std.testing.expectApproxEqAbs(result.wearing_mask, 0.3, 0.001);
    try std.testing.expectApproxEqAbs(result.mouth_open, 0.6, 0.001);
}

test "AttributePredictor full prediction" {
    const predictor = AttributePredictor{};
    const demo = try predictor.predictDemographyFromModel(.{ 0.9, 0.1 }, 35.0, .{ 0.1, 0.1, 0.6, 0.1, 0.1 });
    try std.testing.expect(demo.gender == .Male);
    try std.testing.expect(demo.race == .Asian);

    const emo = try predictor.predictEmotion(.{ 0.02, 0.02, 0.02, 0.02, 0.8, 0.02, 0.02, 0.08 });
    try std.testing.expect(emo.label == .Surprised);

    const state = predictor.predictFaceState(.{ 0.95, 0.1, 0.05, 0.02, 0.3 });
    try std.testing.expectApproxEqAbs(state.eyes_open, 0.95, 0.001);
}

test "parseGender rejects negative scores" {
    try std.testing.expectError(error.InvalidScores, parseGender(.{ -0.1, 0.5 }));
}
