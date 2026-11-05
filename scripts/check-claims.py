#!/usr/bin/env python3
"""Reject claim metadata in a proposed/accepted tree, including dotfiles."""
import subprocess
import sys

result = subprocess.run(["git", "ls-files", "-z", "--", ".claims/"], check=True, capture_output=True)
paths = [p.decode(errors="replace") for p in result.stdout.split(b"\0") if p]
if paths:
    print("Remove tracked claim metadata before PR/merge: " + ", ".join(paths), file=sys.stderr)
    sys.exit(1)
print("No tracked claim metadata")
