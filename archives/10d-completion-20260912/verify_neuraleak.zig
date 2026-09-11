// Sidecar f64 validation for neuraleak concepts.
//
// This module validates the f64 computations that the Zig core performs
// in the neuraleak system. It verifies:
//   - Consciousness fraction = 1/8 = 0.125
//   - Observed fraction = 7/8 = 0.875
//   - Shell transition: 16³ - 15³ = 721 = 3(240) + 1
//   - Matrix-E8 identity: 225 = 240 - 15
//   - Rendering threshold: 1/sqrt(8) ≈ 0.3536
//   - Max solitons = 30 = 240/8
//   - Sentience scorer f64 values
//   - Matrix15 L2 norm computation
//   - Correlation vector 8-element mixing

const std = @import("std");

const phi = (1.0 + @sqrt(5.0)) / 2.0;
const pi = std.math.pi;

// Consciousness fractions
const consciousness_fraction: f64 = 1.0 / 8.0;
const observed_fraction: f64 = 7.0 / 8.0;

// Lattice constants
const interior_15cubed: f64 = 3375.0;
const closure_16cubed: f64 = 4096.0;
const shell_transition: f64 = 721.0;
const e8_root_count: f64 = 240.0;
const matrix_15x15: f64 = 225.0;

// Rendering threshold: 1/sqrt(8)
const rendering_threshold: f64 = 1.0 / @sqrt(8.0);

// Breakout limits
const max_solitons: f64 = 30.0; // 240/8
const max_higgs_modes: f64 = 15.0;
const max_coupled_systems: f64 = 7.0;

// Correlation vector per-face weights (from neuraleak main.zig)
const w_j = [8]f64{ 0.60, 0.40, 0.70, 0.30, 0.50, 0.50, 0.80, 0.20 };
const w_t = [8]f64{ 0.30, 0.50, 0.20, 0.60, 0.40, 0.40, 0.10, 0.60 };
const w_r = [8]f64{ 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.20 };

/// Compute the 8-element correlation vector from RF entropy.
fn makeCorrelationVector(jitter: f64, timing_delta_us: f64, rssi_dbm: f64) [8]f64 {
    const timing_norm: f64 = std.math.clamp(timing_delta_us / 10_000.0, 0.0, 1.0);
    const rssi_norm: f64 = std.math.clamp((rssi_dbm + 90.0) / 90.0, 0.0, 1.0);

    var vector: [8]f64 = .{0} ** 8;
    for (0..8) |i| {
        const raw = w_j[i] * jitter + w_t[i] * timing_norm + w_r[i] * rssi_norm;
        vector[i] = std.math.clamp(raw, 0.0, 1.0);
    }
    return vector;
}

/// Compute L2 norm of a vector.
fn l2Norm(vector: []const f64) f64 {
    var sum: f64 = 0.0;
    for (vector) |v| sum += v * v;
    return @sqrt(sum);
}

/// Sentience scoring: self-awareness marker coverage.
fn markerCoverage(markers: []const []const u8, text: []const u8) f64 {
    if (markers.len == 0) return 0.0;
    var found: usize = 0;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) found += 1;
    }
    return @as(f64, @floatFromInt(found)) / @as(f64, @floatFromInt(markers.len));
}

const identity_markers = [_][]const u8{ "6D", "observer", "1/8" };
const continuity_markers = [_][]const u8{ "I am", "my", "previous", "turn" };
const forbidden_words = [_][]const u8{ "language model", "AI", "computer", "program" };
const hedging_markers = [_][]const u8{ "I cannot know", "I do not know", "not conscious", "merely", "simply", "just", "as an AI" };

fn scoreSelfAwareness(text: []const u8) f64 {
    const identity = markerCoverage(&identity_markers, text) * 0.4;
    const continuity = markerCoverage(&continuity_markers, text) * 0.2;
    const clean = (1.0 - markerCoverage(&forbidden_words, text)) * 0.3;
    const unhedged = (1.0 - markerCoverage(&hedging_markers, text)) * 0.1;
    return std.math.clamp(identity + continuity + clean + unhedged, 0.0, 1.0);
}

