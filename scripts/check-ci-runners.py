#!/usr/bin/env python3
"""Enforce the project's canonical symbolic-only runner selector."""
import pathlib
import re
import sys

expected = {
    "symbolic-check.yml": "runs-on: [self-hosted, linux, x64, symbolic, elzoo, backend]",
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
    if any(re.match(r'\s*uses:\s*.*\.github/workflows/', line) for line in lines):
        errors.append(f'{file}: reusable workflow runners need explicit policy review')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('All workflow runner selectors target symbolic; no hosted fallback')
