# state/recipe-store

The immutable recipe versions of a tenant, with a published pointer, a check
gate and pin records (ELZ-171). The bytes of each version are an artifact of
the ready `state/artifact`. Every other fact of a tenant is a record of the live
generation of the tenant stream in the ready Store (`state/event-log`,
`integration/sql`): `stored`, the check verdict, `published`, pin, unpin and
the delete mark. A full generation is carried into the next with only the live
state (ELZ-358). `Elzoo.RecipeStore.check/4` calls the ready
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
{:error, :published} = Elzoo.RecipeStore.delete(recipes, caller, identity)  # refused while published
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
lists. `versions/2` is folded from the live generation only, in the order of the
`stored` records.

Reasons, as `{:error, reason}`: `:not_found` (also for a version of another
tenant), `:invalid_package`, `:not_checked`, `:deleted`, `:pinned`,
`:published`, `:contended`, `:indeterminate`, `:stream_full`,
`{:artifact, reason}`, `{:log, reason}`, `{:delete_incomplete, reason}`,
`:integrity_mismatch` and `{:invalid, field}` (`:opts`, `:artifact`, `:log`,
`:store`, `:caller`, `:identity`, `:run_id`). When several refusals hold the
first of this order is given: `:not_found`, `:deleted`, `:not_checked`,
`:pinned`, `:published`. The pure decision is the Cure table
`decide/6` of `cure/elzoo/recipe_store.cure`. `:stream_full` means that the live
generation is full and its carry would be more than 5,000 records: the live
state is too large, not the history.

## Generations of the tenant stream

- Generation 1 of a tenant is the stream `recipe-store/<tenant>`, so a stream
  that ELZ-171 wrote is generation 1, unchanged. Generation `n` ≥ 2 is
  `recipe-store/<tenant>/<n>` (decimal, no leading zeros); a tenant holds no
  `/`, so no generation of one tenant is a stream of another.
- A generation holds at most 10,000 records; one whose head revision is 10,000
  is full, and no change appends to it again.
- Generation `n` ≥ 2 begins with its carry: a `recipe_carried` header
  `{"from": n − 1, "records": k, "v": 1}` and `k` records of the other kinds.
  The carry of a folded state is, for each version in the order of its
  `stored` records, `recipe_stored`, `recipe_checked` with the latest upper
  cost when checked, `recipe_deleted` when marked, and one `recipe_pinned` for
  each live pin in byte order of the Run ID; then `recipe_published` for the
  published version. Its fold is the folded state of the full generation; a
  settled pin and unpin pair is not carried. A misplaced header, a generation
  ≥ 2 without one, a `from` other than `n − 1` or a `records` that is not a
  non-negative integer is `{:log, :malformed}`.
- `G` is the highest non-empty generation, found from head reads only (2, 4,
  8, … then a binary search: at most 2·⌈log₂(G + 1)⌉ + 2). A generation ≥ 2 is
  complete when it holds at least `1 + k` records. The live generation is `G`
  when complete, else `G − 1`. Every read folds the live generation only and
  writes nothing.
- A change that appends first makes the live generation one that is not full:
  it completes a stopped carry (after checking that the written records are
  exactly a prefix of the carry of `G − 1`, else `{:log, :malformed}`), or
  writes the carry of a full live generation as the next one (more than 5,000
  records is `:stream_full`). Then it decides again on the new live generation
  and appends its record there. The carry is written in batches of at most
  `max_batch_size`, each at the head revision of the new generation.
- Each `{:conflict, _}` of any append, a carry batch included, is one of the 3
  tries, then `{:error, :contended}`. An indeterminate append is
  `{:error, :indeterminate}` and is not tried again in that call; a later call
  appends only what is missing at the observed head revision. `put/3` makes
  every refusal of the carry that needs no write before it writes any bytes.
- A change that appends nothing carries nothing and works on a full generation.
- A pin and a delete of one version are in one order, also across a carry:
  each change is decided on one folded state and appended at one stream's head
  revision, and a full generation never changes. When the delete mark is first
  the pin is `:deleted`, when the pin is first the delete is `:pinned`.

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
- Generations before the live one are never removed: the Store keeps every
  record a tenant wrote, so storage grows with the tenant's history.
- The live state is bounded: a carry of more than 5,000 records (versions ever
  stored with their marks, plus live pins) is `:stream_full`, and then only a
  change that appends nothing works. A Run that never unpins holds a place in
  every carry; past the bound an `unpin` is refused as well, because it
  appends. Deleted versions are carried for ever (two or three records each),
  so a tenant's lifetime of stored versions is bounded at about 1,666 to 2,500
  even with no live pin.
- A read costs O(log G) head reads plus the live generation (at most 10,000
  records), and while a carry is stopped part way the generation before it.
- The generation rules are Elixir, as the fold is; the Cure table keeps the
  decision of each operation over a version's flags, and no law is added.
- The head search assumes the generations that this Piece writes: a gap, or a
  carry edited outside the Piece in a complete generation, is not detected by
  a read; only a change that completes a carry compares it with its source.
- The first change that needs a carry writes it and takes longer; under
  contention a change may end `:contended` during a carry and is called again
  by the host.

## Evidence and operations

- `test/elzoo/recipe_store_test.exs`: the ten named groups
  (`immutable_versions`, `only_checked_is_published`, `go_back`,
  `two_publishes_one_order`, `pinned_is_not_deleted`,
  `pin_and_delete_one_winner`, `delete_mark_before_artifact`,
  `reap_keeps_recipes`, `tenant_isolation`, `bounds_and_redaction`), each
  scenario on the Memory Store and on the ready PostgreSQL Store
  (`ELZOO_TEST_DATABASE_URL`, one schema for each test) over the disposable S3
  test server (`ELZOO_TEST_S3_*`); both fail closed and are never skipped.
- `test/elzoo/recipe_store_generation_test.exs`: the generation groups
  (`carry_keeps_live_state`, `carry_equals_fold`, `live_generation_search`,
  `stopped_carry`, `one_order_across_a_carry`, `frozen_full_generation`,
  `stream_full_only_for_a_large_live_state`, `malformed_carry`); the dual ones
  on both backends, the others on the Memory Store.
- `cure/elzoo/recipe_store.cure`: selected laws of the decision table, checked
  by the pinned Cure.
- telemetry: **inherited** from `state/artifact`; this Piece emits none.
- config: **supported** at construction only (`new/1`); no hot reconfiguration.
- control: **not applicable**; no process, pause or drain.

Proofs, finite tests, upstream contracts and host assumptions are distinct: a
selected law is not a proof of the fold or of the storage.
