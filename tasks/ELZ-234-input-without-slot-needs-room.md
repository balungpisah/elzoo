# ELZ-234 — An input that settles no slot is given to a pattern only when control has room for its invocation entry

- Dependencies: ELZ-033, ELZ-192, ELZ-232
- Output: none. A change in place of the ready Piece `assembly/run-engine`, before the first release, with the same Piece ID. The Contract changes in one point: an input that settles no slot is refused with the classification `record_size` when control has no room for its invocation entry. The README and the `limits` of `piece.json` state it.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

Issue #508 records the defect. The durable control state has a bound of
2,097,152 bytes. The engine adds one entry to `control.invocations` for
each input that reaches a pattern, and no code removes an entry during a
Run. An input that settles a slot is limited: at most 256 lifetime
actions, and each active slot holds a reserve of 4,096 bytes. An input
that settles no slot has no limit and no reserve: a `wake` while no slot
is active, a granted Resource event, and the other kinds that the
lifecycle permits. When the pattern answers with no output, nothing is
charged, so the request cap does not stop these inputs. Enough of them
pass the bound. The step then fails after its input is appended, the
durable unit stops, and a replay fails on the same input again: the Run
halts and no restart helps. It is the same class of defect as the issues
#383, #501 and #502.

The entries cannot be reserved, because their number has no limit. They
cannot be removed, because the fold reads them to classify a repeated
input ID. So the repair is a check of room before the pattern is called.
With no room the pattern is not called, and the input leaves nothing in
control but its classification.

This task runs after ELZ-232 and before ELZ-217. ELZ-232 adds the
reserve of the pattern states to `fits?/1`, which makes the room smaller,
so this path is reached sooner. Every engine task edits the same file,
and ELZ-217 rewrites `fits?/1`. ELZ-217 will depend on this task: its
oracle is the `fits?/1` that this task calls.

Facts checked on `origin/main` at `b532942`: they were read, not run.
Lines are of `lib/elzoo/run_engine.ex` at that commit, before ELZ-232;
ELZ-232 moves them. The byte numbers are estimates by hand. Confirm each
fact when you start, and if one differs, stop and ask.

- The bound is `fits?/1` (about 2938 to 2949). It is asserted after
  every step (about lines 37 and 76); a failure raises. ELZ-232 adds the
  reserve of each open callable to it.
- The durable unit appends the input first and evaluates then
  (`pieces/runtime/durable-unit/lib/elzoo/durable_unit.ex`, about 145 to
  147). A raise in the step is caught (about 191 to 193) and stops the
  unit with `durable_unit_transition_failed` (about 168 to 172). A new
  start of the unit evaluates the pending input again (about line 70).
- The fold of a `:protocol` record is at about 80 to 119. A record of
  another Run or of a stale Attempt is `late` (about 85 to 86). A record
  whose ID is in `control.invocations` is `duplicate` (about 88 to 90).
  Else the fold calls `expire_waits/2` (about 93) and `protocol/3`
  (about 94). `protocol/3` returns the state, a flag and a callable. The
  fold calls `invoke/3` (about 99) when the flag is true, the generation
  is open, no stop is pending, the Run is not paused and the callable is
  not closed (about 96 to 98).
- `protocol/3` (about 498 to 563) sends `action_outcome` and
  `person_answer` to `settle_protocol/3` (about 505 to 506). These are
  the inputs that settle a slot. For every other kind the callable is
  `root`. A `wake` is accepted when the lifecycle permits new work, the
  request count is not exhausted and no slot is active (about 508 to
  524). A `resource_event` is accepted when its Resource has a cursor,
  the lifecycle allows it and no slot is active (about 543 to 548). Each
  other kind is accepted when the lifecycle permits new work and no slot
  is active (about 550 to 561). `cancel` and `run_ended` are never
  accepted (about 526 to 541).
- `invoke/3` (about 851 to 932) calls the pattern (about 856) and then
  adds the entry `record.id => digest({record.input,
  record.correlation})` to `control.invocations` (about 858 to 859),
  whatever the pattern answers.
- An entry is the ID and a digest of 32 bytes: the bytes of the ID plus
  about 42. `input/4` accepts an ID of at most 160 bytes (about 1325).
  So an entry is at most about 202 bytes.
- `invocations` is written at about 859 only and read at about 88 to 89
  only. A new Run starts with an empty map (about 1176 and 147 to 151).
- When the pattern gives a request that does not fit, `admit_request/5`
  returns the state without the request (about 984). That state holds
  the entry, the count, the receipt and the new pattern state.
