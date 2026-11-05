#!/usr/bin/env python3
"""Measure BEAM scheduler choices in an otherwise idle Linux CI container.

Run from a disposable, prepared checkout after mix setup && mix check.
This deliberately rebuilds the Ash experiment's dependencies in compile mode.
Logs and JSONL measurements go to an explicit directory outside the checkout.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def cpu_seconds():
    fields = dict(line.split() for line in Path('/sys/fs/cgroup/cpu.stat').read_text().splitlines())
    return int(fields['usage_usec']) / 1_000_000


def memory_bytes():
    return int(Path('/sys/fs/cgroup/memory.current').read_text())


def validate_revision(revision):
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if actual != revision:
        raise ValueError('--revision must match the checkout HEAD')
    status = subprocess.check_output(
        ['git', 'status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'],
        text=True,
    )
    if status:
        raise ValueError('Benchmark requires a clean checkout, including untracked files')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--mode', choices=['warm', 'compile', 'gleam', 'serial', 'parallel'], default='warm')
    parser.add_argument('--schedulers', type=int, nargs='+', default=[2, 4, 8, 8, 4, 2])
    args = parser.parse_args()
    if any(value not in (2, 4, 8) for value in args.schedulers):
        parser.error('scheduler candidates must be 2, 4 or 8')
    try:
        validate_revision(args.revision)
    except ValueError as error:
        parser.error(str(error))
    args.output.mkdir(parents=True, exist_ok=False)

    for index, schedulers in enumerate(args.schedulers, 1):
        # Change only normal schedulers; dirty settings match the baseline.
        flags = f'+S {schedulers}:{schedulers} +SDcpu 1 +SDio 1'
        env = dict(os.environ, ERL_FLAGS=flags, MIX_ENV='test')
        actual = subprocess.check_output(
            ['elixir', '-e', 'IO.puts(:erlang.system_info(:schedulers_online))'],
            env=env, text=True,
        ).strip()
        if int(actual) != schedulers:
            raise RuntimeError(f'Expected {schedulers} schedulers, got {actual}')
        command = ['mix', 'check']
        if args.mode == 'compile':
            command = ['sh', '-ec',
                       '(cd spikes/ash_foundation && mix deps.compile --force && mix clean); '
                       'mix clean; mix check']
        if args.mode == 'gleam':
            command = ['sh', '-ec', 'cd spikes/gleam_ui && ./scripts/check.sh']
        gleam_command = ('cd spikes/gleam_ui && '
                         'ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1" ./scripts/check.sh')
        if args.mode == 'serial':
            command = ['sh', '-ec', f'mix check; ({gleam_command})']
        if args.mode == 'parallel':
            # These workloads write to separate build trees. Wait for both and
            # propagate either failure, rather than hiding a background exit.
            command = ['sh', '-c',
                       'mix check & backend=$!; '
                       f'({gleam_command}) & gleam=$!; '
                       'result=0; wait "$backend" || result=$?; '
                       'wait "$gleam" || result=$?; exit "$result"']
        log_path = args.output / f'{index:02d}-s{schedulers}.log'
        cpu_before = cpu_seconds()
        peak_memory = memory_bytes()
        started = time.monotonic()
        with log_path.open('w') as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None:
                peak_memory = max(peak_memory, memory_bytes())
                time.sleep(0.1)
        elapsed = time.monotonic() - started
        cpu = cpu_seconds() - cpu_before
        log_text = log_path.read_text()
        record = {
            'revision': args.revision, 'mode': args.mode, 'sample': index,
            'erl_flags': flags, 'command': command, 'exit_code': process.returncode,
            'gleam_erl_flags': '+S 2:2 +SDcpu 1 +SDio 1' if args.mode in ('serial', 'parallel') else None,
            'wall_seconds': round(elapsed, 3), 'container_cpu_seconds': round(cpu, 3),
            'average_cpu_cores': round(cpu / elapsed, 3),
            # Includes container page cache; not BEAM heap or summed process RSS.
            'sampled_container_memory_peak_bytes': peak_memory,
            'backend_check_passed': 'ELZOO CHECK PASSED' in log_text,
            'browser_check_passed': 'Browser host check passed:' in log_text,
            'host_loadavg': Path('/proc/loadavg').read_text().strip(),
            'log': str(log_path),
        }
        with (args.output / 'results.jsonl').open('a') as output:
            output.write(json.dumps(record) + '\n')
        print(json.dumps(record), flush=True)
        if process.returncode:
            raise SystemExit(process.returncode)
        if args.mode != 'gleam' and not record['backend_check_passed']:
            raise RuntimeError(f'Backend acceptance marker missing: {log_path}')
        if args.mode in ('gleam', 'serial', 'parallel') and not record['browser_check_passed']:
            raise RuntimeError(f'Browser acceptance marker missing: {log_path}')


if __name__ == '__main__':
    main()
