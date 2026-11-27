# state/conversation

One conversation on its own `state/event-log` stream. An owner process per
conversation appends immutable, self-contained records: input messages,
input-to-Run associations and completed answers. Reads page through the
stream without an owner. There is no cap on the number of messages. This
Piece owns no authentication, authorization, Run creation, retention or
writer exclusivity.

## Interface

```elixir
{:ok, owner} =
  Elzoo.Conversation.start_link(
    store: store,                  # a ready Store term, e.g. the integration/sql Store
    target_tenant: "tenant-1",     # stream-name segments, see Records
    conversation_id: "conversation-1"
  )

Elzoo.Conversation.append_input(owner, %{message_id: m, role: "user", actor: a, text: t})
Elzoo.Conversation.associate_run(owner, %{input_message_id: m, run_id: r})
Elzoo.Conversation.append_answer(owner, %{message_id: m2, actor: a, text: t,
                                          run_id: r, input_message_id: m, completed: true})
Elzoo.Conversation.check(owner, [{:input, dto}, {:association, dto}, {:answer, dto}])

reference = %{target_tenant: "tenant-1", conversation_id: "conversation-1"}
scope = %{tenant: "tenant-1", actor: "reader", resources: ["conversation-1"]}
Elzoo.Conversation.page(store, scope, reference, from_sequence, limit)
Elzoo.Conversation.tail(store, scope, reference, count)
Elzoo.Conversation.import_v1(store, reference, v1_snapshot)
```

`start_link/1` takes exactly the options `store`, `target_tenant` and
`conversation_id`; the module's `child_spec/1` starts it under the caller's
supervisor. The DTOs are exact plain maps with exactly these keys; the host
vouches for every field. `completed` is the host's boolean fact that the Run
completed. Each owner call takes an optional last argument, a positive
timeout in milliseconds (default 30,000).

### Write results

- `{:ok, %{sequence: s}}`: this call committed its record at `s`.
- `{:ok, :already_present}`: the identical record is already committed; no
  second record. An input or an answer is identical when its message ID and
  its complete canonical payload (kind, every field, every reference) are
  equal. An association is identical when its exact
  `{input_message_id, run_id}` pair is committed. This is checked before every
  other rule, so an identical answer retried with `completed: false` is
  `{:ok, :already_present}`.
- `{:refused, code}`: `"invalid_request"` for a malformed DTO, else the Cure
  decision table of `cure/elzoo/conversation.cure`, with this precedence:
  - input: `duplicate_message_id`;
  - association: `missing_input` (no such input, or the ID is an answer),
    then `already_associated`;
  - answer: `duplicate_message_id`, `run_not_completed`, `missing_input`,
    `association_mismatch` (no association, or another Run), then
    `already_answered`.

  A message ID is unique across all roles: the same ID with other content is
  `"duplicate_message_id"`. Before it refuses, the owner reads the rows after
  its head, as after a lost compare-and-set, and decides once more, because
  rows that another writer appended can make the same record identical or
  admissible: a refusal is decided on the history as of that read.
- `{:error, :contended}`: the Store's head compare-and-set lost 9 times in one
  call (the bound is 8 retries). On each loss the owner reads only the rows
  after its head, folds them and decides again; nothing was appended.
- `{:error, :unavailable}` or `{:error, :damaged}`: the refresh after a lost
  compare-and-set or before a refusal could not read the Store, or found a
  row that fails validation; nothing was appended by this call. The owner
  keeps its last validated model, and each later refresh tries again.
- `{:error, :rejected}`: the Store definitively rejected the append (for
  example a sequence beyond the signed 64-bit range); nothing was appended.
- `{:unknown, :unresolved}`: the append was indeterminate and could not be
  resolved, or the call timed out or the owner exited during the call. The
  owner resolves an indeterminate append by the proposed row's nonce and bytes
  (`Elzoo.DurableLog.confirm/5`), by finding its own row at the next sequence,
  or, when another row holds that sequence, by deciding again; never by the
  existence of the referenced input. A missing row is not proof that nothing
  committed. Retry only the identical operation: by the identity rule the
  retry is `{:ok, :already_present}` if the first attempt committed.

### check

