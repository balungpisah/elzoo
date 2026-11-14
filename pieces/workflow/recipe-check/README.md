# workflow/recipe-check

`Elzoo.RecipeCheck` is one pure check of a recipe before it can run. Nothing
executes and nothing is stored. It compares a neutral recipe package with facts
that the caller supplies: what the tools are, what the host provides, what the
tenant granted, what each node costs and the largest cost that the caller
accepts. It grants nothing and reserves nothing.

## Interface

- `check(package, facts)` checks a neutral package map of `domain/recipe-package`.
- `check_graph(recipe, declared, facts)` checks a neutral recipe map of
  `domain/recipe-graph` that is not in a package. `declared` is exactly
  `{"needs": [text], "permissions": [text]}`.

Both return `{:ok, verdict}`, `{:refused, reasons}` or `{:error, :invalid_facts}`.

A verdict is `%{identity: identity, unit: unit, upper_cost: integer}`. The
identity is the `identity` string of the package for `check/2` and
`{id, revision, version}` of the recipe for `check_graph/3`. A reason is exactly
`%{path: path, code: code}`, the violation form of `core/payload-schema`: `path`
is a list of strings and nonnegative integers, `code` a fixed atom. A reason
holds no value of the package and no text of a library.

`facts` is a map with exactly these string keys:

| Key | Content |
| --- | --- |
| `tools` | the snapshot of `Elzoo.ToolRegistry.snapshot/1` captured for this recipe |
| `provided_needs` | at most 256 unique texts: the needs that the host can supply |
| `granted_permissions` | at most 256 unique texts: the permissions that the tenant granted |
| `tool_requirements` | at most 1,000 entries: tool name (as a `tool` node holds it) to exactly `{"needs": [text], "permissions": [text]}`, each list at most 64 unique texts; a tool with no entry requires nothing |
| `unit` | the one budget unit of this check |
| `costs` | at most 1,064 maps; `{"callable", "node", "estimate"}` for a `tool` or `ask` node, `{"callable", "estimate"}` for an `agent` or `decision` callable; no two for one target |
| `cap` | an integer from 1 to 2^63-1: the largest upper cost for one run of the root, in `unit` |

A text is a valid UTF-8 string of 1 to 128 bytes. `estimate` is an integer (not
a float) from 1 to 2^53. Strings are compared by exact bytes.

## Stage 1: structure

One reason, the first fault, then stop. No second structural validator is
written here; the two ready validators decide.

- `check/2` calls `Elzoo.RecipePackage.decode/1`. A refusal other than
  `:invalid_graph` is `%{path: [], code: reason}`, except
  `:invalid_settings_descriptor` at `["settings"]` and `:invalid_skill` at
  `["skills"]`. For `:invalid_graph` it calls `Elzoo.RecipeGraph.decode/1` on the
  `graph` member and gives `%{path: ["graph"], code: reason}` with its atom.
- `check_graph/3` calls `Elzoo.RecipeGraph.decode/1`; its reason has the path `[]`.

A structural fault is located at its part (the package, `graph`, `settings` or
`skills`), not at its node, because the ready validators stop at their first
fault and give no path. A package that fails stage 1 gets no stage 2 reason.

## Stage 2: the recipe against the facts

Only for a recipe that passed stage 1. All reasons are collected, none is
dropped, and the list is sorted by `path` and then by `code`. Paths below are
relative to the recipe; `check/2` puts `"graph"` before each path that points
into the recipe. A node path is `["callables", callable_index, "nodes", node_index]`.

| Code | Path | When |
| --- | --- | --- |
| `:unknown_tool` | the `tool` node | `Elzoo.ToolRegistry.resolve(tools, tool)` is not `{:resolved, _}` (unknown, removed or ambiguous) |
| `:need_not_declared` | the `tool` node | a need in the requirements of its tool is not declared |
| `:permission_not_declared` | the `tool` node | a permission in the requirements of its tool is not declared |
| `:need_not_provided` | `["needs", index]` | a declared need is not in `provided_needs` |
| `:permission_not_granted` | `["permissions", index]` | a declared permission is not in `granted_permissions` |
| `:missing_cost` | the node, or `["callables", index]` | a `tool` or `ask` node, or an `agent` or `decision` callable, has no entry in `costs` |
| `:unknown_cost_target` | `[]` (`["graph"]` in a package) | an entry of `costs` names no such node or callable, or one of another kind; one reason however many entries |
| `:over_cap` | `[]` (`["graph"]` in a package) | the upper cost of the root is larger than `cap`; never reported when a cost is missing |

One node gives at most one reason for each code, however many requirements are
missing. Every callable is checked, also one that the root does not reach.
`resolve/2` is used; `resolve/3` and `{:changed, _}` are not, because this check
holds no tool version.

