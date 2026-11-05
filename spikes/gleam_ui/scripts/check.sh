#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(node --version)" == "v24.16.0" ]] || { echo 'Use Node 24.16.0'; exit 1; }
[[ "$(.tools/gleam --version)" == "gleam 1.19.2" ]] || { echo 'Run scripts/setup.sh'; exit 1; }
.tools/gleam format --check
.tools/gleam test --target javascript
.tools/gleam test --target erlang
.tools/gleam build --target javascript --warnings-as-errors
python3 scripts/package.py
npm test
