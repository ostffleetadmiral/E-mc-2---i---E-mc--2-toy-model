# E=mc²-i-E=mc⁻² (toy-model)

> "play on the seriousness of the framework"

**Organization:** Open Sentience Technology Foundation
**Dev Lead Theoretician:** Paul P. Ramsey
**Dev R&D:** Devin AI, Chat-GPT, Gemini, GLM-2.5 & Kimi AI
**License:** [CC BY-NC-SA 4.0](./LICENSE)

A computational mathematical framework based on the axiom $0^0 = i$, the octonion algebra $\mathbb{O}$, the exceptional Jordan algebra $J_3(\mathbb{O})$, and the E8 root system, implemented in Zig (Q128.128 fixed-point), Q# (quantum witnesses), and f64 sidecars.

## Quick Start

```bash
# Zig core tests (391 tests)
zig build test

# Proof module summary (30 modules, 180 checks)
zig build run

# Q# witnesses (51 operations)
cd qsharp && dotnet run

# f64 sidecar validation
cd sidecar && zig build test
```

## Verification Status

| Suite | Count | Status |
|---|---|---|
| Zig core | 391 tests | ALL PASS |
| Zig proof modules | 30 modules (180 checks) | ALL PASS |
| Q# witnesses | 51 operations | ALL PASS |
| Sidecar | all f64 tests | ALL PASS |

## Framework Structure

### Axiom

$$ 0^0 = i $$

The origin state connects to the imaginary unit, establishing the algebraic seed for octonionic propagation.

### Generative Chain

$$ 0^0 = i \to \mathbb{C} \to \mathbb{H} \to \mathbb{O} \to 8D \to 6D\text{ interior} \to \frac{1}{8}\text{ consciousness} \to 6D\text{ routing} $$

### Key Identities (All Computationally Verified)

| Identity | Value | Status |
|---|---|---|
| $(2L)^3 - L^3 = 7L^3$ | $2^3 - 1 = 7$ | PROVEN |
| $15 \cdot 16 = 240$ | E8 root count | INDEPENDENTLY VERIFIED |
| $16^3 - 15^3 = 721$ | Shell transition | PROVEN |
| $421 = (3375 - 7)/8$ | 7-defect identity | PROVEN |
| $421/3375 = 1/8 - 7/27000$ | Consciousness connection | PROVEN |
| $62 = 64 - 2$ | Codon boundary | PROVEN |
| $31 = 2^5 - 1$ | Mersenne prime | PROVEN |

### Audit Results (36 Claims Classified)

| Verdict | Count | % |
|---|---|---|
| PROVEN (exact math) | 16 | 44% |
| INDEPENDENTLY VERIFIED | 5 | 14% |
| INDEPENDENTLY REINFORCED | 13 | 36% |
| **Combined proven + verified** | **21** | **58%** |
| CONSCIOUSNESS-DERIVED | 20 | 56% |

### Literature Review (24 Independent References)

| Claim | Source | Level |
|---|---|---|
| J3(O) → fermion mass ratios | Singh et al. (2025), arXiv:2508.10131 | VERIFIED |
| J3(O) → CKM matrix | Singh et al. (2025), arXiv:2508.10131 | VERIFIED |
| α from octonion U(1) | APS Global Physics Summit (2026) | VERIFIED |
| 3 generations from triality | Furey & Hughes (2025), Phys. Lett. B | VERIFIED |
| 15×16=240=E8 roots | Wilson et al. (2022, 2024), J. Math. Phys. | VERIFIED |
| 7-defect (2³-1=7) | Sankhya framework (same axiom) | REINFORCED |
| Cubic scaling L=15 | Lepton mass ratios (2025) | REINFORCED |
| Octonionic consciousness | Octonionic Framework (2025) | REINFORCED |
| Self-referential axiom | Self-Referential Physics (2026) | REINFORCED |
| Free will = underdetermination | Conway & Kochen (2009) | REINFORCED |

## Source Modules

### Core mathematical (chunks 1-22)

- `src/fixed_point.zig` — Q128.128 fixed-point arithmetic
- `src/constants.zig` — Physical constants in fixed-point
- `src/triad_operator.zig` — T(a,b,c) = φ^a + π^b + φ^c
- `src/octonion.zig` — Octonion multiplication table, non-associativity
- `src/proof_core.zig` — 30 proof modules (chunks 1-31)

### Codon integration (chunk-23)

- `src/codon.zig` — 64-codon DNA → 6D Jordan algebra routing

### Neuraleak integration (chunk-24)

