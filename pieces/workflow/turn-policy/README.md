# workflow/turn-policy

`Elzoo.TurnPolicy` is the pure pattern step of the root callable of a room Run,
in the `core/operator` shape over `workflow/pattern-step` v1 neutral maps. It
decides which bot member speaks next, runs one turn at a time as a
`nested_callable` action, posts each answer, stops bot-to-bot exchanges at a
bound, hands the room to people on escalation, moves the default member on a
handoff, and at a threshold asks for its own carry so that a successor Run
continues the room. It absorbs the handles `workflow/handoff`,
`workflow/human-escalation` and the room part of `workflow/loop-guard`.

The step has no clock, I/O, store, process or model call. A rule asks a model
only through one decision action that the host binds; the step reads that
action's outcome as untrusted model output. `delivery/room` hosts the step.

The step is test-grounded plain Elixir: no Cure law. The guards (members only,
the bot-turn bound) are each one function that every rule goes through
(`take/3`, `mentioned/2`, `enqueue/3`), and the tests and negative controls
below ground them; they are finite scenarios, not a universal proof.

## Interface

- `new(%{host_rules: rules})` returns `{:ok, state}` or `{:error, :invalid_spec}`.
  `rules` maps 0..8 names (1..64 bytes of `[a-z0-9._-]`, none a built-in name)
  to a loaded module that exports `choose/2` and `read/3`
  (`Elzoo.TurnPolicy.Rule`). The engine's root callable is
  `{Elzoo.TurnPolicy, :step, state}`.
- `step(state, input)` returns `{:Transition, new_state, :none | {:some, request}}`.
  Every request holds exactly one action.
