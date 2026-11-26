# ELZ-418 — assembly/checked-command: no lifetime cap for a tenant

- Dependencies: ELZ-416, ELZ-417, ELZ-419, ELZ-427

## Outcome and scope

Today a tenant has one stream (`Codec.stream(tenant)`). Every call replays it
from sequence 1 in pages of 128 rows. Recovery uses no checkpoint and refuses
any pruned prefix (each `low_water == 0` check of `read_history`). The limits:

- New command identities stop at 1,024 (`@max_operations`): a new one is
  `{:refused, :capacity}`, while retained identities can still be read and
  retried. A usable stream holds at most 2,048 rows (one row per operation and
  at most one terminal release row per ASK), below the defensive 4,096-row
  guard (`@max_records`).
- A 65th distinct resource cannot be created (`@max_resources`); existing
  resources can still be updated. The same constant bounds the read-scope
  grant list. Fields per resource (64) and the resource size (65,536 bytes)
  are separate bounds.
- The Approval state is one `workflow/approval` value. Each ASK operation
  opens its own request line (`approval_owner/1` of its identity), and no line
  ever leaves the state.
- There is no removal: an absent resource reads as revision 0, a write sets
  fields, and no write removes a resource.

New contract. This is a breaking change under the rule of ELZ-415 (same Piece
ID); the README gets a `## Changes` entry with what breaks and how to move.

**Unchanged.** The tenant stream name, the outbox item key
(`"<stream>/<sequence>/1"`), the notification of a write
(`{"type", "version": 1, "tenant", "actor", "operation_id", "resource", "revision"}`),
the result families of `execute/3`, `release/4`, `result/3` and `resource/3`
(the new reasons below join them), and the store's compare-and-set on append.
Store sequences stay bounded by the signed 64-bit integer.

**Versioned rows, provenance and migration.**

- New command rows are `checked_command` schema version 2: they add the
  trusted issuance (`issued_at_ms`), the stream watermark after the command,
  and the removal form below. The maintenance marker below is its own
  versioned row. The fold reads version 1 and version 2 rows.
- The first row of an identity determines its receipt's provenance. A version
  1 row has no issuance time, and none can be inferred. So a receipt first
  written by a version 1 row is never evicted (the old caps bound these to
  1,024 identities per stream), also when a version 2 row later releases its
  ASK, and a retry of it is compared with its version 1 canonical bytes. A
  version 1 pending ASK stays releasable with fresh evidence. A version 1
  unacknowledged outbox item stays pending until it is acknowledged, and
  retention never passes it.
- Migration (a README step): stop the old writers before enabling version 2.
  Upgrade every caller Store fold to admit the new row kinds and versions, and
  confirm that the selected checkpoint budget can hold the non-evictable
  legacy projection before enabling retention. Today the Store folds of the
  wave 4, 5 and 6 helpers and of the kill-switch and tenant-lifecycle tests
  admit version `[1]` only; supplying the new request and context fields alone
  is not enough.

**Trusted time.** The `execute/3` context gains `now` (integer Unix ms,
`0..2^63-1`), as `release/4` has. The request (the public command envelope)
gains `issued_at_ms` (integer Unix ms, `0..2^63-1`):
`%{operation_id, resource, expected_revision, payload, issued_at_ms}`. It is
part of the canonical identity of a version 2 row. The preparer still gets
exactly the four-field DTO `%{operation_id, resource, expected_revision, payload}`
on execute and on release, so `domain/kill-switch` and
`workflow/tenant-lifecycle` keep their preparers.

Issuing Need (README): the trusted boundary that assigns an operation ID
assigns its issue time once, stores them together, and never issues that
operation ID again with another time. A retry repeats both.

**Window, skew and watermark.** The descriptor gets two optional keys,
`window_ms` and `max_skew_ms`, with defaults that the README states. The first
version 2 row of a stream records both. A later `execute/3`, `release/4` or
`maintain/3` whose descriptor has other values is refused before any effect:
`{:refused, :window_changed}`, `{:release_refused, :window_changed}` or
`{:error, :window_changed}`. Changing them needs a new stream, never an
in-place change. Each version 2 row records the stream watermark `W`, the
highest effective time that the stream accepted, in the same append as its
command. For each call:

