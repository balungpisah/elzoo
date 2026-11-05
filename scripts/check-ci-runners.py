#!/usr/bin/env python3
"""Enforce the project's canonical symbolic-only runner selector."""
import pathlib
import re
import sys

expected = "runs-on: [self-hosted, linux, x64, symbolic, elzoo]"
files = sorted(pathlib.Path('.github/workflows').glob('*.y*ml'))
errors = []
if not files:
    errors.append('No workflows found')
for file in files:
    lines = file.read_text().splitlines()
    selectors = [line.strip() for line in lines if re.match(r'\s*runs-on\s*:', line)]
    if not selectors or any(line != expected for line in selectors):
        errors.append(f'{file}: every job must use {expected}')
    if any(re.match(r'\s*uses:\s*.*\.github/workflows/', line) for line in lines):
        errors.append(f'{file}: reusable workflow runners need explicit policy review')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('All workflow runner selectors target symbolic; no hosted fallback')
