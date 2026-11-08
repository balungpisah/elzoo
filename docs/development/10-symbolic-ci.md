# CI on the owner's machines

Elzoo uses only the owner's Linux machines: the user-owned `symbolic` and `macbook-ubuntu` and, from
ELZ-056 (owner decision 2026-11-08), the user-rented Contabo VPS `ratahq-ci-contabo-01`
(runner `contabo-elzoo-1`; trialled, routed only for `main` pushes and measurement runs, see "Runner tiers"
and "Contabo VPS" below). GitHub provides scheduling
and check reporting; it does not supply compute.
Never select a GitHub-hosted image or add a hosted fallback. If a runner is
offline, diagnose it or let work queue on the other approved runner.

## Roles and routing

- `symbolic-elzoo`: backend, fast tier (the `fast` label is assigned by the coordinator before
  ELZ-057 merges); labels `self-hosted`, `linux`, `x64`, `elzoo`,
  `backend`, `fast`, `symbolic`.
- `macbook-ubuntu-elzoo-candidate` (runner id 23): backend; labels
  `self-hosted`, `linux`, `x64`, `elzoo`, `backend`, `fast`, `macbook-ubuntu`,
  `ci-candidate`. It is in the fast tier. It received `backend` after ELZ-034 merged (PR #61), so it
  is in the normal backend pool. The name and `ci-candidate` label are
  historical; they do not select a separate route.
- `contabo-elzoo-1` (runner id 24): backend, **any tier only, never `fast`**; labels `self-hosted`,
  `Linux`, `X64`, `elzoo`, `contabo`, and `backend` once the coordinator adds it after ELZ-057
  merges (owner decision 2026-11-08: the machine took about twice as long as the MacBook on the
  same tree, so it never serves pull request checks or queue runs; see "Contabo VPS").
- `symbolic-elzoo-gleam`: Gleam only; labels `self-hosted`, `linux`, `x64`,
  `symbolic`, `elzoo`, `gleam`.

The backend workflow has two jobs, chosen by the event (see "Runner tiers"). ELZ-040
removed the one-time `task/ELZ-034` candidate selector. Both workflows run only on `push` to `main`,
`pull_request` and `workflow_dispatch`. `pull_request_target` and other events
are not approved. Both backend and Gleam jobs skip fork PRs before runner
selection; a skipped job is not validation and must not be treated as evidence
for merging a fork. This does not make arbitrary same-repository code trustworthy.
The first container step refuses any backend `RUNNER_NAME` other than the three
names above (`symbolic-elzoo`, `macbook-ubuntu-elzoo-candidate`, `contabo-elzoo-1`);
`scripts/check-ci-runners.py` pins the lines of that step, so adding a fourth case arm,
changing a runner name or changing the `ERL_FLAGS` value in an arm fails the guard. It does
not read script text after the gate or the job-level `env: ERL_FLAGS`, so a later line
could still override `ERL_FLAGS`; this relies on independent review of workflow changes. `scripts/merge-queue.py` accepts only the two fast runners as
backend queue evidence (ELZ-057); Gleam evidence stays symbolic-only. The Gleam selector stays symbolic-only. A new backend machine
needs a full task-branch check and independent review before it gets `backend`.
Registration is repository-scoped; administrators must assign these labels only
to the named trusted machines. GitHub label selection is not cryptographic host
identity, and a runner name check happens after the host starts the container.

`scripts/check-ci-runners.py` requires exactly the reviewed named jobs per workflow (`check-fast`, `check-any`
in `symbolic-check.yml`, in this order; `gleam` in `symbolic-gleam.yml`),
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

## Runner tiers and the runner budget (ELZ-057)

Owner decision 2026-11-08: pull request checks and merge-queue runs run only on the **fast** runners
(`symbolic-elzoo`, `macbook-ubuntu-elzoo-candidate`, label `fast`). `main` pushes and measurement
runs may use any backend runner, including `contabo-elzoo-1`, which never gets `fast`.
`symbolic-check.yml` therefore has two jobs with identical bodies:

| Job | Runs for | `runs-on` |
|---|---|---|
| `check-fast` | `pull_request` from this repository; `workflow_dispatch` with `tier` = `fast` | `[self-hosted, linux, x64, elzoo, backend, fast]` |
| `check-any` | `push` to `main`; `workflow_dispatch` with `tier` = `any` | `[self-hosted, linux, x64, elzoo, backend]` |

The `tier` input of `workflow_dispatch` is a choice with default `fast`. The merge queue always
dispatches `fast` (`-f tier=fast`); only a person sets `any`, for a measurement run. The other
job is skipped, so every run shows one skipped job (a fork pull request skips both): a skipped
job is not evidence. The guard pins
both `if:` lines, both `runs-on` lines and the whole `workflow_dispatch` input block, and requires the
two bodies below `runs-on` to be identical, so the two jobs cannot differ from each other. It pins
the container digest, the identity gate and the action pins; it does not pin the job-level `ERL_FLAGS`
value (see above), so a change there applies to both jobs and relies on independent review. The queue accepts a run only when exactly one `check-fast`
job succeeded on a fast runner and no `check-any` job executed.

The `fast` label is an account-level setting, as `backend` is; the guard cannot prove it. Add
`fast` to both fast runners **before** the workflow with `check-fast` merges, or pull request checks
queue without a runner. The runner identity gate still allows three names in both jobs; the label,
not the name check, keeps `contabo-elzoo-1` away from `check-fast`, and the queue refuses evidence from
any other runner name.

Until ELZ-058 lands, the two fast runners are the capacity for pull request checks and queue runs,
and `main` push runs share the backend pool. A pull request check shows as `check-fast`, not `check`;
anything outside this repository that expects the old job name `check` must be updated.

### Runner budget

1. Measurement series (repeat loops, benchmarks) run on the slow or an idle runner (`tier` = `any`) and
   never more than one at a time while a merge queue is pending.
2. A measurement job states its expected duration and stays under the 90-minute job limit.
3. A coordinator does not dispatch by hand while a queue run is being identified: the queue finds its
   run by workflow, event, branch and exact head SHA. A hand dispatch on the same head can be adopted
   as the queue's run when it appears first (a `tier` = `fast` one passes as evidence, a `tier` = `any`
   one is refused at the evidence step), or it makes the match ambiguous and the queue refuses.
   Either way the queue's own run is lost, so do not dispatch by hand.

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
It dispatches `symbolic-check.yml` on that branch with `tier=fast` and identifies a **new** run
by workflow, `workflow_dispatch` event, branch and exact `head_sha`. It records
existing run IDs before dispatch, never chooses an old or merely latest green
run, and refuses an ambiguous match. A dispatch that races a head update cannot
supply evidence for the previous head.

