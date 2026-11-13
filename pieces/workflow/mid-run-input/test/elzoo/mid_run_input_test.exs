# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MidRunInputTest do
  use ExUnit.Case, async: true
  alias Elzoo.{MidRunInput, PatternStep}

  @rules [:queue, :reject, :interrupt, :steer, :side_run]
  @phases [:active, :waiting, :paused, :terminal]

  defp typed(kind, at, extra \\ %{}),
    do:
      Map.merge(
        %{
          "type" => "input",
          "version" => 1,
          "kind" => kind,
          "at_ms" => at,
          "schema_id" => "example/input",
          "schema_version" => 1,
          "payload" => nil
        },
        extra
      )

  defp outcome(id, at),
    do: typed("action_outcome", at, %{"action_id" => id, "outcome" => "completed"})

  # One recorded trace of v1 neutral maps. The request is the pattern's output, not an input.
  @request %{
    "type" => "request",
    "version" => 1,
    "actions" =>
      for id <- ~w(tool-1 tool-2 tool-3) do
        %{
          "id" => id,
          "kind" => "tool_call",
          "schema_id" => "example/tool",
          "schema_version" => 1,
          "payload" => %{"call" => id}
        }
      end
  }
  @message %{
    "type" => "input",
    "version" => 1,
    "kind" => "message",
    "at_ms" => 40,
    "schema_id" => "example/text",
    "schema_version" => 1,
    "payload" => %{"text" => "also check the logs"}
  }
  @wake %{"type" => "input", "version" => 1, "kind" => "wake", "at_ms" => 50}

  # Each input with the Run facts that the caller reads after ELZ-124 decided the same input.
  defp trace do
    [
      {typed("start", 10), run(:active, [], [])},
      {outcome("tool-1", 30), run(:waiting, ["tool-1"], ["tool-2", "tool-3"])},
      {@message, run(:waiting, ["tool-1"], ["tool-2", "tool-3"])},
      {@wake, run(:waiting, ["tool-1"], ["tool-2", "tool-3"])},
      {outcome("tool-2", 60), run(:waiting, ["tool-1", "tool-2"], ["tool-3"])},
      {outcome("tool-3", 70), run(:active, ["tool-1", "tool-2", "tool-3"], [])}
    ]
  end

  defp run(phase, delivered, open), do: %{phase: phase, delivered: delivered, open: open}

  defp checked(map) do
    assert {:ok, checked} = PatternStep.decode(map)
    checked
  end

  defp walk(state, steps) do
    Enum.map_reduce(steps, state, fn {input, run}, state ->
      assert {:ok, next, decision} = MidRunInput.step(state, checked(input), run)
      {{next, decision}, next}
    end)
  end

  defp message(n), do: %{@message | "at_ms" => 100 + n, "payload" => %{"n" => n}}

  test "wake_bypasses_every_rule" do
    for rule <- @rules, phase <- @phases, queue <- [[], [@message, message(1)]] do
      state = %{rule: rule, queue: queue}

      assert {:ok, ^state, :pass} =
               MidRunInput.step(state, checked(@wake), run(phase, ["tool-1"], ["tool-2"]))
    end

    assert {:ok, %{queue: [], rule: :queue}, :empty} = MidRunInput.next(%{rule: :queue, queue: []})
  end

  test "five_rules_one_trace" do
    report = %{delivered: ["tool-1"], open: ["tool-2", "tool-3"]}

    expected = %{
      queue: :queued,
      reject: {:refused, :run_busy},
      interrupt: {:interrupt, @message, report},
      steer: {:deliver, @message},
      side_run: {:side_run, @message, report}
    }

    for rule <- @rules do
      {steps, final} = walk(%{rule: rule, queue: []}, trace())
      decisions = Enum.map(steps, &elem(&1, 1))
      assert decisions == [:pass, :pass, Map.fetch!(expected, rule), :pass, :pass, :pass]

      if rule == :queue do
        assert final == %{rule: :queue, queue: [@message]}
        assert MidRunInput.next(final) == {:ok, %{rule: :queue, queue: []}, {:deliver, @message}}
      else
        assert final == %{rule: rule, queue: []}
      end
    end

    # The report equals what the ready tracker applied on that trace up to the message.
    tracker = PatternStep.open(checked(@request))

    applied =
      for {%{"kind" => "action_outcome"} = input, _} <- Enum.take(trace(), 2),
          match?({:applied, _}, PatternStep.accept(tracker, checked(input))),
          do: input["action_id"]

    assert report == %{delivered: applied, open: ~w(tool-1 tool-2 tool-3) -- applied}

    # Two queued messages leave in arrival order; the 17th is refused.
    busy = run(:paused, [], ["tool-2"])

    {_, full} =
      Enum.map_reduce(1..16, %{rule: :queue, queue: []}, fn n, state ->
        assert {:ok, next, :queued} = MidRunInput.step(state, checked(message(n)), busy)
        {n, next}
      end)

    assert {:ok, ^full, {:refused, :queue_full}} =
             MidRunInput.step(full, checked(message(17)), busy)

    assert {:ok, rest, {:deliver, first}} = MidRunInput.next(full)
    assert {:ok, _, {:deliver, second}} = MidRunInput.next(rest)
    assert [first, second] == [message(1), message(2)]

    # The active row, once: queue delivers only with an empty queue.
    active = run(:active, [], [])
    queued = %{rule: :queue, queue: [message(1)]}

    for rule <- @rules,
        do:
          assert(
            {:ok, %{rule: rule, queue: []}, {:deliver, @message}} ==
              MidRunInput.step(%{rule: rule, queue: []}, checked(@message), active)
          )

    assert {:ok, %{queue: [_, _]}, :queued} = MidRunInput.step(queued, checked(@message), active)

    assert {:ok, ^full, {:refused, :queue_full}} =
             MidRunInput.step(full, checked(@message), active)

    # The terminal row, once.
    ended = run(:terminal, ["tool-1"], [])

    for rule <- @rules,
        do:
          assert(
            {:ok, %{rule: rule, queue: []}, {:refused, :run_ended}} ==
              MidRunInput.step(%{rule: rule, queue: []}, checked(@message), ended)
          )
  end

  test "side_run_leaves_first_run_unchanged" do
    state = %{rule: :side_run, queue: []}
    {[_, _, {after_message, decision} | _] = with_message, _} = walk(state, trace())

    assert after_message == state

    assert decision ==
             {:side_run, @message, %{delivered: ["tool-1"], open: ["tool-2", "tool-3"]}}

    {without_message, _} = walk(state, List.delete_at(trace(), 2))
    assert List.delete_at(with_message, 2) == without_message

    # The same holds with messages already queued under the rule's state.
    held = %{rule: :side_run, queue: [message(1)]}

    assert {:ok, ^held, {:side_run, _, _}} =
             MidRunInput.step(held, checked(@message), run(:waiting, [], ["tool-2"]))
  end

  test "invalid operands are redacted" do
    good = %{rule: :queue, queue: []}
    busy = run(:waiting, [], ["tool-2"])

    for {state, input, run} <- [
          {%{good | rule: :drop}, checked(@message), busy},
          {Map.put(good, :extra, 1), checked(@message), busy},
          {%{good | queue: [@wake]}, checked(@message), busy},
          {%{good | queue: List.duplicate(@message, 17)}, checked(@message), busy},
          {good, @message, busy},
          {good, checked(@request), busy},
          {good, checked(@message), run(:running, [], [])},
          {good, checked(@message), run(:waiting, ["tool-2"], ["tool-2"])},
          {good, checked(@message), run(:waiting, [""], [])},
          {good, checked(@message), Map.put(busy, :extra, 1)}
        ],
        do: assert(MidRunInput.step(state, input, run) == {:error, :invalid_shape})

    assert MidRunInput.next(%{rule: :queue}) == {:error, :invalid_shape}
  end

  test "selected Cure law and checked example" do
    source = File.read!(Path.expand("../../cure/elzoo/mid_run_input.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0

    {result, _} = Code.eval_file(Path.expand("../../examples/mid_run_input.exs", __DIR__))
    assert result == [:queued, :pass, {:deliver, "while you wait"}, :empty]
  end
end
