//! samc_agent.zig — Multi-Channel SAMC Engine for Accelerated Agent Reasoning
//!
//! Applies Self-Assembly Monte Carlo topological edge reconnections across the
//! 421 E0 nodes and 7 reasoning channels, accelerating state relaxation and
//! avoiding local minima traps during phi-cooling inference loops.

const std = @import("std");
const samc_lattice = @import("samc_lattice");

pub const ONE: i64 = samc_lattice.ONE;
pub const HALF: i64 = samc_lattice.HALF;
pub const PHI: i64 = samc_lattice.PHI;
pub const PHI_INV: i64 = samc_lattice.PHI_INV;
pub const E0_NODE_COUNT: usize = samc_lattice.E0_NODE_COUNT;
pub const CHANNEL_COUNT: usize = 7;

pub const ChannelBond = struct {
    src_node: u32,
    src_channel: u3,
    dst_node: u32,
    dst_channel: u3,
    weight: i64 = ONE,
};

pub const SAMCAgent = struct {
    allocator: std.mem.Allocator,
    activations: [E0_NODE_COUNT][CHANNEL_COUNT]i64,
    bonds: std.ArrayList(ChannelBond),
    total_energy: i64,
    temperature: i64,
    cycle: u64,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) SAMCAgent {
        var bonds = std.ArrayList(ChannelBond).init(allocator);
        var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i64 = undefined;

        // Initialize neutral ground state
        for (0..E0_NODE_COUNT) |n| {
            for (0..CHANNEL_COUNT) |c| {
                activations[n][c] = 0;
            }
        }

        // Establish default intra-node channel pathways
        for (0..E0_NODE_COUNT) |n| {
            for (0..CHANNEL_COUNT - 1) |c| {
                bonds.append(.{
                    .src_node = @intCast(n),
                    .src_channel = @intCast(c),
                    .dst_node = @intCast(n),
                    .dst_channel = @intCast(c + 1),
                    .weight = ONE,
                }) catch {};
            }
        }

        return .{
            .allocator = allocator,
            .activations = activations,
            .bonds = bonds,
            .total_energy = 0,
            .temperature = ONE,
            .cycle = 0,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *SAMCAgent) void {
        self.bonds.deinit();
    }

    /// Ingests a token by injecting activation across specific E0 node channels
    pub fn ingestToken(self: *SAMCAgent, token_id: u32) void {
        const node_idx = @mod(token_id, @as(u32, @intCast(E0_NODE_COUNT)));
        const channel_idx: u3 = @intCast(@mod(token_id >> 8, @as(u32, @intCast(CHANNEL_COUNT))));
        self.activations[node_idx][channel_idx] += ONE;
    }

    /// Ingests a batch of token IDs
    pub fn ingestTokens(self: *SAMCAgent, tokens: []const u32) void {
        for (tokens) |t| {
            self.ingestToken(t);
        }
    }

    /// Computes total conserved charge across the entire 421x7 manifold
    pub fn totalCharge(self: *const SAMCAgent) i64 {
        var sum: i64 = 0;
        for (0..E0_NODE_COUNT) |n| {
            for (0..CHANNEL_COUNT) |c| {
                sum += self.activations[n][c];
            }
        }
        return sum;
    }

    /// Computes channel bond Hamiltonian energy
    pub fn computeBondEnergy(self: *const SAMCAgent, bond: ChannelBond) i64 {
        const act_src = self.activations[bond.src_node][bond.src_channel];
        const act_dst = self.activations[bond.dst_node][bond.dst_channel];

        const diff = act_src - act_dst;
        const diff_sq = samc_lattice.fpMul(diff, diff);

        // Distance factor: node distance + channel distance
        const n_diff: i64 = @as(i64, @as(i32, @intCast(bond.src_node)) - @as(i32, @intCast(bond.dst_node))) << 32;
        const c_diff: i64 = @as(i64, @as(i32, @intCast(bond.src_channel)) - @as(i32, @intCast(bond.dst_channel))) << 32;
        const dist_cost = samc_lattice.fpMul(n_diff, n_diff) + samc_lattice.fpMul(c_diff, c_diff);

        return diff_sq + (dist_cost >> 4);
    }

    /// Computes total Hamiltonian energy of the multi-channel agent network
    pub fn computeTotalEnergy(self: *const SAMCAgent) i64 {
        var total: i64 = 0;
        for (self.bonds.items) |bond| {
            total += self.computeBondEnergy(bond);
        }
        return total;
    }

    /// Performs one local 2-opt bond swap across reasoning channels
    pub fn stepBondSwap(self: *SAMCAgent) bool {
        if (self.bonds.items.len < 2) return false;
        var rand = self.prng.random();

        const b1_idx = rand.uintLessThan(usize, self.bonds.items.len);
        const b2_idx = rand.uintLessThan(usize, self.bonds.items.len);
        if (b1_idx == b2_idx) return false;

        const b1 = self.bonds.items[b1_idx];
        const b2 = self.bonds.items[b2_idx];

        // Ensure distinct endpoints
        if (b1.src_node == b2.src_node and b1.src_channel == b2.src_channel) return false;

        const h_old = self.computeBondEnergy(b1) + self.computeBondEnergy(b2);

        // Candidate swapped bonds: (b1.src -> b2.dst) and (b2.src -> b1.dst)
        const cand_b1 = ChannelBond{
            .src_node = b1.src_node,
            .src_channel = b1.src_channel,
            .dst_node = b2.dst_node,
            .dst_channel = b2.dst_channel,
            .weight = b1.weight,
        };
        const cand_b2 = ChannelBond{
            .src_node = b2.src_node,
            .src_channel = b2.src_channel,
            .dst_node = b1.dst_node,
            .dst_channel = b1.dst_channel,
            .weight = b2.weight,
        };

        const h_new = self.computeBondEnergy(cand_b1) + self.computeBondEnergy(cand_b2);
        const delta_h = h_new - h_old;

        var accept = false;
        if (delta_h <= 0) {
            accept = true;
        } else if (self.temperature <= 0) {
            accept = false;
        } else {
            const beta = samc_lattice.fpDiv(ONE, self.temperature);
            const exponent = samc_lattice.fpMul(delta_h, beta);
            const prob = samc_lattice.fpExpNeg(exponent);
            const r = @as(i64, rand.intRangeAtMost(i32, 0, 1 << 30)) << 2;
            if (r <= prob) {
                accept = true;
            }
        }

        if (!accept) return false;

        self.bonds.items[b1_idx] = cand_b1;
        self.bonds.items[b2_idx] = cand_b2;

        return true;
    }

    /// Sweeps across all channels and nodes
    pub fn sweep(self: *SAMCAgent) usize {
        var accepted: usize = 0;
        const total_moves = self.bonds.items.len;
        for (0..total_moves) |_| {
            if (self.stepBondSwap()) {
                accepted += 1;
            }
        }
        return accepted;
    }

    /// Relaxes the agent reasoning state using SAMC phi-cooling
    pub fn relaxSAMC(self: *SAMCAgent, sweeps: usize) struct { initial_energy: i64, final_energy: i64, accepted_swaps: usize } {
        const init_energy = self.computeTotalEnergy();
        var total_accepted: usize = 0;

        for (0..sweeps) |_| {
            total_accepted += self.sweep();
            self.temperature = samc_lattice.fpMul(self.temperature, PHI_INV);
        }

        self.cycle += 1;
        const final_energy = self.computeTotalEnergy();
        return .{
            .initial_energy = init_energy,
            .final_energy = final_energy,
            .accepted_swaps = total_accepted,
        };
    }

    /// Selects the highest coherence output token from the relaxed state
    pub fn sampleTopToken(self: *const SAMCAgent) u32 {
        var best_node: u32 = 0;
        var best_channel: u3 = 0;
        var best_act: i64 = std.math.minInt(i64);

        for (0..E0_NODE_COUNT) |n| {
            for (0..CHANNEL_COUNT) |c| {
                if (self.activations[n][c] > best_act) {
                    best_act = self.activations[n][c];
                    best_node = @intCast(n);
                    best_channel = @intCast(c);
                }
            }
        }

        return best_node | (@as(u32, best_channel) << 8);
    }
};

// Tests
test "SAMCAgent initialization and total charge conservation" {
    const allocator = std.testing.allocator;
    var agent = SAMCAgent.init(allocator, 42);
    defer agent.deinit();

    try std.testing.expectEqual(@as(i64, 0), agent.totalCharge());

    const tokens = [_]u32{ 12, 45, 99, 256, 420, 1024 };
    agent.ingestTokens(&tokens);

    const initial_charge = agent.totalCharge();
    try std.testing.expect(initial_charge > 0);

    const metrics = agent.relaxSAMC(10);
    _ = metrics;

    try std.testing.expectEqual(initial_charge, agent.totalCharge());
    try std.testing.expectEqual(@as(u64, 1), agent.cycle);
}

test "SAMCAgent token sampling" {
    const allocator = std.testing.allocator;
    var agent = SAMCAgent.init(allocator, 101);
    defer agent.deinit();

    agent.ingestToken(1337);
    const top = agent.sampleTopToken();
    try std.testing.expect(top > 0);
}
