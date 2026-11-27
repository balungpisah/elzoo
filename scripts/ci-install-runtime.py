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
    if re.search(r'(?im)^Enabled:', text):
        raise ValueError('unsupported Ubuntu source: explicit Enabled field')
    if re.search(r'(?im)^URIs:[^\n]*(?:\n#[^\n]*)*\n[ \t]', text):
        raise ValueError('unsupported Ubuntu source: continued URIs field')

    def official(uri):
        if uri == MIRROR:
            mirrors = (APT / 'apt-mirrors.txt').read_text().splitlines()
            # Hosted mirror lines have an official URI followed by priority:N.
            return any(OFFICIAL.fullmatch(line.split()[0]) for line in mirrors if line.strip())
        return OFFICIAL.fullmatch(uri)

    stanzas = []
    # Deb822 stanzas are separated by blank lines. Only stanzas with an official
    # URI are kept, and their URIs field names the archive alone, so other
    # repositories of the file, including URIs mixed into an official stanza,
    # are not read.
    for stanza in re.split(r'\n(?:[ \t]*\n)+', text):
        fields = re.findall(r'(?im)^URIs:[ \t]*([^\n]*)$', stanza)
        if len(fields) > 1:
            raise ValueError('unsupported Ubuntu source: repeated URIs field')
        if fields and any(official(uri) for uri in fields[0].split()):
            stanzas.append(re.sub(r'(?im)^URIs:[^\n]*$', 'URIs: ' + ARCHIVE, stanza).strip('\n'))
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
        # apt.conf(5): Dir::Etc::sourcelist names the only main list (apt parses a
        # .sources main list as deb822) and Dir::Etc::sourceparts=- reads no
        # sources.list.d, so third-party repositories cannot fail the fallback.
        only = ['-o', f'Dir::Etc::sourcelist={sourcelist}', '-o', 'Dir::Etc::sourceparts=-']
        # Ordinary update may exit zero with stale indexes after download failures.
        subprocess.run(['apt-get', *only, '-o', 'APT::Update::Error-Mode=any', 'update'], check=True)
        install(only)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Runtime provisioning failed: {error}', file=sys.stderr)
        sys.exit(1)
