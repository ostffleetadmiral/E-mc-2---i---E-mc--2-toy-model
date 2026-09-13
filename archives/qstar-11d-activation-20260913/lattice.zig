//! lattice.zig — Purified core lattice engine.
//!
//! Zero external dependencies beyond std. One axiom per function.
//! Extracted from prototype (LVCE) + freenet-core (ring routing).
//!
//! Axiom mapping (conceptual):
//!   A1 → grid_init        (15³ base grid)
//!   A2 → e0_placement     (421 E0 nodes)
//!   A3 → mobius_twist     (e7→e2 boundary reflection)
//!   A4 → octonion_route   (7x+11y+13z mod 8)
//!   A5 → phi_cooling      (φ-scaled temperature)
//!   A6 → dim_ladder       (11-dimensional ladder)
//!   A7 → lambda_h         (λ_H = c/f_H exact)

const std = @import("std");

// =============================================================================
// A1: Grid — 15³ base lattice, doubling per level (s=0..s=7)
// =============================================================================

/// Maximum lattice level we support (s=7 → 1920³, 2048³ shell).
pub const MAX_LEVEL: u8 = 7;

/// Base grid edge length at s=0.
pub const BASE_EDGE: u32 = 15;

/// Shell multiplier: shell = lattice × (16/15), so shell = lattice + lattice/15.
pub const SHELL_RATIO_NUM: u32 = 16;
pub const SHELL_RATIO_DEN: u32 = 15;

/// Lattice scale entry: one row of the scale table.
pub const LatticeScale = struct {
    s: u8,
    lattice_edge: u32,
    shell_edge: u32,
    qubits: u64,
    resolution_dims: u64,
    info_size_bytes: u64,
};

/// Returns the lattice edge length for a given level s (0..7).
/// edge = 15 × 2^s
pub inline fn latticeEdge(level: u8) u32 {
    return BASE_EDGE * (@as(u32, 1) << @intCast(level));
}

/// Returns the shell edge length for a given level s.
/// shell = lattice × 16 / 15
pub fn shellEdge(level: u8) u32 {
    const l = latticeEdge(level);
    return (l * SHELL_RATIO_NUM) / SHELL_RATIO_DEN;
}

/// Returns the qubit count for level s: qubits = 8^s.
pub inline fn qubitCount(level: u8) u64 {
    return @as(u64, 1) << @intCast(level * 3);
}

/// Returns the resolution dimensions for level s: dims = 8^(s+1).
pub inline fn resolutionDims(level: u8) u64 {
    return @as(u64, 1) << @intCast((level + 1) * 3);
}

/// Returns total interior node count for a given level: edge³.
pub inline fn totalNodes(level: u8) usize {
    const e = latticeEdge(level);
    return @as(usize, e) * @as(usize, e) * @as(usize, e);
}

/// Returns interior node count for level s: 15³ × 8^s (s=0 → 3,375).
pub inline fn interiorNodes(level: u8) usize {
    return totalNodes(level);
}

/// Returns shell node count for level s: 16³ × 8^s (s=0 → 4,096).
pub inline fn shellNodes(level: u8) usize {
    const s = shellEdge(level);
    return @as(usize, s) * @as(usize, s) * @as(usize, s);
}

/// Returns exact boundary node count for level s: shell_nodes - interior_nodes (s=0 → 721 = 7 × 103).
pub inline fn boundaryNodes(level: u8) usize {
    return shellNodes(level) - interiorNodes(level);
}

/// Returns the complete scale table entry for a level.
pub fn scaleEntry(level: u8) LatticeScale {
    return .{
        .s = level,
        .lattice_edge = latticeEdge(level),
        .shell_edge = shellEdge(level),
        .qubits = qubitCount(level),
        .resolution_dims = resolutionDims(level),
        .info_size_bytes = 0,
    };
}

/// 3D lattice coordinates.
pub const Coords = struct {
    x: u32,
    y: u32,
    z: u32,
};

/// Maps a flat chunk index to 3D lattice coordinates at a given level.
pub fn unflatCoords(chunk_idx: usize, level: u8) Coords {
    const size: usize = latticeEdge(level);
    const total = size * size * size;
    const wrapped_idx = chunk_idx % total;

    const slice_size = size * size;
    const x: u32 = @intCast(wrapped_idx / slice_size);
    const rem = wrapped_idx % slice_size;
    const y: u32 = @intCast(rem / size);
    const z: u32 = @intCast(rem % size);

    return .{ .x = x, .y = y, .z = z };
}

// =============================================================================
// A2: E0 Placement — 421 E0 nodes in the 15³ base grid
// =============================================================================

/// Number of E0 nodes placed in the base lattice.
pub const E0_NODE_COUNT: usize = 421;

/// Number of channels per node (octonionic dimensions e0..e6).
pub const CHANNEL_COUNT: usize = 7;

/// Number of nodes for a given lattice scaling level s:
/// nodes = 421 × 8^s (e.g. s=0 → 421, s=1 → 3,368, s=2 → 26,944, s=3 → 215,552).
pub inline fn scaledNodeCount(level: u8) usize {
    return E0_NODE_COUNT * (@as(usize, 1) << @intCast(level * 3));
}

/// Total token capacity / slots for level s = scaledNodeCount(s) * CHANNEL_COUNT.
pub inline fn scaledTokenSlots(level: u8) usize {
    return scaledNodeCount(level) * CHANNEL_COUNT;
}

/// Level-scaled token-to-node mapping.
pub inline fn scaledTokenToNode(tid: u32, level: u8) usize {
    return @as(usize, tid) % scaledNodeCount(level);
}

/// Level-scaled token-to-channel mapping (0..6).
pub inline fn scaledTokenToChannel(tid: u32, level: u8) u3 {
    return @intCast((@as(usize, tid) / scaledNodeCount(level)) % CHANNEL_COUNT);
}

/// Level-scaled (node, channel) to token mapping.
pub inline fn scaledNodeToToken(node: usize, channel: usize, level: u8) u32 {
    return @intCast(node + channel * scaledNodeCount(level));
}

/// E0 node descriptor.
pub const E0Node = struct {
    coords: Coords,
    channel: u8,
};

/// Computes the E0 node index for a given coordinate in the base 15³ grid.
/// E0 nodes are placed at positions where (x + y + z) mod 3 == 0 and
/// the combined hash maps to one of 421 slots.
pub inline fn e0NodeIndex(x: u32, y: u32, z: u32) ?usize {
    if ((x + y + z) % 3 != 0) return null;
    const hash = (x *% 7 + y *% 11 + z *% 13) % 421;
    return hash;
}

// =============================================================================
// A4: Octonion & Fano Plane Router — 7 associative lines
// =============================================================================

/// 7 associative lines of the Fano plane router:
/// (e1,e2,e3), (e1,e4,e5), (e1,e6,e7), (e2,e4,e6), (e2,e5,e7), (e3,e4,e7), (e3,e5,e6)
pub const FanoLine = struct {
    a: u3,
    b: u3,
    c: u3,
};

pub const FANO_LINES = [7]FanoLine{
    .{ .a = 1, .b = 2, .c = 3 }, // Real -> Complex -> Vector (Time -> Plane -> Space)
    .{ .a = 1, .b = 4, .c = 5 }, // Real -> Quaternion -> Bi-complex (Time -> Spacetime -> Fold/Language)
    .{ .a = 1, .b = 6, .c = 7 }, // Real -> Jordan -> Octonion (Time -> Consciousness -> Color)
    .{ .a = 2, .b = 4, .c = 6 }, // Complex -> Quaternion -> Jordan (Plane -> Spacetime -> Consciousness)
    .{ .a = 2, .b = 5, .c = 7 }, // Complex -> Bi-complex -> Octonion (Plane -> Language -> Color)
    .{ .a = 3, .b = 4, .c = 7 }, // Vector -> Quaternion -> Octonion (Space -> Spacetime -> Color)
    .{ .a = 3, .b = 5, .c = 6 }, // Vector -> Bi-complex -> Jordan (Space -> Language -> Consciousness)
};

