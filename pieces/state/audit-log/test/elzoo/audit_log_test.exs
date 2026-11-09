# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuditLogTest do
  use ExUnit.Case, async: true
  alias Elzoo.AuditLog
  alias Elzoo.AuditLog.{Attribution, Migration, Retention}

  # bind/2 performs no database I/O: a Repo module that does not exist is never queried.
  @inner {Elzoo.DurableLog.Postgres,
          %{repo: Elzoo.AuditLog.NoSuchRepo, prefix: "s", fold: %{}, limits: %{}}}
  @good %{actor: "user:1", action: "refund.request", reason: ""}

  test "T3 attribution shape: accepted and refused inputs, typed refusal at bind without I/O" do
    assert {:ok, @good} = Attribution.validate(@good)
    assert {:ok, _} = Attribution.validate(%{@good | actor: String.duplicate("a", 256)})
    assert {:ok, _} = Attribution.validate(%{@good | reason: String.duplicate("r", 1024)})
    assert {:ok, _} = Attribution.validate(%{@good | actor: "pengguna:é"})

    refusals = [
      {nil, :shape},
      {%{}, :shape},
      {Map.delete(@good, :reason), :shape},
      {Map.put(@good, :extra, "x"), :shape},
      {%{@good | actor: ""}, :actor},
      {%{@good | actor: String.duplicate("a", 257)}, :actor},
      {%{@good | actor: "a\nb"}, :actor},
      {%{@good | actor: <<0xFF>>}, :actor},
      {%{@good | actor: :user}, :actor},
      {%{@good | action: ""}, :action},
      {%{@good | action: "x\u0085"}, :action},
      {%{@good | reason: String.duplicate("r", 1025)}, :reason},
      {%{@good | reason: "tab\t"}, :reason},
      {%{"actor" => "a", "action" => "b", "reason" => ""}, :actor}
    ]

    for {input, field} <- refusals do
      assert Attribution.validate(input) == {:error, {:attribution, field}}, inspect(input)
      assert AuditLog.bind(@inner, input) == {:error, {:attribution, field}}
    end

    # a valid attribution reaches the pool check; a Repo that is not running has no
    # DBConnection.ConnectionPool (accepted bindings are exercised in the PostgreSQL tests)
    assert AuditLog.bind(@inner, @good) == {:error, {:store, :unsupported_pool}}
  end

  test "bind accepts only the ready PostgreSQL Store with a Repo, fold and limits" do
    for inner <- [
          {Elzoo.DurableLog.Memory, %{}},
          {Elzoo.DurableLog.Postgres, %{repo: "Repo", fold: %{}, limits: %{}}},
          {Elzoo.DurableLog.Postgres, %{repo: Repo, limits: %{}}},
          {Elzoo.DurableLog.Postgres, [repo: Repo]},
          :store
        ] do
      assert AuditLog.bind(inner, @good) == {:error, {:store, :unsupported}}
    end
  end

  test "migration options: prefixes and excluded columns are validated before any DDL" do
    assert {"public", "audit", ["payload", "nonce"]} = Migration.options!(carbonite_prefix: "audit")

    assert {"st", "audit", []} =
             Migration.options!(store_prefix: "st", carbonite_prefix: "audit", excluded_columns: [])

    for opts <- [
          [],
          [carbonite_prefix: "Audit"],
          [carbonite_prefix: "a-b"],
          [carbonite_prefix: "audit", store_prefix: "audit"],
          [carbonite_prefix: "audit", store_prefix: "x\"y"],
          [carbonite_prefix: "audit", excluded_columns: ["stream"]],
          [carbonite_prefix: "audit", excluded_columns: ["sequence"]],
          [carbonite_prefix: "audit", excluded_columns: ["payload", "payload"]],
          [carbonite_prefix: "audit", excluded_columns: ["unknown"]],
          [carbonite_prefix: "audit", excluded_columns: "payload"]
        ] do
      assert_raise ArgumentError, fn -> Migration.options!(opts) end
    end
  end

  test "T12 retention: explicit dated rule, pure decision at the boundaries" do
    rule = %{keep_days: 30, effective_from: ~D[2026-11-01]}
    now = ~U[2026-11-09 12:00:00Z]
    cutoff = ~N[2026-10-10 12:00:00]
    assert {:ok, ^cutoff} = Retention.cutoff(rule, now)
    assert {:ok, true} = Retention.expired?(rule, ~N[2026-10-10 11:59:59.999999], now)
    assert {:ok, false} = Retention.expired?(rule, cutoff, now)
    assert {:ok, false} = Retention.expired?(rule, ~N[2026-11-09 12:00:00], now)
    # before the rule's date nothing is past the rule, however old
    early = ~U[2026-10-31 23:59:59Z]
    assert {:ok, :not_in_force} = Retention.cutoff(rule, early)
    assert {:ok, false} = Retention.expired?(rule, ~N[2000-01-01 00:00:00], early)
    # the effective date itself is inclusive (UTC date)
    assert {:ok, true} = Retention.expired?(rule, ~N[2000-01-01 00:00:00], ~U[2026-11-01 00:00:00Z])

    for bad <- [
          %{keep_days: 0, effective_from: ~D[2026-11-01]},
          %{keep_days: 36_501, effective_from: ~D[2026-11-01]},
          %{keep_days: 1.5, effective_from: ~D[2026-11-01]},
          %{keep_days: 30, effective_from: "2026-11-01"},
          %{keep_days: 30},
          Map.put(rule, :extra, 1),
          nil
        ] do
      assert Retention.validate(bad) == {:error, :invalid_rule}
      assert Retention.expired?(bad, ~N[2000-01-01 00:00:00], now) == {:error, :invalid_rule}
    end

    assert Retention.expired?(rule, ~U[2000-01-01 00:00:00Z], now) == {:error, :invalid_option}

    assert Retention.expired?(rule, ~N[2000-01-01 00:00:00], ~N[2026-11-09 12:00:00]) ==
             {:error, :invalid_rule}

    assert Retention.expired(Repo, "audit", rule, now, 0) == {:error, :invalid_option}
    assert Retention.expired(Repo, "Audit", rule, now, 10) == {:error, :invalid_prefix}
  end
end
