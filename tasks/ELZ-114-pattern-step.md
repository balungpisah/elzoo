# ELZ-114 — Shared pattern-step protocol

- Dependencies: ELZ-033, ELZ-002, ELZ-006, ELZ-023

## Responsibility and scope

Admit RC-68 as `workflow/pattern-step`, the data and pure validation shared by the bot-platform engine (RC-50) and its patterns. The step is the unchanged `core/operator` shape: state and one input produce new state and zero or one request. A request contains actions, not another runtime. This task owns only `pieces/workflow/pattern-step/**` and its own index rows/generated files under AGENTS.md section 3. No edits to ready Pieces, shared runtime code, dependencies, `mix.exs`, the root tests or CI.

The task body is the scope. Implement only the acceptance scenarios below. Reuse existing upstream and repository facilities. Add no extra options, layers, behaviours, generic helpers or future hooks. Keep tests to these scenarios. Ask the coordinator before building anything outside this scope. The coordinator challenges disproportionate diffs before review; the independent reviewer treats needless abstractions and unrequested features as findings to remove.

## Owner decisions: closed version-1 sets

- Actions: model call (`model_call`), tool call (`tool_call`), local work (`local_work`), ask a person (`ask_person`), run a nested callable (`nested_callable`), open a run resource (`resource_open`), use a run resource (`resource_use`), close a run resource (`resource_close`), finish (`finish`). Resource open/use/close are three kinds because the engine checks and performs them differently.
- Inputs: start (`start`), action outcome (`action_outcome`), a person's answer (`person_answer`), a new message (`message`), a run-resource event (`resource_event`), cancel of one Attempt (`cancel`), Run ended (`run_ended`), wake (`wake`). Every input has engine-read time. Wake has no content and never passes through RC-58's queue/reject/interrupt/steer policy; the host's durable timer supplies it.
- Action outcome classes: completed (`completed`), failed (`failed`), refused (`refused`), late (`late`), unknown (`unknown`), out of budget (`out_of_budget`), tries used up (`retries_exhausted`), too old (`expired`), resource lost (`resource_lost`). These are action outcomes, not the Run outcome set owned by RC-12.
- New versions of all three sets only add members, never change or remove them. Records of older versions remain readable. Implement v1 only; reject unknown versions and kinds. Keep a v1 round-trip fixture for future compatibility, not a speculative version registry.
- Excluded from v1: start a child Run, wait for an outside event, a part of an answer to a channel, a message to another member, make or remove a binding, give an inside event, give a run resource to a person. Each enters in a later version with the wave that performs it. Ask for an approval and fill a secret are never action kinds; the engine does them.
- A person's answer names exactly one ask-person action and carries the verified person's identity. That action gets no other completed outcome. Text without an open ask is a new message. Verification of the person and the choice between answer and message belong to the host/RC-58, not this shape validator.

## Admitted interface and invariants

Use one public module, `Elzoo.PatternStep`, with `decode/1`, `encode/1`, `open/1` and `accept/2`. Follow `Elzoo.Port`'s map/checked-value boundary: `decode(map)` returns `{:ok, checked_value}` or a fixed redacted error; `encode(checked_value)` returns the original map. The checked representation is opaque to callers and documented for source-copy ownership. Encoding is representation translation, not a new serialization format or payload-schema validator.

The exact neutral maps use string keys and v1 snake-case names above:

- A request has `type: "request"`, `version: 1`, and `actions`, an ordered list of 1 through 64 actions. Zero actions is represented by no request in the operator's output. The fixed v1 bound is 64; add no configurability.
- Each action has exactly `id`, `kind`, `schema_id`, `schema_version`, `payload`. IDs and schema IDs are nonempty UTF-8 strings compared exactly; schema versions are positive integers, as in `core/port`. Payload is opaque caller-owned data; this Piece neither interprets nor validates its application schema. Action IDs must be unique within the request. RC-50 owns uniqueness across the Run's recorded history.
- Every input has `type: "input"`, `version: 1`, `kind`, `at_ms`. Time is a nonnegative integer of Unix milliseconds, supplied by the engine when recording; this Piece reads no clock and checks no clock ordering.
- `start`, `message`, `resource_event`, and `run_ended` also have `schema_id`, `schema_version`, `payload`. Resource identity and the opaque Run outcome travel in the typed payload; this Piece adds no resource or Run lifecycle policy.
- `action_outcome` also has `action_id`, `outcome`, `schema_id`, `schema_version`, `payload`.
- `person_answer` also has `action_id`, `person_id`, `schema_id`, `schema_version`, `payload`. The person ID is nonempty UTF-8 text supplied by the trusted host; presence does not prove authentication.
- `cancel` also has exactly one `attempt_id`, nonempty UTF-8 text. It does not cancel a Run implicitly. `wake` has no further fields. Unknown fields or malformed shapes are refused without echoing values.

