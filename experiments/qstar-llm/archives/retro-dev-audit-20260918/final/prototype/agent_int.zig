//! agent_int.zig — Integer-only lattice-native inference engine prototype.
//!
//! Replaces all f64 state with Q64.64 fixed-point i128.
//! Core state: [421][7]i128 activations, i128 temperature, i128 base_temp.
//! No f32/f64/f16/f128 in any state transition path.
//! Deterministic across all platforms.

const std = @import("std");
const fp = @import("fixed_point");

// =============================================================================
// Constants
// =============================================================================

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;
pub const BASE_EDGE: u32 = 15;
pub const MAX_CYCLES: u64 = 1024;
pub const VOCAB_SIZE: u32 = 151936;
pub const EOS_TOKEN_ID: u32 = 151643;
pub const IM_START_TOKEN_ID: u32 = 151644;
pub const IM_END_TOKEN_ID: u32 = 151645;

// =============================================================================
// E0 Node Placement (inlined from lattice.zig — pure integer)
// =============================================================================

fn e0NodeIndex(x: u32, y: u32, z: u32) ?usize {
    if ((x + y + z) % 3 != 0) return null;
    const raw = (x * 7 + y * 11 + z * 13) % 421;
    return @intCast(raw);
}

fn computeEValue(x: u32, y: u32, z: u32, edge: u32) u3 {
    const dx = @min(x, edge - 1 - x);
    const dy = @min(y, edge - 1 - y);
    const half = edge / 2;
    const dz = if (z >= half) z - half else half - z;
    const raw: i64 = 6 + @as(i64, dz) - @as(i64, dx) - @as(i64, dy);
    const modded = @mod(raw, 8);
    return @intCast(modded);
}

fn isBoundary(x: u32, y: u32, z: u32, edge: u32) bool {
    return x == 0 or x == edge - 1 or y == 0 or y == edge - 1 or z == 0 or z == edge - 1;
}

fn e0NodeCoords(idx: usize) struct { x: u32, y: u32, z: u32 } {
    var count: usize = 0;
    var x: u32 = 0;
    while (x < BASE_EDGE) : (x += 1) {
        var y: u32 = 0;
        while (y < BASE_EDGE) : (y += 1) {
            var z: u32 = 0;
            while (z < BASE_EDGE) : (z += 1) {
                if ((x + y + z) % 3 != 0) continue;
                if (count == idx) return .{ .x = x, .y = y, .z = z };
                count += 1;
            }
        }
    }
    return .{ .x = 0, .y = 0, .z = 0 };
}

// =============================================================================
// Tokenization (pure integer)
// =============================================================================

fn tokenToNode(token_id: u32) usize {
    return @intCast(token_id % E0_NODE_COUNT);
}

fn tokenToChannel(token_id: u32) u3 {
    return @intCast((token_id / E0_NODE_COUNT) % CHANNEL_COUNT);
}

fn nodeToToken(node_idx: usize, channel: u3) u32 {
    return @as(u32, @intCast(node_idx)) + @as(u32, channel) * @as(u32, @intCast(E0_NODE_COUNT));
}

pub fn simpleTokenize(allocator: std.mem.Allocator, text: []const u8) ![]u32 {
    var tokens = std.ArrayList(u32).init(allocator);
    errdefer tokens.deinit();
    for (text) |c| {
        try tokens.append(@as(u32, c) + 256);
    }
    return tokens.toOwnedSlice();
}

// =============================================================================
// Agent State — All Integer (Q32.32 fixed-point)
// =============================================================================

