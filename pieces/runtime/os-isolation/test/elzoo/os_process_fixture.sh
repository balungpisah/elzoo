#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Harmless test fixture for runtime/os-isolation. Run as: /bin/sh os_process_fixture.sh <mode> [args]
# POSIX sh only; every mode terminates on its own within the given seconds or on a signal.
mode=$1; shift
case "$mode" in
  exit)        exit "${1:-0}" ;;
  echo)        printf '%s\n' "$@"; exit 0 ;;
  stderr)      printf 'out\n'; printf 'err\n' 1>&2; exit 0 ;;
  self-term)   kill -TERM $$; sleep 1; exit 99 ;;
  sleep)       sleep "${1:-30}"; exit 0 ;;
  ignore-term) trap '' TERM; printf 'ignoring\n'; sleep "${1:-30}"; exit 0 ;;
  child)       sleep "${1:-30}" & printf 'child %s\n' "$!"; wait; exit 0 ;;
  hold)        sleep "${1:-30}" & printf 'started\n'; exit 0 ;;
  linger)      sleep "${1:-30}" >/dev/null 2>&1 & printf 'linger %s\n' "$!"; exit 0 ;;
  linger-ignore)
               /bin/sh -c 'trap "" TERM; i=0; while [ "$i" -lt "$1" ]; do sleep 1; i=$((i+1)); done' sh "${1:-30}" >/dev/null 2>&1 &
               sleep 0.3; printf 'linger-ignore %s\n' "$!"; exit 0 ;;
  natural-exit) trap '' TERM; printf 'ignoring\n'; sleep "${1:-1}"; exit 0 ;;
  spew)        n=${1:-100000}; i=0; while [ "$i" -lt "$n" ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'; i=$((i+100)); done; exit 0 ;;
  env)         for name in "$@"; do eval "v=\${$name-__unset__}"; printf '%s=%s\n' "$name" "$v"; done; exit 0 ;;
  cwd)         pwd; exit 0 ;;
  *)           printf 'unknown mode %s\n' "$mode" 1>&2; exit 64 ;;
esac
