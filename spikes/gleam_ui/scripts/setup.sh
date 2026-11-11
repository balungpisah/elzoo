#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(node --version)" == "v24.16.0" ]] || { echo 'Use Node 24.16.0'; exit 1; }
python3 scripts/setup_gleam.py
# The token is only for the compiler download; later commands (deps, npm, Playwright) do not need it.
unset GITHUB_TOKEN
.tools/gleam deps download
# npm writes node_modules/.package-lock.json on install. Skip the reinstall while it is newer than the
# lock and every package it lists is still present.
if ! { [ node_modules/.package-lock.json -nt package-lock.json ] && node -e '
  const fs = require("fs");
  const installed = JSON.parse(fs.readFileSync("node_modules/.package-lock.json", "utf8")).packages;
  for (const path of Object.keys(installed)) if (path && !fs.existsSync(path + "/package.json")) process.exit(1);
'; }; then
  npm ci
fi
npx --no-install playwright install chromium
