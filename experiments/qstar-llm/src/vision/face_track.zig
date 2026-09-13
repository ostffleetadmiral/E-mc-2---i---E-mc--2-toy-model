//! face_track.zig — Multi-face tracking using BYTETracker algorithm.
//!
//! Implements Kalman filter motion prediction, IoU-based detection association,
//! and track lifecycle management (new → tracked → lost → removed). Pure Zig,
//! no external dependencies. Designed to work with face_detect.zig FaceBox output.

const std = @import("std");
const face_detect = @import("face_detect");

// =============================================================================
// Types
// =============================================================================

pub const TrackState = enum {
    New, // Newly created, not yet confirmed
    Tracked, // Active, currently being tracked
    Lost, // No detection matched, but may reappear
    Removed, // Permanently removed
};

pub const TrackingError = error{
    OutOfMemory,
    InvalidInput,
};

/// A single tracked face with Kalman filter state.
/// State vector: [cx, cy, w, h, vx, vy, vw, vh] (position + velocity).
pub const Track = struct {
    id: u32,
    state: TrackState,
    frame_count: usize, // Frames since creation
    lost_count: usize, // Consecutive frames without detection match

    // Kalman state: [cx, cy, w, h, vx, vy, vw, vh]
    cx: f32,
    cy: f32,
    w: f32,
    h: f32,
    vx: f32,
    vy: f32,
    vw: f32,
    vh: f32,

    confidence: f32,
    landmarks: ?[5][2]f32 = null,

    // Kalman filter covariance (diagonal approximation for 8D state)
    // We use a simplified diagonal covariance for efficiency
    p_cx: f32 = 10.0,
    p_cy: f32 = 10.0,
    p_w: f32 = 10.0,
    p_h: f32 = 10.0,
    p_vx: f32 = 1000.0,
    p_vy: f32 = 1000.0,
    p_vw: f32 = 1000.0,
    p_vh: f32 = 1000.0,

    pub fn fromFaceBox(id: u32, box: face_detect.FaceBox) Track {
        const w = box.width();
        const h = box.height();
        return .{
            .id = id,
            .state = .New,
            .frame_count = 0,
            .lost_count = 0,
            .cx = (box.x1 + box.x2) * 0.5,
            .cy = (box.y1 + box.y2) * 0.5,
            .w = w,
            .h = h,
            .vx = 0,
            .vy = 0,
            .vw = 0,
            .vh = 0,
            .confidence = box.confidence,
            .landmarks = box.landmarks,
        };
    }

    pub fn toFaceBox(self: Track) face_detect.FaceBox {
        const half_w = self.w * 0.5;
        const half_h = self.h * 0.5;
        return .{
            .x1 = self.cx - half_w,
            .y1 = self.cy - half_h,
            .x2 = self.cx + half_w,
            .y2 = self.cy + half_h,
            .confidence = self.confidence,
            .landmarks = self.landmarks,
        };
    }

    /// Predict next position using constant velocity model.
    pub fn predict(self: *Track, dt: f32) void {
        self.cx += self.vx * dt;
        self.cy += self.vy * dt;
        self.w += self.vw * dt;
        self.h += self.vh * dt;

        // Grow uncertainty (process noise)
        const q: f32 = 0.1; // Process noise
        self.p_cx += q;
        self.p_cy += q;
        self.p_w += q;
        self.p_h += q;
        self.p_vx += q * 10;
        self.p_vy += q * 10;
        self.p_vw += q * 10;
        self.p_vh += q * 10;

        self.frame_count += 1;
    }

    /// Update state with a new detection (Kalman update step).
    pub fn update(self: *Track, box: face_detect.FaceBox) void {
        const det_cx = (box.x1 + box.x2) * 0.5;
        const det_cy = (box.y1 + box.y2) * 0.5;
        const det_w = box.width();
        const det_h = box.height();

        // Kalman gain (simplified: K = P / (P + R))
        const r: f32 = 1.0; // Measurement noise
        const k_cx = self.p_cx / (self.p_cx + r);
        const k_cy = self.p_cy / (self.p_cy + r);
        const k_w = self.p_w / (self.p_w + r);
        const k_h = self.p_h / (self.p_h + r);

        // Update position
        self.cx += k_cx * (det_cx - self.cx);
        self.cy += k_cy * (det_cy - self.cy);
        self.w += k_w * (det_w - self.w);
        self.h += k_h * (det_h - self.h);

        // Update velocity (simple finite difference)
        if (self.frame_count > 0) {
            const alpha: f32 = 0.5; // Velocity smoothing
            self.vx = alpha * (det_cx - self.cx) + (1.0 - alpha) * self.vx;
            self.vy = alpha * (det_cy - self.cy) + (1.0 - alpha) * self.vy;
        }

        // Reduce uncertainty
        self.p_cx *= (1.0 - k_cx);
        self.p_cy *= (1.0 - k_cy);
        self.p_w *= (1.0 - k_w);
        self.p_h *= (1.0 - k_h);

        self.confidence = box.confidence;
        self.landmarks = box.landmarks;
        self.lost_count = 0;
        self.state = .Tracked;
    }

    /// Mark track as lost (no detection matched).
    pub fn markLost(self: *Track) void {
        self.lost_count += 1;
        self.state = .Lost;
    }

    /// IoU with a detection box.
    pub fn iou(self: Track, box: face_detect.FaceBox) f32 {
        return self.toFaceBox().iou(box);
    }
};