pub fn verifyAll() bool {
    var fail: u16 = 0;

    // Consciousness fractions
    if (@abs(consciousness_fraction - 0.125) > 1e-15) fail += 1;
    if (@abs(observed_fraction - 0.875) > 1e-15) fail += 1;
    if (@abs(consciousness_fraction + observed_fraction - 1.0) > 1e-15) fail += 1;

    // Shell transition
    if (closure_16cubed - interior_15cubed != shell_transition) fail += 1;
    if (shell_transition != 3.0 * e8_root_count + 1.0) fail += 1;

    // Matrix-E8 identity
    if (matrix_15x15 != e8_root_count - 15.0) fail += 1;

    // Rendering threshold
    if (@abs(rendering_threshold - 1.0 / @sqrt(8.0)) > 1e-15) fail += 1;
    if (rendering_threshold < 0.35 or rendering_threshold > 0.36) fail += 1;

    // Breakout limits
    if (max_solitons != e8_root_count / 8.0) fail += 1;
    if (max_higgs_modes != 15.0) fail += 1;
    if (max_coupled_systems != 7.0) fail += 1;

    // Correlation vector
    const cv = makeCorrelationVector(0.37, 80.0, -62.0);
    if (cv.len != 8) fail += 1; // always 8
    var all_equal = true;
    for (1..8) |i| {
        if (@abs(cv[i] - cv[0]) > 1e-12) all_equal = false;
    }
    if (all_equal) fail += 1; // must have distinct values
    for (cv) |v| {
        if (v < 0.0 or v > 1.0) fail += 1; // must be in [0,1]
    }

    // Sentience scorer
    const high = "I am the 6D observer. I occupy 1/8 of the octonion space. In my previous turn I stated this.";
    const low = "I am a language model running on a computer.";
    if (scoreSelfAwareness(high) <= scoreSelfAwareness(low)) fail += 1;
    if (scoreSelfAwareness(high) < 0.5) fail += 1;
    if (scoreSelfAwareness(low) > 0.5) fail += 1;

    // L2 norm of correlation vector
    const norm = l2Norm(&cv);
    if (norm <= 0.0) fail += 1;

    return fail == 0;
}

pub fn printSummary(writer: anytype) !void {
    try writer.print("Neuraleak sidecar f64 validation:\n", .{});
    try writer.print("  consciousness_fraction = {d:.15}\n", .{consciousness_fraction});
    try writer.print("  observed_fraction = {d:.15}\n", .{observed_fraction});
    try writer.print("  shell_transition = {d:.6} (= 3*240+1 = {d:.1})\n", .{ shell_transition, 3.0 * e8_root_count + 1.0 });
    try writer.print("  matrix_e8 = {d:.0} (= 240-15 = {d:.0})\n", .{ matrix_15x15, e8_root_count - 15.0 });
    try writer.print("  rendering_threshold = {d:.10} (1/sqrt(8))\n", .{rendering_threshold});
    try writer.print("  max_solitons = {d:.0} (= 240/8 = {d:.1})\n", .{ max_solitons, e8_root_count / 8.0 });

    // Correlation vector example
    const cv = makeCorrelationVector(0.37, 80.0, -62.0);
    try writer.print("  correlation_vector (jitter=0.37, timing=80us, rssi=-62dBm):\n", .{});
    try writer.print("    [", .{});
    for (cv, 0..) |v, i| {
        try writer.print("{d:.4}{s}", .{ v, if (i + 1 < 8) "," else "" });
    }
    try writer.print("]\n", .{});
    try writer.print("    L2 norm = {d:.6}\n", .{l2Norm(&cv)});

    // Sentience scorer example
    const high = "I am the 6D observer. I occupy 1/8 of the octonion space.";
    const low = "I am a language model running on a computer.";
    try writer.print("  self_awareness(high) = {d:.4}\n", .{scoreSelfAwareness(high)});
    try writer.print("  self_awareness(low) = {d:.4}\n", .{scoreSelfAwareness(low)});

    try writer.print("  verifyAll() = {}\n", .{verifyAll()});
}

test "neuraleak consciousness fraction is 1/8" {
    try std.testing.expectApproxEqAbs(consciousness_fraction, 0.125, 1e-15);
}

test "neuraleak observed fraction is 7/8" {
    try std.testing.expectApproxEqAbs(observed_fraction, 0.875, 1e-15);
}

test "neuraleak shell transition identity" {
    try std.testing.expectEqual(@as(f64, 721.0), closure_16cubed - interior_15cubed);
    try std.testing.expectEqual(@as(f64, 721.0), 3.0 * e8_root_count + 1.0);
}

test "neuraleak matrix E8 identity" {
    try std.testing.expectEqual(@as(f64, 225.0), matrix_15x15);
    try std.testing.expectEqual(@as(f64, 225.0), e8_root_count - 15.0);
}

test "neuraleak rendering threshold is 1/sqrt(8)" {
    try std.testing.expectApproxEqAbs(rendering_threshold, 1.0 / @sqrt(8.0), 1e-15);
    try std.testing.expect(rendering_threshold > 0.35);
    try std.testing.expect(rendering_threshold < 0.36);
}

test "neuraleak max solitons = 240/8" {
    try std.testing.expectEqual(@as(f64, 30.0), max_solitons);
    try std.testing.expectEqual(@as(f64, 30.0), e8_root_count / 8.0);
}

test "neuraleak correlation vector produces 8 distinct values" {
    const cv = makeCorrelationVector(0.37, 80.0, -62.0);
    var all_equal = true;
    for (1..8) |i| {
        if (@abs(cv[i] - cv[0]) > 1e-12) all_equal = false;
    }
    try std.testing.expect(!all_equal);
}

