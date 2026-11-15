# ELZ-225 — The number of VM launches of one full `mix check` and their share of the time are recorded, and `AGENTS.md` names the one-launch way to repeat a test

- Dependencies: ELZ-033
- Output: none. A measurement and one sentence; no code and no Piece Contract changes.
- Change class: documents only (`AGENTS.md` and one paragraph under `docs/development/`); roadmap checks and the docs-only hosted check. `AGENTS.md` is a shared path: coordinator one-PR path.
- Allowed implementation path: `AGENTS.md` (section 4, one sentence), `docs/development/10-symbolic-ci.md` (section "Timing lines in CI logs"), this task file, its job row in `docs/plans/release-plan.json` and the generated plan views.

Why. One full check starts many separate BEAM instances: Mix in the Ash
spike, Mix and a second VM in each copied consumer, and helper VMs in
tests. Nobody has counted them or measured what their start costs. If the
share is a few percent, the question is closed with the number. If it is
large, a later task can look at it with a fact in hand.

Facts read on `main` (no run was made; confirm by the count of step 1):

- `mix check` itself: 1 launch. Its stages run in that VM
  (`lib/mix/tasks/check.ex:62-100`).
- Ash spike: 2 launches of `mix` (`lib/mix/tasks/elzoo.ash_spike.ex:12`
  and `:19`: `format --check-formatted`, `test --warnings-as-errors`).
- Copied consumers: 29 outer tests (28 per-ID and the aggregate;
  `test/export_test.exs:258-259`). Each starts `elixir` for the inner
  `mix test` (`test/support/cure_consumer_case_test_helper.exs:216`) and
  again for the runtime VM (`:455`): 58 launches. A consumer whose plan
  has install configuration starts one more (`:556`); how many do is not
  known without a run.
- Root tests: `test/export_test.exs:139` (`mix test`),
  `test/elz010_provider_probe_test.exs:333`,
  `test/elz099_streaming_provider_test.exs:71` (`mix`),
  `test/elz099_fuse_provider_test.exs:58`: at least 4.
- Piece tests that start `elixir`: 11 call sites in 9 Pieces
  (`workflow/context-selection`, `assembly/durable-job`,
  `integration/observability`, `delivery/data-stream` twice,
  `delivery/effect-intent`, `delivery/circuit-breaker` three times,
  `runtime/os-isolation`, `runtime/lua-sandbox`). Each runs in the root
  suite, again inside the aggregate consumer, and again inside each
  per-ID consumer whose closure holds the Piece. Some sit in a loop.
- Lower bound from these lines: 1 + 2 + 58 + 4 + 11 = 76. The true number
  is higher and needs the run.
- `bin/elixir` of the pinned toolchain ends with `exec erl ...`, found
  through `PATH`; `mix` is an `elixir` script. So every launch passes
  one program: `erl`. The consumers pass `PATH` on to their child.
- `mix test` has `--repeat-until-failure <n>` since Elixir 1.17 (pinned:
  1.20.4): it repeats the tests in one VM.

## Task

1. Count, in one run, with no change in the repository. Put a directory
   outside the worktree first on `PATH`. It holds one script named `erl`
   that appends one line (time, parent command) to a log file outside
   the worktree and then runs the real `erl` with `exec`. Run `mix check`
   with no flag once on a fresh worker database (the one slot of the
   database server). The number of lines is the number of launches.
   Record the count, the total time from the last `ELZOO STAGE ... end`
   line, and the count by parent (Mix task, consumer, helper).
2. Cost of one launch, on the same host, same load: the median of 20
   runs of `elixir -e ''` (bare VM), and the median of 20 runs of the
   smallest Mix start inside one copied consumer directory that the run
   left behind, or, if none is left, inside the root project
   (`MIX_ENV=test mix run --no-start --no-compile --no-deps-check -e
   ''`).
3. Share: (launches of Mix times the Mix median, plus the other launches
   times the bare median) divided by the total time. State it as an
   estimate with its two inputs.
4. Decision line, in the CI guide paragraph: under 3 percent: "closed
   with the number; no task". 3 percent or more: "reported to the
   coordinator with the three largest groups of launches"; propose
   nothing more.
5. `AGENTS.md` section 4, last bullet (negative controls), add one
   sentence after "a first green run alone is not enough.":

   > To repeat a test, use one launch: `mix test <path>
   > --repeat-until-failure <n>`, not a shell loop.

## Acceptance

- The pull request body holds: the command, its exit code, the launch
  count, the count by group, the two medians, the total time and the
  share. The wrapper script is quoted in the body and is not committed.
- The paragraph in the CI guide holds the count, the share, the date,
  the host class (developer host) and the decision line.
- The sentence is in `AGENTS.md` section 4 and nowhere contradicts
  section 5.
- `python3 scripts/check-roadmap.py`, `python3 scripts/check-roadmap.py
  --live` and `git diff --check` exit 0; `python3 scripts/ci-change-class.py range
  origin/main HEAD` prints `true`; the docs-only hosted check is green.
- One independent review.

## Review risk

Low. The estimate is rough: a launch inside a consumer also loads and
checks a project, which the bare median does not hold. The body says so.

## Not in scope

Any change that lowers the number of launches; the hosted jobs; a
measurement of compile time.
