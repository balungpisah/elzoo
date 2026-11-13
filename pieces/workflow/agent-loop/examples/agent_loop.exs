# SPDX-License-Identifier: Apache-2.0
# A start, one tool turn and the answer, as one recorded trace of neutral maps.
alias Elzoo.AgentLoop

schema = %{
  "type" => "object",
  "properties" => %{"path" => %{"type" => "string"}},
  "required" => ["path"]
}

{:ok, state} =
  AgentLoop.new(%{
    id: "demo",
    model: "demo-model",
    max_output_tokens: 256,
    role_instructions: ["Answer from the files you read."],
    window: %{
      provider_id: "demo",
      model_id: "demo-model",
      size: 100_000,
      unit: :tokens,
      estimator_id: "bytes",
      estimator_version: 1
    },
    max_request_bytes: 65_536,
    max_image_refs: 0,
    sources: [
      %{
        "id" => "files",
        "kind" => "other",
        "callable" => "adapter",
        "tools" => [
          %{
            "trust" => "untrusted",
            "name" => "read",
            "description" => "Read one file",
            "input_schema" => schema,
            "annotations" => nil
          }
        ]
      }
    ],
    result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
    ask: nil,
    turn_limit: 4
  })

# The host's estimate: one token per byte, an upper bound.
estimate = fn bytes ->
  {:ok,
   %{
     size: byte_size(bytes),
     unit: :tokens,
     direction: :upper_bound,
     estimator_id: "bytes",
     estimator_version: 1
   }}
end

input = fn kind, fields ->
  Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 0}, fields)
end

completed = fn id, schema_id, payload ->
  input.("action_outcome", %{
    "action_id" => id,
    "outcome" => "completed",
    "schema_id" => schema_id,
    "schema_version" => 1,
    "payload" => payload
  })
end

model = fn n, content, finish, proposals ->
  completed.("demo:m:#{n}", "elzoo.ai-text.result", %{
    "content" => content,
    "finish" => finish,
    "tool_proposals" => proposals
  })
end

trace = [
  input.("start", %{
    "schema_id" => "elzoo.agent-loop.message",
    "schema_version" => 1,
    "payload" => %{"text" => "What does the plan file say?"}
  }),
  model.(1, "", "tool_calls", [
    %{
      "id" => "call-1",
      "name" => "files_read",
      "arguments" => %{"path" => "plan.txt"},
      "malformed" => nil
    }
  ]),
  completed.("demo:t:1:1", "elzoo.agent-loop.tool-result", %{
    "content" => %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => ["files:read"],
      "trust" => "untrusted",
      "max_bytes" => 4_096,
      "content" => "Ship on Friday."
    },
    "media_type" => "text/plain",
    "encoding" => "utf8"
  }),
  model.(2, "The plan says to ship on Friday.", "stop", [])
]

{_state, requests} =
  Enum.reduce(trace, {state, []}, fn item, {state, requests} ->
    {:Transition, state, {:some, request}} = AgentLoop.step(state, item, estimate)
    {state, requests ++ [request]}
  end)

%{"actions" => [%{"payload" => finish}]} = List.last(requests)

%{
  actions: Enum.map(requests, fn %{"actions" => [action]} -> action["kind"] end),
  status: finish["status"],
  action_id: finish["action_id"],
  turns: finish["turns"]
}
