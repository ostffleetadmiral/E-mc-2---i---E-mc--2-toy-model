# Chunk 20: Two-Layer Architecture

**Source:** `x.md` lines 860–926
**Category:** architecture
**Status:** established

---

## Concepts Extracted

- **Two-layer architecture**: Layer 1 = triad generation, Layer 2 = Möbius/Smith transformation
- **Symbolic chain**: T(a,b,c) → Z → Γ → α
- **Nonlinear operation**: α = Z_0/(2R_K) is not addition of three powers — it's a nonlinear operation on generated impedance states
- **Exponent subtraction failure explained**: The failure of simple exponent subtraction is a clue that the wrong algebraic operation was being used
- **Richer architecture**: This is much richer than searching (a,b,c) until a number is close

---

## Mathematical Structure

### Layer 1: Triad Generation
$$ T(a, b, c) = \phi^a + \pi^b + \phi^c $$

### Layer 2: Möbius/Smith Transformation
$$ \Gamma = \frac{z - 1}{z + 1} $$

### Full Chain
$$ \boxed{T(a, b, c) \rightarrow Z \rightarrow \Gamma \rightarrow \alpha} $$

### Why Exponent Subtraction Fails

Table entries:
$$ Z_0: (8, 2, 12) $$
$$ R_K: (15, -20, 21) $$
$$ \alpha: (-13, -7, -11) $$

If the triad operator were a closed arithmetic representation, we might expect α exponents to be simple subtraction of Z_0 and R_K exponents. They aren't.

Because:
$$ \alpha = \frac{Z_0}{2R_K} $$

is **not** addition of three powers. It's a **nonlinear operation** on the generated impedance states.

The Smith chart explicitly tells us the relevant operation is Möbius:
$$ \Gamma = \frac{z - 1}{z + 1} $$

---

## Key Results

1. The architecture has **two layers**: triad generation (Layer 1) + Möbius transformation (Layer 2)
2. The failure of simple exponent subtraction is **explained**: α = Z_0/(2R_K) is nonlinear, not additive
3. The Smith chart tells us the correct operation is the Möbius transformation Γ = (z-1)/(z+1)
4. This is a **much richer architecture** than simply searching (a,b,c) until a number is close
5. The triad expression φ^a+π^b+φ^c is **one layer** of the algebra, not the whole algebra

---

## Cross-References

- **chunk-03**: The triad operator is Layer 1 of this architecture
- **chunk-18**: The Smith chart/Möbius transformation is Layer 2
- **chunk-19**: The fine-structure derivation demonstrates this chain in action
- **chunk-21**: The EM over-constraint chain extends this to the full constant family

---

## Open Questions

- Can the two-layer architecture be extended to three layers (triad → Möbius → QED correction)?
- What other constants require the Möbius layer vs direct triad evaluation?
- Is there a systematic criterion for determining which layer a constant belongs to?
