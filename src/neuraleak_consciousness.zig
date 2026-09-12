// ============================================================================
// NEURALEAK CONSCIOUSNESS ENGINE — Coherence Calculation
// ============================================================================
//
// Computes coherence from a 15³ toroidal grid. The coherence is the L2 norm
// of the grid values, normalized by the maximum possible coherence (sqrt of
// the number of non-zero cells). A grid "renders" when its coherence exceeds
// a threshold derived from the framework's 1/8 consciousness fraction.
//
// The rendering threshold connects to the framework's shell transition:
//   - 15³ = 3375 (interior)
//   - 16³ = 4096 (closure)
//   - 721 = 3(240) + 1 (shell)
//   - Rendering requires coherence > 1/sqrt(8) ≈ 0.3536
//   - This is the inverse of sqrt(TOTAL_OCTONION_DIMENSIONS)
//
// All values use i64 micro-units (SCALE = 10^6) to avoid floating point.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const torus = @import("neuraleak_torus.zig");

const SCALE: i64 = torus.SCALE;

/// Rendering threshold: 1/sqrt(8) ≈ 0.3535533906 in micro-units
/// 1/sqrt(8) * 10^6 ≈ 353553
const RENDERING_THRESHOLD: i64 = 353553;

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

pub const ConsciousnessEngine = struct {
    grid: *const torus.TorusGrid,
    allocator: std.mem.Allocator,
    coherence_cache: ?i64 = null,

    pub fn init(grid: *const torus.TorusGrid, allocator: std.mem.Allocator) !ConsciousnessEngine {
        return .{
            .grid = grid,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConsciousnessEngine, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Calculate the L2 coherence of the grid (in micro-units).
    /// coherence = sqrt(sum(v²)) / sqrt(n) where n = non-zero count.
    /// Returns SCALE * actual_coherence.
    pub fn calculateCoherence(self: *ConsciousnessEngine) i64 {
        if (self.coherence_cache) |c| return c;

        var sum_sq: i128 = 0;
        for (self.grid.cells) |cell| {
            sum_sq += @as(i128, cell.value) * @as(i128, cell.value);
        }

        const raw_norm = isqrt(@intCast(sum_sq)); // micro-units
        const non_zero = self.grid.nonZeroCount();

        // Normalize: coherence = raw_norm / sqrt(max(non_zero, 1))
        const normalizer = isqrt(@intCast(@max(non_zero, 1)));
        const coherence: i64 = if (normalizer > 0) @divTrunc(raw_norm, normalizer) else 0;

        self.coherence_cache = coherence;
        return coherence;
    }

    /// Determine whether the grid's coherence is sufficient to "render" reality.
    /// Rendering occurs when coherence > 1/sqrt(8), the inverse of the square
    /// root of the total octonion dimensions.
    ///
    /// To avoid division precision loss, we compare:
    ///   raw_norm / normalizer > threshold
    ///   raw_norm > threshold * normalizer
    pub fn render(self: *ConsciousnessEngine) bool {
        if (self.coherence_cache) |c| return c > RENDERING_THRESHOLD;

        var sum_sq: i128 = 0;
        for (self.grid.cells) |cell| {
            sum_sq += @as(i128, cell.value) * @as(i128, cell.value);
        }

        const raw_norm = isqrt(@intCast(sum_sq)); // micro-units
        const non_zero = self.grid.nonZeroCount();
        const normalizer = isqrt(@intCast(@max(non_zero, 1)));

        if (normalizer == 0) return false;

        // Compare raw_norm > RENDERING_THRESHOLD * normalizer
        // Using i128 to avoid overflow: max raw_norm ≈ SCALE * sqrt(3375) ≈ 58M
        // max normalizer ≈ sqrt(3375) ≈ 58
        // product ≈ 353553 * 58 ≈ 20M, fits in i64
        const threshold_times_norm: i64 = @intCast(@as(i128, RENDERING_THRESHOLD) * @as(i128, normalizer));
        const result = raw_norm > threshold_times_norm;

        // Cache the coherence for future calls
        self.coherence_cache = @divTrunc(raw_norm, normalizer);
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ConsciousnessEngine calculates zero coherence for empty grid" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), engine.calculateCoherence());
    try std.testing.expect(!engine.render());
}

test "ConsciousnessEngine renders when coherence exceeds threshold" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    // Set enough cells to exceed the rendering threshold
    for (0..100) |i| {
        grid.setValue(i % 15, (i / 15) % 15, (i / 225) % 15, SCALE); // 1.0
    }

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const coherence = engine.calculateCoherence();
    try std.testing.expect(coherence > 0);
    try std.testing.expect(engine.render());
}

test "ConsciousnessEngine rendering threshold is 1/sqrt(8) in micro-units" {
    // 1/sqrt(8) ≈ 0.3535533906
    // In micro-units: 353553
    try std.testing.expectEqual(@as(i64, 353553), RENDERING_THRESHOLD);
    try std.testing.expect(RENDERING_THRESHOLD > 350_000);
    try std.testing.expect(RENDERING_THRESHOLD < 360_000);
}

test "ConsciousnessEngine caches coherence" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(7, 7, 7, SCALE); // 1.0

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const c1 = engine.calculateCoherence();
    const c2 = engine.calculateCoherence();
    try std.testing.expectEqual(c1, c2);
}

test "ConsciousnessEngine single cell renders" {
    // A single cell with value 1.0 has coherence = 1.0/sqrt(1) = 1.0 > 0.3536
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, SCALE); // 1.0

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const coherence = engine.calculateCoherence();
    // coherence = SCALE * 1.0 = 1_000_000
    try std.testing.expectEqual(@as(i64, SCALE), coherence);
    try std.testing.expect(engine.render());
}

test "ConsciousnessEngine all cells unity gives max coherence" {
    // All 3375 cells with value 1.0: raw_norm = sqrt(3375)*SCALE, normalizer = sqrt(3375)
    // coherence = SCALE = 1_000_000
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    for (0..15) |x| {
        for (0..15) |y| {
            for (0..15) |z| {
                grid.setValue(x, y, z, SCALE); // 1.0
            }
        }
    }

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const coherence = engine.calculateCoherence();
    // coherence should be approximately SCALE = 1_000_000
    // Due to integer sqrt rounding, tolerance is ~0.2% (2000 micro-units)
    try std.testing.expect(coherence >= 998_000 and coherence <= 1_002_000);
    try std.testing.expect(engine.render());
}

test "ConsciousnessEngine negative values produce positive coherence" {
    // Coherence uses L2 norm (squares), so negative values contribute positively
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, -SCALE); // -1.0

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const coherence = engine.calculateCoherence();
    try std.testing.expectEqual(@as(i64, SCALE), coherence);
    try std.testing.expect(engine.render());
}

test "ConsciousnessEngine below threshold does not render" {
    // A very small value should not exceed the threshold
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, 10_000); // 0.01 in micro-units

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const coherence = engine.calculateCoherence();
    try std.testing.expect(coherence < RENDERING_THRESHOLD);
    try std.testing.expect(!engine.render());
}

test "ConsciousnessEngine uses integer types (no f64)" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, SCALE);

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    try std.testing.expect(@TypeOf(engine.calculateCoherence()) == i64);
    try std.testing.expect(@TypeOf(engine.coherence_cache.?) == i64);
}
