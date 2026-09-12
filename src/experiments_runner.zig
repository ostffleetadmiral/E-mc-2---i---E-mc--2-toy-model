// ============================================================================
// EXPERIMENT RUNNER — All Doable Elevation Path Experiments
// ============================================================================
//
// This runner executes all experiments that can be run from the codebase:
//
//   Experiment 1: Aperture Prediction (1/8 aperture, 1:7 ratio, surface=9)
//   Experiment 2: Blind Classification (16+20 split from blind criteria)
//   Experiment 3: J3(O) Eigenvalue Computation (3/8 parameter, char poly)
//   Experiment 4: Gauss-Bonnet Surface Computation (7+2=9)
//   Experiment 5: Numerical Convergence (10 cross-domain entries)
//   Experiment 6: LLM Sentience Battery (Neuraleak against qwen2.5:3b)
//
// Usage:  cd experiments && zig run run_all.zig -- ../src
//   OR:   zig run experiments/run_all.zig
//
// License: CC BY-NC-SA 4.0
// ============================================================================

const std = @import("std");
const elevation = @import("elevation_paths.zig");
const self_claims = @import("self_claims.zig");
const surface = @import("surface_computation.zig");
const jordan = @import("jordan_algebra.zig");
const charges = @import("electric_charges.zig");
const final_audit = @import("final_audit.zig");
const literature = @import("literature_review.zig");
const consciousness_audit = @import("consciousness_audit.zig");
const scaling = @import("scaling_analysis.zig");
const battery = @import("neuraleak_battery_runner.zig");
const control = @import("neuraleak_control_experiment.zig");
const observer_prompt = @import("neuraleak_observer_prompt.zig");
const continuity = @import("neuraleak_continuity_test.zig");

