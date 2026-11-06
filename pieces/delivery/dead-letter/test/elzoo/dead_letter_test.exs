# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DeadLetterTest do
  use ExUnit.Case, async: false
  alias Elzoo.DeadLetter, as: D
  @source File.read!(Path.expand("../../cure/elzoo/dead_letter.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  test "production record validator audit has no holes or unchecked obligations" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0
  end

  defp request do
    %{
      "version" => 1,
      "message_id" => "m",
      "schema_id" => "example",
      "schema_version" => 1,
      "kind" => "command",
      "producer" => %{"unit_id" => "u", "port_id" => "p"},
      "payload" => "secret",
      "trace_id" => "secret-trace",
      "deadline_unix_ms" => 50
    }
  end

  defp result do
    %{
      "version" => 1,
      "message_id" => "m",
      "correlation_id" => "m",
      "outcome" => "timed_out",
      "dispatch" => "not_dispatched",
      "error_class" => "permanent",
      "deadline_unix_ms" => 50
    }
  end

  test "all reasons roundtrip with payload redacted; caller records refused expiry" do
    for reason <-
          ~w(permanent retries_exhausted deadline_expired dispatched_unresolved deadline_before_dispatch) do
      assert {:ok, map} = D.from_result(request(), result(), 0, reason)
      assert map["reason"] == reason
      refute Map.has_key?(map, "payload")
      refute Map.has_key?(map, "trace_id")
      refute inspect(map) =~ "secret"
      assert {:ok, record} = D.decode(map)
      assert D.encode(record) == map
      assert {:ok, ^map} = D.validate(map)
    end

    assert {:ok, minimal} = D.from_result(request(), nil, 0, "deadline_before_dispatch")
    refute Map.has_key?(minimal, "last_outcome")
    assert {:ok, _} = D.decode(minimal)
  end

  test "fixed validation errors, all-or-none triple and unknown keys" do
    assert D.from_result(request(), nil, -1, "permanent") ==
             {:error, {:dead_letter, :invalid_attempts}}

    {:ok, good} = D.from_result(request(), result(), 1, "permanent")

    for bad <- [
          nil,
          [],
          [good | :bad],
          Map.put(good, "payload", nil),
          Map.delete(good, "last_dispatch"),
          Map.put(good, "attempts", -1),
          Map.put(good, "attempts", 1.0),
          Map.put(good, "last_error_class", "invented"),
          Map.put(good, "reason", "invented"),
          Map.put(good, "last_outcome", "completed"),
          Map.put(good, "deadline_unix_ms", -1),
          Map.put(good, "message_id", ""),
          Map.put(good, "message_id", <<255>>),
          Map.put(good, "version", 2),
          Map.put(good, "last_attempt_id", "")
        ] do
      assert {:error, _} = D.decode(bad)
    end

    assert {:error, {:result, :identity_mismatch}} =
             D.from_result(request(), Map.put(result(), "message_id", "other"), 1, "permanent")
  end
end