- `now < W - max_skew_ms`: `{:refused, :clock_behind}` (execute) or
  `{:release_refused, :clock_behind}` (release), before any effect.
- `E = max(now, W)` is the effective time for every check below and is the
  `now` given to `workflow/approval`, so the Approval clock never moves back
  (the Clock Need of ELZ-417).
- After the stream's clock and descriptor checks, `execute/3` returns a
  retained result only on the matching canonical request; changed bytes for
  that identity give `{:conflict, :identity}`. A terminal checkpoint receipt
  keeps enough binding data to preserve `release/4`'s descriptor and facts
  comparison and its `{:release_refused, :binding_mismatch}` refusal.
- A new identity with `issued_at_ms > E + max_skew_ms` is
  `{:refused, :issued_in_future}`; with `issued_at_ms <= E - window_ms` it is
  `{:refused, :expired}`. Neither writes a row.
- A terminal version 2 receipt can be evicted once
  `issued_at_ms <= W - window_ms` and its outbox item, if any, no longer
  blocks eviction: it is acknowledged, or confirmed retention removed it (a
  delivery may still read the receipt through `result/3`). The receipt keeps
  enough notification provenance to recognize a known emitted item that
  confirmed retention removed. A valid `low_water` covering that item proves
  that it no longer blocks eviction, not which nonce acknowledged it; an
  absent ack row above `low_water` proves nothing. A pending ASK is never
  evicted. So a retry returns the first result until its receipt is evicted:
  never a second execution. After eviction, `execute/3` with the original
  issuance is `{:refused, :expired}`; `release/4`, which has no issuance
  operand, returns `:not_found`; `result/3` returns
  `{:unknown, :not_observed}`, as for an identity never seen. A host
  reconciles an unknown outcome within `window_ms`.
- A pending ASK, of either version, stays releasable at any later time with
  fresh evidence. Its release appends a row and advances `W`.

**Resources and removal.**

- The lifetime count of resources goes. The 64-field and 65,536-byte bounds
  of one resource and the 64-entry read-scope grant bound stay.
- For a new version 2 identity, the preparer returns
  `{:ok, [{:remove, target}], response}` for a removal, the only entry of its
  writes. CheckedCommand authorizes it as the exact reserved write
  `%{target: target, field: "$checked_command.remove", value: true}` under the
  host's removal policy. An ordinary field write to
  `"$checked_command.remove"` by a new version 2 identity is refused. A
  pending ASK of version 1 origin can still release an ordinary write to that
  field, even though its terminal release row is version 2 (the release must
  reproduce the retained prepared writes); replay applies it as a field write,
  never as a removal. (`domain/authorization` accepts only an exact three-key
  write, and `nil` is an ordinary value, not a deletion.)
- Revisions never repeat for a resource ID, and no tombstone is kept per
  removed ID. The stream keeps one number `L`, the sequence of its newest
  removal row (0 before any removal). An absent resource reads as revision
  `L` with empty fields (`resource/3` gives
  `{:ok, %{tenant: t, resource: r, revision: L, fields: %{}}}`), and a create is
  accepted only at `expected_revision == L`. A create gives revision `L + 1`,
  and each write adds one, as today. Every revision is at most the sequence of
  the row that wrote it, so a later incarnation never reuses one. A stream
  with no removal behaves exactly as today. A removal makes every create that
  was prepared before it stale, also for other resource IDs.
- A committed removal reports the new absent revision `L` in its result and
  in a distinct removal notification; a write keeps today's notification
  bytes. The README documents both.

**Bounded checkpoint.** The Piece writes its own versioned checkpoint of the
projection through the Store's `put_checkpoint`; stock `Elzoo.Checkpoint.take/4`
is not usable because it keeps every witness. The checkpoint:

- is self-contained: live resources, `L`, `W`, the stream's window and skew,
  the retained receipts (a terminal receipt keeps what a retry, `result/3`,
  `release/4`'s binding check and eviction need; a pending ASK keeps
  everything its release needs), and the Approval state after the retirement
  and prune below;
