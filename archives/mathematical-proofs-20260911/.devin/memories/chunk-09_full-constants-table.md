# Chunk 09: Full Constants Table

**Source:** `x.md` lines 237–382
**Category:** constants-table
**Status:** established

---

## Concepts Extracted

- **Comprehensive triad fitting**: ~145 physical constants each assigned an integer triple (a,b,c)
- **Triad operator application**: T(a,b,c) = φ^a + π^b + φ^c evaluated for each constant
- **Discrete lattice**: The model produces a discrete lattice of candidate values, not continuous fitting
- **Multi-category coverage**: nuclear, particle, atomic, cosmology, QCD, QED, EM, electroweak, thermo, astro, planck, mixing, neutrino, derived, mound
- **Error spectrum**: Ranging from 0.0015% to 2.7%, with several constants within 10^-2%

---

## Mathematical Structure

### Operator
$$ T(a,b,c) = \phi^a + \pi^b + \phi^c $$

### Error Formula
$$ \text{Error\%} = \frac{\text{Triad\_Value} - \text{Target}}{\text{Target}} \times 100 $$

### Top 10 Best Fits

| Constant | (a,b,c) | Error% |
|---|---|---|
| Proton Magnetic Moment (μ_p) | (-143,-52,-136) | 0.00154% |
| Neutron-to-Proton Mass Ratio | (-18,0,-14) | -0.00191% |
| Hydrogen Line Wavelength (21cm) | (5,2,-4) | -0.00209% |
| Dark Energy Density (Ω_Λ) | (-7,-3,-1) | 0.00400% |
| QCD Scale Parameter (Λ_QCD) | (6,-3,11) | -0.00850% |
| Muon Magnetic Moment (μ_μ) | (-136,-51,-130) | 0.01164% |
| Bottom-to-Charm Quark Mass Ratio | (-12,1,-4) | -0.01227% |
| Vacuum Permittivity (ε_0) | (-59,-35,-53) | 0.01350% |
| Optical Depth (τ) | (-16,-3,-8) | -0.01690% |
| Tau-to-Muon Mass Ratio | (-5,2,4) | -0.01857% |

### Notable Recurring Signatures

| Signature | Constants |
|---|---|
| (-7,-2,-5) | CKM V_us, CKM V_cb, Weak Mixing Angle (on-shell), Cabibbo sin θ_c |
| (-13,0,0) | Electron g-factor, Muon g-factor |
| (-7,-1,-1) | Cabibbo cos θ_c, Scalar Spectral Index, Higgs-to-Top Mass Ratio |
| (13,4,12) | Neutron Mass, Proton Mass |
| (-3,-1,1) | Down-to-Up Quark Mass Ratio, Up Quark Mass |

### Key EM Entries (used in over-constraint chain)

| Constant | (a,b,c) | Triad Value | Error% |
|---|---|---|---|
| Impedance of Free Space (Z_0) | (8,2,12) | 378.845 Ω | 0.561% |
| Von Klitzing Constant (R_K) | (15,-20,21) | 25840.00 Ω | 0.105% |
| Fine-Structure Constant (α) | (-13,-7,-11) | 0.007275 | -0.300% |
| Inverse Fine-Structure (α^-1) | (3,2,10) | 137.098 | 0.045% |

---

## Key Results

1. **Best fit**: Proton Magnetic Moment at 0.00154% error
2. **Hydrogen 21cm**: 0.00209% error — consistent with chunk-03 result
3. **Several within 10^-2%**: μ_p, n/p ratio, H_21, Ω_Λ, Λ_QCD
4. **Exponent recurrence**: Same signatures appear across physically related quantities
5. **EM entries don't close independently**: Z_0 and R_K triad values give α_derived = 0.007331 (0.456% error) — needs Smith chart transformation

---

## Cross-References

- **chunk-03**: Triad operator definition and hydrogen result
- **chunk-10**: Detailed error structure and exponent recurrence analysis
- **chunk-11**: g-factor clue — both g_e and g_μ select (-13,0,0)
- **chunk-21**: EM over-constraint chain uses Z_0 and R_K from this table

---

## Open Questions

- Is the error distribution consistent with random integer search, or does it contain structural information?
- Why do certain signatures recur across physically related constants?
- Can the table be regenerated from the propagation graph without search?
