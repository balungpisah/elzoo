# SPDX-License-Identifier: Apache-2.0
# ELZ-031 domain/money persistence round trip through integration/sql. A
# repository test, so the copied domain/money bundle stays pure and does not
# depend on integration/sql. Same fail-closed ELZOO_TEST_DATABASE_URL handling
# as the integration/sql tests: missing or unreachable fails, never skips.
Code.require_file(
  "../pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs",
  __DIR__
)

defmodule Elzoo.Elz031MoneyPersistenceTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, Record, TestMigration, TestRepo}
  alias Elzoo.Money, as: M
  alias Elzoo.Money.Codec

  @url PostgresHarness.database_url!()
  @limits %{max_record_bytes: 128, max_batch_size: 8, max_checkpoint_bytes: 10_000}

  def reduce(n, _, _, _), do: n + 1

  defp fold,
    do: %{
      initial: 0,
      kinds: %{"money" => :state_bearing},
      versions: [1],
      destinations: ["sink"],
      reduce: &__MODULE__.reduce/4
    }

  setup do
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 2, log: false)
    Process.unlink(repo)
    PostgresHarness.reachable!(TestRepo)
    prefix = "elz031_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)

    on_exit(fn ->
      try do
        SQL.query!(TestRepo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)
      after
        if pid = Process.whereis(TestRepo), do: Supervisor.stop(pid)
      end
    end)

    %{store: Postgres.store(TestRepo, prefix: prefix, fold: fold(), limits: @limits)}
  end

  defp amount!(code, minor) do
    {:ok, c} = M.parse(code)
    {:ok, a} = M.from_minor_units(c, minor)
    a
  end

  test "JPY, BHD, EUR and CLF amounts round-trip through the PostgreSQL Store", %{store: store} do
    amounts = [
      amount!("JPY", 1000),
      amount!("BHD", 1234),
      amount!("EUR", 100),
      amount!("EUR", -5),
      amount!("CLF", 12345)
    ]

    payloads =
      Enum.map(amounts, fn a ->
        {:ok, bytes} = Codec.encode(a)
        bytes
      end)

    nonce = :crypto.strong_rand_bytes(16)

    rows =
      for {payload, sequence} <- Enum.with_index(payloads, 1) do
        r = %Record{
          stream: "money",
          sequence: sequence,
          kind: "money",
          schema_version: 1,
          payload: payload,
          nonce: nonce
        }

        %{r | digest: Log.digest(r)}
      end

    assert {:committed, 5} = Postgres.append(store, "money", 0, rows, [])
    assert {:ok, read, _head} = Postgres.read(store, "money", 1, 10)
    for r <- read, do: assert(Log.validate_row(r, fold(), @limits) == :ok)
    assert Enum.map(read, & &1.payload) == payloads
    assert Enum.map(read, &Codec.decode(&1.payload)) == Enum.map(amounts, &{:ok, &1})
    assert hd(payloads) == "elzoo-money/1 2026-09-17 JPY 392 0 1000"
    assert Enum.at(payloads, 1) == "elzoo-money/1 2026-09-17 BHD 048 3 1234"
  end

  test "equal amounts persist as equal bytes; a retired-with-exponent amount replays after an update",
       %{store: store} do
    {:ok, eur} = M.parse("EUR")
    {:ok, from_string} = M.from_decimal_string(eur, "1.0")
    {:ok, from_units} = M.from_minor_units(eur, 100)
    assert Codec.encode(from_string) == Codec.encode(from_units)

    v1 =
      File.read!(
        Path.expand("../pieces/domain/money/lib/elzoo/money/iso4217/2026-09-17.tsv", __DIR__)
      )

    v2 =
      v1
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "current\tEUR\t"))
      |> Enum.map(&String.replace(&1, "\t2026-09-17", "\t2027-01-01"))
      |> Enum.join("\n")

    later = M.Registry.build!([v1, v2])
    {:ok, bytes} = Codec.encode(from_units)
    nonce = :crypto.strong_rand_bytes(16)

    r = %Record{
      stream: "replay",
      sequence: 1,
      kind: "money",
      schema_version: 1,
      payload: bytes,
      nonce: nonce
    }

    assert {:committed, 1} = Postgres.append(store, "replay", 0, [%{r | digest: Log.digest(r)}], [])
    assert {:ok, [stored], _} = Postgres.read(store, "replay", 1, 10)
    assert {:ok, replayed} = Codec.decode(stored.payload, registry: later)
    assert replayed == from_units
    assert M.current_status(replayed.currency, registry: later) == {:ok, {:retired, :not_recorded}}
  end
end
