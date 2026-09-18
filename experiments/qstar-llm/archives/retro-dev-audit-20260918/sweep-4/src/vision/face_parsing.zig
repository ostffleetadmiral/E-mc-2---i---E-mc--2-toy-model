//! face_parsing.zig — Face parsing/segmentation (BiSeNet 19-class).
//!
//! Provides face region segmentation post-processing: argmax over class logits,
//! color map visualization, and region statistics. All post-processing is pure Zig.

const std = @import("std");
const image = @import("image");

// =============================================================================
// Types
// =============================================================================

pub const ParsingClass = enum(u8) {
    Background = 0,
    Skin = 1,
    LeftBrow = 2,
    RightBrow = 3,
    LeftEye = 4,
    RightEye = 5,
    Nose = 6,
    UpperLip = 7,
    LowerLip = 8,
    Mouth = 9,
    UpperFace = 10,
    LowerFace = 11,
    Hair = 12,
    Hat = 13,
    EarR = 14,
    EarL = 15,
    Neck = 16,
    NeckL = 17,
    Cloth = 18,
};

pub const PARSING_CLASS_COUNT: usize = 19;

pub const ParsingError = error{
    InvalidInput,
    OutOfMemory,
    FileNotFound,
    InvalidFormat,
    UnsupportedFormat,
    TruncatedData,
    LibraryNotFound,
    FreestandingUnsupported,
};

/// Segmentation map: per-pixel class index.
pub const SegmentationMap = struct {
    width: usize,
    height: usize,
    classes: []u8, // Per-pixel class index
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) ParsingError!SegmentationMap {
        const classes = try allocator.alloc(u8, width * height);
        @memset(classes, 0);
        return .{
            .width = width,
            .height = height,
            .classes = classes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SegmentationMap) void {
        self.allocator.free(self.classes);
    }

    pub fn getClass(self: SegmentationMap, x: usize, y: usize) ParsingClass {
        return @enumFromInt(self.classes[y * self.width + x]);
    }

    pub fn setClass(self: *SegmentationMap, x: usize, y: usize, class: ParsingClass) void {
        self.classes[y * self.width + x] = @intFromEnum(class);
    }
};

// =============================================================================
// Color map for visualization
// =============================================================================

pub const PARSING_COLORS = [PARSING_CLASS_COUNT][3]u8{
    .{ 0, 0, 0 }, // Background - black
    .{ 255, 255, 255 }, // Skin - white
    .{ 255, 0, 0 }, // Left brow - red
    .{ 255, 85, 0 }, // Right brow - orange
    .{ 255, 170, 0 }, // Left eye - amber
    .{ 255, 0, 85 }, // Right eye - pink
    .{ 255, 255, 85 }, // Nose - yellow
    .{ 170, 255, 0 }, // Upper lip - lime
    .{ 85, 255, 0 }, // Lower lip - green
    .{ 0, 255, 0 }, // Mouth - bright green
    .{ 0, 255, 85 }, // Upper face - teal
    .{ 0, 255, 170 }, // Lower face - cyan
    .{ 0, 170, 255 }, // Hair - blue
    .{ 0, 85, 255 }, // Hat - deep blue
    .{ 85, 0, 255 }, // EarR - purple
    .{ 170, 0, 255 }, // EarL - violet
    .{ 255, 0, 170 }, // Neck - magenta
    .{ 255, 0, 85 }, // NeckL - rose
    .{ 255, 170, 170 }, // Cloth - light red
};

// =============================================================================
// Post-processing
// =============================================================================

/// Apply argmax over class logits to produce a segmentation map.
/// logits: [C, H, W] flattened — class-major layout.
pub fn argmaxToSegmentation(
    allocator: std.mem.Allocator,
    logits: []const f32,
    num_classes: usize,
    width: usize,
    height: usize,
) ParsingError!SegmentationMap {
    if (logits.len < num_classes * width * height) return error.InvalidInput;
    if (num_classes != PARSING_CLASS_COUNT) return error.InvalidInput;

    var map = try SegmentationMap.init(allocator, width, height);

    for (0..height) |y| {
        for (0..width) |x| {
            const pixel_idx = y * width + x;
            var best_class: usize = 0;
            var best_val: f32 = logits[pixel_idx]; // Class 0 at [0, y, x]

            for (1..num_classes) |c| {
                const val = logits[c * width * height + pixel_idx];
                if (val > best_val) {
                    best_val = val;
                    best_class = c;
                }
            }

            map.classes[pixel_idx] = @intCast(best_class);
        }
    }

    return map;
}

