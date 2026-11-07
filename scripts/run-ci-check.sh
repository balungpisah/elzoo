#!/bin/sh
# Run the same public check while collecting an independent bounded CPU sample.
set -eu
report="${RUNNER_TEMP:?RUNNER_TEMP is required}/elzoo-ci-cpu.json"
python3 scripts/sample-ci-cpu.py "$report" &
sampler=$!
cleanup() {
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
}
trap cleanup EXIT
mix check "$@"
