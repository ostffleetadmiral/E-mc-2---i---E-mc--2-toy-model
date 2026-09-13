//! merge.zig — Möbius merge: conflict resolution for concurrent lattice cell edits.
//!
//! When two peers edit the same lattice cell concurrently, the Möbius merge
//! resolves conflicts using the lattice's inherent topological structure.
//! The Möbius twist at boundary faces creates a deterministic merge order
//! based on e-values and lattice coordinates.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

pub const FACE_CELLS: usize = 225; // 15² = 225 cells per face
pub const BASE_EDGE: u32 = 15;

// =============================================================================
// CellEdit — a single cell modification from a peer
// =============================================================================

pub const CellEdit = struct {
    /// Peer's lattice location hash.
    peer_hash: u64,
    /// Cell coordinates.
    x: u32,
    y: u32,
    z: u32,
    /// E-value at this cell (octonion routing value 0-7).
    e_value: u3,
    /// Whether this cell is on a lattice boundary.
    is_boundary: bool,
    /// New activation value.
    activation: f64,
    /// Timestamp of the edit (ms).
    timestamp: u64,
    /// Sequence number from the peer.
    seq: u64,

    pub fn init(
        peer_hash: u64,
        x: u32,
        y: u32,
        z: u32,
        e_value: u3,
        is_boundary: bool,
        activation: f64,
        timestamp: u64,
        seq: u64,
    ) CellEdit {
        return .{
            .peer_hash = peer_hash,
            .x = x,
            .y = y,
            .z = z,
            .e_value = e_value,
            .is_boundary = is_boundary,
            .activation = activation,
            .timestamp = timestamp,
            .seq = seq,
        };
    }
};

// =============================================================================
// Conflict — two conflicting edits to the same cell
// =============================================================================

pub const Conflict = struct {
    edit_a: CellEdit,
    edit_b: CellEdit,

    pub inline fn init(a: CellEdit, b: CellEdit) Conflict {
        return .{ .edit_a = a, .edit_b = b };
    }

    /// Check if two edits conflict (same cell, different peers).
    pub inline fn isConflict(a: CellEdit, b: CellEdit) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z and a.peer_hash != b.peer_hash;
    }
};

// =============================================================================
// MergeStrategy — strategies for resolving conflicts
// =============================================================================

pub const MergeStrategy = enum {
    /// Last-write-wins (by timestamp).
    last_write_wins,
    /// Highest e-value wins (octonion priority).
    e_value_priority,
    /// Möbius twist: boundary cells use reversed comparison.
    mobius_twist,
    /// Average both values.
    average,
};

// =============================================================================
// MergeResult — result of a merge operation
// =============================================================================

pub const MergeResult = struct {
    /// The winning activation value.
    activation: f64,
    /// Which peer won.
    winning_peer: u64,
    /// Strategy used to resolve.
    strategy: MergeStrategy,
    /// Whether the conflict was resolved or both were kept.
    resolved: bool,
};

// =============================================================================
// Möbius merge logic
// =============================================================================