- keeps a bounded set of witnesses that includes its anchor row;
- fits an enforced byte budget, framing included: the Store's
  `max_checkpoint_bytes`. `new/2` refuses a Store whose limit is below the
  minimum that the README states.

A checkpoint put is confirmed by `{:committed, anchor}`, or by
`Elzoo.DurableLog.confirm_checkpoint/2` returning `{:committed, anchor}` for
the attempted checkpoint (it compares stream, anchor, fold version, nonce and
canonical bytes). A different nonce does not confirm that put. Recovery or a
later cycle may independently validate and reuse an already committed
checkpoint. Loading reads the newest committed checkpoint of this Piece's
checkpoint version, validates it, requires its anchor to be at or above
`low_water`, and replays only the rows after the anchor. With no usable
checkpoint, a stream whose `low_water` is 0 replays from sequence 1; a pruned
stream fails closed with `{:unknown, :unresolved}`. A checkpoint of another
kind or version is never used. On a healthy sequential run the cadence below
bounds the number of checkpoint calls and of tail rows returned, not the
tenant's age. (Provider work inside the Store is not claimed bounded: the
Memory Store scans its maps.)

**Live-state budget and Approval room.** The projection must fit the
checkpoint budget, and the Approval state must have room for the transition
(`Approval.request/3` and `Approval.apply_event/2` refuse a full list). Before
an append that would exceed either, the call durably compacts (a maintenance
cycle with a confirmed checkpoint) and reloads, without requiring an
intervening successful command. If the transition still does not fit after
maintenance, the call returns the appropriate `:capacity` refusal
(`{:refused, :capacity}` or `{:release_refused, :capacity}`) without a command
or release row, resource mutation, or new outbox item; a maintenance marker
may already have committed. An admission decision never depends on a
reclamation that existed only in process memory: replay from the newest
confirmed checkpoint plus the tail makes the same decisions.

**Maintenance cycle.** The Piece runs it after a committed append once the
tail since the last confirmed checkpoint reaches `checkpoint_rows` rows (a
descriptor option with a stated default), before a transition that needs room
(above), and when the host calls a new `maintain(handle, tenant, now)` (`now`
is the same trusted integer Unix ms as in the `execute/3` context; for
example after acknowledging outbox items: `Elzoo.Outbox.ack/3` marks an item
and does not retain). `maintain/3` returns
`{:ok, %{checkpoint: sequence, low_water: low_water}}` or `{:error, reason}`
(the README lists the reasons; `now < W - max_skew_ms` is
`{:error, :clock_behind}` before any effect). After a failed cycle,
maintenance is retried while the threshold remains exceeded; the cadence
bound is not claimed during that backlog. A cycle:

1. loads the projection from the newest confirmed checkpoint plus the tail;
2. advances time when that frees room: if `now` is later than the committed
   `W` and advancing `W` to `now` makes at least one more receipt evictable,
   the cycle compare-and-set appends a versioned maintenance marker that
   records the new `W`. The marker changes no resource, command result or
   outbox item. So a full stream whose receipts expire only with time regains
   room without a successful command, and replay makes the same decision from
   the committed marker;
3. evicts each evictable terminal version 2 receipt (the rule above) at the
   committed `W`, calls `Elzoo.Approval.retire/2` for the request lines of
   exactly those operations, and then `Elzoo.Approval.prune/2` at `W`. The
   receipt tells a terminal-stale operation (whose Approval request is still
   `:open`) from a pending ASK, never the Approval status; a pending ASK is
   never retired;
4. reuses a confirmed checkpoint at the current head only when it already
   represents the required compacted projection. Both Stores key a checkpoint
   by stream, sequence and fold version, so one cannot be replaced. If
   receipt eligibility changed at an occupied anchor (for example after an
   ack) and step 2 appended no marker, the cycle compare-and-set appends a
   maintenance marker that records the unchanged `W`, to obtain a new anchor.
   It then writes and confirms the checkpoint at that head;
