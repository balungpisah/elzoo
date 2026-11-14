# ELZ-172 — The run engine gives the result of a nested callable to its parent

## Scope and reuse

- Dependencies: ELZ-033, ELZ-114, ELZ-127
- Output: none. This task changes the ready Piece `assembly/run-engine` in place; the Piece ID stays.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/assembly/run-engine/**` and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row, and the generated files).

Owner decision, 2026-11-14: Elzoo is not released yet, so a Piece that lacks
something which clearly belongs to it is extended in place, with the same
Piece ID. The new-ID rule of AGENTS.md section 4 protects consumers after a
release; before the first release it would only give two engines. This task
therefore changes one behaviour of `assembly/run-engine` and its Contract
text. Reviewers do not flag the unchanged ID.

Why: a pattern that asks for a `nested_callable` action needs the result of
that callable. A graph node that calls a typed decision needs the choice; an
agent that calls a nested tool needs the tool result. Today the parent gets
only the fact that the child completed.

Facts checked on main (`lib/elzoo/run_engine.ex`, README, the test helper):

- When a nested callable gives a `finish` action, the engine closes the
  child and never reads the payload of that finish.
- When every slot of the child is settled and its Budget holds no
  reservation, the parent gets the outcome of its `nested_callable` action
  with the class `completed`, the schema `elzoo.run-engine.refusal` version 1
  and the payload `{"reason": "nested_completed", "gate_id", "gate_version",
  "request", "index"}`.
- Each binding declares `result: {schema_id, version}`. For a
  `nested_callable` binding nothing is checked against it today.
- The payload of every action, a `finish` included, is checked before
  admission against the payload bounds (65,536 bytes of JSON, 32 levels). A
  larger finish is refused to the child as `payload_schema`, as any other
  action, and does not close the child.
- `workflow/agent-loop` and the published task ELZ-168 state this limit of
  the ready engine in their Limits.

Implement only what is below. Change nothing else of the engine: not the
finish rule of the root callable, not the inputs that a pattern gets, not the
charge count, the Budget share, the limits or the records of other actions.
Add no option, no hook and no new action kind. Edit no other Piece, shared
path, pin or CI file. No fixtures directory is needed.

## The change

1. **The child's finish is kept.** When a nested callable gives a `finish`
   action that the engine admits, the engine keeps `schema_id`,
   `schema_version` and `payload` of that finish in the durable record of
   the child, in the same committed result that closes the child. Only the
   first admitted finish of a child counts.
2. **The parent gets it.** When the child is complete (the existing
   condition: every slot settled, no reservation), the outcome of the
   parent's `nested_callable` action is:
   - class `completed`, with `schema_id`, `schema_version` and `payload` of
     the child's finish, when that schema equals the `result` of the
     `nested_callable` binding of the parent's action;
   - class `failed` with the engine's refusal schema and the reason
     `nested_result_invalid`, when the schema differs from the declared
     `result`.
   An admitted finish is always within the outcome bounds, because the
   admission check above has the same bounds: no new size rule is needed.
   The `actual` cost of the outcome stays the committed amount of the child
   Budget, as today.
3. **A child that ends with no finish.** A child whose slots are all settled
   and that gave no admitted `finish` keeps today's outcome for the parent:
   class `completed`, the refusal schema and the reason `nested_completed`.
   This is the only case that still gives `nested_completed`.
4. **Replay.** The kept finish is part of the durable state. After a
   restart between the child's finish and the parent's outcome, the parent
   gets the same outcome, and the child is not stepped again.
5. **Evidence and audit.** The record of the parent outcome is an ordinary
   outcome record. The payload of the child's finish is content of the
   recipe: `status/1` does not expose it, as it exposes no other payload.

The engine does not validate the payload against a JSON schema beyond what
it does for every outcome today, and it does not interpret the payload: a
child that reports its own failure does so in its payload, and the parent
pattern reads it.

## Contract text

Update `README.md` and `piece.json` (`contract`, `limits`, `grounding`) so
that they state the new behaviour and the three cases of point 2 and 3.
Name the new test
groups in `grounding`. The `note` of the Piece row in
`docs/plans/release-plan.json` equals `contract` in `piece.json`, and
`manifest_sha256` is computed again, in the one last commit of the index
files.

## Named acceptance groups

Add these to the existing suite, on the ready PostgreSQL fixture of the
Piece, with the scripted test pattern and the clock of the helper. Each
existing group stays green without a change of its assertions, with two
exceptions, each named in the pull request body: an assertion that fixes
the old parent outcome of a finished child changes to the new outcome; and
a test or example of this Piece whose child finishes with a schema other
than the declared `result` of its `nested_callable` binding (the document
publication flow does) gets a binding or a finish that agree, so that the
flow still completes.

1. **`nested_result_reaches_parent`**: a child finishes with the declared
   result schema and a payload; the parent pattern receives one
   `action_outcome` for its action with class `completed`, that schema and
   exactly that payload; the `actual` cost equals the committed amount of
   the child Budget.
2. **`nested_result_wrong_schema`**: a child finishes with another schema
   ID, and with another version: the parent gets `failed` with the reason
   `nested_result_invalid`; no payload of the child appears in it.
3. **`nested_without_finish`**: a child whose actions all settle and that
   gives no finish: the parent gets `completed` with `nested_completed`, as
   before.
4. **`nested_result_bounds`**: a finish payload at the payload bound
   reaches the parent whole; a finish with one byte more is refused to the
   child as today, the child stays open, and the parent gets no outcome
   from it.
5. **`nested_result_survives_restart`**: stop the engine after the child's
   finish is committed and before the parent's outcome is applied; after
   the restart the parent gets the same outcome once, the child pattern is
   not called again (a counting pattern shows it), and no action is
   dispatched twice.
6. **`first_finish_only`**: a child that gives a second `finish` after its
   first: the parent outcome holds the first payload.
7. **`two_levels`**: a child of a child finishes; its parent (the middle
   callable) receives the payload, uses it in its own finish, and the root
   receives that; the shared charge count and each Budget share are as
   before.
8. **`payload_not_exposed`**: a sentinel text in a child's finish payload
   appears in the parent's input and nowhere in `status/1`, in a log or in
   a telemetry event.

## Evidence and gate

Test: the eight groups and the unchanged suite. Upstream: none new. Record
in `Limits:` of the pull request body what this task does not change (the
root finish rule, inputs while an action is open, no depth limit). Negative
controls: temporarily give the parent the old `nested_completed` outcome for
a finished child (group 1 must fail), then temporarily skip the schema
comparison (group 2 must fail). Restore both before the final gate.

Run `. .elzoo-services/env.sh`, `mix test pieces/assembly/run-engine/test`,
then `mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The small gate also runs each ready Piece that depends
on this one. One independent review checks the body and the exact diff,
including extra features.

## Not in scope

A finish of the root callable that reports a failure; `cancel`, `message`
or `late` inputs while an action is open; a nesting depth limit; the limits
of open and lifetime actions; `workflow/agent-loop`, `workflow/graph-run`
and their READMEs (their Limits lines are corrected in their own small
tasks after this merges; the text of a published task file such as ELZ-168
is a record of its time and is not edited); any other Piece.