/// Resolves a conflict using the specified strategy.
pub fn resolveConflict(conflict: Conflict, strategy: MergeStrategy) MergeResult {
    switch (strategy) {
        .last_write_wins => {
            if (conflict.edit_a.timestamp > conflict.edit_b.timestamp) {
                return .{
                    .activation = conflict.edit_a.activation,
                    .winning_peer = conflict.edit_a.peer_hash,
                    .strategy = strategy,
                    .resolved = true,
                };
            } else if (conflict.edit_b.timestamp > conflict.edit_a.timestamp) {
                return .{
                    .activation = conflict.edit_b.activation,
                    .winning_peer = conflict.edit_b.peer_hash,
                    .strategy = strategy,
                    .resolved = true,
                };
            }
            // Same timestamp — fall back to e-value priority
            return resolveConflict(conflict, .e_value_priority);
        },

        .e_value_priority => {
            // Higher e-value wins (octonion routing priority)
            if (conflict.edit_a.e_value > conflict.edit_b.e_value) {
                return .{
                    .activation = conflict.edit_a.activation,
                    .winning_peer = conflict.edit_a.peer_hash,
                    .strategy = strategy,
                    .resolved = true,
                };
            } else if (conflict.edit_b.e_value > conflict.edit_a.e_value) {
                return .{
                    .activation = conflict.edit_b.activation,
                    .winning_peer = conflict.edit_b.peer_hash,
                    .strategy = strategy,
                    .resolved = true,
                };
            }
            // Same e-value — fall back to lower peer_hash (deterministic)
            if (conflict.edit_a.peer_hash < conflict.edit_b.peer_hash) {
                return .{
                    .activation = conflict.edit_a.activation,
                    .winning_peer = conflict.edit_a.peer_hash,
                    .strategy = strategy,
                    .resolved = true,
                };
            }
            return .{
                .activation = conflict.edit_b.activation,
                .winning_peer = conflict.edit_b.peer_hash,
                .strategy = strategy,
                .resolved = true,
            };
        },

        .mobius_twist => {
            // For boundary cells, apply Möbius reversal before comparison.
            // This means the "direction" of comparison is flipped at boundaries,
            // creating the twist topology.
            if (conflict.edit_a.is_boundary or conflict.edit_b.is_boundary) {
                // At boundary: lower timestamp wins (reversed from LWW)
                if (conflict.edit_a.timestamp < conflict.edit_b.timestamp) {
                    return .{
                        .activation = conflict.edit_a.activation,
                        .winning_peer = conflict.edit_a.peer_hash,
                        .strategy = strategy,
                        .resolved = true,
                    };
                } else if (conflict.edit_b.timestamp < conflict.edit_a.timestamp) {
                    return .{
                        .activation = conflict.edit_b.activation,
                        .winning_peer = conflict.edit_b.peer_hash,
                        .strategy = strategy,
                        .resolved = true,
                    };
                }
            }
            // Non-boundary: use e-value priority
            return resolveConflict(conflict, .e_value_priority);
        },

        .average => {
            return .{
                .activation = (conflict.edit_a.activation + conflict.edit_b.activation) / 2.0,
                .winning_peer = 0, // no single winner
                .strategy = strategy,
                .resolved = true,
            };
        },
    }
}

// =============================================================================
// MergeSet — collects and resolves multiple conflicts
// =============================================================================

pub const MergeSet = struct {
    allocator: std.mem.Allocator,
    conflicts: std.ArrayList(Conflict),
    strategy: MergeStrategy,

    pub fn init(allocator: std.mem.Allocator, strategy: MergeStrategy) MergeSet {
        return .{
            .allocator = allocator,
            .conflicts = std.ArrayList(Conflict).init(allocator),
            .strategy = strategy,
        };
    }

    pub fn deinit(self: *MergeSet) void {
        self.conflicts.deinit();
    }

    /// Add a conflict to the set.
    pub fn addConflict(self: *MergeSet, a: CellEdit, b: CellEdit) !void {
        if (Conflict.isConflict(a, b)) {
            try self.conflicts.append(Conflict.init(a, b));
        }
    }

    /// Resolve all conflicts and return the winning edits.
    pub fn resolve(self: *MergeSet, allocator: std.mem.Allocator) ![]MergeResult {
        var results = try allocator.alloc(MergeResult, self.conflicts.items.len);
        for (self.conflicts.items, 0..) |conflict, i| {
            results[i] = resolveConflict(conflict, self.strategy);
        }
        return results;
    }

    /// Number of conflicts in the set.
    pub inline fn count(self: *const MergeSet) usize {
        return self.conflicts.items.len;
    }
};

// =============================================================================
// FaceMerge — merge shared face states between two peers
// =============================================================================

