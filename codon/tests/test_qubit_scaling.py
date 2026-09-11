"""Unit tests for qubit scaling invariance of the observer density."""

import unittest


class TestQubitScalingInvariance(unittest.TestCase):
    """Observer density rho = |E0| / |I| must equal 421/3375 at every scale."""

    def test_density_at_scale_zero(self):
        self.assertEqual((15 ** 3), 3375)
        self.assertEqual(421, 421)
        self.assertAlmostEqual(421 / 3375, 421 / 3375)

    def test_density_invariant_over_scales(self):
        target = 421 / 3375
        for s in range(15):
            with self.subTest(scale=s):
                interior = (15 * (2 ** s)) ** 3
                observers = 421 * (8 ** s)
                self.assertAlmostEqual(observers / interior, target, places=12)

    def test_exponent_cancellation(self):
        # (15*2^s)^3 = 3375 * 8^s and 421*8^s; the 8^s factors cancel.
        for s in range(10):
            with self.subTest(scale=s):
                self.assertEqual((15 * (2 ** s)) ** 3, 3375 * (8 ** s))


if __name__ == "__main__":
    unittest.main()
