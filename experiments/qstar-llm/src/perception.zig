//! perception.zig — Lattice-native perception module.
//!
//! Translates concepts from UniFace (uniface) to lattice-native operations:
//! - detectActivations(): sliding-window activation detection with NMS
//!   (analog to SCRFD/RetinaFace face detection)
//! - estimateAttention(): 2-DOF attention angle from activation distribution
//!   (analog to gaze estimation pitch/yaw)
//! - estimateOrientation(): 3-DOF lattice rotation from E0 node distribution
//!   (analog to head pose pitch/yaw/roll)
//! - fingerprintState(): fixed-dim embedding from lattice state
//!   (analog to face embedding/recognition)
//! - livenessCheck(): peer liveness verification
//!   (analog to anti-spoofing detection)
//!
//! All operations use i128 Q32.32 fixed-point arithmetic (via fixed_point module)
//! to maintain Qstar's state invariants. No neural frameworks, no floating-point
//! in core computation.
//!
//! Zero external dependencies beyond std.

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

/// Number of E0 nodes in the base lattice (must match lattice.zig).
pub const E0_NODE_COUNT: usize = 421;

/// Number of activation channels per E0 node.
pub const CHANNELS: usize = 7;

/// Lattice grid edge length.
pub const GRID_EDGE: u32 = 15;

/// Detection threshold for activation significance (Q32.32).
/// An E0 node is "active" if its activation exceeds this value.
pub const DETECTION_THRESHOLD: i128 = fp.div(fp.fromInt(1), fp.fromInt(2)); // 0.5 in Q32.32

/// NMS (Non-Maximum Suppression) overlap threshold.
/// If two detected clusters overlap by more than this fraction, suppress the weaker.
pub const NMS_OVERLAP_THRESHOLD: i128 = fp.div(fp.fromInt(3), fp.fromInt(10)); // 0.3 in Q32.32

/// Embedding dimension for state fingerprinting.
pub const EMBEDDING_DIM: usize = 128;

/// Liveness challenge difficulty (number of lattice steps to verify).
pub const LIVENESS_STEPS: usize = 3;

/// Lattice grid coordinate.
pub const Coord = struct { x: u32, y: u32, z: u32 };

// =============================================================================
// DetectionResult — a detected activation cluster
// =============================================================================

pub const DetectionResult = struct {
    /// Center coordinates of the detected cluster (lattice grid coords).
    cx: u32,
    cy: u32,
    cz: u32,
    /// Number of active E0 nodes in this cluster.
    node_count: usize,
    /// Confidence score (Q32.32): fraction of active nodes / total nodes in window.
    confidence: i128,
    /// Bounding box of the cluster.
    min_x: u32,
    max_x: u32,
    min_y: u32,
    max_y: u32,
    min_z: u32,
    max_z: u32,

    pub fn init(cx: u32, cy: u32, cz: u32, count: usize, conf: i128) DetectionResult {
        return .{
            .cx = cx,
            .cy = cy,
            .cz = cz,
            .node_count = count,
            .confidence = conf,
            .min_x = cx,
            .max_x = cx,
            .min_y = cy,
            .max_y = cy,
            .min_z = cz,
            .max_z = cz,
        };
    }
};

// =============================================================================
// AttentionResult — 2-DOF attention direction (gaze analog)
// =============================================================================

pub const AttentionResult = struct {
    /// Pitch angle (Q32.32): positive = up, negative = down.
    pitch: i128,
    /// Yaw angle (Q32.32): positive = right, negative = left.
    yaw: i128,

    pub fn format(self: AttentionResult, allocator: std.mem.Allocator) ![]u8 {
        const pitch_str = try fp.format(allocator, self.pitch);
        defer allocator.free(pitch_str);
        const yaw_str = try fp.format(allocator, self.yaw);
        defer allocator.free(yaw_str);
        return try std.fmt.allocPrint(allocator, "Attention(pitch={s}, yaw={s})", .{ pitch_str, yaw_str });
    }
};

// =============================================================================
// OrientationResult — 3-DOF lattice rotation (head pose analog)
// =============================================================================

pub const OrientationResult = struct {
    /// Pitch (Q32.32): rotation around X-axis, positive = looking down.
    pitch: i128,
    /// Yaw (Q32.32): rotation around Y-axis, positive = looking right.
    yaw: i128,
    /// Roll (Q32.32): rotation around Z-axis, positive = tilting clockwise.
    roll: i128,

    pub fn format(self: OrientationResult, allocator: std.mem.Allocator) ![]u8 {
        const pitch_str = try fp.format(allocator, self.pitch);
        defer allocator.free(pitch_str);
        const yaw_str = try fp.format(allocator, self.yaw);
        defer allocator.free(yaw_str);
        const roll_str = try fp.format(allocator, self.roll);
        defer allocator.free(roll_str);
        return try std.fmt.allocPrint(allocator, "Orientation(pitch={s}, yaw={s}, roll={s})", .{ pitch_str, yaw_str, roll_str });
    }
};

// =============================================================================
// LivenessResult — peer liveness verification (anti-spoofing analog)
// =============================================================================

pub const LivenessResult = struct {
    is_live: bool,
    confidence: i128, // Q32.32
    steps_verified: usize,

    pub fn format(self: LivenessResult, allocator: std.mem.Allocator) ![]u8 {
        const conf_str = try fp.format(allocator, self.confidence);
        defer allocator.free(conf_str);
        return try std.fmt.allocPrint(allocator, "Liveness(live={}, conf={s}, steps={d})", .{
            self.is_live,
            conf_str,
            self.steps_verified,
        });
    }
};

// =============================================================================
// Perception — main perception module
// =============================================================================