/// Merges two sets of face states (225 cells) using the Möbius twist.
/// Local states are compared with reversed remote states (Möbius reflection).
/// Returns the merged face states.
pub fn mergeFaceStates(
    local: [FACE_CELLS]f64,
    remote: [FACE_CELLS]f64,
    local_timestamp: u64,
    remote_timestamp: u64,
) [FACE_CELLS]f64 {
    var merged: [FACE_CELLS]f64 = undefined;

    for (0..FACE_CELLS) |i| {
        // Möbius twist: compare local[i] with remote[224-i]
        const remote_idx = FACE_CELLS - 1 - i;

        if (local_timestamp > remote_timestamp) {
            merged[i] = local[i];
        } else if (remote_timestamp > local_timestamp) {
            // Take from reversed remote (Möbius reflection)
            merged[i] = remote[remote_idx];
        } else {
            // Same timestamp: average with Möbius reflection
            merged[i] = (local[i] + remote[remote_idx]) / 2.0;
        }
    }

    return merged;
}

/// Computes the merge quality (how well the merged face preserves both inputs).
pub fn mergeQuality(original_local: [FACE_CELLS]f64, original_remote: [FACE_CELLS]f64, merged: [FACE_CELLS]f64) f64 {
    var local_diff: f64 = 0;
    var remote_diff: f64 = 0;

    for (0..FACE_CELLS) |i| {
        const remote_idx = FACE_CELLS - 1 - i;
        local_diff += @abs(merged[i] - original_local[i]);
        remote_diff += @abs(merged[i] - original_remote[remote_idx]);
    }

    const avg_diff = (local_diff + remote_diff) / (2.0 * @as(f64, @floatFromInt(FACE_CELLS)));
    // Quality = 1 - normalized difference (clamped to 0)
    return @max(0.0, 1.0 - avg_diff);
}

// =============================================================================
// Three-way merge — merge with a common ancestor
// =============================================================================

pub const ThreeWayMerge = struct {
    /// Common ancestor state.
    ancestor: [FACE_CELLS]f64,
    /// Local modified state.
    local: [FACE_CELLS]f64,
    /// Remote modified state.
    remote: [FACE_CELLS]f64,

    pub fn init(ancestor: [FACE_CELLS]f64, local: [FACE_CELLS]f64, remote: [FACE_CELLS]f64) ThreeWayMerge {
        return .{
            .ancestor = ancestor,
            .local = local,
            .remote = remote,
        };
    }

    /// Performs a three-way merge with Möbius twist.
    /// Cells changed on only one side are taken from that side.
    /// Cells changed on both sides are resolved by e-value priority.
    pub fn merge(self: ThreeWayMerge, e_values: [FACE_CELLS]u3) [FACE_CELLS]f64 {
        var merged: [FACE_CELLS]f64 = undefined;

        for (0..FACE_CELLS) |i| {
            const remote_idx = FACE_CELLS - 1 - i; // Möbius reflection

            const local_changed = self.local[i] != self.ancestor[i];
            const remote_changed = self.remote[remote_idx] != self.ancestor[i];

            if (local_changed and !remote_changed) {
                // Only local changed
                merged[i] = self.local[i];
            } else if (!local_changed and remote_changed) {
                // Only remote changed (with Möbius reflection)
                merged[i] = self.remote[remote_idx];
            } else if (local_changed and remote_changed) {
                // Both changed — use e-value as tiebreaker
                // Higher e-value at this cell determines priority
                if (e_values[i] >= 4) {
                    merged[i] = self.local[i];
                } else {
                    merged[i] = self.remote[remote_idx];
                }
            } else {
                // Neither changed — keep ancestor
                merged[i] = self.ancestor[i];
            }
        }

        return merged;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "merge: conflict detection" {
    const edit_a = CellEdit.init(100, 5, 5, 5, 3, false, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 5, 5, 5, 3, false, 0.6, 2000, 1);
    const edit_c = CellEdit.init(100, 5, 5, 5, 3, false, 0.7, 3000, 2);

    try std.testing.expect(Conflict.isConflict(edit_a, edit_b)); // same cell, different peers
    try std.testing.expect(!Conflict.isConflict(edit_a, edit_c)); // same peer
}

test "merge: last-write-wins" {
    const edit_a = CellEdit.init(100, 5, 5, 5, 3, false, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 5, 5, 5, 3, false, 0.6, 2000, 1);
    const conflict = Conflict.init(edit_a, edit_b);

    const result = resolveConflict(conflict, .last_write_wins);
    try std.testing.expect(result.resolved);
    try std.testing.expectEqual(@as(u64, 200), result.winning_peer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), result.activation, 1e-9);
}

test "merge: e-value priority" {
    const edit_a = CellEdit.init(100, 5, 5, 5, 7, false, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 5, 5, 5, 2, false, 0.6, 1000, 1);
    const conflict = Conflict.init(edit_a, edit_b);

    const result = resolveConflict(conflict, .e_value_priority);
    try std.testing.expect(result.resolved);
    try std.testing.expectEqual(@as(u64, 100), result.winning_peer); // higher e-value
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), result.activation, 1e-9);
}

