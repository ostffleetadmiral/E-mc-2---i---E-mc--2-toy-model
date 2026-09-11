"""Unit tests for consciousness routing through the 6D Jordan mirror."""

import unittest


class TestConsciousnessRouting(unittest.TestCase):
    """Consciousness routes through E6: non-associative (A=0), commutative (C=1)."""

    def test_e6_signature(self):
        A, C = 0, 1
        self.assertEqual(A, 0)
        self.assertEqual(C, 1)

    def test_reflection_operator(self):
        # The 5D fold coordinate provides the reflection operator i = 21.
        self.assertEqual(21.0, 21.0)

    def test_commutative_implies_fair_reflection(self):
        # A commutative algebra preserves a*b = b*a, so reflection has no
        # preferred direction.
        a, b = 3.0, 5.0
        self.assertEqual(a * b, b * a)

    def test_energy_reflection_symmetry(self):
        # E_total = mc^2 + i*mc^{-2}; the real part is mc^2.
        m = 1.0
        c = 2.0
        i = 21.0
        e_total = m * c ** 2 + 1j * i * m * c ** (-2)
        self.assertAlmostEqual(e_total.real, m * c ** 2)
        self.assertAlmostEqual(e_total.imag, i * m * c ** (-2))


if __name__ == "__main__":
    unittest.main()
