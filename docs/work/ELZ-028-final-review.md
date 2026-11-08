Redacted for publication; SHA-256 of the reviewer's original report: e157f6f053fec66c9e1d668c76b330ae6b7698e5ccb6f65b33915c107136e4b0

# ELZ-028 final diff review

Role: the independent reviewer (Codex), final diff review

Reviewed SHA: `878f0a24e4ec44875fec6c60776512f74071862d`.
Comparison base captured after fetch: `e62ce1843836f7ed1fd3587ba54b0355b25dccc5`.

The review is bound to the requested SHA.  During the review, the shared
remote-tracking refs advanced to later ELZ-028 commits, so neither those
commits nor their stated fixes are evidence for the reviewed SHA.

## Commands

| Command | Exit | Result |
| --- | ---: | --- |
| `git fetch origin --prune` | 0 | Refs fetched before review; later shared ref movement noted above. |
| `git diff origin/main...origin/task/ELZ-028` | 0 | Inspected at the requested SHA before ref movement. |
| `git diff --check e62ce1843836f7ed1fd3587ba54b0355b25dccc5...878f0a24e4ec44875fec6c60776512f74071862d` | 0 | No whitespace errors. |
| `gh pr view 123 --json body,files,comments` | 0 | PR body and changed-file list inspected; no PR comments were returned. |
| `gh pr checks 123` | 8 | Current, advanced PR head has pending/skipped checks; `Devin Review` passes. |
| `gh issue view 45 --json body` | 0 | Inspected. |
| `python3 scripts/check-roadmap.py` | 0 | `97` catalogue IDs, `77` jobs; generated views agree. |
| `python3 scripts/check-roadmap.py --live` | 1 | Only `ELZ-027: live task changed; reconcile`; expected unrelated live-row failure. |
| `python3 scripts/check-claims.py` | 0 | No tracked claim metadata. |

No Mix command was run: the full-check slot was explicitly unavailable.

## Findings

### BLOCKING — `write/4` bypasses the required Memory owner at the reviewed SHA

`pieces/state/lease/lib/elzoo/lease.ex` sends `write/4` directly to
`Store.write/5`.  It does not go through `Elzoo.Lease.Memory`, unlike lease
steps and `complete/4`.  This contradicts `pieces/state/lease/README.md` and
`pieces/state/lease/piece.json`, which state that every Piece call on a leased
Memory stream, including `write/4`, is serialized by the single owner.  It
also leaves the Memory-owner assertion and its retention/interleaving evidence
incomplete at this SHA.

The current PR body says this was one of five Devin findings, but its stated
fix is in a later commit, not `878f0a24e4ec44875fec6c60776512f74071862d`.

### BLOCKING — OD-1b is not true for a mismatched Store fold or limits

At the reviewed SHA, `Elzoo.Lease.new/1` accepts caller-supplied `fold` and
`limits` independently of the Store term.  `Record.records/5` validates with
those caller values, while `Elzoo.Lease.Postgres.write!/5` inserts rows
directly into SQL rather than calling the ready Store append validation.
Consequently, a lease built with a fold that admits lease kinds, or limits
that admit a larger record, can insert rows that the configured Store's own
`validate_row/3`, `read`, or `replay` rejects.  LS24 uses matching test
configuration and therefore does not exercise this counterexample.

This contradicts OD-1b's claim that every Adapter-written lease row passes
the Store's validation and remains readable.  The current PR body also
describes a later fix which obtains fold and limits from the Store; that is
outside this review target.

### BLOCKING — OD-1a does not fail closed for the complete migration-v1 shape

`pieces/state/lease/lib/elzoo/lease/postgres.ex` compares only column names
and `data_type` values from `information_schema.columns`.  Migration v1 in
`pieces/integration/sql/lib/elzoo/durable_log/postgres/migration.ex` also
defines non-null requirements, primary keys, and the
`elzoo_head_bounds`/`elzoo_record_bounds` checks.  Removing or changing any
of those leaves the reviewed shape check successful, contrary to the promise
to fail closed on any other table shape.  LS23 tests added, removed, and
retyped columns only.

Further, after construction, PostgreSQL `write/4` uses the ready Store append
without calling the lease Adapter schema check.  A later compatible-looking
schema mutation therefore has no lease-layer fail-closed check on that entry
point.  Pin the complete required schema invariants and exercise constraint,
nullability/key, and post-construction `write/4` mutations.

### BLOCKING — the checked diff deletes unrelated ELZ-050 planning material

`docs/plans/release-plan.json` removes the published `ELZ-050` entry, and
`docs/plans/views.md` correspondingly removes its planning row and
prerequisite.  The required shared-path scope permits only the `state/lease`
row/entry and the ELZ-028 issue-body hash.  Regeneration consistency does not
authorize deletion of another task's material.

