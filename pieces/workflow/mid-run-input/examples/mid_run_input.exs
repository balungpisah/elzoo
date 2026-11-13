# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{MidRunInput, PatternStep}

{:ok, message} =
  PatternStep.decode(%{
    "type" => "input",
    "version" => 1,
    "kind" => "message",
    "at_ms" => 20,
    "schema_id" => "example/text",
    "schema_version" => 1,
    "payload" => "while you wait"
  })

{:ok, wake} =
  PatternStep.decode(%{"type" => "input", "version" => 1, "kind" => "wake", "at_ms" => 30})

# The Run declared the rule :queue; the caller reads the Run facts from its record.
state = %{rule: :queue, queue: []}
waiting = %{phase: :waiting, delivered: [], open: ["tool-1"]}

{:ok, held, queued} = MidRunInput.step(state, message, waiting)
{:ok, ^held, passed} = MidRunInput.step(held, wake, waiting)

# Later the lifecycle permits new work: the caller takes the oldest queued message.
{:ok, empty, {:deliver, %{"payload" => text}}} = MidRunInput.next(held)
{:ok, ^empty, nothing} = MidRunInput.next(empty)

[queued, passed, {:deliver, text}, nothing]
