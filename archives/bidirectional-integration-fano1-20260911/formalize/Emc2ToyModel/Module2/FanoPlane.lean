/-
  Module 2: Fano Plane Structure

  The Fano plane is the projective plane of order 2, with 7 points
  and 7 lines. Each line contains exactly 3 points, and each point
  is on exactly 3 lines. The 7 oriented triples define octonion
  multiplication.

  License: CC BY-NC-SA 4.0
-/

namespace Emc2ToyModel.Module2

/-- Fano plane point (1..7). -/
abbrev Point := Fin 7

/-- A Fano line is a set of 3 points. -/
structure FanoLine where
  p1 : Point
  p2 : Point
  p3 : Point

/-- The 7 lines of the Fano plane. -/
def fanoLines : List FanoLine := [
  ⟨0, 1, 2⟩,  -- {1,2,3}
  ⟨0, 3, 4⟩,  -- {1,4,5}
  ⟨0, 6, 5⟩,  -- {1,7,6}
  ⟨1, 3, 5⟩,  -- {2,4,6}
  ⟨1, 4, 6⟩,  -- {2,5,7}
  ⟨2, 3, 6⟩,  -- {3,4,7}
  ⟨2, 5, 4⟩   -- {3,6,5}
]

/-- The Fano plane has exactly 7 lines. -/
theorem fano_line_count : fanoLines.length = 7 := by decide

/-- Each Fano line has exactly 3 distinct points. -/
theorem fano_lines_have_3_points :
    ∀ (l : FanoLine), l ∈ fanoLines →
    l.p1 ≠ l.p2 ∧ l.p1 ≠ l.p3 ∧ l.p2 ≠ l.p3 := by
  decide

/-- Each point is on exactly 3 lines. -/
theorem each_point_on_3_lines :
    ∀ (p : Point), (fanoLines.filter (fun l => l.p1 = p ∨ l.p2 = p ∨ l.p3 = p)).length = 3 := by
  decide

end Emc2ToyModel.Module2
