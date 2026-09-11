# Cross-Project Map: E=mc²-i-E=mc⁻² (toy-model) ↔ Q128.128 (FANO-1)

**Date:** 2026-09-11  
**License:** CC BY-NC-SA 4.0  
**Organization:** Open Sentience Technology Foundation

## Overview

This document maps the relationship between two independent but related projects:

- **Hardware (this repo):** E=mc²-i-E=mc⁻² (toy-model) — physics-oriented mathematical framework with deep formalization of octonionic structures, E8/SO(10)/Jordan algebra mappings, codon routing, and neuraleak consciousness experiments.
- **Q128.128 (FANO-1):** Deterministic Q128.128/I256 fixed-point arithmetic engine with WASM portability, Vulkan GPU compute, holographic codec, OS/runtime integration, Lean 4 formalization, and polyglot execution.

Both projects share the same mathematical core (Q128.128 fixed-point, RamseyIdentity, octonions, Fano structures, triad operator) but diverged in emphasis: hardware developed the physics formalization, Q128.128 developed the engineering infrastructure.

## Bidirectional Integration Status

### Phase 1: Precision Fix (Hardware ← Q128.128) ✅ Complete

- **RNE Multiply:** Hardware's `src/fixed_point.zig` now uses round-to-nearest-even with exact 512-bit intermediate products, ported from Q128.128's `zig/q128_128.zig`.
- **Error bound:** |x*y - fl(x*y)| ≤ 2⁻¹²⁹ (half ULP), replacing the previous truncating multiply with up to 1 ULP systematic bias.
- **fromRatio:** Added round-half-away-from-zero constructor matching Q128.128's `q128FromRatio`.
- **New functions:** `sqrt`, `cmp`, `eq`, `fromI64` added to `fixed_point.zig`.
- **Test impact:** All tests pass. Test count increased from 391 to 398+.

### Phase 2: Physics Enrichment (Q128.128 ← Hardware) ✅ Complete

13 physics modules ported from hardware to Q128.128's `zig/` directory:

| Module | Description | Tests |
|--------|-------------|-------|
| `octonion.zig` | Octonion multiplication table, non-associativity | ✅ |
| `e8_roots.zig` | E8 root system (240 roots), reflection closure | ✅ |
| `so10_decomposition.zig` | SO(10) chiral spinor, 16=15+1, fermion decomposition | ✅ |
| `anti_octonion.zig` | 9D anti-octonion scaling structure | ✅ |
| `dual_b_complex.zig` | 10D Dual-B-Complex numbers, SO(10) GUT | ✅ |
| `jordan_algebra.zig` | J3(O) cubic characteristic polynomial | ✅ |
| `so8_triality.zig` | SO(8) triality, three 8D representations | ✅ |
| `electric_charges.zig` | Octonion U(1) charges (0, 1/3, 2/3, 1) | ✅ |
| `pati_salam.zig` | Pati-Salam SU(4)/SO(6) model | ✅ |
| `scaling_analysis.zig` | Cubic scaling chain, 7-defect, 421/3375 | ✅ |
| `checksum_6d.zig` | E=mc²↔i↔E=mc⁻², Möbius, Smith chart | ✅ |
| `completion_10d.zig` | 10D completion, 225=15², 240=15×16, 721 | ✅ |
| `generative_chain.zig` | 0^0=i → C → H → O bootstrap | ✅ |
| `final_audit.zig` | 36-claim classification audit | ✅ |

All modules compile and pass tests in Q128.128. Build target: `zig build test-physics`.

**Codon routing port** (in progress): `codon.zig` with `fixed_compat.zig` compatibility layer.

### Phase 3: Engineering Enrichment (Hardware ← Q128.128) ✅ Mostly Complete

| Module | Description | Status |
|--------|-------------|--------|
| `fano_tensor.zig` | 15³ Fano tensor generator, 421 e0 nodes | ✅ Complete |
| `phi_cooling.zig` | Golden-ratio annealing schedule | ✅ Complete |
| `smith.zig` | Quad Smith chart impedance algebra | ✅ Complete |
| `rf_harvest.zig` | RF energy harvesting link budget | ✅ Complete |
| `holo.zig` | Holographic compression codec | ✅ Complete |
| `formalize/` | Lean 4 formalization framework | ✅ Complete (8 modules) |
| `wasm/` | WASM build target | ✅ Complete |

### Phase 4: Deep Integration (Planned)

- Unified codon routing across polyglot runtime
- Neuraleak + Agent Zero + local LLM inference
- GPU-accelerated E8 root verification
- Machine-checked proofs covering all 30+ proof modules
- Compressed lattice via holographic compression

## Shared Mathematical Core

### Q128.128 Fixed-Point Arithmetic

