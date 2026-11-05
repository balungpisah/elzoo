# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CureJsonTest do
  use ExUnit.Case, async: true
  @source File.read!(Path.expand("../../cure/elzoo/adapter.cure", __DIR__))
  defmodule FailingLibrary do
    def encode(_), do: raise("external failure")
  end

  test "the Cure extern calls Jason and translates invalid input and exceptions" do
    for value <- ["hello", "quotes: \"", "日本語 🌿", "", "\\"] do
      assert {:ok, json} = Elzoo.JsonBoundary.encode(value)
      assert Jason.decode!(json) == value
    end

    assert Elzoo.JsonBoundary.encode(123) == {:error, :invalid_type}
    assert Elzoo.JsonBoundary.encode(<<255>>) == {:error, :invalid_utf8}
    assert Elzoo.JsonBoundary.encode(FailingLibrary, "valid") == {:error, {:library, RuntimeError}}
  end

  test "the foreign implementation is an explicit assumption" do
    report = Cure.Audit.Ledger.audit_source(@source, "Elzoo.Adapter")
    assert report.unaudited == []
    assert report.unresolved == []
    assert report.holes == []
    assert Enum.any?(report.axioms, &(&1.mfa == {Jason, :encode!, 1}))
  end
end