5. retains through
   `T = min(checkpoint_sequence, first_pending_sequence - 1, first_needed_original_row - 1)`,
   ignoring a blocker that does not exist, only when `T > low_water`, with the
   observed `low_water` as `expected` and a fresh 16-byte nonce. An
   unconfirmed checkpoint never authorizes retention.
   `first_needed_original_row` is the first row whose content the checkpoint
   does not hold and a retained receipt or pending ASK still needs; with a
   self-contained checkpoint there is none. The retention also deletes the
   stream's checkpoints below `T` (ELZ-427), so the stored checkpoints, and
   the evicted receipts and removed resources they held, do not outlive it.

Races: at the same expected head, exactly one append compare-and-set wins; a
losing call may reload and commit a later, separately valid row. At the same
checkpoint key only one insert wins, and at the same expected `low_water`
only one advancing retain wins. An append and maintenance on an earlier
confirmed anchor may both succeed. A cycle that loses returns
`{:error, :contended}` and leaves the stream valid. A committed command keeps
its committed result when its cycle fails. Retention deletes acknowledged
outbox rows, so a later ack confirmation can be `{:unknown, :unfenced}`: that
is not proof that the ack did not commit.

**Needs (README).** The Issuing Need above. The Verifier Need and the Clock
Need of ELZ-417 for the host's evidence verifiers and clock. The Retirement
Need of ELZ-417 holds through the Issuing Need: an evicted identity can only
come back with its original time, which is `:expired` before it reaches
Approval.

**Wave 4 handoff.** Today Wave 4's `ReplySource` rejects any pruned prefix
and reads from sequence 1, and the previous-pair proof reads acknowledged
original outbox items. Protecting pending receipts does not protect these
readers. As ELZ-419 states, when it merges the coordinator lists in this issue
the exact remaining wave 4 files that call `assembly/checked-command`, and the
durable source/custody proof that replaces their reads of original command
rows and ack rows (ELZ-419 persists the reply source, association and
original-key/nonce custody facts independently of compactable CheckedCommand
rows). This task migrates those callers and tests a full Wave 4 restart and
next reply after retention removes the original acknowledged rows and
eligible receipts. Do not merely widen the 4,096 sequence guard.

Paths: `pieces/assembly/checked-command/**` (including the SQL example
`examples/elzoo/postgres_trigger_binding.exs`); the tests of the Pieces whose
tests call this Piece: `pieces/domain/kill-switch/test/**` and
`pieces/workflow/tenant-lifecycle/test/**` (contexts gain `now`, requests
gain `issued_at_ms`, Store folds admit the new rows; their `lib/`, README and
manifest do not change); the root callers `test/support/wave5_tenancy_helper.exs`,
`test/wave5_tenancy_test.exs`, `test/support/wave6_count_and_see_helper.exs`
and `test/wave6_count_and_see_test.exs`; `test/checked_command_copy_support_test.exs`;
and the Wave 4 files of the handoff above (before ELZ-419 merges, ELZ-419
owns them). In the last commit: this Piece's `entries` row in
`docs/plans/release-plan.json` (`manifest_sha256`, and `note` equal to the new
`contract`; keep its primary `job`, since this task is a secondary
contribution) and the generated files, regenerated from current `main` and
never hand-merged.

## Acceptance

Memory and PostgreSQL Stores unless a case says otherwise:

- 10,000 operations for one tenant, with a clock that advances so that
  earlier receipts expire, and with no outbox (or each item acknowledged): no
  refusal. After them, a load makes one checkpoint call and returns a bounded
  tail (assert both counts).
- Approval room: start at a confirmed checkpoint containing 65,536 terminal
  version 2 ASK lines already evictable at the committed `W`. Without
  requiring an intervening successful command, durably compact and reload
  before attempting another Approval mutation that would hit the bound. Admit
  a new ASK and verify it after reopen. Separately, a long run of distinct ASK
  operations that are released or stale and then expire: each cycle retires
  their lines.
- A cut after a command append and before its checkpoint: replay from the
  prior confirmed checkpoint plus the tail makes the same decisions and gives
  the same projection.
- 1,000 resources for one tenant, and a removal that frees one from the
  projection and reports the new absent revision `L`.
