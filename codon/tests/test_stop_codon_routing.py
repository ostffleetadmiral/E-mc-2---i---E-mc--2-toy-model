"""Unit tests for stop codon routing through E2."""

import json
import unittest
from pathlib import Path


class TestStopCodonRouting(unittest.TestCase):
    """Stop codons UAA, UAG, UGA route through E2 with signature (1,1,0)."""

    @classmethod
    def setUpClass(cls):
        sig_path = (
            Path(__file__).resolve().parents[2]
            / "codon"
            / "data"
            / "codon_signatures_chemistry.json"
        )
        with open(sig_path) as f:
            cls.table = {s["codon"]: s for s in json.load(f)["signatures"]}

    def test_stop_codons_route_to_e2(self):
        for codon in ("UAA", "UAG", "UGA"):
            with self.subTest(codon=codon):
                self.assertEqual(self.table[codon]["routing"]["channel"], "E2")

    def test_stop_codon_signature(self):
        for codon in ("UAA", "UAG", "UGA"):
            with self.subTest(codon=codon):
                routing = self.table[codon]["routing"]
                self.assertEqual(routing["A"], 1)
                self.assertEqual(routing["C"], 1)
                self.assertEqual(routing["D"], 0)


if __name__ == "__main__":
    unittest.main()
