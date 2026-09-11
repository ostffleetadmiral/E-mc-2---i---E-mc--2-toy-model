"""Unit tests for the protein-folding lattice pilot helpers."""

import unittest

import numpy as np

# Import the pilot script as a module so we can test its helpers.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from protein_folding_lattice import (
    codon_to_lattice_point,
    ideal_helix,
    pairwise_distances,
)


class TestProteinFoldingLattice(unittest.TestCase):
    """Smoke tests for the exploratory protein-folding pilot."""

    def test_codon_to_lattice_point(self):
        # AAA = base-4 indices 0,0,0 -> qubit index 0 -> (0,0,0)
        self.assertEqual(codon_to_lattice_point("AAA"), (0, 0, 0))
        # UUU = indices 3,3,3 -> binary 11 11 11 = 63 -> (3,3,3)
        self.assertEqual(codon_to_lattice_point("UUU"), (3, 3, 3))

    def test_ideal_helix_shape(self):
        pts = ideal_helix(10)
        self.assertEqual(pts.shape, (10, 3))

    def test_pairwise_distances(self):
        coords = np.array([(0, 0, 0), (3, 4, 0)])
        dists = pairwise_distances(coords)
        np.testing.assert_allclose(dists, [5.0])


if __name__ == "__main__":
    unittest.main()
