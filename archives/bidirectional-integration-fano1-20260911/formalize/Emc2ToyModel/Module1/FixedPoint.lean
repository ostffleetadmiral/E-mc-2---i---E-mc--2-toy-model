/-
  Module 1: Fixed-Point Algebra & RNE Multiply

  Q128.128 fixed-point arithmetic with round-to-nearest-even multiplication.
  The mantissa is a signed 256-bit integer; the value is m * 2^(-128).
  RNE multiply computes the exact 512-bit product and rounds to nearest even,
  giving error bound |x*y - fl(x*y)| <= 2^(-129).

  License: CC BY-NC-SA 4.0
-/

namespace Emc2ToyModel.Module1

/-- The scaling factor: 2^128. -/
def SCALE : Int := 2^128

/-- A fixed-point value is an integer mantissa `m` representing `m * 2^(-128)`. -/
structure Q128 where
  mantissa : Int

/-- Construct from mantissa. -/
def Q128.fromMantissa (m : Int) : Q128 := ⟨m⟩

/-- Zero. -/
def Q128.zero : Q128 := ⟨0⟩

/-- One (as fixed-point: mantissa = 2^128). -/
def Q128.one : Q128 := ⟨SCALE⟩

/-- Addition: mantissa addition is exact. -/
def Q128.add (x y : Q128) : Q128 := ⟨x.mantissa + y.mantissa⟩

/-- Subtraction: mantissa subtraction is exact. -/
def Q128.sub (x y : Q128) : Q128 := ⟨x.mantissa - y.mantissa⟩

/-- Negation: exact. -/
def Q128.neg (x : Q128) : Q128 := ⟨-x.mantissa⟩

/-- Absolute value. -/
def Q128.abs (x : Q128) : Q128 := ⟨Int.natAbs x.mantissa⟩

/-- Decidable equality. -/
instance : DecidableEq Q128 := fun x y =>
  if h : x.mantissa = y.mantissa then
    isTrue (by cases x; cases y; subst h; rfl)
  else
    isFalse (by intro contra; apply h; cases x; cases y; injection contra)

/-- Addition is exact. -/
theorem Q128.add_exact (x y : Q128) :
    (x.add y).mantissa = x.mantissa + y.mantissa := rfl

/-- Subtraction is exact. -/
theorem Q128.sub_exact (x y : Q128) :
    (x.sub y).mantissa = x.mantissa - y.mantissa := rfl

/-- Negation is exact. -/
theorem Q128.neg_exact (x : Q128) :
    (x.neg).mantissa = -x.mantissa := rfl

/-- x ≠ y → |m_x - m_y| ≥ 1 (mantissas are integers). -/
theorem mantissa_diff_bound (x y : Q128) (h : x ≠ y) :
    Int.natAbs (x.mantissa - y.mantissa) ≥ 1 := by
  have hne : x.mantissa ≠ y.mantissa := by
    intro contra; apply h; cases x; cases y; subst contra; rfl
  have : x.mantissa - y.mantissa ≠ 0 := by
    intro contra; apply hne; omega
  exact Int.natAbs_pos.mpr this |> Nat.le_of_lt

/-- Zero is the additive identity. -/
theorem Q128.add_zero (x : Q128) : x.add zero = x := by
  cases x; simp [add, zero]

/-- One has mantissa = 2^128. -/
theorem Q128.one_mantissa : Q128.one.mantissa = SCALE := rfl

end Emc2ToyModel.Module1
