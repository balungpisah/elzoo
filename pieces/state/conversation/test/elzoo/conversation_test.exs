# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/conversation_test_helper.exs", __DIR__)

defmodule Elzoo.ConversationTest.DtoStruct do
  defstruct [:message_id, :role, :actor, :text]
end

defmodule Elzoo.ConversationTest do
  @moduledoc "Pure scenarios: the codec, the fold, the decision table and the version 1 rules."
  use ExUnit.Case, async: true

  alias Elzoo.Conversation.{History, Record, V1}
  alias Elzoo.ConversationTest.Helper, as: H
  alias Elzoo.DurableLog, as: Log

  @stream "conversation/tenant-1/conversation-1"

  describe "codec" do
    test "DTOs and payloads accept exactly the declared keys and bounds" do
      id128 = String.duplicate("i", 128)
      text4096 = String.duplicate("t", 4096)

      accepted = [
        {:input, H.input("m", text: "x")},
        {:input, H.input(id128, role: "source", actor: id128, text: text4096)},
        {:association, H.association(id128, id128)},
        {:answer, H.answer(id128, id128, id128, actor: id128, text: text4096)},
        {:answer, H.answer("a", "m", "r", completed: false)}
      ]

      for {mode, dto} <- accepted do
        assert {:ok, entry, completed} = Record.intent(mode, dto), inspect(dto)
        assert completed == Map.get(dto, :completed, true)
        assert {:ok, ^entry} = decode(row(1, entry))
      end

      refused = [
        {:input, Map.delete(H.input("m"), :actor)},
        {:input, Map.put(H.input("m"), :extra, "x")},
        {:input, H.input("")},
        {:input, H.input(String.duplicate("i", 129))},
        {:input, H.input("m\0")},
        {:input, H.input(<<0xFF>>)},
        {:input, H.input("m", role: "assistant")},
        {:input, H.input("m", actor: String.duplicate("a", 129))},
        {:input, H.input("m", text: "")},
        {:input, H.input("m", text: String.duplicate("t", 4097))},
        {:input, H.input("m", text: <<0xC3>>)},
        {:input, %{H.input("m") | text: :text}},
        {:input, struct(Elzoo.ConversationTest.DtoStruct, H.input("m"))},
        {:input, [message_id: "m", role: "user", actor: "a", text: "t"]},
        {:association, H.association("m", "")},
        {:association, Map.put(H.association("m", "r"), :completed, true)},
        {:association, H.association(String.duplicate("i", 129), "r")},
        {:answer, %{H.answer("a", "m", "r") | completed: "true"}},
        {:answer, Map.delete(H.answer("a", "m", "r"), :completed)},
        {:answer, H.answer("a", "m", "r\0")},
        {:answer, H.answer("a", "m", "r", text: String.duplicate("t", 4097))},
        {:other, H.input("m")}
      ]

      for {mode, dto} <- refused do
        assert :error = Record.intent(mode, dto), inspect({mode, dto})
      end
    end

    test "text keeps NUL and every other byte; the payload is exact JSON in declared key order" do
      chunk = IO.iodata_to_binary([Enum.to_list(0..127), "é漢😀"])
      text = chunk |> String.duplicate(30) |> binary_part(0, 4096) |> trim_utf8()
      entry = H.entry!(:input, H.input("m", text: text))

      assert Record.payload(entry) ==
               Jason.encode!(%Jason.OrderedObject{
                 values: [
                   {"message_id", "m"},
                   {"role", "user"},
                   {"actor", "host"},
                   {"text", text}
                 ]
               })

      assert String.starts_with?(Record.payload(entry), ~s({"message_id":"m","role":"user"))
      assert {:ok, decoded} = decode(row(1, entry))
      assert decoded.text == text
      assert :binary.match(decoded.text, <<0>>) != :nomatch
    end

    test "the worst-case payload is an answer of 27,720 bytes" do
      id = String.duplicate(<<1>>, 128)

      worst =
        H.entry!(:answer, H.answer(id, id, id, actor: id, text: String.duplicate(<<0>>, 4096)))

      assert byte_size(Record.payload(worst)) == 27_720
      assert Record.max_payload_bytes() == 27_720

      input =
        H.entry!(
          :input,
          H.input(id, role: "source", actor: id, text: String.duplicate(<<0>>, 4096))
        )

      association = H.entry!(:association, H.association(id, id))

      shorter =
        H.entry!(:answer, H.answer(id, id, id, actor: id, text: String.duplicate(<<0>>, 4095)))

      for smaller <- [input, association, shorter] do
        assert byte_size(Record.payload(smaller)) < 27_720
      end

      for character <- [<<0x22>>, <<0x5C>>, <<0x1F>>, "é", <<0x7F>>] do
        text = String.duplicate(character, div(4096, byte_size(character)))
        entry = H.entry!(:answer, H.answer(id, id, id, actor: id, text: text))
        assert byte_size(Record.payload(entry)) <= 27_720
      end
    end

    test "malformed rows fail closed" do
      entry = H.entry!(:input, H.input("m", text: "abc"))
      valid = row(1, entry)
      assert {:ok, ^entry} = decode(valid)

      payloads = [
        "{",
        "[]",
        ~s({"message_id":"m","role":"user","actor":"host"}),
        ~s({"message_id":"m","role":"user","actor":"host","text":"abc","extra":"x"}),
        ~s({"message_id":"m","role":"user","actor":"host","txt":"abc"}),
        ~s({"role":"user","message_id":"m","actor":"host","text":"abc"}),
        ~s({"message_id":"m","message_id":"m","role":"user","actor":"host","text":"abc"}),
        ~s({"message_id":"m","role":"user","actor":"host","text":1}),
        ~s({"message_id":"m","role":"user","actor":"host","text":null}),
        ~s({"message_id":"m","role":"user","actor":"host","text":{"a":"b"}}),
        ~s({ "message_id":"m","role":"user","actor":"host","text":"abc"}),
        ~s({"message_id":"m","role":"user","actor":"host","text":"\\u0061bc"}),
        ~s({"message_id":"m","role":"user","actor":"host","text":"a\\/c"}),
        ~s({"message_id":"m","role":"user","actor":"host","text":"abc"} ),
        ~s({"message_id":"m\\u0000","role":"user","actor":"host","text":"abc"}),
        ~s({"message_id":"m","role":"assistant","actor":"host","text":"abc"}),
        ~s({"message_id":"m","role":"user","actor":"host","text":""}),
        ~s({"message_id":"m","role":"user","actor":"host","text":") <>
          String.duplicate("t", 4097) <> ~s("}),
        ~s({"message_id":"m","role":"user","actor":"host","text":") <> <<0xFF>> <> ~s("})
      ]

      for payload <- payloads do
        assert :error = decode(redigest(%{valid | payload: payload})), payload
      end

      assert :error = decode(redigest(%{valid | kind: Record.kind(:answer)}))
      assert :error = decode(redigest(%{valid | kind: "foreign"}))
      assert :error = decode(redigest(%{valid | schema_version: 2}), %{H.fold() | versions: [1, 2]})

      assert :error =
               decode(%{
                 valid
                 | payload: ~s({"message_id":"m","role":"user","actor":"host","text":"abd"})
               })

      assert :error = decode(%{valid | digest: :crypto.hash(:sha256, "other")})
      assert :error = decode(%{valid | nonce: <<1, 2>>} |> redigest())
      assert :error = decode(valid, H.fold(), 2)
      assert :error = Record.decode(valid, "conversation/tenant-1/other", 1, H.fold(), H.limits())
      assert :error = decode(:not_a_row)
    end

    test "a segment is 1..64 bytes of [A-Za-z0-9._-], never . or .., so a stream name is at most 142 bytes" do
      seg64 = String.duplicate("s", 64)

      for segment <- ["s", "tenant-1", "A.b_c-9", "...", ".a", "a..", seg64] do
        assert Record.segment?(segment), inspect(segment)
      end

      longest = Record.stream(seg64, seg64)
      assert byte_size(longest) == 142
      assert Elzoo.DurableLog.Codec.stream?(longest)

      for segment <- H.refused_segments() ++ [:segment, nil, ~c"segment"] do
        refute Record.segment?(segment), inspect(segment)
      end
    end
  end

  describe "fold" do
    test "generated histories fold to the reference model" do
      for seed <- 1..12 do
        :rand.seed(:exsss, {seed, 7, 19})
        operations = history(60)
        rows = rows(operations)

        assert {:ok, model, next} = History.fold_rows(History.new(), rows, context(), 1)
        assert next == length(rows) + 1
        assert model == reference(operations)
      end
    end

    test "the fold reports damage for a duplicate ID, an early reference, a double answer, a wrong stream or sequence and a bad digest" do
      assert {:ok, _, 1} = History.fold_rows(History.new(), [], context(), 1)

      base = [
        {:input, H.input("i1")},
        {:input, H.input("i2", role: "source")},
        {:association, H.association("i1", "run-a")},
        {:answer, H.answer("a1", "i1", "run-a")},
        {:association, H.association("i2", "run-a")}
      ]

      assert {:ok, _, 6} = History.fold_rows(History.new(), rows(base), context(), 1)

      histories = %{
        duplicate_input_id: base ++ [{:input, H.input("i1", text: "other")}],
        duplicate_answer_id_as_input: base ++ [{:input, H.input("a1")}],
        input_id_reused_by_answer: base ++ [{:answer, H.answer("i2", "i2", "run-a")}],
        identical_row_repeated: base ++ [{:input, H.input("i2", role: "source")}],
        association_before_input: [{:association, H.association("i1", "run-a")} | base],
        answer_before_association: [
          {:input, H.input("i1")},
          {:answer, H.answer("a1", "i1", "run-a")},
          {:association, H.association("i1", "run-a")}
        ],
        association_to_answer: base ++ [{:association, H.association("a1", "run-b")}],
        second_association: base ++ [{:association, H.association("i1", "run-b")}],
        double_answer: base ++ [{:answer, H.answer("a2", "i1", "run-a")}],
        answer_with_other_run: base ++ [{:answer, H.answer("a2", "i2", "run-b")}]
      }

      for {name, operations} <- histories do
        assert {:error, :damaged} = History.fold_rows(History.new(), rows(operations), context(), 1),
               inspect(name)
      end

      valid = rows(base)
      other_stream = Enum.map(valid, &redigest(%{&1 | stream: "conversation/tenant-1/other"}))
      gap = List.update_at(valid, 4, &redigest(%{&1 | sequence: 6}))
      repeat = List.insert_at(valid, 2, Enum.at(valid, 1))
      reordered = [Enum.at(valid, 1), Enum.at(valid, 0) | Enum.drop(valid, 2)]

      flipped =
        List.update_at(valid, 2, fn row ->
          %{row | payload: String.replace(row.payload, "run-a", "run-b")}
        end)

      for {name, rows} <- [
            other_stream: other_stream,
            gap: gap,
            repeat: repeat,
            reordered: reordered,
            flipped_payload_old_digest: flipped
          ] do
        assert {:error, :damaged} = History.fold_rows(History.new(), rows, context(), 1),
               inspect(name)
      end

      assert {:error, :damaged} =
               History.fold_rows(History.new(), Enum.drop(valid, 1), context(), 1)
    end
  end

  describe "decision" do
    test "today's precedence holds and the identical record is checked first" do
      model =
        fold!([
          {:input, H.input("i1")},
          {:input, H.input("i2", role: "source")},
          {:association, H.association("i1", "run-a")},
          {:answer, H.answer("a1", "i1", "run-a")},
          {:input, H.input("i3")},
          {:association, H.association("i3", "run-b")}
        ])

      cases = [
        {:input, H.input("i1"), true, :already_present},
        {:input, H.input("i1", text: "other"), true, {:refused, "duplicate_message_id"}},
        {:input, H.input("i1", role: "source"), true, {:refused, "duplicate_message_id"}},
        {:input, H.input("a1"), true, {:refused, "duplicate_message_id"}},
        {:input, H.input("i9"), true, :proceed},
        {:association, H.association("i1", "run-a"), true, :already_present},
        {:association, H.association("i1", "run-b"), true, {:refused, "already_associated"}},
        {:association, H.association("i9", "run-a"), true, {:refused, "missing_input"}},
        {:association, H.association("a1", "run-a"), true, {:refused, "missing_input"}},
        {:association, H.association("i2", "run-a"), true, :proceed},
        {:answer, H.answer("a1", "i1", "run-a"), true, :already_present},
        {:answer, H.answer("a1", "i1", "run-a", completed: false), false, :already_present},
        {:answer, H.answer("a1", "i1", "run-a", text: "other"), true,
         {:refused, "duplicate_message_id"}},
        {:answer, H.answer("i2", "i9", "run-x", completed: false), false,
         {:refused, "duplicate_message_id"}},
        {:answer, H.answer("a9", "i9", "run-x", completed: false), false,
         {:refused, "run_not_completed"}},
        {:answer, H.answer("a9", "i9", "run-x"), true, {:refused, "missing_input"}},
        {:answer, H.answer("a9", "a1", "run-a"), true, {:refused, "missing_input"}},
        {:answer, H.answer("a9", "i2", "run-a"), true, {:refused, "association_mismatch"}},
        {:answer, H.answer("a9", "i1", "run-b"), true, {:refused, "association_mismatch"}},
        {:answer, H.answer("a9", "i1", "run-a"), true, {:refused, "already_answered"}},
        {:answer, H.answer("a9", "i3", "run-b"), true, :proceed}
      ]

      for {mode, dto, completed, expected} <- cases do
        {:ok, entry, ^completed} = Record.intent(mode, dto)
        assert History.decide(model, entry, completed) == expected, inspect({mode, dto})
      end
    end

    test "the compiled Cure table equals the stated precedence for every combination of checks" do
      names = [
        :identical,
        :duplicate_message_id,
        :input_exists,
        :input_is_input,
        :already_associated,
        :association_exists,
        :association_matches,
        :already_answered,
        :completed
      ]

      for mode <- [:input, :association, :answer], bits <- 0..511 do
        checks =
          names
          |> Enum.with_index()
          |> Map.new(fn {name, index} -> {name, Bitwise.band(bits, Bitwise.bsl(1, index)) != 0} end)

        assert History.decision(mode, checks) == precedence(mode, checks), inspect({mode, checks})
      end
    end

    test "check decides intents in order against a copy of the model" do
      model = fold!([{:input, H.input("i1")}])

      intents = [
        {:input, H.input("i2")},
        {:association, H.association("i2", "run-a")},
        {:answer, H.answer("a2", "i2", "run-a")},
        {:input, H.input("i1")},
        {:input, H.input("i2", text: "other")},
        {:answer, H.answer("a3", "i1", "run-a")},
        {:input, %{}}
      ]

      prepared =
        Enum.map(intents, fn {mode, dto} ->
          case Record.intent(mode, dto) do
            {:ok, entry, completed} -> {:ok, entry, completed}
            :error -> :invalid
          end
        end)

      assert History.check(model, prepared) == [
               :ok,
               :ok,
               :ok,
               {:ok, :already_present},
               {:refused, "duplicate_message_id"},
               {:refused, "association_mismatch"},
               {:refused, "invalid_request"}
             ]

      assert model == fold!([{:input, H.input("i1")}])
    end
  end

  describe "version 1 rules" do
    test "a version 1 snapshot parses to its ordered messages and associations" do
      snapshot =
        H.v1_snapshot(
          [
            H.v1_input("i1", "q1"),
            H.v1_input("i2", "q2\0", "source", "actor-2"),
            H.v1_answer("a1", "i1", "run-1", "answer")
          ],
          [H.v1_association("i2", "run-1"), H.v1_association("i1", "run-1")]
        )

      assert {:ok,
              %{
                messages: [
                  %{message_id: "i1", role: "user", actor: "host", text: "q1"},
                  %{message_id: "i2", role: "source", actor: "actor-2", text: "q2\0"},
                  %{
                    message_id: "a1",
                    role: "assistant",
                    actor: "host",
                    text: "answer",
                    run_id: "run-1",
                    input_message_id: "i1"
                  }
                ],
                associations: [
                  %{input_message_id: "i2", run_id: "run-1"},
                  %{input_message_id: "i1", run_id: "run-1"}
                ]
              }} = V1.parse(snapshot)

      assert {:ok, %{messages: [], associations: []}} =
               V1.parse(%{tenant: "t", resource: "r", revision: 0, fields: %{}})
    end

    test "version 1 validation is strict, canonical, bounded and fail-closed" do
      valid_input = H.v1_input("input-1", "question")
      valid_assoc = H.v1_association("input-1", "run-1")
      valid_answer = H.v1_answer("answer-1", "input-1", "run-1", "answer")
      record = &H.v1_record/1

      invalid_states = [
        record.([
          {"associations", {:list, []}},
          {"messages", {:list, [valid_input]}},
          {"version", 2}
        ]),
        record.([
          {"associations", {:list, []}},
          {"messages", {:list, [valid_input]}},
          {"version", nil}
        ]),
        record.([{"associations", {:list, []}}, {"messages", {:list, []}}, {"version", 1}]),
        {:record,
         [{"messages", {:list, [valid_input]}}, {"associations", {:list, []}}, {"version", 1}]},
        H.v1_state([H.v1_input("input-1", "q", "admin")], []),
        H.v1_state([H.v1_input("input-1", "q"), H.v1_input("input-1", "q")], []),
        H.v1_state([valid_input], [valid_assoc, valid_assoc]),
        H.v1_state([valid_input], [H.v1_association("missing", "run-1")]),
        H.v1_state([H.v1_input("input-1", "q"), valid_answer], [
          H.v1_association("answer-1", "run-1")
        ]),
        H.v1_state([H.v1_input("input-1", "q"), valid_answer], []),
        H.v1_state([H.v1_input("input-1", "q"), valid_answer], [
          H.v1_association("input-1", "run-2")
        ]),
        H.v1_state([valid_answer, valid_input], [valid_assoc]),
        H.v1_state(
          [valid_input, valid_answer, H.v1_answer("answer-2", "input-1", "run-1", "second")],
          [valid_assoc]
        ),
        record.([
          {"associations", {:list, []}},
          {"messages", {:list, [valid_input | :improper]}},
          {"version", 1}
        ]),
        H.v1_state([H.v1_input("input-1", String.duplicate("x", 4097))], []),
        H.v1_state([H.v1_input("input-1\0", "q")], []),
        H.v1_state([H.v1_input(String.duplicate("i", 129), "q")], []),
        record.([
          {"associations", {:list, []}},
          {"messages", {:list, [valid_input]}},
          {"version", 1},
          {"unknown", true}
        ]),
        H.v1_state(Enum.map(1..65, &H.v1_input("input-#{&1}", "q")), [])
      ]

      for state <- invalid_states do
        assert {:error, :invalid_snapshot} =
                 V1.parse(%{
                   tenant: "t",
                   resource: "r",
                   revision: 1,
                   fields: %{"conversation" => state}
                 }),
               inspect(state)
      end

      state = H.v1_state([valid_input], [])

      for snapshot <- [
            %{tenant: "t", resource: "r", revision: 0, fields: %{"conversation" => state}},
            %{tenant: "t", resource: "r", revision: 1, fields: %{}},
            %{
              tenant: "t",
              resource: "r",
              revision: 1,
              fields: %{"conversation" => state, "other" => true}
            },
            %{
              tenant: "t",
              resource: "r",
              revision: 1,
              fields: %{"conversation" => state},
              extra: 1
            },
            %{tenant: "t\0", resource: "r", revision: 1, fields: %{"conversation" => state}},
            %{tenant: "t", resource: "r", revision: -1, fields: %{"conversation" => state}},
            :not_a_snapshot
          ] do
        assert {:error, :invalid_snapshot} = V1.parse(snapshot), inspect(snapshot)
      end
    end

    test "version 1 accepts exactly the encoded state bound and refuses one byte over" do
      existing = Enum.map(1..15, &H.v1_input("input-#{&1}", String.duplicate("x", 4096)))

      base =
        byte_size(
          :erlang.term_to_binary(H.v1_state(existing ++ [H.v1_input("input-final", "")], []))
        )

      exact = 65_536 - base
      assert exact in 1..4095

      at_bound =
        H.v1_state(existing ++ [H.v1_input("input-final", String.duplicate("x", exact))], [])

      over =
        H.v1_state(existing ++ [H.v1_input("input-final", String.duplicate("x", exact + 1))], [])

      assert byte_size(:erlang.term_to_binary(at_bound)) == 65_536
      assert byte_size(:erlang.term_to_binary(over)) == 65_537

      assert {:ok, %{messages: messages}} =
               V1.parse(%{
                 tenant: "t",
                 resource: "r",
                 revision: 16,
                 fields: %{"conversation" => at_bound}
               })

      assert length(messages) == 16

      assert {:error, :invalid_snapshot} =
               V1.parse(%{
                 tenant: "t",
                 resource: "r",
                 revision: 16,
                 fields: %{"conversation" => over}
               })
    end
  end

  # A random valid history: inputs of both roles, associations that share Runs,
  # answers of associated inputs.
  defp history(count) do
    initial = %{inputs: [], runs: %{}, answered: MapSet.new()}

    {operations, _state} =
      Enum.reduce(1..count, {[], initial}, fn index, {operations, s} ->
        unassociated = Enum.reject(s.inputs, &Map.has_key?(s.runs, &1))
        open = s.runs |> Map.keys() |> Enum.sort() |> Enum.reject(&MapSet.member?(s.answered, &1))

        choice =
          if s.inputs == [], do: :input, else: Enum.random([:input, :input, :association, :answer])

        case choice do
          :association when unassociated != [] ->
            input = Enum.random(unassociated)
            run = "run-#{:rand.uniform(4)}"

            {[{:association, H.association(input, run)} | operations],
             %{s | runs: Map.put(s.runs, input, run)}}

          :answer when open != [] ->
            input = Enum.random(open)
            answer = H.answer("answer-#{index}", input, Map.fetch!(s.runs, input))
            {[{:answer, answer} | operations], %{s | answered: MapSet.put(s.answered, input)}}

          _ ->
            id = "input-#{index}"
            dto = H.input(id, role: Enum.random(["user", "source"]), text: "text #{index}\0")
            {[{:input, dto} | operations], %{s | inputs: [id | s.inputs]}}
        end
      end)

    Enum.reverse(operations)
  end

  defp reference(operations) do
    Enum.reduce(operations, %{messages: %{}, inputs: %{}}, fn
      {:input, dto}, model ->
        digest = :crypto.hash(:sha256, Record.payload(H.entry!(:input, dto)))

        %{
          model
          | messages: Map.put(model.messages, dto.message_id, {:input, digest}),
            inputs: Map.put(model.inputs, dto.message_id, {nil, false})
        }

      {:association, dto}, model ->
        %{model | inputs: Map.put(model.inputs, dto.input_message_id, {dto.run_id, false})}

      {:answer, dto}, model ->
        digest = :crypto.hash(:sha256, Record.payload(H.entry!(:answer, dto)))

        %{
          model
          | messages: Map.put(model.messages, dto.message_id, {:answer, digest}),
            inputs: Map.put(model.inputs, dto.input_message_id, {dto.run_id, true})
        }
    end)
  end

  defp precedence(mode, c) do
    cond do
      c.identical ->
        :already_present

      mode == :input and c.duplicate_message_id ->
        {:refused, "duplicate_message_id"}

      mode == :input ->
        :proceed

      mode == :association and not (c.input_exists and c.input_is_input) ->
        {:refused, "missing_input"}

      mode == :association and c.already_associated ->
        {:refused, "already_associated"}

      mode == :association ->
        :proceed

      c.duplicate_message_id ->
        {:refused, "duplicate_message_id"}

      not c.completed ->
        {:refused, "run_not_completed"}

      not (c.input_exists and c.input_is_input) ->
        {:refused, "missing_input"}

      not (c.association_exists and c.association_matches) ->
        {:refused, "association_mismatch"}

      c.already_answered ->
        {:refused, "already_answered"}

      true ->
        :proceed
    end
  end

  defp fold!(operations) do
    {:ok, model, _} = History.fold_rows(History.new(), rows(operations), context(), 1)
    model
  end

  defp rows(operations) do
    operations
    |> Enum.with_index(1)
    |> Enum.map(fn {{mode, dto}, sequence} -> row(sequence, H.entry!(mode, dto)) end)
  end

  defp row(sequence, entry), do: Record.row(@stream, sequence, entry, :crypto.strong_rand_bytes(16))

  defp redigest(row), do: %{row | digest: Log.digest(row)}

  defp context, do: %{stream: @stream, fold: H.fold(), limits: H.limits()}

  defp decode(row, fold \\ H.fold(), sequence \\ 1),
    do: Record.decode(row, @stream, sequence, fold, H.limits())

  defp trim_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end
end
