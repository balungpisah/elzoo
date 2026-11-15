# ELZ-236 — An agent start may name one skill, and its load is the first request, before the first model call

- Dependencies: ELZ-033, ELZ-142, ELZ-150, ELZ-208, ELZ-136, ELZ-182
- Output: none. A change in place of the ready Piece `workflow/agent-loop`, before the first release, with the same Piece ID. The Contract changes: the start payload may name one skill; its load is one tool action before model call 1; the step table gains one row. No spec key is added.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`. The small gate also runs the tests of the dependents `workflow/skill` and `runtime/recipe-test`.
- Allowed implementation path: `pieces/workflow/agent-loop/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and the `note` of its row in `entries`, because the `contract` changes). The Cure file does not change. No other part of `docs/plans/`, and no file of another Piece.

A host or a graph decision may already know which skill an agent needs.
Today the model must ask for it, which costs one model turn. Only a kept
model proposal makes a tool action, the start payload is exactly
`{"text": t}`, and a loop starts with no skill. This task lets the start
name one skill. The load still goes through a tool action of the
`pinned_skill` source and the unchanged `declare/3`, so the trust rule, the
bounds and the restart behaviour stay. The name gives no new authority: the
model could already ask for every skill of the package.

Facts checked on `main` (at the time of writing, at `6d140be`). They were
read, not run. Lines are "about", in
`pieces/workflow/agent-loop/lib/elzoo/agent_loop.ex` unless named. Confirm
each fact when you start, and if one differs, stop and ask.

- about 97 to 102: a `start` in phase `new` whose payload `message/1`
  accepts adds one `:user` entry and makes model call 1; any other payload
  gives no change and no request.
- about 668 to 677: `message/1` accepts exactly `{"text": t}` with `t` a
  non-empty text. A start with a second member is not a message today.
- about 59: `new/1` starts with `skills: []`. So no skill is loaded at a
  start, and `already_loaded` cannot happen for a start load.
- about 11 to 23 and 713 to 718: the spec keys are exact.
  `workflow/skill` (`test/elzoo/skill_test.exs`, about 1344 to 1358) and
  `runtime/recipe-test` (`test/support/recipe_test_helper.exs`, about 315
  to 321) build specs with exactly these keys, so a new key would break them.
- about 205 to 229, 287 and 573: action ids are `id:t:N:I`, where `N` is
  `state.turns`; `model_call/2` sets it to 1 before the first turn. So no
  action id `id:t:0:I` exists today.
- about 289 to 293: a kept call is resolved with `ToolRegistry.resolve/2`
  and checked with `ToolRegistry.check/2`; about 316 to 331:
  `tool_action/4` builds the action and keeps `source_kind`.
- about 335 to 368: `reduce/3` gives a not completed notice, `[tool result
  not readable]`, a declaration, or the result of `ToolResultLimit`.
- about 485 to 508: `declare/3` with its refusals; it reads the slot's
  `source_kind` and `index`.
- about 444 to 481: `close_turn/2` writes an `:assistant` entry when the
  turn has content or kept calls, a `:tool_result` entry for each slot whose
  result is `{:result, …}` with the `tool_use_id` of its echo, the note
  `id:n:N` only from the lines of proposals left out, and then the waiting
  messages. A start load has no proposal and no echo, so it cannot close
  through `close_turn/2` unchanged.
- `pieces/workflow/prompt-assembly/lib/elzoo/prompt_assembly.ex`, about 154
  to 174: a `:tool_result` entry with no earlier `:assistant` call is
  `orphan_tool_result`; about 228: a `:content` entry is sent as a `user`
  message. So the notice of a start load is a `:content` entry.
- `pieces/integration/ai-text/lib/elzoo/ai_text/request.ex`, about 165 to
  200: each message is checked alone; no rule on the order of roles was
  found. Today the note of a turn and a waiting message already follow each
  other as two `user` messages (`close_turn/2`, about 466 to 480; README
  about 127 to 131).
