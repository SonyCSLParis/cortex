#!/usr/bin/env python3
"""Run the real backfill CLI without newer Bash array-reading builtins."""
import csv
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = 'timestamp_local timestamp_utc epoch agent role run_kind provider model input_tokens cached_input_tokens output_tokens total_tokens estimated_usd estimate_note source'.split()


class BackfillPortabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cortex-backfill-portability-')
        self.addCleanup(self.temp.cleanup)
        self.ledger = Path(self.temp.name) / 'usage.tsv'
        self.rows = [
            ['', '', '1', 'fixture agent', 'worker', 'periodic', 'codex', 'gpt-6.1-sol',
             '100', '200', '300', '600', '', 'unknown_price', ''],
            ['fixture local', '', '2', '', 'worker', '', 'codex', 'gpt-6-luna',
             '', '', '', '1000', '', 'unknown_price', 'literal $(not-code); *'],
            ['', '', '3', 'already-priced', 'worker', 'command', 'codex', 'gpt-6.1-sol',
             '', '100', '', '100', '0.123456', 'exact_or_split', ''],
            ['', '', '4', 'unpriced', 'worker', 'command', 'codex', 'fixture-unpriced-model',
             '1', '', '2', '3', '', 'unknown_price', ''],
        ]
        self.ledger.write_text('\t'.join(HEADER) + '\n' + ''.join('\t'.join(row) + '\n' for row in self.rows))

    def run_cli(self, *flags):
        shell = os.environ.get('CORTEX_TEST_BASH', 'bash')
        # Stock macOS Bash lacks these builtins; disabling them on newer Bash
        # catches accidental dependencies while still running the actual CLI.
        command = 'enable -n mapfile readarray 2>/dev/null || :; source "$1" "${@:2}"'
        return subprocess.run([shell, '-c', command, 'backfill-test',
                               str(ROOT / 'scripts/usage_backfill_prices.sh'), *flags, str(self.ledger)],
                              capture_output=True, text=True, check=True)

    def read_rows(self):
        with self.ledger.open(newline='') as handle:
            return list(csv.reader(handle, delimiter='\t'))

    def test_dry_run_preserves_input_bytes(self):
        original = self.ledger.read_bytes()
        result = self.run_cli()
        self.assertIn('re-priced: 2', result.stderr)
        self.assertEqual(self.ledger.read_bytes(), original)

    def test_apply_preserves_empty_columns_and_unrelated_rows(self):
        self.run_cli('--apply')
        rows = self.read_rows()
        self.assertEqual(rows[0], HEADER)
        self.assertEqual(len(rows), 5)
        self.assertTrue(all(len(row) == 15 for row in rows))
        for original, updated in zip(self.rows, rows[1:]):
            for index in range(15):
                if index not in (12, 13):
                    self.assertEqual(updated[index], original[index], index)
        self.assertEqual(rows[1][12:14], ['0.003220', 'exact_or_split_price_backfill'])
        self.assertEqual(rows[2][12:14], ['0.000180', 'estimated_80_20_from_total_price_backfill'])
        self.assertEqual(rows[3:], self.rows[2:])

    def test_apply_is_idempotent(self):
        self.run_cli('--apply')
        original = self.ledger.read_bytes()
        result = self.run_cli('--apply')
        self.assertIn('re-priced: 0', result.stderr)
        self.assertEqual(self.ledger.read_bytes(), original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
