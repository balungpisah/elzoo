# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RateLimit do
  @moduledoc """
  Pure all-or-nothing admission over a caller-held state: one token from a
  per-tenant and from a per-principal bucket, and one in-flight slot from a
  global and from a per-tenant `Elzoo.Backpressure` bound, or nothing.
  """
  alias Elzoo.Backpressure

  @max_ms 9_223_372_036_854_775_807
  @enforce_keys [:tenant_rate, :principal_rate, :max_in_flight, :tenant_in_flight, :max_keys]
  @options Enum.sort(@enforce_keys)
  defstruct @enforce_keys ++
              [global: nil, tenants: %{}, slots: %{}, principals: %{}, live: %{}, next: 0]

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == @options do
      o = Map.new(opts)

      if config?(o.tenant_rate, o.principal_rate, o.max_in_flight, o.tenant_in_flight, o.max_keys) do
        {:ok, global} = Backpressure.new(o.max_in_flight)
        {:ok, struct!(__MODULE__, Map.put(o, :global, global))}
      else
        {:error, :config}
      end
    else
      {:error, :config}
    end
  end

  def new(_), do: {:error, :config}

  def admit(s, %{tenant: t, principal: p} = key, cost, now)
      when map_size(key) == 2 and is_integer(cost) and cost >= 1 and is_integer(now) and
             now >= 0 and now <= @max_ms do
    if state?(s) and text?(t) and text?(p) and
         cost <= min(s.tenant_rate.capacity, s.principal_rate.capacity),
       do: decide(s, t, {t, p}, cost, now),
       else: {:error, :malformed}
  end

  def admit(_, _, _, _), do: {:error, :malformed}

  def release(s, {:ticket, id, t}) do
    with true <- state?(s),
         %{^id => true} = ids <- Map.get(s.live, t) do
      {:ok, global} = Backpressure.release(s.global)
      {:ok, own} = Backpressure.release(Map.fetch!(s.slots, t))

      live =
        if map_size(ids) == 1,
          do: Map.delete(s.live, t),
          else: Map.put(s.live, t, Map.delete(ids, id))

      {:ok, %{s | global: global, slots: Map.put(s.slots, t, own), live: live}}
    else
      _ -> {:error, :unknown_ticket}
    end
  end

  def release(_, _), do: {:error, :unknown_ticket}

  # Every check reads the input state; only a full pass builds the next state.
  defp decide(s, t, pk, cost, now) do
    with {:ok, drop_t} <- room(s.tenants, t, & &1, s.tenant_rate, s, now),
         {:ok, drop_p} <- room(s.principals, pk, &elem(&1, 0), s.principal_rate, s, now),
         {:ok, global} <- slot(s.global, :slots),
         {:ok, own} <- slot(Map.get_lazy(s.slots, t, fn -> fresh(s) end), :tenant_slots),
         {:ok, tb} <- take(Map.get(s.tenants, t), s.tenant_rate, cost, now, :tenant_rate),
         {:ok, pb} <- take(Map.get(s.principals, pk), s.principal_rate, cost, now, :principal_rate) do
      id = s.next

      {:ok, {:ticket, id, t},
       %{
         s
         | global: global,
           tenants: s.tenants |> Map.delete(drop_t) |> Map.put(t, tb),
           slots: s.slots |> Map.delete(drop_t) |> Map.put(t, own),
           principals: s.principals |> Map.delete(drop_p) |> Map.put(pk, pb),
           live: Map.update(s.live, t, %{id => true}, &Map.put(&1, id, true)),
           next: id + 1
       }}
    else
      {:refused, reason} -> {:refused, reason, nil, s}
      {:refused, reason, retry} -> {:refused, reason, retry, s}
    end
  end

  # A key that is present, or fits, needs no drop. Otherwise the oldest idle
  # bucket (full at now, no live ticket of its tenant) is dropped, by stored
  # last_ms and then by key in Erlang term order (bytes; tenant, then principal).
  defp room(buckets, key, tenant_of, rate, s, now) do
    if Map.has_key?(buckets, key) or map_size(buckets) < s.max_keys do
      {:ok, nil}
    else
      buckets
      |> Enum.reject(fn {k, b} ->
        Map.has_key?(s.live, tenant_of.(k)) or elem(refill(b, rate, now), 0) < rate.capacity
      end)
      |> Enum.min_by(fn {k, {_, last}} -> {last, k} end, fn -> nil end)
      |> case do
        nil -> {:refused, :keys}
        {k, _} -> {:ok, k}
      end
    end
  end

  defp slot(bp, reason) do
    case Backpressure.admit(bp) do
      {:ok, next, :admitted} -> {:ok, next}
      {:ok, _, :saturated} -> {:refused, reason}
    end
  end

  defp fresh(s) do
    {:ok, bp} = Backpressure.new(s.tenant_in_flight)
    bp
  end

  defp take(nil, rate, cost, now, reason), do: take({rate.capacity, now}, rate, cost, now, reason)

  defp take(bucket, rate, cost, now, reason) do
    {tokens, last} = refill(bucket, rate, now)

    if tokens >= cost,
      do: {:ok, {tokens - cost, last}},
      else: {:refused, reason, last + ceil_div(cost - tokens, rate.refill) * rate.interval_ms - now}
  end

  # Whole intervals only; a clock that went back adds nothing and keeps last_ms.
  defp refill({tokens, last}, %{capacity: c, refill: r, interval_ms: i}, now) when now >= last do
    k = div(now - last, i)
    {min(c, tokens + r * k), last + k * i}
  end

  defp refill(bucket, _rate, _now), do: bucket

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # The whole state is checked on every call, in time linear in its buckets and
  # live tickets: config, every bucket, every ticket id below next, and that each
  # Backpressure count equals the live tickets it covers and fits its bound.
  defp state?(
         %__MODULE__{
           tenant_rate: tr,
           principal_rate: pr,
           max_in_flight: m,
           tenant_in_flight: n,
           max_keys: k,
           tenants: tenants,
           principals: principals,
           slots: slots,
           live: live,
           next: next
         } = s
       ) do
    map_size(s) == 12 and config?(tr, pr, m, n, k) and is_integer(next) and next >= 0 and
      buckets?(tenants, k, &text?/1, tr) and
      buckets?(principals, k, &principal_key?/1, pr) and
      is_map(slots) and map_size(slots) == map_size(tenants) and is_map(live) and
      Enum.all?(slots, fn {t, bp} ->
        Map.has_key?(tenants, t) and capacity?(bp, n, held(live, t, next))
      end) and
      Enum.all?(live, fn {t, _} -> Map.has_key?(slots, t) end) and
      capacity?(s.global, m, live |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum())
  end

  defp state?(_), do: false

  defp buckets?(buckets, k, key?, rate),
    do:
      is_map(buckets) and map_size(buckets) <= k and
        Enum.all?(buckets, fn {key, b} -> key?.(key) and bucket?(b, rate) end)

  defp principal_key?({t, p}), do: text?(t) and text?(p)
  defp principal_key?(_), do: false

  defp held(live, t, next) do
    case Map.fetch(live, t) do
      :error ->
        0

      {:ok, ids} when is_map(ids) and map_size(ids) > 0 ->
        if Enum.all?(ids, &match?({id, true} when is_integer(id) and id >= 0 and id < next, &1)),
          do: map_size(ids)

      {:ok, _} ->
        nil
    end
  end

  # Elzoo.Backpressure documents its erased state as {:CapacityState, capacity, in_flight}.
  defp capacity?(bp, capacity, held),
    do: is_integer(held) and held <= capacity and bp == {:CapacityState, capacity, held}

  defp bucket?({tokens, last}, rate),
    do:
      is_integer(tokens) and tokens >= 0 and tokens <= rate.capacity and is_integer(last) and
        last >= 0 and last <= @max_ms

  defp bucket?(_, _), do: false

  defp config?(tr, pr, m, n, k),
    do:
      rate?(tr) and rate?(pr) and int?(m, 1, 1_000_000) and int?(n, 1, m) and
        int?(k, 1, 65_536)

  defp rate?(%{capacity: c, refill: r, interval_ms: i} = rate),
    do:
      map_size(rate) == 3 and int?(c, 1, 1_000_000) and int?(r, 1, c) and
        int?(i, 1, 86_400_000)

  defp rate?(_), do: false

  defp int?(x, lo, hi), do: is_integer(x) and x >= lo and x <= hi

  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
