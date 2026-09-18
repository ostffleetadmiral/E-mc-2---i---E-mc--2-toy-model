//! dim_3d_space.zig — 3D Space (Vector/S³ dimension).
//!
//! The 3D dimension handles the 15³ lattice grid and spatial coordinates.
//! Algebra: Vector algebra (S³), SU(2) weak force copy 2/isospin.
//! Purpose: Spatial coordinates, lattice grid operations.
//!
//! All arithmetic is integer-only. No floating-point in core paths.
//! License: CC BY-NC-SA 4.0

const std = @import("std");

/// A 3D spatial coordinate (x, y, z).
pub const Coord = struct {
    x: u32,
    y: u32,
    z: u32,

    pub fn fromParts(x: u32, y: u32, z: u32) Coord {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn eql(self: Coord, other: Coord) bool {
        return self.x == other.x and self.y == other.y and self.z == other.z;
    }
};

/// The 3D space grid — wraps the 15³ lattice.
pub const SpaceGrid = struct {
    /// Edge length of the cubic lattice (15 for the standard lattice).
    edge: u32,
    /// Total number of nodes (edge³).
    node_count: u64,

    pub fn init(edge: u32) SpaceGrid {
        return .{
            .edge = edge,
            .node_count = @as(u64, edge) * @as(u64, edge) * @as(u64, edge),
        };
    }

    /// Returns the linear index of a 3D coordinate.
    pub fn indexOf(self: SpaceGrid, c: Coord) u64 {
        return @as(u64, c.x) + @as(u64, c.y) * self.edge + @as(u64, c.z) * self.edge * self.edge;
    }

    /// Returns the 3D coordinate from a linear index.
    pub fn coordOf(self: SpaceGrid, index: u64) Coord {
        const z = index / (@as(u64, self.edge) * @as(u64, self.edge));
        const rem = index % (@as(u64, self.edge) * @as(u64, self.edge));
        const y = rem / self.edge;
        const x = rem % self.edge;
        return .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) };
    }

    /// Checks if a coordinate is on the boundary of the grid.
    pub fn isBoundary(self: SpaceGrid, c: Coord) bool {
        const e = self.edge - 1;
        return c.x == 0 or c.x == e or c.y == 0 or c.y == e or c.z == 0 or c.z == e;
    }

    /// Returns the center coordinate of the grid.
    pub fn center(self: SpaceGrid) Coord {
        return .{ .x = self.edge / 2, .y = self.edge / 2, .z = self.edge / 2 };
    }

    /// Returns the Manhattan distance between two coordinates.
    pub fn manhattan(self: SpaceGrid, a: Coord, b: Coord) u32 {
        _ = self;
        const dx: u32 = if (a.x > b.x) a.x - b.x else b.x - a.x;
        const dy: u32 = if (a.y > b.y) a.y - b.y else b.y - a.y;
        const dz: u32 = if (a.z > b.z) a.z - b.z else b.z - a.z;
        return dx + dy + dz;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Coord: fromParts and eql" {
    const c1 = Coord.fromParts(1, 2, 3);
    const c2 = Coord.fromParts(1, 2, 3);
    const c3 = Coord.fromParts(4, 5, 6);
    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(!c1.eql(c3));
}

test "SpaceGrid: init 15³" {
    const grid = SpaceGrid.init(15);
    try std.testing.expect(grid.edge == 15);
    try std.testing.expect(grid.node_count == 3375);
}

test "SpaceGrid: indexOf and coordOf roundtrip" {
    const grid = SpaceGrid.init(15);
    const c = Coord.fromParts(3, 7, 11);
    const idx = grid.indexOf(c);
    const recovered = grid.coordOf(idx);
    try std.testing.expect(c.eql(recovered));
}

test "SpaceGrid: isBoundary" {
    const grid = SpaceGrid.init(15);
    try std.testing.expect(grid.isBoundary(Coord.fromParts(0, 0, 0)));
    try std.testing.expect(grid.isBoundary(Coord.fromParts(14, 7, 7)));
    try std.testing.expect(!grid.isBoundary(Coord.fromParts(7, 7, 7)));
}

test "SpaceGrid: center" {
    const grid = SpaceGrid.init(15);
    const c = grid.center();
    try std.testing.expect(c.x == 7 and c.y == 7 and c.z == 7);
}

test "SpaceGrid: manhattan distance" {
    const grid = SpaceGrid.init(15);
    const a = Coord.fromParts(0, 0, 0);
    const b = Coord.fromParts(3, 4, 5);
    try std.testing.expect(grid.manhattan(a, b) == 12);
}
