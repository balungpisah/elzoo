# ELZ-422 — workflow/run-approval-release: renew the held lease inside the live owner

- Dependencies: ELZ-415, ELZ-416

## Outcome and scope

`Elzoo.RunApprovalRelease` gets a `held` lease token at `start_link/1` and
replaces it only after its own successful `Elzoo.Lease.write/4`. Today,
commands that reach write admission require the current held revision as
`expected_revision`; a mismatch there returns `{:refused, :conflict}`.
Existing duplicate, stale-Attempt and terminal classifications happen first.
`status/2` reports the held revision.
`Elzoo.Lease.renew(lease, owner, keys, ttl_ms)` appends one `lease_renewed`
record to the same stream and returns
`{:renewed, %{keys, held: %{key => held}, refused: %{key => refusal}, errors: %{key => error}}}`.
So a host that renews outside the owner moves the head, and the owner's next
write uses the old fence and fails (`{:refused, :conflict}`). The fence is the
revision: expiry alone does not stop a `Lease.write/4`. Today nobody can renew
the lease of a live owner, and restarting a live owner to refresh its lease can
turn an in-flight effect into a lost outcome.

Add one serialized operation. Existing commands, events and the fold do not
change; the only change to an existing call is the `expected_revision` rule at
the end of this list. This is an improvement under the rule of ELZ-415 (same
Piece ID).

    Elzoo.RunApprovalRelease.renew(owner, ttl_ms)

- The owner handles it in its own process, between two commands, never during
  one. It calls `Elzoo.Lease.renew(lease, held.owner, [stream], ttl_ms)` with
  its own Lease, owner attribution and stream. `ttl_ms` has the Lease bounds
  (`1..86_400_000`).
- Renewed: the result's `held` map has the stream, and the returned token's
  revision is the owner's held revision plus one (only the renewal record was
  appended). The owner installs the token before it handles any later call
  and replies `{:ok, revision, %{until: until}}`: the new held revision and the
  token's `live.until` (lease clock, Unix microseconds).
- Renewed, but the revision is not the held revision plus one: another writer
  appended rows that the owner's model never read. The detecting renewal has
  itself committed, but the owner does not install its token and writes
  nothing afterward: it replies
  `{:refused, {:fenced, %{expected: e, observed: o}}}` and stops with reason
  `{:shutdown, {:fenced, %{expected: e, observed: o}}}`.
- Refused (the stream is in `refused`, for example `:stale`, `:free`,
  `:not_holder`, `:ambiguous` or `:regression`): the lease is lost. The owner
  replies `{:refused, {:lease_lost, refusal}}` and stops with reason
  `{:shutdown, {:lease_lost, refusal}}`. It writes nothing more.
- Unknown with a receipt (`{:indeterminate, info}` for the stream): the owner
  replies `{:indeterminate, info}` and stops with reason
  `{:shutdown, {:indeterminate, info}}`, as it does today after an uncertain
  command write. The host confirms the receipt (the existing `reconcile:`
  start option) and fences before it starts a replacement.
- An error: for a definite no-write error the owner replies `{:error, reason}`
  and keeps its held token: `{:invalid, _}` (for example `ttl_ms`),
  `:caller_transaction`, `{:schema, _}`, `{:rejected, _}`, a PostgreSQL
  `:contended` or `:unavailable` before the renewal append begins (that
  adapter reports these only before its first write statement), and the
  Memory `:clock_unavailable` or `:malformed` from its pre-append head read.
  It then keeps working; the lease stays as it was until its `until`, and the
  host may retry or stop admission. No other error is proof that no renewal
  committed. The Memory backend's `{:error, :unavailable}` is potentially
  committed (its owner process can exit after the Store append and before the
  reply, and the result carries no nonce receipt): the owner stops, replies
  `{:unknown, :no_receipt}` with exit reason
  `{:shutdown, {:unknown, :no_receipt}}`, and does not invent a nonce. This is
  not a `reconcile:` receipt: the host confirms backend and predecessor
  fencing and reads the durable head before it opens a replacement.
