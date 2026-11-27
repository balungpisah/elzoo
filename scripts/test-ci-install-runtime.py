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
STANZA = ('Types: deb\nURIs: {uri}\nSuites: noble\n noble-updates noble-backports\n'
          'Components: main restricted universe multiverse\n'
          'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n')
THIRD_PARTY = ('# Unrelated stanza and its whitespace must remain unchanged.\n'
               'Types: deb\nURIs:  https://third-party.invalid/repo\t\nSuites: stable\n'
               'Components: main\nSigned-By: /etc/apt/keyrings/other.gpg\n')
SOURCE = STANZA + '\n' + THIRD_PARTY
ARCHIVE_STANZA = STANZA.format(uri=ARCHIVE)
INSTALL = ['install', '-y', '--no-install-recommends', 'libncurses6', 'libsctp1', 'libssl3']
ONLY = ['-o', 'Dir::Etc::sourcelist=TEMP', '-o', 'Dir::Etc::sourceparts=-']
FALLBACK_UPDATE = ONLY + ['-o', 'APT::Update::Error-Mode=any', 'update']
FALLBACK_INSTALL = ONLY + INSTALL


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
        # The stub records each argument list and the text of the source list it names.
        binary.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
trace = pathlib.Path(os.environ['APT_TRACE'])
calls = trace.read_text().splitlines() if trace.exists() else []
lists = [pathlib.Path(arg.split('=', 1)[1]) for arg in sys.argv if arg.startswith('Dir::Etc::sourcelist=')]
with trace.open('a') as output:
    output.write(json.dumps({'args': sys.argv[1:],
                             'lists': [path.read_text() if path.exists() else None for path in lists]}) + '\\n')
if 'install' in sys.argv[1:] and os.environ.get('DEBIAN_FRONTEND') != 'noninteractive':
    sys.exit(98)
