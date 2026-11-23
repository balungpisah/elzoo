# SPDX-License-Identifier: Apache-2.0
# A "decided" room with a lead bot: a mention gives b1 the turn; an unaddressed
# message asks one decision, whose pick ["b2", "b1"] gives two turns in order.
alias Elzoo.TurnPolicy

input = fn kind, fields ->
  Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 0}, fields)
end

typed = fn kind, schema, payload ->
  input.(kind, %{"schema_id" => schema, "schema_version" => 1, "payload" => payload})
end

message = fn id, mentions ->
  typed.("message", "elzoo.room.message", %{
    "message_id" => id,
    "from" => "ana",
    "text" => "Can someone look at the invoice?",
    "mentions" => mentions
  })
end

completed = fn id, schema, payload ->
  input.("action_outcome", %{
    "action_id" => id,
    "outcome" => "completed",
    "schema_id" => schema,
    "schema_version" => 1,
    "payload" => payload
  })
end

# The host's side: a bot answers, a post or a notice completes, a decision picks.
host = fn %{"id" => id, "schema_id" => schema} ->
  case schema do
    "elzoo.room.turn" ->
      completed.(id, "elzoo.room.answer", %{
        "text" => "On it.",
        "mentions" => [],
        "handoff_to" => nil,
        "escalate" => false
      })

    "elzoo.room.decide" ->
      completed.(id, "elzoo.typed-decision.result", %{
        "status" => "decided",
        "value" => %{"pick" => ["b2", "b1"]},
        "repairs" => 0,
        "action_id" => id <> ":call:0"
      })

    _ ->
      completed.(id, "elzoo.room.ack", nil)
  end
end

run = fn run, state, output, ids ->
  case output do
    :none ->
      {state, ids}

    {:some, %{"actions" => [action]}} ->
      {:Transition, state, output} = TurnPolicy.step(state, host.(action))
      run.(run, state, output, ids ++ [action["id"]])
  end
end

{:ok, state} = TurnPolicy.new(%{host_rules: %{}})

start = %{
  "room_id" => "support",
  "link" => 1,
  "members" => [
    %{"id" => "ana", "kind" => "human"},
    %{"id" => "b1", "kind" => "bot"},
    %{"id" => "b2", "kind" => "bot"}
  ],
  "policy" => %{
    "rule" => "decided",
    "default_member" => "b1",
    "max_bot_turns" => 2,
    "handoff" => "allowed",
    "post_to" => "channel:support",
    "window" => %{"messages" => 8, "bytes" => 16_384},
    "rollover" => %{"max_turns" => 40}
  },
  "summary" => nil,
  "carry" => nil
}

:ok = TurnPolicy.check_start(state, start)
{:Transition, state, :none} = TurnPolicy.step(state, typed.("start", "elzoo.room.start", start))

Enum.reduce([message.("m1", ["b1"]), message.("m2", [])], {state, []}, fn input, {state, ids} ->
  {:Transition, state, output} = TurnPolicy.step(state, input)
  run.(run, state, output, ids)
end)
|> elem(1)
