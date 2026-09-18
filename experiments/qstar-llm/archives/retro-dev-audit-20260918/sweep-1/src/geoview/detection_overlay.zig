const std = @import("std");

// =============================================================================
// Detection Overlay — Bounding boxes, tracking IDs, confidence scores
// =============================================================================
// Maps vision detection results to screen-space overlay elements.
// Pure Zig, no external dependencies.

pub const DetectionClass = enum {
    face,
    person,
    vehicle,
    aircraft,
    vessel,
    building,
    weapon,
    animal,
    unknown,
};

pub const DetectionBox = struct {
    id: u32,
    class: DetectionClass,
    label: []const u8,
    confidence: f32, // [0, 1]
    x: f64, // screen-space NDC [-1, 1]
    y: f64,
    width: f64, // NDC
    height: f64,
    tracking_id: ?u32 = null, // assigned by tracker
    age_frames: u32 = 0, // how many frames this detection has been visible
    velocity_x: f64 = 0, // NDC per frame
    velocity_y: f64 = 0,

    pub fn init(id: u32, class: DetectionClass, label: []const u8) DetectionBox {
        return .{
            .id = id,
            .class = class,
            .label = label,
            .confidence = 0,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
    }
};

pub const OverlayStyle = struct {
    box_color: [3]f32,
    label_bg_color: [3]f32,
    label_text_color: [3]f32,
    show_confidence: bool = true,
    show_tracking_id: bool = true,
    show_velocity_vector: bool = false,
    line_width: f32 = 2.0,
    corner_length: f32 = 0.15, // fraction of box dimension for corner markers

    pub fn forClass(class: DetectionClass) OverlayStyle {
        return switch (class) {
            .face => .{ .box_color = .{ 0, 1, 0 }, .label_bg_color = .{ 0, 0.5, 0 }, .label_text_color = .{ 1, 1, 1 } },
            .person => .{ .box_color = .{ 0, 1, 1 }, .label_bg_color = .{ 0, 0.5, 0.5 }, .label_text_color = .{ 1, 1, 1 } },
            .vehicle => .{ .box_color = .{ 1, 1, 0 }, .label_bg_color = .{ 0.5, 0.5, 0 }, .label_text_color = .{ 1, 1, 1 } },
            .aircraft => .{ .box_color = .{ 1, 0.5, 0 }, .label_bg_color = .{ 0.5, 0.25, 0 }, .label_text_color = .{ 1, 1, 1 } },
            .vessel => .{ .box_color = .{ 0, 0.5, 1 }, .label_bg_color = .{ 0, 0.25, 0.5 }, .label_text_color = .{ 1, 1, 1 } },
            .building => .{ .box_color = .{ 0.7, 0.7, 0.7 }, .label_bg_color = .{ 0.35, 0.35, 0.35 }, .label_text_color = .{ 1, 1, 1 } },
            .weapon => .{ .box_color = .{ 1, 0, 0 }, .label_bg_color = .{ 0.5, 0, 0 }, .label_text_color = .{ 1, 1, 1 } },
            .animal => .{ .box_color = .{ 0.5, 1, 0.5 }, .label_bg_color = .{ 0.25, 0.5, 0.25 }, .label_text_color = .{ 1, 1, 1 } },
            .unknown => .{ .box_color = .{ 0.5, 0.5, 0.5 }, .label_bg_color = .{ 0.25, 0.25, 0.25 }, .label_text_color = .{ 1, 1, 1 } },
        };
    }
};

pub const OverlayElement = struct {
    box: DetectionBox,
    style: OverlayStyle,
    label_text: []const u8,
    visible: bool = true,
};

pub const DetectionOverlay = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayList(OverlayElement),
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) DetectionOverlay {
        return .{
            .allocator = allocator,
            .elements = std.ArrayList(OverlayElement).init(allocator),
        };
    }

    pub fn deinit(self: *DetectionOverlay) void {
        self.clear();
        self.elements.deinit();
    }

    pub fn addDetection(self: *DetectionOverlay, box: DetectionBox) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        var new_box = box;
        new_box.id = id;

        const style = OverlayStyle.forClass(box.class);
        const label_text = try self.formatLabel(new_box, style);

        try self.elements.append(.{
            .box = new_box,
            .style = style,
            .label_text = label_text,
        });

        return id;
    }

    pub fn removeDetection(self: *DetectionOverlay, id: u32) void {
        var i: usize = 0;
        while (i < self.elements.items.len) {
            if (self.elements.items[i].box.id == id) {
                self.allocator.free(self.elements.items[i].label_text);
                _ = self.elements.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clear(self: *DetectionOverlay) void {
        for (self.elements.items) |el| {
            self.allocator.free(el.label_text);
        }
        self.elements.clearRetainingCapacity();
    }

    /// Update tracking: match new detections to existing ones by IoU
    pub fn updateTracking(self: *DetectionOverlay, new_boxes: []const DetectionBox) !void {
        // Age existing detections
        for (self.elements.items) |*el| {
            el.box.age_frames += 1;
        }

        // Match new boxes to existing by IoU
        var matched = std.AutoHashMap(usize, bool).init(self.allocator);
        defer matched.deinit();

        for (new_boxes) |new_box| {
            var best_iou: f64 = 0;
            var best_idx: ?usize = null;

            for (self.elements.items, 0..) |el, i| {
                if (matched.get(i) orelse false) continue;
                if (el.box.class != new_box.class) continue;

                const iou = computeIoU(el.box, new_box);
                if (iou > best_iou and iou > 0.3) {
                    best_iou = iou;
                    best_idx = i;
                }
            }

            if (best_idx) |idx| {
                try matched.put(idx, true);
                // Update existing detection
                const old = self.elements.items[idx].box;
                self.elements.items[idx].box.x = new_box.x;
                self.elements.items[idx].box.y = new_box.y;
                self.elements.items[idx].box.width = new_box.width;
                self.elements.items[idx].box.height = new_box.height;
                self.elements.items[idx].box.confidence = new_box.confidence;
                self.elements.items[idx].box.age_frames = 0;
                // Update velocity
                self.elements.items[idx].box.velocity_x = new_box.x - old.x;
                self.elements.items[idx].box.velocity_y = new_box.y - old.y;
            } else {
                // New detection
                _ = try self.addDetection(new_box);
            }
        }

        // Remove stale detections (age > 30 frames)
        var i: usize = 0;
        while (i < self.elements.items.len) {
            if (self.elements.items[i].box.age_frames > 30) {
                self.allocator.free(self.elements.items[i].label_text);
                _ = self.elements.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn formatLabel(self: *DetectionOverlay, box: DetectionBox, style: OverlayStyle) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try std.fmt.format(buf.writer(), "{s}", .{box.label});

        if (style.show_confidence) {
            try std.fmt.format(buf.writer(), " {d:.0}%", .{box.confidence * 100.0});
        }

        if (style.show_tracking_id and box.tracking_id != null) {
            try std.fmt.format(buf.writer(), " #{d}", .{box.tracking_id.?});
        }

        return buf.toOwnedSlice();
    }

    pub fn getVisibleElements(self: *DetectionOverlay) []const OverlayElement {
        return self.elements.items;
    }

    pub fn count(self: *DetectionOverlay) usize {
        return self.elements.items.len;
    }
};

/// Compute Intersection over Union (IoU) between two detection boxes
pub fn computeIoU(a: DetectionBox, b: DetectionBox) f64 {
    // NDC coordinates: x,y is center, width/height are dimensions
    const a_x1 = a.x - a.width / 2.0;
    const a_y1 = a.y - a.height / 2.0;
    const a_x2 = a.x + a.width / 2.0;
    const a_y2 = a.y + a.height / 2.0;

    const b_x1 = b.x - b.width / 2.0;
    const b_y1 = b.y - b.height / 2.0;
    const b_x2 = b.x + b.width / 2.0;
    const b_y2 = b.y + b.height / 2.0;

    const inter_x1 = @max(a_x1, b_x1);
    const inter_y1 = @max(a_y1, b_y1);
    const inter_x2 = @min(a_x2, b_x2);
    const inter_y2 = @min(a_y2, b_y2);

    const inter_w = @max(0.0, inter_x2 - inter_x1);
    const inter_h = @max(0.0, inter_y2 - inter_y1);
    const inter_area = inter_w * inter_h;

    const a_area = a.width * a.height;
    const b_area = b.width * b.height;
    const union_area = a_area + b_area - inter_area;

    if (union_area <= 0) return 0;
    return inter_area / union_area;
}

// =============================================================================
// Tests
// =============================================================================

test "detection_overlay: OverlayStyle forClass" {
    const face_style = OverlayStyle.forClass(.face);
    try std.testing.expectEqual(@as(f32, 0), face_style.box_color[0]);
    try std.testing.expectEqual(@as(f32, 1), face_style.box_color[1]);

    const weapon_style = OverlayStyle.forClass(.weapon);
    try std.testing.expectEqual(@as(f32, 1), weapon_style.box_color[0]);
    try std.testing.expectEqual(@as(f32, 0), weapon_style.box_color[1]);
}

test "detection_overlay: addDetection" {
    const allocator = std.testing.allocator;
    var overlay = DetectionOverlay.init(allocator);
    defer overlay.deinit();

    const id = try overlay.addDetection(.{
        .id = 0,
        .class = .face,
        .label = "Person_A",
        .confidence = 0.95,
        .x = 0.0,
        .y = 0.0,
        .width = 0.1,
        .height = 0.2,
    });

    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(usize, 1), overlay.count());
}

test "detection_overlay: removeDetection" {
    const allocator = std.testing.allocator;
    var overlay = DetectionOverlay.init(allocator);
    defer overlay.deinit();

    const id = try overlay.addDetection(.{
        .id = 0,
        .class = .person,
        .label = "Test",
        .confidence = 0.8,
        .x = 0,
        .y = 0,
        .width = 0.1,
        .height = 0.1,
    });

    try std.testing.expectEqual(@as(usize, 1), overlay.count());
    overlay.removeDetection(id);
    try std.testing.expectEqual(@as(usize, 0), overlay.count());
}

test "detection_overlay: computeIoU identical boxes" {
    const a = DetectionBox{ .id = 1, .class = .face, .label = "A", .confidence = 1, .x = 0, .y = 0, .width = 0.2, .height = 0.2 };
    const b = DetectionBox{ .id = 2, .class = .face, .label = "B", .confidence = 1, .x = 0, .y = 0, .width = 0.2, .height = 0.2 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), computeIoU(a, b), 1e-10);
}

test "detection_overlay: computeIoU no overlap" {
    const a = DetectionBox{ .id = 1, .class = .face, .label = "A", .confidence = 1, .x = -0.5, .y = 0, .width = 0.1, .height = 0.1 };
    const b = DetectionBox{ .id = 2, .class = .face, .label = "B", .confidence = 1, .x = 0.5, .y = 0, .width = 0.1, .height = 0.1 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeIoU(a, b), 1e-10);
}

test "detection_overlay: computeIoU partial overlap" {
    const a = DetectionBox{ .id = 1, .class = .face, .label = "A", .confidence = 1, .x = 0, .y = 0, .width = 0.2, .height = 0.2 };
    const b = DetectionBox{ .id = 2, .class = .face, .label = "B", .confidence = 1, .x = 0.1, .y = 0, .width = 0.2, .height = 0.2 };
    // Intersection: 0.1 * 0.2 = 0.02, Union: 0.04 + 0.04 - 0.02 = 0.06
    try std.testing.expectApproxEqAbs(@as(f64, 0.3333), computeIoU(a, b), 0.01);
}

test "detection_overlay: updateTracking matches by IoU" {
    const allocator = std.testing.allocator;
    var overlay = DetectionOverlay.init(allocator);
    defer overlay.deinit();

    _ = try overlay.addDetection(.{
        .id = 0,
        .class = .face,
        .label = "Person",
        .confidence = 0.9,
        .x = 0.0,
        .y = 0.0,
        .width = 0.1,
        .height = 0.1,
    });

    // New box at slightly moved position
    const new_boxes = [_]DetectionBox{.{
        .id = 0,
        .class = .face,
        .label = "Person",
        .confidence = 0.88,
        .x = 0.01,
        .y = 0.0,
        .width = 0.1,
        .height = 0.1,
    }};

    try overlay.updateTracking(&new_boxes);

    // Should have matched, not added new
    try std.testing.expectEqual(@as(usize, 1), overlay.count());
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), overlay.elements.items[0].box.x, 1e-10);
}

test "detection_overlay: updateTracking adds new detection" {
    const allocator = std.testing.allocator;
    var overlay = DetectionOverlay.init(allocator);
    defer overlay.deinit();

    _ = try overlay.addDetection(.{
        .id = 0,
        .class = .face,
        .label = "Person",
        .confidence = 0.9,
        .x = 0.0,
        .y = 0.0,
        .width = 0.1,
        .height = 0.1,
    });

    // New box far away — no match
    const new_boxes = [_]DetectionBox{.{
        .id = 0,
        .class = .face,
        .label = "Person2",
        .confidence = 0.85,
        .x = 0.8,
        .y = 0.8,
        .width = 0.1,
        .height = 0.1,
    }};

    try overlay.updateTracking(&new_boxes);
    try std.testing.expectEqual(@as(usize, 2), overlay.count());
}
