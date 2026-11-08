# SPDX-License-Identifier: Apache-2.0
# Candidate host protocol over existing Store; Memory proves process-boundary
# behaviour only. It does not prove host durability, authentication or fencing.
ExUnit.start(autorun: false)

defmodule Elzoo.IntentRecoveryProbe do
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Record}
  @max 9_223_372_036_854_775_807
  def fold,
    do: %{
      initial: "",
      kinds: %{"intent" => :state_bearing},
      versions: [1],
      reduce: fn _, _, _, b -> b end
    }

  def limits, do: %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

  def row(stream, seq, payload, nonce) do
    r = %Record{
      stream: stream,
      sequence: seq,
      kind: "intent",
      schema_version: 1,
      payload: payload,
      nonce: nonce
    }

    %{r | digest: Log.digest(r)}
  end

  # :fresh is a host-certified never-activated logical key, never inferred from
  # an absent intent row. Every other startup is read-only until explicit grant.
  def activate(store, key, mode, nonce) do
    with :fresh <- mode,
         {:ok, %{revision: 0}} <- Memory.head(store, "host/" <> key),
         r = row("host/" <> key, 1, "active", nonce),
         {:committed, 1} <- Memory.append(store, r.stream, 0, [r], []) do
      {:active, %{key: key, generation: 1, nonce: nonce}}
    else
      _ -> {:read_only, :host_reconciliation_required}
    end
  end

  # Called only by the host/operator after finalising/fencing outstanding writes,
  # validating provider outcome and old-owner safety; the proof is an upstream Need.
  # The receipt binds the exact recovered intent head/digest, never a bare boolean.
  def reconcile(store, key, expected, proof, nonce) do
    with %{
           authoritative: true,
           writes_resolved: true,
           old_owner_safe: true,
           intent_revision: revision,
           intent_digest: digest
         } <- proof,
         true <- is_integer(revision) and revision >= 0 and byte_size(digest) == 32,
         payload = <<revision::64, digest::binary>>,
         r = row("host/" <> key, expected + 1, payload, nonce),
         {:committed, generation} <- Memory.append(store, r.stream, expected, [r], []) do
      {:active,
       %{
         key: key,
         generation: generation,
         nonce: nonce,
         intent_revision: revision,
         intent_digest: digest
       }}
    else
      _ -> {:read_only, :host_reconciliation_required}
    end
  end

  def evidence_write(store, key, expected, payload, nonce) do
    r = row(key, expected + 1, payload, nonce)

    case Memory.append(store, key, expected, [r], []) do
      {:committed, n} -> {:retained, n}
      other -> {:halt, :not_retained, other}
    end
  end

  def recovery_deadline(deadline, grace) do
    cond do
      not is_integer(deadline) or deadline < 0 or deadline > @max -> {:error, :deadline}
      grace == :none -> {:ok, :none}
      not is_integer(grace) or grace < 0 -> {:error, :grace}
      grace > @max - deadline -> {:error, :overflow}
      true -> {:ok, deadline + grace}
    end
  end

  # Finite candidate classification of an authenticated, matching old completion.
  # Full identity/schema/authentication checks are an integration gate.
  def completion(terminal?, matching?, intervening_grounds) do
    cond do
      not matching? ->
        :refused

      Enum.any?(intervening_grounds, &(&1 in [:adapter_no_send, :provider_no_effect])) ->
        :contradiction_freeze

      terminal? ->
        :operator_evidence

      Enum.all?(intervening_grounds, &(&1 == :provider_replay_safe)) ->
        :confirm

      true ->
        :refused
    end
  end
end

