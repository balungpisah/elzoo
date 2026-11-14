# ELZ-212 — A control drains before it replies, and a control ID that a protocol input holds is a conflict

- Dependencies: ELZ-033, ELZ-192, ELZ-211
- Output: none. A repair of the ready Piece `assembly/run-engine` on its control path. One sentence is added to the Contract of `control/4`: it replies after the engine has drained. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

The automated review of pull request #266 left two findings on the
control path, and the code confirms both. First: after an approval,
the control replies before the engine has drained. An approved root
`finish` then leaves the Run open, and an approved finish of a nested
child does not reach its parent, until some later input comes. Second:
a `pause` or `continue` control whose ID equals the ID of a recorded
protocol input raises in the engine process, where the Contract
promises `{:error, :input_id_conflict}`.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing; confirm each when you start, and if one differs, stop and
ask):

- `apply_control/4` for `:begin_attempt` and `:approval_evidence`
  (about 2434 to 2440) runs the Run command, `sync_run/1` and
  `release_waiting/3`, and returns. It does not call `drain/1`. The
  clause for `:pause` and `:continue` ends in `drain(s)` (about line
  2475), and `input/4` drains too (about 1342).
- For an action that is not a model or tool call, `release_waiting/3`
  commits the continuation `ready` and calls `dispatch/3` (about 2518
  to 2532). For a root `finish` that commits the `:finish` record
  (about 1952 to 1969). Its fold step sets `stop_pending: :completed`
  and gives no output (about 445 to 447). `finish_run/3` is called
  from `drain/1` only (about 1572 to 1574).
- For a finish of a nested child, `dispatch/3` settles the finish
  slot (about 1975 to 1986). The parent gets its outcome from the
  branch `finished_child` of `drain/1` only (about 1588 to 1610).
- After ELZ-191 the view record of a new Attempt settles every open
  slot of the older Attempt in its fold step (about 368 to 375 and
  731 to 744). So after `:begin_attempt`, `release_waiting/3` finds no
  slot that it may release (`permitted?/3` needs the current Attempt,
  about 2907 to 2911). A drain there can still hand a later known
  child cost to a parent that the change settled with no actual
  (about 1596 to 1603).
- `original_record/3` (about 1443 to 1465) matches a recorded
  protocol input with no look at the candidate (about line 1448) and
  runs `put_in([:input, "at_ms"], 0)` on both. A lifecycle candidate
  has no `:input` key, so `put_in` raises; `handle_call/3` (about
  1269 to 1276) has no rescue and the engine process ends. The clause
  for a recorded lifecycle input has the guard (about line 1455), and
  the last clause answers `{:error, :input_id_conflict}` (about 1462
  to 1463). `apply_control/4` already maps that answer (about line
  2478).
- The README promises the conflict for changed bytes of one ID (about
  101 to 104 and 125 to 127). It says nothing on when a control
  replies (about 106 to 112).
- The test `ASK non-Effects release approval without inventing an
  intent` (`test/elzoo/run_engine_test.exs`, about 1684 to 1710)
  approves a `finish`, but with no completed source, so it is refused;
  it asserts only that the phase is no longer `approval`. The test
  `stay/close pause and deadline retain Resource's barrier; read-only
  cleanup remains visible` (about 2213) shows the conflict for two
  controls with one ID (about 2257).

## The changed Contract

1. The controls `approval_evidence` and `begin_attempt` end like
   every other accepted call: after the Run command, the view and the
   release, the engine drains, and the control replies after that.
   When the drain ends in a halt, the control replies with that error,
   as `input/4` does. So an approved root `finish` with a completed
   source ends the Run before the reply, and an approved finish of a
   nested child gives its parent the outcome before the reply. The
   README states the sentence beside the text on `control/4`.
2. A `pause` or `continue` control whose ID is the ID of a recorded
   input of another kind gives `{:error, :input_id_conflict}`. Nothing
   is committed and the engine process goes on. This restores the
   stated rule; it is no new rule.

No input, option, control command, public function, record kind or
durable field is added. A control whose Run command is refused or
unchanged replies with `{:error, {:run_control, ...}}` as today and
does not drain.

The README names the new groups, the grounding claim of `piece.json`
follows, and the index row follows in the last commit before the pull
request is opened (in-place change of a ready Piece, same Piece ID).

## Named acceptance groups

Nearest existing tests: the two named above, `document publication
uses typed nested validation, person, genuine consent and actual
completion map` (about line 40), `ordinary ASK waits durably, then
genuine consent dispatches once` (about 1926), and the helper
`finishing_root/1` (about 4444), which shows a root that finishes on a
completed source. Use `require_approval/1` and `consent/1` of the
helper.

1. **`approved_root_finish_ends_the_run`**: a root action completes;
   the pattern then asks a `finish` on it under an ASK rule; the
   consent control replies `{:ok, :applied}`; with no further input
   the view of the engine and the status of the Run show the outcome
   `completed`, and `stop_pending` is nil.
2. **`approved_child_finish_reaches_its_parent`**: the same for the
   `finish` of a nested child: after the consent control, with no
   further input, the parent action is settled `completed` with the
   payload of the finish and its actual.
3. **`begin_attempt_leaves_nothing_to_drain`**: after a
   `begin_attempt` control on a Run with open slots, a restart of the
   engine writes no record and gives an equal view; the tests of the
   change of Attempt pass unchanged. If a test of the group
   `replay_is_equal` (about 5356) already shows this, name it instead
   of a new case.
4. **`control_id_of_a_protocol_input_is_a_conflict`**: an input with
   the ID `x` is applied; a `pause` control with the ID `x` and then a
   `continue` control with the ID `x` each give
   `{:error, :input_id_conflict}`; the engine process is the same
   process, the count of journal records did not move, and the next
   input is applied. The same control ID sent twice with equal bytes
   still gives `{:ok, :applied}` twice.
5. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged. If one fails because a control now drains, stop and ask.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: without
the drain, groups 1 and 2 fail (`stop_pending` is `:completed` and the
Run has no outcome; the parent is `running`); without the guard, the
call of group 4 ends with an exit and the engine process is gone.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and the end of a Run).

## Not in scope

A second `approval_evidence` control with the same evidence after a
lost reply (it replies with the `duplicate` of the Run and releases
nothing; the release then waits for a restart); the answer
`:cancel_unknown` of a `cancel` control whose ID a recorded control
holds (about 2491 to 2497); the evidence rule of
`workflow/run-approval-release` (ELZ-206); and any other Piece.
