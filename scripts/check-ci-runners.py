#!/usr/bin/env python3
"""Check the repository's CI workflows: two workflows, GitHub-hosted jobs only, in the reviewed shape."""
import pathlib
import re
import sys

# ELZ-069: the repository has one lane, GitHub-hosted. The self-hosted jobs, the lane variable ELZOO_CI_LANE and the
# tier input are gone; no workflow reads `vars`. Each workflow has exactly one job whose `if:` line is pinned here.
HOSTED_BACKEND_GATE = """    if: ${{ github.event_name == 'push' || github.event_name == 'workflow_dispatch' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) }}"""
HOSTED_GLEAM_GATE = """    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}"""
# A hosted job runs on the one GitHub-hosted label below, without a job container. Its header lines
# below runs-on are pinned exactly: token permissions, time limit, environment and the database service.
HOSTED_LABEL = "runs-on: ubuntu-24.04"
# ELZ-073: the backend workflow has five jobs. `check-plan` runs the guards, the classification and the push-skip
# decision once (it is the only job with `actions: read` and the decision token) and says through its output `run`
# whether the three work jobs run; the work jobs run the three parts of `mix check`; `check-hosted` (the name that
# branch protection requires) aggregates them and fails explicitly when a job it needs is not as planned.
HOSTED_PLAN_HEADER = """    permissions:
      actions: read
      contents: read
    timeout-minutes: 20
    outputs:
      run: ${{ steps.plan.outputs.run }}
    steps:""".split("\n")
HOSTED_AGG_HEADER = """    permissions:
      contents: read
    timeout-minutes: 10
    steps:""".split("\n")
WORK_IF = "    if: ${{ needs.check-plan.outputs.run == 'true' }}"
WORK_NEEDS = "    needs: check-plan"
AGG_IF = ("    if: ${{ always() && (" + HOSTED_BACKEND_GATE.split("${{ ", 1)[1].rsplit(" }}", 1)[0] + ") }}")
AGG_NEEDS = "    needs: [check-plan, check-root, check-consumers-db, check-consumers]"
WORK_JOBS = {"check-root": "root", "check-consumers-db": "consumers-db", "check-consumers": "consumers"}
HOSTED_BACKEND_HEADER = """    permissions:
      contents: read
    timeout-minutes: 120
    env:
      ImageOS: ubuntu24
      ERL_FLAGS: '+S 4:4 +SDcpu 1 +SDio 1'
    services:
      postgres:
        image: postgres:16-bookworm@sha256:5264710be20f409750ac6dc4e5706dcef929c87e241605463f0f9aefa932a8d9
        env:
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 20
    steps:""".split("\n")
HOSTED_GLEAM_HEADER = """    timeout-minutes: 30
    defaults:
      run:
        working-directory: spikes/gleam_ui
    env:
      ImageOS: ubuntu24
      ERL_FLAGS: '+S 2:2 +SDcpu 1 +SDio 1'
    steps:""".split("\n")
