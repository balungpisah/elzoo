# SPDX-License-Identifier: Apache-2.0
alias Elzoo.Entitlement

# A plan version the host stores; the host computes its hash once and keeps it.
plan = %{
  plan_id: "team",
  version: 2,
  features: ["export", "sso"],
  allowances: [
    %{unit: :output_tokens, amount: 5_000_000, period_kind: :utc_month},
    %{unit: {:cache_write_tokens, "5m"}, amount: 1_000_000, period_kind: :utc_month}
  ]
}

{:ok, hash} = Entitlement.content_hash(plan)
plan = Map.put(plan, :content_hash, hash)

# Grants read from the host's storage; a revoked grant keeps its row.
grant = fn id, tenant, overrides ->
  Map.merge(
    %{
      grant_id: id,
      tenant: tenant,
      plan_id: "team",
      version: 2,
      valid_from_ms: 1_000,
      valid_to_ms: 2_000,
      grace_until_ms: 3_000,
      revoked_at_ms: nil
    },
    overrides
  )
end

facts = %{
  plans: [plan],
  grants: [
    grant.("g-acme", "acme", %{}),
    grant.("g-globex", "globex", %{revoked_at_ms: 1_500})
  ]
}

{:entitled, entitled} = Entitlement.resolve(facts, "acme", 1_500)
{:grace, grace} = Entitlement.resolve(facts, "acme", 2_500)

[
  # Entitled: the plan's features and allowances, attributed to the grant.
  {entitled.features, Enum.map(entitled.allowances, & &1.settle_only)},
  # In grace the features stay allowed and every allowance is settle-only.
  {Entitlement.feature(grace, "sso"), Enum.map(grace.allowances, & &1.settle_only)},
  Entitlement.feature(grace, "audit"),
  # Past grace, and another tenant's revoked grant.
  Entitlement.resolve(facts, "acme", 3_000),
  Entitlement.resolve(facts, "globex", 1_500)
]