The completed run must succeed. Its exact attempt must have one successful
`check-fast` job on `symbolic-elzoo` or `macbook-ubuntu-elzoo-candidate`, with the
`check-any` job skipped, on the same head, with a successful `Run mix check` step. The job log must contain the full
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
`System.schedulers_online()`; this caps every async module in `test/` and `pieces/`, not only the
consumer groups. With `+S 4:4` on symbolic the cap is 4, so all three consumer group modules run
at once (the module count is the bound there); with `+S 2:2` on macbook-ubuntu the cap is 2, so
at most two consumer VMs run at once (the cap is shared with the other async modules). The groups are explicit lists balanced by the
measured `total` seconds on main `0a42370`. The three
PostgreSQL consumers (`integration/sql`, `integration/jobs`, `assembly/durable-job`) and the
aggregate consumer stay in `test/export_test.exs` with `async: false`, because the CI job prepares
one disposable database. The OTP-only consumer and the plan/write tests stay there too; they
were not moved.

Each per-ID test keeps its name and its `consumer_id` tag, so the affected mode (ELZ-038)
filters them with the same `--exclude consumer_id:<id>` arguments. The 23 concurrent tests have a
240 s limit (`Elzoo.CureConsumerCase.concurrent_timeout/0`); the sequential consumers keep 120 s.
Measured basis for 240 s: on macbook-ubuntu with three concurrent VMs, after about 30 minutes of
sustained load, `assembly/request-route-retry` rose from 35.8 s (sequential) to 99.1 s in the last
completed repeat, and two later repeats went over 120 s by an unknown amount (PR #90, run
42454973591, repeats 6 and 7). 240 s is 2x that 120 s lower bound. The same series on symbolic
stayed at 123 to 125 s per repeat with 35.7 s for that consumer, which is consistent with a
slowdown of the two-core host under sustained load. The two-VM setup is to be measured by a later
repeat series, recorded in the PR. The selection test in
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

