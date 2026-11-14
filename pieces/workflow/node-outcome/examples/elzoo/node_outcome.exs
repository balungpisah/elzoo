# SPDX-License-Identifier: Apache-2.0
alias Elzoo.NodeOutcome

links = [
  %{"from" => "a", "to" => "b", "kind" => "order"},
  %{"from" => "b", "to" => "c", "kind" => "outcome", "outcome" => "failed"},
  %{"from" => "d", "to" => "e", "kind" => "outcome", "outcome" => "refused"}
]

{:ok, routes} = NodeOutcome.routes(links, "b")

{
  routes,
  NodeOutcome.decide(routes, "failed"),
  NodeOutcome.decide(routes, "completed"),
  NodeOutcome.decide(routes, "refused")
}
