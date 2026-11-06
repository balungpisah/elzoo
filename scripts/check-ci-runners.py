#!/usr/bin/env python3
"""Check the repository's canonical user-owned runner routing convention."""
import pathlib
import re
import sys

expected = {
    "symbolic-check.yml": """runs-on: ${{ github.event_name == 'pull_request' && github.head_ref == 'task/ELZ-034' && fromJSON('["self-hosted","linux","x64","macbook-ubuntu","elzoo","ci-candidate"]') || fromJSON('["self-hosted","linux","x64","elzoo","backend"]') }}""",
    "symbolic-gleam.yml": "runs-on: [self-hosted, linux, x64, symbolic, elzoo, gleam]",
}
files = sorted(pathlib.Path('.github/workflows').glob('*.y*ml'))
errors = []
for name in expected.keys() - {file.name for file in files}:
    errors.append(f'Missing required workflow: {name}')
for file in files:
    if file.name not in expected:
        errors.append(f'{file}: new workflows require an explicit runner-role policy')
        continue
    lines = file.read_text().splitlines()
    selectors = [line.strip() for line in lines if re.match(r'\s*runs-on\s*:', line)]
    if not selectors or any(line != expected[file.name] for line in selectors):
        errors.append(f'{file}: every job must use {expected[file.name]}')
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
