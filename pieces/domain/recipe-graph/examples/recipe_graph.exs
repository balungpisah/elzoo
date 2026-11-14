# SPDX-License-Identifier: Apache-2.0
typed = fn direction ->
  %{
    "port" => %{
      "id" => direction,
      "direction" => direction,
      "schema_id" => "item",
      "schema_version" => 1
    },
    "schema" => %{"type" => "object"}
  }
end

recipe = %{
  "version" => 1,
  "id" => "reviewed-work",
  "revision" => 1,
  "root" => "main",
  "callables" => [
    %{
      "name" => "main",
      "kind" => "graph",
      "input" => typed.("input"),
      "output" => typed.("output"),
      "input_slots" => [],
      "nodes" => [%{"id" => "review", "kind" => "ask", "needs" => [], "gives" => []}],
      "links" => []
    }
  ],
  "bindings" => [],
  "rules" => [
    %{
      "callable" => "main",
      "node" => "review",
      "policy" => %{"id" => "policy", "version" => 1, "content_hash" => String.duplicate("09", 32)},
      "requirement" => %{"name" => "review", "version" => 1, "scope" => "once"}
    }
  ]
}

{:ok, checked} = Elzoo.RecipeGraph.decode(recipe)
^recipe = Elzoo.RecipeGraph.encode(checked)
[rule] = recipe["rules"]

requirement = %{
  name: rule["requirement"]["name"],
  version: rule["requirement"]["version"],
  scope: :once
}

policy = %{
  id: rule["policy"]["id"],
  version: rule["policy"]["version"],
  content_hash: Base.decode16!(rule["policy"]["content_hash"], case: :lower),
  effect_classes: ["publish"],
  rules: [%{id: "review", effect_class: "publish", verdict: :ask, requirement: requirement}]
}

write = %{target: "item", field: "state", value: {:text, "published"}}

proposal = %{
  tenant: "tenant",
  resource: "item",
  action_id: "action",
  payload: {:text, "body"},
  writes: [write]
}

authority = %{proposer: "proposer", effect_class: "publish", own: [write], parent: :none}
{:ok, asked} = Elzoo.Authorization.decide(policy, proposal, authority)
:ask = asked.verdict
[] = asked.permitted
{:ok, state, request, {:requested, _}} = Elzoo.Approval.request(Elzoo.Approval.new(), "run", asked)

context = %{
  now: 2_000,
  max_age: 10_000,
  verifiers: ["verifier"],
  run: %{id: "run", root: "root", ancestry: ["root"]},
  policy: policy,
  proposal: proposal,
  authority: authority,
  approver: %{identity: "reviewer", authority: [write]}
}

evidence = %{
  verifier: "verifier",
  evidence_id: "evidence",
  reviewer: "reviewer",
  request: request.key,
  decision: :approve,
  scope: :once,
  issued_at: 1_000,
  expiry: 100_000
}

{:refused, _, _} = Elzoo.Approval.release(state, request.key, :retained, context)
{:released, _, [^write], _} = Elzoo.Approval.release(state, request.key, evidence, context)

changed_write = %{write | value: {:text, "changed"}}

for changed <- [
      %{context | proposal: %{proposal | payload: {:text, "changed"}}},
      %{context | policy: %{policy | version: 2}},
      %{
        context
        | proposal: %{proposal | writes: [changed_write]},
          authority: %{authority | own: [changed_write]},
          approver: %{identity: "reviewer", authority: [changed_write]}
      }
    ] do
  {:refused, _, _} = Elzoo.Approval.release(state, request.key, evidence, changed)
end

{:ok, denied} =
  Elzoo.Authorization.decide(
    %{policy | rules: [%{id: "deny", effect_class: "publish", verdict: :deny} | policy.rules]},
    proposal,
    authority
  )

:deny = denied.verdict
[] = denied.permitted
{:error, _} = Elzoo.Approval.request(Elzoo.Approval.new(), "run", denied)
:ok
