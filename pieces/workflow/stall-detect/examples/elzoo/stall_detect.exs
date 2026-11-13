# SPDX-License-Identifier: Apache-2.0
alias Elzoo.StallDetect

call = fn id ->
  %{
    "type" => "request",
    "version" => 1,
    "actions" => [
      %{
        "id" => id,
        "kind" => "model_call",
        "schema_id" => "example/prompt",
        "schema_version" => 1,
        "payload" => %{"prompt" => "next step?"}
      }
    ]
  }
end

result = fn id, at ->
  %{
    "type" => "input",
    "version" => 1,
    "kind" => "action_outcome",
    "at_ms" => at,
    "action_id" => id,
    "outcome" => "completed",
    "schema_id" => "example/reply",
    "schema_version" => 1,
    "payload" => %{"text" => "thinking"}
  }
end

message = %{
  "type" => "input",
  "version" => 1,
  "kind" => "message",
  "at_ms" => 100,
  "schema_id" => "example/message",
  "schema_version" => 1,
  "payload" => %{"text" => "plan the trip"}
}

window = [message, call.("call-1"), result.("call-1", 110), call.("call-2")]
limits = %{repeats: 2, idle_ms: 60_000}

{StallDetect.verdict(window, limits, 120, []),
 StallDetect.verdict(Enum.take(window, 3), limits, 120, [])}
