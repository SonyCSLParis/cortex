#!/usr/bin/env python3
"""Exercise first-run exclusion provisioning and real rsync selection on fixtures."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TEMPLATES = ROOT / 'templates' / 'backup_excludes'


class BackupDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cortex-backup-defaults-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def test_bootstrap_creates_missing_defaults_and_preserves_local_changes(self):
        checkout = self.work / 'checkout'
        for folder in ['scripts', 'config']:
            (checkout / folder).mkdir(parents=True)
            for source in (ROOT / folder).glob('*.sh'):
                shutil.copy2(source, checkout / folder / source.name)
        shutil.copytree(TEMPLATES, checkout / 'templates' / 'backup_excludes')
        env = dict(os.environ, CORTEX_DIR=str(checkout),
                   CORTEX_DEFAULT_ROOT=str(checkout),
                   CORTEX_DEFAULT_ENV_NAME='example-env',
                   CORTEX_DEFAULT_ENV_DIR=str(checkout / 'environments/example-env'),
                   CORTEX_DEFAULT_ENV_SETTINGS_FILE=str(checkout / 'environments/example-env/settings.env'))
        command = ['bash', str(ROOT / 'cortex.sh'), '--init', '--user', 'example-user', '--env', 'example-env']
        def initialize():
            subprocess.run(command, env=env, check=True, capture_output=True, text=True)
        initialize()
        excludes = checkout / 'environments/example-env/backup_excludes'
        for mode in ['repo_worktree', 'source_tree', 'path']:
            self.assertEqual((excludes / (mode + '.txt')).read_bytes(),
                             (TEMPLATES / (mode + '.txt')).read_bytes())
        custom = excludes / 'repo_worktree.txt'
        custom.write_text('# local override\ncustom-cache/\n')
        (excludes / 'source_tree.txt').unlink()
        initialize()
        self.assertEqual(custom.read_text(), '# local override\ncustom-cache/\n')
        self.assertEqual((excludes / 'source_tree.txt').read_bytes(),
                         (TEMPLATES / 'source_tree.txt').read_bytes())

    def test_source_modes_exclude_generated_content_but_keep_results_and_lockfiles(self):
        excluded = ['nested/' + name + '/generated' for name in
                    ['.git', '.cache', '__pycache__', '.pytest_cache', '.mypy_cache',
                     '.ruff_cache', '.venv', 'venv', 'node_modules']]
        excluded += ['nested/module.pyc', 'nested/module.pyo', 'nested/.nfs123',
                     'nested/edit.swp', 'nested/edit.swo']
        retained = ['main.py', 'poetry.lock', 'yarn.lock', 'package-lock.json',
                    'nested/artifacts/result.npy', 'checkpoints/model.pt', 'paper/draft.tex',
                    'recordings/input.wav', 'recordings/input.mp3', 'logs/run.log',
                    'wandb/offline-run/data', 'output/result.csv', 'build/source.txt', 'dist/source.txt']
        source = self.work / 'source'
        for relative in excluded + retained:
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture\n')
        for mode in ['repo_worktree', 'source_tree', 'path']:
            manifest = self.work / (mode + '-targets.txt')
            manifest.write_text('fixture|' + mode + '|' + str(source) + '\n')
            destination = self.work / ('backup-' + mode)
            env = dict(os.environ, CORTEX_DIR=str(ROOT), BACKUP_ROOT=str(destination),
                       BACKUP_TARGETS_FILE=str(manifest), BACKUP_EXCLUDES_DIR=str(TEMPLATES), BACKUP_KEEP='1')
            result = subprocess.run(['bash', str(ROOT / 'roles/operational/backup/backup_snapshot.sh')],
                                    env=env, check=True, capture_output=True, text=True)
            self.assertIn('TARGET: fixture', result.stdout)
            snapshot = (destination / 'latest').resolve() / 'fixture'
            self.assertTrue(snapshot.is_dir())
            for relative in retained:
                self.assertTrue((snapshot / relative).is_file(), (mode, relative))
            for relative in excluded:
                expected = mode == 'path' and '.nfs123' not in relative
                self.assertEqual((snapshot / relative).exists(), expected, (mode, relative))



if __name__ == '__main__':
    unittest.main(verbosity=2)
