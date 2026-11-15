# ELZ-240 — After a restart the recovery of a Resource action that was already sent does not send the action command again

- Dependencies: ELZ-033, ELZ-192, ELZ-216, ELZ-217
- Output: none. A repair of the ready Piece `assembly/run-engine`: a running or reconcile Resource slot whose intent was already tried is kept open for its Resource cursor at recovery, and one that was not tried takes the same decision as the first dispatch. The Contract and `piece.json` do not change; the README gets the rule. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/lib/**`, `pieces/assembly/run-engine/test/**` and `pieces/assembly/run-engine/README.md` only. No `piece.json`, no index file.

Issue #526 records the defect, found by reading and then measured by a
test run during ELZ-216. The recovery of intents moves a running or
reconcile slot that holds no request key to `ready`; only model and
tool calls have the branch for an intent that was already tried. For a
Resource open or use slot this holds also when the action was already
sent. In a terminal Run the drain then refuses the ready slot with
`run_or_authority` and the actual 0, and the Budget releases the
reservation. In a Run that is not terminal the drain sends the action
command again with a new `at_ms`; the Resource holds the receipt of
the first command under the same ID and answers an ID conflict, and
the engine settles the slot `refused` with the actual 0 and the reason
`resource_refused`, and the Budget releases the reservation as zero.
A cursor that arrives later still commits the cost as a late
settlement; when none arrives, the cost stays zero although the
action may have run.

The coordinator decided (issue #526, sizing comment): the recovery
never sends the action command of a running Resource slot again; a
slot whose intent was tried stays open for its cursor, and one that
was not tried takes the same decision as the first dispatch. This is
a repair of the Contract, not a change of it: a Resource action that
was sent keeps the rule that its outcome comes through the cursor.

Facts checked on `main` at `640707ac` (lines of
`lib/elzoo/run_engine.ex` at that commit; confirm each when you
start, and if one differs, stop and ask):

- `recover_intents/1` (about 2730 to 2767) runs at `init` (about 1261)
  and at a replacement of the unit (about 1571), before
  `release_waiting/3` and `drain/1`. For each slot in phase `:running`
  or `:reconcile`, of kind `model_call`, `tool_call`,
  `resource_open` or `resource_use`, with no `request_key`, it gets
  or starts the intent owner and reads `EffectIntent.status(owner)`.
- The branches: `not view.active` moves the slot to `:reconcile` with
  `reconciliation: :read_only` (about 2740 to 2741);
  `view.attempts > 0` and kind `model_call` or `tool_call` settles
  the slot `unknown` with `lost_outcome` (about 2743 to 2744); every
  other case moves the slot to `:ready` with
  `reconciliation: :active` and calls `progress/3` (about 2746 to
  2753). The `true` branch has no kind test, so a Resource slot
  whose intent was tried (`attempts > 0`) takes it too.
- `resource_close` is not in the kind list (about 2733), and
  `dispatch_resource/3` returns at once for it (about 2154 to 2155).
- `progress/3` for `:ready` (about 1937 to 1954) calls `dispatch/3`
  when `permitted?/3`, the payload check and the authorization allow;
  else it settles `refused` with `run_or_authority` and actual 0
  (about 1950). `permitted?/3` (about 3074 to 3078) is false in a
  paused or terminal Run, on a stale Attempt, at or after the slot
  deadline, and when the generation is closed.
- `dispatch/3` for `resource_open`, `resource_use` and
  `resource_close` (about 2087 to 2113) sends
  `RunResource.command(resource, %{id: slot.action_id, at_ms:
  clock, body: {:action, action, context, slot[:intent]}})`. A slot
  reaches `:running` only after this command answered `{:ok, _}` and
  the continuation committed (about 2104 to 2108), so a durable
  `:running` Resource slot proves the Resource accepted the action
  command. Any other reply settles `refused` with
  `resource_refused` and actual 0 (about 2110 to 2111).
- `Elzoo.RunResource.execute/3`
  (`pieces/workflow/run-resource/lib/elzoo/run_resource.ex`, about
  132 to 142) answers `{:refused, :id_conflict}` when the ID is known
  with a different normalized command; `normalize/2` keeps `at_ms` in
  the normalized command (about 1033 to 1036), so the same action ID
  with a new time is a conflict. The dispatch command of
  `dispatch_resource/3` has the same property (about 2169 to 2174).
- `dispatch_resource/3` (about 2153 to 2184) already encodes the
  first-dispatch decision for the intent: `resource_close` does
  nothing; `status.attempts > 0` does nothing; `not status.active`
  moves the slot to `:reconcile` with `read_only`; otherwise it sends
  `{:dispatch, slot.intent.identity, owner}` under the deterministic
  ID `stable_id("dispatch:", {run_id, key})` and takes `not_open`,
  `paused`, `closing` and `closed` as harmless; every other reply
  halts with `resource_dispatch_unknown`.
- The outcome of a sent Resource action arrives through the cursor:
  `consume_resource/3` (about 2375 to 2453) reads the entries after
  the stored cursor, commits one protocol record per input and one
  `resource_cursor` record per entry; the fold of `resource_cursor`
  (about 477 to 511) applies the Budget command, and
  `settle_protocol/3` (about 580 to 688) settles the slot. A slot in
  `:running` or `:reconcile` is not selected by `drain/1` (the `next`
  filter at about 1640 to 1646 takes only `checking`, `refusing`,
  `allowed`, `authorizing`, `ready` and the approval cases), so a
  slot left open waits for its cursor.
- `release_waiting/3` (about 2608 to 2709) also sees a running or
  reconcile Resource slot at `startup` and `replacement`, but only
  when it holds a `request_key`; this task's slots hold none. An
  approved Resource slot keeps its path: `dispatch_resource/3` does
  not resend an intent with `attempts > 0`.
- `EffectIntent.status/1` reads the durable model of the intent
  (`pieces/delivery/effect-intent/lib/elzoo/effect_intent.ex`, about
  566 to 579): `attempts` is the count of dispatch attempts of the
  policy model, so it survives an engine restart; `active` is the
  activation state of the new process.
- ELJ-216 (pull request #535, merged) left the restart case of its
  group 2 out on purpose; its body records the measured wrong result:
  after the state of `expired_intent_does_not_halt` and one further
  input, a restart starts with no halt, but the slot is settled
  `refused` with `resource_refused`, actual 0, and the root Budget
  goes from reserved 3 to reserved 2.
- The test group `Resource lifetime and consumption` holds the
  nearest fixtures: `queued_use/3` (about 2463 to 2530) builds a Run
  with a `resource_open` and two `resource_use` actions where the
  second use `queued` has an intent deadline before its slot
  deadline; `observe_use/5` (about 2532 to 2539) gives the Resource an
  observation; `restart/3` (about 4478 to 4483) stops the engine and
  the unit and starts again in recover mode; `view/1`, `unit_state/1`
  and `budget_status/3` read the committed state.

## The repair

In `recover_intents/1`, a `resource_open` or `resource_use` slot in
`:running` or `:reconcile` with no `request_key` takes the decision
of the first dispatch, never the `:ready` move:

- `view.attempts > 0` (the intent was tried): the slot stays open for
  its cursor. It keeps a phase that `drain/1` does not select and that
  the cursor still settles (`:running`, or `:reconcile` with
  `reconciliation: :active` — choose one and say why in the pull
  request body). No command is sent to the Resource and nothing is
  settled by the engine; the outcome comes through the cursor as for
  a slot that was never restarted.
- `view.attempts == 0` (the intent was not tried): the slot takes the
  same decision as the first dispatch — the checks of
  `dispatch_resource/3` on the intent owner (`not active` gives
  `:reconcile` with `read_only`; active gives the `{:dispatch, ...}`
  command under its deterministic ID, with the same harmless
  refusals). The action command is not sent again in either case: a
  durable `:running` slot proves the Resource accepted it.
- `not view.active` keeps its present branch (`:reconcile` with
  `read_only`) for every kind, Resource included.

No input, option, control command, public function, record kind or
durable field is added. The README gets the rule in the Resource
paragraph: a restart never resends the action command of a Resource
slot; a tried intent stays open for its cursor and an untried one
takes the first-dispatch decision.

A `resource_use` or `resource_open` slot in `:reconcile` is covered by
the same rule. The approved path (`request_key` set) is unchanged:
`release_waiting/3` and `dispatch_resource/3` already keep its
behaviour.

## Named acceptance groups

The cases go into the existing group `Resource lifetime and
consumption`, so the named groups of `piece.json` stay. Nearest
existing test: `refused queued Resource intent remains ordinary after
death before cursor commit` (about 2131 to 2252) and the ELZ-216 tests
`expired_intent_does_not_halt`, `resource_outcome_settles_the_action`
and `unknown_dispatch_still_halts` (about 2551 to 2739). Use
`queued_use/3`, `observe_use/5`, `restart/3`, `view/1`,
`unit_state/1` and `budget_status/3`.

1. **`restart_keeps_a_sent_action_open`**: the state of
   `expired_intent_does_not_halt` (use `queued` running with its
   reservation held and its intent tried) plus one further input, then
   `restart/3`. The start returns `{:ok, _}` with no halt and no
   reconciliation reason; the slot of `queued` is still open (not
   settled, no outcome); its reservation is held and the root Budget
   stays committed 0 / reserved 3; no refusal record with
   `resource_refused` or `run_or_authority` was written for it.
2. **`cursor_settles_after_restart`**: after group 1 the host gives
   the Resource a `not_dispatched` observation for the intent of
   `queued`; the engine reads the cursor at the next input; the slot
   is settled by the outcome of the Resource exactly as without the
   restart (same outcome class and Budget result as
   `resource_outcome_settles_the_action`).
3. **`restart_with_untried_intent_dispatches_once`**: a Resource slot
   whose intent was never dispatched before the restart (for example
   the engine stopped after the action command and before the
   `{:dispatch, ...}` command — build it with `resource_proxy/2` or an
   equivalent seam, or stop the engine between the two commands if the
   fixture allows) recovers to the first-dispatch decision: the
   `{:dispatch, ...}` command is sent once under its deterministic ID
   and the Resource's receipt shows one dispatch; a second restart
   sends nothing more.
4. **`retained_slot_survives_restart`**: a request-cap stop retains the
   sent Resource slot before its deadline; after a restart the slot is
   not refused `run_or_authority` with actual 0 while it is retained;
   it stays open for its cursor, and the existing end-of-Run rule
   settles it at or after its deadline (the closer of ELZ-215). Record
   the exact phase and outcome in the pull request body.
5. **`model_and_tool_recovery_unchanged`**: the existing intent
   recovery tests pass unchanged (`Intent recovery windows` and
   `ASK descriptor recovery checks engine startup binding before first
   Run binding`).
6. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

## Evidence and gate

Negative control, by a temporary edit that is reverted: with the old
`true` branch restored for Resource kinds, group 1 gives the slot
`refused`/`resource_refused` (or `run_or_authority` in a terminal
Run), actual 0, and the Budget reserved drops by the reservation;
group 3 shows the resend. Record each failure, then revert; never
commit the edit.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and recovery of a sent effect).

## Not in scope

When an intent counts as expired in the Resource (ELZ-207), the
`{:unknown, ...}` reply of `RunResource.command` and the `read_only`
reply of a dispatch (both still halt or settle as today), the active
place of a refused use, the approval path of a Resource slot, the
cost of the engine steps (ELZ-217), the room of an input that settles
no slot (ELZ-234), the child of a settled nested parent (ELZ-241) and
any other Piece.
