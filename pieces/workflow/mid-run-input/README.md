# workflow/mid-run-input

A new message during a Run follows the one rule that the Run declares.
`Elzoo.MidRunInput` has two pure functions over values the caller supplies: no
process, clock, timer, storage or callback, and no new input, action or
outcome word. Ready `workflow/pattern-step` owns the shapes; `decode/1` and
`encode/1` are used unchanged.

## `step(state, checked_input, run)`

State is the exact atom-keyed map `%{rule: rule, queue: queue}`. `rule` is
`:queue`, `:reject`, `:interrupt`, `:steer` or `:side_run` and never changes in
a Run. `queue` holds 0..16 neutral `message` maps, oldest first; the bound is
fixed, not Config, and only the rule `:queue` fills it.

`run` is the exact map `%{phase: phase, delivered: ids, open: ids}` that the
caller reads from its record. `phase` is the phase that
`workflow/bot-run-lifecycle` decided for the same input (`:active`,
`:waiting`, `:paused` or `:terminal`). `open` lists the open actions;
`delivered` lists the actions with an applied outcome since the Run last had no
open action. Both are lists of nonempty UTF-8 text and share no ID.

It returns `{:ok, new_state, decision}` or `{:error, :invalid_shape}`. An input
that is not a `message` gives `:pass` with the state unchanged under every rule
and phase: a `wake` is never queued, refused, reported or handed on. For a
`message`:

| `phase` | `:queue` | `:reject` | `:interrupt` | `:steer` | `:side_run` |
| --- | --- | --- | --- | --- | --- |
| `:active` | `{:deliver, message}` with an empty queue; else as the next row | `{:deliver, message}` | `{:deliver, message}` | `{:deliver, message}` | `{:deliver, message}` |
| `:waiting`, `:paused` | `:queued`, or `{:refused, :queue_full}` with 16 queued | `{:refused, :run_busy}` | `{:interrupt, message, report}` | `{:deliver, message}` | `{:side_run, message, report}` |
| `:terminal` | `{:refused, :run_ended}` | `{:refused, :run_ended}` | `{:refused, :run_ended}` | `{:refused, :run_ended}` | `{:refused, :run_ended}` |

`message` is the neutral map (`PatternStep.encode/1`). `report` is
`%{delivered: run.delivered, open: run.open}`. Only `:queued` changes the state.

- `{:deliver, message}`: the message is the next input of the pattern; open
  actions stay as they are (this is steer). When the pattern may run is the
  lifecycle's rule; a paused Run starts no new action.
- `{:interrupt, message, report}`: the same, with the report. "Delivered"
  means an applied outcome in the record. v1 has no action for part of an
  answer to a channel, so the report does not say what a person has seen, and
  it never says that an open action was not sent.
- `{:side_run, message, report}`: a different Run answers the message and gets
  the message and the report to read. The first Run gets nothing.

## `next(state)`

`{:ok, new_state, {:deliver, message}}` with the oldest queued message removed,
or `{:ok, state, :empty}`, or `{:error, :invalid_shape}` for a state that is not
in the form above. The caller calls it when the lifecycle permits new work.

## Grounding

- Proof: the Cure law `non_message_passes` checks the production decision
  table: for each rule, phase and queue fill (empty, holding, full), an input
  that is not a message passes. It does not cover map validation, the queue or
  the Run facts.
- Type: pinned Cure checks the table; the source audit reports no axiom, hole
  or unproved-total definition.
- Test: `mix test pieces/workflow/mid-run-input/test` runs the named groups
  `wake_bypasses_every_rule`, `five_rules_one_trace` and
  `side_run_leaves_first_run_unchanged` over a fixed v1 trace, redacted invalid
  operands, the law/audit and the checked example `examples/mid_run_input.exs`.
  These are finite scenarios.

## Config

The rule is a caller choice that controls how a message is handled: Config,
supported per call. It is set when the caller constructs the state for one Run,
passed with each call, and never changes during the Run; there is no hot
reconfiguration. The queue bound 16 is fixed. Telemetry and Control are not
applicable: no observations and no independently controlled runtime.

## Needs and limits

Needs: each input recorded before the policy reads it; inputs of the current
Attempt only; truthful `run` facts; serialization and preservation of the
state. For an interrupt, the caller stops or leaves the open actions under the
rules of `workflow/run` and `workflow/bot-run-lifecycle`. For a side run, the
host starts the other Run with its own identity and budget, authority not above
the first Run, and a copy of the state it may read.

This Piece does not record, start, cancel or stop anything. There is no
child-Run action in v1, and no input kind carries the report to a pattern.

Modules are application-owned under `Elzoo.MidRunInput` and
`Cure.Elzoo.MidRunInput`. Apache-2.0; direct dependency
`workflow/pattern-step`; no new dependency or pin.
