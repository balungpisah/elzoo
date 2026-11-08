# SPDX-License-Identifier: Apache-2.0
# Run with MIX_ENV=test mix run --no-start docs/work/ELZ-023-probes/probe.exs
# Scratch feasibility against a proposed amendment, NOT production acceptance.
ExUnit.start(autorun: false)

defmodule Elzoo.IntentProposalProbeTest do
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Record}
  @source File.read!(Path.join(__DIR__, "policy.cure"))
  @events [:Admit, :Arm, :NoSend, :Lost, :Pending, :NoEffect, :ProviderUnknown,
           :Completed, :Resume, :Rearm, :Expired]
  @caps [:NoReplay, :ReplaySafe]
  @limits %{max_record_bytes: 4096, max_batch_size: 8, max_checkpoint_bytes: 65_536}

  setup_all do
    {:ok, module} = Cure.Compiler.compile_and_load(@source)
    %{policy_module: module}
  end

  defp fold do
    %{initial: "none", kinds: %{"intent" => :state_bearing}, versions: [1],
      reduce: fn _, _, _, bytes -> bytes end}
  end

  defp row(seq, payload, nonce) do
    r = %Record{stream: "intent-probe", sequence: seq, kind: "intent",
      schema_version: 1, payload: payload, nonce: nonce}
    %{r | digest: Log.digest(r)}
  end

  test "four proposed core laws check with a clean audit" do
    assert {:ok, env} = Cure.Compiler.check_source(@source)
    audit = Cure.Audit.Ledger.audit_env(env)
    for key <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total],
      do: assert(Map.fetch!(audit, key) == [])
    assert audit.absurd == 0
  end

  test "finite proposed phase/event/capability table and positive dispatch", %{policy_module: m} do
    phases = [:Empty, :Intended, :Dispatched, :Confirmed, :Stranded] ++
      Enum.map([:AdapterNoSend, :ProviderNoEffect, :ProviderReplaySafe], &{:Definite, &1})
    for p <- phases, e <- @events, c <- @caps do
      assert {:Decision, _, action} = apply(m, :next, [p, e, c])
      assert action in [:Dispatch, :Poll, :Reconcile, :Stop]
      if action == :Dispatch, do: assert(p == :Intended and e == :Arm)
    end
    assert {:Decision, :Intended, :Stop} = apply(m, :next, [:Empty, :Admit, :NoReplay])
    assert {:Decision, :Dispatched, :Dispatch} = apply(m, :next, [:Intended, :Arm, :NoReplay])
    assert {:Decision, :Dispatched, :Poll} = apply(m, :next, [:Dispatched, :Lost, :ReplaySafe])
    assert {:Decision, :Confirmed, :Stop} = apply(m, :next, [:Dispatched, :Completed, :NoReplay])
  end

  test "each rearm ground and stranded/expiry outcomes", %{policy_module: m} do
    for {event, cap, ground} <- [{:NoSend, :NoReplay, :AdapterNoSend},
          {:NoEffect, :NoReplay, :ProviderNoEffect},
          {:ProviderUnknown, :ReplaySafe, :ProviderReplaySafe}] do
      assert {:Decision, {:Definite, ^ground}, :Stop} = apply(m, :next, [:Dispatched, event, cap])
      assert {:Decision, :Intended, :Stop} = apply(m, :next, [{:Definite, ground}, :Rearm, cap])
    end
    assert {:Decision, :Stranded, :Reconcile} = apply(m, :next, [:Dispatched, :ProviderUnknown, :NoReplay])
    assert {:Decision, :Stranded, :Reconcile} = apply(m, :next, [:Dispatched, :Expired, :ReplaySafe])
    for e <- @events, c <- @caps,
      do: assert(apply(m, :next, [:Stranded, e, c]) == {:Decision, :Stranded, :Stop})
  end

  test "three actual-core mutations fail Cure checking" do
    for {name, from, to} <- [
      {"BypassGround", "NoSend() -> Decision{phase: Definite(AdapterNoSend()), action: Stop()}",
        "NoSend() -> Decision{phase: Intended(), action: Dispatch()}"},
      {"UnknownUnsafe", "NoReplay() -> Decision{phase: Stranded(), action: Reconcile()}",
        "NoReplay() -> Decision{phase: Definite(ProviderReplaySafe()), action: Stop()}"},
      {"LostRearmed", "_ -> Decision{phase: Dispatched(), action: Poll()}",
        "_ -> Decision{phase: Definite(ProviderNoEffect()), action: Stop()}"}
    ] do
      assert String.contains?(@source, from)
      mutated = @source |> String.replace("Elzoo.IntentProbe", "Elzoo.IntentProbe" <> name)
        |> String.replace(from, to, global: false)
      assert {:error, reason} = Cure.Compiler.check_source(mutated)
      assert inspect(reason) =~ "conversion_failure"
    end
  end

  test "accepted Envelope rejects the task's unknown/not_dispatched combination" do
    result = %{"version" => 1, "message_id" => "operation", "correlation_id" => "operation",
      "attempt_id" => "attempt-1", "outcome" => "unknown", "dispatch" => "not_dispatched",
      "error_class" => "retryable"}
    assert {:error, _} = Elzoo.Envelope.validate_result(result)
    assert {:ok, _} = Elzoo.Envelope.validate_result(%{result | "outcome" => "timed_out"})
    assert {:ok, _} = Elzoo.Envelope.validate_result(%{result | "outcome" => "rejected"})
  end

  test "literal direct intended trace contradicts the unqualified through-definite law" do
    # This is an explicit abstract counterexample to two prose obligations,
    # not a claim that a production implementation exists.
    literal_trace = [:intended, :dispatched, :intended, :dispatched]
    assert Enum.count(literal_trace, &(&1 == :dispatched)) == 2
    refute :failed_definite in literal_trace
  end

  test "accepted Store checkpoints recover dispatched plus a terminal tail" do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    s = Memory.store(pid, %{fold: fold()})
    r1 = row(1, "intended", <<1::128>>)
    r2 = row(2, "dispatched", <<2::128>>)
    assert {:committed, 1} = Memory.append(s, "intent-probe", 0, [r1], [])
    assert {:committed, 1} = Elzoo.Checkpoint.take({s, Log.replay([r1], 1, fold()), @limits}, "intent-probe", 1, &Function.identity/1)
    assert {:committed, 2} = Memory.append(s, "intent-probe", 1, [r2], [])
    assert {:committed, 2} = Elzoo.Checkpoint.take({s, Log.replay([r1, r2], 2, fold()), @limits}, "intent-probe", 1, &Function.identity/1)
    assert %{model: "dispatched", cursor: {2, false, []}} =
      Elzoo.Checkpoint.recover(s, "intent-probe", fold(), 1, &{:ok, &1})
    r3 = row(3, "confirmed", <<3::128>>)
    assert {:committed, 3} = Memory.append(s, "intent-probe", 2, [r3], [])
    assert %{model: "confirmed", cursor: {3, false, []}} =
      Elzoo.Checkpoint.recover(s, "intent-probe", fold(), 1, &{:ok, &1})
    assert {:conflict, _} = Memory.append(s, "intent-probe", 2, [row(3, "failed", <<4::128>>)], [])
  end

  test "indeterminate append absence cannot certify no send or rollback" do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    s = Memory.store(pid, %{fold: fold()})
    r = row(1, "dispatched", <<1::128>>)
    assert :ok = Memory.fault(s, :append, {:pause, :late_commit})
    assert {:indeterminate, _} = Memory.append(s, "intent-probe", 0, [r], [])
    assert {:unknown, :unfenced} = Log.confirm(s, "intent-probe", 0, r.nonce, [r])
    assert {:committed, 1} = Memory.release(s, :late_commit)
    assert {:committed, 1} = Log.confirm(s, "intent-probe", 0, r.nonce, [r])
  end
end

result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
IO.puts("Result: #{result.total} passed (proposal probes; not production acceptance)")
