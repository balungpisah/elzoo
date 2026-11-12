# workflow/bot-run-lifecycle

`Elzoo.BotRunLifecycle.step(state, input, context)` is one pure callable returning
`{:ok, new_state, decision}` or `{:error, :invalid_shape}` without echoing operands.
It owns phase, simultaneous open waits, pause and continue, not Run identity or
durability. No process, Store, clock, timer, dispatch, authorization service or
statechart framework is supplied. Ready `workflow/run` and
`workflow/pattern-step` keep their Contracts unchanged.

## Operands

State is an exact atom-keyed map:

| Field | Value |
| --- | --- |
| `phase` | `:active`, `:waiting`, `:paused` or `:terminal` |
| `waits` | map from stable wait/action text ID to `%{kind: kind, attempt_id: execution_attempt, one_shot: boolean}` |
| `tracker` | authentic opaque tracker returned by `PatternStep.open/1` and preserved from each subsequent step |
| `outcome` | nil unless terminal; otherwise an already committed ready Run outcome |
| `run_deadline` | recorded nonnegative Unix milliseconds |
| `pause_deadline` | recorded nonnegative Unix milliseconds when paused; otherwise nil or a recorded deadline |

Wait kinds are `:model`, `:tool`, `:approval`, `:person`, `:child_run`,
`:outside_event`, `:resource_event`. Only a resource wait may have
`one_shot: false`; observation then accepts its input without removing the wait.
Model/tool/person waits use their real action IDs in the ready PatternStep
tracker. The caller supplies and preserves that tracker, including its settled
entries; this Piece adds no second first-result tracker. Trackers retain the
ready request's fixed 1..64-action bound. Callers own wait installation and
phase selection when beginning work. Waiting and active are distinct: waiting
does not permit new work just because a message arrived.

Protocol input is the checked `{:PatternStep, map}` from `PatternStep.decode/1`;
it is rechecked through that same boundary. Unknown versions, fields, kinds and
shapes are refused, not inferred. The only additional inputs are host-recorded
Control maps (not PatternStep kinds):

```elixir
%{control: :pause, at_ms: recorded_time, attempt_id: execution_attempt,
  pause_deadline: future_pause_deadline}
%{control: :continue, at_ms: recorded_time, attempt_id: execution_attempt,
  person_id: verified_person, run_deadline: future_replacement_deadline}
```

Control maps have exactly those keys. Pause/continue deadlines must be valid
and strictly later than the Control's recorded time. Continue requires an
explicit future replacement Run deadline; omission is not an implicit extension.

Context supplies `current_attempt`, `originating_attempt` (text or nil),
`budget_exhausted` (Boolean), and `budget_rule` (`:pause` or `:finish`). These are
intrinsic recorded facts and the one admitted exhausted-budget choice, not a
configuration framework. For protocol inputs without an Attempt, the host
correlates `originating_attempt` from its durable log. Cancel and Control inputs
carry their own target. Wake carries only recorded `at_ms` and evaluates time
without an originating Attempt; it is never a new message or mid-run-message
policy input. Effect-intent transport attempt numbers do not identify an
execution Attempt.

Context also supplies the operand needed by the particular operation:

- `verified_person`: authenticated person ID for person answers and continue;
  it must equal the recorded input's person ID. The host verifies authority;
  string equality and text payloads do not authenticate anybody.
- `pause_deadline`: future deadline when exhausted budget first enters pause.
  An existing pause keeps its original deadline, not a refreshed timeout.
- `wait_id`: host-correlated resource wait ID for a `resource_event` input.
  `one_shot` is supplied wait meaning, not a resource lifetime policy.

`run_ended` has typed opaque payload `%{outcome: committed_outcome}`. The trusted
caller obtains this fact from ready Run and supplies no speculative completion.
`Run.outcome?/1` validates the value; the five outcomes are `:completed`,
`:failed`, `:cancelled`, `:out_of_budget`, `:out_of_time`. Completion still needs
Run's committed evidence record; this pure callable cannot establish that fact.
Action `unknown` and other action classifications never become Run outcomes.

