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

Fail closed: every other case, and every error, prints skip=false (a full run). The script never
exits non-zero because it cannot decide. It writes skip=true|false to $GITHUB_OUTPUT.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

WORKFLOW = "symbolic-check.yml"
HOSTED_JOB = "check-hosted"
HOSTED_GROUP = "GitHub Actions"
HOSTED_LABELS = ["ubuntu-24.04"]
HOSTED_RUNNER = re.compile(r"GitHub Actions [0-9]+")
HOSTED_GATE_STEP = "Verify the GitHub-hosted runner"
SHA = re.compile(r"[0-9a-f]{40}")
BRANCH = re.compile(r"task/ELZ-[0-9]{3}")
MARKER = re.compile(r"(?m)^(?:\d{4}-\d\d-\d\dT[0-9:.]+Z )?ELZOO CHECK PASSED\s*$")
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
                  and run.get("path") == f".github/workflows/{WORKFLOW}"
                  and BRANCH.fullmatch(run.get("head_branch") or "")]
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
    names = [job.get("name") for job in jobs]
    need(len(set(names)) == len(names) and all(name == HOSTED_JOB for name in names),
         "unknown or duplicate backend jobs")
    executed = [job for job in jobs if job.get("conclusion") != "skipped"]
    need(len(executed) == 1 and executed[0].get("name") == HOSTED_JOB,
         "jobs are not one executed check-hosted job")
    job = executed[0]
    need(job.get("run_id") == run_id and job.get("head_sha") == second and job.get("status") == "completed"
         and job.get("conclusion") == "success" and isinstance(job.get("id"), int), "job evidence mismatch")
    need(job.get("runner_group_name") == HOSTED_GROUP and job.get("labels") == HOSTED_LABELS
         and isinstance(job.get("runner_name"), str) and HOSTED_RUNNER.fullmatch(job["runner_name"]),
         "job did not run on an approved GitHub-hosted runner")
    gate = [step for step in job.get("steps", []) if step.get("name") == HOSTED_GATE_STEP]
    need(len(gate) == 1 and gate[0].get("conclusion") == "success", "hosted runner identity step not green")
    steps = [step for step in job.get("steps", []) if step.get("name") == "Run mix check"]
    need(len(steps) == 1 and steps[0].get("conclusion") == "success", "Run mix check step missing or not green")
    log = api.text(f"actions/jobs/{job['id']}/logs")
    need(MARKER.search(log) and "ELZOO AFFECTED CHECK PASSED" not in log,
         "full success marker missing or affected-mode marker present")

    latest = api.json(f"actions/runs/{run_id}")
    need(latest.get("id") == run_id and latest.get("status") == "completed"
         and latest.get("conclusion") == "success" and latest.get("run_attempt") == attempt,
         "run changed while reading it")
    details = dict(second_parent=second, tree=tree, run=run_id, job=job["id"], runner=job["runner_name"])
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
        out("ELZOO PUSH CHECK SKIPPED (identical tree; exact-head full run passed): "
            f"second_parent={details['second_parent']} tree={details['tree']} "
            f"run={details['run']} job={details['job']} runner={details['runner']}")
    else:
        out(f"ELZOO PUSH CHECK DECISION: full check runs ({reason})")
    target = env.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(f"skip={'true' if skip else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