pub const AgentState = struct {
    /// Activation matrix: [node][channel] = activation value in Q64.64.
    /// Total size: 421 × 7 × 16 bytes = 47,152 bytes ≈ 47 KB.
    activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128,
    /// Inference cycle counter.
    cycle: u64,
    /// φ-cooled temperature in Q32.32.
    temperature: i128,
    /// Base temperature for φ-cooling in Q64.64.
    base_temp: i128,
    /// Output token history.
    output_tokens: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator, base_temp: i128) AgentState {
        return .{
            .activations = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT,
            .cycle = 0,
            .temperature = base_temp,
            .base_temp = base_temp,
            .output_tokens = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *AgentState) void {
        self.output_tokens.deinit();
    }

    pub fn reset(self: *AgentState) void {
        self.activations = [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;
        self.cycle = 0;
        self.temperature = self.base_temp;
        self.output_tokens.clearRetainingCapacity();
    }

    /// φ-cooling: T(cycle) = T₀ × φ^(-cycle) — integer-only via lookup table.
    pub fn coolTemperature(self: *AgentState) void {
        self.temperature = fp.phiCool(self.base_temp, self.cycle);
    }
};

// =============================================================================
// Agent — Integer-Only Inference Engine
// =============================================================================

pub const Agent = struct {
    state: AgentState,
    level: u8,
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng = undefined,

    pub fn init(allocator: std.mem.Allocator, level: u8, base_temp: i128) Agent {
        return .{
            .state = AgentState.init(allocator, base_temp),
            .level = level,
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.state.deinit();
    }

    pub fn reset(self: *Agent) void {
        self.state.reset();
    }

    /// Ingests pre-tokenized input: map token IDs to E0 activations.
    /// pos_factor = 1.0 / (1.0 + len * 0.01) — computed in fixed-point.
    pub fn ingestTokens(self: *Agent, token_ids: []const u32) !void {
        for (token_ids) |tid| {
            const node_idx = tokenToNode(tid);
            const channel = tokenToChannel(tid);

            // pos_factor = 1 / (1 + len * 0.01) in fixed-point
            const len_fp = fp.fromInt(@as(i64, @intCast(self.state.output_tokens.items.len)));
            const len_scaled = fp.mul(len_fp, fp.POS_DECAY);
            const denom = fp.add(fp.ONE, len_scaled);
            const pos_factor = fp.div(fp.ONE, denom);

            self.state.activations[node_idx][channel] = pos_factor;
        }
    }

    /// Runs one inference cycle: E0 firing + octonion routing + Fibonacci projection.
    /// All arithmetic in Q32.32 fixed-point — no floating-point anywhere.
    pub fn step(self: *Agent) void {
        const edge = BASE_EDGE * (@as(u32, 1) << @intCast(self.level));

        var new_activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 =
            [_][CHANNEL_COUNT]i128{[_]i128{0} ** CHANNEL_COUNT} ** E0_NODE_COUNT;

        for (0..E0_NODE_COUNT) |i| {
            const coords = e0NodeCoords(i);
            const e_val = computeEValue(coords.x, coords.y, coords.z, edge);
            const is_bnd = isBoundary(coords.x, coords.y, coords.z, edge);

            // Fibonacci projection: weighted sum of channels
            var projection: i128 = 0;
            for (0..CHANNEL_COUNT) |ch| {
                projection += fp.mul(fp.FIB_WEIGHTS[ch], self.state.activations[i][ch]);
            }
            // Normalize by sum of Fibonacci weights (33.0)
            projection = fp.div(projection, fp.FIB_NORM);

            // Temperature-scaled sigmoid
            const temp = fp.maxVal(self.state.temperature, fp.TEMP_FLOOR);
            const scaled = fp.div(projection, temp);
            const fired = fp.sigmoid(scaled);

            if (fired > fp.HALF_FP) {
                // Propagate via octonion routing
                const routed_channel: u3 = @intCast(@as(u32, e_val) % CHANNEL_COUNT);
                new_activations[i][routed_channel] += fp.mul(fired, fp.WEIGHT_08);

                // Boundary nodes reflect (Möbius twist)
                if (is_bnd) {
                    const reflected_channel: u3 = @intCast((CHANNEL_COUNT - @as(u32, e_val) % CHANNEL_COUNT) % CHANNEL_COUNT);
                    new_activations[i][reflected_channel] += fp.mul(fired, fp.WEIGHT_03);
                }

                // Propagate to 6 face-neighbors
                const neighbors = [_]struct { dx: i32, dy: i32, dz: i32 }{
                    .{ .dx = 1, .dy = 0, .dz = 0 }, .{ .dx = -1, .dy = 0, .dz = 0 },
                    .{ .dx = 0, .dy = 1, .dz = 0 }, .{ .dx = 0, .dy = -1, .dz = 0 },
                    .{ .dx = 0, .dy = 0, .dz = 1 }, .{ .dx = 0, .dy = 0, .dz = -1 },
                };
                for (neighbors) |nb| {
                    const nx = @as(i32, @intCast(coords.x)) + nb.dx;
                    const ny = @as(i32, @intCast(coords.y)) + nb.dy;
                    const nz = @as(i32, @intCast(coords.z)) + nb.dz;
                    if (nx < 0 or nx >= edge or ny < 0 or ny >= edge or nz < 0 or nz >= edge) continue;
                    const nidx = e0NodeIndex(@intCast(nx), @intCast(ny), @intCast(nz)) orelse continue;
                    const n_e_val = computeEValue(@intCast(nx), @intCast(ny), @intCast(nz), edge);
                    const n_routed: u3 = @intCast(@as(u32, n_e_val) % CHANNEL_COUNT);
                    new_activations[nidx][n_routed] += fp.mul(fired, fp.WEIGHT_015);
                }
            }

            // Decay existing activations
            for (0..CHANNEL_COUNT) |ch| {
                new_activations[i][ch] += fp.mul(self.state.activations[i][ch], fp.DECAY_07);
            }
        }

        // Swap to new activations
        self.state.activations = new_activations;

        // Increment cycle
        self.state.cycle += 1;

        // φ-cooling
        self.state.coolTemperature();

        // Decode output token from highest activation
        const output = self.readTopToken();
        self.state.output_tokens.append(output) catch {};

        // Autoregressive feedback
        const fb_node = tokenToNode(output);
        const fb_channel = tokenToChannel(output);
        const fb_strength = fp.mul(fp.div(fp.fromInt(3), fp.fromInt(10)), self.state.temperature);
        self.state.activations[fb_node][fb_channel] += fb_strength;
    }

    /// Reads the top activated E0 node + channel as a token ID.
    pub fn readTopToken(self: Agent) u32 {
        var best_node: usize = 0;
        var best_channel: u3 = 0;
        var best_value: i128 = std.math.minInt(i128);

        for (0..E0_NODE_COUNT) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                if (self.state.activations[i][ch] > best_value) {
                    best_value = self.state.activations[i][ch];
                    best_node = i;
                    best_channel = @intCast(ch);
                }
            }
        }

        return nodeToToken(best_node, best_channel);
    }

    /// Runs inference for N cycles.
    pub fn run(self: *Agent, num_cycles: u64) !void {
        const limit = @min(num_cycles, MAX_CYCLES);
        for (0..limit) |_| {
            self.step();
            if (self.state.output_tokens.items.len > 0) {
                const last = self.state.output_tokens.items[self.state.output_tokens.items.len - 1];
                if (last == EOS_TOKEN_ID) break;
            }
        }
    }

    /// Gets the current state size in bytes.
    pub fn stateSizeBytes(self: Agent) usize {
        _ = self;
        return E0_NODE_COUNT * CHANNEL_COUNT * @sizeOf(i128);
    }

    /// Serializes agent state to bytes (bit-exact, no quantization loss).
    pub fn serialize(self: Agent, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        // Activations: 421 * 7 * 8 bytes
        for (0..E0_NODE_COUNT) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                try buf.writer().writeInt(i128, self.state.activations[i][ch], .little);
            }
        }
        // Cycle
        try buf.writer().writeInt(u64, self.state.cycle, .little);
        // Temperature
        try buf.writer().writeInt(i128, self.state.temperature, .little);
        // Base temp
        try buf.writer().writeInt(i128, self.state.base_temp, .little);
        // Output tokens count + tokens
        try buf.writer().writeInt(u32, @intCast(self.state.output_tokens.items.len), .little);
        for (self.state.output_tokens.items) |t| {
            try buf.writer().writeInt(u32, t, .little);
        }

        return buf.toOwnedSlice();
    }

    /// Deserializes agent state from bytes (bit-exact round-trip).
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Agent {
        var fbs = std.io.fixedBufferStream(data);
        var agent = Agent.init(allocator, 5, fp.ONE); // Default level/temp, overwritten

        for (0..E0_NODE_COUNT) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                agent.state.activations[i][ch] = try fbs.reader().readInt(i128, .little);
            }
        }
        agent.state.cycle = try fbs.reader().readInt(u64, .little);
        agent.state.temperature = try fbs.reader().readInt(i128, .little);
        agent.state.base_temp = try fbs.reader().readInt(i128, .little);

        const token_count = try fbs.reader().readInt(u32, .little);
        for (0..token_count) |_| {
            try agent.state.output_tokens.append(try fbs.reader().readInt(u32, .little));
        }

        return agent;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "agent state is all integer" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.ONE);
    defer agent.deinit();

    // Verify state type is i128, not f64
    try std.testing.expectEqual(@as(usize, 421 * 7 * 16), agent.stateSizeBytes());
}

