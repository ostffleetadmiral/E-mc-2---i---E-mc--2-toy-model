// License: CC BY-NC-SA 4.0
//! fano_tensor.zig - 3D Fano tensor generator (15×15×15 grid).
//!
//! Represents ONE qubit: central e0 observer pivot at (7,7,7) [0-indexed,
//! i.e. layer 8, position (8,8,8) in 1-indexed], 6 radial arms (e1–e7),
//! ~421 e0 nodes, layer mirror symmetry (k ↔ 16-k).
//! Encased in a 16³ e9 9D quantum foam shell.

const std = @import("std");

pub const SIDE: u32 = 15;
pub const LAYERS: u32 = 15;

/// Fano tensor: 15×15×15 grid of octonion indices e0..e7.
pub const FanoTensor = struct {
    data: [SIDE * SIDE * SIDE]u8,

    pub fn init() FanoTensor {
        var t: FanoTensor = .{ .data = undefined };
        var L: u32 = 1;
        while (L <= LAYERS) : (L += 1) {
            // Layer pivot index c: e0 at center layer (L=8), symmetric
            const c: u8 = if (L <= 8)
                @intCast(@mod(@as(i32, 8) - @as(i32, @intCast(L)), 8))
            else
                @intCast(@mod(@as(i32, @intCast(L)) - 8, 8));

            var j: u32 = 0;
            while (j < SIDE) : (j += 1) {
                // Row base value: symmetric around j=7
                const row_base: u8 = if (j < 7)
                    @intCast(@mod(@as(i32, c) - (@as(i32, 7) - @as(i32, @intCast(j))), 8))
                else if (j == 7)
                    c
                else
                    @intCast(@mod(@as(i32, c) + (@as(i32, @intCast(j)) - 7), 8));

                var k: u32 = 0;
                while (k < SIDE) : (k += 1) {
                    // Column value: symmetric around k=7
                    const val: u8 = if (k < 7)
                        @intCast(@mod(@as(i32, row_base) - (@as(i32, 7) - @as(i32, @intCast(k))), 8))
                    else if (k == 7)
                        row_base
                    else
                        @intCast(@mod(@as(i32, row_base) + (@as(i32, @intCast(k)) - 7), 8));
                    t.set(k, j, L - 1, val);
                }
            }
        }
        return t;
    }

    pub inline fn idx(x: u32, y: u32, z: u32) usize {
        return x + y * SIDE + z * SIDE * SIDE;
    }

    pub inline fn get(self: *const FanoTensor, x: u32, y: u32, z: u32) u8 {
        return self.data[idx(x, y, z)];
    }

    pub inline fn set(self: *FanoTensor, x: u32, y: u32, z: u32, v: u8) void {
        self.data[idx(x, y, z)] = v;
    }

    /// Layer pivot = center column value at row 7.
    pub fn layerPivot(self: *const FanoTensor, layer: u32) u8 {
        return self.get(7, 7, layer);
    }

    /// Count nodes with value e0.
    pub fn countE0(self: *const FanoTensor) u32 {
        var count: u32 = 0;
        for (self.data) |v| {
            if (v == 0) count += 1;
        }
        return count;
    }

    /// Count nodes with a specific value.
    pub fn countValue(self: *const FanoTensor, val: u8) u32 {
        var count: u32 = 0;
        for (self.data) |v| {
            if (v == val) count += 1;
        }
        return count;
    }

    /// Check layer mirror symmetry: layer k mirrors layer 16-k (1-indexed).
    pub fn checkSymmetry(self: *const FanoTensor) bool {
        var L: u32 = 1;
        while (L <= 7) : (L += 1) {
            const mirror = 16 - L;
            var y: u32 = 0;
            while (y < SIDE) : (y += 1) {
                var x: u32 = 0;
                while (x < SIDE) : (x += 1) {
                    if (self.get(x, y, L - 1) != self.get(x, y, mirror - 1))
                        return false;
                }
            }
        }
        return true;
    }

    /// Check 6 arms from center: along ±x, ±y, ±z from (7,7,7).
    pub fn checkArms(self: *const FanoTensor) bool {
        const cx: u32 = 7;
        const cy: u32 = 7;
        const cz: u32 = 7;
        var seen: [8]bool = .{false} ** 8;
        var d: u32 = 1;
        while (d <= 7) : (d += 1) {
            seen[self.get(cx + d, cy, cz)] = true;
            seen[self.get(cx - d, cy, cz)] = true;
            seen[self.get(cx, cy + d, cz)] = true;
            seen[self.get(cx, cy - d, cz)] = true;
            seen[self.get(cx, cy, cz + d)] = true;
            seen[self.get(cx, cy, cz - d)] = true;
        }
        var k: u32 = 1;
        while (k < 8) : (k += 1) {
            if (!seen[k]) return false;
        }
        return true;
    }

    /// Dump a single layer to a writer.
    pub fn dumpLayer(self: *const FanoTensor, layer: u32, w: anytype) !void {
        try w.print("Layer {d} (pivot i=e{d}):\n", .{ layer + 1, self.layerPivot(layer) });
        var y: u32 = 0;
        while (y < SIDE) : (y += 1) {
            try w.print("  ", .{});
            var x: u32 = 0;
            while (x < SIDE) : (x += 1) {
                try w.print("e{d} ", .{self.get(x, y, layer)});
            }
            try w.print("\n", .{});
        }
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "fano tensor: central e0 at (7,7,7) in layer 8 (0-indexed layer 7)" {
    const t = FanoTensor.init();
    try std.testing.expectEqual(@as(u8, 0), t.get(7, 7, 7));
}

test "fano tensor: layer pivot assignment" {
    const t = FanoTensor.init();
    // Layer 8 (0-indexed 7) should have pivot e0
    try std.testing.expectEqual(@as(u8, 0), t.layerPivot(7));
    // Layer 1 (0-indexed 0) should have pivot e7
    try std.testing.expectEqual(@as(u8, 7), t.layerPivot(0));
    // Layer 15 (0-indexed 14) should have pivot e7
    try std.testing.expectEqual(@as(u8, 7), t.layerPivot(14));
}

test "fano tensor: layer mirror symmetry (k ↔ 16-k)" {
    const t = FanoTensor.init();
    try std.testing.expect(t.checkSymmetry());
}

test "fano tensor: e0 node count = 421" {
    const t = FanoTensor.init();
    const count = t.countE0();
    try std.testing.expectEqual(@as(u32, 421), count);
}

test "fano tensor: 6 arms from center cover e1..e7" {
    const t = FanoTensor.init();
    try std.testing.expect(t.checkArms());
}

test "fano tensor: all values in 0..7" {
    const t = FanoTensor.init();
    for (t.data) |v| {
        try std.testing.expect(v < 8);
    }
}

test "fano tensor: total nodes = 3375" {
    const t = FanoTensor.init();
    try std.testing.expectEqual(@as(usize, 3375), t.data.len);
}

test "fano tensor: each e1..e7 appears in the grid" {
    const t = FanoTensor.init();
    var k: u32 = 1;
    while (k < 8) : (k += 1) {
        try std.testing.expect(t.countValue(@intCast(k)) > 0);
    }
}

test "fano tensor: center row of layer 8 has e0 at center" {
    const t = FanoTensor.init();
    try std.testing.expectEqual(@as(u8, 0), t.get(7, 7, 7));
}

test "fano tensor: dump all layers without error" {
    const t = FanoTensor.init();
    var buf: [32768]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        try t.dumpLayer(i, fbs.writer());
    }
}