`check(owner, intents)` takes a non-empty proper list of
`{:input | :association | :answer, dto}` in command sequence order: a
conversation's earlier committed but undelivered intents, then the candidate.
The owner first reads and folds the rows after its head, exactly as after a
lost compare-and-set, then decides the intents in order against a copy of
that model, applying each admitted intent before the next. It returns
`{:ok, decisions}` with one decision per intent: `:ok` for a new admissible
record, or the decision the write would give against the same history,
`{:ok, :already_present}` or `{:refused, code}` (a malformed DTO is
`{:refused, "invalid_request"}`). It never appends or reserves a sequence or
a message ID. The call's timeout is one deadline for the whole call:
validating and encoding the intents in the caller runs under it, and the
owner call gets only the time that remains; there is no count ceiling.
Errors: `{:error, :invalid_request}` for a malformed list,
`{:error, :timeout}` when the deadline passes, `{:error, :unavailable}` when
the refresh cannot read the Store or the owner is down, and
`{:error, :damaged}` when the refresh finds a failing row.

## Records

One stream per conversation, `conversation/<target_tenant>/<conversation_id>`.
The caller picks the reference. Each of its two parts is a segment under
`state/artifact`'s segment rule: 1–64 bytes matching `[A-Za-z0-9._-]+`, and
neither `.` nor `..`. So the longest name is 142 bytes, within the Store's
200-byte bound (`Elzoo.DurableLog.Codec.stream?/1`); each part has its own
bound; a name never holds a `/` other than its two separators, so one name
never stands for two references; and the alphabet is ASCII. Any other
reference is `{:error, :invalid_options}` at start and
`{:error, :invalid_request}` for `page/5`, `tail/4` and `import_v1/3`.

| Kind | Payload keys, in this order |
| --- | --- |
| `conversation_input` | `message_id`, `role` (`"user"` or `"source"`), `actor`, `text` |
| `conversation_association` | `input_message_id`, `run_id` |
| `conversation_answer` | `message_id`, `actor`, `text`, `run_id`, `input_message_id` |

Every row has `schema_version` 1. A payload is a JSON object with exactly the
kind's keys in that order, every value a JSON string, encoded by Jason 1.4.5
with its default escaping (control characters as `\u00XX`, no escaped `/`, no
whitespace). A stored payload is valid only when it decodes to exactly these
keys, its values satisfy the bounds and it re-encodes to the same bytes.
`actor`, message IDs and Run IDs are 1–128 valid UTF-8 bytes without NUL;
`text` is 1–4,096 valid UTF-8 bytes, NUL allowed, kept byte for byte.

The worst-case payload is an answer with four 128-byte IDs of the byte
`0x01` and a text of 4,096 NUL bytes: **27,720 bytes**. The owner and
`import_v1/3` refuse a Store whose `limits.max_record_bytes` is below it. The
Store term's fold must declare the three kinds (either role; this Piece does
not use `Elzoo.DurableLog.replay/3`) and version 1.

## Owner

At start the owner checks the options, that the Store term carries a fold and
limits as above and that the Store reports `append_visibility: :atomic`
(otherwise `{:error, :invalid_options}` or `{:error, :unsupported_store}`).
It then reads the whole stream once in pages of 1,000 rows and validates every
row: contiguous from sequence 1, stream, kind, schema version, the Store's row
checks (nonce, size, digest) and the exact payload. It folds the rows with the
write decisions: every stored row must be a new admissible record, so a
duplicate ID, a reference before its definition, a second association, a
second answer or a repeated identical row is damage. A stream with
`low_water > 0`, or any failing row, makes `start_link/1` return
`{:error, :damaged}`; a Store read failure returns `{:error, :unavailable}`.

The owner keeps, while it lives, each message ID with its kind and the SHA-256
of its payload, and each input with its Run and whether it is answered. Its
memory and its start time grow with the conversation. Measured on one local
development machine (OTP 29.1.3, PostgreSQL 19.0) with 100,000 input messages
written through one owner, in three runs of `test/elzoo/conversation_store_test.exs`
(each run prints its numbers; the slowest PostgreSQL run shared the database
server with other test runs):

| Store | 100,000 appends | Owner start over 100,000 rows | Owner process memory after start |
| --- | --- | --- | --- |
| PostgreSQL (`integration/sql`) | 36.5–64.3 s | 1.3–1.5 s | 22.6–28.1 MB |
| Memory | 2.0–2.3 s | 6.6–7.7 s (its read scans its map) | 28.2 MB |