### REQUIRED — PR check evidence conflicts with the committed work record

The PR body claims a successful `mix setup` and bare `mix check` at the
reviewed SHA, including timestamps, guard result, `32` Ash tests, `677` root
tests, and `ELZOO CHECK PASSED`.  `docs/work/ELZ-028.md` section 10 instead
states that no bare `mix check` had run and lists full `mix setup` plus bare
`mix check` as open work before the PR.  The committed record therefore does
not support the PR's asserted full-check and guard evidence.  Reconcile the
record with exact command output and the reviewed SHA, or correct the PR
claim.

### REQUIRED — current PR status is not merge-ready and is not the reviewed SHA

The current PR body lists five Devin findings as fixed only in later commits
and explicitly says their code is after the checked SHA.  The current
`gh pr checks` output also contains a pending `check-hosted` check.  A final
review must be repeated at one immutable final head after all corrections,
with the required full check and the repository's self-hosted-runner policy
resolved.

### LOW — review records are preserved, but their historical status is not final evidence

The requested early reviews, re-reviews, confirmations, contract proposal,
OD-1 gates, and G3-a scope are present under `docs/work/ELZ-028*.md`.
Their recorded review SHA-256 values and the live-task publication hash are
present; they do not cure the implementation and evidence failures above.

## Gate assessment

| Gate / claim | Status | Review result |
| --- | --- | --- |
| Sampled-time renew and holder re-claim | Conditional | PostgreSQL source samples after `FOR UPDATE`; Memory samples inside its owner.  The stated stale-then-active unlocked-read limitation is documented and LS8/LS26 are present; not executed here. |
| `claim_expired` ownership, repeated fences, partial Memory sweep | Conditional | Static transaction/owner paths and LS7/LS28 coverage are present, including `SKIP LOCKED`, savepoint plus `NOWAIT`, and `:contended`; not executed here. |
| Revision fence, no-takeover limit, fence-less receipt, LS25 terminal gate | Conditional | Static shell and LS4/LS20/LS25 implement and document the qualified revision-only behavior; not independently run. |
| Memory one-owner rule, duplicate-owner rejection, unsupported bypasses | **BLOCKING** | `write/4` bypasses the owner at the reviewed SHA. |
| **OD-1a** migration-v1 pin and fail-closed shape | **BLOCKING** | Column/type comparison omits v1 constraints, nullability, and keys; PostgreSQL `write/4` has no Adapter schema check after construction. |
| **OD-1b** Store-row conformance | **BLOCKING** | Caller-supplied configuration plus raw PostgreSQL insert permits divergence from the configured Store validation; LS24 covers only matched configuration. |
| **G3-a** comparison scope | Conditional | `pieces/state/lease/cure/elzoo/lease.cure` contains C1–C9 and S1–S6; the selected-law test names compilation/audit and finite `compare/2` agreement, and wording correctly avoids calling production comparison a proof.  No Mix execution was authorized. |
| Hard-coded guard and full-check evidence | **REQUIRED** | PR evidence conflicts with `docs/work/ELZ-028.md` section 10. |
| Operational declaration and dependencies | Static pass | `piece.json` declares `state/event-log` and `integration/sql`, and telemetry/config/control applicability with existing test references. |

## Shared paths

| Path | Status | Review result |
| --- | --- | --- |
| `registry/catalogue.json` | Pass | Only the `state/lease` row changes. |
| `docs/plans/release-plan.json` | **BLOCKING** | Required `state/lease` manifest, contract note, and issue hash are present, but unrelated ELZ-050 is also deleted. |
| `docs/plans/views.md` | **BLOCKING** | Generated view follows the unauthorized ELZ-050 deletion. |
| `LEDGER.md` | Pass | Only the `state/lease` row changes. |
| `tasks/ELZ-028-writer-lease.md` | Pass | Exact live-body SHA-256 is `d3c00d2aab3499ffd73f99a07b2899e5826e31c70a32519153b2d87ee6d17ba4`; task copy and release-plan value match. |
| `pieces/state/lease/piece.json` | Pass | Committed SHA-256 is `d96ffac97c8ab8080d06d456bdd261e5d98cc8b7e419ca583f73c99416cb6fbe`, matching the reviewed release-plan entry. |
| `mix.exs`, providers, merged tests, protected files | Pass | No such existing path changes in the reviewed diff; new tests are confined to `pieces/state/lease`. |

PR comments were empty.  The PR body now itself lists the five Devin findings
and their later-commit dispositions; those dispositions cannot be credited to
the reviewed SHA.

NOT CLEAR — restore or explicitly coordinate the ELZ-050 deletion; make OD-1a
complete and guard all relevant entry points; make OD-1b use and validate the
configured Store contract; reconcile committed full-check/guard evidence; and
repeat this review at the final immutable SHA after allowed-runner checks pass.
