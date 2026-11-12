# SPDX-License-Identifier: Apache-2.0
alias Elzoo.PatternStep

{:ok, request} =
  PatternStep.decode(%{
    "type" => "request",
    "version" => 1,
    "actions" => [
      %{
        "id" => "model-7",
        "kind" => "model_call",
        "schema_id" => "example/prompt",
        "schema_version" => 1,
        "payload" => "question"
      },
      %{
        "id" => "tool-13",
        "kind" => "tool_call",
        "schema_id" => "example/tool",
        "schema_version" => 2,
        "payload" => %{"argument" => 19}
      }
    ]
  })

{:ok, outcome} =
  PatternStep.decode(%{
    "type" => "input",
    "version" => 1,
    "kind" => "action_outcome",
    "at_ms" => 1_730_000_000_123,
    "action_id" => "model-7",
    "outcome" => "completed",
    "schema_id" => "example/result",
    "schema_version" => 1,
    "payload" => "answer"
  })

tracker = PatternStep.open(request)
{:applied, tracker} = PatternStep.accept(tracker, outcome)
{:late, ^tracker} = PatternStep.accept(tracker, outcome)
{:applied, :late}
