# ELZ-237 — The recipe harness answers skill calls with the real skill Piece, and a graph node can start an agent with a skill loaded

- Dependencies: ELZ-033, ELZ-181, ELZ-183, ELZ-199, ELZ-182, ELZ-168, ELZ-235, ELZ-236
- Output: none. A change in place of the ready Piece `runtime/recipe-test`, before the first release, with the same Piece ID. The Contract changes: a new spec member `skills`; with it, an agent's calls of the two tools of the `pinned_skill` source are answered by `Elzoo.Skill`, and a load reaches the agent as a declaration; a `call` node into an agent whose input holds a member `skill` starts that agent with the start form of ELZ-236. `piece.json` gains the Piece dependency `workflow/skill`. It is a dependency between Pieces, inside the lane of this Piece: no `mix.exs` or `mix.lock` change.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/recipe-test/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and the `note` of its row in `entries`, because the `contract` changes). No other part of `docs/plans/`, and no file of another Piece.

RC-67 asks that, with the harness of RC-66, a skill load survives a restart
and is not done again. Today the harness delivers every completed value of
an agent tool call as marked text, so a load never reaches the agent as a
declaration. ELZ-235 makes a load list the declared tools of its skill, and
ELZ-236 lets an agent start with a named skill. This task lets the harness
use both: it answers the skill calls with the real `Elzoo.Skill`, and a
graph node can choose the skill of an agent child.

Facts checked on `main` (at the time of writing, at `6d140be`). They were
read, not run. Lines are "about". `helper` is
`pieces/runtime/recipe-test/test/support/recipe_test_helper.exs`. Confirm
each fact when you start, and if one differs, stop and ask.

- `README.md` about 59 to 76 and helper about 42 to 44 and 79 to 93: the
  spec keys are exact; another key is `:invalid_spec`.
- `README.md` about 118 to 126: a completed value of an agent tool reaches
  it as marked text; about 265 to 266: "A skill load is delivered as marked
  tool text, not as a declaration."
- helper about 866 to 890 (`answer/4`): the harness itself puts the outcome
  of a held call into the engine with `RunEngine.input/4`, from the next
  script entry of its key. About 897 to 914 (`outcome/4`) and 924 to 939
  (`payload/2`): every completed value of an `elzoo.agent-loop.tool-call`
  becomes `{"content": marked text, "media_type": "text/plain",
  "encoding": "utf8"}`. About 941: another class gets `{"reason": reason}`.
  About 892 to 895: `refused` is `not_dispatched`. The scripted Adapter
  (`lib/elzoo/recipe_test/scripted_adapter.ex`, about 16 to 36) only waits
  for the reply and gives an acknowledgement; it does not shape the outcome.
- helper about 788 to 801 (`drain/1`): a held call keeps `adapter`, `key`
  and `schema_id`, read from the intent arguments that `effect_facts/4`
  writes (about 570 to 601: `action_id`, `key`, `schema_id`). The arguments
  of the tool call are not in them. `asked` counts every held call.
- helper about 384 to 395 (`start_form/3`): an agent at a node starts with
  `{"text": canonical(input)}` (about 390 to 391). About 611 to 628
  (`nested/2`): the child of a `call` node is built with the `input` of the
  `nested_callable` payload. About 315 to 321: an agent callable is built
  with `AgentLoop.new/1` over `spec.sources`.
- helper about 169 to 175: the package is checked only through
  `RecipeCheck.check/2`. `piece.json` of this Piece does not list
  `workflow/skill` or `domain/recipe-package`.
- `README.md` about 164 to 171: a restart drops every held call; a dropped
  call uses no script entry, and the engine records the Effect as `unknown`.
  About 180: `asked` counts a dropped call.
- `pieces/workflow/tool-registry/lib/elzoo/tool_registry.ex`, about 166 to
  178: a source id of at most 32 characters of `[a-zA-Z0-9_-]` followed by
  `_load_skill` matches `[a-zA-Z0-9_-]{1,64}`, so its alias is
  `<id>_load_skill`.