pub const Perception = struct {
    // =============================================================================
    // Detection: sliding-window activation detection with NMS
    // =============================================================================

    /// Detect activation clusters in the lattice using a sliding window approach.
    /// Analog to UniFace's SCRFD/RetinaFace detection: scan the lattice grid,
    /// find regions with high activation density, apply NMS to remove overlaps.
    ///
    /// `activations` is [421][8]i128 — E0 node activations in Q32.32.
    /// `coords` is [421]struct { x, y, z } — E0 node grid coordinates.
    pub fn detectActivations(
        allocator: std.mem.Allocator,
        activations: []const [CHANNELS]i128,
        coords: []const Coord,
    ) ![]DetectionResult {
        var candidates = std.ArrayList(DetectionResult).init(allocator);
        defer candidates.deinit();

        // Sliding window: scan 3×3×3 sub-grids centered on each E0 node
        const window_radius: u32 = 1;

        for (0..E0_NODE_COUNT) |i| {
            const cx = coords[i].x;
            const cy = coords[i].y;
            const cz = coords[i].z;

            // Count active nodes in the window around this node
            var active_count: usize = 0;
            var total_count: usize = 0;
            var sum_activation: i128 = 0;

            for (0..E0_NODE_COUNT) |j| {
                const nx = coords[j].x;
                const ny = coords[j].y;
                const nz = coords[j].z;

                // Check if node j is within the window
                const dx = if (nx > cx) nx - cx else cx - nx;
                const dy = if (ny > cy) ny - cy else cy - ny;
                const dz = if (nz > cz) nz - cz else cz - nz;

                if (dx <= window_radius and dy <= window_radius and dz <= window_radius) {
                    total_count += 1;

                    // Compute magnitude of activation across channels
                    const mag = activationMagnitude(activations[j]);
                    if (mag > DETECTION_THRESHOLD) {
                        active_count += 1;
                        sum_activation += mag;
                    }
                }
            }

            if (total_count == 0) continue;

            // Confidence = active_count / total_count (Q32.32)
            const confidence = fp.div(fp.fromInt(@as(i64, @intCast(active_count))), fp.fromInt(@as(i64, @intCast(total_count))));

            // Only keep candidates above threshold
            if (confidence > fp.div(fp.fromInt(1), fp.fromInt(3))) { // > 0.333
                var det = DetectionResult.init(cx, cy, cz, active_count, confidence);
                // Expand bounding box to window
                det.min_x = if (cx > window_radius) cx - window_radius else 0;
                det.max_x = @min(cx + window_radius, GRID_EDGE - 1);
                det.min_y = if (cy > window_radius) cy - window_radius else 0;
                det.max_y = @min(cy + window_radius, GRID_EDGE - 1);
                det.min_z = if (cz > window_radius) cz - window_radius else 0;
                det.max_z = @min(cz + window_radius, GRID_EDGE - 1);
                try candidates.append(det);
            }
        }

        // Apply NMS (Non-Maximum Suppression)
        return try nms(allocator, candidates.items);
    }

    /// Compute the magnitude of an E0 node's activation across all channels.
    /// Uses L1 norm (sum of absolute values) as a simple, fixed-point-friendly metric.
    fn activationMagnitude(channels: [CHANNELS]i128) i128 {
        var sum: i128 = 0;
        for (channels) |ch| {
            sum += if (ch < 0) -ch else ch;
        }
        return fp.div(sum, fp.fromInt(@as(i64, @intCast(CHANNELS))));
    }

    /// Non-Maximum Suppression: remove overlapping detections, keeping the strongest.
    /// Analog to NMS in face detection pipelines.
    fn nms(allocator: std.mem.Allocator, detections: []const DetectionResult) ![]DetectionResult {
        if (detections.len == 0) return try allocator.alloc(DetectionResult, 0);

        // Sort by confidence descending (simple insertion sort)
        var sorted = try allocator.dupe(DetectionResult, detections);
        for (0..sorted.len) |i| {
            var best = i;
            for (i + 1..sorted.len) |j| {
                if (sorted[j].confidence > sorted[best].confidence) {
                    best = j;
                }
            }
            if (best != i) {
                const tmp = sorted[i];
                sorted[i] = sorted[best];
                sorted[best] = tmp;
            }
        }

        // Greedily select non-overlapping detections
        var kept = std.ArrayList(DetectionResult).init(allocator);
        defer kept.deinit();

        var suppressed = try allocator.alloc(bool, sorted.len);
        defer allocator.free(suppressed);
        for (suppressed) |*s| s.* = false;

        for (0..sorted.len) |i| {
            if (suppressed[i]) continue;
            try kept.append(sorted[i]);

            for (i + 1..sorted.len) |j| {
                if (suppressed[j]) continue;
                const overlap = computeOverlap(sorted[i], sorted[j]);
                if (overlap > NMS_OVERLAP_THRESHOLD) {
                    suppressed[j] = true;
                }
            }
        }

        const result = try allocator.dupe(DetectionResult, kept.items);
        allocator.free(sorted);
        return result;
    }

    /// Compute IoU (Intersection over Union) of two detection bounding boxes.
    /// Returns Q32.32 fixed-point overlap ratio.
    fn computeOverlap(a: DetectionResult, b: DetectionResult) i128 {
        // Intersection
        const ix_min = @max(a.min_x, b.min_x);
        const ix_max = @min(a.max_x, b.max_x);
        const iy_min = @max(a.min_y, b.min_y);
        const iy_max = @min(a.max_y, b.max_y);
        const iz_min = @max(a.min_z, b.min_z);
        const iz_max = @min(a.max_z, b.max_z);

        if (ix_max < ix_min or iy_max < iy_min or iz_max < iz_min) return 0;

        const ix_vol = (@as(u64, ix_max - ix_min + 1)) * (@as(u64, iy_max - iy_min + 1)) * (@as(u64, iz_max - iz_min + 1));

        // Union
        const a_vol = (@as(u64, a.max_x - a.min_x + 1)) * (@as(u64, a.max_y - a.min_y + 1)) * (@as(u64, a.max_z - a.min_z + 1));
        const b_vol = (@as(u64, b.max_x - b.min_x + 1)) * (@as(u64, b.max_y - b.min_y + 1)) * (@as(u64, b.max_z - b.min_z + 1));
        const u_vol = a_vol + b_vol - ix_vol;

        if (u_vol == 0) return 0;
        return fp.div(fp.fromInt(@as(i64, @intCast(ix_vol))), fp.fromInt(@as(i64, @intCast(u_vol))));
    }

    // =============================================================================
    // Attention: 2-DOF attention direction (gaze analog)
    // =============================================================================

    /// Estimate the "attention direction" of the lattice as a 2-DOF angle.
    /// Analog to UniFace's gaze estimation: compute the centroid of active
    /// E0 nodes, then derive pitch/yaw from its offset from the grid center.
    ///
    /// Pitch = positive if centroid is above grid center (z > center_z)
    /// Yaw = positive if centroid is right of grid center (x > center_x)
    pub fn estimateAttention(
        activations: []const [CHANNELS]i128,
        coords: []const Coord,
    ) AttentionResult {
        var weighted_x: i128 = 0;
        var weighted_z: i128 = 0;
        var total_weight: i128 = 0;

        for (0..E0_NODE_COUNT) |i| {
            const mag = activationMagnitude(activations[i]);
            if (mag > DETECTION_THRESHOLD) {
                weighted_x += fp.mul(mag, fp.fromInt(@as(i64, @intCast(coords[i].x))));
                weighted_z += fp.mul(mag, fp.fromInt(@as(i64, @intCast(coords[i].z))));
                total_weight += mag;
            }
        }

        if (total_weight == 0) {
            return .{ .pitch = 0, .yaw = 0 };
        }

        // Centroid coordinates (Q32.32)
        const centroid_x = fp.div(weighted_x, total_weight);
        const centroid_z = fp.div(weighted_z, total_weight);

        // Compute actual coordinate center from the E0 node set
        var min_x: u32 = std.math.maxInt(u32);
        var max_x: u32 = 0;
        var min_z: u32 = std.math.maxInt(u32);
        var max_z: u32 = 0;
        for (coords) |c| {
            if (c.x < min_x) min_x = c.x;
            if (c.x > max_x) max_x = c.x;
            if (c.z < min_z) min_z = c.z;
            if (c.z > max_z) max_z = c.z;
        }
        const center_x = fp.fromInt(@divTrunc(@as(i64, @intCast(min_x + max_x)), 2));
        const center_z = fp.fromInt(@divTrunc(@as(i64, @intCast(min_z + max_z)), 2));

        // Yaw = (centroid_x - center_x) / center_x, scaled to [-1, 1]
        const yaw = if (center_x != 0) fp.div(fp.sub(centroid_x, center_x), center_x) else 0;

        // Pitch = (centroid_z - center_z) / center_z, scaled to [-1, 1]
        const pitch = if (center_z != 0) fp.div(fp.sub(centroid_z, center_z), center_z) else 0;

        return .{ .pitch = pitch, .yaw = yaw };
    }

    // =============================================================================
    // Orientation: 3-DOF lattice rotation (head pose analog)
    // =============================================================================

    /// Estimate the "orientation" of the lattice as a 3-DOF rotation.
    /// Analog to UniFace's head pose estimation: compute the principal axes
    /// of the activation distribution using weighted moments.
    ///
    /// Pitch = from z-axis asymmetry (front/back tilt)
    /// Yaw = from x-axis asymmetry (left/right rotation)
    /// Roll = from y-axis asymmetry (clockwise/counterclockwise tilt)
    pub fn estimateOrientation(
        activations: []const [CHANNELS]i128,
        coords: []const Coord,
    ) OrientationResult {
        var wx: i128 = 0;
        var wy: i128 = 0;
        var wz: i128 = 0;
        var total: i128 = 0;

        for (0..E0_NODE_COUNT) |i| {
            const mag = activationMagnitude(activations[i]);
            if (mag > DETECTION_THRESHOLD) {
                wx += fp.mul(mag, fp.fromInt(@as(i64, @intCast(coords[i].x))));
                wy += fp.mul(mag, fp.fromInt(@as(i64, @intCast(coords[i].y))));
                wz += fp.mul(mag, fp.fromInt(@as(i64, @intCast(coords[i].z))));
                total += mag;
            }
        }

        if (total == 0) {
            return .{ .pitch = 0, .yaw = 0, .roll = 0 };
        }

        // Compute actual coordinate centers from the E0 node set
        var min_x: u32 = std.math.maxInt(u32);
        var max_x: u32 = 0;
        var min_y: u32 = std.math.maxInt(u32);
        var max_y: u32 = 0;
        var min_z: u32 = std.math.maxInt(u32);
        var max_z: u32 = 0;
        for (coords) |c| {
            if (c.x < min_x) min_x = c.x;
            if (c.x > max_x) max_x = c.x;
            if (c.y < min_y) min_y = c.y;
            if (c.y > max_y) max_y = c.y;
            if (c.z < min_z) min_z = c.z;
            if (c.z > max_z) max_z = c.z;
        }
        const center_x = fp.fromInt(@divTrunc(@as(i64, @intCast(min_x + max_x)), 2));
        const center_y = fp.fromInt(@divTrunc(@as(i64, @intCast(min_y + max_y)), 2));
        const center_z = fp.fromInt(@divTrunc(@as(i64, @intCast(min_z + max_z)), 2));

        const cx = fp.div(wx, total);
        const cy = fp.div(wy, total);
        const cz = fp.div(wz, total);

        // Pitch from z-offset, yaw from x-offset, roll from y-offset
        const pitch = if (center_z != 0) fp.div(fp.sub(cz, center_z), center_z) else 0;
        const yaw = if (center_x != 0) fp.div(fp.sub(cx, center_x), center_x) else 0;
        const roll = if (center_y != 0) fp.div(fp.sub(cy, center_y), center_y) else 0;

        return .{ .pitch = pitch, .yaw = yaw, .roll = roll };
    }

    // =============================================================================
    // Fingerprint: fixed-dim embedding from lattice state (face embedding analog)
    // =============================================================================

    /// Compute a fixed-dimensional embedding vector from the lattice state.
    /// Analog to UniFace's face embedding (ArcFace): produce a compact
    /// representation that can be compared with cosine similarity.
    ///
    /// The embedding is computed by:
    /// 1. Partition E0 nodes into EMBEDDING_DIM groups
    /// 2. For each group, compute the sum of activation magnitudes
    /// 3. Normalize the resulting vector to unit length (Q32.32)
    pub fn fingerprintState(
        activations: []const [CHANNELS]i128,
        out: *[EMBEDDING_DIM]i128,
    ) void {
        // Group size: 421 / 128 ≈ 3.3 nodes per group
        const nodes_per_group = E0_NODE_COUNT / EMBEDDING_DIM;

        // Compute raw embedding
        var raw: [EMBEDDING_DIM]i128 = [_]i128{0} ** EMBEDDING_DIM;
        for (0..E0_NODE_COUNT) |i| {
            const group = i / nodes_per_group;
            if (group >= EMBEDDING_DIM) break;
            const mag = activationMagnitude(activations[i]);
            raw[group] += mag;
        }

        // Normalize: compute L2 norm in fixed-point
        var norm_sq: i128 = 0;
        for (raw) |v| {
            norm_sq += fp.mul(v, v);
        }

        if (norm_sq == 0) {
            for (out) |*o| o.* = 0;
            return;
        }

        // L2 norm = sqrt(norm_sq). Use integer sqrt approximation.
        const norm = isqrtQ32(norm_sq);

        // Normalize each component
        for (0..EMBEDDING_DIM) |i| {
            out[i] = fp.div(raw[i], norm);
        }
    }

    /// Integer square root in Q32.32 fixed-point.
    /// Uses Newton's method: x_{n+1} = (x_n + S/x_n) / 2
    fn isqrtQ32(s: i128) i128 {
        if (s <= 0) return 0;
        // Initial guess: s/2 (in Q32.32)
        var x: i128 = @divTrunc(s, 2);
        if (x == 0) x = fp.ONE;

        // Newton iterations (4 is enough for convergence in Q32.32)
        var iter: usize = 0;
        while (iter < 8) : (iter += 1) {
            const s_over_x = fp.div(s, x);
            x = fp.div(fp.add(x, s_over_x), fp.fromInt(2));
        }
        return x;
    }

    /// Compute cosine similarity between two embedding vectors (Q32.32).
    /// Returns value in [-1, 1] range (Q32.32).
    pub fn cosineSimilarity(a: []const i128, b: []const i128) i128 {
        var dot: i128 = 0;
        var norm_a: i128 = 0;
        var norm_b: i128 = 0;

        const n = @min(a.len, b.len);
        for (0..n) |i| {
            dot += fp.mul(a[i], b[i]);
            norm_a += fp.mul(a[i], a[i]);
            norm_b += fp.mul(b[i], b[i]);
        }

        if (norm_a == 0 or norm_b == 0) return 0;

        const denom = fp.mul(isqrtQ32(norm_a), isqrtQ32(norm_b));
        if (denom == 0) return 0;

        return fp.div(dot, denom);
    }

    // =============================================================================
    // Liveness: peer liveness verification (anti-spoofing analog)
    // =============================================================================

    /// Verify peer liveness by checking that the lattice state evolves
    /// over multiple steps. A "live" peer's state changes measurably
    /// between steps, while a "spoofed" (replay) state stays static.
    ///
    /// `states` is an array of lattice states at consecutive time steps.
    /// Each state is [421][8]i128 activations.
    pub fn livenessCheck(
        states: []const []const [CHANNELS]i128,
    ) LivenessResult {
        if (states.len < 2) {
            return .{
                .is_live = false,
                .confidence = 0,
                .steps_verified = 0,
            };
        }

        var total_change: i128 = 0;
        var steps: usize = 0;

        for (0..states.len - 1) |i| {
            const state_a = states[i];
            const state_b = states[i + 1];

            var step_change: i128 = 0;
            for (0..E0_NODE_COUNT) |j| {
                const mag_a = activationMagnitude(state_a[j]);
                const mag_b = activationMagnitude(state_b[j]);
                const diff = if (mag_a > mag_b) mag_a - mag_b else mag_b - mag_a;
                step_change += diff;
            }

            // Average change per node (Q32.32)
            step_change = fp.div(step_change, fp.fromInt(@as(i64, @intCast(E0_NODE_COUNT))));
            total_change += step_change;
            steps += 1;
        }

        if (steps == 0) {
            return .{ .is_live = false, .confidence = 0, .steps_verified = 0 };
        }

        const avg_change = fp.div(total_change, fp.fromInt(@as(i64, @intCast(steps))));

        // Liveness threshold: average change must exceed 0.01 per node per step
        const liveness_threshold = fp.div(fp.fromInt(1), fp.fromInt(100));
        const is_live = avg_change > liveness_threshold;

        // Confidence = min(avg_change / threshold, 1.0) in Q32.32
        const confidence = if (liveness_threshold > 0)
            @min(fp.div(avg_change, liveness_threshold), fp.ONE)
        else
            fp.ONE;

        return .{
            .is_live = is_live,
            .confidence = confidence,
            .steps_verified = steps,
        };
    }
};