All backend machines use repository-scoped runner installations and dedicated
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

### Contabo VPS `ratahq-ci-contabo-01` (ELZ-056)

Status: **one full trial passed; to be routed for `main` pushes and measurement runs only.** The
`backend` label is not part of any diff: the coordinator adds it to runner 24 after ELZ-057 merges
and confirms it with one `tier` = `any` dispatch that lands here. The runner never has `fast`, so it
takes only the `check-any` job. Before that (ELZ-056) it was registered without `backend`, and the
label was on only for the trials (owner decision 2026-11-08, then ELZ-057). The trial record is in the
issue: run and job IDs, duration, cgroup memory peak, sampled CPU maximum, and `cpu.max`
and `memory.max` read from the host through the job container's cgroup path.
A failed or timed-out job here means removing the label. Host facts and the host-side limit
readings below come from the worker's SSH inspection on 2026-11-08, not from files in this
repository. Times are WIB (UTC+7) unless a log line is quoted.

**Trial 2 (passed).** Run 42452912435, job 128645769173, `workflow_dispatch` on `task/ELZ-056`
at `b9284c7c9dcaad70554c5c205bea16b0b5c420d3`, runner `contabo-elzoo-1`, success, job
13:00:04 to 14:12:46 WIB (06:00:04Z to 07:12:46Z), 72 min 42 s of the 90 min limit. Cold
dependency cache (first run for this runner name): `mix setup` 22 min 02 s, cache save 24 s (the
entry is scoped to `refs/heads/task/ELZ-056`, so the first `main` run saves its own).
`Run mix check` 06:25:20Z to 07:12:36Z, 47 min 16 s; `ELZOO CHECK PASSED` printed. The root
suite reported `Finished in 2625.6 seconds (191.6s async, 2433.9s sync)`; the aggregate
consumer took 711.0 s (`consumer_mix_test` 708.7 s). Stages: `ledger` 19.2 s, `ash_spike`
168.4 s (`Finished in 10.3 seconds` for its tests), `registry_load` 19.1 s, `root_suite`
2625.9 s. Job log: `ELZOO STAGE` lines, `BEAM schedulers=4 online=4`. Resource lines printed by
the job: cgroup memory peak 2,767,269,888 bytes (about 2.58 GiB); sampled CPU maximum
5.028 cores over 2,831 one-second samples (the cap is 5, so the job reached its cap). Read
from the host during the run through the container's cgroup path (not from inside the
container): `cpu.max` `500000 100000`, `memory.max` `8589934592`, `memory.swap.max` `0`;
throttling counters `nr_throttled` 45 and `throttled_usec` 2,001,766 at 07:09Z, about 69
minutes into the job and near its end. Host load average stayed about 1.4 to 1.8
and the four production containers stayed up.