- `test/elzoo/agent_loop_test.exs`:
  - helpers: `descriptor/2` (about 34), `source/4` (about 43),
    `sources/0` (about 46 to 54), `tools/0` (about 60 to 69), `spec/1`
    (about 71 to 88), `new!/1` (about 90), `start/1` (about 118),
    `outcome/4` (about 121), `model/4` (about 131), `proposal/4` (about
    142), `result/2` (about 163), `declared/3` (about 171), `notice/1`
    (about 204), `action/4` (about 217), `model_call/3` (about 236), `run/2`
    (about 262 to 271), `checked!/2` (about 273 to 283), `trace/2` (about
    293), `messages/1` (about 295).
  - `checked!/2` asserts for every output of `run/2` that the request
    passes `PatternStep.decode/1` and each model call payload passes
    `Request.decode/2` with 65,536 bytes.
  - the `pinned_skill` source `skills` of `sources/0` has one tool `load`
    whose schema (`@schema`, about 11 to 15) requires `q`. A start argument
    `{"name": …}` does not pass its check, so the new tests add a
    `pinned_skill` source with a `name` schema.
  - the group `engine_refusal_as_content` (about 686 to 746) runs
    `translate/2` of both providers on a decoded request (about 714 to 717).
  - the named groups are top-level `test` blocks (about 307 to 1177). No name
    of the Acceptance below is in use.

## The changed Contract

**The start form.** A start payload may be exactly
`{"text": t, "skill": {"tool": alias, "name": name}}`: `t` a non-empty text,
`skill` a map with exactly these two members, both texts. Any other payload
is handled as today. No spec key is added.

**The start load.** In phase `new`, for this form: the `:user` entry
`id:u:1` is added as today. Then `ToolRegistry.resolve(snapshot, alias)`:

- `{:resolved, tool}`, `tool.source_kind == "pinned_skill"` and
  `ToolRegistry.check(tool, %{"name" => name}) == :ok`: the request is one
  action, the tool action that `tool_action/4` builds for that tool with the
  arguments `{"name": name}` and the id `id:t:0:1`. No model call yet.
- any other resolution: no action; the notice `[skill not loaded:
  not_resolved]`.
- resolved, but another source kind: no action; `[skill not loaded:
  not_permitted]`.
- resolved, `pinned_skill`, but the check fails: no action; `[skill not
  loaded: validator_disagreement]`.

**Its outcome.** The applied outcome of `id:t:0:1` is reduced as step 3 of
"One turn" reduces a tool outcome: a declaration goes to `declare/3`
unchanged and gives `[declaration accepted]` or `[declaration refused:
REASON]`; a not completed outcome gives its notice; another schema gives
`[tool result not readable]`. Any other completed result gives `[skill not
loaded: not_a_declaration]`: it never goes to `ToolResultLimit` and makes no
store action.

**The history.** The notice of the start load, or of the case with no
action, becomes one `:content` entry `id:n:0`, marked as every notice is.
Then each waiting message becomes a `:user` entry, then model call 1
(`id:m:1`). No `:assistant` and no `:tool_result` entry is written for the
start load. An accepted start load leaves `[declaration accepted]` in the
history. `turns` counts model calls only; the start load is not a turn.
`cancel` and `run_ended` while the load is open close the loop as today; a
`message` waits as today.

**The trust rule** stays "source kind only": only a tool of kind
`pinned_skill` can load a skill, at start as later.

**README and `piece.json` state:** the start form in the Payloads table; a
new step-table row for phase `new` and a start that names a skill; the ids
`id:t:0:1` and `id:n:0` in the identities paragraph; the four `[skill not
loaded: …]` notices; in Limits, that the provider acceptance of the notice
as a `user` message after the start message is shown on `Request.decode/2`
and the pure `translate/2` only. The `contract` gains one clause, for
example "a start may name one skill, whose load is one tool action of a
pinned_skill tool before model call 1, applied by the same declaration
rule". The grounding test claim names the new groups and their count. The
`note` of the index row equals the new `contract`.

## Task

