# Retrograde Layer 2: Möbius Fix Archive

**Date:** 2026-09-12
**Phase:** 3 (Layer 2 — Second dependencies)
**Critical fix:** Resolved Möbius formula inconsistency between code and papers

## The Problem

The code and papers were inconsistent:
- **Papers (fixed in peer review):** Γ(z) = (1-z)/(1+z), self-inverse ✓
- **Code (original):** Γ(z) = (z-1)/(z+1), NOT self-inverse (Γ(Γ(z)) = -1/z) ✗

The code claimed self-inverse in comments and tests, but used the wrong formula.

## The Fix: Split Approach

Both formulas are correct for their respective purposes:

1. **Self-inverse checksum** (checksum_6d.zig): Γ(z) = (1-z)/(1+z)
   - Γ(Γ(z)) = z ✓ (self-inverse)
   - Used for E=mc² ↔ E=mc⁻² round-trip checksum
   - Boundaries: Γ(0)=1, Γ(1)=0, Γ(∞)=-1

2. **Smith chart operations** (smith.zig, codon.zig): Γ(z) = (z-1)/(z+1)
   - Standard electrical engineering formula
   - NOT self-inverse (Γ(Γ(z)) = -1/z)
   - Used for impedance matching
   - Boundaries: Γ(0)=-1, Γ(1)=0, Γ(∞)=+1

## Files Changed

### src/checksum_6d.zig
- Added `mobiusSelfInverse(z)` function implementing (1-z)/(1+z)
- Rewrote `verifyMobiusSelfInverse()` to actually test Γ(Γ(z)) ≈ z
- Updated all comments from (z-1)/(z+1) to (1-z)/(1+z) for self-inverse
- Added 3 new tests: Γ(0)=1, Γ(1)=0, Γ(Γ(z))≈z

### src/final_audit.zig
- Split claim 14 into:
  - 14: "Self-inverse Möbius Γ=(1-z)/(1+z): Γ(Γ(z))=z" — PROVEN
  - 15: "Smith chart Γ=(z-1)/(z+1): Γ(0)=-1, Γ(1)=0, Γ(∞)=+1" — PROVEN

### src/rebuttal_stress.zig
- Updated C3 rebuttal to use (1-z)/(1+z) for self-inverse claim
- Updated explanation to distinguish Smith chart from self-inverse

## Test Results
- All 472 tests pass (was 460+)
- 30/30 proof modules pass (180 checks)
- Zero regressions
- Möbius self-inverse now VERIFIED with actual Γ(Γ(z))=z computation