test "merge: mobius twist at boundary" {
    const edit_a = CellEdit.init(100, 0, 5, 5, 3, true, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 0, 5, 5, 3, true, 0.6, 2000, 1);
    const conflict = Conflict.init(edit_a, edit_b);

    // At boundary with Möbius twist: lower timestamp wins (reversed)
    const result = resolveConflict(conflict, .mobius_twist);
    try std.testing.expect(result.resolved);
    try std.testing.expectEqual(@as(u64, 100), result.winning_peer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), result.activation, 1e-9);
}

test "merge: mobius twist non-boundary" {
    const edit_a = CellEdit.init(100, 5, 5, 5, 3, false, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 5, 5, 5, 3, false, 0.6, 2000, 1);
    const conflict = Conflict.init(edit_a, edit_b);

    // Non-boundary: falls back to e-value priority (same e-value → lower hash wins)
    const result = resolveConflict(conflict, .mobius_twist);
    try std.testing.expect(result.resolved);
    try std.testing.expectEqual(@as(u64, 100), result.winning_peer); // lower hash
}

test "merge: average strategy" {
    const edit_a = CellEdit.init(100, 5, 5, 5, 3, false, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 5, 5, 5, 3, false, 0.6, 2000, 1);
    const conflict = Conflict.init(edit_a, edit_b);

    const result = resolveConflict(conflict, .average);
    try std.testing.expect(result.resolved);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), result.activation, 1e-9);
    try std.testing.expectEqual(@as(u64, 0), result.winning_peer);
}

test "merge: same timestamp falls back to e-value" {
    const edit_a = CellEdit.init(100, 5, 5, 5, 5, false, 0.8, 1000, 1);
    const edit_b = CellEdit.init(200, 5, 5, 5, 2, false, 0.6, 1000, 1);
    const conflict = Conflict.init(edit_a, edit_b);

    const result = resolveConflict(conflict, .last_write_wins);
    try std.testing.expectEqual(@as(u64, 100), result.winning_peer); // higher e-value
}

test "merge: MergeSet collects and resolves" {
    const allocator = std.testing.allocator;
    var ms = MergeSet.init(allocator, .last_write_wins);
    defer ms.deinit();

    const edit_a1 = CellEdit.init(100, 1, 1, 1, 3, false, 0.5, 1000, 1);
    const edit_b1 = CellEdit.init(200, 1, 1, 1, 3, false, 0.6, 2000, 1);
    try ms.addConflict(edit_a1, edit_b1);

    const edit_a2 = CellEdit.init(100, 2, 2, 2, 5, false, 0.7, 3000, 2);
    const edit_b2 = CellEdit.init(200, 2, 2, 2, 5, false, 0.8, 4000, 2);
    try ms.addConflict(edit_a2, edit_b2);

    try std.testing.expectEqual(@as(usize, 2), ms.count());

    const results = try ms.resolve(allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u64, 200), results[0].winning_peer); // later timestamp
    try std.testing.expectEqual(@as(u64, 200), results[1].winning_peer); // later timestamp
}

