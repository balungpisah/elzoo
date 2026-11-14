# state/recipe-store

The immutable recipe versions of a tenant, with a published pointer, a check
gate and pin records (ELZ-171). The bytes of each version are an artifact of
the ready `state/artifact`. Every other fact of a tenant is a record of the one
stream `recipe-store/<tenant>` of the ready Store (`state/event-log`,
`integration/sql`): `stored`, the check verdict, `published`, pin, unpin and
the delete mark. `Elzoo.RecipeStore.check/4` calls the ready
`Elzoo.RecipeCheck.check/2` unchanged. The Piece adds the published pointer,
the check gate and the one rule that needs them together: a version that a
live Run pins is not deleted. `workflow/version-pin` is a separate task and is
not called here.

## Copy and providers

Select `state/recipe-store` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without `Elzoo.Application`. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/artifact`,
`state/event-log`, `integration/sql`, `domain/recipe-package`,
`workflow/recipe-check`. Providers: `cure`, `jason`, `ecto_sql`, `postgrex`,
`req`, `req_s3`, `telemetry`, `elixir`, `otp`; exact versions, the source list
and the grounding of each claim are in [piece.json](piece.json). Cure is a
build-time compiler; the compiled decision table runs without
`Cure.Compiler`.

## Use

```elixir
# the host's fold carries the kinds of both Pieces; schema_version 1 stays in versions
fold = %{fold | kinds: Map.merge(fold.kinds, Map.merge(Elzoo.Artifact.kinds(), Elzoo.RecipeStore.kinds()))}

{:ok, artifact} = Elzoo.Artifact.new(store: store, object_store: object_store_config)
{:ok, recipes} = Elzoo.RecipeStore.new(artifact: artifact, log: store)

caller = %{tenant: "acme", principal: "publisher", scopes: []}

{:ok, identity} = Elzoo.RecipeStore.put(recipes, caller, package)      # a neutral package map
{:ok, package}  = Elzoo.RecipeStore.get(recipes, caller, identity)
{:ok, verdict}  = Elzoo.RecipeStore.check(recipes, caller, identity, facts)
{:ok, %{published: identity, previous: nil}} = Elzoo.RecipeStore.publish(recipes, caller, identity)
{:ok, ^identity} = Elzoo.RecipeStore.published(recipes, caller)
{:ok, :pinned}   = Elzoo.RecipeStore.pin(recipes, caller, identity, run_id)
{:ok, :unpinned} = Elzoo.RecipeStore.unpin(recipes, caller, identity, run_id)
{:ok, :deleted}  = Elzoo.RecipeStore.delete(recipes, caller, identity)
{:ok, versions}  = Elzoo.RecipeStore.versions(recipes, caller)
```

The Store of the artifact handle and `log` can be the same or different. The
checked example [examples/recipe_store.exs](examples/recipe_store.exs) runs the
whole interface on the Memory Store.

## Interface and results

`put/3` writes the compact JSON of the package (keys in byte order) under the
artifact ID of the 64 hex characters of its identity, with access expiry and
retention `:never`, and then appends a `stored` record. The same package again
writes nothing; a package whose identity is marked deleted is
`{:error, :deleted}`. `get/3` returns the stored map after its identity was
computed again from the bytes. `check/4` returns the result of
`RecipeCheck.check/2` unchanged; only `{:ok, verdict}` is recorded (identity and
upper cost). `publish/3` needs a stored, checked, live version; go-back is a
publish of an older version. `pin/4` and `unpin/4` keep one record for each
version and Run ID (1 to 128 bytes). `delete/3` is refused while a pin record
exists and while the version is published; it commits the delete mark first and
only then calls `Artifact.delete/4` for each version that `Artifact.versions/3`
lists. `versions/2` is folded from the tenant stream only, in the order of the
`stored` records.

Reasons, as `{:error, reason}`: `:not_found` (also for a version of another
tenant), `:invalid_package`, `:not_checked`, `:deleted`, `:pinned`,
`:published`, `:contended`, `:indeterminate`, `:stream_full`,
`{:artifact, reason}`, `{:log, reason}`, `{:delete_incomplete, reason}`,
`:integrity_mismatch` and `{:invalid, field}` (`:opts`, `:artifact`, `:log`,
`:store`, `:caller`, `:identity`, `:run_id`). When several refusals hold the
first of this order is given: `:not_found`, `:deleted`, `:not_checked`,
`:pinned`, `:published`. The pure decision is the Cure table
`decide/6` of `cure/elzoo/recipe_store.cure`.

## One stream per tenant

Each change reads the stream, decides on the folded state and appends one
record at the expected head revision. On `{:conflict, _}` it reads again and
decides again, at most 3 times, then `{:error, :contended}`; an indeterminate
append is `{:error, :indeterminate}` and is never tried again. A pin and a
delete of one version are in one order: when the delete mark is first the pin
is `:deleted`, when the pin is first the delete is `:pinned`. At 10,000 records
each change that appends is `:stream_full` (no compaction in this Piece).

## Boundary and limits

- No transaction across the tenant stream and an artifact: between the delete
  mark and the artifact delete the bytes exist and `get/3` already gives
  `:deleted`. A second `delete/3` completes an incomplete delete.
- `put/3` after an interrupted `put/3` adopts the bytes; several artifact
  versions of equal bytes may exist. `Artifact.reap/3` removes none of them
  (access expiry and retention are `:never`). A staging version left by an
  interrupted artifact `put` makes `delete/3` report
  `{:delete_incomplete, {:invalid, :state}}` until `Artifact.reap/3` removes it.
- A pin record is a record, not a lease: a Run that never unpins keeps the
  version. The host pins before a Run starts, unpins when it has ended (also
  after a crash) and never calls `delete` or `reap` of `state/artifact` on a
  recipe artifact directly.
- The check verdict is that of the facts given then. No listing across
  tenants, no search, no settings. Publishing changes no running Run.
- The caller is consumer-vouched attribution. No package content appears in an
  error; this Piece emits no log and no telemetry event.

## Evidence and operations

- `test/elzoo/recipe_store_test.exs`: the ten named groups
  (`immutable_versions`, `only_checked_is_published`, `go_back`,
  `two_publishes_one_order`, `pinned_is_not_deleted`,
  `pin_and_delete_one_winner`, `delete_mark_before_artifact`,
  `reap_keeps_recipes`, `tenant_isolation`, `bounds_and_redaction`), each
  scenario on the Memory Store and on the ready PostgreSQL Store
  (`ELZOO_TEST_DATABASE_URL`, one schema for each test) over the disposable S3
  test server (`ELZOO_TEST_S3_*`); both fail closed and are never skipped.
- `cure/elzoo/recipe_store.cure`: selected laws of the decision table, checked
  by the pinned Cure.
- telemetry: **inherited** from `state/artifact`; this Piece emits none.
- config: **supported** at construction only (`new/1`); no hot reconfiguration.
- control: **not applicable**; no process, pause or drain.

Proofs, finite tests, upstream contracts and host assumptions are distinct: a
selected law is not a proof of the fold or of the storage.
