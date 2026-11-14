# ELZ-216 — A Resource that refuses a dispatch as closing does not halt the engine

- Dependencies: ELZ-033, ELZ-192, ELZ-215
- Output: none. A repair of the ready Piece `assembly/run-engine`: a definite refusal of a Resource dispatch is no unknown dispatch. The Contract and `piece.json` do not change; the README gets one sentence. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/lib/**`, `pieces/assembly/run-engine/test/**` and `pieces/assembly/run-engine/README.md` only. No `piece.json`, no index file.

Found by reading, beside the review threads of pull request #248 and
#266; no test shows it and it was not run. The engine asks a Resource
to dispatch the intent of a `resource_open` or `resource_use` action.
It takes two refusals as harmless, `not_open` and `paused`. Every
other reply halts the engine with `resource_dispatch_unknown`. But the
Resource can also refuse with `closing`: when it is closing, and when
the deadline of the intent has passed. A refusal commits nothing and
sends nothing, so it is not unknown. The halt stops every input of
the Run until the host restarts the engine, and the restart meets the
same refusal.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing, and in brackets lines of
`pieces/workflow/run-resource/lib/elzoo/run_resource.ex`; confirm each
when you start, and if one differs, stop and ask):

- `dispatch_resource/3` (about 2055 to 2086) sends the command
  `{:dispatch, identity, owner}` and takes `{:ok, _}`,
  `{:refused, :not_open}` and `{:refused, :paused}` as `{:ok, s}`.
  Every other reply halts (about 2078 to 2082).
- It has three callers: after the action command of a ready slot
  (about 2006 to 2010), for an effect that the Resource cursor names
  (about 2386 to 2392, after `permitted?/3` and the authority check),
  and for an approved Resource slot in recovery (about 2525 to 2527).
- The Resource answers a dispatch [about 614 to 630]: `late` when the
  intent is not `ready`; `{:refused, dispatch_refusal(m)}` when the
  intent is not dispatchable, which is `:closed`, `:closing`,
  `:paused` or `:not_open` [about 663 to 680]; and
  `{:refused, :closing}` when the deadline of the intent is not later
  than the time of the command [about line 625]. A refusal commits
  nothing [about 148 to 149], so the intent stays `ready`.
- `permitted?/3` (about 2907 to 2911) compares the clock with the
  deadline of the slot, not with the deadline of the intent, and it
  reads the clock before the command does (about 2386 and 2074). The
  binding gives both deadlines (`deadline_ms` of the facts and of the
  intent). So the refusal for an expired intent is reached when the
  intent deadline is earlier than the slot deadline, or when the
  clock passes the deadline between the two reads. The refusal for a
  closing Resource is reached when the Resource starts to close
  between the entry that the engine reads and the dispatch: for
  example its own deadline passes [about 231 to 241] while the slot
  deadline is later.
- A use that became active and is refused keeps the active place of
  the Resource. It leaves by a `not_dispatched` observation of the
  host, by completion, or when the Resource closes and settles every
  open action [about 813 and 840 to 862]. The outcome of the action
  then comes to the engine through the cursor, as for `not_open` and
  `paused`.
- The open task ELZ-207 (issue #456) changes [about 625]: the intent
  is expired when its deadline is not later than the later of the
  sampled clock and the time of the command. The reply stays
  `{:refused, :closing}`. After ELZ-207 the refusal is reached more
  often, also when the engine read its clock before the deadline. Its
  text names this halt as a task on the engine.
- The test helper gives both deadlines as 40,000
  (`test/support/run_engine_test_helper.exs`, about 431 to 443), and
  the Resource the same clock as the engine (about line 735).

## The repair

`{:refused, :closing}` from a Resource dispatch is taken like
`not_open` and `paused`: the engine goes on, the slot stays as it is,
nothing is settled by the engine, and the outcome of the action comes
from the Resource through the cursor. Nothing was sent, and the
reservation stays held until that outcome settles it.

Step 1, by reading, before the edit: can a `ready` intent of an open
or use action exist in a Resource whose phase is `closed`? If it can,
`{:refused, :closed}` is taken the same way; if it cannot, leave it
out. Say which in the pull request body, with the lines.

Every other reply (an unknown receipt, an error, another refusal)
halts as today. No input, option, control command, public function,
record kind or durable field is added. The README gets one sentence
in the paragraph on Resources: a Resource that refuses a dispatch as
not open, paused or closing leaves the action with the Resource, and
only an unknown dispatch halts the engine.

The repair holds before and after ELZ-207: the reply is the same. Do
not wait for ELZ-207, and choose test times that give the refusal
under both rules (the time of the command at or after the deadline of
the intent).

## Named acceptance groups

The cases go into the existing group `Resource lifetime and
consumption`, so the named groups of `piece.json` stay. Nearest
existing test: `refused queued Resource intent remains ordinary after
death before cursor commit` (`test/elzoo/run_engine_test.exs`, about
2091 to 2212), which queues one use behind another and completes the
first. Use `resource/3` of the helper and a binding whose intent
deadline is earlier than its slot deadline.

1. **`expired_intent_does_not_halt`**: use B is queued behind use A,
   with an intent deadline before its slot deadline. The clock passes
   the intent deadline. A completes and the engine reads the cursor.
   The call returns `{:ok, :applied}`; `status/1` shows no
   reconciliation reason; no effect was started for B; the slot of B
   is still open and its reservation is held.
2. **`engine_goes_on`**: after group 1 a further input is applied,
   and a restart of the engine starts and is not halted.
3. **`resource_outcome_settles_the_action`**: after group 1 the host
   gives the Resource a `not_dispatched` observation for the intent
   of B; the engine reads the cursor; the slot of B is settled by the
   outcome of the Resource, and its Budget entry follows the existing
   rule for that outcome (record the numbers before and after).
4. **`closing_resource_does_not_halt`**: a use whose slot deadline is
   later than the deadline of the Resource becomes active; the clock
   passes the deadline of the Resource before the engine reads the
   cursor: the call returns, and the action is settled by the outcome
   that the closing Resource gives. If the fixture cannot hold this
   case, stop and ask; do not drop it.
5. **`unknown_dispatch_still_halts`**: a reply that is no refusal
   (the unknown receipt) still halts with
   `resource_dispatch_unknown`. Name the existing test if one shows
   it; if none does and the fixture cannot make the reply, say so in
   the pull request body under `Assumptions:`.
6. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

## Evidence and gate

Negative control, by a temporary edit that is reverted: without the
new clause, the call of group 1 and of group 4 gives
`{:error, :resource_dispatch_unknown}` and `status/1` shows that
reason.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and a halt of the engine).

## Not in scope

When an intent counts as expired in the Resource (ELZ-207), the
active place of a use that was refused (a rule of the Resource), a
`not_dispatched` observation made by the engine, the reply
`read_only`, and any other Piece.
