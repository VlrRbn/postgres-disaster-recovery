"""Check measurement boundaries and refusal of misleading success reports."""

import unittest

from scripts.recovery_report import build_report

class RecoveryReportTests(unittest.TestCase):
    def report(self, **overrides):
        args = {
            # Deliberately reversed wall-clock times: duration must use monotonic time.
            "start": {"utc": "2026-10-01T10:00:03+00:00", "monotonic_ns": 1_000_000_000},
            "verified": {"utc": "2026-10-01T10:00:01+00:00", "monotonic_ns": 3_500_000_000},
            "expected": [["1", "wanted", "100", "2026-10-01 10:00:00+00"]],
            "recovered": [["1", "wanted", "100", "2026-10-01 10:00:00+00"]],
            "later": [["2", "excluded", "200", "2026-10-01 10:00:02+00"]],
            "target": "2026-10-01 10:00:00+00:00",
            "incident": "2026-10-01 10:00:01+00:00",
        }
        args.update(overrides)
        return build_report(**args)

    def test_monotonic_duration_and_explicit_rpo_limit(self):
        report = self.report()
        self.assertEqual(report["recovery_duration_seconds"], 2.5)
        self.assertEqual(report["rollback_window_seconds"], 1)
        self.assertEqual(report["missing_expected_rows"], 0)
        self.assertIsNone(report["rpo_seconds"])

    def test_corrupt_missing_or_post_target_rows_reject_success(self):
        for recovered in ([], [["1", "wanted", "999", "2026-10-01 10:00:00+00"]]):
            with self.subTest(recovered=recovered), self.assertRaises(ValueError):
                self.report(recovered=recovered)
        with self.assertRaises(ValueError):
            self.report(later=[["1", "wanted", "100", "2026-10-01 10:00:00+00"]])

    def test_invalid_clock_and_rollback_boundaries_reject_success(self):
        with self.assertRaises(ValueError):
            self.report(verified={"utc": "ignored", "monotonic_ns": 0})
        with self.assertRaises(ValueError):
            self.report(incident="2026-09-30 10:00:00+00:00")
        with self.assertRaises(ValueError):
            self.report(target="2026-10-01 10:00:00")


if __name__ == "__main__":
    unittest.main()
