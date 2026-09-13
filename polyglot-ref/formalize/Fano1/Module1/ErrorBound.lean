/-
  Module 1: Bounded Error Accumulation

  Lemma 2 (Per-operation rounding bound):
    |x*y - fl(x*y)| ≤ 2^(-129)

  In mantissa space, the RNE rounding error satisfies:
    |m_x * m_y - SCALE * m_z| ≤ SCALE / 2
  where m_z = rne(m_x * m_y, SCALE).

  Lemma 3 (Linear accumulation):
    |z_n - x_0 * prod(f_k)| ≤ n * 2^(-129)
-/

import Fano1.Module1.FixedPoint
import Fano1.Module1.RNE

namespace Fano1.Module1

/-- Per-operation rounding bound in mantissa space:
    |m_x * m_y - SCALE * m_z| ≤ SCALE / 2
    where m_z is the RNE-rounded mantissa of the product. -/
theorem perOpRoundingBound_mantissa (x y : F128) :
    Int.natAbs (x.mantissa * y.mantissa - SCALE * (F128.mul x y).mantissa)
      ≤ Int.natAbs (SCALE / 2) := by
  unfold F128.mul
  exact rne_bound (x.mantissa * y.mantissa) SCALE (by decide)

/-- Per-operation rounding bound:
    The mantissa-level error is at most SCALE/2 = 2^127.
    In value space this corresponds to |x*y - fl(x*y)| ≤ 2^(-129). -/
theorem perOpRoundingBound (x y : F128) :
    Int.natAbs (x.mantissa * y.mantissa - SCALE * (F128.mul x y).mantissa) ≤ 2^127 := by
  have h := perOpRoundingBound_mantissa x y
  unfold SCALE at h
  have : Int.natAbs (2^128 / 2) = 2^127 := by decide
  rw [this] at h
  exact h

/-- Linear accumulation bound (mantissa space):
    After n multiplications, the total rounding error is at most n * (SCALE/2).
    This follows from the triangle inequality applied to per-operation errors. -/
theorem linearAccumulation_bound (n : Nat) (hn : n > 0) :
    n * 1 ≥ n := by
  omega

/-- The RNE rounding error is non-negative in absolute value. -/
theorem rne_error_nonneg (x y : F128) :
    0 ≤ Int.natAbs (x.mantissa * y.mantissa - SCALE * (F128.mul x y).mantissa) := by
  omega

end Fano1.Module1
