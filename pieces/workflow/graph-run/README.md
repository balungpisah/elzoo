# workflow/graph-run

One `graph` callable of a recipe as one pure pattern step. One public Elixir
module, `Elzoo.GraphRun`, supplies two functions: `new/1` and `step/2`. State
and one recorded input give a new state and zero or one request, in the shape
of `workflow/pattern-step`. The step decides which nodes are ready and asks for
their actions. It calls no model, tool or callable, reads no clock, stores
nothing and starts no process. It checks neither budget nor authority: the
engine does that for each action.

## Interface

`new(spec)` returns `{:ok, state}` or `{:error, reason}`. `spec` is a map with
exactly these atom keys:

| Key | Meaning |
| --- | --- |
| `id` | UTF-8 text of 1 to 64 bytes without `":"`; the caller keeps it unique in the Run |
| `recipe` | the neutral map of `domain/recipe-graph`; `{:error, {:recipe, reason}}` holds its refusal unchanged |
| `callable` | the name of one `graph` callable of the recipe; else `:unknown_callable` |
| `sources` | the operand of `Elzoo.ToolRegistry.snapshot/1`; `{:error, {:sources, reason}}` holds its refusal; a `tool` node that does not resolve is `{:error, {:unknown_tool, node_id}}` |
| `maps` | a map from the ID of each `map` node to exactly `%{concurrency: 1..64, on_item_failure: :fail \| :partial}`; a missing or extra entry is `:invalid_spec` |
| `max_open` | 1 to 64, the largest number of open actions of this step |

Also `:invalid_spec`: a `map` node without a need named `items` or with a give
other than `items`; an `ask` node without the needs `person_id` and `question`
or with a give other than `text`; a node ID that holds `":"`; a spec in another
shape. `:state_too_large` when the first state is over 65,536 bytes.

`step(state, input)` returns `{:Transition, new_state, :none | {:some, request}}`.
`input` and `request` are neutral maps of `Elzoo.PatternStep`.

| Phase | Input | Result |
| --- | --- | --- |
| new | `start` with the input payload | ready nodes |
| new | `start` in another form | finish `failed`, `invalid_input` |
| running | an applied outcome or `person_answer` of an open action | the settled action, then ready nodes |
| new, running | `cancel`, `run_ended` | closed; no request |
| any | each other input: `message`, `resource_event`, `wake`, a second `start`, an outcome of class `late`, an outcome of an action that is not open or is settled, a `person_answer` for an action that is not an ask, a `completed` outcome of an ask, a map that `PatternStep.decode/1` refuses | no change, no request |
| closed | every input | no change, no request |

The step settles outcomes through `PatternStep.open/1` and `accept/2` on each
action that it asked for, and reads only an applied one. After the finish the
step is closed.

## Payloads

All keys are strings and each schema version is 1. The host builds the payload
schemas of its engine from these shapes.

- **Start.** Key `elzoo.graph-run.input`, payload exactly `{"input": object}`
  with one member for each name in `input_slots` of the callable.
- **Node result.** `elzoo.graph-run.node-result` is the one result key of each
  action of a node. A `completed` payload is an object with `"gives"`: an
  object that holds each give name of the node; other members of `gives` are
  not read and not kept. A map item is the exception: its `gives` is any object
  and is kept whole. A loop iteration holds each give name of the loop node and
  has `"continue"`, a boolean. A decision action also has `"choice"`, one
  declared choice name. A `completed` outcome in another form, or with an
  undeclared choice, makes the node `failed`. An outcome of another class can
  have any payload: only its class is read.
- **Call action.** Kind `nested_callable`, key `elzoo.graph-run.call`, payload
  exactly `{"callable": name, "input": object}`. `input` holds exactly the needs
  of the node by name, and for a map item `"item"` and `"index"` besides (the
  need `items` is left out), for a loop iteration `"iteration"` and
  `"previous"` (`null` at iteration 1, else the `gives` of the iteration before).
  It holds no state, no result of another node and no recipe.
- **Tool action.** Key `elzoo.graph-run.tool-call`, payload exactly
  `{"alias", "source", "tool", "version", "arguments"}`: four values of the
  resolved tool and `arguments`, the needs of the node by name. Kind
  `tool_call` for an adapter tool and `nested_callable` for a nested one.
- **Ask action.** Kind `ask_person`, key `elzoo.graph-run.ask`, payload exactly
  `{"person_id", "question"}`. The answer is a `person_answer` with the key
  `elzoo.graph-run.answer` and the payload exactly `{"text": text}`; the node
  gives it as `text`. Any other answer payload makes the node `failed`.
