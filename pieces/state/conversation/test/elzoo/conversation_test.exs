# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ConversationTest.StructValue do
  defstruct [:tenant, :resource, :revision, :fields]
end

defmodule Elzoo.ConversationTest.RequestValue do
  defstruct [:operation_id, :resource, :expected_revision, :payload]
end

defmodule Elzoo.ConversationTest.FactsValue do
  defstruct [:tenant, :actor, :data]
end

defmodule Elzoo.ConversationTest.ScopeValue do
  defstruct [:tenant, :actor, :resources]
end

defmodule Elzoo.ConversationTest do
  use ExUnit.Case, async: true

  alias Elzoo.Conversation

  @tenant "tenant-a"
  @resource "conversation-a"
  @max_revision 9_223_372_036_854_775_807
  @max_expected_revision @max_revision - 1

  test "prepares, reconstructs and projects immutable messages across Runs" do
    empty = snapshot()

    {one, write, response} =
      successful_step(
        empty,
        append_input(empty, "input-1", "First\0 input", role: "user", actor: "person-1")
      )

    assert write.target == @resource
    assert write.field == "conversation"
    assert Enum.sort(Map.keys(write)) == [:field, :target, :value]
    assert response == record([{"message_id", text("input-1")}, {"revision", 1}])

    {two, _write, response} = successful_step(one, associate(one, "input-1", "run-1"))

    assert response ==
             record([{"message_id", text("input-1")}, {"revision", 2}, {"run_id", text("run-1")}])

    {three, _write, answer_response} =
      successful_step(
        two,
        append_answer(two, "answer-1", "input-1", "run-1", "First answer", actor: "run-host")
      )

    assert answer_response ==
             record([
               {"input_message_id", text("input-1")},
               {"message_id", text("answer-1")},
               {"revision", 3},
               {"run_id", text("run-1")}
             ])

    {four, _write, _response} =
      successful_step(three, append_input(three, "input-2", "Second input", role: "source"))

    {five, _write, _response} = successful_step(four, associate(four, "input-2", "run-1"))

    {six, _write, _response} =
      successful_step(five, append_answer(five, "answer-2", "input-2", "run-1", "Second answer"))

    {seven, _write, _response} = successful_step(six, append_input(six, "input-3", "Third input"))
    {eight, _write, _response} = successful_step(seven, associate(seven, "input-3", "run-2"))

    {nine, _write, _response} =
      successful_step(eight, append_answer(eight, "answer-3", "input-3", "run-2", "Third answer"))

    assert nine.revision == 9

    assert {:ok, view} =
             Conversation.view(nine, %{tenant: @tenant, actor: "reader", resources: [@resource]})

    assert Enum.map(view.messages, &{&1.message_id, &1.role, &1.text}) == [
             {"input-1", "user", "First\0 input"},
             {"answer-1", "assistant", "First answer"},
             {"input-2", "source", "Second input"},
             {"answer-2", "assistant", "Second answer"},
             {"input-3", "user", "Third input"},
             {"answer-3", "assistant", "Third answer"}
           ]

    assert Enum.map(view.messages, & &1.actor) == [
             "person-1",
             "run-host",
             "host",
             "host",
             "host",
             "host"
           ]

    assert view.associations == [
             %{input_message_id: "input-1", run_id: "run-1"},
             %{input_message_id: "input-2", run_id: "run-1"},
             %{input_message_id: "input-3", run_id: "run-2"}
           ]

    assert view.tenant == @tenant
    assert view.resource == @resource
    assert view.revision == 9

    assert Map.keys(view) |> Enum.sort() == [
             :associations,
             :messages,
             :resource,
             :revision,
             :tenant
           ]

    {:record, state_fields} = nine.fields["conversation"]
    assert Enum.map(state_fields, &elem(&1, 0)) == ["associations", "messages", "version"]
  end

  test "accepts the exact DTOs and facts schema, and rejects extra or forged controls" do
    initial = snapshot()
    input_data = [{"mode", text("append_input")}, {"input_role", text("user")}]
    unsorted_facts = %{tenant: @tenant, actor: "host", data: {:record, Enum.reverse(input_data)}}
    input_request = request(initial, %{"message_id" => "input-1", "text" => "text"})

    assert {:ok, [_write], _response} = Conversation.prepare(initial, input_request, unsorted_facts)

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(
               initial,
               input_request,
               struct(Elzoo.ConversationTest.FactsValue,
                 tenant: @tenant,
                 actor: "host",
                 data: {:record, input_data}
               )
             )

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(
               initial,
               input_request,
               Map.put(unsorted_facts, :principal, "forged")
             )

    assert {:refused, "invalid_facts"} =
             prepare_with_data(initial, input_request, [
               {"mode", text("append_input")},
               {"input_role", text("assistant")}
             ])

    assert {:refused, "invalid_facts"} =
             prepare_with_data(initial, input_request, input_data ++ [{"actor", text("forged")}])

    assert {:refused, "invalid_facts"} =
             prepare_with_data(initial, input_request, [
               {"mode", text("append_input")},
               {"input_role", text("user")},
               {"mode", text("append_input")}
             ])

    assert {:refused, "invalid_facts"} =
             prepare_with_data(initial, input_request, [{"mode", text("append_input")}])

    assert {:refused, "invalid_facts"} =
             prepare_with_data(initial, input_request, [
               {"mode", "append_input"},
               {"input_role", text("user")}
             ])

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(initial, input_request, %{
               tenant: @tenant,
               actor: "host",
               data: %{"mode" => "append_input"}
             })

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(initial, input_request, %{
               tenant: @tenant,
               actor: "",
               data: facts_data("append_input", input_role: "user")
             })

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(initial, input_request, %{
               tenant: @tenant,
               actor: "host\0",
               data: facts_data("append_input", input_role: "user")
             })

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(
               initial,
               input_request,
               %{
                 tenant: @tenant,
                 actor: String.duplicate("a", 129),
                 data: facts_data("append_input", input_role: "user")
               }
             )

    assert {:refused, "invalid_facts"} =
             Conversation.prepare(
               initial,
               input_request,
               struct(Elzoo.ConversationTest.StructValue,
                 tenant: @tenant,
                 resource: @resource,
                 revision: 0,
                 fields: %{}
               )
             )

    answer_snapshot = associated_snapshot()
    answer_request = request(answer_snapshot, %{"message_id" => "answer-1", "text" => "answer"})

    assert {:refused, "invalid_facts"} =
             prepare_with_data(answer_snapshot, answer_request, [
               {"mode", text("append_answer")},
               {"run_id", text("run-1")},
               {"input_message_id", text("input-1")},
               {"completed", 1}
             ])

    associate_request = request(initial, %{"message_id" => "input-1"})

    assert {:refused, "invalid_facts"} =
             prepare_with_data(associated_snapshot(), associate_request, [
               {"mode", text("associate_run")},
               {"run_id", text("run-1")},
               {"extra", text("control")}
             ])
  end

  test "bounds and validates IDs and text by UTF-8 byte length without normalizing text" do
    initial = snapshot()
    id128 = String.duplicate("i", 128)
    id128_unicode = String.duplicate("é", 64)
    text4096 = String.duplicate("é", 2048)

    assert byte_size(id128_unicode) == 128
    assert byte_size(text4096) == 4096
    assert {:ok, [_write], _response} = append_input(initial, id128, "x")
    assert {:ok, [_write], _response} = append_input(initial, id128_unicode, "x")
    assert {:ok, [_write], _response} = append_input(initial, "input-1", text4096)
    assert {:ok, [_write], _response} = append_input(initial, "input-1", "x\0y")

    assert {:refused, "invalid_request"} = append_input(initial, String.duplicate("i", 129), "x")

    assert {:refused, "invalid_request"} =
             append_input(initial, String.duplicate("é", 64) <> "a", "x")

    assert {:refused, "invalid_request"} = append_input(initial, "input-1\0", "x")
    assert {:refused, "invalid_request"} = append_input(initial, <<255>>, "x")
    assert {:refused, "invalid_request"} = append_input(initial, "input-1", "")
    assert {:refused, "invalid_request"} = append_input(initial, "input-1", text4096 <> "a")
    assert {:refused, "invalid_request"} = append_input(initial, "input-1", <<255>>)

    original_text = "é" <> "é"
    assert {:ok, [write], _response} = append_input(initial, "input-1", original_text)
    assert {:record, state_fields} = write.value
    {:list, [message]} = Map.fetch!(Map.new(state_fields), "messages")
    assert {:record, message_fields} = message
    assert Map.fetch!(Map.new(message_fields), "text") == text(original_text)
  end

  test "accepts 128-byte IDs in every trusted DTO slot" do
    id = String.duplicate("i", 128)
    initial = %{tenant: id, resource: id, revision: 0, fields: %{}}

    request = %{
      operation_id: id,
      resource: id,
      expected_revision: 0,
      payload: %{"message_id" => id, "text" => "x"}
    }

    facts = %{tenant: id, actor: id, data: facts_data("append_input", input_role: "user")}

    assert {:ok, [write], response} = Conversation.prepare(initial, request, facts)

    stored = %{
      initial
      | revision: response_field(response, "revision"),
        fields: %{"conversation" => write.value}
    }

    association_request = %{
      operation_id: id,
      resource: id,
      expected_revision: stored.revision,
      payload: %{"message_id" => id}
    }

    association_facts = %{
      tenant: id,
      actor: id,
      data: record([{"mode", text("associate_run")}, {"run_id", text(id)}])
    }

    assert {:ok, [association_write], association_response} =
             Conversation.prepare(stored, association_request, association_facts)

    assert response_field(association_response, "run_id") == text(id)

    stored = %{
      stored
      | revision: response_field(association_response, "revision"),
        fields: %{"conversation" => association_write.value}
    }

    assert {:ok, _view} = Conversation.view(stored, %{tenant: id, actor: id, resources: [id]})
  end

  test "enforces exact request maps and the resource revision range" do
    initial = snapshot()
    valid_facts = facts("append_input", [])
    valid_request = request(initial, %{"message_id" => "input-1", "text" => "x"})

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               Map.put(valid_request, :unknown, "sentinel"),
               valid_facts
             )

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               struct(Elzoo.ConversationTest.StructValue,
                 tenant: @tenant,
                 resource: @resource,
                 revision: 0,
                 fields: %{}
               ),
               valid_facts
             )

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               struct(Elzoo.ConversationTest.RequestValue,
                 operation_id: "operation-1",
                 resource: @resource,
                 expected_revision: 0,
                 payload: %{"message_id" => "input-1", "text" => "x"}
               ),
               valid_facts
             )

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               %{valid_request | payload: %{:message_id => "input-1", "text" => "x"}},
               valid_facts
             )

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               %{
                 valid_request
                 | payload: %{"message_id" => "input-1", "text" => "x", "role" => "assistant"}
               },
               valid_facts
             )

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               request(initial, %{"input_message_id" => "input-1"}),
               facts("associate_run", run_id: "run-1")
             )

    assert {:refused, "invalid_request"} =
             Conversation.prepare(initial, %{valid_request | expected_revision: -1}, valid_facts)

    assert {:refused, "invalid_request"} =
             Conversation.prepare(
               initial,
               %{valid_request | expected_revision: @max_revision},
               valid_facts
             )

    at_max = snapshot_with_state([input("old", "old")], [], @max_expected_revision)

    assert {:ok, [_write], response} =
             append_input(at_max, "new", "text", expected_revision: @max_expected_revision)

    assert response_field(response, "revision") == @max_revision

    assert {:refused, "stale_revision"} =
             append_input(
               snapshot_with_state([input("old", "old")], [], @max_revision),
               "new",
               "text",
               expected_revision: @max_expected_revision
             )

    assert {:error, :invalid_snapshot} =
             Conversation.view(%{at_max | revision: @max_revision + 1}, %{
               tenant: @tenant,
               actor: "reader",
               resources: [@resource]
             })

    assert {:refused, "stale_revision"} =
             append_input(snapshot_with_state([input("old", "old")], [], 10), "new", "text",
               expected_revision: 9
             )
  end

  test "uses the specified prepare refusal order without exposing unscoped state" do
    empty = snapshot(fields: :malformed)

    bad_request =
      request(snapshot(), %{"message_id" => "input-1", "text" => "x"}) |> Map.put(:extra, true)

    mismatched_facts = %{facts("append_input", []) | tenant: "another-tenant"}

    assert {:refused, "invalid_facts"} = Conversation.prepare(empty, bad_request, %{})
    assert {:refused, "invalid_scope"} = Conversation.prepare(empty, bad_request, mismatched_facts)

    assert {:refused, "invalid_request"} =
             Conversation.prepare(empty, bad_request, facts("append_input", []))

    valid_route_bad_state = %{snapshot() | fields: :malformed}

    assert {:refused, "invalid_snapshot"} =
             Conversation.prepare(
               valid_route_bad_state,
               request(valid_route_bad_state, %{"message_id" => "input-1", "text" => "x"}, 9),
               facts("append_input", [])
             )

    associated = associated_snapshot()

    assert {:refused, "stale_revision"} =
             append_answer(associated, "answer-1", "input-1", "wrong-run", "answer",
               completed: false,
               expected_revision: 0
             )

    assert {:refused, "run_not_completed"} =
             append_answer(associated, "answer-1", "input-1", "run-1", "answer", completed: false)
  end

  @tag :duplicate_message_id_control
  test "rejects all duplicate IDs across roles, whether equal or changed" do
    initial = snapshot()

    {with_input, _write, _response} =
      successful_step(initial, append_input(initial, "shared-id", "same"))

    assert {:refused, "duplicate_message_id"} = append_input(with_input, "shared-id", "same")
    assert {:refused, "duplicate_message_id"} = append_input(with_input, "shared-id", "changed")

    with_answer =
      snapshot_with_state(
        [input("input-1", "question"), answer("shared-id", "input-1", "run-1", "answer")],
        [association("input-1", "run-1")]
      )

    assert {:refused, "duplicate_message_id"} =
             append_input(with_answer, "shared-id", "different role")

    assert {:refused, "duplicate_message_id"} =
             append_answer(with_answer, "shared-id", "input-1", "run-1", "same")
  end

  @tag :run_input_association_control
  test "refuses an answer whose trusted Run does not match the stored input association" do
    associated = associated_snapshot()

    assert {:refused, "association_mismatch"} =
             append_answer(associated, "answer-1", "input-1", "run-2", "answer")
  end

  test "Cure applies input, association, completion, match and answered refusals" do
    initial = snapshot()

    {with_input, _write, _response} =
      successful_step(initial, append_input(initial, "input-1", "question"))

    assert {:refused, "missing_input"} = associate(with_input, "missing", "run-1")
    assert {:ok, [_write], _response} = associate(with_input, "input-1", "run-1")

    {associated, _write, _response} =
      successful_step(with_input, associate(with_input, "input-1", "run-1"))

    assert {:refused, "already_associated"} = associate(associated, "input-1", "run-2")

    non_input =
      snapshot_with_state(
        [input("input-1", "question"), answer("answer-1", "input-1", "run-1", "answer")],
        [association("input-1", "run-1")]
      )

    assert {:refused, "missing_input"} = associate(non_input, "answer-1", "run-2")

    assert {:refused, "association_mismatch"} =
             append_answer(associated, "answer-1", "input-1", "run-2", "answer")

    assert {:refused, "missing_input"} =
             append_answer(associated, "answer-1", "absent", "run-1", "answer")

    {answered, _write, _response} =
      successful_step(
        associated,
        append_answer(associated, "answer-1", "input-1", "run-1", "answer")
      )

    assert {:refused, "already_answered"} =
             append_answer(answered, "answer-2", "input-1", "run-1", "another answer")

    assert {:refused, "duplicate_message_id"} =
             append_answer(answered, "input-1", "input-1", "run-1", "cross-role duplicate")
  end

  test "snapshot validation is strict, canonical, bounded and fail-closed" do
    valid_input = input("input-1", "question")
    valid_assoc = association("input-1", "run-1")
    valid_answer = answer("answer-1", "input-1", "run-1", "answer")

    invalid_states = [
      record([{"associations", list([])}, {"messages", list([valid_input])}, {"version", 2}]),
      record([{"associations", list([])}, {"messages", list([])}, {"version", 1}]),
      {:record, [{"messages", list([valid_input])}, {"associations", list([])}, {"version", 1}]},
      {:record, [{"associations", list([])}, {"associations", list([])}, {"version", 1}]},
      record([
        {"associations", list([])},
        {"messages",
         list([
           record([
             {"actor", text("host")},
             {"extra", text("x")},
             {"message_id", text("input-1")},
             {"role", text("user")},
             {"text", text("question")}
           ])
         ])},
        {"version", 1}
      ]),
      record([
        {"associations", list([])},
        {"messages", list([input("input-1", "q", "admin")])},
        {"version", 1}
      ]),
      record([
        {"associations", list([])},
        {"messages", list([input("input-1", "q"), input("input-1", "q")])},
        {"version", 1}
      ]),
      record([
        {"associations", list([valid_assoc, valid_assoc])},
        {"messages", list([valid_input])},
        {"version", 1}
      ]),
      record([
        {"associations", list([association("missing", "run-1")])},
        {"messages", list([valid_input])},
        {"version", 1}
      ]),
      record([
        {"associations", list([association("answer-1", "run-1")])},
        {"messages", list([input("input-1", "q"), valid_answer])},
        {"version", 1}
      ]),
      record([
        {"associations", list([])},
        {"messages", list([input("input-1", "q"), valid_answer])},
        {"version", 1}
      ]),
      record([
        {"associations", list([association("input-1", "run-2")])},
        {"messages", list([input("input-1", "q"), valid_answer])},
        {"version", 1}
      ]),
      record([
        {"associations", list([valid_assoc])},
        {"messages", list([valid_answer, valid_input])},
        {"version", 1}
      ]),
      record([
        {"associations", list([valid_assoc])},
        {"messages",
         list([valid_input, valid_answer, answer("answer-2", "input-1", "run-1", "second")])},
        {"version", 1}
      ]),
      record([
        {"associations", list([])},
        {"messages",
         list([
           {:record,
            [
              {"message_id", text("id")},
              {"role", text("user")},
              {"actor", text("actor")},
              {"text", nil}
            ]}
         ])},
        {"version", 1}
      ]),
      record([
        {"associations", list([])},
        {"messages", {:list, [valid_input | :improper]}},
        {"version", 1}
      ]),
      record([
        {"associations", {:list, [valid_assoc | :improper]}},
        {"messages", list([valid_input])},
        {"version", 1}
      ]),
      state_value([input("input-1", String.duplicate("x", 4097))], []),
      state_value([input("input-1\0", "q")], []),
      state_value([input(String.duplicate("i", 129), "q")], []),
      record([
        {"associations", list([])},
        {"messages", list([valid_input])},
        {"version", 1},
        {"unknown", true}
      ])
    ]

    for malformed <- invalid_states do
      assert {:error, :invalid_snapshot} = view_state(malformed), inspect(malformed)
    end

    assert {:error, :invalid_snapshot} =
             Conversation.view(
               %{
                 snapshot()
                 | revision: 0,
                   fields: %{"conversation" => state_value([valid_input], [])}
               },
               read_scope()
             )

    assert {:error, :invalid_snapshot} =
             Conversation.view(%{snapshot() | revision: 1, fields: %{}}, read_scope())

    assert {:error, :invalid_snapshot} =
             Conversation.view(
               %{
                 snapshot()
                 | revision: 1,
                   fields: %{"conversation" => state_value([valid_input], []), "other" => true}
               },
               read_scope()
             )
  end

  test "view validates scope before malformed fields and enforces the proper bounded resource list" do
    malformed = snapshot(fields: :malformed)

    assert {:error, :invalid_snapshot} =
             Conversation.view(
               struct(Elzoo.ConversationTest.StructValue,
                 tenant: @tenant,
                 resource: @resource,
                 revision: 0,
                 fields: %{}
               ),
               read_scope()
             )

    assert {:error, :invalid_scope} =
             Conversation.view(
               snapshot(),
               struct(Elzoo.ConversationTest.ScopeValue,
                 tenant: @tenant,
                 actor: "reader",
                 resources: [@resource]
               )
             )

    assert :not_found =
             Conversation.view(%{malformed | tenant: "another-tenant"}, %{
               tenant: @tenant,
               actor: "reader",
               resources: [@resource]
             })

    assert :not_found =
             Conversation.view(malformed, %{
               tenant: @tenant,
               actor: "reader",
               resources: ["other-resource"]
             })

    assert {:error, :invalid_scope} =
             Conversation.view(malformed, %{tenant: @tenant, actor: "", resources: [@resource]})

    assert {:error, :invalid_scope} =
             Conversation.view(malformed, %{
               tenant: @tenant,
               actor: "reader",
               resources: [@resource | :improper]
             })

    allowed = Enum.map(1..63, &"resource-#{&1}") ++ [@resource]

    assert {:ok, _view} =
             Conversation.view(snapshot(), %{tenant: @tenant, actor: "reader", resources: allowed})

    too_many = [@resource | Enum.map(1..64, &"resource-#{&1}")]

    assert {:error, :invalid_scope} =
             Conversation.view(snapshot(), %{tenant: @tenant, actor: "reader", resources: too_many})

    assert {:error, :invalid_scope} =
             Conversation.view(snapshot(), %{
               tenant: @tenant,
               actor: "reader",
               resources: [String.duplicate("r", 129)]
             })

    assert {:error, :invalid_scope} =
             Conversation.view(snapshot(), Map.put(read_scope(), :unknown, true))
  end

  test "enforces message and association container bounds without truncation" do
    messages = Enum.map(1..64, &input("input-#{&1}", "question"))
    full_messages = snapshot_with_state(messages, [], 10)
    before = :erlang.term_to_binary(full_messages)

    assert {:refused, "capacity"} = append_input(full_messages, "input-65", "new")
    assert :erlang.term_to_binary(full_messages) == before

    assert {:error, :invalid_snapshot} =
             view_state(state_value(messages ++ [input("input-65", "extra")], []))

    associations = Enum.map(1..64, &association("input-#{&1}", "run-shared"))
    full_associations = snapshot_with_state(messages, associations, 11)

    assert {:ok, full_view} = Conversation.view(full_associations, read_scope())
    assert length(full_view.messages) == 64
    assert length(full_view.associations) == 64

    assert {:error, :invalid_snapshot} =
             view_state(
               state_value(messages, associations ++ [association("input-1", "run-other")])
             )
  end

  test "accepts exactly the encoded state bound and refuses one byte over" do
    existing_messages = Enum.map(1..15, &input("input-#{&1}", String.duplicate("x", 4096)))
    candidate = input("input-final", "")
    empty_text_state = state_value(existing_messages ++ [candidate], [])
    base_size = byte_size(:erlang.term_to_binary(empty_text_state))
    exact_text_size = 65_536 - base_size

    assert exact_text_size in 1..4096

    exact_snapshot = snapshot_with_state(existing_messages, [], 21)

    assert {:ok, [write], response} =
             append_input(exact_snapshot, "input-final", String.duplicate("x", exact_text_size))

    assert byte_size(:erlang.term_to_binary(write.value)) == 65_536
    reconstructed = apply_write(exact_snapshot, write, response)
    assert {:ok, _view} = Conversation.view(reconstructed, read_scope())

    over_text_size = exact_text_size + 1
    assert over_text_size <= 4096

    assert {:refused, "capacity"} =
             append_input(exact_snapshot, "input-final", String.duplicate("x", over_text_size))

    oversized =
      state_value(
        existing_messages ++ [input("input-final", String.duplicate("x", over_text_size))],
        []
      )

    assert byte_size(:erlang.term_to_binary(oversized)) == 65_537
    assert {:error, :invalid_snapshot} = view_state(oversized)
    assert exact_snapshot == snapshot_with_state(existing_messages, [], 21)
  end

  defp append_input(snapshot, message_id, message_text, opts \\ []) do
    request_opts = Keyword.take(opts, [:expected_revision])
    facts_opts = Keyword.take(opts, [:actor, :role])

    attempt(
      snapshot,
      "append_input",
      %{"message_id" => message_id, "text" => message_text},
      request_opts,
      facts_opts
    )
  end

  defp append_answer(snapshot, message_id, input_id, run_id, message_text, opts \\ []) do
    request_opts = Keyword.take(opts, [:expected_revision])

    facts_opts =
      [run_id: run_id, input_message_id: input_id] ++ Keyword.take(opts, [:completed, :actor])

    attempt(
      snapshot,
      "append_answer",
      %{"message_id" => message_id, "text" => message_text},
      request_opts,
      facts_opts
    )
  end

  defp associate(snapshot, input_id, run_id, opts \\ []) do
    attempt(
      snapshot,
      "associate_run",
      %{"message_id" => input_id},
      Keyword.take(opts, [:expected_revision]),
      run_id: run_id
    )
  end

  defp attempt(snapshot, mode, payload, request_opts, facts_opts) do
    request =
      request(snapshot, payload, Keyword.get(request_opts, :expected_revision, snapshot.revision))

    Conversation.prepare(snapshot, request, facts(mode, facts_opts))
  end

  defp successful_step(snapshot, {:ok, [write], response}) do
    {apply_write(snapshot, write, response), write, response}
  end

  defp facts(mode, opts) do
    pairs = [{"mode", text(mode)} | fact_pairs(mode, opts)]
    %{tenant: @tenant, actor: Keyword.get(opts, :actor, "host"), data: {:record, pairs}}
  end

  defp fact_pairs("append_input", opts),
    do: [{"input_role", text(Keyword.get(opts, :role, "user"))}]

  defp fact_pairs("associate_run", opts), do: [{"run_id", text(Keyword.fetch!(opts, :run_id))}]

  defp fact_pairs("append_answer", opts) do
    [
      {"run_id", text(Keyword.fetch!(opts, :run_id))},
      {"input_message_id", text(Keyword.fetch!(opts, :input_message_id))},
      {"completed", Keyword.get(opts, :completed, true)}
    ]
  end

  defp facts_data(mode, opts) do
    {:record, Enum.sort_by([{"mode", text(mode)} | fact_pairs(mode, opts)], &elem(&1, 0))}
  end

  defp prepare_with_data(snapshot, request, pairs) do
    Conversation.prepare(snapshot, request, %{
      tenant: @tenant,
      actor: "host",
      data: {:record, pairs}
    })
  end

  defp request(snapshot, payload), do: request(snapshot, payload, snapshot.revision)

  defp request(snapshot, payload, expected_revision) do
    %{
      operation_id: "operation-1",
      resource: snapshot.resource,
      expected_revision: expected_revision,
      payload: payload
    }
  end

  defp snapshot(opts \\ []) do
    %{
      tenant: Keyword.get(opts, :tenant, @tenant),
      resource: @resource,
      revision: Keyword.get(opts, :revision, 0),
      fields: Keyword.get(opts, :fields, %{})
    }
  end

  defp snapshot_with_state(messages, associations, revision \\ 1) do
    %{
      tenant: @tenant,
      resource: @resource,
      revision: revision,
      fields: %{"conversation" => state_value(messages, associations)}
    }
  end

  defp associated_snapshot do
    snapshot_with_state([input("input-1", "question")], [association("input-1", "run-1")])
  end

  defp view_state(value) do
    Conversation.view(snapshot(revision: 1, fields: %{"conversation" => value}), read_scope())
  end

  defp read_scope, do: %{tenant: @tenant, actor: "reader", resources: [@resource]}

  defp apply_write(snapshot, write, response) do
    %{
      snapshot
      | revision: response_field(response, "revision"),
        fields: %{write.field => write.value}
    }
  end

  defp response_field({:record, pairs}, name) do
    {^name, value} = Enum.find(pairs, fn {field, _} -> field == name end)
    value
  end

  defp state_value(messages, associations) do
    record([
      {"associations", list(associations)},
      {"messages", list(messages)},
      {"version", 1}
    ])
  end

  defp input(id, message_text, role \\ "user", actor \\ "host") do
    record([
      {"actor", text(actor)},
      {"message_id", text(id)},
      {"role", text(role)},
      {"text", text(message_text)}
    ])
  end

  defp answer(id, input_id, run_id, message_text, actor \\ "host") do
    record([
      {"actor", text(actor)},
      {"input_message_id", text(input_id)},
      {"message_id", text(id)},
      {"role", text("assistant")},
      {"run_id", text(run_id)},
      {"text", text(message_text)}
    ])
  end

  defp association(input_id, run_id) do
    record([{"input_message_id", text(input_id)}, {"run_id", text(run_id)}])
  end

  defp record(pairs), do: {:record, Enum.sort_by(pairs, &elem(&1, 0))}
  defp text(value), do: {:text, value}
  defp list(values), do: {:list, values}
end
