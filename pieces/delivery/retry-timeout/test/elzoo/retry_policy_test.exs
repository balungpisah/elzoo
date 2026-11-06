# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryPolicyTest do
  use ExUnit.Case, async: false
  alias Elzoo.RetryTimeout, as: R
  @source File.read!(Path.expand("../../cure/elzoo/retry_policy.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  test "full valid result matrix and decision tables" do
    {:ok, forbidden} = R.policy(max_attempts: 3, base_backoff_ms: 2, max_backoff_ms: 9)
    {:ok, idempotent} = R.policy(max_attempts: 3, mode: :redispatch_idempotent)

    for outcome <- ~w(completed rejected timed_out failed unknown),
        dispatch <- ~w(dispatched not_dispatched unknown),
        error <- [nil | ~w(permanent retryable unavailable unclassified)] do
      row = %{
        "version" => 1,
        "message_id" => "m",
        "correlation_id" => "m",
        "outcome" => outcome,
        "dispatch" => dispatch
      }

      row =
        if error,
          do: Map.put(row, "error_class", error),
          else:
            Map.merge(row, %{"value" => nil, "value_schema_id" => "v", "value_schema_version" => 1})

      valid =
        case outcome do
          "completed" -> dispatch == "dispatched" and is_nil(error)
          "rejected" -> dispatch == "not_dispatched" and error != nil
          "timed_out" -> error != nil
          "failed" -> dispatch == "dispatched" and error != nil
          "unknown" -> dispatch in ~w(dispatched unknown) and error != nil
        end

      if valid do
        expected =
          cond do
            outcome == "completed" -> :completed
            error == "permanent" -> :permanent
            dispatch == "not_dispatched" -> :retryable
            true -> :dispatched
          end

        assert R.classify(row) == {:ok, expected}
      else
        assert {:error, _} = R.classify(row)
      end
    end

    for policy <- [forbidden, idempotent],
        class <- [:completed, :permanent, :retryable, :dispatched],
        n <- 1..4 do
      expected =
        cond do
          class == :completed -> :settle
          class == :permanent -> :permanent
          class == :dispatched and policy == forbidden -> :unresolved
          n < 3 -> :retry
          true -> :exhausted
        end

      assert R.decide(policy, n, class) == {:ok, expected}
    end

    for {n, expected} <- [{1, 2}, {2, 4}, {3, 8}, {4, 9}, {10_000_000, 9}],
        do: assert(R.backoff(forbidden, n) == {:ok, expected})

    assert {:ok, zero} = R.policy(base_backoff_ms: 0)
    assert R.backoff(zero, 10_000_000) == {:ok, 0}
  end

  test "boundary rejects improper options, policy and attempts" do
    assert R.policy([{:max_attempts, 1} | :bad]) == {:error, :invalid_options}
    assert R.policy(max_attempts: 0) == {:error, :invalid_max_attempts}
    assert R.policy(base_backoff_ms: -1) == {:error, :invalid_backoff}
    assert R.policy(mode: :blind) == {:error, :invalid_mode}
    {:ok, policy} = R.policy([])
    assert R.decide(policy, 0, :completed) == {:error, :invalid_attempt}
    assert R.decide(policy, 1, :bad) == {:error, :invalid_class}
    assert R.backoff(nil, 1) == {:error, :invalid_policy}
  end

  test "production proof audit; false law, production mutation and hole are rejected" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0

    for {name, from, to} <- [
          {"WrongRetryLaw", "retry_permitted(RedispatchForbidden(), ClassDispatched()), False()",
           "retry_permitted(RedispatchForbidden(), ClassDispatched()), True()"},
          {"WrongRetryProduction", "RedispatchForbidden() -> False()",
           "RedispatchForbidden() -> True()"}
        ] do
      assert String.contains?(@source, from)

      wrong =
        @source
        |> String.replace("mod Elzoo.RetryPolicy", "mod Elzoo." <> name)
        |> String.replace(from, to)

      assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)
    end

    unfinished =
      @source
      |> String.replace("mod Elzoo.RetryPolicy", "mod Elzoo.RetryHole")
      |> String.replace("reflexive(False())", "?unfinished", global: false)

    assert {:error, {:codegen_error, {:unfilled_hole, _}}} =
             Cure.Compiler.compile_and_load(unfinished, source_roots: @roots)
  end
end
