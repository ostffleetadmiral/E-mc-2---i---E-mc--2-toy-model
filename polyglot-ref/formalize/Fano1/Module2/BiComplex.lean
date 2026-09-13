/-
  Module 2: Bi-Complex Algebra

  The bi-complex numbers C ⊗_R C ≅ C ⊕ C form an associative,
  commutative algebra. This file defines the bi-complex type and
  proves associativity of multiplication.
-/

import Fano1.Module1.FixedPoint

namespace Fano1.Module2

/-- The bi-complex numbers, modeled as pairs of complex-like values.
    We use Int pairs to represent (a + b*i, c + d*i) components,
    keeping everything in integer arithmetic for Q128.128 compatibility. -/
structure BiComplex where
  re1 : Int  -- real part of first component
  im1 : Int  -- imaginary part of first component
  re2 : Int  -- real part of second component
  im2 : Int  -- imaginary part of second component

/-- Zero element. -/
def BiComplex.zero : BiComplex := ⟨0, 0, 0, 0⟩

/-- One element (multiplicative identity). -/
def BiComplex.one : BiComplex := ⟨1, 0, 1, 0⟩

/-- Addition is componentwise. -/
def BiComplex.add (x y : BiComplex) : BiComplex :=
  ⟨x.re1 + y.re1, x.im1 + y.im1, x.re2 + y.re2, x.im2 + y.im2⟩

/-- Multiplication is componentwise: (z1, z2) * (w1, w2) = (z1*w1, z2*w2). -/
def BiComplex.mul (x y : BiComplex) : BiComplex :=
  ⟨x.re1 * y.re1 - x.im1 * y.im1,
   x.re1 * y.im1 + x.im1 * y.re1,
   x.re2 * y.re2 - x.im2 * y.im2,
   x.re2 * y.im2 + x.im2 * y.re2⟩

/-- Negation. -/
def BiComplex.neg (x : BiComplex) : BiComplex :=
  ⟨-x.re1, -x.im1, -x.re2, -x.im2⟩

/-- The idempotents e_+ = (1+j)/2 and e_- = (1-j)/2.
    In our model, j^2 = 1, so e_+ corresponds to (1,0) and e_- to (0,1). -/
def ePlus : BiComplex := ⟨1, 0, 0, 0⟩
def eMinus : BiComplex := ⟨0, 0, 1, 0⟩

/-- e_+ + e_- = 1 -/
theorem ePlus_eMinus_one : ePlus.add eMinus = BiComplex.one := rfl

/-- e_+ * e_- = 0 -/
theorem ePlus_eMinus_zero : ePlus.mul eMinus = BiComplex.zero := rfl

/-- e_+ * e_+ = e_+ -/
theorem ePlus_idempotent : ePlus.mul ePlus = ePlus := rfl

/-- e_- * e_- = e_- -/
theorem eMinus_idempotent : eMinus.mul eMinus = eMinus := rfl

/-- Multiplication is associative. -/
theorem BiComplex.mul_assoc (x y z : BiComplex) :
    (x.mul y).mul z = x.mul (y.mul z) := by
  unfold BiComplex.mul
  -- Each component is complex multiplication, which is associative
  -- (a+bi)(c+di) = (ac-bd) + (ad+bc)i
  -- Associativity follows from ring properties of Int
  simp [Int.mul_comm, Int.mul_left_comm, Int.mul_add,
        Int.add_comm, Int.add_assoc, Int.add_left_comm,
        Int.sub_eq_add_neg, Int.neg_add, Int.mul_neg]

/-- Multiplication is commutative. -/
theorem BiComplex.mul_comm (x y : BiComplex) :
    x.mul y = y.mul x := by
  unfold BiComplex.mul
  simp [Int.mul_comm, Int.add_comm, Int.sub_eq_add_neg]

/-- Addition is commutative. -/
theorem BiComplex.add_comm (x y : BiComplex) :
    x.add y = y.add x := by
  unfold BiComplex.add
  simp [Int.add_comm]

/-- Addition is associative. -/
theorem BiComplex.add_assoc (x y z : BiComplex) :
    (x.add y).add z = x.add (y.add z) := by
  unfold BiComplex.add
  simp [Int.add_assoc]

/-- Left distributivity. -/
theorem BiComplex.left_distrib (x y z : BiComplex) :
    x.mul (y.add z) = (x.mul y).add (x.mul z) := by
  unfold BiComplex.mul BiComplex.add
  simp [Int.mul_add, Int.mul_comm,
        Int.add_assoc, Int.add_left_comm,
        Int.sub_eq_add_neg, Int.neg_add]

/-- Right distributivity. -/
theorem BiComplex.right_distrib (x y z : BiComplex) :
    (x.add y).mul z = (x.mul z).add (y.mul z) := by
  unfold BiComplex.mul BiComplex.add
  simp [Int.mul_add, Int.mul_comm,
        Int.add_assoc, Int.add_left_comm,
        Int.sub_eq_add_neg, Int.neg_add]

/-- Zero is left identity for addition. -/
theorem BiComplex.zero_add (x : BiComplex) : BiComplex.zero.add x = x := by
  unfold BiComplex.add BiComplex.zero
  simp

/-- Zero is right identity for addition. -/
theorem BiComplex.add_zero (x : BiComplex) : x.add BiComplex.zero = x := by
  unfold BiComplex.add BiComplex.zero
  simp

/-- One is left identity for multiplication. -/
theorem BiComplex.one_mul (x : BiComplex) : BiComplex.one.mul x = x := by
  unfold BiComplex.mul BiComplex.one
  simp [Int.one_mul]

/-- One is right identity for multiplication. -/
theorem BiComplex.mul_one (x : BiComplex) : x.mul BiComplex.one = x := by
  unfold BiComplex.mul BiComplex.one
  simp [Int.mul_one]

/-- The associator (xy)z - x(yz) = 0 for all bi-complex numbers. -/
theorem BiComplex.associator_zero (x y z : BiComplex) :
    (x.mul y).mul z = x.mul (y.mul z) := BiComplex.mul_assoc x y z

end Fano1.Module2
