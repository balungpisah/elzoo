# ELZ-387 — assembly/run-engine: an opt-in start option gives a message to the root while slots are active

- Phase: in-place change of the ready Piece `assembly/run-engine` before the first release (owner decision on #930, 2026-11-25)
- Dependencies: ELZ-127, ELZ-142, ELZ-351, ELZ-385
- Release: V1B
- Output: none. A change in place of the ready Piece `assembly/run-engine` (ELZ-127; expiry reports ELZ-351; read rechecks ELZ-385) before the first release, with the same Piece ID (`AGENTS.md` section 4), for #930. The Contract gains one optional start option. With the option absent, every record, state, pattern call and charge stays as it is. This publication does not settle #930; the build pull request does.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: two Piece directories, one index row and the generated files)
- Owned paths: `pieces/assembly/run-engine/**`; in `pieces/workflow/agent-loop/`, only the "No engine claim" sentence of `README.md` (see "agent-loop's README"); the `manifest_sha256` and `note` of the `assembly/run-engine` row of `entries` in `docs/plans/release-plan.json`; and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). Do not change agent-loop's `lib/`, `cure/`, `test/`, `examples/` or `piece.json`, or its index row. No other Piece, no root test or helper (the Wave 9 acceptance harness included), no `mix.exs`, `mix.lock` or CI.
- Build environment: an a1.medium orb (disposable PostgreSQL 16; the small gate runs the tests of every ready Piece that depends on the engine)

## Outcome and boundary

#930 reports that an agent-loop bot under `assembly/run-engine` never sees a `message`. The engine gives a `message` to the root only when no slot is active (README, "Recorded cycle and obligations", the sentence that ends "a slot is active while it is not settled or while it holds a pending input"). An agent-loop root always has an active slot from its start to its finish. So agent-loop's step-table row "`message` | the text waits; no request" (its README, "Step table", and "One turn" step 5) is reachable only through its pure `step/3`.

