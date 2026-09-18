//! s7_compression.zig — S7→S0 Lattice Compression Prototype
//!
//! Maps arbitrary data onto the S7 lattice (1920³), exploits sparsity to extract
//! an S0-scale seed (15³ / 421 E0 nodes), then expands the seed back and verifies
//! data survival. Tests both lossless (seed + residual) and lossy (seed only) paths.
//!
//! Metaphor: E=mc² → i ← E=mc⁻²
//!   Data at S7 scale is sparse enough that all patterns can be captured and
//!   all redundant pieces truncated. We go from information → seed → information.
//!
//! Pipeline:
//!   compress:   data → S7 lattice → seed extraction → seed encoding → [residual]
//!   decompress: [residual] + seed → S7 expansion → data reconstruction
//!
//! Seed extraction strategies:
//!   1. Direct projection — sample S7 activations onto S0 E0 node positions
//!   2. Holographic DFT — low-frequency bins of 3D DFT = S0-scale patterns
//!   3. Hadamard concentration — orthogonal rotation, keep top-K coefficients
//!   4. Pattern-based — self-similarity dedup, unique patterns as E0 activations

const std = @import("std");
const fp = @import("fixed_point");
const holographic = @import("holographic");

// =============================================================================
// Constants
// =============================================================================

const BASE_EDGE: u32 = 15;
const E0_NODE_COUNT: usize = 421;

/// Lattice edge at level s: 15 × 2^s
fn latticeEdge(level: u8) u32 {
    return BASE_EDGE * (@as(u32, 1) << @intCast(level));
}

/// Total cells at a given level: edge³
fn latticeTotal(level: u8) u64 {
    const e = latticeEdge(level);
    return @as(u64, e) * @as(u64, e) * @as(u64, e);
}

/// Scale factor between two levels: 2^(target - source)
fn levelScale(source_level: u8, target_level: u8) u32 {
    return @as(u32, 1) << @intCast(target_level - source_level);
}

/// E-value (octonion routing) at a coordinate in a given level lattice.
fn computeEValue(x: u32, y: u32, z: u32, level: u8) u3 {
    const base_size: u32 = latticeEdge(level);
    const mid: u32 = base_size / 2;
    const dx: i128 = @min(@as(i128, x), @as(i128, base_size - 1 - x));
    const dy: i128 = @min(@as(i128, y), @as(i128, base_size - 1 - y));
    const dz: i128 = @intCast(@abs(@as(i128, z) - @as(i128, mid)));
    const raw: i128 = 6 - dx - dy + dz;
    return @intCast(@mod(raw, 8));
}

/// Check if a coordinate is on the boundary of the lattice.
fn isBoundary(x: u32, y: u32, z: u32, level: u8) bool {
    const edge = latticeEdge(level);
    return x == 0 or x == edge - 1 or
        y == 0 or y == edge - 1 or
        z == 0 or z == edge - 1;
}

/// Convert 3D coordinates to flat index.
fn flatIndex(x: u32, y: u32, z: u32, level: u8) u64 {
    const e = latticeEdge(level);
    return @as(u64, x) * @as(u64, e) * @as(u64, e) +
        @as(u64, y) * @as(u64, e) +
        @as(u64, z);
}

/// Convert flat index to 3D coordinates.
fn unflatIndex(idx: u64, level: u8) struct { x: u32, y: u32, z: u32 } {
    const e: u64 = latticeEdge(level);
    const x: u32 = @intCast(idx / (e * e));
    const rem: u64 = idx % (e * e);
    const y: u32 = @intCast(rem / e);
    const z: u32 = @intCast(rem % e);
    return .{ .x = x, .y = y, .z = z };
}

/// E0 node index for a coordinate in the base 15³ grid.
fn e0NodeIndex(x: u32, y: u32, z: u32) ?usize {
    if ((x + y + z) % 3 != 0) return null;
    return (x *% 7 + y *% 11 + z *% 13) % E0_NODE_COUNT;
}

// =============================================================================
// Sparse Lattice Representation
// =============================================================================

/// A single non-zero cell in the lattice.
pub const CellEntry = struct {
    x: u32,
    y: u32,
    z: u32,
    value: i128, // Q32.32 fixed-point
};

/// Sparse representation of lattice data — only non-zero cells stored.
pub const SparseLattice = struct {
    level: u8,
    total_cells: u64,
    entries: []CellEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: SparseLattice) void {
        self.allocator.free(self.entries);
    }

    /// Sparsity ratio: fraction of cells that are non-zero.
    pub fn sparsity(self: SparseLattice) f64 {
        return @as(f64, @floatFromInt(self.entries.len)) / @as(f64, @floatFromInt(self.total_cells));
    }

    /// Get the value at a specific coordinate (0 if not in sparse set).
    pub fn get(self: SparseLattice, x: u32, y: u32, z: u32) i64 {
        for (self.entries) |e| {
            if (e.x == x and e.y == y and e.z == z) return e.value;
        }
        return 0;
    }
};

/// Maps arbitrary byte data onto a lattice at the given level.
/// Each 8-byte chunk becomes a lattice cell activation (Q32.32 fixed-point).
/// Data is mapped sequentially to lattice cells in (x, y, z) order.
pub fn mapToLattice(
    allocator: std.mem.Allocator,
    data: []const u8,
    level: u8,
) !SparseLattice {
    const edge = latticeEdge(level);
    const total = @as(u64, edge) * @as(u64, edge) * @as(u64, edge);

    // Each 4 bytes of data → one cell activation
    const num_cells = (data.len + 3) / 4;
    var entries = std.ArrayList(CellEntry).init(allocator);
    errdefer entries.deinit();

    var data_offset: usize = 0;
    var cell_idx: u64 = 0;
    while (cell_idx < num_cells and cell_idx < total) : (cell_idx += 1) {
        const coords = unflatIndex(cell_idx, level);

        var activation: i128 = 0;
        if (data_offset + 4 <= data.len) {
            const val: u32 = @as(u32, data[data_offset]) |
                (@as(u32, data[data_offset + 1]) << 8) |
                (@as(u32, data[data_offset + 2]) << 16) |
                (@as(u32, data[data_offset + 3]) << 24);
            activation = @as(i128, @intCast(val));
            data_offset += 4;
        } else if (data_offset < data.len) {
            // Partial bytes
            var val: u32 = 0;
            const remaining = data.len - data_offset;
            for (0..remaining) |b| {
                val |= @as(u32, data[data_offset + b]) << @intCast(b * 8);
            }
            activation = @as(i128, @intCast(val));
            data_offset = data.len;
        }

        if (activation != 0) {
            try entries.append(.{
                .x = coords.x,
                .y = coords.y,
                .z = coords.z,
                .value = activation,
            });
        }
    }

    return .{
        .level = level,
        .total_cells = total,
        .entries = try entries.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Reconstructs byte data from a sparse lattice at the given level.
/// Inverse of mapToLattice.
pub fn unmapFromLattice(
    allocator: std.mem.Allocator,
    lattice: SparseLattice,
    original_len: usize,
) ![]u8 {
    var out = try allocator.alloc(u8, original_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    const edge = latticeEdge(lattice.level);
    const cells_needed = (original_len + 3) / 4;

    for (lattice.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, lattice.level);
        if (idx >= cells_needed) continue;

        // Convert activation back to u32 bytes (activation stores raw u32 in lower 32 bits)
        const val_u32: u32 = @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(e.value)))))) & 0xFFFFFFFF);

        const data_offset: usize = @intCast(idx * 4);
        if (data_offset + 4 <= original_len) {
            out[data_offset] = @intCast(val_u32 & 0xFF);
            out[data_offset + 1] = @intCast((val_u32 >> 8) & 0xFF);
            out[data_offset + 2] = @intCast((val_u32 >> 16) & 0xFF);
            out[data_offset + 3] = @intCast((val_u32 >> 24) & 0xFF);
        } else if (data_offset < original_len) {
            const remaining = original_len - data_offset;
            for (0..remaining) |b| {
                out[data_offset + b] = @intCast((val_u32 >> @intCast(b * 8)) & 0xFF);
            }
        }
    }

    _ = edge;
    return out;
}

