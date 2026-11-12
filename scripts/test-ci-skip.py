#!/usr/bin/env python3
"""ELZ-058 controls for scripts/ci-skip-decision.py: real Git repositories, a fake GitHub API."""
import copy
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ci_skip", ROOT / "scripts" / "ci-skip-decision.py")
skip = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(skip)


def sh(repo, *argv):
    result = subprocess.run(["git", "-C", str(repo), *argv], capture_output=True, text=True, check=True)
    return result.stdout.strip()


def make_repo(root, scenario):
    """Build a repository for one scenario and return (path, head, second_parent_or_None)."""
    repo = pathlib.Path(root)
    sh(repo, "init", "-q", "-b", "main")
    sh(repo, "config", "user.email", "t@example.invalid")
    sh(repo, "config", "user.name", "t")
    (repo / "a").write_text("a\n")
    sh(repo, "add", "a")
    sh(repo, "commit", "-qm", "base")
    if scenario == "root":
        return repo, sh(repo, "rev-parse", "HEAD"), None
    sh(repo, "switch", "-qc", "pr")
    # ELZ-071: scenarios whose pull request changes documentation paths (the default changes the file "b").
    pr_files = {"docs": ["docs/b.md"], "docs-code": ["docs/b.md", "scripts/x.py"], "docs-consuming": ["docs/consuming.md"],
                "docs-ledger": ["LEDGER.md"], "docs-rename-out": ["scripts/a.md"]}.get(scenario, ["b"])
    for name in pr_files:
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text("b\n")
        sh(repo, "add", name)
    sh(repo, "commit", "-qm", "pr")
    pr_head = sh(repo, "rev-parse", "HEAD")
    sh(repo, "switch", "-q", "main")
    if scenario == "moved":
        (repo / "d").write_text("d\n")
        sh(repo, "add", "d")
        sh(repo, "commit", "-qm", "other change on main")
    if scenario == "same-change":
        (repo / "b").write_text("b\n")
        sh(repo, "add", "b")
        sh(repo, "commit", "-qm", "same change on main")
    if scenario == "fast-forward":
        sh(repo, "merge", "-q", "--ff-only", "pr")
    elif scenario == "squash":
        sh(repo, "merge", "-q", "--squash", "pr")
        sh(repo, "commit", "-qm", "squash")
    elif scenario == "octopus":
        sh(repo, "switch", "-qc", "pr2")
        (repo / "c").write_text("c\n")
        sh(repo, "add", "c")
        sh(repo, "commit", "-qm", "pr2")
        sh(repo, "switch", "-q", "main")
        sh(repo, "merge", "-q", "--no-ff", "pr", "pr2", "-m", "octopus")
    else:
        sh(repo, "merge", "-q", "--no-ff", "pr", "-m", "merge")
    return repo, sh(repo, "rev-parse", "HEAD"), pr_head


class FakeApi:
    """Answers the JSON reads, the logs reads and the run re-read from dictionaries (ELZ-073: five jobs per run, plus the
    small-gate job check-piece, which is skipped unless `piece` is set)."""

    NAMES = ("check-plan", "check-root", "check-consumers-db", "check-consumers", "check-hosted")
    ALL = NAMES + ("check-piece",)
    WORK = {"check-root": "ELZOO ROOT SUITE PASSED", "check-consumers-db": "ELZOO CONSUMERS DB PASSED",
            "check-consumers": "ELZOO CONSUMERS PASSED"}
    STAMP = "2026-11-08T12:00:00.0000000Z "

    def __init__(self, second):
        self.second = second
        self.calls = []
        self.run = dict(id=900, event="workflow_dispatch", head_sha=second, head_branch="task/ELZ-058",
                        path=".github/workflows/symbolic-check.yml", status="completed",
                        conclusion="success", run_attempt=1, run_started_at="2026-11-08T12:00:00Z")
        self.listing_changes = {}
        self.runs = None
        # The fields that every executed job of the unit shares; a test that sets "steps" here gives every job those steps.
        self.job = dict(run_id=900, head_sha=second, status="completed", conclusion="success",
                        runner_name="GitHub Actions 7", runner_group_name="GitHub Actions", labels=["ubuntu-24.04"],
                        started_at="2026-11-08T12:00:10Z")
        self.jobs_changes = {}             # job name -> changes of that one job
        self.drop_jobs = set()
        self.extra_jobs = []               # jobs that are added to the listing as they are
        self.jobs = None                   # a complete listing instead of the generated one
        self.jobs_total = None             # a total_count that differs from the listing
        self.docs = False                  # the docs-only shape: the three work jobs are skipped
        self.piece = False                 # the small-gate shape: the three work jobs skipped, check-piece ran
        self.plan_steps = None             # the steps of the plan job after the identity step
        self.log = None                    # a log text for every job instead of the default logs
        self.logs_by_job = {}
        self.reread = {}
        self.fail = None
        self.first_parent_runs = None      # None: one completed successful push run on the first parent
        self.first_parent_error = False
        self.first_parent_body = None      # a raw body instead of the listing

    def build_jobs(self):
        gate = {"name": "Verify the GitHub-hosted runner", "conclusion": "success"}
        plan = self.plan_steps if self.plan_steps is not None else (
            [{"name": "Classify the change", "conclusion": "success"},
             {"name": "Docs-only check", "conclusion": "success" if self.docs else "skipped"}])
        jobs = []
        for position, name in enumerate(self.ALL):
            if name in self.drop_jobs:
                continue
            skipped = ((self.docs or self.piece) and name in self.WORK) or (name == "check-piece" and not self.piece)
            steps = ([] if skipped else
                     [gate] + (plan if name == "check-plan" else
                               [{"name": "Require every job", "conclusion": "success"}] if name == "check-hosted" else
                               [{"name": "Run the small gate", "conclusion": "success"}] if name == "check-piece" else
                               [{"name": "Run mix check", "conclusion": "success"}]))
            job = dict(copy.deepcopy(self.job), id=901 + position, name=name, steps=steps)
            if skipped:
                job["conclusion"] = "skipped"
            job.update(copy.deepcopy(self.jobs_changes.get(name, {})))
            jobs.append(job)
        return jobs + copy.deepcopy(self.extra_jobs)

    def json(self, path):
        self.calls.append(path)
        if self.fail and self.fail in path:
            raise skip.Full(f"API {path} answered HTTP 500")
        if "event=push" in path and "head_sha=" in path:     # ELZ-071: the push run of the first parent
            if self.first_parent_error:
                raise skip.Full(f"API {path} answered HTTP 500")
            sha = urllib.parse.parse_qs(path.split("?", 1)[1])["head_sha"][0]
            runs = self.first_parent_runs if self.first_parent_runs is not None else [
                dict(id=800, event="push", head_branch="main", head_sha=sha, status="completed",
                     conclusion="success", path=".github/workflows/symbolic-check.yml")]
            return self.first_parent_body if self.first_parent_body is not None else dict(total_count=len(runs), workflow_runs=runs)
        if "/workflows/" in path or path.startswith("actions/workflows/"):
            runs = self.runs if self.runs is not None else [copy.deepcopy(self.run)]
            body = dict(total_count=len(runs), workflow_runs=runs)
            body.update(self.listing_changes)
            return body
        if "/attempts/" in path:
            jobs = self.jobs if self.jobs is not None else self.build_jobs()
            return dict(total_count=len(jobs) if self.jobs_total is None else self.jobs_total, jobs=jobs)
        out = copy.deepcopy(self.run)
        out.update(self.reread)
        return out

    def text(self, path):
        self.calls.append(path)
        if self.fail and self.fail in path:
            raise skip.Full(f"API {path} answered HTTP 500")
        position = int(path.split("/jobs/")[1].split("/")[0]) - 901
        name = self.ALL[position]
        if name in self.logs_by_job:
            return self.logs_by_job[name]
        if self.log is not None:
            return self.log
        if name == "check-piece":
            return self.STAMP + "ELZOO PIECE CHECK PASSED (small gate)\n" if self.piece else ""
        if name == "check-plan":
            if self.piece:
                return (self.STAMP + "ELZOO PLAN: run=false skip=false docs_only=false\n" + self.STAMP +
                        "ELZOO PIECE PLAN: piece=true piece_only=true\n")
            if self.docs:
                return self.STAMP + "ELZOO DOCS-ONLY CHECK PASSED\n" + self.STAMP + "ELZOO PLAN: run=false skip=false docs_only=true\n"
            return self.STAMP + "ELZOO PLAN: run=true skip=false docs_only=false\n"
        if name == "check-hosted":
            return "" if self.docs else self.STAMP + "ELZOO CHECK PASSED\n"
        return "" if self.docs else self.STAMP + self.WORK[name] + "\n"


