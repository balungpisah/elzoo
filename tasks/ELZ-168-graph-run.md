# ELZ-168 — Graph pattern as one pure pattern step

## Scope and reuse

- Dependencies: ELZ-033, ELZ-002, ELZ-114, ELZ-136, ELZ-161, ELZ-166
- Output: `workflow/graph-run`, one public module `Elzoo.GraphRun`; release V1B; RC-63 graph-run portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/graph-run/**` and its index/generated changes under AGENTS.md section 3.

Admit the rest of RC-63. The graph is one pattern among others: a pure step
in the shapes of `workflow/pattern-step`, where state and one recorded input
give a new state and zero or one request. The step runs one `graph` callable
of a recipe. It decides which nodes are ready and asks for their actions. It
calls no model, tool or callable, reads no clock, stores nothing and starts no
process. It checks neither budget nor authority: the engine does that for
every action.

Implement only the acceptance groups below. Use the public functions of
ELZ-114, ELZ-136, ELZ-161 and ELZ-166 as they are on main. Add no options,
layers, behaviours, generic helpers or future hooks: no retry, no timeout
rule, no engine code, no agent or decision logic, no Lua. Edit no ready Piece,
shared path, pin or CI file. No fixtures directory is needed: each test input
is a literal neutral map. Ask the coordinator before any expansion.

Facts checked on main:

- `domain/recipe-graph` (ELZ-161) validates a recipe and refuses every cycle.
  A `map` or `loop` node holds only `callable` and `max_iterations` (1 to
  256): it holds no concurrency bound, no part-failure rule, no name of the
  collection and no stop rule. ELZ-161 leaves those to this task. A graph
  callable has `input_slots` under the source `$input` and no output slots.
- `workflow/pattern-step` (ELZ-114): a request holds 1 to 64 actions with
  unique IDs; a payload is opaque; `open/1` and `accept/2` settle each action
  once, and a second or `late` outcome is not applied.
- `workflow/node-outcome` (ELZ-166): `routes/2` and `decide/2`.
- `workflow/tool-registry` (ELZ-136): `snapshot/1` and `resolve/2`; a resolved
  tool has `callable: {:adapter | :nested, source, name}`.
- `assembly/run-engine` calls a pattern as `function(state, input)` and
  installs a state only when it is plain data of at most 65,536 bytes as
  `:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])`. It
  allows 64 open actions.
- `workflow/dependency-graph` gives only the AND-join of acyclic
  prerequisites, and `delivery/aggregation` holds a clock function and takes
  Envelope results. Coordinator decision, 2026-11-14: this step calls neither.
  ELZ-161 already used dependency-graph for the cycle check; the join after a
  branch, the skip rule and the count over the items of a map are written
  here, over recorded outcomes only.

## Payloads

All keys are strings and each schema version is 1. The README states these
shapes; the host builds the payload schemas of its engine from them.

- **Start.** Key `elzoo.graph-run.input`, payload exactly `{"input": object}`
  with one member for each name in `input_slots` of the callable.
- **Node result.** `elzoo.graph-run.node-result` is the one result key of
  every action of a node. A completed payload is an object with `"gives"`: an
  object that holds each give name of the node (other members of `gives` are
  not read). A decision action also has `"choice"`: one declared choice name.
  A loop action also has `"continue"`: a boolean. An outcome that is not
  completed can have any key: the step reads only its class.
- **Call action.** Kind `nested_callable`, key `elzoo.graph-run.call`, payload
  exactly `{"callable": name, "input": object}`. `input` holds exactly the
  needs of the node by name, and for a map or a loop the members below. It
  holds nothing else: no state, no result of another node, no recipe.
- **Tool action.** Key `elzoo.graph-run.tool-call`, payload exactly
  `{"alias", "source", "tool", "version", "arguments"}`: four values of the
  resolved tool, and `arguments`, the needs of the node by name. Kind
  `tool_call` for a callable `{:adapter, _, _}` and `nested_callable` for
  `{:nested, _, _}`. This is the payload form of ELZ-142 under another key.
- **Ask action.** Kind `ask_person`, key `elzoo.graph-run.ask`, payload
  exactly `{"person_id", "question"}`: the values of the two needs of these
  names. The answer is a `person_answer` with the key `elzoo.graph-run.answer`
  and the payload exactly `{"text": text}`; the node gives it as `text`.
- **Finish.** Kind `finish`, key `elzoo.graph-run.result`, payload exactly
  `{"status", "reason", "node", "action_id", "gives"}`. `completed` has
  `reason` and `node` `null`, the `gives` of the graph (below) and the
  identity of the completed action that settled last. `failed` has `gives`
  and `action_id` `null`, a reason from the table below and the node ID, or
  `null` when no node is at fault.

Action identities derive from `id` of the spec and are unique in the Run when
`id` is: a `call`, `tool`, `ask` or `decision` node `N` has
`id <> ":n:" <> N`; item `I` of a map (from 0) and iteration `K` of a loop
(from 1) have `id <> ":n:" <> N <> ":" <> I`; the finish has
`id <> ":finish"`.

## Interface

`Elzoo.GraphRun.new(spec)` returns `{:ok, state}` or `{:error, reason}`.
`spec` is a map with exactly these atom keys:

- `id`: UTF-8 text of 1 to 64 bytes without `":"`. The caller keeps it unique
  in the Run.
- `recipe`: the neutral map of ELZ-161. `new/1` decodes it;
  `{:error, {:recipe, reason}}` holds the refusal unchanged.
- `callable`: the name of one `graph` callable of it; else
  `:unknown_callable`.
- `sources`: the operand of `ToolRegistry.snapshot/1`;
  `{:error, {:sources, reason}}` holds its refusal. A `tool` node whose `tool`
  does not give `{:resolved, _}` is `{:error, {:unknown_tool, node_id}}`.
- `maps`: a map from the ID of each `map` node of the callable to exactly
  `%{concurrency: 1..64, on_item_failure: :fail | :partial}`. A missing or
  extra entry is `:invalid_spec`.
- `max_open`: 1 to 64, the largest number of open actions of this step.

Also `:invalid_spec`: a `map` node without a need named `items` or with a
give other than `items`; an `ask` node without the needs `person_id` and
`question` or with a give other than `text`; a node ID that holds `":"`; a
`spec` in another shape. `:state_too_large` when the first state is over the
bound.

`Elzoo.GraphRun.step(state, input)` returns
`{:Transition, new_state, :none | {:some, request}}`, the `core/operator`
shape. `input` and `request` are neutral maps of `Elzoo.PatternStep`, and
each request passes `PatternStep.decode/1`. The state is opaque plain data
(maps, lists, tuples, atoms, numbers, binaries). Document its form for
source-copy ownership.

| Phase | Input | Result |
| --- | --- | --- |
| new | `start` with the input payload | "Ready nodes" |
| new | `start` in another form | finish `failed`, `invalid_input` |
| running | an applied outcome or `person_answer` of an open action | "One settled action", then "Ready nodes" |
| new, running | `cancel`, `run_ended` | closed; no request |
| any | each other input: `message`, `resource_event`, `wake`, a second `start`, an outcome of class `late`, an outcome of an action that is not open or is settled, a `person_answer` for an action that is not an ask, a `completed` outcome of an ask, a map that `PatternStep.decode/1` refuses | no change, no request |
| closed | every input | no change, no request |

The step settles outcomes through `PatternStep.open/1` and `accept/2` on each
request that it gave, and reads only an applied one. After the finish the
step is closed.

## Node states and links

Each node is `pending`, `open`, `done` with one outcome class, or `skipped`.
It leaves `pending` once and never returns to it: a node that is `open`,
`done` or `skipped` gets no new action.

A link is live, dead or not yet decided, from the state of its source:

| Link | Live | Dead |
| --- | --- | --- |
| `data` from a node | source `done` `completed` | source `skipped`, or `done` with another class |
| `data` from `$input` | always | never |
| `order` | source `done` `completed` | source `done` with another class |
| `choice` | source `done` `completed` with this choice | source `skipped`, `done` with another class, or `completed` with another choice |
| `outcome` | source `done` with this class | source `skipped`, or `done` with another class |

An `order` link whose source is `skipped` is void: it is neither live nor
dead.

A pending node whose incoming links are all decided is **ready** when each
`data` link is live, no `order` link is dead, and, if it has an `order`,
`choice` or `outcome` link at all, at least one of them is live. Otherwise it
becomes **skipped**. So a join after a decision is ready when the taken branch
completes; the branch that was not taken is skipped and not waited for; a
node behind a node that did not complete is skipped, and the target of its
outcome link runs.

## Ready nodes

After each change, in the order of the `nodes` list and until nothing changes:
mark each node that must be skipped; start each ready node while fewer than
`max_open` actions are open. All actions that one step starts are one
request. A ready node that cannot start waits as `pending`.

- `call`: one call action. `decision`: one call action to its decision
  callable.
- `tool`, `ask`: one tool or ask action.
- `map`: the value of the need `items` must be a list of at most
  `max_iterations` values. Item `I` gets one call action whose `input` has
  the other needs and `"item"` and `"index"`. At most `concurrency` items of
  one map are open. A map over an empty list is done at once.
- `loop`: iteration 1 gets one call action whose `input` has the needs,
  `"iteration": 1` and `"previous": null`.

When no node is `pending` or `open`, or the Run has failed and no action is
open, the step gives the finish. The `gives` of a completed graph is one
object with the gives of each `done` `completed` node that no link names as
`from`. A give name that two such nodes hold is finish `failed`,
`ambiguous_output`.

## One settled action

- A node action that is not a map item or a loop iteration: `completed` with
  a payload in the form above makes the node `done` `completed` and keeps its
  `gives` (and its choice). `completed` with another payload, or with a
  choice that the callable does not declare, makes it `done` `failed`. Each
  other class makes it `done` with that class. A `person_answer` makes an ask
  node `done` `completed`.
- A map item keeps its class and `gives`. With `:fail`, the first item that
  is not `completed` stops the start of further items; when no item is open
  the node is `done` `failed`. When every item is `completed` the node is
  `done` `completed`. With `:partial` every item runs; the node is `done`
  `completed` when at least one item completed or the list was empty, else
  `done` `failed`. A completed map gives `items`: a list in index order of
  `{"index", "status": "completed", "gives"}` or `{"index", "status": class}`.
  A value of `items` that is not a list or is longer than `max_iterations`
  makes the node `done` `failed` with no action. Every item of the list
  appears in the result exactly once.
- A loop iteration `K` that is `completed` with `"continue": true` and
  `K < max_iterations` starts iteration `K + 1` with `"previous"` set to its
  `gives`. With `false`, or at `K = max_iterations`, the node is `done`
  `completed` with the `gives` of iteration `K`. An iteration with another
  class makes the node `done` with that class.
- For each node that becomes `done`:
  `NodeOutcome.decide(routes, class)` with the routes of `routes/2`.
  `:fail_run` fails the Run: no node starts after it, open actions are
  awaited, and the finish is `failed`, `no_outcome_link` with that node (the
  first such node in the order of the `nodes` list when there are several).
  `:proceed` and `:follow` need no further action: the link table above
  already makes the route live.
- A state over 65,536 bytes: finish `failed`, `state_over_bound`.

No action is asked for twice. No outcome, `unknown` included, starts a second
try of a node, an item or an iteration.

Finish reasons: `invalid_input`, `no_outcome_link`, `ambiguous_output`,
`state_over_bound`.

## Host Needs and Limits

Fixed bounds: those of ELZ-161; 64 open actions; 64 concurrent items of one
map; 256 items or iterations; state 65,536 bytes in the measure above. New
reasons are the fixed atoms above. No input fragment appears in an error, a
log or a telemetry event.

Needs: an engine that records each input before the step reads it, gives the
step only inputs of the Attempt that it runs in and checks payload, budget,
authority and approval for every action; a `nested_callable` binding that
runs the named callable of the same recipe with exactly the given `input` and
returns its result in the node-result form; a tool binding that maps `source`
and `tool` to a real Adapter call or nested callable and returns the
node-result form; an `ask_person` binding whose `person` function returns
`person_id` of the payload, with verification of the person by the host; a
Run-wide unique `id`; a recipe that `workflow/recipe-check` accepted; results
small enough for the state bound.

Limits: one graph callable; a nested graph is another instance of this step
that the host binds, and this step never sees its state. Arguments of a tool
and inputs of a callable are not validated against a schema here: the engine
checks the payload of each action. The step verifies no person. The gives of
skipped nodes do not exist. Results in a different arrival order give the
same set of actions and the same finish; the grouping of actions into
requests can differ. No engine claim: the ready `assembly/run-engine` holds
no result of the child in its outcome of a nested callable, so with that
engine a `call`, `decision`, `map` or `loop` node settles as `done` `failed`;
it allows 256 lifetime actions for each Unit; and a request that it does not
admit gets no outcome. A model graph at run time is `workflow/runtime-graph`.
Telemetry, Config and Control are not applicable: pure functions over
intrinsic operands.

The manifest declares `kind: owned`, providers `cure` and `elixir`, and the
Piece dependencies `domain/recipe-graph`, `workflow/pattern-step`,
`workflow/node-outcome` and `workflow/tool-registry`.

## Named acceptance groups

Each test folds `step/2` over a recorded trace: a fixed list of literal
neutral inputs, with the expected requests written by hand. Each request
passes `PatternStep.decode/1` and each state is plain data within the bound.

1. **`needs_and_gives_only`**: a graph of four nodes with data links only
   runs in data order; nodes with no common prerequisite start in one
   request; the finish holds the gives of the last nodes.
2. **`decision_branch_and_join`**: a decision in the middle selects one of
   two branches of two nodes each; the other branch is skipped and gets no
   action; a join with an order link from each branch is ready when the taken
   branch completes; the same graph with the other choice.
3. **`map_bounds_and_part_failure`**: a map over 5 items with concurrency 2
   never has more than 2 items open; one failed item under `:fail` (no
   further item starts, the node fails) and under `:partial` (every item
   runs, the result lists 5 entries in index order); all items failed under
   `:partial`; an empty list; a list of `max_iterations` items and of one
   more; a value that is not a list.
4. **`loop_bounded`**: a loop that ends with `"continue": false` at iteration
   2; a loop with `max_iterations` 3 whose every iteration says `true` ends
   completed after exactly 3 actions; iteration `K + 1` holds the gives of
   iteration `K`; a failed iteration.
5. **`each_outcome_link`**: for each of the seven uncompleted classes that
   the step can apply (`late` is never applied), a node with that outcome and a route
   starts the target and skips its ordinary successors; a `completed` route
   starts its target and the ordinary successors.
6. **`missing_outcome_link_fails_run`**: each of the seven uncompleted
   applied classes with no route gives finish `failed`, `no_outcome_link`
   with the node; open actions are awaited first; no node starts after the
   failure; `unknown` starts no second try.
7. **`settled_node_never_runs_again`**: the trace cut at each position and
   folded again from the start over the same inputs gives the same states
   and requests; a second outcome for a settled action, an outcome of class
   `late` and an outcome for an unknown action change nothing; over all
   traces of the suite no action ID appears in two requests.
8. **`arrival_order`**: for three nodes that are open together, each of the
   six orders of their outcomes gives the same set of actions and the same
   finish.
9. **`nested_graph_gets_only_its_input`**: the payload of a call action is
   exactly `callable` and `input` with the needs of the node; a sentinel in
   the result of another node and in the start input never appears in it.
10. **`new_refusals_and_closed`**: each refusal of `new/1`; `cancel` and
    `run_ended` close the step; each input of the "no change" row; a start
    in another form; `ambiguous_output`; `state_over_bound`; `max_open` 1
    runs a wide graph one action at a time. One small checked example covers
    the public API.

## Evidence and gate

Proof: Cure owns the transition of one node state. Prove at least
`left_pending_never_starts`: a node that is `open`, `done` or `skipped` gets
no start, for every input of that function. A second law for "every item of
a map appears once in its result" when it can be stated without repeating a
Boolean. Test: the ten groups. Negative controls: temporarily let a void
order link count as dead (group 2 must fail), then temporarily let a node
start a second time after an `unknown` outcome (groups 6 and 7 and the law
must fail). Restore both before the final gate. Record assumptions and test
results separately.

Run `mix test pieces/workflow/graph-run/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

`workflow/runtime-graph`, agent and decision logic, Lua, the engine and its
bindings, retry and timeout policy, a change of `domain/recipe-graph` (map
and loop fields stay as they are), persistence, and a change of any ready
Piece.