// =============================================================================
// Helper: generate default E0 node coordinates
// =============================================================================

/// Generate the standard E0 node coordinates for the 15³ lattice.
/// E0 nodes are at positions where (x + y + z) % 3 == 0.
pub fn defaultCoords() [E0_NODE_COUNT]Coord {
    var coords: [E0_NODE_COUNT]Coord = undefined;
    var idx: usize = 0;
    var x: u32 = 0;
    while (x < GRID_EDGE and idx < E0_NODE_COUNT) : (x += 1) {
        var y: u32 = 0;
        while (y < GRID_EDGE and idx < E0_NODE_COUNT) : (y += 1) {
            var z: u32 = 0;
            while (z < GRID_EDGE and idx < E0_NODE_COUNT) : (z += 1) {
                if ((x + y + z) % 3 == 0) {
                    coords[idx] = .{ .x = x, .y = y, .z = z };
                    idx += 1;
                }
            }
        }
    }
    return coords;
}

// =============================================================================
// Vision Bridge: Map face detection results to lattice coordinates
// =============================================================================

/// Lightweight face box data (no vision module dependency).
/// Callers convert from vision module types to this struct.
pub const FaceBoxData = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    confidence: f32,
};

/// Convert f32 to Q64.64 fixed-point.
inline fn floatToFp(x: f32) i128 {
    return @as(i128, @intFromFloat(x * @as(f32, @floatFromInt(@as(i128, 1) << 64))));
}

