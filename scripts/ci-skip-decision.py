#!/usr/bin/env python3
"""ELZ-058: may the push run on main skip `mix check` because it would repeat a passed run?

A push to main whose head commit is a merge commit has two parents: the first is main before the
merge, the second is the pull request head that the merge queue merged with --match-head-commit.
If the merge commit's tree equals the second parent's tree, the merged content is exactly the
content that the queue's exact-head full run checked. The run is skipped only when that run can be
found again and passes the same evidence rules as the queue (scripts/merge-queue.py): the latest
run of symbolic-check.yml on that exact head (a same-repository pull_request run, or a workflow_dispatch
run as the queue's fallback; ELZ-059) succeeded, with one successful
`check-hosted` job on a GitHub-hosted runner of the approved label (ELZ-066, ELZ-069: the only lane),
a successful identity step, a successful `Run mix check` step, the full success marker and no
affected-mode marker in its log.

ELZ-071: the evidence of a documentation-only merge is the short check of a pull_request run instead: its
`Run mix check` step was skipped, its `Classify the change` and `Docs-only check` steps passed, and its log has
the line ELZOO DOCS-ONLY CHECK PASSED and no full-run or affected-mode marker. That counts only when this
checkout's own scripts/ci-change-class.py classifies the merge commit's change against its first parent as
documentation only (a dispatch run never has the short shape: it is not a pull_request event), and only when the
first parent, the main before the merge, has a push run of this workflow that completed with success: a short check
runs no tests, so it must not hide a red or unfinished push run of that main behind a green documentation merge
(otherwise the full check runs, with the code of the first parent in the tree).

Small gate: a run whose job `check-piece` ran (the small gate of a Piece-only pull request, `mix check --piece`) is never
evidence here, whatever the classification of the merge says. The small gate is a selected check; the push run on main
is the full check of the merged content (owner decision), so it always runs after a small-gate merge.

Fail closed: every other case, and every error, prints skip=false (a full run). The script never
exits non-zero because it cannot decide. It writes skip=true|false to $GITHUB_OUTPUT.
"""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

WORKFLOW = "symbolic-check.yml"
HOSTED_JOB = "check-hosted"
# ELZ-073: one run has five jobs and is one evidence unit (see scripts/merge-queue.py, which reads the same rules).
PLAN_JOB = "check-plan"
WORK_PARTS = (("check-root", "ELZOO ROOT SUITE PASSED"), ("check-consumers-db", "ELZOO CONSUMERS DB PASSED"),
              ("check-consumers", "ELZOO CONSUMERS PASSED"))
SPLIT_WORK_PARTS = (("check-root", "ELZOO ROOT A SUITE PASSED"), ("check-root-b", "ELZOO ROOT B SUITE PASSED"),
                    ("check-aggregate", "ELZOO AGGREGATE CONSUMER PASSED"),
                    ("check-consumers-db", "ELZOO CONSUMERS DB PASSED"),
                    ("check-consumers", "ELZOO CONSUMERS PASSED"))
# The five jobs that are the evidence of an accepted run.
EVIDENCE_JOBS = (PLAN_JOB,) + tuple(job for job, _marker in WORK_PARTS) + (HOSTED_JOB,)
# Small gate: the sixth job of the unit. It must be skipped in every run that this script accepts.
PIECE_JOB = "check-piece"
BACKEND_JOBS = EVIDENCE_JOBS + (PIECE_JOB,)
SPLIT_EVIDENCE_JOBS = (PLAN_JOB,) + tuple(job for job, _marker in SPLIT_WORK_PARTS) + (HOSTED_JOB,)
SPLIT_BACKEND_JOBS = SPLIT_EVIDENCE_JOBS + (PIECE_JOB,)
PART_MARKERS = {marker for _job, marker in WORK_PARTS + SPLIT_WORK_PARTS}
LOG_STAMP = r"(?m)^(?:\d{4}-\d\d-\d\dT[0-9:.]+Z )?"
HOSTED_GROUP = "GitHub Actions"
HOSTED_LABELS = ["ubuntu-24.04"]
HOSTED_RUNNER = re.compile(r"GitHub Actions [0-9]+")
HOSTED_GATE_STEP = "Verify the GitHub-hosted runner"
SHA = re.compile(r"[0-9a-f]{40}")
API_ROOT = "https://api.github.com"
HOST = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+")
# The job-log endpoint answers with a redirect to GitHub's Actions results storage (observed 2026-11-08:
# productionresultssa9.blob.core.windows.net, path /actions-results/...). Only that shape is accepted.
RESULTS_HOST = re.compile(r"productionresultssa[0-9]+\.blob\.core\.windows\.net")