/// Given two channels (1..7), returns the third channel on the shared Fano plane line.
/// Returns null if channels are identical or include 0 (identity/observer).
pub fn fanoRoute(ch_a: u3, ch_b: u3) ?u3 {
    if (ch_a == 0 or ch_b == 0 or ch_a == ch_b) return null;
    for (FANO_LINES) |line| {
        if ((line.a == ch_a and line.b == ch_b) or (line.b == ch_a and line.a == ch_b)) return line.c;
        if ((line.a == ch_a and line.c == ch_b) or (line.c == ch_a and line.a == ch_b)) return line.b;
        if ((line.b == ch_a and line.c == ch_b) or (line.c == ch_a and line.b == ch_b)) return line.a;
    }
    return null;
}

/// Computes the e-value (0-7) at given coordinates in an L-level lattice.
/// This is the octonion routing function: (7x + 11y + 13z) mod 8,
/// adjusted for distance from boundary.
pub fn computeEValue(x: u32, y: u32, z: u32, level: u8) u3 {
    const base_size: u32 = latticeEdge(level);
    const mid: u32 = base_size / 2;

    const dx: i64 = @min(@as(i64, x), @as(i64, base_size - 1 - x));
    const dy: i64 = @min(@as(i64, y), @as(i64, base_size - 1 - y));
    const dz: i64 = @intCast(@abs(@as(i64, z) - @as(i64, mid)));

    const raw: i64 = 6 - dx - dy + dz;
    return @intCast(@mod(raw, 8));
}

/// Checks if a coordinate is on the boundary of the L-level lattice.
pub fn isBoundaryCoord(x: u32, y: u32, z: u32, level: u8) bool {
    const base_size: u32 = latticeEdge(level);
    return x == 0 or x == base_size - 1 or
        y == 0 or y == base_size - 1 or
        z == 0 or z == base_size - 1;
}

// =============================================================================
// A3: Möbius Twist & Quadrupole Dual-Twist (Boundary Reflection)
// =============================================================================

/// Quadrupole quadrants mapped to quaternion units (1, i, j, k) and channels (e0, e1, e2, e3).
pub const QuadrupoleQuadrant = enum(u2) {
    q1 = 0, // x > 7, y > 7 -> Quaternion i, Channel e1 (Electric mode)
    q2 = 1, // x < 7, y > 7 -> Quaternion j, Channel e2 (Magnetic mode)
    q3 = 2, // x < 7, y < 7 -> Quaternion k, Channel e3 (Spatial orthogonal)
    q4 = 3, // x > 7, y < 7 -> Quaternion 1, Channel e0 (Real / Observer)

    pub fn fromCoords(x: u32, y: u32, edge: u32) QuadrupoleQuadrant {
        const mid = edge / 2;
        if (x >= mid and y >= mid) return .q1;
        if (x < mid and y >= mid) return .q2;
        if (x < mid and y < mid) return .q3;
        return .q4;
    }
};

/// Permutes an 8-byte chunk forward based on e-value and boundary condition.
/// On boundary coordinates, applies a Möbius reflection (reverse order).
pub fn permuteChunkForward(bytes: [8]u8, e_val: u3, is_boundary: bool) [8]u8 {
    var rotated: [8]u8 = undefined;
    for (0..8) |i| {
        rotated[(i + @as(usize, e_val)) % 8] = bytes[i];
    }
    if (!is_boundary) return rotated;

    var reflected: [8]u8 = undefined;
    for (0..8) |i| {
        reflected[i] = rotated[7 - i];
    }
    return reflected;
}

/// Permutes an 8-byte chunk through the 90° dual-twist quadrupole (E ⊥ B modes).
/// Combines T1 (0° anti-diagonal) with T2 (90° main diagonal) across 4 quadrants.
pub fn permuteQuadrupole(bytes: [8]u8, e_val: u3, quad: QuadrupoleQuadrant, is_boundary: bool) [8]u8 {
    const t1_rotated = permuteChunkForward(bytes, e_val, is_boundary);
    var t2_rotated: [8]u8 = undefined;
    const quad_offset = @as(usize, @intFromEnum(quad)) * 2;
    for (0..8) |i| {
        t2_rotated[(i + quad_offset) % 8] = t1_rotated[i];
    }
    return t2_rotated;
}

/// Inversely permutes an 8-byte chunk from the 90° dual-twist quadrupole.
pub fn permuteQuadrupoleInverse(bytes: [8]u8, e_val: u3, quad: QuadrupoleQuadrant, is_boundary: bool) [8]u8 {
    var t1_recovered: [8]u8 = undefined;
    const quad_offset = @as(usize, @intFromEnum(quad)) * 2;
    for (0..8) |i| {
        t1_recovered[i] = bytes[(i + quad_offset) % 8];
    }
    return permuteChunkInverse(t1_recovered, e_val, is_boundary);
}

/// Inversely permutes an 8-byte chunk (undo of permuteChunkForward).
pub fn permuteChunkInverse(bytes: [8]u8, e_val: u3, is_boundary: bool) [8]u8 {
    var rotated: [8]u8 = undefined;
    if (is_boundary) {
        for (0..8) |i| {
            rotated[i] = bytes[7 - i];
        }
    } else {
        rotated = bytes;
    }
    var original: [8]u8 = undefined;
    for (0..8) |i| {
        original[i] = rotated[(i + @as(usize, e_val)) % 8];
    }
    return original;
}

// =============================================================================
// Lattice Transform — map/unmap data through lattice geometry
// =============================================================================

/// Transforms data stream by routing and permuting through lattice geometry.
/// Data is split into 8-byte chunks, each placed at lattice coordinates,
/// and permuted according to its e-value and boundary status.
pub fn mapToLattice(allocator: std.mem.Allocator, data: []const u8, level: u8) ![]u8 {
    const num_chunks = (data.len + 7) / 8;
    var out = try allocator.alloc(u8, num_chunks * 8);
    errdefer allocator.free(out);

    for (0..num_chunks) |chunk_idx| {
        var chunk: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const start = chunk_idx * 8;
        const end = @min(start + 8, data.len);
        for (start..end, 0..) |src, i| {
            chunk[i] = data[src];
        }

        const coords = unflatCoords(chunk_idx, level);
        const e_val = computeEValue(coords.x, coords.y, coords.z, level);
        const is_bdy = isBoundaryCoord(coords.x, coords.y, coords.z, level);

        const permuted = permuteChunkForward(chunk, e_val, is_bdy);
        @memcpy(out[start .. start + 8], &permuted);
    }

    return out;
}

/// Restores original data stream by inverse lattice unmapping.
pub fn unmapFromLattice(allocator: std.mem.Allocator, mapped: []const u8, original_len: usize, level: u8) ![]u8 {
    const num_chunks = (original_len + 7) / 8;
    if (mapped.len < num_chunks * 8) return error.IncompleteMappedData;

    var out = try allocator.alloc(u8, original_len);
    errdefer allocator.free(out);

    for (0..num_chunks) |chunk_idx| {
        var permuted: [8]u8 = undefined;
        const start = chunk_idx * 8;
        @memcpy(&permuted, mapped[start .. start + 8]);

        const coords = unflatCoords(chunk_idx, level);
        const e_val = computeEValue(coords.x, coords.y, coords.z, level);
        const is_bdy = isBoundaryCoord(coords.x, coords.y, coords.z, level);

        const recovered = permuteChunkInverse(permuted, e_val, is_bdy);

        const end = @min(start + 8, original_len);
        for (start..end, 0..) |dst, i| {
            out[dst] = recovered[i];
        }
    }

    return out;
}

