# Clean-check handoff for the current exemplar

ELZ-012 records reproducibility of the existing exemplar and selected P1/P2/P3
Assemblies. The task's historical `core/grounding` and `verification/clean-check`
headings name this evidence handoff: no executable Piece or readiness promotion
is created, and `core/grounding` remains a planned index owned by ELZ-033.

## Reproduce

Use an empty directory, the configured private remote and a recorded revision
from the evidence table below. Install Elixir 1.20.4 / OTP 29.1.2, Git, Mix/Hex
and access to the pinned Git and Hex dependencies; supply a disposable
PostgreSQL database through `ELZOO_TEST_DATABASE_URL` (never a personal or
production database). The recorded local database was the disposable test database.
Do not print the URL or dump your environment.

```sh
git clone <configured-private-remote> elzoo-clean
cd elzoo-clean
git checkout --detach <recorded-revision>
git status --short
# Confirm these four paths do not exist before the first setup:
# deps, _build, spikes/ash_foundation/deps, spikes/ash_foundation/_build
unset MIX_ENV MIX_DEPS_PATH MIX_BUILD_PATH ERL_LIBS
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
# Set ELZOO_TEST_DATABASE_URL privately to your disposable database.
mix setup > ../elzoo-setup.log 2>&1
elz012_setup_status=$?
printf 'mix setup exit=%s\n' "$elz012_setup_status"
test "$elz012_setup_status" -eq 0 || exit "$elz012_setup_status"
mix check > ../elzoo-check.log 2>&1
elz012_check_status=$?
printf 'mix check exit=%s\n' "$elz012_check_status"
test "$elz012_check_status" -eq 0 || exit "$elz012_check_status"
# Also require ELZOO CHECK PASSED in ../elzoo-check.log.
```

Keep logs outside the clone if checking an empty `git status --short` afterward.
The root commands choose their test environment themselves. No `--affected`,
filter or targeted test substitutes for this full check. Compare the two
lockfile hashes before/after and inspect any source change before accepting.
Check `deps/cure` HEAD equals `208248063d64e621782cd26dd30698ee42850a89` and its
tracked state is clean. A separate `MIX_ENV=test mix run --no-start` inspection
can read `:code.lib_dir(:cure)` and `:code.which(Cure.Compiler)`; these must point
inside this clone. The emitted `_build/test/lib/elzoo/ebin/elzoo.cure.manifest`
records the fingerprint and project modules. The first setup must compile
real Cure; a later matching-fingerprint skip is expected, not fresh evidence.

The run used macOS arm64, OTP 29.1.2 / ERTS 17.1.1 and Elixir 1.20.4. Root and
Ash-spike `deps`/`_build` began absent, and Git alternates were absent. Machine
`~/.hex`, `~/.mix` and Hex package caches existed. This is a fresh source/build
checkout with network access, not a cold machine, offline build or independent
cold installation of every provider. The isolated Ash project has its own
lock/build/dependency directories; no compiled artifacts were copied into the
fresh root or spike.

## Recorded runs

| Run | Revision | Result |
| --- | --- | --- |
| Fresh remote clone, setup then full check | `36e097819e6039bb56c43eea3092c662df738c45` | Setup exit 0; full check exit 0, 32 Ash + 642 root tests, ELZOO CHECK PASSED |
| Follow-up after normal main merge of ELZ-060 | `d70bee6e22e830019065f04b509d367bc9b446eb` | Setup exit 0; full check exit 0, 32 Ash + 642 root tests, ELZOO CHECK PASSED |
| Latest follow-up after normal main merge of ELZ-049 | `907c37f02ed857b4e83d55fb3a9929f3525e8419` | Setup exit 0; full check exit 0, 32 Ash + 642 root tests, ELZOO CHECK PASSED |

The first run began with no builds/dependencies and compiled 29 project Cure
modules after building pinned Cure. The follow-ups retain that clone's build
artifacts and are explicitly warm rechecks, not new fresh-clone claims.
The inherited ELZ-060 changes concern Gleam setup/CI; none is an ELZ-012-authored
runtime or protected-file change. ELZ-049 then changed consumer-test scheduling;
its inherited tests are unedited and the full check was repeated again. These
runs do not execute the separate Gleam
spike. Its CI acceptance belongs to its own workflow and merge record.

## Grounding and boundaries

| Claim | Grounding reached by the full check | Boundary |
| --- | --- | --- |
| Zero/one-output composition | Pinned Cure compiles `drop_has_no_output` and `drop_keeps_downstream`; composition tests run owned-source audit and incompatible-connection rejection | Selected laws only; erased Elixir callers must honor the ABI; no compiler-soundness proof |
| Exemplar direct/OTP behavior | Independent set/sum model, nested-consumer and volatile-restart scenarios | Finite traces; synchronous hops; unbounded volatile deduplication, not arbitrary crash equivalence |
| P1 request/route/retry | Three supplied-decision label laws and their compiler/audit checks, FalseLabelLaw/MutatedLabelStep/WrongLabelOperator rejections, root S1–S22 composition scenarios | Laws cover label_step only; hop partial failure and restart history loss remain |
| P2 durable jobs | Store CAS, indeterminate-write, outbox, real PostgreSQL/Oban and process-kill/restart scenarios | Database durability/locking is a pinned upstream contract under host configuration; no exactly-once execution or schema upcast |
| P3 publication | Root suite plus aggregate: declaration/action types, EffectIntent history/grounding, loopback publication, recovery/quarantine, refusal/concurrency and size-guard mutation scenarios | No live vendor/TLS/DNS certification, physical cancellation, rollback or external exactly-once guarantee |
| Source copying | Aggregate over all ready IDs and only the per-ID consumers printed by selection; runtime stages shown in the log | Consumers reuse root-built provider artifacts, not independent cold provider installs; edited downstream applications are excluded |