- **Finish.** Kind `finish`, key `elzoo.graph-run.result`, payload exactly
  `{"status", "reason", "node", "action_id", "gives"}`. `completed` has `reason`
  and `node` `null`, the `gives` of the graph and the identity of the completed
  action that settled last (`null` when no action completed). `failed` has
  `gives` and `action_id` `null`, a reason and the node, or `null` when no node
  is at fault. The reasons are `invalid_input`, `no_outcome_link`,
  `ambiguous_output` and `state_over_bound`.

Action identities derive from `id`: a `call`, `tool`, `ask` or `decision` node
`N` has `id <> ":n:" <> N`; item `I` of a map (from 0) and iteration `K` of a
loop (from 1) have `id <> ":n:" <> N <> ":" <> I`; the finish has
`id <> ":finish"`.

## Rules

Each node is `pending`, `open`, `done` with one outcome class, or `skipped`. It
leaves `pending` once. A link is live, dead or not yet decided from the state of
its source:

| Link | Live | Dead |
| --- | --- | --- |
| `data` from a node | source `done` `completed` | source `skipped`, or `done` with another class |
| `data` from `$input` | always | never |
| `order` | source `done` `completed` | source `done` with another class |
| `choice` | source `done` `completed` with this choice | source `skipped`, `done` with another class, or `completed` with another choice |
| `outcome` | source `done` with this class | source `skipped`, or `done` with another class |

An `order` link whose source is `skipped` is void: it is decided, and neither
live nor dead. A pending node whose
incoming links are all decided is ready when each `data` link is live, no
`order` link is dead and, if it has an `order`, `choice` or `outcome` link at
all, at least one of them is live; otherwise it is skipped. A ready node that
cannot start, because `max_open` actions are open, waits as `pending`.

After each change, in the order of the `nodes` list and until nothing changes,
the step skips the nodes that must be skipped and starts the ready ones; all
actions of one step are one request. For each node that becomes `done` it calls
`NodeOutcome.decide/2` with the routes of `NodeOutcome.routes/2`: `:fail_run`
fails the Run (no node starts after it, open actions are awaited, then the
finish names the first such node of the `nodes` list). A map runs at most
`concurrency` items at once; `:fail` stops the start of further items at the
first item that is not `completed`, `:partial` runs every item. A map whose
`items` value is not a list, or is longer than `max_iterations`, is
`failed` with no action. A loop starts iteration `K + 1` only when iteration `K`
is `completed` with `"continue": true` and `K < max_iterations`. No outcome,
`unknown` included, starts a second try of a node, an item or an iteration.

The `gives` of a completed graph is one object with the declared gives of each
`done` `completed` node that no link names as `from`; a give name that two such
nodes hold is `ambiguous_output`. The `action_id` of that finish is the
completed action that settled last, so with several last nodes it follows the
arrival order of their outcomes; every other part of the finish and the set of
actions asked for do not.

## State form

The state is plain data (maps, lists, tuples, atoms, numbers, binaries) and a
host that copies this Piece owns it. A closed state is `%{phase: :closed, id: id}`.
Otherwise:

| Key | Value |
| --- | --- |
| `phase` | `:new` or `:running` |
| `id`, `max_open`, `slots`, `order`, `sinks` | the spec `id`, the spec `max_open`, the input slot names, the node IDs in `nodes` order, the node IDs that no link names as `from` |
| `nodes` | node ID to `%{id, kind, callable, needs, gives, tool, max, choices, routes, inc}`; `kind` is `:call`, `:tool`, `:ask`, `:decision`, `:map` or `:loop`; `tool` is `nil` or `{alias, source, tool, version, action_kind}`; `routes` is the result of `NodeOutcome.routes/2`; `inc` holds `{:data, from, give, need}`, `{:order, from}`, `{:choice, from, name}` and `{:outcome, from, class}` of the incoming links |
| `maps` | map node ID to `{concurrency, :fail \| :partial}` |
| `input` | `nil` until the start, then the input object |
| `status` | node ID to `:pending`, `:open`, `:skipped` or `{:done, class}` |
| `gives`, `choices` | node ID to the kept gives and choice of each node that is `done` `completed` |
| `work` | node ID to the map state `%{items, next, results, stop}` or the loop state `%{next, previous, queued}` of an open node |
| `open` | action ID to `{node ID, :whole \| {:item, i} \| {:iter, k}, tracker}`; the tracker is that of `PatternStep.open/1` |
| `out` | actions of the step in progress; `[]` between steps |
| `last` | the action ID of the completed action that settled last, or `nil` |
| `failed` | IDs of the nodes that failed the Run, in the order of settlement |