class DecisionTest(unittest.TestCase):
    def fresh_dir(self):
        path = tempfile.mkdtemp(prefix="elzoo-skip-test-")
        self.addCleanup(shutil.rmtree, path, True)
        return path

    def scenario(self, name):
        repo, head, second = make_repo(self.fresh_dir(), name)
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": head,
               "GITHUB_REPOSITORY": "balungpisah/elzoo", "GITHUB_TOKEN": "token"}
        return env, (lambda *argv: sh(repo, *argv)), second

    def decide(self, name, api=None, **env_changes):
        env, run_git, second = self.scenario(name)
        env.update(env_changes)
        api = api if api is not None else FakeApi(second)
        return skip.decide(env, run_git, api), api, second

    def refuses(self, name, pattern, api=None, **env_changes):
        env, run_git, second = self.scenario(name)
        env.update(env_changes)
        api = api if api is not None else FakeApi(second)
        with self.assertRaisesRegex(skip.Full, pattern):
            skip.decide(env, run_git, api)
        return api

    def test_identical_tree_and_passed_exact_head_run_skips(self):
        (verdict, reason, details), api, second = self.decide("merge")
        self.assertTrue(verdict)
        self.assertEqual((second, 900, "check-plan:901,check-root:902,check-consumers-db:903,check-consumers:904,check-hosted:905"),
                         (details["second_parent"], details["run"], details["jobs"]))
        self.assertRegex(reason, "identical tree")

    def test_same_change_on_main_still_has_an_identical_tree_and_skips(self):
        (verdict, _reason, _details), _api, _second = self.decide("same-change")
        self.assertTrue(verdict)

    def test_main_moved_runs_the_full_check_without_calling_the_api(self):
        api = self.refuses("moved", "tree differs")
        self.assertEqual([], api.calls)

    def test_other_commit_shapes_run_the_full_check(self):
        for name in ("fast-forward", "squash", "octopus", "root"):
            with self.subTest(shape=name):
                self.refuses(name, "two-parent merge commit")

    def test_not_a_push_to_main_never_skips(self):
        for changes in ({"GITHUB_EVENT_NAME": "pull_request"}, {"GITHUB_EVENT_NAME": "workflow_dispatch"},
                        {"GITHUB_EVENT_NAME": "schedule"}, {"GITHUB_REF": "refs/heads/task/ELZ-058"},
                        {"GITHUB_REF": "refs/pull/1/merge"}, {"GITHUB_EVENT_NAME": ""}):
            with self.subTest(changes=changes):
                self.refuses("merge", "not a push to main", **changes)

    def test_pushed_sha_must_be_the_checked_out_head(self):
        self.refuses("merge", "two-parent merge commit", GITHUB_SHA="d" * 40)
        self.refuses("merge", "invalid GITHUB_SHA", GITHUB_SHA="not-a-sha")

    def test_missing_token_or_repository_runs_the_full_check(self):
        for changes in ({"GITHUB_TOKEN": ""}, {"GITHUB_REPOSITORY": ""}, {"GITHUB_REPOSITORY": "no-slash"}):
            with self.subTest(changes=changes):
                env, run_git, _second = self.scenario("merge")
                env.update(changes)
                with self.assertRaisesRegex(skip.Full, "missing repository or token"):
                    skip.decide(env, run_git, None)

    def mutated(self, **changes):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        for key, value in changes.items():
            target, field = key.split("__", 1)
            if target == "run":
                api.run[field] = value
            elif target == "job":
                api.job[field] = value
            elif target == "attr":
                setattr(api, field, value)
        return env, run_git, api

    def test_run_must_be_a_completed_success(self):
        for field, value in (("status", "in_progress"), ("conclusion", "failure"), ("conclusion", "cancelled"),
                             ("conclusion", None), ("run_attempt", None), ("run_attempt", 0)):
            with self.subTest(field=field, value=value):
                env, run_git, api = self.mutated(**{f"run__{field}": value})
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_run_identity_fields_must_match(self):
        for field, value in (("event", "pull_request"), ("head_sha", "e" * 40), ("head_branch", "feature/x"),
                             ("head_branch", "task/ELZ-58"), ("head_branch", None),
                             ("path", ".github/workflows/symbolic-gleam.yml")):
            with self.subTest(field=field, value=value):
                env, run_git, api = self.mutated(**{f"run__{field}": value})
                with self.assertRaisesRegex(skip.Full, "no queue run"):
                    skip.decide(env, run_git, api)

    def test_the_latest_run_decides_an_older_success_cannot_hide_a_newer_failure(self):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        newer = dict(api.run, id=950, conclusion="failure")
        api.runs = [dict(api.run), newer]
        with self.assertRaisesRegex(skip.Full, "latest run 950 is not a completed success"):
            skip.decide(env, run_git, api)
        # and a newer success after an older failure is accepted only with its own passing jobs
        api = FakeApi(second)
        api.runs = [dict(api.run, id=800, conclusion="failure"), dict(api.run, id=900)]
        self.assertTrue(skip.decide(env, run_git, api)[0])

    def test_listing_must_be_complete_and_well_formed(self):
        for changes in ({"total_count": 101}, {"total_count": 0}, {"total_count": "1"}, {"workflow_runs": None},
                        {"workflow_runs": "x"}):
            with self.subTest(changes=changes):
                env, run_git, second = self.scenario("merge")
                api = FakeApi(second)
                api.listing_changes = changes
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_no_run_for_the_second_parent_runs_the_full_check(self):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        api.runs = []
        with self.assertRaisesRegex(skip.Full, "no queue run"):
            skip.decide(env, run_git, api)

    def test_job_evidence_rules(self):
        # ELZ-073: every executed job of the unit must pass the same rules, one job at a time.
        cases = {
            "job not success": dict(conclusion="failure"),
            "job not completed": dict(status="in_progress"),
            "job other head": dict(head_sha="f" * 40),
            "job other run": dict(run_id=1),
            "job wrong name": dict(name="check"),
            "removed job name check-fast": dict(name="check-fast"),
            "other runner group": dict(runner_group_name="Default"),
            "no runner group": dict(runner_group_name=None),
            "other label": dict(labels=["ubuntu-latest"]),
            "extra label": dict(labels=["ubuntu-24.04", "extra"]),
            "self-hosted label": dict(labels=["self-hosted", "ubuntu-24.04"]),
            "no labels": dict(labels=None),
            "self-hosted runner name": dict(runner_name="self-hosted-1"),
            "short runner name": dict(runner_name="GitHub Actions"),
            "long runner name": dict(runner_name="GitHub Actions 7 extra"),
            "no runner name": dict(runner_name=None),
        }
        env, run_git, second = self.scenario("merge")
        for name in FakeApi.NAMES:
            for label, changes in cases.items():
                with self.subTest(job=name, label=label):
                    api = FakeApi(second)
                    api.jobs_changes[name] = changes
                    with self.assertRaises(skip.Full):
                        skip.decide(env, run_git, api)

    @staticmethod
    def step_variants(steps, step_name):
        index = next(i for i, step in enumerate(steps) if step["name"] == step_name)
        item = steps[index]
        return {"missing": steps[:index] + steps[index + 1:],
                "skipped": steps[:index] + [dict(item, conclusion="skipped")] + steps[index + 1:],
                "failed": steps[:index] + [dict(item, conclusion="failure")] + steps[index + 1:],
                "twice": steps[:index + 1] + [item] + steps[index + 1:]}

    def test_step_rules_per_job_role(self):
        env, run_git, second = self.scenario("merge")
        base = {job["name"]: job["steps"] for job in FakeApi(second).build_jobs()}
        wanted = [(name, "Verify the GitHub-hosted runner") for name in FakeApi.NAMES]
        wanted += [(name, "Run mix check") for name in FakeApi.WORK]
        wanted += [("check-plan", "Classify the change"), ("check-hosted", "Require every job")]
        for name, step_name in wanted:
            for how, steps in self.step_variants(base[name], step_name).items():
                with self.subTest(job=name, step=step_name, how=how):
                    api = FakeApi(second)
                    api.jobs_changes[name] = dict(steps=steps)
                    with self.assertRaises(skip.Full):
                        skip.decide(env, run_git, api)
        # the docs-only step must be skipped in a full run: missing, twice, failed or executed all refuse
        for how, steps in self.step_variants(base["check-plan"], "Docs-only check").items():
            if how == "skipped":
                continue            # the skipped state is the normal full-run state
            with self.subTest(step="Docs-only check", how=how):
                api = FakeApi(second)
                api.jobs_changes["check-plan"] = dict(steps=steps)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)
        ran = [dict(step, conclusion="success") if step["name"] == "Docs-only check" else step for step in base["check-plan"]]
        api = FakeApi(second)
        api.jobs_changes["check-plan"] = dict(steps=ran)
        with self.assertRaisesRegex(skip.Full, "docs-only step ran in a full run"):
            skip.decide(env, run_git, api)

    def test_job_list_shapes(self):
        env, run_git, second = self.scenario("merge")
        base = FakeApi(second).build_jobs()
        by_name = {job["name"]: job for job in base}
        shapes = {"empty": [],
                  "only the aggregator (the earlier single-job shape)": [by_name["check-hosted"]],
                  "extra job": base + [dict(by_name["check-root"], id=999, name="other")],
                  "removed check-fast executed": base[:-1] + [dict(by_name["check-hosted"], name="check-fast")]}
        for name in FakeApi.NAMES:
            shapes[f"{name} missing"] = [job for job in base if job["name"] != name]
            shapes[f"{name} twice"] = base + [dict(by_name[name], id=990)]
        for label, jobs in shapes.items():
            with self.subTest(label=label):
                api = FakeApi(second)
                api.jobs = copy.deepcopy(jobs)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_the_job_listing_must_be_complete_and_well_formed(self):
        env, run_git, second = self.scenario("merge")
        for label, total in {"more jobs exist": 7, "fewer jobs exist": 4, "no count": None, "text count": "5"}.items():
            with self.subTest(label=label):
                api = FakeApi(second)
                api.jobs_total = total if total is not None else -1
                if total is None:
                    api.jobs = api.build_jobs()
                    api.jobs_total = 0
                with self.assertRaisesRegex(skip.Full, "job listing incomplete"):
                    skip.decide(env, run_git, api)
        api = FakeApi(second)
        api.jobs = FakeApi(second).build_jobs() + ["not a job"]
        api.jobs_total = 7
        with self.assertRaisesRegex(skip.Full, "job listing malformed"):
            skip.decide(env, run_git, api)

    def test_skipped_jobs_are_never_full_evidence(self):
        env, run_git, second = self.scenario("merge")
        work = list(FakeApi.WORK)
        for skipped in ([work[0]], [work[1]], [work[2]], work[:2], work[1:], ["check-plan"], ["check-hosted"],
                        ["check-plan", "check-hosted"], ["check-plan"] + work):
            with self.subTest(skipped=skipped):
                api = FakeApi(second)
                for name in skipped:
                    api.jobs_changes[name] = dict(conclusion="skipped")
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_a_job_copied_from_an_earlier_attempt_is_not_evidence(self):
        # A partial re-run copies the green jobs of the earlier attempt with new IDs and the old start time.
        env, run_git, second = self.scenario("merge")
        for started in ("2026-11-08T11:59:59Z", "2026-11-07T12:00:10Z"):
            for name in FakeApi.NAMES:
                with self.subTest(job=name, started=started):
                    api = FakeApi(second)
                    api.jobs_changes[name] = dict(started_at=started)
                    with self.assertRaisesRegex(skip.Full, "earlier attempt"):
                        skip.decide(env, run_git, api)
        control = FakeApi(second)       # a job that starts at the very second of the run start is accepted
        for name in FakeApi.NAMES:
            control.jobs_changes[name] = dict(started_at="2026-11-08T12:00:00Z")
        self.assertTrue(skip.decide(env, run_git, control)[0])
        for bad in (None, "", "yesterday", 5):
            with self.subTest(start=bad):
                for target in ("run", "job"):
                    api = FakeApi(second)
                    if target == "run":
                        api.run["run_started_at"] = bad
                    else:
                        api.jobs_changes["check-root"] = dict(started_at=bad)
                    with self.assertRaises(skip.Full):
                        skip.decide(env, run_git, api)

    # ELZ-059: the same-repository pull_request run is the merge evidence; the dispatch run is the fallback.
    PR_RUN = dict(event="pull_request", head_repository={"full_name": "balungpisah/elzoo"})

    def test_pull_request_run_is_accepted_as_evidence(self):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        api.run.update(self.PR_RUN)
        skipped, _reason, details = skip.decide(env, run_git, api)
        self.assertTrue(skipped)
        self.assertEqual(900, details["run"])

    def test_pull_request_run_needs_a_head_that_holds_the_first_parent(self):
        # A pull_request run tests the merge of the head with its base. When main moved past the head, the
        # tested tree can differ from the head tree, so only a head that holds the first parent can skip.
        # "same-change": the merge tree equals the head tree, so only this rule refuses the skip.
        env, run_git, second = self.scenario("same-change")
        api = FakeApi(second)
        api.run.update(self.PR_RUN)
        with self.assertRaisesRegex(skip.Full, "another tree"):
            skip.decide(env, run_git, api)

    def test_dispatch_run_does_not_need_the_ancestor_of_the_first_parent(self):
        # A dispatch run tests the head itself, so the tree of the head is the tested tree.
        (verdict, _reason, _details), _api, _second = self.decide("same-change")
        self.assertTrue(verdict)

    def test_pull_request_run_from_a_fork_or_without_repository_is_refused(self):
        for repo in ({"full_name": "someone/elzoo"}, {"full_name": "balungpisah/elzoo-fork"}, {}, None, "balungpisah/elzoo"):
            with self.subTest(repo=repo):
                env, run_git, second = self.scenario("merge")
                api = FakeApi(second)
                api.run.update(event="pull_request", head_repository=repo)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_other_events_are_not_evidence(self):
        for event in ("push", "schedule", "workflow_run", "pull_request_target", "issue_comment", "", None):
            with self.subTest(event=event):
                env, run_git, second = self.scenario("merge")
                api = FakeApi(second)
                api.run.update(event=event, head_repository={"full_name": "balungpisah/elzoo"})
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_the_latest_run_decides_across_events(self):
        env, run_git, second = self.scenario("merge")
        for newer in (dict(conclusion="failure"), dict(conclusion="cancelled"), dict(status="in_progress", conclusion=None)):
            with self.subTest(newer=newer):
                api = FakeApi(second)
                older = dict(api.run)
                api.runs = [older, dict(api.run, id=950, **self.PR_RUN, **newer)]
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)
        api = FakeApi(second)
        api.runs = [dict(api.run, id=950, **self.PR_RUN, conclusion="failure"), dict(api.run, id=960)]
        api.job["run_id"] = 960
        api.run["id"] = 960
        skipped, _reason, details = skip.decide(env, run_git, api)  # a newer dispatch success after a failed pull_request run
        self.assertTrue(skipped)
        self.assertEqual(960, details["run"])

    def test_listing_is_not_filtered_by_event_on_the_server(self):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        skip.decide(env, run_git, api)
        listing = next(c for c in api.calls if "workflows/" in c and "runs?" in c)
        self.assertIn(f"head_sha={second}", listing)
        self.assertNotIn("event=", listing)

    def test_log_markers(self):
        env, run_git, second = self.scenario("merge")
        stamp = FakeApi.STAMP
        bad_for = {
            "check-hosted": ["", "ELZOO AFFECTED CHECK PASSED", "echo 'ELZOO CHECK PASSED'",
                             "ELZOO CHECK PASSED\nELZOO AFFECTED CHECK PASSED (not full consumer acceptance)",
                             "ELZOO CHECK PASSED but not really", "ELZOO PUSH CHECK SKIPPED (identical tree)"],
            "check-plan": ["", "ELZOO PLAN: run=false skip=false docs_only=false", "ELZOO PLAN: run=true",
                           "echo 'ELZOO PLAN: run=true skip=false docs_only=false'"],
        }
        for name, marker in FakeApi.WORK.items():
            bad_for[name] = ["", "ELZOO CHECK PASSED", f"echo '{marker}'", f"{marker} but not really",
                             f"{marker}\nELZOO AFFECTED CHECK PASSED (not full consumer acceptance)",
                             *[other for other in FakeApi.WORK.values() if other != marker]]
        for name, logs in bad_for.items():
            for log in logs:
                with self.subTest(job=name, log=log):
                    api = FakeApi(second)
                    api.logs_by_job[name] = log
                    with self.assertRaisesRegex(skip.Full, "marker|plan did not say run=true"):
                        skip.decide(env, run_git, api)
        # an affected-mode marker in the plan log of a full run
        api = FakeApi(second)
        api.logs_by_job["check-plan"] = stamp + "ELZOO PLAN: run=true skip=false docs_only=false\n" + stamp + "ELZOO AFFECTED CHECK PASSED (not full)\n"
        with self.assertRaisesRegex(skip.Full, "affected-mode marker is present"):
            skip.decide(env, run_git, api)
        # a docs-only marker in the plan log of a full run
        api = FakeApi(second)
        api.logs_by_job["check-plan"] = stamp + "ELZOO PLAN: run=true skip=false docs_only=false\n" + stamp + "ELZOO DOCS-ONLY CHECK PASSED\n"
        with self.assertRaisesRegex(skip.Full, "docs-only marker present in a full run"):
            skip.decide(env, run_git, api)

    def test_run_that_changes_while_reading_is_refused(self):
        env, run_git, second = self.scenario("merge")
        for reread in ({"run_attempt": 2}, {"conclusion": "failure"}, {"status": "in_progress"}, {"id": 1}):
            with self.subTest(reread=reread):
                api = FakeApi(second)
                api.reread = reread
                with self.assertRaisesRegex(skip.Full, "changed while reading"):
                    skip.decide(env, run_git, api)

    def test_every_api_failure_runs_the_full_check(self):
        env, run_git, second = self.scenario("merge")
        for part in ("workflows/symbolic-check.yml/runs", "/attempts/", "/logs", "actions/runs/900"):
            with self.subTest(part=part):
                api = FakeApi(second)
                api.fail = part
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_main_prints_skip_true_only_after_every_check_and_writes_the_output(self):
        env, run_git, second = self.scenario("merge")
        output = pathlib.Path(self.fresh_dir()) / "github_output"
        env["GITHUB_OUTPUT"] = str(output)
        lines = []
        skip.main(env, run_git, FakeApi(second), out=lines.append)
        self.assertEqual("skip=true\n", output.read_text())
        self.assertTrue(lines[0].startswith("ELZOO PUSH CHECK SKIPPED (identical tree; exact-head full run passed):"))
        self.assertIn("run=900 jobs=check-plan:901,check-root:902,check-consumers-db:903,check-consumers:904,check-hosted:905", lines[0])
        self.assertNotIn("ELZOO CHECK PASSED", lines[0])  # the success marker stays reserved for a run of mix check

    def test_main_never_fails_and_prints_skip_false_on_any_error(self):
        env, run_git, second = self.scenario("merge")
        output = pathlib.Path(self.fresh_dir()) / "github_output"
        env["GITHUB_OUTPUT"] = str(output)

        class Exploding(FakeApi):
            def json(self, path):
                raise RuntimeError("boom")
        lines = []
        self.assertEqual(0, skip.main(env, run_git, Exploding(second), out=lines.append))
        self.assertEqual("skip=false\n", output.read_text())
        self.assertIn("RuntimeError: boom", lines[0])
        self.assertTrue(lines[0].startswith("ELZOO PUSH CHECK DECISION: full check runs"))

    def test_main_prints_skip_false_when_git_fails(self):
        env, _run_git, second = self.scenario("merge")
        output = pathlib.Path(self.fresh_dir()) / "github_output"
        env["GITHUB_OUTPUT"] = str(output)

        def broken_git(*argv):
            raise skip.Full("git failed")
        skip.main(env, broken_git, FakeApi(second), out=lambda text: None)
        self.assertEqual("skip=false\n", output.read_text())


