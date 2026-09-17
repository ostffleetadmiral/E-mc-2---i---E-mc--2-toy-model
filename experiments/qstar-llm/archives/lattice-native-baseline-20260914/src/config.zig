//! config.zig — Unified configuration for Qstar modules.
//!
//! Centralizes all tunable parameters so they can be adjusted at runtime
//! without recompiling. Supports loading from JSON and programmatic override.

const std = @import("std");
const fp = @import("fixed_point");

pub const Config = struct {
    // Compression
    lattice_level: u8 = 5,
    use_dedup: bool = true,
    qubit_config: u8 = 1,

    // Agent
    agent_level: u8 = 0,
    agent_base_temp: i128 = fp.ONE,
    agent_max_cycles: u64 = 1024,

    // Mesh
    mesh_port: u16 = 9753,
    mesh_sync_interval_ms: u64 = 100,
    mesh_max_connections: usize = 16,

    // Memory
    pool_block_size: usize = 256,
    pool_capacity: usize = 64,
    arena_size: usize = 65536,

    // Build/optimization
    strip_binaries: bool = true,
    wasm_optimize: std.builtin.OptimizeMode = .ReleaseSmall,

    pub inline fn default() Config {
        return .{};
    }

    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !Config {
        var parsed = try std.json.parseFromSlice(Config, allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return parsed.value;
    }

    pub fn toJson(self: Config, allocator: std.mem.Allocator) ![]u8 {
        return try std.json.stringifyAlloc(allocator, self, .{});
    }
};

// =============================================================================
// Tests
// =============================================================================

test "config default values" {
    const c = Config.default();
    try std.testing.expectEqual(@as(u8, 5), c.lattice_level);
    try std.testing.expect(c.use_dedup);
    try std.testing.expectEqual(@as(u64, 1024), c.agent_max_cycles);
}

test "config json round trip" {
    const allocator = std.testing.allocator;
    const original = Config{
        .lattice_level = 7,
        .use_dedup = false,
        .agent_max_cycles = 512,
        .mesh_port = 8080,
    };
    const json = try original.toJson(allocator);
    defer allocator.free(json);

    const restored = try Config.fromJson(allocator, json);
    try std.testing.expectEqual(@as(u8, 7), restored.lattice_level);
    try std.testing.expect(!restored.use_dedup);
    try std.testing.expectEqual(@as(u64, 512), restored.agent_max_cycles);
    try std.testing.expectEqual(@as(u16, 8080), restored.mesh_port);
}

test "config json ignores unknown fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"lattice_level": 3, "unknown_field": 42, "use_dedup": true}
    ;
    const c = try Config.fromJson(allocator, json);
    try std.testing.expectEqual(@as(u8, 3), c.lattice_level);
    try std.testing.expect(c.use_dedup);
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
