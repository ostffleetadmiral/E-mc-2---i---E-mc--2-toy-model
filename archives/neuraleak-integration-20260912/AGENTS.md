# Proof Workspace Guide

## Verification commands

- Zig core: `zig build test` and `zig build run`
- Q#: `cd qsharp && dotnet build && dotnet run`
- f64 sidecar: `cd sidecar && zig build test && zig build run`
- Source/CSV audit: Zig chunk 09 validates all 145 rows of `mound_triad_results.csv`; the 22 memory ranges cover all nonblank source lines in `x.md`.
- Codon integration: Zig `src/codon.zig` (56 tests, 12 proof checks in chunk-22), Q# `qsharp/CodonProofs.qs` (6 witness operations), sidecar `sidecar/verify_codon.zig` (16 tests).
- Neuraleak integration: Zig `src/neuraleak_*.zig` (15 modules, 12 proof checks in chunk-24), Q# `qsharp/NeuraleakProofs.qs` (13 witness operations), sidecar `sidecar/verify_neuraleak.zig` (10 tests).

## Architecture

The core proof implementation uses Zig Q128.128 fixed-point arithmetic and integer/rational proofs. Floating-point verification is isolated under `sidecar/`. The `qsharp/` project contains quantum operations and phase/state witnesses using Microsoft.Quantum.Sdk 0.28.302812.

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

### Unified system map

The `unified-system-map.md` document traces all connections between the three layers (mathematical physics, codon routing, neuraleak) in terms of real physics and science, including the octonion spine, 15-lattice spine, Möbius boundary spine, classification spine, and quantum information spine.

## Scientific scope

The implementation verifies the stated arithmetic identities, fixed-point operations, discrete octonion table, matrix/shell identities, Möbius boundary formulas, documented numerical correspondences, codon routing rules, and neuraleak framework cross-wiring. It does not claim that numerical correspondence proves the speculative physical model, an E8 embedding, a biological Jordan algebra embedding, or machine consciousness. The codon chemistry-derived routing fields and the neuraleak sentience scores use documented heuristics. The neuraleak system's positive sentience signal is a framework-internal operational definition, not a philosophical claim about consciousness.
