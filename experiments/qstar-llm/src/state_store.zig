//! StateStore — file-based agent state persistence.
//!
//! Replaces Qstar's VFSBridge for standalone agent state save/load.
//! Provides the same saveAgentState / loadAgentState / hasAgentState / clearAgentState
//! interface but uses simple in-memory buffers instead of VFS pages.
//! Zero external dependencies beyond std.

const std = @import("std");

pub const E0_NODE_COUNT: usize = 421;
pub const CHANNEL_COUNT: usize = 7;

pub const AgentState = struct {
    activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128,
    cycle: u64,
    temperature: i128,
    base_temp: i128,
    output_tokens: []u32,
};

pub const StateStore = struct {
    allocator: std.mem.Allocator,
    saved_state: ?AgentState,
    has_state: bool,

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return .{
            .allocator = allocator,
            .saved_state = null,
            .has_state = false,
        };
    }

    pub fn deinit(self: *StateStore) void {
        if (self.saved_state) |state| {
            self.allocator.free(state.output_tokens);
        }
        self.saved_state = null;
    }

    pub fn saveAgentState(
        self: *StateStore,
        activations: []const [CHANNEL_COUNT]i128,
        cycle: u64,
        temperature: i128,
        base_temp: i128,
        output_tokens: []const u32,
    ) !void {
        // Free previous saved state if any
        if (self.saved_state) |old| {
            self.allocator.free(old.output_tokens);
        }

        // Copy activations
        var act_copy: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
        const copy_count = @min(activations.len, E0_NODE_COUNT);
        for (0..copy_count) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                act_copy[i][ch] = activations[i][ch];
            }
        }
        // Zero remaining if activations is shorter
        for (copy_count..E0_NODE_COUNT) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                act_copy[i][ch] = 0;
            }
        }

        // Copy output tokens
        const tokens_copy = try self.allocator.alloc(u32, output_tokens.len);
        @memcpy(tokens_copy, output_tokens);

        self.saved_state = .{
            .activations = act_copy,
            .cycle = cycle,
            .temperature = temperature,
            .base_temp = base_temp,
            .output_tokens = tokens_copy,
        };
        self.has_state = true;
    }

    pub fn loadAgentState(
        self: *StateStore,
        out_activations: *[E0_NODE_COUNT][CHANNEL_COUNT]i128,
    ) !?struct {
        cycle: u64,
        temperature: i128,
        base_temp: i128,
        output_tokens: []u32,
    } {
        if (!self.has_state or self.saved_state == null) return null;

        const state = self.saved_state.?;

        // Copy activations to output
        for (0..E0_NODE_COUNT) |i| {
            for (0..CHANNEL_COUNT) |ch| {
                out_activations[i][ch] = state.activations[i][ch];
            }
        }

        // Copy output tokens (caller must free)
        const tokens_copy = try self.allocator.alloc(u32, state.output_tokens.len);
        @memcpy(tokens_copy, state.output_tokens);

        return .{
            .cycle = state.cycle,
            .temperature = state.temperature,
            .base_temp = state.base_temp,
            .output_tokens = tokens_copy,
        };
    }

    pub fn hasAgentState(self: *const StateStore) bool {
        return self.has_state;
    }

    pub fn clearAgentState(self: *StateStore) void {
        if (self.saved_state) |state| {
            self.allocator.free(state.output_tokens);
        }
        self.saved_state = null;
        self.has_state = false;
    }
};

test "StateStore save and load round-trip" {
    const allocator = std.testing.allocator;
    var store = StateStore.init(allocator);
    defer store.deinit();

    // Create test state
    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            activations[i][ch] = @intCast(@as(i128, @intCast(i)) * 7 + @as(i128, @intCast(ch)));
        }
    }
    const tokens = [_]u32{ 10, 20, 30, 40, 50 };

    try store.saveAgentState(&activations, 42, 5000, 10000, &tokens);
    try std.testing.expect(store.hasAgentState());

    // Load into fresh buffer
    var loaded_activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
    const result = try store.loadAgentState(&loaded_activations);
    try std.testing.expect(result != null);
    const r = result.?;
    defer allocator.free(r.output_tokens);

    try std.testing.expectEqual(@as(u64, 42), r.cycle);
    try std.testing.expectEqual(@as(i128, 5000), r.temperature);
    try std.testing.expectEqual(@as(i128, 10000), r.base_temp);
    try std.testing.expectEqual(@as(usize, 5), r.output_tokens.len);
    try std.testing.expectEqual(@as(u32, 10), r.output_tokens[0]);
    try std.testing.expectEqual(@as(u32, 50), r.output_tokens[4]);

    for (0..10) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            try std.testing.expectEqual(activations[i][ch], loaded_activations[i][ch]);
        }
    }
}

test "StateStore load returns null when no state saved" {
    const allocator = std.testing.allocator;
    var store = StateStore.init(allocator);
    defer store.deinit();

    try std.testing.expect(!store.hasAgentState());

    var loaded_activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
    const result = try store.loadAgentState(&loaded_activations);
    try std.testing.expect(result == null);
}

test "StateStore save overwrites previous state" {
    const allocator = std.testing.allocator;
    var store = StateStore.init(allocator);
    defer store.deinit();

    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
    for (0..E0_NODE_COUNT) |i| {
        for (0..CHANNEL_COUNT) |ch| {
            activations[i][ch] = @intCast(@as(i128, @intCast(i)));
        }
    }
    const tokens1 = [_]u32{ 1, 2, 3 };
    try store.saveAgentState(&activations, 10, 100, 200, &tokens1);
    try std.testing.expect(store.hasAgentState());

    const tokens2 = [_]u32{ 4, 5, 6, 7, 8, 9 };
    try store.saveAgentState(&activations, 20, 300, 400, &tokens2);

    var loaded_activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
    const result = try store.loadAgentState(&loaded_activations);
    const r = result.?;
    defer allocator.free(r.output_tokens);

    try std.testing.expectEqual(@as(u64, 20), r.cycle);
    try std.testing.expectEqual(@as(i128, 300), r.temperature);
    try std.testing.expectEqual(@as(usize, 6), r.output_tokens.len);
}

test "StateStore clearAgentState removes saved state" {
    const allocator = std.testing.allocator;
    var store = StateStore.init(allocator);
    defer store.deinit();

    var activations: [E0_NODE_COUNT][CHANNEL_COUNT]i128 = undefined;
    const tokens = [_]u32{ 1, 2 };
    try store.saveAgentState(&activations, 5, 100, 200, &tokens);
    try std.testing.expect(store.hasAgentState());

    store.clearAgentState();
    try std.testing.expect(!store.hasAgentState());

    const result = try store.loadAgentState(&activations);
    try std.testing.expect(result == null);
}

// =============================================================================
// Framework Constants (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework E0 node count: 421 = (15³ - 7) / 8.
pub const FRAMEWORK_E0_NODE_COUNT: u32 = 421;

/// Framework 7-defect: 2³ - 1 = 7.
pub const FRAMEWORK_SEVEN_DEFECT: u32 = 7;

/// Framework consciousness aperture: 1/8.
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_NUM: u32 = 1;
pub const FRAMEWORK_CONSCIOUSNESS_APERTURE_DEN: u32 = 8;

/// Framework C=2 consciousness value.
pub const FRAMEWORK_CONSCIOUSNESS_C: u32 = 2;

/// Verifies the 421 identity: 421 = (15³ - 7) / 8.
pub fn verify421Identity() bool {
    return (3375 - 7) / 8 == 421;
}

test "framework: 421 identity" {
    try std.testing.expect(verify421Identity());
}