// =============================================================================
// Tracker configuration
// =============================================================================

pub const TrackerConfig = struct {
    high_score_threshold: f32 = 0.6, // High-confidence detection split
    low_score_threshold: f32 = 0.1, // Low-confidence detection minimum
    first_match_threshold: f32 = 0.5, // IoU threshold for high-conf match
    second_match_threshold: f32 = 0.5, // IoU threshold for low-conf match
    lost_time_limit: usize = 30, // Frames before a lost track is removed
    new_track_time_limit: usize = 3, // Frames before a new track is confirmed
    max_track_count: usize = 100,
    dt: f32 = 1.0, // Time step per frame
};

// =============================================================================
// Face tracker (BYTETracker)
// =============================================================================

pub const FaceTracker = struct {
    config: TrackerConfig,
    tracks: std.ArrayList(Track),
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: TrackerConfig) FaceTracker {
        return .{
            .config = config,
            .tracks = std.ArrayList(Track).init(allocator),
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FaceTracker) void {
        self.tracks.deinit();
    }

    /// Update tracker with new detections for the current frame.
    pub fn update(self: *FaceTracker, detections: []const face_detect.FaceBox) TrackingError!void {
        // Step 1: Predict all existing tracks
        for (self.tracks.items) |*track| {
            track.predict(self.config.dt);
        }

        // Step 2: Split detections into high and low confidence
        var high_dets = std.ArrayList(face_detect.FaceBox).init(self.allocator);
        defer high_dets.deinit();
        var low_dets = std.ArrayList(face_detect.FaceBox).init(self.allocator);
        defer low_dets.deinit();

        for (detections) |det| {
            if (det.confidence >= self.config.high_score_threshold) {
                try high_dets.append(det);
            } else if (det.confidence >= self.config.low_score_threshold) {
                try low_dets.append(det);
            }
        }

        // Step 3: Match high-confidence detections to tracks
        var matched_high = try self.associateTracks(self.tracks.items, high_dets.items, self.config.first_match_threshold);
        defer matched_high.deinit();

        // Update matched tracks
        for (matched_high.items) |m| {
            self.tracks.items[m.track_idx].update(high_dets.items[m.det_idx]);
        }

        // Track which detections were matched
        var high_matched = try self.allocator.alloc(bool, high_dets.items.len);
        defer self.allocator.free(high_matched);
        @memset(high_matched, false);
        for (matched_high.items) |m| high_matched[m.det_idx] = true;

        // Track which tracks were matched
        var track_matched = try self.allocator.alloc(bool, self.tracks.items.len);
        defer self.allocator.free(track_matched);
        @memset(track_matched, false);
        for (matched_high.items) |m| track_matched[m.track_idx] = true;

        // Step 4: Match remaining tracks with low-confidence detections
        var unmatched_tracks = std.ArrayList(usize).init(self.allocator);
        defer unmatched_tracks.deinit();
        for (track_matched, 0..) |matched, i| {
            if (!matched and self.tracks.items[i].state != .Removed) {
                try unmatched_tracks.append(i);
            }
        }

        var low_matched = try self.allocator.alloc(bool, low_dets.items.len);
        defer self.allocator.free(low_matched);
        @memset(low_matched, false);

        for (unmatched_tracks.items) |ti| {
            const track = &self.tracks.items[ti];
            var best_iou: f32 = self.config.second_match_threshold;
            var best_det: ?usize = null;

            for (low_dets.items, 0..) |det, di| {
                if (low_matched[di]) continue;
                const iou_val = track.iou(det);
                if (iou_val > best_iou) {
                    best_iou = iou_val;
                    best_det = di;
                }
            }

            if (best_det) |di| {
                track.update(low_dets.items[di]);
                low_matched[di] = true;
                track_matched[ti] = true;
            }
        }

        // Step 5: Mark unmatched tracks as lost
        for (track_matched, 0..) |matched, i| {
            if (!matched and self.tracks.items[i].state != .Removed) {
                self.tracks.items[i].markLost();
            }
        }

        // Step 6: Remove tracks that have been lost too long
        for (self.tracks.items) |*track| {
            if (track.state == .Lost and track.lost_count >= self.config.lost_time_limit) {
                track.state = .Removed;
            }
        }

        // Step 7: Create new tracks from unmatched high-confidence detections
        for (high_dets.items, 0..) |det, di| {
            if (high_matched[di]) continue;
            if (self.tracks.items.len >= self.config.max_track_count) break;

            const track = Track.fromFaceBox(self.next_id, det);
            try self.tracks.append(track);
            self.next_id += 1;
        }

        // Step 8: Confirm new tracks that have been seen enough frames
        for (self.tracks.items) |*track| {
            if (track.state == .New and track.frame_count >= self.config.new_track_time_limit) {
                track.state = .Tracked;
            }
        }

        // Done — callers can inspect tracks via getActiveTracksOwned()
    }

    /// Get count of currently active (tracked or new) tracks.
    pub fn activeTrackCount(self: FaceTracker) usize {
        var count: usize = 0;
        for (self.tracks.items) |t| {
            if (t.state == .Tracked or t.state == .New) count += 1;
        }
        return count;
    }

    /// Get all currently active tracks as an owned slice (caller must free).
    pub fn getActiveTracksOwned(self: FaceTracker) TrackingError![]Track {
        var result = std.ArrayList(Track).init(self.allocator);
        for (self.tracks.items) |t| {
            if (t.state == .Tracked or t.state == .New) {
                try result.append(t);
            }
        }
        return result.toOwnedSlice();
    }

    /// Associate tracks with detections using greedy IoU matching.
    const Match = struct { track_idx: usize, det_idx: usize };
    const MatchList = std.ArrayList(Match);

    fn associateTracks(
        self: FaceTracker,
        tracks: []Track,
        dets: []const face_detect.FaceBox,
        threshold: f32,
    ) TrackingError!MatchList {
        var matches = MatchList.init(self.allocator);

        var det_matched = try self.allocator.alloc(bool, dets.len);
        defer self.allocator.free(det_matched);
        @memset(det_matched, false);

        // Greedy matching: for each track, find best unmatched detection
        for (tracks, 0..) |track, ti| {
            if (track.state == .Removed) continue;

            var best_iou: f32 = threshold;
            var best_det: ?usize = null;

            for (dets, 0..) |det, di| {
                if (det_matched[di]) continue;
                const iou_val = track.iou(det);
                if (iou_val > best_iou) {
                    best_iou = iou_val;
                    best_det = di;
                }
            }

            if (best_det) |di| {
                try matches.append(.{ .track_idx = ti, .det_idx = di });
                det_matched[di] = true;
            }
        }

        return matches;
    }

    /// Reset tracker state (clear all tracks).
    pub fn reset(self: *FaceTracker) void {
        self.tracks.clearRetainingCapacity();
        self.next_id = 1;
    }

    /// Get total track count (including lost and removed).
    pub fn totalTrackCount(self: FaceTracker) usize {
        return self.tracks.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Track fromFaceBox creates correct initial state" {
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 20, .x2 = 50, .y2 = 80, .confidence = 0.9 };
    const track = Track.fromFaceBox(1, box);

    try std.testing.expect(track.id == 1);
    try std.testing.expect(track.state == .New);
    try std.testing.expect(track.cx == 30.0); // (10+50)/2
    try std.testing.expect(track.cy == 50.0); // (20+80)/2
    try std.testing.expect(track.w == 40.0);
    try std.testing.expect(track.h == 60.0);
    try std.testing.expect(track.vx == 0.0);
    try std.testing.expect(track.vy == 0.0);
}