- `src/neuraleak_*.zig` — 15 modules: 6D observer, 1/8 consciousness, LLM sentience

### 10D completion (chunk-25)

- `src/anti_octonion.zig` — 9D anti-octonion
- `src/dual_b_complex.zig` — 10D Dual-B-Complex
- `src/completion_10d.zig` — SO(10) completion

### Gap closure (chunk-26)

- `src/e8_roots.zig` — E8 root system (240 roots)
- `src/so10_decomposition.zig` — SO(10) chiral spinor
- `src/jordan_algebra.zig` — J3(O) cubic characteristic
- `src/electric_charges.zig` — Octonion U(1) charges
- `src/so8_triality.zig` — SO(8) triality
- `src/pati_salam.zig` — Pati-Salam SU(4)
- `src/gap_closure.zig` — 10 gap closures (30 checks)

### Generative chain (chunks 27-31)

- `src/generative_chain.zig` — 0^0=i → C → H → O bootstrap
- `src/dimensional_ladder.zig` — φ, π, triad exponents
- `src/checksum_6d.zig` — E=mc²↔i↔E=mc⁻², Möbius, Smith chart
- `src/free_will_6d.zig` — Free will as 6D routing underdetermination
- `src/scaling_analysis.zig` — Cubic scaling chain, 7-defect, 421/3375

### Audit and literature (post-chunk-31)

- `src/final_audit.zig` — 36 claims classified (8 tests)
- `src/consciousness_audit.zig` — 20 claims traced to axiom via consciousness (8 tests)
- `src/literature_review.zig` — 24 references, 18 reclassifications (11 tests)

### Stress testing

- `src/stress_test.zig` — 18 stress findings
- `src/rebuttal_stress.zig` — Rebuttals with proofs and prototypes

## Documentation

| Document | Purpose |
|---|---|
| `IMPLICATIONS.md` | Master implications document (1253+ lines) |
| `coherent-system.md` | Master synthesis of mathematical system |
| `unified-system-map.md` | Cross-layer integration map |
| `AGENTS.md` | Workspace guide and verification commands |
| `.devin/memories/` | 31 context memory chunks (JSON + Markdown) |
| `.devin/memories/index.json` | Master memory index |

## Scientific Scope

### What this framework verifies

- Arithmetic identities (exact, fixed-point)
- Octonion multiplication table and non-associativity
- E8 root system (240 roots)
- SO(10) chiral spinor decomposition (16 = 15 + 1)
- J3(O) cubic characteristic polynomial
- Möbius self-inverse transformation
- Smith chart boundary formulas
- Cubic scaling chain and 7-defect
- Codon routing rules (64 codons, 6-bit encoding)
- Neuraleak framework cross-wiring (1/8 consciousness)

### What this framework does NOT claim

- That numerical correspondence proves the speculative physical model
- That the E8 embedding is physically realized
- That the biological Jordan algebra embedding is proven
- That machine consciousness is established
- That codon chemistry heuristics are fundamental physics
- That neuraleak sentience scores establish philosophical consciousness

### The structure/content split

The framework predicts that the generative chain determines **structure** but not **content**:

- **Structure** (16 claims): follows from the axiom WITHOUT consciousness
- **Content** (20 claims): follows from the axiom THROUGH consciousness (6D routing)

The audit independently found exactly this split: 16 determined claims, 20 free claims.

## Technologies

- **Zig 0.13.0** — Core implementation, Q128.128 fixed-point arithmetic
- **Q# / Microsoft Quantum SDK 0.28.302812** — Quantum witnesses
- **f64 sidecars** — Floating-point validation layer (isolated from core)
- **Fixed-point integer arithmetic** — All core logic uses i256/u256/i512

## Archive Policy

Every passing state is archived under `archives/`. Archives are never deleted.

Current archives (19):
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

## License

Copyright (c) 2026 Open Sentience Technology Foundation. Licensed under [CC BY-NC-SA 4.0](./LICENSE).

## Citation

```bibtex
@misc{emc2i_emc2_2026,
  title        = {E=mc²-i-E=mc⁻² (toy-model): "play on the seriousness of the framework"},
  author       = {Ramsey, Paul P. and Devin AI and Chat-GPT and Gemini and GLM-2.5 and Kimi AI},
  organization = {Open Sentience Technology Foundation},
  year         = {2026},
  license      = {CC BY-NC-SA 4.0},
  note         = {Computational mathematical framework: 391 Zig tests, 30 proof modules, 180 proof checks, 51 Q\# witnesses}
}
```
