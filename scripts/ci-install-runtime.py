#!/usr/bin/env python3
"""One official-archive fallback for the hosted Ubuntu runtime libraries."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

APT = Path('/etc/apt')
ARCHIVE = 'https://archive.ubuntu.com/ubuntu/'
OFFICIAL = re.compile(r'https?://(?:azure\.archive\.ubuntu\.com|archive\.ubuntu\.com)/ubuntu/?\Z')
MIRROR = 'mirror+file:/etc/apt/apt-mirrors.txt'
PACKAGES = ['libncurses6', 'libsctp1', 'libssl3']


def archive_sources():
    # Ubuntu 24.04's canonical deb822 source only: no arbitrary repository scan,
    # URI substring replacement, legacy source parser or mirror discovery.
    text = (APT / 'sources.list.d/ubuntu.sources').read_text()
    # Apt reads a line of only whitespace as a continuation, not a stanza boundary.
    if re.search(r'(?m)^[ \t]+$', text):
        raise ValueError('unsupported Ubuntu source: whitespace-only line')

    def official(uri):
        if uri == MIRROR:
            mirrors = (APT / 'apt-mirrors.txt').read_text().splitlines()
            # Hosted mirror lines have an official URI followed by priority:N.
            return any(OFFICIAL.fullmatch(line.split()[0]) for line in mirrors if line.strip())
        return OFFICIAL.fullmatch(uri)

    stanzas = []
    # Stanzas are separated by empty lines. Only stanzas with an official URI are
    # kept, and their URIs field names the archive alone, so other repositories of
    # the file, including URIs mixed into an official stanza, are not read.
    for stanza in re.split(r'\n{2,}', text.strip('\n')):
        lines = stanza.split('\n')
        fields = []  # [name, line index, continued] per field, named as apt compares them
        for index, line in enumerate(lines):
            if line.startswith('#'):  # apt drops comment lines before parsing
                continue
            if line[:1] in (' ', '\t'):
                if not fields:
                    raise ValueError('unsupported Ubuntu source: continuation without field')
                fields[-1][2] = True
                continue
            name, colon, _ = line.partition(':')
            if not colon:
                raise ValueError('unsupported Ubuntu source: line without field name')
            # Apt ignores whitespace before the colon and the case of field names.
            fields.append([name.strip().lower(), index, False])
        if any(name == 'enabled' for name, _, _ in fields):
            raise ValueError('unsupported Ubuntu source: explicit Enabled field')
        uris = [field for field in fields if field[0] == 'uris']
        if len(uris) > 1:  # apt would use the last occurrence
            raise ValueError('unsupported Ubuntu source: repeated URIs field')
        if not uris:
            continue
        _, index, continued = uris[0]
        if continued:
            raise ValueError('unsupported Ubuntu source: continued URIs field')
        if any(official(uri) for uri in lines[index].partition(':')[2].split()):
            lines[index] = 'URIs: ' + ARCHIVE
            stanzas.append('\n'.join(lines))
    if not stanzas:
        raise ValueError('unsupported Ubuntu source: no recognized official URI')
    return '\n\n'.join(stanzas) + '\n'


def install(options=()):
    subprocess.run(['apt-get', *options, 'install', '-y', '--no-install-recommends', *PACKAGES],
                   env=os.environ | {'DEBIAN_FRONTEND': 'noninteractive'}, check=True)


def main():
    try:
        subprocess.run(['apt-get', 'update'], check=True)
        install()
        return
    except subprocess.CalledProcessError as error:
        print(f'Primary runtime provisioning failed (apt exit {error.returncode}); '
              'checking official Ubuntu archive fallback', flush=True)
    sources = archive_sources()
    print('Retrying runtime provisioning once through archive.ubuntu.com', flush=True)
    with tempfile.TemporaryDirectory() as directory:
        sourcelist = Path(directory) / 'archive.sources'
        sourcelist.write_text(sources)
        parts = Path(directory) / 'parts'
        parts.mkdir()
        # apt.conf(5): Dir::Etc::sourcelist names the only main list (apt parses a
        # .sources main list as deb822) and Dir::Etc::sourceparts names an empty
        # directory instead of sources.list.d ("-" would resolve to /etc/apt/-/),
        # so third-party repositories cannot fail the fallback.
        only = ['-o', f'Dir::Etc::sourcelist={sourcelist}', '-o', f'Dir::Etc::sourceparts={parts}']
        # Ordinary update may exit zero with stale indexes after download failures;
        # --no-list-cleanup keeps the cached indexes of the sources not read here.
        subprocess.run(['apt-get', *only, '-o', 'APT::Update::Error-Mode=any', '--no-list-cleanup',
                        'update'], check=True)
        install(only)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Runtime provisioning failed: {error}', file=sys.stderr)
        sys.exit(1)