statuses = json.loads(os.environ['APT_STATUSES'])
sys.exit(statuses[len(calls)] if len(calls) < len(statuses) else 99)
''')
        binary.chmod(0o755)

    def provision(self, statuses, failure=None):
        """Runs the installer; returns argument lists with the temporary list path as TEMP."""
        self.output = io.StringIO()
        original = self.source.read_text() if self.source.exists() else None
        env = {'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
               'APT_TRACE': str(self.trace), 'APT_STATUSES': json.dumps(statuses)}
        with patch.object(runtime, 'APT', self.apt), patch.dict(os.environ, env), contextlib.redirect_stdout(self.output):
            if failure:
                with self.assertRaises(failure):
                    runtime.main()
            else:
                runtime.main()
        self.assertEqual('deb [signed-by=/other.gpg] https://other.invalid stable main\n', self.other.read_text())
        self.assertEqual(original, self.source.read_text() if self.source.exists() else None)
        records = [json.loads(line) for line in self.trace.read_text().splitlines()]
        paths = {arg.split('=', 1)[1] for record in records for arg in record['args']
                 if arg.startswith('Dir::Etc::sourcelist=')}
        self.assertLessEqual(len(paths), 1)
        for path in paths:
            self.assertTrue(path.endswith('.sources'))
            self.assertFalse(Path(path).exists())
            self.assertFalse(Path(path).is_relative_to(self.apt))
        self.lists = [text for record in records for text in record['lists']]
        return [[('Dir::Etc::sourcelist=TEMP' if arg.startswith('Dir::Etc::sourcelist=') else arg)
                 for arg in record['args']] for record in records]

    def test_primary_success_does_not_read_or_change_sources(self):
        self.source.unlink()
        calls = self.provision([0, 0])
        self.assertEqual([['update'], INSTALL], calls)
        self.assertEqual([], self.lists)
        self.assertNotIn('fallback', self.output.getvalue())

    def test_fallback_update_and_install_name_only_the_temporary_archive_list(self):
        calls = self.provision([0, 100, 0, 0])
        self.assertEqual([['update'], INSTALL, FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
        self.assertEqual([ARCHIVE_STANZA, ARCHIVE_STANZA], self.lists)
        self.assertIn('apt exit 100', self.output.getvalue())

    def test_third_party_stanzas_of_ubuntu_sources_are_not_read(self):
        security = STANZA.format(uri='http://archive.ubuntu.com/ubuntu').replace(
            'noble\n noble-updates noble-backports', 'noble-security')
        self.source.write_text(STANZA.format(uri=AZURE) + '\n \n\t\n' + THIRD_PARTY + '\n\n'
                               + security + '\n' + THIRD_PARTY.replace('third-party', 'another'))
        calls = self.provision([100, 0, 0])
        self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
        expected = ARCHIVE_STANZA + '\n' + security.replace('http://archive.ubuntu.com/ubuntu', ARCHIVE)
        self.assertEqual([expected, expected], self.lists)

    def test_unrelated_uri_mixed_into_an_official_stanza_is_omitted(self):
        for uris in (AZURE + ' https://third-party.invalid/repo',
                     'https://third-party.invalid/repo\t' + ARCHIVE + ' ' + AZURE):
            with self.subTest(uris=uris):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(SOURCE.format(uri=uris))
                calls = self.provision([100, 0, 0])
                self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
                self.assertEqual([ARCHIVE_STANZA, ARCHIVE_STANZA], self.lists)

    def test_observed_mirror_file_form_and_primary_refresh_failure(self):
        self.source.write_text(SOURCE.format(uri='mirror+file:/etc/apt/apt-mirrors.txt'))
        mirrors = self.apt / 'apt-mirrors.txt'
        original = ('http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n'
                    'https://archive.ubuntu.com/ubuntu/\tpriority:2\n'
                    'https://security.ubuntu.com/ubuntu/\tpriority:3\n')
        mirrors.write_text(original)
        calls = self.provision([100, 0, 0])
        self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
        self.assertEqual([ARCHIVE_STANZA, ARCHIVE_STANZA], self.lists)
        self.assertEqual(original, mirrors.read_text())

    def test_failed_fresh_refresh_never_attempts_cached_install(self):
        calls = self.provision([100, 100], subprocess.CalledProcessError)
        self.assertEqual([['update'], FALLBACK_UPDATE], calls)

    def test_failed_final_install_does_not_repeat_fallback(self):
        calls = self.provision([100, 0, 100], subprocess.CalledProcessError)
        self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
        self.assertEqual(1, self.output.getvalue().count('Retrying runtime provisioning once'))

    def test_unsupported_sources_refuse_without_mutation_or_install(self):
        for uri in ('https://other.invalid/ubuntu/', 'http://azure.archive.ubuntu.com.evil/ubuntu/',
                    'http://archive.ubuntu.com/other/', 'mirror+file:/tmp/other-mirrors.txt',
                    'mirror+file:/etc/apt/apt-mirrors.txt'):
            with self.subTest(uri=uri):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(SOURCE.format(uri=uri))
                (self.apt / 'apt-mirrors.txt').write_text('https://other.invalid/ubuntu/\n')
                calls = self.provision([100], ValueError)
                self.assertEqual([['update']], calls)
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_continued_uris_refuse_unchanged_before_fallback(self):
        for continuation in (' https://other.invalid/ubuntu/',
                             '\thttps://other.invalid/ubuntu/',
                             '# An intervening comment\n https://other.invalid/ubuntu/'):
            with self.subTest(continuation=continuation):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(SOURCE.format(uri=AZURE + '\n' + continuation))
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_disabled_repeated_or_comment_only_official_source_refuses_unchanged(self):
        for original in ('Enabled: no\n' + SOURCE.format(uri=AZURE),
                         SOURCE.format(uri=AZURE + '\nuris: https://other.invalid/ubuntu/'),
                         '# URIs: ' + AZURE + '\n' + SOURCE.format(uri='https://other.invalid/')):
            with self.subTest(source=original):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(original)
                self.assertEqual([['update']], self.provision([100], ValueError))

    def test_unsupported_legacy_layout_is_not_rewritten(self):
        self.source.unlink()
        legacy = self.apt / 'sources.list'
        original = 'deb ' + AZURE + ' noble main\n'
        legacy.write_text(original)
        self.assertEqual([['update']], self.provision([100], FileNotFoundError))
        self.assertEqual(original, legacy.read_text())


if __name__ == '__main__':
    unittest.main()
