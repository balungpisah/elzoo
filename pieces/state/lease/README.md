# state/lease

Single-owner leases fenced by the record revision, over the ready Store
(`state/event-log`, `integration/sql`). A key is a Store stream; its lease is
recorded **in that same stream** as self-contained `:non_state_bearing`
records, so the stream's head revision is the one fence for lease records and
guarded state records. Decides which single owner may drive a durable Run or
job attempt for a bounded interval and lets a replacement take over after
expiry; it never decides whether a state write is valid (the revision does).

## Copy and providers

Select `state/lease` with `mix elzoo.take`; the dependency-closed copy is owned
by the consuming application, without `Elzoo.Application`. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/event-log`,
`integration/sql`. Providers: `cure`, `jason`, `ecto_sql`, `postgrex`,
`elixir`, `otp`; exact versions, source lists and claim-level grounding are in
[piece.json](piece.json). Cure is a build-time compiler; the compiled tables
run without `Cure.Compiler`.

## Use

```elixir
# the consumer's fold carries the lease kinds; schema_version 1 stays in versions
fold = %{fold | kinds: Map.merge(fold.kinds, Elzoo.Lease.kinds())}

{:ok, lease} = Elzoo.Lease.new(store: store, clock: :store)   # fold and limits are the Store term's own
# PostgreSQL Store: clock: :store (clock_timestamp() of the Store's own Repo, sampled under the head lock)
# Memory double:    clock: {:manual, pid} from Elzoo.Lease.Clock.manual/1