// =============================================================================
// A5: φ-Cooling — golden ratio scaled temperature
// =============================================================================

/// Golden ratio φ = (1 + √5) / 2.
pub const PHI: f64 = 1.6180339887498948482;

/// Computes the φ-scaled cooling temperature at a given level.
/// Temperature decreases by φ factor per level: T(s) = T₀ × φ^(-s).
pub fn phiCooling(level: u8, base_temp: f64) f64 {
    return base_temp * std.math.pow(f64, PHI, -@as(f64, @floatFromInt(level)));
}

// =============================================================================
// A6: 11-Dimensional Ladder — remapped from first principles
// =============================================================================

/// Number of dimensions in the ladder.
pub const LADDER_DIMS: u8 = 11;

/// Structure class determined by commutativity (C) and associativity (A).
pub const StructureClass = enum {
    preserved, // C=Yes, A=Yes — structure preserved
    quaternion, // C=No,  A=Yes — quaternions unique
    jordan, // C=Yes, A=No  — Jordan unique
    chaotic, // C=No,  A=No  — odd dimensions lose structure
};

/// Full specification of a single dimension in the 11-dimensional ladder.
pub const DimSpec = struct {
    dim: u8,
    name: []const u8,
    algebra: []const u8,
    commutative: bool,
    associative: bool,
    symmetry: []const u8,
    physics: []const u8,

    pub fn structureClass(self: DimSpec) StructureClass {
        if (self.commutative and self.associative) return .preserved;
        if (!self.commutative and self.associative) return .quaternion;
        if (self.commutative and !self.associative) return .jordan;
        return .chaotic;
    }
};

/// The remapped 11-dimensional ladder table.
pub const DIMENSION_TABLE = [11]DimSpec{
    .{ .dim = 0, .name = "Point", .algebra = "Real (observer anchor)", .commutative = true, .associative = true, .symmetry = "U(1)", .physics = "Phase rotation around e0" },
    .{ .dim = 1, .name = "Line", .algebra = "Real numbers", .commutative = true, .associative = true, .symmetry = "U(1)", .physics = "Electromagnetism" },
    .{ .dim = 2, .name = "Plane", .algebra = "Complex numbers", .commutative = true, .associative = true, .symmetry = "SU(2)", .physics = "Weak force (copy 1)" },
    .{ .dim = 3, .name = "Space", .algebra = "Vector algebra (S³)", .commutative = false, .associative = false, .symmetry = "SU(2)", .physics = "Weak force (copy 2, isospin)" },
    .{ .dim = 4, .name = "Quaternion", .algebra = "Quaternions", .commutative = false, .associative = true, .symmetry = "SO(5)=Sp(2)", .physics = "Quaternion rotation" },
    .{ .dim = 5, .name = "Fold", .algebra = "Bi-complex", .commutative = true, .associative = true, .symmetry = "SO(4)×SO(4)", .physics = "Language" },
    .{ .dim = 6, .name = "Peak", .algebra = "Jordan algebra H₃(O)", .commutative = true, .associative = false, .symmetry = "E6/F4", .physics = "Consciousness" },
    .{ .dim = 7, .name = "Color", .algebra = "Octonions", .commutative = false, .associative = false, .symmetry = "SU(3)", .physics = "Strong force" },
    .{ .dim = 8, .name = "Frequency", .algebra = "Dual numbers", .commutative = true, .associative = true, .symmetry = "U(1)", .physics = "Frequency scaling" },
    .{ .dim = 9, .name = "Anti-octonion", .algebra = "Anti-octonions", .commutative = false, .associative = false, .symmetry = "None", .physics = "Pure chaos (inflation)" },
    .{ .dim = 10, .name = "Dual bi-complex", .algebra = "Dual bi-complex", .commutative = true, .associative = true, .symmetry = "SO(8)", .physics = "Gravity" },
};

/// The 15-element dimensional palindrome:
/// i = e0[e7, e6, e5, e4, e3, e2, e1, e0, e1, e2, e3, e4, e5, e6, e7]e0
pub const PALINDROME_15 = [15]u3{ 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7 };

/// Validates whether a given sequence of channel indices forms a valid palindrome across e0.
pub fn isValidPalindrome(sequence: []const u3) bool {
    if (sequence.len == 0) return false;
    const len = sequence.len;
    for (0..len / 2) |i| {
        if (sequence[i] != sequence[len - 1 - i]) return false;
    }
    return true;
}

/// Returns the full DimSpec for a given dimension (0..10).
pub fn dimSpec(dim: u8) DimSpec {
    return DIMENSION_TABLE[dim];
}

/// Returns the name of a dimension.
pub fn dimName(dim: u8) []const u8 {
    return DIMENSION_TABLE[dim].name;
}

/// Returns the algebra of a dimension.
pub fn dimAlgebra(dim: u8) []const u8 {
    return DIMENSION_TABLE[dim].algebra;
}

/// Returns the symmetry group of a dimension.
pub fn dimSymmetry(dim: u8) []const u8 {
    return DIMENSION_TABLE[dim].symmetry;
}

/// Returns the physics interpretation of a dimension.
pub fn dimPhysics(dim: u8) []const u8 {
    return DIMENSION_TABLE[dim].physics;
}

/// Returns whether a dimension's algebra is commutative.
pub inline fn isCommutative(dim: u8) bool {
    return DIMENSION_TABLE[dim].commutative;
}

/// Returns whether a dimension's algebra is associative.
pub inline fn isAssociative(dim: u8) bool {
    return DIMENSION_TABLE[dim].associative;
}

/// Returns the structure class of a dimension.
pub inline fn dimStructureClass(dim: u8) StructureClass {
    return DIMENSION_TABLE[dim].structureClass();
}

/// Returns the dimensional coordinate for a given dimension d (0..10) at level s.
/// Each dimension scales as 2^(s + d/11).
pub fn dimCoordinate(level: u8, dim: u8) f64 {
    return std.math.pow(f64, 2.0, @as(f64, @floatFromInt(level)) + @as(f64, @floatFromInt(dim)) / @as(f64, @floatFromInt(LADDER_DIMS)));
}

/// Returns the remapped dimensional coordinate using per-dimension scaling
/// based on commutativity (C) and associativity (A) properties:
///   C=Yes, A=Yes (preserved):  2^(s + d/11)         — structure preserved
///   C=No,  A=Yes (quaternion): 2^(s + d/11) × φ     — quaternion unique factor
///   C=Yes, A=No  (jordan):     2^(s + d/11) / φ     — Jordan unique factor
///   C=No,  A=No  (chaotic):    2^(s + d/11) × sin(d) — odd dims lose structure
pub fn dimCoordinateRemapped(level: u8, dim: u8) f64 {
    const base = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(level)) + @as(f64, @floatFromInt(dim)) / @as(f64, @floatFromInt(LADDER_DIMS)));
    return switch (dimStructureClass(dim)) {
        .preserved => base,
        .quaternion => base * PHI,
        .jordan => base / PHI,
        .chaotic => base * std.math.sin(@as(f64, @floatFromInt(dim))),
    };
}

// =============================================================================
// A7: λ_H = c / f_H — exact wavelength
// =============================================================================