What this shows: the wrapper cap applies to a real job container, and `setup-beam`, `mix setup`
and the full `mix check` pass on this machine. It is slow. The same `main` tree (`a5f0e63`,
without the ELZ-056 files) ran on `macbook-ubuntu-elzoo-candidate` in run 42451768392, job
128642319790: root suite `Finished in 1340.4 seconds`, aggregate consumer 373.3 s, `mix check`
22 min 50 s, with `+S 2:2` on four logical cores. Trial 2 took 2625.6 s for the root suite and
711.0 s for the aggregate, about 1.96 and 1.9 times as long. `symbolic-elzoo` took 1116.3 s
for the root suite (run 42448003515, job 128630949025, a different tree: ELZ-023 head
`aa16605`, so not a controlled comparison), about 2.4 times faster than this machine. The
cap does not explain the gap: the job was throttled 45 times for 2.0 s in total. The cause is
not established; slower virtual CPUs or disk on this VPS, or CPU contention from other guests
of the same host, are untested candidates. What the trial does not show: reliability over many
runs, behavior under a production load spike, or warm-cache time. Expect a warm run (no
22-minute `mix setup`) to take about 50 minutes, but that is an estimate and not an observation.
A cold run is only 17 minutes below the 90-minute limit, so a changed cache key prefix or a
longer suite may exceed it here first.

Owner decision (2026-11-08), quoted: "u may remove/rename those ci ratahq. i dont use it
anymore. use it for this development". The owner rents this machine. It runs production
workloads of the owner's `balungpisah` product, which stay untouched.

Host facts at inventory (2026-11-08): hostname `vmi2852974`, Ubuntu 24.04.3 LTS x86_64,
AMD EPYC (8 vCPU, one thread per core), 23 GiB RAM, no swap, 387 GB disk with 345 GB free,
load average 0.15, cgroup v2 (systemd cgroup driver), systemd 255, Docker CE 29.2.0
(`docker-ce 5:29.2.0` and `containerd.io 2.2.1` from Docker's apt repository, which were
already installed; the Ubuntu `docker.io` package was not swapped in because that would
disturb the production containers). Other workloads: nginx on ports 80 and 443 and four
containers (`balungpisah-core`, `balungpisah-tensorzero`, `balungpisah-minio`,
`balungpisah-postgres`). Headroom was about 22 GiB of RAM and an idle CPU. The other Contabo host in the
owner's SSH config (`ratahq-dev-contabo-01`, 3 cores, 7.8 GiB) was rejected: it
is below the selection rule used for ELZ-056 (at least 4 cores, 8 GiB RAM and 40 GB free
disk), which is not a repository requirement for the other runners.

Runner: version 2.338.2, tarball SHA-256
`baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40` (checked with `sha256sum -c` on the host; equal to the
GitHub release digest read through `gh api` and to the macbook record above), installed at
`/opt/actions-runner/elzoo-backend`, system account `elzoo-ci` (uid 999, in group `docker`),
service `actions.runner.balungpisah-elzoo.contabo-elzoo-1.service` (enabled, running as
`elzoo-ci`). It was registered repository-scoped with a short-lived registration token that
was piped over SSH into `config.sh` and never written to a file or log.

**Shared Docker daemon.** The runner's Docker access is root-equivalent and the daemon is
the same one that runs the production containers above. A job container is not a sandbox:
hostile or buggy PR code could reach those containers. The accepted mitigation is only
trusted code in this private repository plus the resource cap below. This is the owner's
accepted risk. Rootless Docker for `elzoo-ci` is a possible follow-up; it is **not** done.

**Resource mechanism.** Job containers are children of `dockerd`, not of the runner
service, so a systemd cap on the service does not limit them. Two caps apply:

- The service drop-in `/etc/systemd/system/actions.runner.balungpisah-elzoo.contabo-elzoo-1.service.d/10-elzoo-cap.conf`
  sets `CPUQuota=500%`, `MemoryMax=10G`, `MemoryHigh=9G` and `TasksMax=8192` for the runner
  listener and worker processes.
