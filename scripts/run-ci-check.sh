#!/bin/sh
# ELZ-049 MEASUREMENT COMMIT (reverted before the PR): repeat the three
# database-free consumer group files 20 times instead of mix check.
set -eu
report="${RUNNER_TEMP:?RUNNER_TEMP is required}/elzoo-ci-cpu.json"
python3 scripts/sample-ci-cpu.py "$report" &
sampler=$!
cleanup() {
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
}
trap cleanup EXIT
MIX_ENV=test mix compile
i=1
while [ "$i" -le 20 ]; do
  echo "ELZOO REPEAT $i start utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if mix test test/consumer_group_a_test.exs test/consumer_group_b_test.exs test/consumer_group_c_test.exs --warnings-as-errors; then
    echo "ELZOO REPEAT $i exit=0"
  else
    echo "ELZOO REPEAT $i exit=$?"
  fi
  i=$((i + 1))
done