A write that the owner's current model admits is appended at once, one row
with the head compare-and-set and no read before it. A write that the model
would refuse first reads the rows after the owner's head and decides again
(see Write results), and a write after a lost compare-and-set reads only the
new rows. Each call is serialized in the owner process.

## Reads without an owner

`page(store, scope, reference, from_sequence, limit)` returns the entries
`from_sequence..min(head, from_sequence + limit - 1)`;
`tail(store, scope, reference, count)` returns the last `count` entries up to
the head it sampled, so a concurrent append is not part of that tail. Both
return `{:ok, %{revision: head_revision, entries: entries}}` with the entries
in stream order:

```elixir
%{sequence: s, kind: :input, message_id: _, role: _, actor: _, text: _}
%{sequence: s, kind: :association, input_message_id: _, run_id: _}
%{sequence: s, kind: :answer, message_id: _, actor: _, text: _, run_id: _, input_message_id: _}
```

Before any Store call they validate, in this order: the scope (an exact plain
map `%{tenant, actor, resources}` with IDs as above and at most 64 granted
conversation IDs; else `{:error, :invalid_scope}`), the reference (an exact
plain map of two segments; else `{:error, :invalid_request}`), the grant
(`scope.tenant` must equal `target_tenant` and the conversation ID must be in
`resources`; else `:not_found`), then `from_sequence >= 1` and `limit` or
`count` in 1..1,000 and the Store term (else `{:error, :invalid_request}`).
`page/5` makes one Store call and `tail/4` two (head, then read). Every
returned row is checked for contiguity, stream, kind, exact payload and digest;
the cross-history rules are the owner's fold. A missing expected row, an
invalid row, a nonzero `low_water` in an observed head or a pruned read is
`{:error, :damaged}`; a Store read failure is `{:error, :unavailable}`. Each
call returns at most `limit` or `count` rows; provider work inside the Store
is not claimed bounded (the Memory Store scans its map).

## Needs

- The Store's append is atomic: all rows of one append become visible
  together. The Store term carries the fold and limits that its rows are
  validated with.
- Nothing retains or prunes these streams out of band: the Store's append
  compare-and-set checks the head revision, and retention moves `low_water`
  without moving it. A pruned prefix is damage.
- The host authenticates the principal, vouches for every DTO field and read
  grant, allocates stable Run IDs and attests Run completion.
- Wave 4: the signed channel is the sole writer of the conversation streams
  that it delivers to, and the only party that acknowledges its own outbox
  items: each with that item's own nonce, and only after that item's
  Conversation append is proven (a primary or reply item also only after its
  native-work custody). `check/2` does not reserve a message ID. If an outside
  writer commits the same ID with different content before delivery, the
  delivery is refused, and the channel blocks later deliveries to that
  conversation; deliveries to other conversations continue, and only the
  tenant's outbox window is shared (admission and observation refuse while
  it is full). An identical outside write cannot be told from a redelivery,
  so `check/2` does not enforce this exclusivity. An item acknowledged with
  its own nonce whose Conversation row is missing breaks the Need: the
  channel dispatches no new append for it, live or after a reopen, and
  fences with `{:delivery_unproven, kind, key}`. The live fence holds until a
  fenced reopen; recovery then reads the row read-only, and only the row
  equal to the intent rebuilt from the retained command proves the delivery.
  An unreadable row is retried, a row with other content is the refusal
  fence, and an acknowledgement under another nonce is the superseded fence.
  Detection covers the items the channel holds: live once it has observed
  the item, and after a fenced reopen the items of a round whose custody it
  persisted. An acknowledgement before the channel first observes an item
  leaves no pending item and no custody, so nothing the channel reads shows
  it: the Need excludes it, as it excludes an identical outside write, and
  later deliveries to that conversation proceed without that item.

## Migration from version 1

`import_v1(store, reference, v1_snapshot)` takes the snapshot that
`CheckedCommand.resource/3` returns for a version 1 conversation resource
(`%{tenant, resource, revision, fields}`; a channel resource must first drop
fields other than `"conversation"`). It validates the snapshot with the
version 1 rules (exact sorted portable records normalized by
`domain/authorization`, at most 64 messages and associations, at most 65,536
encoded bytes, the consistency rules) or returns
`{:error, :invalid_snapshot}`. It plans one row for each message in the
order of the version 1 message list, and each association directly after its
input. So the association order becomes the input order, which can differ
from the version 1 association list (version 1 appended associations in the
order of their operations); the message list and the input-to-Run mapping are
preserved exactly. It appends the plan to the stream one row at a time with
the compare-and-set, then reads the whole stream again and verifies those two
projections.

