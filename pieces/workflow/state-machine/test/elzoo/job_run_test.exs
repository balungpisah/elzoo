# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.JobRunTest do
  use ExUnit.Case, async: false
  alias Elzoo.JobRun
  @source File.read!(Path.expand("../../cure/elzoo/job_run.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @laws ~w(succeeded_absorbing failed_absorbing exhausted_absorbing expired_absorbing
           cancelled_absorbing stale_completed_ignored_requested stale_completed_ignored_waiting
           stale_completed_ignored_active stale_failed_ignored_requested stale_failed_ignored_waiting
           stale_failed_ignored_active duplicate_yields_requested duplicate_yields_waiting
           duplicate_yields_active stale_start_never_begins_requested stale_start_never_begins_waiting
           stale_start_never_begins_active requested_completed_ignored requested_failed_ignored
           waiting_completed_ignored cancel_from_requested cancel_from_waiting cancel_from_active
           expired_never_begins_requested expired_never_begins_waiting expired_never_begins_active
           exhausted_never_begins late_success_expires permanent_not_retried)

  test "L1–L29 compile and audit clean; six negative controls are rejected" do
    assert {:module, :"Cure.Elzoo.JobRun"} = Code.ensure_loaded(:"Cure.Elzoo.JobRun")
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0
    exports = :"Cure.Elzoo.JobRun".module_info(:exports) |> Enum.map(&elem(&1, 0))
    for law <- @laws, do: assert(String.to_atom(law) in exports)
    IO.puts("ELZ-010 JobRun laws compiled: #{length(@laws)}")

    for {name, law, from, to} <- [
          {"FalseLaw", "succeeded_absorbing",
           "step(RunSucceeded(), input, expired, retry), keep(RunSucceeded())) =\n    reflexive(keep(RunSucceeded()))",
           "step(RunSucceeded(), input, expired, retry), keep(RunActive())) =\n    reflexive(keep(RunActive()))"},
          {"CancelRevivesSucceeded", "succeeded_absorbing",
           "RunSucceeded() -> keep(RunSucceeded())",
           "RunSucceeded() -> idle(RunSucceeded(), input, expired)"},
          {"ExhaustedBegins", "exhausted_never_begins",
           "DecideExhausted() -> RunStep{phase: RunExhausted(), action: RecordExhausted()}\n      DecidePermanent() -> keep(RunActive())",
           "DecideExhausted() -> begin()\n      DecidePermanent() -> keep(RunActive())"},
          {"StaleCompletes", "stale_completed_ignored_active",
           "StaleCompleted() -> keep(RunActive())",
           "StaleCompleted() -> RunStep{phase: RunSucceeded(), action: RecordSuccess()}"},
          {"DuplicateBegins", "duplicate_yields_active",
           "StartDuplicate() -> yield_to(RunActive())", "StartDuplicate() -> begin()"},
          {"StaleStartBegins", "stale_start_never_begins_active",
           "StartStale() -> stale_start(RunActive())", "StartStale() -> begin()"}
        ] do
      # name: the mutation; law: the law it must break. Cure's diagnostic
      # carries the failing line (proof_name is nil on this pinned release),
      # so the line is mapped back to its enclosing law declaration.
      assert String.contains?(@source, from)

      wrong =
        @source
        |> String.replace("mod Elzoo.JobRun", "mod Elzoo.JobRun" <> name)
        |> String.replace(from, to, global: false)

      assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, context}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)

      assert law_at(wrong, context.line) == law,
             "#{name} failed at line #{context.line} (#{law_at(wrong, context.line)}), expected #{law}"

      IO.puts("ELZ-010 JobRun negative rejected: #{name} at line #{context.line} in #{law}")
    end
  end

  defp law_at(source, line) do
    source
    |> String.split("\n")
    |> Enum.take(line)
    |> Enum.reverse()
    |> Enum.find_value(fn text ->
      case Regex.run(~r/^  fn (\w+)\(/, text) do
        [_, name] -> name
        nil -> nil
      end
    end)
  end

  # Independent Elixir reference of the Contract table, compared exhaustively.
  defp expected(phase, input, expired, retry) do
    cond do
      JobRun.terminal?(phase) -> {phase, :no_change}
      input == :cancel -> {:cancelled, :record_cancel}
      input == :duplicate_start -> {phase, :yield_duplicate}
      input == :stale_start -> {phase, :yield_stale}
      phase in [:requested, :waiting] and input == :start and expired -> {:expired, :record_expired}
      phase in [:requested, :waiting] and input == :start -> {:active, :begin_attempt}
      phase in [:requested, :waiting] -> {phase, :no_change}
      input in [:stale_completed, :stale_failed] -> {:active, :no_change}
      expired -> {:expired, :record_expired}
      input == :current_completed -> {:succeeded, :record_success}
      input == :current_failed and retry == :retry -> {:waiting, :schedule_retry}
      input == :current_failed and retry == :exhausted -> {:exhausted, :record_exhausted}
      input == :current_failed -> {:failed, :record_failure}
      input == :start and retry == :retry -> {:active, :begin_attempt}
      input == :start and retry == :exhausted -> {:exhausted, :record_exhausted}
      input == :start -> {:active, :no_change}
    end
  end

  test "step/4 matches the Contract table over every phase, input, expiry and retry decision" do
    inputs =
      ~w(start duplicate_start stale_start current_completed current_failed stale_completed stale_failed cancel)a

    rows =
      for phase <- JobRun.phases(),
          input <- inputs,
          expired <- [true, false],
          retry <- ~w(retry exhausted permanent settle unresolved)a do
        assert JobRun.step(phase, input, expired, retry) ==
                 {:ok, expected(phase, input, expired, retry)},
               inspect({phase, input, expired, retry})
      end

    assert length(rows) == 8 * 8 * 2 * 5
  end

  test "identity classification (test-grounded integer comparisons) and input validation" do
    assert JobRun.start_input(0, 7, 0, 1) == {:ok, :start}
    assert JobRun.start_input(7, 7, 2, 2) == {:ok, :start}
    assert JobRun.start_input(7, 7, 2, 3) == {:ok, :start}
    assert JobRun.start_input(7, 7, 3, 2) == {:ok, :stale_start}
    assert JobRun.start_input(7, 8, 1, 5) == {:ok, :duplicate_start}
    assert JobRun.result_input(true, 2, 2) == {:ok, :current_completed}
    assert JobRun.result_input(false, 2, 2) == {:ok, :current_failed}
    assert JobRun.result_input(true, 1, 2) == {:ok, :stale_completed}
    assert JobRun.result_input(false, 1, 0) == {:ok, :stale_failed}
    assert JobRun.start_input(-1, 7, 0, 1) == {:error, :invalid_start}
    assert JobRun.result_input(:yes, 1, 1) == {:error, :invalid_result}
    assert JobRun.step(:unknown, :start, false, :retry) == {:error, :invalid_phase}
    assert JobRun.step(:active, :bogus, false, :retry) == {:error, :invalid_input}
    assert JobRun.step(:active, :start, :no, :retry) == {:error, :invalid_expired}
    assert JobRun.step(:active, :start, false, :maybe) == {:error, :invalid_retry}
  end

  test "retry decisions come from the unchanged ELZ-006 policy" do
    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 2)
    assert JobRun.retry_decision(policy, 0, :retryable) == {:ok, :retry}
    assert JobRun.retry_decision(policy, 1, :retryable) == {:ok, :retry}
    assert JobRun.retry_decision(policy, 2, :retryable) == {:ok, :exhausted}
    assert JobRun.retry_decision(policy, 1, :permanent) == {:ok, :permanent}
    assert JobRun.retry_decision(policy, 1, :dispatched) == {:error, :invalid_class}
  end
end