{:held, held0} = Elzoo.Lease.claim(lease, "job/q/42", "worker-7", 60_000)
{:held, held1} = Elzoo.Lease.write(lease, held0, [{"attempt_started", 1, payload}])  # fenced by held0.live.revision
{:renewed, %{held: %{"job/q/42" => held2}}} = Elzoo.Lease.renew(lease, "worker-7", ["job/q/42"], 60_000)
{:completed, receipt} = Elzoo.Lease.complete(lease, held2, [{"succeeded", 1, result}])  # the renewed fence; + lease_released{terminal}, one step
{:claimed, sweep} = Elzoo.Lease.claim_expired(lease, "recoverer", 60_000, 10, candidate_keys)
{:ok, %{status: status}} = Elzoo.Lease.status(lease, "job/q/42")   # :free | :active | :stale | :ambiguous, as_of a revision
```

Every lease operation is **one atomic step on the Adapter**: PostgreSQL runs
one transaction (`Elzoo.Lease.Postgres`): lock the key's head row
(`FOR UPDATE`), sample `clock_timestamp()` under that lock, read the latest
lease record, classify/decide/gate with the pure `Cure.Elzoo.Lease` tables,
insert the lease record(s) and advance the revision, commit. The Memory double
runs one serialized owner section (`Elzoo.Lease.Memory`) with the manual clock.
The holder's non-terminal `write/4` goes through the ready Store's `append` at
the fence revision.

## Records and statuses

| kind | payload (JSON, schema_version 1) | reading |
| --- | --- | --- |
| `lease_claimed`, `lease_renewed`, `lease_seized` | `owner, at, ttl_ms, until` | holder from store time `at` until `until` |
| `lease_released` | `owner` (prior or null), `by`, `at`, `reason` | free |

Reason codes (closed): `released`, `stale`, `terminal`, `operator_takeover`,
`crashed_owner`, `pruned_prefix`, `corrupt_record`, `clock_regression`.
Statuses against the store-clock sample `now`: `free`; `active` when
`at <= now < until`; `stale` when `until <= now`; `ambiguous` when the stamp
is later than the sample (`future_stamp`), the latest record is unreadable, or
the prefix was pruned past the latest lease record (`pruned_prefix`).
Ambiguous keys admit only `seize`. A sample earlier than the latest recorded
stamp (clock regression) refuses every operation except `seize`.

## Results

| call | results |
| --- | --- |
| `claim/4`, `seize/5` | `{:held, %{owner, live: %{key, revision, at, until}}}`; `{:lease_refused, %{reason: :active \| :stale \| :ambiguous \| :unreadable \| :pruned_prefix \| :not_holder \| :free \| :regression \| :lost_race, holder, status, revision}}`; `{:error, {:invalid, field}}`; `{:error, :caller_transaction}`; `{:error, :contended}`; `{:error, :unavailable}`; `{:error, :malformed}`; `{:error, :clock_unavailable}` (Memory); `{:error, {:schema, detail}}`; `{:indeterminate, info}` |
| `renew/4` | `{:renewed, %{keys, held: %{key => held}, refused: %{key => refusal}, errors: %{key => error}}}` (one atomic step per key) |
| `release/3` | `{:free, %{revision, as_of}}` (idempotent on free, no write); refusals and errors as above |
| `hold/3`, `status/2` | read-only, `as_of` a revision, information not authority; `status` adds `reason`; `{:error, :contended}` when the head moved during the unlocked read three times |
| `claim_expired/5` | PostgreSQL: `{:claimed, %{held, refused, skipped_locked, skipped}}` or `{:error, …}` (nothing committed) or `{:indeterminate, info}`; Memory: the same or `{:partial, %{committed, refused, failed, not_evaluated}}` (no rollback of earlier per-key commits) |
| `write/4` | `{:held, held'}` (fence advanced); `{:fenced, %{expected, observed}}`; `{:rejected, reason}`; `{:error, :caller_transaction}`; `{:indeterminate, info}` |
| `complete/4` | `{:completed, %{key, owner, revision}}` (a receipt without a fence; `write/4`/`complete/4` refuse it with `{:error, {:invalid, :held}}`); `{:fenced, …}`; `{:lease_refused, %{reason: :regression}}`; `{:rejected, reason}`; `{:error, {:invalid, :items}}`; `{:error, :caller_transaction}`; `{:error, :contended}`; `{:indeterminate, info}` |
| `confirm/2` | `{:committed, target}`; `:superseded`; `{:unknown, reason}` (the ready Store's `confirm/5` by nonce) |
| `retention_bound/2` | `{:ok, %{through, as_of}}`: the highest `retain/5` `through` that keeps the latest lease record |

## Boundary and limits

- **Sampled-time liveness** (issue #45 as amended): a renewal, or the active
  holder's re-claim, is admitted only if the lease is live at the store-clock
  sample taken under the head lock within the transaction that records the
  change; a renewal sampled before expiry may commit after expiry, and an
  unlocked `status`/`hold` may report the prior lease stale before that commit
  and the renewed lease active afterwards; a renewal sampled at or after
  expiry records nothing. No claim of liveness at the physical commit instant.
- **Revision fencing, not identity:** a write using the fence of a superseded
  lease is refused once any record moved the head; the revision cannot
  authenticate how a current fence was obtained (`held` maps are
  transferable, `hold/3` has no authentication, owner strings are
  attribution), and expiry alone is not detected by the revision.
- **`claim_expired`** never grants one key to two concurrently live owners;
  overlapping invocations may both list a key whose grant ceased to be live,
  with different fence revisions. PostgreSQL: one transaction, per-key
  `FOR UPDATE SKIP LOCKED` then a savepoint `FOR UPDATE NOWAIT` probe, no head
  insert, locks held until commit. Memory: one owner section, no batch rollback
  (`{:partial, …}`), a finite approximation of the provider's law.
- **OD-1 Option L schema dependency:** `Elzoo.Lease.Postgres` acts on the
  `integration/sql` tables of migration version 1 under the Store's prefix and
  fails closed on any other table shape; its rows are ordinary Store records.
  No outbox items on `complete/4`.
- **Retention:** only the latest lease record is read; pruning it makes the key
  `pruned_prefix` ambiguous until a `seize`; `retention_bound/2` is advisory.
  PostgreSQL serializes retention with the lease step by the head lock; on the
  Memory double every call of this Piece (lease steps, `write/4`,
  `complete/4`, `Elzoo.Lease.Memory.retain/5`) goes through the single owner,
  a second owner is rejected, direct Store calls are outside the Contract,
  `retention_observed` is after-the-fact. A modifying Memory call waits for
  the owner without a timeout (a call timeout would not cancel the queued
  request); only read-only calls can return `{:error, :contended}`.
- **Proof scope:** selected laws cover the classification over ordering
  outcomes and the specification of the comparison; the production comparison
  is finite-test-grounded against the law-covered structural mirror, not
  proved.
- Every entry point refuses inside the caller's open Ecto transaction before
  any statement. Bounds: owner 1..200 bytes, `ttl_ms` 1..86_400_000, `limit`
  1..1_000, at most 1_000 candidates, `max_record_bytes >= 1_024`,
  `max_batch_size >= 2`.
- Non-goals: distributed lock service, consensus, cross-store agreement,
  authorization, TTL policy, sweeper cadence, key discovery, job scheduling.

## Evidence and operations

- `cure/elzoo/lease.cure`: 48 laws (C1–C9, R1–R5, G1–G9, D1–D19, S1–S6),
  audit clean, seven negative controls rejected in the named law.
- `test/elzoo/lease_test.exs`: Memory scenarios LS1–LS21, LS25, LS27 and the
  law test; `test/elzoo/lease_postgres_test.exs`: PostgreSQL scenarios incl.
  LS22 (guard), LS23 (OD-1a), LS24 (OD-1b conformance K1–K11 over lease
  records on both harnesses), LS26, LS28.
- telemetry: **planned** — no events; decisions are return values and records.
- config: **supported** — construction-time Store, fold, limits, clock
  binding, timeout; per-call bounds; no hot reconfiguration.
- control: **supported** — `seize/5` and `release/3` with applied, refused,
  failed and unknown results; authority external; no pause or drain.

See [ELZ-028](../../../docs/work/ELZ-028.md) for the Contract reading, the
review history, the ownership decision and the scenario plan.
