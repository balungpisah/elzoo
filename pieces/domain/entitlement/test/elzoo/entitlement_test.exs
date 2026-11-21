# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EntitlementTest do
  use ExUnit.Case, async: true
  alias Elzoo.Entitlement

  @max 9_223_372_036_854_775_807
  @errors [:now, :tenant, :facts, :plans, :grants, :content_hash, :unknown_plan, :overlap]

  defmodule FakeFacts, do: defstruct([:plans, :grants])

  # ---------------------------------------------------------------- builders

  defp body(overrides \\ %{}) do
    Map.merge(
      %{
        plan_id: "team",
        version: 1,
        features: ["export", "sso"],
        allowances: [
          %{unit: :output_tokens, amount: 1_000, period_kind: :utc_month},
          %{unit: {:cache_write_tokens, "5m"}, amount: 50, period_kind: :utc_month}
        ]
      },
      overrides
    )
  end

  defp plan(overrides \\ %{}) do
    b = body(overrides)
    assert {:ok, hash} = Entitlement.content_hash(b)
    Map.put(b, :content_hash, hash)
  end

  defp grant(overrides \\ %{}) do
    Map.merge(
      %{
        grant_id: "g1",
        tenant: "acme",
        plan_id: "team",
        version: 1,
        valid_from_ms: 1_000,
        valid_to_ms: 2_000,
        grace_until_ms: 3_000,
        revoked_at_ms: nil
      },
      overrides
    )
  end

  defp facts(grants, plans \\ [plan()]), do: %{plans: plans, grants: grants}

  defp at(grants, now, tenant \\ "acme"), do: Entitlement.resolve(facts(grants), tenant, now)

  defp refused(f, reason), do: assert(Entitlement.resolve(f, "acme", 1_500) == {:error, reason})

  defp bad_plan(overrides), do: refused(facts([grant()], [Map.merge(plan(), overrides)]), :plans)

  defp bad_grant(overrides), do: refused(facts([grant(overrides)]), :grants)

  # ---------------------------------------------------------------- time boundaries

  describe "boundaries at exact now" do
    test "valid_from_ms is inclusive" do
      assert at([grant()], 999) == {:not_entitled, :no_grant}
      assert {:entitled, _} = at([grant()], 1_000)
    end

    test "valid_to_ms is exclusive, to grace or to expired" do
      assert {:entitled, _} = at([grant()], 1_999)
      assert {:grace, _} = at([grant()], 2_000)
      assert {:entitled, _} = at([grant(%{grace_until_ms: nil})], 1_999)
      assert at([grant(%{grace_until_ms: nil})], 2_000) == {:not_entitled, :expired}
    end

    test "grace_until_ms is exclusive" do
      assert {:grace, _} = at([grant()], 2_999)
      assert at([grant()], 3_000) == {:not_entitled, :expired}
    end

    test "an open valid_to_ms stays entitled" do
      open = grant(%{valid_to_ms: nil, grace_until_ms: nil})
      for now <- [1_000, 2_000, 3_000, @max], do: assert({:entitled, _} = at([open], now))
    end

    test "time zero and the largest time are accepted" do
      g = grant(%{valid_from_ms: 0, valid_to_ms: @max - 1, grace_until_ms: @max})
      assert {:entitled, _} = at([g], 0)
      assert {:entitled, _} = at([g], @max - 2)
      assert {:grace, _} = at([g], @max - 1)
      assert at([g], @max) == {:not_entitled, :expired}
    end
  end

  describe "revocation" do
    test "revoked during grace is revoked" do
      g = grant(%{revoked_at_ms: 2_500})
      assert {:grace, _} = at([g], 2_499)
      assert at([g], 2_500) == {:not_entitled, :revoked}
      assert at([g], 2_999) == {:not_entitled, :revoked}
    end

    test "revoked at exactly valid_to_ms with grace is revoked" do
      assert at([grant(%{revoked_at_ms: 2_000})], 2_000) == {:not_entitled, :revoked}
    end

    test "revoked before valid_from_ms is revoked at a now after it" do
      g = grant(%{revoked_at_ms: 500})
      assert at([g], 500) == {:not_entitled, :revoked}
      assert at([g], 1_500) == {:not_entitled, :revoked}
    end

    test "a revocation after now does not apply yet" do
      g = grant(%{revoked_at_ms: 1_500})
      assert {:entitled, _} = at([g], 1_499)
      assert at([g], 1_500) == {:not_entitled, :revoked}
    end

    test "revoked and expired is revoked" do
      assert at([grant(%{revoked_at_ms: 2_500})], 4_000) == {:not_entitled, :revoked}
      assert at([grant(%{revoked_at_ms: 500})], 4_000) == {:not_entitled, :revoked}
    end

    test "a revoked grant beside an expired one is revoked; expired beside not yet is expired" do
      revoked = grant(%{grant_id: "r", revoked_at_ms: 100, valid_from_ms: 0, valid_to_ms: 10})
      expired = grant(%{grant_id: "e", valid_from_ms: 0, valid_to_ms: 10, grace_until_ms: nil})
      later = grant(%{grant_id: "l", valid_from_ms: 5_000, valid_to_ms: nil, grace_until_ms: nil})
      assert at([expired, revoked], 4_000) == {:not_entitled, :revoked}
      assert at([later, expired], 4_000) == {:not_entitled, :expired}
      assert at([later], 4_000) == {:not_entitled, :no_grant}
      assert at([], 4_000) == {:not_entitled, :no_grant}
    end
  end

  # ---------------------------------------------------------------- tenants and overlap

  describe "grants of one tenant and of two tenants" do
    test "two grants of one tenant active or in grace at now overlap" do
      a = grant(%{grant_id: "a"})
      b = grant(%{grant_id: "b", valid_from_ms: 1_500, valid_to_ms: nil, grace_until_ms: nil})
      assert at([a, b], 1_500) == {:error, :overlap}
      # a in grace and b active.
      assert at([a, b], 2_500) == {:error, :overlap}
      # Before b starts only a contributes; after a's grace only b.
      assert {:entitled, %{grants: [%{grant_id: "a"}]}} = at([a, b], 1_499)
      assert {:entitled, %{grants: [%{grant_id: "b"}]}} = at([a, b], 3_000)
    end

    test "two grants that do not overlap at now resolve to the active one" do
      old = grant(%{grant_id: "old", valid_from_ms: 0, valid_to_ms: 1_000, grace_until_ms: nil})
      new = grant(%{grant_id: "new", valid_to_ms: nil, grace_until_ms: nil})

      revoked =
        grant(%{
          grant_id: "rev",
          valid_from_ms: 0,
          valid_to_ms: nil,
          grace_until_ms: nil,
          revoked_at_ms: 10
        })

      assert {:entitled, %{grants: [%{grant_id: "new"}]}} = at([old, revoked, new], 1_000)
      assert {:entitled, %{grants: [%{grant_id: "old"}]}} = at([old, revoked, new], 999)
    end

    test "grants of two tenants never cross" do
      pro = plan(%{plan_id: "pro", features: ["audit"]})
      a = grant(%{grant_id: "a", tenant: "acme"})
      b = grant(%{grant_id: "b", tenant: "globex", plan_id: "pro"})
      f = facts([a, b], [plan(), pro])

      assert {:entitled, ra} = Entitlement.resolve(f, "acme", 1_500)
      assert {:entitled, rb} = Entitlement.resolve(f, "globex", 1_500)
      assert {ra.tenant, ra.features, hd(ra.grants).plan_id} == {"acme", ["export", "sso"], "team"}
      assert {rb.tenant, rb.features, hd(rb.grants).plan_id} == {"globex", ["audit"], "pro"}
      assert Entitlement.resolve(f, "initech", 1_500) == {:not_entitled, :no_grant}

      assert Entitlement.resolve(facts([b], [plan(), pro]), "acme", 1_500) ==
               {:not_entitled, :no_grant}
    end

    test "an overlap of another tenant does not affect this tenant" do
      a = grant(%{grant_id: "a", tenant: "globex"})
      b = grant(%{grant_id: "b", tenant: "globex"})
      c = grant(%{grant_id: "c"})
      assert {:entitled, %{grants: [%{grant_id: "c"}]}} = at([a, b, c], 1_500)
      assert at([a, b, c], 1_500, "globex") == {:error, :overlap}
    end

    test "tenants compare by exact bytes" do
      assert at([grant()], 1_500, "Acme") == {:not_entitled, :no_grant}
      assert at([grant()], 1_500, "acme ") == {:not_entitled, :no_grant}
      assert at([grant(%{tenant: "e\u0301"})], 1_500, "\u00e9") == {:not_entitled, :no_grant}
    end
  end

  # ---------------------------------------------------------------- plan references

  describe "plan references and content hashes" do
    test "an unknown plan version is unknown_plan" do
      assert at([grant(%{version: 2})], 1_500) == {:error, :unknown_plan}
      assert at([grant(%{plan_id: "pro"})], 1_500) == {:error, :unknown_plan}
    end

    test "an unknown plan of another tenant's grant is not checked" do
      other = grant(%{grant_id: "o", tenant: "globex", version: 9})
      assert {:entitled, _} = at([grant(), other], 1_500)
    end

    test "an unknown plan wins over an ended or not yet grant" do
      assert at([grant(%{version: 2})], 0) == {:error, :unknown_plan}
      assert at([grant(%{version: 2, revoked_at_ms: 0})], 5_000) == {:error, :unknown_plan}
    end

    test "a content hash mismatch is content_hash, also for a plan no grant names" do
      bad = %{plan(%{version: 2}) | content_hash: :binary.copy(<<0>>, 32)}

      assert Entitlement.resolve(facts([grant()], [plan(), bad]), "acme", 1_500) ==
               {:error, :content_hash}

      stale = %{plan() | content_hash: plan(%{features: ["export"]}).content_hash}

      assert Entitlement.resolve(facts([grant()], [stale]), "acme", 1_500) ==
               {:error, :content_hash}

      assert Entitlement.resolve(facts([], [bad]), "acme", 1_500) == {:error, :content_hash}
    end

    test "content_hash/1 ignores the content_hash key and covers every body field" do
      assert {:ok, h} = Entitlement.content_hash(body())
      assert byte_size(h) == 32
      assert Entitlement.content_hash(Map.put(body(), :content_hash, "anything")) == {:ok, h}

      variants = [
        body(%{plan_id: "team2"}),
        body(%{version: 2}),
        body(%{features: ["export"]}),
        body(%{features: ["export", "ssp"]}),
        body(%{allowances: []}),
        body(%{allowances: [%{unit: :output_tokens, amount: 1_001, period_kind: :utc_month}]}),
        body(%{allowances: [%{unit: :reasoning_tokens, amount: 1_000, period_kind: :utc_month}]}),
        body(%{
          allowances: [%{unit: {:cache_write_tokens, "1h"}, amount: 50, period_kind: :utc_month}]
        }),
        # The length prefix keeps feature boundaries apart.
        body(%{features: ["exports"]}),
        body(%{features: ["ex", "port"]})
      ]

      hashes = [h | Enum.map(variants, &elem(Entitlement.content_hash(&1), 1))]
      assert length(Enum.uniq(hashes)) == length(hashes)
    end

    test "content_hash/1 matches the documented canonical encoding" do
      text = fn b -> <<byte_size(b)::32, b::binary>> end
      list = fn items -> [<<length(items)::32>> | items] end
      field = fn k, v -> [text.(k), v] end

      allowance = fn unit, amount ->
        text.(
          IO.iodata_to_binary([
            field.("unit", list.(Enum.map(unit, text))),
            field.("amount", <<amount::64>>),
            field.("period_kind", text.("utc_month"))
          ])
        )
      end

      expected =
        :crypto.hash(:sha256, [
          text.("elzoo/entitlement/plan"),
          field.("plan_id", text.("team")),
          field.("version", <<1::64>>),
          field.("features", list.([text.("export"), text.("sso")])),
          field.(
            "allowances",
            list.([
              allowance.(["output_tokens"], 1_000),
              allowance.(["cache_write_tokens", "5m"], 50)
            ])
          )
        ])

      assert Entitlement.content_hash(body()) == {:ok, expected}
    end

    test "content_hash/1 refuses a malformed plan" do
      for bad <- [
            nil,
            [],
            Map.delete(body(), :features),
            Map.put(body(), :extra, 1),
            body(%{features: ["sso", "export"]}),
            body(%{version: 0}),
            struct(FakeFacts, %{})
          ],
          do: assert(Entitlement.content_hash(bad) == {:error, :plans})
    end
  end

  # ---------------------------------------------------------------- resolution and feature/2

  describe "resolution and feature/2" do
    test "an entitled resolution names its source and marks no allowance settle-only" do
      p = plan()
      assert {:entitled, r} = at([grant()], 1_500)

      assert r == %{
               tenant: "acme",
               at_ms: 1_500,
               grants: [
                 %{
                   grant_id: "g1",
                   plan_id: "team",
                   version: 1,
                   content_hash: p.content_hash,
                   status: :entitled
                 }
               ],
               features: ["export", "sso"],
               allowances: [
                 %{
                   unit: :output_tokens,
                   amount: 1_000,
                   period_kind: :utc_month,
                   settle_only: false,
                   grant_id: "g1"
                 },
                 %{
                   unit: {:cache_write_tokens, "5m"},
                   amount: 50,
                   period_kind: :utc_month,
                   settle_only: false,
                   grant_id: "g1"
                 }
               ]
             }

      assert Entitlement.feature(r, "sso") == :allow
      assert Entitlement.feature(r, "audit") == {:deny, :feature_absent}
      assert Entitlement.feature(r, "SSO") == {:deny, :feature_absent}
    end

    test "a resolution in grace allows its features and marks every allowance settle-only" do
      assert {:grace, r} = at([grant()], 2_500)
      assert [%{status: :grace, grant_id: "g1"}] = r.grants
      assert Enum.map(r.allowances, & &1.settle_only) == [true, true]
      assert Entitlement.feature(r, "export") == :allow
      assert Entitlement.feature(r, "audit") == {:deny, :feature_absent}
    end

    test "a plan with no features or allowances resolves to empty lists" do
      empty = plan(%{features: [], allowances: []})
      assert {:entitled, r} = Entitlement.resolve(facts([grant()], [empty]), "acme", 1_500)
      assert {r.features, r.allowances} == {[], []}
      assert Entitlement.feature(r, "sso") == {:deny, :feature_absent}
    end

    test "the plan version the grant names is the one resolved" do
      v2 = plan(%{version: 2, features: ["audit"]})
      f = facts([grant(%{version: 2})], [plan(), v2])
      assert {:entitled, r} = Entitlement.resolve(f, "acme", 1_500)
      assert r.features == ["audit"]
      assert hd(r.grants).content_hash == v2.content_hash
    end

    test "feature/2 refuses a malformed resolution or name" do
      {:entitled, r} = at([grant()], 1_500)

      bad_resolutions = [
        nil,
        {:entitled, r},
        Map.delete(r, :features),
        Map.put(r, :extra, 1),
        %{r | grants: []},
        %{r | features: ["sso", "export"]},
        %{r | features: ["export" | "sso"]},
        %{r | tenant: ""},
        %{r | grants: [%{hd(r.grants) | status: :revoked}]},
        %{r | allowances: [%{hd(r.allowances) | settle_only: nil}]}
      ]

      for bad <- bad_resolutions, do: assert(Entitlement.feature(bad, "sso") == {:error, :invalid})

      for name <- ["", :sso, nil, String.duplicate("a", 129), "s\u0085o", <<0xFF>>],
          do: assert(Entitlement.feature(r, name) == {:error, :invalid})
    end
  end

  # ---------------------------------------------------------------- validation and order

  describe "validation" do
    test "now and tenant" do
      for now <- [-1, @max + 1, 1.5, nil, "1"],
          do: assert(Entitlement.resolve(facts([grant()]), "acme", now) == {:error, :now})

      for t <- [
            "",
            String.duplicate("a", 129),
            "a\u0085",
            "a\u0000",
            "a\u007F",
            <<0xC3>>,
            :acme,
            nil
          ],
          do: assert(Entitlement.resolve(facts([grant()]), t, 1_500) == {:error, :tenant})

      assert {:entitled, _} =
               at([grant(%{tenant: String.duplicate("a", 128)})], 1_500, String.duplicate("a", 128))
    end

    test "the facts shape" do
      for f <- [
            nil,
            %{plans: []},
            %{plans: [], grants: [], extra: []},
            %{"plans" => [], "grants" => []},
            struct(FakeFacts, plans: [], grants: []),
            %{plans: nil, grants: []},
            %{plans: [plan() | plan()], grants: []},
            %{plans: [], grants: [grant() | :x]}
          ],
          do: refused(f, :facts)
    end

    test "plan shape and bounds" do
      bad_plan(%{content_hash: nil})
      bad_plan(%{content_hash: :binary.copy(<<0>>, 31)})
      bad_plan(%{version: 0})
      bad_plan(%{version: 2_147_483_648})
      bad_plan(%{plan_id: String.duplicate("p", 129)})
      bad_plan(%{plan_id: "p\u0085"})
      bad_plan(%{features: ["sso", "export"]})
      bad_plan(%{features: ["sso", "sso"]})
      bad_plan(%{features: ["f\u009F"]})
      bad_plan(%{features: Enum.map(1..257, &String.pad_leading("#{&1}", 4, "0"))})
      refused(facts([grant()], [Map.delete(plan(), :features)]), :plans)
      refused(facts([grant()], [Map.put(plan(), :tier, :pro)]), :plans)
      refused(facts([grant()], [plan(), plan()]), :plans)
      refused(facts([], for(v <- 1..1025, do: plan(%{version: v}))), :plans)
    end

    test "plan bounds at their largest accepted value" do
      features = Enum.map(1..256, &String.pad_leading("#{&1}", 4, "0"))

      units =
        Elzoo.AiModel.Usage.units() ++
          Enum.map(Elzoo.AiModel.Usage.ttls(), &{:cache_write_tokens, &1})

      allowances =
        Enum.map(units, &%{unit: &1, amount: @max, period_kind: :utc_month})
        |> Enum.sort_by(& &1.unit)

      p =
        plan(%{
          features: features,
          allowances: allowances,
          version: 2_147_483_647,
          plan_id: String.duplicate("p", 128)
        })

      g = grant(%{plan_id: p.plan_id, version: p.version})
      assert {:entitled, r} = Entitlement.resolve(facts([g], [p]), "acme", 1_500)
      assert length(r.features) == 256 and length(r.allowances) == length(units)
    end

    test "allowances" do
      a = fn unit, amount -> %{unit: unit, amount: amount, period_kind: :utc_month} end
      ok = a.(:output_tokens, 1)
      bad_plan(%{allowances: [a.(:output_tokens, 0)]})
      bad_plan(%{allowances: [a.(:output_tokens, @max + 1)]})
      bad_plan(%{allowances: [a.(:output_tokens, 1.0)]})
      bad_plan(%{allowances: [a.(:runs, 1)]})
      bad_plan(%{allowances: [a.(:cache_write_tokens, 1)]})
      bad_plan(%{allowances: [a.({:cache_write_tokens, "2h"}, 1)]})
      bad_plan(%{allowances: [a.({:cache_write_tokens, :"5m"}, 1)]})
      bad_plan(%{allowances: [%{ok | period_kind: :month}]})
      bad_plan(%{allowances: [%{ok | period_kind: "utc_month"}]})
      bad_plan(%{allowances: [Map.put(ok, :rollover, true)]})
      bad_plan(%{allowances: [ok, ok]})
      bad_plan(%{allowances: [a.(:output_tokens, 1), a.(:output_tokens, 2)]})
      bad_plan(%{allowances: [a.({:cache_write_tokens, "5m"}, 1), a.(:output_tokens, 1)]})
      bad_plan(%{allowances: [a.(:output_tokens, 1), a.(:cache_read_tokens, 1)]})

      # The v1 unit set has 15 distinct {unit, period_kind} pairs, so the
      # 64-entry bound is not reachable without a duplicate.
      bad_plan(%{allowances: List.duplicate(ok, 65)})
      bad_plan(%{allowances: [ok | ok]})

      for amount <- [1, @max] do
        p = plan(%{allowances: [a.(:output_tokens, amount)]})

        assert {:entitled, %{allowances: [%{amount: ^amount}]}} =
                 Entitlement.resolve(facts([grant()], [p]), "acme", 1_500)
      end
    end

    test "grant shape and bounds" do
      bad_grant(%{grant_id: ""})
      bad_grant(%{grant_id: String.duplicate("g", 129)})
      bad_grant(%{tenant: "a\u0085"})
      bad_grant(%{plan_id: :team})
      bad_grant(%{version: 0})
      bad_grant(%{version: 2_147_483_648})
      bad_grant(%{tenant: String.duplicate("t", 129)})
      bad_grant(%{plan_id: String.duplicate("p", 129)})
      bad_grant(%{valid_from_ms: @max + 1, valid_to_ms: nil, grace_until_ms: nil})
      bad_grant(%{grace_until_ms: @max + 1})
      bad_grant(%{revoked_at_ms: @max + 1})
      bad_grant(%{valid_from_ms: -1})
      bad_grant(%{valid_from_ms: nil})
      bad_grant(%{valid_to_ms: 1_000})
      bad_grant(%{valid_to_ms: 999})
      bad_grant(%{valid_to_ms: @max + 1})
      bad_grant(%{grace_until_ms: 2_000})
      bad_grant(%{valid_to_ms: nil, grace_until_ms: 3_000})
      bad_grant(%{revoked_at_ms: -1})
      bad_grant(%{revoked_at_ms: 1.0})
      refused(facts([Map.delete(grant(), :revoked_at_ms)]), :grants)
      refused(facts([Map.put(grant(), :seats, 3)]), :grants)
      refused(facts([grant(), grant(%{tenant: "globex"})]), :grants)
      refused(facts(for(n <- 1..1025, do: grant(%{grant_id: "g#{n}", tenant: "t#{n}"}))), :grants)
      # A malformed grant of another tenant is still refused.
      refused(
        facts([grant(), grant(%{grant_id: "o", tenant: "globex", valid_from_ms: -1})]),
        :grants
      )

      # Revoked at time zero is accepted.
      assert at([grant(%{revoked_at_ms: 0})], 1_500) == {:not_entitled, :revoked}
    end

    test "1024 plans and 1024 grants are accepted" do
      plans = for v <- 1..1024, do: plan(%{version: v})
      grants = for n <- 1..1024, do: grant(%{grant_id: "g#{n}", tenant: "t#{n}", version: n})
      f = facts(grants, plans)
      assert {:entitled, %{grants: [%{version: 7}]}} = Entitlement.resolve(f, "t7", 1_500)
    end

    test "the fixed error order" do
      bad_plan = Map.put(plan(), :version, 0)
      bad_grant = grant(%{valid_from_ms: -1})
      bad_hash = %{plan() | content_hash: :binary.copy(<<1>>, 32)}

      assert Entitlement.resolve(facts([bad_grant], [bad_plan]), :x, -1) == {:error, :now}
      assert Entitlement.resolve(facts([bad_grant], [bad_plan]), :x, 1_500) == {:error, :tenant}
      assert Entitlement.resolve(%{plans: bad_plan}, "acme", 1_500) == {:error, :facts}
      assert Entitlement.resolve(facts([bad_grant], [bad_plan]), "acme", 1_500) == {:error, :plans}
      assert Entitlement.resolve(facts([bad_grant], [bad_hash]), "acme", 1_500) == {:error, :grants}

      assert Entitlement.resolve(facts([grant(%{version: 2})], [bad_hash]), "acme", 1_500) ==
               {:error, :content_hash}

      overlap = [grant(%{version: 2}), grant(%{grant_id: "g2"}), grant(%{grant_id: "g3"})]
      assert Entitlement.resolve(facts(overlap), "acme", 1_500) == {:error, :unknown_plan}
    end

    test "error atoms carry no ID and nothing raises" do
      id = "secret-id"
      p = plan(%{plan_id: id})
      g = grant(%{grant_id: id, tenant: id, plan_id: id})

      inputs = [
        {facts([g], [%{p | content_hash: :binary.copy(<<0>>, 32)}]), id},
        {facts([%{g | version: 9}], [p]), id},
        {facts([g, %{g | grant_id: id <> "2"}], [p]), id},
        {facts([%{g | valid_from_ms: -1}], [p]), id},
        {facts([g], [%{p | version: 0}]), id},
        {%{plans: [p]}, id},
        {facts([g], [p]), id <> <<0>>}
      ]

      for {f, t} <- inputs do
        assert {:error, reason} = Entitlement.resolve(f, t, 1_500)
        assert reason in @errors
        refute inspect(reason) =~ "secret"
      end

      junk = [nil, 1, "x", [nil], %{}, {:a}, [%{}], %{plan_id: nil}, [plan() | nil]]

      for a <- junk, b <- junk do
        assert {:error, r} = Entitlement.resolve(%{plans: a, grants: b}, "acme", 0)
        assert r in @errors
        assert {:error, :invalid} = Entitlement.feature(a, b)
        assert {:error, :plans} = Entitlement.content_hash(a)
      end
    end
  end

  # ---------------------------------------------------------------- Cure

  describe "cure" do
    test "the status order over every flag combination" do
      cure = :"Cure.Elzoo.Entitlement"

      for r <- [true, false], e <- [true, false], g <- [true, false], a <- [true, false] do
        expected =
          cond do
            r -> :StatusRevoked
            e -> :StatusExpired
            g -> :StatusGrace
            a -> :StatusActive
            true -> :StatusNotYet
          end

        assert cure.status(r, e, g, a) == expected
      end
    end

    test "selected Cure laws, a clean audit and the checked example" do
      source = File.read!(Path.expand("../../cure/elzoo/entitlement.cure", __DIR__))
      roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
      assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
      audit = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(audit, key) == [])

      {result, _} = Code.eval_file(Path.expand("../../examples/entitlement.exs", __DIR__))

      assert result == [
               {["export", "sso"], [false, false]},
               {:allow, [true, true]},
               {:deny, :feature_absent},
               {:not_entitled, :expired},
               {:not_entitled, :revoked}
             ]
    end
  end
end