- `invoke/3` has two more callers. The fold of `:resume_input` (about
  141) gives a slot its pending input; a slot with a pending input
  counts as active (about 2903 to 2904), so it holds its 4,096 bytes.
  The `:nested` fold (about 360) gives a child its `start`; ELZ-232
  checks the result of that fold.
- `classify/2` (about 2901) sets `control.classification` and nothing
  else. `status/1` shows it (about 1266). `input/4` answers with the
  result of the durable unit (about 1348 to 1353): `{:ok, :applied}` for
  a committed input, whatever its classification.
- The classification `record_size` exists: `admit_request/5` gives it to
  a request without room (about 984).
- `step/2` is a public function (about 35 and 41). The README says that
  it is exported only for the Operator binding of the directory (about
  129). No test calls it directly today.
- The test file builds a `:protocol` record by hand at one place
  (`test/elzoo/run_engine_test.exs`, about 932 to 941): `version`,
  `kind`, `id`, `run_id`, `attempt_id`, `input` with `at_ms`,
  `correlation` and `context`.
- `unit_state/1` of the test file (about 3916) returns the state of the
  durable unit. `control_headroom/1` of the test support file (about
  826) recomputes the bound from a state; ELZ-232 gives it the reserve
  of the callables.

## The repair

**The inputs.** "An input that settles no slot" is a `:protocol` record
whose input kind is neither `action_outcome` nor `person_answer`. The
kind is read from the record alone.

**The check.** In the fold of a `:protocol` record, at the place where
`invoke/3` is chosen (about 96 to 99), and only for an input that
settles no slot: the fold takes the state that `protocol/3` returned,
places the entry of this record in `control.invocations`, and asks
`fits?/1` of that state.

- When it fits, the fold calls `invoke/3` as today.
- When it does not fit, the fold does not call `invoke/3`. It returns
  the state that `protocol/3` returned, changed by `classify(state,
  :record_size)` only, and no output.

So after a refusal: the pattern was not called; `control.invocations`
has no entry for the input; the pattern state, the request count, the
receipts, the trackers, the slots and the requests are as `protocol/3`
left them. What `expire_waits/2` and `protocol/3` did stays: it is the
state that an input reaches today when it is not accepted. The engine
goes on.

An input that settles a slot is given to its pattern as today, with no
new check. The fold of `:resume_input` and the `:nested` fold do not
change.

The check is before the call and not after it, so that no evaluated
result is dropped. After a check that passed, `invoke/3` adds only what
is reserved: the pattern state (ELZ-232), the receipt (1,024 bytes for
each receipt that can still come), and a request that `admit_request/5`
checks itself.

The decision is a pure function of the stored state and the record: the
kind and the ID come from the record, the room from the stored state. A
replay gives the same state. A journal that was recorded before this
repair can fold to another state: an input whose entry did not fit, and
whose step still passed because the same step removed enough afterwards,
now folds to the refusal. Where the step failed, the input is still
pending, and it now folds to the refusal. Elzoo is not released, so no
stored journal has to be kept equal; name the case under `Limits:`.

Nothing else changes. Add no record kind, input, option, public
function, durable field or helper layer. Use the existing classification
`record_size`; add no new one. Do not change the reply of `input/4`.

## Task

1. **Measure first. Make no edit of the Piece before the coordinator
   answers.** Nothing in this task text was run. On your base, which
   holds ELZ-232:
   - Confirm the facts above and give the lines at your base.
   - Run the tests of the Piece once and record the result.
   - Measure the bytes that one entry adds to the control state, for an
     ID of 1 byte and for an ID of 160 bytes.
   - By reading `protocol/3`, list each input kind that can be accepted
     for `root` without settling a slot. For a kind of the last branch,
     say whether the lifecycle can permit it on a started Run.
   - List every existing test in which an input that settles no slot
     reaches a pattern while the headroom of control
     (`control_headroom/1`) is under 4,096 bytes. None is expected.
   - By reading, say what a second send of a refused input ID gives:
     while the durable unit remembers the ID, and after it has forgotten
     it (`original_record/3`, about 1452). Compare it with an input that
     is not accepted today.
   - Say whether a durable unit can be started on a built state through
     its journal at low cost (the test at about 932 to 950 writes a
     journal row by hand). It decides group 8 below.
   - Send these answers to the coordinator and wait for the reply before
     you build.
2. By reading, before the edit: show that the state which the fold
   returns on a refusal satisfies `fits?/1` when the state before the
   step did. It differs from an input that is not accepted today by the
   classification only. Then show, for each path of `invoke/3` (no
   output; a state over its bound; over the cap; an invalid request; a
   request without room; an admitted request), that a state which passed
   the check also passes the assertion of `step/2`. Write the reasoning
   in the pull request body with the lines. If one path does not hold,
   stop and ask. A change of the classification or of a lifecycle field
   can add a few bytes with no reserve, on every path and also today: a
   state at the exact byte of the bound is not repaired here; name it
   under `Limits:`.
