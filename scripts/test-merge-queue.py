#!/usr/bin/env python3
"""Offline coordinator queue controls; all gh/git calls use a stateful fake."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("merge_queue", ROOT / "scripts/merge-queue.py")
queue = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(queue)
A, B, M = "a" * 40, "b" * 40, "c" * 40
# ELZ-066, ELZ-069: job fields of a job that a GitHub-hosted runner ran (observed on a real hosted job).
HOSTED_FIELDS = dict(runner_name="GitHub Actions 7", runner_group_name="GitHub Actions", labels=["ubuntu-24.04"])


def jobs_text(base):
    """The jobs part of the merge line: the five job IDs of a run whose job base is `base` (position 0 to 4)."""
    names = ("check-plan", "check-root", "check-consumers-db", "check-consumers", "check-hosted")
    return ",".join(f"{name}:{base * 10 + position}" for position, name in enumerate(names))


def merge_line(run, base, head=None, merge=None):
    return f"ELZOO MERGE EVIDENCE pr=79 run={run} jobs={jobs_text(base)} head={head or A} merge={merge or M}"


class Fake:
    def __init__(self):
        self.calls = []
        self.now = 0
        self.messages = []
        self.pr = dict(number=79, state="OPEN", isDraft=False, isCrossRepository=False,
                       baseRefName="main", headRefName="task/ELZ-039", headRefOid=A,
                       headRepository={"nameWithOwner": queue.REPO}, mergeable="MERGEABLE")
        self.stale = False
        self.move_main = False
        self.move_head = False
        self.merge_race = False
        self.dispatches = 0
        self.dispatch_args = []
        self.pr_runs = None            # None: GitHub started no pull_request run for the exact head
        self.transient_calls = 0
        self.transient_left = 0          # ELZ-058 item 4: the next N read-only gh api calls fail transiently
        self.transient_text = "Get \"https://api.github.com/x\": net/http: TLS handshake timeout"
        self.write_failure = None
        self.pr_run_listing_error = False
        self.pr_run_listing_calls = 0
        self.pr_run_listing_text = "listing failed"
        # ELZ-059: the freeze rule reads the push runs of main and the classification comments on issue #98;
        # the Gleam gate reads the changed paths from Git.
        self.timeline = []             # the timeline events of the pull request (base_ref_changed)
        self.timeline_pages = None     # None: one page that holds self.timeline; else the raw pages
        self.head_prs = [{"number": 79}]  # every pull request (any state) from the head branch
        self.head_prs_pages = None
        self.head_prs_calls = 0
        # ELZ-071: a run can have the docs-only shape (mix check skipped, short check green, its own marker).
        self.docs_runs = set()         # IDs of runs that have the docs-only shape; their jobs have the base ID 400
        self.jobs_changes = {}         # ELZ-073: job name -> changes of that one job (job_changes applies to every executed job)
        self.drop_jobs = set()         # names of jobs that the listing of the attempt leaves out
        self.logs_by_job = {}          # job name -> log text instead of the default log of that job
        self.job_start = "2026-11-09T01:00:10Z"
        self.docs_steps = [{"name": "Classify the change", "conclusion": "success"},
                           {"name": "Docs-only check", "conclusion": "success"}]       # steps of the plan job in a docs-only run
        self.docs_log = "2026-11-09T05:00:00.0000000Z ELZOO DOCS-ONLY CHECK PASSED\n"
        # ELZ-071 (review of PR #135): the short check needs a main whose own push run completed with success.
        self.main_head_runs = None     # None: one completed successful push run on the canonical main
        self.main_head_runs_later = None   # from the second listing on, these runs
        self.main_head_hidden = 0      # the listing is empty for this many calls
        self.main_head_calls = 0
        self.main_head_error = False
        self.main_head_raw = None      # a raw body instead of {"workflow_runs": ...}
        self.raw_diff_calls = []
        self.raw_error = False
        self.raw_output = None         # a raw string instead of the one built from raw_paths
        self.raw_paths = None          # None: the same paths as diff_paths
        self.raw_paths_later = None    # from the second raw diff on, these paths
        self.raw_entries = None        # full entries (old_mode, new_mode, status, path) instead of paths
        self.extra_head_runs = []      # more runs of the backend workflow on the head, as the unfiltered listing shows them
        self.head_run_pages = None     # raw pages for that listing (malformed bodies)
        self.head_prs_later = None     # from the second listing on, the listing shows these pull requests
        self.timeline_calls = 0
        self.timeline_later = None     # from the second timeline read on, the timeline shows these events
        self.main_runs = None          # None: one green push run of main
        self.main_listing_error = False
        self.login = "queue-user"
        self.comments = []
        self.comments_error = False
        self.diff_paths = ["spikes/gleam_ui/src/gleam_ui.gleam"]  # default: a Gleam path, so the Gleam run is required
        self.diff_error = False
        self.diff_calls = []
        self.pr_run_hidden_calls = 0   # the pull_request run is listed only after this many listings
        self.main_calls = 0
        self.main_red_from_call = 0    # from this call on, the latest push run of main is red
        self.other_job_changes = None  # a second backend job, as a change of the first (ELZ-069: any second job is refused)
        self.merged = False
        self.run_changes = {}
        self.discovery_changes = {}
        self.job_changes = {}
        self.steps = [{"name": "Run mix check", "conclusion": "success"}]
        self.log = None                # a log text for every job instead of the default logs
        self.old_run = False
        self.ambiguous = False
        self.rerun = False
        self.reads = 0
        self.api_error = False
        self.suppress_new_run = False
        self.duplicate_job = False
        self.unconfirmed_merge = False
        self.gleam_missing = False
        self.gleam_changes = {}
        self.gleam_job_changes = {}
        self.gleam_other_changes = None  # a second Gleam job, as a change of the first
        self.canonical_main = M
        self.gleam_reads = 0
        self.gleam_rerun = False

    def main_head_run(self, run_id=9000, **changes):
        run = dict(id=run_id, event="push", head_branch="main", head_sha=self.canonical_main, status="completed",
                   conclusion="success", path=".github/workflows/symbolic-check.yml")
        run.update(changes)
        return run

    def pr_run_ids(self):
        """IDs of the listed runs that really are the same-repository pull_request run of the exact head."""
        return {run["id"] for run in (self.pr_runs or []) if isinstance(run, dict) and isinstance(run.get("id"), int)
                and run.get("event") == "pull_request" and run.get("head_sha") == self.pr["headRefOid"]
                and run.get("head_branch") == self.pr["headRefName"] and run.get("workflow_id") == 10
                and run.get("path") == ".github/workflows/symbolic-check.yml"
                and isinstance(run.get("head_repository"), dict) and run["head_repository"].get("full_name") == queue.REPO
                and any(isinstance(item, dict) and item.get("number") == self.pr["number"]
                        and isinstance(item.get("base"), dict) and item["base"].get("ref") == "main"
                        and isinstance(item["base"].get("repo"), dict)
                        and item["base"]["repo"].get("url") == f"https://api.github.com/repos/{queue.REPO}"
                        for item in (run.get("pull_requests") if isinstance(run.get("pull_requests"), list) else []))}

    def adopted(self):
        ids = sorted(self.pr_run_ids())
        return ids[-1] if ids else None

    def main_push_runs(self):
        if self.main_runs is not None:
            return self.main_runs
        return [dict(id=9000, event="push", head_branch="main", status="completed", conclusion="success",
                     path=".github/workflows/symbolic-check.yml")]

    def run_data(self, run_id):
        if run_id in self.pr_run_ids():
            return self.pr_run(run_id, status="completed", conclusion="success", run_attempt=1)
        return dict(id=run_id, workflow_id=10, path=".github/workflows/symbolic-check.yml",
                    event="workflow_dispatch", head_branch=self.pr["headRefName"],
                    head_sha=self.pr["headRefOid"], status="completed", conclusion="success",
                    run_attempt=1, run_started_at="2026-11-09T01:00:05Z")

    def pr_run(self, run_id, **changes):
        run = dict(id=run_id, workflow_id=10, path=".github/workflows/symbolic-check.yml",
                   event="pull_request", head_branch=self.pr["headRefName"],
                   head_sha=self.pr["headRefOid"], status="in_progress", conclusion=None, run_attempt=1,
                   head_repository={"full_name": queue.REPO}, created_at="2026-11-09T01:00:00Z",
                   run_started_at="2026-11-09T01:00:05Z",
                   pull_requests=[{"number": self.pr["number"],
                                   "base": {"ref": "main", "repo": {"url": f"https://api.github.com/repos/{queue.REPO}"}}}])
        run.update(changes)
        return run

    def gleam_run(self):
        result = dict(id=501, workflow_id=20, path=".github/workflows/symbolic-gleam.yml",
                      event="pull_request", head_branch=self.pr["headRefName"],
                      head_sha=self.pr["headRefOid"], status="completed", conclusion="success",
                      run_attempt=1)
        result.update(self.gleam_changes)
        return result

    # ELZ-073: one run has five jobs. Job IDs are base * 10 + position (check-plan 0, check-root 1,
    # check-consumers-db 2, check-consumers 3, check-hosted 4); the base is 400 for a docs-only run,
    # else 200 + the number of dispatches (so the adopted run has base 200).
    NAMES = ("check-plan", "check-root", "check-consumers-db", "check-consumers", "check-hosted")
    PART_MARKERS = {"check-root": "ELZOO ROOT SUITE PASSED", "check-consumers-db": "ELZOO CONSUMERS DB PASSED",
                    "check-consumers": "ELZOO CONSUMERS PASSED"}

    def job_base(self, read_run):
        return 400 if read_run in self.docs_runs else 200 + self.dispatches

    def job_id(self, base, name):
        return base * 10 + self.NAMES.index(name)

    def backend_jobs(self, read_run):
        docs = read_run in self.docs_runs
        base = self.job_base(read_run)
        run_id = read_run if docs else 100 + self.dispatches if self.dispatches else self.adopted()
        gate = {"name": "Verify the GitHub-hosted runner", "conclusion": "success"}
        plan_steps = (list(self.docs_steps) if docs else
                      [{"name": "Classify the change", "conclusion": "success"},
                       {"name": "Docs-only check", "conclusion": "skipped"}])
        jobs = []
        for name in self.NAMES:
            if name in self.drop_jobs:
                continue
            skipped = docs and name in self.PART_MARKERS
            steps = ([] if skipped else
                     [gate] + (plan_steps if name == "check-plan" else
                               [{"name": "Require every job", "conclusion": "success"}] if name == "check-hosted" else
                               list(self.steps)))
            job = dict(id=self.job_id(base, name), run_id=run_id, name=name, head_sha=self.pr["headRefOid"],
                       status="completed", conclusion="skipped" if skipped else "success", **HOSTED_FIELDS,
                       started_at=self.job_start, steps=steps)
            if not skipped:
                job.update(self.job_changes)
            job.update(self.jobs_changes.get(name, {}))
            jobs.append(job)
        if self.other_job_changes is not None:
            jobs.append(dict(jobs[0], id=998, **self.other_job_changes))
        if self.duplicate_job:
            jobs.append(dict(jobs[1], id=999))
        return jobs

    def job_log(self, job_id):
        base, position = divmod(job_id, 10)
        name = self.NAMES[position]
        if name in self.logs_by_job:
            return self.logs_by_job[name]
        if self.log is not None:
            return self.log
        stamp = "2026-11-07T13:00:00.0000000Z "
        if base == 400:   # a docs-only run
            return (self.docs_log + stamp + "ELZOO PLAN: run=false skip=false docs_only=true\n"
                    if name == "check-plan" else "")
        if name == "check-plan":
            return stamp + "ELZOO PLAN: run=true skip=false docs_only=false\n"
        if name == "check-hosted":
            return stamp + "ELZOO CHECK PASSED\n"
        return stamp + self.PART_MARKERS[name] + "\n"

    def execute(self, argv, allowed=(0,)):
        self.calls.append(argv)
        out, code = "", 0
        if argv[:3] == ["gh", "pr", "view"]:
            out = copy.deepcopy(self.pr)
            if self.merged and not self.unconfirmed_merge:
                out.update(state="MERGED", mergeCommit={"oid": M})
        elif argv[:3] == ["gh", "pr", "update-branch"]:
            self.pr["headRefOid"] = B
            self.stale = False
        elif argv[:3] == ["gh", "pr", "merge"]:
            if self.merge_race:
                raise queue.QueueError("head changed: match-head-commit refused")
            self.merged = True
        elif argv[:3] == ["gh", "workflow", "run"]:
            self.dispatches += 1
            self.dispatch_args.append(argv)
        elif argv[:2] == ["git", "diff"] and "--raw" in argv:
            self.raw_diff_calls.append(argv)
            if self.raw_error:
                raise queue.QueueError("git diff failed")
            paths = self.raw_paths if self.raw_paths is not None else self.diff_paths
            if self.raw_paths_later is not None and len(self.raw_diff_calls) >= 2:
                paths = self.raw_paths_later
            entries = self.raw_entries if self.raw_entries is not None else [("100644", "100644", "M", p) for p in paths]
            out = self.raw_output if self.raw_output is not None else "".join(
                f":{o} {n} {'a' * 40} {'b' * 40} {st}\x00{path}\x00" for o, n, st, path in entries)
        elif argv[:2] == ["git", "diff"]:
            self.diff_calls.append(argv)
            if self.diff_error:
                raise queue.QueueError("git diff failed")
            out = "".join(path + "\x00" for path in self.diff_paths)
        elif argv[:2] == ["git", "fetch"]:
            pass
        elif argv[:2] == ["git", "rev-parse"]:
            out = M if argv[-1].endswith("/main") else self.pr["headRefOid"]
        elif argv[:2] == ["git", "merge-base"]:
            code = int(self.stale)
        elif argv[:2] == ["gh", "api"]:
            if self.api_error:
                raise queue.QueueError("API unavailable")
            if self.transient_left > 0 and "-X" not in argv:
                self.transient_left -= 1
                self.transient_calls += 1
                raise queue.QueueError(f"gh api exited 1: {self.transient_text}")
            path = argv[-1]
            if argv[2:4] == ["-X", "POST"]:
                raise AssertionError(f"The queue must not write through gh api: {argv}")
            elif argv[2:4] == ["user", "--jq"]:
                out = self.login
            elif "/workflows/symbolic-check.yml/runs?" in path and "head_sha=" in path and "event=" not in path:
                runs = [r for r in (self.pr_runs or []) if isinstance(r, dict)]
                if self.dispatches:
                    # The queue dispatches after it found no adoptable run, so GitHub gave every earlier run a lower
                    # ID than the dispatch run (the fixtures use large IDs for readability).
                    runs = [dict(r, id=r["id"] // 10) if isinstance(r.get("id"), int) else r for r in runs]
                    runs.append(self.run_data(100 + self.dispatches))
                out = self.head_run_pages if self.head_run_pages is not None else [
                    {"workflow_runs": runs + self.extra_head_runs}]
            elif "/pulls?head=" in path:
                self.head_prs_calls += 1
                out = self.head_prs_pages if self.head_prs_pages is not None else [self.head_prs]
                if self.head_prs_later is not None and self.head_prs_calls >= 2:
                    out = [self.head_prs_later]
            elif "/issues/79/timeline" in path:
                self.timeline_calls += 1
                out = self.timeline_pages if self.timeline_pages is not None else [self.timeline]
                if self.timeline_later is not None and self.timeline_calls >= 2:
                    out = [self.timeline_later]
            elif "/issues/98/comments" in path:
                if self.comments_error:
                    raise queue.QueueError("gh api exited 1: comments failed")
                out = [self.comments]
            elif "/workflows/symbolic-check.yml/runs?" in path and "event=push" in path and "head_sha=" in path:
                self.main_head_calls += 1
                if self.main_head_error:
                    raise queue.QueueError("gh api exited 1: main head listing failed")
                runs = self.main_head_runs if self.main_head_runs is not None else [self.main_head_run()]
                if self.main_head_runs_later is not None and self.main_head_calls >= 2:
                    runs = self.main_head_runs_later
                if self.main_head_calls <= self.main_head_hidden:
                    runs = []
                out = self.main_head_raw if self.main_head_raw is not None else {"workflow_runs": runs}
            elif "/workflows/symbolic-check.yml/runs?" in path and "event=push" in path:
                if self.main_listing_error:
                    raise queue.QueueError("gh api exited 1: main listing failed")
                self.main_calls += 1
                runs = self.main_push_runs()
                if self.main_red_from_call and self.main_calls >= self.main_red_from_call:
                    runs = [dict(runs[0], id=9100, conclusion="failure")]
                out = {"workflow_runs": runs}
            elif "/workflows/symbolic-check.yml/runs?" in path and "event=pull_request" in path:
                self.pr_run_listing_calls += 1
                if self.pr_run_listing_error:
                    raise queue.QueueError(f"gh api exited 1: {self.pr_run_listing_text}")
                runs = [] if self.pr_runs is None or self.pr_run_listing_calls <= self.pr_run_hidden_calls else self.pr_runs
                out = [{"workflow_runs": runs}]  # malformed bodies are passed through as they are
            elif path.endswith("git/ref/heads/main"):
                out = {"object": {"sha": self.canonical_main}}
            elif "/workflows/symbolic-gleam.yml/runs?" in path:
                out = [{"workflow_runs": [] if self.gleam_missing else [self.gleam_run()]}]
            elif path.endswith("/workflows/symbolic-gleam.yml"):
                out = {"id": 20}
            elif "/actions/runs/501/attempts/" in path:
                job = dict(id=601, run_id=501, name="gleam-hosted", head_sha=self.pr["headRefOid"],
                           status="completed", conclusion="success", **HOSTED_FIELDS,
                           steps=[{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                                  {"name": "Run ./scripts/check.sh", "conclusion": "success"}])
                job.update(self.gleam_job_changes)
                jobs = [job]
                if self.gleam_other_changes is not None:
                    jobs.append(dict(job, id=602, **self.gleam_other_changes))
                out = [{"jobs": jobs}]
            elif path.endswith("/actions/runs/501"):
                self.gleam_reads += 1
                out = self.gleam_run()
                if self.gleam_rerun and self.gleam_reads == 2:
                    out["run_attempt"] = 2
            elif "/workflows/" in path and "/runs?" not in path:
                out = {"id": 10}
            elif "/workflows/" in path and "/runs?" in path:
                runs = [self.run_data(99)] if self.old_run else []
                if self.dispatches and not self.suppress_new_run:
                    run = self.run_data(100 + self.dispatches)
                    run.update(self.discovery_changes)
                    runs.append(run)
                    if self.ambiguous:
                        runs.append(dict(run, id=900))
                out = [{"workflow_runs": runs}]
            elif "/attempts/" in path:
                out = [{"jobs": self.backend_jobs(int(path.split("/actions/runs/")[1].split("/")[0]))}]
            elif path.endswith("/logs"):
                out = self.job_log(int(path.rsplit("/", 2)[1]))
            elif "/runs/" in path:
                self.reads += 1
                out = self.run_data(int(path.rsplit("/", 1)[1]))
                out.update(self.run_changes)
                if self.reads == 2:
                    if self.rerun:
                        out["run_attempt"] = 2
                    if self.move_main:
                        self.stale = True
                        self.move_main = False
                    if self.move_head:
                        self.pr["headRefOid"] = B
        else:
            raise AssertionError(f"Unexpected command {argv}")
        if code not in allowed:
            raise queue.QueueError(f"fake command failed: {argv}")
        return subprocess.CompletedProcess(argv, code, json.dumps(out) if not isinstance(out, str) else out, "")

    def sleep(self, seconds):
        self.now += seconds

    def make_queue(self, timeout=30, pr_run_wait=0):
        return queue.Queue(run=self.execute, sleep=self.sleep, clock=lambda: self.now,
                           timeout=timeout, poll=15, emit=lambda text, **_: self.messages.append(text),
                           pr_run_wait=pr_run_wait)

    def commands(self, prefix):
        return [call for call in self.calls if call[:len(prefix)] == prefix]


class QueueTest(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def refuses(self, pattern=None):
        with self.assertRaisesRegex(queue.QueueError, pattern or ".+"):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))

    def test_success_has_exact_head_merge_and_evidence(self):
        self.q.process(79)
        self.assertEqual(self.fake.commands(["gh", "pr", "merge"]), [
            ["gh", "pr", "merge", "79", "-R", queue.REPO, "--merge", "--match-head-commit", A]])
        self.assertEqual(self.fake.messages[-1],
                         merge_line(101, 201))
        self.assertFalse(any(flag in call for call in self.fake.calls
                             for flag in ("--rebase", "--force", "--admin", "--delete-branch", "--auto")))
        self.assertFalse(self.fake.commands(["git", "push"]))

    # ELZ-069: the workflow has no dispatch inputs; the queue sends none.
    def test_dispatch_sends_no_input(self):
        self.q.process(79)
        self.assertEqual(1, len(self.fake.dispatch_args))
        args = self.fake.dispatch_args[0]
        self.assertEqual(["gh", "workflow", "run", queue.WORKFLOW, "-R", queue.REPO, "--ref", self.fake.pr["headRefName"]], args)
        self.assertNotIn("-f", args)

    def test_stale_main_updates_by_merge_and_checks_new_head(self):
        self.fake.stale = True
        self.q.process(79)
        self.assertEqual(self.fake.commands(["gh", "pr", "update-branch"]),
                         [["gh", "pr", "update-branch", "79", "-R", queue.REPO]])
        self.assertEqual(self.fake.commands(["gh", "pr", "merge"])[0][-1], B)
        self.assertIn(f"head={B}", self.fake.messages[-1])

    # ELZ-058 item 4: bounded retries of read-only calls, and the awaited run named when the queue stops.
    def test_transient_gh_api_failures_are_retried_then_succeed(self):
        for text in ("Get \"https://api.github.com/x\": net/http: TLS handshake timeout",
                     "read tcp 1.2.3.4:1->5.6.7.8:443: read: connection reset by peer",
                     "dial tcp: i/o timeout", "gh: HTTP 502: Bad Gateway", "HTTP 503", "HTTP 504 Gateway Timeout",
                     "unexpected EOF"):
            with self.subTest(text=text):
                self.setUp()
                self.fake.transient_text = text
                self.fake.transient_left = 3
                self.q = self.fake.make_queue(timeout=3600)
                self.q.process(79)
                self.assertTrue(self.fake.merged)
                self.assertEqual(3, self.fake.transient_calls)
                self.assertEqual(3, sum("Transient failure" in m for m in self.fake.messages))
                self.assertGreaterEqual(self.fake.now, 10 + 20 + 40)  # backoff waits were taken

    def test_persistent_transient_failure_stops_after_five_attempts_and_names_the_run(self):
        self.fake.transient_left = 0
        self.q = self.fake.make_queue(timeout=3600)
        original = self.fake.execute

        def failing_after_dispatch(argv, allowed=(0,)):
            if (self.fake.dispatches and argv[:2] == ["gh", "api"] and "-X" not in argv
                    and "/actions/runs/101" in argv[-1]):
                self.fake.calls.append(argv)
                self.fake.transient_calls += 1
                raise queue.QueueError(f"gh api exited 1: {self.fake.transient_text}")
            return original(argv, allowed)
        self.q = queue.Queue(run=failing_after_dispatch, sleep=self.fake.sleep, clock=lambda: self.fake.now,
                             timeout=3600, poll=15, emit=lambda text, **_: self.fake.messages.append(text))
        with self.assertRaisesRegex(queue.QueueError, "TLS handshake timeout"):
            self.q.process(79)
        self.assertEqual(5, self.fake.transient_calls)  # five attempts of the same read
        self.assertEqual(4, sum("Transient failure" in m for m in self.fake.messages))
        self.assertTrue(any("Stopped while awaiting run 101 for PR #79" in m and f"head={A}" in m
                            for m in self.fake.messages))
        self.assertFalse(self.fake.merged)

    def test_non_transient_errors_are_not_retried(self):
        for text in ("gh api exited 1: HTTP 404: Not Found", "gh api exited 1: HTTP 401: Bad credentials",
                     "gh api exited 1: HTTP 403: rate limit", "gh api exited 1: HTTP 422"):
            with self.subTest(text=text):
                self.setUp()
                self.fake.transient_text = text.replace("gh api exited 1: ", "")
                self.fake.transient_left = 1
                with self.assertRaises(queue.QueueError):
                    self.q.process(79)
                self.assertEqual(1, self.fake.transient_calls)
                self.assertFalse(any("Transient failure" in m for m in self.fake.messages))

    def test_a_non_queue_error_inside_evidence_still_names_the_run(self):
        self.fake.stale = False
        original = self.q.evidence

        def broken(run_id, pr, workflow_id):
            raise KeyError("workflow_runs")
        self.q.evidence = broken
        with self.assertRaises(KeyError):
            self.q.process(79)
        self.assertTrue(any("Stopped while awaiting run 101 for PR #79" in m for m in self.fake.messages))

    def test_write_commands_are_never_retried(self):
        for argv in (["gh", "workflow", "run", "symbolic-check.yml"], ["gh", "pr", "merge", "79"],
                     ["gh", "pr", "update-branch", "79"], ["gh", "api", "-X", "POST", "repos/x/actions/runs/1/cancel"],
                     ["gh", "api", "--method", "POST", "repos/x/actions/runs/1/cancel"]):
            with self.subTest(argv=argv):
                calls = []

                def failing(command, allowed=(0,)):
                    calls.append(command)
                    raise queue.QueueError("net/http: TLS handshake timeout")
                run = queue.retrying(failing, lambda s: None, lambda *a, **k: None)
                with self.assertRaises(queue.QueueError):
                    run(argv)
                self.assertEqual(1, len(calls))

    def test_retry_never_waits_past_the_pr_deadline(self):
        now = [0]
        calls = []

        def failing(command, allowed=(0,)):
            calls.append(command)
            raise queue.QueueError("net/http: TLS handshake timeout")

        def sleep(seconds):
            now[0] += seconds
        run = queue.retrying(failing, sleep, lambda *a, **k: None, clock=lambda: now[0], deadline=lambda: 25)
        with self.assertRaises(queue.QueueError):
            run(["gh", "api", "repos/x/actions/runs/1"])
        self.assertEqual(2, len(calls))  # one retry after 10 s; the next 20 s wait would pass the deadline of 25 s
        self.assertLessEqual(now[0], 25)
        # exact boundary: a wait that ends exactly at the deadline is not taken
        now[0], calls[:] = 0, []
        run = queue.retrying(failing, sleep, lambda *a, **k: None, clock=lambda: now[0], deadline=lambda: 10)
        with self.assertRaises(queue.QueueError):
            run(["gh", "api", "repos/x/actions/runs/1"])
        self.assertEqual(1, len(calls))

    def test_transient_pattern_and_read_only_rules(self):
        for text in ("TLS handshake timeout", "connection reset by peer", "HTTP 502", "HTTP 503: x", "HTTP 504",
                     "502 Bad Gateway", "i/o timeout", "unexpected EOF", "context deadline exceeded",
                     "gh failed: Command '['gh', 'api', 'x']' timed out after 120 seconds", "operation timed out"):
            with self.subTest(text=text):
                self.assertTrue(queue.TRANSIENT.search(text))
        for text in ("HTTP 404", "HTTP 401", "Not Found", "HTTP 429", "HTTP 422", "mergeable"):
            with self.subTest(text=text):
                self.assertFalse(queue.TRANSIENT.search(text))
        for text in ("fatal: early EOF", "unexpected EOF", "HTTP 500", "connection refused", "server closed idle connection",
                     "Client.Timeout exceeded while awaiting headers"):
            with self.subTest(text=text):
                self.assertTrue(queue.TRANSIENT.search(text))
        # only the tool's message counts, never the arguments of the command
        error = queue.QueueError("gh api repos/x/actions/runs/502 exited 1: HTTP 404: Not Found")
        self.assertFalse(queue.TRANSIENT.search(queue.error_detail(error)))
        self.assertTrue(queue.TRANSIENT.search(queue.error_detail(queue.QueueError("gh api x exited 1: HTTP 502"))))
        for argv in (["gh", "api", "-f", "a=b", "repos/x"], ["gh", "api", "-fa=b", "repos/x"], ["gh", "api", "-F", "a=1", "x"],
                     ["gh", "api", "--field", "a=1", "x"], ["gh", "api", "--field=a=1", "x"], ["gh", "api", "--raw-field", "a=b", "x"],
                     ["gh", "api", "--input", "f.json", "x"], ["gh", "api", "--input=f.json", "x"], ["gh", "api", "-XPOST", "x"],
                     ["gh", "api", "--method=POST", "x"], ["gh", "api", "--method", "DELETE", "x"]):
            with self.subTest(argv=argv):
                self.assertFalse(queue.is_read_only(argv))
        self.assertTrue(queue.is_read_only(["git", "fetch", "origin", "refs/heads/main:refs/remotes/origin/main"]))
        self.assertTrue(queue.is_read_only(["gh", "api", "--paginate", "--slurp", "repos/x/actions/runs?a=b"]))
        self.assertTrue(queue.is_read_only(["gh", "api", "repos/x/actions/runs/1"]))
        self.assertTrue(queue.is_read_only(["gh", "pr", "view", "79"]))
        self.assertFalse(queue.is_read_only(["gh", "api", "-X", "POST", "x"]))
        self.assertFalse(queue.is_read_only(["gh", "pr", "merge", "79"]))

    def test_main_moves_during_check_requires_new_full_run(self):
        self.fake.move_main = True
        self.q.process(79)
        self.assertEqual(self.fake.dispatches, 2)
        self.assertEqual(len(self.fake.commands(["gh", "pr", "update-branch"])), 1)
        self.assertIn(f"run=102 jobs={jobs_text(202)} head={B}", self.fake.messages[-1])

    def test_ineligible_prs(self):
        for change in ({"isDraft": True}, {"isCrossRepository": True},
                       {"headRepository": None}, {"headRepository": {"nameWithOwner": "other/elzoo"}},
                       {"headRefName": "fix/ELZ-039"}, {"headRefName": "task/ELZ-039-agent"},
                       {"headRefName": "task/ELZ-39"}, {"baseRefName": "release"},
                       {"mergeable": "CONFLICTING"}, {"mergeable": "UNKNOWN"},
                       {"state": "CLOSED"}, {"headRefOid": "abc"}, {"isDraft": None}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.pr.update(change)
                self.refuses()
                self.assertEqual(self.fake.dispatches, 0)

    def test_wrong_run_identity_never_accepted(self):
        for change in ({"head_sha": B}, {"event": "pull_request"}, {"head_branch": "main"},
                       {"workflow_id": 11}, {"path": ".github/workflows/symbolic-gleam.yml"}, {"id": 500}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.run_changes = change
                self.refuses("mismatch")

    def test_wrong_discovery_identity_is_not_used(self):
        for change in ({"head_sha": B}, {"event": "push"}, {"head_branch": "main"}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.discovery_changes = change
                self.refuses("Timed out")

    def test_existing_run_is_not_used(self):
        self.fake.old_run = True
        self.q.process(79)
        self.assertIn("run=101", self.fake.messages[-1])

    def test_old_green_run_does_not_replace_missing_dispatch(self):
        self.fake.old_run = True
        self.fake.suppress_new_run = True
        self.refuses("Timed out")

    def test_fetch_failure_never_merges(self):
        execute = self.fake.execute

        def failing_fetch(argv, allowed=(0,)):
            if argv[:2] == ["git", "fetch"]:
                raise queue.QueueError("fetch unavailable")
            return execute(argv, allowed)
        self.q.run = failing_fetch
        self.refuses("fetch unavailable")

    def test_unconfirmed_merge_never_emits_evidence(self):
        self.fake.unconfirmed_merge = True
        with self.assertRaisesRegex(queue.QueueError, "Merge not confirmed"):
            self.q.process(79)
        self.assertFalse(any(line.startswith("ELZOO MERGE EVIDENCE") for line in self.fake.messages))

    def test_ambiguous_dispatch_refused(self):
        self.fake.ambiguous = True
        self.refuses("Ambiguous")

    def test_failed_cancelled_or_skipped_run(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                self.setUp()
                self.fake.run_changes["conclusion"] = conclusion
                self.refuses()

    def test_wait_timeout_never_merges(self):
        self.fake.run_changes["status"] = "in_progress"
        self.refuses("Timed out")

    def test_job_controls(self):
        for change in ({"runner_name": "self-hosted-1"}, {"runner_name": ""},
                       {"conclusion": "failure"}, {"status": "queued"}, {"head_sha": B},
                       {"run_id": 1}, {"name": "other"}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.job_changes = change
                self.refuses()

    def test_check_step_must_execute_successfully(self):
        for steps in ([], [{"name": "Run mix check", "conclusion": "skipped"}],
                      [{"name": "Run mix check", "conclusion": "failure"}]):
            with self.subTest(steps=steps):
                self.setUp()
                self.fake.steps = steps
                self.refuses()

    def test_missing_or_affected_markers_and_echo_decoys(self):
        for log in ("", "ELZOO AFFECTED CHECK PASSED", "echo 'ELZOO CHECK PASSED'",
                    "ELZOO CHECK PASSED\nELZOO AFFECTED CHECK PASSED (not full consumer acceptance)",
                    "ELZOO CHECK PASSED but not really"):
            with self.subTest(log=log):
                self.setUp()
                self.fake.log = log
                self.refuses()

    def test_rerun_during_evidence_collection_refused(self):
        self.fake.rerun = True
        self.refuses("Run changed")

    def test_head_changes_during_check_refused(self):
        self.fake.move_head = True
        self.refuses("head changed")

    def test_head_changes_at_merge_is_server_guarded(self):
        self.fake.merge_race = True
        with self.assertRaisesRegex(queue.QueueError, "match-head-commit"):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertEqual(self.fake.commands(["gh", "pr", "merge"])[0][-2:], ["--match-head-commit", A])

    def test_api_failure_stops_without_merge(self):
        self.fake.api_error = True
        self.refuses("API unavailable")

    def test_cli_stops_default_and_continues_only_explicitly(self):
        class FailingQueue:
            def __init__(self):
                self.seen = []

            def process(self, number):
                self.seen.append(number)
                if number == 79:
                    raise queue.QueueError("failed check")
        for flags, expected in (([], [79]), (["--continue-on-failure"], [79, 80])):
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()):
                fake = FailingQueue()
                self.assertEqual(queue.main(["79", "80", *flags], queue=fake), 1)
                self.assertEqual(fake.seen, expected)

    def test_workflow_non_pr_runs_do_not_share_cancellation_group(self):
        source = (ROOT / ".github/workflows/symbolic-check.yml").read_text()
        self.assertIn("\nconcurrency:\n  group: check-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}\n  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", source)
        self.assertIn("      - run: python3 scripts/test-merge-queue.py\n", source)
        self.assertIn("permissions:\n  contents: read\n", source)


class HostedLaneEvidence(unittest.TestCase):
    """ELZ-066: the same queue accepts evidence from the hosted lane, under stricter job identity rules."""

    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def refuses(self, pattern=None):
        with self.assertRaisesRegex(queue.QueueError, pattern or ".+"):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))

    def test_executed_check_any_is_never_evidence_in_either_lane(self):
        self.fake.job_changes = {"name": "check-any"}
        self.refuses("Expected exactly the five backend jobs")

    def test_each_job_of_the_unit_needs_the_exact_head_run_and_success(self):
        for name in self.fake.NAMES:
            for change in ({"conclusion": "failure"}, {"conclusion": "cancelled"}, {"conclusion": None},
                           {"status": "queued"}, {"status": "in_progress"}, {"head_sha": B}, {"run_id": 1},
                           {"id": "x"}, {"id": None}):
                with self.subTest(job=name, change=change):
                    self.setUp()
                    self.fake.jobs_changes = {name: change}
                    self.refuses()
        # job_changes applies to every executed job of the unit
        for change in ({"conclusion": "failure"}, {"head_sha": B}, {"run_id": 1}):
            with self.subTest(all_jobs=change):
                self.setUp()
                self.fake.job_changes = change
                self.refuses()

    def test_each_job_of_the_unit_needs_its_own_steps(self):
        gate = {"name": "Verify the GitHub-hosted runner", "conclusion": "success"}
        shapes = {
            "check-plan": [("no classification", [gate, {"name": "Docs-only check", "conclusion": "skipped"}], "Classification step"),
                           ("classification failed", [gate, {"name": "Classify the change", "conclusion": "failure"},
                                                      {"name": "Docs-only check", "conclusion": "skipped"}], "Classification step"),
                           ("docs-only check ran", [gate, {"name": "Classify the change", "conclusion": "success"},
                                                    {"name": "Docs-only check", "conclusion": "success"}], "Docs-only step ran"),
                           ("docs-only step missing", [gate, {"name": "Classify the change", "conclusion": "success"}], "Docs-only step ran or is missing")],
            "check-root": [("mix check skipped", [gate, {"name": "Run mix check", "conclusion": "skipped"}], "Full check step"),
                           ("mix check failed", [gate, {"name": "Run mix check", "conclusion": "failure"}], "Full check step"),
                           ("mix check missing", [gate], "Full check step"),
                           ("mix check twice", [gate, {"name": "Run mix check", "conclusion": "success"},
                                                {"name": "Run mix check", "conclusion": "success"}], "Full check step")],
            "check-hosted": [("no aggregating step", [gate], "Aggregating step"),
                             ("aggregating step failed", [gate, {"name": "Require every job", "conclusion": "failure"}], "Aggregating step"),
                             ("aggregating step twice", [gate, {"name": "Require every job", "conclusion": "success"},
                                                         {"name": "Require every job", "conclusion": "success"}], "Aggregating step")],
        }
        for name in self.fake.NAMES:        # the identity step of every job
            for label, steps in (("no identity step", []), ("identity step failed", [{"name": "Verify the GitHub-hosted runner", "conclusion": "failure"}]),
                                 ("identity step skipped", [{"name": "Verify the GitHub-hosted runner", "conclusion": "skipped"}]),
                                 ("identity step twice", [{"name": "Verify the GitHub-hosted runner", "conclusion": "success"}] * 2)):
                with self.subTest(job=name, label=label):
                    self.setUp()
                    steps = steps + self.fake.backend_jobs(self.fake.adopted() or 101)[self.fake.NAMES.index(name)]["steps"][1:]
                    self.fake.jobs_changes = {name: {"steps": steps}}
                    self.refuses("identity step")
        for name, cases in shapes.items():
            for label, steps, pattern in cases:
                with self.subTest(job=name, label=label):
                    self.setUp()
                    self.fake.jobs_changes = {name: {"steps": steps}}
                    self.refuses(pattern)

    def test_only_the_five_backend_jobs_may_be_in_the_unit(self):
        # A sixth job, whatever its name or result, and a duplicate of any job are refused.
        for change in ({"conclusion": "success"}, {"conclusion": "skipped"}, {"name": "check-extra"},
                       {"name": "check-any", "conclusion": "skipped"}, {"name": "gleam-hosted"}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.other_job_changes = change
                self.refuses("Expected exactly the five backend jobs")
        for name in self.fake.NAMES:
            with self.subTest(duplicate=name):
                self.setUp()
                self.fake.jobs_changes = {}
                self.fake.duplicate_job = True
                self.fake.drop_jobs = set()
                self.refuses("Expected exactly the five backend jobs")
                break

    def test_a_missing_or_renamed_job_is_no_unit(self):
        for name in self.fake.NAMES:
            with self.subTest(missing=name):
                self.setUp()
                self.fake.drop_jobs = {name}
                self.refuses("Expected exactly the five backend jobs")
            for new in ("other", "check", "check-fast", "check-any", "check-hosted-2", "gleam-hosted", ""):
                with self.subTest(job=name, renamed=new):
                    self.setUp()
                    self.fake.jobs_changes = {name: {"name": new}}
                    self.refuses("Expected exactly the five backend jobs")
        self.setUp()
        self.fake.drop_jobs = set(self.fake.NAMES)
        self.refuses("Expected exactly the five backend jobs")

    def test_a_skipped_job_is_not_evidence_where_a_job_must_run(self):
        # The plan job and the aggregating job always run; a work job may be skipped only in a docs-only run.
        for name in ("check-plan", "check-hosted"):
            with self.subTest(job=name):
                self.setUp()
                self.fake.jobs_changes = {name: {"conclusion": "skipped"}}
                self.refuses("must have run")
        for name in ("check-root", "check-consumers-db", "check-consumers"):
            with self.subTest(job=name):
                self.setUp()
                self.fake.jobs_changes = {name: {"conclusion": "skipped"}}
                self.refuses("not a full run")
        for names in (("check-root", "check-consumers"), ("check-consumers-db", "check-consumers")):
            with self.subTest(jobs=names):
                self.setUp()
                self.fake.jobs_changes = {name: {"conclusion": "skipped"} for name in names}
                self.refuses("not a full run")
        # all three skipped without the docs-only shape is not a full run either
        self.setUp()
        self.fake.jobs_changes = {name: {"conclusion": "skipped"} for name in ("check-root", "check-consumers-db", "check-consumers")}
        self.refuses("Docs-only check step|Docs-only step ran")

    def test_a_job_that_ran_in_an_earlier_attempt_is_no_evidence(self):
        # GitHub copies the green jobs of an earlier attempt into the new attempt (new job ID, new run_attempt, but the
        # old start time and runner) when only the failed jobs are re-run: the unit must have run in one attempt.
        for name in self.fake.NAMES:
            with self.subTest(job=name):
                self.setUp()
                self.fake.jobs_changes = {name: {"started_at": "2026-11-09T00:20:00Z"}}
                self.refuses("did not run in this attempt")
        for value in (None, "", "yesterday", 5, "2026-11-09 01:00:10"):
            with self.subTest(started_at=value):
                self.setUp()
                self.fake.jobs_changes = {"check-root": {"started_at": value}}
                self.refuses("Invalid job start")
        self.setUp()
        self.fake.jobs_changes = {"check-root": {"started_at": "2026-11-09T01:00:05Z"}}   # starts with the run: fine
        self.q.process(79)
        self.assertTrue(self.fake.merged)
        for value in (None, "", "x", 5):
            with self.subTest(run_started_at=value):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.run_changes = {"run_started_at": value}
                self.refuses()

    def test_each_log_of_the_unit_must_carry_its_marker_as_a_line_of_its_own(self):
        stamp = "2026-11-07T13:00:00.0000000Z "
        markers = {"check-root": "ELZOO ROOT SUITE PASSED", "check-consumers-db": "ELZOO CONSUMERS DB PASSED",
                   "check-consumers": "ELZOO CONSUMERS PASSED", "check-hosted": "ELZOO CHECK PASSED"}
        for name, marker in markers.items():
            for label, log in (("no marker", stamp + "all done\n"), ("empty", ""),
                               ("echoed command", stamp + f'echo "{marker}"\n'), ("text before", stamp + "x " + marker + "\n"),
                               ("text after", stamp + marker + " but not really\n"), ("lower case", stamp + marker.lower() + "\n"),
                               ("another part's marker", stamp + ("ELZOO ROOT SUITE PASSED" if name != "check-root" else "ELZOO CONSUMERS PASSED") + "\n")):
                with self.subTest(job=name, label=label):
                    self.setUp()
                    self.fake.logs_by_job = {name: log}
                    self.refuses("marker")
            with self.subTest(job=name, label="timestamp prefix and other lines"):
                self.setUp()
                self.fake.logs_by_job = {name: "x\n" + stamp + marker + "\ny\n"}
                self.q.process(79)
                self.assertTrue(self.fake.merged)
        for name in markers:
            if name == "check-hosted":
                continue
            with self.subTest(job=name, label="affected-mode marker"):
                self.setUp()
                self.fake.logs_by_job = {name: stamp + markers[name] + "\n" + stamp + "ELZOO AFFECTED CHECK PASSED (not full)\n"}
                self.refuses("affected-mode marker")

    def test_the_plan_line_must_say_run_true_in_a_full_run(self):
        stamp = "2026-11-07T13:00:00.0000000Z "
        for label, log in (("run=false", stamp + "ELZOO PLAN: run=false skip=false docs_only=false\n"), ("none", ""),
                           ("echoed command", stamp + 'echo "ELZOO PLAN: run=true skip=false docs_only=false"\n'),
                           ("the docs-only marker too", stamp + "ELZOO PLAN: run=true skip=false docs_only=false\n" + stamp + "ELZOO DOCS-ONLY CHECK PASSED\n")):
            with self.subTest(label=label):
                self.setUp()
                self.fake.logs_by_job = {"check-plan": log}
                self.refuses("Plan did not say run=true|Docs-only marker present")

    def test_an_affected_mode_marker_in_the_plan_log_of_a_full_run_is_refused(self):
        stamp = "2026-11-07T13:00:00.0000000Z "
        self.fake.logs_by_job = {"check-plan": stamp + "ELZOO PLAN: run=true skip=false docs_only=false\n"
                                 + stamp + "ELZOO AFFECTED CHECK PASSED (not full)\n"}
        self.refuses("affected-mode marker")

    def test_hosted_job_is_accepted_and_recorded(self):
        self.q.process(79)
        self.assertTrue(self.fake.merged)
        self.assertEqual(self.fake.messages[-1], merge_line(101, 201))
        # every job of the unit was read and its log fetched for the markers: plan, three parts, aggregator
        logs = [c for c in self.fake.calls if c[:2] == ["gh", "api"] and c[-1].endswith("/logs")]
        self.assertEqual(sorted(c[-1].split("/jobs/")[1].split("/")[0] for c in logs),
                         sorted(str(201 * 10 + n) for n in range(5)))

    def test_hosted_runner_identity_is_exact(self):
        for change in ({"runner_group_name": "Default"}, {"runner_group_name": None}, {"runner_group_name": "github actions"},
                       {"labels": ["self-hosted", "ubuntu-24.04"]}, {"labels": ["ubuntu-latest"]},
                       {"labels": ["ubuntu-24.04", "extra"]}, {"labels": ["ubuntu-24.04-arm"]}, {"labels": []},
                       {"labels": "ubuntu-24.04"}, {"labels": None},
                       {"runner_name": "self-hosted-1"}, {"runner_name": "GitHub Actions"},
                       {"runner_name": "GitHub Actions 7 extra"}, {"runner_name": "github actions 7"},
                       {"runner_name": "GitHub Actions x"}, {"runner_name": None}, {"runner_name": ""}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.job_changes = change
                self.refuses("Unapproved hosted runner")

    def test_hosted_identity_fields_cannot_be_empty(self):
        for field in ("runner_name", "runner_group_name", "labels"):
            with self.subTest(field=field):
                self.setUp()
                self.fake.job_changes = {field: None}
                self.refuses("Unapproved hosted runner")

    def test_hosted_identity_step_must_have_run_and_passed(self):
        for steps in ([{"name": "Run mix check", "conclusion": "success"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "skipped"},
                       {"name": "Run mix check", "conclusion": "success"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "failure"},
                       {"name": "Run mix check", "conclusion": "success"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                       {"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                       {"name": "Run mix check", "conclusion": "success"}]):
            with self.subTest(steps=steps):
                self.setUp()
                self.fake.job_changes = {"steps": steps}
                self.refuses("identity step")

    def test_hosted_gleam_job_is_accepted_and_recorded(self):
        self.q.process(79)
        self.assertTrue(self.fake.merged)
        self.assertIn(f"ELZOO GLEAM EVIDENCE pr=79 run=501 job=601 runner=GitHub Actions 7 head={A}", self.fake.messages)

    def test_hosted_gleam_job_identity_is_exact(self):
        for change in ({"runner_group_name": "Default"}, {"labels": ["ubuntu-latest"]}, {"labels": ["self-hosted", "ubuntu-24.04"]},
                       {"runner_name": "self-hosted-gleam-1"}, {"runner_name": "GitHub Actions x"}, {"runner_name": None},
                       {"conclusion": "failure"}, {"head_sha": B}, {"run_id": 101}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.gleam_job_changes = change
                self.refuses()
        for steps in ([{"name": "Run ./scripts/check.sh", "conclusion": "success"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "failure"},
                       {"name": "Run ./scripts/check.sh", "conclusion": "success"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                       {"name": "Run ./scripts/check.sh", "conclusion": "skipped"}]):
            with self.subTest(steps=steps):
                self.setUp()
                self.fake.gleam_job_changes = {"steps": steps}
                self.refuses()

    def test_old_gleam_job_name_is_refused_even_when_skipped(self):
        # A run of the former shape lists a skipped `gleam` job next to `gleam-hosted`: not evidence.
        self.fake.gleam_other_changes = {"name": "gleam", "conclusion": "skipped"}
        self.refuses("Expected exactly one executed Gleam job")

    def test_both_gleam_jobs_executed_or_none_refused(self):
        self.fake.gleam_job_changes = {"conclusion": "skipped"}
        self.refuses("Expected exactly one executed Gleam job")
        self.setUp()
        self.fake.gleam_other_changes = {"conclusion": "success"}
        self.refuses("Expected exactly one executed Gleam job")


class PullRequestEvidence(unittest.TestCase):
    """ELZ-059: the full pull_request run of the exact head is the merge evidence. The queue adopts it, waits
    for it, never cancels it, and dispatches only when GitHub started none."""

    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def refuses(self, pattern=None):
        with self.assertRaisesRegex(queue.QueueError, pattern or ".+"):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))

    def test_the_pull_request_run_is_adopted_without_a_dispatch(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertEqual([], self.fake.commands(["gh", "workflow", "run"]))
        self.assertIn(f"Adopted pull_request run 700 for PR #79 head={A}", self.fake.messages)
        self.assertTrue(self.fake.messages[-2].startswith("ELZOO GLEAM EVIDENCE"))  # the default path list is a Gleam path
        self.assertEqual(merge_line(700, 200),
                         self.fake.messages[-1])
        self.assertTrue(self.fake.merged)

    def test_after_update_branch_the_new_heads_run_is_adopted_and_nothing_is_cancelled(self):
        self.fake.stale = True
        self.fake.pr_runs = [self.fake.pr_run(700, head_sha=B)]
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertEqual(self.fake.commands(["gh", "pr", "update-branch"]),
                         [["gh", "pr", "update-branch", "79", "-R", queue.REPO]])
        self.assertEqual(B, self.fake.commands(["gh", "pr", "merge"])[0][-1])
        # The fake refuses every write through gh api (cancel is a POST), so a cancel would have failed the test.
        self.assertFalse([c for c in self.fake.calls if c[:2] == ["gh", "api"] and ("-X" in c or "POST" in c)])
        self.assertIn(f"run=700 jobs={jobs_text(200)} head={B}", self.fake.messages[-1])

    def test_the_queue_waits_for_the_run_of_the_new_head(self):
        self.fake.stale = True
        self.fake.pr_runs = [self.fake.pr_run(700, head_sha=B)]
        self.fake.pr_run_hidden_calls = 3
        self.q = self.fake.make_queue(timeout=3600, pr_run_wait=300)
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertEqual(3, len([m for m in self.fake.messages if m == "Waiting: pull_request run on the exact head"]))
        self.assertTrue(self.fake.merged)

    def test_without_a_run_the_queue_dispatches_and_says_why(self):
        self.q = self.fake.make_queue(timeout=3600, pr_run_wait=45)
        self.q.process(79)
        self.assertEqual(1, self.fake.dispatches)
        reasons = [m for m in self.fake.messages if m.startswith("No pull_request run for PR #79")]
        self.assertEqual(1, len(reasons))
        self.assertIn("within 45 s", reasons[0])
        self.assertIn("a dispatch run is not a pull request status", reasons[0])
        self.assertIn(f"run=101 jobs={jobs_text(201)}", self.fake.messages[-1])

    def test_only_the_same_repository_pull_request_run_of_the_exact_head_is_adopted(self):
        # Every run below differs from the exact-head pull_request run in one respect: none is adopted, so the
        # queue falls back to its own dispatch.
        others = {
            "previous head": self.fake.pr_run(701, head_sha=B),
            "another branch": self.fake.pr_run(702, head_branch="task/ELZ-040"),
            "dispatch event": self.fake.pr_run(703, event="workflow_dispatch"),
            "push event": self.fake.pr_run(704, event="push"),
            "another workflow id": self.fake.pr_run(705, workflow_id=20),
            "another workflow file": self.fake.pr_run(706, path=".github/workflows/symbolic-gleam.yml"),
            "fork repository": self.fake.pr_run(707, head_repository={"full_name": "someone/elzoo"}),
            "no head repository": self.fake.pr_run(708, head_repository=None),
            "string head repository": self.fake.pr_run(709, head_repository="balungpisah/elzoo"),
            # ELZ-059 review B1: GitHub lists the pull requests that the run belongs to, with their base.
            "another base branch": self.fake.pr_run(710, pull_requests=[
                {"number": 79, "base": {"ref": "some-other-base", "repo": {"url": f"https://api.github.com/repos/{queue.REPO}"}}}]),
            "another pull request": self.fake.pr_run(711, pull_requests=[
                {"number": 555, "base": {"ref": "main", "repo": {"url": f"https://api.github.com/repos/{queue.REPO}"}}}]),
            "another base repository": self.fake.pr_run(712, pull_requests=[
                {"number": 79, "base": {"ref": "main", "repo": {"url": "https://api.github.com/repos/someone/elzoo"}}}]),
            "no pull requests": self.fake.pr_run(713, pull_requests=[]),
            "no pull request field": self.fake.pr_run(714, pull_requests=None),
            "string pull requests": self.fake.pr_run(715, pull_requests="79"),
            "malformed pull request": self.fake.pr_run(716, pull_requests=[None, "79", {"number": 79}, {"number": 79, "base": "main"}]),
        }
        for label, run in others.items():
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = [run]
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)
                self.assertTrue(any(m.startswith("No pull_request run for PR #79") for m in self.fake.messages))

    def test_a_newer_run_of_another_base_is_not_adopted_and_stops_the_merge(self):
        # Run 710 belongs to another PR, so the queue adopts 700. But the push run of the merge would let the
        # higher ID (710) decide, so the queue refuses to merge until the newer run is out of the way.
        other = self.fake.pr_run(710, pull_requests=[
            {"number": 555, "base": {"ref": "some-other-base", "repo": {"url": f"https://api.github.com/repos/{queue.REPO}"}}}])
        self.fake.pr_runs = [self.fake.pr_run(700), other]
        self.refuses("Run 710 on head .* is newer than the evidence run 700")
        self.assertEqual(0, self.fake.dispatches)
        self.assertIn(f"Adopted pull_request run 700 for PR #79 head={A}", self.fake.messages)

    def test_a_pull_request_that_ever_changed_its_base_does_not_use_a_pull_request_run(self):
        # GitHub lists the current base on the run, and the time of the event does not tell which base the run
        # tested (a retarget just before the run still leaves the run on the old base; an automatic one is
        # another event type). Any base change makes the queue dispatch its own run.
        for label, events in (
                ("by hand", [{"event": "base_ref_changed", "created_at": "2026-11-09T01:30:00Z"}]),
                ("by hand before the run", [{"event": "base_ref_changed", "created_at": "2026-11-09T00:59:59Z"}]),
                ("by hand just before the run", [{"event": "base_ref_changed", "created_at": "2026-11-09T01:00:00Z"}]),
                ("without a time", [{"event": "base_ref_changed"}]),
                ("automatic", [{"event": "automatic_base_change_succeeded", "created_at": "2026-11-09T01:30:00Z"}]),
                ("automatic failure", [{"event": "automatic_base_change_failed"}]),
                ("odd entry", [{"event": "labeled"}, None]),
                ("odd string entry", ["x"])):
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.timeline = events
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)
                self.assertTrue(any("base of PR #79 changed once" in m for m in self.fake.messages))
                self.assertIn(f"run=101 jobs={jobs_text(201)}", self.fake.messages[-1])

    def test_other_timeline_events_keep_the_run(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.timeline = [{"event": "labeled", "created_at": "2026-11-09T02:00:00Z"},
                              {"event": "head_ref_force_pushed"}, {"event": "committed"}]
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertIn(f"run=700 jobs={jobs_text(200)}", self.fake.messages[-1])

    def test_a_timeline_page_that_is_not_a_list_refuses_the_merge(self):
        for pages in ([{"event": "base_ref_changed", "created_at": "2026-11-09T02:00:00Z"}], [[], {"x": 1}],
                      [None], [[]] + ["x"], "x"):
            with self.subTest(pages=pages):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.timeline_pages = pages
                self.refuses("Invalid timeline pages|Invalid JSON")

    def test_a_run_of_a_sibling_pull_request_from_the_same_branch_is_not_adopted(self):
        # The run lists the pull requests that are open for its head now. A run that a sibling PR with another
        # base started can list only this PR after the sibling is closed, or both while it is open.
        for label, others in (("closed sibling", [{"number": 79}, {"number": 200}]),
                              ("only another number", [{"number": 200}]),
                              ("no pull request at all", []),
                              ("odd entries", [{"number": 79}, None]),
                              ("string number", [{"number": "79"}])):
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.head_prs = others
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)
                self.assertTrue(any("Another pull request exists for branch task/ELZ-039" in m
                                    for m in self.fake.messages))
                self.assertIn(f"run=101 jobs={jobs_text(201)}", self.fake.messages[-1])

    def test_a_sibling_pull_request_that_appears_after_the_adoption_stops_the_merge(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.head_prs_later = [{"number": 79}, {"number": 200}]
        self.refuses("appeared after run 700 was adopted")
        self.assertEqual(0, self.fake.dispatches)

    def test_a_base_change_that_appears_after_the_adoption_stops_the_merge(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.timeline_later = [{"event": "base_ref_changed", "created_at": "2026-11-09T02:00:00Z"}]
        self.refuses("appeared after run 700 was adopted")

    def test_the_adopted_run_is_checked_again_just_before_the_merge_and_not_earlier_than_the_evidence(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.q.process(79)
        self.assertEqual((2, 2), (self.fake.head_prs_calls, self.fake.timeline_calls))
        calls = self.fake.calls
        last_listing = max(i for i, c in enumerate(calls) if c[:2] == ["gh", "api"] and "/pulls?head=" in c[-1])
        merge = next(i for i, c in enumerate(calls) if c[:3] == ["gh", "pr", "merge"])
        evidence = max(i for i, c in enumerate(calls) if c[:2] == ["gh", "api"] and c[-1].endswith("/logs"))
        gleam = max(i for i, c in enumerate(calls) if c[:2] == ["gh", "api"] and "symbolic-gleam.yml/runs?" in c[-1])
        last_view = max(i for i, c in enumerate(calls[:merge]) if c[:3] == ["gh", "pr", "view"])
        fetch = max(i for i, c in enumerate(calls[:merge]) if c[:2] == ["git", "fetch"])
        # The recheck comes after everything that takes time (evidence, Gleam wait, head and ancestry rereads).
        self.assertTrue(max(evidence, gleam, last_view, fetch) < last_listing < merge)
        newer = [i for i, c in enumerate(calls) if c[:2] == ["gh", "api"] and "head_sha=" in c[-1] and "event=" not in c[-1]]
        self.assertEqual(1, len(newer))
        self.assertTrue(max(evidence, gleam, last_view, fetch) < newer[0] < merge)

    def newer_run(self, run_id, **changes):
        run = dict(id=run_id, workflow_id=10, path=".github/workflows/symbolic-check.yml", event="pull_request",
                   head_branch="task/ELZ-039", head_sha=A, status="completed", conclusion="success", run_attempt=1,
                   head_repository={"full_name": queue.REPO})
        run.update(changes)
        return run

    def test_a_newer_run_on_the_head_stops_the_merge_on_both_paths(self):
        # The push run of the merge lets the run with the highest ID on the head decide. A run of a sibling pull
        # request or another dispatch that is newer than the evidence run would decide in place of it.
        for label, runs, dispatch in (
                ("adopted run, newer pull_request run", [self.fake.pr_run(700)], self.newer_run(800)),
                ("dispatch fallback, newer pull_request run", None, self.newer_run(900)),
                ):
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = runs
                self.fake.extra_head_runs = [dispatch]
                self.refuses(f"Run {dispatch['id']} on head {A} is newer than the evidence run")

    def test_runs_that_the_skip_decision_would_not_take_do_not_stop_the_merge(self):
        for label, run in (("older run", self.newer_run(600)),
                           # A dispatch run tests the head itself; the skip decision accepts it only when it is a
                           # completed success with the full marker. It must not block an adopted run for good.
                           ("newer dispatch run", self.newer_run(800, event="workflow_dispatch")),
                           ("newer failed dispatch run", self.newer_run(801, event="workflow_dispatch", conclusion="failure")),
                           ("the evidence run itself", self.newer_run(700)),
                           ("fork pull request run", self.newer_run(800, head_repository={"full_name": "someone/elzoo"})),
                           ("string head repository", self.newer_run(801, head_repository="balungpisah/elzoo")),
                           ("no head repository", self.newer_run(802, head_repository=None)),
                           ("push event", self.newer_run(803, event="push")),
                           ("schedule event", self.newer_run(804, event="schedule")),
                           ("another workflow file", self.newer_run(805, path=".github/workflows/symbolic-gleam.yml")),
                           ("another head", self.newer_run(806, head_sha=B)),
                           ("string id on another head", self.newer_run("x", head_sha=B)),
                           ("not a run", None)):
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.extra_head_runs = [run]
                self.q.process(79)
                self.assertTrue(self.fake.merged)

    def test_a_malformed_run_listing_before_the_merge_refuses(self):
        for pages in ([None], ["x"], [{"workflow_runs": None}], [{"workflow_runs": "x"}], [{}], {"workflow_runs": []}):
            with self.subTest(pages=pages):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.head_run_pages = pages
                self.refuses("Invalid run pages|Invalid JSON")

    def test_a_newer_run_on_a_later_page_is_found(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        page1 = {"workflow_runs": [self.newer_run(700, head_repository={"full_name": queue.REPO})]}
        page2 = {"workflow_runs": [self.newer_run(900)]}
        self.fake.head_run_pages = [page1, page2]
        self.refuses("Run 900 on head .* is newer than the evidence run 700")

    def test_a_newer_run_with_an_unreadable_id_refuses(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.extra_head_runs = [self.newer_run("x")]
        self.refuses("Invalid run ID")

    def test_the_run_listing_before_the_merge_has_no_event_filter(self):
        # The skip decision lists by head_sha only; the check must see the same runs.
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.q.process(79)
        listing = [c[-1] for c in self.fake.calls if c[:2] == ["gh", "api"] and "head_sha=" in c[-1]
                   and "event=" not in c[-1]]
        self.assertEqual(1, len(listing))
        self.assertIn(f"head_sha={A}", listing[0])

    def test_the_dispatch_fallback_has_no_adopted_run_to_recheck(self):
        self.q.process(79)
        self.assertEqual((0, 0), (self.fake.head_prs_calls, self.fake.timeline_calls))

    def test_the_sibling_listing_asks_for_every_state_of_the_head_branch_of_this_repository(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.q.process(79)
        listing = next(c[-1] for c in self.fake.calls if c[:2] == ["gh", "api"] and "/pulls?head=" in c[-1])
        self.assertIn("head=balungpisah%3Atask%2FELZ-039", listing)
        self.assertIn("state=all", listing)

    def test_a_malformed_sibling_listing_refuses_the_merge(self):
        for pages in ({"number": 79}, [{"number": 79}], [None], "x"):
            with self.subTest(pages=pages):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.head_prs_pages = pages
                self.refuses("Invalid pull request pages|Invalid JSON")

    def test_malformed_run_entries_are_ignored(self):
        self.fake.pr_runs = [None, "x", 7, {}, {"id": "9"}, self.fake.pr_run(700)]
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertIn(f"run=700 jobs={jobs_text(200)}", self.fake.messages[-1])

    def test_the_latest_run_decides(self):
        # Two pull_request runs for the same head: the higher ID is adopted, so a newer failure is not hidden.
        self.fake.pr_runs = [self.fake.pr_run(700), self.fake.pr_run(710)]
        self.fake.run_changes = {"conclusion": "failure"}
        self.refuses("Run 710: failure")
        self.assertTrue(any("Stopped while awaiting run 710" in m for m in self.fake.messages))
        self.assertEqual(0, self.fake.dispatches)

    def test_a_failed_cancelled_or_unfinished_pull_request_run_never_merges(self):
        for change, pattern in (({"conclusion": "failure"}, "failure"), ({"conclusion": "cancelled"}, "cancelled"),
                                ({"conclusion": "timed_out"}, "timed_out"), ({"conclusion": None}, ".+"),
                                ({"status": "in_progress", "conclusion": None}, "Timed out")):
            with self.subTest(change=change):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                self.fake.run_changes = change
                self.refuses(pattern)

    def test_evidence_rules_apply_to_the_adopted_run_too(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        for label, setup in (("failed job", lambda f: f.job_changes.update(conclusion="failure")),
                             ("other runner", lambda f: f.job_changes.update(runner_name="symbolic-elzoo")),
                             ("no identity step", lambda f: f.job_changes.update(steps=[{"name": "Run mix check", "conclusion": "success"}])),
                             ("mix check skipped", lambda f: setattr(f, "steps", [{"name": "Run mix check", "conclusion": "skipped"}])),
                             ("affected marker", lambda f: setattr(f, "log", "ELZOO AFFECTED CHECK PASSED\nELZOO CHECK PASSED\n")),
                             ("only the affected marker", lambda f: setattr(f, "log", "ELZOO AFFECTED CHECK PASSED\n")),
                             ("no marker", lambda f: setattr(f, "log", "")),
                             ("other head", lambda f: f.job_changes.update(head_sha=B)),
                             ("second job", lambda f: setattr(f, "duplicate_job", True))):
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = [self.fake.pr_run(700)]
                setup(self.fake)
                self.refuses()

    def test_a_rerun_while_collecting_evidence_is_refused(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.rerun = True
        self.refuses()

    def test_a_listing_failure_fails_closed(self):
        self.fake.pr_run_listing_error = True
        self.refuses("listing failed")
        self.assertEqual(0, self.fake.dispatches)

    def test_the_head_changing_during_the_adopted_run_is_refused(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.move_head = True
        self.refuses()

    def test_the_queue_never_writes_through_the_api(self):
        for stale in (False, True):
            with self.subTest(stale=stale):
                self.setUp()
                self.fake.stale = stale
                self.fake.pr_runs = [self.fake.pr_run(700, head_sha=B if stale else A)]
                self.q.process(79)
                writes = [c for c in self.fake.calls if c[:2] == ["gh", "api"] and any(queue.WRITE_FLAG.match(a) for a in c[2:])]
                self.assertEqual([], writes)
                self.assertFalse(hasattr(self.q, "cancel_duplicate_pr_run"))


class FreezeRule(unittest.TestCase):
    """ELZ-059: the queue refuses to merge while the latest completed push run of main is red and not classified."""

    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def red(self, run_id=9001, conclusion="failure", **changes):
        run = dict(id=run_id, event="push", head_branch="main", status="completed", conclusion=conclusion,
                   path=".github/workflows/symbolic-check.yml")
        run.update(changes)
        return run

    def classify(self, run_id=9001, text=None, login="queue-user", cls="infrastructure"):
        body = text if text is not None else f"CI main status: freeze classification run={run_id} class={cls}"
        return {"body": body, "user": {"login": login}}

    def frozen(self, pattern="Main is frozen"):
        with self.assertRaisesRegex(queue.QueueError, pattern):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertEqual(0, self.fake.dispatches)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))
        self.assertFalse(self.fake.commands(["gh", "pr", "update-branch"]))

    def test_green_main_does_not_freeze(self):
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_a_logged_skip_is_a_success(self):
        # A push run that took the ELZ-058 skip path ends with conclusion success.
        self.fake.main_runs = [self.red(9000, "success"), self.red(9001, "success")]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_a_red_unclassified_run_freezes_the_queue(self):
        for conclusion in ("failure", "timed_out", "cancelled", "neutral", "action_required", "startup_failure", None):
            with self.subTest(conclusion=conclusion):
                self.setUp()
                self.fake.main_runs = [self.red(9001, conclusion)]
                self.frozen(r"Main is frozen: the latest push run 9001 .* is %s and not classified" % conclusion)

    def test_the_message_says_how_to_classify(self):
        self.fake.main_runs = [self.red()]
        self.frozen("Comment on issue #98 as queue-user: 'CI main status: freeze classification run=9001 class=")

    def test_a_valid_classification_by_the_queue_login_lets_the_queue_continue(self):
        for cls in ("infrastructure", "defect", "conflict"):
            with self.subTest(cls=cls):
                self.setUp()
                self.fake.main_runs = [self.red()]
                self.fake.comments = [self.classify(cls=cls)]
                self.q.process(79)
                self.assertTrue(self.fake.merged)
                self.assertTrue(any(f"classified as {cls} on issue #98" in m for m in self.fake.messages))

    def test_surrounding_whitespace_is_allowed_other_changes_are_not(self):
        self.fake.main_runs = [self.red()]
        self.fake.comments = [self.classify(text="  CI main status: freeze classification run=9001 class=defect \n")]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_a_wrong_classification_does_not_unfreeze(self):
        self.fake.main_runs = [self.red()]
        wrong = {
            "wrong author": self.classify(login="someone-else"),
            "no author": {"body": "CI main status: freeze classification run=9001 class=defect", "user": None},
            "other run": self.classify(run_id=9000),
            "next run": self.classify(run_id=9002),
            "unknown class": self.classify(cls="flaky"),
            "capitalized class": self.classify(cls="Defect"),
            "extra words": self.classify(text="CI main status: freeze classification run=9001 class=defect, please"),
            "prefix text": self.classify(text="Note: CI main status: freeze classification run=9001 class=defect"),
            "no number": self.classify(text="CI main status: freeze classification run= class=defect"),
            "wrong phrase": self.classify(text="freeze classification run=9001 class=defect"),
            "no body": {"body": None, "user": {"login": "queue-user"}},
            "not a mapping": "x",
        }
        for label, comment in wrong.items():
            with self.subTest(label=label):
                self.setUp()
                self.fake.main_runs = [self.red()]
                self.fake.comments = [comment]
                self.frozen()

    def test_a_later_green_push_run_unfreezes(self):
        self.fake.main_runs = [self.red(9001), self.red(9002, "success")]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_an_unfinished_newer_run_does_not_hide_the_red_one_or_the_green_one(self):
        self.fake.main_runs = [self.red(9001), self.red(9002, None, status="in_progress", run_attempt=1)]
        self.frozen("push run 9001")
        self.setUp()
        self.fake.main_runs = [self.red(9001, "success"), self.red(9002, None, status="in_progress", run_attempt=1)]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_a_rerun_of_a_red_run_keeps_the_queue_frozen(self):
        # A re-run keeps the run ID; the listing shows it as unfinished with run_attempt > 1. The older green run
        # must not open main while the re-run has no result.
        self.fake.main_runs = [self.red(8999, "success"), self.red(9001, None, status="in_progress", run_attempt=2)]
        self.frozen("push run 9001")
        self.setUp()
        self.fake.main_runs = [self.red(8999, "success"), self.red(9001, None, status="queued", run_attempt=3)]
        self.frozen("push run 9001")
        self.setUp()
        # A classification of that run ID is honoured, as for a red run.
        self.fake.main_runs = [self.red(8999, "success"), self.red(9001, None, status="in_progress", run_attempt=2)]
        self.fake.comments = [self.classify(9001)]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_an_unfinished_first_attempt_does_not_freeze(self):
        # The push run of the latest merge is normally in progress while the next pull request is processed.
        for status in ("in_progress", "queued", "waiting", "requested", "pending"):
            with self.subTest(status=status):
                self.setUp()
                self.fake.main_runs = [self.red(8999, "success"), self.red(9001, None, status=status, run_attempt=1)]
                self.q.process(79)
                self.assertTrue(self.fake.merged)

    def test_an_unfinished_run_without_a_readable_attempt_keeps_the_queue_frozen(self):
        # A listing that cannot show whether a run is a re-run fails closed.
        for attempt in (None, "2", "1", True, False, 0, -1, 1.0, [], {}):
            with self.subTest(attempt=attempt):
                self.setUp()
                self.fake.main_runs = [self.red(8999, "success"), self.red(9001, None, status="in_progress", run_attempt=attempt)]
                self.frozen("push run 9001")

    def test_an_unfinished_run_without_an_attempt_field_keeps_the_queue_frozen(self):
        run = self.red(9001, None, status="in_progress")
        self.fake.main_runs = [self.red(8999, "success"), run]
        self.frozen("push run 9001")

    def test_a_newer_completed_run_replaces_the_rerun(self):
        self.fake.main_runs = [self.red(9001, None, status="in_progress", run_attempt=2), self.red(9002, "success")]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_other_events_branches_and_workflows_do_not_count(self):
        self.fake.main_runs = [self.red(9001, "success"),
                               self.red(9002, "failure", event="pull_request"),
                               self.red(9003, "failure", head_branch="task/ELZ-040"),
                               dict(self.red(9004, "failure"), path=".github/workflows/symbolic-gleam.yml"),
                               "x", None, {}]
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_api_failures_fail_closed(self):
        self.fake.main_listing_error = True
        self.frozen("main listing failed")
        self.setUp()
        self.fake.main_runs = [self.red()]
        self.fake.comments_error = True
        self.frozen("comments failed")
        self.setUp()
        self.fake.main_runs = [self.red()]
        self.fake.login = ""
        self.frozen("Invalid authenticated login")
        self.setUp()
        self.fake.main_runs = [self.red()]
        self.fake.login = "bad login; rm"
        self.frozen("Invalid authenticated login")

    def test_no_completed_push_run_fails_closed(self):
        for runs in ([], [self.red(9001, None, status="in_progress")], [self.red(9001, "success", event="pull_request")]):
            with self.subTest(runs=len(runs)):
                self.setUp()
                self.fake.main_runs = runs
                self.frozen("cannot tell whether main is green")

    def test_main_turning_red_during_the_check_stops_the_merge(self):
        self.fake.main_red_from_call = 2   # the first read (at the start) is green, the read before the merge is red
        self.fake.pr_runs = [self.fake.pr_run(700)]
        with self.assertRaisesRegex(queue.QueueError, "Main is frozen"):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))

    def test_the_freeze_reads_the_push_runs_of_the_backend_workflow_on_main(self):
        self.q.process(79)
        listing = next(c[-1] for c in self.fake.calls if c[:2] == ["gh", "api"] and "event=push" in c[-1])
        self.assertIn("/workflows/symbolic-check.yml/runs?", listing)
        self.assertIn("branch=main", listing)


class GleamPathGate(unittest.TestCase):
    """ELZ-059: the Gleam pull_request run is required only when the pull request changes a Gleam path."""

    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def gleam_listing_calls(self):
        return [c for c in self.fake.calls if c[:2] == ["gh", "api"] and "symbolic-gleam.yml/runs" in c[-1]]

    def test_a_change_without_a_gleam_path_needs_no_gleam_run(self):
        self.fake.diff_paths = ["docs/development/10-symbolic-ci.md", "tasks/ELZ-059.md", "lib/mix/tasks/check.ex"]
        self.fake.gleam_missing = True   # a missing Gleam run would stop the queue if it were required
        self.q.process(79)
        self.assertTrue(self.fake.merged)
        self.assertEqual([], self.gleam_listing_calls())
        self.assertTrue(any(m.startswith("Gleam run not required for PR #79: 3 changed paths, none a Gleam path")
                            for m in self.fake.messages))
        self.assertEqual(f"ELZOO GLEAM GATE not required pr=79 head={A} (3 changed paths, none a Gleam path)",
                         self.fake.messages[-2])
        self.assertFalse(any(m.startswith("ELZOO GLEAM EVIDENCE") for m in self.fake.messages))

    def test_each_gleam_path_requires_the_gleam_run(self):
        for path in ("spikes/gleam_ui/src/gleam_ui.gleam", "spikes/gleam_ui/package-lock.json", "spikes/gleam_ui/a/b/c.txt",
                     "spikes/gleam_ui", ".github/workflows/symbolic-gleam.yml", "scripts/check-ci-runners.py",
                     "scripts/test-ci-runners.py"):
            with self.subTest(path=path):
                self.setUp()
                self.fake.diff_paths = ["docs/a.md", path, "tasks/b.md"]
                self.q.process(79)
                self.assertTrue(self.fake.merged)
                self.assertTrue(self.gleam_listing_calls())
                self.assertTrue(any(m.startswith("ELZOO GLEAM EVIDENCE") for m in self.fake.messages))

    def test_a_required_gleam_run_that_is_missing_stops_the_queue(self):
        self.fake.diff_paths = ["spikes/gleam_ui/src/gleam_ui.gleam"]
        self.fake.gleam_missing = True
        with self.assertRaisesRegex(queue.QueueError, "Timed out: Gleam pull_request run on exact head"):
            self.q.process(79)
        self.assertFalse(self.fake.merged)

    def test_look_alike_paths_are_not_gleam_paths(self):
        for path in ("spikes/gleam_uix/a.gleam", "spikes/gleam_ui_notes.md", "docs/spikes/gleam_ui/a", "x/spikes/gleam_ui/a",
                     ".github/workflows/symbolic-gleam.yml.bak", ".github/workflows/symbolic-check.yml",
                     "scripts/check-ci-runners.pyc", "scripts/check-ci-runners.py.orig", "scripts/test-ci-skip.py",
                     "Spikes/gleam_ui/a"):
            with self.subTest(path=path):
                self.setUp()
                self.fake.diff_paths = [path]
                self.fake.gleam_missing = True
                self.q.process(79)
                self.assertTrue(self.fake.merged)
                self.assertEqual([], self.gleam_listing_calls())

    def test_a_bad_path_list_fails_closed_to_gleam_required(self):
        for label, setup, reason in (
                ("git diff failed", lambda f: setattr(f, "diff_error", True), "path list failed"),
                ("empty list", lambda f: setattr(f, "diff_paths", []), "empty path list"),
                ("absolute path", lambda f: setattr(f, "diff_paths", ["/etc/x"]), "changes /etc/x"),
                ("parent path", lambda f: setattr(f, "diff_paths", ["../x"]), "changes ../x"),
                ("newline in path", lambda f: setattr(f, "diff_paths", ["docs/a\nb"]), "changes"),
                ("backslash in path", lambda f: setattr(f, "diff_paths", ["docs\\a"]), "changes")):
            with self.subTest(label=label):
                self.setUp()
                setup(self.fake)
                self.q.process(79)
                self.assertTrue(self.fake.merged)
                self.assertTrue(self.gleam_listing_calls(), label)
                self.assertTrue(any(m.startswith("ELZOO GLEAM EVIDENCE") for m in self.fake.messages))

    def test_the_path_list_comes_from_git_with_renames_listed_as_two_paths(self):
        self.q.process(79)
        self.assertEqual([["git", "diff", "--name-only", "-z", "--no-renames",
                           f"{M}...refs/remotes/origin/task/ELZ-039"]], self.fake.diff_calls)

    def test_the_path_list_is_taken_against_the_main_sha_of_the_canonical_repository(self):
        self.fake.canonical_main = "d" * 40
        self.q.process(79)
        self.assertEqual("d" * 40 + "...refs/remotes/origin/task/ELZ-039", self.fake.diff_calls[0][-1])

    def test_a_rename_out_of_a_gleam_path_still_requires_the_gleam_run(self):
        # With --no-renames git lists the old path as a deletion, so moving a file out of spikes/gleam_ui/ counts.
        self.fake.diff_paths = ["spikes/gleam_ui/src/old.gleam", "docs/new.gleam"]
        self.q.process(79)
        self.assertTrue(any(m.startswith("ELZOO GLEAM EVIDENCE") for m in self.fake.messages))


class DocsOnlyFastPath(unittest.TestCase):
    """ELZ-071: a run that passed the short docs-only check is evidence only when the queue's own classifier agrees."""

    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def docs_pr(self, run_id=700, paths=("docs/a.md", "tasks/ELZ-1.md")):
        self.fake.pr_runs = [self.fake.pr_run(run_id)]
        self.fake.docs_runs = {run_id}
        self.fake.diff_paths = list(paths)

    def refuses(self, pattern):
        with self.assertRaisesRegex(queue.QueueError, pattern):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))

    def test_a_docs_only_run_with_a_documentation_change_merges_on_the_short_check(self):
        self.docs_pr()
        self.q.process(79)
        self.assertTrue(self.fake.merged)
        self.assertEqual(0, self.fake.dispatches)
        self.assertEqual(merge_line(700, 400) + " mode=docs-only",
                         self.fake.messages[-1])
        # No Gleam path in the change: the Gleam run is not required.
        self.assertTrue(any(m.startswith("Gleam run not required for PR #79") for m in self.fake.messages))
        self.assertTrue(any(m.startswith("ELZOO GLEAM GATE not required") for m in self.fake.messages))

    def test_agents_md_is_documentation_for_the_queue_too(self):
        # ELZ-073 scope addition (owner, 2026-11-09): the queue's own classifier accepts AGENTS.md (the one-code-path
        # test above keeps a code path next to it a full run).
        for paths in (["AGENTS.md"], ["AGENTS.md", "docs/a.md"]):
            with self.subTest(paths=paths):
                self.setUp()
                self.docs_pr(paths=paths)
                self.fake.raw_paths = paths
                self.q.process(79)
                self.assertTrue(self.fake.merged)
                self.assertEqual(0, self.fake.dispatches)
                self.assertTrue(self.fake.messages[-1].endswith(" mode=docs-only"))

    def test_the_queue_classifies_the_fetched_refs_with_the_main_sha_of_the_canonical_repository(self):
        self.docs_pr()
        self.fake.canonical_main = "d" * 40
        self.q.process(79)
        expected = ["git", "diff", "--raw", "-z", "--no-renames", "--no-abbrev", "--ignore-submodules=none",
                    "--no-relative", "d" * 40 + "...refs/remotes/origin/task/ELZ-039", "--"]
        self.assertEqual(expected, queue.CLASSIFIER.diff_argv("d" * 40, "refs/remotes/origin/task/ELZ-039"))
        # Once after the evidence and once right before the merge.
        self.assertEqual([expected, expected], self.fake.raw_diff_calls)

    # --- review of PR #135, finding 1: a documentation merge must not hide a main that is red or unfinished -----
    def test_the_short_check_needs_a_main_whose_push_run_completed_with_success(self):
        for label, runs in (
                ("red", [self.fake.main_head_run(conclusion="failure")]),
                ("cancelled", [self.fake.main_head_run(conclusion="cancelled")]),
                ("timed out", [self.fake.main_head_run(conclusion="timed_out")]),
                ("skipped", [self.fake.main_head_run(conclusion="skipped")]),
                ("no conclusion", [self.fake.main_head_run(conclusion=None)]),
                ("no run at all", []),
                ("newest is red, older is green", [self.fake.main_head_run(9000), self.fake.main_head_run(9001, conclusion="failure")]),
                ("another event only", [self.fake.main_head_run(event="workflow_dispatch")]),
                ("another branch only", [self.fake.main_head_run(head_branch="task/ELZ-040")]),
                ("another commit only", [self.fake.main_head_run(head_sha="e" * 40)]),
                ("another workflow only", [self.fake.main_head_run(path=".github/workflows/symbolic-gleam.yml")]),
                ("odd entries only", [None, "x", 7, {}])):
            with self.subTest(label=label):
                self.setUp()
                self.q = self.fake.make_queue(timeout=3600)
                self.docs_pr()
                self.fake.main_head_runs = runs
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches, label)
                self.assertTrue(any("push run of the current main is not a completed success" in m for m in self.fake.messages))
                self.assertNotIn("mode=docs-only", self.fake.messages[-1])

    def test_the_newest_push_run_of_main_decides(self):
        self.docs_pr()
        self.fake.main_head_runs = [self.fake.main_head_run(9000, conclusion="failure"), self.fake.main_head_run(9001)]
        self.q.process(79)     # a red run, then the green re-run result with a higher ID
        self.assertEqual(0, self.fake.dispatches)
        self.assertIn("mode=docs-only", self.fake.messages[-1])

    def test_a_push_run_of_main_in_progress_is_awaited_for_a_bounded_time(self):
        self.docs_pr()
        self.q = self.fake.make_queue(timeout=3600)
        self.fake.main_head_runs = [self.fake.main_head_run(status="in_progress", conclusion=None)]
        self.fake.main_head_runs_later = [self.fake.main_head_run()]
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertTrue(any(m == "Waiting: push run of main ccccccc to finish" or m.startswith("Waiting: push run of main")
                            for m in self.fake.messages))
        self.assertIn("mode=docs-only", self.fake.messages[-1])

    def test_a_push_run_that_never_finishes_ends_the_wait_and_needs_a_full_run(self):
        self.docs_pr()
        self.q = self.fake.make_queue(timeout=36000)
        self.fake.main_head_runs = [self.fake.main_head_run(status="in_progress", conclusion=None)]
        self.q.process(79)
        self.assertEqual(1, self.fake.dispatches)
        waits = [m for m in self.fake.messages if m.startswith("Waiting: push run of main")]
        self.assertTrue(waits)
        self.assertLessEqual(len(waits) * 15, queue.MAIN_RUN_WAIT + 15)    # bounded by MAIN_RUN_WAIT, not by the PR deadline

    def test_a_push_run_that_is_not_listed_yet_is_awaited_too(self):
        self.docs_pr()
        self.q = self.fake.make_queue(timeout=3600)
        self.fake.main_head_hidden = 2
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertIn("mode=docs-only", self.fake.messages[-1])

    def test_a_failed_or_malformed_push_run_listing_needs_a_full_run(self):
        for label, change in (("error", dict(main_head_error=True)), ("not an object", dict(main_head_raw=["x"])),
                              ("no list", dict(main_head_raw={"workflow_runs": "x"})),
                              ("string", dict(main_head_raw="garbage")),
                              ("odd id", dict(main_head_runs=[{"id": "x", "event": "push", "head_branch": "main",
                                                               "head_sha": "c" * 40, "status": "completed",
                                                               "conclusion": "success",
                                                               "path": ".github/workflows/symbolic-check.yml"}]))):
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                for name, value in change.items():
                    setattr(self.fake, name, value)
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)

    def test_main_turning_red_between_the_two_classifications_refuses_the_merge(self):
        self.docs_pr()
        self.fake.main_head_runs_later = [self.fake.main_head_run(conclusion="failure")]
        self.refuses("no longer matches the queue's own classification")

    def test_the_push_run_listing_asks_for_the_canonical_main_commit(self):
        self.docs_pr()
        self.fake.canonical_main = "d" * 40
        self.fake.main_head_runs = [self.fake.main_head_run(head_sha="d" * 40)]
        self.q.process(79)
        listings = [c[-1] for c in self.fake.calls if c[:2] == ["gh", "api"] and "event=push" in c[-1] and "head_sha=" in c[-1]]
        self.assertEqual(2, len(listings))     # once per classification
        self.assertTrue(all("head_sha=" + "d" * 40 in listing and "per_page=100" in listing for listing in listings))

    def test_a_full_run_needs_no_push_run_of_main_here(self):
        # The freeze rule covers a full run; the extra rule is for the short check only.
        self.fake.diff_paths = ["docs/a.md"]
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.fake.main_head_runs = [self.fake.main_head_run(conclusion="failure")]
        self.q.process(79)
        self.assertEqual(0, self.fake.main_head_calls)

    def test_a_full_run_is_still_accepted_without_a_classification(self):
        self.fake.diff_paths = ["docs/a.md"]
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.q.process(79)
        self.assertEqual([], self.fake.raw_diff_calls)
        self.assertNotIn("mode=docs-only", self.fake.messages[-1])
        self.assertEqual(merge_line(700, 200),
                         self.fake.messages[-1])

    def test_the_dispatch_fallback_run_is_accepted_as_before(self):
        self.q.process(79)
        self.assertEqual(1, self.fake.dispatches)
        self.assertEqual([], self.fake.raw_diff_calls)
        self.assertNotIn("mode=", self.fake.messages[-1])

    def test_one_code_path_makes_the_queue_dispatch_a_full_run(self):
        # The run passed the short check (its classifier or its change differs), the queue's own list has a code path.
        for label, paths in (("script", ["docs/a.md", "scripts/tool.py"]),
                             ("the classifier itself", ["scripts/ci-change-class.py", "docs/a.md"]),
                             ("workflow", [".github/workflows/symbolic-check.yml"]),
                             ("lib", ["lib/elzoo/export.ex"]),
                             ("test", ["test/registry_test.exs"]),
                             ("pieces readme", ["pieces/core/selection/README.md"]),
                             ("ledger", ["LEDGER.md"]),
                             ("file read by the export", ["docs/consuming.md"]),
                             ("traversal", ["docs/../scripts/x.py"]),
                             ("look-alike", ["docs-x/a.md"]),
                             ("empty list", [])):
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr(paths=paths)
                self.fake.raw_paths = paths
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)
                self.assertTrue(any("the queue does not accept the short check" in m and "dispatching a full run" in m
                                    for m in self.fake.messages))
                self.assertEqual(merge_line(101, 201),
                                 self.fake.messages[-1])
                self.assertTrue(any("does NOT satisfy branch protection" in m for m in self.fake.messages))

    def test_a_failed_or_odd_classification_makes_the_queue_dispatch_a_full_run(self):
        for label, changes in (("git failed", dict(raw_error=True)),
                               ("malformed output", dict(raw_output="garbage")),
                               ("rename entry", dict(raw_entries=[("100644", "100644", "R", "docs/a.md")])),
                               ("symlink entry", dict(raw_entries=[("000000", "120000", "A", "docs/link")])),
                               ("submodule entry", dict(raw_entries=[("000000", "160000", "A", "docs/sub")])),
                               ("odd count of fields", dict(raw_output=":100644 100644 " + "a" * 40 + " " + "b" * 40 + " M\x00")),
                               ("abbreviated names", dict(raw_output=":100644 100644 aaaaaaa bbbbbbb M\x00docs/a.md\x00"))):
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                for name, value in changes.items():
                    setattr(self.fake, name, value)
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)
                self.assertNotIn("mode=docs-only", self.fake.messages[-1])

    def test_a_missing_classifier_means_the_full_run(self):
        self.docs_pr()
        original = queue.CLASSIFIER
        queue.CLASSIFIER = None
        try:
            self.q.process(79)
        finally:
            queue.CLASSIFIER = original
        self.assertEqual(1, self.fake.dispatches)
        self.assertEqual([], self.fake.raw_diff_calls)

    def test_a_classifier_that_raises_means_the_full_run(self):
        class Broken:
            Unclear = ValueError

            @staticmethod
            def diff_argv(base, head):
                raise ValueError("unsafe")

        self.docs_pr()
        original = queue.CLASSIFIER
        queue.CLASSIFIER = Broken
        try:
            self.q.process(79)
        finally:
            queue.CLASSIFIER = original
        self.assertEqual(1, self.fake.dispatches)

    def test_the_answer_must_hold_again_right_before_the_merge(self):
        self.docs_pr()
        self.fake.raw_paths_later = ["scripts/tool.py"]    # the second classification sees a code path
        self.refuses("no longer matches the queue's own classification")
        self.assertEqual(2, len(self.fake.raw_diff_calls))

    def test_the_short_check_needs_every_one_of_its_steps_green(self):
        # The plan job of a docs-only run: the identity step, the classification and the short check, each once and green.
        gate = {"name": "Verify the GitHub-hosted runner", "conclusion": "success"}

        def shape(classify="success", docs="success", extra=()):
            return [gate] + ([{"name": "Classify the change", "conclusion": classify}] if classify else []) + \
                   ([{"name": "Docs-only check", "conclusion": docs}] if docs else []) + list(extra)
        bad = {
            "docs-only check failed": shape(docs="failure"),
            "docs-only check skipped": shape(docs="skipped"),
            "docs-only check cancelled": shape(docs="cancelled"),
            "docs-only check missing": shape(docs=None),
            "docs-only check without conclusion": shape(docs=None, extra=[{"name": "Docs-only check"}]),
            "docs-only check twice": shape(extra=[{"name": "Docs-only check", "conclusion": "success"}]),
            "classify failed": shape(classify="failure"),
            "classify skipped": shape(classify="skipped"),
            "classify missing": shape(classify=None),
            "classify twice": shape(extra=[{"name": "Classify the change", "conclusion": "success"}]),
        }
        for label, steps in bad.items():
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                self.fake.jobs_changes = {"check-plan": {"steps": steps}}
                self.refuses("Classification step|Docs-only check step")
                self.assertEqual(0, self.fake.dispatches)

    def test_the_marker_must_be_a_line_of_its_own(self):
        marker = "ELZOO DOCS-ONLY CHECK PASSED"
        good = {"with a timestamp": f"2026-11-09T05:00:00.0000000Z {marker}\n", "bare": f"{marker}\n",
                "among other lines": f"x\n2026-11-09T05:00:00.0000000Z {marker}\ny\n",
                "carriage return": f"2026-11-09T05:00:00.0000000Z {marker}\r\n"}
        for label, log in good.items():
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                self.fake.docs_log = log
                self.q.process(79)
                self.assertTrue(self.fake.merged)
        bad = {
            "no marker": "2026-11-09T05:00:00.0000000Z all done\n",
            "empty log": "",
            "echoed command": f"2026-11-09T05:00:00.0000000Z echo \"{marker}\"\n",
            "echoed with run prefix": f"2026-11-09T05:00:00.0000000Z ##[group]Run echo \"{marker}\"\n",
            "text before": f"2026-11-09T05:00:00.0000000Z x {marker}\n",
            "text after": f"2026-11-09T05:00:00.0000000Z {marker} but not really\n",
            "lower case": f"2026-11-09T05:00:00.0000000Z {marker.lower()}\n",
            "the full marker only": "2026-11-09T05:00:00.0000000Z ELZOO CHECK PASSED\n",
            "the push skip line": "2026-11-09T05:00:00.0000000Z ELZOO PUSH CHECK SKIPPED (identical tree)\n",
            "both markers": f"{marker}\nELZOO CHECK PASSED\n",
            "with the affected marker": f"{marker}\nELZOO AFFECTED CHECK PASSED (not full)\n",
        }
        for label, log in bad.items():
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                self.fake.docs_log = log
                self.refuses("marker")

    def test_a_docs_only_run_needs_the_plan_line_run_false(self):
        # Review of PR #144, note 1: the marker alone is not the short shape; the plan line must say run=false.
        stamp = "2026-11-09T05:00:00.0000000Z "
        marker = stamp + "ELZOO DOCS-ONLY CHECK PASSED\n"
        for label, log in (("no plan line", marker),
                           ("plan says run=true", marker + stamp + "ELZOO PLAN: run=true skip=false docs_only=true\n"),
                           ("plan says docs_only=false", marker + stamp + "ELZOO PLAN: run=false skip=false docs_only=false\n"),
                           ("echoed plan line", marker + stamp + 'echo "ELZOO PLAN: run=false skip=false docs_only=true"\n')):
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                self.fake.logs_by_job = {"check-plan": log}
                self.refuses("docs-only success marker or plan line")
        self.setUp()
        self.docs_pr()
        self.fake.logs_by_job = {"check-plan": marker + stamp + "ELZOO PLAN: run=false skip=false docs_only=true\n"}
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    def test_a_docs_only_run_is_not_accepted_by_another_event_or_head_or_runner(self):
        for label, change in (("failed run", dict(run_changes={"conclusion": "failure"})),
                              ("another head", dict(run_changes={"head_sha": B})),
                              ("another runner", dict(job_changes={"runner_name": "self", "runner_group_name": "x"})),
                              ("an unfinished run", dict(run_changes={"status": "in_progress", "conclusion": None}))):
            with self.subTest(label=label):
                self.setUp()
                self.docs_pr()
                for name, value in change.items():
                    setattr(self.fake, name, value)
                with self.assertRaises(queue.QueueError):
                    self.q.process(79)
                self.assertFalse(self.fake.merged)

    def test_a_job_with_the_old_shape_is_not_a_docs_only_run(self):
        # A sixth job (an old-shape run) is refused as before, whatever the steps say.
        self.docs_pr()
        self.fake.other_job_changes = {"name": "check-other"}
        self.refuses("Expected exactly the five backend jobs")

    def test_the_full_step_alone_never_substitutes_for_the_docs_only_shape_when_the_queue_forbids_it(self):
        # After the fallback dispatch the evidence run must be a full run: a docs-only shape is refused.
        self.docs_pr()
        self.fake.docs_runs = {700, 101}      # the fallback run also has the docs-only shape
        self.fake.raw_paths = ["scripts/tool.py"]
        self.refuses("Full check jobs missing or skipped: not a full run")
        self.assertEqual(1, self.fake.dispatches)

    def test_the_newer_run_check_and_the_adoption_rules_still_apply(self):
        self.docs_pr()
        self.fake.extra_head_runs = [dict(self.fake.pr_run(900), status="completed", conclusion="success")]
        self.refuses("Run 900 on head .* is newer than the evidence run 700")

    def test_the_frozen_main_still_stops_a_docs_only_pull_request(self):
        self.docs_pr()
        self.fake.main_runs = [dict(id=9001, event="push", head_branch="main", status="completed", conclusion="failure",
                                    path=".github/workflows/symbolic-check.yml")]
        self.refuses("Main is frozen")

    def test_the_queue_never_reads_the_classifier_of_the_pull_request(self):
        self.docs_pr()
        self.fake.raw_paths = ["scripts/tool.py"]
        self.q.process(79)
        joined = [" ".join(call) for call in self.fake.calls]
        self.assertFalse([c for c in joined if "ci-change-class" in c])
        self.assertFalse([c for c in joined if c.startswith(("git show", "git cat-file", "git ls-tree", "git checkout"))])

    def test_the_queue_loads_the_classifier_next_to_itself(self):
        self.assertIsNotNone(queue.CLASSIFIER)
        self.assertEqual((ROOT / "scripts/ci-change-class.py").resolve(), Path(queue.CLASSIFIER.__file__).resolve())

    def test_a_queue_copied_without_its_classifier_loads_none_and_needs_full_runs(self):
        import shutil
        import tempfile
        directory = tempfile.mkdtemp(prefix="elzoo-queue-alone-")
        self.addCleanup(shutil.rmtree, directory, True)
        shutil.copy(ROOT / "scripts/merge-queue.py", directory)
        alone = importlib.util.spec_from_file_location("queue_alone", Path(directory) / "merge-queue.py")
        module = importlib.util.module_from_spec(alone)
        alone.loader.exec_module(module)
        self.assertIsNone(module.CLASSIFIER)

    def test_every_fallback_dispatch_says_that_protection_is_not_satisfied(self):
        for label, setup in (("no pull_request run", lambda f: None),
                             ("a sibling pull request", lambda f: (setattr(f, "pr_runs", [f.pr_run(700)]),
                                                                    setattr(f, "head_prs", [{"number": 79}, {"number": 200}]))),
                             ("a retargeted pull request", lambda f: (setattr(f, "pr_runs", [f.pr_run(700)]),
                                                                       setattr(f, "timeline", [{"event": "base_ref_changed"}])))):
            with self.subTest(label=label):
                self.setUp()
                setup(self.fake)
                self.q.process(79)
                notes = [m for m in self.fake.messages if "does NOT satisfy branch protection" in m]
                self.assertEqual(1, len(notes))
                self.assertIn("check-hosted and gleam-hosted are required on the pull request", notes[0])

    def test_an_adopted_run_says_nothing_about_protection(self):
        self.fake.pr_runs = [self.fake.pr_run(700)]
        self.q.process(79)
        self.assertFalse([m for m in self.fake.messages if "branch protection" in m])


