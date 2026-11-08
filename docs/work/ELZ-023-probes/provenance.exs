# SPDX-License-Identifier: Apache-2.0
# Reduced amendment probe only: no storage, authentication or production owner proof.
ExUnit.start(autorun: false)

defmodule Elzoo.IntentProvenanceProbeTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.join(__DIR__, "provenance.cure"))
  @events [
    :Admit,
    :Arm,
    :NoSend,
    :PermanentNoSend,
    :Lost,
    :TimedOut,
    :Failed,
    :Pending,
    :NoEffect,
    :ProviderUnknown,
    :Completed,
    :Resume,
    :Rearm,
    :Expired,
    :SchemaInvalid,
    :CapacityRefused,
    :Uncertain,
    :Recover
  ]
  setup_all do
    {:ok, m} = Cure.Compiler.compile_and_load(@source)
    %{policy_module: m}
  end

  defp state(phase, disarmed \\ false, quarantined \\ false),
    do: {:State, phase, disarmed, quarantined}

  defp cfg(opts \\ []) do
    v =
      Map.merge(
        %{
          now: 10,
          admission: 100,
          anchor: 5,
          horizon: 90,
          flight: 20,
          allowance: 5,
          replay: :ReplaySafe,
          recovery: :NoRecovery
        },
        Map.new(opts)
      )

    {:Config, v.now, v.admission, v.anchor, v.horizon, v.flight, v.allowance, v.replay, v.recovery}
  end

  defp step(m, s, e, c \\ cfg()), do: apply(m, :step, [s, e, c])
  defp next(m, s, e, c \\ cfg()), do: elem(step(m, s, e, c), 1)
  defp sent(n \\ 1), do: state({:Dispatched, :Fresh, n})

  test "seven unconditional label laws and guard instantiations have clean Cure audit" do
    assert {:ok, env} = Cure.Compiler.check_source(@source)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0
  end

  test "initial state and positive first send", %{policy_module: m} do
    assert apply(m, :initial, []) == state(:Empty)
    i = next(m, state(:Empty), :Admit)
    assert i == state({:Intended, :Fresh, 0})
    assert step(m, i, :Arm) == {:Decision, sent(), :Dispatch}
  end

  test "all grounds preserve provenance and increment only on send", %{policy_module: m} do
    for {e, g} <- [
          {:NoSend, :AdapterNoSend},
          {:NoEffect, :ProviderNoEffect},
          {:ProviderUnknown, :ProviderReplaySafe}
        ] do
      d = next(m, sent(), e)
      assert d == state({:Definite, g, 1})
      i = next(m, d, :Rearm)
      assert i == state({:Intended, {:After, g}, 1})
      assert step(m, i, :Arm) == {:Decision, state({:Dispatched, {:After, g}, 2}), :Dispatch}
    end
  end

  test "observation alone never grants replay, regardless of capability", %{policy_module: m} do
    for e <- [:Pending, :Lost, :TimedOut, :Failed, :Resume], cap <- [:NoReplay, :ReplaySafe] do
      assert step(m, sent(), e, cfg(replay: cap)) == {:Decision, sent(), :Poll}
    end

    assert step(m, sent(), :ProviderUnknown, cfg(replay: :NoReplay)) ==
             {:Decision, state({:Stranded, 1}), :Reconcile}
  end

  test "admission boundary, attempt ceilings and malformed origin counters", %{policy_module: m} do
    first = state({:Intended, :Fresh, 0})
    assert elem(step(m, first, :Arm, cfg(now: 99)), 2) == :Dispatch

    for c <- [cfg(now: 100), cfg(now: -1), cfg(admission: 9_223_372_036_854_775_808)] do
      assert elem(step(m, first, :Arm, c), 2) == :Stop
    end

    for {origin, n} <- [
          {:Fresh, 1},
          {:Fresh, -1},
          {{:After, :AdapterNoSend}, 0},
          {{:After, :AdapterNoSend}, 256}
        ] do
      assert elem(step(m, state({:Intended, origin, n}), :Arm), 2) == :Stop
    end

    assert elem(step(m, state({:Intended, {:After, :AdapterNoSend}, 255}), :Arm), 2) == :Dispatch

    assert next(m, state({:Definite, :AdapterNoSend, 256}), :Rearm) ==
             state({:Definite, :AdapterNoSend, 256})
  end

  test "replay horizon is rechecked at rearm and actual send", %{policy_module: m} do
    d = state({:Definite, :ProviderReplaySafe, 1})
    assert next(m, d, :Rearm, cfg(now: 65)) == state({:Intended, {:After, :ProviderReplaySafe}, 1})

    for c <- [
          cfg(now: 66),
          cfg(flight: -1),
          cfg(allowance: -1),
          cfg(now: 4),
          cfg(anchor: -1),
          cfg(replay: :NoReplay),
          cfg(horizon: 9_223_372_036_854_775_808)
        ] do
      assert next(m, d, :Rearm, c) == d

      assert elem(step(m, state({:Intended, {:After, :ProviderReplaySafe}, 1}), :Arm, c), 2) ==
               :Stop
    end
  end

  test "schema and permanent rejection disarm, no new attempt before reservation", %{
    policy_module: m
  } do
    i = state({:Intended, :Fresh, 0})
    assert next(m, i, :SchemaInvalid) == state({:Intended, :Fresh, 0}, true)
    d = next(m, sent(), :PermanentNoSend)
    assert d == state({:Definite, :AdapterNoSend, 1}, true)
    assert next(m, d, :Rearm) == d
    assert elem(step(m, next(m, i, :CapacityRefused), :Arm), 2) == :Stop
  end

  test "recovery expiry strands; admission expiry alone does not", %{policy_module: m} do
    assert step(m, sent(), :Expired, cfg(now: 100)) == {:Decision, sent(), :Poll}

    assert step(m, sent(), :Expired, cfg(now: 109, recovery: {:RecoveryAt, 110})) ==
             {:Decision, sent(), :Poll}

    assert step(m, sent(), :Expired, cfg(now: 110, recovery: {:RecoveryAt, 110})) ==
             {:Decision, state({:Stranded, 1}), :Reconcile}

    for e <- @events do
      assert elem(step(m, state({:Stranded, 1}), e), 2) != :Dispatch
      assert elem(step(m, state({:Confirmed, 1}), e), 2) != :Dispatch
    end
  end

  test "uncertain/recovered state is read-only until external reconciliation", %{policy_module: m} do
    for p <- [{:Intended, :Fresh, 0}, {:Definite, :AdapterNoSend, 1}, {:Dispatched, :Fresh, 1}],
        e <- [:Uncertain, :Recover] do
      q = next(m, state(p), e)
      assert q == state(p, false, true)
      for event <- @events, do: assert(step(m, q, event) == {:Decision, q, :Stop})
    end
  end

  test "silent returns, groundless/incorrect grounds, count/reset and stray-send mutations fail conversion" do
    silent =
      for e <- [:Pending, :Expired, :Resume, :Lost, :TimedOut, :Failed] do
        from =
          if e == :Expired,
            do: "          Expired() ->\n            match expired",
            else: "          Completed() -> move(state, Confirmed(n), Stop())"

        to =
          if e == :Expired,
            do:
              "          Expired() -> move(state, Intended(Fresh(), n), Stop())\n          SchemaInvalid() ->\n            match expired",
            else: "          #{e}() -> move(state, Intended(Fresh(), n), Stop())\n" <> from

        {to_string(e), from, to}
      end

    other = [
      {"Groundless", "NoSend() -> move(state, Definite(AdapterNoSend(), n), Stop())",
       "NoSend() -> move(state, Intended(After(AdapterNoSend()), n), Stop())"},
      {"WrongGround", "NoSend() -> move(state, Definite(AdapterNoSend(), n), Stop())",
       "NoSend() -> move(state, Definite(ProviderNoEffect(), n), Stop())"},
      {"Reset", "_ -> move(state, state.phase, Poll())", "_ -> move(state, Empty(), Stop())"},
      {"Count", "Dispatched(origin, n + 1), Dispatch()", "Dispatched(origin, n), Dispatch()"},
      {"StrayDispatch", "Confirmed(n) -> keep(state)",
       "Confirmed(n) -> move(state, state.phase, Dispatch())"}
    ]

    for {name, from, to} <- silent ++ other do
      assert String.contains?(@source, from)

      src =
        @source
        |> String.replace("Elzoo.IntentProvenanceProbe", "Elzoo.ProvenanceMutation" <> name)
        |> String.replace(from, to, global: false)

      assert {:error, reason} = Cure.Compiler.check_source(src)
      assert inspect(reason, limit: :infinity) =~ "conversion_failure", name
      IO.puts("Rejected policy mutation: " <> name)
    end
  end

  test "always-stop fails the positive dispatch gate even without proofs" do
    [runtime | _] = String.split(@source, "  fn empty_never_recreated_gated", parts: 2)
    # Keep definitions, drop proof declarations, mutate the actual send action.
    runtime =
      runtime
      |> String.replace("Elzoo.IntentProvenanceProbe", "Elzoo.ProvenanceAlwaysStop")
      |> String.replace(
        "Dispatched(origin, n + 1), Dispatch()",
        "Dispatched(origin, n + 1), Stop()"
      )

    {:ok, m} = Cure.Compiler.compile_and_load(runtime <> "end\n")
    refute elem(step(m, state({:Intended, :Fresh, 0}), :Arm), 2) == :Dispatch
  end
end

result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
IO.puts("Result: #{result.total} passed (provenance amendment probe)")
