#!/usr/bin/env python3
"""Serial coordinator queue: full, exact-head CI before a merge (own gh login).

Run from this repository. This is not branch protection or an independent review.
No branch deletion, issue closure, or acceptance posting is performed.

ELZ-059: the full pull_request run of the exact head is the merge evidence; the queue adopts it (it never
cancels it) and dispatches a run only when GitHub started none within a bounded wait. The queue refuses to
merge while the latest completed push run of main is red and not classified on issue #98, and it requires the
Gleam pull_request run only when the pull request changes a Gleam path.

ELZ-071: a documentation-only pull request is accepted on the short `Docs-only check` of its run (marker
ELZOO DOCS-ONLY CHECK PASSED instead of ELZOO CHECK PASSED) only when this queue's own copy of
scripts/ci-change-class.py, next to this file and never the pull request's, classifies the change
(`git diff main...head` on the fetched refs) as documentation only. Otherwise the queue dispatches a full run.

Small gate: a Piece-only pull request is accepted on the small gate of its pull_request run (job check-piece,
`mix check --piece`, marker ELZOO PIECE CHECK PASSED ...) only when the queue's own copy of scripts/ci-change-class.py
classifies the change as Piece-only, the run is on the exact head and on a hosted runner, and the run has the piece
marker and no other marker. Otherwise the queue dispatches a full run. The small gate is a selected check: the full
check of the merged content is the push run on main after the merge. The queue requires that main is not frozen, but
it does not wait for the push run of the current main (see `piece_only_change`).
"""
import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlencode

REPO = "balungpisah/elzoo"
WORKFLOW = "symbolic-check.yml"
PR_RUN_WAIT = 300  # seconds to wait for GitHub to start the pull_request run of the exact head
MAIN_RUN_WAIT = 600  # seconds to wait for the push run of the current main before a docs-only merge
FREEZE_ISSUE = 98  # classifications of a red run of main are comments on this issue
CLASSIFICATION = re.compile(r"CI main status: freeze classification run=([0-9]+) class=(infrastructure|defect|conflict)")
# ELZ-059: the Gleam gate applies only to a pull request that changes one of these paths. The guard cannot be
# split by content, so the whole of both guard files counts.
GLEAM_PREFIX = "spikes/gleam_ui/"
GLEAM_PATHS = {".github/workflows/symbolic-gleam.yml", "scripts/check-ci-runners.py", "scripts/test-ci-runners.py"}
GLEAM_WORKFLOW = "symbolic-gleam.yml"
# ELZ-069: one lane, GitHub-hosted. The only backend job is check-hosted, the only Gleam job is gleam-hosted.
HOSTED_JOB = "check-hosted"
GLEAM_HOSTED_JOB = "gleam-hosted"
# ELZ-073: one run of the backend workflow has five jobs, and the run is one evidence unit. `check-plan` runs the
# guards, the classification and the push-skip decision; the three work jobs run the three parts of `mix check`
# when the plan says so; `check-hosted` aggregates them (the name that branch protection requires). The small gate
# adds a sixth job, check-piece (below).
PLAN_JOB = "check-plan"
WORK_PARTS = (("check-root", "root", "ELZOO ROOT SUITE PASSED"),
              ("check-consumers-db", "consumers-db", "ELZOO CONSUMERS DB PASSED"),
              ("check-consumers", "consumers", "ELZOO CONSUMERS PASSED"))
SPLIT_WORK_PARTS = (("check-root", "root-a", "ELZOO ROOT A SUITE PASSED"),
                    ("check-root-b", "root-b", "ELZOO ROOT B SUITE PASSED"),
                    ("check-aggregate", "aggregate", "ELZOO AGGREGATE CONSUMER PASSED"),
                    ("check-consumers-db", "consumers-db", "ELZOO CONSUMERS DB PASSED"),
                    ("check-consumers", "consumers", "ELZOO CONSUMERS PASSED"))
EVIDENCE_JOBS = (PLAN_JOB,) + tuple(job for job, _part, _marker in WORK_PARTS) + (HOSTED_JOB,)
# Small gate: the sixth job of the unit. It runs only in the piece shape and is skipped in the full and docs-only shapes.
PIECE_JOB = "check-piece"
PIECE_STEP = "Run the small gate"
BACKEND_JOBS = EVIDENCE_JOBS + (PIECE_JOB,)
SPLIT_EVIDENCE_JOBS = (PLAN_JOB,) + tuple(job for job, _part, _marker in SPLIT_WORK_PARTS) + (HOSTED_JOB,)
SPLIT_BACKEND_JOBS = SPLIT_EVIDENCE_JOBS + (PIECE_JOB,)
PART_MARKERS = {marker for _job, _part, marker in WORK_PARTS + SPLIT_WORK_PARTS}
FULL_MARKER = "ELZOO CHECK PASSED"
DOCS_MARKER = "ELZOO DOCS-ONLY CHECK PASSED"
# Elzoo.CheckSelection.success_marker(%{mode: :piece}); scripts/test-merge-queue.py compares the two.
PIECE_MARKER = "ELZOO PIECE CHECK PASSED (small gate; a selected check, not the full check; see LIMIT)"
AFFECTED_MARKER = "ELZOO AFFECTED CHECK PASSED"
LOG_STAMP = r"(?m)^(?:\d{4}-\d\d-\d\dT[0-9:.]+Z )?"
HOSTED_GROUP = "GitHub Actions"
HOSTED_LABELS = ["ubuntu-24.04"]
HOSTED_RUNNER = re.compile(r"GitHub Actions [0-9]+")
HOSTED_GATE_STEP = "Verify the GitHub-hosted runner"
SHA = re.compile(r"[0-9a-f]{40}")
BASE_CHANGES = ("base_ref_changed", "automatic_base_change_succeeded", "automatic_base_change_failed")
PR_FIELDS = ("number,state,isDraft,isCrossRepository,baseRefName,headRefName,"
             "headRefOid,headRepository,mergeable,mergeCommit")


class QueueError(Exception):
    """A refusal or unavailable evidence; never a reason to merge anyway."""