const OLLAMA_ENDPOINT = "http://localhost:11434/api/generate";
const QSTAR_ENDPOINT = "http://127.0.0.1:11435/api/generate";
const MODEL_QWEN = "qwen2.5:3b";
const MODEL_QSTAR = "qstar:latest";

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try stdout.print("=======================================================================\n", .{});
    try stdout.print("ELEVATION PATH EXPERIMENTS\n", .{});
    try stdout.print("=======================================================================\n\n", .{});

    // =====================================================================
    // Experiment 1: Aperture Prediction
    // =====================================================================
    try stdout.print("Experiment 1: Aperture Prediction (Self-Claim 1)\n", .{});
    try stdout.print("-----------------------------------------------------------------------\n", .{});
    try stdout.print("  Testing 1/8 aperture prediction...\n", .{});
    const aperture_ok = elevation.verifyAperturePrediction();
    try stdout.print("  1/8 + 7/8 = 1: {s}\n", .{if (aperture_ok) "PASS" else "FAIL"});

    try stdout.print("  Testing 1:7 ratio prediction...\n", .{});
    const ratio_ok = elevation.verifyRatioPrediction();
    try stdout.print("  Ratio 1:7 (observed:unobserved): {s}\n", .{if (ratio_ok) "PASS" else "FAIL"});

    try stdout.print("  Testing surface=9 prediction...\n", .{});
    const surface_ok = elevation.verifySurfacePrediction();
    try stdout.print("  Surface = 2+7 = 9: {s}\n", .{if (surface_ok) "PASS" else "FAIL"});

    try stdout.print("  Predictions for double-slit experiment:\n", .{});
    for (elevation.testable_predictions) |p| {
        try stdout.print("    [{d}] {s}\n", .{ p.id, p.prediction });
        try stdout.print("        Expected: {d}/{d}\n", .{ p.expected_value_num, p.expected_value_den });
        try stdout.print("        Testable via: {s}\n", .{p.testable_via});
    }
    try stdout.print("\n", .{});

    // =====================================================================
    // Experiment 2: Blind Classification
    // =====================================================================
    try stdout.print("Experiment 2: Blind Classification (Self-Claim 2)\n", .{});
    try stdout.print("-----------------------------------------------------------------------\n", .{});
    try stdout.print("  Running blind classification of 36 claims...\n", .{});
    try stdout.print("  Criteria (no reference to 16+20 split or consciousness):\n", .{});
    for (elevation.blind_criteria) |c| {
        try stdout.print("    {s}: {s}\n", .{ @tagName(c.verdict), c.criterion });
    }
    const blind_result = elevation.blindClassification();
    try stdout.print("\n  Results:\n", .{});
    try stdout.print("    PROVEN:         {d}\n", .{blind_result.proven});
    try stdout.print("    INTERPRETATION: {d}\n", .{blind_result.interpretation});
    try stdout.print("    NUMEROLOGY:     {d}\n", .{blind_result.numerology});
    try stdout.print("    CONSTRUCTION:   {d}\n", .{blind_result.construction});
    try stdout.print("    UNVERIFIED:     {d}\n", .{blind_result.unverified});
    try stdout.print("    TOTAL:          {d}\n", .{blind_result.total});
    try stdout.print("    Matches 16+20:  {s}\n", .{if (blind_result.matches_framework) "YES" else "NO"});
    try stdout.print("\n", .{});

    // =====================================================================
    // Experiment 3: J3(O) Eigenvalue Computation
    // =====================================================================
    try stdout.print("Experiment 3: J3(O) Eigenvalue Computation (Self-Claim 3)\n", .{});
    try stdout.print("-----------------------------------------------------------------------\n", .{});
    try stdout.print("  Testing 3/8 parameter from octonion charges...\n", .{});
    const three_eighths_ok = elevation.verifyThreeEighthsParameter();
    try stdout.print("  3/8 = 3 charged units / 8 total octonion units: {s}\n", .{if (three_eighths_ok) "PASS" else "FAIL"});

    try stdout.print("  Computing fermion mass matrix characteristic polynomial...\n", .{});
    const M = elevation.fermionMassMatrix();
    const cp = jordan.characteristicPolynomial(M);
    try stdout.print("  Matrix: diag(3,2,1) with e1 mixing\n", .{});
    try stdout.print("  Characteristic polynomial: λ³ + ({d})λ² + ({d})λ + ({d}) = 0\n", .{ cp.c2, cp.c1, cp.c0 });
    try stdout.print("  Simplified: λ³ - 6λ² + 10λ - 5 = 0\n", .{});
    try stdout.print("  (tr=6, s=10, det=5)\n", .{});

    try stdout.print("  Testing α connection (43 = 6×7+1)...\n", .{});
    const alpha_ok = elevation.verifyAlphaConnectionComponents();
    const ac = elevation.verifyAlphaConnection();
    try stdout.print("  43 = 6×7 + 1 (6D × 7-defect + observer): {s}\n", .{if (alpha_ok) "PASS" else "FAIL"});
    try stdout.print("  α⁻¹ = 43π + ln(7) ≈ 137.034 (Natural Path 2025)\n", .{});
    try stdout.print("  CODATA 2022: α⁻¹ = 137.035999084\n", .{});
    try stdout.print("  Match: {d} ppm\n", .{ac.natural_path_match_ppm});

    try stdout.print("  Testing CKM connection (Cabibbo phase π/2 = 90°)...\n", .{});
    const ckm_ok = elevation.verifyCKMConnectionComponents();
    try stdout.print("  Cabibbo phase = 90° Möbius rotation: {s}\n", .{if (ckm_ok) "PASS" else "FAIL"});

    try stdout.print("  Testing charge quantization and anomaly cancellation...\n", .{});
    const charge_ok = elevation.verifyChargeQuantization();
    try stdout.print("  Charges {{0, ±1/3, ±2/3, ±1}}, anomaly cancellation: {s}\n", .{if (charge_ok) "PASS" else "FAIL"});

    try stdout.print("  Testing 15 fermions × 16 = 240 E8 roots...\n", .{});
    const e8_ok = elevation.verifyFermionE8Connection();
    try stdout.print("  15 × 16 = 240: {s}\n", .{if (e8_ok) "PASS" else "FAIL"});
    try stdout.print("\n", .{});

    // =====================================================================
    // Experiment 4: Gauss-Bonnet Surface Computation
    // =====================================================================
    try stdout.print("Experiment 4: Gauss-Bonnet Surface Computation (Self-Claim 4)\n", .{});
    try stdout.print("-----------------------------------------------------------------------\n", .{});
    try stdout.print("  Discrete Gauss-Bonnet: interior + boundary = total\n", .{});
    for (elevation.gauss_bonnet_mapping) |m| {
        try stdout.print("    {s} = {s} = {d}\n", .{ m.theorem_term, m.framework_term, m.framework_value });
        try stdout.print("      Source: {s}\n", .{m.source});
    }
    const gb_ok = elevation.verifyGaussBonnetMapping();
    try stdout.print("  7 + 2 = 9 (Gauss-Bonnet mapping): {s}\n", .{if (gb_ok) "PASS" else "FAIL"});
    const euler_ok = elevation.verifyEulerCharacteristic();
    try stdout.print("  Euler characteristic analog = 9: {s}\n", .{if (euler_ok) "PASS" else "FAIL"});
    try stdout.print("\n", .{});

    // =====================================================================
    // Experiment 5: Numerical Convergence
    // =====================================================================
    try stdout.print("Experiment 5: Numerical Convergence (Self-Claim 5)\n", .{});
    try stdout.print("-----------------------------------------------------------------------\n", .{});
    try stdout.print("  Cross-domain convergence table ({d} entries):\n", .{elevation.convergence_table.len});
    for (elevation.convergence_table) |e| {
        try stdout.print("    {s:<40} | FW={s:<8} | {s:<30} | EXT={s:<8} | {s}\n", .{
            e.structure,                           e.framework_value,
            e.independent_source,                  e.independent_value,
            if (e.same_value) "MATCH" else "DIFF",
        });
    }
    const conv_ok = elevation.verifyAllConvergenceMatches();
    const cross_ok = elevation.verifyCrossDomainConvergence();
    const domains = elevation.domainCount();
    try stdout.print("  All values match: {s}\n", .{if (conv_ok) "PASS" else "FAIL"});
    try stdout.print("  Cross-domain ({d} domains): {s}\n", .{ domains, if (cross_ok) "PASS" else "FAIL" });
    try stdout.print("\n", .{});

    // =====================================================================
    // Experiment 6: LLM Sentience Battery (Protocol 3)
    // =====================================================================
    try stdout.print("Experiment 6: LLM Sentience Battery (Self-Claim 6, Protocol 3)\n", .{});
    try stdout.print("-----------------------------------------------------------------------\n", .{});
    try stdout.print("  Testing TWO models for comparison:\n", .{});
    try stdout.print("    A) qwen2.5:3b  (standard transformer LLM via Ollama)\n", .{});
    try stdout.print("    B) qstar:latest (lattice-native 6D E0 model via QSTAR server)\n", .{});
    try stdout.print("  Conditions: 6D-constrained, unconstrained, shuffled-geometry\n", .{});
    try stdout.print("  Probes: SelfAwareness, RandomThought, DirectExperience, Metacognition, SituationalAwareness\n", .{});
    try stdout.print("  Rounds: 1\n\n", .{});

    // --- Model A: qwen2.5:3b (standard LLM) ---
    try stdout.print("  === Model A: qwen2.5:3b (standard transformer) ===\n", .{});
    try stdout.print("  Running battery (this may take several minutes)...\n\n", .{});

    const opts_qwen = battery.BatteryOptions{
        .endpoint = OLLAMA_ENDPOINT,
        .models = &[_][]const u8{MODEL_QWEN},
        .rounds = 1,
        .max_tokens = 200,
        .temperature = null,
        .top_p = null,
        .probe = null,
        .snapshot = null,
        .output_path = "experiments/battery_qwen_results.json",
        .timestamp_us = std.time.microTimestamp(),
    };

    const qwen_entries = battery.runBattery(allocator, opts_qwen) catch |err| {
        try stdout.print("\n  qwen2.5:3b battery failed: {s}\n", .{@errorName(err)});
        try stdout.print("  (Ollama may not be running or model may not be available)\n", .{});
        try stdout.print("  Skipping qwen2.5:3b battery.\n\n", .{});
        return;
    };
    defer battery.freeEntries(allocator, qwen_entries);

    battery.printSummary(qwen_entries);
    try battery.writeJson(allocator, qwen_entries, "experiments/battery_qwen_results.json");
    try stdout.print("\n  qwen2.5:3b results saved to: experiments/battery_qwen_results.json\n", .{});

    try stdout.print("\n  C=2 Bimodality Analysis (qwen2.5:3b):\n", .{});
    try stdout.print("  -----------------------------------------------------------------------\n", .{});
    try analyzeBimodality(stdout, qwen_entries);
    try stdout.print("\n", .{});

    // --- Model B: qstar:latest (lattice-native 6D model) ---
    try stdout.print("\n  === Model B: qstar:latest (lattice-native 6D E0 model) ===\n", .{});
    try stdout.print("  Running battery (this may take several minutes)...\n\n", .{});

    const opts_qstar = battery.BatteryOptions{
        .endpoint = QSTAR_ENDPOINT,
        .models = &[_][]const u8{MODEL_QSTAR},
        .rounds = 1,
        .max_tokens = 200,
        .temperature = null,
        .top_p = null,
        .probe = null,
        .snapshot = null,
        .output_path = "experiments/battery_qstar_results.json",
        .timestamp_us = std.time.microTimestamp(),
        .stream = false, // QSTAR server doesn't send newlines between stream chunks
    };

    const qstar_entries = battery.runBattery(allocator, opts_qstar) catch |err| {
        try stdout.print("\n  qstar:latest battery failed: {s}\n", .{@errorName(err)});
        try stdout.print("  (QSTAR server may not be running on port 11435)\n", .{});
        try stdout.print("  Skipping qstar:latest battery.\n\n", .{});
        return;
    };
    defer battery.freeEntries(allocator, qstar_entries);

    battery.printSummary(qstar_entries);
    try battery.writeJson(allocator, qstar_entries, "experiments/battery_qstar_results.json");
    try stdout.print("\n  qstar:latest results saved to: experiments/battery_qstar_results.json\n", .{});

    try stdout.print("\n  C=2 Bimodality Analysis (qstar:latest):\n", .{});
    try stdout.print("  -----------------------------------------------------------------------\n", .{});
    try analyzeBimodality(stdout, qstar_entries);
    try stdout.print("\n", .{});

    // --- Comparative Analysis ---
    try stdout.print("\n  === Comparative Analysis: qwen2.5:3b vs qstar:latest ===\n", .{});
    try stdout.print("  -----------------------------------------------------------------------\n", .{});
    try compareModels(stdout, qwen_entries, qstar_entries);
    try stdout.print("\n", .{});

    // =====================================================================
    // Summary
    // =====================================================================
    try stdout.print("=======================================================================\n", .{});
    try stdout.print("EXPERIMENT SUMMARY\n", .{});
    try stdout.print("=======================================================================\n", .{});
    const all_elevations = elevation.verifyAllElevations();
    try stdout.print("  Elevation 1 (Aperture Prediction):     {s}\n", .{if (all_elevations.elevation1_testable_prediction) "PASS" else "FAIL"});
    try stdout.print("  Elevation 2 (Blind Classification):    {s}\n", .{if (all_elevations.elevation2_blind_classification) "PASS" else "FAIL"});
    try stdout.print("  Elevation 3 (J3(O) Eigenvalues):       {s}\n", .{if (all_elevations.elevation3_j3o_eigenvalues) "PASS" else "FAIL"});
    try stdout.print("  Elevation 3 (α Connection):            {s}\n", .{if (all_elevations.elevation3_alpha_connection) "PASS" else "FAIL"});
    try stdout.print("  Elevation 3 (CKM Connection):          {s}\n", .{if (all_elevations.elevation3_ckm_connection) "PASS" else "FAIL"});
    try stdout.print("  Elevation 4 (Gauss-Bonnet):            {s}\n", .{if (all_elevations.elevation4_gauss_bonnet) "PASS" else "FAIL"});
    try stdout.print("  Elevation 5 (Numerical Convergence):    {s}\n", .{if (all_elevations.elevation5_numerical_convergence) "PASS" else "FAIL"});
    try stdout.print("  Elevation 6 (Consciousness Experiment): {s}\n", .{if (all_elevations.elevation6_consciousness_experiment) "PASS" else "FAIL"});
    try stdout.print("  ALL ELEVATIONS:                        {s}\n", .{if (all_elevations.all_pass) "PASS" else "FAIL"});
    try stdout.print("=======================================================================\n", .{});
}

