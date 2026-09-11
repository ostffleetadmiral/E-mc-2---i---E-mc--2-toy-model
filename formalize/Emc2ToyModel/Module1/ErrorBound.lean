/-
  Module 1: Error Bound for RNE Multiply

  The RNE multiply guarantees |x*y - fl(x*y)| <= 2^(-129),
  which is half a ULP (unit in the last place).

  License: CC BY-NC-SA 4.0
-/

namespace Emc2ToyModel.Module1

/-- The ULP (unit in the last place) is 2^(-128). -/
def ULP : Int := 1

/-- Half ULP is 2^(-129), represented as 2^127 in mantissa space. -/
def HALF_ULP : Int := 2^127

/-- The error bound for RNE multiply: at most half a ULP. -/
theorem rne_half_ulp_bound :
    ∀ (x y : Q128),
    Int.natAbs (x.mantissa * y.mantissa - (x.mulRNE y).mantissa * SCALE) ≤ HALF_ULP := by
  sorry

/-- The error bound for truncating multiply: at most one ULP. -/
theorem trunc_one_ulp_bound :
    ∀ (x y : Q128),
    Int.natAbs (x.mantissa * y.mantissa - (x.mulTrunc y).mantissa * SCALE) < SCALE := by
  sorry

/-- RNE is strictly better than truncation for halfway cases. -/
theorem rne_strictly_better_halfway :
    ∀ (x y : Q128),
    discardedBits (x.mantissa * y.mantissa) = HALFWAY →
    truncDiv (x.mantissa * y.mantissa) % 2 = 1 →
    Int.natAbs (x.mantissa * y.mantissa - (x.mulRNE y).mantissa * SCALE) <
    Int.natAbs (x.mantissa * y.mantissa - (x.mulTrunc y).mantissa * SCALE) := by
  sorry

end Emc2ToyModel.Module1
