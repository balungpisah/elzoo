# ELZ-166 — What follows the outcome of a graph node

## Scope and reuse

- Dependencies: ELZ-033, ELZ-114, ELZ-161
- Output: `workflow/node-outcome`, one public module `Elzoo.NodeOutcome`; release V1B; RC-63 node-outcome portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/node-outcome/**` and its index/generated changes under AGENTS.md section 3.

Coordinator decision, 2026-11-14: RC-63 is published as two tasks. This task
is the pure rule for one settled node. `workflow/graph-run` follows in a later
publication and calls this rule; it is not part of this task.

One pure decision. Nothing executes. Implement only the named acceptance
groups below. Add no scheduler, graph walk, readiness rule, map or loop rule,
retry policy, options, behaviours or hooks. Change no ready Piece, shared
source, dependency pin or CI file. No fixtures directory is needed: use small
literal neutral maps in tests.

Facts checked on main:

- `workflow/pattern-step` (ELZ-114) fixes nine outcome classes: `completed`,
  `failed`, `refused`, `late`, `unknown`, `out_of_budget`,
  `retries_exhausted`, `expired`, `resource_lost`. `unknown` gives no retry
  authority. Its `accept/2` does not apply an outcome of class `late`.
- `domain/recipe-graph` (ELZ-161) accepts a link of kind `outcome` as exactly
  `{"from", "to", "kind": "outcome", "outcome": class}`, at most one per
  `(from, outcome)`. An omitted class has no fallback.

Use these words and shapes as they are. Define no new outcome word.

## Interface: `Elzoo.NodeOutcome`

Two functions.

`routes(links, node_id)` returns `{:ok, routes}` or `{:error, :invalid_input}`.
`links` is the `links` list of one graph callable, as neutral string-keyed maps
in the form of ELZ-161. `node_id` is UTF-8 text of 1 to 128 bytes. `routes` is
a map from an outcome class (string) to the target node ID (string): one entry
for each link with kind `outcome` and `from` equal to `node_id`. Links of the
kinds `order`, `data` and `choice`, and outcome links of other nodes, are not
read. A list of more than 10,000 links, a link that is not a map, an outcome
link with a class outside the nine, with a target that is not text of 1 to 128
bytes, or a second outcome link for one `(from, outcome)` is `:invalid_input`.
The function does not check that the target exists: `Elzoo.RecipeGraph.decode/1`
did that. It does not replace that validation.

`decide(routes, outcome)` returns one of exactly three decisions, or
`{:error, :invalid_input}`:

| Decision | When |
| --- | --- |
| `{:follow, target}` | `routes` has an entry for `outcome`. This holds for each of the nine classes, `completed` included. |
| `:proceed` | `outcome` is `completed` and `routes` has no entry for it. The ordinary successors of the node apply. |
| `{:fail_run, :no_outcome_link}` | `outcome` is one of the other eight classes and `routes` has no entry for it. The Run fails explicitly. |

`routes` is a map with at most nine entries whose keys are among the nine
classes and whose values are text of 1 to 128 bytes; `outcome` is one of the
nine class strings. Anything else is `:invalid_input`. The decision reads no
other route: a route for `failed` is never used for `refused`, and no class
falls back to `completed`.

No decision is a retry, a second try, a wait or a default target. The result
type has no such member. An `unknown` outcome with no route fails the Run; with
a route it follows the route. Whether the action behind an `unknown` outcome
ran is not decided here and is never assumed.

`late` is decided like the other seven classes that are not `completed`. The
README states that a step which settles outcomes through `PatternStep.accept/2`
never applies a `late` outcome, so with pattern-step version 1 a route for
`late` is not taken by such a step.

Cure owns the decision. Write it as a total Cure function over two facts (the
class is `completed`; a route exists for the class) with a three-member result
type, and prove at least these named laws:

- `route_is_followed`: when a route exists, the result is follow, for both
  values of the other fact.
- `uncompleted_without_route_fails`: no route and not `completed` gives fail.
- `completed_without_route_proceeds`: no route and `completed` gives proceed.

The Elixir module derives the two facts and calls the Cure decision; it does
not decide again in Elixir. Do not state a law that only repeats a Boolean.

## Host Needs and Limits

Fixed bounds: 10,000 links for `routes/2`; nine routes; 128 bytes for an ID.
Reasons: only `:invalid_input`. No input fragment appears in an error, a log
or a telemetry event.

Needs: links that `Elzoo.RecipeGraph.decode/1` accepted; an outcome class that
the engine recorded for the node; a caller that ends the Run on `:fail_run`
and runs no node again because of a decision of this Piece.

Limits: one node and one outcome at a time. No graph walk, no skip rule, no
join, no map or loop rule, no rule for the successors after `:proceed` or
after the target of a route completes: those belong to `workflow/graph-run`.
No retry and no time. No I/O, clock, process or storage. The Piece does not
say that a followed route repairs anything. Telemetry, Config and Control are
not applicable: pure functions over intrinsic operands.

The manifest declares `kind: owned`, providers `cure` and `elixir`, and the
Piece dependency `workflow/pattern-step`. It does not depend on
`domain/recipe-graph`: the link form above is the only thing it reads.

## Named acceptance groups

1. **`routes_of_one_node`**: from a link list with all four kinds and several
   nodes, `routes/2` gives exactly the outcome routes of the named node; a
   node with no outcome link gives an empty map; each malformed case above is
   `:invalid_input`; 10,000 links are accepted and 10,001 refused.
2. **`nine_classes_total`**: for each of the nine classes, with a route:
   follow to that target; without a route: proceed for `completed`, fail for
   each of the other eight. All 18 cases are listed, not sampled.
3. **`no_fallback_between_classes`**: with a route only for `failed`, each of
   the other seven uncompleted classes fails the Run and `completed`
   proceeds; with a route only for `completed`, each uncompleted class fails.
4. **`unknown_is_never_retried`**: `unknown` with and without a route; over
   the whole input space of `decide/2` (nine classes, each subset of routes
   used in the tests) the result is one of the three decisions and no other
   term.
5. **`class_names_match_pattern_step`**: for each of the nine classes, a
   neutral `action_outcome` input with that class passes
   `Elzoo.PatternStep.decode/1`, and a tenth name is refused by both.
6. **`invalid_input_and_redaction`**: wrong types, an unknown class, an
   unknown route key, an over-long target; a sentinel text inside a refused
   value never appears in the returned error or in captured logs. Equal inputs
   give equal results. One small checked example covers the public API.

## Evidence and gate

Proof: the three named Cure laws, checked by Cure. Test: the six groups.
Upstream: none. Negative controls: temporarily make an uncompleted class
without a route proceed, then temporarily let `refused` use the route of
`failed`; the corresponding law or group must fail. Restore both before the
final gate. Record assumptions and test results separately.

Run `mix test pieces/workflow/node-outcome/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

`workflow/graph-run`, readiness, skipped branches, joins, map, loop, nested
callables, the engine, retry or timeout policy, and any change of
`domain/recipe-graph` or `workflow/pattern-step`.
