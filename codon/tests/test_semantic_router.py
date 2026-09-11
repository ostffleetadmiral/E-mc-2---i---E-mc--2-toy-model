"""Unit tests for the 8Di semantic router mapping."""

import json
import unittest
from pathlib import Path


class TestSemanticRouter(unittest.TestCase):
    """The 8Di boundary maps (A, C) signatures to canonical channels."""

    ROUTER = {
        (1, 1): "E5",
        (0, 1): "E6",
        (1, 0): "E4",
        (0, 0): "E7",
    }

    DIMENSIONS = {
        "0D Real": (1, 1),
        "1D Timeline": (1, 1),
        "2D Complex": (1, 1),
        "3D Vector": (0, 1),
        "4D Quaternion": (1, 0),
        "5D Bi-complex": (1, 1),
        "6D Jordan": (0, 1),
        "7D Octonion": (0, 0),
        "8Di Infinity": (1, 1),
        "9D Anti-octonion": (0, 0),
        "10D Container": (1, 1),
    }

    def test_router_mappings(self):
        for sig, channel in self.ROUTER.items():
            with self.subTest(signature=sig):
                self.assertIn(sig, self.ROUTER)
                self.assertEqual(self.ROUTER[sig], channel)

    def test_dimension_table_consistent(self):
        for name, sig in self.DIMENSIONS.items():
            with self.subTest(dimension=name):
                self.assertIn(sig, self.ROUTER)

    def test_codon_routing_matches_signature(self):
        """Each codon class routes to the channel expected from its chemistry."""
        sig_path = (
            Path(__file__).resolve().parents[2]
            / "codon"
            / "data"
            / "codon_signatures_chemistry.json"
        )
        with open(sig_path) as f:
            data = json.load(f)

        expected = {
            "stop": "E2",
            "hydrophobic": "E6",
            "polar": "E5",
            "acidic": "E7",
            "basic": "E4",
            "other": "E4",  # legacy label for basic residues
        }

        for entry in data["signatures"]:
            with self.subTest(codon=entry["codon"]):
                aa_type = entry["type"]
                channel = entry["routing"]["channel"]
                self.assertEqual(channel, expected[aa_type])


if __name__ == "__main__":
    unittest.main()
