# ELZ-205 — An identical retry of a stored submission gets the stored answer also after its deadline

- Dependencies: ELZ-010
- Output: none. A changed Contract of the ready Piece `assembly/durable-job` on the order of two checks of `submit/5`; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/durable-job/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

The automated review of pull request #54 found that a caller that lost
the reply of `submit/5` and repeats the same call after the deadline of
the job gets `{:error, {:invalid, :deadline_ms}}`. It cannot learn from
`submit/5` that the first call was stored. No Contract text decides the
case today. This task decides it.

Facts checked on `main` (confirm each when you start, and if one differs,
stop and ask):

- `submit/5` (`lib/elzoo/durable_job.ex`, about 130 to 140) calls
  `Run.request/5` first and goes to the Submitter only with a valid
  request.
- `Run.request/5` (`lib/elzoo/durable_job/run.ex`, about 60 to 98)
  refuses `deadline_ms` that is not an integer greater than the clock
  with `{:error, {:invalid, :deadline_ms}}` (about 81 to 82).
- `Run.digest/1` (about 112 to 118) covers every member of the request
  except `submitted_ms`, so it covers `deadline_ms`. An identical retry
  has the same deadline.
- The Submitter (`lib/elzoo/durable_job/submitter.ex`, about 77 to 95)
  answers a stored key before it appends: `{:duplicate, key}` for the
  same digest, `{:error, :job_key_conflict}` for another. `submit/5`
  turns the first into `{:duplicate, status}` with a read of the Run
  stream. Neither answer writes.
- The result table of `submit/5` and the rule on duplicates are in
  `docs/work/ELZ-010.md` (about 551 to 554 and line 567), which the
  README names as the place of the Contract (about line 88). They list
  the results and state no order between `{:invalid, field}` and the
  answer for a stored key.
- The fixture of the tests takes `:now_ms`
  (`test/support/durable_job_test_helper.exs`, about line 130), so a
  test can move the clock past a deadline.

## The changed Contract

`submit/5` compares `deadline_ms` with the clock only for a job key that
is not stored. The new sentence of the README:

> A submit of a stored job key is answered from the stored request,
> whatever the clock says: `{:duplicate, status}` for the same request
> and `{:error, :job_key_conflict}` for another, also after the deadline
> of the request. A submit of a job key that is not stored, with a
> deadline that is not later than the clock, is
> `{:error, {:invalid, :deadline_ms}}` and stores nothing.

Everything else stays. Each other field is checked before the Submitter
is asked, as today, and a `deadline_ms` that is not an integer is still
`{:error, {:invalid, :deadline_ms}}` before it. The stored request, the
digest, the records, the Relay and the worker do not change: no record
is written for a late submit, with or without a stored key. A late
submit now reaches the Submitter, where before it was refused first. So
it can get the results of that call: an error of the Submitter such as
`{:error, :unavailable}`, and `{:indeterminate, info}` when the call
exits, although a late submit of a new key appends nothing. The README
states that too.

The rule is safe because both answers for a stored key read only.
Build it with the smallest change: the comparison with the clock moves
from `Run.request/5` to the place where the Submitter has found that the
key is not stored. Add no option, no new result, no record kind and no
second validation layer.

Write the sentence into the README of the Piece. Do not edit
`docs/work/ELZ-010.md`: it is an old record, and its table stays true.
`piece.json` changes in the claim of the test grounding, which names the
new scenario; the `contract` sentence is unchanged. So the
`manifest_sha256` of the index row follows in the last commit before the
pull request is opened (in-place change of a ready Piece, same Piece ID;
Elzoo is not released).

## Named acceptance groups

1. **`late_identical_retry_is_duplicate`**: a submit is stored; the
   clock of the fixture moves past its deadline; the same call returns
   `{:duplicate, status}` with the status of the Run; the submission
   stream holds one `requested` record. The same on Memory and on
   PostgreSQL.
2. **`late_conflict_is_conflict`**: after the deadline, the same key
   with another input, and with another deadline, returns
   `{:error, :job_key_conflict}`; nothing is appended.
3. **`late_new_key_is_refused`**: after the clock passed the deadline
   that the call names, a key that is not stored returns
   `{:error, {:invalid, :deadline_ms}}`; the submission stream is
   unchanged and no Oban job exists. A `deadline_ms` that is not an
   integer is `{:error, {:invalid, :deadline_ms}}` and the Submitter is
   not asked, as today.
4. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged (DJ2 and the lost-reply scenarios included).

Negative control, by a temporary edit that is reverted: with the
comparison back in `Run.request/5`, group 1 gets
`{:error, {:invalid, :deadline_ms}}` and fails.

Run `mix test pieces/assembly/durable-job/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk normal (order of
checks before a durable append).

## Not in scope

The deadline of a Run as the worker reads it, the digest, a status call
by another name, `integration/jobs`, `workflow/state-machine`, and any
other Piece.
