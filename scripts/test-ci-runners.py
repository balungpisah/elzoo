#!/usr/bin/env python3
"""Negative controls for CI runner routing policy."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class RunnerPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        (self.root / ".github").mkdir()
        shutil.copytree(ROOT / ".github" / "workflows", self.root / ".github" / "workflows")

    def tearDown(self):
        self.temp.cleanup()

    def check(self, expected):
        result = subprocess.run(
            ["python3", str(ROOT / "scripts" / "check-ci-runners.py")],
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
        self.change("symbolic-check.yml", '"self-hosted","linux","x64","elzoo","backend"', '"ubuntu-latest"')
        self.check(1)

    def test_unknown_machine_selector_rejected(self):
        self.change("symbolic-check.yml", '"macbook-ubuntu"', '"other-machine"')
        self.check(1)

    def test_fork_cannot_spoof_candidate_branch(self):
        self.change(
            "symbolic-check.yml",
            "github.event.pull_request.head.repo.full_name == github.repository && github.head_ref",
            "github.head_ref",
        )
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