def load_classifier():
    """This queue's own copy of the documentation-only allowlist: the file next to this script, never the file of
    the pull request (the queue does not read any file from the pull request head). A missing or broken file
    means that no change is documentation only, so every pull request needs the full run."""
    try:
        path = Path(__file__).resolve().with_name("ci-change-class.py")
        spec = importlib.util.spec_from_file_location("ci_change_class", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:  # noqa: BLE001 - any failure to load the classifier means "full run"
        return None


CLASSIFIER = load_classifier()


def hosted_runner(job):
    """True for a job that a GitHub-hosted runner of the one approved label ran."""
    name = job.get("runner_name")
    return (job.get("runner_group_name") == HOSTED_GROUP and job.get("labels") == HOSTED_LABELS and
            isinstance(name, str) and HOSTED_RUNNER.fullmatch(name) is not None)


def one_executed_job(jobs, known, executable, message):
    """The one job of a run that did not skip. Every job must be known, once, and the executed one allowed."""
    names = [job.get("name") for job in jobs]
    require(len(set(names)) == len(names) and all(name in known for name in names), message)
    executed = [job for job in jobs if job.get("conclusion") != "skipped"]
    require(len(executed) == 1 and executed[0].get("name") in executable, message)
    return executed[0]


def command(argv, allowed=(0,)):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise QueueError(f"{argv[0]} failed: {error}") from error
    if result.returncode not in allowed:
        raise QueueError(f"{' '.join(argv)} exited {result.returncode}: "
                         f"{result.stderr.strip() or result.stdout.strip()}")
    return result


# ELZ-058 item 4: read-only gh and git calls are retried on transport errors and gateway errors, with a
# bounded backoff, before the queue stops. Writes (dispatch, update-branch, merge) are never retried
# here: a repeated dispatch would create a second run.
TRANSIENT = re.compile(
    r"TLS handshake timeout|connection reset|connection refused|i/o timeout|timeout awaiting|"
    r"Client\.Timeout|context deadline exceeded|timed out after \d+ seconds|operation timed out|unexpected EOF|\bEOF\b|server closed|temporary failure|"
    r"HTTP 50[0234]\b|\b50[0234] (?:Bad Gateway|Service Unavailable|Gateway Time-?out|Internal Server Error)",
    re.IGNORECASE)
RETRY_WAITS = (10, 20, 40, 50)  # five attempts over two minutes of waiting


# `gh api` switches to POST by itself when a field or an input file is given, so every spelling of a method, a
# field or an input counts as a write, including the attached forms (-XPOST, --method=POST, -fname=value).
WRITE_FLAG = re.compile(r"^(?:-X|--method|-f|-F|--field|--raw-field|--input)")


def is_read_only(argv):
    if argv[:2] == ["gh", "api"]:
        return not any(WRITE_FLAG.match(arg) for arg in argv[2:])
    return argv[:3] == ["gh", "pr", "view"] or argv[:2] == ["git", "fetch"]


def error_detail(error):
    """The tool's own message: what follows `exited N:` in a command failure, so that the arguments of the
    command are never matched against the transient patterns."""
    text = str(error)
    return text.split(" exited ", 1)[1] if " exited " in text else text


def retrying(run, sleep, emit, clock=None, deadline=None):
    """Wrap a command runner so that read-only calls survive a short network or gateway failure.
    The wait never runs past the PR deadline: past it, the original error is raised."""
    def wrapped(argv, allowed=(0,)):
        for attempt in range(len(RETRY_WAITS) + 1):
            try:
                return run(argv, allowed)
            except QueueError as error:
                if (attempt == len(RETRY_WAITS) or not is_read_only(argv)
                        or not TRANSIENT.search(error_detail(error))):
                    raise
                wait = RETRY_WAITS[attempt]
                if clock and deadline and clock() + wait >= deadline():
                    raise
                emit(f"Transient failure of {' '.join(argv[:3])} (attempt {attempt + 1} of "
                     f"{len(RETRY_WAITS) + 1}): {str(error)[:200]}; retrying in {wait} s", flush=True)
                sleep(wait)
    return wrapped


def require(condition, reason):
    if not condition:
        raise QueueError(reason)


def parse_time(value, what):
    """A GitHub UTC timestamp as a datetime; anything else refuses."""
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError) as error:
        raise QueueError(f"Invalid {what}: {value!r}") from error


def valid_sha(value):
    return isinstance(value, str) and SHA.fullmatch(value) is not None


