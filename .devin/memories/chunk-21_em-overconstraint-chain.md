# Chunk 21: EM Family Over-Constraint Chain

**Source:** `x.md` lines 928–1016
**Category:** over-constraint
**Status:** established

---

## Concepts Extracted

- **Full derivation chain**: From primitive lattice outputs through EM closure to atomic/QED constants
- **Zero-free-parameter test**: One set of primitive lattice outputs generates entire network without refitting
- **Derived α test**: Using table's independently assigned Z_0 and R_K gives α_derived with +0.456% error
- **Table doesn't close yet**: The primitive outputs need propagation through the correct transformation
- **c and ℏ correction**: Scaling relations ≠ numerical derivation; need normalization/closure mechanism
- **Smith-chart normalization**: May be part of the missing mechanism for c and ℏ numerical values

---

## Mathematical Structure

### Full Derivation Chain
$$ \boxed{e_0/e_7 \rightarrow Z_0 \rightarrow R_K \rightarrow \Gamma \rightarrow \alpha} $$

### EM Constants from Z_0 and R_K
$$ G_0 = \frac{2}{R_K} $$
$$ K_J = \frac{2e}{h} $$
$$ \mu_0 = \frac{Z_0}{c} $$
$$ \epsilon_0 = \frac{1}{Z_0 c} $$
$$ \alpha = \frac{Z_0}{2R_K} $$

### Atomic Quantities from α
$$ R_\infty = \frac{\alpha}{4\pi a_0} $$
$$ r_e = \alpha^2 a_0 $$
$$ \sigma_T = \frac{8\pi}{3} r_e^2 $$

### Derived α Test (from table values)
$$ \alpha_{\text{derived}} = \frac{378.8452125448}{2(25840.000774)} $$

$$ \boxed{\alpha_{\text{derived}} = 0.0073305960} $$

$$ \boxed{+0.456\%} \text{ from measured } \alpha $$

### c and ℏ Scaling Relations
$$ t(N) \propto N^{-1}, \quad l(N) \propto N^{-1}, \quad E(N) \propto N^{-2} $$

These imply cancellation of certain powers of N, but do **not** by themselves produce numerical values of c or ℏ.

### Structural vs Numerical Derivation
- **Structural derivation**: power of N cancels
- **Numerical derivation**: $c = 299\,792\,458$ m/s

The latter needs the actual normalization/closure mechanism.

---

## Key Results

1. The full EM/atomic derivation chain is defined: one α → entire family of constants
2. Using the table's independently assigned Z_0 and R_K: α_derived = 0.0073305960, +0.456% error
3. **The table by itself does not yet constitute a closed theory** — the Smith-chart operation is needed
4. Primitive outputs need to be propagated through the correct transformation, not compared as independent scalars
5. c and ℏ: scaling relations are established but numerical values require a normalization/closure mechanism
6. The Smith-chart normalization may be part of that missing mechanism

---

## Cross-References

- **chunk-05**: The CODATA propagation hierarchy (α-power family)
- **chunk-07**: CODATA consistency relationships (R_∞, a_0 formulas)
- **chunk-09**: The constants table provides the Z_0 and R_K entries
- **chunk-19**: The Smith chart derivation α = Z_0/(2R_K) is the correct operation
- **chunk-22**: Tests D (EM closure) and E (atomic closure) formalize this chain

---

## Open Questions

- Can the lattice generate Z_0 and R_K accurately enough that the derived α closes within experimental precision?
- Does the Smith-chart normalization provide the missing mechanism for c and ℏ?
- How many independent constraints does the full EM/atomic chain provide?
- Can the chain be extended to QED corrections (g-2)?