Results: `{:ok, %{sequence: s}}` (the last imported row) when it appended;
`{:ok, :already_present}` when the stream already held exactly this import (an
empty version 1 snapshot is `{:ok, :already_present}` on an empty stream); a
stream that holds a prefix of this import (an import cut by a crash) is
completed; `{:error, :not_empty}` for a stream with other content;
`{:error, :invalid_snapshot}`; `{:unknown, :unresolved}` as for a write (run
the import again); and `{:error, :invalid_request | :unsupported_store |
:damaged | :unavailable | :rejected | :contended}` for a malformed reference,
an unsupported Store, a damaged or unreadable stream, a rejected append, or
more concurrent appends than the plan length plus 8. Version 1 IDs need not
be valid segments (they are 1–128 bytes of any UTF-8 without NUL), so the
caller picks the new reference.

The offline step, in this order:

1. Quiesce every old writer of the version 1 resource.
2. Resolve or explicitly abandon each pending old ASK operation: a pending old
   ASK cannot be released under a replacement preparer with different
   canonical or prepared bytes.
3. Drain the old outbox custody: acknowledge or settle every pending item.
4. Keep the target stream exclusive to the importer until the import returns
   `{:ok, _}` (its verification passed).
5. Only then route writes to the new owner.

## Evidence

- `cure/elzoo/conversation.cure`: the pinned Cure checks the types and the
  declared totality of `decide/2`; the identical record is matched first.
- `test/elzoo/conversation_test.exs`: pure scenarios: the codec (exact keys
  and bounds, NUL kept, the worst case, malformed rows failing closed), the
  fold over generated histories and its damage cases, the decision precedence
  including the identical-record exception, the compiled table against the
  stated precedence for all 1,536 combinations of checks, ordered `check`
  decisions, and the version 1 rules and bounds.
- `test/elzoo/conversation_store_test.exs`: every scenario on the Memory Store
  and on a disposable PostgreSQL database through `integration/sql`
  (`ELZOO_TEST_DATABASE_URL`, fail closed): 100,000 messages with a deep page,
  a tail window and the measured start; identical retries; two owners racing
  one ID with other content; four concurrent owners; `already_answered` and
  `missing_input`; committed and unresolved lost replies of an append and an
  association; `check` parity with the write, refresh, chains, conflicts and
  both timeouts including an append that commits after its caller timed out;
  refresh errors; refused reads with zero Store calls; the row checks of
  `page` and `tail`; a pruned prefix; start refusals; the contention bound;
  and `import_v1/3` with a cut import.
- `examples/conversation.exs`: one owner on the Memory Store.

These are finite scenarios and selected checks, not proofs of production
behavior. Memory is volatile; PostgreSQL durability settings are the
consumer's.

## Changes

- ELZ-416 (2026-11-26): the encoded-state bound is measured with the default
  external-term encoding of the pinned OTP 29.1.3 (before 29.1.2); the Piece's
  tests pass on it. No code or API change.
- ELZ-419: a conversation is no longer one resource field written through
  `assembly/checked-command`; it is its own event-log stream with an owner
  process. What breaks: `prepare/3`, `view/2` and the version 1 field state
  are removed, with the 64-message, 64-association and 65,536-byte caps and the
  `"capacity"` and `"stale_revision"` refusals; version 2 writes and reads do
  not use Authorization; a conversation reference is now a pair of segments
  (1–64 bytes of `[A-Za-z0-9._-]`, never `.` or `..`; see Records), where
  version 1 accepted any pair of 128-byte IDs;
  the Piece now needs `state/event-log` and an atomic Store, and keeps
  `domain/authorization` only for `import_v1/3`. How to move: follow the
  offline step above, import each conversation with `import_v1/3` (pick a new
  segment reference where a version 1 tenant or resource ID is not a segment),
  start one owner per conversation under your supervisor, send the three writes
  to it (with `check/2` before your own commit if you queue intents), and read
  with `page/5` and `tail/4`. The wave 4 Need changes too: the channel is
  now the only party that acknowledges its own outbox items. Before traffic
  resumes on this revision, stop every other party that acknowledges the
  channel's outbox items, let their in-flight acknowledgements finish, and
  give the channel sole authority. A reopen is not permission to append an
  acknowledged item whose row is missing.
