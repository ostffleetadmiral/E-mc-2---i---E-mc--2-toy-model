# Retrograde Layer 6: External Systems Archive

**Date:** 2026-09-12
**Phase:** 7 (Layer 6 — External systems)

## Components Reverse Engineered

### Q# Quantum Witnesses (6 files)
- **Upgrade:** .NET 6.0 → .NET 8.0 (resolved EOL warning)
- **Result:** 0 warnings, 0 errors, all 51 witness operations pass
- **Files:** Foundation.qs, PhysicalProofs.qs, CodonProofs.qs, NeuraleakProofs.qs, QuantumTests.qs, Program.qs

### Sidecar f64 Validation (10 files)
- **verify_em_chain.zig:** 1 → 7 tests (+6)
  - Added: alphaFromImpedance formula verification, alpha ≈ 1/137, 
    gammaFromAlpha uses self-inverse Möbius form, self-inverse property,
    boundary values Γ(0)=1, Γ(0.5)=0
  - Note: gammaFromAlpha uses (1-2α)/(1+2α) = (1-z)/(1+z) — self-inverse form ✓
- **verify_triad.zig:** 2 → 7 tests (+5)
  - Added: triad(0,0,0)=3, symmetry a↔c, triad(1,0,0)=φ+2, triad(0,1,0)=π+2, triad(-1,0,0)=1/φ+2
- **Other sidecar files:** verify_codon.zig (10 tests), verify_constants.zig (3 tests), 
  verify_neuraleak.zig (20 tests) — all adequate, no changes needed

### WASM Build (3 files)
- **Status:** Builds successfully, produces emc2-proofs.wasm (598KB)
- **No changes needed**

### OS Hooks (5 files, 37 tests)
- **neuraleak_qwen_hook.zig:** 3/3 tests pass
- **vulkan_e8_hook.zig:** 5/5 tests pass
- **polyglot_codon_hook.zig:** 5/5 tests pass
- **npu_detect_hook.zig:** 8/8 tests pass
- **npu_neuraleak_hook.zig:** 16/16 tests pass
- **Total:** 37/37 tests pass, no changes needed

### Lean 4 Formalization (10 files)
- **Status:** Lean not installed on this system — cannot verify
- **Files:** FixedPoint.lean, RNE.lean, ErrorBound.lean, FanoPlane.lean, 
  Octonion.lean, E8Roots.lean, SO10.lean, Scaling.lean, All.lean, lakefile.lean
- **Action:** Documented as pending — requires Lean installation to verify

## Test Results
- Sidecar: 49 tests pass (was 36, +13)
- Q#: 51 witness operations pass (0 warnings, 0 errors on .NET 8.0)
- OS hooks: 37/37 tests pass
- WASM: builds successfully
- Lean: pending (not installed)
- Core Zig: 502 tests pass, 30/30 proof modules pass
