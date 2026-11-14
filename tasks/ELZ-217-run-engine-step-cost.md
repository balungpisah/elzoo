# ELZ-217 — The engine reads the unit state once per commit and encodes each part of the state once per size check

- Dependencies: ELZ-033, ELZ-192, ELZ-216
- Output: none. A cost repair of the ready Piece `assembly/run-engine`. The Contract, every record, every reply and every bound stay as they are. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/lib/**` and `pieces/assembly/run-engine/test/**` only. No `README.md`, no `piece.json`, no index file.

Issue #431 (closed as an observation) keeps the cost on record, with
the numbers of the measurement comment of issue #415: one input at the
bounds of the Piece takes about 4.5 s. About 14 percent is the size
check of the step, and about 8 percent is work of the engine outside
the commit. Both can go with no change of the Contract. The rest is
the journal write path of other Pieces and is not touched here. This
task comes last in the row of engine repairs because the others
change the same functions.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing; confirm each when you start, and if one differs, stop and
ask). ELZ-192 changes `fits?/1` and its reserve, and ELZ-210 adds
stops to `drain/1`: read both first.

- `snapshot/1` (about 2861 to 2874) is a call to the unit process
  that copies the whole state, when the unit is alive. `drain/1`
  takes one at its start (about line 1551) and one more for the
  compare (about line 1620). The clauses of `progress/3`,
  `internal_outcome/6` (about 2162), `release_waiting/3` (for each
  slot, about 2505 to 2513) and others take more. The measurement of
  issue #415 counted 1,039 for 260 commits; that number is not
  checked here.
- The unit state changes only by `DurableUnit.step/3`. The engine
  calls it at two places: `ingest/4` (about line 1339) and
  `commit/3` (about line 2705). The unit process can be replaced
  (`current/1`, about 1486 to 1501). `DurableUnit.step/3` answers
  `{:ok, :applied}`, `{:ok, :duplicate}` or an error
  (`pieces/runtime/durable-unit/lib/elzoo/durable_unit.ex`, about 124
  to 160).
- One place reads the state with an older engine state than the
  newest: `release_waiting/3` passes `s`, not `acc`, to
  `action_context/3` (about line 2515). Today that is harmless,
  because each read asks the unit.
- The stop of `drain/1` compares the whole state before and after
  the round (about 1617 to 1621; after ELZ-210 in each branch). A
  record can be applied and leave the state equal but for the
  classification (an outcome that is classified late).
- `action/2` (about 2805 to 2816) decodes the whole request JSON when
  the slot holds no action. `progress/3` for `:checking` calls it for
  each candidate of the request (about 1706 to 1709): up to 64
  decodes of one request in one round.
- `fits?/1` (about 2897 to 2905) runs after every step (about lines
  37 and 76) and once more for each admitted request (about 971). It
  walks the state (`plain?/1`), encodes the control state, encodes
  each slot (`slot_fits?/1`), encodes the slot map again, encodes
  the requests, and encodes the whole state again with an ID of 160
  bytes. Each slot is encoded three times.
- `binary/1` (about line 2922) uses the external term format with
  `:deterministic` and minor version 2, with no compression. So the
  size of a map is one tag byte, four bytes of arity and the sizes
  of its keys and values, and the size of each result of `binary/1`
  is one version byte more than the term in it. The worker confirms
  this against the pinned OTP document that `piece.json` names.
- The bounds are: control plus reserve 2,097,152; one slot 131,072;
  slot map 8,388,608; request map 4,456,448; record 16,777,216. The
  first, third and fourth sum to 14,942,208. So a state that holds
  them cannot pass the record bound, but for the few bytes of the
  frame. Confirm the number of frame bytes.
- `step/2` is a pure Operator and is replayed. It keeps nothing
  between two calls.
- The input of the measurement is the first input of the test
  `64-entry gate batches and 256 lifetime actions leave refusal
  capacity, then refuse the next request`
  (`test/elzoo/run_engine_test.exs`, about 2602). The group
  `known_costs_are_exact` (about 3774 to 3907) compares journal rows
  with rows recorded on an earlier engine; `journal/1` (about 3757)
  reads them.

## The repair

Four changes. None changes a record, a reply, a view or a bound.

1. **One read of the unit state per commit.** The engine process
   keeps the state that it read last. Each call of
   `DurableUnit.step/3`, each change of the unit process and each
   halt ends that copy. Every read uses the newest engine state;
   repair the place named above. A kept state is never used after a
   step whose result is unknown.
2. **The stop of the drain.** A round of `drain/1` goes on when it
   appended a record (`{:ok, :applied}`) and ends when it did not.
   Step 1 of the task, before the edit: list each branch and each
   clause of `progress/3` in which a record can be applied and leave
   the state equal, and show that the one further round calls no
   host function again (gate, authority, binding functions, the
   Run). Where one would be called again, keep the compare for that
   branch, on the kept states, with no call to the unit, and say so
   in the pull request body.
3. **One decode of a request per round.** In one round of `drain/1`
   a request is decoded at most once, also for a gate batch of 64
   entries.
4. **`fits?/1` encodes each part once.** The control state, the
   requests and each slot are encoded once. The size of the slot map
   and of the whole record come by addition of those sizes, the key
   sizes and the fixed frame. The answer is equal to the answer of
   the old function for every state, at the exact byte of each
   bound. No size and no encoding is kept between two steps, and
   none goes into the process dictionary or a table.

No input, option, control command, public function, record kind or
durable field is added. The README and `piece.json` do not change;
the time of an input stays one observation and no bound.

## Named acceptance groups

The cases go into the existing group `Sizing and sanitized evidence`,
so the named groups of `piece.json` stay. Every acceptance is a
count. No test asserts a time.

1. **`one_state_read_per_commit`**: for the sizing input named
   above, the calls of `Elzoo.DurableUnit.snapshot/1` made by the
   engine process, counted by call tracing, are at most the count of
   records that the input appended plus a small constant. Name the
   constant, and record the count before and after in the pull
   request body.
2. **`one_decode_per_round`**: for the same input, the calls of
   `Jason.decode!/1` in the engine process are at most the count of
   appended records plus a small constant. Record both counts.
3. **`journal_is_equal`**: for the sizing input, for the publication
   flow (test at about line 40) and for one Run of the group
   `replay_is_equal` (about 5356), the journal rows, without nonce
   and with the clock of the fixture, are equal to rows recorded on
   the engine before this task, in the way of
   `known_costs_are_exact`.
4. **`size_check_agrees_with_the_old_one`**: the old `fits?/1`, as
   it is on `main` when the task starts, is copied into the test
   file as an oracle. For generated states one byte under, at and
   one byte over each bound, `Elzoo.RunEngine.step/2` with a record
   that changes nothing passes where the oracle says true and fails
   where it says false. Cover the control bound with its reserve
   (also through the `:configure` step), one slot, the slot map and
   the request map. For the record bound show by numbers that the
   other bounds keep it out of reach, and compare on states that
   pass it together with another bound. Use states that the step
   leaves as they are (no pending input, no kept finish, each
   request with a slot that keeps it).
5. **`each_part_is_encoded_once`**: for one step that changes
   nothing, on a state of the shape of the sizing input, the bytes
   that `:erlang.term_to_binary/2` returns inside `step/2`, summed by
   return tracing in the test process, are at most the bytes of one
   encoding of the control state, the slots and the requests plus a
   small constant. Record the sum before and after. If the pinned
   OTP cannot trace that function, say so, keep group 4 alone and
   name the gap under `Assumptions:`.
6. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged, with the counts of gate calls and dispatches that they
   assert.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: a read
of the unit state at the start of each round (group 1 fails by its
count); one byte less in the computed frame of the slot map (group 4
fails at the bound); the kept state not ended after a commit (name
the first existing test that fails).

Write under `Monitored:` only counts and bytes, with the host named
by its role. Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state:
a stale state or a moved bound is wrong behaviour).

## Not in scope

The journal write path, the durable unit, the log and the store
(tasks of their own Pieces); the sort of the slots in each round; a
size check that skips slots which did not change (it needs a kept
size, which a replayed step may not have); a change of a bound; a
time as an acceptance; and any other Piece.
