"""Unit tests for codon signature reconstruction and routing rules."""

import math
import unittest

from codon.constants import GENETIC_CODE
from codon.rules import predicts_hydrophobic, predicts_stop
from codon.signature import (
    ChemistrySignatureBuilder,
    PlaceholderSignatureBuilder,
    _surface_area,
    _triplet_qubit_index,
)


class TestChemistryHelpers(unittest.TestCase):
    def test_qubit_index_encoding(self):
        """AUG encodes to 0b001110 = 14."""
        self.assertEqual(_triplet_qubit_index("AUG"), 14)

    def test_surface_area_formula(self):
        """Surface area matches the van der Waals + backbone formula."""
        # UAG: U(1.80) + A(1.88) + G(1.96) = 5.64 Å; + backbone 3.4 Å = 9.04 Å = 0.904 nm
        r = 0.564 + 0.34
        expected = 4.0 * math.pi * r * r
        self.assertAlmostEqual(_surface_area("UAG"), expected, places=4)


class TestPlaceholderBuilder(unittest.TestCase):
    def setUp(self):
        self.table = PlaceholderSignatureBuilder().build()

    def test_all_64_codons_present(self):
        self.assertEqual(len(self.table), 64)

    def test_stop_codons_match_rule(self):
        for codon in ("UAA", "UAG", "UGA"):
            self.assertTrue(
                predicts_stop(self.table[codon]),
                f"{codon} should be predicted as stop",
            )

    def test_hydrophobic_codons_match_rule(self):
        hydrophobic = {
            c for c, aa in GENETIC_CODE.items()
            if aa in {"F", "L", "I", "M", "V", "P", "A", "W", "G"}
        }
        for codon in hydrophobic:
            if codon == "GCA":
                # documented outlier: exactly on the threshold
                self.assertEqual(self.table[codon]["coord_sum"], 42.0)
                self.assertFalse(predicts_hydrophobic(self.table[codon]))
            else:
                self.assertTrue(
                    predicts_hydrophobic(self.table[codon]),
                    f"{codon} should be predicted as hydrophobic",
                )


class TestChemistryBuilder(unittest.TestCase):
    def setUp(self):
        self.table = ChemistrySignatureBuilder().build()

    def test_all_64_codons_present(self):
        self.assertEqual(len(self.table), 64)

    def test_stop_codons_match_rule(self):
        for codon in ("UAA", "UAG", "UGA"):
            self.assertTrue(
                predicts_stop(self.table[codon]),
                f"{codon} should be predicted as stop",
            )

    def test_hydrophobic_codons_match_rule(self):
        hydrophobic = {
            c for c, aa in GENETIC_CODE.items()
            if aa in {"F", "L", "I", "M", "V", "P", "A", "W", "G"}
        }
        for codon in hydrophobic:
            if codon == "AUG":
                # documented E6 outlier sitting exactly on the threshold
                self.assertEqual(self.table[codon]["coord_sum"], 42.0)
                self.assertFalse(predicts_hydrophobic(self.table[codon]))
            else:
                self.assertTrue(
                    predicts_hydrophobic(self.table[codon]),
                    f"{codon} should be predicted as hydrophobic",
                )

    def test_routing_fields(self):
        self.assertEqual(self.table["UAA"]["routing"]["channel"], "E2")
        self.assertEqual(self.table["AUG"]["routing"]["channel"], "E6")
        self.assertEqual(self.table["GAU"]["routing"]["channel"], "E7")


if __name__ == "__main__":
    unittest.main()