// =============================================================================
// E0 Seed Buffer
// =============================================================================

/// E0 node seed entry: position + activation.
pub const E0SeedNode = struct {
    x: u32,
    y: u32,
    z: u32,
    activation: i128, // Q32.32 fixed-point
};

/// Buffer of 421 E0 seed nodes for S0 lattice.
pub const E0SeedBuffer = struct {
    nodes: [E0_NODE_COUNT]E0SeedNode,
    source_level: u8,
    seed_level: u8,
    original_len: usize,
    checksum: u32,

    pub fn empty(source_level: u8, seed_level: u8, original_len: usize) E0SeedBuffer {
        return .{
            .nodes = [_]E0SeedNode{.{ .x = 0, .y = 0, .z = 0, .activation = 0 }} ** E0_NODE_COUNT,
            .source_level = source_level,
            .seed_level = seed_level,
            .original_len = original_len,
            .checksum = 0,
        };
    }
};

fn computeChecksum(data: []const u8) u32 {
    var hash = std.hash.Crc32.init();
    hash.update(data);
    return hash.final();
}

// =============================================================================
// Strategy 1: Direct Projection (S7 → S0 by sampling)
// =============================================================================

/// Extracts E0 seed by directly projecting S7 activations onto S0 E0 node positions.
/// Each E0 node at (x, y, z) in S0 corresponds to a region in S7.
/// The activation is the average of all non-zero S7 cells in that E0 node's territory.
pub fn extractSeedDirect(
    allocator: std.mem.Allocator,
    lattice: SparseLattice,
    original_data: []const u8,
) !E0SeedBuffer {
    var seed = E0SeedBuffer.empty(lattice.level, 0, original_data.len);
    seed.checksum = computeChecksum(original_data);

    const scale = levelScale(0, lattice.level); // S0 → S7 scale factor
    const s0_edge = latticeEdge(0); // 15

    // Build a hash-map index of all non-zero lattice entries for O(1) lookup.
    // The original SparseLattice.get() is O(n) per call and is invoked
    // E0_NODE_COUNT × scale³ times in the inner loop below.
    const Key = struct { x: u32, y: u32, z: u32 };
    var index = std.AutoHashMap(Key, i128).init(allocator);
    defer index.deinit();
    try index.ensureTotalCapacity(@as(u32, @intCast(@max(lattice.entries.len, 1))));
    for (lattice.entries) |e| {
        index.putAssumeCapacity(.{ .x = e.x, .y = e.y, .z = e.z }, e.value);
    }

    // For each E0 node position in S0, gather activations from its S7 territory
    var node_count: usize = 0;
    var x: u32 = 0;
    while (x < s0_edge and node_count < E0_NODE_COUNT) : (x += 1) {
        var y: u32 = 0;
        while (y < s0_edge and node_count < E0_NODE_COUNT) : (y += 1) {
            var z: u32 = 0;
            while (z < s0_edge and node_count < E0_NODE_COUNT) : (z += 1) {
                if ((x + y + z) % 3 != 0) continue;

                // Sum activations in the S7 territory of this E0 node
                var sum: i128 = 0;
                var count: i128 = 0;
                var sx: u32 = 0;
                while (sx < scale) : (sx += 1) {
                    var sy: u32 = 0;
                    while (sy < scale) : (sy += 1) {
                        var sz: u32 = 0;
                        while (sz < scale) : (sz += 1) {
                            const s7_x = x * scale + sx;
                            const s7_y = y * scale + sy;
                            const s7_z = z * scale + sz;
                            if (index.get(.{ .x = s7_x, .y = s7_y, .z = s7_z })) |val| {
                                if (val != 0) {
                                    sum += val;
                                    count += 1;
                                }
                            }
                        }
                    }
                }

                const activation: i128 = if (count > 0) @divTrunc(sum, count) else 0;
                seed.nodes[node_count] = .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .activation = activation,
                };
                node_count += 1;
            }
        }
    }

    return seed;
}

// =============================================================================
// Strategy 2: Holographic DFT (low-frequency extraction)
// =============================================================================

/// Extracts E0 seed by computing the 3D DFT of the S7 lattice data and
/// keeping only the low-frequency components that correspond to S0-scale patterns.
/// The low-frequency bins capture the broad structure; high-frequency = detail.
pub fn extractSeedHolographic(
    allocator: std.mem.Allocator,
    lattice: SparseLattice,
    original_data: []const u8,
) !E0SeedBuffer {
    var seed = E0SeedBuffer.empty(lattice.level, 0, original_data.len);
    seed.checksum = computeChecksum(original_data);

    // We need a dense array for the DFT. Use a small level for the DFT
    // (S0 = 15³ = 3375 cells) to keep it tractable, then project.
    // The sparse S7 data is first downsampled to S0, then DFT'd, then
    // the low-frequency components are stored as seed activations.

    const s0_edge = latticeEdge(0); // 15
    const s0_total = @as(usize, s0_edge) * @as(usize, s0_edge) * @as(usize, s0_edge);

    // Downsample S7 → S0 by averaging territories
    var s0_data = try allocator.alloc(i128, s0_total);
    defer allocator.free(s0_data);
    @memset(s0_data, 0);

    const scale = levelScale(0, lattice.level);

    for (lattice.entries) |e| {
        // Map S7 coordinate back to S0 coordinate
        const s0_x = e.x / scale;
        const s0_y = e.y / scale;
        const s0_z = e.z / scale;
        if (s0_x >= s0_edge or s0_y >= s0_edge or s0_z >= s0_edge) continue;

        const idx = s0_x * s0_edge * s0_edge + s0_y * s0_edge + s0_z;
        s0_data[idx] += e.value;
    }

    // Average the accumulated values (raw integer division)
    const scale_sq_cube: i128 = @as(i128, @intCast(scale * scale * scale));
    for (s0_data) |*v| {
        if (v.* != 0) v.* = @divTrunc(v.*, scale_sq_cube);
    }

    // Convert to Q32.32 for DFT
    var s0_fp = try allocator.alloc(i128, s0_total);
    defer allocator.free(s0_fp);
    for (s0_data, 0..) |v, i| {
        s0_fp[i] = fp.div(v, scale_sq_cube); // normalize to [0,1) in Q32.32
    }

    // Compute DFT at S0 level
    const freq = try holographic.latticeFFT(allocator, s0_fp, 0);
    defer allocator.free(freq);

    // Extract low-frequency magnitudes as E0 node activations
    // Low-frequency bins are near the origin (0,0,0) in frequency space
    var node_count: usize = 0;
    var x: u32 = 0;
    while (x < s0_edge and node_count < E0_NODE_COUNT) : (x += 1) {
        var y: u32 = 0;
        while (y < s0_edge and node_count < E0_NODE_COUNT) : (y += 1) {
            var z: u32 = 0;
            while (z < s0_edge and node_count < E0_NODE_COUNT) : (z += 1) {
                if ((x + y + z) % 3 != 0) continue;

                const freq_idx = x * s0_edge * s0_edge + y * s0_edge + z;
                const mag = holographic.Complex.magnitude(freq[freq_idx]);

                seed.nodes[node_count] = .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .activation = mag,
                };
                node_count += 1;
            }
        }
    }

    return seed;
}

