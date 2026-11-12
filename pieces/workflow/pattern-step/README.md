# workflow/pattern-step

Shared v1 data and pure validation for a pattern and its engine. One public
Elixir module, `Elzoo.PatternStep`, supplies `decode/1`, `encode/1`, `open/1`
and `accept/2`. The unchanged `core/operator` transition remains state + one
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

| Input kind | Additional fields |
| --- | --- |
| `start`, `message`, `resource_event`, `run_ended` | `schema_id`, `schema_version`, `payload` |
| `action_outcome` | `action_id`, `outcome`, `schema_id`, `schema_version`, `payload` |
| `person_answer` | `action_id`, `person_id`, `schema_id`, `schema_version`, `payload` |
| `cancel` | `attempt_id` (one Attempt, never implicit Run cancellation) |
| `wake` | None: no payload or content; the host's durable timer supplies it |

Action kinds: `model_call`, `tool_call`, `local_work`, `ask_person`,
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
or executed. All three kind sets are closed in v1. Later versions may only
add members, not change or remove them; this implementation rejects versions
other than 1. The fixed unequal `@v1_fixture` in the test is retained for
future compatibility checks.

## Request settlement

`open(checked_request)` returns an immutable request tracker.
`accept(tracker, checked_input)` returns:

- `{:applied, new_tracker}` for a known, open, compatible outcome;
- `{:late, unchanged_tracker}` for an unknown or settled action, or an
  explicitly `late` outcome (which never consumes the open action);
- `{:refused, :not_an_outcome, unchanged_tracker}` for other input kinds;
- `{:refused, :incompatible_answer_kind, unchanged_tracker}` for a person
  answer to a non-ask or a generic `completed` outcome for an open ask.

A person answer settles exactly one ask-person action, sharing the settlement
bit with ordinary outcomes. Other non-late, non-completed outcomes can settle
an ask; a later answer is late. The host supplies verified person identity;
presence of `person_id` does not authenticate it. Text without an open ask is
a `message`; the host/RC-58 makes that choice. Wake is not message handling
and never passes through queue/reject/interrupt/steer policy here.
No input causes effects, callbacks, retries or scheduling, including `unknown`.

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
`PatternApplied()`. It does not prove Elixir map validation, identity lookup,
caller persistence, authentication or durability. The production source audit checks no axioms, holes, unresolved,
unaudited, opaque or unproved-total definitions and zero absurd. A temporary
mutation admitting a settled action is checked separately and never shipped.
The pinned Cure compiler checks types; compiler soundness is upstream grounding.

`mix test pieces/workflow/pattern-step/test` runs the named finite scenarios:
every v1 kind and fixed fixture, redacted malformed shapes, bounds/duplicates/
order, independent/late settlement without callbacks, person-answer settlement,
the selected law/audit, and the checked two-action example. These are tests,
not a universal durability proof. There is no monitored runtime claim.

Needs: truthful schema declarations, host-recorded time and verified principal,
caller serialization and preservation of tracker state, host Run-wide identity
uniqueness, secret exclusion and application payload validation. This callable
does not authenticate, authorize, record inputs, retain state, schedule timers
or enforce budget. Telemetry, Config and Control are not applicable: no
observations, ambient settings or independent lifecycle exist.

The checked value is the opaque `{:PatternStep, original_map}`; the tracker is
the opaque `{:PatternStepTracker, %{id => {kind, settled_boolean}}}`. Callers
use the four functions, preserve returned trackers, and do not forge or mix
representations. `encode/1`, `open/1` and `accept/2` expect checked operands,
not arbitrary BEAM terms. Copies are application-owned under `Elzoo.PatternStep`
and `Cure.Elzoo.PatternStep`, one coordinated revision per module. Library
redistributors must rename modules, references and both tuple tags explicitly.
See [consuming](../../../docs/consuming.md). Apache-2.0 source; direct dependency
`core/port`; provider Cure at the repository pin. No new dependency or runtime.
