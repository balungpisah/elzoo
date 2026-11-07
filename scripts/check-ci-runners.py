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
# ELZ-043: every action is pinned by a full commit SHA; a tag or branch can move.
pinned_action = re.compile(r'\s*(?:-\s+)?uses:\s*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}(?:\s+#.*)?')
quoted_key = re.compile(r'\s*(?:-\s*)?(["\'])[^"\']*\1\s*:(?:\s|$)')
# Plain block scalars (`key: |`, `key: >-`); explicit indentation digits are not
# recognised, so their content stays subject to every check.
block_scalar = re.compile(r'(\s*(?:-\s+)?)[A-Za-z0-9_-]+\s*:\s*[|>][+-]?\s*(?:#.*)?')


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
        if indent <= len(m.group(1)):  # content must be deeper than the key column
            continue
        while i < len(lines) and (not lines[i].strip() or lines[i][:indent] == ' ' * indent):
            skip.add(i)
            i += 1
    return skip


def line_problem(line):
    """Reject YAML forms the reviewed workflows never use, so line checks see every key.

    Not a parser: it only walks node starts on one line and fails closed.
    """
    i, n, depth, start = 0, len(line), 0, True
    flow_mapping = False
    while i < n:
        c = line[i]
        if c in ' \t':
            i += 1
            continue
        if c == '#' and (i == 0 or line[i - 1] in ' \t'):
            break
        if start:
            if c in '"\'':
                j = i + 1
                while True:
                    if j >= n:
                        return 'quoted scalars must close on the same line'
                    if c == '"' and line[j] == '\\':
                        j += 2
                        continue
                    if line[j] == c:
                        if c == "'" and j + 1 < n and line[j + 1] == "'":
                            j += 2
                            continue
                        break
                    j += 1
                i, start = j + 1, False
                continue
            if c in '[{':
                flow_mapping = flow_mapping or c == '{'
                depth += 1
                i += 1
                continue
            if depth and c in ']}':
                depth -= 1
                i, start = i + 1, False
                continue
            if c == '-' and not depth and (i + 1 == n or line[i + 1] == ' '):
                i += 1
                continue
            if c in '&*?!%@`':
                return 'anchors, aliases, tags and explicit keys are outside the reviewed source convention'
            if line.startswith('<<', i):
                return 'merge keys are outside the reviewed source convention'
            j = i
            while j < n:
                d = line[j]
                if d == ':' and (j + 1 == n or line[j + 1] == ' '
                                 or (depth and line[j + 1] in ',[]{}')):
                    break
                if d == '#' and j > i and line[j - 1] in ' \t':
                    break
                if depth and d in ',[]{}':
                    break
                j += 1
            i, start = j, False
            continue
        if c == ':' or (depth and c == ','):
            i, start = i + 1, True
            continue
        if depth and c in ']}':
            depth -= 1
            i += 1
            continue
        return 'unexpected YAML token'
    if depth:
        return 'flow collections must close on the same line'
    if flow_mapping:
        return 'flow mappings are outside the reviewed source convention'
    return None


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
    for line in yaml_lines:
        if problem := line_problem(line):
            errors.append(f'{file}: {problem}: {line.strip()}')
    if any(re.match(r'(?:---|\.\.\.)(?:\s|$)|%', line) for line in lines):
        errors.append(f'{file}: one YAML document without directives is required')
    if any('pull_request_target' in line for line in yaml_lines):
        errors.append(f'{file}: pull_request_target is not an approved trigger')
    if any(quoted_key.match(line) for line in yaml_lines):
        errors.append(f'{file}: quoted YAML keys are outside the reviewed source convention')
    if any('\t' in line[:len(line) - len(line.lstrip())] for line in lines):
        errors.append(f'{file}: tab indentation is outside the reviewed source convention')
    for line in yaml_lines:
        if re.match(r'\s*image\s*:', line) and not digest_image.fullmatch(line):
            errors.append(f'{file}: container images must be pinned by @sha256 digest: {line.strip()}')
        if re.match(r'\s*(?:-\s*)?uses\s*:', line) and not pinned_action.fullmatch(line):
            errors.append(f'{file}: actions must be pinned by a full commit SHA: {line.strip()}')
        if re.fullmatch(r'\s*container\s*:\s*[^\s#].*', line):
            errors.append(f'{file}: container must be a mapping with a digest-pinned image')
    selectors = [i for i, line in enumerate(lines) if re.match(r'\s*(?:-\s*)?runs-on\s*:', line)]
    if (len(selectors) != 1 or selectors[0] in skip
            or lines[selectors[0]] != '    ' + expected[file.name]):
        errors.append(f'{file}: every job must use {expected[file.name]}')
    required_job_gate = """    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}"""
    expected_job = 'check' if file.name == 'symbolic-check.yml' else 'gleam'
    jobs_roots = [i for i, line in enumerate(lines) if line == 'jobs:']
    job_headers = []
    end = len(lines)
    if len(jobs_roots) == 1:
        start = jobs_roots[0] + 1
        if any(re.match(r'^[^\s#]', line) for line in lines[start:]):
            errors.append(f'{file}: jobs: must be the last top-level key')
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
            or containers[0] in skip or containers[0] + 1 in skip
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
