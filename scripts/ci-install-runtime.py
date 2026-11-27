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
# The four line forms accepted in ubuntu.sources; anything else is refused.
COMMENT = re.compile(r'#[ -~]*')
CONTINUATION = re.compile(r'[ \t][ -~]*')
FIELD = re.compile(r'([A-Za-z][A-Za-z0-9-]*):[ \t]?[ -~]*')
TOKEN = re.compile(r'[a-z0-9][a-z0-9.+-]*')
KEYRING = re.compile(r'/[A-Za-z0-9._/-]+')
OFFICIAL_FIELDS = {'types', 'uris', 'suites', 'components', 'signed-by'}


def unsupported(reason):
    return ValueError('unsupported Ubuntu source: ' + reason)


def ascii_text(path):
    # Bytes, so no newline translation: LF, or CRLF with no bare CR left; tab is
    # the only other control byte accepted, and only where a line form allows it.
    data = path.read_bytes().replace(b'\r\n', b'\n')
    if re.search(rb'[^\t\n -~]', data):
        raise unsupported(f'{path.name} has a non-ASCII or control byte')
    return data.decode('ascii')


def official(uri):
    if uri == MIRROR:
        # Hosted mirror lines have an official URI followed by priority:N.
        return any(OFFICIAL.fullmatch(re.findall(r'[!-~]+', line)[0])
                   for line in ascii_text(APT / 'apt-mirrors.txt').split('\n') if line.strip(' \t'))
    return OFFICIAL.fullmatch(uri)


def parse_stanzas(text):
    """Returns each stanza as {lowercase field name: [tokens, continued]}."""
    stanzas, fields, last = [], {}, None
    for line in text.split('\n') + ['']:
        if not line:  # an empty line separates stanzas
            if fields:
                stanzas.append(fields)
            fields, last = {}, None
        elif line[0] == '#':
            if not COMMENT.fullmatch(line):
                raise unsupported('malformed comment line')
        elif line[0] in ' \t':
            if not CONTINUATION.fullmatch(line) or last is None:
                raise unsupported('malformed continuation line')
            fields[last][1] = True
        else:
            match = FIELD.fullmatch(line)
            if not match:
                raise unsupported('line is not a comment, continuation or field')
            last = match[1].lower()  # apt compares field names ASCII-case-insensitively
            if last in fields:
                raise unsupported(f'repeated {match[1]} field')
            if last == 'enabled':
                raise unsupported('explicit Enabled field')
            fields[last] = [re.findall(r'[!-~]+', line[match.end(1) + 1:]), False]
    return stanzas


def archive_sources():
    # Ubuntu 24.04's canonical deb822 source only: no arbitrary repository scan,
    # URI substring replacement, legacy source parser or mirror discovery. No input
    # text is copied: each stanza with an official URI is generated from validated
    # tokens with the archive as its only URI, and every other stanza is dropped.
    generated = []
    for stanza in parse_stanzas(ascii_text(APT / 'sources.list.d/ubuntu.sources')):
        if not any(official(uri) for uri in stanza.get('uris', [[]])[0]):
            continue
        if set(stanza) != OFFICIAL_FIELDS:
            raise unsupported('official stanza fields other than Types, URIs, Suites, Components and Signed-By')
        if any(continued for _, continued in stanza.values()):
            raise unsupported('continued field in an official stanza')
        types = stanza['types'][0]
        suites = stanza['suites'][0]
        components = stanza['components'][0]
        keyring = stanza['signed-by'][0]
        if not types or not set(types) <= {'deb', 'deb-src'}:
            raise unsupported('official stanza types other than deb and deb-src')
        if not suites or not components or not all(TOKEN.fullmatch(token) for token in suites + components):
            raise unsupported('official stanza suite or component token')
        if len(keyring) != 1 or not KEYRING.fullmatch(keyring[0]):
            raise unsupported('official stanza Signed-By is not one absolute keyring path')
        generated.append('\n'.join([
            'Types: ' + ' '.join(kind for kind in ('deb', 'deb-src') if kind in types),
            'URIs: ' + ARCHIVE,
            'Suites: ' + ' '.join(suites),
            'Components: ' + ' '.join(components),
            'Signed-By: ' + keyring[0]]))
    if not generated:
        raise unsupported('no recognized official URI')
    return '\n\n'.join(generated) + '\n'


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