# Jobs in order: (name, exact lines below the job name (if:, needs:), exact runs-on line, exact hosted header lines
# below runs-on, role). A hosted job has the exact header and no job container. `actions: read` (ELZ-058, the
# decision step reads the exact-head run of the merged pull request head) is in the check-plan header only.
expected = {
    "symbolic-check.yml": [
        ("check-plan", [HOSTED_BACKEND_GATE], HOSTED_LABEL, HOSTED_PLAN_HEADER, "plan"),
        ("check-root", [WORK_IF, WORK_NEEDS], HOSTED_LABEL, HOSTED_BACKEND_HEADER, "work"),
        ("check-consumers-db", [WORK_IF, WORK_NEEDS], HOSTED_LABEL, HOSTED_BACKEND_HEADER, "work"),
        ("check-consumers", [WORK_IF, WORK_NEEDS], HOSTED_LABEL, HOSTED_BACKEND_HEADER, "work"),
        ("check-hosted", [AGG_IF, AGG_NEEDS], HOSTED_LABEL, HOSTED_AGG_HEADER, "aggregate"),
    ],
    "symbolic-gleam.yml": [
        ("gleam-hosted", [HOSTED_GLEAM_GATE], HOSTED_LABEL, HOSTED_GLEAM_HEADER, "gleam"),
    ],
}
# ELZ-058: the decision step is the only backend step that sees the job token, and the heavy steps after it
# may carry exactly these step-level conditions. Pairs are (step header line, if: line), in order.
DECISION_STEP = """      - name: Decide whether the full check is redundant
        id: skip
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: python3 scripts/ci-skip-decision.py"""
# ELZ-071: a documentation-only pull request (classified by scripts/ci-change-class.py, step `class`) skips every
# heavy step and runs the short `Docs-only check` instead.
SKIP_IF = "        if: ${{ steps.skip.outputs.skip != 'true' && steps.class.outputs.docs_only != 'true' }}"
DOCS_IF = "        if: ${{ steps.class.outputs.docs_only == 'true' }}"
# ELZ-064: the disposable S3 test server. Its start step is the only other backend step that sees the job
# token (to fetch the pinned release asset); the restore and save steps use the same pinned cache key.
MINIO_KEY = "elzoo-minio-RELEASE.2025-09-07T16-13-09Z-7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f"
MINIO_START_STEP = """      - name: Start the disposable S3 test server
        id: minio
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: python3 scripts/ci-minio.py"""
MINIO_SAVE_IF = "        if: ${{ steps.minio.outputs.source != 'cache' }}"
DEPS_SAVE_IF = "        if: ${{ steps.deps-cache.outputs.cache-hit != 'true' }}"
MINIO_CACHE_STEPS = [
    """      - name: Restore the pinned S3 test server binary
        uses: actions/cache/restore@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0
        with:
          path: ${{ runner.temp }}/elzoo-minio-cache
          key: """ + MINIO_KEY,
    """      - name: Save the pinned S3 test server binary
""" + MINIO_SAVE_IF + """
        uses: actions/cache/save@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0
        with:
          path: ${{ runner.temp }}/elzoo-minio-cache
          key: """ + MINIO_KEY,
]
# The checkout must not persist the job token in .git/config, where every later step (mix setup, mix check,
# dependency code) could read it; with ELZ-058 that token carries actions: read on check-plan.
CHECKOUT_STEP = """      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          fetch-depth: 0
          persist-credentials: false"""
# ELZ-059: the pull request run is the merge evidence, so it runs the full check (no affected mode), and the
# generated roadmap views are checked, not regenerated. ELZ-073: the full check runs as three parts, one per
# work job (`mix check --part ...`), and the steps are pinned by their exact text.
MIX_CHECK_STEPS = {
    job: f"""      - name: Run mix check
        run: sh scripts/run-ci-check.sh --part {part}"""
    for job, part in WORK_JOBS.items()
}
ROADMAP_STEP = """      - name: Check the roadmap views
        if: ${{ steps.skip.outputs.skip != 'true' && steps.class.outputs.docs_only != 'true' }}
        run: python3 scripts/check-roadmap.py"""
# ELZ-071: the classification step (right after the checkout; it has no `if:`, so it always runs and a failure
# fails the job), the tests of the classifier, and the short check of a documentation-only run. The merge queue
# accepts the marker line of the short check only when its own classification of the change agrees.
CLASS_STEP = """      - name: Classify the change
        id: class
        run: python3 scripts/ci-change-class.py github"""
CLASS_TEST_STEP = "      - run: python3 scripts/test-ci-change-class.py"
DOCS_ONLY_MARKER = "ELZOO DOCS-ONLY CHECK PASSED"
DOCS_ONLY_STEP = """      - name: Docs-only check
        if: ${{ steps.class.outputs.docs_only == 'true' }}
        run: |
          python3 scripts/check-claims.py
          python3 scripts/check-roadmap.py
          echo "ELZOO DOCS-ONLY CHECK PASSED\""""
# ELZ-073: the plan step exposes whether the work jobs run: true unless the push skip or the docs-only path applies.
PLAN_STEP = """      - name: Plan the work jobs
        id: plan
        env:
          SKIP: ${{ steps.skip.outputs.skip }}
          DOCS_ONLY: ${{ steps.class.outputs.docs_only }}
        run: |
          if [ "$SKIP" != true ] && [ "$DOCS_ONLY" != true ]; then
            RUN=true
          else
            RUN=false
          fi
          echo "run=$RUN" >> "$GITHUB_OUTPUT"
          echo "ELZOO PLAN: run=$RUN skip=${SKIP:-unset} docs_only=${DOCS_ONLY:-unset}\""""
