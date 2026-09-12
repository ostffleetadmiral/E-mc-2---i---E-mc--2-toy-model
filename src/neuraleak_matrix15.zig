// ============================================================================
// NEURALEAK MATRIX15 — 15³ Scalar Field
// ============================================================================
//
// Provides a 15³ = 3375 cell scalar field for mapping LLM responses into the
// framework's lattice. This is the interior of the 15³ → 16³ shell transition
// (chunk 16: 16³ - 15³ = 721 = 3(240) + 1).
//
// The matrix uses i64 with SCALE = 10^6 (micro-units) for scalar field values
// to avoid floating point in core. The cross-wiring to the existing system
// (15³ = 3375, 225 = 240 - 15) is verified in exact integer arithmetic in the
// proof module.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

pub const SIZE: usize = 15;
pub const TOTAL_CELLS: usize = SIZE * SIZE * SIZE; // 3375

/// Scale factor: 1.0 = 1_000_000 micro-units
pub const SCALE: i64 = 1_000_000;

/// Integer square root for i64
fn isqrt(n: i64) i64 {
    if (n <= 0) return 0;
    var x: i64 = n;
    var y: i64 = @divTrunc(x + 1, 2);
    while (y < x) {
        x = y;
        y = @divTrunc(x + @divTrunc(n, x), 2);
    }
    return x;
}

pub const Matrix15 = struct {
    data: []i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Matrix15 {
        const data = try allocator.alloc(i64, TOTAL_CELLS);
        @memset(data, 0);
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

    pub fn get(self: *const Matrix15, x: u4, y: u4, z: u4) i64 {
        return self.data[index(x, y, z)];
    }

    pub fn set(self: *Matrix15, x: u4, y: u4, z: u4, value: i64) void {
        self.data[index(x, y, z)] = value;
    }

    pub fn clear(self: *Matrix15) void {
        @memset(self.data, 0);
    }

    /// L2 norm in micro-units: sqrt(sum of squares) / SCALE
    /// Since data is in micro-units, sum of squares is in micro-units².
    /// sqrt(micro²) = micro, so we divide by SCALE to get back to micro-units.
    pub fn l2Norm(self: *const Matrix15) i64 {
        var sum: i128 = 0;
        for (self.data) |v| {
            sum += @as(i128, v) * @as(i128, v);
        }
        // sum is in micro² units. sqrt gives micro units.
        return isqrt(@intCast(sum));
    }

    pub fn maxValue(self: *const Matrix15) i64 {
        var max: i64 = 0;
        for (self.data) |v| {
            if (v > max) max = v;
        }
        return max;
    }

    pub fn nonZeroCount(self: *const Matrix15) usize {
        var count: usize = 0;
        for (self.data) |v| {
            if (v != 0) count += 1;
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
    try std.testing.expectEqual(@as(i64, 0), matrix.l2Norm());
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

    matrix.set(7, 7, 7, 500_000); // 0.5 in micro-units
    try std.testing.expectEqual(@as(i64, 500_000), matrix.get(7, 7, 7));
    try std.testing.expectEqual(@as(i64, 0), matrix.get(0, 0, 0));
}

test "Matrix15 l2Norm computes correctly" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    matrix.set(0, 0, 0, 3 * SCALE); // 3.0
    matrix.set(1, 0, 0, 4 * SCALE); // 4.0
    // L2 norm = sqrt(9e12 + 16e12) = sqrt(25e12) = 5e6 = 5.0 in micro-units
    const norm = matrix.l2Norm();
    try std.testing.expect(norm >= 4_999_999 and norm <= 5_000_001);
}

test "Matrix15 nonZeroCount counts populated cells" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    matrix.set(0, 0, 0, SCALE); // 1.0
    matrix.set(7, 7, 7, 2 * SCALE); // 2.0
    matrix.set(14, 14, 14, 3 * SCALE); // 3.0
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

test "Matrix15 uses integer types (no f64)" {
    var matrix = try Matrix15.init(std.testing.allocator);
    defer matrix.deinit();

    try std.testing.expect(@TypeOf(matrix.data) == []i64);
    try std.testing.expect(@TypeOf(matrix.get(0, 0, 0)) == i64);
    try std.testing.expect(@TypeOf(matrix.l2Norm()) == i64);
}