Law and test names in this table come from the hashed sources and manifests;
the log proves that those sources compiled and that the counted suites passed,
not that each named law printed a line.

`core/effect`, `delivery/effect-intent`, `integration/http`, `integration/json`
and `assembly/http-job` have no fixed per-ID consumer: their bundle tests run
in the root suite and the aggregate. Root-only cross-Piece tests do not
silently become copied-bundle tests. The separate historical ELZ-011 export
utility is outside `mix check`; its earlier 221-test record is not counted as
an ELZ-012 command or result. The current selection report is retained with
this task's evidence so the exact coverage can be inspected.

[Selected manifest grounding](../work/ELZ-012-evidence/selected-grounding.json)
identifies declared claims and source references; it is metadata, not a second
execution result. Actual logs and exit statuses ground the recorded runs.
Pinned Cure is trusted for selected checking; Elixir/OTP, Req/Jason,
Ecto/Postgrex/PostgreSQL and Oban retain upstream implementation ownership.
Runtime timing/counts are observations in these fixtures. Telemetry is not a
durable audit record, billing ledger or control receipt; start/per-call config
and OTP stop do not imply hot reconfiguration or business drain. No new law,
provider adoption, runtime feature or whole-catalogue assurance is created.

## Evidence record

The executed record, exact review and revision relationship are in
[ELZ-012](../work/ELZ-012.md), with [early review](../work/ELZ-012-early-review.md)
and the adjacent evidence directory. Fresh-clone results and the explicit
post-main-merge follow-up are separate observations. Historical bootstrap
[validation](07-bootstrap-validation.md) remains unchanged; its older pin and
counts are not this task's acceptance baseline.

## Next work

Use the dated published-issue snapshot below as discovery only. Re-read each
live Contract and dependencies and check its deterministic remote task branch;
labels and the canonical manifest are not claim locks or proof of merge
acceptance. Newer published issues can exist outside the manifest snapshot.

Coordinator-communicated, not published: **ELZ-050** (catalogue admission and
dispositions) is the coordinator's stated next task; no issue, task file or
manifest row exists at this recorded revision, and the coordinator publishes
it. This handoff does not supply its scope or decisions. No unpublished task
issues are created here.

Issues #89 (ELZ-049) and #100 (ELZ-060) were merged after the first snapshot and
appear in the recorded follow-up runs; #12 is this task and is omitted. Treat
none of the rows as a claim lock. The snapshot file is
[open-issues.json](../work/ELZ-012-evidence/open-issues.json).

Published/readable snapshot at 2026-11-08T13:14:17.724139+00:00:

| Issue | Published title | Use |
| --- | --- | --- |
| [#99](https://github.com/balungpisah/elzoo/issues/99) | ELZ-059 — Light pull request checks; staggered full runs of main; freeze rule | Recheck dependencies and remote claims; not a lock |
| [#98](https://github.com/balungpisah/elzoo/issues/98) | CI main status: freeze classifications (ELZ-059 tracking) | Recheck dependencies and remote claims; not a lock |
| [#96](https://github.com/balungpisah/elzoo/issues/96) | ELZ-058 — Remove redundant full CI runs without weakening the evidence | Recheck dependencies and remote claims; not a lock |
| [#95](https://github.com/balungpisah/elzoo/issues/95) | ELZ-057 — Route backend checks by runner tier; add the runner budget rule | Recheck dependencies and remote claims; not a lock |
| [#76](https://github.com/balungpisah/elzoo/issues/76) | ELZ-044 — Make the CI guard check workflow structure, not line shapes | Recheck dependencies and remote claims; not a lock |
| [#70](https://github.com/balungpisah/elzoo/issues/70) | ELZ-041 — Trial an advisory ARM64 PR lane on an M1 Pro MacBook | Recheck dependencies and remote claims; not a lock |
| [#48](https://github.com/balungpisah/elzoo/issues/48) | ELZ-031 — Specify exact money amounts and the currency registry | Recheck dependencies and remote claims; not a lock |
| [#46](https://github.com/balungpisah/elzoo/issues/46) | ELZ-029 — Specify the OS-process Adapter boundary | Recheck dependencies and remote claims; not a lock |
| [#45](https://github.com/balungpisah/elzoo/issues/45) | ELZ-028 — Specify single-owner leases fenced by record revision | Recheck dependencies and remote claims; not a lock |
| [#44](https://github.com/balungpisah/elzoo/issues/44) | ELZ-027 — Specify schedule occurrence identity and overlap policy | Recheck dependencies and remote claims; not a lock |
