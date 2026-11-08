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
    (repo / "b").write_text("b\n")
    sh(repo, "add", "b")
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
    """Answers the three JSON reads, the logs read and the run re-read from dictionaries."""

    def __init__(self, second):
        self.second = second
        self.calls = []
        self.run = dict(id=900, event="workflow_dispatch", head_sha=second, head_branch="task/ELZ-058",
                        path=".github/workflows/symbolic-check.yml", status="completed",
                        conclusion="success", run_attempt=1)
        self.listing_changes = {}
        self.runs = None
        self.job = dict(id=901, run_id=900, name="check-fast", head_sha=second, status="completed",
                        conclusion="success", runner_name="symbolic-elzoo",
                        steps=[{"name": "Run mix check", "conclusion": "success"}])
        self.skipped = dict(id=902, run_id=900, name="check-any", head_sha=second, status="completed",
                            conclusion="skipped", runner_name=None, steps=[])
        self.jobs = None
        self.log = "2026-11-08T12:00:00.0000000Z ELZOO CHECK PASSED\n"
        self.reread = {}
        self.fail = None

    def json(self, path):
        self.calls.append(path)
        if self.fail and self.fail in path:
            raise skip.Full(f"API {path} answered HTTP 500")
        if "/workflows/" in path or path.startswith("actions/workflows/"):
            runs = self.runs if self.runs is not None else [copy.deepcopy(self.run)]
            body = dict(total_count=len(runs), workflow_runs=runs)
            body.update(self.listing_changes)
            return body
        if "/attempts/" in path:
            jobs = self.jobs if self.jobs is not None else [copy.deepcopy(self.job), copy.deepcopy(self.skipped)]
            return dict(total_count=len(jobs), jobs=jobs)
        out = copy.deepcopy(self.run)
        out.update(self.reread)
        return out

    def text(self, path):
        self.calls.append(path)
        if self.fail and self.fail in path:
            raise skip.Full(f"API {path} answered HTTP 500")
        return self.log


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
        self.assertEqual((second, 900, 901, "symbolic-elzoo"),
                         (details["second_parent"], details["run"], details["job"], details["runner"]))
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
        cases = {
            "job not success": dict(conclusion="failure"),
            "job not completed": dict(status="in_progress"),
            "job other head": dict(head_sha="f" * 40),
            "job other run": dict(run_id=1),
            "job wrong name": dict(name="check"),
            "job on contabo": dict(runner_name="contabo-elzoo-1"),
            "job on unknown runner": dict(runner_name="github-hosted"),
            "job without runner": dict(runner_name=None),
            "no mix check step": dict(steps=[]),
            "mix check skipped": dict(steps=[{"name": "Run mix check", "conclusion": "skipped"}]),
            "mix check failed": dict(steps=[{"name": "Run mix check", "conclusion": "failure"}]),
            "mix check twice": dict(steps=[{"name": "Run mix check", "conclusion": "success"}] * 2),
        }
        for label, changes in cases.items():
            with self.subTest(label=label):
                env, run_git, second = self.scenario("merge")
                api = FakeApi(second)
                api.job.update(changes)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_job_list_shapes(self):
        env, run_git, second = self.scenario("merge")
        fast, other = FakeApi(second).job, FakeApi(second).skipped
        shapes = {
            "check-any executed": [fast, dict(other, conclusion="success")],
            "check-any failed": [fast, dict(other, conclusion="failure")],
            "two check-fast": [fast, dict(fast, id=999), other],
            "no check-fast": [other],
            "extra job": [fast, other, dict(other, id=903, name="other")],
        }
        for label, jobs in shapes.items():
            with self.subTest(label=label):
                api = FakeApi(second)
                api.jobs = copy.deepcopy(jobs)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    # ELZ-066: evidence from the hosted lane (check-hosted on a GitHub-hosted runner).
    def hosted_jobs(self, second, **changes):
        api = FakeApi(second)
        hosted = dict(api.job, id=903, name="check-hosted", runner_name="GitHub Actions 7",
                      runner_group_name="GitHub Actions", labels=["ubuntu-24.04"],
                      steps=[{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                             {"name": "Run mix check", "conclusion": "success"}])
        hosted.update(changes)
        return [dict(api.skipped, id=904, name="check-fast"), api.skipped, hosted]

    def test_hosted_lane_evidence_allows_the_skip(self):
        env, run_git, second = self.scenario("merge")
        api = FakeApi(second)
        api.jobs = self.hosted_jobs(second)
        skipped, _reason, details = skip.decide(env, run_git, api)
        self.assertTrue(skipped)
        self.assertEqual("GitHub Actions 7", details["runner"])

    def test_hosted_lane_evidence_rules(self):
        cases = {
            "other runner group": dict(runner_group_name="Default"),
            "no runner group": dict(runner_group_name=None),
            "other label": dict(labels=["ubuntu-latest"]),
            "extra label": dict(labels=["ubuntu-24.04", "extra"]),
            "self-hosted label": dict(labels=["self-hosted", "ubuntu-24.04"]),
            "no labels": dict(labels=None),
            "self-hosted runner name": dict(runner_name="symbolic-elzoo"),
            "short runner name": dict(runner_name="GitHub Actions"),
            "long runner name": dict(runner_name="GitHub Actions 7 extra"),
            "no runner name": dict(runner_name=None),
            "no identity step": dict(steps=[{"name": "Run mix check", "conclusion": "success"}]),
            "identity step skipped": dict(steps=[{"name": "Verify the GitHub-hosted runner", "conclusion": "skipped"},
                                                 {"name": "Run mix check", "conclusion": "success"}]),
            "identity step failed": dict(steps=[{"name": "Verify the GitHub-hosted runner", "conclusion": "failure"},
                                                {"name": "Run mix check", "conclusion": "success"}]),
            "mix check skipped": dict(steps=[{"name": "Verify the GitHub-hosted runner", "conclusion": "success"},
                                             {"name": "Run mix check", "conclusion": "skipped"}]),
            "job failed": dict(conclusion="failure"),
            "job other head": dict(head_sha="f" * 40),
            "job other run": dict(run_id=1),
        }
        for label, changes in cases.items():
            with self.subTest(label=label):
                env, run_git, second = self.scenario("merge")
                api = FakeApi(second)
                api.jobs = self.hosted_jobs(second, **changes)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_hosted_lane_job_list_shapes(self):
        env, run_git, second = self.scenario("merge")
        jobs = self.hosted_jobs(second)
        shapes = {
            "check-fast also executed": [dict(jobs[0], conclusion="success"), jobs[1], jobs[2]],
            "check-any executed": [jobs[0], dict(jobs[1], conclusion="success"), jobs[2]],
            "only check-any ran": [jobs[0], dict(jobs[1], conclusion="success"), dict(jobs[2], conclusion="skipped")],
            "no job ran": [jobs[0], jobs[1], dict(jobs[2], conclusion="skipped")],
            "two check-hosted": [jobs[0], jobs[1], jobs[2], dict(jobs[2], id=999)],
            "extra job": [jobs[0], jobs[1], jobs[2], dict(jobs[1], id=998, name="other")],
        }
        for label, shape in shapes.items():
            with self.subTest(label=label):
                api = FakeApi(second)
                api.jobs = copy.deepcopy(shape)
                with self.assertRaises(skip.Full):
                    skip.decide(env, run_git, api)

    def test_log_markers(self):
        env, run_git, second = self.scenario("merge")
        for log in ("", "ELZOO AFFECTED CHECK PASSED", "echo 'ELZOO CHECK PASSED'",
                    "ELZOO CHECK PASSED\nELZOO AFFECTED CHECK PASSED (not full consumer acceptance)",
                    "ELZOO CHECK PASSED but not really", "ELZOO PUSH CHECK SKIPPED (identical tree)"):
            with self.subTest(log=log):
                api = FakeApi(second)
                api.log = log
                with self.assertRaisesRegex(skip.Full, "marker"):
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
        self.assertIn("run=900 job=901 runner=symbolic-elzoo", lines[0])
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


if __name__ == "__main__":
    unittest.main()