1. Confirm the facts above at your base.
2. **A gate before any change of `lib/`.** Build the history of an accepted
   start load by hand: a `:user` entry and a `:content` entry with a notice.
   Check that `PromptAssembly.build/2` builds a request from it, that the
   request passes `Request.decode/2` with 65,536 bytes, and that
   `translate/2` of `integration/ai-text-anthropic` and
   `integration/ai-text-openai` accept it, in the way of
   `engine_refusal_as_content`. Record the commands and results. If one of
   them refuses, stop and ask the coordinator, and make no change.
3. Make the change of the Contract in `lib/elzoo/agent_loop.ex`. No other
   clause of the step table changes.
4. Update the README and `piece.json` as above.
5. The rule for existing tests: no existing test changes. If one fails,
   stop and ask.

## Acceptance

New top-level named tests in `test/elzoo/agent_loop_test.exs`. Each runs
its trace through `run/2`, so `checked!/2` checks every request. The tests
add a `pinned_skill` source `sk` with one descriptor `load_skill` whose
schema has a `name` property with an `enum` (built with `descriptor/2` and
`source/4`), and use `spec(%{sources: sources() ++ [that source]})`.

1. `start_loads_skill`: the first output is exactly one request with the
   action `run:t:0:1` for `sk_load_skill` and `{"name": name}`. After a
   completed declaration with a skill and a listing (`declared/3`), the next
   output is model call 1: the system message holds the instructions, the
   messages are the start text and the notice `[declaration accepted]` as a
   `user` message, and the tool list holds the listed tools. A `message`
   that arrives while the load is open follows the notice.
2. `start_load_refused`: `instructions_over_bound` (a body over 16,384
   bytes), `too_many_tools` (a listing that would pass 64 tools),
   `invalid_declaration`, a `refused` outcome with a reason, and a completed
   result that is not a declaration (`not_a_declaration`). Each gives its
   notice as `run:n:0`, then model call 1 with no instructions and the tool
   list of the start.
3. `start_load_not_pinned_skill`: an alias of kind `other` (`files_read`)
   and one of kind `host_listing` (`hub_list`) make no action; the first
   output is model call 1 with `[skill not loaded: not_permitted]`.
4. `start_load_not_run`: an unknown alias gives `not_resolved`; a name
   outside the `enum` gives `validator_disagreement`; a `skill` member with
   an extra key or a non-text member gives no change and no request, as
   today.
5. `start_load_survives_refold`: the trace of group 1, continued by one
   model turn and an answer, cut after each input and run again from
   `new!/1`, gives the same prefix of states and outputs. The id `run:t:0:1`
   appears in one request only.
6. `model_repeat_after_start_load`: a later model load of the same skill
   gives `[declaration refused: already_loaded]`, and the system message
   holds the instructions once.
7. `existing_behaviour`: every existing test passes with an unchanged body.

Negative controls, each a temporary edit that is reverted and never
committed. Record the failing output in the pull request body.

- Skip the source-kind check: `start_load_not_pinned_skill` fails.
- Put the skill into the state without `declare/3`: `start_load_refused`
  fails.
- Write the notice as a `:tool_result` entry instead of `:content`:
  `start_loads_skill` fails (the request is not built).

## Evidence and gate

Run `mix test pieces/workflow/agent-loop/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. The small gate also
runs the tests of `workflow/skill` and `runtime/recipe-test`; the second
needs PostgreSQL (AGENTS.md section 5 says what to record if it cannot run).
The index row follows in the last commit (AGENTS.md section 3). Record the
results of the gate of task step 2 in the pull request body.

## Review risk

Medium to high. One independent review by a strong reasoning model. The
reviewer checks:

- that only a tool of kind `pinned_skill` can make the start load, and that
  the load is applied only through `declare/3`;
- the step table, the history shape (`id:n:0`, no `:assistant` and no
  `:tool_result` entry) and the gate of task step 2;
- that every other start payload, and every existing transition, is
  unchanged;
- that the README and `piece.json` claim no provider acceptance beyond
  `Request.decode/2` and `translate/2`.

## Not in scope

- The harness and the mapping of a graph `call` node to the start form
  (ELZ-237).
- More than one skill at start; a skill named by a `message` or a later
  `start`.
- Any spec key, and any change of the Cure decisions.
- A check that a listing of a `pinned_skill` result targets a source of
  that skill.
