#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(node --version)" == "v24.16.0" ]] || { echo 'Use Node 24.16.0'; exit 1; }
python3 scripts/setup_gleam.py
# The token is only for the compiler download; later commands (deps, npm, Playwright) do not need it.
unset GITHUB_TOKEN
.tools/gleam deps download
# npm writes node_modules/.package-lock.json on install; skip the reinstall while it is newer than the lock.
[ node_modules/.package-lock.json -nt package-lock.json ] || npm ci
npx --no-install playwright install chromium
