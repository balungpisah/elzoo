# workflow/wait-for-person

A Run asks a named person one question and continues with the answer or the
time-out. `Elzoo.WaitForPerson` has two pure functions over values the caller
supplies: no process, clock, timer, deadline, storage or callback, and no new
input, action or outcome word. Ready `workflow/pattern-step` owns the shapes
and the first settlement of an action; its `decode/1` and `accept/2` are used
unchanged.

This is not an approval. An approval binds one exact action; an ask uses none
of its state. Only the way to bind a person is shared: the verified identity
is a host Need, compared with the named identity by exact equality.

## `step(state, checked_input, verified_person)`

State is the exact atom-keyed map `%{asks: asks, tracker: tracker}` for one
request. `asks` maps the ID of each open `ask_person` action to the ID of the
person it names (0..64 entries); the caller adds an entry when the ask opens,
from trusted host data, not from the action payload. `tracker` is the
authentic `PatternStep.open/1` tracker of that request as the caller holds it.
`checked_input` is a `PatternStep.decode/1` value. `verified_person` is the
host-verified sender of this input, or `nil`; it never comes from message
text or a payload.

It returns `{:ok, new_state, decision}` or `{:error, :invalid_shape}` with no
operand echoed. Rules, in order:

1. An `action_outcome` for an action not in `asks`, and any input that is
   neither an `action_outcome` nor a `person_answer`: `:pass`, state unchanged.
2. Otherwise `PatternStep.accept/2` decides settlement: late gives `:late`,
   refused gives `{:refused, :incompatible_answer_kind}`; state unchanged.
3. An applied `action_outcome`: `{:closed, action_id, outcome}`; the entry
   leaves `asks` and the new tracker is kept. Outcome `"expired"` is the
   time-out; there is no other.
4. An applied `person_answer` is `{:answer, action_id}` only when the action is
   in `asks` and the named person, the input's `person_id` and
   `verified_person` are byte-equal; the entry leaves `asks` and the new
   tracker is kept. Otherwise `{:refused, :wrong_person}`: the applied tracker
   is discarded, the ask stays open, and a later answer of the named person
   still stands.

A caller that also uses `workflow/bot-run-lifecycle` gives it a `person_answer`
only after this policy returned `{:answer, _}`, with the tracker from before
this step. When `workflow/bot-run-lifecycle` accepts that wait, both steps
return equal trackers; on its terminal, deadline-expired and closed-wait
paths it returns its tracker unchanged.

## `route(asks, verified_person)`

Which input the host records for text from a verified person. Exactly one open
ask names the person: `{:answer, action_id}` (record a `person_answer`). None:
`:message` (record a `message`). Several: `{:refused, :ambiguous_ask}`; this
Piece does not choose. `asks` may be the union of the `asks` maps of the Run.
An `asks` that is not a map of nonempty UTF-8 texts (any size), or a
`verified_person` that is not nonempty UTF-8 text (`nil` included), is
`{:error, :invalid_shape}`.

## Grounding

- Proof: the Cure law `mismatch_never_answer` checks the production decision:
  for both values of "the ID is in `asks`" and each tracker class (applied,
  late, refused), an answer whose three person texts are not all equal is never
  the answer decision. It does not cover map validation, text comparison,
  lookup or the ready tracker.
- Type: pinned Cure checks the decision; the source audit reports no axiom,
  hole or unproved-total definition.
- Test: `mix test pieces/workflow/wait-for-person/test` runs the named groups
  `answer_after_timeout_is_late`, `other_person_refused`,
  `first_answer_stands`, `answer_names_its_ask` and
  `text_without_open_ask_is_message` over a fixed v1 trace, redacted invalid
  operands, the law/audit and the checked example
  `examples/wait_for_person.exs`. These are finite scenarios.

## Needs and limits

Needs: authentication of the person and a truthful `verified_person`; the
named person of each ask; each input recorded before the policy reads it;
inputs of the current Attempt only (`workflow/run` owns currentness); the
`expired` outcome recorded for an ask past its deadline before any input read
at or after that deadline (the engine owns the deadline and durable timer);
serialization and preservation of the state and tracker.

This Piece does not authenticate, record, start, cancel or stop anything, does
no deadline arithmetic and uses no timer (`delivery/time` is not used). Phase,
open waits, pause and continue belong to `workflow/bot-run-lifecycle`. A text
never settles an ask by itself. Telemetry, Config and Control are not
applicable: it is a pure callable with no selectable behavior.

Modules are application-owned under `Elzoo.WaitForPerson` and
`Cure.Elzoo.WaitForPerson`. Apache-2.0; direct dependency
`workflow/pattern-step`; no new dependency or pin.
