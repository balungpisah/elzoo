# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ContextCompactionTest do
  use ExUnit.Case, async: true
  alias Elzoo.AiText.Request
  alias Elzoo.{ContextCompaction, PatternStep}

  @window %{
    provider_id: "provider-a",
    model_id: "model-a",
    size: 1_000_000,
    unit: :tokens,
    estimator_id: "bytes",
    estimator_version: 1
  }

  # A plain function of the byte size: one token per byte, an upper bound.
  defp estimate(bytes),
    do:
      {:ok,
       %{
         size: byte_size(bytes),
         unit: :tokens,
         direction: :upper_bound,
         estimator_id: "bytes",
         estimator_version: 1
       }}

  defp marked(content) do
    %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => ["mcp:files/read_file"],
      "trust" => "untrusted",
      "max_bytes" => 4096,
      "content" => content
    }
  end

  defp entries do
    [
      %{kind: :record, id: "r1", keep: :goal, record: %{"goal" => "ship the report"}},
      %{kind: :user, id: "u1", text: "Please read the file."},
      %{
        kind: :assistant,
        id: "a1",
        text: "Reading it.",
        tool_calls: [%{"id" => "c1", "name" => "read_file", "arguments" => %{"path" => "a.txt"}}]
      },
      %{
        kind: :tool_result,
        id: "t1",
        tool_use_id: "c1",
        content: marked("file text"),
        ref_media_type: nil
      },
      %{kind: :record, id: "r2", keep: :failed_approach, record: %{"tried" => "grep"}},
      %{kind: :content, id: "d1", content: marked("a member message"), ref_media_type: nil}
    ]
  end

  defp input(fields \\ []) do
    Map.merge(
      %{
        action_id: "compact-1",
        entries: entries(),
        model: "model-a",
        max_output_tokens: 512,
        role_instructions: ["Summarize the history in a few lines."],
        window: @window,
        max_request_bytes: 65_536,
        summary: %{id: "s1", source: "summary:compact-1", max_bytes: 64}
      },
      Map.new(fields)
    )
  end

  defp outcome(fields \\ []) do
    fields = Map.new(fields)

    Map.merge(
      %{
        "type" => "input",
        "version" => 1,
        "kind" => "action_outcome",
        "at_ms" => 1,
        "action_id" => "compact-1",
        "outcome" => "completed",
        "schema_id" => "elzoo.ai-text.result",
        "schema_version" => 1,
        "payload" =>
          Map.merge(
            %{"content" => "Read a.txt.", "structured" => nil, "finish" => "stop"},
            Map.get(fields, "payload", %{})
          )
      },
      Map.delete(fields, "payload")
    )
  end

  test "compaction" do
    assert {:ok, state, request} = ContextCompaction.open(input(), &estimate/1)

    # One model_call action whose payload ai-text accepts and which holds no record.
    assert {:ok, _} = PatternStep.decode(request)
    assert %{"actions" => [action]} = request

    assert %{
             "id" => "compact-1",
             "kind" => "model_call",
             "schema_id" => "elzoo/ai-text-request",
             "schema_version" => 1,
             "payload" => payload
           } = action

    assert {:ok, _, _} = Request.decode(Request.canonical(payload))
    texts = Enum.map(payload["messages"], & &1["text"])
    refute Enum.any?(texts, &(&1 =~ "keep" or &1 =~ "ship the report" or &1 =~ "grep"))
    assert hd(texts) == "Summarize the history in a few lines."

    # A completed outcome: the records unchanged, then the derived summary.
    assert {:ok, compacted} = ContextCompaction.accept(state, outcome())

    assert compacted == %{
             entries: [
               Enum.at(entries(), 0),
               Enum.at(entries(), 4),
               %{
                 kind: :content,
                 id: "s1",
                 content: %{
                   "schema_id" => "elzoo.untrusted-content.marked",
                   "schema_version" => 1,
                   "sources" => ["summary:compact-1"],
                   "trust" => "derived",
                   "max_bytes" => 64,
                   "content" => "Read a.txt."
                 },
                 ref_media_type: nil
               }
             ],
             derived_from: [
               %{item_id: "u1", version: 1},
               %{item_id: "a1", version: 1},
               %{item_id: "t1", version: 1},
               %{item_id: "d1", version: 1}
             ]
           }

    # Outcomes that give no compacted value.
    for class <- ["failed", "refused", "unknown"] do
      assert ContextCompaction.accept(state, outcome(%{"outcome" => class})) ==
               {:error, {:model_call, class}}
    end

    for bad <- [
          outcome(%{"payload" => %{"finish" => "length"}}),
          outcome(%{"payload" => %{"finish" => "refusal"}}),
          outcome(%{"payload" => %{"content" => ""}}),
          outcome(%{"payload" => %{"content" => String.duplicate("s", 65)}}),
          outcome(%{"schema_id" => "elzoo.other.result"})
        ] do
      assert ContextCompaction.accept(state, bad) == {:error, :invalid_summary}
    end

    assert ContextCompaction.accept(state, outcome(%{"action_id" => "other"})) == {:late, state}
    assert ContextCompaction.accept(state, outcome(%{"outcome" => "late"})) == {:late, state}
    assert ContextCompaction.accept(state, %{"type" => "input"}) == {:error, :invalid_input}
    assert ContextCompaction.accept(state, request) == {:error, :invalid_input}

    message =
      outcome()
      |> Map.drop(["action_id", "outcome"])
      |> Map.put("kind", "message")

    assert ContextCompaction.accept(state, message) == {:error, :not_an_outcome}

    # check/2 names a lost keep-rule item.
    lost = %{compacted | entries: tl(compacted.entries)}
    assert ContextCompaction.check(entries(), lost) == {:error, {:keep_items_lost, ["r1"]}}
    assert ContextCompaction.check(entries(), compacted) == :ok
  end

  test "open refusals" do
    records = Enum.filter(entries(), &(&1.kind == :record))

    assert ContextCompaction.open(input(entries: records), &estimate/1) ==
             {:error, :nothing_to_summarize}

    {:ok, %{"actions" => [%{"payload" => payload}]}} =
      ContextCompaction.open(input(), &estimate/1) |> then(fn {:ok, _, r} -> {:ok, r} end)

    small = byte_size(Request.canonical(payload)) - 1

    assert ContextCompaction.open(input(window: %{@window | size: small}), &estimate/1) ==
             {:error, :over_limit}

    assert ContextCompaction.open(input(max_request_bytes: small), &estimate/1) ==
             {:error, :over_limit}

    # A record that is not a JSON object never enters the plain-data state.
    for value <- [fn -> :ok end, self()] do
      [record | rest] = entries()

      assert ContextCompaction.open(
               input(entries: [%{record | record: %{"x" => value}} | rest]),
               &estimate/1
             ) ==
               {:error, :invalid_input}
    end

    for summary <- [
          %{id: "s1", source: "bad source", max_bytes: 64},
          %{id: "s1", source: "summary:x", max_bytes: 0},
          %{id: "s1", source: "summary:x", max_bytes: 16_777_217},
          %{id: "u1", source: "summary:x", max_bytes: 64}
        ] do
      assert ContextCompaction.open(input(summary: summary), &estimate/1) ==
               {:error, :invalid_input}
    end

    orphan = [
      %{kind: :tool_result, id: "t9", tool_use_id: "c9", content: marked("x"), ref_media_type: nil}
    ]

    assert ContextCompaction.open(input(entries: orphan), &estimate/1) ==
             {:error, :orphan_tool_result}
  end
end