test "merge: face state merge with Möbius reflection" {
    var local: [FACE_CELLS]f64 = undefined;
    var remote: [FACE_CELLS]f64 = undefined;
    for (0..FACE_CELLS) |i| {
        local[i] = @as(f64, @floatFromInt(i)) * 0.01;
        remote[i] = @as(f64, @floatFromInt(FACE_CELLS - 1 - i)) * 0.01;
    }

    // Local is newer
    const merged = mergeFaceStates(local, remote, 2000, 1000);
    for (0..FACE_CELLS) |i| {
        try std.testing.expectApproxEqAbs(local[i], merged[i], 1e-9);
    }

    // Remote is newer — Möbius reflection applied
    const merged2 = mergeFaceStates(local, remote, 1000, 2000);
    for (0..FACE_CELLS) |i| {
        const remote_idx = FACE_CELLS - 1 - i;
        try std.testing.expectApproxEqAbs(remote[remote_idx], merged2[i], 1e-9);
    }
}

test "merge: face state merge same timestamp averages" {
    var local: [FACE_CELLS]f64 = undefined;
    var remote: [FACE_CELLS]f64 = undefined;
    for (0..FACE_CELLS) |i| {
        local[i] = 1.0;
        remote[i] = 3.0;
    }

    const merged = mergeFaceStates(local, remote, 1000, 1000);
    // With Möbius reflection: (local[i] + remote[224-i]) / 2 = (1.0 + 3.0) / 2 = 2.0
    for (0..FACE_CELLS) |i| {
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), merged[i], 1e-9);
    }
}

test "merge: merge quality calculation" {
    var local: [FACE_CELLS]f64 = undefined;
    var remote: [FACE_CELLS]f64 = undefined;
    for (0..FACE_CELLS) |i| {
        local[i] = 1.0;
        remote[i] = 1.0;
    }

    // Merged = local (perfect match with local, Möbius match with remote)
    const merged = mergeFaceStates(local, remote, 2000, 1000);
    const quality = mergeQuality(local, remote, merged);
    try std.testing.expect(quality > 0.99);
}

test "merge: three-way merge — only local changed" {
    var ancestor: [FACE_CELLS]f64 = undefined;
    var local: [FACE_CELLS]f64 = undefined;
    var remote: [FACE_CELLS]f64 = undefined;
    var e_values: [FACE_CELLS]u3 = undefined;

    for (0..FACE_CELLS) |i| {
        ancestor[i] = 0.5;
        local[i] = if (i == 10) 0.9 else 0.5;
        remote[i] = 0.5;
        e_values[i] = 3;
    }

    const twm = ThreeWayMerge.init(ancestor, local, remote);
    const merged = twm.merge(e_values);

    // Only local changed cell 10 → take local
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), merged[10], 1e-9);
    // Other cells unchanged → keep ancestor
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), merged[0], 1e-9);
}

test "merge: three-way merge — both changed, e-value tiebreaker" {
    var ancestor: [FACE_CELLS]f64 = undefined;
    var local: [FACE_CELLS]f64 = undefined;
    var remote: [FACE_CELLS]f64 = undefined;
    var e_values: [FACE_CELLS]u3 = undefined;

    for (0..FACE_CELLS) |i| {
        ancestor[i] = 0.5;
        local[i] = 0.8;
        remote[FACE_CELLS - 1 - i] = 0.3; // Möbius reflection
        e_values[i] = if (i == 5) 6 else 2;
    }

    const twm = ThreeWayMerge.init(ancestor, local, remote);
    const merged = twm.merge(e_values);

    // Cell 5: e_value=6 (>=4) → local wins
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), merged[5], 1e-9);
    // Cell 0: e_value=2 (<4) → remote (Möbius reflected) wins
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), merged[0], 1e-9);
}

test "merge: three-way merge — neither changed" {
    var ancestor: [FACE_CELLS]f64 = undefined;
    var local: [FACE_CELLS]f64 = undefined;
    var remote: [FACE_CELLS]f64 = undefined;
    var e_values: [FACE_CELLS]u3 = undefined;

    for (0..FACE_CELLS) |i| {
        ancestor[i] = 0.5;
        local[i] = 0.5;
        remote[i] = 0.5;
        e_values[i] = 3;
    }

    const twm = ThreeWayMerge.init(ancestor, local, remote);
    const merged = twm.merge(e_values);

    for (0..FACE_CELLS) |i| {
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), merged[i], 1e-9);
    }
}
