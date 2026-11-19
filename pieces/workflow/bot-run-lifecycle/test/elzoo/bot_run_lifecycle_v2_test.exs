# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.BotRunLifecycleV2Test do
  use ExUnit.Case, async: false
  alias Elzoo.{BotRunLifecycle, PatternStep}

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        current_attempt: "execution-2",
        originating_attempt: "execution-2",
        budget_exhausted: false,
        budget_rule: :pause,
        pause_deadline: 80,
        verified_person: "principal-7",
        wait_id: "resource"
      },
      extra
    )
  end

  defp state(extra \\ %{}) do
    actions =
      for {id, kind} <- [
            {"model", "model_call"},
            {"tool", "tool_call"},
            {"person", "ask_person"},
            {"outside", "wait_event"},
            {"outside-2", "wait_event"}
          ] do
        %{
          "id" => id,
          "kind" => kind,
          "schema_id" => "example/work",
          "schema_version" => 1,
          "payload" => nil
        }
      end

    {:ok, request} =
      PatternStep.decode(%{"type" => "request", "version" => 2, "actions" => actions}, 2)

    phase = Map.get(extra, :phase, :waiting)

    waits =
      Map.get(extra, :waits, %{
        "model" => %{kind: :model, attempt_id: "execution-2", one_shot: true},
        "tool" => %{kind: :tool, attempt_id: "execution-2", one_shot: true},
        "person" => %{kind: :person, attempt_id: "execution-2", one_shot: true},
        "outside" => %{
          kind: :outside_event,
          attempt_id: "execution-2",
          one_shot: true,
          source_id: "source-1",
          correlation_id: "ticket-1"
        },
        "outside-2" => %{
          kind: :outside_event,
          attempt_id: "execution-2",
          one_shot: true,
          source_id: "source-2",
          correlation_id: "ticket-2"
        },
        "resource" => %{kind: :resource_event, attempt_id: "execution-2", one_shot: false}
      })

    Map.merge(
      %{
        phase: phase,
        waits: waits,
        tracker: PatternStep.open(request),
        outcome: if(phase == :terminal, do: :completed),
        run_deadline: 100,
        pause_deadline: if(phase == :paused, do: 80)
      },
      extra
    )
  end

  defp input(kind, extra \\ %{}, at \\ 10) do
    typed =
      if kind in ["wake", "cancel"],
        do: %{},
        else: %{"schema_id" => "example/input", "schema_version" => 1, "payload" => nil}

    map =
      %{"type" => "input", "version" => 2, "kind" => kind, "at_ms" => at}
      |> Map.merge(typed)
      |> Map.merge(extra)

    {:ok, checked} = PatternStep.decode(map, 2)
    checked
  end

  defp outside(extra \\ %{}, at \\ 10) do
    input(
      "outside_event",
      %{
        "action_id" => "outside",
        "source_id" => "source-1",
        "correlation_id" => "ticket-1",
        "event_id" => "event-1"
      }
      |> Map.merge(extra),
      at
    )
  end

  defp verified_event(input) do
    map = PatternStep.encode(input)

    %{
      source_id: map["source_id"],
      correlation_id: map["correlation_id"],
      event_id: map["event_id"]
    }
  end

  defp outside_context(input, extra \\ %{}),
    do: context(Map.put(extra, :verified_event, verified_event(input)))

  defp run(state, input, context \\ context()), do: BotRunLifecycle.step(state, input, context, 2)

  defp outcome(id, result, at \\ 10),
    do: input("action_outcome", %{"action_id" => id, "outcome" => result}, at)

  test "v2 dispatch keeps the strict v1 entry point and tags separate" do
    {:ok, request} =
      PatternStep.decode(%{
        "type" => "request",
        "version" => 1,
        "actions" => [
          %{
            "id" => "model",
            "kind" => "model_call",
            "schema_id" => "example/work",
            "schema_version" => 1,
            "payload" => nil
          }
        ]
      })

    v1_state = %{
      phase: :active,
      waits: %{},
      tracker: PatternStep.open(request),
      outcome: nil,
      run_deadline: 100,
      pause_deadline: nil
    }

    assert {:error, :invalid_shape} = BotRunLifecycle.step(v1_state, input("start"), context())
    assert {:error, :invalid_shape} = BotRunLifecycle.step(state(), input("start"), context(), 1)
    assert {:error, :invalid_shape} = BotRunLifecycle.step(state(), input("start"), context(), 3)
    assert {:error, :invalid_shape} = BotRunLifecycle.step(state(), input("start"), context(), 2.0)

    {:ok, v1_input} =
      PatternStep.decode(%{
        "type" => "input",
        "version" => 1,
        "kind" => "start",
        "at_ms" => 10,
        "schema_id" => "example/input",
        "schema_version" => 1,
        "payload" => nil
      })

    assert {:error, :invalid_shape} = run(state(), v1_input, context())
    assert {:error, :invalid_shape} = BotRunLifecycle.step(v1_state, input("start"), context(), 2)
    assert {:error, :invalid_shape} = BotRunLifecycle.step(state(), v1_input, context(), 2)
    assert {:error, :invalid_shape} = BotRunLifecycle.step(state(), v1_input, context())
    assert {:ok, _, :permit_new_work} = run(state(%{phase: :active}), input("start"))

    assert MapSet.new(Map.keys(state())) ==
             MapSet.new([:phase, :waits, :tracker, :outcome, :run_deadline, :pause_deadline])

    assert {:error, :invalid_shape} = run(Map.put(state(), :extra, true), input("start"))
    assert match?({:PatternStepTrackerV2, _}, state().tracker)
  end

  test "existing v1 inputs and Controls retain their meanings through explicit v2" do
    assert {:ok, _, :permit_new_work} = run(state(%{phase: :active}), input("message"))
    assert {:ok, _, :permit_new_work} = run(state(%{phase: :active}), input("wake"))

    assert {:ok, resource, {:accept_wait, "resource"}} =
             run(state(), input("resource_event"))

    assert Map.has_key?(resource.waits, "resource")

    assert {:ok, model, {:accept_wait, "model"}} =
             run(state(), outcome("model", "completed"))

    refute Map.has_key?(model.waits, "model")

    assert {:ok, person, {:accept_wait, "person"}} =
             run(
               state(),
               input("person_answer", %{"action_id" => "person", "person_id" => "principal-7"})
             )

    refute Map.has_key?(person.waits, "person")

    ended = input("run_ended", %{"payload" => %{outcome: :failed}})
    assert {:ok, %{phase: :terminal, outcome: :failed}, :unchanged} = run(state(), ended)

    cancel = input("cancel", %{"attempt_id" => "execution-2"})
    assert {:ok, _, {:request_outcome, :cancelled}} = run(state(), cancel)

    pause = %{control: :pause, at_ms: 10, attempt_id: "execution-2", pause_deadline: 80}
    assert {:ok, %{phase: :paused}, :remain_paused} = run(state(), pause)

    continue = %{
      control: :continue,
      at_ms: 20,
      attempt_id: "execution-2",
      person_id: "principal-7",
      run_deadline: 150
    }

    assert {:ok, %{run_deadline: 150, phase: :waiting}, :remain_waiting} =
             run(state(%{phase: :paused}), continue)
  end

  test "outside-event wait and input keep their exact v2 shapes" do
    wait = state().waits["outside"]

    assert MapSet.new(Map.keys(wait)) ==
             MapSet.new([:kind, :attempt_id, :one_shot, :source_id, :correlation_id])

    assert wait.one_shot

    event = outside()
    assert {:PatternStepV2, encoded} = event

    assert MapSet.new(Map.keys(encoded)) ==
             MapSet.new([
               "type",
               "version",
               "kind",
               "at_ms",
               "schema_id",
               "schema_version",
               "payload",
               "action_id",
               "source_id",
               "correlation_id",
               "event_id"
             ])

    assert {:ok, next, {:accept_wait, "outside"}} = run(state(), event, outside_context(event))
    refute Map.has_key?(next.waits, "outside")
    assert Map.has_key?(next.waits, "outside-2")
    assert match?({:PatternStepTrackerV2, _}, next.tracker)
    assert {:PatternStepTrackerV2, actions} = next.tracker
    assert {"wait_event", true} = actions["outside"]
    assert next.phase == :waiting

    long = String.duplicate("x", 512)
    long_event = outside(%{"source_id" => long, "correlation_id" => long, "event_id" => long})

    long_wait = %{
      kind: :outside_event,
      attempt_id: "execution-2",
      one_shot: true,
      source_id: long,
      correlation_id: long
    }

    long_state = %{
      state(%{waits: %{"outside" => long_wait}})
      | tracker: state().tracker
    }

    assert {:ok, _, {:accept_wait, "outside"}} =
             run(long_state, long_event, outside_context(long_event))

    long_action = String.duplicate("action", 100)

    long_action_wait = %{
      kind: :outside_event,
      attempt_id: "execution-2",
      one_shot: true,
      source_id: long,
      correlation_id: long
    }

    long_action_entry = %{
      "id" => long_action,
      "kind" => "wait_event",
      "schema_id" => "example/work",
      "schema_version" => 1,
      "payload" => nil
    }

    {:ok, long_request} =
      PatternStep.decode(
        %{"type" => "request", "version" => 2, "actions" => [long_action_entry]},
        2
      )

    long_action_state =
      state(%{
        waits: %{long_action => long_action_wait},
        tracker: PatternStep.open(long_request)
      })

    long_action_event =
      outside(%{"action_id" => long_action, "source_id" => long, "correlation_id" => long})

    assert {:ok, _, {:accept_wait, ^long_action}} =
             run(long_action_state, long_action_event, outside_context(long_action_event))
  end

  test "v2 outside waits reject unknown kinds, extra keys and every missing required field" do
    original = state()
    wait = original.waits["outside"]

    invalid_waits =
      [
        %{wait | kind: :unknown},
        %{wait | one_shot: false},
        %{wait | source_id: ""},
        %{wait | correlation_id: <<255>>},
        Map.put(wait, :extra, true)
      ] ++
        Enum.map(
          [:kind, :attempt_id, :one_shot, :source_id, :correlation_id],
          &Map.delete(wait, &1)
        )

    for invalid_wait <- invalid_waits do
      assert {:error, :invalid_shape} =
               run(
                 %{original | waits: Map.put(original.waits, "outside", invalid_wait)},
                 input("start")
               )
    end

    valid = PatternStep.encode(outside())

    for key <- Map.keys(valid) do
      assert {:error, :invalid_shape} =
               run(original, {:PatternStepV2, Map.delete(valid, key)}, outside_context(outside()))
    end

    assert {:error, :invalid_shape} =
             run(
               original,
               {:PatternStepV2, Map.put(valid, "late_field", true)},
               outside_context(outside())
             )

    assert {:error, :invalid_shape} =
             run(
               original,
               {:PatternStepV2, Map.put(valid, "version", 1)},
               outside_context(outside())
             )

    assert {:error, :invalid_shape} =
             run(
               original,
               {:PatternStepV2, Map.put(valid, "version", 2.0)},
               outside_context(outside())
             )

    for {field, invalid} <- [
          {"type", "request"},
          {"kind", "unknown"},
          {"at_ms", 10.0},
          {"schema_id", ""},
          {"schema_version", 0},
          {"action_id", ""},
          {"source_id", <<255>>},
          {"correlation_id", 7},
          {"event_id", ""}
        ] do
      assert {:error, :invalid_shape} =
               run(
                 original,
                 {:PatternStepV2, Map.put(valid, field, invalid)},
                 outside_context(outside())
               )
    end

    assert {:ok, _, {:accept_wait, "outside"}} =
             run(
               original,
               {:PatternStepV2, Map.put(valid, "payload", {:opaque, self()})},
               outside_context(outside())
             )
  end

  test "verified event facts are exact and checked before terminal, stale or time precedence" do
    event = outside()
    valid = verified_event(event)

    invalid_contexts = [
      context(),
      context(%{originating_attempt: "execution-1"}),
      context(%{verified_event: Map.put(valid, :extra, "x")}),
      context(%{verified_event: Map.delete(valid, :event_id)}),
      context(%{verified_event: %{source_id: "", correlation_id: "ticket-1", event_id: "event-1"}}),
      context(%{verified_event: %{valid | correlation_id: 7}}),
      context(%{verified_event: %{valid | event_id: <<255>>}}),
      context(%{verified_event: %{valid | event_id: "other-event"}})
    ]

    for candidate <- invalid_contexts do
      assert {:error, :invalid_shape} =
               run(state(%{phase: :terminal}), event, candidate)
    end

    mismatches = [
      outside(%{"source_id" => "other-source"}),
      outside(%{"correlation_id" => "other-ticket"}),
      outside(%{"event_id" => "other-event"})
    ]

    for mismatched <- mismatches do
      assert {:error, :invalid_shape} =
               run(state(%{run_deadline: 10}), mismatched, outside_context(event))
    end
  end

  test "source and ticket mismatches are late and preserve the original state" do
    for mismatched <- [
          outside(%{"source_id" => "other-source"}),
          outside(%{"correlation_id" => "other-ticket"})
        ] do
      original = state()
      assert {:ok, ^original, :late} = run(original, mismatched, outside_context(mismatched))
    end
  end

  @tag :source_mismatch_control
  test "outside source mismatch is late without consuming a wait" do
    event = outside(%{"source_id" => "other-source"})
    original = state()

    assert {:ok, ^original, :late} =
             run(original, event, outside_context(event))
  end

  test "absent, retired, wrong-kind and stale-wait outside actions are late" do
    absent = outside(%{"action_id" => "unknown-action"})
    assert {:ok, original, :late} = run(state(), absent, outside_context(absent))
    assert original == state()

    retired = %{state() | waits: Map.delete(state().waits, "outside")}
    event = outside()
    assert {:ok, ^retired, :late} = run(retired, event, outside_context(event))

    wrong_kind = outside(%{"action_id" => "model"})
    assert {:ok, _, :late} = run(state(), wrong_kind, outside_context(wrong_kind))

    stale_wait = %{
      state()
      | waits:
          Map.put(state().waits, "outside", %{state().waits["outside"] | attempt_id: "execution-1"})
    }

    assert {:ok, ^stale_wait, :late} = run(stale_wait, event, outside_context(event))
  end

  test "stale origin precedes expiry, while a current event at the deadline requests time" do
    event = outside(%{"source_id" => "other-source"}, 100)
    expired = state(%{run_deadline: 100})

    assert {:ok, ^expired, :unchanged} =
             run(expired, event, outside_context(event, %{originating_attempt: "execution-1"}))

    assert {:ok, ^expired, {:request_outcome, :out_of_time}} =
             run(expired, event, outside_context(event))

    pause_expired = state(%{phase: :paused, pause_deadline: 10})
    pause_event = outside(%{"source_id" => "other-source"}, 10)

    assert {:ok, ^pause_expired, {:request_outcome, :out_of_time}} =
             run(pause_expired, pause_event, outside_context(pause_event))
  end

  test "terminal absorbs valid events and run-ended still wins stale and time" do
    event = outside()
    terminal = state(%{phase: :terminal})
    assert {:ok, ^terminal, :unchanged} = run(terminal, event, outside_context(event))

    ended = input("run_ended", %{"payload" => %{outcome: :failed}}, 100)

    assert {:ok, %{phase: :terminal, outcome: :failed}, :unchanged} =
             run(state(), ended, context(%{originating_attempt: "execution-1"}))
  end

  test "generic completed outcomes refuse outside waits, failures settle and late never consumes" do
    completed = outcome("outside", "completed")
    original = state()
    assert {:ok, ^original, :unchanged} = run(original, completed)

    failed = outcome("outside", "failed")
    assert {:ok, failed_state, {:accept_wait, "outside"}} = run(original, failed)
    refute Map.has_key?(failed_state.waits, "outside")
    assert {:PatternStepTrackerV2, failed_actions} = failed_state.tracker
    assert {"wait_event", true} = failed_actions["outside"]

    late = outcome("outside", "late")
    assert {:ok, ^original, :late} = run(original, late)
  end

  test "person answers cannot satisfy outside waits and a second event id is late" do
    original = state()
    answer = input("person_answer", %{"action_id" => "outside", "person_id" => "principal-7"})
    assert {:ok, ^original, :unchanged} = run(original, answer)

    first = outside(%{"event_id" => "first-event"})

    assert {:ok, settled, {:accept_wait, "outside"}} =
             run(original, first, outside_context(first))

    second = outside(%{"event_id" => "second-event"})
    assert {:ok, ^settled, :late} = run(settled, second, outside_context(second))

    {:applied, settled_tracker} = PatternStep.accept(original.tracker, first)
    settled_open_wait = %{original | tracker: settled_tracker}

    assert {:ok, ^settled_open_wait, :late} =
             run(settled_open_wait, first, outside_context(first))
  end

  test "paused and budget decisions retain accepted outside receipts without granting work" do
    event = outside()
    paused = state(%{phase: :paused})

    assert {:ok, accepted_paused, {:accept_wait, "outside"}} =
             run(paused, event, outside_context(event))

    assert accepted_paused.phase == :paused
    assert accepted_paused.outcome == nil
    refute Map.has_key?(accepted_paused.waits, "outside")

    last_wait = state(%{waits: %{"outside" => state().waits["outside"]}})

    assert {:ok, active, {:accept_wait, "outside"}} =
             run(last_wait, event, outside_context(event))

    assert active.phase == :active
    assert active.outcome == nil

    pause_budget =
      context(%{budget_exhausted: true, budget_rule: :pause, verified_event: verified_event(event)})

    assert {:ok, budget_paused, :remain_paused} =
             run(state(), event, pause_budget)

    assert budget_paused.phase == :paused
    refute Map.has_key?(budget_paused.waits, "outside")

    finish_budget =
      context(%{
        budget_exhausted: true,
        budget_rule: :finish,
        verified_event: verified_event(event)
      })

    assert {:ok, budget_finished, {:request_outcome, :out_of_budget}} =
             run(state(), event, finish_budget)

    assert budget_finished.phase == :waiting
    refute Map.has_key?(budget_finished.waits, "outside")
  end
end