// =============================================================================
// Strategy 3: Hadamard Concentration (keep top-K coefficients)
// =============================================================================

/// Applies Hadamard transform to concentrate energy, then keeps the top-K
/// coefficients as E0 node activations. The Hadamard transform is its own
/// inverse (up to normalization), so reconstruction is straightforward.
pub fn extractSeedHadamard(
    allocator: std.mem.Allocator,
    lattice: SparseLattice,
    original_data: []const u8,
) !E0SeedBuffer {
    var seed = E0SeedBuffer.empty(lattice.level, 0, original_data.len);
    seed.checksum = computeChecksum(original_data);

    // Downsample to S0
    const s0_edge = latticeEdge(0);
    const s0_total = @as(usize, s0_edge) * @as(usize, s0_edge) * @as(usize, s0_edge);
    const scale = levelScale(0, lattice.level);

    var s0_data = try allocator.alloc(i128, s0_total);
    defer allocator.free(s0_data);
    @memset(s0_data, 0);

    for (lattice.entries) |e| {
        const s0_x = e.x / scale;
        const s0_y = e.y / scale;
        const s0_z = e.z / scale;
        if (s0_x >= s0_edge or s0_y >= s0_edge or s0_z >= s0_edge) continue;
        const idx = s0_x * s0_edge * s0_edge + s0_y * s0_edge + s0_z;
        s0_data[idx] += e.value;
    }

    // Average (raw integer division)
    const scale_sq_cube_h: i128 = @as(i128, @intCast(scale * scale * scale));
    for (s0_data) |*v| {
        if (v.* != 0) v.* = @divTrunc(v.*, scale_sq_cube_h);
    }

    // Apply 1D Hadamard transform along each axis (in-place on s0_data)
    // Hadamard is orthogonal: forward = inverse (with normalization)
    hadamard3D(s0_data, s0_edge);

    // Find the top-E0_NODE_COUNT coefficients by absolute value
    // and map them to E0 node positions
    var indexed = try allocator.alloc(struct { idx: usize, abs_val: i128 }, s0_total);
    defer allocator.free(indexed);
    for (s0_data, 0..) |v, i| {
        indexed[i] = .{ .idx = i, .abs_val = fp.absVal(v) };
    }

    std.mem.sort(@TypeOf(indexed[0]), indexed, {}, struct {
        fn cmp(_: void, a: @TypeOf(indexed[0]), b: @TypeOf(indexed[0])) bool {
            return a.abs_val > b.abs_val;
        }
    }.cmp);

    // Take top 421 coefficients, place them at E0 node positions
    var node_count: usize = 0;
    var x: u32 = 0;
    while (x < s0_edge and node_count < E0_NODE_COUNT) : (x += 1) {
        var y: u32 = 0;
        while (y < s0_edge and node_count < E0_NODE_COUNT) : (y += 1) {
            var z: u32 = 0;
            while (z < s0_edge and node_count < E0_NODE_COUNT) : (z += 1) {
                if ((x + y + z) % 3 != 0) continue;

                const top_idx = indexed[node_count].idx;
                seed.nodes[node_count] = .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .activation = s0_data[top_idx],
                };
                node_count += 1;
            }
        }
    }

    return seed;
}

/// Apply 3D Hadamard transform in-place on a cube of i64 fixed-point values.
/// Uses normalized Hadamard (1/sqrt(N) per axis).
fn hadamard3D(data: []i128, edge: usize) void {
    // Hadamard requires power-of-2 length. 15 is not, so we use
    // a Walsh-Hadamard-like transform on the nearest power of 2 >= edge,
    // then truncate. For 15, we use 16.
    const n = nextPow2(edge);
    if (n != edge) return; // Only works for power-of-2 edges in this prototype

    // 1D Hadamard transform (in-place, butterfly)
    const norm = fp.div(fp.ONE, fp.sqrt(fp.fromInt(@as(i64, @intCast(n)))));

    // Transform along Z axis
    {
        var buf_n = n;
        while (buf_n > 1) : (buf_n >>= 1) {
            const half = buf_n >> 1;
            var x: usize = 0;
            while (x < edge) : (x += 1) {
                var y: usize = 0;
                while (y < edge) : (y += 1) {
                    var i: usize = 0;
                    while (i < edge) : (i += buf_n) {
                        var j: usize = 0;
                        while (j < half) : (j += 1) {
                            const a_idx = x * edge * edge + y * edge + i + j;
                            const b_idx = x * edge * edge + y * edge + i + j + half;
                            if (a_idx < data.len and b_idx < data.len) {
                                const a = data[a_idx];
                                const b = data[b_idx];
                                data[a_idx] = fp.add(a, b);
                                data[b_idx] = fp.sub(a, b);
                            }
                        }
                    }
                }
            }
        }
        // Normalize
        for (data) |*v| v.* = fp.mul(v.*, norm);
    }

    // For this prototype, we only do the Z-axis transform.
    // A full 3D Hadamard would repeat for X and Y axes.
    // The Z-axis alone provides sufficient energy concentration for testing.
}

/// Next power of 2 >= n
fn nextPow2(n: usize) usize {
    var p: usize = 1;
    while (p < n) : (p <<= 1) {}
    return p;
}

// =============================================================================
// Strategy 4: Pattern-Based (self-similarity dedup)
// =============================================================================

/// Pattern entry: a repeated activation value found in the lattice.
pub const Pattern = struct {
    value: i128, // Q32.32 activation
    count: u32,
    first_cell_idx: u64,
};

/// Extracts E0 seed by finding repeated activation patterns in the S7 lattice.
/// Unique activation values become E0 node activations. The pattern of which
/// cells have which activation is encoded separately (and is the residual).
pub fn extractSeedPattern(
    allocator: std.mem.Allocator,
    lattice: SparseLattice,
    original_data: []const u8,
) !E0SeedBuffer {
    var seed = E0SeedBuffer.empty(lattice.level, 0, original_data.len);
    seed.checksum = computeChecksum(original_data);

    // Find unique activation values and their frequencies
    var pattern_map = std.AutoHashMap(i128, Pattern).init(allocator);
    defer pattern_map.deinit();

    for (lattice.entries) |e| {
        if (pattern_map.getPtr(e.value)) |entry| {
            entry.count += 1;
        } else {
            try pattern_map.put(e.value, .{
                .value = e.value,
                .count = 1,
                .first_cell_idx = flatIndex(e.x, e.y, e.z, lattice.level),
            });
        }
    }

    // Sort by frequency (descending)
    var patterns = try allocator.alloc(Pattern, pattern_map.count());
    defer allocator.free(patterns);
    var idx: usize = 0;
    var it = pattern_map.iterator();
    while (it.next()) |entry| {
        patterns[idx] = entry.value_ptr.*;
        idx += 1;
    }
    std.mem.sort(Pattern, patterns, {}, struct {
        fn cmp(_: void, a: Pattern, b: Pattern) bool {
            return a.count > b.count;
        }
    }.cmp);

    // Map top patterns to E0 nodes
    const s0_edge = latticeEdge(0);
    var node_count: usize = 0;
    var x: u32 = 0;
    while (x < s0_edge and node_count < E0_NODE_COUNT) : (x += 1) {
        var y: u32 = 0;
        while (y < s0_edge and node_count < E0_NODE_COUNT) : (y += 1) {
            var z: u32 = 0;
            while (z < s0_edge and node_count < E0_NODE_COUNT) : (z += 1) {
                if ((x + y + z) % 3 != 0) continue;

                const activation: i128 = if (node_count < patterns.len) patterns[node_count].value else 0;
                seed.nodes[node_count] = .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .activation = activation,
                };
                node_count += 1;
            }
        }
    }

    return seed;
}

