/-
  Module 1: Computational Verification

  Executable checks that validate the theorems of Module 1
  against concrete values.
-/

import Fano1.Module1.FixedPoint
import Fano1.Module1.RNE
import Fano1.Module1.FloorInvariance
import Fano1.Module1.ErrorBound
import Fano1.Module1.Orthogonality

namespace Fano1.Module1

/-- Verify floor invariance: zero and one ULP differ by exactly 1 in mantissa space. -/
example : Int.natAbs (F128.zero.mantissa - (F128.fromMantissa 1).mantissa) ≥ 1 :=
  subPlanckFloorInvariance F128.zero (F128.fromMantissa 1) (by decide)

/-- Verify floor bound attainment: |0 - 1| = 1. -/
example : Int.natAbs (F128.zero.mantissa - (F128.fromMantissa 1).mantissa) = 1 :=
  floorBoundAttained

/-- Verify zero cancellation: subtraction is exact. -/
example : (F128.zero.sub (F128.fromMantissa 1)).mantissa =
            F128.zero.mantissa - (F128.fromMantissa 1).mantissa :=
  zeroCancellation F128.zero (F128.fromMantissa 1)

/-- Verify RNE of 3/2 = 2 (round to even). -/
example : rne 3 2 (by decide) = 2 := by decide

/-- Verify RNE of 5/2 = 2 (round to even, since 2 is even). -/
example : rne 5 2 (by decide) = 2 := by decide

/-- Verify RNE of 7/2 = 4 (round to even, since 4 is even). -/
example : rne 7 2 (by decide) = 4 := by decide

/-- Verify RNE of 1/4 = 0 (round down). -/
example : rne 1 4 (by decide) = 0 := by decide

/-- Verify RNE of 3/4 = 1 (round up). -/
example : rne 3 4 (by decide) = 1 := by decide

/-- Verify RNE of 2/4 = 0 (round to even, tie at 1, 0 is even). -/
example : rne 2 4 (by decide) = 0 := by decide

/-- Verify RNE of 6/4 = 2 (round to even, tie at 1, 1 is odd so round to 2). -/
example : rne 6 4 (by decide) = 2 := by decide

/-- Verify per-operation rounding bound for small values. -/
example : Int.natAbs (F128.one.mantissa * (F128.fromMantissa 1).mantissa -
            SCALE * (F128.one.mul (F128.fromMantissa 1)).mantissa) ≤ 2^127 :=
  perOpRoundingBound F128.one (F128.fromMantissa 1)

/-- Verify 90-degree rotation preserves inner product. -/
example : (Vec2.rotate ⟨1, 0⟩).dot (Vec2.rotate ⟨0, 1⟩) = (⟨1, 0⟩ : Vec2).dot ⟨0, 1⟩ :=
  orthogonalityPreservation ⟨1, 0⟩ ⟨0, 1⟩

/-- Verify orthogonality preservation with zero inner product. -/
example : (Vec2.rotate ⟨1, 0⟩).dot (Vec2.rotate ⟨0, 1⟩) = 0 :=
  orthogonalityPreservation_zero ⟨1, 0⟩ ⟨0, 1⟩ (by decide)

end Fano1.Module1
