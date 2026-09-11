# Phase 4: Deep Integration Plan

**Date:** 2026-09-11  
**License:** CC BY-NC-SA 4.0  
**Status:** Planned (Phases 1-3 and 5 complete, FANO-1 native deployment complete)

## FANO-1 Native Deployment (Complete ✅)

The hardware project is now packaged as a FANO-1 `.pet` package (`os/`),
installing as a native OS application with CLI wrappers, desktop entries,
boot integration, and 5 integration hook modules (37 tests, all pass).

### Orange Pi Zero 3W NPU Backend (Researched ✅)

The Orange Pi Zero 3W (Allwinner A733) has a VeriSilicon Vivante VIP9000
NPU with 3 TOPS @ INT8 (INT8/INT16/FP16/BF16 mixed-precision). Research
completed in `os/npu-research.md`. NPU detection and neuraleak inference
hooks created and tested (24 tests).

**Backend priority on Orange Pi 3W:**
1. NPU (VIP9000) — LLM inference (SmolLM2-135M @ 21 tok/s)
2. Vulkan GPU (PowerVR BXM-4-64) — E8 root verification
3. Native Zig (Cortex-A76) — Full proof suite
4. WASM (wasm3) — Fallback

## Overview

Phase 4 connects the two integrated repositories at the runtime, compute, and proof levels. Each sub-task is independently verifiable and must not disrupt the existing passing test suites.

## 1. Unified Codon Routing

**Goal:** Wire hardware's `src/codon.zig` into Q128.128's polyglot runtime.

**Steps:**
1. Export codon routing functions from Q128.128's `zig/codon.zig` via the polyglot FFI.
2. Verify that codon routing produces identical results across Zig native, WASM, and polyglot runtimes.
3. Add cross-language codon routing integration tests to Q128.128's `test-polyglot` target.

**Verification:** Codon routing results match bit-for-bit across all runtimes.

## 2. Neuraleak + Agent Zero

**Goal:** Connect hardware's neuraleak modules to Q128.128's Agent Zero and local LLM inference.

**Steps:**
1. Port hardware's `src/neuraleak_proof.zig` into Q128.128's `zig/` directory.
2. Wire Q128.128's Agent Zero to call the neuraleak sentience scorer.
3. Connect to local Qwen inference via Ollama HTTP client (already in hardware).
4. Add integration tests verifying the full pipeline: observer prompt → LLM response → sentience score.

**Verification:** Neuraleak sentience scores are deterministic for fixed LLM responses.

## 3. GPU-Accelerated E8

**Goal:** Port E8 root verification into Q128.128's Vulkan compute pipeline.

**Steps:**
1. Create a SPIR-V compute shader that verifies E8 root closure under reflections.
2. Upload the 240 roots as a storage buffer.
3. Dispatch a compute shader that checks each root pair's reflection is in the set.
4. Read back results and compare with CPU verification.

**Verification:** GPU and CPU E8 verification produce identical results.

## 4. Machine-Checked Proofs

**Goal:** Extend Lean 4 formalization to cover all 30+ hardware proof modules.

**Steps:**
1. Complete the sorried proofs in the existing 8 Lean modules.
2. Add modules for: Jordan algebra, Pati-Salam, electric charges, generative chain.
3. Add modules for: Scaling chain, checksum 6D, free will 6D, surface computation.
4. Add modules for: Codon routing, neuraleak, consciousness audit.
5. Verify all proofs compile with `lake build`.

**Verification:** `lake build` succeeds with zero sorries.

## 5. Compressed Lattice

**Goal:** Apply holographic compression to scaling-chain data.

**Steps:**
1. Generate the full cubic scaling chain lattice (15³ → 16³ → 32³ → 62³ → 128³ → 256³).
2. Apply the holographic codec (`holo.zig`) to fold each level into a 16³ core.
3. Verify that unfolding reconstructs the original lattice bit-for-bit.
4. Measure compression ratios and verify they match theoretical predictions.

**Verification:** Fold/unfold round-trip is exact for all scaling chain levels.

## 6. Cross-Project Memory

**Goal:** Create shared context-memory chunks covering the integrated system.

**Steps:**
1. Create JSON and Markdown memory chunks for each integration phase.
2. Update the master memory index with cross-project chunks.
3. Ensure all chunks preserve the scientific claim classification.

**Verification:** All memory chunks are valid JSON and reference correct file paths.

## Pre-requisites

- Phase 1-3 complete ✅
- Phase 5 complete ✅
- Both repositories pass all tests ✅
- Q128.128 writable checkout available (SFTP mount has AccessDenied for builds)

## Risks

- SFTP mount limitations may require a local Q128.128 clone for builds.
- Vulkan compute requires a compatible GPU (RX 580, PowerVR BXM-4-64, or similar).
- Lean 4 proof completion may require significant mathematical effort.
- Agent Zero integration depends on Q128.128's Agent Zero API stability.
- NPU integration requires Orange Pi Zero 3W hardware and VIPLite SDK.
- Qwen2.5 does not yet run on the A733 NPU (SmolLM2 is the proven model).
- Mainline Linux kernel does not support A733 — vendor kernel required.
- ACUITY toolkit model conversion (ONNX → NBG) is an offline host-side step.
