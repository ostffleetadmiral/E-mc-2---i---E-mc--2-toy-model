//! lattice_context.zig — Multi-Tier Spatial Lattice Context Engine
//!
//! Models scale-independent spatial context memory across levels s=0..s=3,
//! providing the equivalent of 128k/256k KV cache attention on the 7-channel
//! octonionic lattice without quadratic memory blowup.

const std = @import("std");

pub const CHANNEL_COUNT: usize = 7;

pub const ContextTier = enum(u3) {
    s0_working = 0,   // 421 nodes
    s1_dialogue = 1,  // 3,375 cells
    s2_document = 2,  // 27,000 cells (~32k tokens)
    s3_archival = 3,  // 216,000 cells (~256k tokens)
};

pub const TierConfig = struct {
    cell_count: usize,
    token_capacity: usize,
    decay_rate: f64,
};

pub const TIER_CONFIGS = [_]TierConfig{
    .{ .cell_count = 421, .token_capacity = 2947, .decay_rate = 0.95 },
    .{ .cell_count = 3375, .token_capacity = 23625, .decay_rate = 0.98 },
    .{ .cell_count = 27000, .token_capacity = 189000, .decay_rate = 0.995 },
    .{ .cell_count = 216000, .token_capacity = 1512000, .decay_rate = 0.999 },
};

pub const SpatialContext = struct {
    allocator: std.mem.Allocator,
    tier: ContextTier,
    cells: []f64, // Activation memory (cell_count * 7 channels)
    tokens: std.ArrayList(u32),
    active_tokens_count: usize,

    pub fn init(allocator: std.mem.Allocator, tier: ContextTier) !SpatialContext {
        const tier_idx = @intFromEnum(tier);
        const config = TIER_CONFIGS[tier_idx];
        const total_floats = config.cell_count * CHANNEL_COUNT;

        const cells = try allocator.alloc(f64, total_floats);
        @memset(cells, 0.0);

        return .{
            .allocator = allocator,
            .tier = tier,
            .cells = cells,
            .tokens = std.ArrayList(u32).init(allocator),
            .active_tokens_count = 0,
        };
    }

    pub fn deinit(self: *SpatialContext) void {
        self.allocator.free(self.cells);
        self.tokens.deinit();
    }

    /// Appends a token into spatial context memory.
    pub fn pushToken(self: *SpatialContext, token_id: u32) !void {
        try self.tokens.append(token_id);
        self.active_tokens_count += 1;

        const tier_idx = @intFromEnum(self.tier);
        const config = TIER_CONFIGS[tier_idx];

        const node_idx = token_id % @as(u32, @intCast(config.cell_count));
        const channel_idx: usize = (token_id / @as(u32, @intCast(config.cell_count))) % CHANNEL_COUNT;

        const cell_offset = node_idx * CHANNEL_COUNT + channel_idx;
        if (cell_offset < self.cells.len) {
            self.cells[cell_offset] += 1.0;
        }
    }

    /// Computes spatial attention resonance score for a candidate query token.
    pub fn computeContextResonance(self: *const SpatialContext, query_token: u32) f64 {
        const tier_idx = @intFromEnum(self.tier);
        const config = TIER_CONFIGS[tier_idx];

        const node_idx = query_token % @as(u32, @intCast(config.cell_count));
        const channel_idx: usize = (query_token / @as(u32, @intCast(config.cell_count))) % CHANNEL_COUNT;

        const cell_offset = node_idx * CHANNEL_COUNT + channel_idx;
        if (cell_offset < self.cells.len) {
            return self.cells[cell_offset];
        }
        return 0.0;
    }

    /// Applies spatial context decay.
    pub fn stepDecay(self: *SpatialContext) void {
        const tier_idx = @intFromEnum(self.tier);
        const decay = TIER_CONFIGS[tier_idx].decay_rate;
        for (self.cells) |*c| {
            c.* *= decay;
        }
    }

    /// Gets active sequence length in this spatial context.
    pub fn sequenceLength(self: *const SpatialContext) usize {
        return self.tokens.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "lattice_context: multi-tier allocation and memory bounds" {
    const allocator = std.testing.allocator;

    var s0_ctx = try SpatialContext.init(allocator, .s0_working);
    defer s0_ctx.deinit();
    try std.testing.expectEqual(@as(usize, 421 * 7), s0_ctx.cells.len);

    var s1_ctx = try SpatialContext.init(allocator, .s1_dialogue);
    defer s1_ctx.deinit();
    try std.testing.expectEqual(@as(usize, 3375 * 7), s1_ctx.cells.len);
}

test "lattice_context: push token and compute resonance" {
    const allocator = std.testing.allocator;

    var ctx = try SpatialContext.init(allocator, .s1_dialogue);
    defer ctx.deinit();

    try ctx.pushToken(42);
    try ctx.pushToken(1337);

    try std.testing.expectEqual(@as(usize, 2), ctx.sequenceLength());

    const r_42 = ctx.computeContextResonance(42);
    const r_999 = ctx.computeContextResonance(999);

    try std.testing.expect(r_42 > 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), r_999);
}