class ReviewControls(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.q = self.fake.make_queue()

    def refuses(self):
        with self.assertRaises(queue.QueueError):
            self.q.process(79)
        self.assertFalse(self.fake.merged)
        self.assertFalse(self.fake.commands(["gh", "pr", "merge"]))

    def test_missing_gleam_run_never_merges(self):
        self.fake.gleam_missing = True
        self.refuses()

    def test_failed_gleam_run_never_merges(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out"):
            with self.subTest(conclusion=conclusion):
                self.setUp()
                self.fake.gleam_changes["conclusion"] = conclusion
                self.refuses()

    def test_wrong_gleam_sha_never_merges(self):
        self.fake.gleam_changes["head_sha"] = B
        self.refuses()

    def test_old_gleam_success_after_update_is_not_accepted(self):
        self.fake.stale = True
        self.fake.gleam_changes["head_sha"] = A
        self.refuses()
        self.assertEqual(self.fake.pr["headRefOid"], B)

    def test_gleam_success_on_updated_head_is_required_and_recorded(self):
        self.fake.stale = True
        self.q.process(79)
        self.assertIn(f"ELZOO GLEAM EVIDENCE pr=79 run=501 job=601 runner=GitHub Actions 7 head={B}", self.fake.messages)

    def test_wrong_gleam_workflow_event_branch_or_job_refused(self):
        for field, value in (("workflow_id", 10), ("event", "workflow_dispatch"),
                             ("head_branch", "other"), ("path", ".github/workflows/other.yml")):
            with self.subTest(field=field):
                self.setUp()
                self.fake.gleam_changes[field] = value
                self.refuses()
        for change in ({"runner_name": "self-hosted-1"}, {"head_sha": B},
                       {"conclusion": "failure"}, {"run_id": 101}, {"steps": []}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.gleam_job_changes = change
                self.refuses()

    def test_gleam_run_in_progress_times_out_without_merge(self):
        self.fake.gleam_changes["status"] = "in_progress"
        self.refuses()

    def test_gleam_rerun_during_evidence_collection_refused(self):
        self.fake.gleam_rerun = True
        self.refuses()

    def test_main_sha_comes_from_canonical_github_repository(self):
        self.fake.canonical_main = "d" * 40
        self.q.process(79)
        ancestry = self.fake.commands(["git", "merge-base"])
        self.assertTrue(ancestry)
        self.assertTrue(all(call[-2] == "d" * 40 for call in ancestry))
        self.assertFalse(self.fake.commands(["git", "rev-parse", "refs/remotes/origin/main"]))
        self.assertTrue(self.fake.commands(["gh", "api", f"repos/{queue.REPO}/git/ref/heads/main"]))

    def test_invalid_canonical_main_sha_never_merges(self):
        self.fake.canonical_main = None
        self.refuses()

    def test_malformed_api_shape_obeys_stop_and_continue(self):
        for flags, expected in (([], [79]), (["--continue-on-failure"], [79, 80])):
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()):
                fake = Fake()
                seen = []
                execute = fake.execute

                def malformed(argv, allowed=(0,)):
                    if argv[:3] == ["gh", "pr", "view"]:
                        number = int(argv[3])
                        seen.append(number)
                        if number == 79:
                            return subprocess.CompletedProcess(argv, 0, "[]", "")
                        fake.pr["number"] = number
                    return execute(argv, allowed)
                q = fake.make_queue()
                q.run = malformed
                self.assertEqual(queue.main(["79", "80", *flags], queue=q), 1)
                self.assertEqual(list(dict.fromkeys(seen)), expected)
                self.assertFalse(any(call[3] == "79" for call in fake.commands(["gh", "pr", "merge"])))
                self.assertEqual(fake.merged, bool(flags))

    def test_gleam_concurrency_keeps_main_and_dispatch_runs(self):
        source = (ROOT / ".github/workflows/symbolic-gleam.yml").read_text()
        self.assertIn("\nconcurrency:\n  group: gleam-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}\n  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", source)


if __name__ == "__main__":
    unittest.main()
