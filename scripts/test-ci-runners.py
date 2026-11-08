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

    def change_all(self, filename, old, new):
        path = self.root / ".github" / "workflows" / filename
        source = path.read_text()
        self.assertIn(old, source)
        path.write_text(source.replace(old, new))

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
        # ELZ-057: the backend fork-PR gate is now part of the check-fast if: line.
        self.change(
            "symbolic-check.yml",
            "    if: ${{ (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) || (github.event_name == 'workflow_dispatch' && inputs.tier == 'fast') }}",
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
        self.assertIn("exactly the jobs check-fast, check-any are required", self.check(1).stderr)

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
        # ELZ-057: apply to both backend jobs; their bodies must stay identical.
        self.change_all(
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


    # ELZ-043 controls: split cache actions and every other action stay SHA-pinned.
    CACHE_SHA = "0057852bfaa89a56745cba8c7296529d2fc39830"

    def test_tag_pinned_cache_save_rejected(self):
        self.change("symbolic-check.yml", "actions/cache/save@" + self.CACHE_SHA, "actions/cache/save@v4")
        self.assertIn("pinned by a full commit SHA", self.check(1).stderr)

    def test_branch_pinned_cache_restore_rejected(self):
        self.change("symbolic-check.yml", "actions/cache/restore@" + self.CACHE_SHA, "actions/cache/restore@main")
        self.assertIn("pinned by a full commit SHA", self.check(1).stderr)

    def test_short_sha_action_rejected(self):
        self.change("symbolic-gleam.yml", "actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020",
                    "actions/setup-node@49933ea")
        self.assertIn("pinned by a full commit SHA", self.check(1).stderr)

    def test_unpinned_added_action_rejected(self):
        self.append("symbolic-check.yml", "      - uses: actions/cache@v4\n")
        self.assertIn("pinned by a full commit SHA", self.check(1).stderr)

    def test_flow_mapping_unpinned_step_rejected(self):
        self.append("symbolic-check.yml", "      - { uses: actions/cache@v4 }\n")
        self.assertIn("flow mappings are outside", self.check(1).stderr)

    def test_flow_mapping_in_flow_sequence_rejected(self):
        self.append("symbolic-check.yml", "      - [ { uses: actions/cache@v4 } ]\n")
        self.assertIn("flow mappings are outside", self.check(1).stderr)

    # ELZ-043 re-review (comment 6706080840) controls.
    GATE_START = "      - name: Verify approved backend runner\n"
    GATE_END = "      - name: Report host load and memory context\n"

    def gate_text(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        start = source.index(self.GATE_START)
        return source[start:source.index(self.GATE_END, start)]

    def test_flow_sequence_step_mapping_rejected(self):
        self.append("symbolic-check.yml", "      - [ uses: actions/cache@main ]\n")
        self.assertIn("mappings inside flow sequences are outside", self.check(1).stderr)

    def test_one_line_steps_rejected(self):
        gate = self.gate_text()
        self.change("symbolic-check.yml", gate, "")
        self.change("symbolic-check.yml", "jobs:\n", "env:\n  NOTE: |\n" + gate + "\njobs:\n")
        self.change("symbolic-check.yml", "    steps:\n", "    steps: [ uses: docker://alpine:3 ]\n    old-steps:\n")
        stderr = self.check(1).stderr
        self.assertIn("mappings inside flow sequences are outside", stderr)
        self.assertIn("one block-style steps: list", stderr)

    def test_gate_only_in_block_scalar_rejected(self):
        gate = self.gate_text()
        self.change("symbolic-check.yml", gate, "")
        self.change("symbolic-check.yml", "jobs:\n", "env:\n  NOTE: |\n" + gate + "\njobs:\n")
        self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)

    def test_uses_plain_continuation_rejected(self):
        pinned = "actions/cache/restore@" + self.CACHE_SHA + " # v4.3.0\n"
        self.change("symbolic-check.yml", pinned, pinned + "          actions/cache@v4\n")
        self.assertIn("plain-scalar continuation lines are outside", self.check(1).stderr)

    # ELZ-043 third review (comment 6706162316): the gate step cannot be switched off.
    def test_gate_step_if_rejected(self):
        self.change("symbolic-check.yml", self.GATE_END,
                    "        if: ${{ github.run_id == 0 }}\n" + self.GATE_END)
        self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)

    def test_gate_step_continue_on_error_rejected(self):
        self.change("symbolic-check.yml", self.GATE_END, "        continue-on-error: true\n" + self.GATE_END)
        stderr = self.check(1).stderr
        self.assertIn("approved runner identity gate is missing or changed", stderr)
        self.assertIn("could disable the runner identity gate", stderr)

    def test_gate_step_shell_rejected(self):
        self.change("symbolic-check.yml", self.GATE_END, "        shell: cat {0}\n" + self.GATE_END)
        self.assertIn("could disable the runner identity gate", self.check(1).stderr)

    def test_job_defaults_shell_rejected(self):
        self.change("symbolic-check.yml", "    steps:\n", "    defaults:\n      run:\n        shell: cat {0}\n    steps:\n")
        self.assertIn("could disable the runner identity gate", self.check(1).stderr)

    def test_workflow_defaults_shell_rejected(self):
        self.change("symbolic-check.yml", "jobs:\n", "defaults:\n  run:\n    shell: cat {0}\n\njobs:\n")
        self.assertIn("could disable the runner identity gate", self.check(1).stderr)

    # ELZ-056: the Contabo VPS runner is admitted with its own ERL_FLAGS, and nothing else.
    CONTABO_CASE = """            contabo-elzoo-1)
              echo 'ERL_FLAGS=+S 4:4 +SDcpu 1 +SDio 1' >> "$GITHUB_ENV"
              ;;
"""

    def test_contabo_case_present_and_exact(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        self.assertIn(self.CONTABO_CASE, source)
        self.check(0)

    def test_contabo_case_removed_rejected(self):
        self.change("symbolic-check.yml", self.CONTABO_CASE, "")
        self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)

    def test_contabo_erl_flags_changed_rejected(self):
        self.change("symbolic-check.yml", "ERL_FLAGS=+S 4:4 +SDcpu 1 +SDio 1' >> \"$GITHUB_ENV\"",
                    "ERL_FLAGS=+S 8:8 +SDcpu 1 +SDio 1' >> \"$GITHUB_ENV\"")
        self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)

    def test_contabo_runner_name_changed_rejected(self):
        for name in ("contabo-elzoo-2", "contabo-elzoo-*", "contabo-*"):
            with self.subTest(name=name):
                self.change("symbolic-check.yml", "            contabo-elzoo-1)", "            " + name + ")")
                self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_additional_unlisted_runner_case_rejected(self):
        self.change("symbolic-check.yml", self.CONTABO_CASE,
                    self.CONTABO_CASE + "            other-runner) ;;\n")
        self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)

    def test_contabo_label_in_runs_on_rejected(self):
        # The candidate is not routed: adding its label to the selector must fail the guard.
        for selector in ("[self-hosted, linux, x64, elzoo, backend, contabo]",
                         "[self-hosted, linux, x64, elzoo, contabo]",
                         "[self-hosted, linux, x64, elzoo, contabo, backend]"):
            with self.subTest(selector=selector):
                self.change("symbolic-check.yml", "[self-hosted, linux, x64, elzoo, backend]", selector)
                self.assertIn("every job must use", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    # ELZ-057: runner tiers. check-fast (pull_request and queue dispatch, tier fast) needs the fast
    # label; check-any (push and measurement dispatch, tier any) may use any backend runner.
    FAST_RUNS_ON = "    runs-on: [self-hosted, linux, x64, elzoo, backend, fast]"
    ANY_RUNS_ON = "    runs-on: [self-hosted, linux, x64, elzoo, backend]\n"
    FAST_IF = "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) || (github.event_name == 'workflow_dispatch' && inputs.tier == 'fast')"
    ANY_IF = "github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.tier == 'any')"

    def test_two_tier_jobs_present_and_pinned(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        self.assertEqual(1, source.count(self.FAST_RUNS_ON))
        self.assertEqual(1, source.count(self.ANY_RUNS_ON))
        self.assertIn("  check-fast:\n", source)
        self.assertIn("  check-any:\n", source)
        self.check(0)

    def test_fast_job_without_fast_label_rejected(self):
        self.change("symbolic-check.yml", self.FAST_RUNS_ON, self.ANY_RUNS_ON.rstrip("\n"))
        self.assertIn("every job must use", self.check(1).stderr)

    def test_any_job_with_fast_label_rejected(self):
        self.change("symbolic-check.yml", self.ANY_RUNS_ON, self.FAST_RUNS_ON + "\n")
        self.assertIn("every job must use", self.check(1).stderr)

    def test_contabo_label_in_either_selector_rejected(self):
        for old, new in ((self.FAST_RUNS_ON, "    runs-on: [self-hosted, linux, x64, elzoo, backend, fast, contabo]"),
                         (self.ANY_RUNS_ON, "    runs-on: [self-hosted, linux, x64, elzoo, backend, contabo]\n")):
            with self.subTest(selector=new):
                self.change("symbolic-check.yml", old, new)
                self.assertIn("every job must use", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_fast_job_cannot_run_for_tier_any(self):
        self.change("symbolic-check.yml", "inputs.tier == 'fast'", "inputs.tier == 'any'")
        self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)

    def test_fast_job_cannot_drop_fork_pr_gate(self):
        self.change("symbolic-check.yml", "github.event.pull_request.head.repo.full_name == github.repository", "true")
        self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)

    def test_any_job_cannot_run_for_pull_request(self):
        self.change("symbolic-check.yml", "github.event_name == 'push' || (",
                    "github.event_name == 'push' || github.event_name == 'pull_request' || (")
        self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)

    def test_any_job_cannot_run_for_tier_fast(self):
        self.change("symbolic-check.yml", "inputs.tier == 'any'", "inputs.tier == 'fast'")
        self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)

    def test_tier_input_cannot_change(self):
        for old, new in (("        default: fast\n", "        default: any\n"),
                         ("        options: [fast, any]\n", "        options: [fast, any, other]\n"),
                         ("        type: choice\n", "        type: string\n"),
                         ("      tier:\n", "      tier:\n        required: false\n")):
            with self.subTest(change=new):
                self.change("symbolic-check.yml", old, new)
                self.assertIn("triggers must be exactly", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_extra_dispatch_input_rejected(self):
        self.change("symbolic-check.yml", "        default: fast\n",
                    "        default: fast\n      runner:\n        type: string\n")
        self.assertIn("triggers must be exactly", self.check(1).stderr)

    def test_bodies_must_stay_identical(self):
        # A change in only one job (here ERL_FLAGS) is rejected even though each job is otherwise valid.
        self.change("symbolic-check.yml", "      ERL_FLAGS: '+S 4:4 +SDcpu 1 +SDio 1'\n",
                    "      ERL_FLAGS: '+S 8:8 +SDcpu 1 +SDio 1'\n")
        self.assertIn("identical bodies", self.check(1).stderr)

    def test_identity_gate_removed_from_one_job_rejected(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        # Rename only the second occurrence of the gate step name.
        first = source.index("Verify approved backend runner")
        second = source.index("Verify approved backend runner", first + 1)
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(source[:second] + "Verify runner" + source[second + len("Verify approved backend runner"):])
        stderr = self.check(1).stderr
        self.assertIn("approved runner identity gate is missing or changed (check-any)", stderr)

    def test_container_digest_removed_from_one_job_rejected(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        first = source.index(IMAGE)
        second = source.index(IMAGE, first + 1)
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(source[:second] + "ubuntu:24.04" + source[second + len(IMAGE):])
        self.assertIn("digest-pinned image", self.check(1).stderr)

    def test_jobs_must_keep_names_and_order(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(source.replace("  check-fast:\n", "  TMPNAME:\n").replace("  check-any:\n", "  check-fast:\n").replace("  TMPNAME:\n", "  check-any:\n"))
        self.assertIn("exactly the jobs check-fast, check-any are required, in this order", self.check(1).stderr)

    def test_backend_workflow_with_one_job_rejected(self):
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        source = path.read_text()
        path.write_text(source[:source.index("\n  check-any:\n")] + "\n")
        self.assertIn("exactly the jobs check-fast, check-any are required", self.check(1).stderr)

    def test_if_lines_cannot_be_swapped_between_jobs(self):
        # Swapping the two if: lines would send pull requests to check-any (any backend runner).
        self.change("symbolic-check.yml", self.FAST_IF, "TMP_SWAP")
        self.change("symbolic-check.yml", self.ANY_IF, self.FAST_IF)
        self.change("symbolic-check.yml", "TMP_SWAP", self.ANY_IF)
        self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)

    def test_pull_request_cannot_reach_any_tier_through_selector_text(self):
        # The if: lines are pinned exactly; there is no expression that routes pull requests to check-any.
        self.change("symbolic-check.yml", self.ANY_IF, self.ANY_IF + " || github.event_name == 'pull_request'")
        self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)


if __name__ == "__main__":
    unittest.main()