/// Convert a segmentation map to a color visualization image.
pub fn segmentationToImage(allocator: std.mem.Allocator, map: SegmentationMap) ParsingError!image.Image {
    var img = try image.Image.init(allocator, map.width, map.height, 3);

    for (0..map.height) |y| {
        for (0..map.width) |x| {
            const class_idx = map.classes[y * map.width + x];
            const color = PARSING_COLORS[class_idx];
            const px_idx = (y * map.width + x) * 3;
            img.data[px_idx + 0] = color[0];
            img.data[px_idx + 1] = color[1];
            img.data[px_idx + 2] = color[2];
        }
    }

    return img;
}

/// Compute per-class pixel counts.
pub fn classStatistics(allocator: std.mem.Allocator, map: SegmentationMap) ParsingError![]usize {
    var counts = try allocator.alloc(usize, PARSING_CLASS_COUNT);
    @memset(counts, 0);

    for (map.classes) |c| {
        counts[c] += 1;
    }

    return counts;
}

/// Extract a binary mask for a specific class.
pub fn extractClassMask(allocator: std.mem.Allocator, map: SegmentationMap, class: ParsingClass) ParsingError![]u8 {
    var mask = try allocator.alloc(u8, map.width * map.height);
    const class_val = @intFromEnum(class);

    for (map.classes, 0..) |c, i| {
        mask[i] = if (c == class_val) 255 else 0;
    }

    return mask;
}

/// Get class name as string.
pub fn classToString(c: ParsingClass) []const u8 {
    return switch (c) {
        .Background => "background",
        .Skin => "skin",
        .LeftBrow => "left_brow",
        .RightBrow => "right_brow",
        .LeftEye => "left_eye",
        .RightEye => "right_eye",
        .Nose => "nose",
        .UpperLip => "upper_lip",
        .LowerLip => "lower_lip",
        .Mouth => "mouth",
        .UpperFace => "upper_face",
        .LowerFace => "lower_face",
        .Hair => "hair",
        .Hat => "hat",
        .EarR => "right_ear",
        .EarL => "left_ear",
        .Neck => "neck",
        .NeckL => "neck_line",
        .Cloth => "cloth",
    };
}

// =============================================================================
// High-level parser
// =============================================================================

pub const FaceParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FaceParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: FaceParser, logits: []const f32, num_classes: usize, width: usize, height: usize) ParsingError!SegmentationMap {
        return argmaxToSegmentation(self.allocator, logits, num_classes, width, height);
    }

    pub fn visualize(self: FaceParser, map: SegmentationMap) ParsingError!image.Image {
        return segmentationToImage(self.allocator, map);
    }

    pub fn stats(self: FaceParser, map: SegmentationMap) ParsingError![]usize {
        return classStatistics(self.allocator, map);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SegmentationMap init and deinit" {
    const allocator = std.testing.allocator;
    var map = try SegmentationMap.init(allocator, 10, 10);
    defer map.deinit();

    try std.testing.expect(map.width == 10);
    try std.testing.expect(map.height == 10);
    try std.testing.expect(map.classes.len == 100);
    // All initialized to 0 (Background)
    for (map.classes) |c| try std.testing.expect(c == 0);
}

test "SegmentationMap setClass and getClass" {
    const allocator = std.testing.allocator;
    var map = try SegmentationMap.init(allocator, 5, 5);
    defer map.deinit();

    map.setClass(2, 3, .Nose);
    try std.testing.expect(map.getClass(2, 3) == .Nose);
    try std.testing.expect(map.getClass(0, 0) == .Background);
}

test "argmaxToSegmentation picks highest logit" {
    const allocator = std.testing.allocator;
    // 2x2 image, 19 classes
    var logits: [19 * 4]f32 = undefined;
    @memset(&logits, 0.0);

    // Pixel (0,0): class 1 (Skin) has highest logit
    logits[1 * 4 + 0] = 5.0;
    // Pixel (1,0): class 12 (Hair) has highest logit
    logits[12 * 4 + 1] = 3.0;
    // Pixel (0,1): class 6 (Nose) has highest logit
    logits[6 * 4 + 2] = 7.0;
    // Pixel (1,1): class 0 (Background) has highest logit (default 0, all zero)

    var map = try argmaxToSegmentation(allocator, &logits, 19, 2, 2);
    defer map.deinit();

    try std.testing.expect(map.getClass(0, 0) == .Skin);
    try std.testing.expect(map.getClass(1, 0) == .Hair);
    try std.testing.expect(map.getClass(0, 1) == .Nose);
    try std.testing.expect(map.getClass(1, 1) == .Background);
}

