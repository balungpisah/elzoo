# ELZ-419 — state/conversation: an unbounded conversation on its own event-log stream

- Dependencies: ELZ-415, ELZ-416

## Outcome and scope

Today a conversation is one resource field (`"conversation"`) written through
`assembly/checked-command`: `prepare/3` rewrites the whole state on each
write, and `view/2` reads it. The state holds at most 64 messages, 64
associations and 65,536 encoded bytes. So at most 32 two-message turns fit,
and the byte bound can stop a conversation earlier. New contract, a breaking
change under the rule of ELZ-415 (same Piece ID); the README gets a
`## Changes` entry with what breaks and how to move.

**Storage.** One `state/event-log` stream for each conversation, named by the
Piece `conversation/<target_tenant>/<conversation_id>`. Each segment follows
`state/artifact`'s segment rule: 1–64 bytes matching `[A-Za-z0-9._-]+`, and
neither `.` nor `..`. The longest name is 142 bytes, within the Store's
200-byte bound. The caller supplies the Store. Records are self-contained
and immutable:

- `conversation_input`: `message_id`, `role` (`"user"` or `"source"`),
  `actor`, `text`;
- `conversation_association`: `input_message_id`, `run_id`;
- `conversation_answer`: `message_id`, `actor`, `text`, `run_id`,
  `input_message_id`.

Bounds as today: `actor`, message IDs and Run IDs are 1–128 valid UTF-8 bytes
without NUL; `text` is 1–4,096 valid UTF-8 bytes, NUL allowed, kept byte for
byte. There is no cap on the number of messages or associations; Store
sequences stay bounded by the signed 64-bit integer. The README declares the
exact codec (kind names, schema version, fields and encoding) and the
worst-case encoded payload. The owner refuses at start a Store whose
`max_record_bytes` is below that size.

**Owner and writes.** `Elzoo.Conversation.start_link(opts)` starts one owner
for one conversation, supervised by the caller. Options: `store`,
`target_tenant`, `conversation_id` (the README lists any others). At start it
checks that the Store reports `append_visibility: :atomic` and the record
size above, reads the whole stream once, validates every row (contiguous from
sequence 1, stream, kind, exact payload, digest) and folds it, checking the
cross-history rules. A stream with `low_water > 0`, or a row or history that
fails these checks, is damage: `start_link/1` returns `{:error, :damaged}`.
Its memory grows with the conversation while it lives (each
message ID with its content digest, each input with its association and
answer); the README states it.

Three calls, each with one exact DTO. The host vouches for every field:

    append_input(owner, %{message_id, role, actor, text})
    associate_run(owner, %{input_message_id, run_id})
    append_answer(owner, %{message_id, actor, text, run_id, input_message_id, completed})

and one read-only call, `check(owner, intents)`. `intents` is a non-empty
list, in command sequence order, of `{:input, dto}`, `{:association, dto}` or
`{:answer, dto}` with the DTO of the matching call: the conversation's
earlier committed but undelivered intents, then the candidate. The owner first
reads the rows after its head (as an append does after a conflict) and folds
them, then applies the intents in order to a copy of that projection with the
same decision rules, and returns one decision per intent: `:ok` for a new
admissible record, or the same duplicate or refusal decision as the write
against the same history (`{:ok, :already_present}` or `{:refused, code}`).
It never appends or reserves a sequence. A refresh that cannot read the
Store returns `{:error, :unavailable}`; a row that fails validation returns
`{:error, :damaged}`. These results apply both to `check/2` and to an
append's refresh after a compare-and-set conflict. Each owner call has a bounded
timeout that the README states: a timed-out check returns
`{:error, :timeout}`; a timed-out append returns `{:unknown, :unresolved}` and
is retried only with the identical operation.

`completed` is the host's boolean fact that the Run completed. Results:

- `{:ok, %{sequence: s}}`: this call committed its record at `s`.
- `{:ok, :already_present}`: the identical record is already committed; no
  second record. An input or an answer is identical when its message ID and
  complete canonical content (kind, every field, every reference) are equal.
  An association is identical when its exact `{input_message_id, run_id}`
  pair is committed.
- `{:refused, code}` with today's string codes: `"invalid_request"` for a
  malformed DTO, and the Cure decision table with today's precedence for
  `"duplicate_message_id"`, `"missing_input"`, `"already_associated"`,
  `"run_not_completed"`, `"association_mismatch"` and `"already_answered"`.
  The one exception to that precedence is the identical record above, checked
  first. A message ID is unique across all roles: the same ID with other
  content is `"duplicate_message_id"`.