Owner decision (2026-11-25, option A of the coordinator note on #930): `assembly/run-engine` gains an opt-in start option. With the option on, a `message` input given while slots are active is given to the root as an input that settles no slot. Without the option, behaviour stays as it is today. agent-loop's step logic does not change.

This task adds that option and only that. It does not change the root's input rule for `wake`, `start` or `resource_event`. It does not give a message to a nested callable, keep a message while the Run is paused, or add a status or transcript member.

The engine keeps durable state, settles unknown outcomes and serves every engine consumer. So the task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk", `AGENTS.md` section 6).

## Facts on `main` that this task builds on

Checked at `ac598acb` in `pieces/assembly/run-engine/lib/elzoo/run_engine.ex` and the README. ELZ-385 (#935) merges first. It changes the owner recheck of `result/3`, `event_waits/3` and `transcript/3` (about line 5238) and the README paragraphs that state that recheck. This task changes none of those. Confirm each fact below on the `main` that holds ELZ-385. If one differs, stop and comment on the issue.

- `protocol_transition/2` (about line 683) classifies a record of another Run or a stale Attempt as `late`, and a known invocation ID as `duplicate`, before any expiry. Otherwise it runs `expire_and_report/3` (the expiry pass, and with `expiry_reports: :owner` its held reports) at `input["at_ms"]`, then the input's own rule `protocol/2`, then `close_run/2` when the view is terminal.
- In `protocol/2` (about line 708), the last branch (`true ->`, about lines 760–771) handles `start` and `message`, the two inputs that settle no slot and have no branch of their own. It runs `BotRunLifecycle.step` with `exhausted` false and returns `accepted = decision == :permit_new_work and active_count(next) == 0`, with callable `"root"`. The `wake` branch (about line 718) and the `resource_event` branch (about line 751) have the same `active_count == 0` condition.
- `workflow/bot-run-lifecycle` (`classify/4` and `decide/4`) treats a `message` that is not ended, not of an old Attempt and not at or after the Run deadline (`Expired`, which requests `out_of_time`) as `Work`. It decides `Work` as `PermitWork` in `Active`, `RemainWaiting` in `Waiting`, `RemainPaused` in `Paused`, and `Unchanged` in `Terminal`. The decision also reads `budget_exhausted`, which `life_context/5` (about lines 1582–1591) sets from the root Budget's status: a `message` when the root Budget's committed amount is at its cap (`status.committed >= status.cap`; reserved amounts do not count) gets `EnterPause` (`:remain_paused`) or `RequestBudget` (`{:request_outcome, :out_of_budget}`). A paused Run at or after its pause deadline gets `Expired`, not `RemainPaused`. The engine puts the lifecycle in `:waiting` when the continuation of a slot of any kind reaches `:running` or `:waiting` (about lines 380–383): `tool_call`, `model_call`, `ask_person`, `local_work`, a Resource action, and a v2 `wait_event` at its activation (`restore_waiting/1`). It lists a lifecycle wait only for `model_call`, `tool_call` and `ask_person` (about lines 364–378), and for a v2 `wait_event`. A Run stays `:active` with `active_count > 0` only while its open slots are `nested_callable` parents whose children hold no such slot, slots that are not yet running, or settled slots that hold a `pending_input`. So today, outside a pause and a Budget exhaustion, a `message` while a slot is active gets `:remain_waiting`, or `:permit_new_work` with `active_count > 0`, and in both cases it is not given.
- `transition/2` for a `:protocol` record (about lines 129–179) calls `invoke/3` for the callable that `protocol_transition/2` names. It does so only when the input is accepted, generation is open, no stop is pending, the Run is not paused and the callable is not closed. An input that settles no slot is first checked for room for its invocation entry (`fits?/1` with `invocations[record.id]` placed). With no room it is classified `record_size`, and nothing else is kept. An accepted input that settles no slot while the Run is paused is not kept: only an input with an `occurrence` is retained as a `pending_input`.
- `invoke/3` (about line 1255) places `invocations[record.id]`. It charges nothing for `:none`. For `{:some, request}` it charges one count of the sealed request cap, with a receipt whose `input_id` is `record.id`, and runs `admit_request/5`, whose `active_count(state) + length(actions) <= 64` check applies. The first excess closes generation (`over_cap`).
- `init/1` (about line 1612) parses `expiry_reports` with `Keyword.get_values/2` (about line 1616), wraps the fingerprint as `digest({:expiry_reports, :owner, fingerprint})` (about lines 1653–1657) and records `expiry_reports: :owner` in control (about lines 1714–1715). A restart of the same `run_id` with another fingerprint is `{:stop, :incompatible_recovery}`. A malformed option is `{:stop, :invalid_options_or_recovery}` before `DynamicUnits.start/2`.
- `active_count/1` (about line 4666) counts a slot that is not settled or holds a `pending_input`. The drain gives held expiry reports through `:resume_input` records after the step of the input whose expiry pass held them. So an input's own pattern call comes before those reports (task ELZ-351, "Paused": "a settling input's own pattern call is in its own fold step, so it comes before the reports that its expiry pass holds").
- `transcript_entries/5` (about line 5835) gives each committed protocol record of the scoped Run an `:input` entry `%{type: :input, input_id: id, kind: input["kind"]}`, whether or not a pattern was called for it. Both readers fold the recorded results with the DurableUnit reducer and rerun pure engine code on each record, which reads only recorded control: `event_waits/3` through `protocol_transition/2` (`project_event_wait_transition/2`, about line 4825, and `event_wait_pattern_invocation/2`, about line 4903; for a v2 first excess, `project_recorded_over_cap_closure/4`, about line 4874), and `transcript/3` through `own_settlement?/3` (about line 1557). So the new accept rule belongs in `protocol/2`, the code that the readers rerun, not in `transition/2` alone.

## The option

- **Name, shape and default.** `start_link/1` takes one new optional key, `messages: :while_active`. `:while_active` is the only value. Without the key, the engine is today's engine, and there is no other default. A second `messages` key, or any other value (`:idle`, `true` and `nil` among them), is `{:error, :invalid_options_or_recovery}` before any Unit starts, as for `expiry_reports`. It is valid with `protocol_version` 1 and 2, and with or without `expiry_reports: :owner`.
- **Per Run, recorded.** The option holds for the whole Run. With it, the control of the `:configure` record gains exactly one key, `messages: :while_active`, and the fingerprint differs from the fingerprint of the same start without it (wrapped as `expiry_reports` wraps it; the builder fixes the order of the two wraps and states it in the README). Without it, the configure record, the control and the fingerprint are the same bytes as today. A restart of the same Run with the option added or removed is `:incompatible_recovery`. A new Run configured on the same Unit takes the option of its own start. The pure `step/2` reads it only from the recorded control.

## The rule with the option

- **Which input.** Only `message`. With the option, a `message` is accepted for the root when the lifecycle decision is `:permit_new_work` or `:remain_waiting`, whatever `active_count/1` is. So an unsettled slot or a held `pending_input` no longer keeps it from the root. Everything else that `transition/2` checks stays: generation open, no stop pending, the Run not paused, the root callable open, and room for the invocation entry.
- **Why only `message`.** `wake` is the host's timer for an idle Run, and agent-loop takes it as "no change, no request". `start` opens a Run, and agent-loop takes a later `start` as "no change". A `resource_event` has its own rule (`local_precedence/3` and a granted cursor), and agent-loop takes it as "no change". None of them needs the option for the decision of #930. Keeping them out leaves the Contract of each one, and its tests, as they are.
- **Root only.** The message is given to the root pattern, never to a nested callable, whichever callable owns the active slots.
- **What the root gets.** One ordinary pattern call with the `message` input exactly as committed (`kind`, `schema_id`, `schema_version`, `payload` and the `at_ms` that `input/4` read from the engine clock). It settles no slot: no slot, join, tracker, Budget entry or lifecycle wait changes, and the lifecycle phase stays what the decision left (a `:waiting` Run stays `:waiting`). `:none` charges nothing and stores the root's next state within its state bound. `{:some, request}` charges one count of the sealed request cap with a receipt whose `input_id` is the message's ID, and its request goes through the ordinary admission. That includes the 64-active bound, which counts the slots that are still open, and the first-excess rule (`over_cap`, generation closed; under `budget_rule: :pause` the pause with the input's `pause_deadline`). A state over the root's bound is `invalid_pattern_state`.
- **Duplicates and conflicts.** As for every input: the same ID with equal bytes is `{:ok, :duplicate}` and calls no pattern again, and changed bytes are `{:error, :input_id_conflict}`.

## Order

- **Commit order.** The root is given the message in the fold step of the message's own Unit record. A slot's outcome, answer or event that commits later is given to its callable in its own later step. One that committed earlier was given in its own earlier step. Nothing is held or reordered for the message.
- **Expiry pass and held reports.** The message's own expiry pass runs first, as for every input (`protocol_transition/2`). A slot past its deadline is settled before the root is given the message. With `expiry_reports: :owner`, the reports that this pass holds are given by the drain after the message's own pattern call, in their `order`, before `input/4` replies. This is the order that ELZ-351 states for a settling input. So the root can be given a message before the report of a slot that the same input's pass expired. Without `expiry_reports`, that slot settles `expired` and no pattern is told, as today.
- **Pause.** A message while the Run is paused gets `RemainPaused`. It is not given and not kept for `continue`, as today. Sent again after `continue` with the same ID and equal bytes, it is `{:ok, :duplicate}` and is not given; the host sends it again under a new input ID. Inputs retained while paused are given after `continue`, before its reply, so they come before any later message.
- **Stream heads.** The message is one Unit input row like every protocol input. It reads no event-source head, and it changes no stream head other than the Unit's own by its commit. The readers' head and owner rechecks (as ELZ-385 leaves them) treat its commit as they treat any other commit during a read.

## What the transcript and status record

- `transcript/3` gives the message its `:input` entry (`input_id`, `kind` `"message"`), as it does today for every committed protocol record. It gives no `:settlement` entry for it. The actions of a request that the root's call opens appear from their own gate, admission and later records, with `path` `[]`. No entry type, field or `by` kind is added.
- `status/1` keeps its keys. The classification of the message is the lifecycle decision, as today (`:remain_waiting` for a `:waiting` Run, `:permit_new_work` for an `:active` one). It is `record_size` when the invocation entry has no room, and the request classification when the root's output opens a request. Neither read says on its own whether the root was given a message. That is a stated Limit, as it is for `wake` today.
- `result/3` is unchanged: the message is not a completion source. `event_waits/3` lists the waits that a request opened by the root's call holds, as for any request.

## What stays refused

With the option, the root is still not given a `message` in each of these cases, and each case keeps today's classification and records:

- the Run is paused (`RemainPaused`), or paused at or after its pause deadline (`Expired`), or terminal (`Unchanged`), or the message is at or after the Run deadline (`Expired`, then the end of the Run);
- the root Budget's committed amount is at its cap (`EnterPause` under `budget_rule: :pause`, `RequestBudget` under `:finish`);
- the record is of another Run or of a stale Attempt (`late`), or its ID is a known invocation (`duplicate`);
- generation is closed, a stop is pending, or the root callable is closed;
- control has no room for its invocation entry (`record_size`).

`wake`, `start` and a granted `resource_event` while a slot is active are not given to the root, with or without the option. Without the option, a `message` while a slot is active is not given, as today.

## README and piece.json

- README, "Host construction": a paragraph after the `expiry_reports` paragraph states the option, its value, its validation, its record in control and fingerprint, and the order of the two fingerprint wraps.
- README, "Recorded cycle and obligations": the paragraph that ends "`:active` again" (today's lines 536–541) keeps its sentences and adds the exception. With `messages: :while_active`, a `message` is given to the root when the lifecycle permits new work or decides `RemainWaiting`, also while a slot is active. It settles no slot, and the order and the cases that stay refused are as above. The README states the order rule against held reports in the "Expiry reports" paragraphs as well, and qualifies the sentence there that becomes false with the option ("so an input that settles no slot and whose own pass holds a report is not given to the root: the root learns of its own expired slots from their reports"): with `messages: :while_active`, a `message` is given to the root before those reports.
- The transcript, event-wait and result sections do not change, except that the transcript section may say in one sentence that a message given under the option has only its `:input` entry. Do not edit the recheck sentences that ELZ-385 owns.
- `piece.json`: `contract` (the option in one sentence, and the `expiry_reports` clause "(counted active, so an input that settles no slot is not given to the root while one is held)" qualified for a `message` under the option), `limits` (the Limits below), `grounding` (a claim for the new test file and its negative controls), `operations.config` (the option) and `files` (the new test file). The `note` and `manifest_sha256` of the index row follow `piece.json`.
- The start options may gain members in a later in-place version; a caller matches on the ones it uses.

## agent-loop's README

The sentence of `pieces/workflow/agent-loop/README.md` that begins "No engine claim:" (today's lines 379–385; the clause is on lines 381–382) that says the ready engine "gives a pattern no `cancel`, late outcome or `message` while an action is open" becomes false for an engine started with the option. So it must change, and only it. It becomes, with the rest of the sentence unchanged:

> No engine claim: the ready `assembly/run-engine` completes a Run with a root `finish` only when it names a completed action (a `stopped` finish comes back refused), gives a pattern no `cancel` or late outcome while an action is open, gives it no `message` while an action is open unless the host starts the engine with `messages: :while_active` (then a `message` reaches the root pattern only, never a nested callable, and an agent-loop root takes the row "the text waits; no request"), and gives the first admitted finish of a nested callable …

agent-loop's step, Contract, `piece.json` (its limits and grounding do not name the message rule) and index row do not change. Its README is not in its `files`, so its `manifest_sha256` does not change. This is an exception to "One task is one Piece directory" (coordinator guide), by coordinator decision: a separate task would leave a ready Piece's README false between two merges. If the builder finds that agent-loop has to change behaviour, stop: that is its own task.

## Acceptance

New groups go in a new test file, `test/elzoo/run_engine_messages_test.exs`, listed in `piece.json`. Use the Piece's disposable PostgreSQL (`ELZOO_TEST_DATABASE_URL`) and the in-memory Store where the existing groups do. Use the helper's `fixture/1`, `start/2` overrides, `TestPattern.waiting/2` (which sends each input to the observer), `view/1`, `protocol_record/3` and `pad_invocations/2`, and `RunEngine.step/2` and `RunEngine.transcript/3`. The file may copy the private `restart/3`, `unit_state/1`, `assert_non_settling_refused/2` and `non_settling_switch/4` of `run_engine_test.exs` (about lines 5941, 5948, 10714 and 10726). No existing test changes. The helper may gain functions, and none of its existing functions changes. Each case asserts the exact sequence of pattern inputs per callable.

1. **`default_off_is_unchanged`**
   - Every existing test of the Piece passes unchanged, including ELZ-351's golden trace "the recorded scenario without the option has the trace of the base" with its committed values.
   - The #930 shape without the option: the root asks one `tool_call` (an Effect through the test bindings) and the test does not answer it, so the slot is `running` and the Run is `:waiting`. A `message` through `input/4` is `{:ok, :applied}`, and the root is not given it. The transcript holds its `:input` entry of kind `"message"`. After the tool outcome, the root's inputs are exactly `start`, then the outcome.
   - A restart of a Run configured without the option, started with it, is `:incompatible_recovery`, and the same holds the other way. `messages: :idle`, `true`, `nil` and a second `messages` key are each `{:error, :invalid_options_or_recovery}`, with no Unit started.
2. **`message_reaches_root_while_active`** (with `messages: :while_active`)
   - The same shape: the root is given the `message` input exactly as committed, while the tool slot stays `running`. The root returns `:none`, so the count and receipts are unchanged, and the slot's Budget entry and the lifecycle wait are unchanged. The Run stays `:waiting`. After the tool outcome, the root's inputs are exactly `start`, `message` and the outcome. The transcript has the message's `:input` entry and no `:settlement` entry in its record. The tool slot's `:settlement` entry is in the outcome's record.
   - A Run whose only open slot is a running `nested_callable` whose child has opened nothing (the Run is `:active`, the decision is `:permit_new_work`, `active_count` 1): the root is given the message, and the child is not given it: the child's inputs are exactly its `start`.
   - A Run whose only open slot is a running `local_work` (the Run is `:waiting`, the decision is `:remain_waiting`): the root is given the message.
   - The same message ID again with equal bytes is `{:ok, :duplicate}` and gives the root nothing. Changed bytes are `{:error, :input_id_conflict}`.
   - With `protocol_version: 2` and the option, a v2 `message` while a slot is active is given to the root (any v2 action whose slot stays active, for example a waiting `wait_event` as in ELZ-351's v2 case). With `protocol_version: 2` and `request_cap` 1, a message while that `wait_event` waits whose root request is the first excess: `event_waits/3` and `transcript/3` each return `{:ok, _}`.
3. **`message_opens_work`** (with the option)
   - While the tool slot is open, the root's call for a message returns a request with one `local_work` action. It is charged one count with a receipt whose `input_id` is the message ID. It is admitted, and its slot progresses while the tool slot stays open.
   - With the count at the cap (`request_cap` 1, the fixture's `budget_rule: :finish`), the root's request for a message is the first excess: classification `:over_cap`, receipt `over_cap`, generation closed, the Run terminal with outcome `:out_of_budget`, and the tool slot still `:running` (retained until its deadline).
4. **`root_only_message_only`** (with the option)
   - A nested child C is open (its parent `nested_callable` slot running, C's own `tool_call` running). A message is given to the root only: C's inputs are exactly its `start`.
   - While a slot is active, a `wake`, a later `start` and a granted `resource_event` are each not given to the root, and each keeps today's classification. For the `resource_event`, the root's script is a `resource_open` request, then a `tool_call` request, then `:wait`; after the open completes and the tool slot runs, the `resource_event` record goes through `step/2` with correlation `%{resource: "document"}` (the Resource setup of `each_kind_without_a_slot` in `run_engine_test.exs`, about line 10786, settles the open before the cursor is granted, so it has no active slot on its own).
   - While paused, a message is not given, and after `continue` it is not given either. The root's inputs show no `message`. After `continue`, the same ID with equal bytes is `{:ok, :duplicate}` with no pattern call, and a message under a new ID is given.
5. **`ordering_with_reports`** (with `expiry_reports: :owner` and the option)
   - The root's only open slot is an `ask_person`. A `message` at its deadline settles the slot `expired` in its own pass. Its report is held, and the root is given the message, then the report, before `input/4` replies: exactly `start`, `message` and the expiry `action_outcome`, in that order.
   - The same with `expiry_reports: :owner` alone: the root is given only the report, and no `message`.
6. **`room_and_replay`** (with the option)
   - Through `step/2`, take a state with an active slot, padded with `pad_invocations/2` to less room than the message's invocation entry. The message gets `:none` with classification `record_size`, no invocation entry and no pattern call (`assert_non_settling_refused/2`). With room, the same record is given to the root.
   - After groups 2 and 5, two restarts give equal views, slots, Budgets, callable states, receipts, count and number of Unit records, and they call no pattern and start no Effect. Two reads of `transcript/3` are equal.

Negative controls, each a temporary edit of `lib/` that is reverted and never committed. Record each failure in the pull request:

- the option ignored (today's rule with the option on): group 2 fails;
- the default flipped on (the option absent behaves as `:while_active`): group 1's #930 item fails;
- the rule applied to `wake`, `start` and `resource_event` as well: group 4's second item fails;
- the accept rule applied in `transition/2` instead of `protocol/2`: group 2's v2 first-excess item fails (`event_waits/3` and `transcript/3` return `{:error, :history}`);
- the message given to the callable that owns the newest active slot instead of the root: group 4's first item fails;
- the room check for the invocation entry skipped for the message: group 6's first item fails;
- the option left out of the fingerprint: group 1's restart item fails;
- with the option, the message refused while any slot holds a `pending_input` (only unsettled slots ignored): group 5's first item fails.

## Gate, review and build

Build on an a1.medium orb. Run `mix test pieces/assembly/run-engine/test` and `mix test pieces/workflow/agent-loop/test`. Then run the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which runs the tests of every ready Piece that depends on `assembly/run-engine` and the per-ID consumers, and `git diff --check`. The full review of the coordinator guide ("Reviewer by risk") finds the code and a test for each rule of this text. Then the exact-head hosted `check-piece` run and the merge queue follow.

## Kept open

Each can be added in place before the first release, because it is reached only through a value or a key that no caller passes today:

- a member that also gives `wake`, `start` or a granted `resource_event` to the root while slots are active;
- a member that gives a message to a named nested callable (for example a room's agent-loop turn under ELZ-348);
- a message kept while paused and given after `continue`;
- a transcript field or a `status/1` member that says whether the root was given an input that settles no slot.

## Limits to state

- Root only: a bot that runs as a nested callable is given no message while slots are active.
- A message while paused is not given and not kept. The host sends it again after `continue`, under a new input ID.
- A pattern whose Need is an engine that gives a message only while no action is open (`workflow/turn-policy`, its README and `piece.json`; a room included) is hosted on an engine started without the option. Nothing in that Piece becomes false, so it is not an owned path.
- Neither `status/1` nor `transcript/3` says on its own whether the root was given a message, as for `wake` today. The root's request, if any, appears from its own records.
- With `expiry_reports: :owner`, the root can be given a message before the report of a slot that the message's own expiry pass expired.
- That an agent-loop root then takes its row "the text waits; no request" rests on agent-loop's own step tests. This task runs the engine with a test pattern and no agent-loop composition, changes no root test, and does not turn the option on in the Wave 9 acceptance harness (ELZ-379).
- Listed scenarios on disposable PostgreSQL and the in-memory Store, not a proof.
