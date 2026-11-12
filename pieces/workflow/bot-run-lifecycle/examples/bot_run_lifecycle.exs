# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{BotRunLifecycle, PatternStep}

{:ok, request} =
  PatternStep.decode(%{
    "type" => "request",
    "version" => 1,
    "actions" =>
      for id <- ["tool-a", "tool-b"] do
        %{
          "id" => id,
          "kind" => "tool_call",
          "schema_id" => "example/tool",
          "schema_version" => 1,
          "payload" => nil
        }
      end
  })

state = %{
  phase: :waiting,
  waits:
    Map.new(["tool-a", "tool-b"], fn id ->
      {id, %{kind: :tool, attempt_id: "execution-2", one_shot: true}}
    end),
  tracker: PatternStep.open(request),
  outcome: nil,
  run_deadline: 100,
  pause_deadline: nil
}

context = %{
  current_attempt: "execution-2",
  originating_attempt: "execution-2",
  budget_exhausted: false,
  budget_rule: :pause,
  verified_person: "principal-7"
}

{:ok, paused, :remain_paused} =
  BotRunLifecycle.step(
    state,
    %{control: :pause, at_ms: 10, attempt_id: "execution-2", pause_deadline: 80},
    context
  )

{:ok, result} =
  PatternStep.decode(%{
    "type" => "input",
    "version" => 1,
    "kind" => "action_outcome",
    "at_ms" => 15,
    "action_id" => "tool-a",
    "outcome" => "completed",
    "schema_id" => "example/result",
    "schema_version" => 1,
    "payload" => nil
  })

{:ok, settled, {:accept_wait, "tool-a"}} = BotRunLifecycle.step(paused, result, context)

{:ok, resumed, :remain_waiting} =
  BotRunLifecycle.step(
    settled,
    %{
      control: :continue,
      at_ms: 20,
      attempt_id: "execution-2",
      person_id: "principal-7",
      run_deadline: 150
    },
    context
  )

%{phase: resumed.phase, waits: Map.keys(resumed.waits), run_deadline: resumed.run_deadline}