- `check_start(state, start)` returns `:ok` or `{:error, reason}` by exactly the
  checks of a `start` input: `:malformed`, `:unknown_rule`, `:default_member`,
  `:too_many_bots` (`"everyone"` or `"decided"` with more bot members than
  `max_bot_turns`) and `:carry` (a queued member or the carried default member
  that is not a bot member of the start, more queued turns than `bot_turns` or a
  `bot_turns` over this start's `max_bot_turns`, a carried window over this
  start's `window` bounds, or a carry over 65,536 bytes of compact JSON). The room
  checks every start and carry before it pins or opens anything.
- `restart_carry(start)` returns the start of the successor of a link that
  ended without a carry: `link` + 1, the queue emptied and the note
  `restarted_queue_dropped` added; with `carry` `null`, `link` + 1 only; at link
  2^31−1, `{:error, :link_limit}`.
- `pick_schema()` returns the decoded JSON Schema of `elzoo.room.pick` v1.

State: an atom-keyed plain map owned by the copying application. A start that
fails `check_start/2` opens nothing and keeps the reason in `invalid_start`.

## Rules

For a person's message (`"human"` member); a message from a `"bot"` or `"peer"`
member, and a bot's answer, ask no rule: they queue the turns of the bot
members they mention, under the bound.

| Rule | Turns |
| --- | --- |
| `"addressed"` | the addressed members, else `default_member` (none when `null`). Presets: **lead bot** (`default_member` set) and **mention-only** (`default_member` `null`). |
| `"round_robin"` | the next bot member in member order after the last one this rule chose; the position is the rule state, carried over |
| `"everyone"` | every bot member one turn, in member order (bounded: `check_start/2` refuses more bots than `max_bot_turns`) |
| `"decided"` | the addressed members, else one decision action `d/<link>/<n>` |
| host rule | `choose/2`, and `read/3` after a `{:decide, context}` |

Addressing: the mentioned bot members in mention order without repeats; with
none, a `reply_to_member` that is a bot member. A `reply_to_member` that is not a
bot member gives `reply_to: :invalid` and the note `reply_to_not_member`.
Addressing decides under `"addressed"` and `"decided"` only; `"round_robin"`
and `"everyone"` do not read it; a host rule gets it in its view and decides
itself.

The pick of `"decided"` counts only when the outcome is `completed`, schema
`elzoo.typed-decision.result` v1, payload `"status": "decided"` and a `"value"`
of exactly `{"pick": "several"}` (every bot one turn) or `{"pick": ids}` with
1..16 distinct bot member IDs. Anything else falls back whole to
`default_member` with the note `decision_fallback`.

A host rule's callbacks get `view = %{message, addressed, reply_to, members,
default_member}` (`members` as `%{id, kind}` with kind atoms) and the rule
state (`nil` at the room's start). A raise, throw or exit, another shape, a
second `{:decide, _}` from `read/3`, more than 16 IDs, a `context` over 4,096
bytes or a rule state over 1,024 bytes of compact JSON is a bad answer: no
turn, the rule state unchanged, the note `host_rule_failed`.

## Guards, for every rule

1. One open action at a time: a turn, then its post, then the next queued turn;
   a decision only while no turn is open.
2. Members only: a non-member's message is left out (`not_member`); a named ID
   that is not a bot member, or a repeat, is left out (`not_member`,
   `repeated_member`).
3. The bot-turn bound: a turn is queued only while the bot turns since the last
   person's message stay within `max_bot_turns`. A turn left out puts the room
   in `awaiting_person` with one notice `"bot_turn_bound"`; queued turns still
   run; turns that exactly fill the bound post no notice.
4. Escalation: `escalate: true` drops the queue, enters `awaiting_person` and
   posts one notice `"escalated"`. A notice is posted only on entering
   `awaiting_person`; while awaiting, nothing is queued (`awaiting_person`) and
   a second escalation or bound is a note only, until a person writes.
5. Handoff: `handoff_to` a bot member becomes `default_member` when `handoff` is
   `"allowed"` (`handoff`); otherwise the answer is posted and the handoff left
   out (`handoff_denied`, `handoff_not_member`).
6. The window: newest first, always the newest entry, older ones while at most
   `window.messages` entries and `window.bytes` compact JSON bytes. Content is a
   `workflow/untrusted-content` value of source `room`: `"untrusted"` for a
   person's or peer's message, `"derived"` for a bot's message or answer.
7. Action IDs: turn `t/<link>/<n>` with `<turn_id>/turn` and `<turn_id>/post`,
   decision `d/<link>/<n>`, notice `n/<link>/<n>` (sequences from 1, carried),
   carry `c/<link>/<k>` (k from 1 in the Run) and finish `f/<link>`.

A turn outcome that is not `completed` (`turn_not_completed`) or not a valid
`elzoo.room.answer` (`invalid_answer`) posts nothing and counts as a run turn. A
post or notice that does not complete is `post_failed`, not retried. A `late`
outcome changes nothing. A malformed message is `invalid_message`. `cancel` and
`run_ended` close the step; `wake`, other schemas, a second `start` and inputs
that `PatternStep.decode/1` refuses change nothing.

## Carry

After `rollover.max_turns` turns in this Run, or on an `elzoo.room.rollover`
message, the step is carrying: it asks no turn and asks the `local_work` action
`c/<link>/<k>` of schema `elzoo.room.carry`, whose payload is the start with
`link` + 1 and `carry` set (window, `bot_turns`, `default_member`, `rule_state`,
`awaiting_person`, `queue`, `seq`, the 16 newest `notes`). On its completed
outcome it asks the root `finish` `f/<link>` with payload `{"action_id": <carry
ID>}`. A carry that does not complete is `carry_failed`; each later message is
added to the window, its turns are queued (at most `max_bot_turns` entries,
else `carry_queue_full`), a decision falls back (`decision_fallback`), the bound
adds only a note, and the carry is asked again under the next `k`. A successor
runs its queued turns first and counts its own turns from zero. At link 2^31−1
no carry is asked (`link_limit`).

## The per-message count (Q8 reserve)

Between two messages the step asks at the root at most one decision action,
`max_bot_turns` turns with one post each, and one notice, and, when those turns
reach `rollover.max_turns`, the carry `local_work` action and the finish after
them; a carrying step asks,
for a message, no turn, no decision and no notice, and one carry action, then
the finish. The room's per-message reserve is this count with the worst case of
the decision binding and of the bot recipes, over every rule the room may use.

## Host bindings

- **Turn** (`nested_callable`, `elzoo.room.turn`: `turn_id`, `member`,
  `message_id`, `window`, `summary`): the host's binding wraps the bot's
  `workflow/agent-loop` callable with the turn ID as its spec `id` and maps its
  finish to `elzoo.room.answer` (`text`, `mentions`, `handoff_to`, `escalate`);
  the binding's `result` is `{"elzoo.room.answer", 1}`.
- **Decision** (`nested_callable`, `elzoo.room.decide`: `decision_id`, `rule`,
  `message_id`, `members`, `window`, `context`): the binding starts
  `workflow/typed-decision` with the decision ID as `id`,
  `answer: {:schema, Elzoo.TurnPolicy.pick_schema()}` and an output Port of
  `elzoo.room.pick` v1; its `result` is `{"elzoo.typed-decision.result", 1}`.
- **Carry** (`local_work`, `elzoo.room.carry`): the binding gives the payload
  back unchanged as the completed outcome.
- **Post and notice** (`tool_call`, `elzoo.room.post` and `elzoo.room.notice`):
  the binding delivers to `post_to`, a mailbox `put/3` on another chain or a
  channel, never the room's own chain.

## Grounding, Needs and Limits

`mix test pieces/workflow/turn-policy/test` runs the groups listed in
`piece.json`, including one finish of the real `Elzoo.TypedDecision` with
`pick_schema/0`, the size case (the largest start fits the root state bound as
the engine measures it, and each payload stays within 65,536 bytes), and the
checked example `examples/turn_policy.exs`. Four negative controls were run by
a temporary edit and reverted: dropping the bound, counting a peer as a
person, letting a non-member's mention open a turn, and accepting any pick ID.

Dependencies: `workflow/pattern-step` and `workflow/untrusted-content`;
`workflow/typed-decision` and `core/payload-schema` are test-only (the library
code calls neither). Telemetry, Config and Control are not applicable.

Needs: an engine that records each input before the step reads it, gives a
message only while no action is open and checks each action; host-vouched
`from`, `reply_to_member` and member kinds; the bindings above.

Limits: a pick and an answer are model output: the step checks shape and
membership, not quality. The bound counts turns, not cost; a stalled turn holds
the room until its deadline. A host rule must be pure and deterministic, which
the step cannot check. The room cannot roll over past link 2^31−1.

Module application-owned under `Elzoo.TurnPolicy`. Apache-2.0; no new
dependency or pin.
