# Chunk 10: Error Structure & Exponent Recurrence

**Source:** `x.md` lines 385–432
**Category:** error-analysis
**Status:** established

---

## Concepts Extracted

- **Error structure as signal**: The pattern of errors is more informative than exact matches
- **Exponent recurrence**: The same (a,b,c) triples appear across physically related constants
- **Discrete lattice**: The model produces a discrete lattice of candidate values, not continuous fitting
- **Structural recurrence**: More meaningful than merely finding a close number
- **Dimensional tracking**: Some constants track closely despite spanning enormous orders of magnitude

---

## Mathematical Structure

### Example: Proton Magnetic Moment
$$ \mu_p: (-143,-52,-136) \rightarrow 1.4106285 \times 10^{-26} $$

vs.

$$ 1.4106068 \times 10^{-26} $$

Error: $1.54 \times 10^{-3}\%$

### Example: Rydberg Constant
$$ R_\infty: (29,14,28) \rightarrow 10\,982\,669.18 \text{ m}^{-1} $$

vs.

$$ 10\,973\,731.568 \text{ m}^{-1} $$

Error: $0.0814\%$

### Recurring Signatures

$$ (-7,-2,-5) $$

appears for CKM $V_{us}$, $V_{cb}$-related structures, and the fine-structure region.

$$ (-13,0,0) $$

appears for both electron and muon $g$-factors.

---

## Key Results

1. Several quantities are within $10^{-2}\%$; many more within $10^{-1}\%$
2. The same exponents recur across physically related quantities — this is potentially much more meaningful than close numbers
3. The model produces a discrete lattice of candidate values from integer triples, not continuous fitting
4. Some dimensional constants track surprisingly closely despite spanning enormous orders of magnitude

---

## Cross-References

- **chunk-09**: The full constants table provides the source data for this analysis
- **chunk-11**: The (-13,0,0) g-factor recurrence is analyzed in detail, revealing the QED correction hierarchy
- **chunk-22**: Test G (statistical null test) is designed to distinguish structural results from fitting flexibility

---

## Open Questions

- Is the recurrence of (-7,-2,-5) across CKM/α region physically significant or coincidental?
- Does the discrete lattice structure contain information beyond the flexibility of the exponent space?
- What determines which constants share the same signature?
