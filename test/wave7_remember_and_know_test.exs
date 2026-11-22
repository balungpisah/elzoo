Code.require_file("support/wave7_remember_and_know_helper.exs", __DIR__)

defmodule Elzoo.Wave7.RememberAndKnowTest do
  # ELZ-338: the Wave 7 Pieces together on real PostgreSQL 16 with pgvector and MinIO, every
  # application call running as the fixed non-owner, non-bypass role of ELZ-285. Each test
  # names its acceptance group.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Elzoo.{KnowledgeIngest, SearchData, TenantIsolation}
  alias Elzoo.Wave7.{AppRepo, OwnerRepo}
  alias Elzoo.Wave7.Helper, as: H

  setup_all do
    role = H.start_repos!()
    on_exit(fn -> for repo <- [OwnerRepo, AppRepo], do: H.stop!(repo) end)
    # Fails, never skips: the application connection must be the application role.
    H.role_guard!(role)
    _ = Elzoo.RunEngine.TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for pid <- [registry, units], do: Process.unlink(pid)
    %{role: role}
  end

  setup %{role: role} do
    Process.flag(:trap_exit, true)
    fx = H.fixture!(role)
    on_exit(fn -> H.cleanup!(fx) end)
    %{fx: fx, p: fx.prefix}
  end

  test "setup: the floor holds as elzoo_app and one ingest reaches indexed", %{fx: fx, p: p} do
    assert :ok = KnowledgeIngest.verify(fx.ki)
    for {_, b} <- fx.search, do: assert(:ok = SearchData.verify(b))

    for t <-
          ~w(elzoo_memory_records elzoo_memory_tombstones elzoo_metering_observations elzoo_metering_corrections) do
      assert :ok =
               TenantIsolation.verify(AppRepo, {p, t},
                 prefix: p,
                 tenant_column: "tenant",
                 space_column: nil
               )
    end

    doc = H.put_doc!(fx, "T1", "refunds", "Refunds are paid within 14 days.", "text/plain")
    r = H.submit!(fx, "T1", H.request(doc, "refunds", 1, "text/plain"))
    H.drain(fx)
    assert %{state: :indexed} = H.status(fx, "T1", r)
    IO.inspect(H.grants(fx), label: "grants")
  end
end
