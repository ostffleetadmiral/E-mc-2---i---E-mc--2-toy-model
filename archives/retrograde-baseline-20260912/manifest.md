# Retrograde Development Baseline Archive

**Date:** 2026-09-12
**Commit:** ce409b9 (Peer review fixes: correct Möbius formula, AI authorship, 17 issues)
**Tag:** v1.0.0

## Baseline Test Results

### Zig Core
- `zig build test`: ALL PASS (440+ tests)
- `zig build run`: 30/30 proof modules passed (180 checks total)
  - chunk-01 through chunk-31 (22 chunks + 8 extension chunks)
  - All 180 proof checks pass with 0 failures

### Q# Witnesses
- `dotnet build && dotnet run`: ALL PASS (51 witness operations)
  - Foundation: 5 witnesses
  - Physical: 4 witnesses
  - Codon: 6 witnesses
  - Neuraleak: 13 witnesses
  - 10D completion: 13 witnesses
  - All quantum proof suite completed

### Sidecar (f64 validation)
- `zig build test && zig build run`: ALL PASS
  - Constants validation
  - Codon validation (16 tests)
  - Neuraleak validation (10 tests)
  - EM chain validation
  - Triad validation
  - CODATA values
  - 10D completion validation

### FANO-1 OS Hooks (37 tests)
- `os/neuraleak_qwen_hook.zig`: 3/3 PASS
- `os/vulkan_e8_hook.zig`: 5/5 PASS
- `os/polyglot_codon_hook.zig`: 5/5 PASS
- `os/npu_detect_hook.zig`: 8/8 PASS
- `os/npu_neuraleak_hook.zig`: 16/16 PASS

### WASM
- `wasm/zig build`: BUILD OK
- Output: `zig-out/bin/emc2-proofs.wasm`

### Lean 4
- 8 formalization modules (not compiled in this baseline)

## Known Issues (to fix during retrograde)

1. **Möbius formula inconsistency:**
   - Code uses (z-1)/(z+1) — standard Smith chart, NOT self-inverse
   - Papers use (1-z)/(1+z) — self-inverse, NOT standard Smith chart
   - Resolution: SPLIT — both formulas for their correct purposes

2. **final_audit.zig claim 14:** "Möbius Γ=(z-1)/(z+1) is self-inverse" marked PROVEN but is WRONG
   - Γ(Γ(z)) = -1/z, not z
   - Need to split into 14a (Smith chart inverse) and 14b (Möbius self-inverse)

3. **Q# .NET version:** May need upgrade from .NET 6 to .NET 8

4. **Test coverage:** Need to verify ≥101% coverage per global rules

## File Counts (Baseline)
- Zig source: 78 files (14,055 lines)
- Q# files: 6 files (551 lines)
- Sidecar: 10 files (819 lines)
- Lean 4: 10 files
- OS hooks: 5 files
- WASM: 1 file (3,482 bytes)
- Papers: 4 papers (4 .tex + 4 .bib + 4 .pdf)
- Archives: 21 existing (never delete)
- Documentation: 9 .md files
