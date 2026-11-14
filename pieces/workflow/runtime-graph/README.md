# workflow/runtime-graph

`Elzoo.RuntimeGraph` decides whether a graph that a model gave during a Run may
run. The graph is plain data. The Piece adds it to the recipe of the Run as one
more `graph` callable, checks the result with `Elzoo.RecipeCheck.check_graph/3`
and holds it to the limits of the agent that gave it. It is a pure function: it
runs nothing, stores nothing and grants nothing.

## Interface

- `accept(proposal, context)` returns `{:ok, accepted}`, `{:refused, reasons}`
  or `{:error, :invalid_context}`.
- `render(reasons)` returns the reasons as text for the model, or
  `{:error, :invalid_input}`.

`proposal` is decoded JSON: a string-keyed map with exactly `nodes`, `links`,
`input_slots`, `input` and `output`, the members of a `graph` callable of
`domain/recipe-graph`. It has no name, no bindings and no rules.

`context` is a string-keyed map with exactly these keys, all from the host:

| Key | Content |
| --- | --- |
| `recipe` | the neutral recipe map of the Run |
| `name` | text of 1 to 128 bytes that no callable of `recipe` has: the name of the new callable |
| `callables` | at most 64 unique names of callables of `recipe` that the agent may call |
| `agent_tools` | a snapshot of `Elzoo.ToolRegistry.snapshot/1` with only the tool sources of the agent |
| `declared` | the `declared` operand of `check_graph/3` |
| `facts` | the `facts` operand of `check_graph/3` for `recipe`; its `cap` is the budget share of this graph |
| `tool_costs` | at most 1,000 entries: tool name to an estimate (1 to 2^53), the upper cost of one call from the new graph |
| `ask_cost` | an estimate, or `nil` when the new graph may not ask a person |
| `max_nodes` | 1 to 64 |
| `max_depth` | 1 to 16 |
| `depth` | 1 to 16: the nesting depth of the agent node that gave the graph, the root of the Run being 1 |

A context in another shape, a `name` that `recipe` has, or an entry of
`callables` that `recipe` does not have is `{:error, :invalid_context}`: an error
of the host, not a verdict on the graph. It is reported before any verdict.

A reason is `%{path: path, code: code}` as in `workflow/recipe-check`. Paths are
relative to `proposal` (for example `["nodes", 2]`). A stage runs only when the
stage before it gave no reason.

**Stage 1, the proposal as data.** One reason with the path `[]`:
`:invalid_shape` when `proposal` is not a map with exactly the five keys, when
`nodes`, `links` or `input_slots` is not a list, when an entry of `nodes` is not a
map with a string `kind`, or when a value is not plain JSON data (a function, a
tuple, an atom other than a boolean or `nil`, a struct, a key that is not a
string, an improper list, invalid UTF-8); `:too_large` when the compact JSON is
over 65,536 bytes; `:too_many_nodes` when `nodes` holds more than `max_nodes`
entries. A number that is not finite cannot occur as a decoded term on the BEAM
(every Elixir float is finite and Jason decodes no NaN or infinity), so stage 1
has no check for it and no test covers it.

**Stage 2, the limits of the agent.** All reasons, sorted by path and then by
code:

| Code | Path | When |
| --- | --- | --- |
| `:callable_not_allowed` | the node | a `call`, `decision`, `map` or `loop` node names a callable that is not in `callables` |
| `:tool_not_allowed` | the node | `ToolRegistry.resolve(agent_tools, tool)` of a `tool` node is not `{:resolved, _}` |
| `:tool_cost_unknown` | the node | a `tool` node whose tool has no entry in `tool_costs` |
| `:ask_not_allowed` | the node | an `ask` node while `ask_cost` is `nil` |

**Stage 3, the same check as at load time.** `recipe2` is `recipe` with one more
callable (`name`, `kind: "graph"` and the five members) added at the end of
`callables`, and with `root` set to `name`. `facts2` is `facts` with one more cost
entry for each `tool` node (its tool cost) and each `ask` node (`ask_cost`) of the
new callable. `check_graph(recipe2, declared, facts2)` decides. Its reasons keep
their meaning with these paths: a path into the new callable becomes the path into
`proposal`; `[]` stays; every other path gets `"recipe"` in front. When it gives
no reason, the nesting of the new callable (1 for itself plus the longest chain of
named calls below it) plus `depth` must be at most `max_depth`, else
`:depth_exceeded` with the path `[]`.

Because the root of `recipe2` is the new callable, `:over_cap` means that the
upper cost of the new graph is larger than its budget share. Because every
requirement of a tool must be in `declared`, the graph gets no need and no
permission that the recipe does not declare.

`accepted` is exactly `%{recipe: recipe2, callable: name, unit: unit, upper_cost:
integer}`. The host runs `accepted.callable` from `accepted.recipe` with a budget
of at most `upper_cost`.

