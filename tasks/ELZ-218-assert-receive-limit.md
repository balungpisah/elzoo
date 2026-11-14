# ELZ-218 — `assert_receive` with no limit waits 5,000 ms in the root suite and in the copied consumers

- Dependencies: ELZ-033
- Output: none. A harness repair; no Piece Contract changes.
- Change class: non-Piece root/shared harness repair (`test/**`). Local gate `mix check --affected origin/main` and `git diff --check`; full hosted check. No selected-gate shortcut.
- Allowed implementation path: `test/test_helper.exs`, `test/support/cure_consumer_case_test_helper.exs`, and one root test file under `test/` for the two scenarios below (a new small file, or `test/export_test.exs`). No file under `pieces/`, no `lib/`, no `mix.exs`, no workflow.

Why. A test that says `assert_receive pattern` with no limit waits 100 ms,
the default of ExUnit. Such a line asserts that a message arrives. It
asserts no time. On a loaded host 100 ms is sometimes too short: issue
#420 (`runtime/dynamic-units`, inside the copied consumer of all sources)
was repaired line by line in ELZ-189, and the same shape is in about 400
other lines. One setting repairs the catalogue's own runs at once.

Facts checked on `main` (confirm each when you start; if one differs, stop
and comment on the issue):

- ExUnit of the pinned Elixir 1.20.4 has two separate options:
  `assert_receive_timeout` and `refute_receive_timeout`, each with the
  default 100 (`ExUnit.configure/1` documentation; `assert_receive` reads
  the first, `refute_receive` the second). `assert_received` and
  `refute_received` do not wait at all.
- `test/test_helper.exs:14-19` starts ExUnit with `seed`, `timeout`,
  `max_cases` and `exclude`, and with neither option.
  `pieces/test_helper.exs` only loads that file.
- `test/support/cure_consumer_case_test_helper.exs:168-174` writes the
  `test/test_helper.exs` of each copied consumer: `ExUnit.start(seed: 0,
  timeout: <ms>)` or `ExUnit.start(seed: 0)`. The aggregate consumer and
  the per-ID consumers run Piece tests under this helper. The failure of
  issue #420 was there.
- Count on `main` over `test/` and `pieces/` (a call counts as explicit
  when it has a second argument): `assert_receive` about 400 with no limit and
  about 180 with one; `refute_receive` about 71 with no limit and about
  146 with one (two counts differ by a few; count again when you start
  and record your numbers). The
  largest groups with no limit: `assembly/run-engine` 91,
  `delivery/effect-intent` 40, `runtime/async-work` 39,
  `runtime/durable-unit` 38, `runtime/dynamic-units` 28,
  `delivery/retry-timeout` 25, `workflow/run-approval-release` 22, root
  `test/` 15. Explicit limits in use are 1,000 to 30,000 ms; 5,000 is the
  most frequent (72 lines), and ELZ-189 chose it.
- No test was found whose assertion is that a message arrives inside the
  100 ms default. Two default calls stand near timing code and measure the
  time by other means:
  `pieces/assembly/http-job/test/elzoo/http_job_test.exs:296` (an
  `elapsed_ms` field) and
  `pieces/delivery/retry-timeout/test/elzoo/retry_runner_test.exs:452`
  (`:timer.tc` on a later call). No `assert_raise ExUnit.AssertionError`
  wraps an `assert_receive`.
- Four more places start ExUnit and are outside this task:
  `test/export_test.exs:135` (the consumer of `runtime/unit`, whose tests
  have no such call), and three files of Pieces (see "Not in scope").

## Task

1. In `test/test_helper.exs` add `assert_receive_timeout: 5_000` to
   `ExUnit.start/1`. Add no `refute_receive_timeout`.
2. In the generated helper of the copied consumers add the same option to
   both forms of the text. Give the text one place (for example one
   function of `Elzoo.CureConsumerCase` that returns it), so that a test
   can read it.
3. Change no test of a Piece, no explicit limit, no `timeout` of a test
   and no tag.

The value. A longer limit costs time only in a test that fails. 5,000 ms
is far below each per-test limit (60,000 ms default in a consumer,
120,000 ms in the root suite).

## Acceptance

- `receive_limits` (root test, committed): `assert_receive` with no limit
  receives a message that `Process.send_after/3` sends after 300 ms; and
  `refute_receive` with no limit returns before a message that is sent
  after 300 ms arrives. The second half shows that `refute_receive` did
  not get longer.
- `consumer_helper_text` (root test, committed): both forms of the
  generated helper hold `assert_receive_timeout: 5_000` and neither holds
  `refute_receive_timeout`.
- Negative control: with the option removed from `test/test_helper.exs`
  by a temporary edit, the first half of `receive_limits` fails with "no
  matching message after 100ms"; revert the edit.
- Evidence in the pull request body: the two counts above, before and
  after. They must be equal: the diff changes no call.
- The count of tests and of excluded tests of the full check is as before,
  plus the new tests; show both numbers.
- `mix check --affected origin/main` exits 0 (take the one slot of the
  database server), `git diff --check` exits 0, and the full hosted check
  is green on the exact head.
- One independent review.

## Review risk

Low for behavior: a passing test stays passing. The risk is a test that
relied on a short wait to fail fast; the reviewer repeats the search for
such a test. A failing default `assert_receive` now costs 5 s, not 0.1 s.

## Limits

This repairs the runs of the catalogue only. A developer who copies a
Piece runs its tests under the helper of the application, with the 100 ms
default. Explicit limits in the tests of a Piece, as in ELZ-189, are the
repair for that and are separate Piece tasks.

## Not in scope

`refute_receive`; explicit limits; the three helpers that Piece tests
write for their own copies
(`pieces/integration/observability/test/elzoo/observability_copy_test.exs:23`,
`pieces/delivery/data-stream/test/test_helper.exs:2`,
`pieces/delivery/circuit-breaker/test/elzoo/circuit_source_copy_test.exs:136`);
the Ash spike; the text that `mix elzoo.take` prints for a consumer.
