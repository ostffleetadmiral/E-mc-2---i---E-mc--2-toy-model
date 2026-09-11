"""Unit tests for genetic-code degeneracy / third-base wobble."""

import json
import unittest
from collections import defaultdict
from pathlib import Path


class TestGeneticWobble(unittest.TestCase):
    """Synonymous codons should route through the same dimensional channel."""

    @classmethod
    def setUpClass(cls):
        sig_path = (
            Path(__file__).resolve().parents[2]
            / "codon"
            / "data"
            / "codon_signatures_chemistry.json"
        )
        with open(sig_path) as f:
            cls.sigs = json.load(f)["signatures"]

    def test_synonymous_codons_share_channel(self):
        by_aa = defaultdict(list)
        for sig in self.sigs:
            by_aa[sig["aa"]].append(sig["routing"]["channel"])

        for aa, channels in by_aa.items():
            with self.subTest(amino_acid=aa):
                self.assertEqual(len(set(channels)), 1)

    def test_third_base_variation_preserves_channel_for_most(self):
        by_aa = defaultdict(list)
        for sig in self.sigs:
            by_aa[sig["aa"]].append(sig["codon"])

        third_base_only_count = 0
        total = 0
        for aa, codons in by_aa.items():
            total += 1
            prefixes = {c[:2] for c in codons}
            third_bases = {c[2] for c in codons}
            if len(prefixes) == 1 and len(third_bases) > 1:
                third_base_only_count += 1

        # At least half of amino-acid families show third-base-only variation.
        self.assertGreaterEqual(third_base_only_count / total, 0.5)


if __name__ == "__main__":
    unittest.main()
