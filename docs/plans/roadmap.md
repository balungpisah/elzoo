# Product-led catalogue roadmap

ELZ-033 adopts planning policy and scope accounting. It does not implement the
release plan. The dedicated roadmap coordinator retains independent review,
GitHub merge, acceptance, cleanup and issue closure; this worker's delivery
boundary is a checked self-contained PR. The task Contract is
[live #55](https://github.com/balungpisah/elzoo/issues/55), copied exactly to
[ELZ-033](../../tasks/ELZ-033-product-led-roadmap.md).

## Authority and reproducibility

[release-plan.json](release-plan.json) is the **one canonical planning
status/dependency source**. [views.md](views.md) and
[dependencies.mmd](dependencies.mmd) are generated from it, including release
prerequisites and published issue links. The [task DAG](../development/02-task-dag.md)
links to these views instead of maintaining another graph or status board.
Published issue bodies remain task Contracts, and remote deterministic branches
remain claims. A roadmap status cannot override either. Historical closed-issue
observations are not newly asserted acceptance.

The manifest preserves the 97-row inventory at main
`404d159a122d18a22554c5688aa79199e4d5c124` (33 ready subsets, 19 planned,
45 deferred). Normal merge of main `32aef4e7dba40231257e2a91095910377c5c4ab9`
then brought ELZ-010's three ready manifests: current inventory is 36 ready,
16 planned and 45 deferred, still the same 97 IDs. Baseline statuses are retained
separately; current ready Contracts are read from those merged manifests. This
is catalogue reconciliation, not a takeover of the owner's final acceptance.
Each ID has exactly one primary planning owner, a disposition and
its actual ready Contract or remaining gap. Ready manifests were read; their
hashes and scoped Contract summaries bind this accounting to actual source
metadata. No registry status, ready manifest, schema or generated ledger is
changed. Later catalogue additions must be explicitly reconciled, preserving
this baseline; do not silently replace it with a fresh count.

The four external proposal inputs are reconciled here rather than required at
runtime or at check time. Their SHA-256 digests are retained in the manifest.
All necessary product mappings, scoped job briefs, reuse directions, failure
acceptance, dependencies, blockers and release gates are repository-owned.
`RC-00` maps to published `ELZ-033`; RC-01 through RC-43 remain planning labels,
not issue IDs or permission to implement. No remaining RC proposal is
mechanically published by adoption.

Run from the repository root with the recorded baseline commit available in
local Git history (fetch history first in a shallow checkout):

```sh
python3 scripts/check-roadmap.py --write
python3 scripts/check-roadmap.py --live
```

`--write` derives only the two roadmap views. The default checks their exact
bytes, original/current inventory coverage, unique owners/references, published
task dependencies, ready manifest hashes, candidate separation, acyclicity,
release ordering, prerequisite merge ancestry and local Markdown link targets.
`--self-test` exercises nine in-memory invalid-plan controls. Job `outputs`
are exclusive planning deliverables; separately labeled `contributions` retain
historical/supporting work without assigning a second primary owner.
`--live` additionally compares all published issue body hashes and direct
prerequisites with GitHub, and checks the exact #55 copy. A changed live Contract
requires reconciliation; do not regenerate a stale assumption into acceptance.
These checks establish structural planning consistency, not runtime correctness.

## Selection and release meaning

A published, admitted Piece can be selected for a concrete product aim before
a new Assembly example exists. Admission still names a caller, invariant,
failure paths, state/effect boundary, Needs, reuse comparison and scoped evidence.
The source catalogue remains reusable: no wrapper merely to fill an inventory
row, no implicit global runtime, and no quota to reproduce 402 historical patterns.
New pure policy belongs in Cure when suitable; OTP and maintained libraries
supply runtime/integration mechanisms. Ready behavior changes require a new
Piece ID with migration and source-copy/namespace evidence.

The generated product map describes conditional consumer possibilities:
V1 application/workflow/identity/artifact/bounded-agent capabilities; V2
money, pricing, reconciliation, richer providers and infrastructure; V3
research-gated distributed/device/classified-record directions. None is a
claim that a complete product can currently be assembled. Consumers supply
business policy, UI, ingress/authentication where noted, deployment and credentials.

V1/V2 gates select all same-release jobs except `examples-later` and `research`,
with V2 also waiting on V1 acceptance. Every selected job needs accepted scoped
outputs or a reviewed resolution naming exact upstream/composition/index evidence.
A conditional resolution does not make a deferred Piece ready. Integrated
source-copy, provider-pin closure, schema/module/record collision checks and
cross-Piece failure evidence are required. ELZ-012 is the existing exemplar's
clean-check handoff, never blanket acceptance for future V1/V2 work. Final
release-acceptance issues are admitted only after the selected set is frozen;
this task publishes none. V3 has admission outcomes, not an implementation promise.

RC-37–41 are explicitly later new Assembly/example work. They remain visibly
incomplete and need a separately authorized examples wave. Deferring polished
examples does **not** defer Piece tests, copying checks, provider conformance,
negative controls or failure evidence. Existing ELZ-010/011/012 retain their
published scope and dependency chain.

## Exact non-implementation dispositions

`domain/value-types` is a discoverability index for concrete value semantics,
initially the separately admitted `domain/money` candidate (ELZ-031).
`domain/saas-controls` indexes `domain/membership`, `domain/authorization`,
`domain/entitlement` and `domain/quota`. Their primary planning owner remains
RC-32; its index decision is resolved by ELZ-033. Index presence says nothing
about child availability. No executable wrapper, new metadata enum or ready
source is invented. A catalogue-schema representation change needs its own
reviewed task and checker evidence.

`core/grounding` has an evidence-index planning deliverable owned here by
ELZ-033: [claim distinctions](../../AGENTS.md#verify-the-actual-claim), the
[public checking harness](../../lib/mix/tasks/check.ex),
[claim-level manifests and ledger](../../LEDGER.md),
[operational applicability](../operational-contracts.md), and
[source/provenance contract](../consuming.md). This linked index is not an
executable Piece, source bundle, assurance badge or new proof. The registry
entry stays planned. ELZ-012 still owns its published clean-check handoff;
its task body and acceptance are unchanged. A reusable grounding tool/export,
if actually needed, requires a separate admitted task, not a readiness promotion
based on that handoff.

RC-42's durable-operation gap is separate from all 97 baseline IDs. Existing
`delivery/idempotency` and `delivery/windowed-idempotency` remain volatile.
Test provider uniqueness plus domain/result transaction composition first:
restart duplicates, same key/different payload, concurrent claims, partial or
indeterminate commit and retention expiry. Tested composition can close the
gap without an engine or new Piece. External exactly-once Effects are not inferred.

## Existing Relay before any new dispatcher

RC-43 first assesses ELZ-010's existing `integration/jobs` Relay, then the
ELZ-011 Effect and ELZ-023 intent boundaries. Source inspection at
[`18287d22a4b694581af6d1788a84a4868c1b47d3`](https://github.com/balungpisah/elzoo/tree/18287d22a4b694581af6d1788a84a4868c1b47d3)
in [PR #54](https://github.com/balungpisah/elzoo/pull/54) covered:

- [Relay source](https://github.com/balungpisah/elzoo/blob/18287d22a4b694581af6d1788a84a4868c1b47d3/pieces/integration/jobs/lib/elzoo/jobs/relay.ex): one Store stream, bounded oldest page, `handle(item)`, ack only on `:done`; skips/raises remain pending and the pass continues within that page. Ack is accepted only for `{:committed, _}`. Fixed interval or manual polling, OTP start/stop; no cross-stream discovery.
- [Jobs Contract and tests](https://github.com/balungpisah/elzoo/blob/18287d22a4b694581af6d1788a84a4868c1b47d3/pieces/integration/jobs/test/elzoo/jobs_test.exs): persisted enqueue IDs, held unique-lock retry, real Oban execution, ack/skip/in-page continuation, full-page starvation and option validation. A full page of permanently skipped offers blocks later offers. Reading these tests is not running or accepting them.
- [ELZ-010 Contract](https://github.com/balungpisah/elzoo/blob/18287d22a4b694581af6d1788a84a4868c1b47d3/docs/work/ELZ-010.md): queue submission stream, Run-stream CAS, attempt fencing, cancellation and crash recovery; no general externally idempotent dispatch guarantee. Oban uniqueness is advisory-lock/query behavior, not a database uniqueness constraint or a proof of exactly-once Effects.

The branch was open when first inspected and subsequently merged through PR #54
as `32aef4e7dba40231257e2a91095910377c5c4ab9`. This task merged that main revision
normally; Relay source matches the inspected final head. Task acceptance remains
exclusively owned by the existing
coordinator at
<thread link redacted>.
That thread was read before status reconciliation. No branch, issue or runtime
source owned by that team is edited here. RC-43 requires final accepted
merge-SHA evidence; a Git merge alone is not that evidence. The owner reported
branch/worktree cleanup and posting the ELZ-028 evidence, while merge CI and
issue closure were still pending at reconciliation. Reuse the accepted
Relay wherever it fits. Any missing crash-before-send, timeout-after-acceptance,
crash-before-ack, cancellation or unknown-outcome path must be tested in the
ELZ-011/023 composition before deciding a residual Piece is needed.

`state/schema-evolution` remains RC-01: PR #54 explicitly supports v1 only and
refuses other record/args versions, without upcast or rolling-version support.
`state/scheduler` remains RC-02: persistent recurring scheduling, timezone/DST
and misfire policy do not follow from job execution or the timer recipe.
`state/lease` remains conditional ELZ-028: PR #54 records O5/O6/O10 and source
observations about Oban timestamp ack guards, time-based rescue (including live
jobs), no renewal and node-clock timestamps. The composed Run revision/attempt
fence is narrower than ELZ-028's store-clock/renewal/atomic-change Contract.
These are inputs to its owner decision, not a new lease implementation or
permission to dispatch one. The ELZ-010 coordinator owns that evidence handoff on #45.

## Ownership and bounded execution

Only the adoption worker runs under this assignment; no recursive delegation.
After adoption acceptance, the dedicated roadmap coordinator may prepare the
bounded ELZ-022/024/026 wave under [preflight.md](preflight.md). At most **three
total implementation workers**, counting an active ELZ-010 worker: at most two
new Piece workers while it is active. Reserve one independent review slot and
coordinator capacity. This is a resource limit, not a measured speedup claim.

Use this sequence: ELZ-022 and ELZ-026 are the first two candidate slots once
their gates pass; ELZ-024 follows the exact-action/evidence decisions and an
available slot. A blocked candidate does not reserve a slot. If ELZ-010 is
still active it continues unchanged; do not exceed the total by treating it as
another pool. No other RC or ELZ task is dispatched by this wave authorization.

Each implementation gets its own tool-provided isolated workspace, deterministic
`task/ELZ-###` branch and first-push claim containing login, session ID, UTC and
base SHA. Record actual worker/thread identity, workspace, base and claim SHA
at dispatch; future IDs are deliberately not fabricated here. Workers report
against the canonical plan; only the coordinator reconciles its statuses.
No automatic cross-worktree integration is assumed. Ordinary Git pushes and
GitHub PR integration are the authorized mechanics; no extra coordination
worktrees, sibling checkout access, patch shuttling, or Delta-specific merge
operations are required.

The coordinator owns shared-interface prerequisite decisions and review order.
Piece workers own only their named directories, tests and scoped metadata rows.
Shared Envelope/Port/results stay frozen; changes need a separately admitted,
reviewed prerequisite and a new ID when ready behavior changes. No provider,
`mix.exs`, lockfile or provider-registry change without separately admitted
ownership. In particular, a suggested libgraph or Ash dependency is not
permission to change pins in the first wave.

The coordinator serializes generated-ledger integration: source metadata stays
scoped, then `mix elzoo.ledger` runs after normal main merges; never hand-merge
generated rows or overwrite another worker's metadata. This documentation task
neither changes metadata nor regenerates the ledger. Isolate PostgreSQL clusters,
ports, fixtures and build output for every validation worker; no personal DB,
no cross-path Cure cache copies. Keep `ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'`.
The existing machine A backend queue serializes backend CI; Gleam has its existing
role queue. No hosted fallback, service disruption, additional runner or workflow
change. The parent receives review/merge/cleanup; this worker neither watches
PRs nor merges them.

## Reconciliation: Cure pin migration (ELZ-048)

ELZ-047 (#84, merged 230cc5b) moved the Cure pin to `balungpisah/cure-lang`
`208248063d64e621782cd26dd30698ee42850a89` and changed only the `upstream`
reference URL and the pin named in prose inside 24 ready Piece manifests. No
ready Contract, summary, disposition, owner or status changed. ELZ-048 (#86)
re-recorded the 24 `manifest_sha256` values against the merged manifest bytes
and regenerated the views (no change in them). This is a reconciliation of an inherited pin
migration, not a new acceptance; the Piece evidence binds to the fork revision
as recorded in `docs/dependencies/forks/cure.md`.

## Catalogue admission rule and dispositions (ELZ-050)

The owner set the admission rule on 2026-11-08: all planned and deferred
catalogue entries are open for development as part of the build plan;
demand-led admission applies only to gaps outside the catalogue; prefer a
maintained Elixir library and build only what does not exist; copy or
clean-room only for a concrete recorded reason. ELZ-050 ([live #103](https://github.com/balungpisah/elzoo/issues/103),
copied exactly to [ELZ-050](../../tasks/ELZ-050-catalogue-dispositions.md))
records one decision-ready disposition per planned or deferred ID in
[catalogue-dispositions.md](catalogue-dispositions.md), rendered from
hand-authored records by `docs/work/ELZ-050-tools/render_dispositions.py` with
a coverage check and a Hex re-read kept under `docs/work/ELZ-050-evidence/`.
The owner decisions it rests on are in
[owner-decisions-2026-11-08.md](../work/research/owner-decisions-2026-11-08.md),
merged from `research/ecosystem-survey`. The owner's build order is telemetry,
object store, notification, audit log, then the first model boundary; the
payments provider and the message broker stay explicit open owner choices.
A disposition changes no planning status, readiness, manifest or registry row
in this manifest; each later task still needs its own published issue,
Contract review, evidence and merge.

## Verification and limits

The durable commands are the roadmap checker above, `git diff --check`,
`python3 scripts/check-claims.py`, `python3 scripts/check-ci-runners.py`,
`mix setup` and full `mix check`. Preserve the Cure pin that `mix.lock` and
`registry/providers.json` record (since ELZ-047: `balungpisah/cure-lang`
`208248063d64e621782cd26dd30698ee42850a89`, see `docs/dependencies/forks/cure.md`;
before that, upstream `a004c335`), Elixir 1.20.4 and OTP 29.1.2.
Actual execution results and blockers are recorded in [validation.md](validation.md).
Independent review must inspect the actual policy/evidence diff at its exact
head. The coordinator owns affected rechecks, machine A checks, merged-commit
acceptance, branch/workspace cleanup and closing #55; PR creation is not completion.

Planning checks and review ground plan consistency only. Proof, type/contract
checking, finite tests, monitored observations, upstream contracts and unverified
assumptions remain distinct. No new runtime behavior, authentication, durable
approval, provider adoption, security certification or product/release completion
is established by adoption. Missing essential provider/API/transaction decisions
remain explicit per-job blockers in the canonical manifest.
