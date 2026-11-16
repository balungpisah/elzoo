# SPDX-License-Identifier: Apache-2.0
defmodule ConversationExample do
  alias Elzoo.Conversation

  def run do
    snapshot = %{tenant: "tenant-1", resource: "conversation-1", revision: 0, fields: %{}}

    {:ok, [input_write], input_response} =
      Conversation.prepare(
        snapshot,
        request("op-1", 0, %{"message_id" => "input-1", "text" => "First"}),
        facts("append_input", "worker", input_role: "user")
      )

    snapshot = reconstruct(snapshot, input_write, input_response)

    {:ok, [association_write], association_response} =
      Conversation.prepare(
        snapshot,
        request("op-2", snapshot.revision, %{"message_id" => "input-1"}),
        facts("associate_run", "worker", run_id: "run-1")
      )

    snapshot = reconstruct(snapshot, association_write, association_response)

    {:ok, [answer_write], answer_response} =
      Conversation.prepare(
        snapshot,
        request("op-3", snapshot.revision, %{"message_id" => "answer-1", "text" => "First answer"}),
        facts("append_answer", "worker",
          run_id: "run-1",
          input_message_id: "input-1",
          completed: true
        )
      )

    snapshot = reconstruct(snapshot, answer_write, answer_response)

    Conversation.view(snapshot, %{
      tenant: "tenant-1",
      actor: "reader",
      resources: ["conversation-1"]
    })
  end

  defp request(operation_id, revision, payload) do
    %{
      operation_id: operation_id,
      resource: "conversation-1",
      expected_revision: revision,
      payload: payload
    }
  end

  defp facts(mode, actor, values) do
    data =
      values
      |> Enum.map(fn
        {:input_role, role} -> {"input_role", {:text, role}}
        {:run_id, run_id} -> {"run_id", {:text, run_id}}
        {:input_message_id, id} -> {"input_message_id", {:text, id}}
        {:completed, completed} -> {"completed", completed}
      end)
      |> then(&[{"mode", {:text, mode}} | &1])
      |> Enum.sort_by(&elem(&1, 0))

    %{tenant: "tenant-1", actor: actor, data: {:record, data}}
  end

  defp reconstruct(snapshot, write, response) do
    %{
      snapshot
      | revision: portable_field(response, "revision"),
        fields: %{write.field => write.value}
    }
  end

  defp portable_field({:record, fields}, key) do
    {^key, value} = Enum.find(fields, fn {name, _} -> name == key end)
    value
  end
end

IO.inspect(ConversationExample.run())