# ELZ-073: the aggregating job. It is never skipped (`always()`), fails when the plan failed, when the work jobs
# were planned and one is not successful, and when they were not planned and one is not skipped. Only it prints
# the full-check marker.
FULL_MARKER = "ELZOO CHECK PASSED"
AGG_STEP = """      - name: Require every job
        env:
          PLAN: ${{ needs.check-plan.result }}
          RUN: ${{ needs.check-plan.outputs.run }}
          ROOT: ${{ needs.check-root.result }}
          DB: ${{ needs.check-consumers-db.result }}
          CONSUMERS: ${{ needs.check-consumers.result }}
        run: |
          echo "plan=$PLAN run=$RUN root=$ROOT consumers-db=$DB consumers=$CONSUMERS"
          test "$PLAN" = success
          if [ "$RUN" = true ]; then
            test "$ROOT" = success
            test "$DB" = success
            test "$CONSUMERS" = success
            echo "ELZOO CHECK PASSED"
          else
            test "$RUN" = false
            test "$ROOT" = skipped
            test "$DB" = skipped
            test "$CONSUMERS" = skipped
          fi"""
REPORT_STEP_IF = ("      - name: Report container resource observations", "        if: always()")
# Pinned steps and step-level conditions per job. Pairs are (step header line, if: line), in order.
PLAN_PINNED = [CLASS_STEP, CLASS_TEST_STEP, ROADMAP_STEP, DOCS_ONLY_STEP, PLAN_STEP]
PLAN_STEP_IFS = [
    ("      - name: Check the roadmap views", SKIP_IF),
    ("      - name: Docs-only check", DOCS_IF),
]
# Only the root job saves the caches (three jobs saving the same key would race); the others only restore.
WORK_STEP_IFS = {
    "check-root": [
        ("      - name: Save the pinned S3 test server binary", MINIO_SAVE_IF),
        ("      - name: Save dependency cache after mix setup", DEPS_SAVE_IF),
        REPORT_STEP_IF,
    ],
    "check-consumers-db": [REPORT_STEP_IF],
    "check-consumers": [REPORT_STEP_IF],
}
# Approved triggers: push to main, same-repository pull_request, workflow_dispatch (no inputs).
# pull_request_target and every other event need a new reviewed policy.
_triggers = [
    "on:",
    "  push:",
    "    branches: [main]",
    "  pull_request:",
    "  workflow_dispatch:",
]
expected_triggers = {
    "symbolic-check.yml": _triggers,
    "symbolic-gleam.yml": _triggers,
}
HOSTED_BACKEND_GATE_STEP = """      - name: Verify the GitHub-hosted runner
        run: |
          test "$RUNNER_ENVIRONMENT" = github-hosted
          test "$RUNNER_OS" = Linux
          test "$RUNNER_ARCH" = X64
          . /etc/os-release
          test "$ID" = ubuntu
          test "$VERSION_ID" = 24.04
          echo "Hosted runner: $RUNNER_NAME"
          free -h || true"""
# The hosted Gleam checkout must not persist the job token either.
HOSTED_GLEAM_CHECKOUT = """      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false"""
HOSTED_GLEAM_GATE_STEP = """      - name: Verify the GitHub-hosted runner
        working-directory: /
        run: |
          test "$RUNNER_ENVIRONMENT" = github-hosted
          test "$RUNNER_OS" = Linux
          test "$RUNNER_ARCH" = X64
          . /etc/os-release
          test "$ID" = ubuntu
          test "$VERSION_ID" = 24.04
          echo "Hosted runner: $RUNNER_NAME\""""
# ELZ-060: the Gleam job installs the pinned compiler through the release-asset API with the job token;
# the token is exposed to this one step only.
GLEAM_SETUP_STEP = """      - name: Install the pinned Gleam compiler
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: ./scripts/setup.sh"""
TOKEN_EXPRESSION = re.compile(
    r"github\s*\.\s*token|github\s*\.\s*\*|github\s*\[|\bsecrets\b|tojson\s*\(\s*(?:github|secrets)\b",
    re.IGNORECASE)
digest_image = re.compile(r'\s+image:\s*[^\s@\'"]+@sha256:[0-9a-f]{64}\s*')
# ELZ-043: every action is pinned by a full commit SHA; a tag or branch can move.
pinned_action = re.compile(r'\s*(?:-\s+)?uses:\s*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}(?:\s+#.*)?')
quoted_key = re.compile(r'\s*(?:-\s*)?(["\'])[^"\']*\1\s*:(?:\s|$)')
# Plain block scalars (`key: |`, `key: >-`); explicit indentation digits are not
# recognised, so their content stays subject to every check.
block_scalar = re.compile(r'(\s*(?:-\s+)?)[A-Za-z0-9_-]+\s*:\s*[|>][+-]?\s*(?:#.*)?')


