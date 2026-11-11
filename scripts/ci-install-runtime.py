#!/usr/bin/env python3
"""One official-archive fallback for the hosted Ubuntu runtime libraries."""
import os
from pathlib import Path
import re
import subprocess
import sys

APT = Path('/etc/apt')
ARCHIVE = 'https://archive.ubuntu.com/ubuntu/'
OFFICIAL = re.compile(r'https?://(?:azure\.archive\.ubuntu\.com|archive\.ubuntu\.com)/ubuntu/?\Z')
MIRROR = 'mirror+file:/etc/apt/apt-mirrors.txt'
PACKAGES = ['libncurses6', 'libsctp1', 'libssl3']


def use_archive():
    # Ubuntu 24.04's canonical deb822 source only: no arbitrary repository scan,
    # URI substring replacement, legacy source parser or mirror discovery.
    source = APT / 'sources.list.d/ubuntu.sources'
    text = source.read_text()
    if re.search(r'(?im)^Enabled:', text):
        raise ValueError('unsupported Ubuntu source: explicit Enabled field')
    if re.search(r'(?m)^URIs:[^\n]*(?:\n#[^\n]*)*\n[ \t]', text):
        raise ValueError('unsupported Ubuntu source: continued URIs field')
    matched = False

    def replace(match):
        nonlocal matched
        def uri_replace(token):
            nonlocal matched
            uri = token[0]
            official = OFFICIAL.fullmatch(uri)
            if uri == MIRROR:
                mirrors = (APT / 'apt-mirrors.txt').read_text().splitlines()
                # Hosted mirror lines have an official URI followed by priority:N.
                official = any(OFFICIAL.fullmatch(line.split()[0]) for line in mirrors if line.strip())
            if official:
                matched = True
                return ARCHIVE
            return uri
        return match[1] + re.sub(r'\S+', uri_replace, match[2])

    updated = re.sub(r'(?m)^(URIs:[ \t]+)([^\n]+)$', replace, text)
    if not matched:
        raise ValueError('unsupported Ubuntu source: no recognized official URI')
    source.write_text(updated)


def install():
    subprocess.run(['apt-get', 'install', '-y', '--no-install-recommends', *PACKAGES],
                   env=os.environ | {'DEBIAN_FRONTEND': 'noninteractive'}, check=True)


def main():
    try:
        subprocess.run(['apt-get', 'update'], check=True)
        install()
        return
    except subprocess.CalledProcessError as error:
        print(f'Primary runtime provisioning failed (apt exit {error.returncode}); '
              'checking official Ubuntu archive fallback', flush=True)
    use_archive()
    print('Retrying runtime provisioning once through archive.ubuntu.com', flush=True)
    # Ordinary update may exit zero with stale indexes after download failures.
    subprocess.run(['apt-get', '-o', 'APT::Update::Error-Mode=any', 'update'], check=True)
    install()


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Runtime provisioning failed: {error}', file=sys.stderr)
        sys.exit(1)
