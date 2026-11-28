# SPDX-License-Identifier: Apache-2.0
# Run with `mix run pieces/state/conversation/examples/conversation.exs` from the repository root.
# It uses the volatile Memory Store; a real host passes its PostgreSQL Store term instead.
defmodule ConversationExample do
  alias Elzoo.Conversation
  alias Elzoo.Conversation.Record
  alias Elzoo.DurableLog.Memory

  def run do
    fold = %{
      kinds: Map.new(Record.kinds(), &{&1, :non_state_bearing}),
      versions: [Record.version()],
      destinations: []
    }

    limits = %{max_record_bytes: Record.max_payload_bytes(), max_batch_size: 1}
    {:ok, memory} = Memory.start_link(fold: fold, limits: limits, append_visibility: :atomic)
    store = Memory.store(memory)
    reference = %{target_tenant: "tenant-1", conversation_id: "conversation-1"}

    {:ok, owner} =
      Conversation.start_link(
        store: store,
        target_tenant: reference.target_tenant,
        conversation_id: reference.conversation_id
      )

    input = %{message_id: "input-1", role: "user", actor: "worker", text: "First"}
    {:ok, %{sequence: 1}} = Conversation.append_input(owner, input)
    {:ok, :already_present} = Conversation.append_input(owner, input)

    {:ok, [:ok, :ok]} =
      Conversation.check(owner, [
        {:association, %{input_message_id: "input-1", run_id: "run-1"}},
        {:answer,
         %{
           message_id: "answer-1",
           actor: "worker",
           text: "First answer",
           run_id: "run-1",
           input_message_id: "input-1",
           completed: true
         }}
      ])

    {:ok, %{sequence: 2}} =
      Conversation.associate_run(owner, %{input_message_id: "input-1", run_id: "run-1"})

    {:ok, %{sequence: 3}} =
      Conversation.append_answer(owner, %{
        message_id: "answer-1",
        actor: "worker",
        text: "First answer",
        run_id: "run-1",
        input_message_id: "input-1",
        completed: true
      })

    {:refused, "duplicate_message_id"} =
      Conversation.append_input(owner, %{input | text: "Other content"})

    scope = %{tenant: "tenant-1", actor: "reader", resources: ["conversation-1"]}
    {:ok, page} = Conversation.page(store, scope, reference, 1, 10)
    {:ok, tail} = Conversation.tail(store, scope, reference, 1)
    :not_found = Conversation.tail(store, %{scope | resources: []}, reference, 1)
    %{page: page, tail: tail}
  end
end

IO.inspect(ConversationExample.run())
