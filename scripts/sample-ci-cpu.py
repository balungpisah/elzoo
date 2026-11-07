#!/usr/bin/env python3
"""Sample job-container cgroup CPU usage with constant memory until stopped."""
import json
import pathlib
import signal
import sys
import time

output = pathlib.Path(sys.argv[1])
stopped = False


def stop(_signum, _frame):
    global stopped
    stopped = True


def usage_us():
    rows = pathlib.Path("/sys/fs/cgroup/cpu.stat").read_text().splitlines()
    return int(next(row.split()[1] for row in rows if row.startswith("usage_usec ")))


signal.signal(signal.SIGTERM, stop)
try:
    previous_usage = usage_us()
    previous_time = time.monotonic_ns()
    peak = 0.0
    samples = 0
    while not stopped:
        time.sleep(1)
        now = time.monotonic_ns()
        current_usage = usage_us()
        if current_usage >= previous_usage and now > previous_time:
            cores = (current_usage - previous_usage) * 1000 / (now - previous_time)
            peak = max(peak, cores)
            samples += 1
        previous_usage, previous_time = current_usage, now
    result = {
        "scope": "job container cgroup cpu.stat; sampled one-second interval averages",
        "sampled_peak_cores": round(peak, 3) if samples else None,
        "samples": samples,
    }
except (OSError, ValueError, StopIteration) as error:
    result = {"scope": "job container cgroup cpu.stat", "unavailable": str(error)}
output.write_text(json.dumps(result) + "\n")
