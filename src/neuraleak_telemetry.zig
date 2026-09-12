// ============================================================================
// NEURALEAK TELEMETRY — Snapshot and Field Parameters
// ============================================================================
//
// Provides the Snapshot struct used by the neuraleak system to carry field
// parameters from the 15³ lattice. The snapshot connects to the framework's
// coherence and rendering concepts.
//
// All scalar values use i64 micro-units (SCALE = 10^6) internally.
// JSON parsing uses f64 temporarily, then converts to i64.
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");

/// Scale factor: 1.0 = 1_000_000 micro-units
pub const SCALE: i64 = 1_000_000;

/// Field parameters for a 15³ Möbius torus snapshot (all in micro-units).
pub const FieldParams = struct {
    amplitude: i64, // micro-units
    phi_freq: i64, // micro-units
    pi_freq: i64, // micro-units
    harmonic_count: u32,
};

/// A telemetry snapshot of the 15³ field state (all scalars in micro-units).
pub const Snapshot = struct {
    params: FieldParams,
    coherence: i64, // micro-units
    rendered: bool,
    soliton_count: usize,
    higgs_count: usize,
    coupled_count: usize,
    total_generated_mass: i64, // micro-units

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Convert f64 to i64 micro-units
fn toMicro(v: f64) i64 {
    return @intFromFloat(v * @as(f64, @floatFromInt(SCALE)));
}

/// Read a snapshot from a JSON file.
pub fn readSnapshot(allocator: std.mem.Allocator, path: []const u8) !Snapshot {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(content);

    const Parsed = struct {
        amplitude: f64,
        phi_freq: f64,
        pi_freq: f64,
        harmonic_count: u32,
        coherence: f64,
        rendered: bool,
        soliton_count: usize,
        higgs_count: usize,
        coupled_count: usize,
        total_generated_mass: f64,
    };

    const parsed = try std.json.parseFromSlice(Parsed, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .params = .{
            .amplitude = toMicro(parsed.value.amplitude),
            .phi_freq = toMicro(parsed.value.phi_freq),
            .pi_freq = toMicro(parsed.value.pi_freq),
            .harmonic_count = parsed.value.harmonic_count,
        },
        .coherence = toMicro(parsed.value.coherence),
        .rendered = parsed.value.rendered,
        .soliton_count = parsed.value.soliton_count,
        .higgs_count = parsed.value.higgs_count,
        .coupled_count = parsed.value.coupled_count,
        .total_generated_mass = toMicro(parsed.value.total_generated_mass),
    };
}

/// Create a default snapshot with zeroed parameters.
pub fn defaultSnapshot() Snapshot {
    return .{
        .params = .{
            .amplitude = 0,
            .phi_freq = 0,
            .pi_freq = 0,
            .harmonic_count = 0,
        },
        .coherence = 0,
        .rendered = false,
        .soliton_count = 0,
        .higgs_count = 0,
        .coupled_count = 0,
        .total_generated_mass = 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "defaultSnapshot produces zeroed state" {
    const s = defaultSnapshot();
    try std.testing.expectEqual(@as(i64, 0), s.params.amplitude);
    try std.testing.expectEqual(@as(i64, 0), s.coherence);
    try std.testing.expect(!s.rendered);
    try std.testing.expectEqual(@as(usize, 0), s.soliton_count);
}

test "readSnapshot parses JSON file" {
    const allocator = std.testing.allocator;
    const test_json =
        \\{"amplitude":0.5,"phi_freq":1.618,"pi_freq":3.14159,"harmonic_count":7,"coherence":0.8,"rendered":true,"soliton_count":3,"higgs_count":2,"coupled_count":1,"total_generated_mass":0.001}
    ;
    const path = "/tmp/neuraleak_snapshot_test.json";
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(test_json);

    const snapshot = try readSnapshot(allocator, path);
    // 0.5 * 10^6 = 500_000
    try std.testing.expectEqual(@as(i64, 500_000), snapshot.params.amplitude);
    // 1.618 * 10^6 ≈ 1_618_000
    try std.testing.expect(snapshot.params.phi_freq >= 1_617_990 and snapshot.params.phi_freq <= 1_618_010);
    try std.testing.expectEqual(@as(u32, 7), snapshot.params.harmonic_count);
    try std.testing.expect(snapshot.rendered);
    try std.testing.expectEqual(@as(usize, 3), snapshot.soliton_count);
}

test "telemetry uses integer types (no f64 in structs)" {
    const s = defaultSnapshot();
    try std.testing.expect(@TypeOf(s.params.amplitude) == i64);
    try std.testing.expect(@TypeOf(s.coherence) == i64);
    try std.testing.expect(@TypeOf(s.total_generated_mass) == i64);
}
