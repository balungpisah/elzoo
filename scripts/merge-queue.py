#!/usr/bin/env python3
"""Serial coordinator queue: full, exact-head CI before a merge (own gh login).

Run from this repository. This is not branch protection or an independent review.
No branch deletion, issue closure, or acceptance posting is performed.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from urllib.parse import urlencode

REPO = "balungpisah/elzoo"
WORKFLOW = "symbolic-check.yml"
GLEAM_WORKFLOW = "symbolic-gleam.yml"
# ELZ-057: queue runs are dispatched with tier=fast and only the fast-tier runners may supply evidence.
FAST_RUNNERS = {"symbolic-elzoo", "macbook-ubuntu-elzoo-candidate"}
FAST_JOB = "check-fast"
ANY_JOB = "check-any"
SHA = re.compile(r"[0-9a-f]{40}")
PR_FIELDS = ("number,state,isDraft,isCrossRepository,baseRefName,headRefName,"
             "headRefOid,headRepository,mergeable,mergeCommit")


class QueueError(Exception):
    """A refusal or unavailable evidence; never a reason to merge anyway."""


def command(argv, allowed=(0,)):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise QueueError(f"{argv[0]} failed: {error}") from error
    if result.returncode not in allowed:
        raise QueueError(f"{' '.join(argv)} exited {result.returncode}: "
                         f"{result.stderr.strip() or result.stdout.strip()}")
    return result


def require(condition, reason):
    if not condition:
        raise QueueError(reason)


def valid_sha(value):
    return isinstance(value, str) and SHA.fullmatch(value) is not None


class Queue:
    def __init__(self, run=command, sleep=time.sleep, clock=time.monotonic,
                 timeout=10800, poll=15, emit=print):
        self.run, self.sleep, self.clock = run, sleep, clock
        self.timeout, self.poll, self.emit = timeout, poll, emit
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
                run.get("path") == f".github/workflows/{WORKFLOW}")

    def cancel_duplicate_pr_run(self, pr, workflow_id):
        """ELZ-058: update-branch makes GitHub start a pull_request check on the new head, and the
        queue's own exact-head dispatch follows on that same head, so the check is a duplicate.
        Cancel only that run (same workflow, pull_request event, branch and exact head SHA); never
        another head, another PR, a dispatch, a push run or the Gleam workflow. A failure is
        logged and never blocks the queue: the exact-head dispatch is the merge gate."""
        try:
            query = urlencode({"event": "pull_request", "branch": pr["headRefName"],
                               "head_sha": pr["headRefOid"], "per_page": 100})
            end = self.clock() + 30
            while True:
                pages = self.data("gh", "api", "--paginate", "--slurp",
                                  f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?{query}")
                runs = [run for page in pages for run in page["workflow_runs"]
                        if self.pr_run_matches(run, pr, workflow_id)]
                if runs:
                    break
                self.pause("pull_request run on the updated head", end)
            for run in runs:
                if not isinstance(run.get("id"), int):
                    raise QueueError("Invalid duplicate run ID")
                if run.get("status") == "completed":
                    self.emit(f"Duplicate pull_request run {run['id']} already completed; not cancelled",
                              flush=True)
                    continue
                self.text("gh", "api", "-X", "POST", f"repos/{REPO}/actions/runs/{run['id']}/cancel")
                self.emit(f"Cancelled duplicate pull_request run {run['id']} head={pr['headRefOid']}",
                          flush=True)
        except (QueueError, KeyError, TypeError) as error:
            self.emit(f"Duplicate pull_request run not cancelled: {error}", flush=True)

    def dispatch(self, pr, workflow_id):
        previous = {run["id"] for run in self.runs(pr["headRefName"])}
        self.text("gh", "workflow", "run", WORKFLOW, "-R", REPO,
                  "--ref", pr["headRefName"], "-f", "tier=fast")
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

    def evidence(self, run_id, pr, workflow_id):
        while True:
            run = self.api(f"actions/runs/{run_id}")
            require(run.get("id") == run_id and self.matches(run, pr, workflow_id),
                    "Run event/branch/workflow/head SHA mismatch")
            if run.get("status") == "completed":
                break
            self.pause(f"run {run_id} status={run.get('status')}")
        require(run.get("conclusion") == "success", f"Run {run_id}: {run.get('conclusion')}")
        attempt = run.get("run_attempt")
        require(isinstance(attempt, int) and attempt > 0, "Missing run attempt")
        pages = self.data("gh", "api", "--paginate", "--slurp",
                          f"repos/{REPO}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        jobs = [job for page in pages for job in page["jobs"]]
        # Two backend jobs exist in the workflow; a fast-tier run runs check-fast and skips check-any.
        fast_jobs = [job for job in jobs if job.get("name") == FAST_JOB]
        other_jobs = [job for job in jobs if job.get("name") != FAST_JOB]
        require(len(fast_jobs) == 1 and all(job.get("name") == ANY_JOB and job.get("conclusion") == "skipped"
                                            for job in other_jobs),
                "Expected exactly one check-fast job and no executed check-any job")
        job = fast_jobs[0]
        require(job.get("run_id") == run_id and job.get("head_sha") == pr["headRefOid"] and
                job.get("status") == "completed" and job.get("conclusion") == "success",
                "Backend job is not successful on the exact head/run")
        require(job.get("runner_name") in FAST_RUNNERS, "Unapproved backend runner")
        steps = [step for step in job.get("steps", []) if step.get("name") == "Run mix check"]
        require(len(steps) == 1 and steps[0].get("conclusion") == "success",
                "Full check step missing, skipped or failed")
        require(isinstance(job.get("id"), int), "Invalid job ID")
        log = self.text("gh", "api", "--allow-escape-sequences",
                        f"repos/{REPO}/actions/jobs/{job['id']}/logs")
        # Raw job logs have a UTC timestamp prefix. Do not accept an echoed command
        # containing the marker, nor any affected-mode success marker.
        full = re.search(r"(?m)^(?:\d{4}-\d\d-\d\dT[0-9:.]+Z )?ELZOO CHECK PASSED\s*$", log)
        require(full and "ELZOO AFFECTED CHECK PASSED" not in log,
                "Missing full success marker or affected-mode marker present")
        latest = self.api(f"actions/runs/{run_id}")
        require(self.matches(latest, pr, workflow_id) and latest.get("status") == "completed" and
                latest.get("conclusion") == "success" and latest.get("run_attempt") == attempt,
                "Run changed while collecting evidence")
        return job

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
        require(len(jobs) == 1 and jobs[0].get("name") == "gleam", "Expected exactly one Gleam job")
        job = jobs[0]
        require(job.get("run_id") == run_id and job.get("head_sha") == pr["headRefOid"] and
                job.get("status") == "completed" and job.get("conclusion") == "success" and
                job.get("runner_name") == "symbolic-elzoo-gleam", "Gleam job evidence mismatch")
        steps = [step for step in job.get("steps", []) if step.get("name") == "Run ./scripts/check.sh"]
        require(len(steps) == 1 and steps[0].get("conclusion") == "success", "Gleam check step did not pass")
        require(isinstance(job.get("id"), int), "Invalid Gleam job ID")
        latest = self.api(f"actions/runs/{run_id}")
        require(latest.get("id") == run_id and matches(latest) and
                latest.get("status") == "completed" and latest.get("conclusion") == "success" and
                latest.get("run_attempt") == attempt, "Gleam run changed while collecting evidence")
        return job

    def unchanged_pr(self, pr):
        fresh = self.pr(pr["number"])
        require(fresh["headRefOid"] == pr["headRefOid"] and
                fresh["headRefName"] == pr["headRefName"],
                "PR head changed during check; refusing stale evidence")
        return fresh

    def process(self, number):
        self.deadline = self.clock() + self.timeout
        workflow_id = self.api(f"actions/workflows/{WORKFLOW}")["id"]
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
                self.cancel_duplicate_pr_run(updated, workflow_id)
                continue
            run_id = self.dispatch(pr, workflow_id)
            job = self.evidence(run_id, pr, workflow_id)
            self.unchanged_pr(pr)
            gleam_job = self.gleam_evidence(pr)
            fresh = self.unchanged_pr(pr)
            if not self.fetch(fresh):
                self.emit("Main moved during check; updating and validating a new head", flush=True)
                continue
            require(self.clock() < self.deadline, "PR deadline exceeded before merge")
            self.text("gh", "pr", "merge", str(number), "-R", REPO,
                      "--merge", "--match-head-commit", pr["headRefOid"])
            merged = self.data("gh", "pr", "view", str(number), "-R", REPO,
                               "--json", "state,headRefOid,mergeCommit")
            merge_sha = (merged.get("mergeCommit") or {}).get("oid")
            require(merged.get("state") == "MERGED" and merged.get("headRefOid") == pr["headRefOid"]
                    and valid_sha(merge_sha), "Merge not confirmed; inspect PR before retrying")
            self.emit(f"ELZOO GLEAM EVIDENCE pr={number} run={gleam_job['run_id']} "
                      f"job={gleam_job['id']} runner={gleam_job['runner_name']} "
                      f"head={pr['headRefOid']}", flush=True)
            self.emit(f"ELZOO MERGE EVIDENCE pr={number} run={run_id} job={job['id']} "
                      f"runner={job['runner_name']} head={pr['headRefOid']} merge={merge_sha}", flush=True)
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