class Full(Exception):
    """A reason to run the full check. Never an error of this script."""


def need(condition, reason):
    if not condition:
        raise Full(reason)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_get(url, headers, timeout=60):
    """One GET, no automatic redirect. Returns (status, headers, body bytes)."""
    request = urllib.request.Request(url, headers=headers)
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.headers, error.read()
        finally:
            error.close()


def redirect_allowed(location):
    """HTTPS only, plain host, no user info, port 443 or none, GitHub-owned domain."""
    try:
        if not location.isascii() or any(c in location for c in "\\ \t\r\n"):
            return False
        parts = urllib.parse.urlsplit(location)
        host = parts.hostname or ""
        if "%" in parts.netloc or parts.scheme != "https" or parts.username is not None \
                or parts.password is not None or parts.port not in (None, 443) or not HOST.fullmatch(host):
            return False
    except ValueError:
        return False
    if RESULTS_HOST.fullmatch(host):
        return parts.path.startswith("/actions-results/")
    return host == "github.com" or host.endswith(".github.com") or host.endswith(".githubusercontent.com")


class Api:
    """GitHub REST reads with the job token. The token never goes to a redirect target."""

    def __init__(self, repo, token, get=http_get):
        self.repo, self.token, self.get = repo, token, get

    def _headers(self):
        return {"Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.token}",
                "User-Agent": "elzoo-ci-skip-decision", "X-GitHub-Api-Version": "2022-11-28"}

    def json(self, path):
        status, _headers, body = self.get(f"{API_ROOT}/repos/{self.repo}/{path}", self._headers())
        need(status == 200, f"API {path.split('?')[0]} answered HTTP {status}")
        try:
            return json.loads(body)
        except ValueError as error:
            raise Full(f"API {path.split('?')[0]} returned invalid JSON") from error

    def text(self, path):
        status, headers, body = self.get(f"{API_ROOT}/repos/{self.repo}/{path}", self._headers())
        if status in (301, 302, 303, 307, 308):
            location = headers.get("Location", "")
            need(redirect_allowed(location), "log redirect to an unexpected host")
            status, _headers, body = self.get(location, {"User-Agent": "elzoo-ci-skip-decision"})
        need(status == 200, f"API {path} answered HTTP {status}")
        return body.decode("utf-8", errors="replace")


def git(*argv):
    result = subprocess.run(["git", *argv], capture_output=True, text=True, timeout=60)
    need(result.returncode == 0, f"git {' '.join(argv)} failed")
    return result.stdout.strip()


def parse_time(value, what):
    """A GitHub UTC timestamp as a datetime; anything else is a reason to run the full check."""
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError) as error:
        raise Full(f"invalid {what}: {value!r}") from error


