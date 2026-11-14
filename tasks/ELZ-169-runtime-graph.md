# ELZ-169 — Accept a graph that a model gives at run time

## Scope and reuse

- Dependencies: ELZ-033, ELZ-114, ELZ-136, ELZ-161, ELZ-167
- Output: `workflow/runtime-graph`, one public module `Elzoo.RuntimeGraph`; release V1B; RC-64 run-time portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/runtime-graph/**` and its index/generated changes under AGENTS.md section 3.

Admit the rest of RC-64. A model can give a graph as plain data during a Run.
This Piece decides whether that graph may run: it adds the graph to the
recipe of the Run as one more `graph` callable, runs the checker of ELZ-167
on the result, and applies the limits of the agent that gave it. It is a pure
function. It runs nothing, stores nothing and grants nothing.

Implement only the acceptance groups below. Use `Elzoo.RecipeCheck.check_graph/3`
(ELZ-167), `Elzoo.RecipeGraph` (ELZ-161) and `Elzoo.ToolRegistry.resolve/2`
(ELZ-136) as they are on main. Write no second structural validator and no
second cost sum. Add no engine code, no agent logic, no options, behaviours
or hooks. Edit no ready Piece, shared path, pin or CI file. No fixtures
directory is needed: each test input is a literal neutral map.

Facts checked on main, and for ELZ-167 in its published task:

- `workflow/recipe-check` (ELZ-167): `check_graph(recipe, declared, facts)`
  checks every callable of a recipe map, gives located reasons relative to
  that map, and bounds the upper cost of the `root` by `cap`.
- `domain/recipe-graph` (ELZ-161): a `graph` callable is exactly `name`,
  `kind`, `input`, `output`, `nodes`, `links`, `input_slots`. Unknown keys
  fail closed. Recursive names are refused. An `agent` callable holds only
  `binding`, so the recipe does not say which callables and tools an agent
  may use: the host supplies that.
- `workflow/pattern-step` (ELZ-114): the payload of a `nested_callable`
  action is opaque. This Piece defines no action.
- `workflow/output-repair` renders a located violation as one line
  `<path>: <code>`, with `$` for the root, `.name` for a key and `[i]` for an
  index. The same line form is used here; that Piece is not called.

## Interface: `Elzoo.RuntimeGraph`

`accept(proposal, context)` returns `{:ok, accepted}`, `{:refused, reasons}`
or `{:error, :invalid_context}`.

`proposal` is what the model gave, decoded from JSON: a string-keyed map with
exactly `nodes`, `links`, `input_slots`, `input` and `output`, in the form of
the members of a `graph` callable of ELZ-161. It has no name, no bindings and
no rules.

`context` is a string-keyed map with exactly these keys, all from the host:

- `recipe`: the neutral recipe map of the Run.
- `name`: the name of the new callable: text of 1 to 128 bytes that no
  callable of `recipe` has.
- `callables`: a list of at most 64 unique names of callables of `recipe`
  that the agent may call.
- `agent_tools`: a snapshot of `Elzoo.ToolRegistry.snapshot/1` with only the
  tool sources of the agent.
- `declared`: the `declared` operand of `check_graph/3`.
- `facts`: the `facts` operand of `check_graph/3` for `recipe`. Its `cap` is
  the budget share of this graph: the largest upper cost that the agent may
  give to it.
- `tool_costs`: a map from a tool name to an estimate (1 to 2^53): the upper
  cost of one call of that tool from the new graph. At most 1,000 entries.
- `ask_cost`: an estimate, or `null` when the new graph may not ask a person.
- `max_nodes`: 1 to 64. `max_depth`: 1 to 16. `depth`: 1 to 16, the nesting
  depth of the agent node that gave the graph, with the root of the Run as 1.

A `context` in another shape, a `name` that `recipe` already has, or an entry
of `callables` that `recipe` does not have is `{:error, :invalid_context}`: an
error of the host, not a verdict on the graph.

A reason is `%{path: path, code: code}` as in ELZ-167. Paths are relative to
`proposal`, for example `["nodes", 2]`. The check has three stages; a stage
runs only when the stage before it gave no reason.

**Stage 1, the proposal as data.** Reasons with the path `[]`:
`:invalid_shape` when `proposal` is not a map with exactly the five keys,
when `nodes`, `links` or `input_slots` is not a list, when an entry of
`nodes` is not a map with a string `kind`, or when it
holds a value that is not plain JSON data (a function, a tuple, an atom other
than a boolean or `nil`, a number that is not finite); `:too_large` when its
compact JSON is over 65,536 bytes; `:too_many_nodes` when `nodes` holds more
than `max_nodes` entries. So a proposal that carries code in any form is
refused here or as an unknown key in stage 3.

**Stage 2, the limits of the agent.** All reasons, sorted as in ELZ-167:

| Code | Path | When |
| --- | --- | --- |
| `:callable_not_allowed` | the node | a `call`, `decision`, `map` or `loop` node names a callable that is not in `callables` |
| `:tool_not_allowed` | the node | `resolve(agent_tools, tool)` of a `tool` node is not `{:resolved, _}` |
| `:tool_cost_unknown` | the node | a `tool` node whose tool has no entry in `tool_costs` |
| `:ask_not_allowed` | the node | an `ask` node while `ask_cost` is `null` |

**Stage 3, the same check as at load time.** Build `recipe2`: `recipe` with
one more callable `{name, kind: "graph"}` plus the five members of
`proposal`, added at the end of `callables`, and with `root` set to `name`.
Build `facts2`: `facts` with one more cost entry for each `tool` node (its
tool cost) and each `ask` node (`ask_cost`) of the new callable. Call
`RecipeCheck.check_graph(recipe2, declared, facts2)`. Its
`{:error, :invalid_facts}` is `{:error, :invalid_context}` here.

- Its reasons come back with these paths: a path into the new callable
  becomes the path into `proposal` (the leading `"callables"` and its index
  are removed); `[]` stays; every other path gets `"recipe"` in front. A
  recipe that passed the load-time check gives no such other reason.
- With no reason from `check_graph/3`: the nesting of the new callable (1 for
  itself plus the longest chain of named calls below it) plus `depth` must be
  at most `max_depth`, else `:depth_exceeded` with the path `[]`.

Because the root of `recipe2` is the new callable, `:over_cap` means that the
upper cost of the new graph is larger than its budget share. Because every
requirement of a tool must be in `declared`, the graph gets no need and no
permission that the recipe does not declare.

`accepted` is exactly `%{recipe: recipe2, callable: name, unit: unit,
upper_cost: integer}`. The host runs the new callable from `recipe2` with a
budget of at most `upper_cost`. The same `proposal` and `context` give the
same result, also in another process.

`render(reasons)` returns the reasons as content for the model: UTF-8 text
with the fixed first line `graph refused:`, then one line `<path>: <code>`
for each of the first 64 reasons in their order, then `and <n> more` when
there are more. A path is written as `$`, with `.name` for a string and
`[i]` for an integer. The text holds no value of the proposal, of the
recipe or of the context. A list that is not a list of reasons is
`{:error, :invalid_input}`.

## Host Needs and Limits

Fixed bounds: 64 nodes; 65,536 bytes; depth 16; 64 allowed callables; 1,000
tool costs; 64 rendered reasons; and those of ELZ-161 and ELZ-167. Codes are
the fixed atoms above and those of ELZ-167 and ELZ-161.

Needs: a host that calls `accept/2` before it runs a graph of a model, with
the recipe that the Run pinned, the true callables and tool sources of that
agent, the true depth and a budget share that it then reserves; that records
the proposal and the verdict before use, so that after a restart the
recorded graph is read again and the model is not asked again; that gives
`render/1` to the model as marked content (ELZ-137) and never as an
instruction; that runs only `accepted.callable` of `accepted.recipe`.

Limits: the verdict is about data. It does not run the graph, reserve a
budget, check a permission of a person or approve an action: the engine does
that for every action of the new graph. The graph can call the callables in
`callables`, also the agent that gave it; `depth` and the budget share bound
that, not this check alone. Schemas of the proposal are checked as ELZ-161
checks them; no claim that the graph does what the model intends. No I/O,
clock, process or storage. Telemetry, Config and Control are not applicable:
pure functions over intrinsic operands.

The manifest declares `kind: owned`, providers `elixir` and `jason`, and the
Piece dependencies `workflow/recipe-check`, `domain/recipe-graph` and
`workflow/tool-registry`.

## Named acceptance groups

1. **`accepted_graph`**: a proposal of three nodes (a call to an allowed
   callable, an allowed tool, a join) is accepted; `accepted.recipe` passes
   `RecipeGraph.decode/1`, holds the old callables unchanged and the new one
   last, and has the new root; `upper_cost` equals a sum written by hand.
2. **`outside_the_agent`**: a callable outside `callables`; a tool that
   resolves in the snapshot of the recipe but not in `agent_tools`; a tool
   with no cost; an ask while `ask_cost` is `null`; two faults give two
   reasons in path order.
3. **`no_new_authority_and_budget`**: a tool whose requirement is not in
   `declared` gives the reason of ELZ-167 at the node of the proposal; an
   upper cost at the share passes and share plus 1 is `:over_cap`; a map of
   256 iterations over a costly callable is `:over_cap`.
4. **`node_and_depth_maximum`**: `max_nodes` nodes pass and one more is
   `:too_many_nodes`; nesting plus `depth` at `max_depth` passes and one more
   is `:depth_exceeded`; a node that names the new callable itself is
   `:callable_not_allowed`, because `name` is never in `callables`.
5. **`data_only`**: a proposal with a sixth key, with a key `code` inside a
   node, with a function, with a tuple and with an over-long text is
   refused; a structural fault of ELZ-161 (a need with no giver, a cycle, a
   decision with a missing branch) is refused with its atom at `[]`.
6. **`reasons_as_content`**: `render/1` of one reason of each code; 64 and 65
   reasons; a sentinel text in the proposal, in a tool name and in the
   context never appears in a reason, in the rendered text, in an error or
   in a captured log; `{:error, :invalid_context}` for each malformed member.
7. **`same_input_same_verdict`**: 20 calls, and a call in a second BEAM
   process, give equal results for one accepted and one refused proposal;
   `proposal` and `context` are not changed. One small checked example covers
   the public API.

## Evidence and gate

Test: the seven groups; reused Piece claims stay scoped to their Contracts.
Cure owns a new pure decision when a meaningful law is selected; do not add a
Boolean restatement. Negative controls: temporarily skip the comparison with
`callables`, then temporarily leave `root` of `recipe2` unchanged; groups 2
and 3 must fail. Restore both before the final gate. Record assumptions and
test results separately.

Run `mix test pieces/workflow/runtime-graph/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

The engine, the agent loop, a tool that carries the proposal, marking of
content, persistence of the proposal, `workflow/graph-run`, and any change of
a ready Piece.
