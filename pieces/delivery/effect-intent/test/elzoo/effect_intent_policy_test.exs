# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/effect_intent_test_helper.exs", __DIR__)

defmodule Elzoo.EffectIntent.PolicyTest do
  use ExUnit.Case, async: false
  alias Elzoo.EffectIntent.{Binding, Model, Policy, TestBinding}
  @source File.read!(Path.expand("../../cure/elzoo/effect_intent.cure", __DIR__))
  setup do
    {:ok, b} = Binding.load(TestBinding)
    {:ok, c} = Policy.config(b, 5000, 100, 100)
    %{binding: b, config: c}
  end

  defp next(s, e, c, n \\ nil) do
    {:Decision, next, _} = Policy.decide(s, e, n || Policy.count(s), c)
    next
  end

  defp sent(c), do: Policy.initial() |> next(:Admit, c) |> next(:Arm, c)

  defp check_error(source) do
    assert {:error, error} = Cure.Compiler.check_source(source)
    assert inspect(error, limit: :infinity) =~ "conversion_failure"
  end

  test "production Cure laws and complete audit have no proof escape hatch" do
    assert {:ok, env} = Cure.Compiler.check_source(@source)
    audit = Cure.Audit.Ledger.audit_env(env)

    for k <- [:axioms, :opaque, :holes, :unresolved, :unaudited, :not_proven_total],
        do: assert(Map.fetch!(audit, k) == [])

    assert audit.absurd == 0
  end

  test "silent-return, groundless, reset, wrong-ground and count mutations fail actual production laws" do
    start = "          Completed() -> move(state, Confirmed(n), Stop())"
    # Restrict replacement to the dispatched arm, not the newly supported old completion arms.
    {offset, _} = :binary.match(@source, "      Dispatched(origin, n) ->\n        match event")
    {prefix, tail} = String.split_at(@source, offset)

    for event <- [:Pending, :Resume, :Lost, :TimedOut, :Failed] do
      mutated =
        prefix <>
          String.replace(
            tail,
            start,
            "          #{event}() -> move(state, Intended(Fresh(), n), Stop())\n" <> start,
            global: false
          )

      check_error(mutated)
    end

    for {from, to} <- [
          {"False() -> move(state, state.phase, Poll())",
           "False() -> move(state, Intended(Fresh(), n), Stop())"},
          {"NoSend() -> settled(state, AdapterNoSend(), n, SentNoBytes())",
           "NoSend() -> move(state, Intended(After(AdapterNoSend()), n), Stop())"},
          {"NoSend() -> settled(state, AdapterNoSend(), n, SentNoBytes())",
           "NoSend() -> settled(state, ProviderNoEffect(), n, SentNoBytes())"},
          {"_ -> move(state, state.phase, Poll())", "_ -> move(state, Empty(), Stop())"},
          {"Dispatched(origin, n + 1)", "Dispatched(origin, n)"},
          {"carry_replay(state.replay_dependent, ground)", "False()"}
        ] do
      assert String.contains?(@source, from)
      check_error(String.replace(@source, from, to, global: false))
    end
  end

  test "always-stop and horizon removal mutants fail executable positive/safety gates", c do
    # Keep the actual runtime and helpers, omit proof declarations only in a
    # scratch module so scenario failures cannot be masked by proof rejection.
    [runtime | _] = String.split(@source, "  fn replay_dependence_never_cleared", parts: 2)

    for {label, from, to} <- [
          {"Stop", "action: Dispatch()}", "action: Stop()}"},
          {"Horizon", "config.now + config.flight + config.allowance > config.horizon -> False()",
           "config.now + config.flight + config.allowance > config.horizon -> True()"}
        ] do
      assert String.contains?(runtime, from)

      src =
        runtime
        |> String.replace("Elzoo.EffectIntentPolicy", "Elzoo.EffectIntentMutation" <> label)
        |> String.replace(from, to, global: false)

      assert {:ok, m} = Cure.Compiler.compile_and_load(src <> "end\n")
      s = apply(m, :initial, [])
      {:Decision, i, _} = apply(m, :decide, [s, :Admit, 0, c.config])
      {:Decision, dispatched, action} = apply(m, :decide, [i, :Arm, 0, c.config])

      if label == "Stop" do
        refute action == :Dispatch
      else
        {:Decision, d, _} = apply(m, :decide, [dispatched, :ProviderUnknown, 1, c.config])
        {:Decision, i, _} = apply(m, :decide, [d, :Rearm, 1, c.config])
        {:ok, expired} = Policy.config(c.binding, 5000, 100, 1101)
        {:Decision, _, action} = apply(m, :decide, [i, :Arm, 1, expired])
        assert action == :Dispatch
        assert elem(Policy.decide(i, :Arm, 1, expired), 2) == :Stop
      end
    end
  end

  test "narrow replay, deadline, disarm, lifetime and count boundaries are executed", c do
    s = sent(c.config)

    for event <- [:Pending, :Lost, :TimedOut, :Failed, :Resume] do
      assert {:Decision, ^s, :Poll} = Policy.decide(s, event, 1, c.config)
    end

    no_cap = %{c.binding | replay: :none}
    {:ok, no_replay} = Policy.config(no_cap, 5000, 100, 100)
    assert {:Decision, stranded, :Reconcile} = Policy.decide(s, :ProviderUnknown, 1, no_replay)
    assert Policy.phase(stranded) == {:Stranded, 1}
    initial = next(Policy.initial(), :Admit, c.config)
    {:ok, expired} = Policy.config(c.binding, 100, 100, 100)
    assert {:Decision, ^initial, :Stop} = Policy.decide(initial, :Arm, 0, expired)
    permanent = next(s, :PermanentNoSend, c.config)
    assert Policy.flags(permanent).disarmed
    assert {:Decision, ^permanent, :Stop} = Policy.decide(permanent, :Rearm, 1, c.config)
    replay = next(s, :ProviderUnknown, c.config)
    {:ok, last} = Policy.config(c.binding, 5000, 100, 990)
    {:ok, over} = Policy.config(c.binding, 5000, 100, 991)
    assert Policy.permitted?(replay, :Rearm, last)
    refute Policy.permitted?(replay, :Rearm, over)
    {:State, p, d, q, dep, ever, _, h} = initial
    capped = {:State, p, d, q, dep, ever, 256, h}
    refute Policy.permitted?(capped, :Arm, c.config)
  end

  test "revision is refused after any non-no-send history and never clears replay dependence", c do
    for event <- [:NoEffect, :ProviderUnknown] do
      s = sent(c.config) |> next(event, c.config)
      refute Policy.permitted?(s, :Revise, c.config)
    end

    s = sent(c.config) |> next(:NoSend, c.config)
    assert Policy.permitted?(s, :Revise, c.config)
    revised = next(s, :Revise, c.config)
    assert Policy.history(revised) == Policy.history(s)
    assert Policy.revisions(revised) == 1

    replay =
      sent(c.config)
      |> next(:ProviderUnknown, c.config)
      |> next(:Rearm, c.config)
      |> next(:Arm, c.config)
      |> next(:NoSend, c.config)

    refute Policy.permitted?(replay, :Revise, c.config)
  end

  test "both completion/reconciliation orders and older completion before new reservation", c do
    s = sent(c.config)
    confirmed = next(s, :Completed, c.config)
    assert Policy.phase(next(confirmed, :NoEffect, c.config)) == {:Confirmed, 1}

    for ground <- [:NoSend, :NoEffect] do
      d = next(s, ground, c.config)
      frozen = next(d, :Completed, c.config)
      assert Policy.flags(frozen).quarantined
    end

    d = next(s, :ProviderUnknown, c.config)
    i = next(d, :Rearm, c.config)
    assert Policy.phase(next(i, :Completed, c.config, 1)) == {:Confirmed, 1}
    assert Policy.phase(next(d, :Completed, c.config, 1)) == {:Confirmed, 1}
  end

  test "snapshot validation rejects forged forgotten history and malformed native terms", c do
    s =
      sent(c.config)
      |> next(:ProviderUnknown, c.config)
      |> next(:Rearm, c.config)
      |> next(:Arm, c.config)
      |> next(:NoSend, c.config)

    assert Policy.valid?(s)
    {:State, p, d, q, _, ever, r, h} = s
    refute Policy.valid?({:State, p, d, q, false, ever, r, h})

    for bad <- [
          nil,
          {},
          %{},
          [],
          {:State, :Empty, false, false, false, false, 0, [:Awaiting]},
          {:State, {:Intended, :Fresh, 1}, false, false, false, true, 0, [:Awaiting]},
          {:State, {:Dispatched, :Fresh, 1}, false, false, false, true, 0, [:ReplayCovered]}
        ] do
      refute Policy.valid?(bad)
    end

    assert {:error, :encoding} = Model.decode_term(<<131, 80, 0, 0, 255, 255, 1>>, 1_048_576)
  end
end
