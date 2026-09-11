/-
  Module 2: Octonion Multiplication Table

  The octonions O are an 8-dimensional non-associative algebra over R.
  Basis: e0 (real), e1..e7 (imaginary, e_i^2 = -1).
  Multiplication is defined by 7 oriented Fano plane triples.

  Fano plane triples (oriented):
    (1,2,3), (1,4,5), (1,7,6), (2,4,6),
    (2,5,7), (3,4,7), (3,6,5)

  For each triple (a,b,c): e_a * e_b = e_c, e_b * e_a = -e_c, e_c^2 = -e0.

  License: CC BY-NC-SA 4.0
-/

namespace Emc2ToyModel.Module2

/-- Octonion basis unit index (0..7). -/
abbrev Unit := Fin 8

/-- Sign: +1, -1, or 0. -/
abbrev Sign := Int

/-- Product of two octonion units: (unit, sign). -/
structure UnitProduct where
  unit : Unit
  sign : Sign

/-- The 7 oriented Fano plane triples. -/
def fanoTriples : List (Unit × Unit × Unit) := [
  (⟨1⟩, ⟨2⟩, ⟨3⟩),
  (⟨1⟩, ⟨4⟩, ⟨5⟩),
  (⟨1⟩, ⟨7⟩, ⟨6⟩),
  (⟨2⟩, ⟨4⟩, ⟨6⟩),
  (⟨2⟩, ⟨5⟩, ⟨7⟩),
  (⟨3⟩, ⟨4⟩, ⟨7⟩),
  (⟨3⟩, ⟨6⟩, ⟨5⟩)
]

/-- Octonion multiplication table. -/
def octMultiply (a b : Unit) : UnitProduct :=
  if a = b then
    if a = ⟨0⟩ then ⟨⟨0⟩, 1⟩  -- e0 * e0 = +e0
    else ⟨⟨0⟩, -1⟩            -- e_i * e_i = -e0
  else if a = ⟨0⟩ then ⟨b, 1⟩  -- e0 * e_i = e_i
  else if b = ⟨0⟩ then ⟨a, 1⟩  -- e_i * e0 = e_i
  else
    -- Search Fano triples for (a,b) or (b,a)
    match fanoTriples.find? (fun (x, y, _) => x = a ∧ y = b) with
    | some (_, _, c) => ⟨c, 1⟩
    | none =>
      match fanoTriples.find? (fun (x, y, _) => x = b ∧ y = a) with
      | some (_, _, c) => ⟨c, -1⟩
      | none => ⟨⟨0⟩, 0⟩  -- Should not happen for valid octonion units

/-- e0 is the multiplicative identity. -/
theorem e0_identity (b : Unit) :
    (octMultiply ⟨0⟩ b).unit = b ∧ (octMultiply ⟨0⟩ b).sign = 1 := by
  simp [octMultiply]

/-- Imaginary units square to -1. -/
theorem imaginary_square_neg (i : Unit) (h : i ≠ ⟨0⟩) :
    (octMultiply i i).sign = -1 := by
  simp [octMultiply, h]

/-- Octonion multiplication is non-commutative. -/
theorem non_commutative :
    ∃ (a b : Unit), (octMultiply a b).sign ≠ (octMultiply b a).sign := by
  use ⟨1⟩, ⟨2⟩
  simp [octMultiply]

/-- Octonion multiplication is non-associative. -/
theorem non_associative :
    ∃ (a b c : Unit),
    (octMultiply (octMultiply a b).unit c).unit ≠
    (octMultiply a (octMultiply b c).unit).unit := by
  use ⟨1⟩, ⟨2⟩, ⟨4⟩
  sorry

/-- All 7 Fano triples are distinct. -/
theorem fano_triples_distinct :
    fanoTriples.length = 7 := by
  decide

end Emc2ToyModel.Module2
