# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.StallDetectTest do
  use ExUnit.Case, async: true
  alias Elzoo.StallDetect, as: S

  @limits %{repeats: 3, idle_ms: 100}

  # Recorded traces: fixed v1 neutral maps, oldest first.
  @start %{
    "type" => "input",
    "version" => 1,
    "kind" => "start",
    "at_ms" => 1_000,
    "schema_id" => "example/start",
    "schema_version" => 1,
    "payload" => %{"task" => "summarise"}
  }

  @repeat_trace [
    @start,
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "call-1",
          "kind" => "tool_call",
          "schema_id" => "example/search",
          "schema_version" => 1,
          "payload" => %{"query" => "status", "page" => 1}
        }
      ]
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "at_ms" => 1_010,
      "action_id" => "call-1",
      "outcome" => "completed",
      "schema_id" => "example/result",
      "schema_version" => 1,
      "payload" => %{"hits" => []}
    },
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "call-2",
          "kind" => "tool_call",
          "schema_id" => "example/search",
          "schema_version" => 1,
          "payload" => %{"query" => "status", "page" => 1}
        }
      ]
    },
    %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "at_ms" => 1_020,
      "action_id" => "call-2",
      "outcome" => "completed",
      "schema_id" => "example/result",
      "schema_version" => 1,
      "payload" => %{"hits" => []}
    },
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "call-3",
          "kind" => "tool_call",
          "schema_id" => "example/search",
          "schema_version" => 1,
          "payload" => %{"query" => "status", "page" => 1}
        }
      ]
    }
  ]

  @ask_trace [
    @start,
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "ask-1",
          "kind" => "ask_person",
          "schema_id" => "example/question",
          "schema_version" => 1,
          "payload" => %{"text" => "Which account?"}
        }
      ]
    },
    %{"type" => "input", "version" => 1, "kind" => "wake", "at_ms" => 5_000}
  ]

  @expired %{
    "type" => "input",
    "version" => 1,
    "kind" => "action_outcome",
    "at_ms" => 1_050,
    "action_id" => "ask-1",
    "outcome" => "expired",
    "schema_id" => "example/result",
    "schema_version" => 1,
    "payload" => nil
  }

  @approval_trace [
    @start,
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => "transfer-1",
          "kind" => "tool_call",
          "schema_id" => "example/transfer",
          "schema_version" => 1,
          "payload" => %{"amount" => 10}
        }
      ]
    }
  ]

  defp with_action(trace, index, field, value) do
    List.update_at(trace, index, fn request ->
      Map.update!(request, "actions", fn [action] -> [Map.put(action, field, value)] end)
    end)
  end

  test "repeated_identical_actions" do
    assert S.verdict(@repeat_trace, @limits, 1_030, []) == {:ok, {:stalled, :repeated_action}}

    two = [@start | Enum.drop(@repeat_trace, 3)]
    assert S.verdict(two, @limits, 1_030, []) == {:ok, :not_stalled}

    for {field, value} <- [
          {"payload", %{"query" => "status", "page" => 2}},
          {"payload", %{"query" => "status", "page" => 1.0}},
          {"kind", "local_work"},
          {"schema_version", 2}
        ] do
      assert S.verdict(with_action(@repeat_trace, 5, field, value), @limits, 1_030, []) ==
               {:ok, :not_stalled}
    end

    # A retried action keeps its ID and adds no action: one action, exhausted, is no repeat.
    exhausted =
      Enum.take(@repeat_trace, 2) ++
        [
          @repeat_trace
          |> Enum.at(2)
          |> Map.merge(%{"outcome" => "retries_exhausted", "at_ms" => 1_090})
        ]

    assert S.verdict(exhausted, %{repeats: 2, idle_ms: 1_000}, 1_100, []) == {:ok, :not_stalled}

    # Rule 3 and rule 4 both hold: rule 3 wins.
    assert S.verdict(@repeat_trace, @limits, 1_000_000, []) ==
             {:ok, {:stalled, :repeated_action}}
  end

  test "no_new_input_within_bound" do
    trace = Enum.take(@repeat_trace, 3)
    last = 1_010

    assert S.verdict(trace, @limits, last + 99, []) == {:ok, :not_stalled}
    assert S.verdict(trace, @limits, last + 100, []) == {:ok, {:stalled, :no_input}}
    assert S.verdict(trace, @limits, last + 101, []) == {:ok, {:stalled, :no_input}}

    woken = trace ++ [%{"type" => "input", "version" => 1, "kind" => "wake", "at_ms" => 1_105}]
    assert S.verdict(woken, @limits, last + 100, []) == {:ok, {:stalled, :no_input}}
  end

  test "healthy_person_or_approval_wait" do
    far = 1_000_000

    assert S.verdict(@ask_trace, @limits, far, []) == {:ok, :not_stalled}
    expired = List.insert_at(@ask_trace, 2, @expired)
    assert S.verdict(expired, @limits, far, []) == {:ok, {:stalled, :no_input}}

    assert S.verdict(@approval_trace, @limits, far, ["transfer-1"]) == {:ok, :not_stalled}
    assert S.verdict(@approval_trace, @limits, far, []) == {:ok, {:stalled, :no_input}}

    assert S.verdict(@approval_trace, @limits, far, ["other-action"]) ==
             {:ok, {:stalled, :no_input}}

    settled = Enum.take(@repeat_trace, 3)
    assert S.verdict(settled, @limits, far, ["call-1"]) == {:ok, {:stalled, :no_input}}
  end

  test "window_over_bound_refused" do
    wake = %{"type" => "input", "version" => 1, "kind" => "wake", "at_ms" => 1_000}
    full = [@start | List.duplicate(wake, 255)]

    assert S.verdict(full, @limits, 1_000, []) == {:ok, :not_stalled}
    assert S.verdict(full ++ [wake], @limits, 1_000, []) == {:error, :window_too_large}
    assert S.verdict(full ++ [:malformed], @limits, 1_000, []) == {:error, :window_too_large}
    assert S.verdict(full ++ [wake], :malformed, 1_000, []) == {:error, :window_too_large}

    for {window, limits, now, waits} <- [
          {[], @limits, 1_000, []},
          {[@start, %{"type" => "input", "secret" => "s3cr3t"}], @limits, 1_000, []},
          {[wake, wake], @limits, 1_000, []},
          {Enum.drop(@repeat_trace, 1) |> Enum.take(1), @limits, 1_000, []},
          {[@start], %{repeats: 1, idle_ms: 100}, 1_000, []},
          {[@start], %{repeats: 257, idle_ms: 100}, 1_000, []},
          {[@start], %{repeats: 3, idle_ms: 0}, 1_000, []},
          {[@start], %{repeats: 3}, 1_000, []},
          {[@start], Map.put(@limits, :extra, 1), 1_000, []},
          {[@start], %{"repeats" => 3, "idle_ms" => 100}, 1_000, []},
          {[@start], @limits, -1, []},
          {[@start], @limits, 1.0e3, []},
          {[@start], @limits, 1_000, [""]},
          {[@start], @limits, 1_000, List.duplicate("id", 65)},
          {[@start], @limits, 1_000, :none},
          {[@start | :improper], @limits, 1_000, []}
        ] do
      assert S.verdict(window, limits, now, waits) == {:error, :invalid_shape}
    end
  end

  test "deterministic_verdict" do
    rebuilt =
      Enum.map(@repeat_trace, fn entry ->
        entry
        |> Enum.reverse()
        |> Map.new(fn
          {"payload", %{} = payload} -> {"payload", payload |> Enum.reverse() |> Map.new()}
          {"actions", actions} -> {"actions", Enum.map(actions, &rebuild_action/1)}
          pair -> pair
        end)
      end)

    for {window, now} <- [{@repeat_trace, 1_030}, {rebuilt, 1_030}, {@ask_trace, 9_999}] do
      results = for _ <- 1..5, do: S.verdict(window, @limits, now, [])
      assert Enum.uniq(results) |> length() == 1
    end

    assert S.verdict(rebuilt, @limits, 1_030, []) == S.verdict(@repeat_trace, @limits, 1_030, [])
  end

  test "checked example gives the repeated-action verdict" do
    {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/stall_detect.exs", __DIR__))
    assert result == {{:ok, {:stalled, :repeated_action}}, {:ok, :not_stalled}}
  end

  defp rebuild_action(action) do
    payload = action["payload"] |> Enum.reverse() |> Map.new()
    action |> Enum.reverse() |> Map.new() |> Map.put("payload", payload)
  end
end