- `{:error, :contended}`: the Store's compare-and-set on the head lost more
  times than the bound that the README states. On each conflict the owner
  reads only the new rows, folds them and decides again.
- `{:error, :unavailable}` or `{:error, :damaged}`: that refresh could not
  read the Store, or found a row that fails validation; nothing was appended
  by this call.
- `{:unknown, :unresolved}`: an append was indeterminate and could not be
  resolved. The owner resolves an indeterminate append by the proposed row's
  nonce and bytes (`Elzoo.DurableLog` confirmation) or by finding the
  identical record as defined above, never by the existence of the referenced
  input. A missing row is not proof that nothing committed. The caller retries
  only the identical operation; that retry is safe by the identity rule.

**Reads without an owner.**

    page(store, scope, %{target_tenant: t, conversation_id: c}, from_sequence, limit)
    tail(store, scope, %{target_tenant: t, conversation_id: c}, count)

- `scope` is `%{tenant, actor, resources}` as for `view/2` today
  (`resources` are the granted conversation IDs, at most 64). Before any Store
  call they validate the scope, the reference, the grant,
  `from_sequence >= 1`, and `limit` and `count` within the bound that the
  README states. A malformed scope is `{:error, :invalid_scope}`; another
  malformed operand is `{:error, :invalid_request}`; `scope.tenant` other than
  `target_tenant`, or a conversation ID not in `resources`, is `:not_found`.
- `page/5` validates the full expected range from `from_sequence` through
  `min(read_head, from_sequence + limit - 1)`. `tail/4` caps the requested
  range at the sampled head and requires every row of that range; a concurrent
  append is not part of this tail. Each row is checked for contiguity, stream,
  kind, exact payload and digest; the cross-history rules are the owner's
  fold. A missing expected row, an invalid returned row, a nonzero
  `low_water` in either observed head, or `{:error, {:pruned, _}}` from the
  Store gives `{:error, :damaged}`.
- A page returns the entries in stream order with their sequences, and the
  head revision. Each call makes a bounded number of Store calls and returns
  at most `limit` or `count` rows (provider work inside the Store is not
  claimed bounded: the Memory Store scans its map).

**Needs (README).** The Store's append is atomic: all rows of one append
become visible together. Nothing retains or prunes these streams out of band:
the Store's append compare-and-set checks the head revision, and retention
moves `low_water` without moving it.

**Removed.** `prepare/3` over a checked-command snapshot, `view/2`, the field
state, and the `"capacity"` and `"stale_revision"` refusals. Version 2 writes
and reads do not use Authorization. `import_v1/3` retains
`domain/authorization` as a migration-only dependency for the exact version 1
portable-value validation. The manifest declares `state/event-log`, that
migration-only `domain/authorization`, and the `integration/sql` test closure
that its PostgreSQL tests use, and replaces the pure-only Config and Control
declarations with the owner's (construction-time Store and target; the owner
process and its writes).

**Migration from version 1.** `import_v1(store, %{target_tenant, conversation_id}, v1_snapshot)`
takes the snapshot that `CheckedCommand.resource/3` returns for a version 1
conversation resource. It validates it with the version 1 rules, appends to
an empty stream each message in the order of the version 1 message list, and
each association directly after its input message. It preserves the exact
ordered message list and the exact input-to-Run mapping. Association
iteration order becomes the new stream's order, which can differ from the
version 1 association list (version 1 appends associations in the order of
their operations); the README documents that change. After the import it
verifies those two projections. A stream that already holds a prefix of this
import (an import cut by a crash) is completed. Results:
`{:ok, %{sequence: s}}` (the last imported row); `{:ok, :already_present}`
when the stream already holds exactly this import; `{:error, :not_empty}` for
a stream with other content; `{:error, :invalid_snapshot}`; and
`{:unknown, :unresolved}` as for a write. The caller picks the new reference,
because version 1 IDs need not be valid segments. The README states the
offline step: quiesce all old writers, resolve or explicitly abandon pending
old ASK operations (a pending old ASK cannot be released under a replacement
preparer with different canonical or prepared bytes), drain the old outbox
custody, and keep the target stream exclusive to the importer until
verification passes; only then route writes to the new owner. The README
`## Changes` entry adds, for the Wave 4 Need (below): before traffic resumes
on this revision, stop every other party that acknowledges the channel's
outbox items, let their in-flight acknowledgements finish, and give the
channel sole authority to acknowledge them; a reopen is never permission to
append an acknowledged item whose Conversation row is missing.