3. Make the repair above. No clause of `transition/2` but the one of
   `:protocol` changes. No line of `protocol/3`, `invoke/3`,
   `admit_request/5` or `fits?/1` changes.
4. The rule for existing tests: no existing test changes. If one fails,
   stop and ask.
5. README, beside the text on the room of a child finish and of a nested
   start (about 204 to 211 on `main`; ELZ-232 adds to it), add:

   > An input that settles no slot (a `wake`, a Resource event, and each
   > other kind that is neither an action outcome nor a person answer)
   > is given to the root pattern only when control, with the invocation
   > entry of that input placed in it, still satisfies the bound. With
   > no room the pattern is not called and nothing of the input is kept:
   > no invocation entry, no charge, no receipt and no request. Its
   > classification in `status/1` is `record_size`, `input/4` answers as
   > for every committed input, and the engine goes on. An input that
   > settles a slot is given to its pattern as before. An invocation
   > entry stays in control until the Run ends, so room comes back only
   > when other state leaves control. `cancel` needs no entry.

   README, in "Failure, size and audit limits" (about 292 to 296), after
   the text on the control bound, add:

   > an input that settles no slot needs room in control for its
   > invocation entry (its ID and about 42 bytes), else it is
   > classified `record_size` and not given to a pattern

   Put the measured number in place of "about 42". At the end of
   "Grounding and limits", add the new groups to the list of named
   groups, each with what it shows, in the way of the groups of ELZ-192,
   and add:

   > Limits of the invocation entries. The entries of one Run are never
   > removed. The entry of an input that settles a slot is taken to be
   > covered by the 4,096 bytes of that slot. A state at the exact byte
   > of the control bound can still fail a step by a change of a few
   > bytes. A Run recorded before this repair can fold to another state
   > (Elzoo is not released).

6. `piece.json`, in the entry of `limits` on sizes, add at the end:

   > An input that settles no slot is given to a pattern only when
   > control has room for its invocation entry; with no room it is
   > classified `record_size`, the pattern is not called and nothing of
   > the input is kept.

   Add one entry to `limits`:

   > A Run recorded before the repair of the invocation entries can fold
   > to another state: an input that settles no slot and has no room is
   > refused where the old engine called the pattern (Elzoo is not
   > released).

   The `contract` string stays, so the `note` of the index row stays;
   `manifest_sha256` follows the new bytes. Extend the test claim in
   `grounding` only as far as the new groups need.
7. Name the paths of "Not in scope" in the pull request body under
   `Limits:`, with the lines at your head.

## Named acceptance groups

The cases go into the existing group `Sizing and sanitized evidence` of
`test/elzoo/run_engine_test.exs`, so the named groups of `piece.json`
stay. Thousands of inputs through the engine would be needed to fill
control, so the groups may call `Elzoo.RunEngine.step/2` on a built
state. Build it so: run a small Run through the engine to the wanted
point, read the state with `unit_state/1`, and add entries to
`control.invocations` (an ID and 32 bytes each) until
`control_headroom/1` gives the wanted number. The length of one added ID
sets the last byte. A step on a state near the bound encodes about 2 MB
several times, so record the time of the sweep of group 2; if it is over
30 s, stop and ask before you make it shorter. Build the record as the test at about 932 to 941
does. Add no fixture file. You may add helpers for the padding and for
the record to the test support file of the Piece, and nothing else
there.

The headroom below is the headroom of the built state, before the step.
`protocol/3` changes the classification and can change the lifecycle, so
the place where the answer switches is the entry plus a few bytes, and
the tests find it by a sweep. No built state has a headroom under 64
bytes: the last bytes of the bound are a named limit of this task.

1. **`wake_without_room_is_not_given`**: the state has no active slot,
   the lifecycle permits new work, and the headroom is 64 bytes, which
   is less than one entry. `step/2` returns a transition and does not
   raise. The classification is `record_size`. The output is `:none`.
   `control.invocations`, the callables with the root pattern state,
   the request count, the receipts, the trackers, the slots and the
   requests are equal to the built state. The bound holds
   (`control_headroom/1` is not negative).
2. **`the_switch_is_one_place`**: the same state and the same `wake`,
   for every headroom from 64 bytes up to the bytes of the entry plus
   64, one byte at a time. No step raises, and the bound holds after
   each. There is one headroom S: under S the input is refused as in
   group 1; from S on the pattern is called, the entry is in
   `control.invocations` and the root pattern state is the next state
   of the test pattern. Both answers occur. Print S and the bytes of
   the entry.
