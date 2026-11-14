# ELZ-207 — The deadline of an intent of a Run resource is compared with the sampled clock

- Dependencies: ELZ-123
- Output: none. A repair of the ready Piece `workflow/run-resource` that brings the intent deadline under its stated rule of delegated-clock sampling; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/run-resource/lib/**`, `pieces/workflow/run-resource/test/**` and `pieces/workflow/run-resource/README.md` only. No `piece.json`, no index file.

The automated review of pull request #248 found that an expired intent
can take the one active slot of a resource. The finding holds in a
narrow form: the deadline of the intent is compared with the time that
the command carries, not with the clock, so a command with an old
`at_ms` can admit and reserve an intent that is already expired. The
send then cannot happen, the receipt stays `unknown`, and the use keeps
the active slot until the host gives a `not_dispatched` observation or
the resource is cleaned up.

Facts checked on `main` (lines of `lib/elzoo/run_resource.ex` at the
time of writing; confirm each when you start, and if one differs, stop
and ask):

- `execute_new/4` (about 144 to 171) samples the clock with `now(s)`
  only for `expire_first/2`, which compares it with the deadline of the
  resource. It then calls `transition(s.model, normalized)`, and
  `normalized` holds the `at_ms` of the command (`normalize/2`, about
  1030 to 1036).
- The admission of an action refuses an intent with
  `intent["deadline_ms"] <= at` as `:invalid_input` (about 550 to 553).
  The dispatch refuses with
  `record["descriptor"]["deadline_ms"] <= at` as `:closing` (about line
  625). Both use the time of the command.
- After an accepted dispatch the receipt is first committed as
  `["unknown", id]` (about 153 to 156), and it stays so unless the
  intent owner answers `read_only` (about 172 to 199). The active slot
  of a use is freed by a `not_dispatched` observation (about 753 to
  756), by completion or by cleanup.
- **Replay.** `transition/2` has one call site, in `execute_new/4`.
  `recover/1` (about 274 to 296) takes the stored state of the last
  record and does not run `transition/2` again; `validate_command!/2`
  (about 415 to 460) only normalizes each stored command again and
  compares it. A retry with the same ID and the same bytes gets the
  stored receipt (about 133 to 137) and reads no clock. So a value of
  the clock that the transition uses is not replayed, and it must not
  enter the stored command.
- The README (about 87 to 88) says: "Delegated-clock sampling commits
  expiry before new admission/dispatch even when timer delivery or
  command time is old." That sentence holds for the deadline of the
  resource only. It is not in `piece.json`.
- The test `pause_stay_close_and_deadline`
  (`test/elzoo/run_resource_test.exs`, about 664 to 667) shows the rule
  for the resource deadline with a command whose `at_ms` is 1.

## The repair

`execute_new/4` samples the clock once and uses that one sample for
`expire_first/2` and for the two comparisons of an intent deadline. An
intent is expired when its deadline is not later than the later of the
sampled clock and the `at_ms` of the command, so every refusal of today
stays. The refusals keep their reasons: `:invalid_input` at admission,
`:closing` at dispatch. Nothing is committed for a refusal, as today.

The stored command keeps the `at_ms` of the caller and nothing else: the
sample is an operand of the decision, not a part of the record. The
stored state, the receipts, the recovery and the answer to a retry of a
stored command do not change. Every other use of `at` in the transition
(usage, close, events) keeps the time of the command.

The README sentence gets one more clause: the deadline of an intent is
compared with the same sample at admission and at dispatch. `piece.json`
does not change. Add no option, no record field, no timer and no second
clock read.

## Named acceptance groups

The new cases go into the existing tests, named below, so the seven
named groups of `piece.json` stay as they are.

1. **`expired_intent_is_not_admitted`** (in
   `serial_use_and_bounded_wait`): the clock is at 150; a
   `resource_use` whose intent has the deadline 100 and whose command
   has `at_ms: 50` is `{:refused, :invalid_input}`; nothing is
   committed, the active slot is free, and a next use with a later
   deadline is accepted and dispatched.
2. **`expired_intent_is_not_reserved`** (same test): a use is admitted
   at clock 90 with the intent deadline 100; at clock 150 its dispatch
   with `at_ms: 95` is `{:refused, :closing}`; the intent is not
   `reserved` and the intent owner was not called.
3. **`command_time_still_counts`** (same test): with the clock at 50, a
   command with `at_ms: 150` and the intent deadline 100 is refused, as
   today.
4. **`replay_is_equal`**: after groups 1 to 3 a recovery of the owner
   gives an equal snapshot and the same count of records; a retry of an
   accepted command with the same bytes, sent after the clock passed
   the intent deadline, gets the stored receipt.
5. **`existing_behaviour`**: every existing assertion of the Piece
   passes unchanged.

Use the deadlines and clock values that the fixture allows; the numbers
above name the order only. Negative control, by a temporary edit that is
reverted: with the comparisons on `at_ms` alone, groups 1 and 2 fail
(the use becomes active and the intent is reserved).

Run `mix test pieces/workflow/run-resource/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The small gate also runs the ready Pieces that
depend on this one. One independent review, risk normal (durable state,
replay).

## Not in scope

The slot of a use whose send is truly unknown (a stated rule), a
`{:refused, :closing}` of a resource dispatch that halts
`assembly/run-engine` (its own task on the engine), the clock of
`Elzoo.EffectIntent`, and any other Piece.
