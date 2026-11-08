# CI on user-owned machines

Elzoo uses only the user-owned Linux machines `symbolic` and `macbook-ubuntu`.
GitHub provides scheduling and check reporting; it does not supply compute.
Never select a GitHub-hosted image or add a hosted fallback. If a runner is
offline, diagnose it or let work queue on the other approved runner.

## Roles and routing

- `symbolic-elzoo`: backend; labels `self-hosted`, `linux`, `x64`, `elzoo`,
  `backend`, `symbolic`.
- `macbook-ubuntu-elzoo-candidate` (runner id 23): backend; labels
  `self-hosted`, `linux`, `x64`, `elzoo`, `backend`, `macbook-ubuntu`,
  `ci-candidate`. It received `backend` after ELZ-034 merged (PR #61), so it
  is in the normal backend pool. The name and `ci-candidate` label are
  historical; they do not select a separate route.
- `symbolic-elzoo-gleam`: Gleam only; labels `self-hosted`, `linux`, `x64`,
  `symbolic`, `elzoo`, `gleam`.

The backend workflow uses `[self-hosted, linux, x64, elzoo, backend]` for every
event; either backend runner may take the job. ELZ-040 removed the one-time
`task/ELZ-034` candidate selector. Both workflows run only on `push` to `main`,
`pull_request` and `workflow_dispatch`. `pull_request_target` and other events
are not approved. Both backend and Gleam jobs skip fork PRs before runner
selection; a skipped job is not validation and must not be treated as evidence
for merging a fork. This does not make arbitrary same-repository code trustworthy.
The first container step refuses any backend `RUNNER_NAME` other than the two
names above. The Gleam selector stays symbolic-only. A new backend machine
needs a full task-branch check and independent review before it gets `backend`.
Registration is repository-scoped; administrators must assign these labels only
to the named trusted machines. GitHub label selection is not cryptographic host
identity, and a runner name check happens after the host starts the container.

`scripts/check-ci-runners.py` requires exactly one named job per reviewed workflow,
with its fork-PR gate immediately below the job name; it checks the exact `on:`
trigger block, rejects `pull_request_target` and quoted YAML keys, requires every
container `image:` to carry an `@sha256:` digest, and checks exact selector
conventions, the identity gate and known workflow files. Jobs must be
block-style: a flow-style, aliased or explicit-key job line under `jobs:` is
rejected, and `jobs:` must be the last top-level key. Each job must keep exactly
one `container:` mapping whose first key is a digest-pinned `image:`, so its steps
run in that image rather than in a plain host shell. `container.options` (for
example `--privileged` or host mounts) is not restricted, so this is not host
isolation. The guard fails closed on YAML forms the workflows never use: anchors,
aliases, tags, explicit `?` keys, merge keys, quoted scalars or flow collections
that do not close on their own line, document markers and directives.
Text inside plain block scalars (`run: |`, content deeper than the key column)
and full-line comments is not read as YAML keys for the trigger-name,
quoted-key, image and form checks. The `runs-on:` and `container:` lines must be
visible keys outside that text, and any copy of them inside script text still
counts against the one allowed. It disallows reusable workflows without a policy. Every `uses:` action
must be pinned by a full 40-character commit SHA (ELZ-043); a tag, branch or
short SHA is rejected. Flow mappings (`{ ... }`, for example a
`- { uses: ... }` step) are rejected even on one line, so no key hides from
these line checks; one-line flow sequences of plain words such as
`[self-hosted, ...]` stay allowed, but a `key: value` inside `[ ... ]` is rejected.
Every visible line must start a key or a list item, so a plain-scalar
continuation line is rejected. The job keeps one block-style `    steps:` list,
and the backend runner identity gate must be its first step, outside script text.
The gate is a whole step: only its own script text may follow it before the next
step, so no `if:`, `continue-on-error:` or `shell:` can switch it off, and
`symbolic-check.yml` may not use `defaults:`, `shell:` or `continue-on-error:`.
An added job requires deliberate guard review.
`python3 scripts/test-ci-runners.py` exercises positive routing and negative
controls. This is a source convention guard, not protection against hostile YAML
or an account-level runner admission policy. Workflow and trust-model changes
require independent review. Inspect the actual GitHub job `runner_name` and
labels, not just the check name, when verifying a machine.

## Affected consumer checks (ELZ-038)

`mix check` defaults to the full check. Every push to `main` and every
`workflow_dispatch` uses that default: all root tests, all 26 existing per-ID
consumers, the separate OTP-only consumer, and the aggregate over every ready
ID (40 at ELZ-038). The aggregate and per-ID consumers are tests inside the
root suite, not additional phases to add to its reported duration. The fixed
per-ID list does not cover every ready Piece independently.

On `pull_request` only, the backend workflow invokes
`mix check --affected BASE`, where `BASE` is the event's base commit SHA.
Checkout fetches full history; the selector compares that commit with the
checked-out PR merge result, including any working changes and non-ignored
untracked files. Renames are read as deletion plus addition. Git paths are
NUL-delimited, so filenames are not split at spaces. A local opt-in is:

```sh
mix check --affected origin/main
```

`Elzoo.CheckSelection` maps paths below known ready `pieces/<family>/<name>/`
directories to IDs, including their manifests, README and test files. It
follows reverse `piece.json` dependencies transitively across all ready IDs,
then selects from the existing 26 per-ID consumers. A dependency without its
own fixed consumer still selects its dependants. The selector uses
`Registry.select!`, the same dependency closure as the exporter, to check which
affected IDs those selected consumers actually copy. If any affected ready ID
is outside those closures, it also runs the full aggregate and logs the
uncovered IDs and reason. For example, `workflow/approval` selects no fixed
consumer but still runs the aggregate on the PR. A change confined to
`delivery/transformation` and its covered dependants can omit the aggregate.
Changing a covered Piece still runs the aggregate if an affected dependant is
uncovered: currently `core/operator` affects `workflow/dependency-graph`,
`integration/json` affects `integration/cure-json`, and `runtime/unit` affects
`workflow/budget` and `workflow/dependency-graph`.
The 26 fixed consumers currently cover 31 of the 40 ready IDs through their
dependencies; 14 lack a standalone consumer, but only nine lack coverage in
every fixed consumer's closure.

Every shared harness, toolchain, `mix.exs`/`mix.lock`, registry, workflow or
unknown/unmapped path selects all 26 **and the aggregate**. There is no docs-only
exception. Missing Git history, failed Git commands, malformed paths and an empty diff also
select all 26 and the aggregate with a logged fallback reason. Shared changes
cannot rule out effects on IDs outside the fixed consumers' closures, or on
aggregate composition. A dependency or registry validation failure still fails
`mix check`; selection does not suppress it.

Affected mode excludes only unaffected tagged per-ID consumer tests and, when
every affected ID has selected-consumer closure coverage, the aggregate. It
retains all other root proofs, runtime tests, negative controls, export
assertions, the OTP-only consumer, the Ash spike,
formatting, compilation and ledger checks. No test body or time limit changes.
The log names the mode/comparison, affected ready IDs, selected/skipped consumer
IDs, ready IDs without a standalone consumer, uncovered affected IDs, and
aggregate/OTP disposition with the aggregate selection reason.
The success marker is `ELZOO AFFECTED CHECK PASSED (not full consumer acceptance; see selected consumer scope)`;
only the default full run emits `ELZOO CHECK PASSED`.

A PR subset does not validate unselected consumer checks or an omitted
aggregate. Merge acceptance still needs the full run on the merge commit. A failure found there
is a regression to fix forward, not justification to reduce the full run.
The ELZ-038 implementation PR itself changes the shared harness and must select
all 26 consumers and the aggregate; a later genuine covered one-Piece PR supplies
the narrow-subset CI observation. Compare wall times with runner, cache state and commit differences
visible, rather than treating unrelated runs as a controlled speed experiment.
Cure source-scan caching, registry parse reuse, incremental Cure compilation
and test partitioning remain separate work.

## Coordinator merge queue (ELZ-039)

Run `python3 scripts/merge-queue.py <PR>...` from a checkout of this repository
with `origin` pointing at `balungpisah/elzoo`. It uses the coordinator's own
`gh` authentication, not CI credentials. Obtain independent review first.
No workflow, job, runner, label or token is added; CI keeps `contents: read`.
The queue only handles same-repository, open, non-draft, mergeable PRs targeting
`main` with an exact `task/ELZ-###` branch. Unknown mergeability is polled for
up to one minute, then refused if it remains unknown.

For each PR, the queue fetches main and the task branch, then reads main’s SHA
from `gh api repos/balungpisah/elzoo/git/ref/heads/main`. The canonical GitHub
repository owns the base; a misconfigured origin cannot substitute a different
main SHA. Missing commit objects fail closed. If main is not an ancestor of the
head, `gh pr update-branch` creates a merge update; it never
rebases or force-pushes. The new head must become visible before continuing.
It dispatches `symbolic-check.yml` on that branch and identifies a **new** run
by workflow, `workflow_dispatch` event, branch and exact `head_sha`. It records
existing run IDs before dispatch, never chooses an old or merely latest green
run, and refuses an ambiguous match. A dispatch that races a head update cannot
supply evidence for the previous head.

The completed run must succeed. Its exact attempt must have one successful
`check` job on `symbolic-elzoo` or `macbook-ubuntu-elzoo-candidate`, on the same
head, with a successful `Run mix check` step. The job log must contain the full
`ELZOO CHECK PASSED` output line and no `ELZOO AFFECTED CHECK PASSED` marker.
Missing logs, API/command failures, cancelled runs and reruns during evidence
collection fail closed. This validates observed evidence from trusted workflow
code, not authenticity against a hostile PR or administrator.

The queue also waits for a successful `symbolic-gleam.yml` **pull_request**
run on the exact same head SHA, including after `update-branch`. That update
triggers the synchronize event; no extra Gleam dispatch is added. The latest
matching run must succeed, have one successful `gleam` job on
`symbolic-elzoo-gleam`, and a successful `Run ./scripts/check.sh` step. An old
head’s green Gleam run, a missing run, or a failed/cancelled run cannot satisfy
this gate. It rechecks run identity and attempt after collecting the job.

Before merging, it re-reads the PR and fetches again. A changed head stops the
queue. Main advancing beyond the checked head triggers another merge update
and full dispatch. The merge command is always:

```sh
gh pr merge <PR> -R balungpisah/elzoo --merge --match-head-commit <checked-head-SHA>
```

After confirming the merge, it prints an `ELZOO GLEAM EVIDENCE` line and an
`ELZOO MERGE EVIDENCE` line with PR, run/job IDs, runner names, checked head SHA
and merge SHA. Preserve those lines in the coordinator's acceptance record.
No branch deletion, issue closure or
acceptance posting is performed. A transport failure during a merge can leave
an unknown result: inspect the PR before retrying; an already merged PR is
refused rather than merged again.

`--continue-on-failure` explicitly allows the next supplied PR after a failure;
the overall exit status still fails. Malformed API object shapes are per-PR
failures too; they never authorize a merge. Default behavior stops immediately.
`--timeout SECONDS` defaults to 10800 seconds per PR, including queue time.
Run discovery is bounded to five minutes; individual commands to two minutes;
main-update/check passes to ten. Interrupting the CLI stops local processing,
but does not cancel an already dispatched run or undo a merge request.

### Cancellation and overlap

Both workflows use this policy (the Gleam group starts with `gleam-`):

```yaml
concurrency:
  group: check-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

PR runs share their ref group and cancel superseded PR checks. Main and manual
runs each have their own run-ID group, so they cannot replace each other's
running **or pending** checks through concurrency. Merely setting
`cancel-in-progress: false` with a shared main group would still replace a
pending run when a newer run arrived; see [GitHub concurrency semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
This corrects the original issue's request to keep the group for all events,
with owner approval. The review correction applies it to both workflows,
so Gleam merge-commit evidence is retained too.

A's merge-commit backend check can overlap B's full pre-merge dispatch on the
two approved backend runners. There is no new per-runner route, speculative
stack checking, or guarantee of immediate capacity. Preserving pending checks
can increase queue length; this does not speed up an individual full check.

### Limits and acceptance

The queue is a serial coordinator convenience, not enforced branch protection.
It does not enforce independent review or replace merge-commit acceptance.
It requires both full backend dispatch success and current-head Gleam PR
success, without a separate Gleam dispatch. The coordinator checks any other
PR checks and review before invoking it. The final fetch and GitHub merge
are separate operations: another coordinator/manual merge can advance main
between them. `--match-head-commit` protects the head, not an atomic base SHA.
Use one integration coordinator and retain full merge-commit checks; no atomic
base guard or multi-coordinator locking is claimed.

`scripts/test-merge-queue.py` uses a fake gh/git command runner and stdlib
`unittest` to exercise refusals and races without network or merges. It runs
next to `scripts/test-ci-runners.py` in backend CI. Existing runner tests and
source convention rules stay unchanged. These tests are scenario evidence,
not a proof of GitHub behavior. Acceptance additionally needs one real queue
merge with run/runner/merge SHA, and an observed pair of overlapping main
checks (or an explicit statement that the pair was not observed). Those live
observations and independent review belong to the coordinator; a local fake
run does not satisfy them.

## Timing lines in CI logs (ELZ-045)

`mix check` prints `ELZOO STAGE <name> start|end utc=... elapsed=...` around format, compile,
ledger, Ash spike, registry load and the root suite. The consumer harness (`Elzoo.CureConsumerCase`
since ELZ-049; `test/export_test.exs` before) prints
`ELZOO TIMING consumer=<id|aggregate(N)> <step> seconds=...` for each copied consumer. Steps are
`plan_write`, `consumer_mix_test`, `runtime_vm` and `total`.

Mix compiles the project before it loads the `mix check` task, and runs each task once, so the
`compile` stage brackets a no-op and reads about 0 s. The pre-task work (VM boot, `deps.loadpaths`
and the compile) is the gap between the `Run mix check` step `started_at` in the jobs API and the
`format start` stamp: 110 s on symbolic, run 42404495544. The OTP-only `runtime/unit` test prints
one `consumer_mix_test` line only. Timing lines can share a line with ExUnit progress dots, so
match them without a `^` anchor.

These lines are monitored behavior from a monotonic clock. They prove nothing about correctness.
They add no stage, test or assertion. Queue time is not part of any line. Compare runs only on the
same SHA and the same runner.

## Concurrent database-free consumers (ELZ-049)

The copied-consumer tests share one harness, `Elzoo.CureConsumerCase` in
`test/support/cure_consumer_case_test_helper.exs`. The 23 consumers whose copy closure names no PostgreSQL
provider (`postgrex`, `ecto_sql`, `oban`) are defined in three modules with `async: true`:
`test/consumer_group_a_test.exs`, `_b_` and `_c_`. ExUnit runs async modules at the same time
and tests inside one module in sequence. `test/test_helper.exs` sets `max_cases` to
`System.schedulers_online()`, so at most three consumer VMs run at once on symbolic (`+S 4:4`)
and at most two on macbook-ubuntu (`+S 2:2`). The groups are explicit lists balanced by the
measured `total` seconds on main `0a42370`. The three
PostgreSQL consumers (`integration/sql`, `integration/jobs`, `assembly/durable-job`) and the
aggregate consumer stay in `test/export_test.exs` with `async: false`, because the CI job prepares
one disposable database. The OTP-only consumer and the plan/write tests stay there too; they
were not moved.

Each per-ID test keeps its name and its `consumer_id` tag, so the affected mode (ELZ-038)
filters them with the same `--exclude consumer_id:<id>` arguments. The 23 concurrent tests have a
240 s limit (`Elzoo.CureConsumerCase.concurrent_timeout/0`); the sequential consumers keep 120 s.
Measured basis for 240 s: on macbook-ubuntu, three concurrent VMs after about 30 minutes of
sustained load pushed `assembly/request-route-retry` from 35.8 s (sequential) to 99.1 s and then
past 120 s twice (PR #90, run 42454973591, repeats 6 and 7). 240 s is about 2.4x that worst
value, the ELZ-036 margin rule. The same series on symbolic stayed at 123 to 125 s per repeat with
35.7 s for that consumer, so the slowdown is a property of the two-core host under sustained load. The selection test in
`test/export_test.exs` counts the per-ID tests over the four modules (still 26, plus one
aggregate), checks that the groups plus the PostgreSQL list equal
`Elzoo.CheckSelection.consumer_ids/0`, and checks that no database-free group ID copies a Piece
with a PostgreSQL provider. That test needs the four modules loaded: run the whole suite, or name
the four files together.

Measured basis before the change, main `0a42370` on `symbolic-elzoo` (job 128581094645): the 23
database-free consumers took 189.5 s in sequence; the root suite reported `Finished in 862.2
seconds`. Locally on the implementation branch, the three group files ran in 100.7 s wall time
for 205.0 s of summed consumer `total` time. Under concurrency a per-consumer `total` includes
contention, so it is not comparable with a sequential `total`; compare the root suite `Finished
in` and the stage elapsed on the same SHA and runner. CI before/after figures and the repeat
series are recorded in the ELZ-049 PR. The repeat series runs the three group files alone; in
`mix check` they also overlap the other async root and piece test modules, so the per-test
margin under full load is shown only by whole-suite runs. Three concurrent consumer VMs add
memory: compare the cgroup peak before and after on the same runner. The concurrency bound is
the module count, not a measured CPU budget; a passing repeat series is a finite sample.

## Owned Cure compile fingerprint (ELZ-046)

`Mix.Tasks.Compile.Cure` writes `elzoo.cure.manifest` (format 2) with a sha256 fingerprint over
named inputs: the path and content of every owned `.cure` source, the nearest `Cure.toml` of each
source, the sorted source roots, the whole `mix.lock`, every file in the loaded Cure `ebin`, the
compiler module's own BEAM md5, and the Elixir, OTP and ERTS versions. The compile is skipped only
when the fingerprint matches, every listed BEAM exists and `--force` was not given; the log then
says `Cure sources unchanged (...); skipping N modules`. A mismatch on any named input, a missing
or malformed manifest, a missing BEAM, or `mix compile --force` recompiles everything.

Copied consumers carry the same compiler. Their first build starts from an empty `_build` and
always compiles; a later build in the same consumer skips under the same rule. The fingerprint
covers the named inputs only. It is not a proof that no other input exists. Negative controls live
in `test/compile_cure_fingerprint_test.exs`.

## Cure pin on the balungpisah fork (ELZ-047)

`mix.lock` pins Cure to `balungpisah/cure-lang` commit `208248063`, which is upstream `a004c335`
plus one import-resolution fix (see `docs/dependencies/forks/cure.md`). The first CI run on each
backend runner after this change restores the previous cache by prefix key, then `mix deps.get`
refetches Cure because `mix.lock` changed and Cure compiles from source once per runner; that run
saves a new cache. Later runs are warm. Compare consumer timings only between warm runs.

## Machine and container setup

Both machines use repository-scoped runner installations and dedicated
`elzoo-ci` accounts. The account can access Docker, which is root-equivalent;
job containers are not a sandbox for hostile PR code. Run only trusted code in
this private repository. Never store runner registration tokens in the repo or
logs. Use a short-lived registration token directly for `config.sh`.

`symbolic` is Ubuntu 26.04.1 x86_64, four physical/eight logical CPUs and
about 30 GiB RAM. Its backend and Gleam services are
`actions.runner.balungpisah-elzoo.symbolic-elzoo.service` and
`actions.runner.balungpisah-elzoo.symbolic-elzoo-gleam.service`, with separate
installations and `_work` directories.

`macbook-ubuntu` is Ubuntu 26.04.1 x86_64, two physical/four logical CPUs,
7.1 GiB usable RAM and 4 GiB swap, also running other user workloads. Docker
29.1.3 was installed from Ubuntu packages. Its candidate runner is version
2.338.2, verified against SHA-256
`baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40`, installed
at `/opt/actions-runner/elzoo-backend` and served by
`actions.runner.balungpisah-elzoo.macbook-ubuntu-elzoo-candidate.service`.
It has a separate `_work` directory. Docker startup and a pull/run of the pinned
CI image passed during provisioning; those are not a full CI validation.

The first complete candidate trial, Actions run 42305933284 at `2346426`,
ran for 29 minutes 45 seconds; the container reported a cgroup memory peak of
2,312,663,040 bytes (about 2.15 GiB). `mix setup` passed, but `mix check`
failed with 364/366 root tests passing. The CI guard test used an outdated
symbolic-only fixture; ELZ-034 updates it. A separate durable-job PostgreSQL
scenario failed while starting Oban's notifier with `no process`; the cause is
unconfirmed. This failed run does not establish reliable capacity or a passing
check. Repeat the full run on the final head and retain both results.

The next trial, Actions run 42310175044 at `d061e50`, passed `mix setup`
but failed `mix check`: the outer suite reported 393/394, with the copied
durable-job consumer reporting 177/179. Two PostgreSQL scenarios failed while
starting Oban's PG notifier with `no process`, the same error class as the
earlier run. Its cause remains unconfirmed. The run reported a cgroup memory
peak of 2,319,937,536 bytes (about 2.16 GiB). These results do not establish
reliable capacity. Retest on the current merged main and do not lower the
test or delivery Contracts to obtain a pass.

Actions run 42315972879 at `1fe2bf7`, with current main merged, passed
`mix setup` and `mix check` on `macbook-ubuntu-elzoo-candidate`: 32 spike tests
and 428 root tests passed. The job took 38m06s and reported cgroup memory peak
2,325,393,408 bytes (about 2.17 GiB). CPU was not sampled in that run; two
configured BEAM schedulers per VM do not measure peak CPU. A passing run does
not erase the earlier failures or establish behavior under different load.
ELZ-035 owns the independently reproduced notifier race and a separate durable
job Contract defect; its fixes and scoped evidence remain pending review.

Actions run 42325304955 at `1700cad` reported `mix setup` passed but
`mix check` failed (427/428 root tests). The DJ21 PostgreSQL test could not
start the Oban PG notifier and exited `:noproc`, the previously reported
failure class. The full job took 24m49s. The cgroup reported 2,271,883,264
bytes peak memory (about 2.12 GiB), and the sampler observed a maximum
one-second average of 3.267 CPU cores across 1,235 samples. These are
container observations, not hard resource limits or proof of isolation from
other workloads. The failing run does not establish reliable CI capacity.

Actions run 42335711837 at `33dc45f` (job 128292087874, the final ELZ-034
head) passed `mix setup` and `mix check` on `macbook-ubuntu-elzoo-candidate`:
32 spike tests and 432 root tests passed. The job took 25m21s. The cgroup
reported 2,251,575,296 bytes peak memory (about 2.10 GiB), and the sampler
observed a maximum one-second average of 3.385 CPU cores across 1,265 samples.
After this run and independent review, ELZ-034 merged and runner 23 received
the `backend` label. This is one observation, not a resource guarantee or proof
of reliability; the earlier failed runs above remain part of the record.

ELZ-040 raised the backend job `timeout-minutes` from 45 to 90 (Gleam stays
30; test time limits are unchanged). Measured basis:

- Main `94df396` run 42340251145 on `symbolic-elzoo` passed, but the run took
  44m17s (job 04:51:50Z–05:35:51Z, 44m01s). The root suite reported
  `Finished in 1377.4 seconds` and 510 tests.
- PR #71 run 42342334978 attempt 1 at `11abcfa` on
  `macbook-ubuntu-elzoo-candidate` was cancelled: "The job has exceeded the
  maximum execution time of 45m0s" (check run 128312535761, 05:20:51Z–06:06:03Z).
  `mix check` was still running and had reported no test failure. The cache
  missed, so `mix setup` took 13m16s (1m22s in run 42335711837).
- Attempt 2 of the same run, which is a separate observation and does not
  replace attempt 1, passed on `symbolic-elzoo` (06:07:51Z–06:36:38Z, 28m47s)
  with a restored cache: 510 root tests, `Finished in 1356.5 seconds`, cgroup
  memory peak 2,814,078,976 bytes, sampled CPU peak 5.037 cores over 1,479
  samples.

Contributing factors: more Pieces and tests after ELZ-024; the ELZ-034 cache
prefix change, which left runners with cold caches; and `+S 2:2` on the
candidate. A 90-minute limit is headroom, not a performance target. Look into
a growing duration rather than raising the limit again.

Each role runs at most one job per runner. The candidate has no hard container
memory or CPU quota. The backend workflow keeps `+S 4:4 +SDcpu 1 +SDio 1` on
symbolic and selects `+S 2:2 +SDcpu 1 +SDio 1` on macbook-ubuntu, per BEAM VM;
child VMs and other processes are additional. The host is smaller, so check the
actual run's duration and cgroup peak, inspect host memory and user workload
contention, and keep it candidate-only if the full workload is unreliable.
The check wrapper samples cgroup CPU usage at one-second intervals during
`mix check` and reports the largest observed interval average in logical-core
equivalents. It is not an instantaneous peak or a CPU quota; child VMs and
all other processes inside the job container are included. Before/after
`/proc/meminfo` and load averages provide host context but do not attribute
resource use to individual user workloads. Missing metrics are reported as
unavailable rather than treated as zero.

Jobs run inside Ubuntu 24.04 pinned to
`sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`.
`ImageOS: ubuntu24` selects setup-beam's container build. Packages are installed
from apt repositories and are not a bit-for-bit package snapshot. Exact Cure,
Elixir, OTP, Node and Gleam pins remain in the repository. Backend jobs create a
per-container disposable PostgreSQL role and database and export
`ELZOO_TEST_DATABASE_URL`; required tests fail closed without it. Do not use a
personal or production database. Cache keys include the runner name as well as
toolchain/dependency pins: compiled Cure and Mix artifacts are not restored from
another machine's checkout. GitHub's cache service remains in use; no claim is
made about other GitHub account costs.

### Dependency cache (ELZ-043)

The backend job restores with `actions/cache/restore` and saves with
`actions/cache/save`, both pinned at `0057852bfaa89a56745cba8c7296529d2fc39830`
(tag v4.3.0). The key and restore-keys prefix are unchanged:
`elzoo-ubuntu24-v2-<runner name>-Linux-otp29.1.2-elixir1.20.4-<hash of the two
mix.lock/mix.exs pairs>`. The save step runs immediately after `mix setup`
succeeds and before `mix check`, only when the restore had no exact
primary-key hit (`cache-hit != 'true'`), using the restore step's
`cache-primary-key`. It runs on the same events as the job itself (push to
`main`, same-repository PRs, `workflow_dispatch`), as the earlier combined step
did. A `mix check` failure, cancellation or timeout now keeps the saved state;
a failed `mix setup` saves nothing. GitHub scopes caches by ref: a PR save is
visible to that PR only, while a `main` save is visible to every branch.

What is saved is the post-`mix setup` state (`deps`, `_build` and the spike's
`deps`/`_build`, `test` env). Files that `mix check` adds later are no longer in
a newly saved entry. The save stays on the same runner key, so compiled Mix and
Cure artifacts, including the root application's BEAMs in `_build`, are still
never restored on another machine or path; they are not a substitute for the
source-copy boundary.

No per-runner warm job was added. Measured on the backend workflow, steps
`Run mix setup` and the cache save:

| Restore | Runs (runner) | `mix setup` |
|---|---|---|
| exact hit | 42342334978 attempt 2, 42306658171 (symbolic) | 111 s, 54 s |
| restore-key hit on the runner's own older key, after a lock change | 42215808401, 42224055535, 42256519279, 42267542586 (symbolic) | 346 s, 306 s, 38 s, 36 s |
| no cache for the prefix (after the ELZ-034 v1→v2 change) | 42340251145 (symbolic); 42342334978 attempt 1, 42337998577, 42351427886 (macbook-ubuntu) | 662 s; 796 s, 739 s, 811 s |

Saves took 45–543 s (for example 273 s in 42340251145, 543 s in 42215808401).
After a `mix.lock` or `mix.exs` change, the runner that did not take the `main`
run still restores its own older main entry by prefix, so its first run costs
an incremental `mix setup` plus one save, not a cold build. A warm job would
need a second, per-runner job and route (a guard and trust-model change) and
would occupy each runner for a setup and save on every key change. The fully
cold case comes only from a changed key prefix or an evicted entry. Change the
prefix only deliberately and expect one cold run per runner. These are
observations from listed runs, not a timing guarantee; no claim is made about
warm-run speed.

Coordinator check after merge: `gh api
'repos/balungpisah/elzoo/actions/caches?per_page=50' --jq '.actions_caches[] |
select(.ref=="refs/heads/main") | {id,key,created_at}'` must list one entry per
backend runner name with the current hash.

On 2026-11-07, pulls from `registry-1.docker.io` timed out from `symbolic`
while `github.com` and `auth.docker.io` were reachable. The Docker daemon on
`symbolic` now has `/etc/docker/daemon.json` set to
`{"registry-mirrors": ["https://mirror.gcr.io"]}`. A mirror changes only where
layers are fetched: the job image stays pinned by the same digest, so Docker
verifies the same content. The mirror is host configuration, not repository
state. This record covers `symbolic` only.

## Operation and rollback

```sh
ssh symbolic 'sudo systemctl status actions.runner.balungpisah-elzoo.symbolic-elzoo.service --no-pager'
ssh macbook-ubuntu 'systemctl status actions.runner.balungpisah-elzoo.macbook-ubuntu-elzoo-candidate.service --no-pager'
gh api repos/balungpisah/elzoo/actions/runners --jq '.runners[] | {name,status,busy,labels: [.labels[].name]}'
```

Do not restart or remove a busy runner or its `_work` directory. If the candidate
is unavailable, remove its `backend` label after the current job is finished;
symbolic continues to accept backend jobs. If it is the cause of failures,
record the exact run, environment and failure; preserve failed evidence and
route only to the healthy named machine. Never change to hosted CI.

To replace a runner, verify the published release archive checksum, provision a
separate service account and work directory, configure a short-lived repository
registration token without printing it, assign only the documented role labels,
and verify runner identity and the full job on a reviewed change. Do not point
two runners at one `_work` directory or blindly register more runners to reduce
queue time.

## Historical evidence

ELZ-019 moved CI from hosted machines to symbolic. ELZ-020 measured BEAM
scheduler settings and split backend and Gleam roles. Earlier hosted runs are
historical evidence and do not satisfy the user-owned machine policy. ELZ-034
admitted the second backend runner (PR #61, merge `9890dee`). ELZ-040 removed its
one-time route and hardened the guard. ELZ-042 closed the flow-style job and
missing-container gaps found in the ELZ-040 review. ELZ-043 split the dependency
cache so it is saved after `mix setup` and added the action SHA-pin check.