`open(checked_request)` returns an immutable tracker for only that request, owned and persisted by the caller if needed. `accept(tracker, checked_input)` returns `{:applied, new_tracker}` for the first admissible outcome of a known action, `{:late, unchanged_tracker}` for an unknown or already-settled action or an explicitly late outcome, and `{:refused, fixed_reason, unchanged_tracker}` for a non-outcome input or incompatible answer kind. A person answer can settle only an ask-person action; an ordinary `completed` action outcome cannot settle an ask-person action. Non-completed outcomes can settle an open ask. Accepting an answer and accepting an outcome share the same settlement bit. This is pure correlation bookkeeping, not a Run log, dispatcher, callback executor, or concurrent service. No automatic retries or effects occur for any outcome, including unknown.

## Reuse, Needs and limits

- `pieces/core/operator/cure/elzoo/composition.cure` owns zero-or-one output; do not wrap or modify it. The request is its one output.
- `pieces/core/port/lib/elzoo/port.ex` and its README define exact schema identity/version declarations, not payload validation. Reuse its validation where it fits; do not introduce a second schema framework or add an artificial port connection.
- Record a short outcome terminology table in the README: `delivery/retry-timeout` has the `:exhausted` decision and `retries_exhausted` dead-letter reason; its expiry admission is `:expired`. `delivery/effect-intent` distinguishes dispatched/unknown outcomes and forbids automatic resend. Explain correspondence without claiming that these different Contracts are interchangeable. The new action-specific outcomes have no invented upstream equivalent.
- Cure owns the small pure correlation decision where it fits; Elixir owns foreign-map validation and representation translation. No new dependency or provider pin. Use existing source-copy and Cure audit facilities rather than a new harness.
- Needs: truthful schema declarations; host-recorded time and verified principal; caller serialization and preservation of tracker state; host Run-wide identity uniqueness, secret exclusion and payload validation. This validator does not authenticate, authorize, record inputs, schedule timers, retain state, or enforce a budget. Telemetry, Config and Control are not applicable to this pure callable; document why.

## Acceptance and evidence

1. Construct/decode/encode every admitted action, input and outcome class. Round-trip a fixed v1 fixture with unequal IDs, timestamps and payloads. Unknown kinds, version 0 or 2, extra fields, invalid identity/schema/time shapes are refused with no payload values in errors. Future versions must keep this v1 fixture readable.
2. Requests of 1 and 64 actions pass; 0 and 65 fail. Two different actions with the same ID fail, including separated duplicates. Preserve action order on round-trip.
3. An unknown action outcome is late and changes no tracker state. Apply a known action once; its second outcome is late. Apply different actions independently. An explicitly late outcome does not consume an open action. No input invokes effects or callbacks.
4. A valid person answer settles its ask exactly once. A second answer or a later outcome is late. A generic completed outcome for an open ask is refused; a person answer for another action kind is refused. A failed/expired ask makes a later answer late. Verified identity is carried unchanged, not inferred from text. A wake rejects payload/content and never goes through message handling.
5. Check the selected Cure law that the production correlation decision never applies a settled action again, with a temporary negative mutation that admits a repeat and fails the named check. State the actual law scope; map validation, identity lookup and caller persistence remain test/assumption grounding, not a universal durability proof. Ask the coordinator if the pinned compiler prevents this selected law rather than weakening the claim silently.
6. One small checked example demonstrates a request with two actions, the first settlement and a duplicate. Existing repository checks cover source ownership/export inventory. No new root consumer or unrelated scenario suite.

Run the Piece tests while building, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before opening or pushing the PR. Record commands, exit codes, selected laws, scenarios and limits separately. If a local command is impossible, put the command and reason in `Local gate:`; hosted CI is its evidence. Native PostgreSQL, if needed by selected consumers, uses a private disposable database and credentials for this worker, never shared test state.

One independent review checks the task body and exact diff, including needless abstraction/features. The coordinator owns the merge queue and the six first-Piece-only observations required by #219; do not mark those observations as passed from local tests. Other admitted level-1 Pieces may build in parallel in separate orbs, but no other small-gate merge may occur until that proof run is accepted.
