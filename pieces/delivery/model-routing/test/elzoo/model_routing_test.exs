# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ModelRoutingTest do
  use ExUnit.Case, async: true
  alias Elzoo.ModelRouting, as: Routing

  @now 1_700_000_000_000
  @max_u32 4_294_967_295

  # p1 admits :internal and :pii in eu under zero; p2 admits :internal in us under zero.
  @policy %{
    providers: [
      %{
        provider: "p1",
        classes: [
          %{class: :internal, regions: ["eu"], retention: ["zero"]},
          %{class: :pii, regions: ["eu"], retention: ["zero"]}
        ]
      },
      %{provider: "p2", classes: [%{class: :internal, regions: ["us"], retention: ["zero"]}]}
    ]
  }

  @retry [
    max_attempts: 3,
    base_backoff_ms: 100,
    max_backoff_ms: 1_000,
    jitter: :none,
    max_failure_delay_ms: 10_000
  ]

  defp cand(ref, rank, fields \\ %{}) do
    Map.merge(
      %{
        ref: ref,
        provider: "p1",
        region: "eu",
        retention: "zero",
        model_id: "model-#{ref}",
        features: [],
        rank: rank
      },
      fields
    )
  end

  defp route(candidates, fields \\ %{}) do
    Map.merge(
      %{
        id: "chat",
        version: 1,
        candidates: candidates,
        on_unknown: :stop,
        max_health_age_ms: 60_000,
        cool_down_ms: 5_000,
        retry: @retry
      },
      fields
    )
  end

  defp refs(route), do: Enum.map(route.candidates, & &1.ref)

  defp request(route, fields \\ %{}) do
    Map.merge(
      %{
        features: [],
        classes: [:internal],
        data_policy: @policy,
        costs: Map.new(refs(route), &{&1, 1}),
        tried: []
      },
      fields
    )
  end

  defp fresh, do: %{circuit: :closed, observed_at_ms: @now, not_before_ms: nil}

  defp health(route, entries \\ %{}, fields \\ %{}) do
    Map.merge(
      %{
        now_ms: @now,
        budget_remaining: 100,
        candidates: Map.merge(Map.new(refs(route), &{&1, fresh()}), entries)
      },
      fields
    )
  end

  defp entry(fields), do: Map.merge(fresh(), fields)

  defp attempt(ref, outcome, n \\ 1), do: %{ref: ref, same_ref_attempts: n, outcome: outcome}
  defp facts(random \\ 0), do: %{now_ms: @now, random: random}

  defp two, do: route([cand("a", 1), cand("b", 2)])

  describe "new/1 (case 1)" do
    test "16 candidates are accepted and 17 refused" do
      sixteen = route(for i <- 1..16, do: cand("c#{i}", i))
      assert Routing.new(sixteen) == {:ok, sixteen}
      seventeen = route(for i <- 1..17, do: cand("c#{i}", i))
      assert Routing.new(seventeen) == {:error, :invalid_route}
      assert Routing.new(route([])) == {:error, :invalid_route}
    end

    test "duplicate ref, duplicate rank and an unknown feature are refused" do
      assert Routing.new(route([cand("a", 1), cand("a", 2)])) == {:error, :invalid_route}
      assert Routing.new(route([cand("a", 1), cand("b", 1)])) == {:error, :invalid_route}

      assert Routing.new(route([cand("a", 1, %{features: [:telepathy]})])) ==
               {:error, :invalid_route}

      assert Routing.new(route([cand("a", 1, %{features: [:tools, :tools]})])) ==
               {:error, :invalid_route}

      all = Elzoo.AiText.Provider.features()
      assert {:ok, _} = Routing.new(route([cand("a", 1, %{features: all})]))
    end

    test "rank, max_health_age_ms and cool_down_ms at their bounds" do
      assert {:ok, _} = Routing.new(route([cand("a", 1), cand("b", 1_000)]))
      assert Routing.new(route([cand("a", 0)])) == {:error, :invalid_route}
      assert Routing.new(route([cand("a", 1_001)])) == {:error, :invalid_route}

      for ok <- [1, 3_600_000],
          do: assert({:ok, _} = Routing.new(route([cand("a", 1)], %{max_health_age_ms: ok})))

      for bad <- [0, 3_600_001],
          do:
            assert(
              Routing.new(route([cand("a", 1)], %{max_health_age_ms: bad})) ==
                {:error, :invalid_route}
            )

      for ok <- [1, 86_400_000],
          do: assert({:ok, _} = Routing.new(route([cand("a", 1)], %{cool_down_ms: ok})))

      for bad <- [0, 86_400_001],
          do:
            assert(
              Routing.new(route([cand("a", 1)], %{cool_down_ms: bad})) == {:error, :invalid_route}
            )
    end

    test "on_unknown :fallback and a retry with mode are refused" do
      assert Routing.new(route([cand("a", 1)], %{on_unknown: :fallback})) ==
               {:error, :invalid_route}

      for mode <- [:redispatch_forbidden, :redispatch_idempotent] do
        assert Routing.new(route([cand("a", 1)], %{retry: [{:mode, mode} | @retry]})) ==
                 {:error, :invalid_route}
      end
    end

    test "retry keys, max_attempts bound and a policy that policy/1 refuses" do
      assert {:ok, _} = Routing.new(route([cand("a", 1)], %{retry: []}))
      assert {:ok, _} = Routing.new(route([cand("a", 1)], %{retry: [max_attempts: 256]}))

      for bad <- [
            [max_attempts: 257],
            [timeout_ms: 5],
            [max_attempts: 2, max_attempts: 3],
            [base_backoff_ms: 500, max_backoff_ms: 100],
            [max_attempts: 0],
            [jitter: :some],
            %{max_attempts: 3},
            [:max_attempts]
          ] do
        assert Routing.new(route([cand("a", 1)], %{retry: bad})) == {:error, :invalid_route}
      end
    end

    test "route and candidate shapes and texts" do
      long = String.duplicate("x", 65)

      for bad <- [
            Map.put(route([cand("a", 1)]), :extra, 1),
            Map.delete(route([cand("a", 1)]), :retry),
            route([cand("a", 1)], %{id: ""}),
            route([cand("a", 1)], %{id: String.duplicate("i", 129)}),
            route([cand("a", 1)], %{id: "a\nb"}),
            route([cand("a", 1)], %{version: 0}),
            route([cand("a", 1)], %{version: 2_147_483_648}),
            route([cand("A", 1)]),
            route([cand(String.duplicate("r", 65), 1)]),
            route([cand("a", 1, %{provider: long})]),
            route([cand("a", 1, %{region: "e\u0085u"})]),
            route([cand("a", 1, %{retention: ""})]),
            route([cand("a", 1, %{model_id: String.duplicate("m", 257)})]),
            route([cand("a", 1, %{model_id: <<255>>})]),
            route([Map.put(cand("a", 1), :weight, 1)]),
            route([cand("a", 1) | :tail]),
            :route
          ] do
        assert Routing.new(bad) == {:error, :invalid_route}
      end

      assert {:ok, _} =
               Routing.new(
                 route(
                   [cand(String.duplicate("r", 64), 1, %{model_id: String.duplicate("m", 256)})],
                   %{id: String.duplicate("i", 128), version: 2_147_483_647}
                 )
               )
    end
  end

  describe "select/3 capability (case 2)" do
    setup do
      r =
        route([
          cand("a", 1, %{features: [:tools, :structured_output]}),
          cand("b", 2, %{features: [:tools]}),
          cand("c", 3, %{features: [:image_input, :tools, :structured_output]})
        ])

      %{r: r}
    end

    test "tools and structured_output", %{r: r} do
      req = request(r, %{features: [:structured_output, :tools]})

      assert Routing.select(r, req, health(r)) ==
               {:ok, %{eligible: ["a", "c"], excluded: [{"b", :capability}]}}
    end

    test "image_input", %{r: r} do
      req = request(r, %{features: [:image_input]})

      assert Routing.select(r, req, health(r)) ==
               {:ok, %{eligible: ["c"], excluded: [{"a", :capability}, {"b", :capability}]}}
    end

    test "no needed feature takes every candidate", %{r: r} do
      assert {:ok, %{eligible: ["a", "b", "c"], excluded: []}} =
               Routing.select(r, request(r), health(r))
    end
  end

  describe "select/3 health at its edge (case 3)" do
    test "a fact exactly max_health_age_ms old is fresh, 1 ms older is stale" do
      r = two()
      h = health(r, %{"a" => entry(%{observed_at_ms: @now - 60_000})})
      assert {:ok, %{eligible: ["a", "b"]}} = Routing.select(r, request(r), h)

      h = health(r, %{"a" => entry(%{observed_at_ms: @now - 60_001})})

      assert Routing.select(r, request(r), h) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :stale_health}]}}
    end

    test "a missing entry is stale" do
      r = two()
      h = health(r) |> update_in([:candidates], &Map.delete(&1, "a"))

      assert Routing.select(r, request(r), h) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :stale_health}]}}
    end

    test "open and unavailable are circuit_open, half_open is eligible" do
      r = route([cand("a", 1), cand("b", 2), cand("c", 3)])

      h =
        health(r, %{
          "a" => entry(%{circuit: :open}),
          "b" => entry(%{circuit: :unavailable}),
          "c" => entry(%{circuit: :half_open})
        })

      assert Routing.select(r, request(r), h) ==
               {:ok, %{eligible: ["c"], excluded: [{"a", :circuit_open}, {"b", :circuit_open}]}}
    end

    test "not_before_ms equal to now_ms is eligible, 1 ms later is cooling_down" do
      r = two()
      h = health(r, %{"a" => entry(%{not_before_ms: @now})})
      assert {:ok, %{eligible: ["a", "b"]}} = Routing.select(r, request(r), h)

      h = health(r, %{"a" => entry(%{not_before_ms: @now + 1})})

      assert Routing.select(r, request(r), h) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :cooling_down}]}}
    end
  end

  describe "select/3 data policy (case 4)" do
    test "unapproved provider and region" do
      r =
        route([
          cand("a", 1, %{provider: "p9"}),
          cand("b", 2, %{region: "us"}),
          cand("c", 3, %{provider: "p2", region: "us"})
        ])

      assert Routing.select(r, request(r), health(r)) ==
               {:ok,
                %{
                  eligible: ["c"],
                  excluded: [{"a", {:data_policy, :provider}}, {"b", {:data_policy, :region}}]
                }}

      # p2 does not admit :pii at all.
      assert Routing.select(r, request(r, %{classes: [:pii]}), health(r)) ==
               {:error,
                {:no_candidate,
                 [
                   {"a", {:data_policy, :provider}},
                   {"b", {:data_policy, :region}},
                   {"c", {:data_policy, :class}}
                 ]}}
    end

    test "secret data is refused for every candidate" do
      r = two()

      assert Routing.select(r, request(r, %{classes: [:internal, :secret]}), health(r)) ==
               {:error,
                {:no_candidate, [{"a", {:data_policy, :secret}}, {"b", {:data_policy, :secret}}]}}
    end
  end

  describe "select/3 budget (case 5)" do
    test "a cost equal to budget_remaining is eligible, one more is budget" do
      r = two()
      req = request(r, %{costs: %{"a" => 100, "b" => 101}})

      assert Routing.select(r, req, health(r)) ==
               {:ok, %{eligible: ["a"], excluded: [{"b", :budget}]}}

      assert Routing.select(
               r,
               request(r, %{costs: %{"a" => 0, "b" => 1}}),
               health(r, %{}, %{budget_remaining: 0})
             ) ==
               {:ok, %{eligible: ["a"], excluded: [{"b", :budget}]}}
    end
  end

  describe "select/3 order (case 6)" do
    test "eligible and excluded refs come in ascending rank" do
      r =
        route([
          cand("z", 1_000),
          cand("m", 500, %{features: [:tools]}),
          cand("a", 1),
          cand("y", 999, %{features: [:tools]}),
          cand("x", 2)
        ])

      req = request(r, %{features: [:tools], tried: []})

      assert Routing.select(r, request(r), health(r)) ==
               {:ok, %{eligible: ["a", "x", "m", "y", "z"], excluded: []}}

      assert Routing.select(r, req, health(r)) ==
               {:ok,
                %{
                  eligible: ["m", "y"],
                  excluded: [{"a", :capability}, {"x", :capability}, {"z", :capability}]
                }}
    end

    test "a candidate both tried and stale is tried" do
      r = two()
      h = health(r, %{"a" => entry(%{observed_at_ms: @now - 60_001})})

      assert Routing.select(r, request(r, %{tried: ["a"]}), h) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :tried}]}}
    end

    test "the first reason that applies, peeled one at a time" do
      # "a" fails every check; each step lifts the reason that was given.
      r = route([cand("a", 1, %{provider: "p9"}), cand("b", 2, %{features: [:tools]})])
      bad = entry(%{observed_at_ms: @now - 60_001, circuit: :open, not_before_ms: @now + 1})
      req = %{features: [:tools], costs: %{"a" => 101, "b" => 1}, tried: ["a"]}
      excluded = fn req, h -> Routing.select(r, request(r, req), health(r, %{"a" => h})) end

      assert {:ok, %{excluded: [{"a", :tried}]}} = excluded.(req, bad)
      req = %{req | tried: []}
      assert {:ok, %{excluded: [{"a", :capability}]}} = excluded.(req, bad)
      req = %{req | features: []}
      assert {:ok, %{excluded: [{"a", {:data_policy, :provider}}]}} = excluded.(req, bad)

      r = route([cand("a", 1), cand("b", 2, %{features: [:tools]})])
      excluded = fn req, h -> Routing.select(r, request(r, req), health(r, %{"a" => h})) end
      assert {:ok, %{excluded: [{"a", :stale_health}]}} = excluded.(req, bad)
      bad = %{bad | observed_at_ms: @now}
      assert {:ok, %{excluded: [{"a", :circuit_open}]}} = excluded.(req, bad)
      bad = %{bad | circuit: :half_open}
      assert {:ok, %{excluded: [{"a", :cooling_down}]}} = excluded.(req, bad)
      bad = %{bad | not_before_ms: nil}
      assert {:ok, %{excluded: [{"a", :budget}]}} = excluded.(req, bad)
      req = %{req | costs: %{"a" => 100, "b" => 1}}
      assert {:ok, %{eligible: ["a", "b"], excluded: []}} = excluded.(req, bad)
    end
  end

  describe "after_failure/3 moves on with a cool-down (case 7)" do
    test "throttled with retry_after 30 cools down 30,000 ms and the next select skips it" do
      r = two()
      out = {:refused, :throttled, %{retry_after: 30}}
      cool = %{ref: "a", not_before_ms: @now + 30_000}
      assert Routing.after_failure(r, attempt("a", out), facts()) == {:ok, {:next, cool}}

      h = health(r, %{"a" => entry(%{not_before_ms: cool.not_before_ms})})

      assert Routing.select(r, request(r, %{tried: ["a"]}), h) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :tried}]}}

      # A later call that has not tried it still honours the cool-down.
      assert Routing.select(r, request(r), h) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :cooling_down}]}}
    end

    test "overloaded with retry_after nil uses cool_down_ms, retry_after 0 none" do
      r = two()

      assert Routing.after_failure(
               r,
               attempt("b", {:refused, :overloaded, %{retry_after: nil}}),
               facts()
             ) ==
               {:ok, {:next, %{ref: "b", not_before_ms: @now + 5_000}}}

      assert Routing.after_failure(
               r,
               attempt("b", {:refused, :throttled, %{retry_after: nil}}),
               facts()
             ) ==
               {:ok, {:next, %{ref: "b", not_before_ms: @now + 5_000}}}

      assert Routing.after_failure(
               r,
               attempt("b", {:refused, :overloaded, %{retry_after: 0}}),
               facts()
             ) ==
               {:ok, {:next, %{ref: "b", not_before_ms: @now}}}

      assert Routing.after_failure(
               r,
               attempt("b", {:refused, :throttled, %{retry_after: 86_400}}),
               facts()
             ) ==
               {:ok, {:next, %{ref: "b", not_before_ms: @now + 86_400_000}}}
    end

    test "authentication_failed moves on with no cool-down and the next select leaves it out as tried" do
      r = two()

      assert Routing.after_failure(
               r,
               attempt("a", {:refused, :authentication_failed, %{retry_after: nil}}),
               facts()
             ) ==
               {:ok, {:next, nil}}

      assert Routing.select(r, request(r, %{tried: ["a"]}), health(r)) ==
               {:ok, %{eligible: ["b"], excluded: [{"a", :tried}]}}

      assert Routing.select(r, request(r, %{tried: ["a", "b"]}), health(r)) ==
               {:error, {:no_candidate, [{"a", :tried}, {"b", :tried}]}}
    end

    test "permission_denied and not_found move on; a retry_after on them is ignored" do
      r = two()

      for reason <- [:permission_denied, :not_found] do
        assert Routing.after_failure(
                 r,
                 attempt("a", {:refused, reason, %{retry_after: 9}}),
                 facts()
               ) ==
                 {:ok, {:next, nil}}
      end
    end
  end

  describe "after_failure/3 retries the same candidate when nothing was sent (case 8)" do
    test "a rate refusal waits max(wait, backoff), the wait cut at max_failure_delay_ms" do
      r = two()

      # backoff of attempt 1 is base_backoff_ms (100), of attempt 2 is 200.
      assert Routing.after_failure(r, attempt("a", {:rate_limited, 2_500}), facts()) ==
               {:ok, {:retry_same, 2_500}}

      r1k = route(r.candidates, %{retry: Keyword.put(@retry, :max_failure_delay_ms, 1_000)})

      assert Routing.after_failure(r1k, attempt("a", {:rate_limited, 2_500}), facts()) ==
               {:ok, {:retry_same, 1_000}}

      big =
        route(r.candidates, %{retry: [base_backoff_ms: 4_000, max_backoff_ms: 8_000, jitter: :none]})

      assert Routing.after_failure(big, attempt("a", {:rate_limited, 2_500}), facts()) ==
               {:ok, {:retry_same, 4_000}}
    end

    test "a rate refusal with no wait is the backoff alone" do
      r = two()

      assert Routing.after_failure(r, attempt("a", {:rate_limited, nil}), facts()) ==
               {:ok, {:retry_same, 100}}

      assert Routing.after_failure(r, attempt("a", {:rate_limited, nil}, 2), facts()) ==
               {:ok, {:retry_same, 200}}
    end

    test "the caller's random draw drives full jitter" do
      r = route(two().candidates, %{retry: Keyword.put(@retry, :jitter, :full)})

      # spread(random, b) = random * (b + 1) div 2^32, with b = 100.
      assert Routing.after_failure(r, attempt("a", {:rate_limited, nil}), facts(0)) ==
               {:ok, {:retry_same, 0}}

      assert Routing.after_failure(r, attempt("a", {:rate_limited, nil}), facts(@max_u32)) ==
               {:ok, {:retry_same, 100}}

      # With a wait: max(min(wait, max_failure_delay_ms), b) + spread.
      assert Routing.after_failure(r, attempt("a", {:rate_limited, 2_500}), facts(0)) ==
               {:ok, {:retry_same, 2_500}}

      assert Routing.after_failure(r, attempt("a", {:rate_limited, 2_500}), facts(@max_u32)) ==
               {:ok, {:retry_same, 2_600}}

      assert Routing.after_failure(r, attempt("a", {:rate_limited, 20_000}), facts(@max_u32)) ==
               {:ok, {:retry_same, 10_100}}
    end

    test "a not-sent refusal retries until max_attempts, then stops" do
      r = two()

      for out <- [
            {:refused, :credentials_unavailable, %{retry_after: nil}},
            {:refused, :input_unavailable, %{retry_after: 5}},
            {:not_admitted, :input_unavailable},
            {:rate_limited, 2_500}
          ] do
        assert {:ok, {:retry_same, _}} = Routing.after_failure(r, attempt("a", out, 2), facts())

        assert Routing.after_failure(r, attempt("a", out, 3), facts()) ==
                 {:ok, {:stop, :retries_exhausted}}

        assert Routing.after_failure(r, attempt("a", out, 4), facts()) ==
                 {:ok, {:stop, :retries_exhausted}}
      end

      assert Routing.after_failure(
               r,
               attempt("a", {:refused, :credentials_unavailable, %{}}, 2),
               facts()
             ) ==
               {:ok, {:retry_same, 200}}

      r256 = route(r.candidates, %{retry: [max_attempts: 256]})
      out = {:not_admitted, :input_unavailable}
      assert {:ok, {:retry_same, _}} = Routing.after_failure(r256, attempt("a", out, 255), facts())

      assert Routing.after_failure(r256, attempt("a", out, 256), facts()) ==
               {:ok, {:stop, :retries_exhausted}}
    end
  end

  describe "after_failure/3 stops (case 9)" do
    test "an unknown outcome stops, on the first Attempt and every unknown reason" do
      r = two()

      for reason <- [:timeout, :transport, :malformed_response, :provider_error, :no_outcome] do
        assert Routing.after_failure(r, attempt("a", {:unknown, reason}), facts()) ==
                 {:ok, {:stop, :unknown_outcome}}
      end
    end

    test "a request fault stops for every candidate" do
      r = two()

      for out <- [
            {:refused, :invalid_request, %{retry_after: nil}},
            {:refused, :too_large, %{retry_after: nil}},
            {:not_admitted, :invalid_request},
            {:not_admitted, :too_large}
          ] do
        assert Routing.after_failure(r, attempt("a", out), facts()) ==
                 {:ok, {:stop, :request_fault}}
      end
    end

    test "unsupported_feature moves on, input_unavailable at admission retries the same" do
      r = two()

      assert Routing.after_failure(r, attempt("a", {:not_admitted, :unsupported_feature}), facts()) ==
               {:ok, {:next, nil}}

      assert Routing.after_failure(r, attempt("a", {:not_admitted, :input_unavailable}), facts()) ==
               {:ok, {:retry_same, 100}}
    end

    test "a completed outcome is done" do
      assert Routing.after_failure(two(), attempt("b", {:completed, %{content: "x"}}, 3), facts()) ==
               {:ok, :done}
    end
  end

  describe "invalid input (case 9)" do
    # Every candidate would be excluded first: "a" is tried, "b" lacks :tools.
    setup do
      r = route([cand("a", 1, %{features: [:tools]}), cand("b", 2)])
      %{r: r, req: request(r, %{features: [:tools], tried: ["a"]})}
    end

    test "the baseline is no candidate", %{r: r, req: req} do
      assert Routing.select(r, req, health(r)) ==
               {:error, {:no_candidate, [{"a", :tried}, {"b", :capability}]}}
    end

    test "a tried ref not on the route", %{r: r, req: req} do
      assert Routing.select(r, %{req | tried: ["a", "q"]}, health(r)) == {:error, :invalid_input}
    end

    test "a malformed data_policy", %{r: r, req: req} do
      for bad <- [%{providers: [%{provider: "p1", classes: []}]}, %{}, nil] do
        assert Routing.select(r, %{req | data_policy: bad}, health(r)) == {:error, :invalid_input}
      end

      assert Routing.select(r, %{req | classes: []}, health(r)) == {:error, :invalid_input}

      assert Routing.select(r, %{req | classes: [:public, :top]}, health(r)) ==
               {:error, :invalid_input}
    end

    test "a future observed_at_ms", %{r: r, req: req} do
      h = health(r, %{"a" => entry(%{observed_at_ms: @now + 1})})
      assert Routing.select(r, req, h) == {:error, :invalid_input}
    end

    test "costs and health keys must match the route", %{r: r, req: req} do
      assert Routing.select(r, %{req | costs: %{"a" => 1}}, health(r)) == {:error, :invalid_input}

      assert Routing.select(r, %{req | costs: %{"a" => 1, "b" => 1, "q" => 1}}, health(r)) ==
               {:error, :invalid_input}

      assert Routing.select(r, %{req | costs: %{"a" => 1, "b" => -1}}, health(r)) ==
               {:error, :invalid_input}

      assert Routing.select(r, req, health(r, %{"q" => fresh()})) == {:error, :invalid_input}
    end

    test "other malformed request and health", %{r: r, req: req} do
      h = health(r)

      for {bad_req, bad_h} <- [
            {Map.put(req, :extra, 1), h},
            {%{req | features: [:telepathy]}, h},
            {%{req | tried: ["a" | "b"]}, h},
            {req, Map.put(h, :extra, 1)},
            {req, %{h | now_ms: nil}},
            {req, %{h | budget_remaining: -1}},
            {req, health(r, %{"a" => entry(%{circuit: :broken})})},
            {req, health(r, %{"a" => entry(%{not_before_ms: :soon})})},
            {req, health(r, %{"a" => Map.put(fresh(), :extra, 1)})}
          ] do
        assert Routing.select(r, bad_req, bad_h) == {:error, :invalid_input}
      end

      assert Routing.select(route([cand("a", 1)], %{on_unknown: :fallback}), req, h) ==
               {:error, :invalid_input}
    end

    test "after_failure/3 refuses a malformed attempt, outcome, facts or route" do
      r = two()
      ok = {:refused, :throttled, %{retry_after: 1}}

      for {a, f} <- [
            {attempt("q", ok), facts()},
            {attempt("a", ok, 0), facts()},
            {attempt("a", ok, 257), facts()},
            {Map.put(attempt("a", ok), :extra, 1), facts()},
            {attempt("a", ok), %{now_ms: @now, random: @max_u32 + 1}},
            {attempt("a", ok), %{now_ms: @now, random: -1}},
            {attempt("a", ok), %{now_ms: nil, random: 0}},
            {attempt("a", {:refused, :throttled, %{retry_after: 86_401}}), facts()},
            {attempt("a", {:refused, :throttled, %{retry_after: -1}}), facts()},
            {attempt("a", {:refused, :throttled, %{}}), facts()},
            {attempt("a", {:refused, :overloaded, %{retry_after: 1, why: "x"}}), facts()},
            {attempt("a", {:refused, :unsupported_feature, %{retry_after: nil}}), facts()},
            {attempt("a", {:refused, :provider_error, %{retry_after: nil}}), facts()},
            {attempt("a", {:not_admitted, :credentials_unavailable}), facts()},
            {attempt("a", {:rate_limited, 0}), facts()},
            {attempt("a", {:rate_limited, 2.5}), facts()},
            {attempt("a", {:failed, :x}), facts()},
            {attempt("a", :completed), facts()}
          ] do
        assert Routing.after_failure(r, a, f) == {:error, :invalid_input}
      end

      assert Routing.after_failure(%{r | version: 0}, attempt("a", ok), facts()) ==
               {:error, :invalid_input}

      assert {:ok, {:next, _}} = Routing.after_failure(r, attempt("a", ok, 256), facts())
    end
  end
end
