"""Unit tests for the lattice-resonant qubit-count pilot."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from lattice_resonant_qubits import grover_success_probability


class TestLatticeResonantQubits(unittest.TestCase):
    """Resonant qubit counts follow 8**s = 2**(3s)."""

    def test_resonant_counts(self):
        for s in range(6):
            total = 8 ** s
            n = 3 * s
            self.assertEqual(2 ** n, total)

    def test_grover_success_high_for_resonant_n3(self):
        p = grover_success_probability(3)
        self.assertGreater(p, 0.9)
        self.assertLessEqual(p, 1.0)

    def test_grover_success_between_zero_and_one(self):
        for n in range(3, 10):
            p = grover_success_probability(n)
            self.assertGreaterEqual(p, 0.0)
            self.assertLessEqual(p, 1.0)


if __name__ == "__main__":
    unittest.main()