- Delete and recreate a resource. Then commands with fresh identities whose
  `expected_revision` was read before the removal are
  `{:conflict, :stale_revision}` against the absent resource and against the
  recreated one. A create prepared before a removal of another resource is
  stale too. For a new version 2 identity, an ordinary field write to
  `"$checked_command.remove"` is refused; a pending ASK of version 1 origin
  with such a write releases it as a field write, and replay keeps it a field
  write.
- Retries: a retry inside the window returns the first result with no second
  effect; changed bytes for a retained identity are `{:conflict, :identity}`;
  after eviction `execute/3` with the original issuance is
  `{:refused, :expired}` and `release/4` is `:not_found`, with no effect; a
  `release/4` retry of a terminal receipt read from a checkpoint with another
  descriptor or other facts is `{:release_refused, :binding_mismatch}`; a
  request issued more than `max_skew_ms` ahead is
  `{:refused, :issued_in_future}`. The skew boundary: with `W = 200`,
  `window_ms = 100`, `max_skew_ms = 10`, an evicted receipt issued at 99 and
  retried at `now = 190` is `{:refused, :expired}`; `now = 189` is
  `{:refused, :clock_behind}`.
- A pending ASK survives checkpoints, eviction of other receipts and
  retention, and is released later with the same outcome as without them. A
  version 1 ASK released by a version 2 row stays non-evictable, and its retry
  compares version 1 canonical bytes.
- A pending outbox item at sequence `S` stops retention at `S - 1`, and its
  expired receipt stays readable through `result/3`. Then: checkpoint with the
  item pending, ack without another command append, maintain, reopen, and
  prove that the receipt is gone and `low_water` advanced.
- Ack and retention while the receipt is live: acknowledge the item and let
  confirmed retention remove it before the receipt expires, then advance `W`,
  maintain, reopen, and verify that the receipt is evicted. An absent ack row
  above `low_water` does not count as removal.
- A changed `window_ms` or `max_skew_ms` for an existing stream is refused
  before any effect.
- Races: at the same expected head exactly one append wins, and a losing call
  may reload and commit a later, separately valid row; at the same checkpoint
  key only one insert wins; at the same expected `low_water` only one
  advancing retain wins; an append and maintenance on an earlier confirmed
  anchor may both succeed. After each, reopen and prove no lost or repeated
  mutation.
- The live-state budget: at an occupied checkpoint anchor whose projection
  changes after an ack but still cannot fit the proposed command, the
  `:capacity` refusal leaves no command or release row, resource mutation or
  new outbox item; a maintenance marker may already have committed.
- Time alone frees room: a stream at the live-state budget whose receipts
  become evictable only as time passes. With no successful command, after the
  clock passes their expiry, `maintain/3` (and, separately, the pre-append
  compaction of the next command) appends one marker that advances `W`,
  evicts them, and the next command is admitted; after reopen the decisions
  are the same. With a clock that has not passed their expiry, no marker is
  appended and the command stays `:capacity`.
- Stored checkpoints stay bounded: after many maintenance cycles with
  retention, the stream holds no checkpoint below `low_water` on either Store.
- Checkpoint use: an incompatible checkpoint (another version, or the stock
  checkpoint that the existing test installs) is never used, and a pruned
  stream with no usable checkpoint is `{:unknown, :unresolved}`.
- The v1 reader and migration: a stream written by the current code (a
  pending ASK, terminal receipts, an unacknowledged outbox item) loads through
  an upgraded fold; exact retries return their results; the pending ASK
  releases; the item acknowledges; version 2 commands follow.
- Wave 4: a full restart and the next reply after retention removed the
  original acknowledged rows and eligible receipts.
- The tests of `domain/kill-switch` and `workflow/tenant-lifecycle`, and the
  wave 5 and wave 6 root tests, pass with `now`, `issued_at_ms` and upgraded
  folds.
- `test/checked_command_copy_support_test.exs`: its pinned count of 17
  enabled PostgreSQL cases (in two places) changes only by a deliberate update
  to the new count; its real-helper and no-skipped-case assertions stay.
- `mix check --affected origin/main` exits 0, or the pull request records the
  exact reason a command cannot run on the host. `git diff --check` exits 0.
  The full hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece keeps durable state and decides retries), and the exact-head
  automated review with its threads answered and resolved, or the authorized
  replacement review under `AGENTS.md` section 6.
