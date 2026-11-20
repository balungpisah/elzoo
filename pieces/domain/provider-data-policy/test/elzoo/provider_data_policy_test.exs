# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderDataPolicyTest do
  use ExUnit.Case, async: true
  alias Elzoo.ProviderDataPolicy, as: Policy

  defmodule Holder, do: defstruct([:providers])

  defp admit(class, regions, retention), do: %{class: class, regions: regions, retention: retention}

  # p1 admits :pii in eu under zero, :public in eu/us under zero/30d.
  @policy %{
    providers: [
      %{
        provider: "p1",
        classes: [
          %{class: :pii, regions: ["eu"], retention: ["zero"]},
          %{class: :public, regions: ["eu", "us"], retention: ["zero", "30d"]}
        ]
      }
    ]
  }

  defp req(provider, region, retention, classes),
    do: %{provider: provider, region: region, retention: retention, classes: classes}

  defp valid_req, do: req("p1", "eu", "zero", [:pii])
  defp with_classes(classes), do: %{providers: [%{provider: "p1", classes: classes}]}
  defp texts(n), do: for(i <- 1..n, do: "t#{i}")

  describe "data_classes" do
    test "returns exactly the five tags in order" do
      assert Policy.data_classes() == [:public, :internal, :confidential, :pii, :secret]
    end
  end

  describe "admission" do
    test "admitted provider, region, retention and classes allow" do
      assert Policy.decide(@policy, req("p1", "eu", "zero", [:pii, :public])) == :allow
      assert Policy.decide(@policy, req("p1", "us", "30d", [:public])) == :allow
    end

    test "each failing dimension denies with its reason" do
      assert Policy.decide(@policy, req("p1", "us", "zero", [:pii, :public])) == {:deny, :region}
      assert Policy.decide(@policy, req("p1", "eu", "30d", [:pii])) == {:deny, :retention}
      assert Policy.decide(@policy, req("p1", "eu", "zero", [:internal])) == {:deny, :class}
      assert Policy.decide(@policy, req("p1", "eu", "zero", [:pii, :internal])) == {:deny, :class}
      assert Policy.decide(@policy, req("p2", "eu", "zero", [:public])) == {:deny, :provider}
    end
  end

  describe "order" do
    test "secret is refused before the provider lookup" do
      assert Policy.decide(@policy, req("p9", "eu", "zero", [:secret])) == {:deny, :secret}
      assert Policy.decide(@policy, req("p1", "eu", "zero", [:public, :secret])) == {:deny, :secret}
    end

    test "unknown provider is refused before the class check" do
      assert Policy.decide(@policy, req("p9", "eu", "zero", [:internal])) == {:deny, :provider}
    end

    test "classes are checked in the fixed order pii first, whatever the input order" do
      policy = with_classes([admit(:pii, ["eu"], ["zero"])])
      assert Policy.decide(policy, req("p1", "us", "zero", [:public, :pii])) == {:deny, :region}
    end

    test "each adjacent pair of the fixed order: the earlier class's failure wins" do
      # pii before confidential: pii fails on region, confidential is absent.
      policy = with_classes([admit(:pii, ["us"], ["zero"])])

      assert Policy.decide(policy, req("p1", "eu", "zero", [:confidential, :pii])) ==
               {:deny, :region}

      # confidential before internal: confidential fails on retention, internal on region.
      policy =
        with_classes([admit(:confidential, ["eu"], ["30d"]), admit(:internal, ["us"], ["zero"])])

      assert Policy.decide(policy, req("p1", "eu", "zero", [:internal, :confidential])) ==
               {:deny, :retention}

      # internal before public: internal fails on region, public is absent.
      policy = with_classes([admit(:internal, ["us"], ["zero"])])

      assert Policy.decide(policy, req("p1", "eu", "zero", [:public, :internal])) ==
               {:deny, :region}
    end

    test "region before retention within a class, and class by class across classes" do
      assert Policy.decide(@policy, req("p1", "us", "30d", [:pii])) == {:deny, :region}

      # pii passes region and fails retention; public fails region. pii comes first.
      policy = with_classes([admit(:pii, ["eu"], ["zero"]), admit(:public, ["us"], ["30d"])])
      assert Policy.decide(policy, req("p1", "eu", "30d", [:public, :pii])) == {:deny, :retention}
    end

    test "a malformed policy wins over a malformed request" do
      assert Policy.decide(%{providers: :x}, %{provider: "p1"}) == {:error, :policy}
      assert Policy.decide(nil, nil) == {:error, :policy}
    end
  end

  describe "policy shape" do
    test "an empty policy denies by provider" do
      assert Policy.decide(%{providers: []}, valid_req()) == {:deny, :provider}
    end

    test "malformed policies are errors" do
      bad = [
        with_classes([admit(:secret, ["eu"], ["zero"])]),
        with_classes([admit(:restricted, ["eu"], ["zero"])]),
        with_classes([admit("pii", ["eu"], ["zero"])]),
        %{
          providers: [
            %{provider: "p1", classes: [admit(:pii, ["eu"], ["zero"])]},
            %{provider: "p1", classes: [admit(:public, ["eu"], ["zero"])]}
          ]
        },
        with_classes([admit(:pii, ["eu"], ["zero"]), admit(:pii, ["us"], ["zero"])]),
        %{
          providers:
            for(i <- 1..257, do: %{provider: "p#{i}", classes: [admit(:pii, ["eu"], ["zero"])]})
        },
        with_classes([admit(:pii, texts(65), ["zero"])]),
        with_classes([admit(:pii, ["eu"], texts(17))]),
        with_classes([admit(:pii, [], ["zero"])]),
        with_classes([admit(:pii, ["eu"], [])]),
        with_classes([]),
        with_classes(
          Enum.map([:pii, :public, :internal, :confidential, :pii], &admit(&1, ["eu"], ["zero"]))
        ),
        %{providers: [%{provider: "p1", classes: [admit(:pii, ["eu"], ["zero"])]}], extra: 1},
        %{"providers" => []},
        %{providers: [%{"provider" => "p1", classes: [admit(:pii, ["eu"], ["zero"])]}]},
        %{providers: [%{provider: "p1", classes: [Map.put(admit(:pii, ["eu"], ["zero"]), :x, 1)]}]},
        %{providers: [%{provider: "p1", classes: [admit(:pii, ["eu" | "us"], ["zero"])]}]},
        %{providers: [%{provider: "p1", classes: :pii}]},
        %{providers: [:p1]},
        %{providers: [nil]},
        %Holder{providers: []}
      ]

      for policy <- bad,
          do: assert(Policy.decide(policy, valid_req()) == {:error, :policy}, inspect(policy))
    end

    test "bounds at the limit pass" do
      many =
        for i <- 1..256,
            do: %{provider: "p#{i}", classes: [admit(:pii, texts(64), texts(16))]}

      assert Policy.decide(%{providers: many}, req("p256", "t64", "t16", [:pii])) == :allow

      four =
        with_classes(
          Enum.map([:pii, :public, :internal, :confidential], &admit(&1, ["eu"], ["zero"]))
        )

      assert Policy.decide(four, req("p1", "eu", "zero", [:public, :internal, :confidential, :pii])) ==
               :allow
    end
  end

  describe "request shape" do
    test "malformed requests are errors" do
      bad = [
        req("p1", "eu", "zero", []),
        req("p1", "eu", "zero", [:pii, :public, :pii, :public, :pii, :public]),
        req("p1", "eu", "zero", [:restricted]),
        req("p1", "eu", "zero", ["pii"]),
        req("p1", "eu", "zero", :pii),
        req("p1", "eu", "zero", [:pii | :public]),
        Map.put(valid_req(), :tenant, "t"),
        Map.delete(valid_req(), :retention),
        %{"provider" => "p1", region: "eu", retention: "zero", classes: [:pii]},
        :request
      ]

      for request <- bad,
          do: assert(Policy.decide(@policy, request) == {:error, :request}, inspect(request))
    end

    test "five entries with duplicates pass and coalesce" do
      assert Policy.decide(@policy, req("p1", "eu", "zero", [:pii, :public, :pii, :public, :pii])) ==
               :allow
    end
  end

  describe "text bounds on both sides" do
    @bad_texts [
      {"empty", ""},
      {"65 bytes", String.duplicate("a", 65)},
      {"invalid UTF-8", <<0xFF>>},
      {"NUL", "p\0"},
      {"DEL", "p\x7F"},
      {"U+0085", "p\u0085"},
      {"not a binary", :p1}
    ]

    test "1 and 64 bytes pass on both sides" do
      for t <- ["a", String.duplicate("é", 32)] do
        assert byte_size(t) in [1, 64]
        policy = %{providers: [%{provider: t, classes: [admit(:pii, [t], [t])]}]}
        assert Policy.decide(policy, req(t, t, t, [:pii])) == :allow
      end
    end

    test "bad texts are a policy error in each policy text field" do
      for {name, t} <- @bad_texts do
        for policy <- [
              %{providers: [%{provider: t, classes: [admit(:pii, ["eu"], ["zero"])]}]},
              with_classes([admit(:pii, [t], ["zero"])]),
              with_classes([admit(:pii, ["eu"], [t])])
            ] do
          assert Policy.decide(policy, valid_req()) == {:error, :policy}, name
        end
      end
    end

    test "bad texts are a request error in each request text field" do
      for {name, t} <- @bad_texts do
        for request <- [
              req(t, "eu", "zero", [:pii]),
              req("p1", t, "zero", [:pii]),
              req("p1", "eu", t, [:pii])
            ] do
          assert Policy.decide(@policy, request) == {:error, :request}, name
        end
      end
    end
  end

  describe "exact bytes" do
    test "case and trailing space differ" do
      assert Policy.decide(@policy, req("p1", "EU", "zero", [:pii])) == {:deny, :region}
      assert Policy.decide(@policy, req("p1 ", "eu", "zero", [:pii])) == {:deny, :provider}
      assert Policy.decide(@policy, req("p1", "eu", "Zero", [:pii])) == {:deny, :retention}
    end
  end

  test "results never echo supplied values" do
    results =
      for policy <- [@policy, %{providers: "secret-value"}],
          request <- [req("secret-value", "eu", "zero", [:pii]), %{provider: "secret-value"}],
          do: Policy.decide(policy, request)

    refute inspect(results) =~ "secret-value"
  end
end