def load_classifier():
    """The documentation-only allowlist of this checkout (the merge commit of main). Any failure to load it means
    that no change is documentation only."""
    try:
        path = Path(__file__).resolve().with_name("ci-change-class.py")
        spec = importlib.util.spec_from_file_location("ci_change_class", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:  # noqa: BLE001
        return None


CLASSIFIER = load_classifier()


def docs_only_merge(run_git, first, merge):
    """True only when the change of the merge commit against its first parent is documentation only."""
    if CLASSIFIER is None:
        return False
    try:
        output = run_git(*CLASSIFIER.diff_argv(first, merge)[1:])
        return CLASSIFIER.docs_only(CLASSIFIER.parse_raw(output)) is True
    except Exception:  # noqa: BLE001 - any failure means "not documentation only"
        return False


def first_parent_verified(api, first):
    """True when the push run with the highest ID on the first parent (the main before the merge) completed with
    success. A logged skip is a success of the job. No run, an unfinished run or a malformed listing is False."""
    query = urllib.parse.urlencode({"event": "push", "head_sha": first, "per_page": 100})
    try:
        listing = api.json(f"actions/workflows/{WORKFLOW}/runs?{query}")
    except Full:
        return False
    runs = listing.get("workflow_runs") if isinstance(listing, dict) else None
    if not isinstance(runs, list):
        return False
    mine = [run for run in runs if isinstance(run, dict) and run.get("event") == "push"
            and run.get("head_branch") == "main" and run.get("head_sha") == first
            and run.get("path") == f".github/workflows/{WORKFLOW}"]
    if not mine or not all(isinstance(run.get("id"), int) for run in mine):
        return False
    latest = max(mine, key=lambda run: run["id"])
    return latest.get("status") == "completed" and latest.get("conclusion") == "success"


def evidence_event(run, repo):
    """ELZ-059: the pull_request run of the same repository is the merge evidence; a workflow_dispatch run
    stays valid as the queue's fallback. A pull_request run from a fork is never evidence."""
    event = run.get("event")
    if event == "workflow_dispatch":
        return True
    source = run.get("head_repository")
    return event == "pull_request" and isinstance(source, dict) and source.get("full_name") == repo


def decide(env, run_git=git, api=None):
    """Return (skip, reason, details). Raises Full for every reason to run the full check."""
    need(env.get("GITHUB_EVENT_NAME") == "push" and env.get("GITHUB_REF") == "refs/heads/main",
         "not a push to main")
    sha = env.get("GITHUB_SHA", "")
    need(SHA.fullmatch(sha), "invalid GITHUB_SHA")
    parents = run_git("rev-list", "--parents", "-n1", "HEAD").split()
    need(len(parents) == 3 and parents[0] == sha and all(SHA.fullmatch(p) for p in parents),
         "head is not a two-parent merge commit of the pushed SHA")
    second = parents[2]
    tree, second_tree = run_git("rev-parse", "HEAD^{tree}"), run_git("rev-parse", f"{second}^{{tree}}")
    need(SHA.fullmatch(tree) and tree == second_tree, "merge tree differs from the second parent's tree")
    repo = env.get("GITHUB_REPOSITORY", "")
    need(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) and env.get("GITHUB_TOKEN"),
         "missing repository or token")
    api = api or Api(repo, env["GITHUB_TOKEN"])

    query = urllib.parse.urlencode({"head_sha": second, "per_page": 100})
    listing = api.json(f"actions/workflows/{WORKFLOW}/runs?{query}")
    runs = listing.get("workflow_runs")
    need(isinstance(runs, list) and isinstance(listing.get("total_count"), int)
         and listing["total_count"] == len(runs) <= 100, "run listing incomplete or malformed")
    candidates = [run for run in runs if evidence_event(run, repo)
                  and run.get("head_sha") == second
                  and run.get("path") == f".github/workflows/{WORKFLOW}"]
    need(candidates and all(isinstance(run.get("id"), int) for run in candidates),
         "no queue run on the second parent")
    # The latest run decides: an older success must not hide a newer failure or a cancellation.
    run = max(candidates, key=lambda r: r["id"])
    run_id, attempt = run["id"], run.get("run_attempt")
    if run.get("event") == "pull_request":
        # A pull_request run tests the merge of the head with its base. When the head holds the whole of main
        # (the first parent), that merge has the tree of the head. Otherwise the run tested another tree.
        # No commit of the first parent is outside the head: rev-list lists none.
        ancestor = run_git("rev-list", "--count", f"{second}..{parents[1]}") == "0"
        need(ancestor, "the pull_request run may have tested another tree: the head does not hold the first parent")
    need(run.get("status") == "completed" and run.get("conclusion") == "success"
         and isinstance(attempt, int) and attempt > 0,
         f"latest run {run_id} is not a completed success")

    jobs_page = api.json(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    jobs = jobs_page.get("jobs")
    need(isinstance(jobs, list) and jobs_page.get("total_count") == len(jobs), "job listing incomplete")
    need(all(isinstance(job, dict) for job in jobs), "job listing malformed")
    names = sorted(str(job.get("name")) for job in jobs)
    split = names == sorted(SPLIT_BACKEND_JOBS)
    need(split or names == sorted(BACKEND_JOBS),
         "the jobs are not the six backend jobs (five and check-piece) or the fixed split eight-job unit, once each")
    work_parts = SPLIT_WORK_PARTS if split else WORK_PARTS
    by_name = {job["name"]: job for job in jobs}
    began = parse_time(run.get("run_started_at"), "run start")
    for job in jobs:
        if job.get("conclusion") == "skipped":
            continue
        name = job["name"]
        need(job.get("run_id") == run_id and job.get("head_sha") == second and job.get("status") == "completed"
             and job.get("conclusion") == "success" and isinstance(job.get("id"), int), f"job evidence mismatch ({name})")
        need(job.get("runner_group_name") == HOSTED_GROUP and job.get("labels") == HOSTED_LABELS
             and isinstance(job.get("runner_name"), str) and HOSTED_RUNNER.fullmatch(job["runner_name"]),
             f"job did not run on an approved GitHub-hosted runner ({name})")
        gate = [step for step in job.get("steps", []) if step.get("name") == HOSTED_GATE_STEP]
        need(len(gate) == 1 and gate[0].get("conclusion") == "success", f"hosted runner identity step not green ({name})")
        # A partial re-run copies the green jobs of the earlier attempt into the new one (new ID, old start time).
        need(parse_time(job.get("started_at"), f"job start ({name})") >= began, f"job {name} ran in an earlier attempt")
    plan, aggregate = by_name[PLAN_JOB], by_name[HOSTED_JOB]
    need(plan.get("conclusion") != "skipped" and aggregate.get("conclusion") != "skipped",
         "the plan job and the aggregating job must have run")
    # Small gate: never the evidence of a push run, also when the classification of the merge agrees.
    need(by_name[PIECE_JOB].get("conclusion") == "skipped",
         "the second parent's run is a small-gate (piece) run: a selected check is never the evidence of a push run")
    work = [by_name[job] for job, _marker in work_parts]
    ran = [job for job in work if job.get("conclusion") != "skipped"]
    mode = "full" if len(ran) == len(work) else "docs-only"
    need(mode == "full" or not ran, "the work jobs are partly skipped: not a full run")
    logs = {}

    def log(job):
        if job["name"] not in logs:
            logs[job["name"]] = api.text(f"actions/jobs/{job['id']}/logs")
        return logs[job["name"]]

    def step(job, name):
        return [item for item in job.get("steps", []) if item.get("name") == name]

    def has_line(job, text):
        return re.search(LOG_STAMP + text + r"\s*$", log(job)) is not None

    classify, docs_step = step(plan, "Classify the change"), step(plan, "Docs-only check")
    need(len(classify) == 1 and classify[0].get("conclusion") == "success", "the classification step is not green")
    need(len(step(aggregate, "Require every job")) == 1 and step(aggregate, "Require every job")[0].get("conclusion") == "success",
         "the aggregating step is not green")
    if mode == "full":
        need(len(docs_step) == 1 and docs_step[0].get("conclusion") == "skipped", "the docs-only step ran in a full run")
        need(has_line(plan, r"ELZOO PLAN: run=true skip=\S+ docs_only=\S+") and "ELZOO AFFECTED CHECK PASSED" not in log(plan),
             "the plan did not say run=true, or an affected-mode marker is present in its log")
        for job in work:
            mix = step(job, "Run mix check")
            need(len(mix) == 1 and mix[0].get("conclusion") == "success", f"Run mix check step not green ({job['name']})")
        for name, marker in work_parts:
            need(has_line(by_name[name], re.escape(marker)) and "ELZOO AFFECTED CHECK PASSED" not in log(by_name[name]),
                 f"part marker missing or affected-mode marker present ({name})")
            need(not any(has_line(by_name[name], re.escape(other)) for other in PART_MARKERS - {marker}),
                 f"unexpected part marker ({name})")
        need(has_line(aggregate, "ELZOO CHECK PASSED") and "ELZOO AFFECTED CHECK PASSED" not in log(aggregate),
             "full success marker missing or affected-mode marker present in the aggregating job")
        need(not any(has_line(job, "ELZOO CHECK PASSED") for job in [plan] + work),
             "full success marker outside check-hosted")
        need(not has_line(plan, "ELZOO DOCS-ONLY CHECK PASSED"), "docs-only marker present in a full run")
    else:
        # ELZ-071: the short check of a documentation-only pull_request run.
        need(run.get("event") == "pull_request", "a run without the work jobs is evidence only on a pull_request run")
        need(docs_only_merge(run_git, parents[1], sha), "the change of the merge is not documentation only")
        need(first_parent_verified(api, parents[1]),
             "the push run of the first parent is not a completed success; the short check would hide it")
        need(len(docs_step) == 1 and docs_step[0].get("conclusion") == "success", "the docs-only check step is not green")
        need(has_line(plan, "ELZOO DOCS-ONLY CHECK PASSED") and has_line(plan, r"ELZOO PLAN: run=false skip=\S+ docs_only=true"),
             "docs-only success marker or plan line missing")
        need(not has_line(aggregate, "ELZOO CHECK PASSED") and not has_line(plan, "ELZOO CHECK PASSED")
             and "ELZOO AFFECTED CHECK PASSED" not in log(plan),
             "a full or affected-mode marker is present in a docs-only run")
        need(not any(has_line(job, re.escape(marker)) for job in [plan, aggregate] for marker in PART_MARKERS),
             "part marker present in a docs-only run")

    latest = api.json(f"actions/runs/{run_id}")
    need(latest.get("id") == run_id and latest.get("status") == "completed"
         and latest.get("conclusion") == "success" and latest.get("run_attempt") == attempt,
         "run changed while reading it")
    details = dict(second_parent=second, tree=tree, run=run_id, mode=mode,
                   jobs=",".join(name + ":" + str(by_name[name]["id"])
                                 for name in (SPLIT_EVIDENCE_JOBS if split else EVIDENCE_JOBS)))
    if mode == "docs-only":
        return True, "identical tree, documentation-only change and a passed exact-head docs-only check", details
    return True, "identical tree and a passed exact-head full run", details


def main(env=None, run_git=git, api=None, out=print):
    env = os.environ if env is None else env
    try:
        skip, reason, details = decide(env, run_git, api)
    except Full as why:
        skip, reason, details = False, str(why), {}
    except Exception as error:  # noqa: BLE001 - any failure means a full run, never a failed job
        skip, reason, details = False, f"{type(error).__name__}: {error}", {}
    if skip:
        kind = "docs-only check" if details.get("mode") == "docs-only" else "full run"
        out(f"ELZOO PUSH CHECK SKIPPED (identical tree; exact-head {kind} passed): "
            f"second_parent={details['second_parent']} tree={details['tree']} "
            f"run={details['run']} jobs={details['jobs']}")
    else:
        out(f"ELZOO PUSH CHECK DECISION: full check runs ({reason})")
    target = env.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(f"skip={'true' if skip else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
