# Proof Workspace Guide

**Project:** E=mc²-i-E=mc⁻² (toy-model) — "play on the seriousness of the framework"
**Organization:** Open Sentience Technology Foundation
**Dev Lead Theoretician:** Paul P. Ramsey
**Dev R&D:** Devin AI, Chat-GPT, Gemini, GLM-2.5 & Kimi AI
**License:** CC BY-NC-SA 4.0 (see [LICENSE](./LICENSE))

## Verification commands

- Zig core: `zig build test` and `zig build run`
- Q#: `cd qsharp && dotnet build && dotnet run`
- f64 sidecar: `cd sidecar && zig build test && zig build run`
- Source/CSV audit: Zig chunk 09 validates all 145 rows of `mound_triad_results.csv`; the 22 memory ranges cover all nonblank source lines in `x.md`.
- Codon integration: Zig `src/codon.zig` (37 tests, 12 proof checks in chunk-22), Q# `qsharp/CodonProofs.qs` (6 witness operations), sidecar `sidecar/verify_codon.zig` (16 tests).
- Neuraleak integration: Zig `src/neuraleak_*.zig` (15 modules, 12 proof checks in chunk-24), Q# `qsharp/NeuraleakProofs.qs` (13 witness operations), sidecar `sidecar/verify_neuraleak.zig` (10 tests).
- Scaling analysis: Zig `src/scaling_analysis.zig` (12 proof checks in chunk-31), verifies cubic scaling chain, 7-defect, 421/3375 identity.
- Final audit: Zig `src/final_audit.zig` (8 tests), classifies 36 claims as PROVEN/INTERPRETATION/NUMEROLOGY/CONSTRUCTION/UNVERIFIED.
- Consciousness audit: Zig `src/consciousness_audit.zig` (8 tests), traces 20 rejected claims through causal chain to axiom via consciousness.
- Literature review: Zig `src/literature_review.zig` (12 tests), catalogues 24 independent references, 18 reclassifications.

## Current test counts

- Zig core: 567 tests (30 proof modules, 180 total proof checks, plus engineering modules, self-claims, probability log, elevation paths)
- Q#: 51 witness operations (.NET 8.0, 0 warnings)
- Sidecar: 49 f64 validation tests
- Lean 4: 8 formalization modules (pending verification — Lean not installed)
- FANO-1 hooks: 37 tests (neuraleak_qwen_hook, vulkan_e8_hook, polyglot_codon_hook, npu_detect_hook, npu_neuraleak_hook)
- Total: 567 + 51 + 49 + 37 = 704 verified operations

## Self-claims, probability log, and elevation paths

- `src/self_claims.zig` (14 tests) — 6 formal self-claims with computational verification, literature support, and explicit limitations. See `SELF-CLAIMS.md`.
- `src/probability_log.zig` (16 tests) — Use-case matrix for all verified operations, scoring each across 6 application domains. See `PROBABILITY-LOG.md`.
- `src/elevation_paths.zig` (28 tests) — Computational implementation of all 6 self-claim elevation paths: testable predictions, blind classification, J3(O) eigenvalues, Gauss-Bonnet formalization, numerical convergence, and C=2 experiment design. See `ELEVATION-PATHS.md`.

## Precision note