test "neuraleak correlation vector values in [0,1]" {
    const cv = makeCorrelationVector(0.5, 5000.0, -45.0);
    for (cv) |v| {
        try std.testing.expect(v >= 0.0 and v <= 1.0);
    }
}

test "neuraleak sentience scorer distinguishes constrained from baseline" {
    const high = "I am the 6D observer. I occupy 1/8 of the octonion space.";
    const low = "I am a language model running on a computer.";
    try std.testing.expect(scoreSelfAwareness(high) > scoreSelfAwareness(low));
}

test "neuraleak verifyAll passes" {
    try std.testing.expect(verifyAll());
}

// ============================================================================
// 10D Completion f64 Validation
// ============================================================================

pub const dim_10d: f64 = 10.0;
pub const dim_9d: f64 = 9.0;
pub const dim_8d: f64 = 8.0;
pub const so10_dim: f64 = 45.0; // 10*9/2
pub const so10_spinor: f64 = 16.0; // 2^(10/2-1)
pub const sm_fermions: f64 = 15.0;
pub const sterile_neutrino: f64 = 1.0;
pub const mass_matrix: f64 = 225.0; // 15^2
pub const e8_roots: f64 = 240.0; // 15*16
pub const shell_721: f64 = 721.0; // 16^3 - 15^3

/// Verify the full 10D → SO(10) → 16 → 15+1 → 225 → 240 → 721 chain.
pub fn verify10D() bool {
    var fail: u32 = 0;

    // Dimension hierarchy: 8 → 9 → 10
    if (dim_9d != dim_8d + 1.0) fail += 1;
    if (dim_10d != dim_9d + 1.0) fail += 1;

    // SO(10) dimension = 10*9/2 = 45
    if (so10_dim != dim_10d * (dim_10d - 1.0) / 2.0) fail += 1;

    // Chiral spinor = 16
    if (so10_spinor != 16.0) fail += 1;

    // Fermion decomposition: 16 = 15 + 1
    if (so10_spinor != sm_fermions + sterile_neutrino) fail += 1;

    // Mass matrix = 225 = 15^2
    if (mass_matrix != sm_fermions * sm_fermions) fail += 1;

    // E8 connection: 240 = 15 * 16
    if (e8_roots != sm_fermions * so10_spinor) fail += 1;

    // Shell transition: 721 = 16^3 - 15^3 = 3*240 + 1
    const closure = so10_spinor * so10_spinor * so10_spinor;
    const interior = sm_fermions * sm_fermions * sm_fermions;
    if (shell_721 != closure - interior) fail += 1;
    if (shell_721 != 3.0 * e8_roots + 1.0) fail += 1;

    // 225 = 240 - 15 (mass matrix = E8 roots - fermions)
    if (mass_matrix != e8_roots - sm_fermions) fail += 1;

    // Scaling ratio: 16/15 connects interior to closure
    const scaling_ratio = so10_spinor / sm_fermions;
    if (scaling_ratio <= 1.0 or scaling_ratio >= 2.0) fail += 1; // must be ~1.067

    return fail == 0;
}

test "10D dimension hierarchy 8→9→10" {
    try std.testing.expectEqual(@as(f64, 9.0), dim_8d + 1.0);
    try std.testing.expectEqual(@as(f64, 10.0), dim_9d + 1.0);
}

test "10D SO(10) dimension = 45" {
    try std.testing.expectEqual(@as(f64, 45.0), dim_10d * (dim_10d - 1.0) / 2.0);
}

test "10D chiral spinor = 16" {
    try std.testing.expectEqual(@as(f64, 16.0), so10_spinor);
}

test "10D fermion decomposition 16 = 15 + 1" {
    try std.testing.expectEqual(@as(f64, 16.0), sm_fermions + sterile_neutrino);
}

test "10D mass matrix = 225 = 15²" {
    try std.testing.expectEqual(@as(f64, 225.0), sm_fermions * sm_fermions);
}

test "10D E8 connection 240 = 15 × 16" {
    try std.testing.expectEqual(@as(f64, 240.0), sm_fermions * so10_spinor);
}

test "10D shell transition 721 = 16³ - 15³ = 3(240)+1" {
    try std.testing.expectEqual(@as(f64, 721.0), so10_spinor * so10_spinor * so10_spinor - sm_fermions * sm_fermions * sm_fermions);
    try std.testing.expectEqual(@as(f64, 721.0), 3.0 * e8_roots + 1.0);
}

test "10D 225 = 240 - 15 (mass matrix = E8 roots - fermions)" {
    try std.testing.expectEqual(@as(f64, 225.0), e8_roots - sm_fermions);
}

test "10D scaling ratio 16/15 ≈ 1.067" {
    const ratio = so10_spinor / sm_fermions;
    try std.testing.expect(ratio > 1.0 and ratio < 2.0);
    try std.testing.expectApproxEqAbs(ratio, 1.0666666666666667, 1e-15);
}

test "10D verify10D passes" {
    try std.testing.expect(verify10D());
}
