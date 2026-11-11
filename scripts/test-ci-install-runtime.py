#!/usr/bin/env python3
"""Simulated apt controls; no repositories or installed packages are changed."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('runtime', Path(__file__).with_name('ci-install-runtime.py'))
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
AZURE = 'http://azure.archive.ubuntu.com/ubuntu/'
ARCHIVE = 'https://archive.ubuntu.com/ubuntu/'
SOURCE = ('Types: deb\nURIs: {uri}\nSuites: noble\n noble-updates noble-backports\n'
          'Components: main restricted universe multiverse\n'
          'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\n'
          '# Unrelated stanza and its whitespace must remain unchanged.\n'
          'Types: deb\nURIs:  https://third-party.invalid/repo\t\nSuites: stable\n'
          'Components: main\nSigned-By: /etc/apt/keyrings/other.gpg\n')


class RuntimeProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apt = self.root / 'etc/apt'
        (self.apt / 'sources.list.d').mkdir(parents=True)
        self.source = self.apt / 'sources.list.d/ubuntu.sources'
        self.source.write_text(SOURCE.format(uri=AZURE))
        self.other = self.apt / 'sources.list.d/other.list'
        self.other.write_text('deb [signed-by=/other.gpg] https://other.invalid stable main\n')
        self.trace = self.root / 'calls.jsonl'
        binary = self.root / 'apt-get'
        binary.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
trace = pathlib.Path(os.environ['APT_TRACE'])
calls = trace.read_text().splitlines() if trace.exists() else []
with trace.open('a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'install' and os.environ.get('DEBIAN_FRONTEND') != 'noninteractive':
    sys.exit(98)
statuses = json.loads(os.environ['APT_STATUSES'])
sys.exit(statuses[len(calls)] if len(calls) < len(statuses) else 99)
''')
        binary.chmod(0o755)

    def provision(self, statuses, failure=None):
        self.output = io.StringIO()
        env = {'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
               'APT_TRACE': str(self.trace), 'APT_STATUSES': json.dumps(statuses)}
        with patch.object(runtime, 'APT', self.apt), patch.dict(os.environ, env), contextlib.redirect_stdout(self.output):
            if failure:
                with self.assertRaises(failure):
                    runtime.main()
            else:
                runtime.main()
        self.assertEqual('deb [signed-by=/other.gpg] https://other.invalid stable main\n', self.other.read_text())
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def test_primary_success_does_not_read_or_change_sources(self):
        self.source.unlink()
        calls = self.provision([0, 0])
        self.assertEqual([['update'], ['install', '-y', '--no-install-recommends',
                                     'libncurses6', 'libsctp1', 'libssl3']], calls)
        self.assertFalse(self.source.exists())
        self.assertNotIn('fallback', self.output.getvalue())

    def test_primary_install_failure_uses_one_strict_refresh_and_same_packages(self):
        calls = self.provision([0, 100, 0, 0])
        self.assertEqual([['update'], ['install', '-y', '--no-install-recommends',
                                     'libncurses6', 'libsctp1', 'libssl3'],
                          ['-o', 'APT::Update::Error-Mode=any', 'update'],
                          ['install', '-y', '--no-install-recommends',
                           'libncurses6', 'libsctp1', 'libssl3']], calls)
        self.assertEqual(SOURCE.format(uri=ARCHIVE), self.source.read_text())
        self.assertIn('apt exit 100', self.output.getvalue())

    def test_observed_mirror_file_form_and_primary_refresh_failure(self):
        self.source.write_text(SOURCE.format(uri='mirror+file:/etc/apt/apt-mirrors.txt'))
        mirrors = self.apt / 'apt-mirrors.txt'
        original = ('http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n'
                    'https://archive.ubuntu.com/ubuntu/\tpriority:2\n'
                    'https://security.ubuntu.com/ubuntu/\tpriority:3\n')
        mirrors.write_text(original)
        calls = self.provision([100, 0, 0])
        self.assertEqual(3, len(calls))
        self.assertEqual(['-o', 'APT::Update::Error-Mode=any', 'update'], calls[1])
        self.assertEqual(SOURCE.format(uri=ARCHIVE), self.source.read_text())
        self.assertEqual(original, mirrors.read_text())

    def test_failed_fresh_refresh_never_attempts_cached_install(self):
        calls = self.provision([100, 100], subprocess.CalledProcessError)
        self.assertEqual([['update'], ['-o', 'APT::Update::Error-Mode=any', 'update']], calls)

    def test_failed_final_install_does_not_repeat_fallback(self):
        calls = self.provision([100, 0, 100], subprocess.CalledProcessError)
        self.assertEqual(3, len(calls))
        self.assertEqual(['install', '-y', '--no-install-recommends',
                          'libncurses6', 'libsctp1', 'libssl3'], calls[-1])
        self.assertEqual(1, self.output.getvalue().count('Retrying runtime provisioning once'))

    def test_unsupported_sources_refuse_without_mutation_or_install(self):
        for uri in ('https://other.invalid/ubuntu/', 'http://azure.archive.ubuntu.com.evil/ubuntu/',
                    'http://archive.ubuntu.com/other/', 'mirror+file:/tmp/other-mirrors.txt',
                    'mirror+file:/etc/apt/apt-mirrors.txt'):
            with self.subTest(uri=uri):
                self.trace.unlink(missing_ok=True)
                original = SOURCE.format(uri=uri)
                self.source.write_text(original)
                (self.apt / 'apt-mirrors.txt').write_text('https://other.invalid/ubuntu/\n')
                calls = self.provision([100], ValueError)
                self.assertEqual([['update']], calls)
                self.assertEqual(original, self.source.read_text())
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_continued_uris_refuse_unchanged_before_fallback(self):
        for continuation in (' https://other.invalid/ubuntu/',
                             '\thttps://other.invalid/ubuntu/',
                             '# An intervening comment\n https://other.invalid/ubuntu/'):
            with self.subTest(continuation=continuation):
                self.trace.unlink(missing_ok=True)
                original = SOURCE.format(uri=AZURE + '\n' + continuation)
                self.source.write_text(original)
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertEqual(original, self.source.read_text())
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_disabled_or_comment_only_official_source_refuses_unchanged(self):
        for original in ('Enabled: no\n' + SOURCE.format(uri=AZURE),
                         '# URIs: ' + AZURE + '\n' + SOURCE.format(uri='https://other.invalid/')):
            with self.subTest(source=original):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(original)
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertEqual(original, self.source.read_text())

    def test_unsupported_legacy_layout_is_not_rewritten(self):
        self.source.unlink()
        legacy = self.apt / 'sources.list'
        original = 'deb ' + AZURE + ' noble main\n'
        legacy.write_text(original)
        self.assertEqual([['update']], self.provision([100], FileNotFoundError))
        self.assertEqual(original, legacy.read_text())


if __name__ == '__main__':
    unittest.main()
