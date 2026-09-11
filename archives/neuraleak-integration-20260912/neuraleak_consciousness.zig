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
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const torus = @import("neuraleak_torus.zig");

const RENDERING_THRESHOLD: f64 = 1.0 / @sqrt(8.0); // ≈ 0.3536

pub const ConsciousnessEngine = struct {
    grid: *const torus.TorusGrid,
    allocator: std.mem.Allocator,
    coherence_cache: ?f64 = null,

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

    /// Calculate the L2 coherence of the grid.
    pub fn calculateCoherence(self: *ConsciousnessEngine) f64 {
        if (self.coherence_cache) |c| return c;

        var sum_sq: f64 = 0.0;
        for (self.grid.cells) |cell| {
            sum_sq += cell.value * cell.value;
        }

        const raw_norm = std.math.sqrt(sum_sq);
        const non_zero = self.grid.nonZeroCount();

        // Normalize: coherence = raw_norm / sqrt(max(non_zero, 1))
        // This gives a value in [0, sqrt(max_cell_value²)] that scales
        // with how concentrated the field is.
        const normalizer = @sqrt(@as(f64, @floatFromInt(@max(non_zero, 1))));
        const coherence = if (normalizer > 0.0) raw_norm / normalizer else 0.0;

        self.coherence_cache = coherence;
        return coherence;
    }

    /// Determine whether the grid's coherence is sufficient to "render" reality.
    /// Rendering occurs when coherence > 1/sqrt(8), the inverse of the square
    /// root of the total octonion dimensions.
    pub fn render(self: *ConsciousnessEngine) bool {
        const coherence = self.calculateCoherence();
        return coherence > RENDERING_THRESHOLD;
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

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), engine.calculateCoherence(), 1e-10);
    try std.testing.expect(!engine.render());
}

test "ConsciousnessEngine renders when coherence exceeds threshold" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    // Set enough cells to exceed the rendering threshold
    for (0..100) |i| {
        grid.setValue(i % 15, (i / 15) % 15, (i / 225) % 15, 1.0);
    }

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const coherence = engine.calculateCoherence();
    try std.testing.expect(coherence > 0.0);
    try std.testing.expect(engine.render());
}

test "ConsciousnessEngine rendering threshold is 1/sqrt(8)" {
    try std.testing.expectApproxEqAbs(RENDERING_THRESHOLD, 1.0 / @sqrt(8.0), 1e-15);
    try std.testing.expect(RENDERING_THRESHOLD > 0.35);
    try std.testing.expect(RENDERING_THRESHOLD < 0.36);
}

test "ConsciousnessEngine caches coherence" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(7, 7, 7, 1.0);

    var engine = try ConsciousnessEngine.init(&grid, std.testing.allocator);
    defer engine.deinit(std.testing.allocator);

    const c1 = engine.calculateCoherence();
    const c2 = engine.calculateCoherence();
    try std.testing.expectEqual(c1, c2);
}
