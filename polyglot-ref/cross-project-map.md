# Cross-Project Map: Q128.128 (FANO-1) ↔ E=mc²-i-E=mc⁻² (toy-model)

**Date:** 2026-09-11  
**License:** CC BY-NC-SA 4.0  
**Organization:** Open Sentience Technology Foundation

## Overview

This document maps the relationship between Q128.128 (FANO-1) and the E=mc²-i-E=mc⁻² (toy-model) hardware project.

- **Q128.128 (this repo):** Deterministic Q128.128/I256 fixed-point arithmetic engine with WASM, Vulkan, holographic codec, OS/runtime, Lean 4 formalization, and polyglot execution.
- **Hardware (toy-model):** Physics-oriented mathematical framework with octonionic structures, E8/SO(10)/Jordan algebra, codon routing, neuraleak consciousness experiments, Q# witnesses, and f64 sidecar validation.

Both projects share the same mathematical core but diverged in emphasis: Q128.128 developed engineering infrastructure, hardware developed physics formalization.

## Bidirectional Integration Status

### Phase 1: Precision Fix (Hardware ← Q128.128) ✅ Complete

Q128.128's exact 512-bit RNE multiply was ported into hardware's `fixed_point.zig`, replacing truncating multiplication. Error bound: |x*y - fl(x*y)| ≤ 2⁻¹²⁹.

### Phase 2: Physics Enrichment (Q128.128 ← Hardware) ✅ Complete

13 physics modules ported from hardware into `zig/`:

| Module | Description |
|--------|-------------|
| `octonion.zig` | Octonion multiplication table, non-associativity |
| `e8_roots.zig` | E8 root system (240 roots), reflection closure |
| `so10_decomposition.zig` | SO(10) chiral spinor, 16=15+1, fermion decomposition |
| `anti_octonion.zig` | 9D anti-octonion scaling structure |
| `dual_b_complex.zig` | 10D Dual-B-Complex, SO(10) GUT |
| `jordan_algebra.zig` | J3(O) cubic characteristic polynomial |
| `so8_triality.zig` | SO(8) triality, three 8D representations |
| `electric_charges.zig` | Octonion U(1) charges (0, 1/3, 2/3, 1) |
| `pati_salam.zig` | Pati-Salam SU(4)/SO(6) model |
| `scaling_analysis.zig` | Cubic scaling chain, 7-defect, 421/3375 |
| `checksum_6d.zig` | E=mc²↔i↔E=mc⁻², Möbius, Smith chart |
| `completion_10d.zig` | 10D completion, 225=15², 240=15×16, 721 |
| `generative_chain.zig` | 0^0=i → C → H → O bootstrap |
| `final_audit.zig` | 36-claim classification audit |

Build target: `zig build test-physics`

A `fixed_compat.zig` compatibility layer provides the hardware project's API on top of `q128_128.zig`, enabling the codon.zig port.

### Phase 3: Engineering Enrichment (Hardware ← Q128.128) ✅ Complete

| Module | Source in Q128.128 | Ported to Hardware |
|--------|--------------------|--------------------|
| `fano_tensor.zig` | `zig/fano_tensor.zig` | `src/fano_tensor.zig` |
| `phi_cooling.zig` | `zig/phi_cooling.zig` | `src/phi_cooling.zig` |
| `smith.zig` | `zig/smith.zig` | `src/smith.zig` |
| `rf_harvest.zig` | `zig/rf_harvest.zig` | `src/rf_harvest.zig` |
| `holo.zig` | `zig/holo.zig` | `src/holo.zig` |
| Lean 4 | `formalize/` (5 modules) | `formalize/` (8 modules, new) |
| WASM | `wasm/` | `wasm/` (new) |

### Phase 4: Deep Integration (Planned)

- Unified codon routing across polyglot runtime
- Neuraleak + Agent Zero + local LLM inference
- GPU-accelerated E8 root verification via Vulkan
- Machine-checked Lean 4 proofs for all 30+ proof modules
- Holographic compression of scaling chain data

## Shared Mathematical Core

### Q128.128 Fixed-Point Arithmetic

Both projects use Q128.128 fixed-point (128 integer bits, 128 fractional bits):
- **Hardware:** `i256` raw mantissa with `i512` intermediate products
- **Q128.128:** `U256 = {hi: u128, lo: u128}` with `U512` intermediate products
- **RNE multiply:** Both now use round-to-nearest-even with exact 512-bit products
- **Error bound:** |x*y - fl(x*y)| ≤ 2⁻¹²⁹ (half ULP)

### Key Identities (Proven)

| Identity | Meaning |
|----------|---------|
| 16 = 15 + 1 | SO(10) spinor = SM fermions + sterile ν |
| 225 = 15² | Mass matrix entries |
| 240 = 15 × 16 | E8 root count |
| 721 = 16³ - 15³ = 3(240) + 1 | Shell transition with Higgs |
| 7 = 2³ - 1 | 7-defect in cubic doubling |
| 421 = (3375 - 7) / 8 | Active e0 nodes in Fano tensor |
| 421/3375 = 1/8 - 7/27000 | Consciousness fraction |