class HttpTest(unittest.TestCase):
    def test_log_redirect_does_not_carry_the_token_and_refuses_foreign_hosts(self):
        seen = []

        def get(url, headers):
            seen.append((url, dict(headers)))
            if url.startswith(skip.API_ROOT):
                return 302, {"Location": "https://release-assets.githubusercontent.com/x?sig=a%2Bb"}, b""
            return 200, {}, b"ELZOO CHECK PASSED\n"
        api = skip.Api("balungpisah/elzoo", "secret-token", get=get)
        self.assertEqual("ELZOO CHECK PASSED\n", api.text("actions/jobs/1/logs"))
        self.assertEqual("Bearer secret-token", seen[0][1]["Authorization"])
        self.assertNotIn("Authorization", seen[1][1])
        for location in ("https://evil.example/x", "http://github.com/x", "https://github.com@evil.example/x",
                         "https://evilgithubusercontent.com/x", ""):
            with self.subTest(location=location):
                api = skip.Api("balungpisah/elzoo", "secret-token",
                               get=lambda url, headers, loc=location: (302, {"Location": loc}, b""))
                with self.assertRaisesRegex(skip.Full, "unexpected host"):
                    api.text("actions/jobs/1/logs")

    def test_non_200_answers_and_bad_json_are_a_reason_for_a_full_run(self):
        for status in (401, 403, 404, 429, 500, 502, 504):
            with self.subTest(status=status):
                api = skip.Api("balungpisah/elzoo", "t", get=lambda url, headers, s=status: (s, {}, b"{}"))
                with self.assertRaisesRegex(skip.Full, f"HTTP {status}"):
                    api.json("actions/runs/1")
        api = skip.Api("balungpisah/elzoo", "t", get=lambda url, headers: (200, {}, b"<html>"))
        with self.assertRaisesRegex(skip.Full, "invalid JSON"):
            api.json("actions/runs/1")

    def test_requests_use_the_job_token_only_for_the_api_host(self):
        seen = []
        api = skip.Api("balungpisah/elzoo", "t", get=lambda url, headers: seen.append((url, headers)) or (200, {}, b"{}"))
        api.json("actions/runs/1")
        self.assertEqual("https://api.github.com/repos/balungpisah/elzoo/actions/runs/1", seen[0][0])

    def test_redirect_hosts_are_parsed_strictly(self):
        for location in ("https://evilgithubusercontent.com/x", "https://github.com:8443/x", "https://github.com@e.x/",
                         "https://exaмple.githubusercontent.com/x", "https://github.com.evil.example/x",
                         "https://github.com\\@evil.example/x", "https://evil%2f.github.com/x", "ftp://github.com/x"):
            with self.subTest(location=location):
                self.assertFalse(skip.redirect_allowed(location))
        self.assertTrue(skip.redirect_allowed("https://objects.githubusercontent.com/a?x=1%3A2"))
        # the real job-log redirect target (shape observed 2026-11-08), and look-alikes of it
        real = "https://productionresultssa9.blob.core.windows.net/actions-results/e77d/workflow-job-run-9f8e/logs/job/job-logs.txt?sv=2025&sig=a%2Bb"
        self.assertTrue(skip.redirect_allowed(real))
        for location in ("https://productionresultssa.blob.core.windows.net/actions-results/x",
                         "https://evilproductionresultssa9.blob.core.windows.net/actions-results/x",
                         "https://productionresultssa9.blob.core.windows.net.evil.example/actions-results/x",
                         "https://productionresultssa9.blob.core.windows.net/other-container/x",
                         "https://myaccount.blob.core.windows.net/actions-results/x",
                         "https://productionresultssa9.blob.core.windows.net:8443/actions-results/x",
                         "http://productionresultssa9.blob.core.windows.net/actions-results/x"):
            with self.subTest(location=location):
                self.assertFalse(skip.redirect_allowed(location))


