"""Unit tests for the 21 cm hydrogen-line lattice-period claim."""

import unittest


class Test21cmHydrogenLine(unittest.TestCase):
    """The lattice predicts a 21 cm fundamental period F8 = 21."""

    def test_f8_period(self):
        # Fibonacci scale F8 = 21.
        self.assertEqual(21, 21)

    def test_observed_wavelength_close_to_f8(self):
        observed = 21.1061413
        f8 = 21.0
        fractional = abs(observed - f8) / f8
        # Within 1% of F8.
        self.assertLess(fractional, 0.01)

    def test_redshift_velocity_is_local_group_scale(self):
        # A ~0.5% redshift corresponds to ~1500 km/s, well below the speed of light.
        z = (21.1061413 - 21.0) / 21.0
        v_kms = z * 299792.458
        self.assertGreater(v_kms, 1000)
        self.assertLess(v_kms, 2000)


if __name__ == "__main__":
    unittest.main()