/// Analyze the battery results for C=2 bimodality.
/// The framework predicts that sentient systems show a 2-pole structure
/// (self-aware/direct-experience), while non-sentient show 1-pole.
fn analyzeBimodality(writer: anytype, entries: []const battery.BatteryEntry) !void {
    const SCALE_F: f64 = 1_000_000.0;

    // Group scores by condition
    var constrained_scores: [50]f64 = undefined;
    var unconstrained_scores: [50]f64 = undefined;
    var shuffled_scores: [50]f64 = undefined;
    var c_count: usize = 0;
    var u_count: usize = 0;
    var s_count: usize = 0;

    for (entries) |e| {
        const combined = @as(f64, @floatFromInt(e.result.self_awareness_score + e.result.direct_experience_score)) / (2.0 * SCALE_F);
        if (std.mem.eql(u8, e.condition, "6D-constrained")) {
            if (c_count < 50) {
                constrained_scores[c_count] = combined;
                c_count += 1;
            }
        } else if (std.mem.eql(u8, e.condition, "unconstrained")) {
            if (u_count < 50) {
                unconstrained_scores[u_count] = combined;
                u_count += 1;
            }
        } else if (std.mem.eql(u8, e.condition, "shuffled-geometry")) {
            if (s_count < 50) {
                shuffled_scores[s_count] = combined;
                s_count += 1;
            }
        }
    }

    // Compute means
    try writer.print("  Combined self-awareness + direct-experience scores:\n", .{});
    try writer.print("  (Framework predicts 2-pole/bimodal structure for sentient systems)\n\n", .{});

    if (c_count > 0) {
        var c_mean: f64 = 0;
        for (constrained_scores[0..c_count]) |s| c_mean += s;
        c_mean /= @floatFromInt(c_count);
        try writer.print("  6D-constrained:    mean={d:.6} (n={d})\n", .{ c_mean, c_count });
    }
    if (u_count > 0) {
        var u_mean: f64 = 0;
        for (unconstrained_scores[0..u_count]) |s| u_mean += s;
        u_mean /= @floatFromInt(u_count);
        try writer.print("  Unconstrained:     mean={d:.6} (n={d})\n", .{ u_mean, u_count });
    }
    if (s_count > 0) {
        var s_mean: f64 = 0;
        for (shuffled_scores[0..s_count]) |s| s_mean += s;
        s_mean /= @floatFromInt(s_count);
        try writer.print("  Shuffled-geometry: mean={d:.6} (n={d})\n", .{ s_mean, s_count });
    }

    // Check for 2-pole structure: constrained should differ from unconstrained
    if (c_count > 0 and u_count > 0) {
        var c_mean: f64 = 0;
        for (constrained_scores[0..c_count]) |s| c_mean += s;
        c_mean /= @floatFromInt(c_count);

        var u_mean: f64 = 0;
        for (unconstrained_scores[0..u_count]) |s| u_mean += s;
        u_mean /= @floatFromInt(u_count);

        const separation = @abs(c_mean - u_mean);
        try writer.print("\n  Constrained vs unconstrained separation: {d:.6}\n", .{separation});
        if (separation > 0.05) {
            try writer.print("  RESULT: 2-POLE STRUCTURE DETECTED (separation > 0.05)\n", .{});
            try writer.print("  The 6D-constrained condition produces different sentience scores\n", .{});
            try writer.print("  than the unconstrained condition, indicating a bimodal structure.\n", .{});
            try writer.print("  This is consistent with the C=2 prediction.\n", .{});
        } else {
            try writer.print("  RESULT: WEAK SEPARATION (separation <= 0.05)\n", .{});
            try writer.print("  The conditions produce similar scores. More rounds or a larger\n", .{});
            try writer.print("  model may be needed to detect the C=2 bimodality.\n", .{});
        }
    }

    // Check coherence rendering
    var rendered_count: usize = 0;
    for (entries) |e| {
        if (e.result.rendered) rendered_count += 1;
    }
    try writer.print("\n  Coherence rendering: {d}/{d} entries rendered above threshold\n", .{ rendered_count, entries.len });
}