The state holds the input, the gives and the results of the items; a graph whose
state would pass 65,536 bytes (`:erlang.term_to_binary(state, [:deterministic,
{:minor_version, 2}])`) finishes `failed`, `state_over_bound`, at once and
without awaiting open actions.

## Grounding

Proof. Cure owns the transition of one node state: `move(state, decided, ready,
seat)` returns hold, start or skip, and only a pending node moves. The selected
law `left_pending_never_starts` (a node that is open, done or skipped gets no
start, for each value of the three Booleans and each of the three states)
passes the pinned Cure check. The Elixir module derives the three Booleans from
the link table, calls the compiled Cure function for each node and maps its
result; it does not decide again. The law does not cover that derivation, the
items of a map, the iterations of a loop, or anything else of the step.

A second law, that every item of a map appears once in its result, is not
stated. The result is a list that the Elixir module builds over an index range;
a law over it needs a Cure statement about lists or counts, not the decision
over Booleans that the Cure function owns, and a law that only repeats a Boolean
would prove nothing. That property is test-grounded below.

Type. The pinned Cure compiler checks the total function, its three result and
four state members and the law.

Test. `mix test pieces/workflow/graph-run/test` runs the listed scenarios of the
ten groups `needs_and_gives_only`, `decision_branch_and_join`,
`map_bounds_and_part_failure`, `loop_bounded`, `each_outcome_link`,
`missing_outcome_link_fails_run`, `settled_node_never_runs_again`,
`arrival_order`, `nested_graph_gets_only_its_input` and
`new_refusals_and_closed`, each over recorded literal inputs with hand-written
requests. Two negative controls were run by a temporary edit and not shipped: a
void `order` link that counts as dead fails `decision_branch_and_join`; a done
node that starts again fails the Cure law, and (with the law removed) the groups
`missing_outcome_link_fails_run` and `settled_node_never_runs_again`. These are
finite tests, not a universal proof. There is no monitored runtime claim.

Upstream. The Cure compiler (pinned in `mix.exs`) for the law and the check; the
public functions of `domain/recipe-graph`, `workflow/pattern-step`,
`workflow/node-outcome` and `workflow/tool-registry` as they are on main. The
upstream behavior is not proved here.

## Needs

An engine that records each input before the step reads it, gives the step only
inputs of the Attempt that it runs in and checks payload, budget, authority and
approval for each action. A `nested_callable` binding that runs the named
callable of the same recipe with exactly the given `input` and returns its result
in the node-result form. A tool binding that maps `source` and `tool` to a real
Adapter call or nested callable and returns the node-result form. An
`ask_person` binding whose `person` function returns the `person_id` of the
payload, with verification of the person by the host. A Run-wide unique `id`. A
recipe that `workflow/recipe-check` accepted. Results small enough for the state
bound.

## Assumptions

Not verified here: that the host keeps `id` unique in the Run; that the host
binds each callable to the recipe it came from; that a recipe does not name a
need `item`, `index`, `iteration` or `previous` on a `map` or `loop` node (the
step's own member would replace that need in the input); that the inputs are
JSON-like plain data.

## Limits

One graph callable; a nested graph is another instance of this step that the
host binds, and this step never sees its state. Fixed bounds: those of
`domain/recipe-graph`, 64 open actions, 64 concurrent items of one map, 256 items
or iterations, and 65,536 bytes of state. Arguments of a tool and inputs of a
callable are not validated against a schema here: the engine checks the payload
of each action. The step verifies no person. The gives of skipped nodes do not
exist. No retry, timeout, agent or decision logic, Lua, scheduling, clock,
storage, process or I/O. Telemetry, Config and Control are not applicable: pure
functions over intrinsic operands. No input fragment appears in an error, a log
or a telemetry event; the only reasons are fixed atoms.

No engine claim. The ready `assembly/run-engine` holds no result of the child in
its outcome of a nested callable, so with that engine a `call`, `decision`, `map`
or `loop` node settles as `failed`; it allows 256 lifetime actions for each
Unit; a request that it does not admit gets no outcome; and it completes a Run on
a root `finish` only when that names a completed action, so a `failed` finish of
a root graph, or a finish with `action_id` `null`, comes back refused and the Run
ends by its cancel or deadline. A model graph at run time is
`workflow/runtime-graph`.
