# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RateLimitTest.Model do
  @moduledoc false
  # Independent reference: buckets as maps, slots as plain counts, retry by stepping
  # through whole intervals, and eviction by an explicit scan.

  def new(c), do: %{c: c, tenants: %{}, principals: %{}, held: %{}, live: %{}, next: 0}

  def admit(m, t, p, cost, now) do
    pk = {t, p}

    cond do
      not room?(m, :tenants, t, now) or not room?(m, :principals, pk, now) ->
        {{:refused, :keys, nil}, m}

      map_size(m.live) == m.c.max_in_flight ->
        {{:refused, :slots, nil}, m}

      Map.get(m.held, t, 0) == m.c.tenant_in_flight ->
        {{:refused, :tenant_slots, nil}, m}

      true ->
        tb = bucket(m.tenants, t, m.c.tenant_rate, now)
        pb = bucket(m.principals, pk, m.c.principal_rate, now)

        cond do
          tb.tokens < cost ->
            {{:refused, :tenant_rate, wait(tb, m.c.tenant_rate, cost, now)}, m}

          pb.tokens < cost ->
            {{:refused, :principal_rate, wait(pb, m.c.principal_rate, cost, now)}, m}

          true ->
            commit(
              m,
              t,
              pk,
              %{tb | tokens: tb.tokens - cost},
              %{pb | tokens: pb.tokens - cost},
              now
            )
        end
    end
  end

  def release(m, id) do
    case Map.fetch(m.live, id) do
      {:ok, t} ->
        held = if m.held[t] == 1, do: Map.delete(m.held, t), else: Map.update!(m.held, t, &(&1 - 1))
        {:ok, %{m | live: Map.delete(m.live, id), held: held}}

      :error ->
        {:unknown_ticket, m}
    end
  end

  defp commit(m, t, pk, tb, pb, now) do
    tenants = m.tenants |> evict(m, :tenants, t, now) |> Map.put(t, tb)
    principals = m.principals |> evict(m, :principals, pk, now) |> Map.put(pk, pb)
    id = m.next

    {{:ok, id},
     %{
       m
       | tenants: tenants,
         principals: principals,
         held: Map.update(m.held, t, 1, &(&1 + 1)),
         live: Map.put(m.live, id, t),
         next: id + 1
     }}
  end

  defp room?(m, kind, k, now),
    do: Map.has_key?(m[kind], k) or map_size(m[kind]) < m.c.max_keys or idle(m, kind, now) != []

  defp evict(buckets, m, kind, k, now) do
    if Map.has_key?(buckets, k) or map_size(buckets) < m.c.max_keys do
      buckets
    else
      [{_, victim} | _] = Enum.sort(idle(m, kind, now))
      Map.delete(buckets, victim)
    end
  end

  defp idle(m, kind, now) do
    rate = if kind == :tenants, do: m.c.tenant_rate, else: m.c.principal_rate

    for {k, b} <- m[kind],
        not Map.has_key?(m.held, owner(k)),
        refilled(b, rate, now).tokens == rate.capacity,
        do: {b.last, k}
  end

  defp owner({t, _}), do: t
  defp owner(t), do: t

  defp bucket(buckets, k, rate, now) do
    case Map.fetch(buckets, k) do
      {:ok, b} -> refilled(b, rate, now)
      :error -> %{tokens: rate.capacity, last: now}
    end
  end

  defp refilled(b, _rate, now) when now < b.last, do: b

  defp refilled(b, rate, now) do
    intervals = div(now - b.last, rate.interval_ms)

    %{
      tokens: min(rate.capacity, b.tokens + rate.refill * intervals),
      last: b.last + intervals * rate.interval_ms
    }
  end

  defp wait(b, rate, cost, now) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find(&(b.tokens + rate.refill * &1 >= cost))
    |> Kernel.*(rate.interval_ms)
    |> Kernel.+(b.last - now)
  end
end