def scalar_or_comment_lines(lines):
    """Indexes of block-scalar content and full-line comments: text, never keys."""
    skip = set()
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith('#'):
            skip.add(i)
        m = block_scalar.fullmatch(lines[i])
        i += 1
        if not m:
            continue
        first = next((j for j in range(i, len(lines)) if lines[j].strip()), None)
        if first is None:
            break
        indent = len(lines[first]) - len(lines[first].lstrip(' '))
        if indent <= len(m.group(1)):  # content must be deeper than the key column
            continue
        while i < len(lines) and (not lines[i].strip() or lines[i][:indent] == ' ' * indent):
            skip.add(i)
            i += 1
    return skip


def line_problem(line):
    """Reject YAML forms the reviewed workflows never use, so line checks see every key.

    Not a parser: it only walks node starts on one line and fails closed.
    """
    i, n, depth, start = 0, len(line), 0, True
    flow_mapping = sequence_mapping = has_escape = False
    while i < n:
        c = line[i]
        if c in ' \t':
            i += 1
            continue
        if c == '#' and (i == 0 or line[i - 1] in ' \t'):
            break
        if start:
            if c in '"\'':
                j = i + 1
                while True:
                    if j >= n:
                        return 'quoted scalars must close on the same line'
                    if c == '"' and line[j] == '\\':
                        # A YAML escape (\\x6f, \\u006f) decodes before GitHub reads ${{ }}, so it could hide
                        # github.token, secrets or vars from the raw-text checks; reported once the line scanned clean.
                        has_escape = True
                        j += 2
                        continue
                    if line[j] == c:
                        if c == "'" and j + 1 < n and line[j + 1] == "'":
                            j += 2
                            continue
                        break
                    j += 1
                i, start = j + 1, False
                continue
            if c in '[{':
                flow_mapping = flow_mapping or c == '{'
                depth += 1
                i += 1
                continue
            if depth and c in ']}':
                depth -= 1
                i, start = i + 1, False
                continue
            if c == '-' and not depth and (i + 1 == n or line[i + 1] == ' '):
                i += 1
                continue
            if c in '&*?!%@`':
                return 'anchors, aliases, tags and explicit keys are outside the reviewed source convention'
            if line.startswith('<<', i):
                return 'merge keys are outside the reviewed source convention'
            j = i
            while j < n:
                d = line[j]
                if d == ':' and (j + 1 == n or line[j + 1] == ' '
                                 or (depth and line[j + 1] in ',[]{}')):
                    break
                if d == '#' and j > i and line[j - 1] in ' \t':
                    break
                if depth and d in ',[]{}':
                    break
                j += 1
            i, start = j, False
            continue
        if c == ':' and depth:
            sequence_mapping = True
        if c == ':' or (depth and c == ','):
            i, start = i + 1, True
            continue
        if depth and c in ']}':
            depth -= 1
            i += 1
            continue
        return 'unexpected YAML token'
    if depth:
        return 'flow collections must close on the same line'
    if flow_mapping:
        return 'flow mappings are outside the reviewed source convention'
    if sequence_mapping:
        return 'mappings inside flow sequences are outside the reviewed source convention'
    if has_escape:
        return 'escapes in double-quoted scalars are outside the reviewed source convention'
    return None


files = sorted(pathlib.Path('.github/workflows').glob('*.y*ml'))
errors = []
for name in expected.keys() - {file.name for file in files}:
    errors.append(f'Missing required workflow: {name}')
