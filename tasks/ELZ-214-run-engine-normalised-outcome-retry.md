# ELZ-214 — A retried outcome that was recorded as `invalid_outcome` is a duplicate after settlement too

- Dependencies: ELZ-033, ELZ-192, ELZ-213
- Output: none. A repair of the ready Piece `assembly/run-engine` that restores its retry rule for one case under a schema map; the Contract and `piece.json` do not change. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/lib/**` and `pieces/assembly/run-engine/test/**` only. No `README.md`, no `piece.json`, no index file.

The automated review of pull request #411 (ELZ-180) found it. When the
binding of an action kind is a schema map, an outcome in another
schema than the `result` of the binding of that action is recorded as
`unknown` with the reason `invalid_outcome`. The host then sends the
same ID with the same bytes again, as the Contract tells it to. Before
the action settles, the answer is `{:ok, :duplicate}`. After it
settles, the answer is `{:error, :input_id_conflict}`: the engine no
longer knows the schema of the action, does not normalise the retry,
and compares the raw input with the normalised record. The host cannot
confirm a settlement that is committed.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing; confirm each when you start, and if one differs, stop and
ask):

- `checked_ingress/3` (about 1360 to 1421) reads the expected result
  from the binding of the slot. For a schema map `choose/3` needs the
  action (about 2850 to 2854). The action is read only when the slot
  holds `:action` or the request is still in the state (about 1373 to
  1375). With an expected result, an input in another schema is
  replaced by `invalid_outcome/4` with `loss: :unavailable` (about
  1401 to 1403 and 1423 to 1439).
- The admission merges the facts into the slot, and the facts hold
  the action (about 1786 to 1787 and 233). A settled slot is rebuilt
  from a list of fields that has no `:action` (about 625 to 639; the
  closer of a change of Attempt about 775 to 789). `step/2` drops a
  request from the state when each of its slots is running, waiting,
  settled or in reconcile (about 68 to 73).
- So after settlement, under a schema map, the expected result is
  nil. The clause at about 1401 is skipped. When the schema of the
  input is registered and its payload is valid, the raw input is
  returned (about 1405 to 1408).
- `ingest/4` calls `checked_ingress/3` first and `original_record/3`
  after it (about 1323 and 1337). `original_record/3` compares the
  candidate with the recorded input, with the time set to 0 (about
  1448 to 1453). The raw candidate is not equal to the normalised
  record, so the answer is the conflict.
- Not affected: a binding that is no schema map (`choose/3` does not
  read the action, about 2847 to 2848); a retry before the slot
  settles; an input whose schema is not registered or whose payload
  is invalid (it is normalised with no expected result, about 1410 to
  1415).
- The schema of the action is still durable after settlement, with no
  new field: the admission record of the occurrence holds the action
  in its facts (about 1786 to 1795). Its ID is stable:
  `admit:` and the digest of `{run_id, occurrence}` (about 1789).
  `find_input/4` (about 1467 to 1482) reads a recorded input by its
  ID, and `ingest/4` already uses it for each input.
- The README promises: "The same admitted ID retains its original
  data and time on retry" (about 101), and that every read of the
  expected result of an outcome uses the binding chosen for the
  action (about 67 to 69).
- The record keeps only the normalised outcome, not the bytes that
  the host sent. So before settlement, today, two different invalid
  inputs with one ID are both a duplicate of the same record.

## The repair

When a retried ID has a recorded protocol input that is not equal to
the candidate, and the candidate names an occurrence whose slot holds
no action and whose request has left the state, the engine reads the
action from the recorded admission of that occurrence, chooses the
binding as at the first time, and runs the same check again with that
expected result. If the check now replaces the candidate by
`invalid_outcome`, the engine compares that with the record. Equal
means the recorded input is used and the answer is `{:ok,
:duplicate}`; else the answer is the conflict, as today.

Nothing else changes. An ID with no recorded input, a candidate that
is equal at the first compare, an occurrence with no recorded
admission, and an input for a slot that is not settled take the paths
of today, with the bytes of today. No record is written by the second
check. The settled slot keeps its shape. No input, option, control
command, public function, record kind or durable field is added. The
Contract is restored, not changed, so the README and `piece.json`
stay as they are.

The second read of the journal happens only on that path (an ID that
is recorded, a compare that fails, a settled slot under a schema
map). Say in the pull request body under `Limits:` that, as before
settlement, the engine cannot tell two different invalid inputs with
one ID apart.

## Named acceptance groups

The cases go into the existing group `outcome_schema_by_binding`
(`test/elzoo/run_engine_test.exs`, about 3184 to 3243, test `an
outcome is checked against the result of the binding of its own
occurrence`), so the named groups of `piece.json` stay. Use
`provider_input/2`, `outcome_for/1`, `variant/3`, `add_schemas/3` and
`restart/3` of the test file.

1. **`retry_after_settlement_is_a_duplicate`**: in the Run of that
   test, after the occurrence `b1` is settled `unknown`, the same ID
   with the same input and context gives `{:ok, :duplicate}`; the
   count of journal records did not move and the slot is equal.
2. **`retry_after_a_restart_is_a_duplicate`**: the same after a
   restart of the engine with the same bindings.
3. **`changed_bytes_are_still_a_conflict`**: the same ID with an
   input in the schema that the binding expects gives
   `{:error, :input_id_conflict}`, before and after settlement.
4. **`valid_retry_is_unchanged`**: the ID of the valid outcome of
   `b2`, sent again after settlement, gives `{:ok, :duplicate}`, and
   with another payload the conflict.
5. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged. No existing test asserts the conflict of group 1.

## Evidence and gate

Negative control, by a temporary edit that is reverted: without the
second check, groups 1 and 2 give `{:error, :input_id_conflict}`.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state:
which bytes count as the same input).

## Not in scope

A check of a first outcome for a settled slot against its binding (it
is classified late and its bytes stay as they are), a stored copy of
the bytes that the host sent, a new field on the slot, and any other
Piece.