- A graph tool node's value can be given to a later `call` node as one of
  its needs with no change outside this Piece:
  - `pieces/domain/recipe-graph/README.md` about 29 to 47: every node has
    `needs` and `gives`; a `data` link joins a give of one node to a need of
    another, with the same slot schema.
    `pieces/domain/recipe-graph/lib/elzoo/recipe_graph.ex` about 254 to 263:
    a `decision` node needs one `choice` link for each of its choices.
  - `pieces/workflow/graph-run/lib/elzoo/graph_run.ex` about 422 to 431:
    a completed node result `{"gives": gives}` that holds each give of the
    node is kept; about 476 to 487 stores it; about 311 to 315 (`needs/2`)
    builds the input of a node from its data links; about 215 to 219: the
    `nested_callable` payload of a `call` node has that map as `input`.
  - helper about 918 to 919: a scripted value of a graph tool node becomes
    `{"gives": value}`. `README.md` about 213: a Lua tool node that
    completes gives `{"gives": result}`, as the test at about 497 to 530 of
    `test/elzoo/recipe_test_lua_test.exs` shows.
- A Lua flow cannot reach the load: a module call of a Lua tool is a
  `tool_call` only to the tools of its own source
  (`pieces/workflow/lua-tool/lib/elzoo/lua_tool.ex` about 179 to 188 and
  317 to 333), and that source has kind `other`
  (`pieces/runtime/lua-binding/lib/elzoo/lua_binding.ex` about 78 to 99).
- `test/elzoo/recipe_test_test.exs`:
  - builders: `package/1` (about 91 to 112; its `"skills"` is `[]`),
    `recipe/1` (about 114), `node/5` (about 65), `data/4` (about 77),
    `choice/3` (about 80), `tool/1` (about 129), `files/1` (about 138),
    `facts/1` (about 146), `cost/2,3` (about 156 to 158), `agent_config/0`
    (about 161), `decision_config/0` (about 180), `answer/1` (about 191),
    `decided/1` (about 194), `base_spec/5` (about 204 to 219),
    `graph_spec/1` (about 222 to 261), `agent_spec/1` (about 263 to 273),
    `proposal/2` (about 275), `child_id/2` (about 619 to 622).
  - `test/elzoo/recipe_test_lua_test.exs` has its own `base_spec/7` (about
    189 to 205).
  - describe groups: `start_refusals`, `adapter_allow_list`,
    `agent_with_tools`, `decision_repair`, `graph_with_children`,
    `same_spec_same_record`, `unscripted_call`, and in the Lua file
    `tool_start_refusals`, `lua_tool_module_call`,
    `model_graph_after_restart`, `model_graph_refused`,
    `same_lua_spec_same_record`. No name of the Acceptance below is in use.

## The changed Contract

**The spec member `skills`.** It is `nil`, or exactly
`%{id: id, files: files, descriptors: descriptors}`: `id` a text, `files` a
map (skill name to the `files` that `Skill.read/4` gave), `descriptors` a
list. Any other value is `:invalid_spec`. Every existing spec gets
`skills: nil`.

**Skill calls.** With `skills` set, the package is the value of
`RecipePackage.decode(spec.package)`, and `arguments` is the `arguments`
member of the tool call payload:

- a held call of the key `{:tool, id <> "_load_skill"}` with the schema
  `elzoo.agent-loop.tool-call` is answered with
  `Skill.load(id, package, descriptors, arguments)`;
- a held call of `{:tool, id <> "_read_skill_file"}` with that schema is
  answered with `Skill.read_file(package, files, arguments)`;
- `{:ok, payload}` is a `completed` outcome under
  `elzoo.agent-loop.tool-result` with the payload unchanged (dispatch
  `dispatched`); `{:error, reason}` is a `refused` outcome with
  `{"reason": Atom.to_string(reason)}` (dispatch `not_dispatched`);
- such a call uses no script entry. It counts in `asked` and is one
  delivery, as every call. A script entry for these two keys is never used
  and shows in `unused`.

How the harness reads the arguments of a held call is the worker's choice
(for example, more members in the intent arguments of `effect_facts/4`); say
which in the pull request. A Run with `skills: nil` gives the same record as
today.

**The sources.** The test author puts the list of
`Skill.sources(id, package, descriptors)` into `spec.sources`, as for every
other tool of the Run. The tools of the per-skill sources are scripted by
their aliases, as other tools are.

**The start of an agent at a node.** With `skills` set, when the `input` of
the `call` node holds a member `"skill"` that is a text, the agent child
starts with `{"text": canonical(input), "skill": {"tool": id <>
"_load_skill", "name": input["skill"]}}`. In every other case the start
form is the one of today. The start of a root agent does not change.

**README and `piece.json` state:** the spec member; the answer of the two
skill tools; the start form of an agent at a node; the Needs (the sources of
`sources/3` in `sources`, the files and descriptors of the same package);
the Limits sentence on a skill load is replaced by what is now shown; the
restart case of RC-67 is shown with this harness. `piece.json`: add
`workflow/skill` to `dependencies`, and `domain/recipe-package` if the
helper calls `RecipePackage.decode/1` itself; the `contract` gains one clause
on skill calls; the grounding names the new groups. The `note` of the index
row equals the new `contract`.

