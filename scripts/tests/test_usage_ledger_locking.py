#!/usr/bin/env python3
"""Real-process races between ledger appenders and atomic price backfills."""
import csv
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = 'timestamp_local timestamp_utc epoch agent role run_kind provider model input_tokens cached_input_tokens output_tokens total_tokens estimated_usd estimate_note source'.split()
WRITER = r'''
source "$1/scripts/usage_lib.sh"
cortex_usage_claude_session_match() {
    [[ "$TEST_WRITER_MODE" == claude ]] || return 0
    printf 'claude-sonnet-4-6\t10\t0\t2\t3\t1\n'
}
cortex_usage_codex_rollout_match() {
    [[ "$TEST_WRITER_MODE" == codex ]] || return 0
    printf 'gpt-6-luna\t10\t2\t3\t1\n'
}
provider=codex
[[ "$TEST_WRITER_MODE" != claude ]] || provider=claude
cortex_usage_record_from_file "$2" "writer-$TEST_WRITER_MODE" worker command "$provider" gpt-6-luna fixture
'''


class LedgerLockingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ledger-lock-test-', dir=os.environ.get('CORTEX_TEST_TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.ledger = self.path / 'usage.tsv'
        row = ['', '', '1', 'seed', 'worker', 'command', 'codex', 'gpt-6-luna', '100', '', '100', '200', '', 'unknown_price', '']
        self.ledger.write_text('\t'.join(HEADER) + '\n' + '\t'.join(row) + '\n')
        self.output = self.path / 'provider-output'
        self.output.write_text('total tokens: 10\n')
        self.bin = self.path / 'bin'
        self.bin.mkdir()
        # An external flock utility must never be called, even if installed.
        self.script('flock', '#!/bin/sh\ntouch "$TEST_FLOCK_CALLED"\nexit 127\n')
        self.env = dict(os.environ, CORTEX_USAGE_LEDGER=str(self.ledger), CORTEX_USAGE_DISABLE='0',
                        PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TEST_FLOCK_CALLED=str(self.path / 'external-flock-called'))
        self.children = []
        self.addCleanup(self.stop_children)

    def script(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def stop_children(self):
        for process in self.children:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

    def start(self, command, **extra_env):
        process = subprocess.Popen(command, env=dict(self.env, **extra_env),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        self.children.append(process)
        return process

    def writer(self, mode):
        return self.start(['bash', '-c', WRITER, 'test', str(ROOT), str(self.output)], TEST_WRITER_MODE=mode)

    def backfill(self):
        return self.start(['bash', str(ROOT / 'scripts/usage_backfill_prices.sh'), '--apply', str(self.ledger)])

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertFalse((self.path / 'external-flock-called').exists())

    def wait_for(self, path, process):
        deadline = time.monotonic() + 10
        while not path.exists() and time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail('process ended before reaching synchronization point: ' + process.communicate()[1])
            time.sleep(0.01)
        self.assertTrue(path.exists(), 'synchronization point not reached')

    def rows(self):
        with self.ledger.open(newline='') as handle:
            return list(csv.DictReader(handle, delimiter='\t'))

    def test_appenders_wait_through_backfill_rename_and_all_rows_survive(self):
        reached, release = self.path / 'rename-reached', self.path / 'release-rename'
        # Pause immediately before the actual rename while backfill holds FD 9.
        self.script('mv', '#!' + sys.executable + '\nimport os,time\nfrom pathlib import Path\n'
                    'Path(os.environ["TEST_REACHED"]).touch()\n'
                    'while not Path(os.environ["TEST_RELEASE"]).exists(): time.sleep(0.01)\n'
                    'os.replace(os.sys.argv[1],os.sys.argv[2])\n')
        self.env.update(TEST_REACHED=str(reached), TEST_RELEASE=str(release))
        backfill = self.backfill()
        self.wait_for(reached, backfill)
        writers = [self.writer(mode) for mode in ('claude', 'codex', 'fallback')]
        other_backfill = self.backfill()
        time.sleep(0.2)
        self.assertTrue(all(writer.poll() is None for writer in writers), 'writer bypassed backfill lock')
        self.assertIsNone(other_backfill.poll(), 'second backfill bypassed the lock')
        self.assertEqual(len(self.rows()), 1)
        release.touch()
        self.finish(backfill)
        for writer in writers:
            self.finish(writer)
        self.finish(other_backfill)
        rows = self.rows()
        self.assertEqual({row['agent'] for row in rows}, {'seed', 'writer-claude', 'writer-codex', 'writer-fallback'})
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]['estimated_usd'], '0.000060')
        self.assertTrue(all(None not in row for row in rows))

    def test_concurrent_first_writes_create_exactly_one_header(self):
        self.ledger.unlink()
        writers = [self.writer(mode) for mode in ('claude', 'codex', 'fallback') for _ in range(4)]
        for writer in writers:
            self.finish(writer)
        rows = self.rows()
        self.assertEqual(len(rows), 12)
        self.assertEqual({row['agent'] for row in rows}, {'writer-claude', 'writer-codex', 'writer-fallback'})
        self.assertTrue(all(None not in row for row in rows))

    def test_helper_lock_survives_python_exit_and_blocks_other_processes(self):
        ready, release = self.path / 'holder-ready', self.path / 'release-holder'
        command = r'''
source "$1/scripts/usage_lib.sh"
exec 9>>"$CORTEX_USAGE_LEDGER.lock"
cortex_usage_lock_ledger || exit 1
# The Python helper is now gone. This shell still owns the inherited lock.
touch "$2"
while [[ ! -e "$3" ]]; do sleep 0.01; done
'''
        holder = self.start(['bash', '-c', command, 'test', str(ROOT), str(ready), str(release)])
        self.wait_for(ready, holder)
        with Path(str(self.ledger) + '.lock').open('a') as handle:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        writer = self.writer('fallback')
        backfill = self.backfill()
        time.sleep(0.2)
        self.assertIsNone(writer.poll())
        self.assertIsNone(backfill.poll())
        release.touch()
        for process in (holder, writer, backfill):
            self.finish(process)
        self.assertEqual(len(self.rows()), 2)

    def test_lock_errors_abort_all_writer_paths_and_backfill_without_changes(self):
        # Inject ENOLCK into the actual helper, simulating a filesystem lock error.
        self.script('python3', '#!' + sys.executable + '\nimport os,sys,fcntl,errno\n'
                    'if len(sys.argv)>2 and sys.argv[1]=="-c" and "fcntl.flock(9," in sys.argv[2]:\n'
                    ' def fail(*args): raise OSError(errno.ENOLCK,"fixture lock failure")\n'
                    ' fcntl.flock=fail\n'
                    ' exec(sys.argv[2])\n'
                    'else: os.execv(' + repr(sys.executable) + ', [' + repr(sys.executable) + ']+sys.argv[1:])\n')
        original = self.ledger.read_bytes()
        processes = [self.writer(mode) for mode in ('claude', 'codex', 'fallback')] + [self.backfill()]
        for process in processes:
            _, stderr = process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn('ledger write aborted', stderr)
        self.assertEqual(self.ledger.read_bytes(), original)
        self.assertEqual(list(self.path.glob('usage.tsv.backfill.*')), [])

    def test_lock_file_open_errors_are_reported_by_every_writer(self):
        Path(str(self.ledger) + '.lock').mkdir()
        original = self.ledger.read_bytes()
        for process in [self.writer(mode) for mode in ('claude', 'codex', 'fallback')] + [self.backfill()]:
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.ledger.read_bytes(), original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