for file in files:
    if file.name not in expected:
        errors.append(f'{file}: new workflows require an explicit runner-role policy')
        continue
    lines = file.read_text().splitlines()
    on_roots = [i for i, line in enumerate(lines)
                if re.match(r'''^["']?(?:on|true)["']?\s*:''', line)]
    trigger_block = []
    if len(on_roots) == 1:
        start = on_roots[0]
        end = next((i for i in range(start + 1, len(lines))
                    if re.match(r'^[^\s#]', lines[i])), len(lines))
        trigger_block = [line.rstrip() for line in lines[start:end]
                         if line.strip() and not line.lstrip().startswith('#')]
    if trigger_block != expected_triggers[file.name]:
        errors.append(f'{file}: triggers must be exactly push to main, pull_request and workflow_dispatch')
    # Script text and comments are not YAML keys; structure checks below still see every line.
    skip = scalar_or_comment_lines(lines)
    yaml_lines = [line for i, line in enumerate(lines) if i not in skip]
    for line in yaml_lines:
        if problem := line_problem(line):
            errors.append(f'{file}: {problem}: {line.strip()}')
    if any(re.match(r'(?:---|\.\.\.)(?:\s|$)|%', line) for line in lines):
        errors.append(f'{file}: one YAML document without directives is required')
    if any('pull_request_target' in line for line in yaml_lines):
        errors.append(f'{file}: pull_request_target is not an approved trigger')
    if any(quoted_key.match(line) for line in yaml_lines):
        errors.append(f'{file}: quoted YAML keys are outside the reviewed source convention')
    if any('\t' in line[:len(line) - len(line.lstrip())] for line in lines):
        errors.append(f'{file}: tab indentation is outside the reviewed source convention')
    for line in yaml_lines:
        # Every visible line starts a key or a list item; a plain-scalar continuation
        # line (for example a second line under a pinned uses:) is outside the convention.
        if line.strip() and not re.match(r'\s*(?:-\s+)?[A-Za-z_$][^:#]*:(?:\s|$)|\s*-\s+\S', line):
            errors.append(f'{file}: plain-scalar continuation lines are outside the reviewed source convention: {line.strip()}')
        if re.match(r'\s*image\s*:', line) and not digest_image.fullmatch(line):
            errors.append(f'{file}: container images must be pinned by @sha256 digest: {line.strip()}')
        if re.match(r'\s*(?:-\s*)?uses\s*:', line) and not pinned_action.fullmatch(line):
            errors.append(f'{file}: actions must be pinned by a full commit SHA: {line.strip()}')
        if re.fullmatch(r'\s*container\s*:\s*[^\s#].*', line):
            errors.append(f'{file}: container must be a mapping with a digest-pinned image')
    spec = expected[file.name]
    names = [item[0] for item in spec]
    jobs_roots = [i for i, line in enumerate(lines) if line == 'jobs:']
    job_headers = []
    end = len(lines)
    if len(jobs_roots) == 1:
        start = jobs_roots[0] + 1
        if any(re.match(r'^[^\s#]', line) for line in lines[start:]):
            errors.append(f'{file}: jobs: must be the last top-level key')
        job_headers = [(i, m.group(1)) for i in range(start, end)
                       if (m := re.fullmatch(r'  ([A-Za-z_][A-Za-z0-9_-]*):\s*', lines[i]))]
        # Flow-style, aliased or explicit-key jobs would hide runs-on from the line checks:
        # every line indented less than a job body must be a bare block-style job header.
        for i in range(start, end):
            line = lines[i]
            indent = len(line) - len(line.lstrip(' '))
            if (line.strip() and not line.lstrip().startswith('#') and indent < 4
                    and not re.fullmatch(r'  [A-Za-z_][A-Za-z0-9_-]*:\s*', line)):
                errors.append(f'{file}: jobs must be block-style mappings: {line.strip()}')
    shape_ok = [name for _, name in job_headers] == names
    if not shape_ok:
        if len(names) == 1:
            errors.append(f'{file}: exactly one {names[0]} job is required')
        else:
            errors.append(f'{file}: exactly the jobs {", ".join(names)} are required, in this order')
    pinned_tokens = []
    job_ranges = []
    for k, (name, head, runs_on, hosted, role) in enumerate(spec if shape_ok else []):
        h = job_headers[k][0]
        e = job_headers[k + 1][0] if k + 1 < len(job_headers) else len(lines)
        block = range(h, e)
        job_ranges.append(block)
        if lines[h + 1:h + 1 + len(head)] != head:
            errors.append(f'{file}: {name}: same-repository PR job gate is missing or changed')
        selectors = [i for i in block if re.match(r'\s*(?:-\s*)?runs-on\s*:', lines[i])]
        if (len(selectors) != 1 or selectors[0] in skip or selectors[0] != h + 1 + len(head)
                or lines[selectors[0]] != '    ' + runs_on):
            errors.append(f'{file}: every job must use {runs_on} ({name})')
        containers = [i for i in block if re.match(r'\s*(?:-\s*)?container\s*:', lines[i])]
        # A hosted job is pinned by its exact header and has no job container.
        if lines[h + 2 + len(head):h + 2 + len(head) + len(hosted)] != hosted:
            errors.append(f'{file}: the hosted job header lines below runs-on changed ({name})')
        if containers:
            errors.append(f'{file}: a hosted job must not use a job container ({name})')
        # Steps must be one visible block-style list, so the gate below is a real first step.
        steps = [i for i in block if re.match(r'\s*(?:-\s*)?steps\s*:', lines[i])]
        if len(steps) != 1 or lines[steps[0]] != '    steps:' or steps[0] in skip:
            errors.append(f'{file}: the job must keep one block-style steps: list ({name})')
        gate_step = {
            'symbolic-check.yml': HOSTED_BACKEND_GATE_STEP,
            'symbolic-gleam.yml': HOSTED_GLEAM_GATE_STEP,
        }.get(file.name)
        if gate_step is not None:
            gate_lines = gate_step.split('\n')
            after_gate = steps[0] + 1 + len(gate_lines) if len(steps) == 1 else e
            # The gate must be a whole step: up to the next step only its own script text
            # may follow, so no key such as if:, continue-on-error: or shell: can switch it off.
            next_step = next((i for i in range(after_gate, e) if lines[i].startswith('      - ')), None)
            if (len(steps) != 1 or lines[steps[0] + 1:after_gate] != gate_lines
                    or any(i in skip for i in range(steps[0] + 1, steps[0] + 2))
                    or next_step is None
                    or any(lines[i].strip() and i not in skip for i in range(after_gate, next_step))):
                errors.append(f'{file}: approved runner identity gate is missing or changed ({name})')
        if len(steps) == 1:
            # No job-level key (strategy:, services:, environment:, continue-on-error:) may follow the steps list.
            late = [i for i in range(steps[0] + 1, e)
                    if lines[i].strip() and not lines[i].lstrip().startswith('#') and i not in skip
                    and len(lines[i]) - len(lines[i].lstrip(' ')) <= 4]
            if late:
                errors.append(f'{file}: a hosted job must end with its steps list ({name}): {lines[late[0]].strip()}')
        if file.name == 'symbolic-gleam.yml':
            # Step-level conditions could switch off a Gleam gate or check; only the job-level gate may use if:.
            for i in block:
                if i != h + 1 and i not in skip and re.match(r'\s*(?:-\s+)?if\s*:', lines[i]):
                    errors.append(f'{file}: unreviewed if: key ({name}): {lines[i].strip()}')
            pin = HOSTED_GLEAM_CHECKOUT.split('\n')
            found = [i for i in block if re.match(r'\s*(?:-\s+)?uses\s*:\s*actions/checkout@', lines[i])]
            after_pin = ([line for line in lines[found[0] + len(pin):e]
                          if line.strip() and not line.lstrip().startswith('#')] if len(found) == 1 else [])
            if (len(found) != 1 or lines[found[0]:found[0] + len(pin)] != pin or found[0] in skip
                    or not after_pin or not after_pin[0].startswith('      - ')):
                errors.append(f'{file}: the pinned checkout step (persist-credentials: false) is missing or changed ({name})')
        if file.name == 'symbolic-check.yml':
            # ELZ-073: the pinned steps and conditions depend on the role of the job.
            def pin(step_text):
                step_lines = step_text.split('\n')
                found = [i for i in block if lines[i:i + len(step_lines)] == step_lines]
                after_step = ([line for line in lines[found[0] + len(step_lines):e]
                               if line.strip() and not line.lstrip().startswith('#')] if len(found) == 1 else [])
                # A pinned step ends where the next step starts, or where the job ends: no key can be appended.
                if len(found) != 1 or found[0] in skip or (after_step and not after_step[0].startswith('      - ')):
                    errors.append(f'{file}: the pinned step "{step_lines[0].strip()[2:]}" is missing or changed ({name})')
                    return None
                return found[0]

            checkout = CHECKOUT_STEP.split('\n')
            checkouts = [i for i in block if re.match(r'\s*(?:-\s+)?uses\s*:\s*actions/checkout@', lines[i])]
            # The step must end where the next step starts: no further input (ref:, repository:, token:) may follow.
            after_checkout = ([line for line in lines[checkouts[0] + len(checkout):e]
                               if line.strip() and not line.lstrip().startswith('#')]
                              if len(checkouts) == 1 else [])
            checkout_ok = not (len(checkouts) != 1 or lines[checkouts[0]:checkouts[0] + len(checkout)] != checkout
                               or checkouts[0] in skip or not after_checkout or not after_checkout[0].startswith('      - '))
            if role == 'aggregate':
                if checkouts:
                    errors.append(f'{file}: the aggregating job must not check out the repository ({name})')
            elif not checkout_ok:
                errors.append(f'{file}: the pinned checkout step (persist-credentials: false) is missing or changed ({name})')
            if role == 'plan':
                decision = DECISION_STEP.split('\n')
                starts = [i for i in block if lines[i:i + len(decision)] == decision]
                rest = [line for line in lines[starts[0] + len(decision):e]
                        if line.strip() and not line.lstrip().startswith('#')] if len(starts) == 1 else []
                if (len(starts) != 1 or starts[0] in skip or lines[starts[0] - 1] != '      - run: python3 scripts/test-ci-skip.py'
                        or not rest or not rest[0].startswith('      - ')):
                    errors.append(f'{file}: the pinned decision step is missing or changed ({name})')
                else:
                    pinned_tokens.append(starts[0] + 3)
                for pinned_step in PLAN_PINNED:
                    pin(pinned_step)
                expected_ifs = PLAN_STEP_IFS
            elif role == 'work':
                # ELZ-064: the S3 test server steps follow the checkout step directly, as one pinned block.
                # Only the root job saves the binary (the other jobs only restore it).
                s3_steps = [MINIO_CACHE_STEPS[0], MINIO_START_STEP] + ([MINIO_CACHE_STEPS[1]] if name == 'check-root' else [])
                s3_block = '\n'.join(s3_steps).split('\n')
                s3_start = checkouts[0] + len(checkout) if checkout_ok else -1
                s3_rest = [line for line in lines[s3_start + len(s3_block):e]
                           if line.strip() and not line.lstrip().startswith('#')] if s3_start >= 0 else []
                if (s3_start < 0 or lines[s3_start:s3_start + len(s3_block)] != s3_block or s3_start in skip
                        or not s3_rest or not s3_rest[0].startswith('      - ')):
                    errors.append(f'{file}: the pinned S3 test server steps are missing or changed ({name})')
                else:
                    pinned_tokens.append(s3_start + len(MINIO_CACHE_STEPS[0].split('\n')) + 3)
                pin(MIX_CHECK_STEPS[name])
                expected_ifs = WORK_STEP_IFS[name]
            else:
                pin(AGG_STEP)
                step_starts = [i for i in block if lines[i].startswith('      - ') and i > steps[0]]
                if len(step_starts) != 2:
                    errors.append(f'{file}: the aggregating job has exactly the identity step and the pinned step ({name})')
                expected_ifs = []
            # Any if: key other than the reviewed 8-space step-level lines (a header-form `- if:`, or another
            # indentation) is outside the convention; the job-level gate sits at h + 1.
            for i in block:
                if (i != h + 1 and i not in skip and re.match(r'\s*(?:-\s+)?if\s*:', lines[i])
                        and not lines[i].startswith('        if:')):
                    errors.append(f'{file}: unreviewed if: key ({name}): {lines[i].strip()}')
            pairs = []
            for i in block:
                if lines[i].startswith('        if:') and i not in skip:
                    header = next((j for j in range(i - 1, h, -1) if lines[j].startswith('      - ')), None)
                    pairs.append((lines[header] if header is not None else '', lines[i]))
            if pairs != expected_ifs:
                errors.append(f'{file}: step-level conditions are not the reviewed ones ({name})')
            # ELZ-071: the queue accepts the docs-only marker line, so the pinned Docs-only check step is the one
            # place in the workflow that may print it (the step text itself is pinned above). ELZ-073: the full-check
            # marker is printed by the aggregating job only.
            docs_lines = [i for i in block if DOCS_ONLY_MARKER in lines[i]]  # raw lines: script text and comments count
            full_lines = [i for i in block if FULL_MARKER in lines[i]]
            if len(docs_lines) != (1 if role == 'plan' else 0):
                errors.append(f'{file}: the docs-only marker may be printed by the pinned Docs-only check step only ({name})')
            if len(full_lines) != (1 if role == 'aggregate' else 0):
                errors.append(f'{file}: the full-check marker may be printed by the pinned aggregating step only ({name})')
    # ELZ-069: no workflow reads `vars` (the lane variable is gone), and no self-hosted runner, label list or
    # tier input may come back. Case-insensitive and on raw lines, script text and comments included: GitHub
    # expressions ignore case.
    for i, line in enumerate(lines):
        if re.search(r'\bvars\b|ELZOO_CI_LANE', line, re.IGNORECASE):
            errors.append(f'{file}: vars and the repository variable ELZOO_CI_LANE are not allowed: {line.strip()}')
        if re.search(r'self[-_ ]?hosted', line, re.IGNORECASE):
            errors.append(f'{file}: self-hosted runners are not allowed in this repository: {line.strip()}')
    for line in yaml_lines:
        if re.match(r'\s*(?:-\s+)?labels\s*:', line):
            errors.append(f'{file}: a labels: list could select a runner and is not allowed: {line.strip()}')
        if re.match(r'\s*(?:-\s+)?inputs\s*:', line):
            errors.append(f'{file}: workflow_dispatch inputs (the tier input) are not allowed: {line.strip()}')
    # Token exposure: github.token and secrets appear nowhere except the pinned steps.
    # Case-insensitive and tolerant of spacing, bracket access and whole-object dumps; script text and
    # comments are included on purpose (the check reads raw lines). A source-convention check only.
    token_lines = [i for i, line in enumerate(lines) if TOKEN_EXPRESSION.search(line)]
    if file.name == 'symbolic-gleam.yml':
        step = GLEAM_SETUP_STEP.split('\n')
        starts = [i for i in range(len(lines)) if lines[i:i + len(step)] == step]
        # The Gleam job has exactly one pinned setup step.
        pinned = (shape_ok and len(starts) == len(job_ranges)
                  and all(sum(1 for t in starts if t in r) == 1 for r in job_ranges)
                  and all(t not in skip for t in starts)
                  and token_lines == [t + 2 for t in starts])
        for t in starts if pinned else []:
            before = lines[t - 1]
            # The first line after the step that is neither blank nor a comment decides where the step ends.
            rest = [line for line in lines[t + len(step):] if line.strip() and not line.lstrip().startswith('#')]
            after = rest[0] if rest else ''
            # The step must follow the setup-node step and end where the next step starts, so no key
            # (shell:, if:, working-directory:, continue-on-error:) can be appended to it.
            pinned = pinned and (before == "          node-version: '24.16.0'"
                                 and (not after or after.startswith('      - ')
                                      or len(after) - len(after.lstrip(' ')) <= 4))
        if not pinned:
            errors.append(f'{file}: the pinned Gleam setup step is missing or changed, or the token appears elsewhere')
    elif token_lines != pinned_tokens:
        errors.append(f'{file}: github.token and secrets are not allowed in this workflow outside the pinned decision and S3 test server steps')
    # Token permissions: one top-level contents: read block, plus actions: read on check-hosted only; never write.
    perm_lines = [i for i, line in enumerate(lines) if re.match(r'\s*permissions\s*:', line)]
    expected_perms = ['permissions:'] + (['    permissions:'] * len(spec) if file.name == 'symbolic-check.yml' else [])
    top = perm_lines[0] if perm_lines else None
    if ([lines[i] for i in perm_lines] != expected_perms or top is None or lines[top:top + 2] != ['permissions:', '  contents: read']
            or (top + 2 < len(lines) and lines[top + 2].strip() and lines[top + 2][0] == ' ')
            or any(re.search(r':\s*write(?:-all)?\b|permissions\s*:\s*\S', line) for line in yaml_lines)):
        errors.append(f'{file}: token permissions must be exactly the reviewed ones (contents: read; actions: read on check-plan only; no write)')
    if file.name == 'symbolic-check.yml' and any(
            re.match(r'\s*(?:-\s+)?(?:defaults|shell|continue-on-error)\s*:', line) for line in yaml_lines):
        errors.append(f'{file}: defaults:, shell: and continue-on-error: could disable the runner identity gate')
    if file.name == 'symbolic-gleam.yml' and any(
            re.match(r'\s*(?:-\s+)?(?:shell|continue-on-error)\s*:', line) for line in yaml_lines):
        errors.append(f'{file}: shell: and continue-on-error: could disable a Gleam gate or check')
    if any(re.match(r'\s*(?:-\s*)?uses:\s*.*\.github/workflows/', line) for line in lines):
        errors.append(f'{file}: reusable workflow runners need explicit policy review')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('All workflow jobs are the reviewed GitHub-hosted jobs; no self-hosted runner, label list, tier input or lane variable')
