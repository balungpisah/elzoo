# delivery/room

`Elzoo.Room` hosts a **room** as the continuation chain of `delivery/durable-mailbox`: each
link of the chain is one Run of `assembly/run-engine` on its own Unit, and that Run's root
pattern is `workflow/turn-policy`. The room gives the tip one mail message at a time, and only
while the tip's Run is idle. It gives the tip its rollover message before a message whose worst
case could pass the engine's bounds. It runs the rollover sequence (result, settlement, pin, the
mailbox's atomic step, the successor's start, the old unpin) so that every step can be repeated
after a crash. Version pins are records of `state/recipe-store`.

One Assembly in plain Elixir over the public interfaces of those four Pieces. It has no table,
process, timer or state of its own, retries nothing, logs nothing and emits no telemetry. It
starts no child Run and applies no parent-close rule: a bot's turn starts children through a
host `tool_call` binding, and the host applies `workflow/delegation`'s `on_parent_close/1` to the
items that `workflow/work-item`'s `list_open/3` lists for the ended Run.

## Copy and providers

Select `delivery/room` with `mix elzoo.take`; the dependency-closed copy is owned by the
consuming application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`delivery/durable-mailbox`, `workflow/turn-policy`, `assembly/run-engine` and
`state/recipe-store`. Providers: `elixir` and `otp` (`:crypto` SHA-256 for the IDs). The room's
library calls no `workflow/run` and no `workflow/version-pin` function: the host's `start` Need
builds the engine and its pinned capture.

## Interface

Every function takes the binding, the tenant and one request map, except `new/1`. Request maps
have exactly the keys listed.