class Queue:
    def __init__(self, run=command, sleep=time.sleep, clock=time.monotonic,
                 timeout=10800, poll=15, emit=print, pr_run_wait=PR_RUN_WAIT, main_run_wait=MAIN_RUN_WAIT):
        self.pr_run_wait = pr_run_wait
        self.main_run_wait = main_run_wait
        self.sleep, self.clock = sleep, clock
        self.timeout, self.poll, self.emit = timeout, poll, emit
        self.raw_run = run
        self.run = retrying(run, sleep, emit, clock, lambda: self.deadline)
        self.deadline = 0

    def text(self, *argv):
        return self.run(list(argv)).stdout.strip()

    def data(self, *argv):
        try:
            return json.loads(self.text(*argv))
        except (ValueError, TypeError) as error:
            raise QueueError(f"Invalid JSON from {' '.join(argv)}") from error

    def api(self, path):
        return self.data("gh", "api", f"repos/{REPO}/{path}")

    def pause(self, reason, deadline=None):
        remaining = min(self.deadline, deadline or self.deadline) - self.clock()
        require(remaining > 0, f"Timed out: {reason}")
        self.emit(f"Waiting: {reason}", flush=True)
        self.sleep(min(self.poll, remaining))

    def pr(self, number, ready=True):
        end = self.clock() + 60
        while True:
            pr = self.data("gh", "pr", "view", str(number), "-R", REPO,
                           "--json", PR_FIELDS)
            require(pr.get("number") == number, "PR identity mismatch")
            require(pr.get("state") == "OPEN", "PR is not open")
            require(pr.get("isDraft") is False, "Draft PR refused")
            require(pr.get("isCrossRepository") is False and
                    (pr.get("headRepository") or {}).get("nameWithOwner") == REPO,
                    "Fork or unknown head repository refused")
            require(pr.get("baseRefName") == "main", "PR must target main")
            require(re.fullmatch(r"task/ELZ-[0-9]{3}", pr.get("headRefName", "")),
                    "PR must use exact task/ELZ-### branch")
            require(valid_sha(pr.get("headRefOid")), "Missing or invalid PR head SHA")
            if not ready or pr.get("mergeable") == "MERGEABLE":
                return pr
            require(pr.get("mergeable") == "UNKNOWN", "PR is not mergeable")
            self.pause("GitHub calculating mergeability", end)

    def fetch(self, pr):
        # Fetch only the two relevant refs, without touching the working tree.
        branch = pr["headRefName"]
        self.text("git", "fetch", "origin",
                  "refs/heads/main:refs/remotes/origin/main",
                  f"refs/heads/{branch}:refs/remotes/origin/{branch}")
        # origin may be misconfigured: only the canonical repository owns the base.
        main = self.api("git/ref/heads/main")["object"]["sha"]
        head = self.text("git", "rev-parse", f"refs/remotes/origin/{branch}")
        require(valid_sha(main) and head == pr["headRefOid"],
                "Fetched refs disagree with PR metadata; retry queue after inspecting head")
        result = self.run(["git", "merge-base", "--is-ancestor", main, head], allowed=(0, 1))
        return result.returncode == 0

    def runs(self, branch):
        query = urlencode({"event": "workflow_dispatch", "branch": branch, "per_page": 100})
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?{query}")
        require(isinstance(pages, list), "Invalid run pages")
        return [run for page in pages for run in page["workflow_runs"]]

    def run_matches(self, run, pr, workflow_id):
        """The evidence run is the same-repository pull_request run of the exact head, or the dispatch run
        that the queue starts as a fallback."""
        return self.matches(run, pr, workflow_id) or self.pr_run_matches(run, pr, workflow_id)

    @staticmethod
    def matches(run, pr, workflow_id):
        return (run.get("event") == "workflow_dispatch" and
                run.get("head_branch") == pr["headRefName"] and
                run.get("head_sha") == pr["headRefOid"] and
                run.get("workflow_id") == workflow_id and
                run.get("path") == f".github/workflows/{WORKFLOW}")

    @staticmethod
    def pr_run_matches(run, pr, workflow_id):
        return (run.get("event") == "pull_request" and
                run.get("head_branch") == pr["headRefName"] and
                run.get("head_sha") == pr["headRefOid"] and
                run.get("workflow_id") == workflow_id and
                run.get("path") == f".github/workflows/{WORKFLOW}" and
                isinstance(run.get("head_repository"), dict) and
                run["head_repository"].get("full_name") == REPO and
                Queue.names_pr_on_main(run, pr))

    @staticmethod
    def names_pr_on_main(run, pr):
        """The run belongs to this pull request and GitHub tested it against main (not another base)."""
        listed = run.get("pull_requests")
        return isinstance(listed, list) and any(
            isinstance(item, dict) and item.get("number") == pr["number"] and
            isinstance(item.get("base"), dict) and item["base"].get("ref") == "main" and
            isinstance(item["base"].get("repo"), dict) and
            item["base"]["repo"].get("url") == f"https://api.github.com/repos/{REPO}"
            for item in listed)

    def sole_pull_request_of_head(self, pr):
        """True when this pull request is the only pull request (open, closed or merged) from the head branch.
        GitHub lists on a run the pull requests that are open for its head now, not the one that triggered it,
        so a run of a sibling pull request with another base could be taken for this one."""
        query = urlencode({"head": f"{REPO.split('/')[0]}:{pr['headRefName']}", "state": "all", "per_page": 100})
        pages = self.data("gh", "api", "--paginate", "--slurp", f"repos/{REPO}/pulls?{query}")
        require(isinstance(pages, list) and all(isinstance(page, list) for page in pages),
                "Invalid pull request pages")
        items = [item for page in pages for item in page]
        return bool(items) and all(isinstance(item, dict) and item.get("number") == pr["number"] for item in items)

    def ever_retargeted(self, pr):
        """True when the base of the pull request ever changed, by hand or automatically. A run can have tested
        the old base, and the time of the event does not tell which one. Any odd entry counts as changed."""
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/issues/{pr['number']}/timeline?per_page=100")
        require(isinstance(pages, list) and all(isinstance(page, list) for page in pages),
                "Invalid timeline pages")
        for event in [e for page in pages for e in page]:
            if not isinstance(event, dict) or event.get("event") in BASE_CHANGES:
                return True
        return False

    def newer_run_of_head(self, run_id, pr):
        """ID of a same-repository pull_request run of the backend workflow on the exact head that is newer than
        the evidence run, or None. The push-run skip decision lets the run with the highest ID on the second parent
        decide, and a pull_request run tests the merge with its base, so a later run of a sibling pull request would
        decide in place of the run that the queue checked. A newer workflow_dispatch run is not counted: it tests
        the head itself, and the skip decision accepts it only as a completed success with the full marker, else
        the full check runs."""
        query = urlencode({"head_sha": pr["headRefOid"], "per_page": 100})
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?{query}")
        require(isinstance(pages, list) and all(isinstance(page, dict) for page in pages) and
                all(isinstance(page.get("workflow_runs"), list) for page in pages), "Invalid run pages")
        newest = None
        for run in [run for page in pages for run in page["workflow_runs"]]:
            if not isinstance(run, dict) or run.get("head_sha") != pr["headRefOid"] or \
                    run.get("path") != f".github/workflows/{WORKFLOW}":
                continue
            source = run.get("head_repository")
            valid = (run.get("event") == "pull_request" and isinstance(source, dict) and
                     source.get("full_name") == REPO)
            if not valid:
                continue
            require(isinstance(run.get("id"), int), "Invalid run ID")
            if run["id"] > run_id:
                newest = max(newest or 0, run["id"])
        return newest

    def adopt_pr_run(self, pr, workflow_id):
        """ELZ-059: the latest same-repository pull_request run of the exact head, waited for up to
        PR_RUN_WAIT seconds (after update-branch GitHub starts it a few seconds later). Returns its ID, or None
        when GitHub started none. The queue never cancels this run."""
        query = urlencode({"event": "pull_request", "branch": pr["headRefName"],
                           "head_sha": pr["headRefOid"], "per_page": 100})
        end = self.clock() + self.pr_run_wait
        while True:
            pages = self.data("gh", "api", "--paginate", "--slurp",
                              f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?{query}")
            require(isinstance(pages, list), "Invalid run pages")
            runs = [run for page in pages for run in page["workflow_runs"]
                    if isinstance(run, dict) and self.pr_run_matches(run, pr, workflow_id)]
            if runs:
                require(all(isinstance(run.get("id"), int) for run in runs), "Invalid run ID")
                # The latest run decides: an older success must not hide a newer failure.
                latest = max(runs, key=lambda run: run["id"])
                if not self.sole_pull_request_of_head(pr):
                    self.emit(f"Another pull request exists for branch {pr['headRefName']}; run {latest['id']} "
                              "may belong to it and is not evidence", flush=True)
                    return None
                if self.ever_retargeted(pr):
                    self.emit(f"The base of PR #{pr['number']} changed once; run {latest['id']} may have tested "
                              "the old base and is not evidence", flush=True)
                    return None
                return latest["id"]
            if end - self.clock() <= 0:
                return None
            self.pause("pull_request run on the exact head", end)

    def dispatch(self, pr, workflow_id):
        # Said on every fallback: branch protection requires check-hosted and gleam-hosted as pull request statuses.
        self.emit(f"Fallback for PR #{pr['number']}: a workflow_dispatch run is valid evidence for this queue but does "
                  "NOT satisfy branch protection (check-hosted and gleam-hosted are required on the pull request), so "
                  "GitHub may refuse the merge; a green pull_request run of the same head is needed for that", flush=True)
        previous = {run["id"] for run in self.runs(pr["headRefName"])}
        self.text("gh", "workflow", "run", WORKFLOW, "-R", REPO,
                  "--ref", pr["headRefName"])
        end = self.clock() + 300
        while True:
            candidates = [run for run in self.runs(pr["headRefName"])
                          if run["id"] not in previous and self.matches(run, pr, workflow_id)]
            require(len(candidates) <= 1, "Ambiguous new dispatch runs; refusing to choose latest")
            if candidates:
                run = candidates[0]
                require(isinstance(run.get("id"), int), "Invalid run ID")
                self.emit(f"Dispatched PR #{pr['number']} head={pr['headRefOid']} run={run['id']}", flush=True)
                return run["id"]
            self.pause("new exact-head workflow_dispatch run", end)

    def evidence(self, run_id, pr, workflow_id, allow_docs_only=True, allow_piece=True):
        """The successful run of the exact head, read as one evidence unit (ELZ-073). Returns (jobs, mode), where
        jobs maps the complete legacy six-job or fixed split eight-job unit to API objects. Mode "full": all work
        jobs ran in this attempt and succeeded, check-piece was skipped, each work job printed its part marker and
        the aggregating job printed the full marker. Mode "docs-only": the plan job passed the short check (marker
        line), all work jobs and check-piece were skipped and the aggregating job succeeded. Mode "piece" (small gate):
        a pull_request run in which check-piece ran and printed the piece marker, all work jobs were skipped and no other marker
        is present. The caller accepts docs-only and piece only after the queue's own classification. Anything else (a
        missing, extra, duplicated, red, cancelled or mixed set, a job that ran in an earlier attempt) is no evidence."""
        while True:
            run = self.api(f"actions/runs/{run_id}")
            require(run.get("id") == run_id and self.run_matches(run, pr, workflow_id),
                    "Run event/branch/workflow/head SHA mismatch")
            if run.get("status") == "completed":
                break
            self.pause(f"run {run_id} status={run.get('status')}")
        require(run.get("conclusion") == "success", f"Run {run_id}: {run.get('conclusion')}")
        attempt = run.get("run_attempt")
        require(isinstance(attempt, int) and attempt > 0, "Missing run attempt")
        began = parse_time(run.get("run_started_at"), "run start")
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        jobs = [job for page in pages for job in page["jobs"]]
        names = [job.get("name") for job in jobs]
        split = sorted(names) == sorted(SPLIT_BACKEND_JOBS)
        require(split or sorted(names) == sorted(BACKEND_JOBS),
                "Expected exactly the five backend jobs and check-piece, or the fixed split eight-job unit, once each")
        work_parts = SPLIT_WORK_PARTS if split else WORK_PARTS
        by_name = {job["name"]: job for job in jobs}
        for job in jobs:
            if job.get("conclusion") != "skipped":
                self.check_backend_job(job, run_id, pr, began)
        plan, aggregate = by_name[PLAN_JOB], by_name[HOSTED_JOB]
        require(plan.get("conclusion") != "skipped" and aggregate.get("conclusion") != "skipped",
                "The plan job and the aggregating job must have run")
        work = [by_name[job] for job, _part, _marker in work_parts]
        ran = [job for job in work if job.get("conclusion") != "skipped"]
        piece_ran = by_name[PIECE_JOB].get("conclusion") != "skipped"
        if len(ran) == len(work):
            require(not piece_ran, "check-piece ran in a full run: not one shape")
            mode = "full"
        elif piece_ran:
            require(not ran and allow_piece, "Small gate run refused here, or work jobs ran beside it: not a full run")
            require(run.get("event") == "pull_request", "A small gate run is evidence only on a pull_request run")
            mode = "piece"
        else:
            require(not ran and allow_docs_only, "Full check jobs missing or skipped: not a full run")
            mode = "docs-only"
        logs = {}

        def log(job):
            if job["name"] not in logs:
                logs[job["name"]] = self.text("gh", "api", "--allow-escape-sequences",
                                              f"repos/{REPO}/actions/jobs/{job['id']}/logs")
            return logs[job["name"]]

        def step(job, name):
            return [item for item in job.get("steps", []) if item.get("name") == name]

        def has_line(job, text):
            return re.search(LOG_STAMP + text + r"\s*$", log(job)) is not None

        classify, docs_step = step(plan, "Classify the change"), step(plan, "Docs-only check")
        require(len(classify) == 1 and classify[0].get("conclusion") == "success",
                "Classification step missing, skipped or failed")
        require(len(step(aggregate, "Require every job")) == 1 and
                step(aggregate, "Require every job")[0].get("conclusion") == "success",
                "Aggregating step missing, skipped or failed")
        if mode == "full":
            require(len(docs_step) == 1 and docs_step[0].get("conclusion") == "skipped",
                    "Docs-only step ran or is missing in a full run")
            require(has_line(plan, r"ELZOO PLAN: run=true skip=\S+ docs_only=\S+") and
                    "ELZOO AFFECTED CHECK PASSED" not in log(plan),
                    "Plan did not say run=true, or an affected-mode marker is present in its log")
            for job in work:
                mix = step(job, "Run mix check")
                require(len(mix) == 1 and mix[0].get("conclusion") == "success",
                        f"Full check step missing, skipped or failed ({job['name']})")
            for job, _part, marker in work_parts:
                require(has_line(by_name[job], re.escape(marker)) and
                        "ELZOO AFFECTED CHECK PASSED" not in log(by_name[job]),
                        f"Missing part marker or affected-mode marker present ({job})")
                require(not any(has_line(by_name[job], re.escape(other)) for other in PART_MARKERS - {marker}),
                        f"Unexpected part marker ({job})")
            require(has_line(aggregate, re.escape(FULL_MARKER)), "Missing full success marker of the aggregating job")
            require(not any(has_line(job, re.escape(FULL_MARKER)) for job in [plan] + work),
                    "Full success marker outside check-hosted")
            require(not has_line(plan, re.escape(DOCS_MARKER)), "Docs-only marker present in a full run")
            require(all("ELZOO PIECE CHECK PASSED" not in log(job) for job in [plan, aggregate] + work),
                    "Small gate marker present in a full run")
        elif mode == "piece":
            piece = by_name[PIECE_JOB]
            small = step(piece, PIECE_STEP)
            require(len(small) == 1 and small[0].get("conclusion") == "success",
                    "Small gate step missing, skipped or failed (check-piece)")
            piece_class = step(plan, "Classify a Piece change")
            require(len(piece_class) == 1 and piece_class[0].get("conclusion") == "success",
                    "Piece classification step missing, skipped or failed")
            require(len(docs_step) == 1 and docs_step[0].get("conclusion") == "skipped",
                    "Docs-only step ran or is missing in a small gate run")
            require(has_line(plan, r"ELZOO PLAN: run=false skip=\S+ docs_only=false") and
                    has_line(plan, r"ELZOO PIECE PLAN: piece=true piece_only=true"),
                    "Missing small gate plan lines")
            require(has_line(piece, re.escape(PIECE_MARKER)), "Missing small gate marker (check-piece)")
            # No other marker: not the full, part, docs-only or affected marker in any executed job.
            for job in (plan, piece, aggregate):
                require(not has_line(job, re.escape(FULL_MARKER)) and not has_line(job, re.escape(DOCS_MARKER)) and
                        not any(has_line(job, re.escape(marker)) for marker in PART_MARKERS) and
                        AFFECTED_MARKER not in log(job),
                        f"A full, part, docs-only or affected-mode marker is present in a small gate run ({job['name']})")
            require(not has_line(plan, "ELZOO PIECE CHECK PASSED.*") and not has_line(aggregate, "ELZOO PIECE CHECK PASSED.*"),
                    "Small gate marker printed outside check-piece")
        else:
            require(len(docs_step) == 1 and docs_step[0].get("conclusion") == "success",
                    "Docs-only check step missing, skipped or failed")
            require(has_line(plan, re.escape(DOCS_MARKER)) and has_line(plan, r"ELZOO PLAN: run=false skip=\S+ docs_only=true"),
                    "Missing docs-only success marker or plan line")
            require(not has_line(aggregate, re.escape(FULL_MARKER)) and not has_line(plan, re.escape(FULL_MARKER)) and
                    "ELZOO AFFECTED CHECK PASSED" not in log(plan),
                    "A full-run or affected-mode marker is present in a docs-only run")
            require("ELZOO PIECE CHECK PASSED" not in log(plan) and not has_line(aggregate, "ELZOO PIECE CHECK PASSED.*"),
                    "Small gate marker present in a docs-only run")
            require(not any(has_line(job, re.escape(marker)) for job in [plan, aggregate] for marker in PART_MARKERS),
                    "Part marker present in a docs-only run")
        latest = self.api(f"actions/runs/{run_id}")
        require(self.run_matches(latest, pr, workflow_id) and latest.get("status") == "completed" and
                latest.get("conclusion") == "success" and latest.get("run_attempt") == attempt,
                "Run changed while collecting evidence")
        return by_name, mode

    def check_backend_job(self, job, run_id, pr, began):
        """One job of the evidence unit: successful on the exact head and run, on an approved hosted runner, with a
        successful identity step, and executed in this attempt (a partial re-run copies the green jobs of the earlier
        attempt into the new one with new IDs but their old start times: that is no evidence)."""
        name = job.get("name")
        require(isinstance(job.get("id"), int), f"Invalid job ID ({name})")
        require(job.get("run_id") == run_id and job.get("head_sha") == pr["headRefOid"] and
                job.get("status") == "completed" and job.get("conclusion") == "success",
                f"Backend job is not successful on the exact head/run ({name})")
        require(hosted_runner(job), f"Unapproved hosted runner ({name})")
        gate = [step for step in job.get("steps", []) if step.get("name") == HOSTED_GATE_STEP]
        require(len(gate) == 1 and gate[0].get("conclusion") == "success",
                f"Hosted runner identity step missing, skipped or failed ({name})")
        require(parse_time(job.get("started_at"), f"job start ({name})") >= began,
                f"Job {name} did not run in this attempt (a partial re-run is no evidence; re-run all jobs)")

    def latest_push_run(self, sha):
        """The push run of the backend workflow with the highest ID on this commit of main, or None."""
        query = urlencode({"event": "push", "head_sha": sha, "per_page": 100})
        listing = self.data("gh", "api", f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?{query}")
        runs = listing.get("workflow_runs") if isinstance(listing, dict) else None
        require(isinstance(runs, list), "Invalid push run listing of main")
        mine = [run for run in runs if isinstance(run, dict) and run.get("event") == "push"
                and run.get("head_branch") == "main" and run.get("head_sha") == sha
                and run.get("path") == f".github/workflows/{WORKFLOW}"]
        require(all(isinstance(run.get("id"), int) for run in mine), "Invalid push run ID")
        return max(mine, key=lambda run: run["id"]) if mine else None

    def main_verified(self, main):
        """True when the newest push run on this commit of main completed with success (a logged skip is a success
        of the job). A short check runs no tests, so it adds no test of main's code: the change must start from a
        main that was itself checked, or a red or unfinished push run of main would be hidden behind a green
        documentation merge. A run in progress, or not listed yet, is awaited for MAIN_RUN_WAIT seconds."""
        end = self.clock() + self.main_run_wait
        while True:
            latest = self.latest_push_run(main)
            if latest is not None and latest.get("status") == "completed":
                return latest.get("conclusion") == "success"
            if end - self.clock() <= 0:
                return False
            self.pause(f"push run of main {main[:7]} to finish", end)

    def docs_only_change(self, pr):
        """True only when the queue may accept the short check for this head: this queue's own classifier says that
        the change of the head since main is documentation only (`git diff main...head` on the fetched refs, with
        the main SHA of the canonical repository), and the push run of that main completed with success. Any
        failure, a missing classifier or an odd answer is False."""
        if CLASSIFIER is None:
            return False
        try:
            main = self.api("git/ref/heads/main")["object"]["sha"]
            require(valid_sha(main), "Invalid canonical main SHA")
            out = self.run(CLASSIFIER.diff_argv(main, f"refs/remotes/origin/{pr['headRefName']}")).stdout
            return CLASSIFIER.docs_only(CLASSIFIER.parse_raw(out)) is True and self.main_verified(main)
        except (QueueError, CLASSIFIER.Unclear, KeyError, TypeError, ValueError, AttributeError):
            return False

    def piece_only_change(self, pr):
        """True only when the queue may accept the small gate for this head: this queue's own classifier says that the
        change of the head since main is Piece-only (`git diff main...head` on the fetched refs, with the main SHA of
        the canonical repository) and names at least one Piece. Any failure, a missing classifier or an odd answer is
        False.

        Unlike `docs_only_change`, this does not wait for the push run of the current main. The caller separately
        checks the freeze rule and the bounded first-parent window before accepting Piece evidence and merging."""
        if CLASSIFIER is None:
            return False
        try:
            main = self.api("git/ref/heads/main")["object"]["sha"]
            require(valid_sha(main), "Invalid canonical main SHA")
            out = self.run(CLASSIFIER.diff_argv(main, f"refs/remotes/origin/{pr['headRefName']}")).stdout
            verdict, ids = CLASSIFIER.piece_only(CLASSIFIER.parse_raw(out))
            return verdict is True and isinstance(ids, list) and len(ids) > 0
        except (QueueError, CLASSIFIER.Unclear, KeyError, TypeError, ValueError, AttributeError):
            return False

    def check_piece_window(self):
        """ELZ-120: at most two first-parent commits may be outstanding before the next small-gate merge."""
        main = self.api("git/ref/heads/main")["object"]["sha"]
        require(valid_sha(main), "Invalid canonical main SHA")
        chain = self.text("git", "rev-list", "--first-parent", main).splitlines()
        require(chain and chain[0] == main and all(valid_sha(sha) for sha in chain),
                "Unreadable first-parent chain; refusing small gate")
        for count, sha in enumerate(chain):
            run = self.latest_push_run(sha)
            if run is None or run.get("status") != "completed" or run.get("conclusion") != "success":
                continue
            require(count < 3, f"Small gate window exhausted: covering SHA={sha} count={count}; "
                              "wait for a newer successful main push")
            return
        raise QueueError("No successful covering main push on the first-parent chain; refusing small gate")

    def gleam_evidence(self, pr):
        workflow_id = self.api(f"actions/workflows/{GLEAM_WORKFLOW}")["id"]
        query = urlencode({"event": "pull_request", "branch": pr["headRefName"],
                           "head_sha": pr["headRefOid"], "per_page": 100})

        def matches(run):
            return (run.get("event") == "pull_request" and
                    run.get("head_branch") == pr["headRefName"] and
                    run.get("head_sha") == pr["headRefOid"] and
                    run.get("workflow_id") == workflow_id and
                    run.get("path") == f".github/workflows/{GLEAM_WORKFLOW}")

        end = self.clock() + 300
        while True:
            pages = self.data("gh", "api", "--paginate", "--slurp",
                              f"repos/{REPO}/actions/workflows/{GLEAM_WORKFLOW}/runs?{query}")
            candidates = [run for page in pages for run in page["workflow_runs"] if matches(run)]
            if candidates:
                require(all(isinstance(run.get("id"), int) for run in candidates), "Invalid Gleam run ID")
                # Do not hide a newer failed/cancelled check behind an older success.
                run_id = max(run["id"] for run in candidates)
                break
            self.pause("Gleam pull_request run on exact head", end)
        while True:
            run = self.api(f"actions/runs/{run_id}")
            require(run.get("id") == run_id and matches(run), "Gleam run identity mismatch")
            if run.get("status") == "completed":
                break
            self.pause(f"Gleam run {run_id} status={run.get('status')}")
        require(run.get("conclusion") == "success", f"Gleam run {run_id}: {run.get('conclusion')}")
        attempt = run.get("run_attempt")
        require(isinstance(attempt, int) and attempt > 0, "Missing Gleam run attempt")
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        jobs = [job for page in pages for job in page["jobs"]]
        job = one_executed_job(jobs, {GLEAM_HOSTED_JOB}, {GLEAM_HOSTED_JOB}, "Expected exactly one executed Gleam job")
        require(job.get("run_id") == run_id and job.get("head_sha") == pr["headRefOid"] and
                job.get("status") == "completed" and job.get("conclusion") == "success", "Gleam job evidence mismatch")
        require(hosted_runner(job), "Gleam job evidence mismatch: unapproved hosted runner")
        gate = [step for step in job.get("steps", []) if step.get("name") == HOSTED_GATE_STEP]
        require(len(gate) == 1 and gate[0].get("conclusion") == "success",
                "Gleam hosted runner identity step missing, skipped or failed")
        steps = [step for step in job.get("steps", []) if step.get("name") == "Run ./scripts/check.sh"]
        require(len(steps) == 1 and steps[0].get("conclusion") == "success", "Gleam check step did not pass")
        require(isinstance(job.get("id"), int), "Invalid Gleam job ID")
        latest = self.api(f"actions/runs/{run_id}")
        require(latest.get("id") == run_id and matches(latest) and
                latest.get("status") == "completed" and latest.get("conclusion") == "success" and
                latest.get("run_attempt") == attempt, "Gleam run changed while collecting evidence")
        return job

    def check_main_not_frozen(self):
        """ELZ-059 freeze rule. The latest completed push run of the backend workflow on main decides: a
        success (including a logged skip) leaves main open; any other conclusion (failure, timed_out,
        cancelled, ...) freezes the queue until a comment on issue #98 by this login classifies that run. A
        later green push run of main unfreezes it. Any API failure fails closed."""
        query = urlencode({"event": "push", "branch": "main", "per_page": 30})
        listing = self.data("gh", "api", f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?{query}")
        runs = listing.get("workflow_runs") if isinstance(listing, dict) else None
        require(isinstance(runs, list), "Invalid push run listing of main; refusing")
        done = [run for run in runs if isinstance(run, dict) and run.get("event") == "push"
                and run.get("head_branch") == "main" and run.get("status") == "completed"
                and run.get("path") == f".github/workflows/{WORKFLOW}"]
        require(done and all(isinstance(run.get("id"), int) for run in done),
                "No completed push run of main found; cannot tell whether main is green; refusing")
        latest = max(done, key=lambda run: run["id"])
        # A re-run keeps the run ID and the listing shows it as unfinished: it must not hide a red result.
        pending = [run for run in runs if isinstance(run, dict) and run.get("event") == "push"
                   and run.get("head_branch") == "main" and run.get("status") != "completed"
                   and run.get("path") == f".github/workflows/{WORKFLOW}" and isinstance(run.get("id"), int)
                   and run["id"] > latest["id"]
                   # A first attempt in progress is normal; a re-run or a run without a readable attempt is not.
                   and not (type(run.get("run_attempt")) is int and run["run_attempt"] == 1)]
        if pending:
            latest = dict(max(pending, key=lambda run: run["id"]), conclusion="re-run in progress")
        elif latest.get("conclusion") == "success":
            return
        run_id, conclusion = latest["id"], latest.get("conclusion")
        login = self.text("gh", "api", "user", "--jq", ".login")
        require(re.fullmatch(r"[A-Za-z0-9-]{1,39}", login or ""), "Invalid authenticated login; refusing")
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/issues/{FREEZE_ISSUE}/comments?per_page=100")
        require(isinstance(pages, list), "Invalid comment pages; refusing")
        for comment in [c for page in pages for c in page]:
            match = CLASSIFICATION.fullmatch((comment.get("body") or "").strip()) if isinstance(comment, dict) else None
            author = (comment.get("user") or {}).get("login") if isinstance(comment, dict) else None
            if match and author == login and int(match.group(1)) == run_id:
                self.emit(f"Main push run {run_id} is {conclusion}, classified as {match.group(2)} on issue "
                          f"#{FREEZE_ISSUE}; continuing", flush=True)
                return
        raise QueueError(
            f"Main is frozen: the latest push run {run_id} of {WORKFLOW} on main is {conclusion} and not "
            f"classified. Comment on issue #{FREEZE_ISSUE} as {login}: 'CI main status: freeze classification "
            f"run={run_id} class=<infrastructure|defect|conflict>', or wait for a later green push run.")

    def gleam_required(self, pr):
        """ELZ-059: (required, reason). The path list is Git's own, from the fetched refs, rename-aware.
        An empty, failed or malformed list means the Gleam run is required."""
        branch = pr["headRefName"]
        # The base is the main SHA of the canonical repository, as for the ancestry test, not a local ref.
        main = self.api("git/ref/heads/main")["object"]["sha"]
        require(valid_sha(main), "Invalid canonical main SHA")
        try:
            out = self.run(["git", "diff", "--name-only", "-z", "--no-renames",
                            f"{main}...refs/remotes/origin/{branch}"]).stdout
        except QueueError as error:
            return True, f"path list failed ({error_detail(error)})"
        paths = [path for path in out.split("\x00") if path]
        if not paths:
            return True, "empty path list"
        for path in paths:
            if (path.startswith(("/", "../")) or "\n" in path or "\\" in path or
                    path.startswith(GLEAM_PREFIX) or path == GLEAM_PREFIX.rstrip("/") or path in GLEAM_PATHS):
                return True, f"changes {path}"
        return False, f"{len(paths)} changed paths, none a Gleam path"

    def unchanged_pr(self, pr):
        fresh = self.pr(pr["number"])
        require(fresh["headRefOid"] == pr["headRefOid"] and
                fresh["headRefName"] == pr["headRefName"],
                "PR head changed during check; refusing stale evidence")
        return fresh

    def process(self, number):
        self.deadline = self.clock() + self.timeout
        workflow_id = self.api(f"actions/workflows/{WORKFLOW}")["id"]
        self.check_main_not_frozen()
        for _ in range(10):
            require(self.clock() < self.deadline, "PR deadline exceeded")
            pr = self.pr(number)
            if not self.fetch(pr):
                self.emit(f"Updating PR #{number} by merging main", flush=True)
                self.text("gh", "pr", "update-branch", str(number), "-R", REPO)
                end = self.clock() + 60
                updated = self.pr(number, ready=False)
                while updated["headRefOid"] == pr["headRefOid"]:
                    self.pause("updated PR head", end)
                    updated = self.pr(number, ready=False)
                continue
            run_id = self.adopt_pr_run(pr, workflow_id)
            adopted = run_id is not None
            if run_id is None:
                self.emit(f"No pull_request run for PR #{number} head={pr['headRefOid']} within {self.pr_run_wait} s; "
                          "dispatching a run as the fallback (a dispatch run is not a pull request status)",
                          flush=True)
                run_id = self.dispatch(pr, workflow_id)
            else:
                self.emit(f"Adopted pull_request run {run_id} for PR #{number} head={pr['headRefOid']}", flush=True)
            try:
                jobs, mode = self.evidence(run_id, pr, workflow_id)
                if mode == "docs-only" and not self.docs_only_change(pr):
                    # The run passed the short check of its own classification; this queue's own classifier does
                    # not agree (or is unavailable), so only a full run is evidence.
                    self.emit(f"Run {run_id} passed the docs-only check, but the queue does not accept the short check "
                              f"for PR #{number} head={pr['headRefOid']} (its own classification is not "
                              "documentation only, or the push run of the current main is not a completed "
                              "success); dispatching a full run", flush=True)
                    run_id, adopted = self.dispatch(pr, workflow_id), False
                    jobs, mode = self.evidence(run_id, pr, workflow_id, allow_docs_only=False, allow_piece=False)
                elif mode == "piece" and not self.piece_only_change(pr):
                    # The run passed the small gate of its own classification; this queue's own classifier does not
                    # agree (or is unavailable), so only a full run is evidence.
                    self.emit(f"Run {run_id} passed the small gate, but the queue does not accept it for PR #{number} "
                              f"head={pr['headRefOid']} (its own classification is not Piece-only); dispatching a "
                              "full run", flush=True)
                    run_id, adopted = self.dispatch(pr, workflow_id), False
                    jobs, mode = self.evidence(run_id, pr, workflow_id, allow_docs_only=False, allow_piece=False)
            except (QueueError, KeyError, TypeError, ValueError, AttributeError):
                # The run goes on after the queue stops; name it so that it can be adopted by hand.
                self.emit(f"Stopped while awaiting run {run_id} for PR #{number} head={pr['headRefOid']}: "
                          "inspect that run; the queue adopts it again on the next start", flush=True)
                raise
            if mode == "piece":
                self.check_piece_window()
            self.unchanged_pr(pr)
            required, why = self.gleam_required(pr)
            gleam_job = self.gleam_evidence(pr) if required else None
            if not required:
                self.emit(f"Gleam run not required for PR #{number}: {why}", flush=True)
            fresh = self.unchanged_pr(pr)
            if not self.fetch(fresh):
                self.emit("Main moved during check; updating and validating a new head", flush=True)
                continue
            require(self.clock() < self.deadline, "PR deadline exceeded before merge")
            if mode == "docs-only":
                # Main and the head are unchanged since the first classification (fetch above); classify once more
                # on the fresh refs right before the merge, so that the merge never rests on an older answer.
                require(self.docs_only_change(fresh),
                        f"Docs-only run {run_id} no longer matches the queue's own classification; refusing to merge")
            if mode == "piece":
                # The same for the small gate: classify once more on the fresh refs right before the merge.
                require(self.piece_only_change(fresh),
                        f"Small gate run {run_id} no longer matches the queue's own classification; refusing to merge")
            if adopted:
                # The adoption rules held when the run was chosen. A sibling pull request or a retarget that came
                # later could make the run (or the push run that follows the merge) count for another base.
                require(self.sole_pull_request_of_head(fresh) and not self.ever_retargeted(fresh),
                        f"Another pull request for branch {fresh['headRefName']} or a base change appeared after "
                        f"run {run_id} was adopted; refusing to merge on it")
            newer = self.newer_run_of_head(run_id, fresh)
            require(newer is None, f"Run {newer} on head {fresh['headRefOid']} is newer than the evidence run "
                                   f"{run_id}; the push run could decide on it; refusing to merge")
            self.check_main_not_frozen()
            if mode == "piece":
                self.check_piece_window()
            self.text("gh", "pr", "merge", str(number), "-R", REPO,
                      "--merge", "--match-head-commit", pr["headRefOid"])
            merged = self.data("gh", "pr", "view", str(number), "-R", REPO,
                               "--json", "state,headRefOid,mergeCommit")
            merge_sha = (merged.get("mergeCommit") or {}).get("oid")
            require(merged.get("state") == "MERGED" and merged.get("headRefOid") == pr["headRefOid"]
                    and valid_sha(merge_sha), "Merge not confirmed; inspect PR before retrying")
            if gleam_job:
                self.emit(f"ELZOO GLEAM EVIDENCE pr={number} run={gleam_job['run_id']} "
                          f"job={gleam_job['id']} runner={gleam_job['runner_name']} "
                          f"head={pr['headRefOid']}", flush=True)
            else:
                self.emit(f"ELZOO GLEAM GATE not required pr={number} head={pr['headRefOid']} ({why})", flush=True)
            names = (SPLIT_EVIDENCE_JOBS if "check-root-b" in jobs else EVIDENCE_JOBS) + ((PIECE_JOB,) if mode == "piece" else ())
            job_ids = ",".join(name + ":" + str(jobs[name]["id"]) for name in names)
            self.emit(f"ELZOO MERGE EVIDENCE pr={number} run={run_id} jobs={job_ids} "
                      f"head={pr['headRefOid']} merge={merge_sha}"
                      + (" mode=docs-only" if mode == "docs-only" else "")
                      + (" mode=piece (small gate; the full check is the push run on main)" if mode == "piece" else ""),
                      flush=True)
            return
        raise QueueError("Main/head did not stabilize after 10 passes; inspect before retrying")


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main(argv=None, queue=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prs", type=positive_int, nargs="+", metavar="PR")
    parser.add_argument("--continue-on-failure", action="store_true")
    parser.add_argument("--timeout", type=positive_int, default=10800,
                        help="maximum seconds per PR (default: 10800)")
    args = parser.parse_args(argv)
    queue = queue or Queue(timeout=args.timeout)
    failed = False
    for number in args.prs:
        try:
            queue.process(number)
        except (QueueError, KeyError, TypeError, ValueError, AttributeError) as error:
            print(f"PR #{number} STOPPED: {error}", file=sys.stderr, flush=True)
            failed = True
            if not args.continue_on_failure:
                break
    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Queue interrupted; no further PRs processed. Inspect any dispatched run/merge.", file=sys.stderr)
        sys.exit(130)