- A renewal moves the head between a caller's `status/2` and its next
  command. `assembly/run-engine` reads `status/2` and then sends the command in
  a second call, and a refused finish command halts it with
  `:terminal_commit_pending`. So commands that reach write admission check the
  expected revision after the existing classifications for duplicates, stale
  Attempts and terminal outcomes. They accept the current revision, or one
  separated from it solely by successful renewals installed by this live
  owner. The floor resets on startup and after every successful Run append,
  including child, death and recovery writes. Nothing is normalized across
  another writer or an owner restart. Every other check is unchanged, and
  replies still carry the current held revision.

Update the README (a renewal section and a `## Changes` entry for this task:
the new `renew/2` and the `expected_revision` rule) and `piece.json`
(contract, the Control declaration, grounding). In the last commit, update the
Piece's `entries` row in `docs/plans/release-plan.json` (`manifest_sha256`, and
`note` equal to the new `contract`; keep its primary `job`, since this task is
a secondary contribution) and the generated files, regenerated from current
`main` and never hand-merged. Only `pieces/workflow/run-approval-release/**`
changes outside the index files.

## Acceptance

Tests in `pieces/workflow/run-approval-release/test`, on the PostgreSQL Store
that the existing tests use unless a case names the Memory Lease backend:

- A real owner write after renewal: create the Run without starting an
  Attempt. Renew and verify that `status/2` reports the returned revision.
  Begin the Attempt at that revision, then complete it at the revision
  returned by `begin_attempt`, using `:failed` with `evidence_ref: nil` or
  valid completion evidence. Both writes apply; the stream holds the renewal
  followed by both Run records.
- A command whose `expected_revision` is from before one or more renewals of
  this live owner, with no Run record written since, is applied. One
  separated from the current revision by a Run record write (including a child
  or death write) or by another writer is still `{:refused, :conflict}`.
- Restart: renew in the first owner, stop it, and start a replacement at the
  renewed fence. A new write carrying the revision from before that renewal
  still conflicts, including after the replacement renews. A restart alone
  does not invalidate a revision equal to the replacement's startup fence.
- Refusal after a lost renewal: with a short TTL, let the lease expire and
  have another owner attribution claim the stream, then renew. The reply is
  `{:refused, {:lease_lost, %{reason: :not_holder}}}`, the owner exits with
  `{:shutdown, {:lease_lost, _}}`, and the first owner writes no further
  record. A renewal after expiry with no other claimant is refused with
  reason `:stale`.
- After a renewal outside the owner (a direct `Elzoo.Lease.renew/4` on the
  same stream and owner attribution), the owner's own detecting renewal can
  commit but is not installed: the reply is `{:refused, {:fenced, _}}`, the
  owner exits, and it writes nothing afterward.
- Unknown renewal with a receipt: a PostgreSQL Lease whose `test_hook` fails
  at `:after_commit` gives `{:indeterminate, _}`, and the owner exits with
  `{:shutdown, {:indeterminate, _}}`. Unknown renewal without a receipt, on
  the Memory Lease backend: at the existing `:before_write` hook, suspend the
  Memory Store and let the renewal queue its append. Once the append call is
  queued, suspend the lease backend, resume the Store, and verify the renewal
  row committed. Kill the backend before it can reply. Assert
  `{:unknown, :no_receipt}` and monitor the Run owner exiting with
  `{:shutdown, {:unknown, :no_receipt}}`.
- Nothing written: `renew(owner, 0)` gives `{:error, {:invalid, :ttl_ms}}`,
  and the next command still succeeds.
- Concurrent command and renewal: one process sends commands in a loop, each
  after reading `status/2`, while another process renews repeatedly. No
  command is refused with `:conflict`, every write is fenced on the newest
  token, and the stream's revisions are contiguous.
- Negative control (a temporary edit, never committed): an owner that keeps
  the old token after a renewal fails the write-after-renewal test with
  `{:refused, :conflict}`.
- `mix test pieces/workflow/run-approval-release/test`,
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. The hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece keeps durable state and fences concurrent owners), and the
  exact-head automated review with its threads answered and resolved, or the
  authorized replacement review under `AGENTS.md` section 6.