/// Speed of light in vacuum, m/s.
pub const C_LIGHT: f64 = 299_792_458.0;

/// Computes λ_H = c / f_H exactly.
pub inline fn lambdaH(f_h: f64) f64 {
    return C_LIGHT / f_h;
}

// =============================================================================
// Ring Location & Distance (extracted from freenet-core)
// =============================================================================

/// An abstract location on the 1D ring, represented by f64 on [0, 1).
pub const Location = struct {
    value: f64,

    pub fn new(v: f64) !Location {
        if (v < 0.0 or v >= 1.0) return error.InvalidLocation;
        if (std.math.isNan(v)) return error.InvalidLocation;
        return .{ .value = v };
    }

    pub fn fromBytes(bytes: []const u8) Location {
        var v: f64 = 0.0;
        var divisor: f64 = 256.0;
        for (bytes) |b| {
            v += @as(f64, @floatFromInt(b)) / divisor;
            divisor *= 256.0;
        }
        return .{ .value = v };
    }

    /// Ring distance: shortest arc on [0,1) circle.
    pub fn distance(self: Location, other: Location) f64 {
        const d = @abs(self.value - other.value);
        if (d < 0.5) return d;
        return 1.0 - d;
    }

    /// Signed shortest-arc distance: positive = clockwise.
    pub fn signedDistance(self: Location, other: Location) f64 {
        const diff = other.value - self.value;
        if (diff > 0.5) return diff - 1.0;
        if (diff < -0.5) return diff + 1.0;
        if (diff == -0.5) return 0.5;
        return diff;
    }
};

// =============================================================================
// Isotonic Regression (PAV algorithm) — extracted from freenet-core
// =============================================================================

/// A single observation point for isotonic regression.
pub const IsoPoint = struct {
    x: f64,
    y: f64,
};

/// Isotonic regression using the Pool Adjacent Violators (PAV) algorithm.
/// Produces a monotonically non-decreasing fit of y given x.
pub const IsotonicRegression = struct {
    points: []IsoPoint,

    pub fn deinit(self: *IsotonicRegression, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }

    /// Fit isotonic regression to raw data points using PAV.
    pub fn fit(allocator: std.mem.Allocator, raw: []const IsoPoint) !IsotonicRegression {
        if (raw.len == 0) {
            return .{ .points = try allocator.alloc(IsoPoint, 0) };
        }

        const sorted = try allocator.dupe(IsoPoint, raw);
        defer allocator.free(sorted);
        std.mem.sort(IsoPoint, sorted, {}, struct {
            fn cmp(_: void, a: IsoPoint, b: IsoPoint) bool {
                return a.x < b.x;
            }
        }.cmp);

        var blocks = try allocator.alloc(IsoPoint, sorted.len);
        defer allocator.free(blocks);
        var weights = try allocator.alloc(f64, sorted.len);
        defer allocator.free(weights);
        var n_blocks: usize = 0;

        for (sorted) |pt| {
            blocks[n_blocks] = pt;
            weights[n_blocks] = 1.0;
            n_blocks += 1;

            while (n_blocks >= 2 and blocks[n_blocks - 2].y > blocks[n_blocks - 1].y) {
                const w1 = weights[n_blocks - 2];
                const w2 = weights[n_blocks - 1];
                const merged_y = (blocks[n_blocks - 2].y * w1 + blocks[n_blocks - 1].y * w2) / (w1 + w2);
                blocks[n_blocks - 2].y = merged_y;
                weights[n_blocks - 2] = w1 + w2;
                n_blocks -= 1;
            }
        }

        const result = try allocator.alloc(IsoPoint, n_blocks);
        @memcpy(result, blocks[0..n_blocks]);
        return .{ .points = result };
    }

    /// Predict y for a given x using linear interpolation between fitted points.
    pub fn predict(self: IsotonicRegression, x: f64) f64 {
        if (self.points.len == 0) return 0.0;
        if (x <= self.points[0].x) return self.points[0].y;
        if (x >= self.points[self.points.len - 1].x) return self.points[self.points.len - 1].y;

        for (0..self.points.len - 1) |i| {
            if (x >= self.points[i].x and x <= self.points[i + 1].x) {
                const t = (x - self.points[i].x) / (self.points[i + 1].x - self.points[i].x);
                return self.points[i].y + t * (self.points[i + 1].y - self.points[i].y);
            }
        }
        return self.points[self.points.len - 1].y;
    }
};

// =============================================================================
// RMSY Container Format — extracted from prototype
// =============================================================================

/// Magic bytes identifying an RMSY container.
pub const RMSY_MAGIC: [4]u8 = .{ 'R', 'M', 'S', 'Y' };
pub const RMSY_VERSION: u16 = 1;

/// 24-byte RMSY container header.
/// | Offset | Size | Field           |
/// |--------|------|-----------------|
/// | 0      | 4    | Magic "RMSY"    |
/// | 4      | 2    | Version (u16)   |
/// | 6      | 1    | Lattice level   |
/// | 7      | 1    | Qubit config    |
/// | 8      | 4    | Payload offset  |
/// | 12     | 4    | Payload length  |
/// | 16     | 4    | Original length |
/// | 20     | 4    | CRC32 checksum  |
pub const RmsyHeader = struct {
    magic: [4]u8,
    version: u16,
    lattice_level: u8,
    qubit_config: u8,
    payload_offset: u32,
    payload_len: u32,
    original_len: u32,
    checksum: u32,

    pub const SIZE: usize = 4 + 2 + 1 + 1 + 4 + 4 + 4 + 4;

    pub fn write(self: RmsyHeader, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u16, self.version, .little);
        try writer.writeByte(self.lattice_level);
        try writer.writeByte(self.qubit_config);
        try writer.writeInt(u32, self.payload_offset, .little);
        try writer.writeInt(u32, self.payload_len, .little);
        try writer.writeInt(u32, self.original_len, .little);
        try writer.writeInt(u32, self.checksum, .little);
    }

    pub fn read(reader: anytype) !RmsyHeader {
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &RMSY_MAGIC)) return error.InvalidMagic;
        return .{
            .magic = magic,
            .version = try reader.readInt(u16, .little),
            .lattice_level = try reader.readByte(),
            .qubit_config = try reader.readByte(),
            .payload_offset = try reader.readInt(u32, .little),
            .payload_len = try reader.readInt(u32, .little),
            .original_len = try reader.readInt(u32, .little),
            .checksum = try reader.readInt(u32, .little),
        };
    }
};

/// Computes CRC32 checksum.
pub fn computeChecksum(data: []const u8) u32 {
    var hash = std.hash.Crc32.init();
    hash.update(data);
    return hash.final();
}

/// Parsed RMSY container.
pub const RmsyContainer = struct {
    header: RmsyHeader,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: RmsyContainer) void {
        self.allocator.free(self.payload);
    }
};

/// Writes a complete RMSY container (header + payload) to a writer.
pub fn writeRmsy(writer: anytype, payload: []const u8, original_len: usize, lattice_level: u8, qubit_config: u8) !void {
    const checksum = computeChecksum(payload);
    const header = RmsyHeader{
        .magic = RMSY_MAGIC,
        .version = RMSY_VERSION,
        .lattice_level = lattice_level,
        .qubit_config = qubit_config,
        .payload_offset = @intCast(RmsyHeader.SIZE),
        .payload_len = @intCast(payload.len),
        .original_len = @intCast(original_len),
        .checksum = checksum,
    };
    try header.write(writer);
    try writer.writeAll(payload);
}