| Concept | Hardware | Q128.128 | Status |
|---------|----------|----------|--------|
| Representation | `i256` raw mantissa | `U256 = {hi: u128, lo: u128}` | Different types, same semantics |
| Scale | `2^128` (i256) | `2^128` (q128) | Equivalent |
| Multiply | RNE with exact i512 product | RNE with exact 512-bit product | ✅ Aligned |
| Division | Truncating | Truncating | ✅ Aligned |
| sqrt | Newton's method on i256 | Newton's method on U256 | ✅ Equivalent |
| fromRatio | Round-half-away | Round-half-away | ✅ Aligned |
| Error bound | 2⁻¹²⁹ (half ULP) | 2⁻¹²⁹ (half ULP) | ✅ Aligned |

### RamseyIdentity / Checksum 6D

| Feature | Hardware | Q128.128 |
|---------|----------|----------|
| Forward transform | E_f = m*c² | E_f = m*c² |
| Inverse transform | E_i = m*c⁻² | E_i = m*c⁻² |
| Pivot rotation | (re,im) → (-im,re) | (re,im) → (-im,re) |
| Möbius boundary | Γ = (z-1)/(z+1) | Γ = (z-1)/(z+1) |
| Smith chart | checksum_6d.zig | smith.zig (quad, enhanced) |

### Octonions and Fano Structures

| Feature | Hardware | Q128.128 |
|---------|----------|----------|
| Octonion multiplication | `octonion.zig` (7 oriented triples) | `octonion.zig` (ported) + `fano_tensor.zig` (15³ grid) |
| Fano plane | 7 triples in octonion.zig | `fano_tensor.zig` (15³, 421 e0 nodes) |
| E8 roots | `e8_roots.zig` (240 roots) | `e8_roots.zig` (ported) |

### Triad Operator

| Feature | Hardware | Q128.128 |
|---------|----------|----------|
| Formula | T(a,b,c) = φ^a + π^b + φ^c | T(a,b,c) = φ^a + π^b + φ^c |
| Table | 145 rows in chunk-09 | 145 rows in `triad_table.zig` |
| Fitting | Not implemented | `fano_const_main.zig` with `fit` |

## Unique Contributions

### Hardware-Only

- **Codon routing:** 64-codon DNA → 6D Jordan algebra routing (37 tests)
- **Neuraleak:** 6D observer → 1/8 consciousness aperture → LLM sentience testing (15 modules)
- **Q# witnesses:** 51 quantum witness operations
- **f64 sidecar validation:** Isolated floating-point verification
- **Consciousness audit:** 20 rejected claims traced through causal chain
- **Literature review:** 24 independent published references
- **Surface computation:** Numerological reduction as geometric measurement
- **Stress testing:** 18 stress findings with rebuttals

### Q128.128-Only

- **WASM portability:** wasm32-wasi build target, wasm3 verification
- **Vulkan GPU compute:** SPIR-V shaders, RX 580 bit-exact verification
- **Holographic codec:** N³ → 16³ fold/unfold, FHOLO1 serialization
- **Polyglot runtime:** 22 tests, multi-language execution
- **OS integration:** Puppy Linux/FANO-1 packaging, kernel, VFS
- **Blockchain:** Deterministic ledger and state transitions
- **ISG:** RGB transcoder and Q128 error correction
- **Space-agent:** Browser-first desktop shell
- **Smith chart:** Quad-chart with complex division and singularity handling
- **RF harvesting:** Friis, Johnson-Nyquist, Greinacher, near-field coupling
- **Phi cooling:** Golden-ratio annealing schedule
- **Lean 4 formalization:** 5 modules with machine-checked proofs

## Compatibility Matrix

| Component | Hardware | Q128.128 | Compatible | Notes |
|-----------|----------|----------|------------|-------|
| Q128.128 multiply | RNE ✅ | RNE ✅ | ✅ | Aligned in Phase 1 |
| Q128.128 division | Truncating | Truncating | ✅ | Same semantics |
| Q128.128 sqrt | Newton i256 | Newton U256 | ✅ | Equivalent |
| Octonion multiplication | 7 triples | 7 triples (ported) | ✅ | Identical |
| E8 roots | 240 roots | 240 roots (ported) | ✅ | Identical |
| SO(10) decomposition | 16=15+1 | 16=15+1 (ported) | ✅ | Identical |
| Triad operator | T(a,b,c) | T(a,b,c) | ✅ | Same formula |
| RamseyIdentity | checksum_6d | ramsey_identity | ✅ | Same transforms |
| Smith chart | Basic (checksum_6d) | Quad (smith.zig) | ✅ | Q128.128 enhanced |
| Holographic codec | holo.zig (ported) | holo.zig (native) | ✅ | Ported in Phase 3 |
| Fano tensor | fano_tensor.zig (ported) | fano_tensor.zig (native) | ✅ | Ported in Phase 3 |
| Codon routing | codon.zig (native) | codon.zig (ported) | ⚠️ | In progress |
| Lean 4 | formalize/ (new) | formalize/ (native) | ✅ | Hardware created its own |