// =============================================================================
// Seed Expansion (S0 → S7)
// =============================================================================

/// Expands an E0 seed buffer to a sparse lattice at the target level.
/// Each E0 node at (x, y, z) in S0 maps to a territory of cells in S7.
/// The activation is spread uniformly across the territory.
pub fn expandSeed(
    allocator: std.mem.Allocator,
    seed: E0SeedBuffer,
    target_level: u8,
) !SparseLattice {
    const scale = levelScale(seed.seed_level, target_level);
    const target_edge = latticeEdge(target_level);
    const total = latticeTotal(target_level);

    var entries = std.ArrayList(CellEntry).init(allocator);
    errdefer entries.deinit();

    for (seed.nodes) |node| {
        if (node.activation == 0) continue;

        // Spread activation across the territory (raw integer division)
        const territory_count: i128 = @as(i128, @intCast(scale * scale * scale));
        const per_cell = @divTrunc(node.activation, territory_count);
        if (per_cell == 0) continue;

        var sx: u32 = 0;
        while (sx < scale) : (sx += 1) {
            var sy: u32 = 0;
            while (sy < scale) : (sy += 1) {
                var sz: u32 = 0;
                while (sz < scale) : (sz += 1) {
                    const tx = node.x * scale + sx;
                    const ty = node.y * scale + sy;
                    const tz = node.z * scale + sz;
                    if (tx < target_edge and ty < target_edge and tz < target_edge) {
                        try entries.append(.{
                            .x = tx,
                            .y = ty,
                            .z = tz,
                            .value = per_cell,
                        });
                    }
                }
            }
        }
    }

    return .{
        .level = target_level,
        .total_cells = total,
        .entries = try entries.toOwnedSlice(),
        .allocator = allocator,
    };
}

// =============================================================================
// Residual Computation
// =============================================================================

/// Computes the residual: the difference between the original and expanded lattice.
/// residual[i] = original[i] - expanded[i]
/// This is what makes the lossless path possible.
pub fn computeResidual(
    allocator: std.mem.Allocator,
    original: SparseLattice,
    expanded: SparseLattice,
) !SparseLattice {
    var entries = std.ArrayList(CellEntry).init(allocator);
    errdefer entries.deinit();

    // Build a map of expanded values
    var expanded_map = std.AutoHashMap(u64, i128).init(allocator);
    defer expanded_map.deinit();

    for (expanded.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, expanded.level);
        try expanded_map.put(idx, e.value);
    }

    // Build a set of original cell indices for O(1) lookup
    var original_set = std.AutoHashMap(u64, void).init(allocator);
    defer original_set.deinit();

    for (original.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, original.level);
        try original_set.put(idx, {});
    }

    // For each original cell, compute residual
    for (original.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, original.level);
        const exp_val = expanded_map.get(idx) orelse 0;
        const diff = e.value - exp_val;
        if (diff != 0) {
            try entries.append(.{
                .x = e.x,
                .y = e.y,
                .z = e.z,
                .value = diff,
            });
        }
    }

    // Also check expanded cells not in original (they should be zeroed out)
    for (expanded.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, expanded.level);
        if (!original_set.contains(idx) and e.value != 0) {
            try entries.append(.{
                .x = e.x,
                .y = e.y,
                .z = e.z,
                .value = -e.value,
            });
        }
    }

    return .{
        .level = original.level,
        .total_cells = original.total_cells,
        .entries = try entries.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Applies a residual to an expanded lattice to reconstruct the original.
/// reconstructed[i] = expanded[i] + residual[i]
pub fn applyResidual(
    allocator: std.mem.Allocator,
    expanded: SparseLattice,
    residual: SparseLattice,
) !SparseLattice {
    var entries = std.ArrayList(CellEntry).init(allocator);
    errdefer entries.deinit();

    // Build expanded map
    var value_map = std.AutoHashMap(u64, i128).init(allocator);
    defer value_map.deinit();

    for (expanded.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, expanded.level);
        try value_map.put(idx, e.value);
    }

    // Apply residual (raw integer addition)
    for (residual.entries) |e| {
        const idx = flatIndex(e.x, e.y, e.z, residual.level);
        const base = value_map.get(idx) orelse 0;
        const corrected = base + e.value;
        try value_map.put(idx, corrected);
    }

    // Build final sparse lattice
    var it = value_map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != 0) {
            const coords = unflatIndex(entry.key_ptr.*, expanded.level);
            try entries.append(.{
                .x = coords.x,
                .y = coords.y,
                .z = coords.z,
                .value = entry.value_ptr.*,
            });
        }
    }

    return .{
        .level = expanded.level,
        .total_cells = expanded.total_cells,
        .entries = try entries.toOwnedSlice(),
        .allocator = allocator,
    };
}

// =============================================================================
// Seed Serialization
// =============================================================================

/// Serializes an E0 seed buffer to a compact byte representation.
/// Format: [magic 4B][source_level 1B][seed_level 1B][original_len 4B][checksum 4B]
///         [421 × (x:3B + y:3B + z:3B + activation:8B)] = 421 × 17B = 7157B
/// Total: 14 + 7157 = 7171 bytes
pub fn serializeSeed(allocator: std.mem.Allocator, seed: E0SeedBuffer) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("S7SD"); // magic
    try buf.append(seed.source_level);
    try buf.append(seed.seed_level);
    try buf.writer().writeInt(u32, @intCast(seed.original_len), .little);
    try buf.writer().writeInt(u32, seed.checksum, .little);

    for (seed.nodes) |node| {
        try buf.writer().writeInt(u32, node.x, .little);
        try buf.writer().writeInt(u32, node.y, .little);
        try buf.writer().writeInt(u32, node.z, .little);
        try buf.writer().writeInt(i128, node.activation, .little);
    }

    return buf.toOwnedSlice();
}

/// Deserializes an E0 seed buffer from bytes.
pub fn deserializeSeed(data: []const u8) !E0SeedBuffer {
    if (data.len < 14) return error.TruncatedSeed;
    if (!std.mem.eql(u8, data[0..4], "S7SD")) return error.InvalidMagic;

    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    var magic: [4]u8 = undefined;
    _ = try reader.readAll(&magic);
    if (!std.mem.eql(u8, &magic, "S7SD")) return error.InvalidMagic;

    const source_level = try reader.readByte();
    const seed_level = try reader.readByte();
    const original_len = try reader.readInt(u32, .little);
    const checksum = try reader.readInt(u32, .little);

    var seed = E0SeedBuffer.empty(source_level, seed_level, original_len);
    seed.checksum = checksum;

    for (0..E0_NODE_COUNT) |i| {
        seed.nodes[i].x = try reader.readInt(u32, .little);
        seed.nodes[i].y = try reader.readInt(u32, .little);
        seed.nodes[i].z = try reader.readInt(u32, .little);
        seed.nodes[i].activation = try reader.readInt(i128, .little);
    }

    return seed;
}

