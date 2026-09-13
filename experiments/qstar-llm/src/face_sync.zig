//! FaceSync — SharedFace struct for lattice-to-lattice peer synchronization.
//!
//! Extracted from Qstar's mesh.zig to provide standalone agent face sync
//! without the full P2P connection management stack.
//! Zero external dependencies beyond std + fixed_point.

const std = @import("std");
const fp = @import("fixed_point");

pub const FaceAxis = enum {
    pos_x,
    neg_x,
    pos_y,
    neg_y,
    pos_z,
    neg_z,
};

/// A shared face between two connected lattices.
/// When two peers connect, their lattices align at a boundary face.
/// The Möbius twist at the boundary creates instant correlation.
/// All states are Q32.32 fixed-point i128 — no floating-point in core state.
pub const SharedFace = struct {
    peer_id: []const u8,
    face_axis: FaceAxis,
    edge: u32,
    /// E0 states on the shared face (15² = 225 cells per face) in Q32.32.
    local_states: [225]i128,
    remote_states: [225]i128,
    synced: bool,
    /// Previous local states for delta computation.
    prev_local_states: [225]i128 = [_]i128{0} ** 225,

    pub fn init(peer_id: []const u8, axis: FaceAxis, edge: u32) SharedFace {
        return .{
            .peer_id = peer_id,
            .face_axis = axis,
            .edge = edge,
            .local_states = [_]i128{0} ** 225,
            .remote_states = [_]i128{0} ** 225,
            .synced = false,
        };
    }

    /// Sets local E0 states from a slice of Q32.32 activations.
    pub fn setLocalStates(self: *SharedFace, states: []const i128) void {
        const n = @min(states.len, 225);
        @memcpy(self.prev_local_states[0..n], self.local_states[0..n]);
        for (0..n) |i| self.local_states[i] = states[i];
    }

    /// Sets remote E0 states received from peer.
    pub fn setRemoteStates(self: *SharedFace, states: []const i128) void {
        const n = @min(states.len, 225);
        for (0..n) |i| self.remote_states[i] = states[i];
        self.synced = true;
    }

    /// Computes delta: returns indices and values of changed local states.
    pub fn computeDelta(self: *const SharedFace, out_indices: []u8, out_values: []i128) usize {
        var count: usize = 0;
        for (0..225) |i| {
            if (self.local_states[i] != self.prev_local_states[i]) {
                if (count >= out_indices.len or count >= out_values.len) break;
                out_indices[count] = @intCast(i);
                out_values[count] = self.local_states[i];
                count += 1;
            }
        }
        return count;
    }

    /// Applies a delta received from a peer to remote_states.
    pub fn applyDelta(self: *SharedFace, indices: []const u8, values: []const i128) void {
        const n = @min(indices.len, values.len);
        for (0..n) |i| {
            const idx = indices[i];
            if (idx < 225) {
                self.remote_states[idx] = values[i];
            }
        }
        self.synced = true;
    }

    /// Serializes local states to a byte buffer (full 1800 bytes).
    pub fn serializeFull(self: *const SharedFace, out: []u8) usize {
        const size = 225 * @sizeOf(i128);
        if (out.len < size) return 0;
        for (0..225) |i| {
            const bytes = std.mem.asBytes(&self.local_states[i]);
            @memcpy(out[i * 16 .. i * 16 + 16], bytes);
        }
        return size;
    }

    /// Deserializes full states from a byte buffer.
    pub fn deserializeFull(self: *SharedFace, data: []const u8) void {
        const n = @min(data.len / 16, 225);
        for (0..n) |i| {
            var val: i128 = 0;
            @memcpy(std.mem.asBytes(&val), data[i * 16 .. i * 16 + 16]);
            self.remote_states[i] = val;
        }
        self.synced = true;
    }

    /// Computes the Möbius correlation between local and remote states.
    pub fn mobiusCorrelation(self: *const SharedFace) i128 {
        var correlation: i128 = 0;
        for (0..225) |i| {
            const remote_idx = 224 - i;
            correlation += fp.mul(self.local_states[i], self.remote_states[remote_idx]);
        }
        return fp.div(correlation, fp.fromInt(225));
    }

    /// Checks if the shared face is phase-locked (|correlation| > threshold).
    pub fn isPhaseLocked(self: *const SharedFace, threshold: i128) bool {
        return fp.absVal(self.mobiusCorrelation()) > threshold;
    }

    /// Couples local states toward remote states using the universal coupling constant g = 0.00388.
    pub fn coupleStates(self: *SharedFace, custom_rate: ?i128) void {
        const rate = custom_rate orelse fp.COUPLING_G;
        for (0..225) |i| {
            const remote_idx = 224 - i;
            const diff = self.remote_states[remote_idx] - self.local_states[i];
            const exchange = fp.mul(diff, rate);
            self.local_states[i] += exchange;
        }
    }
};

/// Computes quadrupole cross-correlation (0° Möbius + 90° transverse twist) between two shared faces.
pub fn quadrupoleCoupling(face_a: *const SharedFace, face_b: *const SharedFace) i128 {
    var t1_corr: i128 = 0;
    var t2_corr: i128 = 0;
    for (0..15) |y| {
        for (0..15) |x| {
            const idx_a = y * 15 + x;
            // T1 (anti-diagonal reflection: 14-x, 14-y)
            const idx_t1 = (14 - y) * 15 + (14 - x);
            // T2 (main-diagonal transpose: y, x)
            const idx_t2 = x * 15 + y;

            t1_corr += fp.mul(face_a.local_states[idx_a], face_b.remote_states[idx_t1]);
            t2_corr += fp.mul(face_a.local_states[idx_a], face_b.remote_states[idx_t2]);
        }
    }
    const avg_t1 = fp.div(t1_corr, fp.fromInt(225));
    const avg_t2 = fp.div(t2_corr, fp.fromInt(225));
    return fp.div(avg_t1 + avg_t2, fp.fromInt(2));
}