- A root-owned wrapper `/opt/actions-runner/elzoo-backend-bin/docker` (mode 755, a
  `#!/usr/bin/python3 -I` script) is first in the runner's `.path`. For `docker create` and
  `docker run` it adds `--cpus=5 --memory=8g --memory-swap=8g`; it then replaces itself with
  `/usr/bin/docker` by `os.execv`, so every other subcommand keeps its arguments,
  environment, stdin, stdout, stderr and exit code. The first version was a `/bin/sh`
  script and broke the first trial (see below): Ubuntu's `/bin/sh` is `dash`, which drops
  environment variables whose names contain a hyphen, and Actions passes inputs that way
  (`INPUT_OTP-ARCHITECTURE`). Do not rewrite the wrapper as a shell script.
  After the fix, as `elzoo-ci`, `INPUT_OTP-ARCHITECTURE=64` reached the container's
  initial environment through the wrapper (it was missing before); `docker exec` output
  and the exit code (7) matched plain `docker` by SHA-256 of stdout and stderr, and
  `getconf LONG_BIT` printed `64`.

The runner runs one job at a time, so the job container cap is the practical limit: it
leaves about 3 cores and 15 GiB (23 GiB minus 8 GiB) for the production workloads. The
service cap covers only the runner's own processes and does not add to the container cap;
worst case with both at their limits is 10 GiB plus 8 GiB. Memory observed on the other
runners (2.1 to 2.8 GiB cgroup peak, 3.3 to 5.0 sampled cores) fits inside the container cap,
though a CPU peak near 5 cores may be throttled; the cap is 5 of 8 cores, and the
service and container CPU caps could add up to 10 cores' worth, which only the 8 vCPUs
of the host limit. A job that reaches 8 GiB is killed by the
kernel; that is the intended protection, not a failure of the host.

**Trial 1 (failed, kept as evidence).** Run 42452504044, job 128644528184, `workflow_dispatch`
on `task/ELZ-056` at `1406f40c8d98b0218f8bdf8afb80998522086f39`, runner `contabo-elzoo-1`,
job 12:53:20 to 12:55:05 WIB (05:53:20Z to 05:55:05Z, 1 min 45 s). The steps before
`Run erlef/setup-beam` passed: container start, PostgreSQL, checkout, the guard scripts and the
38 merge-queue tests. `setup-beam` failed with `##[error]otp-architecture must be 32 or 64`;
`mix setup` and `mix check` were skipped. Cause: the `dash` wrapper dropped
`INPUT_OTP-ARCHITECTURE` (reproduced on the host, see above). During this job, read from the host,
the job container had `cpu.max` `500000 100000`, `memory.max` `8589934592`,
`memory.swap.max` `0`, Docker `NanoCpus` 5000000000, `Memory` 8589934592, and
`nr_throttled` 0; the cgroup memory peak seen was 1,059,106,816 bytes in the early part of
the job only. This shows the cap applies to a real job container. It says nothing about a full
`mix check`, which did not run. The `backend` label was removed after the failure.

**Limit of the cap.** The wrapper caps only containers that the runner creates through its
`PATH`. By the upstream actions/runner contract (not re-checked here), the runner mounts the
Docker socket into job containers, so code inside a job can
start containers with no cap, or reach the production containers. The cap is a guard
against accidents and runaway builds, not isolation from hostile code.

**Network.** The pinned `ubuntu:24.04` image is pulled by digest. Inside a container
`builds.hex.pm`, `repo.hex.pm` and `github.com` resolve over IPv4 and answer HTTPS 200.
The Docker bridge has no IPv6, so IPv6 requests fail by design; host and container resolvers
returned only IPv4 (v4-mapped) answers and no NXDOMAIN, unlike the macbook failure on
`builds.hex.pm`. Jobs here are IPv4-only. No registry mirror is configured; Docker Hub
reachability was not an issue on 2026-11-08.

**Retired runner.** The host previously had an unused runner install for another repository
(`sabrang-mdp/rakan`, service name `actions.runner.sabrang-mdp-rakan.sabrang-ci-ephemeral-rakan-v98`).
It had no `.runner` registration file, no systemd unit and no process. Its directory was
renamed to `/opt/actions-runner.retired-rakan-20261108` (about 953 MB of `_work`) and not
deleted. The owner may delete it.