## Scientific Claim Classification

Both projects must maintain the distinction between:

1. **PROVEN** — Exact mathematics, independently verifiable
2. **INTERPRETATION** — Framework labeling on math facts
3. **NUMEROLOGY** — Small-number coincidences
4. **CONSTRUCTION** — Built to match, not derived
5. **UNVERIFIED** — Not computationally validated

Numerical matches (including the triad table and identities such as 240=15×16) must not be presented as physical derivations without dimensional consistency, parameter independence, generative equations, and predictive validation.

The Q128.128 Lean 4 formalization explicitly treats holographic codec completeness and reconstruction as axioms, not derived theorems. Any cross-reference must make this explicit.

## Verification Commands

### Hardware
```bash
zig build test          # Core Zig tests
zig build run           # Run all proof modules
cd sidecar && zig build test  # f64 sidecar validation
cd qsharp && dotnet build && dotnet run  # Q# witnesses
```

### Q128.128
```bash
cd zig && zig build test          # All Zig tests
cd zig && zig build test-physics  # Physics layer tests (ported)
cd zig && zig build test-engine   # Q128.128 engine tests
cd zig && zig build test-holo     # Holographic codec tests
cd zig && zig build test-smith    # Smith chart tests
cd zig && zig build test-rf       # RF harvesting tests
```

## File Cross-Reference

| Hardware | Q128.128 | Relationship |
|----------|----------|-------------|
| `src/fixed_point.zig` | `zig/q128_128.zig` | RNE multiply ported from Q128.128 |
| `src/octonion.zig` | `zig/octonion.zig` | Ported to Q128.128 |
| `src/e8_roots.zig` | `zig/e8_roots.zig` | Ported to Q128.128 |
| `src/so10_decomposition.zig` | `zig/so10_decomposition.zig` | Ported to Q128.128 |
| `src/anti_octonion.zig` | `zig/anti_octonion.zig` | Ported to Q128.128 |
| `src/dual_b_complex.zig` | `zig/dual_b_complex.zig` | Ported to Q128.128 |
| `src/jordan_algebra.zig` | `zig/jordan_algebra.zig` | Ported to Q128.128 |
| `src/so8_triality.zig` | `zig/so8_triality.zig` | Ported to Q128.128 |
| `src/electric_charges.zig` | `zig/electric_charges.zig` | Ported to Q128.128 |
| `src/pati_salam.zig` | `zig/pati_salam.zig` | Ported to Q128.128 |
| `src/scaling_analysis.zig` | `zig/scaling_analysis.zig` | Ported to Q128.128 |
| `src/checksum_6d.zig` | `zig/checksum_6d.zig` | Ported to Q128.128 |
| `src/completion_10d.zig` | `zig/completion_10d.zig` | Ported to Q128.128 |
| `src/generative_chain.zig` | `zig/generative_chain.zig` | Ported to Q128.128 |
| `src/final_audit.zig` | `zig/final_audit.zig` | Ported to Q128.128 |
| `src/fano_tensor.zig` | `zig/fano_tensor.zig` | Ported from Q128.128 |
| `src/phi_cooling.zig` | `zig/phi_cooling.zig` | Ported from Q128.128 |
| `src/smith.zig` | `zig/smith.zig` | Ported from Q128.128 |
| `src/rf_harvest.zig` | `zig/rf_harvest.zig` | Ported from Q128.128 |
| `src/holo.zig` | `zig/holo.zig` | Ported from Q128.128 |
| `formalize/` | `formalize/` | New in hardware, modeled on Q128.128 |
| `wasm/` | `wasm/` | New in hardware, modeled on Q128.128 |
| `src/codon.zig` | `zig/codon.zig` | Ported to Q128.128 (via fixed_compat.zig) |
| `os/` | — | FANO-1 native deployment (hardware → Q128.128 OS) |
| `os/neuraleak_qwen_hook.zig` | `os/agent-zero/` | Neuraleak ↔ Qwen LLM hook |
| `os/vulkan_e8_hook.zig` | `vulkan/` | E8 roots ↔ Vulkan GPU hook |
| `os/polyglot_codon_hook.zig` | `zig/poly/` | Codon routing ↔ polyglot runtime hook |
| `os/npu_detect_hook.zig` | — | Orange Pi 3W NPU detection (VIP9000, 3 TOPS) |
| `os/npu_neuraleak_hook.zig` | — | NPU neuraleak inference via VIPLite (SmolLM2) |
| `os/npu-research.md` | — | Orange Pi Zero 3W NPU research document |
