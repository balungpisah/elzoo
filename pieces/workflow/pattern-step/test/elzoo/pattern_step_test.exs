# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PatternStepTest do
  use ExUnit.Case, async: false
  alias Elzoo.PatternStep, as: P

  @actions ~w(model_call tool_call local_work ask_person nested_callable resource_open resource_use resource_close finish)
  @outcomes ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)
  @typed_inputs ~w(start message resource_event run_ended)
  # Fixed v1 compatibility fixture: do not regenerate it when a later version is added.
  @v1_fixture [
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "model-7",
          "kind" => "model_call",
          "schema_id" => "example/prompt",
          "schema_version" => 2,
          "payload" => %{"question" => "seven?"}
        },
        %{
          "id" => "ask-合計",
          "kind" => "ask_person",
          "schema_id" => "example/question",
          "schema_version" => 3,
          "payload" => [11, "answer?"]
        }
      ]
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "at_ms" => 1_730_000_000_123,
      "action_id" => "model-7",
      "outcome" => "unknown",
      "schema_id" => "example/result",
      "schema_version" => 4,
      "payload" => %{"detail" => "not observed"}
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "person_answer",
      "at_ms" => 1_730_000_000_456,
      "action_id" => "ask-合計",
      "person_id" => "principal-29",
      "schema_id" => "example/answer",
      "schema_version" => 5,
      "payload" => %{"text" => "principal-from-text-is-not-identity"}
    }
  ]

  defp action(kind, id),
    do: %{
      "id" => id,
      "kind" => kind,
      "schema_id" => "example/work",
      "schema_version" => 1,
      "payload" => %{"work" => id}
    }

  defp request(actions), do: %{"type" => "request", "version" => 1, "actions" => actions}

  defp input(kind, extra \\ %{}) do
    Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 0}, extra)
  end

  defp typed(kind, extra \\ %{}) do
    input(
      kind,
      Map.merge(
        %{"schema_id" => "example/result", "schema_version" => 1, "payload" => nil},
        extra
      )
    )
  end

  defp checked(map) do
    assert {:ok, checked} = P.decode(map)
    checked
  end

  defp outcome(id, class \\ "completed"),
    do: checked(typed("action_outcome", %{"action_id" => id, "outcome" => class}))

  defp answer(id),
    do: checked(typed("person_answer", %{"action_id" => id, "person_id" => "principal-29"}))

  defp admitted_maps do
    [
      request(Enum.with_index(@actions, 1) |> Enum.map(fn {kind, n} -> action(kind, "a#{n}") end)),
      input("cancel", %{"attempt_id" => "attempt-19"}),
      input("wake"),
      typed("person_answer", %{"action_id" => "a4", "person_id" => "principal-29"})
    ] ++
      Enum.map(@typed_inputs, &typed/1) ++
      Enum.map(@outcomes, &typed("action_outcome", %{"action_id" => "a1", "outcome" => &1}))
  end

  test "every v1 kind and the fixed unequal v1 fixture round-trip unchanged" do
    for map <- @v1_fixture ++ admitted_maps(), do: assert(P.encode(checked(map)) === map)
  end

  test "unknown versions, kinds, extra fields and malformed shapes return only a fixed redacted error" do
    for map <- admitted_maps() do
      for key <- Map.keys(map),
          do: assert(P.decode(Map.delete(map, key)) == {:error, :invalid_shape})

      for version <- [0, 2],
          do: assert(P.decode(Map.put(map, "version", version)) == {:error, :invalid_shape})

      assert P.decode(Map.put(map, "secret-extra", "do-not-echo")) == {:error, :invalid_shape}
    end

    for bad <- [
          nil,
          [],
          %{},
          request([action("local_work", "a1") | :malformed]),
          input("future"),
          input("wake", %{"payload" => "secret"}),
          input("wake", %{"content" => "secret"}),
          typed("action_outcome", %{"action_id" => "a1", "outcome" => "future"})
        ] do
      assert P.decode(bad) == {:error, :invalid_shape}
    end

    for {map, fields, invalid} <- [
          {typed("start"), ["schema_id"], ["", <<255>>, :atom]},
          {typed("start"), ["schema_version"], [0, -1, 1.0, "1"]},
          {input("wake"), ["at_ms"], [-1, 1.0, "0", nil]},
          {typed("person_answer", %{"action_id" => "a4", "person_id" => "p"}),
           ["action_id", "person_id"], ["", <<255>>, 17]},
          {input("cancel", %{"attempt_id" => "attempt-19"}), ["attempt_id"], ["", <<255>>, nil]}
        ],
        field <- fields,
        value <- invalid do
      assert P.decode(Map.put(map, field, value)) == {:error, :invalid_shape}
    end

    valid = action("local_work", "a1")

    for action <-
          Enum.map(Map.keys(valid), &Map.delete(valid, &1)) ++
            [Map.put(valid, "extra", "secret"), Map.put(valid, "kind", "future")] ++
            for(
              field <- ["id", "schema_id"],
              value <- ["", <<255>>, :atom],
              do: Map.put(valid, field, value)
            ) ++
            Enum.map([0, -1, 1.0, "1"], &Map.put(valid, "schema_version", &1)) do
      assert P.decode(request([action])) == {:error, :invalid_shape}
    end
  end

  test "request bounds, separated duplicate IDs and action order" do
    for n <- [1, 64] do
      map = request(for i <- 1..n, do: action("local_work", "work-#{i}"))
      assert P.encode(checked(map)) == map
    end

    assert P.decode(request([])) == {:error, :invalid_shape}

    assert P.decode(request(for i <- 1..65, do: action("local_work", "work-#{i}"))) ==
             {:error, :invalid_shape}

    a = action("model_call", "same")
    b = action("tool_call", "same")

    for actions <- [[a, b], [a, action("finish", "different"), b]],
        do: assert(P.decode(request(actions)) == {:error, :invalid_shape})
  end

  test "unknown, repeat and explicit late outcomes preserve state; actions settle independently without callbacks" do
    callback = fn -> flunk("opaque payload invoked") end
    a = Map.put(action("local_work", "work-7"), "payload", callback)
    tracker = P.open(checked(request([a, action("tool_call", "tool-13")])))
    assert {:late, ^tracker} = P.accept(tracker, outcome("absent"))
    assert {:late, ^tracker} = P.accept(tracker, outcome("work-7", "late"))
    assert {:applied, settled} = P.accept(tracker, outcome("work-7", "unknown"))
    assert {:late, ^settled} = P.accept(settled, outcome("work-7", "failed"))
    assert {:applied, both} = P.accept(settled, outcome("tool-13"))
    assert {:late, ^both} = P.accept(both, outcome("tool-13", "expired"))

    for map <- admitted_maps(),
        map["type"] == "input",
        map["kind"] not in ["action_outcome", "person_answer"] do
      assert {:refused, :not_an_outcome, ^tracker} = P.accept(tracker, checked(map))
    end
  end

  test "person answers and ordinary outcomes share settlement; incompatible answers never settle" do
    tracker =
      P.open(checked(request([action("ask_person", "ask-5"), action("model_call", "model-8")])))

    assert {:refused, :incompatible_answer_kind, ^tracker} = P.accept(tracker, outcome("ask-5"))
    assert {:refused, :incompatible_answer_kind, ^tracker} = P.accept(tracker, answer("model-8"))
    assert {:late, ^tracker} = P.accept(tracker, answer("absent"))
    assert {:late, ^tracker} = P.accept(tracker, outcome("ask-5", "late"))
    assert {:applied, answered} = P.accept(tracker, answer("ask-5"))
    assert {:late, ^answered} = P.accept(answered, answer("ask-5"))
    assert {:late, ^answered} = P.accept(answered, outcome("ask-5"))
    assert {:applied, _} = P.accept(answered, outcome("model-8"))

    for class <- @outcomes -- ["completed", "late"] do
      assert {:applied, failed} = P.accept(tracker, outcome("ask-5", class))
      assert {:late, ^failed} = P.accept(failed, answer("ask-5"))
    end
  end

  test "selected settled_never_applied law and production source audit" do
    source = File.read!(Path.expand("../../cure/elzoo/pattern_step.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
    assert {:ok, _module} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0
  end

  test "checked two-action example applies once and classifies the duplicate late" do
    {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/pattern_step.exs", __DIR__))
    assert result == {:applied, :late}
  end
end