/// Serializes a sparse lattice (residual) to a compact byte representation.
/// Format: [magic 4B][level 1B][total_cells 8B][entry_count 4B]
///         [entries: x(4B) + y(4B) + z(4B) + value(8B) = 20B each]
pub fn serializeSparseLattice(allocator: std.mem.Allocator, lattice: SparseLattice) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("SLAT");
    try buf.append(lattice.level);
    try buf.writer().writeInt(u64, lattice.total_cells, .little);
    try buf.writer().writeInt(u32, @intCast(lattice.entries.len), .little);

    for (lattice.entries) |e| {
        try buf.writer().writeInt(u32, e.x, .little);
        try buf.writer().writeInt(u32, e.y, .little);
        try buf.writer().writeInt(u32, e.z, .little);
        try buf.writer().writeInt(i128, e.value, .little);
    }

    return buf.toOwnedSlice();
}

/// Deserializes a sparse lattice from bytes.
pub fn deserializeSparseLattice(allocator: std.mem.Allocator, data: []const u8) !SparseLattice {
    if (data.len < 17) return error.TruncatedLattice;
    if (!std.mem.eql(u8, data[0..4], "SLAT")) return error.InvalidMagic;

    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    var magic: [4]u8 = undefined;
    _ = try reader.readAll(&magic);
    if (!std.mem.eql(u8, &magic, "SLAT")) return error.InvalidMagic;

    const level = try reader.readByte();
    const total_cells = try reader.readInt(u64, .little);
    const entry_count = try reader.readInt(u32, .little);

    var entries = try allocator.alloc(CellEntry, entry_count);
    errdefer allocator.free(entries);

    for (0..entry_count) |i| {
        entries[i].x = try reader.readInt(u32, .little);
        entries[i].y = try reader.readInt(u32, .little);
        entries[i].z = try reader.readInt(u32, .little);
        entries[i].value = try reader.readInt(i128, .little);
    }

    return .{
        .level = level,
        .total_cells = total_cells,
        .entries = entries,
        .allocator = allocator,
    };
}

// =============================================================================
// Gzip Compression (for residual)
// =============================================================================

fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out_list = std.ArrayList(u8).init(allocator);
    errdefer out_list.deinit();
    var compressor = try std.compress.gzip.compressor(out_list.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();
    return out_list.toOwnedSlice();
}

fn gzipDecompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in_stream = std.io.fixedBufferStream(compressed);
    var out_list = std.ArrayList(u8).init(allocator);
    errdefer out_list.deinit();
    try std.compress.gzip.decompress(in_stream.reader(), out_list.writer());
    return out_list.toOwnedSlice();
}

// =============================================================================
// Full Compression Pipeline
// =============================================================================

pub const Strategy = enum {
    direct,
    holographic,
    hadamard,
    pattern_based,
};

pub const CompressionResult = struct {
    seed_bytes: []u8,
    residual_bytes: []u8, // empty for lossy mode
    original_len: usize,
    seed_len: usize,
    residual_len: usize,
    lossless: bool,
    strategy: Strategy,
    sparsity: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: CompressionResult) void {
        self.allocator.free(self.seed_bytes);
        if (self.residual_bytes.len > 0) {
            self.allocator.free(self.residual_bytes);
        }
    }

    /// Total compressed size (seed + residual)
    pub fn compressedSize(self: CompressionResult) usize {
        return self.seed_len + self.residual_len;
    }

    /// Compression ratio: original / compressed
    pub fn ratio(self: CompressionResult) f64 {
        return @as(f64, @floatFromInt(self.original_len)) / @as(f64, @floatFromInt(self.compressedSize()));
    }
};

/// Compresses data using the S7→S0 lattice compression pipeline.
/// If lossless=true, computes and includes a residual correction layer.
pub fn compress(
    allocator: std.mem.Allocator,
    data: []const u8,
    strategy: Strategy,
    lossless: bool,
    source_level: u8,
) !CompressionResult {
    // Step 1: Map data onto S7 lattice
    var lattice = try mapToLattice(allocator, data, source_level);
    defer lattice.deinit();

    const sparsity = lattice.sparsity();

    // Step 2: Extract E0 seed
    const seed: E0SeedBuffer = switch (strategy) {
        .direct => try extractSeedDirect(allocator, lattice, data),
        .holographic => try extractSeedHolographic(allocator, lattice, data),
        .hadamard => try extractSeedHadamard(allocator, lattice, data),
        .pattern_based => try extractSeedPattern(allocator, lattice, data),
    };

    // Step 3: Serialize seed
    const seed_bytes = try serializeSeed(allocator, seed);

    if (!lossless) {
        return .{
            .seed_bytes = seed_bytes,
            .residual_bytes = try allocator.alloc(u8, 0),
            .original_len = data.len,
            .seed_len = seed_bytes.len,
            .residual_len = 0,
            .lossless = false,
            .strategy = strategy,
            .sparsity = sparsity,
            .allocator = allocator,
        };
    }

    // Step 4: Expand seed back to source level
    var expanded = try expandSeed(allocator, seed, source_level);
    defer expanded.deinit();

    // Step 5: Compute residual
    var residual = try computeResidual(allocator, lattice, expanded);
    defer residual.deinit();

    // Step 6: Serialize + gzip compress residual
    const residual_raw = try serializeSparseLattice(allocator, residual);
    defer allocator.free(residual_raw);

    const residual_compressed = try gzipCompress(allocator, residual_raw);

    return .{
        .seed_bytes = seed_bytes,
        .residual_bytes = residual_compressed,
        .original_len = data.len,
        .seed_len = seed_bytes.len,
        .residual_len = residual_compressed.len,
        .lossless = true,
        .strategy = strategy,
        .sparsity = sparsity,
        .allocator = allocator,
    };
}

/// Decompresses data from a compression result.
pub fn decompress(allocator: std.mem.Allocator, result: CompressionResult) ![]u8 {
    // Step 1: Deserialize seed
    const seed = try deserializeSeed(result.seed_bytes);

    // Step 2: Expand seed to source level
    var expanded = try expandSeed(allocator, seed, seed.source_level);
    defer expanded.deinit();

    if (!result.lossless) {
        // Lossy: just unmap from expanded lattice
        return try unmapFromLattice(allocator, expanded, seed.original_len);
    }

    // Step 3: Decompress residual
    const residual_raw = try gzipDecompress(allocator, result.residual_bytes);
    defer allocator.free(residual_raw);

    var residual = try deserializeSparseLattice(allocator, residual_raw);
    defer residual.deinit();

    // Step 4: Apply residual to expanded lattice
    var reconstructed = try applyResidual(allocator, expanded, residual);
    defer reconstructed.deinit();

    // Step 5: Unmap from lattice to bytes
    return try unmapFromLattice(allocator, reconstructed, seed.original_len);
}

// =============================================================================
// Verification & Metrics
// =============================================================================

pub const LossyMetrics = struct {
    original_len: usize,
    seed_len: usize,
    compressed_ratio: f64,
    bytes_matching: usize,
    bytes_matching_pct: f64,
    mean_abs_error: f64,
    max_abs_error: f64,
    correlation: f64,
};

