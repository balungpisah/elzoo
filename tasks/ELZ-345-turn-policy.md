# ELZ-345 — The turn policy of a room: who speaks next, a bot-turn bound, escalation, handoff and the rollover carry

- Phase: Wave 8 Level 1
- Dependencies: ELZ-033, ELZ-114, ELZ-115, ELZ-137, ELZ-141
- Release: V1B
- Output: new `workflow/turn-policy` Piece (absorbs the handles `workflow/handoff`, `workflow/human-escalation` and the room part of `workflow/loop-guard`)
- Change class: Piece-only
- Owned paths: `pieces/workflow/turn-policy/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `workflow/pattern-step`, `workflow/untrusted-content`, `workflow/typed-decision`, `workflow/agent-loop` and `assembly/run-engine`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure pattern step in plain Elixir, in the `core/operator` shape over `workflow/pattern-step` v1 neutral maps, for the root callable of a room Run: it decides which bot member speaks next, runs one turn at a time as a `nested_callable` action, posts each answer, stops bot-to-bot exchanges at a bound, hands a room to people on escalation, moves the default member on a handoff, and at a threshold asks for its own carry so that a successor Run continues the room. The Contract source is the `workflow/turn-policy` section of [the Wave 8 plan](../docs/plans/bot-platform-wave8.md) ("Level 1"), with owner answers Q2 A as expanded and Q8 A with its two reserve additions (2026-11-23; [choices](../docs/choices.md#wave-8-owner-choices-2026-11-23)). Where this task and the plan's sketch differ, this task is the Contract.

The handles `workflow/handoff` and `workflow/human-escalation` are absorbed: a handoff and an escalation are moves of the room's turn, not Pieces. The room part of `workflow/loop-guard` is the bot-turn bound below. None gets a Piece ID.

The step has no clock, I/O, store, process or model call. A rule asks a model only through one decision action that the host binds, and the step reads that action's outcome as untrusted model output. `delivery/room` (Wave 8 Level 2) hosts the step; the Wave 8 root acceptance binds the decision action to `workflow/typed-decision`.

The `:decided` rule reads model output (an untrusted pick), and every rule decides which principal acts next, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6); the hosted `check-piece` run does not replace the local run.

## Facts on `main` that this task builds on

Checked at `main` `bce5ea99`:

- `Elzoo.PatternStep.decode/1` and `encode/1` translate v1 neutral maps; a request holds 1..64 actions with unique IDs; v1 inputs include `start`, `message`, `action_outcome`, `cancel`, `run_ended` and `wake`; outcome classes are `completed`, `failed`, `refused`, `late`, `unknown`, `out_of_budget`, `retries_exhausted`, `expired`, `resource_lost`. `open/1` and `accept/2` settle outcomes of one request (`{:applied, tracker}`, `{:late, tracker}`, …).
- `assembly/run-engine` gives a pattern a `message` only while no action is open and the lifecycle permits new work; it refuses an action ID used before in the Run (`reused_identity`); a root `finish` completes a Run only when its payload's `"action_id"` names a settled, completed action of the same Attempt (else `completion_evidence`), and `result/3` returns that action's outcome payload; a pattern state is stored only when `:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])` is at most the callable's state bound (65,536 bytes for the root) and the state is plain data; payload JSON is at most 65,536 bytes; a nested child's finish reaches the parent only when it matches the binding's `result` schema.
- `workflow/agent-loop` takes a spec `id` of 1..128 bytes and derives its action IDs from it (`<id>:m:<n>`, `<id>:finish`); `workflow/typed-decision` takes a spec `id` of 1..128 bytes, an output Port and `answer: {:schema, schema}`, and finishes with schema `elzoo.typed-decision.result` version 1, payload `{"status": "decided", "value", "repairs", "action_id"}` or `{"status": "failed", "reason", …}`.
- `Elzoo.UntrustedContent.decode/1` makes a marked value (sources 1..16 texts of `[A-Za-z0-9._:/@-]`, trust `"untrusted"` or `"derived"`, content valid UTF-8 within `max_bytes`); `encode/1` gives the six-key neutral map.

## Interface

Module `Elzoo.TurnPolicy`.

- `new(spec)` returns `{:ok, state}` or `{:error, :invalid_spec}`. `spec` is exactly `%{host_rules: rules}`, `rules` a map of 0..8 host rule names (1..64 bytes of `[a-z0-9._-]`, none equal to a built-in rule name) to a module that `Code.ensure_loaded/1` loads and that exports `choose/2` and `read/3` (the behaviour `Elzoo.TurnPolicy.Rule`). `state` is the plain initial state of the root callable, `{Elzoo.TurnPolicy, :step, state}` for the engine.
- `step(state, input)` returns `{:Transition, new_state, :none | {:some, request}}`, `input` and `request` v1 neutral maps.
- `check_start(state, start)` returns `:ok` or `{:error, reason}` for a decoded `elzoo.room.start` v1 payload, by exactly the checks that `step/2` applies to a `start` input, so the room checks every start and every carry before it pins or opens anything. It takes `state` from `new/1` because a host rule name is known only from it; the plan named it `check_start/1` (a coordinator correction).
- `restart_carry(start)` returns `{:ok, start2}` or `{:error, reason}` (plan review L2): for the start payload of a link that ended without a carry, the start payload of its successor: `link` + 1, the queued turns removed and the note `restarted_queue_dropped` added, everything else equal. So a restarted successor starts idle and runs no turn of its predecessor again, and the state shape stays in this Piece.
- `pick_schema()` returns the decoded JSON Schema object of `elzoo.room.pick` version 1, for the host to give `workflow/typed-decision` as `answer: {:schema, Elzoo.TurnPolicy.pick_schema()}` on an output Port of schema `elzoo.room.pick` version 1:

  ```json
  {"type": "object",
   "properties": {"pick": {"oneOf": [
     {"const": "several"},
     {"type": "array", "minItems": 1, "maxItems": 16,
      "items": {"type": "string", "minLength": 1, "maxLength": 128}}]}},
   "required": ["pick"],
   "additionalProperties": false}
  ```

**The rule behaviour.** `Elzoo.TurnPolicy.Rule` has two pure callbacks over plain data:

- `choose(view, rule_state)` returns `{{:turns, member_ids}, rule_state2}` or `{{:decide, context}, rule_state2}`;
- `read(view, rule_state, outcome)` returns `{{:turns, member_ids}, rule_state2}`, called once with the decision action's outcome `%{class, schema_id, schema_version, payload}`.

`view` is `%{message, addressed, reply_to, members, default_member}`: the message (`message_id`, `from`, `mentions`, `reply_to_member`), the bot members it addresses (its mentioned bot members in mention order, without repeats), `reply_to` one of `nil`, `{:member, id}` (a bot member) or `:invalid`, the members and the default member. `member_ids` is a list of 0..16 texts; `context` a JSON object of at most 4,096 bytes of compact JSON; `rule_state` a JSON term of at most 1,024 bytes of compact JSON, `nil` at the room's start, kept in the state and the carry. A callback that raises, throws or exits, or that returns any other shape, a second `{:decide, _}` or an over-bound value, is a **bad answer**: it fails closed, with no turn, the rule state unchanged and the note `host_rule_failed`.

## Payloads

All keys are strings and each schema version is 1. Texts are valid UTF-8, and a text bound is in UTF-8 bytes. A member ID is 1..128 bytes of valid UTF-8 without a C0 or C1 control character. The window, the summary, `context`, `rule_state`, the carry and the payloads are bounded in compact JSON bytes (Jason, as `core/payload-schema` measures them), because JSON escaping can make a text up to six times longer; so every payload that the step asks stays within the engine's 65,536 bytes.

- **Start** `elzoo.room.start`: exactly `room_id` (1..128 bytes under the member ID rule), `link` (1..2^31−1, the link sequence of this Run), `members` (1..32 entries `{"id", "kind"}` with distinct IDs, `kind` `"human"`, `"bot"` or `"peer"`; a `"peer"` is another room or an outside sender whose messages the host routes in), `policy`, `summary` (`null` or a text of at most 8,192 bytes of compact JSON) and `carry` (`null` for a fresh room, else the carried state below). `policy` is exactly `rule` (a built-in rule `"addressed"`, `"round_robin"`, `"everyone"` or `"decided"`, or a host rule name of `new/1`), `default_member` (`null` or a bot member), `max_bot_turns` (1..16), `handoff` (`"allowed"` or `"denied"`), `post_to` (1..256 bytes under the member ID rule, an opaque host address), `window` (`{"messages": 1..8, "bytes": 1..24,576}`; the plan's 32,768 is lowered so that the largest carry, with every text escaped, stays within 65,536 bytes, a coordinator correction) and `rollover` (`{"max_turns": 1..63}`).
- **Message** `elzoo.room.message` (a v1 `message` input): exactly `message_id` (1..155 bytes under the member ID rule, as in `delivery/durable-mailbox`), `from` (the host-vouched member ID), `text` (1..4,096 bytes) and `mentions` (0..16 member IDs), plus the optional `reply_to_member` (a member ID that the host resolved and vouches for, as it does for `from`). A message from a `"human"` member is a person's; one from a `"bot"` or `"peer"` member is a bot's.
- **Rollover** `elzoo.room.rollover`: a `message` input with the payload `{}`, given by the host.
- **Turn** `elzoo.room.turn`: the payload of a turn's `nested_callable` action: `turn_id`, `member`, `message_id` (the message that queued the turn), `window` and `summary`.
- **Answer** `elzoo.room.answer`: the expected result of a turn: exactly `text` (1..4,096 bytes), `mentions` (0..16 member IDs), `handoff_to` (`null` or a member ID) and `escalate` (a boolean). The host's binding wraps the bot's agent-loop callable and maps its finish to this schema, and builds each turn's agent-loop spec with the turn ID as its `id`.
- **Decide** `elzoo.room.decide`: the payload of a decision `nested_callable` action: `decision_id`, `rule`, `message_id`, `members` (the bot members), `window` and `context`.
- **Post** `elzoo.room.post`: a `tool_call` with `post_to`, `turn_id`, `member`, `text` and `mentions`; the host binds it to a mailbox `put/3` on another chain or to a channel, never to the room's own chain.
- **Notice** `elzoo.room.notice`: a `tool_call` with `post_to`, `notice_id`, `reason` (`"bot_turn_bound"` or `"escalated"`) and `members` (the human member IDs).
- **Carry** `elzoo.room.carry`: a `local_work` action whose payload is a start payload with `link` + 1 and `carry` set; the host's local-work binding gives that payload back as the completed outcome. The root `finish` payload is `{"action_id": <the carry action ID>}`.

The **window** is a list, newest first, of entries `{"message_id", "from", "content"}`, `content` the neutral map of a marked value with source `room`, trust `"untrusted"` for a person's or a peer's message and `"derived"` for a bot's message or answer. It always holds the newest message; it keeps older messages while it holds at most `window.messages` entries and its compact JSON is at most `window.bytes` bytes. Older messages stay in the engine record.

The **carried state** (`carry`) is exactly the window, `bot_turns` (bot turns since the last person's message), `default_member`, `rule_state`, `awaiting_person` (a boolean), `queue` (the turns still queued, 0..16 entries `{"member", "message_id"}`), `seq` (the room's turn, notice and decision sequences) and `notes` (the 16 newest notes `{"code", "ref"}`, `ref` `null` or the message ID or member ID that the note is about). A notes list is how the step reports the left-out inputs below; the carry and the engine record keep it.

## Rules

**Start.** A `start` input runs `check_start/2`; a start that fails opens no action and records the reason in the state as `invalid_start`; a root finish could not complete such a Run, since it names no completed action, so the room checks every start first. `check_start/2` refuses, with these atoms: `:malformed` (any shape or bound above), `:unknown_rule`, `:default_member` (not a bot member), `:too_many_bots` (rule `"everyone"` or `"decided"` with more bot members than `max_bot_turns`), `:carry` (a carried member, queued turn or default member that is not a bot member of the start, or a carry over 65,536 bytes). A carry-over start continues `bot_turns`, the default member, the rule state and the sequences, and runs its queued turns first; the per-Run turn count that `rollover.max_turns` compares starts at zero, so a successor is not rolled over at once.

**Addressing.** For a person's message, the addressed bot members are its mentioned bot members, in mention order; with none, a `reply_to_member` that is a bot member addresses that member; a `reply_to_member` that is not a bot member gives `reply_to: :invalid`, and the message goes to `default_member` with the note `reply_to_not_member`.

**Built-in rules,** each a module of the rule behaviour, run through the same plug as a host rule, for a person's message:

- `"addressed"`: the addressed members, else `default_member` (none when it is `null`). Its two presets are named in the README and the tests: **lead bot** (`default_member` set) and **mention-only** (`default_member` `null`).
- `"round_robin"`: the addressed members, else the next bot member in member order after the last one this rule chose (its position is the rule state).
- `"everyone"` (bounded): the addressed members, else every bot member one turn, in member order.
- `"decided"`: the addressed members, else, for an unaddressed message, one decision action; mentions and reply-to never ask it. The decision's outcome is untrusted model output. It is read as a pick only when it is a `completed` outcome of schema `elzoo.typed-decision.result` version 1 whose payload has `"status": "decided"` and a `"value"` that is `{"pick": "several"}` (bounded everyone) or `{"pick": ids}` with 1..16 distinct IDs of bot members; anything else, a `failed` status, and any other outcome class (a failure, a refusal or a deadline) falls back to `default_member` with the note `decision_fallback`.

A host rule's `choose/2` decides for every person's message. A `{:decide, context}` answer asks one decision action in the same way, and `read/3` reads its outcome.

**Guards, kept for every rule, built-in or host:**

1. One open turn at a time: the step asks one turn, then its post, then the next queued turn; it asks a decision action only while no turn is open.
2. Members only: a message from a non-member is left out (`not_member`); an ID that a rule or a pick names and that is not a bot member, and a repeated ID, is left out (`not_member`, `repeated_member`); a non-member's mention opens no turn.
3. The bot-turn bound: a turn is queued only while the bot turns run or queued since the last person's message stay within `max_bot_turns`, so one message starts at most `max_bot_turns` turns. Answers of bot members and messages from `"bot"` and `"peer"` members queue the turns of the bot members they mention under the same bound and ask no rule, so a ping-pong between two rooms also stops. A turn left out by the bound puts the room in `awaiting_person` with one notice `"bot_turn_bound"`; a message whose turns exactly fill the bound posts no notice.
4. Escalation: an answer with `escalate: true` puts the room in `awaiting_person`, drops the queue and posts one notice `"escalated"`. While `awaiting_person`, no rule is asked and no bot turn is queued, until a person's message arrives.
5. Handoff: `handoff_to` names a bot member that becomes `default_member` when `handoff` is `"allowed"` (`handoff`); otherwise the answer is posted and the handoff is left out (`handoff_denied`, `handoff_not_member`).
6. The window and the carry as above.
7. Unique action IDs: a turn ID is `t/<link>/<n>`, a decision `d/<link>/<n>`, a notice `n/<link>/<n>` (decimal sequences from 1, carried over), the turn's actions `<turn_id>/turn` and `<turn_id>/post`, the carry `c/<link>` and the finish `f/<link>`; each turn ID is at most 43 bytes, so an agent-loop spec `id` of it stays within 128 bytes for any member ID, and a second turn of the same bot asks new action IDs.

A turn outcome that is not `completed` (`turn_not_completed`) or not a valid answer (`invalid_answer`) posts nothing and counts as a run turn; a post or notice outcome that is not `completed` is a note (`post_failed`) and is not retried; a `late` outcome changes nothing.

**Carry.** After `rollover.max_turns` turns in this Run, or on an `elzoo.room.rollover` message, the step asks no new turn and asks the carry action; on its completed outcome it asks the root `finish` that names it. A carry outcome that is not completed is the note `carry_failed`; the Run then ends at its deadline, and the room restarts from its start carry with `restart_carry/1`. At link 2^31−1 no carry is asked (`link_limit`).

**The per-message count (Q8 reserve).** Between two messages the step asks, at the root, at most one decision action, `max_bot_turns` turns with one post each, and one notice; the carry adds one `local_work` action and the `finish`. The README states this count, so the room's per-message reserve adds the worst case of the decision action and of the bot recipes over every rule that the room may use.

`cancel` and `run_ended` close the step with no request; `wake`, an input of another schema, a second `start`, and an input that `PatternStep.decode/1` refuses change nothing. Reasons and notes are fixed atoms (in the carry, their texts). Within the bounds above the state stays within the root's 65,536-byte bound at every input; a carry over 65,536 bytes of compact JSON cannot be asked, so `check_start/2` bounds it and the tests show the largest state and carry fit. If the bounds above cannot hold, the worker stops and comments on the issue with the measured sizes (`AGENTS.md` section 4) rather than lowering a bound on its own.

The task records whether Cure owns a decision (for example a selected law that the bound is never passed, or that a non-member never gets a turn) or states the step as test-grounded plain Elixir. `piece.json` declares telemetry, config and control `not_applicable`, the dependencies `workflow/pattern-step` and `workflow/untrusted-content`, and `workflow/typed-decision` and `core/payload-schema` as test-only (the tests run a decided finish of the real step and build `pick_schema/0`; the library code calls neither); the README says so and shows the host bindings: the turn wrapper, the decision binding to `workflow/typed-decision`, the echoing carry binding, and the post binding.

## Kept open (owner's "no corner" rule)

Each option below can be added in place before the first release without breaking a caller: the rule, member-kind, notice-reason and note sets may gain members, and the start, policy, message, answer and turn payloads may gain optional keys; an input that is valid now stays valid.

- *A runtime rule switch:* at room level, an optional `set_rule` key of `elzoo.room.answer`, handled like `handoff_to` and allowed only through an optional policy key `rule_change: %{allowed, by}`; for subagents, an `allowed_patterns` key of the `workflow/delegation` grant, narrowed per child like scopes (owner, 2026-11-23). Until then a room keeps its rule.
- *Per-bot stop and resume as a member state:* an optional member key.
- *Host rules for bidding, skill or priority routing, time-of-day rules and per-member rates:* through the rule behaviour; no built-in rule.
- *Another outcome form of the decision action:* an added member of the forms the built-in `"decided"` reads.
- *A reusable wrapper from the agent-loop finish to `elzoo.room.answer`;* more turn payload keys (memories, citations); several open turns at once; a summary made by `workflow/context-compaction` before the carry.

## Acceptance

Traces are recorded inputs given to `step/2`; expected actions, IDs and states are written out by hand.

1. Each built-in rule over a person's message: `"addressed"` lead bot and mention-only, with and without mentions; `"round_robin"` over three bots and two people, with its position carried; `"everyone"` in member order; `"decided"` with an unaddressed message (one decision action of schema `elzoo.room.decide`), with a mention and with a valid reply-to (no decision asked).
2. Reply-to: a bot member gets the turn; a human member and a non-member fall back to `default_member` with the note.
3. The pick, as untrusted output: `["b2", "b1"]` gives two turns in that order; `"several"` gives every bot one turn; an unknown ID, a human member, a repeated ID, 17 IDs, an empty list, `{"pick": 3}`, an extra key, a `failed` typed-decision finish, a `failed` and an `expired` outcome each fall back to `default_member` with `decision_fallback` (and to no turn with `default_member` `null`). One finish comes from running `Elzoo.TypedDecision` itself with `pick_schema/0` and a scripted model result.
4. A host rule: `{:turns, ids}`, `{:decide, context}` then `read/3`, a raise, a bad shape, a second decide, a rule state of 1,025 bytes: each bad answer gives no turn and `host_rule_failed`; a host rule that names a non-member gives no turn to it.
5. The guards under each rule: one open turn at a time; a non-member's message and mention; `max_bot_turns` at its edge (a bot-to-bot exchange stops at exactly the bound, posts one notice, and resumes after a person's message); a two-room trace in which each room's bot answers the other's post stops at the bound; `"everyone"` with exactly `max_bot_turns` bots posts no notice; escalation; an allowed and a denied handoff, and a handoff to a non-member; window eviction at its count and byte edges, and a newest message larger than `window.bytes` kept alone.
6. `check_start/2` and `start` at each edge (32 and 33 members, `max_bot_turns` 0, 1, 16, 17, `max_turns` 63 and 64, `window` edges, a 128- and 129-byte member ID, `"everyone"` with one bot more than the bound, an unknown rule, a default member that is human) agree.
7. The carry: at `max_turns` with turns still queued, and on the rollover message: one `local_work` action of the whole state, then a `finish` naming it; a start from that carry continues `bot_turns`, the default member, the rule state and the sequences, runs the queued turns first and starts the per-Run turn count at zero; `restart_carry/1` of a start with queued turns gives `link` + 1, an empty queue and the note.
8. Action IDs: two turns of one bot in one Run carry distinct turn IDs; every action ID of a trace of 256 entries is distinct; a turn ID with a 128-byte member ID is at most 43 bytes.
9. Sizes: the largest start (32 members of 128-byte IDs that each need JSON escaping, a full window of messages that need escaping, an 8,192-byte summary, 16 notes, a full queue and a 1,024-byte rule state) fits the root state bound measured as the engine measures it, and its carry, turn and decide payloads are each at most 65,536 bytes.
10. Malformed inputs: a malformed start, message or answer gives a fixed reason or note; the step raises for none.
11. Negative controls, one at a time, each restored before the final gates: drop the bot-turn bound (the ping-pong trace never stops within its 256 entries); count a `"peer"` message as a person's (the two-room trace never stops); let a non-member's mention open a turn (case 5 fails); accept any pick ID without the membership check (case 3 fails).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide ("Reviewer by risk": it finds the code and a test for each rule above), the exact-head hosted check and the merge queue are required. Record in the pull request body the change in the time of the aggregate consumer of `test/export_test.exs` (#814, #819).

## Limits to state

A pick and an answer are model output: the step checks their shape and membership, not their quality, and a model may pick or mention a member badly. `from`, `reply_to_member` and the member kinds are host-vouched. The bound counts turns, not cost; a stalled turn holds the room until its deadline. Messages reach the step only between turns, one at a time (the engine gives no `message` while an action is open). A host rule is host code run inside the step: it must be pure and deterministic, which the step cannot check. No clock, timer, I/O or model call.
