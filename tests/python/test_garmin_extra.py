"""Tests für peak_hr_from_details (scripts/garmin_extra.py).
Aufruf (aus dem Projektordner): ~/.virtualenvs/r-garmin/bin/python -m unittest discover -s tests/python
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
from garmin_extra import peak_hr_from_details  # noqa: E402

DESC = [
    {"metricsIndex": 0, "key": "sumDuration"},
    {"metricsIndex": 1, "key": "directHeartRate"},
    {"metricsIndex": 2, "key": "sumElapsedDuration"},
]


def details(samples):
    """samples: Liste (elapsed_s, hr) -> Antwort-Struktur wie get_activity_details."""
    return {"metricDescriptors": DESC,
            "activityDetailMetrics": [{"metrics": [0.0, hr, float(t)]} for t, hr in samples]}


class PeakHr(unittest.TestCase):
    def test_constant_hr(self):
        r = peak_hr_from_details(details([(t, 100) for t in range(0, 61)]))
        self.assertEqual(r["hr_peak30"], 100)
        self.assertEqual(r["hr_max_raw"], 100)
        self.assertEqual(r["n_samples"], 61)

    def test_single_spike_is_smoothed_but_raw_max_is_kept(self):
        s = [(t, 100) for t in range(0, 61)]
        s[40] = (40, 200)                                   # ein einzelner Ausreißer
        r = peak_hr_from_details(details(s))
        self.assertEqual(r["hr_max_raw"], 200)
        self.assertLess(r["hr_peak30"], 110)               # 30-s-Mittel verschluckt ihn (≈ 103)
        self.assertGreater(r["hr_peak30"], 100)

    def test_sustained_plateau_is_not_removed(self):
        s = [(t, 100) for t in range(0, 31)] + [(t, 190) for t in range(31, 91)]
        r = peak_hr_from_details(details(s))
        self.assertEqual(r["hr_peak30"], 190)               # anhaltender Wert bleibt sichtbar (Plausibilität prüft R)

    def test_irregular_sampling_uses_time_window(self):
        s = [(0, 100), (10, 100), (20, 100), (30, 100), (31, 180), (45, 180), (60, 180)]
        r = peak_hr_from_details(details(s))
        self.assertGreater(r["hr_peak30"], 150)

    def test_too_short_for_window_gives_no_peak_but_raw_max(self):
        r = peak_hr_from_details(details([(t, 120) for t in range(0, 20)]))
        self.assertIsNone(r["hr_peak30"])
        self.assertEqual(r["hr_max_raw"], 120)

    def test_missing_values_are_skipped(self):
        s = [(t, 100) for t in range(0, 61)]
        s[10] = (10, None)
        r = peak_hr_from_details(details(s))
        self.assertEqual(r["n_samples"], 60)
        self.assertEqual(r["hr_peak30"], 100)

    def test_missing_descriptors_or_empty(self):
        self.assertIsNone(peak_hr_from_details({}))
        self.assertIsNone(peak_hr_from_details({"metricDescriptors": [], "activityDetailMetrics": []}))
        self.assertIsNone(peak_hr_from_details(details([])))


if __name__ == "__main__":
    unittest.main()
