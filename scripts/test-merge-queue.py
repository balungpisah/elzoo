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
        self.log = "2026-11-07T13:00:00.0000000Z ELZOO CHECK PASSED\n"
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

    def pr_run_ids(self):
        """IDs of the listed runs that really are the same-repository pull_request run of the exact head."""
        return {run["id"] for run in (self.pr_runs or []) if isinstance(run, dict) and isinstance(run.get("id"), int)
                and run.get("event") == "pull_request" and run.get("head_sha") == self.pr["headRefOid"]
                and run.get("head_branch") == self.pr["headRefName"] and run.get("workflow_id") == 10
                and run.get("path") == ".github/workflows/symbolic-check.yml"
                and isinstance(run.get("head_repository"), dict) and run["head_repository"].get("full_name") == queue.REPO}

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
                    run_attempt=1)

    def pr_run(self, run_id, **changes):
        run = dict(id=run_id, workflow_id=10, path=".github/workflows/symbolic-check.yml",
                   event="pull_request", head_branch=self.pr["headRefName"],
                   head_sha=self.pr["headRefOid"], status="in_progress", conclusion=None, run_attempt=1,
                   head_repository={"full_name": queue.REPO})
        run.update(changes)
        return run

    def gleam_run(self):
        result = dict(id=501, workflow_id=20, path=".github/workflows/symbolic-gleam.yml",
                      event="pull_request", head_branch=self.pr["headRefName"],
                      head_sha=self.pr["headRefOid"], status="completed", conclusion="success",
                      run_attempt=1)
        result.update(self.gleam_changes)
        return result

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
            elif "/issues/98/comments" in path:
                if self.comments_error:
                    raise queue.QueueError("gh api exited 1: comments failed")
                out = [self.comments]
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
                job = dict(id=200 + self.dispatches, run_id=self.adopted() or 100 + self.dispatches,
                           name="check-hosted", head_sha=self.pr["headRefOid"], status="completed",
                           conclusion="success", **HOSTED_FIELDS,
                           steps=[{"name": "Verify the GitHub-hosted runner", "conclusion": "success"}] + self.steps)
                job.update(self.job_changes)
                jobs = [job]
                if self.other_job_changes is not None:
                    jobs.append(dict(job, id=998, **self.other_job_changes))
                if self.duplicate_job:
                    jobs.append(dict(job, id=999))
                out = [{"jobs": jobs}]
            elif path.endswith("/logs"):
                out = self.log
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
                         f"ELZOO MERGE EVIDENCE pr=79 run=101 job=201 runner=GitHub Actions 7 head={A} merge={M}")
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

    def test_old_job_names_cannot_supply_evidence(self):
        # The removed self-hosted jobs and the old single job name are not evidence, whatever ran them.
        for name in ("check", "check-fast", "check-any"):
            with self.subTest(name=name):
                self.setUp()
                self.fake.job_changes["name"] = name
                self.refuses("check-hosted job")

    def test_second_backend_job_refused(self):
        for change in ({"name": "check-extra"}, {"name": "check-any", "conclusion": "skipped"},
                       {"conclusion": "success"}, {"conclusion": "skipped"}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.other_job_changes = change
                self.refuses("check-hosted job")

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
        self.assertIn(f"run=102 job=202 runner=GitHub Actions 7 head={B}", self.fake.messages[-1])

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

    def test_duplicate_backend_job_refused(self):
        self.fake.duplicate_job = True
        self.refuses("exactly one")

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

    def test_hosted_job_is_accepted_and_recorded(self):
        self.q.process(79)
        self.assertTrue(self.fake.merged)
        self.assertEqual(self.fake.messages[-1],
                         f"ELZOO MERGE EVIDENCE pr=79 run=101 job=201 runner=GitHub Actions 7 head={A} merge={M}")

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

    def test_hosted_job_still_needs_the_exact_head_run_and_full_check(self):
        for change in ({"conclusion": "failure"}, {"conclusion": "cancelled"}, {"status": "queued"},
                       {"head_sha": B}, {"run_id": 1}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.job_changes = change
                self.refuses()
        for steps in ([{"name": "Verify the GitHub-hosted runner", "conclusion": "success"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                       {"name": "Run mix check", "conclusion": "skipped"}],
                      [{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                       {"name": "Run mix check", "conclusion": "failure"}]):
            with self.subTest(steps=steps):
                self.setUp()
                self.fake.job_changes = {"steps": steps}
                self.refuses("Full check step")

    def test_skipped_hosted_job_is_not_evidence(self):
        # The run succeeded because every job was skipped: no job ran the check.
        self.fake.job_changes = {"conclusion": "skipped"}
        self.refuses("Expected exactly one executed")

    def test_only_one_backend_job_may_have_run(self):
        # A second backend job that executed, whatever its name, is refused: the run has no single evidence job.
        self.fake.other_job_changes = {"conclusion": "success"}
        self.refuses("Expected exactly one executed")

    def test_executed_check_any_is_never_evidence_in_either_lane(self):
        self.fake.job_changes = {"name": "check-any"}
        self.refuses("Expected exactly one executed")

    def test_unknown_or_duplicate_job_names_refused(self):
        for change in ({"name": "other"}, {"name": "check"}, {"name": "gleam-hosted"}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.job_changes = change
                self.refuses("Expected exactly one executed")
        self.setUp()
        self.fake.duplicate_job = True
        self.refuses("Expected exactly one executed")

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
        self.assertEqual(f"ELZOO MERGE EVIDENCE pr=79 run=700 job=200 runner=GitHub Actions 7 head={A} merge={M}",
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
        self.assertIn(f"run=700 job=200 runner=GitHub Actions 7 head={B}", self.fake.messages[-1])

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
        self.assertIn("run=101 job=201", self.fake.messages[-1])

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
        }
        for label, run in others.items():
            with self.subTest(label=label):
                self.setUp()
                self.fake.pr_runs = [run]
                self.q.process(79)
                self.assertEqual(1, self.fake.dispatches)
                self.assertTrue(any(m.startswith("No pull_request run for PR #79") for m in self.fake.messages))

    def test_malformed_run_entries_are_ignored(self):
        self.fake.pr_runs = [None, "x", 7, {}, {"id": "9"}, self.fake.pr_run(700)]
        self.q.process(79)
        self.assertEqual(0, self.fake.dispatches)
        self.assertIn("run=700 job=200", self.fake.messages[-1])

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
        self.fake.main_runs = [self.red(9001), self.red(9002, None, status="in_progress")]
        self.frozen("push run 9001")
        self.setUp()
        self.fake.main_runs = [self.red(9001, "success"), self.red(9002, None, status="in_progress")]
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
                           "refs/remotes/origin/main...refs/remotes/origin/task/ELZ-039"]], self.fake.diff_calls)

    def test_a_rename_out_of_a_gleam_path_still_requires_the_gleam_run(self):
        # With --no-renames git lists the old path as a deletion, so moving a file out of spikes/gleam_ui/ counts.
        self.fake.diff_paths = ["spikes/gleam_ui/src/old.gleam", "docs/new.gleam"]
        self.q.process(79)
        self.assertTrue(any(m.startswith("ELZOO GLEAM EVIDENCE") for m in self.fake.messages))


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