/// Creates a SharedFace for connecting two lattices.
pub fn connectLattices(peer_id: []const u8, axis: FaceAxis, edge: u32) SharedFace {
    return SharedFace.init(peer_id, axis, edge);
}

/// Syncs a SharedFace with local and remote state arrays.
pub fn syncSharedFace(face: *SharedFace, local_states: []const i128, remote_states: []const i128) void {
    face.setLocalStates(local_states);
    face.setRemoteStates(remote_states);
}

/// Computes correlation between two shared faces (dual-torus).
pub fn dualTorusCorrelation(face_a: *const SharedFace, face_b: *const SharedFace) i128 {
    var correlation: i128 = 0;
    for (0..225) |i| {
        correlation += fp.mul(face_a.local_states[i], face_b.remote_states[224 - i]);
    }
    return fp.div(correlation, fp.fromInt(225));
}

test "SharedFace initialization" {
    const face = SharedFace.init("peer-1", .pos_x, 15);
    try std.testing.expectEqualStrings("peer-1", face.peer_id);
    try std.testing.expectEqual(@as(u32, 15), face.edge);
    try std.testing.expect(!face.synced);
    for (0..225) |i| {
        try std.testing.expectEqual(@as(i128, 0), face.local_states[i]);
        try std.testing.expectEqual(@as(i128, 0), face.remote_states[i]);
    }
}

test "SharedFace setLocalStates copies and saves previous" {
    var face = SharedFace.init("peer-1", .pos_x, 15);
    var states: [225]i128 = undefined;
    for (0..225) |i| states[i] = @intCast(@as(i128, @intCast(i)) * 100);
    face.setLocalStates(&states);
    for (0..225) |i| {
        try std.testing.expectEqual(states[i], face.local_states[i]);
    }
    // Previous should still be zero (first set)
    for (0..225) |i| {
        try std.testing.expectEqual(@as(i128, 0), face.prev_local_states[i]);
    }
}

test "SharedFace setRemoteStates marks synced" {
    var face = SharedFace.init("peer-1", .pos_x, 15);
    var states: [225]i128 = undefined;
    for (0..225) |i| states[i] = @intCast(@as(i128, @intCast(i)) * 200);
    face.setRemoteStates(&states);
    try std.testing.expect(face.synced);
    for (0..225) |i| {
        try std.testing.expectEqual(states[i], face.remote_states[i]);
    }
}

test "SharedFace computeDelta detects changes" {
    var face = SharedFace.init("peer-1", .pos_x, 15);
    var states: [225]i128 = undefined;
    for (0..225) |i| states[i] = @intCast(@as(i128, @intCast(i)) * 100);
    face.setLocalStates(&states);

    // Change a few values
    states[0] = 999;
    states[10] = 888;
    states[224] = 777;
    face.setLocalStates(&states);

    var indices: [225]u8 = undefined;
    var values: [225]i128 = undefined;
    const count = face.computeDelta(&indices, &values);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(u8, 0), indices[0]);
    try std.testing.expectEqual(@as(i128, 999), values[0]);
    try std.testing.expectEqual(@as(u8, 10), indices[1]);
    try std.testing.expectEqual(@as(i128, 888), values[1]);
    try std.testing.expectEqual(@as(u8, 224), indices[2]);
    try std.testing.expectEqual(@as(i128, 777), values[2]);
}

test "SharedFace serialize/deserialize round-trip" {
    var face = SharedFace.init("peer-1", .pos_x, 15);
    for (0..225) |i| face.local_states[i] = @intCast(@as(i128, @intCast(i)) * 1000);

    var buf: [3600]u8 = undefined;
    const written = face.serializeFull(&buf);
    try std.testing.expectEqual(@as(usize, 3600), written);

    var face2 = SharedFace.init("peer-2", .neg_x, 15);
    face2.deserializeFull(&buf);
    try std.testing.expect(face2.synced);
    for (0..225) |i| {
        try std.testing.expectEqual(face.local_states[i], face2.remote_states[i]);
    }
}

test "SharedFace Möbius correlation with identical states" {
    var face = SharedFace.init("peer-1", .pos_x, 15);
    for (0..225) |i| {
        face.local_states[i] = fp.fromInt(100);
        face.remote_states[224 - i] = fp.fromInt(100);
    }
    const corr = face.mobiusCorrelation();
    // 100*100 = 10000 per cell, summed over 225 = 2,250,000, divided by 225 = 10000
    try std.testing.expectEqual(fp.fromInt(10000), corr);
}

test "EU v11.1: SharedFace quadrupoleCoupling and g-coupling relaxation" {
    var face_a = SharedFace.init("peer-a", .pos_x, 15);
    var face_b = SharedFace.init("peer-b", .neg_x, 15);

    for (0..225) |i| {
        face_a.local_states[i] = fp.fromInt(10);
        face_b.remote_states[i] = fp.fromInt(10);
    }

    const q_corr = quadrupoleCoupling(&face_a, &face_b);
    try std.testing.expect(q_corr > 0);

    // Test state coupling with universal constant g = 0.00388
    const init_local = face_a.local_states[0];
    face_a.remote_states[224] = fp.fromInt(100);
    face_a.coupleStates(null); // uses fp.COUPLING_G
    try std.testing.expect(face_a.local_states[0] > init_local);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
