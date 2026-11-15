# ELZ-238 — The recipe harness takes an engine gate, so a declared skill tool that the principal may not use is refused by the engine

- Dependencies: ELZ-033, ELZ-181, ELZ-183, ELZ-199, ELZ-182, ELZ-235, ELZ-236, ELZ-237
- Output: none. A change in place of the ready Piece `runtime/recipe-test`, before the first release, with the same Piece ID. The Contract changes: a new spec member `gate`. With it, the engine of the Run uses that gate, so a test can show a real refusal of the engine. No new Piece dependency, no `mix.exs` or `mix.lock` change.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/recipe-test/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and the `note` of its row in `entries`, because the `contract` changes). No other part of `docs/plans/`, and no file of another Piece.

RC-67 asks for "a skill whose declared tool is not permitted for the
principal (the instructions load, the tool is refused at use)". Today the
harness shows only a scripted `refused` entry for such a tool
(`declared_tool_refused_at_use`). The refusal never comes from the engine:
the harness always runs the engine with a gate that allows every action.
The engine already has the check that this needs. Its gate gets each
checked action and the acting principal, before Budget, Authorization and
Approval, and a denial is a `refused` outcome with its reason. This task
lets a test give that gate. It adds no policy layer: the gate is the
engine's own option, passed through unchanged.

Facts checked on `main` (at the time of writing, at `1d57233`). They were
read, not run. Lines are "about". `helper` is
`pieces/runtime/recipe-test/test/support/recipe_test_helper.exs`. Confirm
each fact when you start, and if one differs, stop and ask.

- `pieces/assembly/run-engine/README.md` about 37: the start option `gate:
  %{id, version, call}`, `call` of arity 2. About 165 to 166: a request runs
  payload schema, Run-wide identity, gate, Budget, Authorization, Approval,
  in that order. About 279 to 284: the gate gets the checked action and the
  trusted proposer, effect class and tenant; a denial gives its own refusal
  and no reservation, approval or intent; a malformed return is
  `gate_failure`.
- `pieces/assembly/run-engine/lib/elzoo/run_engine.ex` about 2881 to 2906
  (`sample_gate/2`): `call.(checked, %{proposer: principal, effect_class:
  binding.effect_class, tenant: tenant})`; `{:deny, reason}` with a reason of
  `[a-z0-9_]{1,64}` is kept, any other result is `gate_failure`. About 1159
  to 1187: only the gate `id` and `version` enter durable state.
- `pieces/assembly/run-engine/examples/document_publication.exs` about 42:
  the checked action has the form `{:PatternStep, %{"actions" => [action]}}`.
- `pieces/assembly/run-engine/test/elzoo/run_engine_test.exs` about 1030 to
  1032: a gate `{:deny, "resampled"}` gives the slot outcome `refused` with
  that reason.
- `pieces/assembly/run-engine/test/support/run_engine_test_helper.exs` about
  576 and 579: the fixture sets `principal: "principal"` and the gate `%{id:
  "gate", version: 1, call: fn _, _ -> :allow end}`.
- helper about 459 to 474: the overrides of every engine start (also the one
  after the restart) set no `gate`, so the fixture gate allows every action.
  About 524 to 567: every agent tool call has one binding, effect class
  `publish`, so the Authorization step cannot tell one tool from another; the
  gate sees the action and its alias.
- helper about 43 to 45 (`@keys`) and 79 to 95 (`check_shape/1`): the spec
  keys are exact; another key is `:invalid_spec`.
- `pieces/workflow/agent-loop/lib/elzoo/agent_loop.ex` about 444: an outcome
  that is not completed gives `[tool call not completed: CLASS: REASON]`.
  `pieces/workflow/agent-loop/test/elzoo/agent_loop_test.exs` about 743
  (`engine_refusal_as_content`): an outcome of the schema
  `elzoo.run-engine.refusal` is read this way.
- `README.md` about 63 to 79: the spec table. About 174 to 175: "A refusal of
  a declared tool at use is only scripted here". About 317 to 319 (Limits):
  "A declared tool that is refused at use is a scripted `refused` entry, not
  a policy refusal of the engine or the registry."
- `piece.json` about 28 (`contract`), 33 (`limits`) and 53 (grounding of
  `test/elzoo/recipe_test_test.exs`, "declared_tool_refused_at_use (a
  scripted refusal, not a policy refusal)").
- `test/elzoo/recipe_test_test.exs`: `base_spec/5` about 204 to 219;
  `skill_agent_spec/1` about 825 to 828; `skill_script/1` about 830 to 839;
  `record_outcomes/2` about 844 to 850; `system_text/1`, `tool_names/1`,
  `result_of/2` about 861 to 873; `declared_tool_refused_at_use` about 1025
  to 1044. `test/elzoo/recipe_test_lua_test.exs`: its own `base_spec/7`
  about 189. The describe groups in use are `start_refusals`,
  `adapter_allow_list`, `agent_with_tools`, `decision_repair`,
  `graph_with_children`, `same_spec_same_record`, `unscripted_call`,
  `skill_load_through_engine`, `skills_shape`, `skill_load_after_restart`,
  `declared_tool_refused_at_use`, `decision_chooses_skill`,
  `tool_result_chooses_skill`. No name of the Acceptance below is in use.

