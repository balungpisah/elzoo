# SPDX-License-Identifier: Apache-2.0
# ELZ-010 Contract-proposal probe: compiles test/fixtures/elz010_job_run_probe.cure
# with the unchanged Elzoo.RetryPolicy, audits it and checks negative controls.
# Exploration evidence for docs/work/ELZ-010.md; not a ready Piece.
defmodule Elzoo.Elz010CureProbeTest do
  use ExUnit.Case, async: false
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @source File.read!(Path.expand("fixtures/elz010_job_run_probe.cure", __DIR__))
  @laws ~w(succeeded_absorbing failed_absorbing exhausted_absorbing expired_absorbing
           cancelled_absorbing stale_completed_ignored_requested stale_completed_ignored_waiting
           stale_completed_ignored_active stale_failed_ignored_requested stale_failed_ignored_waiting
           stale_failed_ignored_active duplicate_yields_requested duplicate_yields_waiting
           duplicate_yields_active requested_completed_ignored requested_failed_ignored
           waiting_completed_ignored cancel_from_requested cancel_from_waiting cancel_from_active
           expired_never_begins_requested expired_never_begins_waiting expired_never_begins_active
           exhausted_never_begins late_success_expires permanent_not_retried)

  test "probe laws compile and audit clean; four negative controls are rejected" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0
    assert {:ok, module} = Cure.Compiler.compile_and_load(@source, source_roots: @roots)

    for law <- @laws,
        do: assert(Enum.any?(module.module_info(:exports), &(elem(&1, 0) == String.to_atom(law))))

    IO.puts("ELZ-010 probe laws compiled: #{length(@laws)}")

    for {name, from, to} <- [
          {"FalseLaw",
           "step(RunSucceeded(), input, expired, retry), keep(RunSucceeded())) =\n    reflexive(keep(RunSucceeded()))",
           "step(RunSucceeded(), input, expired, retry), keep(RunActive())) =\n    reflexive(keep(RunActive()))"},
          {"CancelRevivesSucceeded", "RunSucceeded() -> keep(RunSucceeded())",
           "RunSucceeded() -> idle(RunSucceeded(), input, expired)"},
          {"ExhaustedBegins",
           "DecideExhausted() -> RunStep{phase: RunExhausted(), action: RecordExhausted()}\n      DecidePermanent() -> keep(RunActive())",
           "DecideExhausted() -> begin()\n      DecidePermanent() -> keep(RunActive())"},
          {"StaleCompletes", "StaleCompleted() -> keep(RunActive())",
           "StaleCompleted() -> RunStep{phase: RunSucceeded(), action: RecordSuccess()}"}
        ] do
      assert String.contains?(@source, from)

      wrong =
        @source
        |> String.replace("mod Elzoo.JobRunProbe", "mod Elzoo.JobRunProbe" <> name)
        |> String.replace(from, to, global: false)

      assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)

      IO.puts("ELZ-010 probe negative rejected: #{name}")
    end
  end

  test "probe identity classification and listed transitions (test-grounded Int comparisons)" do
    {:ok, m} = Cure.Compiler.compile_and_load(@source, source_roots: @roots)
    assert m.start_input(0, 7) == :StartAttempt
    assert m.start_input(7, 7) == :StartAttempt
    assert m.start_input(7, 8) == :StartDuplicate
    assert m.result_input(true, 2, 2) == :CurrentCompleted
    assert m.result_input(true, 1, 2) == :StaleCompleted
    assert m.result_input(false, 1, 0) == :StaleFailed

    assert m.step(:RunActive, :StaleCompleted, false, :DecideRetry) ==
             {:RunStep, :RunActive, :NoChange}

    assert m.step(:RunActive, :CurrentFailed, false, :DecideRetry) ==
             {:RunStep, :RunWaiting, :ScheduleRetry}

    assert m.step(:RunActive, :StartDuplicate, false, :DecideRetry) ==
             {:RunStep, :RunActive, :YieldDuplicate}

    assert m.step(:RunWaiting, :StartAttempt, true, :DecideRetry) ==
             {:RunStep, :RunExpired, :RecordExpired}
  end
end
