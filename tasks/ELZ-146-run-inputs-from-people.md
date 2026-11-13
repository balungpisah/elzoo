# ELZ-146 — Run inputs from people: wait for a person, and a new message during a Run

## Scope and reuse

- Dependencies: ELZ-033, ELZ-116, ELZ-124, ELZ-114
- Output: `workflow/wait-for-person` and `workflow/mid-run-input`; release V1B; bot-platform level 3.
- Owned paths: `pieces/workflow/wait-for-person/**`, `pieces/workflow/mid-run-input/**` and their index/generated changes under AGENTS.md section 3.

Two small pure policies over one Run, in the v1 input and action shapes of ready `workflow/pattern-step`. One task and one pull request; two Piece directories with no code dependency between them. In code each Piece depends on `workflow/pattern-step` only. Each policy is a callable over supplied values: no process, clock, timer, deadline, storage, callback or new input, action or outcome word.

Implement only the eight acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks. Change no ready Piece, shared path, `mix.exs`, `mix.lock` or CI file. The independent reviewer flags extra features for removal.

Boundaries that this task does not restate:

- `workflow/pattern-step` owns the shapes and the first settlement of an action. Use `decode/1`, `encode/1` and `accept/2` as they are. Write no second settlement rule.
- `workflow/bot-run-lifecycle` (ELZ-124) owns phase, open waits, pause and continue. Neither policy changes or defines them.
- `workflow/run` (ELZ-116) owns Attempt currentness. The caller gives both policies only inputs of the current execution Attempt.
- `workflow/approval` binds one exact action. An ask is not an approval and uses none of its state. Only its way to bind a person is the model: the verified identity is a host Need, compared with the named identity by exact equality (its check 14).

## `workflow/wait-for-person`: `Elzoo.WaitForPerson`

A Run asks a named person one question and continues with the answer or the time-out. Two public functions.

State is the exact atom-keyed map `%{asks: asks, tracker: tracker}` for one request:

- `asks`: map from the ID of each open `ask_person` action of the request to the ID of the person it names, 0..64 entries. The caller adds an entry when the ask opens. The host supplies the named person from trusted data; this Piece does not read the action payload.
- `tracker`: the authentic `PatternStep.open/1` tracker of that request, as the caller holds it now.

`step(state, checked_input, verified_person)` returns `{:ok, new_state, decision}` or `{:error, :invalid_shape}` with no operand echoed. `checked_input` is a `PatternStep.decode/1` value. `verified_person` is the host-verified identity of the sender of this input, or `nil` when the input has no sender. It never comes from message text or a payload. Rules, in this order:

1. An `action_outcome` whose `action_id` is not in `asks`, and each input that is neither an `action_outcome` nor a `person_answer`, gives `:pass`. The state is unchanged. Every `person_answer` goes to rule 2.
2. Otherwise call `PatternStep.accept(tracker, checked_input)`. A late result gives `:late`. A refused result gives `{:refused, :incompatible_answer_kind}`. The state is unchanged in both.
3. An applied `action_outcome` gives `{:closed, action_id, outcome}`. The entry leaves `asks` and the new tracker is kept. Outcome `"expired"` is the time-out; no other time-out exists here.
4. An applied `person_answer` is an answer only when its `action_id` is in `asks` and three texts are byte-equal: the named person, `person_id` of the input, and `verified_person`. Then the decision is `{:answer, action_id}`, the entry leaves `asks` and the new tracker is kept. Otherwise the decision is `{:refused, :wrong_person}`: the applied tracker is discarded, the ask stays open, and a later answer of the named person still stands.

`route(asks, verified_person)` makes the choice that ELZ-114 leaves to this job: which input the host records for text from a verified person. Exactly one open ask names the person: `{:answer, action_id}`, and the host records a `person_answer` for that action. No open ask names the person: `:message`, and the host records a `message`. Several do: `{:refused, :ambiguous_ask}`; this Piece does not choose. `asks` may be the union of the `asks` maps of the Run.

A caller that also uses ELZ-124 gives it a `person_answer` only after this policy returned `{:answer, _}`, with the tracker from before this step. Both steps then return equal trackers.

## `workflow/mid-run-input`: `Elzoo.MidRunInput`

A new message during a Run follows the one rule that the Run declares. Two public functions.

State is the exact atom-keyed map `%{rule: rule, queue: queue}`. `rule` is `:queue`, `:reject`, `:interrupt`, `:steer` or `:side_run` and never changes in a Run. `queue` holds 0..16 neutral `message` maps, oldest first. The bound 16 is fixed, not Config. Only the rule `:queue` fills it.

`step(state, checked_input, run)` returns `{:ok, new_state, decision}` or `{:error, :invalid_shape}`. `run` is the exact map `%{phase: phase, delivered: ids, open: ids}` that the caller reads from its record:

- `phase`: the `phase` of the ELZ-124 state after that Piece decided the same input: `:active`, `:waiting`, `:paused` or `:terminal`. This Piece uses the four values and defines none.
- `open`: IDs of the actions that are open. `delivered`: IDs of the actions with an applied outcome in the record since the Run last had no open action. Both are lists of nonempty UTF-8 text, and no ID is in both. They are not kept in the state.

An input whose kind is not `message` gives `:pass` and leaves the state unchanged, under every rule and phase. So a `wake` is never queued, refused, reported or handed on, and it releases nothing. For a `message`:

| `phase` | `:queue` | `:reject` | `:interrupt` | `:steer` | `:side_run` |
| --- | --- | --- | --- | --- | --- |
| `:active` | `{:deliver, message}` with an empty queue; else as the next row | `{:deliver, message}` | `{:deliver, message}` | `{:deliver, message}` | `{:deliver, message}` |
| `:waiting`, `:paused` | `:queued`, or `{:refused, :queue_full}` with 16 queued | `{:refused, :run_busy}` | `{:interrupt, message, report}` | `{:deliver, message}` | `{:side_run, message, report}` |
| `:terminal` | `{:refused, :run_ended}` | `{:refused, :run_ended}` | `{:refused, :run_ended}` | `{:refused, :run_ended}` | `{:refused, :run_ended}` |

`message` in a decision and in the queue is the neutral map (`PatternStep.encode/1`). `report` is `%{delivered: run.delivered, open: run.open}`. Only `:queued` changes the state.

- `{:deliver, message}`: the message is the next input of the pattern. Open actions stay as they are: this is what steer means. When the pattern may run is the rule of ELZ-124; a paused Run starts no new action.
- `{:interrupt, message, report}`: the same, with the report. "Already delivered" reads the record in pattern-step shapes: the actions that have an applied outcome. v1 has no action for a part of an answer to a channel, so the report does not say what a person has seen. An open action can already be sent: the report never says that it was not.
- `{:side_run, message, report}`: a different Run answers the message. It gets the message and the report to read. The first Run gets nothing: no input, no queued message, no state change.

`next(state)` returns `{:ok, new_state, {:deliver, message}}` with the oldest queued message removed, or `{:ok, state, :empty}`. The caller calls it when ELZ-124 permits new work.

## Host Needs and Limits

Needs: authentication of the person and the truthful `verified_person`; the named person of each ask; each input recorded before a policy reads it; inputs of the current Attempt only; the `expired` outcome recorded for an ask that is past its deadline, before any input that was read at or after that deadline (the engine owns the deadline and the durable timer); truthful `run` facts; serialization and preservation of both states and of the tracker. For an interrupt, the caller stops or leaves the open actions under the rules of ELZ-116 and ELZ-124. For a side run, the host starts the other Run with its own identity and budget, authority not above the first Run, and a copy of the state it may read.

Limits: neither policy authenticates, records, starts, cancels or stops anything. No deadline arithmetic and no timer: `delivery/time` is not used. No child-Run action: v1 has none. The report is part of a decision for the caller; this task adds no input kind that carries it to a pattern. A text never settles an ask by itself. Telemetry, Config and Control are not applicable: both are pure callables, and the rule is a recorded operand of the state.

## Named acceptance groups

Each recorded trace is a fixed list of v1 neutral maps in the test file, as `@v1_fixture` of `workflow/pattern-step` is. No provider fixture is needed. Expected decisions are written by hand, not computed by the production function.

1. **`answer_after_timeout_is_late`**: an ask, then an `expired` outcome (`{:closed, id, "expired"}`), then an answer of the named person: `:late`, state unchanged.
2. **`other_person_refused`**: an answer whose `person_id` is another person, and an answer whose `verified_person` differs from its `person_id`, are both `{:refused, :wrong_person}`. The ask stays open and the named person's answer then stands. The identity in the answer payload text is ignored.
3. **`first_answer_stands`**: two answers of the named person: the first is `{:answer, id}`, the second is `:late`.
4. **`answer_names_its_ask`**: with two open asks in one request, an answer settles only the ask it names. A `completed` outcome for an open ask and an answer that names a tool action are `{:refused, :incompatible_answer_kind}`; the ask stays open.
5. **`text_without_open_ask_is_message`**: `route/2` gives `:message` with no open ask and with an open ask for another person, `{:answer, id}` with one, `{:refused, :ambiguous_ask}` with two. After an ask closes, text from its person is `:message`.
6. **`wake_bypasses_every_rule`**: a `wake` gives `:pass` and an equal state under each of the five rules in each phase, also with a queue that is not empty.
7. **`five_rules_one_trace`**: one trace: start; a request with three tool calls; an applied outcome for the first; a message; a wake; outcomes for the other two. At the message the five rules give `:queued`, `{:refused, :run_busy}`, `{:interrupt, message, report}`, `{:deliver, message}` and `{:side_run, message, report}`. The report names the first action as delivered and the other two as open, and equals what the ready tracker applied on that trace. Under `:queue`, `next/1` gives the message after the last outcome, two queued messages leave in arrival order, and the 17th is `{:refused, :queue_full}`. The `:active` and `:terminal` rows are checked once each.
8. **`side_run_leaves_first_run_unchanged`**: under `:side_run` the decision carries the message and the report, the returned state equals the given state, and the rest of the trace gives the same states and decisions as the same trace without that message.

## Evidence

- Proof: two selected Cure laws over supplied classifications. `wait-for-person`: for both values of "the ID is in `asks`" and each tracker class, an answer whose three person texts are not all equal is never the answer decision. `mid-run-input`: for each rule, phase and queue flag, an input that is not a message passes. The laws do not cover map validation, text comparison, lookup or the ready tracker.
- Type: pinned Cure compiles the two production decisions; the source audit reports no axiom, hole or unproved-total definition.
- Test: the eight groups; one small checked example in each Piece; two negative controls. Remove the person comparison for a moment: `other_person_refused` must fail. Let a side-run message enter the queue for a moment: `side_run_leaves_first_run_unchanged` must fail. Revert both.
- Upstream: the Cure pin; ready `workflow/pattern-step` settlement, used unchanged.
- Assumption: the host Needs above. Monitored: none.

Ask the coordinator if the pinned compiler cannot express a selected law; do not weaken it silently.

Run the tests of both Pieces, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Record commands, exit codes, laws, scenarios and limits separately. One independent review checks this body and the exact diff, including features that nobody asked for.
