/-
  Module 1: Exact Integer Orthogonality under Phase Rotation

  Theorem 5: The 90-degree rotation R(x, y) = (-y, x) preserves
  the exact integer inner product: <Ru, Rv> = <u, v>.

  Proof: R^T R = I (the rotation matrix is orthogonal over Z),
  so <Ru, Rv> = <u, R^T R v> = <u, v>.
-/

import Fano1.Module1.FixedPoint

namespace Fano1.Module1

/-- A 2D vector of fixed-point mantissas. -/
structure Vec2 where
  x : Int
  y : Int

/-- 90-degree rotation: R(x, y) = (-y, x). -/
def Vec2.rotate (v : Vec2) : Vec2 := ⟨-v.y, v.x⟩

/-- Exact integer inner product (512-bit, no rounding). -/
def Vec2.dot (u v : Vec2) : Int := u.x * v.x + u.y * v.y

/-- R^T R = I: applying rotation twice gives negation. -/
theorem Vec2.rotate_twice (v : Vec2) :
    v.rotate.rotate = ⟨-v.x, -v.y⟩ := by
  unfold Vec2.rotate; rfl

/-- The 90-degree rotation preserves the inner product exactly.
    <Ru, Rv> = <u, v> because R^T R = I over the integers. -/
theorem orthogonalityPreservation (u v : Vec2) :
    (u.rotate.dot v.rotate) = u.dot v := by
  unfold Vec2.rotate Vec2.dot
  simp [Int.neg_mul_neg, Int.add_comm]

/-- If <u, v> = 0 exactly, then <Ru, Rv> = 0 exactly. -/
theorem orthogonalityPreservation_zero (u v : Vec2) (h : u.dot v = 0) :
    u.rotate.dot v.rotate = 0 := by
  rw [orthogonalityPreservation, h]

/-- General Pythagorean rotation: R(c,s) = ((c, -s), (s, c)) with c^2 + s^2 = 1.
    In mantissa space, c and s are integers with c^2 + s^2 = SCALE^2. -/
def Vec2.pythagoreanRotate (v : Vec2) (c s : Int) : Vec2 :=
  ⟨c * v.x - s * v.y, s * v.x + c * v.y⟩

/-- Pythagorean rotation preserves inner product when c^2 + s^2 = SCALE^2. -/
theorem pythagoreanOrthogonality (u v : Vec2) (c s : Int)
    (hcs : c * c + s * s = SCALE * SCALE) :
    (u.pythagoreanRotate c s).dot (v.pythagoreanRotate c s) =
      (c * c + s * s) * u.dot v := by
  unfold Vec2.pythagoreanRotate Vec2.dot
  simp only [Int.mul_add, Int.sub_eq_add_neg, Int.mul_neg, Int.neg_neg,
             Int.mul_left_comm, Int.mul_comm, Int.add_comm, Int.add_assoc, Int.add_left_comm,
             Int.neg_add]
  omega

/-- When c^2 + s^2 = SCALE^2, the Pythagorean rotation preserves inner product
    up to the SCALE^2 factor. -/
theorem pythagoreanOrthogonality_exact (u v : Vec2) (c s : Int)
    (hcs : c * c + s * s = SCALE * SCALE) :
    (u.pythagoreanRotate c s).dot (v.pythagoreanRotate c s) =
      SCALE * SCALE * u.dot v := by
  rw [pythagoreanOrthogonality u v c s hcs, hcs]

end Fano1.Module1