class SmallGateDecision(unittest.TestCase):
    """Small gate: a run in which check-piece ran (mix check --piece) is never the evidence of a push run on main."""

    PR_RUN = dict(event="pull_request", head_repository={"full_name": "balungpisah/elzoo"})

    def scenario(self, name):
        path = tempfile.mkdtemp(prefix="elzoo-skip-piece-")
        self.addCleanup(shutil.rmtree, path, True)
        repo, head, second = make_repo(path, name)
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": head,
               "GITHUB_REPOSITORY": "balungpisah/elzoo", "GITHUB_TOKEN": "token"}
        return env, (lambda *argv: sh(repo, *argv)), second

    def piece_api(self, second, **run):
        api = FakeApi(second)
        api.run.update(self.PR_RUN, **run)
        api.piece = True
        return api

    def test_a_small_gate_run_never_skips_the_push_run(self):
        # "merge" is a code change, "docs" a documentation change: the small-gate shape refuses before the
        # classification of the merge is read, so neither one can skip on it.
        for name in ("merge", "docs", "same-change"):
            with self.subTest(name=name):
                env, run_git, second = self.scenario(name)
                api = self.piece_api(second)
                if name == "same-change":
                    api.run.update(event="workflow_dispatch")
                with self.assertRaisesRegex(skip.Full, "small-gate"):
                    skip.decide(env, run_git, api)

    def test_main_prints_skip_false_for_a_small_gate_run(self):
        env, run_git, second = self.scenario("merge")
        lines = []
        out = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-skip-piece-out-"))
        self.addCleanup(shutil.rmtree, out, True)
        env["GITHUB_OUTPUT"] = str(out / "output")
        skip.main(env, run_git, self.piece_api(second), out=lines.append)
        self.assertIn("skip=false", (out / "output").read_text())
        self.assertTrue(any("small-gate" in line for line in lines), lines)

    def test_a_full_run_in_which_check_piece_also_ran_is_not_evidence(self):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        api.run.update(self.PR_RUN)
        gate = {"name": "Verify the GitHub-hosted runner", "conclusion": "success"}
        api.jobs_changes["check-piece"] = dict(conclusion="success", steps=[
            gate, {"name": "Run the small gate", "conclusion": "success"}])
        with self.assertRaisesRegex(skip.Full, "small-gate"):
            skip.decide(env, run_git, api)

    def test_the_piece_job_must_be_listed_once(self):
        # A run of the five-job workflow (before the small gate) or a listing with check-piece twice is no evidence.
        env, run_git, second = self.scenario("merge")
        base = FakeApi(second).build_jobs()
        piece = [job for job in base if job["name"] == "check-piece"][0]
        for label, jobs in {"check-piece missing": [job for job in base if job["name"] != "check-piece"],
                            "check-piece twice": base + [dict(piece, id=990)]}.items():
            with self.subTest(label=label):
                api = FakeApi(second)
                api.jobs = copy.deepcopy(jobs)
                with self.assertRaisesRegex(skip.Full, "six backend jobs"):
                    skip.decide(env, run_git, api)

    def test_a_skipped_piece_job_keeps_the_full_run_valid(self):
        # Positive control for the rule above: the same full run with check-piece skipped skips the push run.
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        api.run.update(self.PR_RUN)
        verdict, _reason, details = skip.decide(env, run_git, api)
        self.assertTrue(verdict)
        self.assertNotIn("check-piece", details["jobs"])


