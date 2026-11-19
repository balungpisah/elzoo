# workflow/pattern-step

Shared v1/v2 data and pure validation for a pattern and its engine. One public
Elixir module, `Elzoo.PatternStep`, supplies `decode/1`, `decode/2`, `encode/1`,
`open/1` and `accept/2`. The unchanged `core/operator` transition remains state + one
input → new state + zero or one output. A request is that one output, not a
runtime. Zero actions means no request.

## Neutral maps

All keys are strings. Every record has exactly the fields below; unknown
fields, kinds, versions and malformed shapes return `{:error, :invalid_shape}`
without echoing values. `decode(map)` returns `{:ok, checked_value}` on success;
`encode(checked_value)` returns the original map, including opaque payloads
and action order. It is representation translation, not serialization or
application payload-schema validation.

- Request: `type: "request"`, `version: 1`, `actions`: an ordered list of
  1..64 actions. The bound is fixed, not Config.
- Action: `id`, `kind`, `schema_id`, `schema_version`, `payload`. IDs must
  be unique within one request, including separated duplicates.
- Input: `type: "input"`, `version: 1`, `kind`, `at_ms`, plus the kind's
  fields in the table. `at_ms` is a nonnegative integer of Unix milliseconds
  supplied by the engine. No clock is read or ordering checked.

| V1 input kind | Additional fields |
| --- | --- |
| `start`, `message`, `resource_event`, `run_ended` | `schema_id`, `schema_version`, `payload` |
| `action_outcome` | `action_id`, `outcome`, `schema_id`, `schema_version`, `payload` |
| `person_answer` | `action_id`, `person_id`, `schema_id`, `schema_version`, `payload` |
| `cancel` | `attempt_id` (one Attempt, never implicit Run cancellation) |
| `wake` | None: no payload or content; the host's durable timer supplies it |

V1 action kinds: `model_call`, `tool_call`, `local_work`, `ask_person`,
`nested_callable`, `resource_open`, `resource_use`, `resource_close`, `finish`.
Outcome classes: `completed`, `failed`, `refused`, `late`, `unknown`,
`out_of_budget`, `retries_exhausted`, `expired`, `resource_lost`.
These action outcomes are not the Run outcome set. Run outcomes and resource
identities travel in opaque typed payloads. Approval and secret entry are
engine responsibilities, never action kinds. Child Runs, outside-event waits,
answer parts, member messages, bindings, inside events and resource handoff
are not v1 actions.

IDs (including person and Attempt IDs) and schema IDs are nonempty UTF-8
strings compared exactly, without normalization. Schema versions are positive
integers. Schema declaration validation reuses `core/port`'s `decode/1`
(using the schema ID as the declaration ID); no connection is created or
compatibility inferred. Payload is arbitrary caller-owned data, not inspected
or executed. The v1 action, input and outcome sets are closed. V2 preserves all
v1 action and input kinds, adds only `wait_event` and `outside_event`, and keeps
the outcome classes unchanged. `decode/1` remains strict v1; `decode(map, 1)`
selects the same v1 contract. `decode(map, 2)` requires a matching version-2 map;
other selectors and version mismatches return `{:error, :invalid_shape}`. The
fixed unequal `@v1_fixture` in the test remains unchanged.

## V2 maps

A v2 request uses the same exact request and action fields as v1, with
`"version" => 2`. Its action list remains bounded to 1..64 unique IDs. The
only added action kind is `wait_event`; its map still has exactly `id`,
`kind`, `schema_id`, `schema_version` and opaque `payload`.

V2 retains every v1 input kind and adds `outside_event`. It is an input with
`"type" => "input"`, `"version" => 2` and `"kind" => "outside_event"`, and has
exactly these eleven string keys: `type`, `version`, `kind`, `at_ms`, `action_id`,
`source_id`, `correlation_id`, `event_id`, `schema_id`, `schema_version` and
`payload`. The four action/source/correlation/event IDs use the existing
nonempty valid-UTF-8 rule; schema IDs and positive schema versions use the
existing `core/port` declaration check. `at_ms` is a nonnegative integer
supplied by the caller. Payload remains opaque; the Piece does not corroborate
an event source, invoke callbacks or inspect application payload schemas.

V1 checked values and trackers keep `{:PatternStep, map}` and
`{:PatternStepTracker, %{id => {kind, settled_boolean}}}`. V2 uses the distinct
tags `{:PatternStepV2, map}` and `{:PatternStepTrackerV2, %{id => {kind,
settled_boolean}}}`. Mixing a v1 tracker with a checked v2 input, or vice versa, returns exactly
`{:refused, :incompatible_version, original_tracker}`. Each tracker remains a
simple per-request action-ID map; no persistence or Run-wide identity registry
is added.