## Unique Contributions

### Q128.128-Only

- WASM portability (wasm32-wasi, wasm3 verification)
- Vulkan GPU compute (SPIR-V shaders, RX 580 bit-exact)
- Holographic codec (N³ → 16³ fold/unfold, FHOLO1)
- Polyglot runtime (22 tests, multi-language)
- OS integration (Puppy Linux/FANO-1, kernel, VFS)
- Blockchain (deterministic ledger)
- ISG (RGB transcoder, error correction)
- Space-agent (browser-first desktop shell)
- Smith chart (quad-chart with complex division)
- RF harvesting (Friis, Johnson-Nyquist, Greinacher)
- Phi cooling (golden-ratio annealing)
- Lean 4 formalization (5 modules)

### Hardware-Only

- Codon routing (64-codon DNA → 6D Jordan algebra, 37 tests)
- Neuraleak (6D observer → 1/8 consciousness aperture, 15 modules)
- Q# witnesses (51 quantum witness operations)
- f64 sidecar validation (isolated floating-point verification)
- Consciousness audit (20 rejected claims traced)
- Literature review (24 independent published references)
- Surface computation (numerological reduction as geometric measurement)
- Stress testing (18 stress findings with rebuttals)

## Scientific Claim Classification

Both projects maintain the distinction between:
1. **PROVEN** — Exact mathematics, independently verifiable
2. **INTERPRETATION** — Framework labeling on math facts
3. **NUMEROLOGY** — Small-number coincidences
4. **CONSTRUCTION** — Built to match, not derived
5. **UNVERIFIED** — Not computationally validated

The Lean 4 formalization explicitly treats holographic codec completeness and reconstruction as axioms. Numerical matches are not physical derivations.

## Verification Commands

### Q128.128
```bash
cd zig && zig build test          # All Zig tests
cd zig && zig build test-physics  # Physics layer tests (ported from hardware)
cd zig && zig build test-engine   # Q128.128 engine tests
cd zig && zig build test-holo     # Holographic codec tests
cd zig && zig build test-smith    # Smith chart tests
cd zig && zig build test-rf       # RF harvesting tests
cd formalize && lake build        # Lean 4 formalization
```

### Hardware
```bash
zig build test          # Core Zig tests
zig build run           # Run all proof modules
cd sidecar && zig build test  # f64 sidecar validation
cd qsharp && dotnet build && dotnet run  # Q# witnesses
```

## File Cross-Reference

| Q128.128 | Hardware | Relationship |
|----------|----------|-------------|
| `zig/q128_128.zig` | `src/fixed_point.zig` | RNE multiply ported to hardware |
| `zig/octonion.zig` | `src/octonion.zig` | Ported from hardware |
| `zig/e8_roots.zig` | `src/e8_roots.zig` | Ported from hardware |
| `zig/so10_decomposition.zig` | `src/so10_decomposition.zig` | Ported from hardware |
| `zig/anti_octonion.zig` | `src/anti_octonion.zig` | Ported from hardware |
| `zig/dual_b_complex.zig` | `src/dual_b_complex.zig` | Ported from hardware |
| `zig/jordan_algebra.zig` | `src/jordan_algebra.zig` | Ported from hardware |
| `zig/so8_triality.zig` | `src/so8_triality.zig` | Ported from hardware |
| `zig/electric_charges.zig` | `src/electric_charges.zig` | Ported from hardware |
| `zig/pati_salam.zig` | `src/pati_salam.zig` | Ported from hardware |
| `zig/scaling_analysis.zig` | `src/scaling_analysis.zig` | Ported from hardware |
| `zig/checksum_6d.zig` | `src/checksum_6d.zig` | Ported from hardware |
| `zig/completion_10d.zig` | `src/completion_10d.zig` | Ported from hardware |
| `zig/generative_chain.zig` | `src/generative_chain.zig` | Ported from hardware |
| `zig/final_audit.zig` | `src/final_audit.zig` | Ported from hardware |
| `zig/fano_tensor.zig` | `src/fano_tensor.zig` | Ported to hardware |
| `zig/phi_cooling.zig` | `src/phi_cooling.zig` | Ported to hardware |
| `zig/smith.zig` | `src/smith.zig` | Ported to hardware |
| `zig/rf_harvest.zig` | `src/rf_harvest.zig` | Ported to hardware |
| `zig/holo.zig` | `src/holo.zig` | Ported to hardware |
| `zig/fixed_compat.zig` | (N/A) | Compatibility layer for codon port |
| `formalize/` | `formalize/` | Hardware created its own (8 modules) |
| `wasm/` | `wasm/` | Hardware created its own |
