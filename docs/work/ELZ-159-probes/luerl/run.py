"""Run only from the copied scratch Mix project. Linux /proc RSS watchdog."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent
COMMAND = ["mix", "run", "--no-compile", "--no-deps-check", "probe.exs"]
LIMIT_KIB = 512 * 1024


def invoke(case):
    env = dict(os.environ, LUERL_FIT_CASE=case)
    shared = case != "limit_value:default_binary_accounting"
    env["LUERL_FIT_SHARED_BINARIES"] = str(shared).lower()
    with tempfile.TemporaryFile(dir=ROOT) as out, tempfile.TemporaryFile(dir=ROOT) as err:
        p = subprocess.Popen(COMMAND, cwd=ROOT, env=env, stdout=out, stderr=err,
                             start_new_session=True)
        started = time.monotonic()
        peak = 0
        guard = None
        while p.poll() is None:
            try:
                status = pathlib.Path(f"/proc/{p.pid}/status").read_text()
                rss = next((int(s.split()[1]) for s in status.splitlines()
                            if s.startswith("VmRSS:")), 0)
                peak = max(peak, rss)
                if rss > LIMIT_KIB:
                    guard = "memory_exceeded"
                elif time.monotonic() - started > (120 if case == "costs" else 15):
                    guard = "wall_time_exceeded"
                if guard:
                    os.killpg(p.pid, signal.SIGKILL)
            except (FileNotFoundError, ProcessLookupError):
                pass
            time.sleep(.005)
        out.seek(0)
        output = out.read().decode()
        if guard or p.returncode:
            assert case != "costs", "cost BEAM did not complete"
            return [{"candidate": "luerl-1.5.1", "case": case,
                     "outcome": guard or "error", "steps": None,
                     "detail": "outer OS RSS watchdog killed BEAM" if guard == "memory_exceeded"
                     else "outer wall watchdog killed BEAM" if guard else "BEAM exited without a result",
                     "beam_survived": False, "os_peak_rss_kib": peak,
                     "include_shared_binaries": shared, "beam_exit_code": p.returncode}]
        rows = [json.loads(line) for line in output.splitlines()]
        for row in rows:
            row.update(os_peak_rss_kib=peak, include_shared_binaries=shared)
        return rows


if __name__ == "__main__":
    if subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], cwd=ROOT,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        sys.exit("Copy sources outside the checkout before running")
    env = dict(os.environ, LUERL_FIT_CASE="list")
    cases = subprocess.check_output(COMMAND, cwd=ROOT, env=env, text=True).splitlines()
    assert len(cases) == len(set(cases)), "duplicate case in manifest"
    for case in cases:
        if not case.endswith(":cost"):
            for row in invoke(case):
                print(json.dumps(row, separators=(",", ":")), flush=True)
    for row in invoke("costs"):
        print(json.dumps(row, separators=(",", ":")), flush=True)
