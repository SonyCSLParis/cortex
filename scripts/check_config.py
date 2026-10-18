#!/usr/bin/env python3
"""Read-only configuration diagnostics. Never print setting values or auth output."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def diagnose(root: Path) -> tuple[int, list[str]]:
    warnings: list[str] = []
    errors: list[str] = []
    env = dict(os.environ, CORTEX_DIR=str(root))
    default_root = Path(env.get('CORTEX_DEFAULT_ROOT', str(root)))
    name = env.get('CORTEX_DEFAULT_ENV_NAME') or env.get('CORTEX_ENV')
    pointer = Path(env.get('CORTEX_DEFAULT_ENV_POINTER_FILE', str(default_root / 'environment.instruct')))
    if not name and pointer.is_file():
        match = re.search(r'environments/([A-Za-z0-9._-]+)/[A-Za-z0-9._-]+\.instruct', pointer.read_text())
        if match:
            name = match[1]
    directory = Path(env.get('CORTEX_DEFAULT_ENV_DIR', str(default_root / 'environments' / (name or 'default'))))
    settings = Path(env.get('CORTEX_DEFAULT_ENV_SETTINGS_FILE', str(directory / 'settings.env')))
    if not settings.is_file():
        warnings.append('settings.env is missing; initialize or select an environment profile')
    else:
        syntax = subprocess.run(['bash', '-n', str(settings)], capture_output=True)
        if syntax.returncode:
            return 2, ['settings.env has invalid shell syntax (values suppressed)']
        # Learn supported names from framework source, not private overlays or this checker.
        known: set[str] = set()
        sources = [root / 'cortex.sh']
        for folder in ('config', 'roles', 'scripts'):
            sources.extend((root / folder).rglob('*.sh'))
            sources.extend((root / folder).rglob('*.py'))
        for source in sources:
            if source.resolve() == Path(__file__).resolve() or 'tests' in source.parts:
                continue
            known.update(re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', source.read_text(errors='replace')))
        for line in settings.read_text().splitlines():
            match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=', line)
            if match and match[1] not in known:
                warnings.append(f'unknown settings key: {match[1]} (check spelling or document local use)')

    # Settings are executable shell, just as in normal launchers. Suppress their
    # stdout and keep the resulting environment private to this process.
    try:
        loaded = subprocess.run(
            ['bash', '-c', 'set -a; source "$1" >/dev/null || exit 2; exec python3 -c '\
             '\'import json, os; print(json.dumps(dict(os.environ)))\'',
             'config-check', str(root / 'config/cortex_defaults.sh')],
            env=env, capture_output=True, text=True, timeout=10)
        if loaded.returncode:
            return 2, ['could not load environment defaults (output suppressed)']
        env = json.loads(loaded.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 2, ['could not load environment defaults within 10 seconds']

    for key in ('CORTEX_PROMPT_LOG_DISABLE', 'CORTEX_TTY_RECORDING_DISABLE', 'CORTEX_USAGE_DISABLE'):
        if env.get(key, '0') not in ('0', '1'):
            errors.append(f'{key} must be 0 or 1')
    if not re.fullmatch(r'[0-9]+', env.get('CORTEX_PROMPT_LOG_RETENTION_DAYS', '0')):
        errors.append('CORTEX_PROMPT_LOG_RETENTION_DAYS must be a nonnegative integer')
    interval = env.get('CORTEX_PROMPT_LOG_SYNC_INTERVAL', '5')
    if not re.fullmatch(r'[0-9]+', interval) or int(interval) < 1:
        errors.append('CORTEX_PROMPT_LOG_SYNC_INTERVAL must be a positive integer')
    backend = env.get('CORTEX_SESSION_BACKEND', env.get('CORTEX_DEFAULT_SESSION_BACKEND', 'screen'))
    if backend not in ('screen', 'tmux'):
        errors.append('session backend must be screen or tmux')
    elif not shutil.which(backend, path=env.get('PATH')):
        warnings.append(f'session backend executable is missing: {backend}')
    sandbox = env.get('CORTEX_WORKER_SANDBOX_BACKEND', 'auto')
    if sandbox not in ('auto', 'bwrap', 'macos-direct'):
        errors.append('worker sandbox backend must be auto, bwrap, or macos-direct')
    elif sandbox == 'macos-direct' and sys.platform != 'darwin':
        errors.append('macos-direct is supported only on macOS')
    elif (sandbox == 'bwrap' or sys.platform != 'darwin') and not shutil.which('bwrap', path=env.get('PATH')):
        warnings.append('bwrap is missing; workers using this backend cannot start')
    elif sys.platform == 'darwin' and (sandbox == 'macos-direct' or (sandbox == 'auto' and not shutil.which('bwrap', path=env.get('PATH')))):
        warnings.append('workers use macos-direct without launcher filesystem isolation')
    if '/' in env.get('CORTEX_RESEARCH_RO_BASE', '/').split(':'):
        warnings.append('research read base includes host root /; reads are broad except credential masks')

    excludes = Path(env.get('BACKUP_EXCLUDES_DIR', str(Path(env.get('CORTEX_DEFAULT_ENV_DIR', str(directory))) / 'backup_excludes')))
    for mode in ('repo_worktree', 'source_tree', 'path'):
        if not (excludes / f'{mode}.txt').is_file():
            warnings.append(f'backup exclusion file is missing: {mode}.txt')
    for channel in ('SIGNAL', 'TELEGRAM'):
        relay = env.get(f'{channel}_RELAY_HOST') or env.get(f'CORTEX_DEFAULT_{channel}_RELAY_HOST')
        if relay:
            secret = Path(env.get(f'{channel}_SECRETS_FILE') or env.get(f'CORTEX_DEFAULT_{channel}_SECRETS_FILE', str(default_root / 'agents/conductor/secrets' / f'{channel.lower()}.env')))
            if not secret.is_file():
                warnings.append(f'{channel.lower()} relay is configured but its secrets file is missing')

    conductor = env.get('CORTEX_CONDUCTOR_PROVIDER', 'codex')
    agent = env.get('CORTEX_AGENT_PROVIDER', 'claude')
    permission = env.get('CORTEX_CONDUCTOR_PERMISSION_MODE', 'provider-default')
    valid_modes = ('provider-default', 'default', 'full-access', 'auto-review') if conductor == 'codex' else ('provider-default', 'default', 'full-access')
    if permission not in valid_modes:
        errors.append('conductor permission preset is unsupported for the selected provider')
    # Shipped named workers choose Codex when the general provider is unset.
    for provider in sorted({conductor, agent, env.get('CORTEX_AGENT_PROVIDER', 'codex')}):
        if provider not in ('codex', 'claude'):
            errors.append('provider must be codex or claude')
            continue
        executable = shutil.which(provider, path=env.get('PATH'))
        if not executable:
            warnings.append(f'{provider} CLI is missing')
            continue
        args = ['login', 'status'] if provider == 'codex' else ['auth', 'status']
        try:
            status = subprocess.run([executable, *args], env=env, capture_output=True, text=True, timeout=10)
            if provider == 'codex':
                ready = status.returncode == 0 and re.search(r'^Logged in\b', status.stdout + status.stderr, re.M | re.I) is not None
            else:
                auth = json.loads(status.stdout)
                ready = status.returncode == 0 and isinstance(auth, dict) and auth.get('loggedIn') is True
            if not ready:
                warnings.append(f'{provider} login could not be confirmed; sign in with its CLI')
        except (OSError, ValueError, subprocess.TimeoutExpired):
            warnings.append(f'{provider} login check failed or exceeded 10 seconds')
    return (2 if errors else 1 if warnings else 0), errors + warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    code, findings = diagnose(args.root.resolve())
    for finding in findings:
        print('- ' + finding)
    return code


if __name__ == '__main__':
    sys.exit(main())
