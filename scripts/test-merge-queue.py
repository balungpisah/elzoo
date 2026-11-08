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
        self.pr_runs = None            # None: default duplicate run on the updated head
        self.cancelled = []
        self.cancel_error = False
        self.cancel_fail_ids = set()
        self.pr_run_listing_error = False
        self.other_job_changes = None
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
        self.canonical_main = M
        self.gleam_reads = 0
        self.gleam_rerun = False

    def run_data(self, run_id):
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
        elif argv[:2] == ["git", "fetch"]:
            pass
        elif argv[:2] == ["git", "rev-parse"]:
            out = M if argv[-1].endswith("/main") else self.pr["headRefOid"]
        elif argv[:2] == ["git", "merge-base"]:
            code = int(self.stale)
        elif argv[:2] == ["gh", "api"]:
            if self.api_error:
                raise queue.QueueError("API unavailable")
            path = argv[-1]
            if argv[2:4] == ["-X", "POST"]:
                if self.cancel_error or int(path.split("/")[-2]) in self.cancel_fail_ids:
                    raise queue.QueueError("cancel refused")
                self.cancelled.append(int(path.split("/")[-2]))
            elif "/workflows/symbolic-check.yml/runs?" in path and "event=pull_request" in path:
                if self.pr_run_listing_error:
                    raise queue.QueueError("listing failed")
                runs = [self.pr_run(700)] if self.pr_runs is None else self.pr_runs
                out = [{"workflow_runs": runs}]  # malformed bodies are passed through as they are
            elif path.endswith("git/ref/heads/main"):
                out = {"object": {"sha": self.canonical_main}}
            elif "/workflows/symbolic-gleam.yml/runs?" in path:
                out = [{"workflow_runs": [] if self.gleam_missing else [self.gleam_run()]}]
            elif path.endswith("/workflows/symbolic-gleam.yml"):
                out = {"id": 20}
            elif "/actions/runs/501/attempts/" in path:
                job = dict(id=601, run_id=501, name="gleam", head_sha=self.pr["headRefOid"],
                           status="completed", conclusion="success", runner_name="symbolic-elzoo-gleam",
                           steps=[{"name": "Run ./scripts/check.sh", "conclusion": "success"}])
                job.update(self.gleam_job_changes)
                out = [{"jobs": [job]}]
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
                job = dict(id=200 + self.dispatches, run_id=100 + self.dispatches,
                           name="check-fast", head_sha=self.pr["headRefOid"], status="completed",
                           conclusion="success", runner_name="symbolic-elzoo", steps=self.steps)
                job.update(self.job_changes)
                # ELZ-057: the other tier's job is skipped in a fast-tier run.
                skipped = dict(job, id=998, name="check-any", conclusion="skipped", runner_name=None, steps=[])
                if self.other_job_changes is not None:
                    skipped.update(self.other_job_changes)
                jobs = [job, skipped]
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

    def make_queue(self, timeout=30):
        return queue.Queue(run=self.execute, sleep=self.sleep, clock=lambda: self.now,
                           timeout=timeout, poll=15, emit=lambda text, **_: self.messages.append(text))

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
                         f"ELZOO MERGE EVIDENCE pr=79 run=101 job=201 runner=symbolic-elzoo head={A} merge={M}")
        self.assertFalse(any(flag in call for call in self.fake.calls
                             for flag in ("--rebase", "--force", "--admin", "--delete-branch", "--auto")))
        self.assertFalse(self.fake.commands(["git", "push"]))

    def test_other_approved_runner(self):
        self.fake.job_changes["runner_name"] = "macbook-ubuntu-elzoo-candidate"
        self.q.process(79)
        self.assertTrue(self.fake.merged)

    # ELZ-056 added the Contabo VPS runner as accepted evidence. ELZ-057 (owner decision 2026-11-08):
    # queue runs are fast-tier runs, so evidence from the slower Contabo runner is refused.
    def test_contabo_runner_refused_as_queue_evidence(self):
        self.fake.job_changes["runner_name"] = "contabo-elzoo-1"
        self.refuses("Unapproved backend runner")

    def test_contabo_lookalike_runner_names_refused(self):
        for name in ("contabo-elzoo-2", "contabo-elzoo-1-extra", "Contabo-elzoo-1", "contabo-elzoo"):
            with self.subTest(name=name):
                self.setUp()
                self.fake.job_changes["runner_name"] = name
                self.refuses("Unapproved backend runner")

    # ELZ-057: tier routing of queue runs.
    def test_dispatch_requests_fast_tier(self):
        self.q.process(79)
        self.assertEqual(1, len(self.fake.dispatch_args))
        args = self.fake.dispatch_args[0]
        self.assertEqual(["-f", "tier=fast"], args[-2:])
        self.assertNotIn("tier=any", " ".join(args))

    def test_executed_check_any_job_refused(self):
        for change in ({"conclusion": "success"}, {"conclusion": "failure"}, {"conclusion": "cancelled"},
                       {"conclusion": None}):
            with self.subTest(change=change):
                self.setUp()
                self.fake.other_job_changes = change
                self.refuses("check-fast job")

    def test_old_single_check_job_name_refused(self):
        self.fake.job_changes["name"] = "check"
        self.refuses("check-fast job")

    def test_unknown_extra_job_refused(self):
        self.fake.other_job_changes = {"name": "check-extra"}
        self.refuses("check-fast job")

    def test_check_any_runner_cannot_supply_evidence(self):
        # Evidence comes only from check-fast, even if check-any ran on a fast runner.
        self.fake.job_changes["name"] = "check-any"
        self.refuses("check-fast job")

    def test_stale_main_updates_by_merge_and_checks_new_head(self):
        self.fake.stale = True
        self.q.process(79)
        self.assertEqual(self.fake.commands(["gh", "pr", "update-branch"]),
                         [["gh", "pr", "update-branch", "79", "-R", queue.REPO]])
        self.assertEqual(self.fake.commands(["gh", "pr", "merge"])[0][-1], B)
        self.assertIn(f"head={B}", self.fake.messages[-1])

    # ELZ-058 item 3: the queue cancels the duplicate pull_request run after update-branch.
    def test_update_cancels_duplicate_pr_run_of_the_exact_new_head(self):
        self.fake.stale = True
        self.q.process(79)
        self.assertEqual([700], self.fake.cancelled)
        self.assertIn(f"Cancelled duplicate pull_request run 700 head={B}", self.fake.messages)
        self.assertTrue(self.fake.merged)
        # the cancel call comes after update-branch and before the dispatch
        calls = [c for c in self.fake.calls if c[:3] in (["gh", "pr", "update-branch"], ["gh", "workflow", "run"])
                 or c[2:4] == ["-X", "POST"]]
        self.assertEqual(["update-branch", "-X", "run"], [c[2] if c[:3] != ["gh", "api", "-X"] else "-X" for c in calls][:3])

    def test_no_cancel_when_no_update_was_needed(self):
        self.q.process(79)
        self.assertEqual([], self.fake.cancelled)

    def test_cancel_only_exact_head_pull_request_runs_of_this_workflow(self):
        self.fake.stale = True
        # Every run below matches the new head B except in one respect, so each is refused for its own reason.
        others = [self.fake.pr_run(701, head_sha=A),                                  # previous head
                  self.fake.pr_run(702, head_sha=B, head_branch="task/ELZ-040"),      # another PR branch
                  self.fake.pr_run(703, head_sha=B, event="workflow_dispatch"),       # a dispatch run
                  self.fake.pr_run(704, head_sha=B, event="push"),                    # a push run
                  self.fake.pr_run(705, head_sha=B, workflow_id=20),                  # another workflow id
                  self.fake.pr_run(706, head_sha=B, path=".github/workflows/symbolic-gleam.yml"),
                  self.fake.pr_run(707, head_sha=B)]                                  # the duplicate
        self.fake.pr_runs = others
        self.q.process(79)
        self.assertEqual([707], self.fake.cancelled)

    def test_fork_run_with_the_same_branch_and_head_is_not_cancelled(self):
        self.fake.stale = True
        self.fake.pr_runs = [self.fake.pr_run(710, head_sha=B, head_repository={"full_name": "someone/elzoo"}),
                             self.fake.pr_run(711, head_sha=B, head_repository=None),
                             self.fake.pr_run(712, head_sha=B)]
        self.q = self.fake.make_queue(timeout=300)
        self.q.process(79)
        self.assertEqual([712], self.fake.cancelled)

    def test_malformed_run_data_never_blocks_the_queue(self):
        for runs in ([None], ["x"], [1], [[]], [{"id": "7", "status": "queued"}]):
            with self.subTest(runs=runs):
                self.setUp()
                self.fake.stale = True
                self.fake.pr_runs = [self.fake.pr_run(700, head_sha=B)] if runs == [{"id": "7", "status": "queued"}] else runs
                if runs == [{"id": "7", "status": "queued"}]:
                    self.fake.pr_runs[0]["id"] = "7"
                self.q = self.fake.make_queue(timeout=300)
                self.q.process(79)
                self.assertEqual([], self.fake.cancelled)
                self.assertTrue(self.fake.merged)
        for body in ("notalist", None, {"x": 1}):
            with self.subTest(body=body):
                self.setUp()
                self.fake.stale = True
                self.fake.pr_runs = body
                self.q = self.fake.make_queue(timeout=300)
                self.q.process(79)
                self.assertTrue(self.fake.merged)

    def test_a_failed_cancel_of_one_run_still_tries_the_others(self):
        self.fake.stale = True
        self.fake.pr_runs = [self.fake.pr_run(720, head_sha=B), self.fake.pr_run(721, head_sha=B)]
        self.fake.cancel_fail_ids = {720}
        self.q.process(79)
        self.assertEqual([721], self.fake.cancelled)
        self.assertTrue(any("not cancelled" in m for m in self.fake.messages))
        self.assertTrue(self.fake.merged)

    def test_completed_duplicate_is_not_cancelled(self):
        self.fake.stale = True
        self.fake.pr_runs = [self.fake.pr_run(700, head_sha=B, status="completed", conclusion="success")]
        self.q.process(79)
        self.assertEqual([], self.fake.cancelled)
        self.assertTrue(any("already completed" in m for m in self.fake.messages))
        self.assertTrue(self.fake.merged)

    def test_failed_cancel_is_logged_and_does_not_block(self):
        self.fake.stale = True
        self.fake.cancel_error = True
        self.q.process(79)
        self.assertTrue(any("not cancelled" in m and "cancel refused" in m for m in self.fake.messages))
        self.assertTrue(self.fake.merged)

    def test_failed_run_listing_is_logged_and_does_not_block(self):
        self.fake.stale = True
        self.fake.pr_run_listing_error = True
        self.q = self.fake.make_queue(timeout=300)
        self.q.process(79)
        self.assertEqual([], self.fake.cancelled)
        self.assertTrue(any("not cancelled" in m for m in self.fake.messages))
        self.assertTrue(self.fake.merged)

    def test_missing_duplicate_run_waits_a_bounded_time_then_continues(self):
        self.fake.stale = True
        self.fake.pr_runs = []
        self.q = self.fake.make_queue(timeout=300)
        self.q.process(79)
        self.assertLessEqual(self.fake.now, 120)  # waited about 30 s, not the whole PR deadline
        self.assertEqual([], self.fake.cancelled)
        self.assertTrue(any("not cancelled" in m for m in self.fake.messages))
        self.assertTrue(self.fake.merged)

    def test_cancelling_never_replaces_the_exact_head_dispatch(self):
        self.fake.stale = True
        self.q.process(79)
        self.assertEqual(1, self.fake.dispatches)  # the queue still dispatches and checks its own run
        self.assertEqual(f"ELZOO MERGE EVIDENCE pr=79 run=101 job=201 runner=symbolic-elzoo head={B} merge={M}",
                         self.fake.messages[-1])

    def test_main_moves_during_check_requires_new_full_run(self):
        self.fake.move_main = True
        self.q.process(79)
        self.assertEqual(self.fake.dispatches, 2)
        self.assertEqual(len(self.fake.commands(["gh", "pr", "update-branch"])), 1)
        self.assertIn(f"run=102 job=202 runner=symbolic-elzoo head={B}", self.fake.messages[-1])

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
        for change in ({"runner_name": "GitHub Actions 1"}, {"runner_name": ""},
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
        self.assertIn(f"ELZOO GLEAM EVIDENCE pr=79 run=501 job=601 runner=symbolic-elzoo-gleam head={B}", self.fake.messages)

    def test_wrong_gleam_workflow_event_branch_or_job_refused(self):
        for field, value in (("workflow_id", 10), ("event", "workflow_dispatch"),
                             ("head_branch", "other"), ("path", ".github/workflows/other.yml")):
            with self.subTest(field=field):
                self.setUp()
                self.fake.gleam_changes[field] = value
                self.refuses()
        for change in ({"runner_name": "symbolic-elzoo"}, {"head_sha": B},
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
