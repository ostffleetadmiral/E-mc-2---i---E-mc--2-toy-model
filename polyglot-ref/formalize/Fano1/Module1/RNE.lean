/-
  Module 1: Round-to-Nearest-Even (RNE) Multiplication

  The product z = fl(x * y) is computed from the exact 512-bit product
  m_x * m_y by RNE(m_x * m_y / 2^128), where RNE rounds to the nearest
  integer, ties to even.
-/

import Fano1.Module1.FixedPoint

namespace Fano1.Module1

/-- Round-to-nearest-even: round num/denom to the nearest integer,
    breaking ties by choosing the even integer. -/
def rne (num denom : Int) (denom_pos : denom > 0) : Int :=
  let q := num / denom
  let r := num % denom
  if 2 * r < denom then q
  else if 2 * r > denom then q + 1
  else if q % 2 = 0 then q else q + 1

/-- RNE rounds within 1/2 of the exact quotient:
    |num - denom * rne(num, denom)| ≤ denom / 2 -/
theorem rne_bound (num denom : Int) (denom_pos : denom > 0) :
    Int.natAbs (num - denom * rne num denom denom_pos) ≤ Int.natAbs (denom / 2) := by
  have hne : denom ≠ 0 := by omega
  have hr_nonneg : 0 ≤ num % denom := Int.emod_nonneg num hne
  have hr_lt : num % denom < ↑denom.natAbs := Int.emod_lt num hne
  have hr_lt_denom : num % denom < denom := by
    have hdenom : ↑denom.natAbs = denom := Int.ofNat_natAbs_of_nonneg (by omega)
    rw [hdenom] at hr_lt
    exact hr_lt
  have hdef : num % denom = num - denom * (num / denom) := Int.emod_def num denom
  have hmul_dist : denom * (num / denom + 1) = denom * (num / denom) + denom := by
    rw [Int.mul_add, Int.mul_one]
  by_cases h1 : 2 * (num % denom) < denom
  · rw [show rne num denom denom_pos = num / denom from by
      unfold rne; rw [if_pos h1]]
    have hr : num - denom * (num / denom) = num % denom := by omega
    rw [hr]
    omega
  · by_cases h2 : 2 * (num % denom) > denom
    · rw [show rne num denom denom_pos = num / denom + 1 from by
        unfold rne; rw [if_neg h1, if_pos h2]]
      have hr : num - denom * (num / denom + 1) = num % denom - denom := by omega
      rw [hr]
      omega
    · have r_eq_half : 2 * (num % denom) = denom := by omega
      have r_eq : num % denom = denom / 2 := by omega
      by_cases h3 : (num / denom) % 2 = 0
      · rw [show rne num denom denom_pos = num / denom from by
          unfold rne; rw [if_neg h1, if_neg h2, if_pos h3]]
        have hr : num - denom * (num / denom) = num % denom := by omega
        rw [hr, r_eq]
        omega
      · rw [show rne num denom denom_pos = num / denom + 1 from by
          unfold rne; rw [if_neg h1, if_neg h2, if_neg h3]]
        have hr : num - denom * (num / denom + 1) = num % denom - denom := by omega
        rw [hr, r_eq]
        omega

/-- Fixed-point multiplication with RNE rounding.
    z = RNE(m_x * m_y / 2^128) -/
def F128.mul (x y : F128) : F128 :=
  ⟨rne (x.mantissa * y.mantissa) SCALE (by decide)⟩

end Fano1.Module1
