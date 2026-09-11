"""Unit tests for the dark energy suppression factor."""

import math
import unittest


class TestDarkEnergySuppression(unittest.TestCase):
    """Dark energy suppression is g = 1/(phi**8 * 5) ~ 1/235."""

    def test_phi_eighth_times_five(self):
        phi = (1 + math.sqrt(5)) / 2
        self.assertAlmostEqual(phi ** 8 * 5, 235.0, places=0)

    def test_g_close_to_one_over_235(self):
        phi = (1 + math.sqrt(5)) / 2
        g = 1 / (phi ** 8 * 5)
        self.assertAlmostEqual(g, 1 / 235, places=3)

    def test_g_within_point_one_percent(self):
        phi = (1 + math.sqrt(5)) / 2
        g = 1 / (phi ** 8 * 5)
        error = abs(g - 1 / 235) / (1 / 235)
        self.assertLess(error, 0.001)


if __name__ == "__main__":
    unittest.main()