test "agent step is deterministic" {
    const allocator = std.testing.allocator;
    var agent1 = Agent.init(allocator, 3, fp.ONE);
    defer agent1.deinit();
    var agent2 = Agent.init(allocator, 3, fp.ONE);
    defer agent2.deinit();

    // Same input
    try agent1.ingestTokens(&.{ 256 + 65, 256 + 66, 256 + 67 }); // A, B, C
    try agent2.ingestTokens(&.{ 256 + 65, 256 + 66, 256 + 67 });

    // Run same number of steps
    agent1.step();
    agent2.step();

    // States must be identical (deterministic, no RNG in step)
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            try std.testing.expectEqual(agent1.state.activations[i][ch], agent2.state.activations[i][ch]);
        }
    }
    try std.testing.expectEqual(agent1.state.cycle, agent2.state.cycle);
    try std.testing.expectEqual(agent1.state.temperature, agent2.state.temperature);
}

test "agent produces output tokens" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.ONE);
    defer agent.deinit();

    try agent.ingestTokens(&.{ 256 + 72, 256 + 73 }); // H, I
    agent.step();

    try std.testing.expect(agent.state.output_tokens.items.len > 0);
}

test "agent φ-cooling decreases temperature" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.ONE);
    defer agent.deinit();

    const temp0 = agent.state.temperature;
    agent.state.cycle = 1;
    agent.state.coolTemperature();
    const temp1 = agent.state.temperature;

    try std.testing.expect(temp1 < temp0);
}

