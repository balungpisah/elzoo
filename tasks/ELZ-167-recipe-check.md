# ELZ-167 — Check a recipe package before it can run

## Scope and reuse

- Dependencies: ELZ-033, ELZ-136, ELZ-161, ELZ-162, ELZ-164
- Output: `workflow/recipe-check`, one public module `Elzoo.RecipeCheck`; release V1B; RC-64 load-time portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/recipe-check/**` and its index/generated changes under AGENTS.md section 3.

Coordinator decision, 2026-11-14: RC-64 is published as two tasks. This task
is the pure check of a whole recipe package at load time.
`workflow/runtime-graph` follows in a later publication and reuses this check
for a graph that a model gives; it is not part of this task.

One pure check. Nothing executes and nothing is stored. Implement only the
named acceptance groups below. Add no engine code, no authorization or
approval decision, no budget owner, no tenant quota, no settings check, no
options, behaviours or hooks. Change no ready Piece, shared source, dependency
pin or CI file. No fixtures directory is needed: use small literal neutral
maps in tests.

Facts checked on main. They decide what this check can read:

- `domain/recipe-package` (ELZ-164): `Elzoo.RecipePackage.decode/1` gives
  `{:ok, checked}` or `{:error, reason}` with one reason atom, the first
  fault only, with no location. A package holds `needs` and `permissions`: each at most 64 unique
  opaque strings of 1 to 128 bytes, declarations only. It holds `identity`
  (`recipe-package-v1:sha256:<hex>`), `graph`, `settings` and `skills`. A graph
  fault of any kind is `:invalid_graph`.
- `domain/recipe-graph` (ELZ-161): `Elzoo.RecipeGraph.decode/1` gives
  `{:ok, checked}` or `{:error, reason}` with one reason atom, the first
  fault only. A callable has no budget, cost, authority
  or permission member. A `tool` node holds `tool`, an opaque text of at most
  128 bytes. An `agent` callable holds only `binding`. `max_iterations` of a
  `map` or `loop` node is 1 to 256, so valid recipe data holds no unbounded
  map: a missing, zero or larger value is the structural fault
  `:invalid_shape`.
- `workflow/tool-registry` (ELZ-136): `resolve(snapshot, name)` gives
  `{:resolved, tool}`, `:removed`, `{:ambiguous, _}` or `:unknown`. Only
  `resolve/3`, with a held version, can give `{:changed, version}`; this check
  holds no version and does not call it.
- `workflow/budget` (ELZ-022): a unit is an opaque nonempty UTF-8 string and a
  cap is a positive integer of one budget identity. It is not a tenant quota.
  No function of it is called here.

So the recipe data does not hold what each node costs, what each tool needs or
which permissions a tenant has. The caller supplies these as the second
operand. The check compares; it grants nothing.

## Interface: `Elzoo.RecipeCheck`

`check(package, facts)` returns `{:ok, verdict}`, `{:refused, reasons}` or
`{:error, :invalid_facts}`.

`package` is the neutral string-keyed package map of ELZ-164, not a checked
value: this function decodes it. `facts` is a string-keyed map with exactly
these keys:

- `tools`: the snapshot of `Elzoo.ToolRegistry.snapshot/1` that the host
  captured for this recipe.
- `provided_needs`: a list of at most 256 unique strings of 1 to 128 bytes:
  the needs that the host can supply.
- `granted_permissions`: the same form: the permissions that the tenant
  granted to this recipe.
- `tool_requirements`: a map from a tool name (as a `tool` node holds it) to
  exactly `{"needs": [text], "permissions": [text]}`, each list at most 64
  unique strings of 1 to 128 bytes. At most 1,000 entries. A tool with no
  entry requires nothing.
- `unit`: a nonempty UTF-8 string of at most 128 bytes: the one budget unit of
  this check.
- `costs`: a list of at most 1,064 exact maps. `{"callable", "node",
  "estimate"}` gives the upper cost of one run of one `tool` or `ask` node;
  `{"callable", "estimate"}` gives the upper cost of one run of one `agent` or
  `decision` callable. `estimate` is an integer from 1 to 2^53. No duplicate
  target.
- `cap`: an integer from 1 to 2^63-1: the largest upper cost that the caller
  accepts for one run of the root, in `unit`.

A `facts` value in another shape is `{:error, :invalid_facts}`; it is an error
of the caller, not a verdict on the recipe. A sentinel text inside it never
appears in the error.

A reason is exactly `%{path: path, code: code}`: the violation form of
`core/payload-schema`. `path` is a list of strings and nonnegative integers
that locates the fault in the package map, for example
`["graph", "callables", 2, "nodes", 0]`. `code` is one of the fixed atoms
below. A reason holds no value of the package and no text of a library.

The check runs in two stages.

**Stage 1, structure.** One reason, the first fault, then stop:

1. `Elzoo.RecipePackage.decode(package)`. An `{:error, reason}` with a
   reason other than `:invalid_graph` gives `%{path: [], code: reason}`, except
   `:invalid_settings_descriptor` with the path `["settings"]` and
   `:invalid_skill` with the path `["skills"]`.
2. For `:invalid_graph`, call `Elzoo.RecipeGraph.decode/1` on the `graph`
   member and give `%{path: ["graph"], code: reason}` with the reason atom of its
   `{:error, reason}`.

This task does not write a second structural validator. The two ready
validators stop at their first fault and give no path, so a structural fault
is located at its part (the package, `graph`, `settings` or `skills`), not at
its node. The README says so. Each structural fault of ELZ-161 is thus refused
with the reason atom of ELZ-161 under `["graph"]`.

**Stage 2, the recipe against the facts.** Only for a package that passed
stage 1. All reasons are collected, none is dropped, and the list is sorted by
`path` (integers before strings, then by value) and then by `code`:

| Code | Path | When |
| --- | --- | --- |
| `:unknown_tool` | the `tool` node | `resolve(tools, tool)` is not `{:resolved, _}` |
| `:need_not_declared` | the `tool` node | a need in the requirements of its tool is not in `needs` of the package |
| `:permission_not_declared` | the `tool` node | a permission in the requirements of its tool is not in `permissions` of the package |
| `:need_not_provided` | `["needs", index]` | a declared need is not in `provided_needs` |
| `:permission_not_granted` | `["permissions", index]` | a declared permission is not in `granted_permissions` |
| `:missing_cost` | the node, or the callable | a `tool` or `ask` node, or an `agent` or `decision` callable, has no entry in `costs` |
| `:unknown_cost_target` | `["graph"]` | an entry of `costs` names no such node or callable, or a node or callable of another kind |
| `:over_cap` | `["graph"]` | the upper cost of the root is larger than `cap` |

One node gives at most one reason for each code. Strings are compared by exact
bytes. Every callable is checked, also one that the root does not reach.

**Upper cost.** With exact integers of any size:

- a `tool` or `ask` node: its estimate;
- an `agent` or `decision` callable: its estimate;
- a `call` or `decision` node: the upper cost of its callable;
- a `map` or `loop` node: `max_iterations` times the upper cost of its
  callable;
- a `graph` callable: the sum over all its nodes, also the nodes of branches
  that one run does not take.

The upper cost of the package is that of its `root`. It is an upper limit for
the declared estimates, not a forecast. When a cost is missing, `:over_cap` is
not reported.

**Verdict.** `{:ok, %{identity: identity, unit: unit, upper_cost: integer}}`,
with the `identity` member of the package. The same `package` and `facts` give
the same result, also in another process.

## Host Needs and Limits

Fixed bounds: those of ELZ-164 and ELZ-161 for the package; 256 provided
needs; 256 granted permissions; 1,000 tool requirements; 1,064 costs. Bounds
are checked before a list is walked. Reasons are the fixed atoms above and
the reason atoms of ELZ-164 and ELZ-161.

Needs: a truthful snapshot, captured for this recipe; truthful requirements
of each tool; truthful grants of the tenant; estimates that are upper limits
in one unit; a caller that runs only a package whose check gave `{:ok, _}` and
keeps the verdict with the package identity.

Limits: the check grants no permission and reserves no budget: at run time the
engine still checks authority, approval and budget for every action. It is not
a tenant quota. Needs and permissions are opaque strings: no call of
`domain/authorization`, whose policies name actions and resources, not these
strings. Settings of a tenant are not checked here (`Elzoo.RecipeConfig.check/2`
does that). A structural fault has the location of its part only. A tool that
changes or leaves its source after the snapshot is not seen. Bindings of
agents and decisions are opaque: their tools and costs are what `costs`
states. No I/O, clock, process or storage. Telemetry, Config and Control are
not applicable: pure functions over intrinsic operands.

The manifest declares `kind: owned`, providers `elixir`, and the Piece
dependencies `domain/recipe-package`, `domain/recipe-graph` and
`workflow/tool-registry`.

## Named acceptance groups

1. **`structural_faults_located`**: one package for each structural fault of
   ELZ-161 (unknown node kind, dangling name, a need with no giver, a decision
   with a missing branch, a cycle, depth over the limit, a link to a missing
   outcome, `max_iterations` of 0, of 257 and absent) is refused with exactly
   one reason under `["graph"]` and the atom of ELZ-161; a malformed skill
   under `["skills"]`; a malformed settings descriptor under `["settings"]`; a
   wrong package shape under `[]`. No stage 2 reason appears with them.
2. **`tools_exist`**: a tool that resolves passes; an unknown, a removed and an
   ambiguous name each give `:unknown_tool` at the node;
   two such nodes give two reasons in path order.
3. **`needs_and_permissions`**: a requirement that the recipe does not declare
   (need, then permission); a declared need that the host does not provide; a
   declared permission that the tenant did not grant; a tool with no
   requirements entry; a recipe that declares more than its tools require
   passes when all of it is provided and granted.
4. **`upper_cost`**: a graph with one node of each of the six kinds, nested
   two levels, where the expected sum is written by hand; a map and a loop at
   256 iterations; a branch that is not taken still counts; a cost at the cap
   passes and cap plus 1 is `:over_cap`; a missing cost of a node and of a
   callable; an unknown cost target; a product above 2^64 is exact.
5. **`all_reasons_in_order`**: one package with a fault of each stage 2 code
   gives every reason once, in the sorted order; the same package with its
   lists in another order gives the same reasons in the order of the new
   paths.
6. **`same_input_same_verdict`**: 20 calls, and a call in a second BEAM
   process, give equal results for one passing and one refused package; the
   package map is not changed; a sentinel text in a package value, a tool
   name, a need or a fact never appears in a reason, an error or a captured
   log. `{:error, :invalid_facts}` for each malformed member of `facts`, and
   for each bound plus 1. One small checked example covers the public API.

## Evidence and gate

Test: the six groups; reused Piece claims stay scoped to their Contracts. Cure
owns a new pure decision when a meaningful law is selected; do not add a
Boolean restatement. Negative controls: temporarily count only the reachable
nodes of the taken branch in the sum, then temporarily skip the grant
comparison; the corresponding groups must fail. Restore both before the final
gate. Record assumptions and test results separately.

Run `mix test pieces/workflow/recipe-check/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

`workflow/runtime-graph`, a graph that a model gives, a budget share, a
rendering of reasons for a model, the engine, `state/recipe-store`, a tenant
quota, authorization policies, settings values and any change of a ready
Piece.