## Task

1. Confirm the facts above at your base.
2. Make the change of the Contract in the helper (and in `lib/` only if a
   compiled module must change; say why in the pull request).
3. Update the README and `piece.json`.
4. Existing tests: `base_spec/5` and `base_spec/7` gain `skills: nil`;
   `package/1` may take the skills as an optional second argument. No
   existing assertion changes. If an existing test fails, stop and ask.

## Acceptance

New describe groups in `test/elzoo/recipe_test_test.exs`. None needs the Lua
sandbox. Each builds a package with skills from `Skill.read/4` entries,
`sources` with `files/1` and the list of `Skill.sources/3`, and a spec with
`base_spec/5`.

1. `skill_load_through_engine`: a root agent; model turn 1 asks for
   `sk_load_skill` with a skill that declares one tool. The load outcome in
   the record is `completed` with the declaration payload. Model call 2 has
   the instructions in its system message and the alias of the skill tool in
   its tools. Model turn 2 calls that tool, scripted `{:completed, …}`; the
   agent answers; the outcome is `completed` and `unused` is `%{}`.
2. `skill_load_after_restart`: the spec of group 1 with `restart_after` set
   so that the restart happens while the call of the skill tool is held
   (after the deliveries of model call 1, the load and model call 2). The
   record shows `restarted: true`; one load action and one load outcome;
   `asked` holds `{:tool, "sk_load_skill"} => 1`; the outcome of the
   dropped skill tool call is `unknown`; the model call after the restart
   has the instructions in its system message and the skill tool in its
   tools. The dropped call uses no entry, so a skill-tool key with one entry
   shows 1 in `unused`.
3. `declared_tool_refused_at_use`: a scripted `{:refused, "not_permitted"}`
   for the skill tool. The next model call holds `[tool call not completed:
   refused: not_permitted]` and the instructions stay in its system message.
4. `decision_chooses_skill`: a root graph in the way of `graph_spec/1`. A
   `decision` node with the choices `alpha` and `beta` (the two skill names)
   gives `value`; a data link gives it to the need `skill` of a `call` node
   into an agent; the choice `alpha` routes to that node and `beta` to
   another node (`recipe_graph.ex` needs a route for each choice). The
   scripted decider decides `alpha`. The first action of the agent child
   (found with `child_id/2`) is its load `…:t:0:1` with
   `{"name": "alpha"}`, and no model call of the child comes before it. Its
   model call 1 holds the instructions of `alpha`.
5. `tool_result_chooses_skill`: a root graph with a tool node `files_read`
   that gives `skill`, scripted `{:completed, %{"skill" => "alpha"}}`, and a
   data link to the need `skill` of a `call` node into an agent. The checks
   of group 4 hold.
6. `existing_behaviour`: every existing test passes; the only changes are
   those of task step 4.

Negative controls, each a temporary edit that is reverted and never
committed. Record the failing output in the pull request body.

- Deliver the load as marked text, as today: `skill_load_through_engine`
  fails.
- Start the agent at a node with `{"text": canonical(input)}` only:
  `decision_chooses_skill` and `tool_result_chooses_skill` fail.

## Evidence and gate

Run `mix test pieces/runtime/recipe-test/test` with a disposable PostgreSQL
through `ELZOO_TEST_DATABASE_URL`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. Run the new groups
once more in one launch with `--repeat-until-failure 5` and record the
command and its exit code. The index row follows in the last commit
(AGENTS.md section 3).

## Review risk

Medium. One independent review. The reviewer checks:

- that the harness answers only the two tools of the source `skills.id`,
  with the real `Elzoo.Skill`, and that every other call goes through the
  script as today;
- that a Run with `skills: nil` gives the same record as before (every
  existing test unchanged);
- the restart group: one load, counted once, and the state after the
  restart from the record;
- the new dependency closure (`workflow/skill` and its providers);
- that the README and `piece.json` claim no real policy refusal.

## Not in scope

- A real policy refusal of a declared tool: group 3 is a scripted refusal.
- A Lua flow that chooses a skill: a module call of a Lua tool reaches only
  the tools of its own source, of kind `other` (facts above).
- A root agent that starts with a skill loaded.
- Skill files other than through `Skill.read_file/3`.
- Any change outside `pieces/runtime/recipe-test/`.
