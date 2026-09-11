"""Unit tests for the Higgs quartic coupling prediction."""

import unittest


class TestHiggsQuarticCoupling(unittest.TestCase):
    """The Higgs quartic coupling equals the observer density 421/3375."""

    def test_lambda_equals_observer_density(self):
        self.assertAlmostEqual(421 / 3375, 0.1247407407, places=5)

    def test_lambda_close_to_one_eighth(self):
        self.assertAlmostEqual(421 / 3375, 1 / 8, places=1)

    def test_lambda_within_two_percent_of_measured(self):
        predicted = 421 / 3375
        measured = 0.126
        error = abs(predicted - measured) / measured
        self.assertLess(error, 0.02)


if __name__ == "__main__":
    unittest.main()