class DocsOnlyDecision(unittest.TestCase):
    """ELZ-071: a documentation-only merge is skipped on the short check of its pull_request run."""

    MARKER = ("2026-11-09T05:00:00.0000000Z ELZOO DOCS-ONLY CHECK PASSED\n"
              "2026-11-09T05:00:00.0000000Z ELZOO PLAN: run=false skip=false docs_only=true\n")

    def scenario(self, name):
        path = tempfile.mkdtemp(prefix="elzoo-skip-docs-")
        self.addCleanup(shutil.rmtree, path, True)
        repo, head, second = make_repo(path, name)
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": head,
               "GITHUB_REPOSITORY": "balungpisah/elzoo", "GITHUB_TOKEN": "token"}
        return env, (lambda *argv: sh(repo, *argv)), second

    def api(self, second, steps=None, log=None, event="pull_request", docs=True, **run):
        """`steps` are the plan job's steps after the identity step; `log` is the plan job's log."""
        api = FakeApi(second)
        api.run.update(event=event, head_repository={"full_name": "balungpisah/elzoo"}, **run)
        api.docs = docs
        api.plan_steps = steps
        if log is not None:
            api.logs_by_job["check-plan"] = log
        return api

    def decide(self, name="docs", **kwargs):
        env, run_git, second = self.scenario(name)
        return skip.decide(env, run_git, self.api(second, **kwargs)), second

    def refuses(self, pattern, name="docs", **kwargs):
        env, run_git, second = self.scenario(name)
        with self.assertRaisesRegex(skip.Full, pattern):
            skip.decide(env, run_git, self.api(second, **kwargs))

    def test_a_documentation_merge_with_a_passed_short_check_skips(self):
        (verdict, reason, details), second = self.decide()
        self.assertTrue(verdict)
        self.assertRegex(reason, "documentation-only change")
        self.assertEqual(("docs-only", second, 900), (details["mode"], details["second_parent"], details["run"]))
        self.assertIn("check-plan:901", details["jobs"])

    def test_the_log_line_names_the_short_check(self):
        env, run_git, second = self.scenario("docs")
        lines = []
        skip.main(env, run_git, self.api(second), out=lines.append)
        self.assertEqual(1, len(lines))
        self.assertTrue(lines[0].startswith("ELZOO PUSH CHECK SKIPPED (identical tree; exact-head docs-only check passed): "))
        self.assertIn(f"second_parent={second} ", lines[0])
        env, run_git, second = self.scenario("merge")
        full = FakeApi(second)
        lines = []
        skip.main(env, run_git, full, out=lines.append)
        self.assertTrue(lines[0].startswith("ELZOO PUSH CHECK SKIPPED (identical tree; exact-head full run passed): "))

    def test_a_code_change_in_the_merge_needs_the_full_marker(self):
        for name in ("docs-code", "docs-consuming", "docs-ledger", "docs-rename-out", "merge"):
            with self.subTest(name=name):
                self.refuses("not documentation only", name=name)

    def test_the_short_check_is_evidence_only_on_a_pull_request_run(self):
        for event in ("workflow_dispatch", "push", "schedule", "", None):
            with self.subTest(event=event):
                self.refuses("only on a pull_request run|no queue run", event=event)

    def test_a_fork_pull_request_run_is_never_evidence(self):
        for repo in ({"full_name": "someone/elzoo"}, {}, None, "balungpisah/elzoo"):
            with self.subTest(repo=repo):
                env, run_git, second = self.scenario("docs")
                api = self.api(second)
                api.run["head_repository"] = repo
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_every_step_of_the_short_check_must_be_green_once(self):
        def shape(classify="success", docs="success", extra=()):
            return ([{"name": "Classify the change", "conclusion": classify}] if classify else []) + \
                   ([{"name": "Docs-only check", "conclusion": docs}] if docs else []) + list(extra)
        bad = {"docs-only check failed": shape(docs="failure"), "docs-only check skipped": shape(docs="skipped"),
               "docs-only check missing": shape(docs=None), "classify failed": shape(classify="failure"),
               "classify skipped": shape(classify="skipped"), "classify missing": shape(classify=None),
               "classify twice": shape(extra=[{"name": "Classify the change", "conclusion": "success"}]),
               "docs-only check twice": shape(extra=[{"name": "Docs-only check", "conclusion": "success"}])}
        for label, steps in bad.items():
            with self.subTest(label=label):
                self.refuses("classification step|docs-only check step", steps=steps)

    def test_a_work_job_that_ran_is_not_a_short_check(self):
        # In a docs-only run the three work jobs are skipped; one executed job makes the run neither shape.
        for name in FakeApi.WORK:
            with self.subTest(job=name):
                env, run_git, second = self.scenario("docs")
                api = self.api(second)
                api.jobs_changes[name] = dict(conclusion="success", steps=[
                    {"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                    {"name": "Run mix check", "conclusion": "success"}])
                with self.assertRaisesRegex(skip.Full, "partly skipped"):
                    skip.decide(env, run_git, api)

    def test_the_short_check_needs_the_plan_line_and_a_skipped_work_set(self):
        stamp = FakeApi.STAMP
        marker = stamp + "ELZOO DOCS-ONLY CHECK PASSED\n"
        for label, log in {"plan says run=true": marker + stamp + "ELZOO PLAN: run=true skip=false docs_only=true\n",
                           "plan says docs_only=false": marker + stamp + "ELZOO PLAN: run=false skip=false docs_only=false\n",
                           "no plan line": marker}.items():
            with self.subTest(label=label):
                self.refuses("docs-only success marker or plan line missing", log=log)
        for name in ("check-hosted",):
            env, run_git, second = self.scenario("docs")
            api = self.api(second)
            api.logs_by_job[name] = stamp + "ELZOO CHECK PASSED\n"
            with self.assertRaisesRegex(skip.Full, "full or affected-mode marker"):
                skip.decide(env, run_git, api)

    def test_the_marker_must_be_a_line_of_its_own_and_alone(self):
        marker = "ELZOO DOCS-ONLY CHECK PASSED"
        plan = "2026-11-09T05:00:00.0000000Z ELZOO PLAN: run=false skip=false docs_only=true\n"
        for label, log in {"timestamp": f"2026-11-09T05:00:00.0000000Z {marker}\n{plan}", "bare": f"{marker}\n{plan}",
                           "crlf": f"{marker}\r\n{plan}"}.items():
            with self.subTest(label=label):
                (verdict, _reason, _details), _second = self.decide(log=log)
                self.assertTrue(verdict)
        for label, log in {"none": plan, "other": f"all done\n{plan}", "echo": f'echo "{marker}"\n{plan}',
                           "prefix": f"x {marker}\n{plan}", "suffix": f"{marker} nope\n{plan}",
                           "full marker only": f"ELZOO CHECK PASSED\n{plan}"}.items():
            with self.subTest(label=label):
                self.refuses("docs-only success marker or plan line missing", log=log)
        for label, log in {"both": f"{marker}\n{plan}ELZOO CHECK PASSED\n",
                           "affected": f"{marker}\n{plan}ELZOO AFFECTED CHECK PASSED (not full)\n"}.items():
            with self.subTest(label=label):
                self.refuses("full or affected-mode marker", log=log)

    # --- review of PR #135, finding 1: the short check must not hide a red or unfinished main --------------------
    def first_parent_refuses(self, runs=None, **changes):
        """`runs` is a list, or a function of the first parent's SHA (the SHA exists only inside the scenario's own
        repository, so the fixtures must be built from it: a fixture with another SHA would refuse for the wrong reason)."""
        env, run_git, second = self.scenario("docs")
        api = self.api(second)
        api.first_parent_runs = runs(run_git("rev-parse", "HEAD^1")) if callable(runs) else runs
        for name, value in changes.items():
            setattr(api, name, value)
        with self.assertRaisesRegex(skip.Full, "push run of the first parent"):
            skip.decide(env, run_git, api)

    def push_run(self, run_id=800, **changes):
        run = dict(id=run_id, event="push", head_branch="main", head_sha=None, status="completed", conclusion="success",
                   path=".github/workflows/symbolic-check.yml")
        run.update(changes)
        return run

    def test_the_short_check_needs_a_first_parent_whose_push_run_completed_with_success(self):
        pr = self.push_run
        env, run_git, second = self.scenario("docs")
        self.assertTrue(skip.decide(env, run_git, self.api(second))[0])      # the control: the default run is accepted
        control = self.api(second)
        control.first_parent_runs = [pr(head_sha=run_git("rev-parse", "HEAD^1"))]
        self.assertTrue(skip.decide(env, run_git, control)[0])               # ... and so is one built from the real SHA
        for label, runs in {
                "red": lambda f: [pr(conclusion="failure", head_sha=f)],
                "cancelled": lambda f: [pr(conclusion="cancelled", head_sha=f)],
                "timed out": lambda f: [pr(conclusion="timed_out", head_sha=f)],
                "skipped": lambda f: [pr(conclusion="skipped", head_sha=f)],
                "in progress": lambda f: [pr(status="in_progress", conclusion=None, head_sha=f)],
                "queued": lambda f: [pr(status="queued", conclusion=None, head_sha=f)],
                # Inconsistent data: a run that is not completed never counts, whatever its conclusion field says.
                "in progress with a conclusion": lambda f: [pr(status="in_progress", conclusion="success", head_sha=f)],
                "queued with a conclusion": lambda f: [pr(status="queued", conclusion="success", head_sha=f)],
                "no status": lambda f: [pr(status=None, conclusion="success", head_sha=f)],
                "no run": lambda f: [],
                "newest is red": lambda f: [pr(800, head_sha=f), pr(801, conclusion="failure", head_sha=f)],
                "newest is unfinished": lambda f: [pr(800, head_sha=f), pr(801, status="in_progress", conclusion=None, head_sha=f)],
                "another commit only": lambda f: [pr(head_sha="e" * 40)],
                "another branch only": lambda f: [pr(head_branch="task/ELZ-040", head_sha=f)],
                "another event only": lambda f: [pr(event="workflow_dispatch", head_sha=f)],
                "another workflow only": lambda f: [pr(path=".github/workflows/symbolic-gleam.yml", head_sha=f)],
                "odd id": lambda f: [pr("x", head_sha=f)],
                "odd entries": lambda f: [None, "x", 7, {}]}.items():
            with self.subTest(label=label):
                self.first_parent_refuses(runs)

    def test_the_newest_push_run_of_the_first_parent_decides(self):
        env, run_git, second = self.scenario("docs")
        first = run_git("rev-parse", "HEAD^1")
        api = self.api(second)
        api.first_parent_runs = [self.push_run(800, conclusion="failure", head_sha=first), self.push_run(801, head_sha=first)]
        self.assertTrue(skip.decide(env, run_git, api)[0])

    def test_a_failed_or_malformed_listing_of_the_first_parent_needs_the_full_check(self):
        self.first_parent_refuses(first_parent_error=True)
        for body in ({"workflow_runs": "x"}, {"workflow_runs": None}, {}, ["x"], "x"):
            with self.subTest(body=body):
                self.first_parent_refuses(first_parent_body=body)

    def test_the_first_parent_listing_asks_for_its_push_runs_by_commit(self):
        env, run_git, second = self.scenario("docs")
        api = self.api(second)
        skip.decide(env, run_git, api)
        first = run_git("rev-parse", "HEAD^1")
        listing = [c for c in api.calls if "event=push" in c]
        self.assertEqual(1, len(listing))
        self.assertIn(f"head_sha={first}", listing[0])
        self.assertIn("per_page=100", listing[0])

    def test_a_full_run_needs_no_push_run_of_the_first_parent(self):
        # The extra rule is for the short check only: a full run tested the code itself.
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        api.first_parent_runs = [self.push_run(conclusion="failure")]
        self.assertTrue(skip.decide(env, run_git, api)[0])
        self.assertEqual([], [c for c in api.calls if "event=push" in c])

    def test_a_full_run_still_skips_a_documentation_merge_too(self):
        (verdict, reason, details), _second = self.decide(docs=False)
        self.assertTrue(verdict)
        self.assertEqual("full", details["mode"])

    def test_the_other_evidence_rules_apply_to_the_short_check(self):
        for label, change in {"failed run": dict(conclusion="failure"), "unfinished": dict(status="in_progress", conclusion=None),
                              "cancelled": dict(conclusion="cancelled"), "another head": dict(head_sha="e" * 40),
                              "another path": dict(path=".github/workflows/other.yml"),
                              "task branch": dict(head_branch="feature/x")}.items():
            with self.subTest(label=label):
                self.refuses(".+", **change)

    def test_the_ancestor_rule_for_pull_request_runs_still_applies(self):
        # "same-change" has an identical tree but main moved past the head; that is no documentation change here,
        # and a pull_request run still needs a head that holds the first parent.
        self.refuses("another tree|not documentation only", name="same-change")

    def test_a_missing_classifier_means_the_full_check(self):
        original = skip.CLASSIFIER
        skip.CLASSIFIER = None
        try:
            self.refuses("not documentation only")
        finally:
            skip.CLASSIFIER = original

    def test_a_classifier_or_git_that_raises_means_the_full_check(self):
        env, run_git, second = self.scenario("docs")

        def failing(*argv):
            if "--raw" in argv:
                raise subprocess.CalledProcessError(128, "git")
            return run_git(*argv)
        with self.assertRaisesRegex(skip.Full, "not documentation only"):
            skip.decide(env, failing, self.api(second))
        self.assertFalse(skip.docs_only_merge(lambda *argv: "garbage", "a" * 40, "b" * 40))
        self.assertFalse(skip.docs_only_merge(lambda *argv: (_ for _ in ()).throw(OSError("x")), "a" * 40, "b" * 40))
        self.assertFalse(skip.docs_only_merge(lambda *argv: "", "a" * 40, "b" * 40))
        self.assertFalse(skip.docs_only_merge(run_git, "--output=x", "b" * 40))

    def test_the_decision_loads_the_classifier_next_to_itself(self):
        self.assertIsNotNone(skip.CLASSIFIER)
        self.assertEqual((ROOT / "scripts/ci-change-class.py").resolve(), pathlib.Path(skip.CLASSIFIER.__file__).resolve())

    def test_the_classification_asks_git_for_the_change_against_the_first_parent(self):
        env, run_git, second = self.scenario("docs")
        calls = []

        def spy(*argv):
            calls.append(argv)
            return run_git(*argv)
        skip.decide(env, spy, self.api(second))
        first = run_git("rev-parse", "HEAD^1")
        raw = [c for c in calls if "--raw" in c]
        self.assertEqual([("diff", "--raw", "-z", "--no-renames", "--no-abbrev", "--ignore-submodules=none", "--no-relative",
                           f"{first}...{env['GITHUB_SHA']}", "--")], raw)
        self.assertEqual(raw[0], tuple(skip.CLASSIFIER.diff_argv(first, env["GITHUB_SHA"])[1:]))


if __name__ == "__main__":
    unittest.main()