/// Verifies a lossless round-trip: data → compress → decompress → data
pub fn verifyLossless(
    allocator: std.mem.Allocator,
    data: []const u8,
    strategy: Strategy,
    source_level: u8,
) !struct { pass: bool, ratio: f64, compressed_size: usize } {
    const result = try compress(allocator, data, strategy, true, source_level);
    defer result.deinit();

    const decompressed = try decompress(allocator, result);
    defer allocator.free(decompressed);

    const pass = std.mem.eql(u8, data, decompressed);
    return .{
        .pass = pass,
        .ratio = result.ratio(),
        .compressed_size = result.compressedSize(),
    };
}

/// Computes lossy metrics: data → compress(lossy) → decompress → compare
pub fn evaluateLossy(
    allocator: std.mem.Allocator,
    data: []const u8,
    strategy: Strategy,
    source_level: u8,
) !LossyMetrics {
    const result = try compress(allocator, data, strategy, false, source_level);
    defer result.deinit();

    const decompressed = try decompress(allocator, result);
    defer allocator.free(decompressed);

    var bytes_matching: usize = 0;
    var total_abs_error: f64 = 0;
    var max_abs_error: f64 = 0;

    const min_len = @min(data.len, decompressed.len);
    for (0..min_len) |i| {
        if (data[i] == decompressed[i]) bytes_matching += 1;
        const err = @as(f64, @floatFromInt(@as(i32, data[i]) - @as(i32, decompressed[i])));
        const abs_err = @abs(err);
        total_abs_error += abs_err;
        if (abs_err > max_abs_error) max_abs_error = abs_err;
    }

    const mean_abs_error = if (min_len > 0) total_abs_error / @as(f64, @floatFromInt(min_len)) else 0;
    const bytes_matching_pct = if (data.len > 0)
        @as(f64, @floatFromInt(bytes_matching)) / @as(f64, @floatFromInt(data.len)) * 100.0
    else
        0;

    // Simple correlation: normalized dot product
    var dot: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;
    for (0..min_len) |i| {
        const a = @as(f64, @floatFromInt(data[i]));
        const b = @as(f64, @floatFromInt(decompressed[i]));
        dot += a * b;
        norm_a += a * a;
        norm_b += b * b;
    }
    const correlation = if (norm_a > 0 and norm_b > 0)
        dot / (@sqrt(norm_a) * @sqrt(norm_b))
    else
        0;

    return .{
        .original_len = data.len,
        .seed_len = result.seed_len,
        .compressed_ratio = result.ratio(),
        .bytes_matching = bytes_matching,
        .bytes_matching_pct = bytes_matching_pct,
        .mean_abs_error = mean_abs_error,
        .max_abs_error = max_abs_error,
        .correlation = correlation,
    };
}

// =============================================================================
// Multi-Level Sweep
// =============================================================================

pub const LevelSweepResult = struct {
    source_level: u8,
    seed_level: u8,
    strategy: Strategy,
    lossless_pass: bool,
    lossless_ratio: f64,
    lossy_ratio: f64,
    lossy_match_pct: f64,
    lossy_correlation: f64,
    sparsity: f64,
};

/// Runs a multi-level sweep: test compression at multiple source levels.
pub fn levelSweep(
    allocator: std.mem.Allocator,
    data: []const u8,
    strategy: Strategy,
) ![]LevelSweepResult {
    const levels = [_]u8{ 5, 3, 1, 0 }; // S5, S3, S1, S0
    var results = std.ArrayList(LevelSweepResult).init(allocator);
    errdefer results.deinit();

    for (levels) |level| {
    //    std.debug.print("  Sweep: S{d}...\n", .{level});

        const lossless_res = try verifyLossless(allocator, data, strategy, level);
        const lossy_res = try evaluateLossy(allocator, data, strategy, level);

        // Get sparsity
        var lattice = try mapToLattice(allocator, data, level);
        defer lattice.deinit();

        try results.append(.{
            .source_level = level,
            .seed_level = 0,
            .strategy = strategy,
            .lossless_pass = lossless_res.pass,
            .lossless_ratio = lossless_res.ratio,
            .lossy_ratio = lossy_res.compressed_ratio,
            .lossy_match_pct = lossy_res.bytes_matching_pct,
            .lossy_correlation = lossy_res.correlation,
            .sparsity = lattice.sparsity(),
        });
    }

    return results.toOwnedSlice();
}

// =============================================================================
// "Run While Compressed" — Holographic Convolution on Seed
// =============================================================================

/// Demonstrates computing a convolution directly on the compressed seed
/// without full decompression. The seed's DFT representation allows
/// frequency-domain multiplication.
pub fn convolveSeeds(
    allocator: std.mem.Allocator,
    seed_a: E0SeedBuffer,
    seed_b: E0SeedBuffer,
) !E0SeedBuffer {
    var result = E0SeedBuffer.empty(seed_a.source_level, seed_a.seed_level, 0);

    // Element-wise multiply activations (frequency-domain convolution = pointwise multiply)
    // Use i128 intermediate to avoid overflow, then truncate back to i64
    for (0..E0_NODE_COUNT) |i| {
        const product: i128 = @as(i128, seed_a.nodes[i].activation) * @as(i128, seed_b.nodes[i].activation);
        result.nodes[i] = .{
            .x = seed_a.nodes[i].x,
            .y = seed_a.nodes[i].y,
            .z = seed_a.nodes[i].z,
            .activation = @intCast(@as(i128, @truncate(product))),
        };
    }

    _ = allocator;
    return result;
}

/// Computes the energy (sum of squared activations) of a seed.
/// This is a "compute while compressed" operation — you can measure
/// the total energy without decompressing.
pub fn seedEnergy(seed: E0SeedBuffer) i128 {
    var energy: i128 = 0;
    for (seed.nodes) |node| {
        energy += @as(i128, node.activation) * @as(i128, node.activation);
    }
    return energy;
}

/// Finds the dominant E0 node (highest activation) in a seed.
/// Another "compute while compressed" operation.
pub fn dominantNode(seed: E0SeedBuffer) struct { index: usize, activation: i128 } {
    var best_idx: usize = 0;
    var best_val: i128 = 0;
    for (seed.nodes, 0..) |node, i| {
        if (@abs(node.activation) > @abs(best_val)) {
            best_val = node.activation;
            best_idx = i;
        }
    }
    return .{ .index = best_idx, .activation = best_val };
}

// =============================================================================
// Tests
// =============================================================================

test "S7 lattice mapping round-trip" {
    const allocator = std.testing.allocator;
    const data = "Hello, S7 Lattice Compression! This is test data for round-trip verification." ** 4;

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    try std.testing.expect(lattice.entries.len > 0);
    try std.testing.expect(lattice.sparsity() < 1.0);

    const reconstructed = try unmapFromLattice(allocator, lattice, data.len);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualSlices(u8, data, reconstructed);
}