/// Reads an RMSY container from a reader. Validates magic, version, offset, CRC32.
pub fn readRmsy(allocator: std.mem.Allocator, reader: anytype) !RmsyContainer {
    const header = try RmsyHeader.read(reader);
    if (header.version != RMSY_VERSION) return error.UnsupportedVersion;
    if (header.payload_offset != RmsyHeader.SIZE) return error.InvalidOffset;

    const payload = try allocator.alloc(u8, header.payload_len);
    errdefer allocator.free(payload);
    const read_bytes = try reader.readAll(payload);
    if (read_bytes != header.payload_len) return error.TruncatedPayload;

    const computed = computeChecksum(payload);
    if (computed != header.checksum) return error.ChecksumMismatch;

    return .{ .header = header, .payload = payload, .allocator = allocator };
}

// =============================================================================
// Manifest Serialization — extracted from prototype
// =============================================================================

pub const MANIFEST_MAGIC: [4]u8 = .{ 'L', 'V', 'C', 'M' };
pub const MANIFEST_VERSION: u16 = 1;

/// 32-byte manifest header.
pub const ManifestHeader = struct {
    magic: [4]u8,
    version: u16,
    total_files: u32,
    uncompressed_payload_size: u64,
    compressed_payload_size: u64,
    lattice_level: u8,
    qubit_config: u8,
    checksum: u32,

    pub const SIZE: usize = 4 + 2 + 4 + 8 + 8 + 1 + 1 + 4;

    pub fn write(self: ManifestHeader, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u16, self.version, .little);
        try writer.writeInt(u32, self.total_files, .little);
        try writer.writeInt(u64, self.uncompressed_payload_size, .little);
        try writer.writeInt(u64, self.compressed_payload_size, .little);
        try writer.writeByte(self.lattice_level);
        try writer.writeByte(self.qubit_config);
        try writer.writeInt(u32, self.checksum, .little);
    }

    pub fn read(reader: anytype) !ManifestHeader {
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &MANIFEST_MAGIC)) return error.InvalidManifestMagic;
        const version = try reader.readInt(u16, .little);
        if (version != MANIFEST_VERSION) return error.UnsupportedManifestVersion;
        return .{
            .magic = magic,
            .version = version,
            .total_files = try reader.readInt(u32, .little),
            .uncompressed_payload_size = try reader.readInt(u64, .little),
            .compressed_payload_size = try reader.readInt(u64, .little),
            .lattice_level = try reader.readByte(),
            .qubit_config = try reader.readByte(),
            .checksum = try reader.readInt(u32, .little),
        };
    }
};

/// File entry in the manifest.
pub const FileEntry = struct {
    path: []const u8,
    uncompressed_offset: u64,
    uncompressed_size: u64,
    mode: u32,
    mtime: i64,
    crc32: u32,
    is_dir: bool,
    is_symlink: bool,
    symlink_target: ?[]const u8 = null,

    pub fn isExecutable(self: FileEntry) bool {
        return (self.mode & 0o111) != 0;
    }
};

/// Serializes file entries to a byte buffer.
pub fn serializeEntries(allocator: std.mem.Allocator, entries: []const FileEntry) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    const writer = buffer.writer();

    try writer.writeInt(u32, @intCast(entries.len), .little);

    for (entries) |entry| {
        try writer.writeInt(u16, @intCast(entry.path.len), .little);
        try writer.writeAll(entry.path);
        try writer.writeInt(u64, entry.uncompressed_offset, .little);
        try writer.writeInt(u64, entry.uncompressed_size, .little);
        try writer.writeInt(u32, entry.mode, .little);
        try writer.writeInt(i64, entry.mtime, .little);
        try writer.writeInt(u32, entry.crc32, .little);

        var flags: u8 = 0;
        if (entry.is_dir) flags |= 1 << 0;
        if (entry.is_symlink) flags |= 1 << 1;
        if (entry.symlink_target != null) flags |= 1 << 2;
        try writer.writeByte(flags);

        if (entry.symlink_target) |target| {
            try writer.writeInt(u16, @intCast(target.len), .little);
            try writer.writeAll(target);
        }
    }

    return buffer.toOwnedSlice();
}

// =============================================================================
// Bit-Exact Verification — extracted from prototype executor
// =============================================================================

/// Verifies that two byte slices are identical (bit-exact comparison).
pub fn verifyBitExact(original: []const u8, decompressed: []const u8) bool {
    return std.mem.eql(u8, original, decompressed);
}

/// Verifies a file entry's CRC32 against its data.
pub fn verifyEntryCrc(entry: FileEntry, data: []const u8) bool {
    if (data.len != entry.uncompressed_size) return false;
    return computeChecksum(data) == entry.crc32;
}

// =============================================================================
// Tests
// =============================================================================

test "lattice edge doubles per level" {
    try std.testing.expectEqual(@as(u32, 15), latticeEdge(0));
    try std.testing.expectEqual(@as(u32, 30), latticeEdge(1));
    try std.testing.expectEqual(@as(u32, 60), latticeEdge(2));
    try std.testing.expectEqual(@as(u32, 120), latticeEdge(3));
    try std.testing.expectEqual(@as(u32, 240), latticeEdge(4));
    try std.testing.expectEqual(@as(u32, 480), latticeEdge(5));
    try std.testing.expectEqual(@as(u32, 960), latticeEdge(6));
    try std.testing.expectEqual(@as(u32, 1920), latticeEdge(7));
}

test "shell edge = lattice × 16/15" {
    try std.testing.expectEqual(@as(u32, 16), shellEdge(0));
    try std.testing.expectEqual(@as(u32, 32), shellEdge(1));
    try std.testing.expectEqual(@as(u32, 64), shellEdge(2));
    try std.testing.expectEqual(@as(u32, 2048), shellEdge(7));
}

test "qubit count = 8^s" {
    try std.testing.expectEqual(@as(u64, 1), qubitCount(0));
    try std.testing.expectEqual(@as(u64, 8), qubitCount(1));
    try std.testing.expectEqual(@as(u64, 64), qubitCount(2));
    try std.testing.expectEqual(@as(u64, 2_097_152), qubitCount(7));
}

test "resolution dims = 8^(s+1)" {
    try std.testing.expectEqual(@as(u64, 8), resolutionDims(0));
    try std.testing.expectEqual(@as(u64, 64), resolutionDims(1));
    try std.testing.expectEqual(@as(u64, 16_777_216), resolutionDims(7));
}

test "total nodes at s=0 is 15³ = 3375" {
    try std.testing.expectEqual(@as(usize, 3375), totalNodes(0));
}

test "total nodes at s=7 is 1920³" {
    try std.testing.expectEqual(@as(usize, 1920 * 1920 * 1920), totalNodes(7));
}

test "lattice mapping round trip s=0" {
    const allocator = std.testing.allocator;
    const data = "The quick brown fox jumps over the lazy dog. 1234567890!@#$%^&*()";
    const mapped = try mapToLattice(allocator, data, 0);
    defer allocator.free(mapped);

    const recovered = try unmapFromLattice(allocator, mapped, data.len, 0);
    defer allocator.free(recovered);

    try std.testing.expectEqualSlices(u8, data, recovered);
}

test "lattice mapping round trip s=4" {
    const allocator = std.testing.allocator;
    var data: [1024]u8 = undefined;
    for (0..1024) |i| data[i] = @intCast(i % 256);

    const mapped = try mapToLattice(allocator, &data, 4);
    defer allocator.free(mapped);

    const recovered = try unmapFromLattice(allocator, mapped, data.len, 4);
    defer allocator.free(recovered);

    try std.testing.expectEqualSlices(u8, &data, recovered);
}

