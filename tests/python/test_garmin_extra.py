"""Tests für peak_hr_from_details (scripts/garmin_extra.py).
Aufruf (aus dem Projektordner): ~/.virtualenvs/r-garmin/bin/python -m unittest discover -s tests/python
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import garmin_extra  # noqa: E402
from garmin_extra import peak_hr_from_details, extra_day  # noqa: E402

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


class FlakyApi:
    """Testdouble für die Garmin-API: einzelne Methoden werfen oder liefern feste Werte."""
    def __init__(self, **calls):
        self.calls = {}
        self.spec = calls

    def __getattr__(self, name):
        def f(*args):
            self.calls[name] = self.calls.get(name, 0) + 1
            v = self.spec.get(name, {})
            if isinstance(v, Exception):
                raise v
            if callable(v):
                return v(self.calls[name])
            return v
        return f


class CallWithRetry(unittest.TestCase):
    def setUp(self):
        self.sleeps = []
        self._orig = garmin_extra.time.sleep
        garmin_extra.time.sleep = lambda s: self.sleeps.append(s)

    def tearDown(self):
        garmin_extra.time.sleep = self._orig

    def test_success_first_try(self):
        api = FlakyApi(get_sleep_data={"x": 1})
        self.assertEqual(garmin_extra._call(api.get_sleep_data, "d"), (True, {"x": 1}))
        self.assertEqual(api.calls["get_sleep_data"], 1)
        self.assertEqual(self.sleeps, [])

    def test_no_data_is_ok_and_not_retried(self):
        api = FlakyApi(get_hrv_data=None)
        self.assertEqual(garmin_extra._call(api.get_hrv_data, "d"), (True, None))
        self.assertEqual(api.calls["get_hrv_data"], 1)

    def test_retries_with_backoff_then_gives_up(self):
        api = FlakyApi(get_sleep_data=RuntimeError("429"))
        self.assertEqual(garmin_extra._call(api.get_sleep_data, "d"), (False, None))
        self.assertEqual(api.calls["get_sleep_data"], 3)
        self.assertEqual(self.sleeps, [1.0, 2.0])

    def test_recovers_on_second_attempt(self):
        def flaky(n):
            if n < 2:
                raise RuntimeError("timeout")
            return {"ok": True}
        api = FlakyApi(get_sleep_data=flaky)
        self.assertEqual(garmin_extra._call(api.get_sleep_data, "d"), (True, {"ok": True}))
        self.assertEqual(self.sleeps, [1.0])


class ExtraDayFlags(unittest.TestCase):
    def setUp(self):
        self._orig = garmin_extra.time.sleep
        garmin_extra.time.sleep = lambda s: None

    def tearDown(self):
        garmin_extra.time.sleep = self._orig

    def test_all_calls_ok_but_no_data(self):
        r = extra_day(FlakyApi(get_sleep_data={}, get_hrv_data=None, get_morning_training_readiness={},
                               get_training_status={}), "2026-10-01")
        self.assertTrue(all(r[k] is True for k in ("fx_sleep", "fx_hrv", "fx_ready", "fx_status")))
        self.assertIsNone(r["sleep_h"])

    def test_failed_call_is_marked_and_others_still_filled(self):
        api = FlakyApi(get_sleep_data=RuntimeError("down"), get_hrv_data={"hrvSummary": {"weeklyAvg": 33}},
                       get_morning_training_readiness={}, get_training_status={})
        r = extra_day(api, "2026-10-01")
        self.assertFalse(r["fx_sleep"])
        self.assertTrue(r["fx_hrv"] and r["fx_ready"] and r["fx_status"])
        self.assertEqual(r["hrv_weekly"], 33)
        self.assertIsNone(r["sleep_h"])


if __name__ == "__main__":
    unittest.main()