`render(reasons)` is UTF-8 text: the first line `graph refused:`, then one line
`<path>: <code>` for each of the first 64 reasons, then `and <n> more` when there
are more. A path is `$`, with `.name` for a string and `[i]` for an integer. The
text holds no value of the proposal, of the recipe or of the context.

## Decisions

- Order: the context is checked first. `declared` and `facts` are checked by one
  call of `check_graph/3` on an empty recipe, which reads them before the recipe;
  a malformed one is `{:error, :invalid_context}` before stage 1. No second
  validator of them is written.
- Stage 1 walks the proposal once with a budget of bytes. Each charge is at most
  the compact JSON size of the part, so an exhausted budget means a document over
  65,536 bytes. A bound is thus reached before a long list or map is walked to its
  end. `Jason.encode!/1` runs only on data that this scan found plain, and decides
  the exact size.
- Stage 1 reports its first fault only. A node with a missing or non-text `callable`
  or `tool` gets no stage 2 reason: the checker of stage 3 refuses it as a shape
  fault.
- A cost entry is added only for a node with a text `id` (a repeated id once). A
  node that `RecipeGraph` refuses is thus refused for its own fault and not as a
  fault of the facts. If the added entries make more than 1,064 costs, the check
  refuses the facts and the result is `{:error, :invalid_context}`.
- The recipe is not decoded before stage 3. A fault of the recipe itself therefore
  shows as a reason with a root path (`[]`) or a `"recipe"` path, as the Contract
  states. A recipe of 64 callables has no room for one more: `RecipeGraph` refuses
  it as `:too_large` at `[]`.
- Nesting counts each callable of a chain, an `agent` or `decision` callable at the
  end included. The recipe is acyclic: `check_graph/3` refused recursion first.
- `render/1` accepts only reasons of this Piece's form: exactly `path` and `code`,
  a code of the fixed atoms of this Piece, `workflow/recipe-check` and
  `domain/recipe-graph`, and a path of at most 16 parts, each a nonnegative integer
  or a lowercase word of `a-z` and `_` (at most 32 bytes). `[]` renders as the
  line `graph refused:` alone.
- No Cure module. No meaningful new law is selected: the decision is finite
  comparisons around the reused check, and a Cure law over supplied Booleans would
  only restate them.
- No logging, telemetry, process, clock or storage. Every refusal and error holds
  only fixed atoms, fixed key strings and integers.

## Bounds and errors

Bounds: 64 nodes (`max_nodes`); 65,536 bytes of compact JSON; depth 16; 64 allowed
callables; 1,000 tool costs; 64 rendered reasons; and those of `domain/recipe-graph`
and `workflow/recipe-check`. Errors: `{:error, :invalid_context}` and
`{:error, :invalid_input}`; reason codes are the fixed atoms above and those of
`workflow/recipe-check` and `domain/recipe-graph`. A sentinel text in the proposal,
a tool name or the context never appears in a reason, in rendered text, in an error
or in a log.

## Grounding

`mix test pieces/workflow/runtime-graph/test` exercises the named groups
`accepted_graph`, `outside_the_agent`, `no_new_authority_and_budget`,
`node_and_depth_maximum`, `data_only`, `reasons_as_content` and
`same_input_same_verdict`. These are finite scenarios: the listed scenarios pass.
The last group evaluates `examples/runtime_graph.exs`; it also runs with
`mix run pieces/workflow/runtime-graph/examples/runtime_graph.exs`.

Two negative controls are temporary edits, never shipped: skipping the comparison
with `callables` and leaving `root` of `recipe2` unchanged each make the groups
`outside_the_agent` and `no_new_authority_and_budget` fail.

This is no proof and no type check claim, and there is no monitored claim. Reused
Piece Contracts stay scoped to those Pieces.

## Needs and limits

Needs: a host that calls `accept/2` before it runs a graph of a model, with the
recipe that the Run pinned, the true callables and tool sources of that agent, the
true depth and a budget share that it then reserves; that records the proposal and
the verdict before use, so that after a restart the recorded graph is read again and
the model is not asked again; that gives `render/1` to the model as marked content
(`workflow/untrusted-content`) and never as an instruction; that runs only
`accepted.callable` of `accepted.recipe`.

Limits: the verdict is about data. It does not run the graph, reserve a budget,
check a permission of a person or approve an action: the engine does that for every
action of the new graph. The graph can call the callables in `callables`, also the
agent that gave it; `depth` and the budget share bound that, not this check alone.
Schemas of the proposal are checked as `domain/recipe-graph` checks them; no claim
that the graph does what the model intends. Agent and decision bindings are opaque.
This Piece defines no `nested_callable` action and does not call
`workflow/output-repair`. No I/O, clock, process or storage. Telemetry, Config and
Control are not applicable: pure functions over intrinsic operands.
Application-owned module, Apache-2.0; no new dependency or pin.