defmodule Elzoo.RateLimitTest do
  use ExUnit.Case, async: true

  alias Elzoo.RateLimit
  alias Elzoo.RateLimitTest.Model

  @seed {280, 644, 2026}
  @max_ms 9_223_372_036_854_775_807

  defp rate(capacity, refill, interval_ms),
    do: %{capacity: capacity, refill: refill, interval_ms: interval_ms}

  defp opts(over \\ []) do
    Keyword.merge(
      [
        tenant_rate: rate(3, 1, 1_000),
        principal_rate: rate(100, 100, 1),
        max_in_flight: 100,
        tenant_in_flight: 100,
        max_keys: 16
      ],
      over
    )
  end

  defp new!(over \\ []) do
    {:ok, s} = RateLimit.new(opts(over))
    s
  end

  defp key(t, p \\ "p"), do: %{tenant: t, principal: p}

  defp ok!(s, k, cost, now) do
    assert {:ok, ticket, next} = RateLimit.admit(s, k, cost, now)
    {ticket, next}
  end

  defp pass!(s, k, cost, now), do: s |> ok!(k, cost, now) |> elem(1)

  defp refused(s, k, cost, now) do
    case RateLimit.admit(s, k, cost, now) do
      {:refused, reason, retry, ^s} -> {reason, retry}
      other -> flunk("expected a refusal with the input state, got #{inspect(other)}")
    end
  end

  describe "1. config" do
    test "accepts each option at its bounds" do
      for over <- [
            [tenant_rate: rate(1, 1, 1), principal_rate: rate(1, 1, 1)],
            [tenant_rate: rate(1_000_000, 1_000_000, 86_400_000)],
            [principal_rate: rate(1_000_000, 1, 86_400_000)],
            [max_in_flight: 1, tenant_in_flight: 1],
            [max_in_flight: 1_000_000, tenant_in_flight: 1_000_000],
            [max_keys: 1],
            [max_keys: 65_536]
          ] do
        assert {:ok, %RateLimit{}} = RateLimit.new(opts(over)), inspect(over)
      end
    end

    test "refuses each option one past its bounds, and refill above capacity" do
      bad_rates = [
        rate(0, 1, 1),
        rate(1_000_001, 1, 1),
        rate(3, 0, 1),
        rate(3, 4, 1),
        rate(3, 1, 0),
        rate(3, 1, 86_400_001),
        rate(3.0, 1, 1),
        %{capacity: 3, refill: 1},
        Map.put(rate(3, 1, 1), :burst, 1),
        %{"capacity" => 3, "refill" => 1, "interval_ms" => 1},
        [capacity: 3, refill: 1, interval_ms: 1]
      ]

      overs =
        Enum.flat_map(bad_rates, &[[tenant_rate: &1], [principal_rate: &1]]) ++
          [
            [max_in_flight: 0, tenant_in_flight: 1],
            [max_in_flight: 1_000_001],
            [tenant_in_flight: 0],
            [tenant_in_flight: 101],
            [max_keys: 0],
            [max_keys: 65_537],
            [max_keys: 2.0]
          ]

      for over <- overs, do: assert({:error, :config} == RateLimit.new(opts(over)), inspect(over))
    end

    test "refuses a missing, extra, duplicate or string key" do
      full = opts()

      for bad <- [
            Keyword.delete(full, :max_keys),
            full ++ [burst: 1],
            full ++ [max_keys: 4],
            [{"max_keys", 16} | Keyword.delete(full, :max_keys)],
            Map.new(full),
            nil
          ] do
        assert {:error, :config} == RateLimit.new(bad)
      end
    end
  end

  describe "2. buckets" do
    test "exact refill, retry and cap with capacity 3, refill 1, interval 1000" do
      s = new!()
      k = key("acme")
      s = Enum.reduce(1..3, s, fn _, s -> pass!(s, k, 1, 0) end)
      assert {:tenant_rate, 1_000} == refused(s, k, 1, 0)
      assert {:tenant_rate, 1} == refused(s, k, 1, 999)
      s = pass!(s, k, 1, 1_000)
      assert {:tenant_rate, 1_000} == refused(s, k, 1, 1_000)

      # Nine intervals elapsed, but the bucket holds only its capacity.
      s = Enum.reduce(1..3, s, fn _, s -> pass!(s, k, 1, 10_000) end)
      assert {:tenant_rate, 1_000} == refused(s, k, 1, 10_000)
    end

    test "a cost of 2 with 1 token left waits for the next whole interval" do
      s = new!()
      k = key("acme")
      s = s |> pass!(k, 1, 0) |> pass!(k, 1, 0)
      assert {:tenant_rate, 600} == refused(s, k, 2, 400)
      # At 1500 one whole interval has passed: 2 tokens, last_ms 1000, not 1500.
      s = pass!(s, k, 1, 1_500)
      assert %{"acme" => {1, 1_000}} = s.tenants
      assert {:tenant_rate, 500} == refused(s, k, 2, 1_500)
      assert {:tenant_rate, 1_500} == refused(s, k, 3, 1_500)
      s = pass!(s, k, 2, 2_000)
      assert %{"acme" => {0, 2_000}} = s.tenants
    end

    test "a refill of several tokens per interval computes the least wait" do
      s = new!(tenant_rate: rate(10, 3, 100))
      k = key("acme")
      s = pass!(s, k, 10, 50)
      assert {:tenant_rate, 100} == refused(s, k, 3, 50)
      assert {:tenant_rate, 200} == refused(s, k, 4, 50)
      assert {:tenant_rate, 330} == refused(s, k, 10, 120)
    end

    test "a clock that goes back adds nothing and keeps last_ms" do
      s = new!()
      k = key("acme")
      s = Enum.reduce(1..3, s, fn _, s -> pass!(s, k, 1, 5_000) end)
      assert {:tenant_rate, 6_000} == refused(s, k, 1, 0)
      s = pass!(s, k, 1, 6_000)
      assert %{"acme" => {0, 6_000}} = s.tenants
      s = pass!(new!(), k, 1, 6_000)
      s = pass!(s, k, 1, 2_000)
      assert %{"acme" => {1, 6_000}} = s.tenants
      assert {:tenant_rate, 5_000} == refused(s, k, 2, 2_000)
      s = pass!(s, k, 1, 7_000)
      assert %{"acme" => {1, 7_000}} = s.tenants
    end

    test "times up to 2^63 - 1 compute without overflow" do
      s = new!(tenant_rate: rate(3, 1, 86_400_000))
      k = key("acme")
      s = Enum.reduce(1..3, s, fn _, s -> pass!(s, k, 1, @max_ms) end)
      assert {:tenant_rate, 86_400_000} == refused(s, k, 1, @max_ms)
      s = pass!(new!(), k, 3, 0)
      s = pass!(s, k, 3, @max_ms)
      assert %{"acme" => {0, last}} = s.tenants
      assert last == @max_ms - rem(@max_ms, 1_000)
    end
  end

  describe "3. all or nothing" do
    test "each of the five refusals returns the input state" do
      one = rate(1, 1, 1_000)

      s = new!(max_keys: 1)
      {_, s} = ok!(s, key("a"), 1, 0)
      assert {:keys, nil} == refused(s, key("b"), 1, 0)

      s = new!(max_in_flight: 1, tenant_in_flight: 1)
      {_, s} = ok!(s, key("a"), 1, 0)
      assert {:slots, nil} == refused(s, key("b"), 1, 0)

      s = new!(tenant_in_flight: 1)
      {_, s} = ok!(s, key("a"), 1, 0)
      assert {:tenant_slots, nil} == refused(s, key("a", "q"), 1, 0)

      s = new!(tenant_rate: one)
      {_, s} = ok!(s, key("a"), 1, 0)
      assert {:tenant_rate, 1_000} == refused(s, key("a", "q"), 1, 0)

      s = new!(principal_rate: one)
      {_, s} = ok!(s, key("a"), 1, 0)
      assert {:principal_rate, 1_000} == refused(s, key("a"), 1, 0)
    end

    test "a principal refusal after the tenant bucket passed takes no token and no slot" do
      s = new!(principal_rate: rate(1, 1, 1_000), max_in_flight: 3, tenant_in_flight: 3)
      s = pass!(s, key("a", "p"), 1, 0)
      assert {:principal_rate, 1_000} == refused(s, key("a", "p"), 1, 0)
      assert %{"a" => {2, 0}} = s.tenants
      # Both remaining tenant tokens and both remaining slots are still there.
      s = s |> pass!(key("a", "q"), 1, 0) |> pass!(key("a", "r"), 1, 0)
      assert %{"a" => {0, 0}} = s.tenants
      assert {:slots, nil} == refused(s, key("b"), 1, 0)
    end

    test "the first refusal in the fixed order wins" do
      s = new!(tenant_rate: rate(1, 1, 1_000), max_in_flight: 1, tenant_in_flight: 1, max_keys: 1)
      s = pass!(s, key("a"), 1, 0)
      assert {:keys, nil} == refused(s, key("b"), 1, 0)
      assert {:slots, nil} == refused(s, key("a"), 1, 0)

      s = new!(tenant_rate: rate(1, 1, 1_000), max_in_flight: 2, tenant_in_flight: 1)
      s = pass!(s, key("a"), 1, 0)
      assert {:tenant_slots, nil} == refused(s, key("a"), 1, 0)

      s = new!(tenant_rate: rate(1, 1, 1_000), principal_rate: rate(1, 1, 1_000))
      s = pass!(s, key("a"), 1, 0)
      assert {:tenant_rate, 1_000} == refused(s, key("a"), 1, 0)
    end
  end

  describe "4. fair share" do
    test "global and per-tenant slot bounds, exact release, double release" do
      s = new!(max_in_flight: 4, tenant_in_flight: 2)
      {a1, s} = ok!(s, key("a"), 1, 0)
      {_a2, s} = ok!(s, key("a"), 1, 0)
      assert {:tenant_slots, nil} == refused(s, key("a"), 1, 0)
      {_b1, s} = ok!(s, key("b"), 1, 0)
      {_b2, s} = ok!(s, key("b"), 1, 0)
      assert {:slots, nil} == refused(s, key("c"), 1, 0)

      assert {:ok, released} = RateLimit.release(s, a1)
      assert {:error, :unknown_ticket} == RateLimit.release(released, a1)
      assert {:tenant_slots, nil} == refused(released, key("b"), 1, 1_000)
      {_a3, s} = ok!(released, key("a"), 1, 1_000)
      # Global saturation is checked before the tenant bound.
      assert {:slots, nil} == refused(s, key("a"), 1, 1_000)
      assert {:slots, nil} == refused(s, key("c"), 1, 1_000)
    end

    test "tickets are unique and a release frees the slots of its own tenant only" do
      s = new!(max_in_flight: 3, tenant_in_flight: 2)
      {a1, s} = ok!(s, key("a"), 1, 0)
      {b1, s} = ok!(s, key("b"), 1, 0)
      {a2, s} = ok!(s, key("a"), 1, 0)
      assert length(Enum.uniq([a1, b1, a2])) == 3
      {:ok, s} = RateLimit.release(s, b1)
      assert {:tenant_slots, nil} == refused(s, key("a"), 1, 0)
      s = pass!(s, key("b"), 1, 0)
      assert {:error, :unknown_ticket} == RateLimit.release(s, b1)
      assert {:error, :unknown_ticket} == RateLimit.release(s, {:ticket, 99, "a"})
      assert {:error, :unknown_ticket} == RateLimit.release(s, :ticket)
    end

    test "a noisy tenant that spent its tokens does not reduce another tenant" do
      quiet = fn s ->
        Enum.reduce_while(1..10, {s, 0}, fn _, {s, n} ->
          case RateLimit.admit(s, key("b"), 1, 0) do
            {:ok, _, s} -> {:cont, {s, n + 1}}
            {:refused, _, _, _} -> {:halt, {s, n}}
          end
        end)
        |> elem(1)
      end

      s = new!(max_in_flight: 10, tenant_in_flight: 5)
      alone = quiet.(s)
      s = Enum.reduce(1..3, s, fn _, s -> pass!(s, key("a"), 1, 0) end)
      for _ <- 1..20, do: assert({:tenant_rate, 1_000} == refused(s, key("a"), 1, 0))
      assert alone == 3
      assert quiet.(s) == alone
    end
  end

  describe "5. keys" do
    test "a third tenant waits until one bucket is idle and full, then drops it" do
      s = new!(max_keys: 2)
      {a, s} = ok!(s, key("a"), 1, 0)
      {b, s} = ok!(s, key("b"), 1, 500)
      assert {:keys, nil} == refused(s, key("c"), 1, 10_000)
      {:ok, s} = RateLimit.release(s, a)
      {:ok, s} = RateLimit.release(s, b)
      # Released, but not full yet.
      assert {:keys, nil} == refused(s, key("c"), 1, 999)
      s = pass!(s, key("c"), 1, 1_000)
      assert Map.keys(s.tenants) == ["b", "c"]
      assert Map.keys(s.slots) == ["b", "c"]
      assert map_size(s.principals) == 2
    end

    test "the oldest stored last_ms drops first, ties in byte order of the key" do
      idle = fn s, k, now ->
        {ticket, s} = ok!(s, k, 1, now)
        {:ok, s} = RateLimit.release(s, ticket)
        s
      end

      s = new!(max_keys: 2, tenant_rate: rate(3, 3, 1_000))
      s = s |> idle.(key("b", "p"), 0) |> idle.(key("a", "q"), 500)
      # At 2000 b projects to last_ms 2000 and a to 1500; the stored 0 of b is older.
      s = pass!(s, key("c", "r"), 1, 2_000)
      assert Map.keys(s.tenants) == ["a", "c"]
      assert Map.keys(s.principals) == [{"a", "q"}, {"c", "r"}]

      s = new!(max_keys: 2)
      s = s |> idle.(key("é"), 0) |> idle.(key("z"), 0)
      s = pass!(s, key("c"), 1, 5_000)
      assert Map.keys(s.tenants) == ["c", "é"]
    end

    test "a dropped tenant's Backpressure state is created again at its next admission" do
      s = new!(max_keys: 1, tenant_in_flight: 1)
      {a, s} = ok!(s, key("a"), 1, 0)
      {:ok, s} = RateLimit.release(s, a)
      s = pass!(s, key("b", "p"), 1, 3_000)
      assert Map.keys(s.slots) == ["b"]
      assert {:keys, nil} == refused(s, key("a"), 1, 3_000)
      assert {:tenant_slots, nil} == refused(s, key("b", "p"), 1, 9_000)
    end

    test "principal buckets have their own cap and idle only without live tickets" do
      s = new!(max_keys: 2, principal_rate: rate(2, 1, 1_000))
      {t1, s} = ok!(s, key("a", "p1"), 1, 0)
      {t2, s} = ok!(s, key("a", "p2"), 1, 0)
      assert {:keys, nil} == refused(s, key("b", "p3"), 1, 5_000)
      {:ok, s} = RateLimit.release(s, t1)
      assert {:keys, nil} == refused(s, key("b", "p3"), 1, 5_000)
      {:ok, s} = RateLimit.release(s, t2)
      s = pass!(s, key("b", "p3"), 1, 5_000)
      assert Map.keys(s.principals) == [{"a", "p2"}, {"b", "p3"}]
    end
  end

  describe "6. model check" do
    @tag timeout: 120_000
    test "10,000 seeded operations agree with an independent reference model" do
      :rand.seed(:exsss, @seed)

      config = [
        tenant_rate: rate(5, 2, 80),
        principal_rate: rate(3, 3, 20),
        max_in_flight: 3,
        tenant_in_flight: 2,
        max_keys: 2
      ]

      {:ok, s} = RateLimit.new(config)
      model = Model.new(Map.new(config))

      {_, _, _, _, counts} =
        Enum.reduce(1..10_000, {s, model, 1_000, %{}, %{}}, fn step, {s, m, now, issued, counts} ->
          now = next_time(now)

          {s, m, issued, outcome} =
            if release?(m, issued) do
              {ticket, id} = pick(issued, m, step)
              got = RateLimit.release(s, ticket)
              {want, m2} = Model.release(m, id)

              case got do
                {:ok, s2} ->
                  assert want == :ok, "step #{step}"
                  {s2, m2, issued, :released}

                {:error, :unknown_ticket} ->
                  assert want == :unknown_ticket, "step #{step}"
                  {s, m2, issued, :unknown_ticket}
              end
            else
              t = Enum.random(["t1", "t2", "t3"])
              p = Enum.random(["p1", "p2", "p3"])
              cost = Enum.random(1..3)
              got = RateLimit.admit(s, %{tenant: t, principal: p}, cost, now)
              {want, m2} = Model.admit(m, t, p, cost, now)

              case got do
                {:ok, ticket, s2} ->
                  assert {:ok, id} = want, "step #{step}"
                  {s2, m2, Map.put(issued, id, ticket), :admitted}

                {:refused, reason, retry, s2} ->
                  assert s2 == s, "step #{step}"
                  assert want == {:refused, reason, retry}, "step #{step}"
                  {s, m2, issued, reason}
              end
            end

          assert map_size(s.slots) <= 2 and map_size(s.tenants) <= 2, "step #{step}"
          assert map_size(s.principals) <= 2, "step #{step}"
          # The same buckets were kept and dropped.
          assert Map.keys(s.tenants) == Map.keys(m.tenants), "step #{step}"
          assert Map.keys(s.principals) == Map.keys(m.principals), "step #{step}"
          {s, m, now, issued, Map.update(counts, outcome, 1, &(&1 + 1))}
        end)

      for outcome <- [
            :admitted,
            :released,
            :unknown_ticket,
            :keys,
            :slots,
            :tenant_slots,
            :tenant_rate,
            :principal_rate
          ] do
        assert Map.get(counts, outcome, 0) >= 100, "#{outcome}: #{inspect(counts)}"
      end
    end

    defp next_time(now) do
      case :rand.uniform(100) do
        n when n <= 2 -> now + 5_000
        n when n <= 4 -> max(0, now - 2_000)
        _ -> max(0, now + Enum.random(-60..120))
      end
    end

    # Most releases free a live ticket; the rest repeat any earlier ticket (live or
    # already released) or forge one. The choice only steers the trace: the expected
    # result still comes from Model.release/2.
    defp release?(m, issued),
      do:
        issued != %{} and
          :rand.uniform(100) <= if(m.live == %{}, do: 4, else: 12 * map_size(m.live))

    defp pick(issued, m, step) do
      if m.live != %{} and :rand.uniform(100) <= 90 do
        id = Enum.random(Map.keys(m.live))
        {Map.fetch!(issued, id), id}
      else
        Enum.random([
          {{:ticket, step + 1_000_000, "t1"}, :forged} | Enum.map(issued, fn {id, t} -> {t, id} end)
        ])
      end
    end
  end

  describe "7. shape" do
    test "malformed texts, costs, times, keys and states" do
      s = new!(principal_rate: rate(5, 1, 1))
      good = "acme"

      for {text, ok?} <- [
            {"", false},
            {"a", true},
            {String.duplicate("a", 128), true},
            {String.duplicate("é", 64), true},
            {String.duplicate("a", 129), false},
            {<<0xFF>>, false},
            {"a\0", false},
            {"a\x1F", false},
            {"\x7F", false},
            {"\u0085", false},
            {"\u009F", false},
            {"\u00A0", true},
            {:acme, false},
            {~c"acme", false}
          ],
          k <- [key(text, good), key(good, text)] do
        result = RateLimit.admit(s, k, 1, 0)
        if ok?, do: assert({:ok, _, _} = result), else: assert({:error, :malformed} == result)
      end

      for {cost, now} <- [{0, 0}, {4, 0}, {1.0, 0}, {nil, 0}, {1, -1}, {1, @max_ms + 1}, {1, 1.0}] do
        assert {:error, :malformed} == RateLimit.admit(s, key(good), cost, now)
      end

      assert {:ok, _, _} = RateLimit.admit(s, key(good), 3, @max_ms)

      for k <- [
            %{tenant: good},
            Map.put(key(good), :extra, 1),
            [tenant: good, principal: good],
            nil
          ] do
        assert {:error, :malformed} == RateLimit.admit(s, k, 1, 0)
      end

      {ticket, held} = ok!(s, key(good), 1, 0)

      for forged <- [
            Map.from_struct(s),
            Map.put(s, :extra, 1),
            %{s | max_keys: 0},
            %{s | tenant_in_flight: 101},
            %{s | tenant_rate: rate(3, 4, 1)},
            %{s | global: :none},
            %{s | tenants: []},
            %{s | next: -1},
            %{s | tenants: %{good => {4, 0}}},
            %{s | tenants: %{good => {1, -1}}},
            %{s | principals: %{{good, good} => {1.0, 0}}},
            %{s | principals: %{good => {1, 0}}},
            %{
              s
              | tenants: %{"\0" => {1, 0}},
                slots: %{"\0" => elem(Elzoo.Backpressure.new(100), 1)}
            },
            %{s | slots: %{good => :none}},
            %{held | live: %{good => []}},
            %{held | live: %{good => %{held.next => true}}},
            %{held | live: %{good => %{-1 => true}}},
            %{held | live: %{good => %{:x => true}}},
            %{held | live: %{good => %{0 => :nope}}},
            %{held | live: %{}},
            %{held | slots: %{}},
            %{held | global: elem(Elzoo.Backpressure.new(100), 1)},
            %{held | global: {:CapacityState, 101, 1}},
            %{held | slots: %{good => {:CapacityState, 100, 0}}},
            %{held | tenants: %{"other" => {1, 0}}},
            :state
          ] do
        assert {:error, :malformed} == RateLimit.admit(forged, key(good), 1, 0), inspect(forged)
      end

      assert {:error, :unknown_ticket} == RateLimit.release(Map.put(held, :extra, 1), ticket)
      assert {:error, :unknown_ticket} == RateLimit.release(%{held | global: :none}, ticket)
      assert {:error, :unknown_ticket} == RateLimit.release(%{held | slots: %{}}, ticket)

      assert {:error, :unknown_ticket} ==
               RateLimit.release(%{held | global: {:CapacityState, 100, 0}}, ticket)

      assert {:ok, _} = RateLimit.release(held, ticket)

      # Counts that agree with the live tickets but exceed their bounds.
      {:ok, one} = RateLimit.new(opts(max_in_flight: 1, tenant_in_flight: 1))
      {t0, one} = ok!(one, key(good), 1, 0)

      over = %{
        one
        | live: %{good => %{0 => true, 1 => true}},
          slots: %{good => {:CapacityState, 1, 2}},
          global: {:CapacityState, 1, 2},
          next: 2
      }

      assert {:error, :malformed} == RateLimit.admit(over, key(good), 1, 0)
      assert {:error, :unknown_ticket} == RateLimit.release(over, t0)
    end
  end
end