Approval, child-Run and outside-event waits remain caller data. This Piece
does not invent v1 actions or approval inputs to open/resolve them, dispatch
child Runs or implement approval persistence. RC-50 owns that routing and ready
Run owns approval/restart semantics. A text message never settles an ask.

## Decisions and precedence

Decisions are `:unchanged`, `:late`, `{:accept_wait, id}`, `:permit_new_work`,
`:remain_waiting`, `:remain_paused`, or `{:request_outcome, outcome}`.
Incompatible action/person answer kinds are unchanged, using PatternStep's
existing refusal. Accepted results update the ready tracker and remove only
their own one-shot wait. Closing the last wait can make the phase active, never
completed; no work permission is emitted by that settlement itself.

1. Terminal state absorbs valid inputs. A trusted Run-ended input otherwise
   installs the committed outcome, even with an old origin or elapsed deadline.
2. Other old/unknown Attempt inputs leave state unchanged. `Run.classify_attempt/2`
   is the identity authority; stale input does not act as a timer tick.
3. Current input or trusted wake at `now >= run_deadline`, or at/after the
   pause deadline while paused, requests `:out_of_time` before new work,
   continuation, cancellation or empty-budget decisions.
4. Current targeted cancellation requests `:cancelled`, never permission for
   new work and never a claim of physical cancellation of an external send.
5. Closed/unknown wait results are late; PatternStep enforces first settlement
   and incompatible ask-person answers. Open results may be retained while
   paused, but start no new action. A settled resource observation may leave a
   continuing resource wait open.
6. Empty budget pauses with its supplied deadline under `:pause`, or requests
   `:out_of_budget` under `:finish`. An accepted result is retained even if this
   same step pauses or requests the budget outcome.
7. Explicit pause keeps waits; timely verified continue removes pause and
   atomically installs its future Run deadline, preserving only unresolved
   waits. With empty budget it remains paused (no deadline replacement or new
   funds). Clocks continue while paused; an at/after-deadline continue cannot
   extend the Run retroactively. Otherwise paused/waiting remain so, and active
   work inputs permit work.

A request to end is **not** a committed terminal state. The serialized caller
must suppress further work and commit through ready Run before presenting
Run ended. Run termination cannot assert that an unknown effect did not happen;
independent effect reconciliation stays separate and may retain late evidence.

## Grounding and example

`mix test pieces/workflow/bot-run-lifecycle/test` has exactly seven named scenario
groups from ELZ-124: Total lifecycle table; Several waits; Attempt and cancel;
Pause and continue; Budget/time boundaries; Owner-approved protocol distinctions;
Selected Cure laws and example. Independent expected table entries, both time
boundaries and both budget choices exercise the actual Elixir callable. These
finite scenarios test validation, lookup and native time arithmetic; they are
not universal proofs or a durable replay claim. Serializing and replaying
supplied state demonstrates only pure state preservation.

The production Cure `decide/4` is checked total over its supplied Phase/Event/
Boolean classification table. Selected equality laws `terminal_absorbing`,
`old_attempt_unchanged` and `closed_wait_late` check the production table, not
Elixir identity lookup, protocol validation, time comparison, authentication or
durability. The source audit checks no axioms, holes, unresolved/unaudited/opaque
or unproved-total definitions and zero absurd. The compiler checks types;
compiler soundness is upstream grounding. A temporary production mutation that
applies a closed-wait result is checked against Several waits, then restored.

The checked example in `examples/bot_run_lifecycle.exs` shows two waits, pause,
settlement of one during pause, and continue with only the other remaining.

Needs: serialized caller state, authentic checked PatternStep trackers, truthful
Run currentness/outcomes and action-to-Attempt correlation, host-verified person
and Control authority, recorded time, actual budget facts and host wakes. No
proof of host authentication, durable timers, budget charging, effect settlement,
physical cancellation or Store replay is claimed. Modules are application-owned
under `Elzoo.BotRunLifecycle` and `Cure.Elzoo.BotRunLifecycle`; redistributors
must coordinate renaming. Apache-2.0; no new dependency or pin.

Telemetry, Config and Control are not applicable **as runtime facilities**:
there are no observations, ambient settings or independently controlled process.
Pause/continue above are pure decisions over host-recorded Control data, not a
new operational service.