- `new(opts)`: `{:ok, room}` or `{:error, :invalid_binding}`. `opts` is exactly:
  - `mailbox:` a binding from `Elzoo.DurableMailbox.new/2`; `recipes:` an `Elzoo.RecipeStore`
    value and `principal:` its caller principal (the caller of `pin/4` and `unpin/4` is
    `%{tenant: tenant, principal: principal, scopes: []}`); `turn_policy:` the state from
    `Elzoo.TurnPolicy.new/1`, the one the `start` Need gives the engine as the root pattern's
    initial state;
  - `start:` the Need `fun(tenant, %{unit_identity, run_id, pin, request_cap})`: it starts a
    RunEngine host for that Run on that Unit with that pin and `request_cap`, the turn-policy
    root pattern and the bindings below, and returns `{:ok, %{engine, scope, run_deadline}}`
    or `{:error, reason}`. For a Run already started on that Unit it returns the same and
    starts nothing;
  - `engine:` the Need `fun(tenant, %{unit_identity, run_id})`: `{:ok, %{engine, scope,
    run_deadline}}` for a started Run, `{:error, :not_started}` or `{:error, reason}`.
    `engine` is the server that `Elzoo.RunEngine` calls take, `scope` the exact reader scope
    and `run_deadline` the Run's deadline in Unix ms;
  - `clock:` a trusted zero-arity positive Unix-millisecond clock;
  - `request_cap:` 1..256;
  - `reserve:` exactly `%{turn: %{actions, requests}, decision: %{actions, requests},
    deadline_margin_ms}`: the worst case of one turn of the host's bot recipes and of the
    host's decision binding, as the actions and requests that the turn's (or decision's)
    `nested_callable` and every callable under it ask, as the engine counts them (0..256
    each); `deadline_margin_ms` 1..2^31−1;
  - `read_limits:` exactly `%{max_records, max_bytes}`, given to `result/3` and
    `transcript/3`.
- `open(room, tenant, %{chain_id, start, pin})`: `{:ok, %{run_id, unit_identity}}` of link 1.
- `deliver(room, tenant, %{chain_id})`: gives the tip at most one input. `{:ok, :delivered}`,
  `{:ok, {:refused, reason}}`, `{:ok, :rollover}`, `{:ok, :empty}`, `{:ok, :busy}` or
  `{:ok, :terminal}`.
- `wake(room, tenant, %{chain_id, wake_id})`: the route of the host's `wake` timer. For an idle
  tip it does what `deliver/3` does, then gives a v1 `wake` input under `wake_id`, and returns
  what `deliver/3` returns. A tip that is not idle gets the wake at once and the result is
  `{:ok, :busy}`; a terminal tip gives `{:ok, :terminal}`.
- `rollover(room, tenant, %{chain_id, link_seq, change})`: the rollover sequence of the
  terminal tip `link_seq` (1..2^31−1), `change` `nil` or `%{pin, ref}` (`ref` the host's
  authorised, recorded action). `{:ok, %{seq: successor_seq, carry_kind: :finished |
  :restarted}}`, or `{:error, {:not_tip, seq}}` when the tip is link `seq` instead.
- `resume(room, tenant, %{chain_id})`: finishes the tip's start (and, for a link after the
  first, the predecessor's unpin). `{:ok, :live}` or `{:ok, :terminal}`.

Fields: `tenant` 1..64 bytes of `[A-Za-z0-9._-]`, not `.` or `..`; `chain_id` 1..128 bytes of
valid UTF-8 without a C0 or C1 control character; `pin` and `change.pin` a recipe-store
identity `recipe-package-v1:sha256:<64 hex>`; `change.ref` 1..256 bytes under the text rule;
`wake_id` 1..160 bytes under the text rule that does not begin with `mail:`, `start:` or
`rollover:`; `start` a decoded `elzoo.room.start` v1 payload. Anything else is
`{:error, :invalid}`, before any call.

**IDs.** The Run ID and the Unit identity of link `seq` are both `room/<h>/<seq>`, `h` the
lowercase hex SHA-256 of the tenant, one NUL byte and the chain ID: at most 80 bytes. Every link
has a fresh Unit, so the engine's lifetime action count of one link is never carried into the
next, and two tenants' chains with one ID never share a Unit. Engine input IDs are
`start:<run_id>`, `mail:<message_id>` and `rollover:<run_id>`. A start input is the v1 `start`
of schema `elzoo.room.start` v1 with the link's carry as payload; a mail input the v1 `message`
of the mail's name and schema version with its payload; the rollover input the v1 `message` of
`elzoo.room.rollover` v1 with payload `{}`. Each input's context is `%{run_id, attempt_id}`
from the `status/1` read before it.

**Idle.** `status/1` has `reconciliation` `nil`, `phase` `:active`, `generation_closed`
`false`, `stop_pending` `nil` and every slot `:settled`.

**The per-message reserve.** For the tip's start payload, with `B` its `max_bot_turns` and `d`
1 when its rule is `"decided"` or a host rule name and 0 for `"addressed"`, `"round_robin"` and
`"everyone"`:

    actions  A = B × (2 + turn.actions)  + 1 + d × (1 + decision.actions)
    requests R = B × (2 + turn.requests) + 1 + d × (1 + decision.requests)

**The threshold.** Before a message the tip is given its rollover message instead when
`map_size(slots) + A + 2 > 256`, `request_count + R + 2 > request_cap` or
`clock.() + deadline_margin_ms >= run_deadline`. The `+ 2` is the carry and the finish.

## Rules

Calls to the mailbox and the recipe store return their own reasons under a tag:
`{:error, {:mailbox, reason}}`, `{:error, {:pin, reason}}`, `{:error, {:unpin, reason}}`. A
refusal of the `start` Need or of a start input is `{:error, {:start, reason}}`; an engine
reply that is not a result below is `{:error, {:engine, reason}}` (`{:engine, :indeterminate}`
for `{:indeterminate, _}`); an exit of an engine call (its 60,000 ms limit, or a dead engine
process) is caught and is `{:error, {:engine, :no_reply}}`; a halted engine is
`{:error, {:engine, reconciliation}}`. Other errors: `:invalid`, `:invalid_binding` (only from
`new/1`), `{:invalid_start, reason}`, `:reserve`, `:not_started`, `:not_terminal`,
`:link_limit`, `{:not_tip, seq}`, `{:result, reason}`, `{:transcript, reason}`. Every function can be called again
with the same request after any error or crash.

**`open/3`:** (1) the shape; `check_start/2`; `link` 1; `carry` `null`; `A + 2 <= 256` and
`R + 2 <= request_cap` (`:reserve`): a refusal writes nothing. (2) For an existing chain the
room pins nothing and gives the mailbox's `open/3` the request, which compares the bytes: a
duplicate goes to step 5 while link 1 is the tip and otherwise returns link 1's IDs; a conflict
reads link 1 with `chain/3` and unpins the request's `pin` for link 1's Run ID unless link 1
holds that pin, then is `{:mailbox, :conflict}` (so a repeat after a step 4 release that did not
finish removes the record it left; an ordinary conflict has no such record, and the unpin
appends nothing). (3) `pin/4` of `pin` for link 1's Run ID. (4) The mailbox's
`open/3`; on a conflict (a chain that appeared after step 2) the room unpins its pin unless that
chain's first link holds this Run ID and this pin. (5) The `start` Need, then the start input.

**`deliver/3`:** (1) `chain/3`, the `engine` Need (`:not_started`), `status/1` (a halted engine
is an error, `:terminal` is `{:ok, :terminal}`, `classification` `:configured` is
`{:error, :not_started}`, a tip that is not idle is `{:ok, :busy}`). (2) A `stopped` tip or the
threshold: the rollover message, `{:ok, :rollover}`, and nothing is claimed. (3) `claim/3`:
`{:ok, :empty}`; mail named `elzoo.room.start`, `elzoo.room.rollover` or `elzoo.room.carry`,
mail whose `message_id` has the form of a turn ID (`t/<n>/<n>`), and `elzoo.room.message` mail
whose payload's `message_id` is not the mailbox's, are settled `{:refused, :invalid_input}` and
given to no engine; else the message is given under `mail:<message_id>`. (4) The reply:

- `{:ok, :applied}` or `{:ok, :duplicate}`: `status/1` again. A slot that is not settled, or
  the classification `:permit_new_work`, `{:request, _}`, `:over_cap`, `:invalid_request`,
  `:invalid_pattern_state`, `:duplicate`, `:applied` or `:incompatible`, settles `:applied`;
  `:record_size` settles `{:refused, :record_size}` (the link stops); every other
  classification (`{:request_outcome, _}`, `:late`, ...) settles `{:refused, :unacknowledged}`.
- `{:error, :input_id_conflict}` settles `{:refused, :input_id_conflict}`;
  `{:error, :invalid_input}`, `{:error, :invalid_payload}` and `{:error, :input_too_large}`
  settle `{:refused, :invalid_input}`.
- `{:indeterminate, _}`, an exit and every other error leave the message delivering: the next
  `deliver/3` or `wake/3` gives the same ID to the same Run.

**`wake/3`:** step 1 of `deliver/3`; a tip that is not idle gets the wake at once (`:busy`); an
idle tip gets steps 2–4, then the wake, so a delivering message is given again before the wake.
An error of that delivery is returned and no wake is given.

**`rollover/3`,** each step safe to repeat:

0. **The link.** `chain/3` reads the tip. When its `seq` is not `link_seq` (the link rolled
   over already, so this repeats a sequence that passed step 4, or the request is stale), the
   result is `{:error, {:not_tip, seq}}` with nothing called or written: the host calls
   `resume/3` and, for a terminal tip, `rollover/3` of link `seq`, with a change only when it
   authorises one for that link. So a change is recorded on one link only.
1. **The result.** The `engine` Need, `status/1` (a halted engine is an error and gets no
   other call), then `result/3`: `{:pending, :not_completed}` is
   `:not_terminal`, an error `{:result, reason}`. A completed Run whose outcome is
   `elzoo.room.carry` v1, passes `check_start/2` and the reserve check and has `link` the tip's
   `seq` + 1 is `:finished` (outcome `"completed"`). Any other end restarts from the tip's own
   start through `restart_carry/1` (`:restarted`, outcome the terminal outcome's text), which
   empties the queue, so no turn that may have run is run again; the restarted carry is checked
   the same way (`{:invalid_start, :reserve}` and the others change nothing).
2. **Settlement.** `claim/3`; a claimed message is settled from `transcript/3` of the tip:
   without the input `mail:<message_id>` it is `:not_applied` (pending again, for the
   successor); with it and an `:action` entry of the root path of `elzoo.room.turn` or
   `elzoo.room.decide` naming the message it is `:applied`; with the input only it is
   `{:refused, :unacknowledged}`. A transcript error leaves it delivering.
3. **The pin** `P` (the tip's pin, or `change.pin`): (a) a `planned_pin` that is not `P` is
   unpinned for the successor's Run ID; (b) `plan_rollover/3`; (c) `pin/4` of `P` for the
   successor's Run ID.
4. **The atomic step**, the mailbox's `rollover/3`. On `:plan_mismatch` the room unpins its own
   pin `P` for the successor's Run ID and returns `{:mailbox, :plan_mismatch}`.
5. **The start.** `pin/4` again (it appends nothing when the record is there), the `start` Need,
   the start input with the carry.
6. **The unpin** of the old Run's pin for the old Run ID.

**`resume/3`:** a tip whose Run is not started gets `pin/4` of its pin and the `start` Need; a
Run whose classification is `:configured` gets its start input; a tip after the first link
unpins the predecessor's pin (a no-op once done); then `{:ok, :terminal}` or `{:ok, :live}`,
from a `status/1` read after the start input.

## Host sequence and Needs

The minimal host: `open/3` with the retry rule below; `deliver/3` after
each `put/3` of the mailbox and each time the tip becomes idle; `wake/3` from the timer, and
after a `wake/3` at the Run deadline, `deliver/3` (a wake that ends the Run can still return
`:busy` or `:rollover`; `deliver/3` then gives `{:ok, :terminal}`); on `{:ok, :terminal}`
`rollover/3` with the tip's `seq` as `link_seq`.

After a crash, if the host has not received a stop result for its outstanding `open/3`
request, it repeats that request, even if it crashed between attempts. With no outstanding
open, the host recovers an existing chain with `resume/3` and, for a terminal tip, `rollover/3`
with the same request (on `{:not_tip, seq}`, `rollover/3` of link `seq`).

The room checks none of these Needs:

- **One deliverer per chain.** The host runs no two calls of this Piece for one chain at a time,
  gives a tip no input except through them and the action outcomes of its own bindings, and
  gives no control (an Attempt change, a cancel) while a call for that chain runs.
- **Repeat `open/3` with the same request** after failure. Stop only on `{:ok, _}`,
  `{:error, {:mailbox, :conflict}}` (returned only after the conflict release finishes), or a
  definite refusal in step 1 (validation or reserve) or step 3 (pin, e.g. `{:error, {:pin, :not_found}}`).
  An indeterminate pin or release, or any other later failure, requires another `open/3`, not
  `resume/3`. In [room_test.exs, case 2 (`open/3`)](test/elzoo/room_test.exs), the refused and
  successful opens illustrate the stops. After an interrupted step 4 release, repeating the
  request removes the losing pin; a conflict with link 1's own pin leaves that pin in place.
- **A halted engine** is the host's to reconcile, fence and start again under the same Unit
  identity and Run ID, as the run-engine README requires; the `engine` Need returns the
  restarted engine.
- **The `start` Need builds the engine with the room's bindings:** the turn binding
  (`nested_callable`, schema `elzoo.room.turn`) wrapping each bot's agent-loop callable with the
  turn ID as its spec `id`, its `result` `{"elzoo.room.answer", 1}`; the decision binding
  (`elzoo.room.decide`, `result` `{"elzoo.typed-decision.result", 1}`); the echoing `local_work`
  binding of `elzoo.room.carry` whose `result` is `{"elzoo.room.carry", 1}`; the post and notice
  bindings (`tool_call`), which deliver to `post_to`, never the room's own chain; the engine's
  `result_reader`, which both readers use; `schemas` holding `elzoo.room.start`,
  `elzoo.room.rollover` and every mail name of the mailbox's declaration at its version (a
  missing one is refused `invalid_payload`); and a `run_deadline` more than
  `deadline_margin_ms` after the start.
- **The `wake` timer** calls `wake/3` with a new `wake_id` at each open slot's deadline and at
  the tip's `run_deadline`: the engine has no timer.
- **The declared reserve** is the true worst case of the host's recipes and decision binding.
- **`deadline_margin_ms`** is more than the longest engine call plus the difference between the
  room's clock and the engine's (else a message can reach the engine at its `run_deadline` and
  be refused `unacknowledged`).
- **`read_limits`** cover one link's full history at the engine's bounds (256 actions): a
  `read_limit` error repeats on every call.
- **The mailbox's declaration** declares the mail of the room's members (`elzoo.room.message`
  v1) and none of the room's own schema names; the host vouches for each mail's `from` and
  `reply_to_member`.

## Limits

- The room is as sound as its Needs: one deliverer per chain, no control during a call, a true
  declared reserve, and bindings that do what they say. It checks none of them.
- The slot count as the lifetime action count, and the meaning of `classification`, are
  readings of the engine's code (owner answer Q8); the tests run the real engine, so a change
  of either fails them.
- A refused message reads "not shown to have been given". A message that a pattern was given can
  be settled refused: after a lost reply, when an outcome of an earlier action lands between the
  reply and the read, when the pattern's request found no room in control (`record_size`), or
  when a lost reply's message reached the pattern and no turn or decision naming it was admitted
  in that Run, or when an Attempt change between two calls (allowed by the Need) makes the
  re-given `mail:<message_id>` differ from the first, lost, one, so the engine answers
  `input_id_conflict` and the room settles `{:refused, :input_id_conflict}`. The host decides
  whether to put it again under a new `message_id`.
- An `open/3` that pinned, failed (`{:mailbox, :unavailable}` that did not commit) and is never
  repeated leaves its pin record for the first Run ID, and that version then cannot be deleted
  (the host Need above).
- The room claims no exactly-once delivery: a message is given at most once per Run by the
  engine's input IDs and to exactly one link by the mailbox.
- A tip whose carry does not complete gets no more mail and ends at its Run deadline, then
  restarts; a stalled turn holds the room until its deadline, a stalled tip until its Run
  deadline. A rollover at link 2^31−1 is refused (`:link_limit`).
- Each link appends a pin and an unpin to the tenant's recipe-store stream; a full stream
  is carried into a new generation with only the live state (ELZ-358, #821), so a tenant's
  rooms are bounded by the live state (a carry of at most 5,000 records, about that many
  live pins), not by settled ones. Past it a rollover is `{:pin, :stream_full}`; when the
  successor's pin is the record that fills the generation, the successor has started and the
  old Run's unpin is `{:unpin, :stream_full}`, which `resume/3` then gives again, because an
  unpin appends and the live state cannot shrink past the bound.
- Mail payloads and carries hold people's text and have no delete or erasure.
- No child Run, parent-close rule, timer, process, A2A peer, live channel or cross-node room. A
  chain keeps its rule: a runtime rule switch would widen `d` to every rule it allows.

## Evidence

`mix test pieces/delivery/room/test` runs on the worker's disposable PostgreSQL 16
(`ELZOO_TEST_DATABASE_URL`): the real engine through the run-engine test helper's `fixture/1`
(one Run per link, created and begun in its Run owner by the test's `start` Need), the real
mailbox in random schemas dropped afterwards with every mailbox call as the application role
(`ELZOO_TEST_APP_ROLE`), the real turn-policy step with scripted bot and decision callables,
and the real recipe store on the Memory Store with a `log_hook`. The `record_size`,
indeterminate, exit and halt replies use a stand-in process for the tip's engine. The test
harness hosts one engine at a time (the fixture routes the Unit's offers to one name), so a
link's record is read before its successor starts. Finite listed scenarios with negative
controls (see [piece.json](piece.json)), not a proof.
