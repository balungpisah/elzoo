# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TypedDecisionTest do
  use ExUnit.Case, async: true
  alias Elzoo.{OutputRepair, PatternStep, TypedDecision}

  @port %{
    "id" => "route",
    "direction" => "output",
    "schema_id" => "test/route",
    "schema_version" => 1
  }
  @request %{
    "version" => 1,
    "model" => "test-model",
    "max_output_tokens" => 32,
    "messages" => [%{"role" => "user", "text" => "Pick one."}]
  }
  @members ["red", "green"]
  @schema %{
    "type" => "object",
    "properties" => %{"n" => %{"type" => "integer"}},
    "required" => ["n"]
  }

  defp spec(extra \\ %{}),
    do:
      Map.merge(
        %{id: "d", request: @request, port: @port, answer: {:set, @members}, repairs: 1},
        extra
      )

  defp new!(extra \\ %{}) do
    {:ok, state} = TypedDecision.new(spec(extra))
    state
  end

  defp input(kind, fields),
    do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 5}, fields)

  defp typed(kind),
    do: input(kind, %{"schema_id" => "test/any", "schema_version" => 1, "payload" => nil})

  defp start, do: typed("start")

  defp outcome(call, class, payload \\ nil, schema \\ "elzoo.ai-text.result"),
    do:
      input("action_outcome", %{
        "action_id" => call,
        "outcome" => class,
        "schema_id" => schema,
        "schema_version" => 1,
        "payload" => payload
      })

  defp completed(call, content, structured, finish \\ "stop"),
    do:
      outcome(call, "completed", %{
        "content" => content,
        "structured" => structured,
        "finish" => finish,
        "usage" => %{"ignored" => true}
      })

  defp answer(member), do: ~s({"answer":"#{member}"})
  defp ok(member), do: completed("d:call:0", answer(member), %{"valid" => %{"answer" => member}})

  defp started(extra \\ %{}) do
    {:Transition, state, {:some, _}} = TypedDecision.step(new!(extra), start())
    state
  end

  # Runs inputs from a state; returns the final state and every request, each checked.
  defp run(state, inputs) do
    Enum.reduce(inputs, {state, []}, fn input, {state, requests} ->
      {:Transition, next, output} = TypedDecision.step(state, input)

      case output do
        :none ->
          {next, requests}

        {:some, request} ->
          assert {:ok, _} = PatternStep.decode(request)
          assert [_] = request["actions"]
          {next, requests ++ [request]}
      end
    end)
  end

  defp action(request), do: hd(request["actions"])
  defp result(request), do: action(request)["payload"]

  defp finished(state, inputs) do
    {closed, requests} = run(state, inputs)
    assert closed.phase == :closed
    last = List.last(requests)
    assert action(last)["kind"] == "finish"
    assert action(last)["id"] == "d:finish"
    assert action(last)["schema_id"] == "elzoo.typed-decision.result"
    {result(last), requests}
  end

  test "outside_the_set" do
    for content <- [answer("blue"), answer("Red"), answer("GREEN")] do
      wrong = completed("d:call:0", content, %{"invalid" => "schema_mismatch"})
      {_state, [repair]} = run(started(), [wrong])
      assert action(repair)["id"] == "d:call:1"
      [_, echoed, text] = action(repair)["payload"]["messages"]
      assert echoed == %{"role" => "assistant", "text" => content}
      assert text["text"] =~ "$.*: schema_mismatch"

      {result, [_]} = finished(started(%{repairs: 0}), [wrong])

      assert %{
               "status" => "failed",
               "reason" => "invalid_at_bound",
               "outcome" => "completed",
               "repairs" => 0,
               "action_id" => "d:call:0",
               "violations" => [_ | _] = violations
             } = result

      assert Enum.all?(violations, &(Map.keys(&1) == ["code", "path"]))
      refute Map.has_key?(result, "value")
    end
  end

  test "valid_after_one_repair" do
    first = completed("d:call:0", answer("blue"), %{"invalid" => "schema_mismatch"})
    second = completed("d:call:1", answer("green"), %{"valid" => %{"answer" => "green"}})
    {result, [repair, _finish]} = finished(started(), [first, second])

    assert result == %{
             "status" => "decided",
             "value" => "green",
             "repairs" => 1,
             "action_id" => "d:call:1"
           }

    {:ok, checked} = Elzoo.PayloadSchema.build(@port, new!().schema)
    {:error, {:violations, list}} = Elzoo.PayloadSchema.check(checked, @port, %{"answer" => "blue"})

    assert action(repair)["payload"]["messages"] ==
             @request["messages"] ++
               [
                 %{"role" => "assistant", "text" => answer("blue")},
                 %{"role" => "user", "text" => OutputRepair.render(list)}
               ]
  end

  test "invalid_at_bound" do
    state = started(%{answer: {:schema, @schema}})
    first = completed("d:call:0", ~s({"n": "x"}), %{"invalid" => "schema_mismatch"})
    second = completed("d:call:1", "not json", %{"invalid" => "invalid_json"})
    {result, [_repair, _finish]} = finished(state, [first, second])

    assert result == %{
             "status" => "failed",
             "reason" => "invalid_at_bound",
             "violations" => [%{"path" => [], "code" => "invalid_json"}],
             "outcome" => "completed",
             "repairs" => 1,
             "action_id" => "d:call:1"
           }

    # Reverse order: the last violations are the schema ones, with "*" for a key.
    first = completed("d:call:0", "{", %{"invalid" => "invalid_json"})
    second = completed("d:call:1", ~s({"n": [1]}), %{"invalid" => "schema_mismatch"})
    {result, _} = finished(state, [first, second])
    assert %{"path" => ["*"], "code" => "schema_mismatch"} in result["violations"]
    refute %{"path" => [], "code" => "invalid_json"} in result["violations"]

    {result, [_finish]} =
      finished(started(%{repairs: 0}), [
        ok("blue") |> put_structured(%{"invalid" => "schema_mismatch"})
      ])

    assert result["reason"] == "invalid_at_bound"
  end

  defp put_structured(input, structured), do: put_in(input, ["payload", "structured"], structured)

  test "refusal_or_empty" do
    cases = [
      completed("d:call:0", answer("red"), %{"valid" => %{"answer" => "red"}}, "refusal"),
      completed("d:call:0", answer("red"), %{"valid" => %{"answer" => "red"}}, "content_filter"),
      completed("d:call:0", "", %{"invalid" => "invalid_json"}),
      completed("d:call:0", answer("red"), %{"invalid" => "missing"})
    ]

    for input <- cases do
      {result, [_finish]} = finished(started(%{repairs: 8}), [input])
      assert %{"status" => "failed", "reason" => "no_answer", "violations" => []} = result
    end
  end

  test "finish_length" do
    for state <- [started(%{repairs: 8}), started(%{answer: {:schema, @schema}, repairs: 2})] do
      valid_cut = completed("d:call:0", answer("red"), %{"valid" => %{"answer" => "red"}}, "length")
      {result, [_finish]} = finished(state, [valid_cut])
      assert %{"status" => "failed", "reason" => "length", "violations" => []} = result
    end
  end

  test "validators_disagree" do
    cases = [
      completed("d:call:0", answer("blue"), %{"valid" => %{"answer" => "red"}}),
      completed("d:call:0", answer("red"), %{"invalid" => "schema_mismatch"})
    ]

    for input <- cases, repairs <- [0, 1] do
      {result, [_finish]} = finished(started(%{repairs: repairs}), [input])

      assert result == %{
               "status" => "failed",
               "reason" => "validator_disagreement",
               "violations" => [],
               "outcome" => "completed",
               "repairs" => 0,
               "action_id" => "d:call:0"
             }
    end
  end

  test "repair_calls_visible" do
    bad = fn call -> completed(call, answer("x"), %{"invalid" => "schema_mismatch"}) end

    {result, requests} =
      finished(started(%{repairs: 2}), [
        bad.("d:call:0"),
        bad.("d:call:1"),
        completed("d:call:2", answer("red"), %{"valid" => %{"answer" => "red"}})
      ])

    assert Enum.map(requests, &action(&1)["id"]) == ["d:call:1", "d:call:2", "d:finish"]
    assert Enum.map(requests, &action(&1)["kind"]) == ["model_call", "model_call", "finish"]
    # Each repair carries only the last output and the last violations.
    assert length(action(Enum.at(requests, 1))["payload"]["messages"]) == 3
    assert result["repairs"] == 2 and result["value"] == "red"

    {_, [call0]} = run(new!(%{repairs: 2}), [start()])
    assert action(call0)["id"] == "d:call:0"
    assert action(call0)["schema_id"] == "elzoo/ai-text-request"
    assert action(call0)["payload"] == Map.put(@request, "output_schema", new!().schema)

    for class <- ["out_of_budget", "refused", "unknown", "failed", "expired"] do
      {result, [_repair, _finish]} =
        finished(started(%{repairs: 2}), [bad.("d:call:0"), outcome("d:call:1", class)])

      assert result == %{
               "status" => "failed",
               "reason" => "call_not_completed",
               "violations" => [],
               "outcome" => class,
               "repairs" => 1,
               "action_id" => "d:call:1"
             }
    end
  end

  test "single_member_set_refused" do
    for members <- [["red"], [], ["red", "red"], ["red", ""], ["red", :green], "red"] do
      assert TypedDecision.new(spec(%{answer: {:set, members}})) == {:error, :invalid_set}
    end

    for schema <- [%{"type" => 7}, %{"$ref" => "http://x"}, "object"] do
      assert TypedDecision.new(spec(%{answer: {:schema, schema}})) == {:error, :invalid_schema}
    end

    for bad <- [
          %{repairs: 9},
          %{repairs: -1},
          %{request: Map.put(@request, "output_schema", %{})},
          %{request: Map.delete(@request, "messages")},
          %{id: ""},
          %{id: String.duplicate("a", 129)},
          %{port: Map.put(@port, "direction", "input")},
          %{answer: {:enum, @members}}
        ] do
      assert TypedDecision.new(spec(bad)) == {:error, :invalid_spec}
    end

    assert TypedDecision.new(Map.put(spec(), :extra, 1)) == {:error, :invalid_spec}
    assert {:ok, _} = TypedDecision.new(spec(%{id: String.duplicate("a", 128), repairs: 8}))
  end

  test "deterministic_replay" do
    other = completed("d:call:9", answer("red"), %{"valid" => %{"answer" => "red"}})

    inputs = [
      start(),
      typed("message"),
      other,
      %{"type" => "input", "version" => 2},
      outcome("d:call:0", "late"),
      completed("d:call:0", answer("x"), %{"invalid" => "schema_mismatch"}),
      input("wake", %{}),
      ok("red") |> Map.put("action_id", "d:call:1")
    ]

    assert run(new!(), inputs) == run(new!(), inputs)
    {closed, _} = run(new!(), inputs)
    assert closed == :erlang.binary_to_term(:erlang.term_to_binary(closed), [:safe])
    assert plain?(new!()) and plain?(started()) and plain?(closed)

    # The table, each input kind of pattern-step v1.
    new = new!()
    waiting = started()

    unchanged = [
      typed("message"),
      typed("resource_event"),
      input("wake", %{}),
      input("person_answer", %{
        "action_id" => "d:call:0",
        "person_id" => "p",
        "schema_id" => "test/any",
        "schema_version" => 1,
        "payload" => nil
      }),
      other,
      outcome("d:call:0", "late"),
      %{"type" => "input"},
      :garbage
    ]

    for input <- unchanged,
        state <- [new, waiting, closed],
        do: assert(TypedDecision.step(state, input) == {:Transition, state, :none})

    assert TypedDecision.step(new, ok("red")) == {:Transition, new, :none}
    assert TypedDecision.step(waiting, start()) == {:Transition, waiting, :none}
    assert TypedDecision.step(closed, start()) == {:Transition, closed, :none}

    for state <- [new, waiting],
        end_input <- [typed("run_ended"), input("cancel", %{"attempt_id" => "a"})] do
      assert {:Transition, %{phase: :closed} = c, :none} = TypedDecision.step(state, end_input)
      assert TypedDecision.step(c, ok("red")) == {:Transition, c, :none}
    end

    # malformed_result: wrong schema pair, missing member, structured null, unknown finish.
    malformed = [
      put_in(ok("red"), ["schema_id"], "other.result"),
      update_in(ok("red"), ["payload"], &Map.delete(&1, "finish")),
      put_structured(ok("red"), nil),
      put_structured(ok("red"), %{"valid" => 1, "invalid" => "missing"}),
      put_in(ok("red"), ["payload", "finish"], "done"),
      put_in(ok("red"), ["payload", "content"], 7),
      put_in(ok("red"), ["payload"], [])
    ]

    for input <- malformed do
      {result, [_]} = finished(waiting, [input])

      assert %{"reason" => "malformed_result", "outcome" => "completed", "violations" => []} =
               result
    end

    {result, [_]} = finished(waiting, [put_in(ok("red"), ["payload", "finish"], %{"other" => "x"})])
    assert result["reason"] == "no_answer"
  end

  defp plain?(term) when is_map(term),
    do: not is_struct(term) and Enum.all?(term, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?(term) when is_list(term), do: Enum.all?(term, &plain?/1)
  defp plain?(term) when is_tuple(term), do: term |> Tuple.to_list() |> plain?()

  defp plain?(term),
    do: is_atom(term) or is_number(term) or is_binary(term)

  test "laws_and_example" do
    {result, _} = Code.eval_file(Path.expand("../../examples/typed_decision.exs", __DIR__))

    assert result ==
             {OutputRepair.render([
                %{path: [:key], code: :schema_mismatch},
                %{path: [], code: :schema_mismatch}
              ]),
              %{
                "status" => "decided",
                "value" => "billing",
                "repairs" => 1,
                "action_id" => "route-1:call:1"
              }}
  end
end