test "Track toFaceBox round-trip" {
    const box = face_detect.FaceBox{ .x1 = 10, .y1 = 20, .x2 = 50, .y2 = 80, .confidence = 0.9 };
    const track = Track.fromFaceBox(1, box);
    const result = track.toFaceBox();

    try std.testing.expectApproxEqAbs(result.x1, 10.0, 0.001);
    try std.testing.expectApproxEqAbs(result.y1, 20.0, 0.001);
    try std.testing.expectApproxEqAbs(result.x2, 50.0, 0.001);
    try std.testing.expectApproxEqAbs(result.y2, 80.0, 0.001);
}

test "Track predict moves by velocity" {
    var track = Track.fromFaceBox(1, .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 });
    track.vx = 5.0;
    track.vy = 3.0;

    track.predict(1.0);

    try std.testing.expectApproxEqAbs(track.cx, 10.0, 0.001); // 5 + 5*1
    try std.testing.expectApproxEqAbs(track.cy, 8.0, 0.001); // 5 + 3*1
    try std.testing.expect(track.frame_count == 1);
}

test "Track update with detection" {
    var track = Track.fromFaceBox(1, .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.5 });
    track.frame_count = 1;

    // Detection at (20, 20) to (30, 30)
    track.update(.{ .x1 = 20, .y1 = 20, .x2 = 30, .y2 = 30, .confidence = 0.9 });

    // Should move toward detection
    try std.testing.expect(track.cx > 5.0); // Moved from 5 toward 25
    try std.testing.expect(track.confidence == 0.9);
    try std.testing.expect(track.state == .Tracked);
    try std.testing.expect(track.lost_count == 0);
}

