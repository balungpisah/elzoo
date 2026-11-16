# state/conversation

Pure version-1 preparation and bounded projection for immutable conversation
messages and input-to-Run associations. This Piece owns no persistence, Run
creation, authentication, authorization or global Run-ID uniqueness.

## Interface

`Elzoo.Conversation.prepare(snapshot, request, facts)` accepts exact plain
atom-keyed outer DTO maps:

- Snapshot: `%{tenant: tenant, resource: resource, revision: revision, fields: fields}`.
- Request: `%{operation_id: id, resource: resource, expected_revision: revision, payload: payload}`.
- Facts: `%{tenant: tenant, actor: actor, data: portable_record}`.

IDs are 1–128 valid UTF-8 bytes with no NUL. `expected_revision` is in
`0..2^63-2`; snapshot `revision` is in `0..2^63-1`. The resource and tenant
in the snapshot must match the request and trusted facts. Request payload is
the original JSON-shaped plain map, with exact string keys:

| Mode in trusted `facts.data` | Payload | Effect |
| --- | --- | --- |
| `append_input` | `message_id`, `text` | Append a `user` or `source` input selected by facts. |
| `associate_run` | `message_id` | Associate that existing input with the trusted Run ID. |
| `append_answer` | `message_id`, `text` | Append one answer for the trusted input/Run pair when completed. |

Message text is valid UTF-8, 1–4,096 bytes; NUL is allowed and bytes are
preserved without Unicode normalization or rendering. The actor for both
inputs and answers is the trusted `facts.actor` value.

`facts.data` is an exact Authorization portable record with these per-mode
keys and no others. Mode, role and IDs use `{:text, binary}`; completion is a
bare boolean:

- `append_input`: `mode`, `input_role` (`user` or `source`)
- `associate_run`: `mode`, `run_id`
- `append_answer`: `mode`, `run_id`, `input_message_id`, `completed`

`prepare/3` returns `{:ok, [write], response}` or `{:refused, code}`. The
single write is exactly `%{target: request.resource, field: "conversation",
value: portable_state}`. Responses are normalized portable records:

- Input: `message_id`, `revision`
- Association: `message_id` (the input ID), `revision`, `run_id`
- Answer: `input_message_id`, `message_id` (the answer ID), `revision`, `run_id`

IDs are tagged text and revisions are bare integers. Record fields are
byte-sorted by the Authorization validator.

## Version-1 state

The resource has no arbitrary application fields. A new resource is exactly
revision zero with `fields: %{}`. Every positive revision has exactly one
field, `"conversation"`, holding this normalized portable value:

```elixir
{:record,
 [
   {"associations", {:list, association_records}},
   {"messages", {:list, message_records}},
   {"version", 1}
 ]}
```

All record pair lists are exact and byte-sorted; duplicate, missing, unknown,
or noncanonical fields are malformed. A stored state must have at least one
message. Input records have exactly these keys:

```elixir
{:record,
 [
   {"actor", {:text, actor}},
   {"message_id", {:text, id}},
   {"role", {:text, "user" | "source"}},
   {"text", {:text, text}}
 ]}
```

Assistant answer records have exactly these keys:

```elixir
{:record,
 [
   {"actor", {:text, actor}},
   {"input_message_id", {:text, input_id}},
   {"message_id", {:text, answer_id}},
   {"role", {:text, "assistant"}},
   {"run_id", {:text, run_id}},
   {"text", {:text, text}}
 ]}
```

Association records have exactly `input_message_id` and `run_id`, both tagged
text, in byte-sorted order:

```elixir
{:record,
 [{"input_message_id", {:text, input_id}}, {"run_id", {:text, run_id}}]}
```

Messages append in conversation order. IDs are unique across all roles. Each
input has at most one immutable association; several inputs may share a Run.
Every association references an existing input. An answer references an
earlier input and its exact association, and there is at most one answer per
input. Corrupt state is rejected, never repaired or treated as empty.

There are at most 64 messages and 64 associations. The encoded-state bound is
`byte_size(:erlang.term_to_binary(normalized_portable_state)) <= 65_536`, using
the pinned OTP 29.1.2 default external-term encoding. The existing
Authorization limits also apply: depth 16, at most 4,096 portable nodes, and
at most 4,096 bytes per text or record field name. No eviction or truncation
occurs. Oversized stored state is `:invalid_snapshot`; an over-capacity
proposal is refused with `"capacity"`.

The 64-message and 64-association caps are separate structural limits; the
65,536-byte encoded-state cap and Authorization depth, node and per-value
limits apply independently. Many 4,096-byte message texts can exhaust the
encoded-state cap before 64 messages. A completed answer adds a message and
can be refused for capacity even when its completion and association checks
pass. Because each association belongs to a distinct input and a valid state
has at most 64 messages, more than 64 associations cannot occur in valid
state; an over-bound stored list is rejected, not truncated.

## Projection and refusal order

`view(snapshot, scope)` requires the exact plain map
`%{tenant: tenant, actor: actor, resources: readable_resource_ids}`. The
resource list is proper, contains at most 64 bounded IDs, and grants the
conversation resource. Scope is checked before fields: a tenant/grant
mismatch returns `:not_found`; malformed scope returns
`{:error, :invalid_scope}`; malformed authorized state returns
`{:error, :invalid_snapshot}`. On success, messages and associations are
ordered lists of plain atom-keyed maps with the same field names as their
stored records and raw binary text. The top-level view is exactly:

```elixir
%{tenant: tenant, resource: resource, revision: revision,
  messages: messages, associations: associations}
```

Prepare refusal precedence is facts, safe tenant/resource scope, request
representation and bounds, complete snapshot, expected revision, mode
policy, then prospective capacity. Fixed mode-policy order is:

- `append_input`: `duplicate_message_id`
- `associate_run`: `missing_input`, then `already_associated`
- `append_answer`: `duplicate_message_id`, `run_not_completed`, `missing_input`,
  `association_mismatch`, then `already_answered`

Other fixed refusal codes are `invalid_facts`, `invalid_scope`,
`invalid_request`, `invalid_snapshot`, `stale_revision`, and `capacity`. Codes
are lowercase ASCII strings and never echo supplied content. A structurally
valid `completed: false` is a mode refusal after revision validation.

## Example and limits

`examples/conversation.exs` demonstrates using the public DTOs directly and
reconstructing successive snapshots from the proposed field write. It is not
a database or CheckedCommand integration test. The caller still owns CAS,
authority, receipts, approval and atomic persistence. An association is a
host-allocated stable Run identity, not proof that a process started or
completed. This Piece makes no authentication, authorization, persistence,
delivery or production-safety claim.

The mandatory ELZ-252 follow-on acceptance must pass actual
Memory/PostgreSQL CheckedCommand composition and RunEngine parity before a
durable Conversation or Wave4 completion claim. This pure Piece and its tests
do not establish that integration acceptance.
