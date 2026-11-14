# workflow/node-outcome

The pure rule for what follows the settled outcome of one graph node. One public
Elixir module, `Elzoo.NodeOutcome`, supplies two functions. Nothing executes:
no scheduler, graph walk, retry or clock.

## Contract

`routes(links, node_id)` returns `{:ok, routes}` or `{:error, :invalid_input}`.
`links` is the `links` list of one graph callable as neutral string-keyed maps
in the form of `domain/recipe-graph`: an outcome link is exactly
`{"from", "to", "kind": "outcome", "outcome": class}`. `routes` maps an outcome
class to the target node ID, one entry for each outcome link whose `from` is
`node_id`. Links of the kinds `order`, `data` and `choice`, and outcome links of
other nodes, are not read. More than 10,000 links, a link that is not a map, an
outcome link of the node with a class outside the nine, a target that is not
UTF-8 text of 1 to 128 bytes, a `node_id` outside that form, or a second outcome
link for one `(from, outcome)` is `:invalid_input`. Targets are not checked to
exist: `Elzoo.RecipeGraph.decode/1` did that, and this function does not replace
it. This Piece does not depend on `domain/recipe-graph`.

`decide(routes, outcome)` returns exactly one of:

| Decision | When |
| --- | --- |
| `{:follow, target}` | `routes` has an entry for `outcome`, for each of the nine classes, `completed` included |
| `:proceed` | `outcome` is `completed` and `routes` has no entry for it: the ordinary successors apply |
| `{:fail_run, :no_outcome_link}` | `outcome` is one of the other eight classes and `routes` has no entry for it |

`routes` is a map of at most nine entries with class keys and 1..128-byte text
values; `outcome` is one of the nine class strings. Anything else is
`{:error, :invalid_input}`. The decision reads no other route: a route for
`failed` is never used for `refused`, and no class falls back to `completed`.
No decision is a retry, a second try, a wait or a default target; the result
type has no such member. An `unknown` outcome with no route fails the Run, and
with a route follows it. Whether the action behind an `unknown` outcome ran is
not decided here and is never assumed.

The nine classes are those of `workflow/pattern-step`: `completed`, `failed`,
`refused`, `late`, `unknown`, `out_of_budget`, `retries_exhausted`, `expired`,
`resource_lost`. No new outcome word is defined.

`late` is decided like the other seven classes that are not `completed`. A step
that settles outcomes through `PatternStep.accept/2` never applies a `late`
outcome, so with pattern-step version 1 a route for `late` is not taken by such
a step.

## Grounding

The Cure decision `decide(completed, routed)` is a total function over two
Booleans (the class is `completed`; a route exists for the class) with the
result type follow / proceed / fail. The selected laws `route_is_followed`
(for both values of `completed`), `uncompleted_without_route_fails` and
`completed_without_route_proceeds` pass the pinned Cure check. The Elixir
module derives the two facts, calls the compiled Cure decision and maps its
result; it does not decide again. The laws do not cover that derivation, the
link and route validation, or the class names.

`mix test pieces/workflow/node-outcome/test` runs the listed scenarios of the
six groups: `routes_of_one_node`, `nine_classes_total` (all 18 cases),
`no_fallback_between_classes`, `unknown_is_never_retried` (every subset of
routes for every class), `class_names_match_pattern_step` and
`invalid_input_and_redaction` (sentinel text, equal inputs, a checked example).
Two temporary negative controls (an uncompleted class without a route that
proceeds; `refused` using the route of `failed`) fail the matching law or
group and are never shipped. These are finite tests, not a universal proof.
There is no monitored runtime claim.

## Needs and Limits

Needs: links that `Elzoo.RecipeGraph.decode/1` accepted; an outcome class that
the engine recorded for the node; a caller that ends the Run on `:fail_run` and
runs no node again because of a decision of this Piece.

Limits: fixed bounds of 10,000 links, nine routes and 128 bytes for an ID. The
only error reason is `:invalid_input`; no input fragment appears in an error, a
log or a telemetry event. One node and one outcome at a time. No graph walk, no
skip rule, no join, no map or loop rule, and no rule for the successors after
`:proceed` or after the target of a route completes: those belong to
`workflow/graph-run`. No retry and no time. No I/O, clock, process or storage.
The Piece does not say that a followed route repairs anything. Telemetry,
Config and Control are not applicable: pure functions over intrinsic operands.

Copies are application-owned under `Elzoo.NodeOutcome` and
`Cure.Elzoo.NodeOutcome`, one coordinated revision per module. See
[consuming](../../../docs/consuming.md). Apache-2.0 source; direct dependency
`workflow/pattern-step`; provider Cure at the repository pin. No new dependency
or runtime.
