/-
  Module 1: Round-to-Nearest-Even (RNE) Multiply

  RNE multiplication computes the exact 512-bit product and rounds
  to nearest even, giving error bound |x*y - fl(x*y)| <= 2^(-129).

  The rounding rule:
    - If discarded < halfway: round down (truncate)
    - If discarded > halfway: round up
    - If discarded == halfway: round to even (round up iff LSB is 1)

  License: CC BY-NC-SA 4.0
-/

namespace Emc2ToyModel.Module1

open Emc2ToyModel.Module1

/-- The halfway value: 2^127. -/
def HALFWAY : Int := 2^127

/-- The low-bit mask: 2^128 - 1. -/
def LOW_MASK : Int := 2^128 - 1

/-- Truncated product: floor(product / 2^128). -/
def truncDiv (product : Int) : Int := product / SCALE

/-- Discarded low bits: product mod 2^128. -/
def discardedBits (product : Int) : Int := product % SCALE

/-- Round bit: bit 127 of the product. -/
def roundBit (product : Int) : Bool :=
  (discardedBits product / HALFWAY) = 1

/-- Sticky bits: any bit 0..126 is set. -/
def stickyBits (product : Int) : Bool :=
  (discardedBits product % HALFWAY) ≠ 0

/-- RNE rounding: round up iff (round_bit AND (sticky OR lsb)). -/
def rneRoundUp (product : Int) (truncated : Int) : Bool :=
  roundBit product && (stickyBits product || (truncated % 2 = 1))

/-- RNE multiply: exact product then round to nearest even. -/
def Q128.mulRNE (x y : Q128) : Q128 :=
  let product := x.mantissa * y.mantissa
  let truncated := truncDiv product
  if rneRoundUp product truncated then
    ⟨truncated + 1⟩
  else
    ⟨truncated⟩

/-- Truncating multiply (old behavior, for comparison). -/
def Q128.mulTrunc (x y : Q128) : Q128 :=
  ⟨truncDiv (x.mantissa * y.mantissa)⟩

/-- RNE rounds up iff round_bit AND (sticky OR lsb). -/
theorem rne_spec (product : Int) (truncated : Int) :
    rneRoundUp product truncated = true ↔
    (discardedBits product ≥ HALFWY) ∧
    (discardedBits product > HALFWAY ∨ truncated % 2 = 1) := by
  sorry

/-- RNE error bound: |x*y - fl(x*y)| <= 2^(-129) (half ULP). -/
theorem rne_error_bound (x y : Q128) :
    Int.natAbs (x.mantissa * y.mantissa - (x.mulRNE y).mantissa * SCALE) ≤ HALFWAY := by
  sorry

/-- RNE is at least as accurate as truncation. -/
theorem rne_better_than_trunc (x y : Q128) :
    Int.natAbs (x.mantissa * y.mantissa - (x.mulRNE y).mantissa * SCALE) ≤
    Int.natAbs (x.mantissa * y.mantissa - (x.mulTrunc y).mantissa * SCALE) := by
  sorry

end Emc2ToyModel.Module1
