# Proof Workspace Guide

## Verification commands

- Zig core: `zig build test` and `zig build run`
- Q#: `cd qsharp && dotnet build && dotnet run`
- f64 sidecar: `cd sidecar && zig build test && zig build run`
- Source/CSV audit: Zig chunk 09 validates all 145 rows of `mound_triad_results.csv`; the 22 memory ranges cover all nonblank source lines in `x.md`.

## Architecture

The core proof implementation uses Zig Q128.128 fixed-point arithmetic and integer/rational proofs. Floating-point verification is isolated under `sidecar/`. The `qsharp/` project contains quantum operations and phase/state witnesses using Microsoft.Quantum.Sdk 0.28.302812.

## Scientific scope

The implementation verifies the stated arithmetic identities, fixed-point operations, discrete octonion table, matrix/shell identities, Möbius boundary formulas, and documented numerical correspondences. It does not claim that numerical correspondence proves the speculative physical model or an E8 embedding.