test "Track markLost increments lost_count" {
    var track = Track.fromFaceBox(1, .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 });
    track.markLost();

    try std.testing.expect(track.state == .Lost);
    try std.testing.expect(track.lost_count == 1);

    track.markLost();
    try std.testing.expect(track.lost_count == 2);
}

test "Track iou with detection" {
    const track = Track.fromFaceBox(1, .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 });
    const box = face_detect.FaceBox{ .x1 = 5, .y1 = 5, .x2 = 15, .y2 = 15, .confidence = 0.8 };

    const iou_val = track.iou(box);
    // Intersection = 5*5=25, union = 100+100-25=175
    try std.testing.expectApproxEqAbs(iou_val, 25.0 / 175.0, 0.001);
}

test "FaceTracker update with single face across frames" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    // Frame 1: detection at (10, 10, 50, 50)
    const det1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };
    _ = try tracker.update(&det1);
    try std.testing.expect(tracker.totalTrackCount() == 1);

    // Frame 2: same face slightly moved
    const det2 = [_]face_detect.FaceBox{
        .{ .x1 = 12, .y1 = 12, .x2 = 52, .y2 = 52, .confidence = 0.88 },
    };
    _ = try tracker.update(&det2);

    // Should still have 1 track (same ID)
    try std.testing.expect(tracker.totalTrackCount() == 1);
    try std.testing.expect(tracker.tracks.items[0].id == 1);
}

test "FaceTracker maintains ID across frames" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    // Frame 1
    const det1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };
    _ = try tracker.update(&det1);
    const track_id = tracker.tracks.items[0].id;

    // Frame 2: same face moved
    const det2 = [_]face_detect.FaceBox{
        .{ .x1 = 14, .y1 = 14, .x2 = 54, .y2 = 54, .confidence = 0.85 },
    };
    _ = try tracker.update(&det2);

    // Frame 3: same face moved more
    const det3 = [_]face_detect.FaceBox{
        .{ .x1 = 18, .y1 = 18, .x2 = 58, .y2 = 58, .confidence = 0.87 },
    };
    _ = try tracker.update(&det3);

    try std.testing.expect(tracker.tracks.items[0].id == track_id);
}

