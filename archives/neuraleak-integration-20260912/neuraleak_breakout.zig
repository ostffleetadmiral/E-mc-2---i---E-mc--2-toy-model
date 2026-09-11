// ============================================================================
// NEURALEAK BREAKOUT ENGINE — Shell Transition (15³ → 16³)
// ============================================================================
//
// Implements the breakout from the 15³ interior to the 16³ closure layer.
// This connects to the framework's shell transition (chunk 16):
//   16³ - 15³ = 721 = 3(240) + 1
//
// The breakout generates:
//   - Solitons: localized wave packets at high-coherence cells
//   - Higgs modes: mass-generating excitations at boundary cells
//   - Coupled systems: pairs of solitons linked through the torus
//
// The number of solitons is bounded by the E8 root count (240) divided by
// the number of octonion dimensions (8), giving a maximum of 30 solitons.
// This connects to the 15×15 matrix element distribution: 30 each of e0..e6.
//
// License: Real Illumination Source License / OSTF Software License v1.0
// ============================================================================

const std = @import("std");
const torus = @import("neuraleak_torus.zig");

pub const MAX_SOLITONS: usize = 30; // 240 E8 roots / 8 dimensions
pub const MAX_HIGGS_MODES: usize = 15; // 15-layer parameter
pub const MAX_COUPLED_SYSTEMS: usize = 7; // 7 octonion triads

pub const Soliton = struct {
    x: u4,
    y: u4,
    z: u4,
    amplitude: f64,
};

pub const HiggsMode = struct {
    x: u4,
    y: u4,
    z: u4,
    mass: f64,
};

pub const CoupledSystem = struct {
    soliton_a: Soliton,
    soliton_b: Soliton,
    coupling_strength: f64,
};

