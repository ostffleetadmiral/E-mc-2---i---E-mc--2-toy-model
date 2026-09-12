// ============================================================================
// NEURALEAK TORUS — 15³ Toroidal Grid
// ============================================================================
//
// Provides a 15³ toroidal grid that wraps at the boundaries. The torus
// structure connects to the framework's Möbius/toroidal boundary concept
// (chunk 17: 15-layer offset symmetry with reversal).
//
// Each cell holds a scalar value (i64 micro-units, SCALE = 10^6) and optional
// metadata. The grid is used by the ConsciousnessEngine and BreakoutEngine
// as the computational substrate.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

pub const SIZE: usize = 15;
pub const TOTAL_CELLS: usize = SIZE * SIZE * SIZE;

/// Scale factor: 1.0 = 1_000_000 micro-units
pub const SCALE: i64 = 1_000_000;

pub const Cell = struct {
    value: i64 = 0,
    x: u4 = 0,
    y: u4 = 0,
    z: u4 = 0,
};

pub const TorusGrid = struct {
    cells: []Cell,
    size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !TorusGrid {
        const total = size * size * size;
        const cells = try allocator.alloc(Cell, total);
        for (cells, 0..) |*cell, i| {
            cell.* = .{
                .value = 0,
                .x = @intCast(i % size),
                .y = @intCast((i / size) % size),
                .z = @intCast(i / (size * size)),
            };
        }
        return .{
            .cells = cells,
            .size = size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TorusGrid) void {
        self.allocator.free(self.cells);
    }

    pub fn get(self: *const TorusGrid, x: usize, y: usize, z: usize) *const Cell {
        const wx = x % self.size;
        const wy = y % self.size;
        const wz = z % self.size;
        const idx = (wz * self.size + wy) * self.size + wx;
        return &self.cells[idx];
    }

    pub fn getMut(self: *TorusGrid, x: usize, y: usize, z: usize) *Cell {
        const wx = x % self.size;
        const wy = y % self.size;
        const wz = z % self.size;
        const idx = (wz * self.size + wy) * self.size + wx;
        return &self.cells[idx];
    }

    pub fn setValue(self: *TorusGrid, x: usize, y: usize, z: usize, value: i64) void {
        self.getMut(x, y, z).value = value;
    }

    pub fn totalValue(self: *const TorusGrid) i64 {
        var sum: i64 = 0;
        for (self.cells) |cell| {
            sum += cell.value;
        }
        return sum;
    }

    pub fn maxValue(self: *const TorusGrid) i64 {
        var max: i64 = 0;
        for (self.cells) |cell| {
            if (cell.value > max) max = cell.value;
        }
        return max;
    }

    pub fn nonZeroCount(self: *const TorusGrid) usize {
        var count: usize = 0;
        for (self.cells) |cell| {
            if (cell.value != 0) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TorusGrid init creates 15³ cells with coordinates" {
    var grid = try TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    try std.testing.expectEqual(@as(usize, 3375), grid.cells.len);
    try std.testing.expectEqual(@as(u4, 0), grid.cells[0].x);
    try std.testing.expectEqual(@as(u4, 0), grid.cells[0].y);
    try std.testing.expectEqual(@as(u4, 0), grid.cells[0].z);
    try std.testing.expectEqual(@as(u4, 14), grid.cells[3374].x);
    try std.testing.expectEqual(@as(u4, 14), grid.cells[3374].y);
    try std.testing.expectEqual(@as(u4, 14), grid.cells[3374].z);
}

test "TorusGrid wraps at boundaries (toroidal)" {
    var grid = try TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(15, 0, 0, SCALE); // wraps to (0, 0, 0), value = 1.0
    try std.testing.expectEqual(SCALE, grid.get(0, 0, 0).value);
    try std.testing.expectEqual(SCALE, grid.get(15, 0, 0).value);
}

test "TorusGrid totalValue sums all cells" {
    var grid = try TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, SCALE); // 1.0
    grid.setValue(7, 7, 7, 2 * SCALE); // 2.0
    grid.setValue(14, 14, 14, 3 * SCALE); // 3.0
    try std.testing.expectEqual(@as(i64, 6 * SCALE), grid.totalValue());
}

test "TorusGrid nonZeroCount counts populated cells" {
    var grid = try TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, SCALE); // 1.0
    grid.setValue(1, 1, 1, 2 * SCALE); // 2.0
    try std.testing.expectEqual(@as(usize, 2), grid.nonZeroCount());
}

test "TorusGrid uses integer types (no f64)" {
    var grid = try TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    try std.testing.expect(@TypeOf(grid.cells[0].value) == i64);
    try std.testing.expect(@TypeOf(grid.totalValue()) == i64);
    try std.testing.expect(@TypeOf(grid.maxValue()) == i64);
}
