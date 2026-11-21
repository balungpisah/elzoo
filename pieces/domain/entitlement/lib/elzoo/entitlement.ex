# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Entitlement do
  @moduledoc """
  Pure resolution of a tenant's plan grants at one injected time to entitled,
  grace or not entitled, with the plan's features and its unit allowances.
  No I/O, clock, process, storage, billing, quota or authorization decision.
  See the bundle README.
  """

  alias Elzoo.AiModel.Usage

  @cure :"Cure.Elzoo.Entitlement"
  @max_int 9_223_372_036_854_775_807
  @max_version 2_147_483_647
  @period_kinds [:utc_month]
  @facts_keys [:grants, :plans]
  @plan_keys [:allowances, :content_hash, :features, :plan_id, :version]
  @body_keys [:allowances, :features, :plan_id, :version]
  @allowance_keys [:amount, :period_kind, :unit]
  @grant_keys [
    :grace_until_ms,
    :grant_id,
    :plan_id,
    :revoked_at_ms,
    :tenant,
    :valid_from_ms,
    :valid_to_ms,
    :version
  ]
  @resolution_keys [:allowances, :at_ms, :features, :grants, :tenant]
  @source_keys [:content_hash, :grant_id, :plan_id, :status, :version]
  @granted_keys [:amount, :grant_id, :period_kind, :settle_only, :unit]

  @doc """
  The SHA-256 of the canonical encoding of `{plan_id, version, features,
  allowances}`; a `content_hash` key in `plan` is ignored.
  """
  def content_hash(plan) when is_map(plan) and not is_struct(plan) do
    body = Map.delete(plan, :content_hash)
    if body?(body), do: {:ok, hash(body)}, else: {:error, :plans}
  end

  def content_hash(_plan), do: {:error, :plans}

  @doc "Resolves the grants of `tenant` in `facts` at `now_ms`."
  def resolve(facts, tenant, now_ms) do
    with true <- time?(now_ms) || {:error, :now},
         true <- text?(tenant) || {:error, :tenant},
         true <-
           (shape?(facts, @facts_keys) and proper?(facts.plans) and proper?(facts.grants)) ||
             {:error, :facts},
         {:ok, plans} <- plans(facts.plans),
         true <- grants?(facts.grants) || {:error, :grants},
         true <- Enum.all?(facts.plans, &(&1.content_hash == hash(&1))) || {:error, :content_hash},
         own = Enum.filter(facts.grants, &(&1.tenant == tenant)),
         true <-
           Enum.all?(own, &Map.has_key?(plans, {&1.plan_id, &1.version})) ||
             {:error, :unknown_plan} do
      classify(own, plans, tenant, now_ms)
    end
  end

  @doc "`:allow` when `name` is a feature of `resolution`, also in grace."
  def feature(resolution, name) do
    cond do
      not (resolution?(resolution) and text?(name)) -> {:error, :invalid}
      name in resolution.features -> :allow
      true -> {:deny, :feature_absent}
    end
  end

  # ---------------------------------------------------------------- resolution

  defp classify(own, plans, tenant, now) do
    statuses = Enum.map(own, &{&1, status(&1, now)})

    case for({g, s} <- statuses, s in [:entitled, :grace], do: {g, s}) do
      [_, _ | _] -> {:error, :overlap}
      [] -> {:not_entitled, ended(Enum.map(statuses, &elem(&1, 1)))}
      contributing -> resolution(contributing, plans, tenant, now)
    end
  end

  defp ended(statuses) do
    cond do
      :revoked in statuses -> :revoked
      :expired in statuses -> :expired
      true -> :no_grant
    end
  end

  # Elixir computes the flags; Cure owns their order.
  defp status(g, now) do
    revoked = g.revoked_at_ms != nil and g.revoked_at_ms <= now
    ended = g.valid_to_ms != nil and g.valid_to_ms <= now
    grace = ended and g.grace_until_ms != nil and now < g.grace_until_ms
    active = g.valid_from_ms <= now and (g.valid_to_ms == nil or now < g.valid_to_ms)

    case apply(@cure, :status, [revoked, ended and not grace, grace, active]) do
      :StatusRevoked -> :revoked
      :StatusExpired -> :expired
      :StatusGrace -> :grace
      :StatusActive -> :entitled
      :StatusNotYet -> :not_yet
    end
  end

  defp resolution(contributing, plans, tenant, now) do
    sources =
      for {g, s} <- contributing, do: {g, s, Map.fetch!(plans, {g.plan_id, g.version})}

    tag = if Enum.all?(contributing, &(elem(&1, 1) == :grace)), do: :grace, else: :entitled

    {tag,
     %{
       tenant: tenant,
       at_ms: now,
       grants:
         for {g, s, p} <- sources do
           %{
             grant_id: g.grant_id,
             plan_id: p.plan_id,
             version: p.version,
             content_hash: p.content_hash,
             status: s
           }
         end,
       features: :lists.usort(Enum.flat_map(sources, fn {_, _, p} -> p.features end)),
       allowances:
         for {g, s, p} <- sources, a <- p.allowances do
           Map.merge(a, %{settle_only: s == :grace, grant_id: g.grant_id})
         end
     }}
  end

  # ---------------------------------------------------------------- canonical encoding

  # Every value is length-prefixed: text = <<size::32, bytes>>, integer =
  # <<n::64>>, list = <<count::32, items>>, record = text(fields), field =
  # text(key) <> value. Optional keys added later are appended only when present.
  defp hash(plan), do: :crypto.hash(:sha256, encode(plan))

  defp encode(plan) do
    [
      text("elzoo/entitlement/plan"),
      field("plan_id", text(plan.plan_id)),
      field("version", int(plan.version)),
      field("features", list(Enum.map(plan.features, &text/1))),
      field("allowances", list(Enum.map(plan.allowances, &allowance/1)))
    ]
  end

  defp allowance(a) do
    text([
      field("unit", unit(a.unit)),
      field("amount", int(a.amount)),
      field("period_kind", text(Atom.to_string(a.period_kind)))
    ])
  end

  defp unit({kind, ttl}), do: list([text(Atom.to_string(kind)), text(ttl)])
  defp unit(kind), do: list([text(Atom.to_string(kind))])

  defp field(key, value), do: [text(key), value]
  defp int(n), do: <<n::64>>
  defp list(items), do: [<<length(items)::32>> | items]

  defp text(iodata) do
    bytes = IO.iodata_to_binary(iodata)
    <<byte_size(bytes)::32, bytes::binary>>
  end

  # ---------------------------------------------------------------- validation

  defp plans(list) do
    with true <- within?(list, 1024) and Enum.all?(list, &plan?/1),
         index = Map.new(list, &{{&1.plan_id, &1.version}, &1}),
         true <- map_size(index) == length(list) do
      {:ok, index}
    else
      _ -> {:error, :plans}
    end
  end

  defp plan?(p) do
    shape?(p, @plan_keys) and is_binary(p.content_hash) and byte_size(p.content_hash) == 32 and
      body?(Map.delete(p, :content_hash))
  end

  defp body?(p) do
    shape?(p, @body_keys) and text?(p.plan_id) and version?(p.version) and
      within?(p.features, 256) and Enum.all?(p.features, &text?/1) and ascending?(p.features) and
      within?(p.allowances, 64) and Enum.all?(p.allowances, &allowance?/1) and
      ascending?(Enum.map(p.allowances, &{&1.unit, &1.period_kind}))
  end

  defp allowance?(a) do
    shape?(a, @allowance_keys) and unit?(a.unit) and is_integer(a.amount) and
      a.amount in 1..@max_int and a.period_kind in @period_kinds
  end

  defp unit?({:cache_write_tokens, ttl}), do: ttl in Usage.ttls()
  defp unit?(unit), do: unit in Usage.units()

  defp grants?(list) do
    within?(list, 1024) and Enum.all?(list, &grant?/1) and
      length(Enum.uniq_by(list, & &1.grant_id)) == length(list)
  end

  defp grant?(g) do
    shape?(g, @grant_keys) and text?(g.grant_id) and text?(g.tenant) and text?(g.plan_id) and
      version?(g.version) and time?(g.valid_from_ms) and
      (g.valid_to_ms == nil or (time?(g.valid_to_ms) and g.valid_to_ms > g.valid_from_ms)) and
      (g.grace_until_ms == nil or
         (g.valid_to_ms != nil and time?(g.grace_until_ms) and g.grace_until_ms > g.valid_to_ms)) and
      (g.revoked_at_ms == nil or time?(g.revoked_at_ms))
  end

  defp resolution?(r) do
    shape?(r, @resolution_keys) and text?(r.tenant) and time?(r.at_ms) and
      r.grants != [] and proper?(r.grants) and Enum.all?(r.grants, &source?/1) and
      proper?(r.features) and Enum.all?(r.features, &text?/1) and ascending?(r.features) and
      proper?(r.allowances) and Enum.all?(r.allowances, &granted?/1)
  end

  defp source?(s) do
    shape?(s, @source_keys) and text?(s.grant_id) and text?(s.plan_id) and version?(s.version) and
      is_binary(s.content_hash) and byte_size(s.content_hash) == 32 and
      s.status in [:entitled, :grace]
  end

  defp granted?(a) do
    shape?(a, @granted_keys) and is_boolean(a.settle_only) and text?(a.grant_id) and
      allowance?(Map.drop(a, [:settle_only, :grant_id]))
  end

  # A plain atom-keyed map with exactly these keys; a struct is refused.
  defp shape?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp shape?(_, _), do: false

  # A proper list of at most n entries.
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  # Strictly increasing in Erlang term order: sorted and unique.
  defp ascending?([a, b | rest]), do: a < b and ascending?([b | rest])
  defp ascending?(_), do: true

  defp version?(n), do: is_integer(n) and n in 1..@max_version
  defp time?(n), do: is_integer(n) and n in 0..@max_int

  # The ELZ-267 text rule: 1..128 bytes of valid UTF-8 without C0 or C1 controls.
  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
