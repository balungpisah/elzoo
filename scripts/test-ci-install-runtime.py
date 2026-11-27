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
STANZA = ('Types: deb\nURIs: {uri}\nSuites: noble noble-updates noble-backports\n'
          'Components: main restricted universe multiverse\n'
          'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n')
THIRD_PARTY = ('# Other stanzas are dropped, whatever fields they carry.\n'
               'Types: deb\nURIs:  https://third-party.invalid/repo\nSuites: stable\n testing\n'
               'Components: main\nTrusted: yes\nSigned-By: /etc/apt/keyrings/other.gpg\n')
SOURCE = STANZA + '\n' + THIRD_PARTY
ARCHIVE_STANZA = STANZA.format(uri=ARCHIVE)
INSTALL = ['install', '-y', '--no-install-recommends', 'libncurses6', 'libsctp1', 'libssl3']
ONLY = ['-o', 'Dir::Etc::sourcelist=TEMP/archive.sources', '-o', 'Dir::Etc::sourceparts=TEMP/parts']
FALLBACK_UPDATE = ONLY + ['-o', 'APT::Update::Error-Mode=any', '--no-list-cleanup', 'update']
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
        # The stub records each argument list, the text of the source list it names
        # and the entries of the source parts directory it names.
        binary.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
trace = pathlib.Path(os.environ['APT_TRACE'])
calls = trace.read_text().splitlines() if trace.exists() else []
def named(option):
    return [pathlib.Path(arg.split('=', 1)[1]) for arg in sys.argv if arg.startswith(option + '=')]
with trace.open('a') as output:
    output.write(json.dumps({'args': sys.argv[1:],
                             'lists': [path.read_text() if path.exists() else None
                                       for path in named('Dir::Etc::sourcelist')],
                             'parts': [sorted(os.listdir(path)) if path.is_dir() else None
                                       for path in named('Dir::Etc::sourceparts')]}) + '\\n')
if 'install' in sys.argv[1:] and os.environ.get('DEBIAN_FRONTEND') != 'noninteractive':
    sys.exit(98)
