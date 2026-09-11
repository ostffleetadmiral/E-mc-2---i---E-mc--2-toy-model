/-
  Module 3: Cubic Scaling Chain and the 7-Defect

  The scaling chain: 15³ → 16³ → 32³ → 62³ → 128³ → 256³
  Key identities:
    7-defect: 2³ - 1 = 7
    421 = (15³ - 7) / 8 = (3375 - 7) / 8
    421/3375 = 1/8 - 7/27000
    62 = 64 - 2 (codon capacity - boundary dimension)
    Mersenne prime: 31 = 2^5 - 1

  License: CC BY-NC-SA 4.0
-/

namespace Emc2ToyModel.Module3

/-- Interior volume: 15³ = 3375. -/
def INTERIOR : Nat := 3375

/-- Closure volume: 16³ = 4096. -/
def CLOSURE : Nat := 4096

/-- First doubling: 32³ = 32768. -/
def FIRST_DOUBLING : Nat := 32768

/-- Codon capacity: 62³ = 238328. -/
def CODON_CAPACITY : Nat := 238328

/-- Third doubling: 128³ = 2097152. -/
def THIRD_DOUBLING : Nat := 2097152

/-- Octonion capacity: 256³ = 16777216. -/
def OCTONION_CAPACITY : Nat := 16777216

/-- 7-defect: 2³ - 1 = 7. -/
theorem seven_defect : 2^3 - 1 = 7 := by decide

/-- 15³ = 3375. -/
theorem interior_volume : 15^3 = INTERIOR := by decide

/-- 16³ = 4096. -/
theorem closure_volume : 16^3 = CLOSURE := by decide

/-- 32³ = 32768. -/
theorem first_doubling : 32^3 = FIRST_DOUBLING := by decide

/-- 62³ = 238328. -/
theorem codon_capacity : 62^3 = CODON_CAPACITY := by decide

/-- 62 = 64 - 2 (codon capacity - boundary dimension). -/
theorem codon_minus_boundary : 62 = 64 - 2 := by decide

/-- 128³ = 2097152. -/
theorem third_doubling : 128^3 = THIRD_DOUBLING := by decide

/-- 256³ = 16777216. -/
theorem octonion_capacity : 256^3 = OCTONION_CAPACITY := by decide

/-- 421 = (15³ - 7) / 8. -/
theorem four_twenty_one : (3375 - 7) / 8 = 421 := by decide

/-- 421/3375 = 1/8 - 7/27000. -/
theorem consciousness_fraction : (421 : Int) * 27000 = 3375 * 3375 - 7 * 3375 := by decide

/-- Mersenne prime: 31 = 2^5 - 1. -/
theorem mersenne_31 : 2^5 - 1 = 31 := by decide

/-- Shell transition: 16³ - 15³ = 721. -/
theorem shell_transition : CLOSURE - INTERIOR = 721 := by decide

end Emc2ToyModel.Module3
