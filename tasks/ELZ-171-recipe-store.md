# ELZ-171 — Recipe versions of a tenant, with publish, pin and delete

## Scope and reuse

- Dependencies: ELZ-033, ELZ-009, ELZ-096, ELZ-164, ELZ-167
- Output: `state/recipe-store`, one public module `Elzoo.RecipeStore`; release V1B; RC-65 recipe-store portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/state/recipe-store/**` and its index/generated changes under AGENTS.md section 3.

Coordinator decision, 2026-11-14: RC-65 is published as two tasks. This task
keeps the immutable recipe versions of each tenant, the published pointer,
the check gate and the pin records, and owns the one rule that needs them
together: a version that a live Run pins is not deleted. `workflow/version-pin`
is a separate, pure task; this Piece does not call it.

Implement only the named acceptance groups below. Reuse ready
`state/artifact` for the bytes of each version, the ready Store of
`state/event-log` for one stream per tenant, and
`Elzoo.RecipeCheck.check/2` for the check gate, all unchanged. Add no query
language, no listing by name, no tenant settings, no cache, no process, no
options, behaviours or hooks. Change no ready Piece, shared source, pin or CI
file. No fixtures directory is needed.

Facts checked on main:

- `state/artifact` (ELZ-096): `put/5`, `get/4`, `delete/4`, `reap/3`,
  `status/3` with a caller `%{tenant, principal, scopes}`. An `artifact_id`
  is 1 to 64 bytes of alphanumerics and `-_.`. Access expiry and retention
  each accept `:never`, and a version with both `:never` is never reaped.
  The streams of two artifacts commit separately: "No cross-stream
  transaction". `delete` is a public call of that Piece.
- `state/event-log` (ELZ-009): a Store appends to a stream with an expected
  revision and gives `{:committed, rev}`, `{:conflict, _}`, `{:rejected, _}`
  or `{:indeterminate, _}`; a stream name is UTF-8 text of 1 to 200 bytes
  and the log has no tenant of its own. `state/lease` is the model of a
  small state kept as records of one stream under head-revision CAS, with a
  Memory and a PostgreSQL Store.
- `domain/recipe-package` (ELZ-164): a package identity is
  `recipe-package-v1:sha256:` plus 64 lowercase hex characters. It is not a
  valid `artifact_id` (the `:` and its 89 bytes).
- `workflow/recipe-check` (ELZ-167): `check(package, facts)` gives
  `{:ok, %{identity, unit, upper_cost}}`, `{:refused, reasons}` or
  `{:error, :invalid_facts}`.

## Interface: `Elzoo.RecipeStore`

`new(opts)` returns `{:ok, store}` or `{:error, {:invalid, field}}`. `opts`
has exactly `artifact` (a handle of `Elzoo.Artifact.new/1`) and `log` (a
ready Store `{module, opts}` whose fold holds `Elzoo.RecipeStore.kinds/0` at
schema version 1). `kinds/0` gives the record kinds of this Piece.

Every other function takes the store and a caller `%{tenant, principal,
scopes}` in the form of `state/artifact`. The tenant of the caller selects
everything: the stream `recipe-store/<tenant>` and the artifacts of that
tenant. No function takes another tenant.

- `put(store, caller, package)`: `package` is the neutral package map of
  ELZ-164. It must pass `RecipePackage.decode/1`. Its bytes (the compact
  JSON of the map with keys sorted by bytes) are written with
  `Artifact.put/5` under the `artifact_id` equal to the 64 hex characters of
  its identity, with access expiry and retention `:never`. Returns
  `{:ok, identity}`. The same package again returns `{:ok, identity}` and
  writes no second version.
- `get(store, caller, identity)`: `{:ok, package}`: the stored map, after
  its identity was computed again from the bytes and compared.
- `check(store, caller, identity, facts)`: reads the package, calls
  `RecipeCheck.check(package, facts)` and, for `{:ok, verdict}`, records the
  verdict for that identity in the tenant stream. Returns the result of
  `check/2` unchanged. A refused package records nothing.
- `publish(store, caller, identity)`: sets the published pointer to a
  version that is stored, checked and not marked deleted. Returns
  `{:ok, %{published: identity, previous: identity | nil}}`. Go-back is
  `publish/3` of an older version. Publishing the published version changes
  nothing and returns it with `previous` equal to it.
- `published(store, caller)`: `{:ok, identity | nil}`.
- `pin(store, caller, identity, run_id)`: records that the live Run `run_id`
  (text of 1 to 128 bytes) uses the version. The version must be stored and
  not marked deleted. A second pin of the same pair changes nothing.
- `unpin(store, caller, identity, run_id)`: removes that pin record. An
  unknown pair changes nothing.
- `delete(store, caller, identity)`: refused while a pin record of the
  version exists and while it is the published version. Otherwise it commits
  a delete mark in the tenant stream and only then calls `Artifact.delete/4`.
  Returns `{:ok, :deleted}`. When the mark is committed and the Artifact
  delete did not complete, it returns `{:error, {:delete_incomplete, reason}}`;
  the mark stays, and a second `delete/3` completes it.
- `versions(store, caller)`: `{:ok, [%{identity, checked: boolean, pins:
  count, published: boolean, deleted: boolean}]}` in the order of first
  `put`.

**One stream per tenant.** The verdicts, the published pointer, the pin
records and the delete marks of a tenant are records of the one stream
`recipe-store/<tenant>`. Each change reads the stream, decides on the folded
state and appends one record with the expected head revision. On
`{:conflict, _}` it reads again and decides again, at most 3 times, then
returns `{:error, :contended}`. So a pin and a delete of one version are in
one order: when the delete mark is first, the pin is refused as `:deleted`;
when the pin is first, the delete is refused as `:pinned`. Two publishes are
in one order, and `published/2` gives the later one. An indeterminate append
returns `{:error, :indeterminate}` and is never tried again by this Piece.

Reasons, as `{:error, reason}`: `:not_found` (no such version of this
tenant, also for a version of another tenant), `:invalid_package`,
`:not_checked`, `:deleted`, `:pinned`, `:published`, `:contended`,
`:indeterminate`, `:stream_full`, `{:artifact, reason}` with the unchanged
reason of `state/artifact`, `{:log, reason}` with a rejection of the Store,
`{:delete_incomplete, reason}`, `:integrity_mismatch` and
`{:invalid, field}`. No package content appears in an error, a log or a
telemetry event.

## Host Needs and Limits

Fixed bounds: those of ELZ-164 for a package; 10,000 records in one tenant
stream, then `:stream_full` for each change (no compaction in this task);
128 bytes for a Run ID; 3 tries on a conflict.

Needs: a ready Store and its migration; the object store and the Artifact
handle of the host, with `kinds/0` of both Pieces in the fold; a caller
whose tenant the host verified; a host that pins a version before a Run
starts and unpins when the Run has ended, also after a crash; truthful
`facts` for the check; and a host that never calls `delete` or `reap` of
`state/artifact` on a recipe artifact directly. A direct delete there breaks
the pin rule, and this Piece cannot prevent it.

Limits: no transaction across the tenant stream and an artifact: between the
delete mark and the Artifact delete the bytes exist and `get/3` already
gives `:deleted`. A pin record is a record, not a lease: a Run that never
unpins keeps the version. The check verdict is that of the facts given then;
a later change of the facts is not seen. No listing across tenants, no
search, no settings. Publishing changes no running Run: which version a Run
uses is `workflow/version-pin`. Declare Telemetry, Config and Control as the
operational contracts ask for an Adapter with no hot Config and no Control.

The manifest declares `kind: adapter`, the providers that the reuse needs,
and the Piece dependencies `state/artifact`, `state/event-log`,
`integration/sql`, `domain/recipe-package` and `workflow/recipe-check`.

## Named acceptance groups

Database groups run on the ready PostgreSQL Store with
`ELZOO_TEST_DATABASE_URL` and the S3 test server, fail closed and are never
skipped; each test uses a schema of its own. The order rules also run on the
Memory Store.

1. **`immutable_versions`**: `put` then `get` gives the same map; the same
   package twice gives one version; a changed package gives another
   identity and both stay readable; a malformed package is
   `:invalid_package`; the artifact has access expiry and retention `:never`.
2. **`only_checked_is_published`**: `publish` of a stored, unchecked version
   is `:not_checked`; a refused check records nothing and publish stays
   refused; after a passing check publish succeeds; an unknown identity is
   `:not_found`.
3. **`go_back`**: publish A, then B, then A again: `published/2` gives A, B,
   A, and each `previous` is correct; all versions stay readable.
4. **`two_publishes_one_order`**: two concurrent publishes of two checked
   versions both return `{:ok, _}` or one returns `:contended`; the stream
   holds them in one order and `published/2` equals the later record; with
   a Store that always conflicts, the result is `:contended` after 3 tries.
5. **`pinned_is_not_deleted`**: delete of a pinned version is `:pinned`;
   after unpin it succeeds; delete of the published version is
   `:published`; two Runs pin one version and it is deletable only after
   both unpin; `get`, `pin`, `check` and `publish` of a deleted version give
   `:deleted`.
6. **`pin_and_delete_one_winner`**: a pin and a delete of one version that
   start together: exactly one succeeds, in both arrival orders on the
   Memory Store and in 20 concurrent rounds on PostgreSQL; the state after
   it agrees with the winner.
7. **`delete_mark_before_artifact`**: with an object store that fails the
   delete, the result is `{:delete_incomplete, _}`, the mark is in the
   stream, the version reads as `:deleted`, and a second `delete/3`
   completes; the stream never holds an Artifact delete without its mark.
8. **`reap_keeps_recipes`**: `Artifact.reap/3` on a recipe artifact, with
   the clock far in the future, removes no version.
9. **`tenant_isolation`**: tenant B gets `:not_found` for each identity of
   tenant A in `get`, `check`, `publish`, `pin`, `unpin` and `delete`, and an
   empty `versions/2`; the published pointer of A is unchanged.
10. **`bounds_and_redaction`**: `:stream_full` at the bound (use a small
    injected bound only if the task can do it without a new option;
    otherwise write the 10,000 records on the Memory Store); a sentinel
    text in a package never appears in an error, a log or a telemetry
    event; `{:invalid, field}` for each malformed operand. One small checked
    example covers the public API on the Memory Store.

## Evidence and gate

Test: the ten groups, with the database groups named as such in
`piece.json`. Upstream: the Contracts of the reused Pieces, scoped as they
state them. Cure owns the pure decision over the folded state (allow or
refuse a change) when a meaningful law is selected, for example "a delete is
never allowed while a pin exists"; do not add a Boolean restatement.
Negative controls: temporarily call `Artifact.delete/4` before the mark is
committed, then temporarily skip the pin test in the delete decision; groups
7 and 5 must fail. Restore both before the final gate.

Run `. .elzoo-services/env.sh`, `mix test pieces/state/recipe-store/test`,
then `mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The copied consumer of the small gate must finish within
its existing 300 seconds; if it does not, stop and report the measured time
to the coordinator. One independent review checks the body and the exact
diff, including extra features.

## Not in scope

`workflow/version-pin`, tenant settings, the engine, compaction of the
tenant stream, a lease for pins, authorization of the caller, a change of
`state/artifact`, of `lib/elzoo/check_selection.ex` or of any shared file.
