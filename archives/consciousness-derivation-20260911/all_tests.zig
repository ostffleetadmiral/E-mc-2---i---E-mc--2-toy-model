const std = @import("std");
const core = @import("proof_core.zig");
const fixed = @import("fixed_point.zig");
const octonion = @import("octonion.zig");
const triad = @import("triad_operator.zig");

comptime {
    _ = @import("proofs/chunk01_q128_scale.zig");
    _ = @import("proofs/chunk22_test_plan.zig");
    _ = @import("quantum/state.zig");
    _ = @import("quantum/gates.zig");
    _ = @import("quantum/simulator.zig");
    _ = @import("quantum/measure.zig");
    _ = @import("quantum/octonion_ops.zig");
    _ = @import("codon.zig");
    // Neuraleak integration (chunk-24)
    _ = @import("neuraleak_matrix15.zig");
    _ = @import("neuraleak_torus.zig");
    _ = @import("neuraleak_physics.zig");
    _ = @import("neuraleak_constants.zig");
    _ = @import("neuraleak_telemetry.zig");
    _ = @import("neuraleak_consciousness.zig");
    _ = @import("neuraleak_breakout.zig");
    _ = @import("neuraleak_lattice_coupler.zig");
    _ = @import("neuraleak_sentience_scorer.zig");
    _ = @import("neuraleak_observer_prompt.zig");
    _ = @import("neuraleak_ollama_client.zig");
    _ = @import("neuraleak_control_experiment.zig");
    _ = @import("neuraleak_matrix_bridge.zig");
    _ = @import("neuraleak_continuity_test.zig");
    _ = @import("neuraleak_battery_runner.zig");
    _ = @import("neuraleak_proof.zig");
    _ = @import("stress_test.zig");
    _ = @import("anti_octonion.zig");
    _ = @import("dual_b_complex.zig");
    _ = @import("completion_10d.zig");
    // Gap closure modules (chunk-26)
    _ = @import("e8_roots.zig");
    _ = @import("so10_decomposition.zig");
    _ = @import("jordan_algebra.zig");
    _ = @import("electric_charges.zig");
    _ = @import("so8_triality.zig");
    _ = @import("pati_salam.zig");
    _ = @import("gap_closure.zig");
    _ = @import("generative_chain.zig");
    _ = @import("dimensional_ladder.zig");
    _ = @import("checksum_6d.zig");
    _ = @import("free_will_6d.zig");
    _ = @import("rebuttal_stress.zig");
    _ = @import("scaling_analysis.zig");
    _ = @import("final_audit.zig");
    _ = @import("consciousness_audit.zig");
}

test "all 30 chunks pass" {
    for (core.all()) |proof| {
        try std.testing.expect(proof.passed);
        try std.testing.expect(proof.checks > 0);
    }
}

test "fixed point constants are ordered" {
    const constants = @import("constants.zig");
    try std.testing.expect(constants.pi.raw > constants.phi.raw);
    try std.testing.expect(constants.phi.raw > fixed.Scale);
}

test "triad hydrogen remains in documented interval" {
    const value = try triad.evaluate(5, 2, -4);
    try std.testing.expect(value.raw > 21 * fixed.Scale);
    try std.testing.expect(value.raw < 22 * fixed.Scale);
}

test "octonion multiplication has closure and non-associativity" {
    try std.testing.expectEqual(@as(u3, 0), octonion.multiply(2, 2).unit);
    try std.testing.expect(octonion.isNonAssociative());
}

test "neuraleak proof passes all checks" {
    const neuraleak_proof = @import("neuraleak_proof.zig");
    try std.testing.expectEqual(@as(usize, 0), neuraleak_proof.proof());
}