Upper cost, with exact integers of any size: a `tool` or `ask` node is its
estimate; an `agent` or `decision` callable is its estimate; a `call` or
`decision` node is the upper cost of its callable; a `map` or `loop` node is
`max_iterations` times the upper cost of its callable; a `graph` callable is the
sum over all its nodes, also the nodes of branches that one run does not take.
The upper cost of the package is that of its `root`. It is an upper limit for the
declared estimates, not a forecast. Entries of `costs` that name no target are
ignored in the sum.

## Decisions

- Order: `facts` (and `declared`) are checked first. A malformed one gives
  `{:error, :invalid_facts}` before any stage 1 or stage 2 work: an error of the
  caller is reported before any verdict on the recipe.
- `tools` must be a `{:ToolRegistry, sources, entries, removed}` tuple with a
  list and two maps. Deeper content is the ready Contract of
  `workflow/tool-registry`; a value that `snapshot/1` or `refresh/3` did not make
  is outside it.
- Each bound is checked before its list or map is walked: a list is counted by a
  function that stops at one more than the bound and refuses an improper list;
  the requirements map is measured with `map_size/1`.
- `check/2` and `check_graph/3` share one private stage 2 function. For a package
  it receives `needs` and `permissions` of the package as `declared`, and the
  `graph` prefix, the re-sort and the package identity are added afterwards.
- If `RecipePackage.decode/1` refuses `:invalid_graph` and `RecipeGraph.decode/1`
  on the member accepts the graph, the reason is `%{path: ["graph"], code: :invalid_graph}`.
  The ready validators give no such case today; the branch is defensive and has
  no test.
- A missing cost forbids `:over_cap`, so one package cannot show all eight codes
  at once; the tests show seven in one package and `:over_cap` in the same
  package with its costs completed.
- Real reason paths never put an integer and a string at one position, so the
  sort needs no special case; the tests show a shorter path before a longer one
  with the same prefix and index 2 before index 10.
- No Cure module. No meaningful new law is selected: the decision is finite
  comparisons and an exact sum, and a Cure law over supplied Booleans would only
  restate them. Stage 2 is Elixir with tests only.
- The tests sign test packages with Jason and OTP crypto, as the test oracle of
  `domain/recipe-package` does. They reach the copy only through that dependency.
  This is test-only; the library calls neither.
- No logging, telemetry, process, clock or storage. Every refusal and error holds
  only fixed atoms, fixed key strings and integers.

## Bounds and errors

Bounds: those of `domain/recipe-package` and `domain/recipe-graph` for the
package; 256 provided needs; 256 granted permissions; 64 needs or permissions per
tool requirement or `declared` list; 1,000 tool requirements; 1,064 costs.
Errors: `{:error, :invalid_facts}`, and the reason atoms of `domain/recipe-package`,
`domain/recipe-graph` and the table above. A sentinel text inside `facts` never
appears in an error.

## Grounding

`mix test pieces/workflow/recipe-check/test` exercises the named groups
`structural_faults_located`, `tools_exist`, `needs_and_permissions`,
`upper_cost`, `all_reasons_in_order` and `same_input_same_verdict`. These are
finite scenarios: the listed scenarios pass. The last group evaluates
`examples/recipe_check.exs`; it also runs with
`mix run pieces/workflow/recipe-check/examples/recipe_check.exs`.

Two negative controls are temporary edits, never shipped: counting only the nodes
of the taken branch in the sum of a graph callable makes the `upper_cost` group
fail; skipping the comparison of declared permissions with the granted ones makes
the `needs_and_permissions` group fail.

This is no proof and no type check claim, and there is no monitored claim.
Reused Piece Contracts stay scoped to those Pieces.

## Needs and limits

Needs: a truthful snapshot, captured for this recipe; truthful requirements of
each tool; truthful grants of the tenant; estimates that are upper limits in one
unit; a caller that runs only a package whose check gave `{:ok, _}` and keeps the
verdict with the package identity.

Limits: the check grants no permission and reserves no budget; at run time the
engine still checks authority, approval and budget for every action. It is not a
tenant quota. Needs and permissions are opaque strings: no call of
`domain/authorization`, whose policies name actions and resources, not these
strings. Settings of a tenant are not checked here (`Elzoo.RecipeConfig.check/2`
does that). A structural fault has the location of its part only. A tool that
changes or leaves its source after the snapshot is not seen. Bindings of agents
and decisions are opaque: their tools and costs are what `costs` states. No I/O,
clock, process or storage. Telemetry, Config and Control are not applicable: pure
functions over intrinsic operands. Application-owned module, Apache-2.0; no new
dependency or pin.