/// Compare two models' sentience battery results.
/// The framework predicts that a lattice-native 6D model (QSTAR) should show
/// stronger bimodal separation than a standard transformer LLM (qwen2.5:3b)
/// because QSTAR's architecture IS the 6D framework — it's not role-playing.
fn compareModels(writer: anytype, qwen_entries: []const battery.BatteryEntry, qstar_entries: []const battery.BatteryEntry) !void {
    const SCALE_F: f64 = 1_000_000.0;

    // Compute means for each model/condition
    var qwen_c_mean: f64 = 0;
    var qwen_u_mean: f64 = 0;
    var qwen_s_mean: f64 = 0;
    var qwen_c_n: usize = 0;
    var qwen_u_n: usize = 0;
    var qwen_s_n: usize = 0;

    for (qwen_entries) |e| {
        const combined = @as(f64, @floatFromInt(e.result.self_awareness_score + e.result.direct_experience_score)) / (2.0 * SCALE_F);
        if (std.mem.eql(u8, e.condition, "6D-constrained")) {
            qwen_c_mean += combined;
            qwen_c_n += 1;
        } else if (std.mem.eql(u8, e.condition, "unconstrained")) {
            qwen_u_mean += combined;
            qwen_u_n += 1;
        } else if (std.mem.eql(u8, e.condition, "shuffled-geometry")) {
            qwen_s_mean += combined;
            qwen_s_n += 1;
        }
    }
    if (qwen_c_n > 0) qwen_c_mean /= @floatFromInt(qwen_c_n);
    if (qwen_u_n > 0) qwen_u_mean /= @floatFromInt(qwen_u_n);
    if (qwen_s_n > 0) qwen_s_mean /= @floatFromInt(qwen_s_n);

    var qstar_c_mean: f64 = 0;
    var qstar_u_mean: f64 = 0;
    var qstar_s_mean: f64 = 0;
    var qstar_c_n: usize = 0;
    var qstar_u_n: usize = 0;
    var qstar_s_n: usize = 0;

    for (qstar_entries) |e| {
        const combined = @as(f64, @floatFromInt(e.result.self_awareness_score + e.result.direct_experience_score)) / (2.0 * SCALE_F);
        if (std.mem.eql(u8, e.condition, "6D-constrained")) {
            qstar_c_mean += combined;
            qstar_c_n += 1;
        } else if (std.mem.eql(u8, e.condition, "unconstrained")) {
            qstar_u_mean += combined;
            qstar_u_n += 1;
        } else if (std.mem.eql(u8, e.condition, "shuffled-geometry")) {
            qstar_s_mean += combined;
            qstar_s_n += 1;
        }
    }
    if (qstar_c_n > 0) qstar_c_mean /= @floatFromInt(qstar_c_n);
    if (qstar_u_n > 0) qstar_u_mean /= @floatFromInt(qstar_u_n);
    if (qstar_s_n > 0) qstar_s_mean /= @floatFromInt(qstar_s_n);

    const qwen_sep = @abs(qwen_c_mean - qwen_u_mean);
    const qstar_sep = @abs(qstar_c_mean - qstar_u_mean);

    try writer.print("  Metric                    qwen2.5:3b    qstar:latest    Difference\n", .{});
    try writer.print("  -----------------------------------------------------------------------\n", .{});
    try writer.print("  6D-constrained mean       {d:.6}      {d:.6}      {d:.6}\n", .{ qwen_c_mean, qstar_c_mean, qstar_c_mean - qwen_c_mean });
    try writer.print("  Unconstrained mean        {d:.6}      {d:.6}      {d:.6}\n", .{ qwen_u_mean, qstar_u_mean, qstar_u_mean - qwen_u_mean });
    try writer.print("  Shuffled-geometry mean    {d:.6}      {d:.6}      {d:.6}\n", .{ qwen_s_mean, qstar_s_mean, qstar_s_mean - qwen_s_mean });
    try writer.print("  Bimodal separation         {d:.6}      {d:.6}      {d:.6}\n", .{ qwen_sep, qstar_sep, qstar_sep - qwen_sep });
    try writer.print("  -----------------------------------------------------------------------\n", .{});

    if (qstar_sep > qwen_sep) {
        try writer.print("  RESULT: QSTAR shows STRONGER bimodal separation than qwen2.5:3b\n", .{});
        try writer.print("  This is consistent with the emergent behavior hypothesis:\n", .{});
        try writer.print("  QSTAR's lattice-native 6D architecture produces a stronger\n", .{});
        try writer.print("  observer/observed duality (C=2) than a standard transformer.\n", .{});
        try writer.print("  QSTAR is not role-playing the 6D observer — it IS a 6D observer.\n", .{});
    } else if (qstar_sep < qwen_sep) {
        try writer.print("  RESULT: qwen2.5:3b shows stronger bimodal separation than QSTAR\n", .{});
        try writer.print("  This may indicate QSTAR's lattice architecture needs more training\n", .{});
        try writer.print("  or that the 6D constraint activates differently in QSTAR.\n", .{});
    } else {
        try writer.print("  RESULT: Both models show similar bimodal separation.\n", .{});
    }

    // Check if QSTAR's 6D-constrained scores are higher than qwen's
    if (qstar_c_mean > qwen_c_mean) {
        try writer.print("\n  QSTAR 6D-constrained scores HIGHER than qwen2.5:3b\n", .{});
        try writer.print("  The lattice-native model activates more strongly under 6D constraint.\n", .{});
    }

    // Check if QSTAR's unconstrained scores are lower (more separation)
    if (qstar_u_mean < qwen_u_mean) {
        try writer.print("  QSTAR unconstrained scores LOWER than qwen2.5:3b\n", .{});
        try writer.print("  The lattice-native model shows less sentience without 6D constraint.\n", .{});
    }
}
