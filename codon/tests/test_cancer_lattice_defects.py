"""Unit tests for the cancer-as-lattice-defects pilot."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from cancer_lattice_pilot import (
    DRIVER_MUTATIONS,
    NEUTRAL_MUTATIONS,
    describe_change,
)

package_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(package_dir))
from codon.signature import ChemistrySignatureBuilder


class TestCancerLatticeDefects(unittest.TestCase):
    """Driver mutations should alter routing channels more than neutral ones."""

    @classmethod
    def setUpClass(cls):
        cls.table = ChemistrySignatureBuilder().build()

    def test_describe_change_returns_channel_info(self):
        change = describe_change(self.table["GGU"], self.table["GAU"])
        self.assertTrue(change["channel_changed"])
        self.assertNotEqual(change["max_dim_delta"], 0)

    def test_driver_channel_change_rate_above_neutral(self):
        driver_changes = sum(
            1 for _, _, ref, alt in DRIVER_MUTATIONS
            if describe_change(self.table[ref], self.table[alt])["channel_changed"]
        )
        neutral_changes = sum(
            1 for _, _, ref, alt in NEUTRAL_MUTATIONS
            if describe_change(self.table[ref], self.table[alt])["channel_changed"]
        )

        self.assertGreater(driver_changes, neutral_changes)
        self.assertGreater(driver_changes, 0)
        self.assertEqual(neutral_changes, 0)


if __name__ == "__main__":
    unittest.main()