defmodule Elzoo.IntentRecoveryProbeTest do
  use ExUnit.Case, async: false
  alias Elzoo.IntentRecoveryProbe, as: P
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Memory

  setup do
    pid = start_supervised!({Memory, fold: P.fold(), limits: P.limits()})
    %{store: Memory.store(pid, %{fold: P.fold()})}
  end

  test "crashed owner leaves host activation obligation across process restart", %{store: s} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:activated, P.activate(s, "key", :fresh, <<1::128>>)})

        receive do
          :crash -> exit(:simulated_crash)
        end
      end)

    assert_receive {:activated, {:active, %{generation: 1}}}
    send(pid, :crash)
    assert_receive {:DOWN, ^ref, :process, ^pid, :simulated_crash}
    # A restarted process sees a superficially harmless intended row; host marker wins.
    r = P.row("key", 1, "intended", <<2::128>>)
    assert {:committed, 1} = Memory.append(s, "key", 0, [r], [])

    assert P.activate(s, "key", :recovery, <<3::128>>) ==
             {:read_only, :host_reconciliation_required}

    assert P.activate(s, "key", :fresh, <<4::128>>) == {:read_only, :host_reconciliation_required}

    assert P.activate(s, "absent", :recovery, <<5::128>>) ==
             {:read_only, :host_reconciliation_required}
  end

  test "indeterminate activation does not grant ownership; delayed commit cannot grant retroactively",
       %{store: s} do
    assert :ok = Memory.fault(s, :append, {:pause, :activation})
    assert {:read_only, _} = P.activate(s, "key", :fresh, <<1::128>>)
    assert {:committed, 1} = Memory.release(s, :activation)
    assert {:read_only, _} = P.activate(s, "key", :fresh, <<2::128>>)
  end

  test "contradiction evidence write uncertainty halts and restart is read-only", %{store: s} do
    assert {:active, _} = P.activate(s, "key", :fresh, <<1::128>>)
    r = P.row("key", 1, "failed_definite:no_send", <<2::128>>)
    assert {:committed, 1} = Memory.append(s, "key", 0, [r], [])
    assert :ok = Memory.fault(s, :append, {:pause, :contradiction})

    assert {:halt, :not_retained, {:indeterminate, _}} =
             P.evidence_write(s, "key", 1, "contradiction", <<3::128>>)

    pending = P.row("key", 2, "contradiction", <<3::128>>)
    assert {:unknown, :unfenced} = Log.confirm(s, "key", 1, pending.nonce, [pending])
    assert {:read_only, _} = P.activate(s, "key", :recovery, <<4::128>>)
    assert {:committed, 2} = Memory.release(s, :contradiction)
    assert {:committed, 2} = Log.confirm(s, "key", 1, pending.nonce, [pending])
    # Resolving the intent write alone does not clear the host obligation.
    assert {:read_only, _} = P.activate(s, "key", :recovery, <<5::128>>)

    proof = %{
      authoritative: true,
      writes_resolved: true,
      old_owner_safe: true,
      intent_revision: 2,
      intent_digest: pending.digest
    }

    assert {:read_only, _} = P.reconcile(s, "key", 1, %{proof | writes_resolved: false}, <<6::128>>)

    assert {:active, %{generation: 2, intent_revision: 2, intent_digest: digest}} =
             P.reconcile(s, "key", 1, proof, <<7::128>>)

    assert digest == pending.digest
    assert {:read_only, _} = P.reconcile(s, "key", 1, proof, <<8::128>>)
  end

  test "a refused evidence write is never reported retained", %{store: s} do
    assert {:halt, :not_retained, {:rejected, :record_too_large}} =
             P.evidence_write(s, "key", 0, String.duplicate("x", 131_073), <<1::128>>)
  end

  test "unavailable host or evidence storage grants no activation or retained result", %{store: s} do
    assert :ok = Memory.fault(s, :head, :unavailable)
    assert {:read_only, _} = P.activate(s, "key", :fresh, <<1::128>>)
    assert :ok = Memory.fault(s, :append, :unavailable)

    assert {:halt, :not_retained, {:indeterminate, _}} =
             P.evidence_write(s, "key", 0, "contradiction", <<2::128>>)
  end

  test "old completion eligibility, contradiction and terminal operator paths" do
    for current <- [:intended_after, :failed_definite, :dispatched],
        grounds <- [[], [:provider_replay_safe], List.duplicate(:provider_replay_safe, 255)] do
      assert current in [:intended_after, :failed_definite, :dispatched]
      assert P.completion(false, true, grounds) == :confirm
    end

    for ground <- [:adapter_no_send, :provider_no_effect], terminal <- [false, true] do
      assert P.completion(terminal, true, [:provider_replay_safe, ground]) == :contradiction_freeze
    end

    assert P.completion(false, false, [:provider_replay_safe]) == :refused
    assert P.completion(false, false, [:adapter_no_send]) == :refused
    assert P.completion(true, true, [:provider_replay_safe]) == :operator_evidence
  end

  test "recovery grace default, zero, boundary and signed-bigint overflow" do
    assert {:ok, :none} = P.recovery_deadline(100, :none)
    assert {:ok, 100} = P.recovery_deadline(100, 0)
    assert {:ok, 120} = P.recovery_deadline(100, 20)
    assert {:ok, 9_223_372_036_854_775_807} = P.recovery_deadline(9_223_372_036_854_775_806, 1)
    assert {:error, :overflow} = P.recovery_deadline(9_223_372_036_854_775_807, 1)
    assert {:error, :grace} = P.recovery_deadline(100, -1)
  end
end

result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
IO.puts("Result: #{result.total} passed (host recovery amendment probe)")
