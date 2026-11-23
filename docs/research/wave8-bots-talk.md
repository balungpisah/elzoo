# Wave 8 bots-talk root acceptance

## Scope

ELZ-349 ([issue #835](https://github.com/balungpisah/elzoo/issues/835)) is the mandatory Wave 8
root consumer acceptance (Level 3 of [the Wave 8 plan](../plans/bot-platform-wave8.md)). It adds
no Piece, runtime, provider or generic framework. It calls the public interfaces of the five
Wave 8 Pieces, `delivery/durable-mailbox`, `workflow/turn-policy`, `workflow/delegation`,
`workflow/work-item` and `delivery/room`, together with the ready `assembly/run-engine`,
`workflow/run-approval-release` (the engines' Run owner), `workflow/agent-loop`,
`workflow/typed-decision`, `workflow/version-pin`, `state/recipe-store` with `state/artifact` and
`integration/object-store`, `domain/principal`, `domain/authorization`,
`workflow/untrusted-content`, `delivery/effect-intent` and `state/tenant-isolation`. No Piece was
edited. Every grant that the application role needed is in the owning Piece's README; the Store
grants follow ELZ-323's `grant_store!/2`.

One Contract sentence was corrected during the build, before the first release (coordinator
decision A on the issue). Case 4 had said that after the `wake` at the child-start tool deadline
"A's turn reads three failed tool results and finishes". The ready engine does not report an
expired slot to the nested callable that asked it: an input that settles no slot is given "to the
root pattern only" ([run-engine README](../../pieces/assembly/run-engine/README.md), lines
502–503), and the expiry pass drops the callable of each slot it settles. Case 4 now states what
the engine does, and the test asserts it: A's turn stays `running`, with no second model call and
no post, and settles `expired` at the `wake` at its own deadline. The task gains the matching
Limit and a kept-open engine option. The engine is unchanged.

Files: [test/wave8_bots_talk_test.exs](../../test/wave8_bots_talk_test.exs) and the bounded fixture
[test/support/wave8_bots_talk_helper.exs](../../test/support/wave8_bots_talk_helper.exs). The
helper copies ELZ-338's `app_role!/0`, `role_facts/1`, `role_guard!/1`, `grant_store!/2`,
`engine_on_app!/2` and `store_on_app!/2`. It requires the run-engine and recipe-store test
helpers, uses their fixture functions only for the construction that it copies, and changes no
Piece's test helper.

## Fixture

- Two Repos on the worker's disposable PostgreSQL 16 database. The owner Repo connects as the
  session role (a non-superuser) and runs the installs and grants, reads the catalog, and reads
  the tables that are not under row security. The application Repo's `after_connect` runs
  `SET ROLE` to `ELZOO_TEST_APP_ROLE` (ELZ-285). Every Piece call other than the installs runs
  on the application Repo, and every RunEngine, recipe-store and artifact Store is on it.
- Fail, never skip: `setup_all` flunks when `ELZOO_TEST_APP_ROLE` is unset or is not
  `elzoo_app`. It also flunks when the application connection's `current_user` is not that role,
  equals the session role, holds the owner's privileges, or is a superuser, `BYPASSRLS`,
  `LOGIN`, `INHERIT`, `CREATEROLE` or `CREATEDB` role. The setup test also shows that the guard
  fails for an unset variable, `elzoo_test` and `postgres`.
- One shared schema holds the mailbox and work-item installs (one each, from consumer
  migrations), so T1's and T2's rows are in the same tables. Each tenant has its own engine
  schema with one Run owner, an evidence writer and the intent Stores. The recipe store has its
  own schema and an artifact bucket on MinIO. Each tenant has three checked versions; `v1` is
  published at the start, and `v2` is published during the cases.
- Grants. The setup test reads, as the owner, that `elzoo_app` and `PUBLIC` hold exactly the
  following, with no column grant, and that `elzoo_app` owns no table:

  | Tables | Grant | Source |
  | --- | --- | --- |
  | `elzoo_mailbox_chains`, `_links`, `_messages` | `SELECT, INSERT, UPDATE` | durable-mailbox README |
  | `elzoo_work_items` | `SELECT, INSERT, UPDATE` | work-item README |
  | Store heads and outbox (each engine schema and the recipe store) | `SELECT, INSERT, UPDATE` | ELZ-323 `grant_store!/2` |
  | Store records and checkpoints (the same schemas) | `SELECT, INSERT` | ELZ-323 `grant_store!/2` |

  plus `USAGE` on each schema. In the fixture, before the first call, `DurableMailbox.verify/1`
  of both mailbox bindings and `WorkItem.verify/1` pass as `elzoo_app`.
- Principals are `domain/principal` values from pinned test identities. In T1 they are Ann
  (`:human`), the room service (`:service`, the root of every lineage) and the room bots A, B
  and D (each an `:agent` delegated from the service; A holds `files.read` and `files.write`).
  The child bots' principals are built only by `Delegation.grant/2`. In T2 there are Cara, a
  room service and bot T.
- Harness code, as the task names it: the wrapper from an agent-loop finish to
  `elzoo.room.answer` (an `answered` finish gives the answer JSON of its last model result;
  anything else gives the no-answer), the per-turn spec ID, the decision binding of `:decided`
  to a real `workflow/typed-decision` step, the child-start `tool_call` binding, the
  parent-close application, the bookkeeping that maps an item to its child-start slot, the
  idle-checked delivery to a child's own chain, the echoing local work of the carry, the `wake`
  timer, and the host loop that delivers, wakes, rolls over and resumes.
- Engines. The run-engine fixture hosts one engine at a time, so the harness copies its
  construction. There is one Run owner per tenant for the room tips and their children, with
  `attach_child` given `child_pid: nil`. A Unit directory routes each offer to the engine of its
  Unit identity. A per-tenant re-entrant lock runs one Run-owner command at a time: one engine
  input or one harness Run command, because the owner's revision covers its whole stream.
- One shared test clock is the engines' clock and the room's clock. The slot deadlines are tool
  20,000 ms, effect 100,000 ms and turn 200,000 ms; the Run deadline is 1,000,000 ms after the
  start; the margin is 1,000 ms.

### The reserve (Q8 A)

The bot recipes, as the script bounds them: each agent loop has `turn_limit` 3, and a scripted
model result proposes at most 4 tool calls, each of which may need one store action. A typed
decision has one repair.

- One turn: actions = 3 model calls + 2 × 4 × (3 − 1) tool and store actions + 1 finish = 20;
  requests = 3 + 2 × (3 − 1) + 1 = 8.
- One decision: actions = requests = 1 + 2 = 3.
- The room's per-message reserve, with B = `max_bot_turns` 3: A = 3 × (2 + 20) + 1 = 67 actions
  and R = 3 × (2 + 8) + 1 = 31 requests, plus `d × (1 + 3)` under `"decided"`.
- Group 5 uses the request edge. With `request_cap` 40, a message is given while
  `request_count + 31 + 2 ≤ 40`. A simple turn costs 4 requests (turn, model call, finish and
  post), so after two messages, 8 + 33 > 40 and `deliver/3` returns `{:ok, :rollover}`.

## Cases

Each test names its group of the task. Model results are scripted per `{label, action_id}`, or
per `{label, member}` as a queue.

- **setup.** The role attributes, the guard refusals, `verify/1` of each binding, the exact grant
  map, and every Store on the application Repo (the engines of two opened rooms are checked when
  they start).
- **group 1, mail in.** An undeclared name and a payload that fails its schema are refused
  (`:undeclared_name`, `:invalid_payload`), and a T1-scope read finds neither row. Ann's second
  message, put while A's model call is held, gets `{:ok, :busy}`, stays `:pending`, and no
  `mail:` input reaches the engine. After the turn it is delivered and `:consumed` on link 1, as
  B's turn `t/1/2`. Two rooms: A's answers go to R2 and D's to R1 through the mailbox. D's
  three turns fill R2's bound, the fourth A turn in R1 is left out with one
  `bot_turn_bound` notice, and only A's three answers are posted to R2.
- **group 2, turns.** Ann addresses A; A mentions B; B answers and mentions A; then A's second
  turn, with new action IDs and no refused action. Three turns fill the bound with no notice.
  An A–B exchange stops at `max_bot_turns` with one notice, and Ann's next message resumes it.
  Escalation gives one notice and no bot turn after a peer's message until Ann writes. Handoff
  gives B the next unaddressed turn.
- **group 2, `:decided`** (R3, `max_bot_turns` 2, `rollover.max_turns` 3). A valid pick gives
  the turn to the picked bot. A schema-valid pick of a non-member falls back to
  `default_member`, with the `decision_fallback` note in the carry after the rollover. A mention
  asks no decision. Each decision ran the real typed-decision step: its model call and its
  finish.
- **group 3, delegation.** A's turn starts C, which is granted: C is delegated from the room
  service with the requested subset of A's scopes and the default rule, gets a work item
  `running`, is pinned to the tip's version (not `v2`, published after A's Run started) by pin
  record and `VersionPin` capture, and is attached to the tip's Run. Its result is recorded and
  its pin released when it ends; the item is `offered`, and `accepted` by A only at A's next
  model result. The refusals, each whole (no item, pin record, Run or engine), are escalation,
  cycle, stale (`root_epoch` 2), revoked (C proposes E while A, the middle bot of lineage
  [A, C], is revoked), budget (501) and depth (`max_depth` 1).
- **group 4, parent close.** A's turn starts three children with `:abandon`, `:request_cancel`
  and `:cancel`. The `wake` at their tool deadline settles the three `tool_call` slots
  `expired`, which ends each child's parent. A's turn stays `running`, with no `t/1/2:m:2` slot,
  no model call and no new post. `list_open/3` lists the three items (C's is final), and
  `on_parent_close/1` is applied with a host restart (bookkeeping dropped) after two actions.
  The restart's second pass gives `{:ok, :duplicate}` for the request, `{:ok, :unchanged}` for
  the listed `cancel_requested` item, and does not list the final items again. `:cancel`: one
  cancel control, `w1` settled not completed, and a late completed outcome changes nothing; the
  item is `cancelled`. `:request_cancel`: one message on the child's own chain, given only when
  idle; the child finishes, and its item goes `cancel_requested`, then `cancelled`.
  `:abandon`: the child finishes, its item stays `abandoned`, and its offer is
  `{:error, {:state, :abandoned}}`. No item stays open. A's turn still waits; the `wake` at its
  own deadline settles it `expired`, and the tip is idle with no post of that turn.
- **group 5, rollover.** The request edge gives `{:ok, :rollover}`; the tip asks its carry
  (`c/1/1`) and finishes. `rollover/3` of link 1 gives `{:ok, %{seq: 2, carry_kind: :finished}}`,
  with link 1 closed and one live link 2 on the fresh Unit `room/<h>/2`. A second `rollover/3` of
  link 1 is `{:error, {:not_tip, 2}}`. Mail addressed to link 1's Run ID, before and after the
  rollover, is given once each, to link 2, and never to link 1. After `v2` is published, the
  successor keeps `v1`. A crash after the mailbox step (the start Need fails once) gives
  `{:error, {:start, :host_crash}}` with no engine, and `resume/3` gives one start with the pin
  moved. Two concurrent rollovers of link 3, outside the one-deliverer Need, wait together on
  the chain row that the harness holds as `elzoo_app` (both seen waiting in `pg_locks`); after
  the release both answer `{:ok, %{seq: 4, carry_kind: :finished}}`, the later one replaying
  the committed step. The chain then has one link after link 3 and four links in all, link 4
  has one start, and `v1` stays pinned. A tip that started with a queued B turn from its carry
  (R1r) stalls in that turn and reaches its Run deadline with `out_of_time`. It rolls over
  `:restarted`, and the successor's start has an empty queue, the `restarted_queue_dropped`
  note, and no turn.
- **group 6, isolation.** T1 has R1 with one child; T2 has room S with one delivered message,
  one rollover and one child item. As `elzoo_app`, `ALTER TABLE … NO FORCE ROW LEVEL SECURITY`
  and `DROP POLICY elzoo_tenant_floor …` on `elzoo_mailbox_messages` and `elzoo_work_items` are
  refused. A read without a tenant predicate of `elzoo_mailbox_chains`, `_links`, `_messages` and
  `elzoo_work_items` finds a T2 row in T2's scope, none in T1's, and T1's own rows in T1's. In
  T1's scope, an insert of a T2 row into each of those tables is refused with SQLSTATE 42501.

## Environment and checks

- PostgreSQL 16.16 (Debian 16.16-1.pgdg13+1), and MinIO RELEASE.2025-09-07T16-13-09Z as the
  disposable S3 test server, on the worker's orb (4 vCPU, 7 GB).
- `elzoo_app`: `NOSUPERUSER`, `NOBYPASSRLS`, `NOLOGIN`, `NOINHERIT`, `NOCREATEROLE`,
  `NOCREATEDB`, without the session role's privileges (read by the setup test).
- `MIX_ENV=test mix test test/wave8_bots_talk_test.exs --trace`: 7 tests, 0 failures. The times
  of the acceptance module are in the pull request body. Every test is well within the root
  suite's per-test limit of 120,000 ms, so no test sets `@tag timeout:`.
- The local gate, `mix check --affected origin/main` and `git diff --check`, and the roadmap and
  claims checks, with their exit codes, are in the pull request body.

## Harness negative controls

Each control was one temporary edit in the worktree, run, recorded and reverted with
`git checkout`; none was committed. The final passing run came after all five were restored.

1. The application Repo without `SET ROLE`. With the guard on, `setup_all` fails: "the
   application connection is not the non-owner application role elzoo_app" (`current` is the
   session role), and all 7 tests are invalid. With the guard off for that run only (the role
   guard and the per-Store check made no-ops), group 6 fails at
   `ALTER TABLE … NO FORCE ROW LEVEL SECURITY`, which the owner may run.
2. Mail given through `input/4` without the room's idle check (the harness calls `input/4`
   with `mail:m-2` while A's model call is held). Group 1 fails:
   `refute "mail:m-2" in H.inputs(w, run)`, because the engine holds `mail:m-2` mid-turn.
3. `max_bot_turns` 9 in R1 and R2, above the scripted exchange. Group 2's bound case fails (the
   A–B exchange goes on past three turns), and the two-room bound in the group 1 test fails
   (more A turns follow R2's posts).
4. The child-start binding without `Delegation.grant/2` (a grant built from the facts with no
   check). Group 3 fails: the refusals list is `[]`, not the six refusals.
5. The successor started on the old Unit identity (the start Need maps `room/<h>/<seq>` to
   `room/<h>/1`). Group 5 fails at the first `rollover/3`: the Unit directory answers
   `{:error, {:already_started, _}}`, so no successor starts.

## Limits

The task's "Limits to state" are the full list; this report adds nothing to them. In short:
model results are scripted, so there is no claim about answer quality, a pick or a model
following a turn. The reserve is the worst case of the scripted recipes. The harness code named
above is harness code. Identities are pinned test identities, and every principal, revocation,
epoch and authority fact is host-built. A cancel request reaches only an idle child, and a cancel
of an Attempt does not stop a sent Effect. An expired tool slot is not reported to the nested
callable that asked it, so a bot's turn whose tool calls expire waits until its own deadline. A
room gives a message at most once per Run, not end to end. The concurrent-rollover case is
outside the room's one-deliverer Need and shows only the mailbox's guards. One tenant's
recipe-store stream bounds its Runs (#821). Mail, carries and intents have no erasure in Wave 8.
The RunEngine Stores, the recipe-store stream and the artifact records are not under row
security. `log: false` silences only the Logger. READ COMMITTED is a consumer Need. The shared
Run owner serializes its commands. The restarts are a host's bookkeeping dropped or a Need
failing in one VM, not a database restart. Races inside one Piece are that Piece's tests. These
are finite scenarios, not proofs, and no complete-Wave claim is made.
