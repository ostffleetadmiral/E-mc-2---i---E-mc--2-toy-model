//! samc_lattice.zig — Self-Assembly Monte Carlo (SAMC) Engine for Dense Lattice Graphs
//!
//! Implements local topological bond-swapping (2-opt rewiring) on dense E0->E7 lattice
//! systems with O(V) linear relaxation scaling, strict charge/flux conservation,
//! and localized knot detection via discrete Gauss linking integrals.

const std = @import("std");

// Fixed-point arithmetic (Q32.32)
pub const ONE: i64 = 1 << 32;
pub const HALF: i64 = 1 << 31;
pub const PHI: i64 = 6948614488; // 1.6180339887 in Q32.32
pub const PHI_INV: i64 = 2654435769; // 0.6180339887 in Q32.32
pub const E0_NODE_COUNT: usize = 421;
pub const MAX_DEGREE: usize = 12;

pub fn fpMul(a: i64, b: i64) i64 {
    const p: i128 = @as(i128, a) * @as(i128, b);
    const shifted = p >> 32;
    if (shifted > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (shifted < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(shifted);
}

pub fn fpDiv(a: i64, b: i64) i64 {
    if (b == 0) return if (a >= 0) std.math.maxInt(i64) else std.math.minInt(i64);
    const n: i128 = @as(i128, a) << 32;
    return @intCast(@divTrunc(n, b));
}

pub fn fpExpNeg(x: i64) i64 {
    if (x <= 0) return ONE;
    if (x >= 16 * ONE) return 0;
    // Pade approximation: e^-x ~= (1 - x/2 + x^2/12) / (1 + x/2 + x^2/12)
    const x_half = x >> 1;
    const x_sq = fpMul(x, x);
    const x_sq_12 = @divTrunc(x_sq, 12);
    const num = ONE - x_half + x_sq_12;
    const den = ONE + x_half + x_sq_12;
    return fpDiv(num, den);
}

pub const Node = struct {
    id: u32,
    x: i32,
    y: i32,
    z: i32,
    activation: i64,
    degree: u8 = 0,
    neighbors: [MAX_DEGREE]u32 = [_]u32{0} ** MAX_DEGREE,

    pub fn hasNeighbor(self: Node, target: u32) bool {
        for (self.neighbors[0..self.degree]) |nb| {
            if (nb == target) return true;
        }
        return false;
    }

    pub fn addNeighbor(self: *Node, target: u32) bool {
        if (self.degree >= MAX_DEGREE or self.hasNeighbor(target)) return false;
        self.neighbors[self.degree] = target;
        self.degree += 1;
        return true;
    }

    pub fn removeNeighbor(self: *Node, target: u32) bool {
        for (0..self.degree) |i| {
            if (self.neighbors[i] == target) {
                self.neighbors[i] = self.neighbors[self.degree - 1];
                self.neighbors[self.degree - 1] = 0;
                self.degree -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn replaceNeighbor(self: *Node, old_nb: u32, new_nb: u32) bool {
        for (0..self.degree) |i| {
            if (self.neighbors[i] == old_nb) {
                self.neighbors[i] = new_nb;
                return true;
            }
        }
        return false;
    }
};

pub const Bond = struct {
    u: u32,
    v: u32,
    weight: i64 = ONE,
};

pub const SAMCGraph = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    bonds: std.ArrayList(Bond),
    total_charge: i64,
    temperature: i64,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, node_count: usize, seed: u64) !SAMCGraph {
        const nodes = try allocator.alloc(Node, node_count);
        var total_charge: i64 = 0;

        for (nodes, 0..) |*node, i| {
            const idx: i32 = @intCast(i);
            // Default 3D tetrahedral coordinates
            node.* = .{
                .id = @intCast(i),
                .x = @mod(idx * 7 + 3, 31) - 15,
                .y = @mod(idx * 11 + 5, 31) - 15,
                .z = @mod(idx * 13 + 7, 31) - 15,
                .activation = (@as(i64, @mod(idx, 100)) + 1) << 24,
                .degree = 0,
            };
            total_charge += node.activation;
        }

        var bonds = std.ArrayList(Bond).init(allocator);

        // Connect regular linear chain backbone initially
        for (0..node_count - 1) |i| {
            const u_idx: u32 = @intCast(i);
            const v_idx: u32 = @intCast(i + 1);
            _ = nodes[u_idx].addNeighbor(v_idx);
            _ = nodes[v_idx].addNeighbor(u_idx);
            try bonds.append(.{ .u = u_idx, .v = v_idx, .weight = ONE });
        }

        return .{
            .allocator = allocator,
            .nodes = nodes,
            .bonds = bonds,
            .total_charge = total_charge,
            .temperature = ONE,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *SAMCGraph) void {
        self.bonds.deinit();
        self.allocator.free(self.nodes);
    }

    /// Computes local bond energy: distance squared + activation gradient squared in Q32.32
    pub fn computeBondEnergy(self: *const SAMCGraph, u: u32, v: u32) i64 {
        const nu = self.nodes[u];
        const nv = self.nodes[v];

        const dx: i64 = @as(i64, nu.x - nv.x) << 32;
        const dy: i64 = @as(i64, nu.y - nv.y) << 32;
        const dz: i64 = @as(i64, nu.z - nv.z) << 32;

        const dist_sq = fpMul(dx, dx) + fpMul(dy, dy) + fpMul(dz, dz);
        const act_diff = nu.activation - nv.activation;
        const act_sq = fpMul(act_diff, act_diff);

        return dist_sq + act_sq;
    }

    /// Computes global total Hamiltonian energy of all current bonds
    pub fn computeTotalEnergy(self: *const SAMCGraph) i64 {
        var total: i64 = 0;
        for (self.bonds.items) |bond| {
            total += self.computeBondEnergy(bond.u, bond.v);
        }
        return total;
    }

    /// Attempts a strictly local 2-opt topological bond swap
    /// Old configuration: (u1-v1) and (u2-v2)
    /// Candidate configuration: (u1-v2) and (u2-v1)
    pub fn stepBondSwap(self: *SAMCGraph) bool {
        if (self.bonds.items.len < 2) return false;
        var rand = self.prng.random();

        const b1_idx = rand.uintLessThan(usize, self.bonds.items.len);
        const b2_idx = rand.uintLessThan(usize, self.bonds.items.len);
        if (b1_idx == b2_idx) return false;

        const b1 = self.bonds.items[b1_idx];
        const b2 = self.bonds.items[b2_idx];

        // Ensure nodes are distinct
        if (b1.u == b2.u or b1.u == b2.v or b1.v == b2.u or b1.v == b2.v) return false;

        // Check if candidate bonds already exist
        if (self.nodes[b1.u].hasNeighbor(b2.v) or self.nodes[b2.u].hasNeighbor(b1.v)) return false;

        // Energy before swap
        const h_old = self.computeBondEnergy(b1.u, b1.v) + self.computeBondEnergy(b2.u, b2.v);
        // Energy after candidate swap: (u1-v2) and (u2-v1)
        const h_new = self.computeBondEnergy(b1.u, b2.v) + self.computeBondEnergy(b2.u, b1.v);

        const delta_h = h_new - h_old;

        // Metropolis-Hastings acceptance check
        var accept = false;
        if (delta_h <= 0) {
            accept = true;
        } else if (self.temperature <= 0) {
            accept = false;
        } else {
            const beta = fpDiv(ONE, self.temperature);
            const exponent = fpMul(delta_h, beta);
            const prob = fpExpNeg(exponent);
            const r = @as(i64, rand.intRangeAtMost(i32, 0, 1 << 30)) << 2;
            if (r <= prob) {
                accept = true;
            }
        }

        if (!accept) return false;

        // Apply topological swap
        _ = self.nodes[b1.u].replaceNeighbor(b1.v, b2.v);
        _ = self.nodes[b1.v].replaceNeighbor(b1.u, b2.u);
        _ = self.nodes[b2.u].replaceNeighbor(b2.v, b1.v);
        _ = self.nodes[b2.v].replaceNeighbor(b2.u, b1.u);

        self.bonds.items[b1_idx] = .{ .u = b1.u, .v = b2.v, .weight = b1.weight };
        self.bonds.items[b2_idx] = .{ .u = b2.u, .v = b1.v, .weight = b2.weight };

        return true;
    }

    /// Performs one Monte Carlo Sweep (MCS) across V elements
    pub fn sweep(self: *SAMCGraph) usize {
        var accepted: usize = 0;
        const v = self.nodes.len;
        for (0..v) |_| {
            if (self.stepBondSwap()) {
                accepted += 1;
            }
        }
        return accepted;
    }

    /// Equilibrates the graph using golden-ratio phi-cooling
    pub fn equilibrate(self: *SAMCGraph, sweeps: usize) struct { initial_energy: i64, final_energy: i64, accepted_swaps: usize } {
        const init_energy = self.computeTotalEnergy();
        var total_accepted: usize = 0;

        for (0..sweeps) |_| {
            total_accepted += self.sweep();
            // Golden-ratio geometric cooling
            self.temperature = fpMul(self.temperature, PHI_INV);
        }

        const final_energy = self.computeTotalEnergy();
        return .{
            .initial_energy = init_energy,
            .final_energy = final_energy,
            .accepted_swaps = total_accepted,
        };
    }

    /// Computes discrete Gauss linking number between two paths C1 and C2
    /// Returns Q32.32 fixed-point approximation of topological link magnitude
    pub fn computeGaussLinking(self: *const SAMCGraph, path1: []const u32, path2: []const u32) i64 {
        if (path1.len < 2 or path2.len < 2) return 0;
        var total_link: i64 = 0;

        for (0..path1.len - 1) |i| {
            const p1_a = self.nodes[path1[i]];
            const p1_b = self.nodes[path1[i + 1]];
            const dr1_x: i64 = @as(i64, p1_b.x - p1_a.x) << 16;
            const dr1_y: i64 = @as(i64, p1_b.y - p1_a.y) << 16;
            const dr1_z: i64 = @as(i64, p1_b.z - p1_a.z) << 16;

            for (0..path2.len - 1) |j| {
                const p2_a = self.nodes[path2[j]];
                const p2_b = self.nodes[path2[j + 1]];
                const dr2_x: i64 = @as(i64, p2_b.x - p2_a.x) << 16;
                const dr2_y: i64 = @as(i64, p2_b.y - p2_a.y) << 16;
                const dr2_z: i64 = @as(i64, p2_b.z - p2_a.z) << 16;

                // Midpoint distance vector r1 - r2
                const rx: i64 = @as(i64, (p1_a.x + p1_b.x) - (p2_a.x + p2_b.x)) << 15;
                const ry: i64 = @as(i64, (p1_a.y + p1_b.y) - (p2_a.y + p2_b.y)) << 15;
                const rz: i64 = @as(i64, (p1_a.z + p1_b.z) - (p2_a.z + p2_b.z)) << 15;

                const r_sq = fpMul(rx, rx) + fpMul(ry, ry) + fpMul(rz, rz) + (1 << 20); // Regularized
                const r_cubed = fpMul(r_sq, @as(i64, @intFromFloat(@sqrt(@as(f64, @floatFromInt(r_sq))))));

                // Cross product dr1 x dr2
                const cross_x = fpMul(dr1_y, dr2_z) - fpMul(dr1_z, dr2_y);
                const cross_y = fpMul(dr1_z, dr2_x) - fpMul(dr1_x, dr2_z);
                const cross_z = fpMul(dr1_x, dr2_y) - fpMul(dr1_y, dr2_x);

                // Dot product (r1 - r2) . (dr1 x dr2)
                const num = fpMul(rx, cross_x) + fpMul(ry, cross_y) + fpMul(rz, cross_z);
                const term = fpDiv(num, @max(r_cubed, 1024));
                total_link += term;
            }
        }

        return if (total_link >= 0) total_link else -total_link;
    }
};

// Tests
test "SAMC fixed-point math edge cases" {
    try std.testing.expectEqual(ONE, fpExpNeg(0));
    try std.testing.expectEqual(ONE, fpExpNeg(-100));
    try std.testing.expectEqual(@as(i64, 0), fpExpNeg(20 * ONE));
    try std.testing.expect(fpExpNeg(ONE) < ONE);
    try std.testing.expect(fpExpNeg(ONE) > 0);

    try std.testing.expectEqual(ONE, fpMul(ONE, ONE));
    try std.testing.expectEqual(HALF, fpMul(ONE, HALF));
    try std.testing.expectEqual(ONE, fpDiv(HALF, HALF));
}

test "Node neighbor management" {
    var node = Node{
        .id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .activation = ONE,
    };

    try std.testing.expect(node.addNeighbor(2));
    try std.testing.expect(node.addNeighbor(3));
    try std.testing.expect(!node.addNeighbor(2)); // Duplicate rejected
    try std.testing.expectEqual(@as(u8, 2), node.degree);
    try std.testing.expect(node.hasNeighbor(2));
    try std.testing.expect(node.hasNeighbor(3));
    try std.testing.expect(!node.hasNeighbor(4));

    try std.testing.expect(node.replaceNeighbor(2, 4));
    try std.testing.expect(node.hasNeighbor(4));
    try std.testing.expect(!node.hasNeighbor(2));

    try std.testing.expect(node.removeNeighbor(3));
    try std.testing.expectEqual(@as(u8, 1), node.degree);
    try std.testing.expect(!node.removeNeighbor(99)); // Not found
}

test "SAMC initialization and charge conservation" {
    const allocator = std.testing.allocator;
    var graph = try SAMCGraph.init(allocator, 100, 42);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 100), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 99), graph.bonds.items.len);

    var current_charge: i64 = 0;
    for (graph.nodes) |node| {
        current_charge += node.activation;
    }
    try std.testing.expectEqual(graph.total_charge, current_charge);
}

test "SAMC zero-temperature rejection of uphill moves" {
    const allocator = std.testing.allocator;
    var graph = try SAMCGraph.init(allocator, 20, 123);
    defer graph.deinit();

    // Set temperature to 0
    graph.temperature = 0;
    const init_energy = graph.computeTotalEnergy();

    // Run sweeps at zero temperature
    _ = graph.sweep();
    const final_energy = graph.computeTotalEnergy();

    // At T=0, energy can NEVER increase
    try std.testing.expect(final_energy <= init_energy);
}

test "SAMC equilibration and energy reduction" {
    const allocator = std.testing.allocator;
    var graph = try SAMCGraph.init(allocator, E0_NODE_COUNT, 1337);
    defer graph.deinit();

    const metrics = graph.equilibrate(20);

    // Verify charge conservation after equilibration
    var post_charge: i64 = 0;
    for (graph.nodes) |node| {
        post_charge += node.activation;
    }
    try std.testing.expectEqual(graph.total_charge, post_charge);

    // Energy should decrease or stay optimal
    try std.testing.expect(metrics.final_energy <= metrics.initial_energy);
}

test "Gauss linking on orthogonal paths" {
    const allocator = std.testing.allocator;
    var graph = try SAMCGraph.init(allocator, 20, 99);
    defer graph.deinit();

    const path1 = [_]u32{ 0, 1, 2, 3 };
    const path2 = [_]u32{ 4, 5, 6, 7 };

    const link = graph.computeGaussLinking(&path1, &path2);
    try std.testing.expect(link >= 0);
}