**ERL_FLAGS.** The workflow sets `+S 4:4 +SDcpu 1 +SDio 1` for `contabo-elzoo-1`, the same as
`symbolic-elzoo`: four schedulers fit inside the 5-core cap on an 8-core host.

Operation, as for the other runners: `ssh ratahq-ci-contabo-01 'systemctl status
actions.runner.balungpisah-elzoo.contabo-elzoo-1.service --no-pager'`. To withdraw the
machine, remove the `backend` label after the current job finishes; the other two runners keep
accepting backend jobs. Do not restart the service while it is busy.

### Gleam compiler download (ELZ-060)

The Gleam job installs the pinned compiler (v1.19.2) with `spikes/gleam_ui/scripts/setup_gleam.py`, called
by `scripts/setup.sh` in the step `Install the pinned Gleam compiler` of `symbolic-gleam.yml`.
`setup-beam` installs only OTP there. Since ELZ-060 the archive comes from the release-asset API,
`GET https://api.github.com/repos/gleam-lang/gleam/releases/assets/<id>` with
`Accept: application/octet-stream` and the job's `github.token` (step `env`, read-only; the guard allows
`github.token` on that one step only, pins the step text, its position (right after `setup-node`) and its end, and
rejects `secrets`, `github.token`, `github[...]` and `toJSON(github|secrets)` spelled in any case and spacing
anywhere else in either workflow; this is a source-convention check, not proof against every YAML form;
`setup.sh` unsets `GITHUB_TOKEN` right after the download so `npm ci` and the Playwright install do not see it).
The API answers with a redirect to a
signed storage URL; the script follows it by hand, refuses any redirect that is not plain HTTPS (no user info, no
other port, no percent or backslash tricks) to `github.com`, `*.github.com` or `*.githubusercontent.com`, and sends
no `Authorization` header to the storage host. It checks
the pinned size and SHA-256 and stops on any mismatch or error; only HTTP 500, 502, 503 and 504 are retried (three
attempts, 2 s and 4 s waits). The API route can fail the same way as the browser URL: a reviewer saw HTTP 500 or
504 on about 9 of 10 requests from one machine between about 17:35 and 17:45 WIB on 2026-11-08, so a job can
still fail closed; a second source (a hash-verified mirror) is planned as ELZ-061.

| Platform | Asset ID | Size (bytes) | SHA-256 |
|---|---|---|---|
| Linux x86_64 (CI) | 633423401 | 10565692 | `2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f` |
| Linux aarch64 | 633423257 | 10126116 | `d1d1a9d53f6b317c0563a4806873c8ccace54291ead023373728af379402d4f1` |
| macOS arm64 | 633423162 | 9234148 | `fa7c6113e162ab1d979f72e7dde3e907b87e4b30c518af178768e577d180324d` |
| macOS x86_64 | 633423317 | 9702221 | `c578192530507b868c4a6c8cb7ad5d2ab0830890257f41036f17c82853f19d05` |

The hashes are unchanged from the earlier browser-URL version; the asset IDs, sizes and hashes were read
from `GET /repos/gleam-lang/gleam/releases/tags/v1.19.2` on 2026-11-08 (the API `digest` fields equal the pins),
and the Linux x86_64 archive downloaded through the API had exactly the pinned size and hash.

Reason: from about 16:20 WIB on 2026-11-08 the browser URL
`https://github.com/gleam-lang/gleam/releases/download/v1.19.2/...` answered `HTTP Error 504: Gateway Time-out`
from the job container (Gleam run 42467133717, job 128689127890, step `Run ./scripts/setup.sh`). That is the first
step of every Gleam job, and the merge queue needs a green Gleam run, so no pull request could merge. The same
URL answered 200 after 12 s from a developer machine at about 16:50 WIB, so the outage is intermittent or slow,
not proven fixed. `spikes/gleam_ui/scripts/test_setup_gleam.py` (21 tests, run by `check.sh`) covers the script with a fake
HTTP layer and a loopback redirect server (the target is never contacted): success, token only to the API host, checksum and size mismatch, 504 retries, no retry on other
errors, refused redirect hosts, network errors, archive shape and unsupported platforms.

