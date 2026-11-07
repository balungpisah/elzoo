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


if __name__ == "__main__":
    unittest.main()
