/-
  Module 1: Sub-Planck Floor Invariance

  Theorem 1: For any x, y ∈ F_128.128 with x ≠ y,
  |x - y| ≥ 2^(-128), and the bound is attained.

  In mantissa space: |m_x - m_y| ≥ 1 (since mantissas are integers).
-/

import Fano1.Module1.FixedPoint

namespace Fano1.Module1

/-- Sub-Planck Floor Invariance: distinct fixed-point values differ by at least one ULP.
    In mantissa space, |m_x - m_y| ≥ 1 when x ≠ y. -/
theorem subPlanckFloorInvariance (x y : F128) (h : x ≠ y) :
    Int.natAbs (x.mantissa - y.mantissa) ≥ 1 :=
  mantissa_diff_bound x y h

/-- The floor bound is attained: m_x = 0, m_y = 1 gives |Δ| = 1 (one ULP). -/
theorem floorBoundAttained :
    Int.natAbs (F128.zero.mantissa - (F128.fromMantissa 1).mantissa) = 1 := by
  decide

/-- Zero cancellation: fl(x - y) = x - y exactly (mantissa subtraction is exact). -/
theorem zeroCancellation (x y : F128) :
    (x.sub y).mantissa = x.mantissa - y.mantissa :=
  F128.sub_exact x y

end Fano1.Module1
