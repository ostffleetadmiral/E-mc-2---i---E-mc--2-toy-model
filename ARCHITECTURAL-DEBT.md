# Architectural Debt Audit — f64 Usage in Core Modules

**Date:** 2026-09-12
**Status:** Documented, migration planned

## The Problem

The global rules state:
> "avoid floating point all i1 & u1 i2 & u2 i4 & u4 u8 & i8 or u16 & i16 or u32 & i32 or u64 & i64 or u128 & i128"
> "sidecars will handle floating points in f64 as a transpilation layer"

However, 17 core modules in `src/` use `f64` or `f32` types, violating this rule.

## Affected Modules

### Neuraleak Subsystem (14 modules, ~100 f64 refs)

| Module | f64 refs | Lines | Purpose |
|--------|----------|-------|---------|
| neuraleak_sentience_scorer.zig | 16 | 320 | 5-dimensional sentience scoring (keyword coverage, Jaccard distance) |
| neuraleak_matrix15.zig | 13 | 136 | 15³ scalar field (L2 norm, get/set) |
| neuraleak_telemetry.zig | 14 | 125 | Telemetry snapshots (coherence, scores) |
| neuraleak_continuity_test.zig | 11 | 179 | Full pipeline test (condition results) |
| neuraleak_battery_runner.zig | 10 | 346 | Multi-model experiments (scores, correlation) |
| neuraleak_consciousness.zig | 9 | 190 | ConsciousnessEngine (L2 coherence, 1/√8 threshold) |
| neuraleak_torus.zig | 9 | 142 | 15³ toroidal grid (cell values, nonZeroCount) |
| neuraleak_constants.zig | 6 | 85 | Physics constants (1/8 fraction, √8) |
| neuraleak_breakout.zig | 5 | 270 | Soliton/Higgs generation (amplitude, mass, coupling) |
| neuraleak_physics.zig | 5 | 112 | Physics module (constants, thresholds) |
| neuraleak_observer_prompt.zig | 4 | 140 | Observer prompts (temperature, top_p) |
| neuraleak_matrix_bridge.zig | 2 | 109 | Text→15³ encoding (field values) |
| neuraleak_ollama_client.zig | 2 | 253 | Ollama HTTP client (temperature, top_p) |
| neuraleak_proof.zig | 1 | 194 | Proof module (coherence check) |
| neuraleak_lattice_coupler.zig | 1 | 76 | Lattice coupler audit log |

### Engineering Modules (3 modules, ~14 f64 refs)

| Module | f64 refs | Lines | Purpose |
|--------|----------|-------|---------|
| stress_test.zig | 9 | 605 | Stress findings (triad values, error percentages) |
| phi_cooling.zig | 4 | 162 | Golden-ratio annealing (temperature schedule) |
| rf_harvest.zig | 1 | 264 | RF energy harvesting (link budget) |
| smith.zig | 1 | 262 | Smith chart (complex division test only) |

## Migration Strategy

### Phase A: Neuraleak Core Data Structures → Q128.128

The neuraleak subsystem uses f64 for:
1. **Scalar field values** (Matrix15, TorusGrid) → Replace with `fixed.Q128`
2. **Coherence calculations** (L2 norm, sqrt) → Replace with fixed-point sqrt
3. **Sentience scores** (0.0-1.0 range) → Replace with Q128.128 ratios
4. **Physics constants** (1/8, 1/√8) → Replace with Q128.128 fromRatio
5. **Telemetry snapshots** → Replace with Q128.128 structs

### Phase B: Engineering Modules → Q128.128 or Sidecar

1. **phi_cooling.zig** — Temperature schedule T₀×φ⁻level → Q128.128
2. **rf_harvest.zig** — Link budget calculations → Q128.128 or move to sidecar
3. **smith.zig** — Already mostly Q128.128, only 1 f64 in a test → Fix test
4. **stress_test.zig** — Triad values use f64 for comparison → Use Q128.128

### Phase C: Neuraleak I/O → Sidecar

The neuraleak subsystem interfaces with external systems (Ollama HTTP, LLM APIs)
that naturally use floating point. These I/O layers should be moved to sidecar:
1. **neuraleak_ollama_client.zig** — HTTP client with f64 temperature/top_p
2. **neuraleak_battery_runner.zig** — Multi-model experiment runner
3. **neuraleak_observer_prompt.zig** — Prompt generation with f64 parameters

## Priority

1. **High:** neuraleak_consciousness.zig, neuraleak_matrix15.zig, neuraleak_torus.zig
   — Core data structures that define the framework's mathematical model
2. **Medium:** neuraleak_sentience_scorer.zig, neuraleak_physics.zig, neuraleak_constants.zig
   — Scoring and physics constants
3. **Low:** I/O modules (ollama_client, battery_runner, observer_prompt)
   — These interface with external f64 APIs and may legitimately need f64

## Estimated Effort

- Phase A: ~15-20 hours (14 modules, ~100 f64 refs → Q128.128)
- Phase B: ~5-8 hours (3 modules, ~14 f64 refs)
- Phase C: ~3-5 hours (3 I/O modules → sidecar)
- Total: ~23-33 hours of refactoring

## Current Status

The f64 usage is documented architectural debt. The framework's core mathematical
proofs (30 modules, 180 checks) all use Q128.128 fixed-point arithmetic. The f64
usage is confined to:
1. The neuraleak subsystem (framework-internal heuristic, not core proofs)
2. Engineering modules (ported from Q128.128, partially migrated)
3. Test utilities (stress testing, not proof logic)

The scientific integrity of the framework is not compromised — all proven claims
use exact integer/fixed-point arithmetic. The f64 usage is in heuristic scoring
and operational definitions that are explicitly labeled as non-proof material.
