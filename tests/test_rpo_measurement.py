"""Check acknowledged-loss counting and refusal of ambiguous recovery frontiers."""

import unittest

from scripts.rpo_measurement import build_rpo_report


class RpoMeasurementTests(unittest.TestCase):
    def report(self, **overrides):
        rows = [[str(n), f'rpo-{n:03d}', str(n * 100), '2026-10-02 12:00:00+00']
                for n in range(1, 4)]
        args = {
            'acknowledgments': [{'row': row, 'utc': f'2026-10-02T12:00:0{n}+00:00',
                                'monotonic_ns': n * 1_000_000_000}
                               for n, row in enumerate(rows, 1)],
            'recovered': rows[:2],
            'fault': {'utc': '2026-10-02T12:00:04+00:00', 'monotonic_ns': 4_000_000_000},
            'start': {'utc': '2026-10-02T12:00:05+00:00', 'monotonic_ns': 5_000_000_000},
            'verified': {'utc': '2026-10-02T12:00:07+00:00', 'monotonic_ns': 7_000_000_000},
        }
        args.update(overrides)
        return build_rpo_report(**args)

    def test_lost_suffix_and_monotonic_windows(self):
        report = self.report()
        self.assertEqual(report['lost_acknowledged_transactions'], 1)
        self.assertEqual(report['lost_references'], ['rpo-003'])
        self.assertEqual(report['observed_rpo_seconds'], 2.0)
        self.assertEqual(report['recovery_duration_seconds'], 2.0)

    def test_no_loss_does_not_turn_idle_time_into_rpo(self):
        rows = [[str(n), f'rpo-{n:03d}', str(n * 100), '2026-10-02 12:00:00+00']
                for n in range(1, 4)]
        report = self.report(recovered=rows)
        self.assertEqual(report['observed_rpo_seconds'], 0.0)
        self.assertEqual(report['last_recovered_ack_to_fault_seconds'], 1.0)

    def test_gaps_modified_rows_and_unknown_rows_reject_report(self):
        for recovered in ([], [['2', 'rpo-002', '200', '2026-10-02 12:00:00+00']],
                          [['1', 'rpo-001', '999', '2026-10-02 12:00:00+00']]):
            with self.subTest(recovered=recovered), self.assertRaises(ValueError):
                self.report(recovered=recovered)

    def test_invalid_acknowledgment_and_fault_order_reject_report(self):
        with self.assertRaises(ValueError):
            self.report(fault={'utc': 'ignored', 'monotonic_ns': 0})
        with self.assertRaises(ValueError):
            self.report(acknowledgments=[])
        ack = {'row': ['1', 'duplicate', '100', 'timestamp'], 'utc': 'ignored',
               'monotonic_ns': 1_000_000_000}
        with self.assertRaises(ValueError):
            self.report(acknowledgments=[ack, ack])


if __name__ == '__main__':
    unittest.main()