## The changed Contract

**The spec member `gate`.** It is `nil` or a function of arity 2. Any other
value is `:invalid_spec`. Every existing spec gets `gate: nil`.

- `nil`: the engine runs with the gate of today. A Run gives the same record
  as before.
- a function `f`: every start of the engine (the one after the restart
  included) gets `gate: %{id: "recipe-test", version: 1, call: f}`. The engine
  calls it as its README says. The harness does not call it, wrap it or read
  its result.

A denied call never reaches the harness: it uses no script entry and is not
counted in `asked`.

**README and `piece.json` state:** the spec member; that a denial is the
engine's refusal, with the reason of the gate; the Limits sentence on a
scripted refusal is replaced by what is now shown. The group
`declared_tool_refused_at_use` stays, and is still called a scripted
refusal. `piece.json`: the `contract` gains one short clause ("an engine gate
that the test gives"); the grounding names the new groups and the negative
controls. The `note` of the index row equals the new `contract`.

## Task

1. Confirm the facts above at your base.
2. Add the spec member in the helper. Change `lib/` only if a compiled
   module must change; say why in the pull request.
3. Update the README and `piece.json`.
4. Existing tests: `base_spec/5` and `base_spec/7` gain `gate: nil`. No
   existing assertion changes. If an existing test fails, stop and ask.

## Acceptance

New describe groups in `test/elzoo/recipe_test_test.exs`. None needs the Lua
sandbox.

1. `gate_shape` (no Run starts): `gate` set to `:nope`, `%{}`, a text and a
   function of arity 1 is `{:error, :invalid_spec}` each; a spec with no
   `gate` key is `{:error, :invalid_spec}`.
2. `declared_tool_denied_by_gate`, test 1: the spec of
   `skill_agent_spec/1`, with a script that has the three model turns of
   `skill_script/1` and **no** entry for the skill tool `sk-1_tool-identity-one`.
   The gate denies, with `{:deny, "not_permitted"}`, a `tool_call` action
   whose payload alias is that tool when the proposer is `"principal"`; it
   allows every other action. The record shows:
   - `outcome` is `:completed` and `unused` is `%{}`;
   - `asked` is `%{{:model, "scripted-model"} => 3, {:tool, "sk_load_skill"} => 1}`:
     the skill tool never reached the harness;
   - the load outcome is `completed` with the declaration payload;
   - the outcome of the skill tool call is `refused`, its reason is
     `not_permitted` and it names the gate `recipe-test`, version 1;
   - model call 3 holds `[tool call not completed: refused: not_permitted]`
     for that call, the instructions of the skill in its system message and
     the skill tool in its tools.
3. `declared_tool_denied_by_gate`, test 2: the same gate rule, but for the
   proposer `"another-principal"`, and a script with one completed entry for
   the skill tool. The tool is asked once and completes. So the gate decides
   by the principal, not only by the tool.
4. `existing_behaviour`: every existing test passes; the only changes are
   those of task step 4.

Negative controls, each a temporary edit that is reverted and never
committed. Record the failing output in the pull request body.

- The harness ignores `spec.gate` (it keeps the gate of the fixture): test 1
  fails, because the skill tool reaches the harness with no script entry
  (`unscripted_call`).
- A gate that denies the tool for every proposer: test 2 fails.

## Evidence and gate

Run `mix test pieces/runtime/recipe-test/test` with a disposable PostgreSQL
through `ELZOO_TEST_DATABASE_URL`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. Run the new groups
once more in one launch with `--repeat-until-failure 5` and record the
command and its exit code. The index row follows in the last commit
(AGENTS.md section 3).

## Review risk

Low to medium. One independent review. The reviewer checks:

- that the gate is passed to the engine unchanged, at each start, and that
  the harness adds no policy, wrapper or decision of its own;
- that a Run with `gate: nil` gives the same record as before;
- that the README and `piece.json` say "the engine gate", not a policy of
  the context or a refusal of the registry;
- that `declared_tool_refused_at_use` is still called a scripted refusal.

## Not in scope

- The Authorization step of the engine (the policy and the authority of the
  context): every agent tool call has one binding and one effect class here,
  so a policy cannot tell one tool from another. A per-tool effect class is
  not part of this task.
- A spec member for the principal: the principal of the fixture is used.
- Any change of `workflow/skill`; its text follows in its own task.
- Any change outside `pieces/runtime/recipe-test/`.
