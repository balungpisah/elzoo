#!/usr/bin/env python3
"""Negative controls for CI runner routing policy."""
import pathlib
import shutil
import subprocess
import tempfile
import os
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Optional overrides, used only to show new controls fail on an older guard.
GUARD = pathlib.Path(os.environ.get("ELZOO_CI_GUARD", ROOT / "scripts" / "check-ci-runners.py"))
WORKFLOWS = pathlib.Path(os.environ.get("ELZOO_CI_WORKFLOWS", ROOT / ".github" / "workflows"))
IMAGE = "ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852"


class RunnerPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        (self.root / ".github").mkdir()
        shutil.copytree(WORKFLOWS, self.root / ".github" / "workflows")

    def tearDown(self):
        self.temp.cleanup()

    def check(self, expected):
        result = subprocess.run(
            ["python3", str(GUARD)],
            cwd=self.root, capture_output=True, text=True, check=False
        )
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        return result

    def change(self, filename, old, new):
        path = self.root / ".github" / "workflows" / filename
        source = path.read_text()
        self.assertIn(old, source)
        path.write_text(source.replace(old, new, 1))

    def test_reviewed_routing_passes(self):
        self.check(0)

    def test_hosted_backend_rejected(self):
        self.change("symbolic-check.yml", "[self-hosted, linux, x64, elzoo, backend]", "ubuntu-latest")
        self.check(1)

    def test_unknown_machine_selector_rejected(self):
        self.change("symbolic-check.yml", "elzoo, backend]", "elzoo, backend, other-machine]")
        self.check(1)

    def test_branch_specific_candidate_route_rejected(self):
        self.change(
            "symbolic-check.yml",
            "runs-on: [self-hosted, linux, x64, elzoo, backend]",
            "runs-on: ${{ github.head_ref == 'task/ELZ-034' && fromJSON('[\"self-hosted\",\"ci-candidate\"]') || fromJSON('[\"self-hosted\",\"linux\",\"x64\",\"elzoo\",\"backend\"]') }}",
        )
        self.check(1)

    # ELZ-040 controls: triggers, quoted keys and container image digests.
    def test_pull_request_target_rejected(self):
        self.change("symbolic-check.yml", "\n  pull_request:\n", "\n  pull_request_target:\n")
        self.check(1)

    def test_gleam_pull_request_target_rejected(self):
        self.change("symbolic-gleam.yml", "\n  pull_request:\n", "\n  pull_request_target:\n")
        self.check(1)

    def test_added_pull_request_target_rejected(self):
        self.change("symbolic-check.yml", "\n  workflow_dispatch:\n",
                    "\n  workflow_dispatch:\n  pull_request_target:\n")
        self.check(1)

    def test_unapproved_trigger_rejected(self):
        self.change("symbolic-check.yml", "\n  workflow_dispatch:\n",
                    "\n  workflow_dispatch:\n  workflow_run:\n    workflows: [other]\n")
        self.check(1)

    def test_push_branch_filter_cannot_widen(self):
        self.change("symbolic-gleam.yml", "branches: [main]", "branches: ['**']")
        self.check(1)

    def test_quoted_on_key_rejected(self):
        self.change("symbolic-check.yml", "\non:\n", '\n"on":\n')
        self.check(1)

    def test_quoted_runs_on_job_rejected(self):
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(path.read_text() + '\n  "evil":\n    "runs-on": ubuntu-latest\n    steps:\n      - run: true\n')
        self.check(1)

    def test_container_image_without_digest_rejected(self):
        self.change("symbolic-check.yml", IMAGE, "ubuntu:latest")
        self.check(1)

    def test_gleam_container_image_without_digest_rejected(self):
        self.change("symbolic-gleam.yml", IMAGE, "ubuntu:24.04")
        self.check(1)

    def test_inline_container_image_rejected(self):
        self.change("symbolic-check.yml", "    container:\n      image: " + IMAGE, "    container: ubuntu:latest")
        self.check(1)

    def test_fork_pr_job_gate_cannot_be_removed(self):
        self.change(
            "symbolic-check.yml",
            "    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}",
            "    if: ${{ true }}",
        )
        self.check(1)

    def test_gleam_fork_pr_job_gate_cannot_be_removed(self):
        self.change(
            "symbolic-gleam.yml",
            "    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}",
            "    if: ${{ true }}",
        )
        self.check(1)

    def test_identity_gate_cannot_be_removed(self):
        self.change("symbolic-check.yml", "Verify approved backend runner", "Verify runner")
        self.check(1)

    def test_additional_ungated_backend_job_rejected(self):
        self.add_ungated_job("symbolic-check.yml")
        self.check(1)

    def test_additional_ungated_gleam_job_rejected(self):
        self.add_ungated_job("symbolic-gleam.yml")
        self.check(1)

    def test_extra_backend_job_header_rejected_independently(self):
        self.add_job_header_without_selector("symbolic-check.yml")
        self.assertIn("exactly one check job is required", self.check(1).stderr)

    def test_extra_gleam_job_header_rejected_independently(self):
        self.add_job_header_without_selector("symbolic-gleam.yml")
        self.assertIn("exactly one gleam job is required", self.check(1).stderr)

    def add_ungated_job(self, filename):
        path = self.root / ".github" / "workflows" / filename
        source = path.read_text()
        selector = next(line for line in source.splitlines() if line.strip().startswith("runs-on:"))
        path.write_text(source + f"\n  unreviewed:\n{selector}\n    steps:\n      - run: true\n")

    def add_job_header_without_selector(self, filename):
        path = self.root / ".github" / "workflows" / filename
        path.write_text(path.read_text() + "\n  unreviewed:\n    steps:\n      - run: true\n")

    def test_gleam_role_cannot_move(self):
        self.change("symbolic-gleam.yml", "symbolic, elzoo, gleam", "macbook-ubuntu, elzoo, backend")
        self.check(1)

    def test_unknown_workflow_rejected(self):
        (self.root / ".github" / "workflows" / "extra.yml").write_text("jobs: {}\n")
        self.check(1)

    def test_missing_workflow_rejected(self):
        (self.root / ".github" / "workflows" / "symbolic-gleam.yml").unlink()
        self.check(1)

    def test_reusable_workflow_rejected(self):
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(path.read_text() + "\n      - uses: owner/repo/.github/workflows/ci.yml@main\n")
        self.check(1)


    # ELZ-042 controls: flow-style jobs and required job containers.
    def append(self, filename, text):
        path = self.root / ".github" / "workflows" / filename
        path.write_text(path.read_text() + text)

    def test_flow_style_backend_job_rejected(self):
        self.append("symbolic-check.yml", "  evil: {runs-on: ubuntu-latest, steps: [{run: 'true'}]}\n")
        self.assertIn("jobs must be block-style mappings", self.check(1).stderr)

    def test_flow_style_gleam_job_rejected(self):
        self.append("symbolic-gleam.yml", "  evil: {runs-on: ubuntu-latest, steps: [{run: 'true'}]}\n")
        self.assertIn("jobs must be block-style mappings", self.check(1).stderr)

    def test_explicit_key_flow_job_rejected(self):
        self.append("symbolic-check.yml", "  ? evil\n  : {runs-on: ubuntu-latest, steps: [{run: 'true'}]}\n")
        self.assertIn("jobs must be block-style mappings", self.check(1).stderr)

    def test_backend_container_removed_rejected(self):
        self.change("symbolic-check.yml", "    container:\n      image: " + IMAGE + "\n", "")
        self.assertIn("must keep one container", self.check(1).stderr)

    def test_gleam_container_removed_rejected(self):
        self.change("symbolic-gleam.yml", "    container:\n      image: " + IMAGE + "\n", "")
        self.assertIn("must keep one container", self.check(1).stderr)

    def test_container_without_image_rejected(self):
        self.change("symbolic-check.yml", "      image: " + IMAGE + "\n", "      options: --cpus 2\n")
        self.assertIn("must keep one container", self.check(1).stderr)

    def test_container_outside_job_rejected(self):
        self.change("symbolic-gleam.yml", "    container:\n      image: " + IMAGE + "\n", "")
        self.change("symbolic-gleam.yml", "\njobs:\n", "\ndefaults:\n    container:\n      image: " + IMAGE + "\n\njobs:\n")
        self.assertIn("must keep one container", self.check(1).stderr)

    # Script text and comments are not YAML keys (ELZ-040 review finding 3).
    def test_run_script_text_and_comments_allowed(self):
        self.change(
            "symbolic-check.yml",
            "          free -h || true\n",
            "          free -h || true\n"
            "          cat > /tmp/daemon.json <<'JSON'\n"
            "          {\"registry-mirrors\": []}\n"
            "          \"debug\": false\n"
            "          JSON\n"
            "          image: not-a-container-key\n"
            "          echo pull_request_target is not used here\n",
        )
        self.change("symbolic-gleam.yml", "\njobs:\n", "\n# No pull_request_target trigger.\njobs:\n")
        self.check(0)

    def test_quoted_key_after_run_script_still_rejected(self):
        self.change("symbolic-check.yml", "          free -h || true\n",
                    "          free -h || true\n        \"env\": {A: b}\n")
        self.check(1)

    def test_image_after_run_script_still_rejected(self):
        self.change("symbolic-check.yml", "          free -h || true\n",
                    "          free -h || true\n    services:\n      db:\n        image: postgres:latest\n")
        self.check(1)

    def test_explicit_indent_scalar_text_still_checked(self):
        self.change("symbolic-check.yml", "          free -h || true\n",
                    "          free -h || true\n      - run: |2\n          \"x\": y\n")
        self.check(1)


    # ELZ-042 review (PR #74 comment 6705035217) reproducers and fail-closed forms.
    BACKEND_SELECTOR = "    runs-on: [self-hosted, linux, x64, elzoo, backend]\n"
    GLEAM_SELECTOR = "    runs-on: [self-hosted, linux, x64, symbolic, elzoo, gleam]\n"

    def test_review_quoted_continuation_then_flow_job_rejected(self):
        self.append("symbolic-check.yml", '    environment: "a\nx"\n'
                                          '  evil: {runs-on: ubuntu-latest, steps: [{run: "true"}]}\n')
        self.check(1)

    def test_review_gleam_quoted_continuation_then_flow_job_rejected(self):
        self.append("symbolic-gleam.yml", '    environment: "a\nx"\n'
                                          '  evil: {runs-on: ubuntu-latest, steps: [{run: "true"}]}\n')
        self.check(1)

    def test_review_escaped_quote_continuation_rejected(self):
        self.append("symbolic-check.yml", '    environment: "a\\"\nx"\n')
        self.assertIn("quoted scalars must close on the same line", self.check(1).stderr)

    def test_review_explicit_runs_on_key_with_decoy_rejected(self):
        self.change("symbolic-check.yml", self.BACKEND_SELECTOR,
                    "    concurrency: |\n  " + self.BACKEND_SELECTOR + "    ? runs-on\n    : ubuntu-latest\n")
        self.check(1)

    def test_review_gleam_explicit_runs_on_key_with_decoy_rejected(self):
        self.change("symbolic-gleam.yml", self.GLEAM_SELECTOR,
                    "    name: |\n  " + self.GLEAM_SELECTOR + "    ? runs-on\n    : ubuntu-latest\n")
        self.check(1)

    def test_review_alias_runs_on_key_with_decoy_rejected(self):
        self.change("symbolic-check.yml", self.BACKEND_SELECTOR,
                    "    concurrency: |\n  " + self.BACKEND_SELECTOR
                    + "    environment: &k runs-on\n    *k : ubuntu-latest\n")
        self.check(1)

    def test_review_sequence_item_block_scalar_does_not_hide_keys(self):
        self.change("symbolic-check.yml", "    steps:\n",
                    '    steps:\n      - name: |\n        "run": echo hidden quoted key\n')
        self.assertIn("quoted YAML keys", self.check(1).stderr)

    def test_review_merge_key_rejected(self):
        self.change("symbolic-check.yml", "    timeout-minutes: 90\n",
                    "    timeout-minutes: 90\n    <<: {runs-on: ubuntu-latest}\n")
        self.assertIn("merge keys", self.check(1).stderr)

    def test_tagged_key_rejected(self):
        self.change("symbolic-check.yml", "    timeout-minutes: 90\n",
                    "    timeout-minutes: 90\n    !!str runs-on: ubuntu-latest\n")
        self.check(1)

    def test_multi_line_flow_collection_rejected(self):
        self.change("symbolic-check.yml", "    timeout-minutes: 90\n",
                    "    timeout-minutes: 90\n    environment: {name: a,\n      url: b}\n")
        self.assertIn("flow collections must close on the same line", self.check(1).stderr)

    def test_top_level_key_after_jobs_rejected(self):
        self.append("symbolic-gleam.yml", "env:\n  A: b\n")
        self.assertIn("jobs: must be the last top-level key", self.check(1).stderr)

    def test_second_document_rejected(self):
        self.append("symbolic-check.yml", "---\njobs: {}\n")
        self.check(1)

    def test_selector_only_in_script_text_rejected(self):
        self.change("symbolic-check.yml", self.BACKEND_SELECTOR, "    concurrency: |\n  " + self.BACKEND_SELECTOR)
        self.check(1)


if __name__ == "__main__":
    unittest.main()
