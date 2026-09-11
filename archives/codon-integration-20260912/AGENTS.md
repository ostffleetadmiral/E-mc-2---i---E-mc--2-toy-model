# Proof Workspace Guide

## Verification commands

- Zig core: `zig build test` and `zig build run`
- Q#: `cd qsharp && dotnet build && dotnet run`
- f64 sidecar: `cd sidecar && zig build test && zig build run`
- Source/CSV audit: Zig chunk 09 validates all 145 rows of `mound_triad_results.csv`; the 22 memory ranges cover all nonblank source lines in `x.md`.
- Codon integration: Zig `src/codon.zig` (56 tests, 12 proof checks in chunk-22), Q# `qsharp/CodonProofs.qs` (6 witness operations), sidecar `sidecar/verify_codon.zig` (16 tests).

## Architecture

The core proof implementation uses Zig Q128.128 fixed-point arithmetic and integer/rational proofs. Floating-point verification is isolated under `sidecar/`. The `qsharp/` project contains quantum operations and phase/state witnesses using Microsoft.Quantum.Sdk 0.28.302812.

### Codon integration (chunk-23 extension)

The codon system ports the Python `codon/` project (64-codon DNA → 6D Jordan algebra routing) into the Zig/Q#/sidecar architecture:

- **Zig core** (`src/codon.zig`): 64-codon genetic code, 6-bit base-4 encoding (first base most significant), chemistry-derived qubit coordinates (qx/qy/qz from integer-scaled molecular weights), base-point lattice coordinates (Q128.128 fixed-point), surface area (fixed-point from VdW radii), lattice triangle area (integer cross product + fixed-point sqrt), E2/E6/E7/E5/E4/E0 routing rules, ChemistrySignatureBuilder (AUG outlier) and PlaceholderSignatureBuilder (GCA outlier), rule predicates, cross-wiring to octonion basis / 3-qubit state / 15-layer central row / Smith-Möbius boundary.
- **Q#** (`qsharp/CodonProofs.qs`): 6-qubit codon encoding, 3-qubit chemistry qubit encoding, channel-specific routing phase witnesses, Smith-Möbius boundary reflection, full/stop/acidic codon witnesses, octonion cross-wiring.
- **Sidecar** (`sidecar/verify_codon.zig`): f64 validation of surface area, lattice area, qubit coordinates, ladder coordinates, and all 64 codon signatures against reference values.

## Scientific scope

The implementation verifies the stated arithmetic identities, fixed-point operations, discrete octonion table, matrix/shell identities, Möbius boundary formulas, documented numerical correspondences, and codon routing rules. It does not claim that numerical correspondence proves the speculative physical model, an E8 embedding, or a biological Jordan algebra embedding. The codon chemistry-derived routing fields use documented heuristics because the source manuscripts do not define the exact base-to-dimension mapping.