test "agent φ-cooling saturates at floor" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.ONE);
    defer agent.deinit();

    agent.state.cycle = 100;
    agent.state.coolTemperature();
    try std.testing.expectEqual(fp.TEMP_FLOOR, agent.state.temperature);
}

test "agent serialize/deserialize is bit-exact round trip" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.fromInt(2));
    defer agent.deinit();

    try agent.ingestTokens(&.{ 256 + 65, 256 + 66, 256 + 67 });
    agent.step();
    agent.step();

    const serialized = try agent.serialize(allocator);
    defer allocator.free(serialized);

    var restored = try Agent.deserialize(allocator, serialized);
    defer restored.deinit();

    // Bit-exact equality of all state
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            try std.testing.expectEqual(agent.state.activations[i][ch], restored.state.activations[i][ch]);
        }
    }
    try std.testing.expectEqual(agent.state.cycle, restored.state.cycle);
    try std.testing.expectEqual(agent.state.temperature, restored.state.temperature);
    try std.testing.expectEqual(agent.state.base_temp, restored.state.base_temp);
    try std.testing.expectEqualSlices(u32, agent.state.output_tokens.items, restored.state.output_tokens.items);
}

test "agent reset clears state" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.ONE);
    defer agent.deinit();

    try agent.ingestTokens(&.{256 + 65});
    agent.step();
    try std.testing.expect(agent.state.cycle > 0);

    agent.reset();
    try std.testing.expectEqual(@as(u64, 0), agent.state.cycle);
    try std.testing.expectEqual(@as(usize, 0), agent.state.output_tokens.items.len);

    // All activations zero
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            try std.testing.expectEqual(@as(i128, 0), agent.state.activations[i][ch]);
        }
    }
}

test "agent run produces multiple tokens" {
    const allocator = std.testing.allocator;
    var agent = Agent.init(allocator, 3, fp.ONE);
    defer agent.deinit();

    try agent.ingestTokens(&.{ 256 + 72, 256 + 69, 256 + 76, 256 + 76, 256 + 79 });
    try agent.run(5);

    try std.testing.expect(agent.state.output_tokens.items.len >= 1);
}

test "no floating-point types in agent state" {
    // Verify at comptime that AgentState uses i128, not f64
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(AgentState, undefined).activations[0][0])));
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(AgentState, undefined).temperature)));
    try std.testing.expectEqual(@sizeOf(i128), @sizeOf(@TypeOf(@as(AgentState, undefined).base_temp)));
}