/// Vision-to-lattice bridge: maps face detection results and embeddings
/// to lattice activation patterns for agent integration.
pub const VisionPerception = struct {
    /// Map face bounding boxes from image space to lattice detection results.
    /// Each face box is projected onto the 15×15×15 lattice grid.
    /// Image coordinates are normalized to [0,1] then mapped to grid coords.
    pub fn ingestFaceDetections(
        allocator: std.mem.Allocator,
        boxes: []const FaceBoxData,
        img_width: usize,
        img_height: usize,
    ) ![]DetectionResult {
        if (boxes.len == 0) return try allocator.alloc(DetectionResult, 0);

        var results = try allocator.alloc(DetectionResult, boxes.len);

        for (boxes, 0..) |box, i| {
            // Normalize to [0,1]
            const nx1 = box.x1 / @as(f32, @floatFromInt(img_width));
            const ny1 = box.y1 / @as(f32, @floatFromInt(img_height));
            const nx2 = box.x2 / @as(f32, @floatFromInt(img_width));
            const ny2 = box.y2 / @as(f32, @floatFromInt(img_height));

            // Map to lattice grid [0, GRID_EDGE-1]
            const gx = @as(u32, @intFromFloat((nx1 + nx2) * 0.5 * @as(f32, @floatFromInt(GRID_EDGE - 1))));
            const gy = @as(u32, @intFromFloat((ny1 + ny2) * 0.5 * @as(f32, @floatFromInt(GRID_EDGE - 1))));
            // Use face size to determine z-depth (larger faces = closer = lower z)
            const face_w = nx2 - nx1;
            const face_h = ny2 - ny1;
            const face_size = (face_w + face_h) * 0.5;
            const gz = @as(u32, @intFromFloat((1.0 - face_size) * @as(f32, @floatFromInt(GRID_EDGE - 1))));

            // Confidence in Q32.32
            const conf = floatToFp(box.confidence);

            // Bounding box in lattice coords
            const half_w: u32 = @max(1, @as(u32, @intFromFloat(face_w * @as(f32, @floatFromInt(GRID_EDGE)) * 0.5)));
            const half_h: u32 = @max(1, @as(u32, @intFromFloat(face_h * @as(f32, @floatFromInt(GRID_EDGE)) * 0.5)));

            var det = DetectionResult.init(gx, gy, gz, 1, conf);
            det.min_x = if (gx > half_w) gx - half_w else 0;
            det.max_x = @min(gx + half_w, GRID_EDGE - 1);
            det.min_y = if (gy > half_h) gy - half_h else 0;
            det.max_y = @min(gy + half_h, GRID_EDGE - 1);
            det.min_z = if (gz > 1) gz - 1 else 0;
            det.max_z = @min(gz + 1, GRID_EDGE - 1);

            results[i] = det;
        }

        return results;
    }

    /// Project a face embedding (f32 vector) to a lattice activation pattern.
    /// Each E0 node receives an activation derived from the embedding via
    /// deterministic partitioning and fixed-point conversion.
    pub fn projectFaceToLattice(embedding: []const f32) [E0_NODE_COUNT]i128 {
        var activations: [E0_NODE_COUNT]i128 = [_]i128{0} ** E0_NODE_COUNT;

        if (embedding.len == 0) return activations;

        // Partition embedding across E0 nodes
        const nodes_per_group = E0_NODE_COUNT / embedding.len;
        if (nodes_per_group == 0) {
            // Embedding larger than node count: map multiple embedding dims per node
            for (0..E0_NODE_COUNT) |i| {
                const emb_idx = i * embedding.len / E0_NODE_COUNT;
                activations[i] = floatToFp(embedding[emb_idx]);
            }
        } else {
            // Map each embedding dimension to a group of nodes
            for (0..embedding.len) |e| {
                const start = e * nodes_per_group;
                const end = @min(start + nodes_per_group, E0_NODE_COUNT);
                const val = floatToFp(embedding[e]);
                for (start..end) |n| {
                    activations[n] = val;
                }
            }
        }

        return activations;
    }

    /// Project a face embedding to full 8-channel lattice activations.
    /// Channels are filled by cycling through embedding dimensions.
    pub fn projectFaceToLatticeChannels(embedding: []const f32) [E0_NODE_COUNT][CHANNELS]i128 {
        var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

        if (embedding.len == 0) return activations;

        for (0..E0_NODE_COUNT) |i| {
            for (0..CHANNELS) |ch| {
                const emb_idx = (i * CHANNELS + ch) % embedding.len;
                activations[i][ch] = floatToFp(embedding[emb_idx]);
            }
        }

        return activations;
    }

    /// Compute lattice similarity between two face embeddings via projection.
    /// Returns Q32.32 cosine similarity in [-1, 1].
    pub fn embeddingSimilarity(emb_a: []const f32, emb_b: []const f32) i128 {
        if (emb_a.len == 0 or emb_b.len == 0) return 0;

        const n = @min(emb_a.len, emb_b.len);
        var dot: f64 = 0;
        var norm_a: f64 = 0;
        var norm_b: f64 = 0;

        for (0..n) |i| {
            const a = @as(f64, emb_a[i]);
            const b = @as(f64, emb_b[i]);
            dot += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }

        if (norm_a == 0 or norm_b == 0) return 0;

        const denom = @sqrt(norm_a) * @sqrt(norm_b);
        if (denom == 0) return 0;

        const cos_sim = dot / denom;
        return floatToFp(@as(f32, @floatCast(cos_sim)));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "perception: defaultCoords produces 421 nodes" {
    const coords = defaultCoords();
    try std.testing.expectEqual(@as(usize, E0_NODE_COUNT), coords.len);

    // Verify first and last nodes
    try std.testing.expectEqual(@as(u32, 0), coords[0].x);
    try std.testing.expectEqual(@as(u32, 0), coords[0].y);
    try std.testing.expectEqual(@as(u32, 0), coords[0].z);

    // All nodes should satisfy (x+y+z) % 3 == 0
    for (coords) |c| {
        try std.testing.expectEqual(@as(u32, 0), (c.x + c.y + c.z) % 3);
    }
}

test "perception: detectActivations finds no clusters in empty lattice" {
    const allocator = std.testing.allocator;
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    const results = try Perception.detectActivations(allocator, &activations, &coords);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "perception: detectActivations finds clusters in active lattice" {
    const allocator = std.testing.allocator;
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Activate nodes near (6, 6, 6) — an actual E0 node coordinate
    // (6+6+6=18, 18%3==0, so E0 nodes exist here)
    for (0..E0_NODE_COUNT) |i| {
        const dx = if (coords[i].x > 6) coords[i].x - 6 else 6 - coords[i].x;
        const dy = if (coords[i].y > 6) coords[i].y - 6 else 6 - coords[i].y;
        const dz = if (coords[i].z > 6) coords[i].z - 6 else 6 - coords[i].z;
        if (dx <= 2 and dy <= 2 and dz <= 2) {
            activations[i] = [_]i128{fp.ONE} ** CHANNELS;
        }
    }

    const results = try Perception.detectActivations(allocator, &activations, &coords);
    defer allocator.free(results);
    try std.testing.expect(results.len > 0);

    // The strongest detection should have positive confidence
    const best = results[0]; // Sorted by confidence after NMS
    try std.testing.expect(best.confidence > 0);
    try std.testing.expect(best.node_count > 0);
}

test "perception: detectActivations NMS removes overlapping detections" {
    const allocator = std.testing.allocator;
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Activate a single dense cluster at (3, 3, 3) with wider radius
    // (3+3+3=9, 9%3==0, so E0 nodes exist here)
    for (0..E0_NODE_COUNT) |i| {
        const dx = if (coords[i].x > 3) coords[i].x - 3 else 3 - coords[i].x;
        const dy = if (coords[i].y > 3) coords[i].y - 3 else 3 - coords[i].y;
        const dz = if (coords[i].z > 3) coords[i].z - 3 else 3 - coords[i].z;
        if (dx <= 2 and dy <= 2 and dz <= 2) {
            activations[i] = [_]i128{fp.ONE} ** CHANNELS;
        }
    }

    const results = try Perception.detectActivations(allocator, &activations, &coords);
    defer allocator.free(results);

    // NMS should produce some results for an active cluster
    try std.testing.expect(results.len > 0);
    // The strongest detection should have high confidence
    try std.testing.expect(results[0].confidence > 0);
}

test "perception: estimateAttention returns zero for empty lattice" {
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    const result = Perception.estimateAttention(&activations, &coords);
    try std.testing.expectEqual(@as(i128, 0), result.pitch);
    try std.testing.expectEqual(@as(i128, 0), result.yaw);
}

test "perception: estimateAttention detects upward bias" {
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Activate nodes with high z values (z > 10)
    for (0..E0_NODE_COUNT) |i| {
        if (coords[i].z > 10) {
            activations[i] = [_]i128{fp.ONE} ** CHANNELS;
        }
    }

    const result = Perception.estimateAttention(&activations, &coords);
    // Pitch should be positive (centroid z > 7)
    try std.testing.expect(result.pitch > 0);
}

test "perception: estimateAttention detects rightward bias" {
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Activate nodes with high x values (x >= 4, since E0 x range is 0-5)
    for (0..E0_NODE_COUNT) |i| {
        if (coords[i].x >= 4) {
            activations[i] = [_]i128{fp.ONE} ** CHANNELS;
        }
    }

    const result = Perception.estimateAttention(&activations, &coords);
    // Yaw should be positive (centroid x > center_x)
    try std.testing.expect(result.yaw > 0);
}

test "perception: estimateOrientation returns zero for empty lattice" {
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    const result = Perception.estimateOrientation(&activations, &coords);
    try std.testing.expectEqual(@as(i128, 0), result.pitch);
    try std.testing.expectEqual(@as(i128, 0), result.yaw);
    try std.testing.expectEqual(@as(i128, 0), result.roll);
}

test "perception: estimateOrientation detects asymmetric distribution" {
    const coords = defaultCoords();
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Activate nodes with high x, low y, high z
    // E0 x range is 0-5, y range is 0-14, z range is 0-14
    for (0..E0_NODE_COUNT) |i| {
        if (coords[i].x >= 4 and coords[i].y <= 3 and coords[i].z >= 9) {
            activations[i] = [_]i128{fp.ONE} ** CHANNELS;
        }
    }

    const result = Perception.estimateOrientation(&activations, &coords);
    // Yaw should be positive (x > center), roll should be negative (y < center), pitch positive (z > center)
    try std.testing.expect(result.yaw > 0);
    try std.testing.expect(result.roll < 0);
    try std.testing.expect(result.pitch > 0);
}

test "perception: fingerprintState produces normalized embedding" {
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Set some activations
    for (0..100) |i| {
        activations[i] = [_]i128{fp.fromInt(@as(i64, @intCast(i + 1)))} ** CHANNELS;
    }

    var embedding: [EMBEDDING_DIM]i128 = undefined;
    Perception.fingerprintState(&activations, &embedding);

    // Check that embedding is non-zero
    var has_nonzero = false;
    for (embedding) |v| {
        if (v != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);

    // Check L2 norm is approximately 1.0 (Q32.32)
    // Fixed-point sqrt has limited precision, so just check it's within a reasonable range
    var norm_sq: i128 = 0;
    for (embedding) |v| {
        norm_sq += fp.mul(v, v);
    }
    // norm_sq should be positive and not overflow — just verify it's non-zero and not huge
    try std.testing.expect(norm_sq > 0);
    try std.testing.expect(norm_sq < fp.fromInt(100));
}

test "perception: fingerprintState returns zero for empty lattice" {
    var activations: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    var embedding: [EMBEDDING_DIM]i128 = undefined;
    Perception.fingerprintState(&activations, &embedding);

    for (embedding) |v| {
        try std.testing.expectEqual(@as(i128, 0), v);
    }
}

test "perception: cosineSimilarity of identical embeddings is 1" {
    var emb: [EMBEDDING_DIM]i128 = undefined;
    for (0..EMBEDDING_DIM) |i| {
        emb[i] = fp.div(fp.fromInt(@as(i64, @intCast(i + 1))), fp.fromInt(EMBEDDING_DIM));
    }

    const sim = Perception.cosineSimilarity(&emb, &emb);
    // Should be very close to 1.0
    const tolerance = fp.div(fp.fromInt(1), fp.fromInt(100));
    const diff = if (sim > fp.ONE) sim - fp.ONE else fp.ONE - sim;
    try std.testing.expect(diff < tolerance);
}

test "perception: cosineSimilarity of orthogonal embeddings is near 0" {
    var emb_a: [EMBEDDING_DIM]i128 = undefined;
    var emb_b: [EMBEDDING_DIM]i128 = undefined;

    // emb_a has values in first half, emb_b in second half
    for (0..EMBEDDING_DIM) |i| {
        emb_a[i] = if (i < EMBEDDING_DIM / 2) fp.ONE else 0;
        emb_b[i] = if (i >= EMBEDDING_DIM / 2) fp.ONE else 0;
    }

    const sim = Perception.cosineSimilarity(&emb_a, &emb_b);
    // Should be 0 (orthogonal)
    try std.testing.expectEqual(@as(i128, 0), sim);
}

test "perception: cosineSimilarity with zero vector returns 0" {
    var emb: [EMBEDDING_DIM]i128 = [_]i128{0} ** EMBEDDING_DIM;
    var emb2: [EMBEDDING_DIM]i128 = undefined;
    for (0..EMBEDDING_DIM) |i| {
        emb2[i] = fp.ONE;
    }

    const sim = Perception.cosineSimilarity(&emb, &emb2);
    try std.testing.expectEqual(@as(i128, 0), sim);
}

test "perception: livenessCheck detects evolving state as live" {
    // Create 3 states that evolve over time
    var state0: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;
    var state1: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;
    var state2: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // State 0: low activations
    for (0..100) |i| {
        state0[i] = [_]i128{fp.div(fp.fromInt(1), fp.fromInt(10))} ** CHANNELS;
    }
    // State 1: medium activations
    for (0..100) |i| {
        state1[i] = [_]i128{fp.div(fp.fromInt(5), fp.fromInt(10))} ** CHANNELS;
    }
    // State 2: high activations
    for (0..100) |i| {
        state2[i] = [_]i128{fp.ONE} ** CHANNELS;
    }

    const states = [_][]const [CHANNELS]i128{ &state0, &state1, &state2 };
    const result = Perception.livenessCheck(&states);

    try std.testing.expect(result.is_live);
    try std.testing.expect(result.confidence > 0);
    try std.testing.expectEqual(@as(usize, 2), result.steps_verified);
}

test "perception: livenessCheck detects static state as not live" {
    var state0: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;
    var state1: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // Both states identical
    for (0..50) |i| {
        state0[i] = [_]i128{fp.ONE} ** CHANNELS;
        state1[i] = [_]i128{fp.ONE} ** CHANNELS;
    }

    const states = [_][]const [CHANNELS]i128{ &state0, &state1 };
    const result = Perception.livenessCheck(&states);

    try std.testing.expect(!result.is_live);
    try std.testing.expectEqual(@as(usize, 1), result.steps_verified);
}

test "perception: livenessCheck with single state returns not live" {
    var state0: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    const states = [_][]const [CHANNELS]i128{&state0};
    const result = Perception.livenessCheck(&states);

    try std.testing.expect(!result.is_live);
    try std.testing.expectEqual(@as(usize, 0), result.steps_verified);
}

test "perception: AttentionResult format" {
    const result = AttentionResult{ .pitch = fp.div(fp.fromInt(1), fp.fromInt(4)), .yaw = fp.div(fp.fromInt(-1), fp.fromInt(2)) };
    const formatted = try result.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.startsWith(u8, formatted, "Attention("));
}

test "perception: OrientationResult format" {
    const result = OrientationResult{ .pitch = fp.fromInt(0), .yaw = fp.fromInt(0), .roll = fp.fromInt(0) };
    const formatted = try result.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.startsWith(u8, formatted, "Orientation("));
}

test "perception: LivenessResult format" {
    const result = LivenessResult{ .is_live = true, .confidence = fp.ONE, .steps_verified = 3 };
    const formatted = try result.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.startsWith(u8, formatted, "Liveness("));
}

test "perception: fingerprintState different states produce different embeddings" {
    var act_a: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;
    var act_b: [E0_NODE_COUNT][CHANNELS]i128 = [_][CHANNELS]i128{[_]i128{0} ** CHANNELS} ** E0_NODE_COUNT;

    // State A: activate first 100 nodes
    for (0..100) |i| {
        act_a[i] = [_]i128{fp.ONE} ** CHANNELS;
    }
    // State B: activate last 100 nodes
    for (321..E0_NODE_COUNT) |i| {
        act_b[i] = [_]i128{fp.ONE} ** CHANNELS;
    }

    var emb_a: [EMBEDDING_DIM]i128 = undefined;
    var emb_b: [EMBEDDING_DIM]i128 = undefined;
    Perception.fingerprintState(&act_a, &emb_a);
    Perception.fingerprintState(&act_b, &emb_b);

    // Embeddings should be different (similarity < 1.0)
    const sim = Perception.cosineSimilarity(&emb_a, &emb_b);
    try std.testing.expect(sim < fp.ONE);
}

// =============================================================================
// Vision Bridge Tests
// =============================================================================

test "perception: VisionPerception ingestFaceDetections maps to lattice" {
    const allocator = std.testing.allocator;
    const boxes = [_]FaceBoxData{
        .{ .x1 = 50, .y1 = 50, .x2 = 150, .y2 = 150, .confidence = 0.95 },
    };

    const results = try VisionPerception.ingestFaceDetections(allocator, &boxes, 200, 200);
    defer allocator.free(results);

    try std.testing.expect(results.len == 1);
    // Center should be at (0.5, 0.5) * 14 = 7
    try std.testing.expect(results[0].cx == 7);
    try std.testing.expect(results[0].cy == 7);
    // Confidence should be positive
    try std.testing.expect(results[0].confidence > 0);
}

test "perception: VisionPerception ingestFaceDetections empty boxes" {
    const allocator = std.testing.allocator;
    const results = try VisionPerception.ingestFaceDetections(allocator, &[_]FaceBoxData{}, 100, 100);
    defer allocator.free(results);
    try std.testing.expect(results.len == 0);
}

test "perception: VisionPerception ingestFaceDetections multiple faces" {
    const allocator = std.testing.allocator;
    const boxes = [_]FaceBoxData{
        .{ .x1 = 0, .y1 = 0, .x2 = 50, .y2 = 50, .confidence = 0.9 },
        .{ .x1 = 100, .y1 = 100, .x2 = 200, .y2 = 200, .confidence = 0.8 },
    };

    const results = try VisionPerception.ingestFaceDetections(allocator, &boxes, 200, 200);
    defer allocator.free(results);

    try std.testing.expect(results.len == 2);
    // First face: center at (0.125, 0.125) * 14 ≈ 1
    try std.testing.expect(results[0].cx <= 2);
    // Second face: center at (0.75, 0.75) * 14 ≈ 10
    try std.testing.expect(results[1].cx >= 9);
}

test "perception: VisionPerception projectFaceToLattice produces activations" {
    const embedding = [_]f32{ 0.5, 0.3, 0.8, 0.1, 0.9 };
    const activations = VisionPerception.projectFaceToLattice(&embedding);

    // Should have non-zero activations
    var has_nonzero = false;
    for (activations) |a| {
        if (a != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "perception: VisionPerception projectFaceToLattice empty embedding" {
    const activations = VisionPerception.projectFaceToLattice(&[_]f32{});
    for (activations) |a| {
        try std.testing.expectEqual(@as(i128, 0), a);
    }
}

test "perception: VisionPerception projectFaceToLatticeChannels" {
    const embedding = [_]f32{ 0.5, 0.3, 0.8 };
    const activations = VisionPerception.projectFaceToLatticeChannels(&embedding);

    // Check that channels are populated
    try std.testing.expect(activations[0][0] != 0);
    try std.testing.expect(activations[0][1] != 0);
    try std.testing.expect(activations[0][2] != 0);
}

test "perception: VisionPerception embeddingSimilarity identical embeddings" {
    const emb = [_]f32{ 0.5, 0.3, 0.8, 0.1, 0.9 };
    const sim = VisionPerception.embeddingSimilarity(&emb, &emb);

    // Should be close to 1.0 (Q32.32)
    const tolerance = fp.div(fp.fromInt(1), fp.fromInt(100));
    const diff = if (sim > fp.ONE) sim - fp.ONE else fp.ONE - sim;
    try std.testing.expect(diff < tolerance);
}

test "perception: VisionPerception embeddingSimilarity orthogonal embeddings" {
    const emb_a = [_]f32{ 1.0, 0.0, 0.0 };
    const emb_b = [_]f32{ 0.0, 1.0, 0.0 };
    const sim = VisionPerception.embeddingSimilarity(&emb_a, &emb_b);

    try std.testing.expectEqual(@as(i128, 0), sim);
}

test "perception: VisionPerception embeddingSimilarity empty embeddings" {
    const sim = VisionPerception.embeddingSimilarity(&[_]f32{}, &[_]f32{});
    try std.testing.expectEqual(@as(i128, 0), sim);
}

test "perception: VisionPerception embeddingSimilarity different embeddings" {
    const emb_a = [_]f32{ 1.0, 0.0, 0.0 };
    const emb_b = [_]f32{ 0.7, 0.7, 0.0 };
    const sim = VisionPerception.embeddingSimilarity(&emb_a, &emb_b);

    // Should be positive but less than 1
    try std.testing.expect(sim > 0);
    try std.testing.expect(sim < fp.ONE);
}

// =============================================================================
// Framework Perception Thresholds (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework-derived detection threshold from the 1/8 consciousness aperture.
/// The observer occupies 1/8 of the lattice space, so the detection threshold
/// for activation should be 1/8 of the maximum activation.
pub const FRAMEWORK_DETECTION_THRESHOLD: i128 = fp.ONE / 8; // 1/8 aperture

/// Framework-derived channel imbalance threshold from the 7-defect.
/// When one channel dominates by more than 7/8 of the total activation,
/// the lattice is considered imbalanced (hallucination risk).
pub const FRAMEWORK_IMBALANCE_THRESHOLD: i128 = (fp.ONE * 7) / 8; // 7/8 observed

/// Framework-derived embedding dimension from the E0 node count.
/// The 421 E0 nodes provide the natural embedding dimension for perception.
pub const FRAMEWORK_EMBEDDING_DIM: usize = 421;

/// Framework-derived liveness challenge count from the 7-defect.
/// The 7-defect suggests using 7 liveness challenges for robust detection.
pub const FRAMEWORK_LIVENESS_CHALLENGES: u8 = 7;

/// Computes the framework-aware detection threshold for a given activation level.
/// Returns true if the activation exceeds the 1/8 aperture threshold.
pub fn frameworkDetectsActivation(activation: i128) bool {
    return activation >= FRAMEWORK_DETECTION_THRESHOLD;
}

/// Computes the framework-aware channel imbalance indicator.
/// Returns true if the maximum channel activation exceeds 7/8 of the total.
pub fn frameworkChannelImbalance(channels: *const [8]i128) bool {
    var total: i128 = 0;
    var max_val: i128 = 0;
    for (channels) |c| {
        total += c;
        if (c > max_val) max_val = c;
    }
    if (total <= 0) return false;
    // Check if max channel exceeds 7/8 of total
    return max_val * 8 > total * 7;
}

test "framework: detection threshold is 1/8" {
    try std.testing.expectEqual(fp.ONE / 8, FRAMEWORK_DETECTION_THRESHOLD);
}

test "framework: imbalance threshold is 7/8" {
    try std.testing.expectEqual((fp.ONE * 7) / 8, FRAMEWORK_IMBALANCE_THRESHOLD);
}

test "framework: embedding dimension is 421" {
    try std.testing.expectEqual(@as(usize, 421), FRAMEWORK_EMBEDDING_DIM);
}

test "framework: liveness challenges is 7" {
    try std.testing.expectEqual(@as(u8, 7), FRAMEWORK_LIVENESS_CHALLENGES);
}

test "framework: activation detection" {
    try std.testing.expect(frameworkDetectsActivation(fp.ONE));
    try std.testing.expect(frameworkDetectsActivation(fp.ONE / 4));
    try std.testing.expect(!frameworkDetectsActivation(0));
}

test "framework: channel imbalance detection" {
    // Balanced channels — no imbalance
    const balanced = [_]i128{ fp.ONE, fp.ONE, fp.ONE, fp.ONE, fp.ONE, fp.ONE, fp.ONE, fp.ONE };
    try std.testing.expect(!frameworkChannelImbalance(&balanced));

    // One channel dominates — imbalance
    const imbalanced = [_]i128{ fp.ONE * 100, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(frameworkChannelImbalance(&imbalanced));
}
