# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.NodeOutcomeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Elzoo.NodeOutcome, as: N
  alias Elzoo.PatternStep

  @classes ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)
  @sentinel "SENTINEL-4f9a"

  defp outcome_link(from, to, class),
    do: %{"from" => from, "to" => to, "kind" => "outcome", "outcome" => class}

  describe "routes_of_one_node" do
    test "gives exactly the outcome routes of the named node among all four kinds" do
      links = [
        %{"from" => "a", "to" => "b", "kind" => "order"},
        %{"from" => "a", "to" => "c", "kind" => "data", "output" => "x", "input" => "y"},
        %{"from" => "a", "to" => "d", "kind" => "choice", "branch" => "yes"},
        outcome_link("a", "e", "failed"),
        outcome_link("a", "f", "completed"),
        outcome_link("z", "g", "refused"),
        %{"from" => "z", "to" => "a", "kind" => "order"}
      ]

      assert N.routes(links, "a") == {:ok, %{"failed" => "e", "completed" => "f"}}
      assert N.routes(links, "z") == {:ok, %{"refused" => "g"}}
    end

    test "a node with no outcome link, or an empty list, gives an empty map" do
      links = [%{"from" => "a", "to" => "b", "kind" => "order"}, outcome_link("z", "b", "failed")]
      assert N.routes(links, "a") == {:ok, %{}}
      assert N.routes(links, "unknown-node") == {:ok, %{}}
      assert N.routes([], "a") == {:ok, %{}}
    end

    test "each malformed case is invalid input" do
      good = outcome_link("a", "b", "failed")
      long = String.duplicate("x", 129)

      for links <- [
            [good, "not a map"],
            [good, nil],
            [outcome_link("a", "b", "vanished")],
            [outcome_link("a", "b", "Completed")],
            [Map.delete(good, "outcome")],
            [outcome_link("a", "b", 1)],
            [outcome_link("a", "", "failed")],
            [outcome_link("a", long, "failed")],
            [outcome_link("a", 7, "failed")],
            [outcome_link("a", <<255>>, "failed")],
            [Map.delete(good, "to")],
            [good, outcome_link("a", "c", "failed")],
            [good, good],
            %{"not" => "a list"},
            nil,
            [good | :improper]
          ] do
        assert N.routes(links, "a") == {:error, :invalid_input}
      end

      for node_id <- ["", String.duplicate("n", 129), nil, 5, :a, <<255>>] do
        assert N.routes([good], node_id) == {:error, :invalid_input}
      end

      assert N.routes([good], String.duplicate("n", 128)) == {:ok, %{}}
    end

    test "malformed outcome links of other nodes are not read" do
      links = [outcome_link("z", "b", "vanished"), outcome_link("z", "", "failed")]
      assert N.routes(links, "a") == {:ok, %{}}
    end

    test "10,000 links are accepted and 10,001 are refused" do
      filler = %{"from" => "z", "to" => "y", "kind" => "order"}
      links = [outcome_link("a", "b", "failed") | List.duplicate(filler, 9_999)]
      assert length(links) == 10_000
      assert N.routes(links, "a") == {:ok, %{"failed" => "b"}}
      assert N.routes([filler | links], "a") == {:error, :invalid_input}
      assert N.routes(links ++ [outcome_link("a", "c", "refused")], "a") == {:error, :invalid_input}
    end
  end

  describe "nine_classes_total" do
    test "all 18 cases are listed" do
      with_route = %{
        "completed" => "t-completed",
        "failed" => "t-failed",
        "refused" => "t-refused",
        "late" => "t-late",
        "unknown" => "t-unknown",
        "out_of_budget" => "t-out_of_budget",
        "retries_exhausted" => "t-retries_exhausted",
        "expired" => "t-expired",
        "resource_lost" => "t-resource_lost"
      }

      assert N.decide(with_route, "completed") == {:follow, "t-completed"}
      assert N.decide(with_route, "failed") == {:follow, "t-failed"}
      assert N.decide(with_route, "refused") == {:follow, "t-refused"}
      assert N.decide(with_route, "late") == {:follow, "t-late"}
      assert N.decide(with_route, "unknown") == {:follow, "t-unknown"}
      assert N.decide(with_route, "out_of_budget") == {:follow, "t-out_of_budget"}
      assert N.decide(with_route, "retries_exhausted") == {:follow, "t-retries_exhausted"}
      assert N.decide(with_route, "expired") == {:follow, "t-expired"}
      assert N.decide(with_route, "resource_lost") == {:follow, "t-resource_lost"}

      assert N.decide(%{}, "completed") == :proceed
      assert N.decide(%{}, "failed") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "refused") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "late") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "unknown") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "out_of_budget") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "retries_exhausted") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "expired") == {:fail_run, :no_outcome_link}
      assert N.decide(%{}, "resource_lost") == {:fail_run, :no_outcome_link}
    end
  end

  describe "no_fallback_between_classes" do
    test "a route only for failed serves no other class" do
      routes = %{"failed" => "r"}
      assert N.decide(routes, "failed") == {:follow, "r"}
      assert N.decide(routes, "completed") == :proceed

      for class <- @classes -- ["completed", "failed"] do
        assert N.decide(routes, class) == {:fail_run, :no_outcome_link}
      end
    end

    test "a route only for completed serves no uncompleted class" do
      routes = %{"completed" => "r"}
      assert N.decide(routes, "completed") == {:follow, "r"}

      for class <- @classes -- ["completed"] do
        assert N.decide(routes, class) == {:fail_run, :no_outcome_link}
      end
    end
  end

  describe "unknown_is_never_retried" do
    test "unknown follows its route or fails the Run" do
      assert N.decide(%{"unknown" => "r"}, "unknown") == {:follow, "r"}
      assert N.decide(%{}, "unknown") == {:fail_run, :no_outcome_link}

      assert N.decide(%{"failed" => "r", "completed" => "s"}, "unknown") ==
               {:fail_run, :no_outcome_link}
    end

    test "every class over every subset of routes gives one of the three decisions" do
      subsets =
        Enum.reduce(@classes, [[]], fn class, acc -> acc ++ Enum.map(acc, &[class | &1]) end)

      assert length(subsets) == 512

      for subset <- subsets, class <- @classes do
        routes = Map.new(subset, &{&1, "t-" <> &1})
        result = N.decide(routes, class)

        expected =
          cond do
            class in subset -> {:follow, "t-" <> class}
            class == "completed" -> :proceed
            true -> {:fail_run, :no_outcome_link}
          end

        assert result == expected
      end
    end
  end

  describe "class_names_match_pattern_step" do
    defp action_outcome(class) do
      %{
        "type" => "input",
        "version" => 1,
        "kind" => "action_outcome",
        "at_ms" => 1,
        "action_id" => "act-1",
        "outcome" => class,
        "schema_id" => "example/result",
        "schema_version" => 1,
        "payload" => nil
      }
    end

    test "each of the nine classes passes both pieces" do
      for class <- @classes do
        assert {:ok, _} = PatternStep.decode(action_outcome(class))
        assert {:follow, "t"} = N.decide(%{class => "t"}, class)
        assert N.decide(%{}, class) in [:proceed, {:fail_run, :no_outcome_link}]
      end
    end

    test "a tenth name is refused by both" do
      assert {:error, :invalid_shape} = PatternStep.decode(action_outcome("vanished"))
      assert N.decide(%{}, "vanished") == {:error, :invalid_input}
      assert N.decide(%{"vanished" => "t"}, "completed") == {:error, :invalid_input}
    end
  end

  describe "invalid_input_and_redaction" do
    test "wrong types, unknown class, unknown route key, over-long target" do
      long = String.duplicate("t", 129)
      too_many = Map.new(1..10, &{"k#{&1}", "t"})

      for {routes, outcome} <- [
            {nil, "failed"},
            {[], "failed"},
            {[{"failed", "t"}], "failed"},
            {%{}, nil},
            {%{}, :failed},
            {%{}, 1},
            {%{}, "vanished"},
            {%{}, "Failed"},
            {%{"vanished" => "t"}, "failed"},
            {%{:failed => "t"}, "failed"},
            {%{"failed" => long}, "failed"},
            {%{"failed" => ""}, "failed"},
            {%{"failed" => :t}, "failed"},
            {%{"failed" => <<255>>}, "failed"},
            {too_many, "failed"}
          ] do
        assert N.decide(routes, outcome) == {:error, :invalid_input}
      end
    end

    test "a sentinel inside a refused value never appears in an error or a log" do
      long = String.duplicate("t", 129) <> @sentinel

      refused = [
        fn -> N.decide(%{"failed" => long}, "failed") end,
        fn -> N.decide(%{@sentinel => "t"}, "failed") end,
        fn -> N.decide(%{}, @sentinel) end,
        fn -> N.decide(%{"failed" => @sentinel <> <<255>>}, "failed") end,
        fn -> N.routes([outcome_link("a", long, "failed")], "a") end,
        fn -> N.routes([outcome_link("a", "b", @sentinel)], "a") end,
        fn ->
          N.routes(
            [
              %{
                "from" => "a",
                "kind" => "outcome",
                "outcome" => "failed",
                "to" => 1,
                "extra" => @sentinel
              }
            ],
            "a"
          )
        end,
        fn -> N.routes([@sentinel], "a") end,
        fn -> N.routes([], String.duplicate(@sentinel, 20)) end
      ]

      log =
        capture_log(fn ->
          for call <- refused do
            result = call.()
            assert result == {:error, :invalid_input}
            refute inspect(result) =~ @sentinel
          end
        end)

      refute log =~ @sentinel
    end

    test "equal inputs give equal results" do
      links = [outcome_link("a", "b", "failed"), outcome_link("a", "c", "expired")]
      assert N.routes(links, "a") == N.routes(links, "a")
      assert N.decide(%{"failed" => "b"}, "failed") == N.decide(%{"failed" => "b"}, "failed")
      assert N.decide(%{}, "vanished") == N.decide(%{}, "vanished")
    end

    test "the Cure law module compiles, checks and has a clean audit" do
      source = File.read!(Path.expand("../../cure/elzoo/node_outcome.cure", __DIR__))
      roots = Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
      assert {:ok, _module} = Cure.Compiler.compile_and_load(source, source_roots: roots)
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
      audit = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(audit, key) == [])

      assert audit.absurd == 0
    end

    test "the checked example covers the public API" do
      {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/node_outcome.exs", __DIR__))

      assert result ==
               {%{"failed" => "c"}, {:follow, "c"}, :proceed, {:fail_run, :no_outcome_link}}
    end
  end
end
