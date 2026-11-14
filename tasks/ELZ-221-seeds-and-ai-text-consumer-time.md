# ELZ-221 — The root suite has run with three other seeds, and the time of the `integration/ai-text` consumer is recorded against its limit

- Dependencies: ELZ-033
- Output: none. A measurement; no code and no Piece Contract changes.
- Change class: documents only (one short paragraph under `docs/development/`); roadmap checks and the docs-only hosted check. A failure becomes an issue of its own.
- Allowed implementation path: `docs/development/10-symbolic-ci.md` (section "Per-test limits of two slow tests") only.

Why. Two things are unmeasured.

1. Every run of the suite uses `seed: 0`, so the order of the tests never
   changes. A test that passes only in this order is not seen.
2. The copied consumer of `integration/ai-text` has the default limit of
   120 s. A sweep suspected 98 to 108 s. If true, one slow runner fails it.

Facts checked on `main` (confirm each when you start):

- `test/test_helper.exs:15` sets `seed: 0`. The generated helper of each
  copied consumer also sets `seed: 0`
  (`test/support/cure_consumer_case_test_helper.exs:170-171`).
- `mix test` applies the options of the command line after it loads the
  test helper (Mix of the pinned Elixir 1.20.4, `mix/tasks/test.ex`), so
  `--seed <n>` wins over the helper. It does not reach the inner run of a
  copied consumer.
- `test/export_test.exs:262-270` fixes the per-test limits: 120,000 ms
  for the PostgreSQL consumers, 300,000 ms for `assembly/durable-job`.
  `integration/ai-text` is a PostgreSQL consumer
  (`lib/elzoo/check_selection.ex:13`).
- The hosted times can be read. Each consumer prints `ELZOO TIMING
  consumer=<id> total seconds=<s>` in the job `check-consumers-db`. Read
  on 2026-11-14 from the six newest green push runs of `main` in which
  that job ran:

  | Run | `integration/ai-text` total, s |
  | --- | --- |
  | 43631684316 | 87.8 |
  | 43627504841 | 65.3 |
  | 43621456382 | 71.5 |
  | 43610606256 | 87.2 |
  | 43608386530 | 86.7 |
  | 43605594917 | 58.8 |

  Largest 87.8 s, 73 percent of the limit. In run 43631684316
  `assembly/durable-job` took 78.4 s against 300 s. The suspected 98 to
  108 s was not found in these runs.

## Task

1. Seeds. On a fresh worker database, at `origin/main`, run the root
   suite three times, one run at a time, each with another seed that you
   choose and record (not 0):

       mix test --warnings-as-errors --seed <n> \
         --exclude consumer_id --exclude aggregate_consumer

   The copied consumers are left out: their inner runs keep seed 0, and
   each is one outer test that does not depend on the order. Record the
   seed, the exit code, the test count and each failure.
2. For each failure: run the same seed once more. Open one issue with the
   seed, the test, the output and both results. Do not repair it here. A
   failure that repeats with its seed is a real order dependency.
3. Hosted time. Read the same line from the three newest green push runs
   of `main` at the time of the task (read-only: `gh run view <run> -R
   balungpisah/elzoo --job <job> --log`) and add them to the table above.
4. Write one short paragraph into the CI guide: the date, the three seeds
   and their results, the table of hosted times with the largest value
   and its share of 120 s, and the decision line below.

Decision line (the worker writes the one that applies; the worker does
not change a limit):

- largest hosted time at most 96 s (80 percent of the limit): "no change
  proposed";
- above 96 s: "reported to the coordinator: the limit of ELZ-062 for
  `assembly/durable-job` (300 s) is the precedent; a change is an owner
  decision and a task of its own".

## Acceptance

- The pull request body holds: the three commands with seed, exit code
  and test count; the table of hosted times with run and job IDs; each
  issue that was opened.
- The paragraph in the CI guide states only what was measured, and names
  the host class of the seed runs (developer host).
- `python3 scripts/check-roadmap.py` and `git diff --check` exit 0;
  `python3 scripts/ci-change-class.py range origin/main HEAD` prints
  `true`; the docs-only hosted check is green.
- One independent review.

## Review risk

Low. No code changes. Three seeds are a sample, not a proof that no
order dependency exists.

## Not in scope

A repair of a failing test; a random seed as the default of the suite
(an owner decision after this measurement); the seed of the inner runs;
any change of a limit.