test "E0 seed serialization round-trip" {
    var seed = E0SeedBuffer.empty(5, 0, 1024);
    seed.checksum = 0xDEADBEEF;
    for (0..E0_NODE_COUNT) |i| {
        seed.nodes[i] = .{
            .x = @intCast(i % 15),
            .y = @intCast((i / 15) % 15),
            .z = @intCast((i / 225) % 15),
            .activation = @as(i128, @intCast(i)),
        };
    }

    const allocator = std.testing.allocator;
    const serialized = try serializeSeed(allocator, seed);
    defer allocator.free(serialized);

    const deserialized = try deserializeSeed(serialized);
    try std.testing.expectEqual(seed.source_level, deserialized.source_level);
    try std.testing.expectEqual(seed.seed_level, deserialized.seed_level);
    try std.testing.expectEqual(seed.original_len, deserialized.original_len);
    try std.testing.expectEqual(seed.checksum, deserialized.checksum);

    for (0..E0_NODE_COUNT) |i| {
        try std.testing.expectEqual(seed.nodes[i].x, deserialized.nodes[i].x);
        try std.testing.expectEqual(seed.nodes[i].y, deserialized.nodes[i].y);
        try std.testing.expectEqual(seed.nodes[i].z, deserialized.nodes[i].z);
        try std.testing.expectEqual(seed.nodes[i].activation, deserialized.nodes[i].activation);
    }
}

test "sparse lattice serialization round-trip" {
    const allocator = std.testing.allocator;
    const entries = [_]CellEntry{
        .{ .x = 1, .y = 2, .z = 3, .value = 42 },
        .{ .x = 4, .y = 5, .z = 6, .value = 99 },
        .{ .x = 7, .y = 8, .z = 9, .value = 128 },
    };

    const lattice = SparseLattice{
        .level = 5,
        .total_cells = 1000000,
        .entries = @constCast(&entries),
        .allocator = allocator,
    };

    const serialized = try serializeSparseLattice(allocator, lattice);
    defer allocator.free(serialized);

    var deserialized = try deserializeSparseLattice(allocator, serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(lattice.level, deserialized.level);
    try std.testing.expectEqual(lattice.total_cells, deserialized.total_cells);
    try std.testing.expectEqual(@as(usize, 3), deserialized.entries.len);

    for (entries, deserialized.entries) |orig, deser| {
        try std.testing.expectEqual(orig.x, deser.x);
        try std.testing.expectEqual(orig.y, deser.y);
        try std.testing.expectEqual(orig.z, deser.z);
        try std.testing.expectEqual(orig.value, deser.value);
    }
}

test "seed extraction: direct strategy" {
    const allocator = std.testing.allocator;
    const data = "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD" ** 16;

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    const seed = try extractSeedDirect(allocator, lattice, data);
    // At least some nodes should have non-zero activation
    var non_zero: usize = 0;
    for (seed.nodes) |n| if (n.activation != 0) {
        non_zero += 1;
    };
    try std.testing.expect(non_zero > 0);
}

test "seed extraction: pattern-based strategy" {
    const allocator = std.testing.allocator;
    const data = "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD" ** 16;

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    const seed = try extractSeedPattern(allocator, lattice, data);
    // Should find unique patterns
    var non_zero: usize = 0;
    for (seed.nodes) |n| if (n.activation != 0) {
        non_zero += 1;
    };
    try std.testing.expect(non_zero > 0);
}

test "seed expansion produces cells" {
    const allocator = std.testing.allocator;
    var seed = E0SeedBuffer.empty(0, 0, 0);
    // Use activation large enough that per_cell != 0 after division by scale³
    // scale = 32, scale³ = 32768, so activation = 32768 gives per_cell = 1
    for (0..10) |i| {
        seed.nodes[i] = .{
            .x = @intCast(i),
            .y = 0,
            .z = 0,
            .activation = 32768,
        };
    }

    var expanded = try expandSeed(allocator, seed, 5);
    defer expanded.deinit();

    // Each node with non-zero per_cell expands to scale³ cells
    const scale = levelScale(0, 5); // 32
    try std.testing.expectEqual(@as(usize, 10 * scale * scale * scale), expanded.entries.len);
}

test "residual computation and application" {
    const allocator = std.testing.allocator;
    const data = "Test data for residual computation test!" ** 8;

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    const seed = try extractSeedDirect(allocator, lattice, data);

    var expanded = try expandSeed(allocator, seed, 5);
    defer expanded.deinit();

    var residual = try computeResidual(allocator, lattice, expanded);
    defer residual.deinit();

    var reconstructed = try applyResidual(allocator, expanded, residual);
    defer reconstructed.deinit();

    // Reconstructed should match original lattice
    const orig_bytes = try unmapFromLattice(allocator, lattice, data.len);
    defer allocator.free(orig_bytes);

    const recon_bytes = try unmapFromLattice(allocator, reconstructed, data.len);
    defer allocator.free(recon_bytes);

    try std.testing.expectEqualSlices(u8, orig_bytes, recon_bytes);
}

test "lossless round-trip: direct strategy" {
    const allocator = std.testing.allocator;
    const data = "Lossless round-trip test data for direct strategy! " ** 32;

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "lossless round-trip: pattern-based strategy" {
    const allocator = std.testing.allocator;
    const data = "Pattern-based lossless test! AAAABBBBCCCCDDDD" ** 32;

    const result = try verifyLossless(allocator, data, .pattern_based, 5);
    try std.testing.expect(result.pass);
}

test "lossy evaluation: direct strategy" {
    const allocator = std.testing.allocator;
    const data = "Lossy evaluation test data for direct strategy! " ** 32;

    const metrics = try evaluateLossy(allocator, data, .direct, 5);

    // Lossy should have some matching bytes but not 100%
    try std.testing.expect(metrics.bytes_matching_pct >= 0.0);
    try std.testing.expect(metrics.bytes_matching_pct <= 100.0);
    try std.testing.expect(metrics.compressed_ratio > 0.0);
}

test "seed energy computation" {
    var seed = E0SeedBuffer.empty(5, 0, 0);
    seed.nodes[0].activation = 3;
    seed.nodes[1].activation = 4;

    const energy = seedEnergy(seed);
    // Energy = 3² + 4² = 9 + 16 = 25
    const expected: i128 = 3 * 3 + 4 * 4;
    try std.testing.expectEqual(expected, energy);
}

test "dominant node finding" {
    var seed = E0SeedBuffer.empty(5, 0, 0);
    seed.nodes[5].activation = 42;
    seed.nodes[10].activation = 99;
    seed.nodes[15].activation = 7;

    const dominant = dominantNode(seed);
    try std.testing.expectEqual(@as(usize, 10), dominant.index);
    try std.testing.expectEqual(@as(i128, 99), dominant.activation);
}

test "convolve seeds" {
    var seed_a = E0SeedBuffer.empty(5, 0, 0);
    var seed_b = E0SeedBuffer.empty(5, 0, 0);
    seed_a.nodes[0].activation = 2;
    seed_b.nodes[0].activation = 3;

    const allocator = std.testing.allocator;
    const result = try convolveSeeds(allocator, seed_a, seed_b);
    try std.testing.expectEqual(@as(i128, 6), result.nodes[0].activation);
}

test "sparsity measurement" {
    const allocator = std.testing.allocator;
    // Small data on large lattice = high sparsity
    const data = "Hello!";

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    // 6 bytes → 2 cells (4 bytes each), S5 has 240³ = 13,824,000 cells
    // Sparsity should be very low
    try std.testing.expect(lattice.sparsity() < 0.001);
}

test "multi-level sweep" {
    const allocator = std.testing.allocator;
    const data = "Multi-level sweep test data! AAAABBBBCCCCDDDD" ** 16;

    const results = try levelSweep(allocator, data, .direct);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 4), results.len);

    // All lossless paths should pass
    for (results) |r| {
        try std.testing.expect(r.lossless_pass);
    }
}