test "FaceTracker creates separate tracks for non-overlapping faces" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    const dets = [_]face_detect.FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 100, .y1 = 100, .x2 = 150, .y2 = 150, .confidence = 0.85 },
    };

    _ = try tracker.update(&dets);
    try std.testing.expect(tracker.totalTrackCount() == 2);
    try std.testing.expect(tracker.tracks.items[0].id != tracker.tracks.items[1].id);
}

test "FaceTracker marks lost tracks when no detection" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{ .lost_time_limit = 3 });
    defer tracker.deinit();

    // Frame 1: detect face
    const det1 = [_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    };
    _ = try tracker.update(&det1);

    // Frame 2: no detections
    _ = try tracker.update(&[_]face_detect.FaceBox{});

    try std.testing.expect(tracker.tracks.items[0].state == .Lost);
}

test "FaceTracker removes lost tracks after time limit" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{ .lost_time_limit = 2 });
    defer tracker.deinit();

    // Frame 1: detect face
    _ = try tracker.update(&[_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    });

    // Frame 2: no detection (lost_count = 1)
    _ = try tracker.update(&[_]face_detect.FaceBox{});

    // Frame 3: no detection (lost_count = 2, should be removed)
    _ = try tracker.update(&[_]face_detect.FaceBox{});

    try std.testing.expect(tracker.tracks.items[0].state == .Removed);
}

test "FaceTracker recovers lost track when detection reappears" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{ .lost_time_limit = 5, .first_match_threshold = 0.1 });
    defer tracker.deinit();

    // Frame 1: detect face
    _ = try tracker.update(&[_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    });

    // Frame 2: no detection (lost)
    _ = try tracker.update(&[_]face_detect.FaceBox{});

    try std.testing.expect(tracker.tracks.items[0].state == .Lost);

    // Frame 3: detection reappears at same location
    _ = try tracker.update(&[_]face_detect.FaceBox{
        .{ .x1 = 12, .y1 = 12, .x2 = 52, .y2 = 52, .confidence = 0.85 },
    });

    // Track should be tracked again with same ID
    try std.testing.expect(tracker.tracks.items[0].state == .Tracked);
    try std.testing.expect(tracker.tracks.items[0].id == 1);
}

test "FaceTracker reset clears all tracks" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    _ = try tracker.update(&[_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    });
    try std.testing.expect(tracker.totalTrackCount() == 1);

    tracker.reset();
    try std.testing.expect(tracker.totalTrackCount() == 0);
    try std.testing.expect(tracker.next_id == 1);
}

test "FaceTracker handles empty detections" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{});
    defer tracker.deinit();

    _ = try tracker.update(&[_]face_detect.FaceBox{});
    try std.testing.expect(tracker.totalTrackCount() == 0);
}

test "FaceTracker low-confidence detections match lost tracks" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{
        .high_score_threshold = 0.6,
        .low_score_threshold = 0.1,
        .first_match_threshold = 0.3,
        .second_match_threshold = 0.3,
    });
    defer tracker.deinit();

    // Frame 1: high-confidence detection
    _ = try tracker.update(&[_]face_detect.FaceBox{
        .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50, .confidence = 0.9 },
    });

    // Frame 2: low-confidence detection at same location
    _ = try tracker.update(&[_]face_detect.FaceBox{
        .{ .x1 = 12, .y1 = 12, .x2 = 52, .y2 = 52, .confidence = 0.3 },
    });

    // Track should still be tracked (matched with low-conf detection)
    try std.testing.expect(tracker.tracks.items[0].state == .Tracked);
}

test "FaceTracker max_track_count limits new tracks" {
    const allocator = std.testing.allocator;
    var tracker = FaceTracker.init(allocator, .{ .max_track_count = 2 });
    defer tracker.deinit();

    const dets = [_]face_detect.FaceBox{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10, .confidence = 0.9 },
        .{ .x1 = 100, .y1 = 100, .x2 = 110, .y2 = 110, .confidence = 0.9 },
        .{ .x1 = 200, .y1 = 200, .x2 = 210, .y2 = 210, .confidence = 0.9 },
    };

    _ = try tracker.update(&dets);
    try std.testing.expect(tracker.totalTrackCount() <= 2);
}
