# ELZ-233 — Three small repairs: the SQL grounding names a page for each part, the engine fixture stops its intents before it drops the schema, and the provider-stream helper waits for the frame or the end of the run

- Dependencies: ELZ-009, ELZ-033, ELZ-143
- Output: none. Three repairs in place on the ready Pieces `integration/sql`, `assembly/run-engine` and `delivery/provider-stream`. No Contract changes. The Piece IDs stay.
- Change class: Piece-only implementation, in place on ready Pieces; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/integration/sql/piece.json`; the index and generated changes of AGENTS.md section 3 for `integration/sql` (the `manifest_sha256` of its row); `pieces/assembly/run-engine/test/**`; `pieces/delivery/provider-stream/test/**`. No file of any `lib/`, no README, no other `piece.json`.

Three findings are open, and each one is small. Issue #500: one upstream
grounding of `integration/sql` claims more than its page covers. Issue
#505: a test of `assembly/run-engine` failed once with a PostgreSQL
deadlock in its teardown. Issue #511: a test of
`delivery/provider-stream` failed twice in the full local check at a
fixed 2,000 ms window of its helper. The three share one task because
each is low risk, none changes a Contract, and they take one gate: the
small gate for `integration/sql` already selects the other two Pieces as
dependants.

Each part below is complete in itself. Make one commit for each part, so
that a part can be reverted alone.

Nothing in this task text was run. Every fact was read on `main`. The
lines are "about N". Confirm each fact when you start, and if one
differs, stop and ask.

## 1. Issue #500: the SQL grounding names a page for each part

Facts checked on `main`:

- `pieces/integration/sql/piece.json`, about 65 to 70: one grounding with
  `"kind": "upstream"`, `"provider": "postgrex"`, the reference
  `https://www.postgresql.org/docs/16/transaction-iso.html` and the claim
  "PostgreSQL transaction atomicity, uniqueness, row locking, WAL/fsync
  and crash semantics are upstream server contracts reached through
  Postgrex, not local proofs."
- That page is the page on transaction isolation. Issue #500 says that it
  covers isolation levels, row locking and uniqueness under concurrency,
  and not the write-ahead log, fsync or the behaviour after a crash.
- An upstream grounding holds one `reference`, a string that starts with
  `https://`, and a `provider` that is listed in `providers`
  (`lib/elzoo/registry.ex`, about 225 to 231). So two pages need two
  groundings.
- The page `https://www.postgresql.org/docs/16/wal.html` has the title
  "Chapter 30. Reliability and the Write-Ahead Log". Only its title was
  read.
- The README of the Piece does not repeat the claim. The `contract`
  string does not hold it.

Repair:

1. Open both pages and read them. Confirm that the first covers
   isolation, uniqueness under concurrency and row locking, and that the
   second (with its sections) covers the write-ahead log, fsync and
   recovery after a crash. If a part of the old claim has no page, stop
   and ask.
2. Replace the one grounding by two, at the same place, both with
   `"kind": "upstream"` and `"provider": "postgrex"`:
   - reference `https://www.postgresql.org/docs/16/transaction-iso.html`,
     claim "PostgreSQL transaction isolation, uniqueness and row locking
     are upstream server contracts reached through Postgrex, not local
     proofs."
   - reference `https://www.postgresql.org/docs/16/wal.html`, claim
     "PostgreSQL commit atomicity and durability through the write-ahead
     log, fsync and crash recovery are upstream server contracts reached
     through Postgrex, not local proofs."
3. Change nothing else of `piece.json`. The `contract` string stays, so
   the `note` of the index row stays. `manifest_sha256` follows the new
   bytes, in the last commit (AGENTS.md section 3).

Acceptance:

- **`each_part_has_a_page`**: every part of the old claim (atomicity,
  uniqueness, row locking, WAL/fsync, crash) is in exactly one of the two
  claims, and the page of that claim covers it. The reviewer opens both
  pages.
- **`nothing_else_moved`**: the diff of `piece.json` holds only these
  lines. No claim got stronger: both still say "not local proofs".
- No negative control: this part has no test of its own. The Registry
  and ledger checks of the gate read the file.

## 2. Issue #505: the engine fixture stops its intents before it drops the schema

Facts checked on `main`:

- The failure, from the log of issue #505: the error `40P01` was raised
  in an `on_exit` callback of the test "a refused parent slot still gets
  its later actual, with the rows of main"
  (`pieces/assembly/run-engine/test/elzoo/run_engine_test.exs`, about
  3819). One backend waited for `AccessExclusiveLock` on one relation.
  The other backend held a lock on that relation and waited for
  `RowExclusiveLock` on a second relation, which the first one held.
- `fixture/1` (`test/support/run_engine_test_helper.exs`, about 296) has
  one `on_exit` (about 601 to 610). It stops `run` and `evidence` with
  `GenServer.stop/1` and then runs `DROP SCHEMA IF EXISTS ... CASCADE`
  for the schema of the fixture.
- ExUnit ends the test supervisor first and runs the `on_exit` callbacks
  after it, in the reverse order of their registration
  (`ExUnit.OnExitHandler.run/2` of ExUnit 1.20.4). So every process that
  the fixture starts with `start_supervised!` is down before the drop.
- The engine starts an `Elzoo.EffectIntent` process for an Effect with
  `EffectIntent.start_link/1` and unlinks it at once
  (`lib/elzoo/run_engine.ex`, about 2118 to 2121). It keeps the PID in
  its own process state only (`intents`, about 1203). The engine has no
  `terminate/2`. So this process lives on after the engine and after the
  test supervisor.
- The intent gets its options from the `startup` function of the fixture
  (about 369 to 394), through `effect_intent: intents` (about 576). Its
  store is in the schema of the fixture.
- The intent writes when its adapter task ends. A reply of the task is
  appended as a result
  (`pieces/delivery/effect-intent/lib/elzoo/effect_intent.ex`, about 298
  to 313). A task that goes down is appended as `Lost` (about 317 to
  331). The task runs under the task supervisor of the fixture with
  `shutdown: :brutal_kill` (about 262 to 270).
- The failing test ends with `send(provider, {:result, %{}})` (about
  3904). So the task returns and the intent appends after the test
  process has ended. 24 lines of the test file send a result to a
  provider task.
- An append of the SQL store is one transaction. It touches
  `elzoo_log_heads` first and `elzoo_log_records` after it
  (`pieces/integration/sql/lib/elzoo/durable_log/postgres.ex`, about 562
  to 567 and about 610). The drop takes an exclusive lock on each table.
  When the drop comes between the two statements, each side waits for
  the other. This fits the two lines of the log; the relation numbers
  could not be mapped to tables.
- The intents that `run` starts are stopped by `Run.terminate/2`
  (`pieces/workflow/run-approval-release/lib/elzoo/run_approval_release.ex`,
  about 821 to 824), so the `GenServer.stop(run)` of the fixture covers
  them.
- The `authorize` function of the fixture (about 383 to 389) is called
  inside the intent process, during its `init/1`: `init/1` calls
  `activate/3` (`effect_intent.ex`, about 63 and 85 to 86), which calls
  `StoreHost.activate/2` (`effect_intent/host.ex`, about 36 to 40), which
  calls `authorize`. So `self()` in that function is the PID of the
  intent.
- Nothing in the copied consumer differs from the root project: the same
  test file and the same helper run there. The cause is timing.

Repair, in `test/support/run_engine_test_helper.exs` only:

1. The fixture remembers the PID of each `Elzoo.EffectIntent` process
   that is started with its startup options. One way that the facts
   above allow: a process of the fixture that is not under the test
   supervisor (started and unlinked like `run`, about 403 to 404) holds
   the PIDs, and the `authorize` function adds `self()` to it. Another
   way is accepted when it finds every such process and no process of
   another test.
2. The `on_exit` of the fixture stops each remembered process that is
   alive with `GenServer.stop/1` and waits for it, before the `DROP
   SCHEMA`. A process that ends between the check and the stop is not a
   failure of the teardown. Then it stops the process of step 1.
3. Change nothing else: no retry of the drop, no `LOCK TABLE`, no sleep,
   no change of an assertion, no change of `lib/`.

`GenServer.stop/1` returns when the process has ended. A write that the
intent began before the stop is finished by then; a message that it had
not yet read is never read. So no intent of the fixture writes after the
stops return.

Acceptance, in the existing group `Intent recovery windows` of
`test/elzoo/run_engine_test.exs`, so the test claim of `piece.json`
stays as it is:

- **`teardown_stops_the_intents`**: a test registers an `on_exit` of its
  own **before** it calls `fixture/1`, so that it runs after the one of
  the fixture. The test starts an engine and one `tool_call`, and waits
  for `{:effect_started, provider, _}`. It learns the PID of the intent
  while the engine is live (one way: `:sys.get_state/1` of the engine,
  key `intents`). It sends `{:result, %{}}` to the provider task, waits
  for the end of that task, and reads the state of the intent once, so
  that the intent has taken the reply and is idle. It hands the PID to
  its `on_exit` through a process of its own that is not under the test
  supervisor. The `on_exit` asserts that the intent process is not alive
  and that the schema of the fixture does not exist. A failure in
  `on_exit` fails the test.
- **`existing_behaviour`**: every existing test of
  `assembly/run-engine` and of `runtime/recipe-test` passes with an
  empty diff of its body.

Negative control, by a temporary edit that is reverted and never
committed: with the stops of step 2 removed,
`teardown_stops_the_intents` fails, because the intent process is alive
after the teardown. Record the failing output.

Write under `Assumptions:`: the deadlock of issue #505 was seen once and
this task does not make it on demand. That it cannot occur again follows
from the order of the teardown; no test shows it.

## 3. Issue #511: the provider-stream helper waits for the frame or for the end of the run

Facts checked on `main`:

- `Fixture.release/2`
  (`pieces/delivery/provider-stream/test/support/provider_stream_test_helper.exs`,
  about 120 to 133) receives `{:held, frame, pid}` with `after 2_000 ->
  raise "frame missing"` (about 131). No comment gives a reason for
  2,000 ms. It is not a limit of the Piece.
- The inner window `window.(frame)` (about 123 to 127) is another thing:
  it shows that no second frame is offered while one is held. It stays.
- `Fixture.run/4` (about 135 to 139) runs
  `Elzoo.ProviderStream.run/4` in a `Task.async`. The first frame needs
  one whole HTTP/1.1 request to the loopback peer.
- The run has a deadline of its own: `total_timeout_ms`, counted from
  the entry of `run/4` (`lib/elzoo/provider_stream.ex`, about 48). At the
  deadline it ends with `{:incomplete, :timeout}` (about 131 to 132).
  `Fixture.settings/1` gives 5,000 ms (about 84). So a correct run can
  give its first frame later than 2,000 ms, and every run ends.
- `release/2` has three call sites in
  `test/elzoo/provider_stream_test.exs`: about 35, 189 and 483. Each has
  the task of `Fixture.run/4` in a variable.
- The failures of issue #511: two full local checks on a loaded host,
  seed 0, the test at about line 24 (the first of its file), early in
  the async phase. Alone the tests passed 31 of 31 times.
- The other receives of the helper are no time windows:
  `holding_sink/0` (about 104 to 114) has no `after`, and `offered/0`
  (about 158 to 164) uses `after 0` to empty the mailbox.
- `integer?(c.receive_timeout_ms, min(30_000, c.total_timeout_ms))`
  (`provider_stream.ex`, about 72): a test may give a larger
  `total_timeout_ms` and `receive_timeout_ms` through
  `Fixture.settings/1`.

Repair, in the two test files only:

1. `release` takes the task as its first operand. It waits with no
   window of its own for one of two events: the next `{:held, frame,
   pid}`, or the reply of the task (the message `{ref, result}` with the
   `ref` of the task). On the reply it raises an error that names the
   result and the number of frames that were still wanted. Everything
   else stays: the inner window, the order, the returned list.
2. The three call sites pass their task. No other line of an existing
   test changes.
3. Write one comment at the wait: the run ends by its own
   `total_timeout_ms`, so the wait ends on an event and needs no time.
4. Change no setting of `Fixture.settings/1`, no `assert_receive` and no
   `refute_receive`.

Acceptance, new tests in the existing group `text_only`:

- **`late_first_frame_is_collected`**: the peer waits 2,500 ms before it
  writes the head of its response, and then sends `text.sse` whole. The
  settings are `total_timeout_ms: 30_000` and `receive_timeout_ms:
  10_000`, with the holding sink. `release` returns the 25 frames in
  order and the run is `{:complete, _}`. The time is certain here and
  not a matter of load.
- **`run_that_ends_early_is_named`**: against the peer that answers 529
  (as in the existing test at about 384 to 397) and with the holding
  sink, `release(task, 1, ...)` raises, and the message holds
  `{:refused, :overloaded}`.
- **`existing_behaviour`**: every existing test of the Piece passes. Its
  body is unchanged but for the task operand at the three call sites.

Negative control, by a temporary edit that is reverted and never
committed: with `after 2_000 -> raise "frame missing"` back in
`release`, `late_first_frame_is_collected` fails with "frame missing".
Record the failing output.

Write under `Assumptions:`: the failure under the load of the full local
check was not made again in this task. The limits of the run itself
(`total_timeout_ms`, `receive_timeout_ms`, `ack_timeout_ms` of the
fixture) are unchanged; a run that ends by one of them under load now
fails with its result named. If you see such a failure, record it on
issue #511 and change no setting.

## Evidence and gate

Run the tests of each part while you build:

    mix test pieces/assembly/run-engine/test
    mix test pieces/delivery/provider-stream/test

On the final head, run
`mix test pieces/delivery/provider-stream/test --repeat-until-failure 30`
and record the command and its exit code. Then run the local gate:

    mix check --piece "$(git merge-base origin/main HEAD)"
    git diff --check "$(git merge-base origin/main HEAD)"

The small gate selects `integration/sql` and every ready Piece that
depends on it, so it needs the PostgreSQL service. If a command cannot
run on the host, record the command and the exact reason under `Local
gate:`. The index row of `integration/sql` follows in the last commit
(AGENTS.md section 3). Record in the pull request body the time that the
new tests add (about 3 s for part 3).

The pull request closes this task and the issues #500, #505 and #511.

## Review risk

Low. One independent review, risk normal. The reviewer checks:

- part 1: that each of the two pages covers its claim, and that no other
  byte of `piece.json` changed;
- part 2: that the fixture finds every intent of its own Run and none of
  another test; that the stops come before the drop; that no assertion
  and no file of `lib/` changed;
- part 3: that `release` has no time of its own left, that the inner
  window is as before, and that the three call sites changed by one
  operand only;
- that no test was weakened: no assertion removed, no limit of a run
  changed, no test tagged or skipped.

## Not in scope

Part 1: any other grounding of `integration/sql` or of another Piece;
the README of the Piece.

Part 2: whether the engine should stop its intents when it stops (a
question of the product, issue #514; the engine file is not edited
here); the
`DROP SCHEMA` of any other test helper; a retry on a deadlock.

Part 3: the limits of `Fixture.settings/1`; the `assert_receive` lines
with 2,000 ms and 3,000 ms of the test file; the plain windows in the
tests of other Pieces.

Also not here: any file of `lib/`, any README, and any other Piece.
