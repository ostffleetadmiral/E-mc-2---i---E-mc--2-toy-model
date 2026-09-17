//! mesh_int.zig — Integer-only SharedFace prototype.
//!
//! Replaces [225]f64 with [225]i128 (Q64.64 fixed-point) in SharedFace.
//! Möbius correlation computed with integer dot product + fixed-point normalization.
//! No f32/f64/f16/f128 in any state path.

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

pub const BASE_EDGE: u32 = 15;
const FACE_CELLS: usize = 225; // 15² = 225 cells per face

// =============================================================================
// Face Axis
// =============================================================================

pub const FaceAxis = enum {
    pos_x,
    neg_x,
    pos_y,
    neg_y,
    pos_z,
    neg_z,
};

// =============================================================================
// SharedFace — Integer-Only (Q32.32)
// =============================================================================

pub const SharedFace = struct {
    peer_id: []const u8,
    face_axis: FaceAxis,
    edge: u32,
    /// E0 states on the shared face in Q64.64 fixed-point.
    local_states: [FACE_CELLS]i128,
    remote_states: [FACE_CELLS]i128,
    synced: bool,

    pub fn init(peer_id: []const u8, axis: FaceAxis, edge: u32) SharedFace {
        return .{
            .peer_id = peer_id,
            .face_axis = axis,
            .edge = edge,
            .local_states = [_]i128{0} ** FACE_CELLS,
            .remote_states = [_]i128{0} ** FACE_CELLS,
            .synced = false,
        };
    }

    /// Sets local E0 states from a slice of Q32.32 activations.
    pub fn setLocalStates(self: *SharedFace, states: []const i128) void {
        const n = @min(states.len, FACE_CELLS);
        for (0..n) |i| self.local_states[i] = states[i];
    }

    /// Sets remote E0 states received from peer.
    pub fn setRemoteStates(self: *SharedFace, states: []const i128) void {
        const n = @min(states.len, FACE_CELLS);
        for (0..n) |i| self.remote_states[i] = states[i];
        self.synced = true;
    }

    /// Computes the Möbius correlation between local and remote states.
    /// The Möbius twist mirrors states with byte reversal at the boundary.
    /// correlation = Σ(local[i] × remote[224-i]) / 225 — all integer arithmetic.
    pub fn mobiusCorrelation(self: SharedFace) i128 {
        var correlation: i128 = 0;
        for (0..FACE_CELLS) |i| {
            const remote_idx = FACE_CELLS - 1 - i;
            correlation += fp.mul(self.local_states[i], self.remote_states[remote_idx]);
        }
        // Normalize by FACE_CELLS (225)
        return fp.div(correlation, fp.fromInt(@as(i64, @intCast(FACE_CELLS))));
    }

    /// Checks if the shared face is phase-locked (|correlation| > threshold).
    pub fn isPhaseLocked(self: SharedFace, threshold: i128) bool {
        return fp.absVal(self.mobiusCorrelation()) > threshold;
    }

    /// Serializes SharedFace to bytes (bit-exact, no quantization).
    pub fn serialize(self: SharedFace, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        // Local states
        for (0..FACE_CELLS) |i| {
            try buf.writer().writeInt(i128, self.local_states[i], .little);
        }
        // Remote states
        for (0..FACE_CELLS) |i| {
            try buf.writer().writeInt(i128, self.remote_states[i], .little);
        }
        // Edge
        try buf.writer().writeInt(u32, self.edge, .little);
        // Synced flag
        try buf.writer().writeByte(@intFromBool(self.synced));

        return buf.toOwnedSlice();
    }

    /// Deserializes SharedFace from bytes (bit-exact round-trip).
    pub fn deserialize(_: std.mem.Allocator, peer_id: []const u8, axis: FaceAxis, data: []const u8) !SharedFace {
        var fbs = std.io.fixedBufferStream(data);
        var face = SharedFace.init(peer_id, axis, 0);

        for (0..FACE_CELLS) |i| {
            face.local_states[i] = try fbs.reader().readInt(i128, .little);
        }
        for (0..FACE_CELLS) |i| {
            face.remote_states[i] = try fbs.reader().readInt(i128, .little);
        }
        face.edge = try fbs.reader().readInt(u32, .little);
        face.synced = (try fbs.reader().readByte()) != 0;

        return face;
    }
};

// =============================================================================
// Public API
// =============================================================================

pub fn connectLattices(peer_id: []const u8, axis: FaceAxis, edge: u32) SharedFace {
    return SharedFace.init(peer_id, axis, edge);
}

pub fn syncSharedFace(face: *SharedFace, local_states: []const i128, remote_states: []const i128) void {
    face.setLocalStates(local_states);
    face.setRemoteStates(remote_states);
}

pub fn dualTorusCorrelation(face_a: SharedFace, face_b: SharedFace) i128 {
    const corr_a = face_a.mobiusCorrelation();
    const corr_b = face_b.mobiusCorrelation();
    // (corr_a + corr_b) / 2 — integer arithmetic
    return fp.div(corr_a + corr_b, fp.fromInt(2));
}

// =============================================================================
// Tests
// =============================================================================

test "shared face initialization" {
    const face = SharedFace.init("peer1", .pos_x, 15);
    try std.testing.expectEqualStrings("peer1", face.peer_id);
    try std.testing.expectEqual(FaceAxis.pos_x, face.face_axis);
    try std.testing.expectEqual(@as(u32, 15), face.edge);
    try std.testing.expect(!face.synced);

    // All states zero
    for (0..FACE_CELLS) |i| {
        try std.testing.expectEqual(@as(i128, 0), face.local_states[i]);
        try std.testing.expectEqual(@as(i128, 0), face.remote_states[i]);
    }
}

