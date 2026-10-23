#!/usr/bin/env python3
"""Provider failure/timeout and concurrent conductor transcript regressions.

Uses fake provider output and temporary native histories; no model calls.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('prompt_log_sync', ROOT / 'scripts/prompt_log_sync.py')
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)


def function(name):
    source = (ROOT / 'scripts/start_agent.sh').read_text()
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)[0]


class ProviderTests(unittest.TestCase):
    def run_attempts(self, primary, fallback=None, primary_rc=1, fallback_rc=1, after=''):
        with tempfile.TemporaryDirectory() as tmp:
            script = f'source "{ROOT}/scripts/bash_compat.sh"\n' + '\n'.join(function(name) for name in (
                'extract_result_field', 'result_has_structured_fields',
                'provider_failure_state_field', 'provider_failure_other_records',
                'provider_failure_matches_quota_auth', 'provider_failure_retry_hint',
                'clear_provider_failure_state_if_matches', 'record_provider_failure_cooldown',
                'provider_failure_cooldown_active', 'provider_failure_cooldown_message',
                'run_agent_cli_provider_attempt', 'run_agent_cli')) + r'''
log() { printf 'LOG: %s\n' "$*"; }
run_agent_cli_single_provider() {
    printf '%s\n' "$AGENT_PROVIDER" >> "$TEST_DIR/attempts"
    if [[ "$AGENT_PROVIDER" == codex ]]; then printf '%s' "$PRIMARY_OUTPUT"; return "$PRIMARY_RC"; fi
    printf '%s' "$FALLBACK_OUTPUT"; return "$FALLBACK_RC"
}
AGENT_PROVIDER=codex
COMMAND_TIMEOUT=10
PROVIDER_FAILURE_STATE="$TEST_DIR/provider_failure_state"
PROVIDER_FAILURE_COOLDOWN_SECONDS=3600
RUN_AGENT_LAST_OUTPUT=''
RUN_AGENT_LAST_FAILURE_KIND=''
rc=0
run_agent_cli 'AGENT_PROVIDER: codex' 10 || rc=$?
printf '\nRETURN_CODE=%s\n' "$rc"
if [[ "$FALLBACK_PROVIDER" == '' ]] && provider_failure_cooldown_active codex; then
    run_agent_cli 'prompt' 10 || true
fi
''' + after
            env = dict(os.environ, TEST_DIR=tmp, PRIMARY_OUTPUT=primary,
                       FALLBACK_OUTPUT=fallback or '', PRIMARY_RC=str(primary_rc),
                       FALLBACK_RC=str(fallback_rc), FALLBACK_PROVIDER='claude' if fallback is not None else '')
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            files = {p.name: p.read_text() for p in Path(tmp).iterdir() if p.is_file()}
            return result.stdout, files

    def test_nonzero_quota_failure_preserves_diagnostics_and_cooldown(self):
        output, files = self.run_attempts('quota exceeded: retry later')
        self.assertIn('quota exceeded: retry later', output)
        self.assertIn("provider 'codex' is cooling down", output)
        self.assertIn('head=quota exceeded: retry later', files['provider_failure_state'])
        self.assertEqual(files['attempts'].splitlines(), ['codex'])

    def test_primary_and_fallback_failures_preserve_both_diagnostics(self):
        output, files = self.run_attempts('quota exceeded: primary', 'quota exceeded: fallback', primary_rc=0)
        self.assertIn('quota exceeded: primary', output)
        self.assertIn('quota exceeded: fallback', output)
        self.assertIn('fallback provider claude also failed', output)
        self.assertIn('provider=codex', files['provider_failure_state'])
        self.assertIn('provider=claude', files['provider_failure_state'])

    def test_both_failed_providers_remain_on_cooldown_across_calls(self):
        output, files = self.run_attempts('quota exceeded: primary', 'quota exceeded: fallback', after=r'''
run_agent_cli prompt 10 || true
printf '\n'
''')
        self.assertEqual(files['attempts'].splitlines(), ['codex', 'claude'])
        self.assertIn("provider 'codex' is cooling down", output)
        self.assertIn("provider 'claude' is cooling down", output)
        state = files['provider_failure_state']
        self.assertEqual(state.count('provider=codex\n'), 1)
        self.assertEqual(state.count('provider=claude\n'), 1)

    def test_successful_fallback_keeps_primary_cooldown(self):
        output, files = self.run_attempts('quota exceeded: primary', 'STATUS: done\nSUMMARY: worked', fallback_rc=0, after=r'''
run_agent_cli prompt 10 || true
''')
        self.assertEqual(files['attempts'].splitlines(), ['codex', 'claude', 'claude'])
        self.assertIn('provider=codex', files['provider_failure_state'])
        self.assertNotIn('provider=claude', files['provider_failure_state'])

    def test_expiration_and_success_clear_only_the_matching_provider(self):
        output, files = self.run_attempts('quota exceeded: primary', 'quota exceeded: fallback', after=r'''
PROVIDER_FAILURE_COOLDOWN_SECONDS=-1
record_provider_failure_cooldown codex quota_auth expired
provider_failure_cooldown_active codex && exit 20
provider_failure_cooldown_active claude || exit 21
printf 'REMAINING_HEAD=%s\n' "$(provider_failure_state_field head claude)"
clear_provider_failure_state_if_matches codex
provider_failure_cooldown_active claude || exit 22
clear_provider_failure_state_if_matches claude
[[ ! -e "$PROVIDER_FAILURE_STATE" ]] || exit 23
''')
        self.assertIn('REMAINING_HEAD=quota exceeded: fallback', output)
        self.assertNotIn('provider_failure_state', files)

    def test_existing_single_provider_state_and_snapshot_remain_supported(self):
        snapshot = (ROOT / 'scripts/cortex_ops_snapshot.sh').read_text()
        helpers = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', snapshot, re.M | re.S)[0]
                            for name in ('state_file_value', 'compact_age', 'provider_cooldown_summary'))
        output, files = self.run_attempts('quota exceeded: legacy', after=helpers + r'''
# The initial state is byte-compatible with the old single-provider format.
provider_failure_cooldown_active codex || exit 20
mkdir -p "$TEST_DIR/agents/fixture"
cp "$PROVIDER_FAILURE_STATE" "$TEST_DIR/agents/fixture/provider_failure_state"
cd "$TEST_DIR"
now="$(date +%s)"
provider_cooldown_summary fixture || exit 21
record_provider_failure_cooldown claude quota_auth 'quota exceeded: fallback'
cp "$PROVIDER_FAILURE_STATE" agents/fixture/provider_failure_state
printf '\nBOTH: '
provider_cooldown_summary fixture || exit 22
printf '\n'
clear_provider_failure_state_if_matches codex
provider_failure_cooldown_active claude || exit 23
''')
        self.assertIn('codex quota_auth cooldown', output.split('BOTH:', 1)[1])
        self.assertIn('claude quota_auth cooldown', output.split('BOTH:', 1)[1])
        self.assertIn('provider=claude', files['provider_failure_state'])
        self.assertNotIn('provider=codex', files['provider_failure_state'])

    def test_fallback_success_and_nonzero_structured_salvage(self):
        output, files = self.run_attempts('primary failed', 'STATUS: done\nSUMMARY: fallback worked', fallback_rc=0)
        self.assertIn('RETURN_CODE=0', output)
        self.assertIn('fallback worked', output)
        self.assertTrue(output.startswith('STATUS: done'), output)
        self.assertNotIn('LOG:', output)
        self.assertEqual(files['attempts'].splitlines(), ['codex', 'claude'])
        output, files = self.run_attempts('STATUS: done\nSUMMARY: salvaged', primary_rc=1)
        self.assertIn('RETURN_CODE=0', output)
        self.assertIn('salvaged', output)
        self.assertTrue(output.startswith('STATUS: done'), output)
        self.assertNotIn('LOG:', output)

    def test_timed_out_partial_structured_output_is_not_success(self):
        output, files = self.run_attempts('STATUS: done\nSUMMARY: partial timeout result', 'fallback unavailable', primary_rc=124)
        self.assertIn('RETURN_CODE=1', output)
        self.assertIn('partial timeout result', output)
        self.assertIn('fallback unavailable', output)
        self.assertEqual(files['attempts'].splitlines(), ['codex', 'claude'])

    @unittest.skipUnless(shutil.which('timeout') or shutil.which('gtimeout'), 'requires coreutils timeout')
    def test_watchdog_term_and_kill_and_external_kill(self):
        real_timeout = shutil.which('timeout') or shutil.which('gtimeout')
        for hard_kill in (False, True):
            with self.subTest(hard_kill=hard_kill), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                # Keep the real group-kill behavior, shorten escalation only for this fixture.
                shim = root / 'timeout'
                shim.write_text('#!/bin/bash\nargs=()\nfor arg in "$@"; do\n'
                                '[[ "$arg" != --kill-after=30s ]] || arg=--kill-after=0.1s\n'
                                'args+=("$arg")\ndone\nexec ' + repr(real_timeout) + ' "${args[@]}"\n')
                shim.chmod(0o755)
                provider = root / 'provider'
                provider.write_text('#!/bin/bash\n' + ("trap '' TERM\n" if hard_kill else '') + "printf 'partial provider output\\n'\nwhile :; do sleep 0.1; done\n")
                provider.chmod(0o755)
                script = f'source "{ROOT}/scripts/bash_compat.sh"\n' + function('run_agent_cli_single_provider') + r'''
start_work_heartbeat() { :; }
stop_work_heartbeat() { :; }
cortex_usage_record_from_file() { :; }
log() { :; }
role_run_provider_cli() {
    local timeout_ref="$5"
    run_with_array_prefix "$timeout_ref" "$TEST_PROVIDER" > "$3" 2>&1
}
AGENT_DIR="$TEST_ROOT"
AGENT_ROLE=node
AGENT_PROVIDER=claude
AGENT_ID=fixture
AGENT_RUN_MODE=persistent
CORTEX_DIR="$TEST_ROOT"
CODEX_MODEL=dummy
CLAUDE_MODEL=dummy
rc=0
run_agent_cli_single_provider prompt 1 || rc=$?
printf '\nRETURN_CODE=%s\n' "$rc"
'''
                result = subprocess.run(['bash', '-c', script], env=dict(os.environ, PATH=tmp+':'+os.environ['PATH'], TEST_ROOT=tmp, TEST_PROVIDER=str(provider)), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('RETURN_CODE=124', result.stdout)
                self.assertIn('exceeded 1s', result.stdout)
                self.assertIn('partial provider output', result.stdout)
        output, _ = self.run_attempts('externally killed', primary_rc=137)
        self.assertIn('RETURN_CODE=1', output)
        self.assertNotIn('exceeded', output)


class TranscriptTests(unittest.TestCase):
    def write_history(self, root, provider, native_id, marker, prompt='owned question', answer='owned answer'):
        startup = f'Read CONDUCTOR.md and follow it.\nCORTEX_TRANSCRIPT_SESSION: {marker}'
        if provider == 'codex':
            path = root / f'rollout-{native_id}.jsonl'
            records = [{'type': 'session_meta', 'payload': {'id': native_id, 'cwd': '/fixture', 'originator': 'codex-tui', 'thread_source': 'user'}}]
            for role, text in [('user', startup), ('user', prompt), ('assistant', answer)]:
                records.append({'type': 'response_item', 'timestamp': '2026-01-01T12:00:00Z', 'payload': {'type': 'message', 'role': role, 'phase': 'final_answer', 'content': [{'type': 'input_text' if role == 'user' else 'output_text', 'text': text}]}})
        else:
            path = root / f'{native_id}.jsonl'
            records = []
            for role, text in [('user', startup), ('user', prompt), ('assistant', answer)]:
                records.append({'type': role, 'timestamp': '2026-01-01T12:00:00Z', 'cwd': '/fixture', 'sessionId': native_id, 'userType': 'external', 'entrypoint': 'cli', 'message': {'role': role, 'stop_reason': 'end_turn', 'content': text if role == 'user' else [{'type': 'text', 'text': text}]}})
        path.write_text(''.join(json.dumps(item)+'\n' for item in records))
        return path

    def test_concurrent_windows_discovery_filtering_resume_and_cursors(self):
        for provider in ('codex', 'claude'):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                owned = self.write_history(root, provider, 'owned-native', 'window-a')
                self.write_history(root, provider, 'foreign-native', 'window-b', 'foreign question', 'foreign answer')
                context = patch.object(sync, 'codex_sessions_root' if provider == 'codex' else 'claude_project_dir', return_value=root)
                with context:
                    self.assertEqual(sync.find_provider_session('/fixture', provider, 'window-a'), 'owned-native')
                    collector = sync.collect_codex_entries if provider == 'codex' else sync.collect_claude_entries
                    entries, prompts, answers = collector('/fixture', set(), {}, {}, 0, True, 'owned-native')
                    self.assertEqual([item['text'] for item in entries], ['owned question', 'owned answer'])
                    self.assertEqual(collector('/fixture', set(), {}, {}, 0, True)[0], [])
                    self.assertEqual(collector('/fixture', set(), prompts, answers, 0, True, 'owned-native')[0], [])
                    # Explicit resume stays on the selected id even if a peer becomes newer.
                    self.write_history(root, provider, 'foreign-native', 'window-b', 'new foreign question', 'new foreign answer')
                    entries, _, _ = collector('/fixture', set(), {}, {}, 0, True, 'owned-native')
                    self.assertEqual([item['text'] for item in entries], ['owned question', 'owned answer'])
                    self.write_history(root, provider, 'duplicate-native', 'window-a')
                    with self.assertRaises(ValueError):
                        sync.find_provider_session('/fixture', provider, 'window-a')

    def test_bound_claude_session_keeps_turns_after_cwd_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = self.write_history(root, 'claude', 'owned', 'window-a')
            records = [json.loads(line) for line in path.read_text().splitlines()]
            for record in records[1:]:
                record['cwd'] = '/fixture/subproject'
            # A foreign record must remain excluded even inside the owned file.
            foreign = dict(records[1], sessionId='foreign', cwd='/fixture/subproject',
                           message={'role': 'user', 'content': 'foreign question'})
            path.write_text(''.join(json.dumps(record)+'\n' for record in records+[foreign]))
            self.write_history(root, 'claude', 'peer', 'window-b', 'peer question', 'peer answer')
            with patch.object(sync, 'claude_project_dir', return_value=root):
                self.assertEqual(sync.find_provider_session('/fixture', 'claude', 'window-a'), 'owned')
                entries, prompts, answers = sync.collect_claude_entries('/fixture', set(), {}, {}, 0, True, 'owned')
                self.assertEqual([entry['text'] for entry in entries], ['owned question', 'owned answer'])
                self.assertEqual(sync.collect_claude_entries('/fixture', set(), prompts, answers, 0, True, 'owned')[0], [])

    def test_resume_baselines_old_history_and_collects_only_new_turns(self):
        for provider in ('codex', 'claude'):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                history = root / 'history'
                history.mkdir()
                session = root / 'session'
                session.mkdir()
                path = self.write_history(history, provider, 'owned', 'original-window')
                args = ['sync', '--cwd', '/fixture', '--session-dir', str(session), '--provider', provider, '--provider-session-id', 'owned']
                with patch.object(sys, 'argv', args), patch.object(sync, 'codex_sessions_root' if provider == 'codex' else 'claude_project_dir', return_value=history), patch.dict(os.environ, {'CORTEX_PROMPT_LOG_DISABLE': '0', 'CORTEX_PROMPT_LOG_RETENTION_DAYS': '0'}), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(sync.main(), 0)
                    self.assertNotIn('owned question', (session / 'prompt_log.txt').read_text())
                    last = json.loads(path.read_text().splitlines()[-1])
                    if provider == 'codex':
                        last['payload']['content'][0]['text'] = 'resumed answer'
                    else:
                        last['message']['content'][0]['text'] = 'resumed answer'
                    with path.open('a') as handle:
                        handle.write(json.dumps(last)+'\n')
                    self.assertEqual(sync.main(), 0)
                    transcript = (session / 'prompt_log.txt').read_text()
                    self.assertIn('resumed answer', transcript)
                    self.assertNotIn('owned answer', transcript)

    def test_launcher_passes_markers_and_exact_resume_ids(self):
        source = (ROOT / 'cortex.sh').read_text()
        prompt_function = re.search(r'^cortex_conductor_prompt\(\) \{\n.*?^\}', source, re.M | re.S)[0]
        launch = source.split('# ── Launch conductor chat session', 1)[1].split('\n', 1)[1]
        for provider in ('codex', 'claude'):
            for resume in (0, 1):
                script = prompt_function + r'''
cortex_projects_initialized() { return 0; }
cortex_usage_new_claude_session_id() { printf 'new-claude-id'; }
run_conductor_provider() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1:]))' "$@"; }
MODEL=''
CONDUCTOR_TIER=''
CLAUDE_EFFORT_EXPLICIT=0
CODEX_REASONING_EFFORT_EXPLICIT=0
NO_ALT_SCREEN=0
PERMISSION_ARG_COUNT=0
CONDUCTOR_PROVIDER_SESSION_ID=selected-native-id
CONDUCTOR_SESSION_ID=unique-window-marker
STARTUP_CHECKS=0
''' + launch
                result = subprocess.run(['bash', '-c', script], env=dict(os.environ, CORTEX_DIR=str(ROOT), PROVIDER=provider, RESUME_LAST=str(resume)), capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(result.stdout)
                if resume:
                    self.assertIn('selected-native-id', args)
                    self.assertNotIn('--last', args)
                    self.assertNotIn('--continue', args)
                else:
                    self.assertIn('CORTEX_TRANSCRIPT_SESSION: unique-window-marker', args[-1])
                    if provider == 'claude':
                        self.assertIn('--session-id', args)

    def test_daemon_forwards_the_exact_binding_on_initial_and_final_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            daemon = root / 'prompt_log_sync_daemon.sh'
            daemon.write_text((ROOT / 'scripts/prompt_log_sync_daemon.sh').read_text())
            (root / 'prompt_log_sync.py').touch()
            session = root / 'session'
            session.mkdir()
            fakebin = root / 'bin'
            fakebin.mkdir()
            capture = root / 'calls'
            python = fakebin / 'python3'
            python.write_text('#!/bin/sh\nprintf \'%s\\0\' "$@" >> "$CAPTURE"\n')
            python.chmod(0o755)
            result = subprocess.run(['bash', str(daemon), '--cwd', '/fixture', '--session-dir', str(session), '--provider', 'codex', '--provider-session-id', 'exact-native', '--session-marker', 'window-a', '--parent-pid', '99999999'], env=dict(os.environ, PATH=str(fakebin)+':'+os.environ['PATH'], CAPTURE=str(capture), CORTEX_PROMPT_LOG_DISABLE='0'), capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = capture.read_bytes().decode().split('\0')
            self.assertEqual(args.count('--provider-session-id'), 2)
            self.assertEqual(args.count('exact-native'), 2)
            self.assertEqual(args.count('window-a'), 2)

    def test_main_persists_binding_and_rejects_switches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            history = root / 'history'
            history.mkdir()
            session = root / 'session'
            session.mkdir()
            self.write_history(history, 'codex', 'owned', 'window-a')
            self.write_history(history, 'codex', 'foreign', 'window-b')
            args = ['sync', '--cwd', '/fixture', '--session-dir', str(session), '--provider', 'codex', '--session-marker', 'window-a', '--backfill']
            with patch.object(sys, 'argv', args), patch.object(sync, 'codex_sessions_root', return_value=history), patch.dict(os.environ, {'CORTEX_PROMPT_LOG_DISABLE': '0', 'CORTEX_PROMPT_LOG_RETENTION_DAYS': '0'}), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sync.main(), 0)
                self.assertEqual(sync.main(), 0)
                transcript = (session / 'prompt_log.txt').read_text()
                self.assertEqual(transcript.count('owned question'), 1)
                self.assertNotIn('foreign', transcript)
                state = json.loads((session / '.prompt_log_state.json').read_text())
                self.assertEqual(state['provider_binding'], {'provider': 'codex', 'session_id': 'owned'})
                with patch.object(sys, 'argv', args+['--provider-session-id', 'foreign']), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(sync.main(), 2)
                self.assertEqual((session / 'prompt_log.txt').read_text(), transcript)
            # Resolve-only still works when transcript logging is disabled.
            with patch.object(sys, 'argv', ['sync', '--cwd', '/fixture', '--resolve-session', 'codex']), patch.object(sync, 'codex_sessions_root', return_value=history), patch.dict(os.environ, {'CORTEX_PROMPT_LOG_DISABLE': '1'}), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(sync.main(), 0)
                self.assertIn(output.getvalue().strip(), ('owned', 'foreign'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