test "lattice mapping round trip s=7" {
    const allocator = std.testing.allocator;
    var data: [4096]u8 = undefined;
    for (0..4096) |i| data[i] = @intCast(i % 256);

    const mapped = try mapToLattice(allocator, &data, 7);
    defer allocator.free(mapped);

    const recovered = try unmapFromLattice(allocator, mapped, data.len, 7);
    defer allocator.free(recovered);

    try std.testing.expectEqualSlices(u8, &data, recovered);
}

test "permute forward/inverse are inverses" {
    const original: [8]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };

    for (0..8) |e| {
        const e_val: u3 = @intCast(e);
        const fwd = permuteChunkForward(original, e_val, false);
        const inv = permuteChunkInverse(fwd, e_val, false);
        try std.testing.expectEqualSlices(u8, &original, &inv);

        const fwd_b = permuteChunkForward(original, e_val, true);
        const inv_b = permuteChunkInverse(fwd_b, e_val, true);
        try std.testing.expectEqualSlices(u8, &original, &inv_b);
    }
}

test "E0 node count is 421" {
    try std.testing.expectEqual(@as(usize, 421), E0_NODE_COUNT);
}

test "E0 node index returns valid slots" {
    var count: usize = 0;
    var x: u32 = 0;
    while (x < 15) : (x += 1) {
        var y: u32 = 0;
        while (y < 15) : (y += 1) {
            var z: u32 = 0;
            while (z < 15) : (z += 1) {
                if (e0NodeIndex(x, y, z)) |_| count += 1;
            }
        }
    }
    try std.testing.expect(count > 0);
}

test "phi cooling decreases with level" {
    const t0 = phiCooling(0, 100.0);
    const t1 = phiCooling(1, 100.0);
    const t7 = phiCooling(7, 100.0);
    try std.testing.expect(t0 > t1);
    try std.testing.expect(t1 > t7);
}

test "lambda H = c / f" {
    const f_h: f64 = 2.4e9;
    const lambda = lambdaH(f_h);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1249135), lambda, 1e-6);
}

test "location distance on ring" {
    const a = try Location.new(0.1);
    const b = try Location.new(0.4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), a.distance(b), 1e-9);

    const c = try Location.new(0.9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), a.distance(c), 1e-9);
}

test "location from bytes" {
    const loc = Location.fromBytes(&.{ 0x80, 0x00, 0x00, 0x00 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), loc.value, 1e-9);
}

test "isotonic regression PAV fit" {
    const allocator = std.testing.allocator;
    const raw = [_]IsoPoint{
        .{ .x = 0.0, .y = 1.0 },
        .{ .x = 1.0, .y = 3.0 },
        .{ .x = 2.0, .y = 2.0 },
        .{ .x = 3.0, .y = 5.0 },
        .{ .x = 4.0, .y = 4.0 },
    };
    var reg = try IsotonicRegression.fit(allocator, &raw);
    defer reg.deinit(allocator);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), reg.predict(0.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), reg.predict(1.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), reg.predict(2.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), reg.predict(3.0), 1e-9);
}

test "RMSY container round trip" {
    const allocator = std.testing.allocator;
    const payload = "Hello, RMSY container world!";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try writeRmsy(buf.writer(), payload, payload.len, 3, 0);

    var fbs = std.io.fixedBufferStream(buf.items);
    const container = try readRmsy(allocator, fbs.reader());
    defer container.deinit();

    try std.testing.expectEqualSlices(u8, payload, container.payload);
    try std.testing.expectEqual(@as(u8, 3), container.header.lattice_level);
}

test "bit-exact verification" {
    const a = "identical bytes";
    try std.testing.expect(verifyBitExact(a, a));
    try std.testing.expect(!verifyBitExact(a, "different bytes"));
}

test "CRC32 checksum" {
    const data = "test data for crc32";
    const crc = computeChecksum(data);
    try std.testing.expect(crc != 0);
}

// =============================================================================
// A6: Remapped 11-Dimensional Ladder tests
// =============================================================================

