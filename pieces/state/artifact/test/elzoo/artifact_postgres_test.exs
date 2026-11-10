# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/artifact_test_helper.exs", __DIR__)

defmodule Elzoo.ArtifactPostgresTest do
  @moduledoc """
  `state/artifact` scenarios on the ready PostgreSQL Store (ELZOO_TEST_DATABASE_URL,
  fail closed) and the disposable MinIO (ELZOO_TEST_S3_*, fail closed): the
  durable reference lifecycle on the real boundary, CAS conflict mapping and
  the caller-transaction refusal.
  """
  use ExUnit.Case, async: false

  alias Elzoo.Artifact
  alias Elzoo.Artifact.TestHelper, as: H
  alias Elzoo.Artifact.TestHelper, as: S3
  alias Elzoo.Artifact.TestRepo

  defp s3?, do: S3.s3?()

  setup_all do
    {:ok, _} = TestRepo.start_link(url: H.url!())
    H.database_guard!(TestRepo)
    :ok
  end

  setup do
    prefix = H.schema!(TestRepo)
    on_exit(fn -> H.drop!(TestRepo, prefix) end)
    f = H.pg(TestRepo, prefix, S3.config!())
    %{pg: f, prefix: prefix}
  end

  defp id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "P1 durable lifecycle: put, head, get, versions, delete on the real Store", %{
    pg: %{art: art}
  } do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    c = H.caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, %{version: 1, state: :committed}} =
             Artifact.put(art, c, aid, H.input("pg-data"))

    assert {:ok, %{version: 1}} = Artifact.head(art, c, aid)
    assert {:ok, %{bytes: "pg-data"}} = Artifact.get(art, c, aid, 1)
    assert {:ok, [%{version: 1}]} = Artifact.versions(art, c, aid)
    assert {:ok, %{record: %{state: :deleted}}} = Artifact.delete(art, c, aid, 1)
    assert {:error, :not_found} = Artifact.head(art, c, aid)
  end

  test "P2 CAS conflict is a typed commit_failed", %{pg: %{art: art}} do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    c = H.caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, %{version: 1}} = Artifact.stage(art, c, aid, H.input("data"))

    # A concurrent writer advances the stream head between the stage and this
    # forged direct append; the next commit re-reads at the moved head.
    stream = "artifact/#{c.tenant}/#{aid}"

    {:ok, rows, request} =
      Elzoo.Artifact.Record.rows(
        stream,
        1,
        [{"foreign", 1, Jason.encode!(%{"v" => 1})}],
        H.fold(),
        H.limits()
      )

    assert {:committed, 2} =
             Elzoo.DurableLog.Store.write(art.store, :append, [stream, 1, rows, []], request)

    # commit re-loads at revision 2, verifies and appends at the fresh head —
    # no stale CAS; the foreign row is ignored by the fold.
    assert {:ok, %{version: 1, state: :committed}} = Artifact.commit(art, c, aid, 1)
    assert {:ok, %{bytes: "data"}} = Artifact.get(art, c, aid, 1)
  end

  test "P3 staged and committed records are ordinary validated Store rows", %{pg: %{art: art}} do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    c = H.caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, _} = Artifact.put(art, c, aid, H.input("data"))
    {:ok, head} = Elzoo.DurableLog.Store.read(art.store, :head, ["artifact/#{c.tenant}/#{aid}"])
    assert head.revision == 2
    {:ok, rows, _} = Elzoo.DurableLog.read(art.store, "artifact/#{c.tenant}/#{aid}", 1, 10)

    for row <- rows do
      assert :ok = Elzoo.DurableLog.validate_row(row, H.fold(), H.limits())
    end
  end

  test "P4 entry points refuse inside the caller's open transaction", %{pg: %{art: art}} do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    c = H.caller("t-#{id("t")}")
    aid = id("art")

    TestRepo.transaction(fn ->
      assert {:error, :caller_transaction} = Artifact.stage(art, c, aid, H.input("data"))
      assert {:error, :caller_transaction} = Artifact.head(art, c, aid)
    end)
  end
end
