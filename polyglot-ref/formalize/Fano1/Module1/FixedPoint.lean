/-
  Module 1: Fixed-Point Algebra & I256 Numerical Stability

  F_128.128 is the set of signed 256-bit fixed-point numbers with 128
  fractional bits.  We model the *scaled mantissa* as an integer `m`,
  where the actual value is `m * 2^(-128)`.

  The ULP (unit in the last place) is `2^(-128)`.
-/

namespace Fano1.Module1

/-- The scaling factor: 2^128. -/
def SCALE : Int := 2^128

/-- A fixed-point value is an integer mantissa `m` representing `m * 2^(-128)`. -/
structure F128 where
  mantissa : Int

/-- Construct from mantissa. -/
def F128.fromMantissa (m : Int) : F128 := ⟨m⟩

/-- Zero. -/
def F128.zero : F128 := ⟨0⟩

/-- One (as fixed-point: mantissa = 2^128). -/
def F128.one : F128 := ⟨SCALE⟩

/-- Addition: mantissa addition is exact. -/
def F128.add (x y : F128) : F128 := ⟨x.mantissa + y.mantissa⟩

/-- Subtraction: mantissa subtraction is exact. -/
def F128.sub (x y : F128) : F128 := ⟨x.mantissa - y.mantissa⟩

/-- Negation: exact. -/
def F128.neg (x : F128) : F128 := ⟨-x.mantissa⟩

/-- Decidable equality. -/
instance : DecidableEq F128 := fun x y =>
  if h : x.mantissa = y.mantissa then
    isTrue (by cases x; cases y; subst h; rfl)
  else
    isFalse (by intro contra; apply h; cases x; cases y; injection contra)

/-- Addition is exact: the mantissa of (x + y) equals m_x + m_y. -/
theorem F128.add_exact (x y : F128) :
    (x.add y).mantissa = x.mantissa + y.mantissa := rfl

/-- Subtraction is exact: the mantissa of (x - y) equals m_x - m_y. -/
theorem F128.sub_exact (x y : F128) :
    (x.sub y).mantissa = x.mantissa - y.mantissa := rfl

/-- Negation is exact. -/
theorem F128.neg_exact (x : F128) :
    (x.neg).mantissa = -x.mantissa := rfl

/-- x ≠ y → |m_x - m_y| ≥ 1 (mantissas are integers). -/
theorem mantissa_diff_bound (x y : F128) (h : x ≠ y) :
    Int.natAbs (x.mantissa - y.mantissa) ≥ 1 := by
  have hne : x.mantissa ≠ y.mantissa := by
    intro contra
    apply h
    cases x; cases y; subst contra; rfl
  have : x.mantissa - y.mantissa ≠ 0 := by
    intro contra
    apply hne
    omega
  have : Int.natAbs (x.mantissa - y.mantissa) > 0 := by
    exact Int.natAbs_pos.mpr this
  omega

end Fano1.Module1
