# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.BotRunLifecycleTest do
  use ExUnit.Case, async: false
  alias Elzoo.{BotRunLifecycle, PatternStep}

  defp context(extra \\ %{}),
    do:
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

  defp state(phase \\ :waiting) do
    actions =
      for {id, kind} <- [
            {"model", "model_call"},
            {"tool-a", "tool_call"},
            {"tool-b", "tool_call"},
            {"person", "ask_person"}
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
      PatternStep.decode(%{"type" => "request", "version" => 1, "actions" => actions})

    waits =
      Map.new(
        [
          {"model", :model},
          {"tool-a", :tool},
          {"tool-b", :tool},
          {"approval", :approval},
          {"person", :person},
          {"child", :child_run},
          {"outside", :outside_event},
          {"resource", :resource_event}
        ],
        fn {id, kind} ->
          {id, %{kind: kind, attempt_id: "execution-2", one_shot: kind != :resource_event}}
        end
      )

    %{
      phase: phase,
      waits: waits,
      tracker: PatternStep.open(request),
      outcome: if(phase == :terminal, do: :completed),
      run_deadline: 100,
      pause_deadline: if(phase == :paused, do: 80)
    }
  end

  defp event(kind, extra \\ %{}, at \\ 10) do
    base = %{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => at}

    typed =
      if kind in ["wake", "cancel"],
        do: %{},
        else: %{"schema_id" => "example/input", "schema_version" => 1, "payload" => nil}

    {:ok, checked} = PatternStep.decode(base |> Map.merge(typed) |> Map.merge(extra))
    checked
  end

  defp result(id, class \\ "completed", at \\ 10),
    do: event("action_outcome", %{"action_id" => id, "outcome" => class}, at)

  defp answer(id),
    do: event("person_answer", %{"action_id" => id, "person_id" => "principal-7"})

  defp pause(at \\ 10),
    do: %{control: :pause, at_ms: at, attempt_id: "execution-2", pause_deadline: 80}

  defp continue(at \\ 20, deadline \\ 150),
    do: %{
      control: :continue,
      at_ms: at,
      attempt_id: "execution-2",
      person_id: "principal-7",
      run_deadline: deadline
    }

  test "Total lifecycle table" do
    inputs = [
      event("start"),
      event("message"),
      event("resource_event"),
      event("run_ended", %{"payload" => %{outcome: :failed}}),
      result("model"),
      answer("person"),
      event("cancel", %{"attempt_id" => "execution-2"}),
      event("wake"),
      pause(),
      continue()
    ]

    table = %{
      active: [
        :permit_new_work,
        :permit_new_work,
        {:accept_wait, "resource"},
        :unchanged,
        {:accept_wait, "model"},
        {:accept_wait, "person"},
        {:request_outcome, :cancelled},
        :permit_new_work,
        :remain_paused,
        :unchanged
      ],
      waiting: [
        :remain_waiting,
        :remain_waiting,
        {:accept_wait, "resource"},
        :unchanged,
        {:accept_wait, "model"},
        {:accept_wait, "person"},
        {:request_outcome, :cancelled},
        :remain_waiting,
        :remain_paused,
        :unchanged
      ],
      paused: [
        :remain_paused,
        :remain_paused,
        {:accept_wait, "resource"},
        :unchanged,
        {:accept_wait, "model"},
        {:accept_wait, "person"},
        {:request_outcome, :cancelled},
        :remain_paused,
        :remain_paused,
        :remain_waiting
      ],
      terminal: List.duplicate(:unchanged, 10)
    }

    for {phase, decisions} <- table, {input, expected} <- Enum.zip(inputs, decisions) do
      s = state(phase)
      assert {:ok, next, ^expected} = BotRunLifecycle.step(s, input, context())
      if phase == :terminal, do: assert(next == s)
    end

    for outcome <- [:completed, :failed, :cancelled, :out_of_budget, :out_of_time] do
      # Committed Run-ended beats current time and stale origin, but not terminal absorption.
      assert {:ok, %{phase: :terminal, outcome: ^outcome}, :unchanged} =
               BotRunLifecycle.step(
                 state(),
                 event("run_ended", %{"payload" => %{outcome: outcome}}, 200),
                 context(%{originating_attempt: "old"})
               )
    end

    for bad <- [
          nil,
          %{},
          {:PatternStep, %{}},
          {:PatternStep, %{"type" => "input", "version" => 2}},
          {:PatternStep, %{"type" => "input", "version" => 1, "kind" => "approval", "at_ms" => 10}},
          event("run_ended", %{"payload" => %{outcome: :unknown}})
        ] do
      assert BotRunLifecycle.step(state(), bad, context()) == {:error, :invalid_shape}
    end

    for key <- Map.keys(state()) do
      assert BotRunLifecycle.step(Map.delete(state(), key), event("wake"), context()) ==
               {:error, :invalid_shape}
    end

    for bad <- [
          %{state() | phase: :future},
          %{state() | run_deadline: nil},
          %{state(:paused) | pause_deadline: nil},
          %{state() | outcome: :failed}
        ] do
      assert BotRunLifecycle.step(bad, event("wake"), context()) == {:error, :invalid_shape}
    end
  end

  test "Several waits" do
    s = state()
    assert map_size(s.waits) == 8

    assert {:ok, model, {:accept_wait, "model"}} =
             BotRunLifecycle.step(s, result("model"), context())

    assert model.waits == Map.delete(s.waits, "model")
    assert {:ok, ^model, :late} = BotRunLifecycle.step(model, result("model", "failed"), context())
    assert {:ok, ^model, :late} = BotRunLifecycle.step(model, result("absent"), context())
    assert {:ok, ^model, :late} = BotRunLifecycle.step(model, result("tool-a", "late"), context())

    assert {:ok, tool, {:accept_wait, "tool-b"}} =
             BotRunLifecycle.step(model, result("tool-b", "unknown"), context())

    assert tool.waits == Map.drop(s.waits, ["model", "tool-b"])

    assert {:ok, answered, {:accept_wait, "person"}} =
             BotRunLifecycle.step(tool, answer("person"), context())

    assert {:ok, ^answered, :late} = BotRunLifecycle.step(answered, answer("person"), context())
    assert {:ok, ^answered, :late} = BotRunLifecycle.step(answered, result("person"), context())

    assert {:ok, ^answered, {:accept_wait, "resource"}} =
             BotRunLifecycle.step(answered, event("resource_event"), context())

    once = put_in(answered.waits["resource"].one_shot, true)

    assert {:ok, observed, {:accept_wait, "resource"}} =
             BotRunLifecycle.step(once, event("resource_event"), context())

    assert observed.waits == Map.delete(once.waits, "resource")

    assert {:ok, ^observed, :late} =
             BotRunLifecycle.step(observed, event("resource_event"), context())

    last = %{s | waits: Map.take(s.waits, ["model"])}

    assert {:ok, empty, {:accept_wait, "model"}} =
             BotRunLifecycle.step(last, result("model"), context())

    assert empty.phase == :active and empty.waits == %{} and empty.outcome == nil

    assert {:ok, ^empty, :permit_new_work} =
             BotRunLifecycle.step(empty, event("wake"), context())
  end

  test "Attempt and cancel" do
    s = state()

    for old <- ["execution-1", "absent", "transport-1", nil] do
      assert {:ok, ^s, :unchanged} =
               BotRunLifecycle.step(
                 s,
                 result("tool-a", "completed", 200),
                 context(%{originating_attempt: old})
               )
    end

    for target <- ["execution-1", "absent", "transport-1"] do
      assert {:ok, ^s, :unchanged} =
               BotRunLifecycle.step(s, event("cancel", %{"attempt_id" => target}, 200), context())
    end

    assert {:ok, ^s, {:request_outcome, :cancelled}} =
             BotRunLifecycle.step(s, event("cancel", %{"attempt_id" => "execution-2"}), context())

    retired = put_in(s.waits["model"].attempt_id, "execution-1")
    assert {:ok, ^retired, :late} = BotRunLifecycle.step(retired, result("model"), context())
    # A request is not a committed outcome and never fabricates Run durability.
    assert s.outcome == nil
  end

  test "Pause and continue" do
    assert {:ok, paused, :remain_paused} = BotRunLifecycle.step(state(), pause(), context())

    assert {:ok, ^paused, :remain_paused} =
             BotRunLifecycle.step(paused, event("message"), context())

    assert {:ok, settled, {:accept_wait, "tool-a"}} =
             BotRunLifecycle.step(paused, result("tool-a"), context())

    assert settled.phase == :paused
    assert settled.waits == Map.delete(paused.waits, "tool-a")

    assert {:ok, budget_paused, :remain_paused} =
             BotRunLifecycle.step(paused, result("tool-a"), context(%{budget_exhausted: true}))

    assert budget_paused == settled
    assert {:ok, resumed, :remain_waiting} = BotRunLifecycle.step(settled, continue(), context())
    assert resumed.waits == settled.waits
    assert resumed.run_deadline == 150 and resumed.pause_deadline == nil

    for control <- [
          Map.delete(pause(), :pause_deadline),
          %{pause() | pause_deadline: nil},
          %{pause() | pause_deadline: 10},
          Map.delete(continue(), :run_deadline),
          %{continue() | run_deadline: 20},
          %{continue() | run_deadline: "secret"},
          %{continue() | person_id: "unverified"}
        ] do
      assert BotRunLifecycle.step(paused, control, context()) == {:error, :invalid_shape}
    end
  end

  test "Budget/time boundaries" do
    s = state()

    assert {:ok, paused, :remain_paused} =
             BotRunLifecycle.step(s, event("wake"), context(%{budget_exhausted: true}))

    assert paused.waits == s.waits and paused.pause_deadline == 80

    assert {:ok, ^s, {:request_outcome, :out_of_budget}} =
             BotRunLifecycle.step(
               s,
               event("wake"),
               context(%{budget_exhausted: true, budget_rule: :finish})
             )

    assert BotRunLifecycle.step(
             s,
             event("wake"),
             Map.delete(context(%{budget_exhausted: true}), :pause_deadline)
           ) == {:error, :invalid_shape}

    for {run_deadline, pause_deadline, boundary} <- [{70, 90, 70}, {100, 80, 80}],
        offset <- [-1, 0, 1],
        empty <- [false, true],
        rule <- [:pause, :finish] do
      before = %{paused | run_deadline: run_deadline, pause_deadline: pause_deadline}
      ctx = context(%{budget_exhausted: empty, budget_rule: rule})

      expected =
        cond do
          offset >= 0 -> {:request_outcome, :out_of_time}
          empty and rule == :finish -> {:request_outcome, :out_of_budget}
          true -> :remain_paused
        end

      assert {:ok, ^before, ^expected} =
               BotRunLifecycle.step(before, event("wake", %{}, boundary + offset), ctx)

      if offset >= 0 do
        assert {:ok, ^before, {:request_outcome, :out_of_time}} =
                 BotRunLifecycle.step(before, continue(boundary + offset, 200), ctx)

        assert {:ok, ^before, {:request_outcome, :out_of_time}} =
                 BotRunLifecycle.step(
                   before,
                   event("cancel", %{"attempt_id" => "execution-2"}, boundary + offset),
                   ctx
                 )
      else
        if not empty do
          assert {:ok, continued, :remain_waiting} =
                   BotRunLifecycle.step(before, continue(boundary - 1, 200), ctx)

          assert continued.run_deadline == 200 and continued.pause_deadline == nil
        end
      end
    end

    assert {:ok, extended, :remain_waiting} =
             BotRunLifecycle.step(paused, continue(79, 200), context())

    assert extended.run_deadline == 200

    assert {:ok, ^paused, :remain_paused} =
             BotRunLifecycle.step(paused, continue(79, 200), context(%{budget_exhausted: true}))

    assert {:ok, resumed, :remain_waiting} =
             BotRunLifecycle.step(paused, continue(79, 200), context(%{budget_exhausted: false}))

    assert resumed.phase == :waiting
    terminal = state(:terminal)

    assert {:ok, ^terminal, :unchanged} =
             BotRunLifecycle.step(terminal, continue(101, 200), context())
  end

  test "Owner-approved protocol distinctions" do
    s = state()

    assert {:ok, ^s, :remain_waiting} =
             BotRunLifecycle.step(s, event("wake"), context(%{originating_attempt: nil}))

    assert {:ok, ^s, {:request_outcome, :out_of_time}} =
             BotRunLifecycle.step(
               s,
               event("wake", %{}, 100),
               context(%{originating_attempt: "old"})
             )

    {:PatternStep, wake} = event("wake")
    assert Map.keys(wake) |> Enum.sort() == ["at_ms", "kind", "type", "version"]

    assert BotRunLifecycle.step(s, {:PatternStep, Map.put(wake, "payload", "text")}, context()) ==
             {:error, :invalid_shape}

    assert {:ok, ^s, :unchanged} = BotRunLifecycle.step(s, result("person"), context())
    assert {:ok, ^s, :unchanged} = BotRunLifecycle.step(s, answer("model"), context())

    assert BotRunLifecycle.step(s, answer("person"), context(%{verified_person: nil})) ==
             {:error, :invalid_shape}

    assert {:ok, ^s, :remain_waiting} =
             BotRunLifecycle.step(
               s,
               event("message", %{"payload" => "principal-7: answer"}),
               context()
             )

    assert {:ok, paused, :remain_paused} = BotRunLifecycle.step(s, pause(), context())

    assert {:ok, settled, {:accept_wait, "person"}} =
             BotRunLifecycle.step(paused, answer("person"), context())

    replayed = :erlang.binary_to_term(:erlang.term_to_binary(settled), [:safe])

    assert BotRunLifecycle.step(replayed, continue(), context()) ==
             BotRunLifecycle.step(settled, continue(), context())

    assert {:ok, ^replayed, :late} = BotRunLifecycle.step(replayed, answer("person"), context())
  end

  test "Selected Cure laws and example" do
    source = File.read!(Path.expand("../../cure/elzoo/bot_run_lifecycle.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0
    {result, _} = Code.eval_file(Path.expand("../../examples/bot_run_lifecycle.exs", __DIR__))
    assert result == %{phase: :waiting, waits: ["tool-b"], run_deadline: 150}
  end
end