Limits: this depends on `api.github.com` and the storage host that the redirect names; it does not show that the
browser URL works again. Without `GITHUB_TOKEN` the unauthenticated API rate limit (60 requests per hour per
address) applies. A changed pin (new Gleam version) needs new asset IDs, sizes and hashes in the script, this
table and the README. Platforms other than the four above stay unsupported.

### Per-test limits of two slow tests (ELZ-062)

Owner approval 2026-11-08 ("1.", relayed by the coordinator): raise the per-test limit of the two tests that timed out on
`contabo-elzoo-1` to 300 s, so that machine can take `any`-tier runs. Time limits only: no assertion, scenario or proof
changed, and no other limit changed (not the 120 s default in `test/test_helper.exs`, not the 240 s of the concurrent
consumer groups, not the inner consumer limits).

- `pieces/workflow/approval/test/elzoo/approval_test.exs`: `@tag timeout: 300_000` on "negative control: dropping g_self
  from the gate list is rejected inside self_approval_refused" (a Cure proof check).
- `test/export_test.exs`: `Elzoo.CureConsumerCase.consumer_tests/2` takes one `timeout:` for all IDs of a call, so the three
  PostgreSQL consumers are defined by two calls: `integration/sql` and `integration/jobs` keep 120 s, `assembly/durable-job`
  gets `timeout: 300_000`. The selection test "affected selection only filters the existing consumer tests" asserts the
  limits exactly (120 s, 300 s for `assembly/durable-job` in `Elzoo.ExportTest`, 240 s for the concurrent groups); it was
  updated for the one new value and fails if that value or an ID's limit is wrong (checked locally by expecting 120 s).

Measured basis. CI logs print no per-test times, so a measurement branch (`measure/ELZ-062`, never merged) ran the full root
suite as `mix check` does in full mode with `--slowest 60` and every per-test limit raised to 900 s, one run per machine on
the same tree (`main` at `f4e3283`):

| Test | `symbolic-elzoo` | `macbook-ubuntu-elzoo-candidate` | `contabo-elzoo-1` (8 cores) |
|---|---|---|---|
| approval negative control | 39.1 s | 45.3 s | 93.1 s |
| `assembly/durable-job` consumer | 77.6 s | 91.3 s | 128.7 s |
| `integration/sql` consumer | 18.8 s | 26.1 s | 52.8 s |
| `integration/jobs` consumer | 13.9 s | 17.0 s | 37.6 s |
| root suite | 1266.5 s | 1492.2 s | 3136.7 s |

Runs 42500718766, 42497402091 and 42497486307 (jobs 128792642738, 128782613975, 128782875563). On Contabo the approval test
exceeded 120 s in the two earlier full runs (42484236992 and 42492726966) and took 93.1 s here, so the spread on one
machine is large; 300 s is 2.3 times the slowest measured time (128.7 s) and 3.2 times the approval test's 93.1 s. It is a
margin, not a performance target. A hung test now costs up to 300 s instead of 120 s before it fails. The measurement
runs of that branch failed two tests each, as expected there (the selection test's 120 s expectation and the test that reads
`scripts/run-ci-check.sh`, which the branch changes). Host readings on Contabo: no throttling in 99 samples, host load
average (1 minute) at most 2.94, cgroup memory peak 2.89 GB; peaks on the fast runners 3.45 GB (symbolic) and 2.75 GB (MacBook).

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
cache so it is saved after `mix setup` and added the action SHA-pin check. ELZ-056 added
the Contabo VPS runner as an unrouted candidate. ELZ-057 added the fast tier (pull request and queue runs on the fast runners only) and the runner budget rules. ELZ-060 moved the Gleam compiler download to the release-asset API after the browser URL answered 504.
