# ELZ-153 — Run a new Piece in a copied consumer in the small gate

- Dependencies: ELZ-152
- Allowed implementation path: `lib/elzoo/check_selection.ex`, `lib/mix/tasks/check.ex`, `test/export_test.exs`, `test/check_selection_test.exs`, `test/support/cure_consumer_case_test_helper.exs`, `test/test_helper.exs`, `pieces/test_helper.exs`, the sections of `AGENTS.md` and `docs/development/10-symbolic-ci.md` that describe the small gate, and the index/generated changes under AGENTS.md section 3. No change of `.github/workflows/`, of a Piece, of the exporter or of the merge queue.

Issue #328 holds the open point of ELZ-152. Nothing exports a new Piece before its merge, so a test that passes in the catalogue layout and fails in a copied consumer is seen only on `main` (the fault repaired by ELZ-147). Check B of ELZ-152 closed this gap, but it ran the tests of the whole dependency closure of each changed Piece and went over the default limit of 120 s for one test: `assembly/run-engine` 257.5 s, `assembly/http-job` 132.3 s, one run each on a developer host. It was built in commit f371e08 and taken out again in 8094f55; both are in the history of `main`.

Decision of the owner on #328 (2026-11-13):

1. The check runs only for a Piece that the pull request adds.
2. A smaller form is measured first. It runs only the tests of the new Piece in the copied consumer, not the tests of its dependencies. If it stays below the default limit with a margin, no new limit is set.
3. If not, this one check gets a limit of 300 s, the value that ELZ-062 set for `assembly/durable-job`. No other limit changes.

**What to build.** In the small gate only, each added ready Piece that has no per-ID consumer in the inventory of `Elzoo.CheckSelection` runs once in a copied consumer of its own. The export of its dependency closure is planned, written and compiled as `assert_cure_consumer` does it today, and the inner test run takes only the test files of the added Piece. A Piece is added when it is a ready ID at the head and was not a ready ID at the comparison base of `mix check --piece BASE` (no `piece.json` at the base, or a status other than `ready` there). A changed Piece that was ready at the base gets no such consumer, and neither does a dependant. The full check, its five parts and affected mode never run these tests. The report of the gate names the IDs that got one, and its LIMIT line stays true. Take the code of f371e08 as the starting point where it fits.

**Measure before the limit is chosen.** Measure the smaller form on five existing IDs that stand for a new Piece: `assembly/run-engine`, `assembly/http-job`, `workflow/agent-loop`, `integration/ai-token-count` and `workflow/context-compaction`. Three runs each, one at a time, with the limit lifted for the measurement only. Record each total and the times of the steps that the helper already prints. These are numbers of a developer host and not evidence of the hosted time; say so where you record them. Then apply this rule to the largest total:

- at most 80 s: no limit of its own. The tests keep the default limit of the suite.
- more than 80 s and at most 200 s: `timeout: 300_000` on these tests only.
- more than 200 s: stop. Write the numbers on issue #328 and deliver nothing.

80 s and 200 s are two thirds of the limit above them. This is the coordinator's margin for a slower hosted runner, not a measured ratio.

Contract: the five parts together still run exactly the tests of the full check (the partition test stays and passes). No existing test, time limit, marker text, job or queue rule changes. The gate keeps refusing a change that is not Piece-only. If the smaller form cannot be built without a change of the exporter, of the workflow or a second way to select tests, stop and write the exact obstacle on issue #328. Do not design around it.

## Acceptance

- `measurement`: the table of the fifteen runs, the rule applied to it and the limit that follows, in the pull request body.
- `new_piece_consumer_catches_the_layout_fault`: make one existing Piece count as added: a local commit that is never pushed removes the directory `pieces/integration/ai-token-count` and is the BASE; the working tree holds the directory again with the one-line fix of ELZ-147 undone in `test/elzoo/ai_token_count_anthropic_test.exs`. `mix check --piece BASE` fails in the consumer of `integration/ai-token-count`; with the fix it passes. Record both and the added run time, then discard the commit. An equivalent way is allowed; say which.
- `changed_piece_gets_none`: a Piece-only change of a ready Piece that exists at the base and is outside the inventory selects no such consumer, and its test arguments are the ones of `main` today.
- A Piece-only change of a Piece that is in the inventory selects the same tests as before (compare the test arguments on one example).
- The partition test and `python3 scripts/test-ci-change-class.py`, `scripts/test-merge-queue.py` and `scripts/test-ci-skip.py` pass.
- This is not a Piece-only change: the hosted full check on the exact head of the pull request passes. Run `mix check` or the hosted run as AGENTS.md says for a shared path, and `git diff --check`. Record exact commands and exit codes.
- The two documents describe the gate as it now is, in the place where they describe it today: which Piece gets the consumer, that only its own tests run there, the limit and its basis if one is set, and what the gate still does not see (a changed Piece that was ready at the base is not exported before the merge; the tests of the dependencies do not run in the consumer of the new Piece).

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6. The pull request closes issue #328 as well.