statuses = json.loads(os.environ['APT_STATUSES'])
sys.exit(statuses[len(calls)] if len(calls) < len(statuses) else 99)
''')
        binary.chmod(0o755)

    def provision(self, statuses, failure=None):
        """Runs the installer; returns argument lists with the temporary directory as TEMP."""
        self.output = io.StringIO()
        original = self.source.read_bytes() if self.source.exists() else None
        env = {'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
               'APT_TRACE': str(self.trace), 'APT_STATUSES': json.dumps(statuses)}
        with patch.object(runtime, 'APT', self.apt), patch.dict(os.environ, env), contextlib.redirect_stdout(self.output):
            if failure:
                with self.assertRaises(failure):
                    runtime.main()
            else:
                runtime.main()
        self.assertEqual('deb [signed-by=/other.gpg] https://other.invalid stable main\n', self.other.read_text())
        self.assertEqual(original, self.source.read_bytes() if self.source.exists() else None)
        records = [json.loads(line) for line in self.trace.read_text().splitlines()]
        paths = {arg.split('=', 1)[1] for record in records for arg in record['args']
                 if arg.startswith('Dir::Etc::sourcelist=')}
        self.assertLessEqual(len(paths), 1)
        directories = [str(Path(path).parent) for path in paths]
        for directory in directories:
            self.assertFalse(Path(directory).exists())
            self.assertFalse(Path(directory).is_relative_to(self.apt))
        self.lists = [text for record in records for text in record['lists']]
        self.assertEqual([[] for record in records if record['parts']],
                         [parts for record in records for parts in record['parts']])
        return [[arg.replace(directories[0], 'TEMP') if directories else arg for arg in record['args']]
                for record in records]

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
            'noble noble-updates noble-backports', 'noble-security')
        self.source.write_text(STANZA.format(uri=AZURE) + '\n\n\n' + THIRD_PARTY + '\n\n'
                               + security + '\n' + THIRD_PARTY.replace('third-party', 'another'))
        calls = self.provision([100, 0, 0])
        self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
        expected = ARCHIVE_STANZA + '\n' + security.replace('http://archive.ubuntu.com/ubuntu', ARCHIVE)
        self.assertEqual([expected, expected], self.lists)

    def test_unrelated_uri_mixed_into_an_official_stanza_is_omitted(self):
        for uris in (AZURE + ' https://third-party.invalid/repo',
                     'https://third-party.invalid/repo  ' + ARCHIVE + ' ' + AZURE):
            with self.subTest(uris=uris):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(SOURCE.format(uri=uris))
                calls = self.provision([100, 0, 0])
                self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], calls)
                self.assertEqual([ARCHIVE_STANZA, ARCHIVE_STANZA], self.lists)

    def test_generated_stanza_uses_only_validated_tokens(self):
        self.source.write_bytes(('# Comment\n' + SOURCE.format(uri=AZURE).replace('Types: deb', 'Types:\tdeb-src deb')
                                 .replace('Suites: ', 'Suites:  ')).replace('\n', '\r\n').encode())
        self.assertEqual([['update'], FALLBACK_UPDATE, FALLBACK_INSTALL], self.provision([100, 0, 0]))
        expected = ARCHIVE_STANZA.replace('Types: deb', 'Types: deb deb-src')
        self.assertEqual([expected, expected], self.lists)

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

    def test_official_uri_only_on_a_continuation_refuses_with_another_official_stanza(self):
        hidden = STANZA.format(uri='https://third-party.invalid/repo\n ' + AZURE).replace(
            'noble noble-updates noble-backports', 'noble-security')
        self.source.write_text(STANZA.format(uri=AZURE) + '\n' + hidden)
        self.assertEqual([['update']], self.provision([100], ValueError))
        self.assertNotIn('Retrying', self.output.getvalue())

    def test_disabled_repeated_or_comment_only_official_source_refuses_unchanged(self):
        for original in ('Enabled: no\n' + SOURCE.format(uri=AZURE),
                         SOURCE + 'Enabled : no\n',
                         SOURCE.format(uri=AZURE + '\nuris: https://other.invalid/ubuntu/'),
                         SOURCE.format(uri=AZURE + '\nURIs : https://third-party.invalid/repo'),
                         SOURCE.format(uri=AZURE + '\nURIS\t:https://third-party.invalid/repo'),
                         '# URIs: ' + AZURE + '\n' + SOURCE.format(uri='https://other.invalid/')):
            with self.subTest(source=original):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(original.format(uri=AZURE))
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_whitespace_only_line_refuses_before_apt(self):
        # Apt reads such a line as a continuation, so it does not end the stanza.
        for original in (SOURCE.format(uri=AZURE).replace('\nSigned-By', '\n \nSigned-By', 1),
                         SOURCE.format(uri=AZURE).replace('\nSigned-By', '\n\t\nSigned-By', 1),
                         STANZA.format(uri=AZURE) + ' \n' + THIRD_PARTY):
            with self.subTest(source=original):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(original)
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_bytes_outside_the_four_line_forms_refuse_before_apt(self):
        official = SOURCE.format(uri=AZURE)
        for original in (official.replace('URIs: ', 'URIs: \f').encode(),
                         official.replace('URIs: ', 'URIs: \v').encode(),
                         official.replace('URIs:', 'URIs\N{NO-BREAK SPACE}:').encode(),
                         official.replace(AZURE, AZURE + '\N{NO-BREAK SPACE}https://third-party.invalid/').encode(),
                         b'# comment\r' + official.encode(),
                         official.replace('Types', 'Types\x00').encode(),
                         official.replace('Types:', ' Types:').encode(),
                         official.replace('URIs: ', 'URIs:  ').replace('\n', '\r\n').replace('\r\nSuites', '\nSuites\r').encode()):
            with self.subTest(source=original):
                self.trace.unlink(missing_ok=True)
                self.source.write_bytes(original)
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_official_stanza_outside_the_generated_shape_refuses_before_apt(self):
        official = STANZA.format(uri=AZURE)
        for original in (official + 'Trusted: yes\n',
                         official.replace('Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n', ''),
                         official.replace('/usr/share/', 'usr/share/'),
                         official.replace('.gpg', '.gpg /etc/apt/keyrings/other.gpg'),
                         official.replace('/usr/share/keyrings/', '/usr/share/key rings/'),
                         official.replace('Types: deb', 'Types: deb rpm'),
                         official.replace('noble-backports', 'noble-backports;x'),
                         official.replace('main restricted', 'Main restricted'),
                         official.replace('Suites: noble', 'Suites: noble\n')):
            with self.subTest(source=original):
                self.trace.unlink(missing_ok=True)
                self.source.write_text(original + '\n' + THIRD_PARTY)
                self.assertEqual([['update']], self.provision([100], ValueError))
                self.assertNotIn('Retrying', self.output.getvalue())

    def test_unsupported_legacy_layout_is_not_rewritten(self):
        self.source.unlink()
        legacy = self.apt / 'sources.list'
        original = 'deb ' + AZURE + ' noble main\n'
        legacy.write_text(original)
        self.assertEqual([['update']], self.provision([100], FileNotFoundError))
        self.assertEqual(original, legacy.read_text())


if __name__ == '__main__':
    unittest.main()