3. **`each_kind_without_a_slot`**: groups 1 and 2 again for a granted
   `resource_event`, and for each other kind of the list of step 1 that
   the lifecycle can permit. For a Resource cursor, take the state of a
   Run that opened a Resource, or place one cursor by hand; say which.
4. **`settling_input_is_given_as_today`**: the state has one active
   slot that waits for an outcome, and a headroom of 64 bytes. The
   `action_outcome` of that slot is applied: the slot is settled, the
   pattern of its callable got the outcome, the entry is in
   `control.invocations`, and the bound holds. If the bound does not
   hold, stop and report: the 4,096 bytes of a slot are then too small,
   and that is not repaired in this task.
5. **`request_after_the_check`**: at the headroom S of group 2, a
   `wake` to which the root pattern answers with a request. The step
   does not raise and the bound holds, whether the request is admitted
   or is classified `record_size` by `admit_request/5`.
6. **`engine_goes_on`**: from the refused state of group 1: a second
   `wake` with another ID is refused in the same way, and the state is
   equal; a `cancel` is applied and the lifecycle shows it; the record
   of group 1, given to the same state with the padding removed, is
   given to the pattern and is not a `duplicate`.
7. **`decision_is_pure`**: for groups 1, 2 and 4, two calls of `step/2`
   with an equal state and an equal record give equal results.
8. **`unit_stays_alive`**, only if step 1 found a way at low cost: a
   durable unit on a state without room takes a `wake` through the
   engine, answers `{:ok, :applied}`, is alive, and starts again on its
   journal with an equal state. If there is no such way, write under
   `Assumptions:` that no test of this task runs the unit at the bound.
9. **`existing_behaviour`**: every existing test of the Piece passes
   with an empty diff of its body.

Negative controls, each by a temporary edit that is reverted and never
committed. Record the failing output in the pull request body.

- Without the check: group 1 fails. `step/2` raises at its size
  assertion.
- With the check on the state without the entry placed: groups 1 and 2
  fail in the same way (the state fits, the entry does not).
- With the check also made for `action_outcome`: record what group 4
  gives. If it still passes, say so; then this control shows nothing and
  the review covers the point by reading.

## Evidence and gate

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. On the final
head, run the new tests once more in one launch with
`--repeat-until-failure 10`, and record the command and its exit code.
The index row follows in the last commit (AGENTS.md section 3). Record
in the pull request body the time that the new tests add, the answers of
step 1 with the reply of the coordinator, and the measured bytes of an
entry.

Write under `Assumptions:` what no test of this task shows:

- A unit that the defect stopped before the repair folds its pending
  input to the refusal. That follows from the pure decision; no test
  holds a journal of the old engine.
- The built states stand for states that many inputs would reach. No
  test sends those inputs through the engine.
- The 4,096 bytes of an active slot cover the growth at its settlement
  in every case. Group 4 shows one case.

The pull request closes this task and issue #508.

## Review risk

High: the fold of the durable control state and the size check of every
step. One independent review by a strong reasoning model. The reviewer
checks:

- that the check reads the kind and the ID from the record and the room
  from the stored state, and nothing else;
- that it is made for every input that settles no slot and for no other
  input, and that the three callers of `invoke/3` are as the task says;
- that the entry in the check is the entry that `invoke/3` would add:
  the same key and the same digest;
- that the refused state holds nothing of `invoke/3` (no entry, pattern
  state, count, receipt, tracker, slot or request), and that the fold
  gives no output for it;
- that the refused state satisfies the bound, and that a state which
  passed the check passes the assertion of `step/2` on every path of
  `invoke/3` (step 2 of the task);
- that a refused input ID is not treated as a `duplicate` by the fold
  later, and that this is what the pull request body says;
- that no existing test changed;
- that the README and `piece.json` hold the sentences of this task and
  claim no more than the listed cases show.

## Not in scope

**A limit on the count of such inputs.** A fixed number of inputs that
settle no slot for one Run, with its bytes reserved from the start, is
another Contract. This task checks the room and states no count.

**The removal of invocation entries.** The fold reads the map to
classify a repeated input ID after the durable unit has forgotten that
ID. A shorter form or an expiry of the entries is a design of its own.

**The reserve of an active slot.** Whether 4,096 bytes cover the join
record, the invocation entry and the Budget entry of every settlement is
measured in one case here (group 4) and not proven.

**The last bytes of the bound.** A change of the classification or of a
lifecycle field with no reserve, at the exact byte of the bound.

Also not here: the reply of `input/4` for a refused input; a signal to
the host other than the classification in `status/1`; a child whose
parent action settled while the child was open (issue #509); the cost of
`fits?/1` (ELZ-217); the control bound itself; the journal write path;
and any other Piece.