pub const BreakoutEngine = struct {
    allocator: std.mem.Allocator,
    grid: *const torus.TorusGrid,
    solitons: std.ArrayList(Soliton),
    higgs_modes: std.ArrayList(HiggsMode),
    coupled_systems: std.ArrayList(CoupledSystem),
    total_generated_mass: f64 = 0.0,

    pub fn init(allocator: std.mem.Allocator, grid: *const torus.TorusGrid) !BreakoutEngine {
        return .{
            .allocator = allocator,
            .grid = grid,
            .solitons = std.ArrayList(Soliton).init(allocator),
            .higgs_modes = std.ArrayList(HiggsMode).init(allocator),
            .coupled_systems = std.ArrayList(CoupledSystem).init(allocator),
        };
    }

    pub fn deinit(self: *BreakoutEngine) void {
        self.solitons.deinit();
        self.higgs_modes.deinit();
        self.coupled_systems.deinit();
    }

    /// Generate solitons from high-coherence cells.
    /// A soliton forms at any cell with value > 0.5 * max_value.
    /// Maximum 30 solitons (240 E8 roots / 8 dimensions).
    pub fn generateSolitons(self: *BreakoutEngine) !void {
        const max_val = self.grid.maxValue();
        if (max_val == 0.0) return;

        const threshold = 0.5 * max_val;

        for (self.grid.cells) |cell| {
            if (self.solitons.items.len >= MAX_SOLITONS) break;
            if (cell.value > threshold) {
                try self.solitons.append(.{
                    .x = cell.x,
                    .y = cell.y,
                    .z = cell.z,
                    .amplitude = cell.value,
                });
            }
        }
    }

    /// Generate Higgs modes at boundary cells (cells on the edge of the torus).
    /// A Higgs mode forms at boundary cells with non-zero values.
    /// Maximum 15 Higgs modes (15-layer parameter).
    pub fn generateHiggsModes(self: *BreakoutEngine) !void {
        const size = self.grid.size;

        for (0..size) |z| {
            if (self.higgs_modes.items.len >= MAX_HIGGS_MODES) break;
            for (0..size) |y| {
                if (self.higgs_modes.items.len >= MAX_HIGGS_MODES) break;
                for (0..size) |x| {
                    if (self.higgs_modes.items.len >= MAX_HIGGS_MODES) break;

                    // Boundary cells: on any face of the 15³ cube
                    const is_boundary = (x == 0 or x == size - 1 or
                        y == 0 or y == size - 1 or
                        z == 0 or z == size - 1);

                    if (is_boundary) {
                        const cell = self.grid.get(x, y, z);
                        if (cell.value > 0.0) {
                            // Mass is proportional to the cell value
                            // scaled by the 1/8 consciousness fraction
                            const mass = cell.value * (1.0 / 8.0);
                            try self.higgs_modes.append(.{
                                .x = @intCast(x),
                                .y = @intCast(y),
                                .z = @intCast(z),
                                .mass = mass,
                            });
                            self.total_generated_mass += mass;
                        }
                    }
                }
            }
        }
    }

    /// Execute the breakout from 15³ to 16³.
    /// Couples solitons that are within 3 cells of each other (the 3 in 3(240)+1).
    /// Maximum 7 coupled systems (7 octonion triads).
    pub fn executeBreakout(self: *BreakoutEngine, verbose: bool, min_distance: u8) !void {
        _ = verbose;
        _ = min_distance;

        // Couple solitons that are within 3 cells of each other
        for (0..self.solitons.items.len) |i| {
            if (self.coupled_systems.items.len >= MAX_COUPLED_SYSTEMS) break;
            for (i + 1..self.solitons.items.len) |j| {
                if (self.coupled_systems.items.len >= MAX_COUPLED_SYSTEMS) break;

                const a = self.solitons.items[i];
                const b = self.solitons.items[j];

                const dx = @as(i32, @intCast(a.x)) - @as(i32, @intCast(b.x));
                const dy = @as(i32, @intCast(a.y)) - @as(i32, @intCast(b.y));
                const dz = @as(i32, @intCast(a.z)) - @as(i32, @intCast(b.z));
                const dist_sq = dx * dx + dy * dy + dz * dz;

                // Couple if within 3 cells (3² = 9)
                if (dist_sq <= 9 and dist_sq > 0) {
                    const coupling = 1.0 / @as(f64, @floatFromInt(@as(u32, @intCast(dist_sq))));
                    try self.coupled_systems.append(.{
                        .soliton_a = a,
                        .soliton_b = b,
                        .coupling_strength = coupling,
                    });
                }
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BreakoutEngine init creates empty lists" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    var engine = try BreakoutEngine.init(std.testing.allocator, &grid);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.solitons.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.higgs_modes.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.coupled_systems.items.len);
}

test "BreakoutEngine generates solitons from high-coherence cells" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(7, 7, 7, 1.0);
    grid.setValue(8, 7, 7, 0.8);
    grid.setValue(7, 8, 7, 0.6);
    grid.setValue(0, 0, 0, 0.1); // below threshold

    var engine = try BreakoutEngine.init(std.testing.allocator, &grid);
    defer engine.deinit();

    try engine.generateSolitons();

    // Solitons at cells with value > 0.5 * max(1.0) = 0.5
    try std.testing.expectEqual(@as(usize, 3), engine.solitons.items.len);
}

test "BreakoutEngine limits solitons to 30" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    // Set 50 cells to 1.0
    for (0..50) |i| {
        grid.setValue(i % 15, (i / 15) % 15, (i / 225) % 15, 1.0);
    }

    var engine = try BreakoutEngine.init(std.testing.allocator, &grid);
    defer engine.deinit();

    try engine.generateSolitons();
    try std.testing.expectEqual(@as(usize, 30), engine.solitons.items.len);
}

test "BreakoutEngine generates Higgs modes at boundary cells" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(0, 0, 0, 1.0); // boundary cell
    grid.setValue(14, 14, 14, 0.5); // boundary cell
    grid.setValue(7, 7, 7, 1.0); // interior cell (no Higgs)

    var engine = try BreakoutEngine.init(std.testing.allocator, &grid);
    defer engine.deinit();

    try engine.generateHiggsModes();

    // Only boundary cells generate Higgs modes
    try std.testing.expectEqual(@as(usize, 2), engine.higgs_modes.items.len);
    try std.testing.expect(engine.total_generated_mass > 0.0);
}

test "BreakoutEngine couples nearby solitons" {
    var grid = try torus.TorusGrid.init(std.testing.allocator, 15);
    defer grid.deinit();

    grid.setValue(7, 7, 7, 1.0);
    grid.setValue(8, 7, 7, 1.0); // distance 1
    grid.setValue(10, 7, 7, 1.0); // distance 3
    grid.setValue(14, 7, 7, 1.0); // distance 7 (too far)

    var engine = try BreakoutEngine.init(std.testing.allocator, &grid);
    defer engine.deinit();

    try engine.generateSolitons();
    try engine.generateHiggsModes();
    try engine.executeBreakout(false, 0);

    // Couples: (7,8) dist=1, (7,10) dist=3, (8,10) dist=2
    // (7,14), (8,14), (10,14) are all > 3, so not coupled
    // But limited to MAX_COUPLED_SYSTEMS=7
    try std.testing.expect(engine.coupled_systems.items.len > 0);
    try std.testing.expect(engine.coupled_systems.items.len <= 7);
}

test "BreakoutEngine max solitons = 30 connects to E8/8" {
    // 240 E8 roots / 8 octonion dimensions = 30
    try std.testing.expectEqual(@as(usize, 30), MAX_SOLITONS);
    try std.testing.expectEqual(@as(usize, 240 / 8), MAX_SOLITONS);
}

test "BreakoutEngine max Higgs = 15 connects to layer parameter" {
    try std.testing.expectEqual(@as(usize, 15), MAX_HIGGS_MODES);
}

test "BreakoutEngine max coupled = 7 connects to octonion triads" {
    try std.testing.expectEqual(@as(usize, 7), MAX_COUPLED_SYSTEMS);
}