## Request settlement

`open(checked_request)` returns an immutable request tracker.
`accept(tracker, checked_input)` returns:

- `{:applied, new_tracker}` for a known, open, compatible outcome;
- `{:late, unchanged_tracker}` for an unknown or settled action, or an
  explicitly `late` outcome (which never consumes the open action);
- `{:refused, :not_an_outcome, unchanged_tracker}` for other input kinds;
- `{:refused, :incompatible_answer_kind, unchanged_tracker}` for a person
  answer to a non-ask, a v2 outside event to a non-wait, or a generic
  `completed` outcome for an open ask (v1/v2) or wait (v2).
- `{:refused, :incompatible_version, original_tracker}` for a mixed v1/v2
  tracker and checked input.

In both versions, a person answer settles exactly one `ask_person` action,
sharing its settlement bit with ordinary outcomes; other non-late,
non-completed action outcomes can also settle an ask. In v2, an
`outside_event` settles only an open `wait_event`; a generic `completed`
action outcome cannot settle a wait, while any non-late, non-completed outcome
can. A `late` outcome never consumes a wait. The first settlement wins per
action, and separate waits settle independently. The host supplies verified
person identity; presence of `person_id` does not authenticate it. Text without
an open ask is a `message`; the host/RC-58 makes that choice. Wake is not
message handling and never passes through queue/reject/interrupt/steer policy
here. No input causes effects, callbacks, retries or scheduling, including
`unknown`.

| Related terminology | Correspondence and limit |
| --- | --- |
| `delivery/retry-timeout` `:exhausted` decision / `retries_exhausted` dead-letter reason | Related to the action class `retries_exhausted`, not an interchangeable result shape |
| `delivery/retry-timeout` `:expired` admission | Related to action `expired`; this Piece enforces no deadline |
| `delivery/effect-intent` dispatched / unknown outcomes | Possible-effect uncertainty forbids automatic resend there; action `unknown` grants no retry authority here |
| Other action-specific classes | No invented upstream equivalent |

## Grounding, ownership and Needs

The selected Cure law `settled_never_applied` checks the actual production
correlation decision for all Boolean known/late/compatible operands when
settled is true: the decision is `PatternLate()` (translated to `:late`), never
`PatternApplied()`. V1 and v2 reuse that production decision; no proof scope is
added. It does not prove Elixir map validation, identity lookup, caller
persistence, authentication or durability. The production source audit checks no axioms, holes, unresolved,
unaudited, opaque or unproved-total definitions and zero absurd. A temporary
mutation admitting a settled action is checked separately and never shipped.
The pinned Cure compiler checks types; compiler soundness is upstream grounding.

`mix test pieces/workflow/pattern-step/test` runs the named finite scenarios:
every v1 kind and fixed fixture, v2 selector/version and kind coverage, exact
wait/event schemas and bounds, IDs and schema checks, mixed-version refusal,
independent/duplicate/late settlement, outcome compatibility, opaque payloads
without callbacks, redacted malformed shapes, the selected law/audit, and the
checked two-action example. The v2 first-settlement assertion also has a
separate temporary second-settlement negative control. These are tests, not a
universal durability proof. There is no monitored runtime claim.

Needs: truthful schema declarations, host-recorded time and verified principal,
caller serialization and preservation of tracker state, host Run-wide identity
uniqueness, secret exclusion and application payload validation. This callable
does not authenticate, authorize, record inputs, retain state, schedule timers
or enforce budget. Telemetry, Config and Control are not applicable: no
observations, ambient settings or independent lifecycle exist.

The v1 checked value is the opaque `{:PatternStep, original_map}` and its
tracker is the opaque `{:PatternStepTracker, %{id => {kind, settled_boolean}}}`;
v2 uses the distinct tags described above. Callers use the functions, preserve
returned trackers, and do not forge or mix representations. `encode/1`,
`open/1` and `accept/2` expect checked operands, not arbitrary BEAM terms.
Copies are application-owned under `Elzoo.PatternStep` and
`Cure.Elzoo.PatternStep`, one coordinated revision per module. Library
redistributors must rename modules, references and all four tuple tags
explicitly.
See [consuming](../../../docs/consuming.md). Apache-2.0 source; direct dependency
`core/port`; provider Cure at the repository pin. No new dependency or runtime.