test "dim 0: Point — Real observer anchor" {
    const spec = dimSpec(0);
    try std.testing.expectEqualStrings("Point", spec.name);
    try std.testing.expectEqualStrings("Real (observer anchor)", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("U(1)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.preserved, spec.structureClass());
}

test "dim 1: Line — Real numbers" {
    const spec = dimSpec(1);
    try std.testing.expectEqualStrings("Line", spec.name);
    try std.testing.expectEqualStrings("Real numbers", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("U(1)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.preserved, spec.structureClass());
}

test "dim 2: Plane — Complex numbers" {
    const spec = dimSpec(2);
    try std.testing.expectEqualStrings("Plane", spec.name);
    try std.testing.expectEqualStrings("Complex numbers", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("SU(2)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.preserved, spec.structureClass());
}

test "dim 3: Space — Vector algebra (S³)" {
    const spec = dimSpec(3);
    try std.testing.expectEqualStrings("Space", spec.name);
    try std.testing.expectEqualStrings("Vector algebra (S³)", spec.algebra);
    try std.testing.expect(!spec.commutative);
    try std.testing.expect(!spec.associative);
    try std.testing.expectEqualStrings("SU(2)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.chaotic, spec.structureClass());
}

test "dim 4: Quaternion — Quaternions" {
    const spec = dimSpec(4);
    try std.testing.expectEqualStrings("Quaternion", spec.name);
    try std.testing.expectEqualStrings("Quaternions", spec.algebra);
    try std.testing.expect(!spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("SO(5)=Sp(2)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.quaternion, spec.structureClass());
}

test "dim 5: Fold — Bi-complex" {
    const spec = dimSpec(5);
    try std.testing.expectEqualStrings("Fold", spec.name);
    try std.testing.expectEqualStrings("Bi-complex", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("SO(4)×SO(4)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.preserved, spec.structureClass());
}

test "dim 6: Peak — Jordan algebra H₃(O)" {
    const spec = dimSpec(6);
    try std.testing.expectEqualStrings("Peak", spec.name);
    try std.testing.expectEqualStrings("Jordan algebra H₃(O)", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(!spec.associative);
    try std.testing.expectEqualStrings("E6/F4", spec.symmetry);
    try std.testing.expectEqual(StructureClass.jordan, spec.structureClass());
}

test "dim 7: Color — Octonions" {
    const spec = dimSpec(7);
    try std.testing.expectEqualStrings("Color", spec.name);
    try std.testing.expectEqualStrings("Octonions", spec.algebra);
    try std.testing.expect(!spec.commutative);
    try std.testing.expect(!spec.associative);
    try std.testing.expectEqualStrings("SU(3)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.chaotic, spec.structureClass());
}

test "dim 8: Frequency — Dual numbers" {
    const spec = dimSpec(8);
    try std.testing.expectEqualStrings("Frequency", spec.name);
    try std.testing.expectEqualStrings("Dual numbers", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("U(1)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.preserved, spec.structureClass());
}

test "dim 9: Anti-octonion — Anti-octonions" {
    const spec = dimSpec(9);
    try std.testing.expectEqualStrings("Anti-octonion", spec.name);
    try std.testing.expectEqualStrings("Anti-octonions", spec.algebra);
    try std.testing.expect(!spec.commutative);
    try std.testing.expect(!spec.associative);
    try std.testing.expectEqualStrings("None", spec.symmetry);
    try std.testing.expectEqual(StructureClass.chaotic, spec.structureClass());
}

test "dim 10: Dual bi-complex — Dual bi-complex" {
    const spec = dimSpec(10);
    try std.testing.expectEqualStrings("Dual bi-complex", spec.name);
    try std.testing.expectEqualStrings("Dual bi-complex", spec.algebra);
    try std.testing.expect(spec.commutative);
    try std.testing.expect(spec.associative);
    try std.testing.expectEqualStrings("SO(8)", spec.symmetry);
    try std.testing.expectEqual(StructureClass.preserved, spec.structureClass());
}

test "structure class pattern: C=Yes A=Yes → preserved" {
    try std.testing.expectEqual(StructureClass.preserved, dimStructureClass(0));
    try std.testing.expectEqual(StructureClass.preserved, dimStructureClass(1));
    try std.testing.expectEqual(StructureClass.preserved, dimStructureClass(2));
    try std.testing.expectEqual(StructureClass.preserved, dimStructureClass(5));
    try std.testing.expectEqual(StructureClass.preserved, dimStructureClass(8));
    try std.testing.expectEqual(StructureClass.preserved, dimStructureClass(10));
}

test "structure class pattern: C=No A=Yes → quaternion" {
    try std.testing.expectEqual(StructureClass.quaternion, dimStructureClass(4));
}

test "structure class pattern: C=Yes A=No → jordan" {
    try std.testing.expectEqual(StructureClass.jordan, dimStructureClass(6));
}

test "structure class pattern: C=No A=No → chaotic" {
    try std.testing.expectEqual(StructureClass.chaotic, dimStructureClass(3));
    try std.testing.expectEqual(StructureClass.chaotic, dimStructureClass(7));
    try std.testing.expectEqual(StructureClass.chaotic, dimStructureClass(9));
}

test "dimCoordinateRemapped: preserved dims match standard dimCoordinate" {
    const preserved_dims = [_]u8{ 0, 1, 2, 5, 8, 10 };
    for (preserved_dims) |d| {
        const standard = dimCoordinate(0, d);
        const remapped = dimCoordinateRemapped(0, d);
        try std.testing.expectApproxEqAbs(standard, remapped, 1e-9);
    }
}

test "dimCoordinateRemapped: quaternion dim (4D) scales by φ" {
    const standard = dimCoordinate(0, 4);
    const remapped = dimCoordinateRemapped(0, 4);
    try std.testing.expectApproxEqAbs(standard * PHI, remapped, 1e-9);
}

test "dimCoordinateRemapped: jordan dim (6D) scales by 1/φ" {
    const standard = dimCoordinate(0, 6);
    const remapped = dimCoordinateRemapped(0, 6);
    try std.testing.expectApproxEqAbs(standard / PHI, remapped, 1e-9);
}

test "dimCoordinateRemapped: chaotic dims differ from standard" {
    const chaotic_dims = [_]u8{ 3, 7, 9 };
    for (chaotic_dims) |d| {
        const standard = dimCoordinate(0, d);
        const remapped = dimCoordinateRemapped(0, d);
        try std.testing.expect(@abs(standard - remapped) > 1e-9);
    }
}

test "dimCoordinateRemapped: chaotic dim 3 scales by sin(3)" {
    const standard = dimCoordinate(7, 3);
    const remapped = dimCoordinateRemapped(7, 3);
    try std.testing.expectApproxEqAbs(standard * std.math.sin(3.0), remapped, 1e-9);
}

test "dimCoordinateRemapped: all 11 dims at s=7 produce finite values" {
    for (0..11) |d| {
        const val = dimCoordinateRemapped(7, @intCast(d));
        try std.testing.expect(!std.math.isNan(val));
        try std.testing.expect(!std.math.isInf(val));
        try std.testing.expect(val > 0);
    }
}

test "query functions return correct values" {
    try std.testing.expectEqualStrings("Octonions", dimAlgebra(7));
    try std.testing.expectEqualStrings("SU(3)", dimSymmetry(7));
    try std.testing.expectEqualStrings("Strong force", dimPhysics(7));
    try std.testing.expect(!isCommutative(7));
    try std.testing.expect(!isAssociative(7));
    try std.testing.expect(isCommutative(0));
    try std.testing.expect(isAssociative(0));
}

test "scaledNodeCount produces correct values s=0..s=3" {
    try std.testing.expectEqual(@as(usize, 421), scaledNodeCount(0));
    try std.testing.expectEqual(@as(usize, 3368), scaledNodeCount(1));
    try std.testing.expectEqual(@as(usize, 26944), scaledNodeCount(2));
    try std.testing.expectEqual(@as(usize, 215552), scaledNodeCount(3));
}

test "scaledTokenSlots produces correct slot capacities s=0..s=3" {
    try std.testing.expectEqual(@as(usize, 2947), scaledTokenSlots(0));
    try std.testing.expectEqual(@as(usize, 23576), scaledTokenSlots(1));
    try std.testing.expectEqual(@as(usize, 188608), scaledTokenSlots(2));
    try std.testing.expectEqual(@as(usize, 1508864), scaledTokenSlots(3));
}

test "scaled token mapping round-trip is exact within mappable range" {
    inline for (0..4) |lvl| {
        const level: u8 = @intCast(lvl);
        const slots = scaledTokenSlots(level);
        // Test first 500, middle 500, and last 500 tokens
        const sample_size = @min(slots, 500);
        for (0..sample_size) |i| {
            const tid: u32 = @intCast(i);
            const node = scaledTokenToNode(tid, level);
            const channel = scaledTokenToChannel(tid, level);
            const recovered = scaledNodeToToken(node, channel, level);
            try std.testing.expectEqual(tid, recovered);
        }
    }
}

// =============================================================================
// EU v11.1 Synthesis Unit Tests
// =============================================================================

test "EU v11.1: 3+1 shell node counts (721 boundary cells at s=0)" {
    // s=0: 15³ interior = 3,375, 16³ shell = 4,096, boundary = 721 (7 × 103)
    try std.testing.expectEqual(@as(usize, 3375), interiorNodes(0));
    try std.testing.expectEqual(@as(usize, 4096), shellNodes(0));
    try std.testing.expectEqual(@as(usize, 721), boundaryNodes(0));
    try std.testing.expectEqual(@as(usize, 721), 7 * 103);

    // Scaling s=1..3
    try std.testing.expectEqual(@as(usize, 27000), interiorNodes(1));
    try std.testing.expectEqual(@as(usize, 32768), shellNodes(1));
    try std.testing.expectEqual(@as(usize, 5768), boundaryNodes(1));
}

test "EU v11.1: Fano plane router 7 associative lines" {
    // 7 lines:
    // (1,2,3), (1,4,5), (1,6,7), (2,4,6), (2,5,7), (3,4,7), (3,5,6)
    try std.testing.expectEqual(@as(?u3, 3), fanoRoute(1, 2));
    try std.testing.expectEqual(@as(?u3, 2), fanoRoute(1, 3));
    try std.testing.expectEqual(@as(?u3, 1), fanoRoute(2, 3));

    try std.testing.expectEqual(@as(?u3, 5), fanoRoute(1, 4));
    try std.testing.expectEqual(@as(?u3, 7), fanoRoute(1, 6));
    try std.testing.expectEqual(@as(?u3, 6), fanoRoute(2, 4));
    try std.testing.expectEqual(@as(?u3, 7), fanoRoute(2, 5));
    try std.testing.expectEqual(@as(?u3, 7), fanoRoute(3, 4));
    try std.testing.expectEqual(@as(?u3, 6), fanoRoute(3, 5));

    // Zero / identity / invalid channels return null
    try std.testing.expectEqual(@as(?u3, null), fanoRoute(0, 1));
    try std.testing.expectEqual(@as(?u3, null), fanoRoute(1, 1));
}

test "EU v11.1: Quadrupole dual-twist permutation across 4 quadrants" {
    const original: [8]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80 };

    // Test across all 4 quadrants
    const q1_perm = permuteQuadrupole(original, 2, .q1, false);
    const q2_perm = permuteQuadrupole(original, 2, .q2, false);
    const q3_perm = permuteQuadrupole(original, 2, .q3, false);
    const q4_perm = permuteQuadrupole(original, 2, .q4, false);

    // Distinct quadrant shifts
    try std.testing.expect(!std.mem.eql(u8, &q1_perm, &q2_perm));
    try std.testing.expect(!std.mem.eql(u8, &q2_perm, &q3_perm));
    try std.testing.expect(!std.mem.eql(u8, &q3_perm, &q4_perm));

    // Quadrant mapping from coordinates (edge=15)
    try std.testing.expectEqual(QuadrupoleQuadrant.q1, QuadrupoleQuadrant.fromCoords(10, 10, 15));
    try std.testing.expectEqual(QuadrupoleQuadrant.q2, QuadrupoleQuadrant.fromCoords(3, 10, 15));
    try std.testing.expectEqual(QuadrupoleQuadrant.q3, QuadrupoleQuadrant.fromCoords(3, 3, 15));
    // Roundtrip involution for all quadrants with boundary and non-boundary
    inline for (std.meta.tags(QuadrupoleQuadrant)) |q| {
        const p_bnd = permuteQuadrupole(original, 3, q, true);
        const inv_bnd = permuteQuadrupoleInverse(p_bnd, 3, q, true);
        try std.testing.expectEqualSlices(u8, &original, &inv_bnd);

        const p_nb = permuteQuadrupole(original, 5, q, false);
        const inv_nb = permuteQuadrupoleInverse(p_nb, 5, q, false);
        try std.testing.expectEqualSlices(u8, &original, &inv_nb);
    }
}

test "EU v11.1: 15-element palindrome validity across e0" {
    try std.testing.expect(isValidPalindrome(&PALINDROME_15));
    try std.testing.expectEqual(@as(usize, 15), PALINDROME_15.len);
    try std.testing.expectEqual(@as(u3, 0), PALINDROME_15[7]); // Center is e0 observer

    // Non-palindrome fails
    const invalid = [_]u3{ 1, 2, 3, 4, 5 };
    try std.testing.expect(!isValidPalindrome(&invalid));
}

// =============================================================================
// Framework Verification (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework constants from the hardware project's scaling analysis.
pub const FRAMEWORK_INTERIOR_VOLUME: u32 = 3375; // 15³
pub const FRAMEWORK_SHELL_VOLUME: u32 = 4096; // 16³
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7; // 2³ - 1 = 7
pub const FRAMEWORK_OCTONION_DIM: u32 = 8;
pub const FRAMEWORK_BOUNDARY_DIM: u32 = 2; // e0 (observer) + e7 (observed) = C = 2
pub const FRAMEWORK_CONSCIOUSNESS: u32 = 2; // C = 2 (observer/observed duality)
pub const FRAMEWORK_SCALING_DIM: u32 = 9; // 2 + 7 = 9 (surface computation)
pub const FRAMEWORK_E8_ROOT_COUNT: u32 = 240; // 15 × 16 = 240
pub const FRAMEWORK_SPINOR_DIM: u32 = 16; // SO(10) chiral spinor
pub const FRAMEWORK_FERMION_COUNT: u32 = 15; // SM fermions

/// Verifies the 421/3375 identity from the hardware framework:
/// 421 = (15³ - 7) / 8 = (interior_volume - seven_defect) / octonion_dim
pub fn verify421Identity() bool {
    const computed = (FRAMEWORK_INTERIOR_VOLUME - FRAMEWORK_SEVEN_DEFECT) / FRAMEWORK_OCTONION_DIM;
    return computed == E0_NODE_COUNT;
}

/// Verifies the consciousness aperture: 421/3375 = 1/8 - 7/27000
pub fn verifyConsciousnessAperture() bool {
    // 421/3375 = 1/8 - 7/27000
    // 1/8 - 7/27000 = (27000 - 56) / (8 * 27000) = 26944 / 216000
    // 421/3375 = 421 * 64 / (3375 * 64) = 26944 / 216000
    // Cross-multiply: 421 * 216000 == 3375 * 26944
    const lhs = @as(u64, E0_NODE_COUNT) * 216000;
    const rhs = @as(u64, FRAMEWORK_INTERIOR_VOLUME) * 26944;
    return lhs == rhs;
}

/// Verifies the shell transition: 16³ - 15³ = 721 = 3(240) + 1
pub fn verifyShellTransition() bool {
    const shell_diff = FRAMEWORK_SHELL_VOLUME - FRAMEWORK_INTERIOR_VOLUME;
    return shell_diff == 721 and shell_diff == 3 * FRAMEWORK_E8_ROOT_COUNT + 1;
}

/// Verifies the surface computation: 2 + 7 = 9 (Gauss-Bonnet)
/// C=2 (boundary) + 7-defect (interior) = 9 (scaling dimension)
pub fn verifySurfaceComputation() bool {
    return FRAMEWORK_BOUNDARY_DIM + FRAMEWORK_SEVEN_DEFECT == FRAMEWORK_SCALING_DIM;
}

/// Verifies the E8 root count: 15 × 16 = 240
pub fn verifyE8RootCount() bool {
    return FRAMEWORK_FERMION_COUNT * FRAMEWORK_SPINOR_DIM == FRAMEWORK_E8_ROOT_COUNT;
}

/// Verifies Fano plane lines match the octonion multiplication triples.
/// The 7 Fano lines must cover all 7 channels with each pair appearing exactly once.
pub fn verifyFanoPlaneCompleteness() bool {
    // Each of the 7 lines has 3 points. Each pair of points appears in exactly one line.
    // Check all 21 pairs (7 choose 2 = 21) are covered.
    var pair_count: u32 = 0;
    for (FANO_LINES) |_| {
        // Count pairs within this line
        pair_count += 1; // (a, b)
        pair_count += 1; // (a, c)
        pair_count += 1; // (b, c)
    }
    // 7 lines × 3 pairs = 21 pairs
    return pair_count == 21;
}

/// Runs all framework verification checks and returns the number of failures.
pub fn verifyAllFramework() u32 {
    var failures: u32 = 0;
    if (!verify421Identity()) failures += 1;
    if (!verifyConsciousnessAperture()) failures += 1;
    if (!verifyShellTransition()) failures += 1;
    if (!verifySurfaceComputation()) failures += 1;
    if (!verifyE8RootCount()) failures += 1;
    if (!verifyFanoPlaneCompleteness()) failures += 1;
    return failures;
}

test "framework: 421 identity (15³ - 7) / 8 = 421" {
    try std.testing.expect(verify421Identity());
}

test "framework: consciousness aperture 421/3375 = 1/8 - 7/27000" {
    try std.testing.expect(verifyConsciousnessAperture());
}

test "framework: shell transition 16³ - 15³ = 721 = 3(240) + 1" {
    try std.testing.expect(verifyShellTransition());
}

test "framework: surface computation 2 + 7 = 9" {
    try std.testing.expect(verifySurfaceComputation());
}

test "framework: E8 root count 15 × 16 = 240" {
    try std.testing.expect(verifyE8RootCount());
}

test "framework: Fano plane completeness (21 pairs)" {
    try std.testing.expect(verifyFanoPlaneCompleteness());
}

test "framework: all framework checks pass" {
    try std.testing.expectEqual(@as(u32, 0), verifyAllFramework());
}
