# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{PatternStep, WaitForPerson}

{:ok, request} =
  PatternStep.decode(%{
    "type" => "request",
    "version" => 1,
    "actions" => [
      %{
        "id" => "ask-1",
        "kind" => "ask_person",
        "schema_id" => "example/question",
        "schema_version" => 1,
        "payload" => nil
      }
    ]
  })

# The host names the asked person from trusted data when the ask opens.
state = %{asks: %{"ask-1" => "principal-7"}, tracker: PatternStep.open(request)}

# Text from the verified person: one open ask names that person, so the host records an answer.
{:answer, "ask-1"} = WaitForPerson.route(state.asks, "principal-7")

{:ok, answer} =
  PatternStep.decode(%{
    "type" => "input",
    "version" => 1,
    "kind" => "person_answer",
    "at_ms" => 20,
    "action_id" => "ask-1",
    "person_id" => "principal-7",
    "schema_id" => "example/answer",
    "schema_version" => 1,
    "payload" => %{"text" => "yes"}
  })

{:ok, ^state, wrong} = WaitForPerson.step(state, answer, "principal-9")
{:ok, closed, answered} = WaitForPerson.step(state, answer, "principal-7")

[wrong, answered, WaitForPerson.route(closed.asks, "principal-7")]