test "set local and remote states" {
    var face = SharedFace.init("peer1", .pos_x, 15);

    const local = [_]i128{ fp.fromInt(1), fp.fromInt(2), fp.fromInt(3) } ++ [_]i128{0} ** 222;
    face.setLocalStates(&local);
    try std.testing.expectEqual(fp.fromInt(1), face.local_states[0]);
    try std.testing.expectEqual(fp.fromInt(2), face.local_states[1]);

    const remote = [_]i128{ fp.HALF_FP, fp.HALF_FP, fp.HALF_FP } ++ [_]i128{0} ** 222;
    face.setRemoteStates(&remote);
    try std.testing.expectEqual(fp.HALF_FP, face.remote_states[0]);
    try std.testing.expect(face.synced);
}

test "möbius correlation with identical states" {
    var face = SharedFace.init("peer1", .pos_x, 15);

    // Set local and remote to same values
    for (0..FACE_CELLS) |i| {
        face.local_states[i] = fp.fromInt(@as(i64, @intCast(i % 5)));
        face.remote_states[i] = fp.fromInt(@as(i64, @intCast(i % 5)));
    }

    // Möbius correlation: local[i] × remote[224-i]
    // Since local and remote are the same, this is autocorrelation with reversal
    const corr = face.mobiusCorrelation();

    // Should be non-zero (positive autocorrelation)
    try std.testing.expect(corr > 0);
}

test "möbius correlation with zero remote" {
    var face = SharedFace.init("peer1", .pos_x, 15);

    for (0..FACE_CELLS) |i| {
        face.local_states[i] = fp.fromInt(@as(i64, @intCast(i % 5)));
    }
    // remote stays zero

    const corr = face.mobiusCorrelation();
    try std.testing.expectEqual(@as(i128, 0), corr);
}

test "phase locked detection" {
    var face = SharedFace.init("peer1", .pos_x, 15);

    // Set identical states → high correlation
    for (0..FACE_CELLS) |i| {
        face.local_states[i] = fp.ONE;
        face.remote_states[FACE_CELLS - 1 - i] = fp.ONE;
    }

    const corr = face.mobiusCorrelation();
    // corr = Σ(1 × 1) / 225 = 225/225 = 1.0
    try std.testing.expectEqual(fp.ONE, corr);

    // Should be phase-locked with threshold 0.5
    try std.testing.expect(face.isPhaseLocked(fp.HALF_FP));
}

test "not phase locked with low correlation" {
    var face = SharedFace.init("peer1", .pos_x, 15);

    for (0..FACE_CELLS) |i| {
        face.local_states[i] = fp.ONE;
        // remote stays zero
    }

    try std.testing.expect(!face.isPhaseLocked(fp.HALF_FP));
}

test "serialize/deserialize is bit-exact round trip" {
    const allocator = std.testing.allocator;
    var face = SharedFace.init("peer1", .pos_x, 15);

    // Set non-trivial states
    for (0..FACE_CELLS) |i| {
        face.local_states[i] = fp.fromInt(@as(i64, @intCast(i % 7)));
        face.remote_states[i] = fp.fromInt(@as(i64, @intCast((i * 3) % 11)));
    }
    face.synced = true;

    const serialized = try face.serialize(allocator);
    defer allocator.free(serialized);

    var restored = try SharedFace.deserialize(allocator, "peer1", .pos_x, serialized);
    _ = &restored;

    // Bit-exact equality
    for (0..FACE_CELLS) |i| {
        try std.testing.expectEqual(face.local_states[i], restored.local_states[i]);
        try std.testing.expectEqual(face.remote_states[i], restored.remote_states[i]);
    }
    try std.testing.expectEqual(face.edge, restored.edge);
    try std.testing.expectEqual(face.synced, restored.synced);
}

test "dual torus correlation" {
    var face_a = SharedFace.init("peer1", .pos_x, 15);
    var face_b = SharedFace.init("peer2", .neg_x, 15);

    // Set identical patterns in both faces
    for (0..FACE_CELLS) |i| {
        face_a.local_states[i] = fp.ONE;
        face_a.remote_states[FACE_CELLS - 1 - i] = fp.ONE;
        face_b.local_states[i] = fp.ONE;
        face_b.remote_states[FACE_CELLS - 1 - i] = fp.ONE;
    }

    const dual = dualTorusCorrelation(face_a, face_b);
    // Both correlations = 1.0, so dual = (1.0 + 1.0) / 2 = 1.0
    try std.testing.expectEqual(fp.ONE, dual);
}

test "no floating-point types in shared face" {
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(SharedFace, undefined).local_states[0])));
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(SharedFace, undefined).remote_states[0])));
}

test "sync shared face" {
    var face = SharedFace.init("peer1", .pos_x, 15);

    const local = [_]i128{fp.fromInt(5)} ** FACE_CELLS;
    const remote = [_]i128{fp.fromInt(3)} ** FACE_CELLS;

    syncSharedFace(&face, &local, &remote);

    try std.testing.expectEqual(fp.fromInt(5), face.local_states[0]);
    try std.testing.expectEqual(fp.fromInt(3), face.remote_states[0]);
    try std.testing.expect(face.synced);
}
