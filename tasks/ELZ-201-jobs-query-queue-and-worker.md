# ELZ-201 — `Elzoo.Jobs.query/2` matches only jobs of its own queue and worker

- Dependencies: ELZ-010
- Output: none. A repair of the ready Piece `integration/jobs` that restores its Contract ("a unique job per `(queue, job_key)`"); the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/integration/jobs/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

The automated review of pull request #54 found that `query/2` filters on
the two JSON arguments only. On an Oban instance that also holds jobs of
another worker with the same two arguments, `cancel/3` cancels that job
and `state/3` and `states/3` report it.

Facts checked on `main` (lines of `lib/elzoo/jobs.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- `query/2` (about 55 to 59) is `Oban.Job` with the one condition
  `args @> %{"queue" => queue, "job_key" => job_key}`.
- `state/3` (about 62 to 71), `states/3` (about 86 to 96) and `cancel/3`
  (about 99 to 103, through `Oban.cancel_all_jobs/2`) use it.
- `changeset/4` (about 28 to 35) makes every job of the Piece with
  `Elzoo.Jobs.Worker.new/2` and the option `queue: queue`, so the Oban
  queue of a job of the Piece equals the `"queue"` argument and its
  worker is `Elzoo.Jobs.Worker`.
- The callers in the repository (`state/scheduler`, `assembly/durable-job`,
  `assembly/http-job`, which calls `cancel/3`) make jobs only through
  `changeset/4`; three tests of `assembly/durable-job` call
  `Elzoo.Jobs.Worker.new/2` directly, with `queue:` equal to the
  argument.
- No Limit of the README or of `piece.json` says that the Oban instance
  must hold no other job with these two arguments.

## Task

`query/2` also requires that the Oban queue of the job equals `queue`
and that the worker of the job is the worker of this Piece. Take the
worker name from the module (the text that Oban stores for
`Elzoo.Jobs.Worker`), not from a literal, so that a copy of the Piece
under another namespace still matches its own jobs. Change nothing else:
no function is added, no result changes for a job that the Piece made.
Add no option and no wrapper.

Contract unchanged. `piece.json` changes only in the claim of the test
grounding, which names the new scenario, so the `manifest_sha256` of the
index row follows in the last commit before the pull request is opened
(in-place change of a ready Piece, same Piece ID; Elzoo is not
released). The README names the scenario in its test list.

## Named acceptance groups

1. **`foreign_job_is_not_reached`**: on the disposable PostgreSQL of the
   existing tests, a job of another worker module of the test with the
   arguments `"queue"` and `"job_key"` of a job of the Piece, in another
   Oban queue, and one in the same Oban queue: `state/3` and `states/3`
   report only the job of the Piece (`:absent` and `[]` when there is
   none), and after `cancel/3` the foreign jobs keep their state.
2. **`own_job_is_reached`**: for a job made with `changeset/4`,
   `state/3`, `states/3` and `cancel/3` give what they give today.
3. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

Negative control, by a temporary edit that is reverted: with the two
conditions removed, group 1 fails (the foreign job is reported and
cancelled).

Run `mix test pieces/integration/jobs/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The small gate also runs the ready Pieces that
depend on this one (`assembly/durable-job`, `assembly/http-job`,
`state/scheduler`); a failure there is a finding, not a reason to change
those Pieces here: stop and comment on the issue. One independent
review, risk normal (scope of a cancellation).

## Not in scope

`Elzoo.Jobs.Worker.trapping/1`, which takes every `{:EXIT, _, _}`
message from the mailbox after the runner returns: `perform/1` runs in
the job process that Oban starts, which does not trap exits, so each such
message in its mailbox arrived while the flag was set by this call, and
the moduledoc states the drain; it is not a defect. Also not in scope:
the backoff map of `changeset/4`, which can replace an argument; the
Relay; and any other Piece.