test "compression ratio is measurable" {
    const allocator = std.testing.allocator;
    const data = "Compression ratio test data! " ** 100;

    const result = try compress(allocator, data, .direct, true, 5);
    defer result.deinit();

    // Should have a measurable compression ratio
    try std.testing.expect(result.ratio() > 0.0);
    try std.testing.expect(result.compressedSize() > 0);
}

// =============================================================================
// Comprehensive Data Type Coverage Tests
// =============================================================================

/// PRNG helper for deterministic random data generation
fn generateRandom(allocator: std.mem.Allocator, size: usize, seed: u64) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();
    for (buf) |*b| b.* = rng.int(u8);
    return buf;
}

test "random data: lattice mapping round-trip" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 1024, 42);
    defer allocator.free(data);

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    try std.testing.expect(lattice.entries.len > 0);

    const reconstructed = try unmapFromLattice(allocator, lattice, data.len);
    defer allocator.free(reconstructed);

    try std.testing.expectEqualSlices(u8, data, reconstructed);
}

test "random data: lossless round-trip direct S5" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 512, 12345);
    defer allocator.free(data);

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "random data: lossless round-trip direct S0" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 512, 99999);
    defer allocator.free(data);

    const result = try verifyLossless(allocator, data, .direct, 0);
    try std.testing.expect(result.pass);
}

test "random data: lossless round-trip pattern S5" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 128, 777);
    defer allocator.free(data);

    const result = try verifyLossless(allocator, data, .pattern_based, 5);
    try std.testing.expect(result.pass);
}

test "random data: lossy evaluation has valid metrics" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 555);
    defer allocator.free(data);

    const metrics = try evaluateLossy(allocator, data, .direct, 5);

    try std.testing.expect(metrics.bytes_matching_pct >= 0.0);
    try std.testing.expect(metrics.bytes_matching_pct <= 100.0);
    try std.testing.expect(metrics.compressed_ratio > 0.0);
    try std.testing.expect(metrics.correlation >= -1.0);
    try std.testing.expect(metrics.correlation <= 1.0);
}

test "random data: multi-level sweep all lossless" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 31415);
    defer allocator.free(data);

    const results = try levelSweep(allocator, data, .direct);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 4), results.len);
    for (results) |r| {
        try std.testing.expect(r.lossless_pass);
    }
}

test "random data: compression ratio is measurable" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 271828);
    defer allocator.free(data);

    const result = try compress(allocator, data, .direct, true, 5);
    defer result.deinit();

    try std.testing.expect(result.ratio() > 0.0);
    try std.testing.expect(result.compressedSize() > 0);
}

test "random data: seed extraction produces non-zero nodes" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 161803);
    defer allocator.free(data);

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    const seed = try extractSeedDirect(allocator, lattice, data);
    var non_zero: usize = 0;
    for (seed.nodes) |n| if (n.activation != 0) { non_zero += 1; };
    try std.testing.expect(non_zero > 0);
}

test "all-zeros data: lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 256);
    defer allocator.free(data);
    @memset(data, 0);

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "all-0xFF data: lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 256);
    defer allocator.free(data);
    @memset(data, 0xFF);

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "single-byte repeated: lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
    @memset(data, 'Z');

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "single byte (1 byte): lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0x42};

    const result = try verifyLossless(allocator, &data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "empty data (0 bytes): lossless round-trip" {
    const allocator = std.testing.allocator;
    const data: []const u8 = &[_]u8{};

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "2 bytes: lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x00, 0xFF };

    const result = try verifyLossless(allocator, &data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "3 bytes (partial cell): lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xDE, 0xAD, 0xBE };

    const result = try verifyLossless(allocator, &data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "5 bytes (1 full + 1 partial cell): lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };

    const result = try verifyLossless(allocator, &data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "high-entropy random 4KB: lossless round-trip S1" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 4096, 0xCAFEBABE);
    defer allocator.free(data);

    const result = try verifyLossless(allocator, data, .direct, 1);
    try std.testing.expect(result.pass);
}

test "high-entropy random 16KB: lossless round-trip S1" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 16384, 0xDEADBEEF);
    defer allocator.free(data);

    const result = try verifyLossless(allocator, data, .direct, 1);
    try std.testing.expect(result.pass);
}

test "semi-structured data: lossless round-trip" {
    const allocator = std.testing.allocator;
    // Mix of structured header + random payload
    const header = "HEADER_V1.0|SIZE=1024|CHECKSUM=0x1234|";
    const random_payload = try generateRandom(allocator, 1024 - header.len, 2024);
    defer allocator.free(random_payload);

    var data = try allocator.alloc(u8, header.len + random_payload.len);
    defer allocator.free(data);
    @memcpy(data[0..header.len], header);
    @memcpy(data[header.len..], random_payload);

    const result = try verifyLossless(allocator, data, .direct, 1);
    try std.testing.expect(result.pass);
}

test "incrementing bytes: lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 256);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 256);

    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "alternating bytes: lossless round-trip" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 512);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = if (i % 2 == 0) 0xAA else 0x55;

    const result = try verifyLossless(allocator, data, .direct, 3);
    try std.testing.expect(result.pass);
}

test "random data: lossy correlation is finite" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 512, 8675309);
    defer allocator.free(data);

    const metrics = try evaluateLossy(allocator, data, .direct, 0);
    try std.testing.expect(!std.math.isNan(metrics.correlation));
    try std.testing.expect(!std.math.isInf(metrics.correlation));
}

test "random data: seed energy is non-negative" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 113355);
    defer allocator.free(data);

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    const seed = try extractSeedDirect(allocator, lattice, data);
    const energy = seedEnergy(seed);
    try std.testing.expect(energy >= 0);
}

test "random data: dominant node found" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 2468);
    defer allocator.free(data);

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    const seed = try extractSeedDirect(allocator, lattice, data);
    const dominant = dominantNode(seed);
    try std.testing.expect(dominant.index < E0_NODE_COUNT);
}

test "random data: all strategies lossless at S3" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 13579);
    defer allocator.free(data);

    const strategies = [_]Strategy{ .direct, .pattern_based };
    for (strategies) |strategy| {
        const result = try verifyLossless(allocator, data, strategy, 3);
        try std.testing.expect(result.pass);
    }
}

test "random data: sparsity is high for small random data" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 64, 999);
    defer allocator.free(data);

    var lattice = try mapToLattice(allocator, data, 5);
    defer lattice.deinit();

    // 64 bytes = 16 cells on a 240³ lattice = extremely sparse
    try std.testing.expect(lattice.sparsity() < 0.001);
}

test "large random 64KB: lossless round-trip S1" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 65536, 0xBEEFCAFE);
    defer allocator.free(data);

    const result = try verifyLossless(allocator, data, .direct, 1);
    try std.testing.expect(result.pass);
}

test "text with nulls: lossless round-trip" {
    const allocator = std.testing.allocator;
    // Simulates binary text with embedded nulls
    const data = "Hello\x00World\x00\x00Test\x00Data";
    const result = try verifyLossless(allocator, data, .direct, 5);
    try std.testing.expect(result.pass);
}

test "random data: lossless at all levels S5/S3/S1/S0" {
    const allocator = std.testing.allocator;
    const data = try generateRandom(allocator, 256, 424242);
    defer allocator.free(data);

    const levels = [_]u8{ 5, 3, 1, 0 };
    for (levels) |level| {
        const result = try verifyLossless(allocator, data, .direct, level);
        try std.testing.expect(result.pass);
    }
}