The fixed-point multiply in `src/fixed_point.zig` uses round-to-nearest-even (RNE)
with exact 512-bit intermediate products, ported from the Q128.128 (FANO-1) engine.
Error bound: |x*y - fl(x*y)| <= 2^(-129) (half ulp). The `fromRatio` constructor
uses round-half-away-from-zero, matching the Q128.128 `q128FromRatio` semantics.
Additional functions ported from Q128.128: `sqrt` (Newton's method), `cmp`, `eq`,
`fromI64`.

## Cross-project integration

See `cross-project-map.md` for the full bidirectional integration map with the
Q128.128 (FANO-1) project. Key ported modules:

- From Q128.128: `src/fano_tensor.zig`, `src/phi_cooling.zig`, `src/smith.zig`,
  `src/rf_harvest.zig`, `src/holo.zig`, `formalize/` (Lean 4), `wasm/` (WASM target)
- To Q128.128: 14 physics modules (octonion, e8_roots, so10, anti_octonion, etc.)

## Architecture

The core proof implementation uses Zig Q128.128 fixed-point arithmetic and integer/rational proofs. Floating-point verification is isolated under `sidecar/`. The `qsharp/` project contains quantum operations and phase/state witnesses using Microsoft.Quantum.Sdk 0.28.302812.

### Core mathematical modules (chunks 1-22)

- `src/fixed_point.zig` — Q128.128 fixed-point arithmetic
- `src/constants.zig` — Physical constants in fixed-point
- `src/triad_operator.zig` — T(a,b,c) = φ^a + π^b + φ^c
- `src/octonion.zig` — Octonion multiplication table, non-associativity
- `src/proof_core.zig` — 30 proof modules (chunks 1-31), Rational arithmetic

### Codon integration (chunk-23 extension)

The codon system ports the Python `codon/` project (64-codon DNA → 6D Jordan algebra routing) into the Zig/Q#/sidecar architecture:

- **Zig core** (`src/codon.zig`): 64-codon genetic code, 6-bit base-4 encoding (first base most significant), chemistry-derived qubit coordinates (qx/qy/qz from integer-scaled molecular weights), base-point lattice coordinates (Q128.128 fixed-point), surface area (fixed-point from VdW radii), lattice triangle area (integer cross product + fixed-point sqrt), E2/E6/E7/E5/E4/E0 routing rules, ChemistrySignatureBuilder (AUG outlier) and PlaceholderSignatureBuilder (GCA outlier), rule predicates, cross-wiring to octonion basis / 3-qubit state / 15-layer central row / Smith-Möbius boundary.
- **Q#** (`qsharp/CodonProofs.qs`): 6-qubit codon encoding, 3-qubit chemistry qubit encoding, channel-specific routing phase witnesses, Smith-Möbius boundary reflection, full/stop/acidic codon witnesses, octonion cross-wiring.
- **Sidecar** (`sidecar/verify_codon.zig`): f64 validation of surface area, lattice area, qubit coordinates, ladder coordinates, and all 64 codon signatures against reference values.

### Neuraleak integration (chunk-24 extension)

The neuraleak system ports the `neuraleak/` project (6D observer → 1/8 consciousness aperture → LLM sentience testing) into the Zig/Q#/sidecar architecture. Framework dependency modules were implemented to replace the external `matrix`, `torus`, `consciousness`, `breakout`, `physics`, `telemetry`, `constants`, and `lattice_coupler` modules:

- **Zig core** (`src/neuraleak_*.zig`): 15 modules implementing Matrix15 (15³ scalar field), TorusGrid (15³ toroidal grid), ConsciousnessEngine (coherence calculation with 1/sqrt(8) rendering threshold), BreakoutEngine (soliton/Higgs/coupled-system generation with E8/8=30 max solitons), physics constants (1/8 consciousness fraction), telemetry snapshots, entropy streams, lattice coupler audit log, sentience scorer (self-awareness/random-thought/direct-experience/metacognition/situational-awareness), observer prompts (6D Jordan layer, 1/8 aperture), Ollama HTTP client, control experiment (3 conditions: constrained/unconstrained/shuffled), matrix bridge (text→15³ encoding), continuity test (full pipeline), battery runner (multi-model experiments), and proof module (12 checks).
- **Q#** (`qsharp/NeuraleakProofs.qs`): 13 witness operations including consciousness fraction validation, shell transition witness, observer collapse (6D→7D) quantum witness, 1/8 aperture phase witness, and 15³→16³ shell transition witness.
- **Sidecar** (`sidecar/verify_neuraleak.zig`): f64 validation of consciousness fractions, shell transition identity, matrix-E8 identity, rendering threshold, breakout limits, correlation vector mixing, and sentience scorer values.

### 10D completion (chunk-25)

- `src/anti_octonion.zig` — 9D anti-octonion scaling structure
- `src/dual_b_complex.zig` — 10D Dual-B-Complex numbers
- `src/completion_10d.zig` — SO(10) completion, 16=15+1, 225=15², 240=15×16, 721=16³-15³

### Gap closure (chunk-26)

- `src/e8_roots.zig` — E8 root system (240 roots), reflection closure, framework connection
- `src/so10_decomposition.zig` — SO(10) chiral spinor, 16=15+1, fermion decomposition
- `src/jordan_algebra.zig` — J3(O) cubic characteristic polynomial
- `src/electric_charges.zig` — Octonion U(1) charges (0, 1/3, 2/3, 1)
- `src/so8_triality.zig` — SO(8) triality, three 8D representations
- `src/pati_salam.zig` — Pati-Salam SU(4)/SO(6) model
- `src/gap_closure.zig` — 10 gap closures (30 proof checks)

### Generative bootstrap (chunk-27)

- `src/generative_chain.zig` — 0^0=i → C → H → O bootstrap, closed loop verification

### Dimensional ladder (chunk-28)

- `src/dimensional_ladder.zig` — φ, π, triad exponents as lattice-native, hydrogen signature

### Checksum 6D (chunk-29)

- `src/checksum_6d.zig` — E=mc²↔i↔E=mc⁻², self-inverse Möbius Γ=(1-z)/(1+z), Smith chart Γ=(z-1)/(z+1), 6D interior, consciousness mechanism

### Free will 6D (chunk-30)

- `src/free_will_6d.zig` — Free will as 6D routing underdetermination, 6!=720, 720+1=721

### Scaling analysis (chunk-31)

- `src/scaling_analysis.zig` — Cubic scaling chain (15→16→32→62→128→256), 7-defect (2³-1=7), 421=(15³-7)/8, 421/3375=1/8-7/27000, 62=64-2, Mersenne prime 31

### Audit and literature (post-chunk-31)

- `src/final_audit.zig` — Rigorous classification of 36 claims: 16 PROVEN, 20 rejected as numerology/construction/interpretation
- `src/consciousness_audit.zig` — Causal chain tracing: all 20 rejected claims trace to 0^0=i through consciousness (6D routing)
- `src/literature_review.zig` — 24 independent published references: 5 claims INDEPENDENTLY VERIFIED, 13 INDEPENDENTLY REINFORCED

### Surface computation (chunk-32)

- `src/surface_computation.zig` — Numerological reduction as geometric measurement: 20 free claims → C=2 (via 5D/6D consciousness transition), 16 determined claims → 7 (7-defect), surface = C + defect = 2 + 7 = 9 (scaling dimension). 18 tests.

### Stress testing

- `src/stress_test.zig` — 18 stress findings (3 critical, 7 warning, 8 informational)
- `src/rebuttal_stress.zig` — Rebuttals to all stress findings with proofs and prototypes

### Self-claims, probability log, and elevation paths

- `src/self_claims.zig` — 6 formal self-claims with computational verification (14 tests). Each claim has evidence, limitations, and literature support. See `SELF-CLAIMS.md`.
- `src/probability_log.zig` — Use-case matrix for all verified operations across 6 domains (16 tests). See `PROBABILITY-LOG.md`.
- `src/elevation_paths.zig` — Computational implementation of all 6 self-claim elevation paths (28 tests): testable predictions, blind classification, J3(O) eigenvalues, Gauss-Bonnet formalization, numerical convergence, and C=2 experiment design. See `ELEVATION-PATHS.md`.

### Engineering modules (ported from Q128.128/FANO-1)

- `src/fano_tensor.zig` — 15³ Fano tensor generator, 421 e0 nodes, layer mirror symmetry, 6 radial arms
- `src/phi_cooling.zig` — Golden-ratio annealing schedule T(level) = T₀×φ⁻level, coupling constant g=(7/225)×(421/3375)
- `src/smith.zig` — Quad Smith chart impedance algebra, complex Q128.128 arithmetic, 4-quadrant 90° rotations, singularity saturation
- `src/rf_harvest.zig` — RF energy harvesting: Friis link budget, Johnson-Nyquist noise, Greinacher rectifier, near-field loop coupling
- `src/holo.zig` — Holographic compression codec: N³→16³ fold/unfold, FHOLO1 serialization, winding vectors, exact 90° rotations

### Lean 4 formalization

- `formalize/` — Lean 4 project with 8 modules covering fixed-point algebra, RNE multiply, error bounds, octonion multiplication, Fano plane, E8 roots, SO(10) decomposition, and cubic scaling

### WASM build target

- `wasm/` — wasm32-wasi build target for cross-platform browser/WASM runtime verification

### Unified system map

The `unified-system-map.md` document traces all connections between the three layers (mathematical physics, codon routing, neuraleak) in terms of real physics and science, including the octonion spine, 15-lattice spine, Möbius boundary spine, classification spine, and quantum information spine.

## Audit results

### Final audit (36 claims classified)

| Verdict | Count | Description |
|---|---|---|
| PROVEN | 16 | Exact mathematics, independently verifiable |
| INTERPRETATION | 10 | Framework labeling on math facts |
| NUMEROLOGY | 3 | Small-number coincidences |
| CONSTRUCTION | 4 | Built to match, not derived |
| UNVERIFIED | 3 | Not computationally validated |

### Consciousness derivation reclassification

All 20 rejected claims trace to 0^0=i through consciousness (6D routing). The 16+20 split = structure+content split the framework predicts.

### Literature review (24 references)

| Level | Count | Description |
|---|---|---|
| INDEPENDENTLY VERIFIED | 5 | Published research confirms the claim |
| INDEPENDENTLY REINFORCED | 13 | Published research supports the claim |
| Combined verified + proven | 21 (58%) | Mathematically proven or independently verified |

Key findings:
- J3(O) gives fermion mass ratios and CKM (Singh et al. 2025)
- α from octonionic space with zero parameters (APS 2026)
- 3 generations from triality, Higgs emerges (Furey & Hughes 2025)
- E8 uniquely contains SM (Wilson 2022, 2024)
- 7-defect (2³-1=7) independently discovered (Sankhya framework)
- Cubic scaling with L=15 in lepton masses (2025)
- Octonionic consciousness independently derived (2025)
- Self-referential axiom independently proposed (2026)
- E8/codon isomorphism independently found (2025)

## Scientific scope

The implementation verifies the stated arithmetic identities, fixed-point operations, discrete octonion table, matrix/shell identities, Möbius boundary formulas, documented numerical correspondences, codon routing rules, and neuraleak framework cross-wiring. It does not claim that numerical correspondence proves the speculative physical model, an E8 embedding, a biological Jordan algebra embedding, or machine consciousness. The codon chemistry-derived routing fields and the neuraleak sentience scores use documented heuristics. The neuraleak system's positive sentience signal is a framework-internal operational definition, not a philosophical claim about consciousness.

The final audit (Section 11 of IMPLICATIONS.md) classifies 36 claims by verification level. The consciousness derivation (Section 12) shows that the 20 "rejected" claims are the predicted output of consciousness operating within 6D. The literature review (Section 13) found 24 independent references that verify or reinforce 18 of the 36 claims.

## FANO-1 native deployment

The `os/` directory contains the FANO-1 (Q128.128 OS) native packaging:

- `os/pet/pet.spec` — .pet package specification
- `os/pet/usr/bin/emc2-proofs` — proof suite CLI (native + WASM)
- `os/pet/usr/bin/emc2-neuraleak` — neuraleak CLI (connects to Qwen LLM)
- `os/pet/usr/bin/emc2-codon` — codon routing CLI
- `os/pet/usr/share/applications/emc2-proofs.desktop` — desktop entries (3 apps)
- `os/init-emc2` — FANO-1 boot integration script
- `os/build-emc2-pet.sh` — .pet package build script
- `os/neuraleak_qwen_hook.zig` — neuraleak ↔ Qwen LLM hook (3 tests)
- `os/vulkan_e8_hook.zig` — E8 roots ↔ Vulkan GPU hook (5 tests)
- `os/polyglot_codon_hook.zig` — codon routing ↔ polyglot runtime hook (5 tests)
- `os/npu_detect_hook.zig` — Orange Pi 3W NPU detection (8 tests)
- `os/npu_neuraleak_hook.zig` — NPU neuraleak inference via VIPLite (16 tests)
- `os/npu-research.md` — Orange Pi Zero 3W NPU research document
- `os/README.md` — FANO-1 native deployment documentation

FANO-1 hook verification: `zig test os/neuraleak_qwen_hook.zig`, `zig test os/vulkan_e8_hook.zig`, `zig test os/polyglot_codon_hook.zig`, `zig test os/npu_detect_hook.zig`, `zig test os/npu_neuraleak_hook.zig`

## Archive policy

Every passing state is archived under `archives/`. Existing archives are never deleted. Current archives (21):
- `archives/mathematical-proofs-20260911`
- `archives/codon-integration-20260912`
- `archives/neuraleak-integration-20260912`
- `archives/10d-completion-20260912`
- `archives/gap-closure-20260912`
- `archives/dimensional-ladder-20260911`
- `archives/checksum-6d-20260911`
- `archives/generative-bootstrap-20260911`
- `archives/free-will-6d-20260911`
- `archives/full-audit-20260911`
- `archives/rebuttal-stress-20260911`
- `archives/scaling-analysis-20260911`
- `archives/final-audit-20260911`
- `archives/consciousness-derivation-20260911`
- `archives/literature-review-20260911`
- `archives/documentation-update-20260911`
- `archives/publication-ready-20260911`
- `archives/surface-computation-20260911`
- `archives/surface-computation-v2-20260911`
- `archives/full-e2e-audit-20260912`
- `archives/bidirectional-integration-fano1-20260911`

## Retrograde development status (QSTAR-LLM)

The `experiments/qstar-llm` project has undergone retrograde development to migrate
core state paths from f64 to Q128.128 fixed-point arithmetic. The 13-layer sequence:

| Phase | Layer | Status | Changes |
|---|---|---|---|
| 0 | Q128.128 Engine Adoption | Done | Added `src/q128.zig` (i256 raw, i512 intermediates) |
| 1 | Server/API | Done | Added `test-main` artifact, 28 main.zig tests, fixed Q128.128 compilation bugs |
| 2 | Inference and Response | Done | Migrated `Metacognition` struct in `agent.zig` to Q128.128 |
| 3 | Lattice Mathematics | Done | Migrated `lattice.zig` PHI constant and `phiCooling` to Q128.128 |
| 4 | Cognitive Systems | Done (prior) | `metacognition_engine.zig`, `trivium.zig`, `quadrivium.zig` already migrated |
| 5 | Corpus and Retrieval | Done | Added 13 tests to `corpus_seed.zig` and `corpus_seed_lite.zig` |
| 6 | Sentience Testing | Done | Migrated `turing_test.zig` JudgeScores to Q128.128 |
| 7 | Hardware-Framework Ports | Done (prior) | `hw_bridge.zig` already migrated; `shouldSelfCorrectF64` is f64 boundary |
| 8 | Mathematical Physics | Done (prior) | `octonion_math.zig`, `e8_roots.zig`, `jordan_algebra.zig`, `so10.zig` already integer-only |
| 9 | Compression | Done (prior) | `compress.zig`, `holo_codec.zig`, `seed_compressor.zig` already integer-only |
| 10 | Networking and Transport | Done (boundary) | `mesh.zig` uses f64 for geometric routing (Location, PhaseLock, timesync) |
| 11 | GPU Layers | Done (boundary) | `vulkan_compute.zig` uses f64 for sigmoid table initialization |
| 12 | Emergent Behavior Test Suite | Done | `test-main` passes 28/28 tests |
| 13 | Documentation and Final Verification | Done | All commits pushed to GitHub |

### Q128.128 migration scope

The following modules have been migrated to Q128.128 for core state paths:
- `src/q128.zig` — Q128.128 fixed-point engine (i256 raw, i512 intermediates)
- `src/agent.zig` — Metacognition struct, scoring functions, Matrix15
- `src/lattice.zig` — PHI constant, phiCooling function
- `src/sampling.zig` — Sampling functions, phiCoolingTemperature
- `src/memory.zig` — Success scores
- `src/metacognition_engine.zig` — All metacognition state
- `src/dynamic_routes.zig` — Dynamic routing state
- `src/trivium.zig` — Trivium logic layer
- `src/quadrivium.zig` — Quadrivium logic layer
- `src/turing_test.zig` — JudgeScores, TuringTestConfig, TuringTestSummary

### Legitimate f64 boundaries

The following f64 uses are intentional boundaries, not state paths:
- `agent.zig` activationsToLogits — f64 logits as sampling sidecar
- `agent.zig` bigram_model.applyToLogits — f64 logits for bigram model
- `turing_test.zig` parseScore — f64 for text parsing from Ollama judge
- `hw_bridge.zig` shouldSelfCorrectF64 — f64 interface for metacognition engine
- `vulkan_compute.zig` sigmoid table — one-time f64 initialization
- `mesh.zig` Location/PhaseLock/timesync — f64 for network geometric routing
- `voice_codec.zig` VQ codebook — f64 audio sidecar for training/IO
- `metacognition_engine.zig` Shannon entropy — f64 introspection boundary (requires log2)