test "argmaxToSegmentation rejects wrong class count" {
    const allocator = std.testing.allocator;
    const logits = [_]f32{0.0} ** 20;
    try std.testing.expectError(error.InvalidInput, argmaxToSegmentation(allocator, &logits, 5, 2, 2));
}

test "argmaxToSegmentation rejects insufficient data" {
    const allocator = std.testing.allocator;
    const logits = [_]f32{0.0} ** 10; // Too small for 19*2*2=76
    try std.testing.expectError(error.InvalidInput, argmaxToSegmentation(allocator, &logits, 19, 2, 2));
}

test "segmentationToImage produces colored output" {
    const allocator = std.testing.allocator;
    var map = try SegmentationMap.init(allocator, 2, 2);
    defer map.deinit();

    map.setClass(0, 0, .Skin); // White
    map.setClass(1, 0, .Hair); // Blue

    var img = try segmentationToImage(allocator, map);
    defer img.deinit();

    // Skin = white (255, 255, 255)
    try std.testing.expect(img.data[0] == 255);
    try std.testing.expect(img.data[1] == 255);
    try std.testing.expect(img.data[2] == 255);

    // Hair = blue (0, 170, 255)
    try std.testing.expect(img.data[3] == 0);
    try std.testing.expect(img.data[4] == 170);
    try std.testing.expect(img.data[5] == 255);
}

test "classStatistics counts pixels per class" {
    const allocator = std.testing.allocator;
    var map = try SegmentationMap.init(allocator, 4, 4);
    defer map.deinit();

    // 10 background, 6 skin
    for (0..10) |i| map.classes[i] = 0;
    for (10..16) |i| map.classes[i] = 1;

    const counts = try classStatistics(allocator, map);
    defer allocator.free(counts);

    try std.testing.expect(counts[0] == 10); // Background
    try std.testing.expect(counts[1] == 6); // Skin
    try std.testing.expect(counts[2] == 0); // LeftBrow
}

test "extractClassMask produces binary mask" {
    const allocator = std.testing.allocator;
    var map = try SegmentationMap.init(allocator, 3, 3);
    defer map.deinit();

    map.setClass(0, 0, .Skin);
    map.setClass(1, 0, .Skin);
    map.setClass(2, 0, .Background);

    const mask = try extractClassMask(allocator, map, .Skin);
    defer allocator.free(mask);

    try std.testing.expect(mask[0] == 255);
    try std.testing.expect(mask[1] == 255);
    try std.testing.expect(mask[2] == 0);
}

test "classToString returns correct names" {
    try std.testing.expect(std.mem.eql(u8, classToString(.Skin), "skin"));
    try std.testing.expect(std.mem.eql(u8, classToString(.Hair), "hair"));
    try std.testing.expect(std.mem.eql(u8, classToString(.Nose), "nose"));
    try std.testing.expect(std.mem.eql(u8, classToString(.Background), "background"));
}

test "PARSING_COLORS has 19 entries" {
    try std.testing.expect(PARSING_COLORS.len == PARSING_CLASS_COUNT);
}

test "PARSING_CLASS_COUNT is 19" {
    try std.testing.expect(PARSING_CLASS_COUNT == 19);
}

test "FaceParser parse and visualize" {
    const allocator = std.testing.allocator;
    const parser = FaceParser.init(allocator);

    var logits: [19 * 4]f32 = undefined;
    @memset(&logits, 0.0);
    logits[1 * 4 + 0] = 5.0; // Skin at (0,0)

    var map = try parser.parse(&logits, 19, 2, 2);
    defer map.deinit();

    try std.testing.expect(map.getClass(0, 0) == .Skin);

    var img = try parser.visualize(map);
    defer img.deinit();

    try std.testing.expect(img.width == 2);
    try std.testing.expect(img.height == 2);
}

test "FaceParser stats" {
    const allocator = std.testing.allocator;
    const parser = FaceParser.init(allocator);

    var map = try SegmentationMap.init(allocator, 4, 4);
    defer map.deinit();

    for (0..8) |i| map.classes[i] = 1; // Skin
    for (8..16) |i| map.classes[i] = 12; // Hair

    const counts = try parser.stats(map);
    defer allocator.free(counts);

    try std.testing.expect(counts[1] == 8);
    try std.testing.expect(counts[12] == 8);
}