**Wave 4.** The signed channel keeps its atomic boundary on
`assembly/checked-command`: the gated write, the durable approval, the receipt
and the pending outbox item still commit in one append. The conversation
append becomes a delivery after the commit:

- Before command commit, the channel validates the exact Conversation intent
  against the conversation's ordered admitted state, including committed intents
  not yet visible in Conversation: it calls `check/2` with this
  conversation's earlier committed, undelivered intents in command sequence
  order followed by the candidate, and admits the candidate only when every
  earlier decision is `:ok` or `{:ok, :already_present}` and the candidate's
  is `:ok` (`{:ok, :already_present}` is not admission for a different
  command). It keeps no index of a conversation itself. It binds the canonical intent, or its exact
  digest, into the write that Authorization and Approval check (a write of a
  channel-owned resource; a command with no write gets no outbox item). The
  retained response carries that same intent (an input, an association, or an
  answer with its Run completion fact; the 8,192-byte ETF response bound of
  `assembly/checked-command` fits the largest), and delivery verifies the
  binding. Idempotent delivery of the same command is not permission for a new
  command to claim an existing message ID.
- Wave 4 Need (document in `pieces/state/conversation/README.md`): the
  channel is the sole writer of the conversation streams it delivers to, and
  the only party that acknowledges its own outbox items: each with that
  item's own nonce, and only after that item's Conversation append is proven
  (a primary or reply item also only after its native-work custody, below).
  `check/2` does not reserve a message ID. If an outside writer commits the
  same ID with different content before delivery, delivery is refused and
  blocks later deliveries to that conversation. An identical outside write is
  indistinguishable from redelivery, so the exclusivity requirement is not
  enforced by `check/2`. An acknowledged item whose Conversation row is
  missing breaks the Need. Once the channel confirms that acknowledgement
  (the item's original key and nonce) and reads the row as absent, it
  dispatches no new append for that item, live or after a reopen, and fences
  with `{:delivery_unproven, kind, key}`. Live, the fence holds until a
  fenced reopen. After a fenced reopen, recovery reads the row read-only:
  the exact row (compared with the input rebuilt from the retained command:
  kind, message ID, role, actor and text) proves the delivery and clears the
  fence; no row keeps it. An unreadable row, a row with conflicting content
  and an acknowledgement under another nonce are not this case and keep
  their own dispositions. The channel detects this breach for each item that
  it holds: live, an item that it observed or whose command it issued; after
  a fenced reopen, an item whose custody it persisted (the README lists
  those kinds). An item that it does not hold (acknowledged before the
  channel first observes it, or, after a reopen, an item whose custody it
  did not persist) leaves no pending item and no custody, and nothing that
  the channel reads shows the breach (a README limit, as for an identical
  outside write). Such an input is never delivered, and later inputs of the
  conversation are; the README states the outcome for each other kind.
- Every Conversation-writing command, including associations and answers, is
  configured with a delivery notification (today the association and answer
  descriptors have no outbox destination). The channel processes each
  conversation's not-yet-delivered intents in command sequence order,
  rebuilding each from its committed receipt (`CheckedCommand.result/3` by the
  identity in the notification) and appending it through that conversation's
  owner. An unknown delivery remains pending and is retried with the identical
  intent before any later intent of the same conversation is delivered. A
  definite refusal is reported, leaves the item pending, and blocks later
  deliveries to that conversation. Order is kept within a conversation, the
  only scope its records reference; an undelivered intent of another
  conversation of the tenant does not hold back this conversation's
  deliveries. The tenant's outbox window stays shared: admission and
  observation keep refusing new commands while the window is full.
- A proven Conversation append (`{:ok, _}` or `{:ok, :already_present}`)
  marks delivery complete; it does not discharge primary/reply native-work
  custody. Once delivery is durably proven, the channel acknowledges the
  delivery-only association and answer items with their original key and
  nonce. It acknowledges primary and reply items only after both delivery and
  the existing native-work custody and teardown checks are complete, and it
  skips an already-proven Conversation append while that custody remains
  pending. The reply source, association and original-key/nonce custody facts
  are persisted independently of compactable CheckedCommand rows.
- So a message or association is visible in the conversation after its
  delivery, not at the command's commit. Reads use `page/5` and `tail/4`.

This task owns the wave 4 files and rewrites that composition:
`examples/support/wave4_channel.ex`, `examples/wave4_channel.exs`,
`test/support/wave4_channel_helper.exs`, `test/wave4_channel_test.exs`,
`test/support/wave4_command_conversation_helper.exs` and
`test/wave4_command_conversation_test.exs`. It keeps every delivery, scope,
approval and recovery test of the two wave 4 test files, moved and adapted to
delivery-time visibility, never deleted. Only a case that tested the old field
state alone (its 64-message capacity, or the `"stale_revision"` refusal of
`prepare/3`) is replaced, by its version 2 counterpart. The pull request lists
each moved or replaced test.
When this task merges, the coordinator lists in ELZ-418 the exact remaining
wave 4 files that call `assembly/checked-command` and their calls, the
custody facts that this task persists, and the original command rows,
receipts and acknowledgement rows that the channel still reads. ELZ-418's
no-retention Need on the channel's tenant stream keeps those rows; neither
task delivers recovery after retention.

Paths: `pieces/state/conversation/**`, the six wave 4 files above, and in the
last commit this Piece's `entries` row in `docs/plans/release-plan.json`
(`manifest_sha256`, and `note` equal to the new `contract`; keep its primary
`job`, since this task is a secondary contribution) and the generated files,
regenerated from current `main` and never hand-merged.

## Acceptance

- Pure tests: the codec (exact keys and bounds, NUL kept, the worst-case
  size, malformed input fails closed); the fold over generated histories
  (damage for a duplicate ID, a reference before its definition, a double
  answer, a wrong stream or sequence, a bad digest); the decision precedence
  including the identical-record exception.
- Store tests, Memory and PostgreSQL:
  - 100,000 messages in one conversation with no refusal; a deep page and a
    tail window correct; the owner's start time measured and stated.
  - Identical retries of an input, an answer and an association: one record
    each, and `{:ok, :already_present}`.
  - The same message ID with other content, raced by two independent owners
    (or through an append barrier on one Store): exactly one record, the
    other `"duplicate_message_id"`.
  - Concurrent appends from independent owners: contiguous sequences, no lost
    message.
  - `"already_answered"`: a new answer ID with `completed: true` for an input
    with its matching association and an existing answer. `"missing_input"`: a
    new answer ID with `completed: true` for an input that does not exist.
  - Lost replies, for a message append and for an association, each in two
    cases: committed (the owner resolves it to `{:ok, _}`, and an identical
    retry gives `{:ok, :already_present}`) and unresolved (`{:unknown,
    :unresolved}`, then an identical retry that is safe either way).
  - `check/2`: decision parity with the write for each result case, an
    unchanged head, a refresh after an independent append, an association
    after an undelivered input and an answer after an undelivered matching
    association (both `:ok`), a conflicting candidate refused before commit,
    and both timeout results, including an append that commits after the
    caller times out.
  - `page` and `tail` for another tenant or an ungranted conversation:
    `:not_found` with zero Store calls (count them); a malformed scope:
    `{:error, :invalid_scope}` with zero Store calls.
  - A pruned prefix: install a valid checkpoint, retain through it with the
    low-water compare-and-set; then the owner does not start and `page` and
    `tail` give `{:error, :damaged}`.
  - Migration: a version 1 fixture with 32 input messages, 32 answers and 32
    associations, including associations admitted in an order different from
    input order. `import_v1/3` preserves the exact ordered message list and
    the exact input-to-Run mapping; a second import is
    `{:ok, :already_present}`; an import cut after a prefix is completed; an
    import into a stream with other content is `{:error, :not_empty}`.
- Wave 4: each kept test passes on the new composition. New cases: a message
  is not in the conversation before its delivery and is after it; a
  conflicting signed command (a reused message ID, or an answer with the wrong
  association) with an earlier delivery pending is refused before commit, and
  the conflict does not block the next valid command; a cut after the
  Conversation commit but before the ack commits (redelivery adds no row); a
  committed ack whose reply is lost (confirm the original key and nonce; no
  redelivery is required). An outside acknowledgement of an input, an
  association and an answer whose Conversation row is missing, each live and
  after a fenced reopen: the channel fences with
  `{:delivery_unproven, kind, key}`, and no later delivery or native action
  of that conversation passes the fence. Count the append attempts: zero
  when the acknowledgement is seen before the channel's first dispatch; the
  one in flight and no other when it lands during that dispatch. After a
  fenced reopen, the exact row that landed later clears the fence
  read-only. An acknowledgement before the channel first observes a primary
  input, in a cold cut: no append is attempted for that input, and the next
  input of the conversation is delivered (the stated limit).
- `mix check --affected origin/main` exits 0, or the pull request records the
  exact reason a command cannot run on the host. `git diff --check` exits 0.
  The full hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece keeps durable state and the composition moves an atomic
  boundary), and the exact-head automated review with its threads answered
  and resolved, or the authorized replacement review under `AGENTS.md`
  section 6.
