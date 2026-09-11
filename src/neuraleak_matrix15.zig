// ============================================================================
// NEURALEAK MATRIX15 — 15³ Scalar Field
// ============================================================================
//
// Provides a 15³ = 3375 cell scalar field for mapping LLM responses into the
// framework's lattice. This is the interior of the 15³ → 16³ shell transition
// (chunk 16: 16³ - 15³ = 721 = 3(240) + 1).
//
// The matrix uses f64 for scalar field values because it encodes text-hash
// densities, not exact arithmetic identities. The cross-wiring to the existing
// system (15³ = 3375, 225 = 240 - 15) is verified in exact integer arithmetic
// in the proof module.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

pub const SIZE: usize = 15;
pub const TOTAL_CELLS: usize = SIZE * SIZE * SIZE; // 3375

pub const Matrix15 = struct {
    data: []f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Matrix15 {
        const data = try allocator.alloc(f64, TOTAL_CELLS);
        @memset(data, 0.0);
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Matrix15) void {
        self.allocator.free(self.data);
    }

    pub fn index(x: u4, y: u4, z: u4) usize {
        return (@as(usize, z) * SIZE + @as(usize, y)) * SIZE + @as(usize, x);
    }

    pub fn get(self: *const Matrix15, x: u4, y: u4, z: u4) f64 {
        return self.data[index(x, y, z)];
    }

    pub fn set(self: *Matrix15, x: u4, y: u4, z: u4, value: f64) void {
        self.data[index(x, y, z)] = value;
    }

    pub fn clear(self: *Matrix15) void {
        @memset(self.data, 0.0);
    }

    pub fn l2Norm(self: *const Matrix15) f64 {
        var sum: f64 = 0.0;
        for (self.data) |v| {
            sum += v * v;
        }
        return std.math.sqrt(sum);
    }

    pub fn maxValue(self: *const Matrix15) f64 {
        var max: f64 = 0.0;
        for (self.data) |v| {
            if (v > max) max = v;
        }
        return max;
    }

    pub fn nonZeroCount(self: *const Matrix15) usize {
        var count: usize = 0;
        for (self.data) |v| {
            if (v != 0.0) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Matrix15 init produces zeroed 3375-cell field" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    try std.testing.expectEqual(@as(usize, 3375), matrix.data.len);
    try std.testing.expectEqual(@as(f64, 0.0), matrix.l2Norm());
}

test "Matrix15 index maps (x,y,z) to flat array" {
    try std.testing.expectEqual(@as(usize, 0), Matrix15.index(0, 0, 0));
    try std.testing.expectEqual(@as(usize, 14), Matrix15.index(14, 0, 0));
    try std.testing.expectEqual(@as(usize, 15), Matrix15.index(0, 1, 0));
    try std.testing.expectEqual(@as(usize, 225), Matrix15.index(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 3374), Matrix15.index(14, 14, 14));
}

test "Matrix15 set and get round-trip" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    matrix.set(7, 7, 7, 0.5);
    try std.testing.expectEqual(@as(f64, 0.5), matrix.get(7, 7, 7));
    try std.testing.expectEqual(@as(f64, 0.0), matrix.get(0, 0, 0));
}

test "Matrix15 l2Norm computes correctly" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    matrix.set(0, 0, 0, 3.0);
    matrix.set(1, 0, 0, 4.0);
    // L2 norm = sqrt(9 + 16) = 5
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), matrix.l2Norm(), 1e-10);
}

test "Matrix15 nonZeroCount counts populated cells" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    matrix.set(0, 0, 0, 1.0);
    matrix.set(7, 7, 7, 2.0);
    matrix.set(14, 14, 14, 3.0);
    try std.testing.expectEqual(@as(usize, 3), matrix.nonZeroCount());
}

test "Matrix15 15³ = 3375 connects to shell transition" {
    // 16³ - 15³ = 4096 - 3375 = 721 = 3(240) + 1
    const interior: u32 = 3375;
    const closure: u32 = 4096;
    const shell: u32 = closure - interior;
    try std.testing.expectEqual(@as(u32, 721), shell);
    try std.testing.expectEqual(@as(u32, 3 * 240 + 1), shell);
}
