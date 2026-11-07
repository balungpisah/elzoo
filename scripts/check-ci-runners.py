#!/usr/bin/env python3
"""Check the repository's canonical user-owned runner routing convention."""
import pathlib
import re
import sys

expected = {
    "symbolic-check.yml": "runs-on: [self-hosted, linux, x64, elzoo, backend]",
    "symbolic-gleam.yml": "runs-on: [self-hosted, linux, x64, symbolic, elzoo, gleam]",
}
# Approved triggers: push to main, same-repository pull_request, workflow_dispatch.
# pull_request_target and every other event need a new reviewed policy.
expected_triggers = [
    "on:",
    "  push:",
    "    branches: [main]",
    "  pull_request:",
    "  workflow_dispatch:",
]
digest_image = re.compile(r'\s+image:\s*[^\s@\'"]+@sha256:[0-9a-f]{64}\s*')
quoted_key = re.compile(r'\s*(?:-\s*)?(["\'])[^"\']*\1\s*:(?:\s|$)')
# Plain block scalars (`key: |`, `key: >-`); explicit indentation digits are not
# recognised, so their content stays subject to every check.
block_scalar = re.compile(r'(\s*)(?:-\s+)?[A-Za-z0-9_-]+\s*:\s*[|>][+-]?\s*(?:#.*)?')


def scalar_or_comment_lines(lines):
    """Indexes of block-scalar content and full-line comments: text, never keys."""
    skip = set()
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith('#'):
            skip.add(i)
        m = block_scalar.fullmatch(lines[i])
        i += 1
        if not m:
            continue
        first = next((j for j in range(i, len(lines)) if lines[j].strip()), None)
        if first is None:
            break
        indent = len(lines[first]) - len(lines[first].lstrip(' '))
        if indent <= len(m.group(1)):
            continue
        while i < len(lines) and (not lines[i].strip() or lines[i][:indent] == ' ' * indent):
            skip.add(i)
            i += 1
    return skip


files = sorted(pathlib.Path('.github/workflows').glob('*.y*ml'))
errors = []
for name in expected.keys() - {file.name for file in files}:
    errors.append(f'Missing required workflow: {name}')
for file in files:
    if file.name not in expected:
        errors.append(f'{file}: new workflows require an explicit runner-role policy')
        continue
    lines = file.read_text().splitlines()
    on_roots = [i for i, line in enumerate(lines)
                if re.match(r'''^["']?(?:on|true)["']?\s*:''', line)]
    trigger_block = []
    if len(on_roots) == 1:
        start = on_roots[0]
        end = next((i for i in range(start + 1, len(lines))
                    if re.match(r'^[^\s#]', lines[i])), len(lines))
        trigger_block = [line.rstrip() for line in lines[start:end]
                         if line.strip() and not line.lstrip().startswith('#')]
    if trigger_block != expected_triggers:
        errors.append(f'{file}: triggers must be exactly push to main, pull_request and workflow_dispatch')
    # Script text and comments are not YAML keys; structure checks below still see every line.
    skip = scalar_or_comment_lines(lines)
    yaml_lines = [line for i, line in enumerate(lines) if i not in skip]
    if any('pull_request_target' in line for line in yaml_lines):
        errors.append(f'{file}: pull_request_target is not an approved trigger')
    if any(quoted_key.match(line) for line in yaml_lines):
        errors.append(f'{file}: quoted YAML keys are outside the reviewed source convention')
    if any('\t' in line[:len(line) - len(line.lstrip())] for line in lines):
        errors.append(f'{file}: tab indentation is outside the reviewed source convention')
    for line in yaml_lines:
        if re.match(r'\s*image\s*:', line) and not digest_image.fullmatch(line):
            errors.append(f'{file}: container images must be pinned by @sha256 digest: {line.strip()}')
        if re.fullmatch(r'\s*container\s*:\s*[^\s#].*', line):
            errors.append(f'{file}: container must be a mapping with a digest-pinned image')
    selectors = [line.strip() for line in lines if re.match(r'\s*runs-on\s*:', line)]
    if len(selectors) != 1 or selectors[0] != expected[file.name]:
        errors.append(f'{file}: every job must use {expected[file.name]}')
    required_job_gate = """    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}"""
    expected_job = 'check' if file.name == 'symbolic-check.yml' else 'gleam'
    jobs_roots = [i for i, line in enumerate(lines) if line == 'jobs:']
    job_headers = []
    end = len(lines)
    if len(jobs_roots) == 1:
        start = jobs_roots[0] + 1
        end = next((i for i in range(start, len(lines))
                    if re.match(r'^[^\s#]', lines[i])), len(lines))
        job_headers = [(i, m.group(1)) for i in range(start, end)
                       if (m := re.fullmatch(r'  ([A-Za-z_][A-Za-z0-9_-]*):\s*', lines[i]))]
        # Flow-style, aliased or explicit-key jobs would hide runs-on from the line checks:
        # every line indented less than a job body must be a bare block-style job header.
        for i in range(start, end):
            line = lines[i]
            indent = len(line) - len(line.lstrip(' '))
            if (line.strip() and not line.lstrip().startswith('#') and indent < 4
                    and not re.fullmatch(r'  [A-Za-z_][A-Za-z0-9_-]*:\s*', line)):
                errors.append(f'{file}: jobs must be block-style mappings: {line.strip()}')
    if len(job_headers) != 1 or job_headers[0][1] != expected_job:
        errors.append(f'{file}: exactly one {expected_job} job is required')
    elif job_headers[0][0] + 1 >= len(lines) or lines[job_headers[0][0] + 1] != required_job_gate:
        errors.append(f'{file}: same-repository PR job gate is missing or changed')
    # The job must keep its digest-pinned container; without it steps run on the host.
    containers = [i for i, line in enumerate(lines) if re.match(r'\s*(?:-\s*)?container\s*:', line)]
    if (len(containers) != 1 or lines[containers[0]] != '    container:'
            or len(job_headers) != 1 or not job_headers[0][0] < containers[0] < end - 1
            or not re.fullmatch(r'      image:\s*[^\s@\'"]+@sha256:[0-9a-f]{64}\s*',
                                lines[containers[0] + 1])):
        errors.append(f'{file}: the job must keep one container: mapping whose first key is a digest-pinned image')
    if file.name == 'symbolic-check.yml':
        required_gate = """      - name: Verify approved backend runner
        run: |
          case "$RUNNER_NAME" in
            symbolic-elzoo) ;;
            macbook-ubuntu-elzoo-candidate)
              echo 'ERL_FLAGS=+S 2:2 +SDcpu 1 +SDio 1' >> "$GITHUB_ENV"
              ;;
            *) echo "Unapproved backend runner: $RUNNER_NAME" >&2; exit 1 ;;
          esac
          echo "Backend runner: $RUNNER_NAME"
          free -h || true"""
        if required_gate not in file.read_text():
            errors.append(f'{file}: approved runner identity gate is missing or changed')
    if any(re.match(r'\s*(?:-\s*)?uses:\s*.*\.github/workflows/', line) for line in lines):
        errors.append(f'{file}: reusable workflow runners need explicit policy review')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('All workflow runner selectors use the reviewed user-owned roles; no hosted fallback')
