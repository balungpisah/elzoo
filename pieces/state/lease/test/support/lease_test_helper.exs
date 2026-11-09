# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Lease.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Lease.TestMigration do
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

defmodule Elzoo.Lease.TestHelper do
  @moduledoc """
  Shared fixtures for the `state/lease` tests: the consumer fold with the lease
  kinds merged, the Memory double with its owner and manual clock, the
  PostgreSQL schema per test, forged records through the ready Store, and the
  fail-closed database guard (R6).
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Postgres}
  alias Elzoo.Lease
  alias Elzoo.Lease.{Clock, Record}

  @epoch 1_700_000_000_000_000

  def epoch, do: @epoch

  def fold,
    do: %{
      initial: 0,
      kinds: Map.merge(%{"added" => :state_bearing, "done" => :state_bearing}, Lease.kinds()),
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  def limits, do: %{max_record_bytes: 1_024, max_batch_size: 4, max_checkpoint_bytes: 10_000}

  # ── Memory double ───────────────────────────────────────────────────

  def memory(opts \\ []) do
    {:ok, pid} = Memory.start_link(fold: fold(), limits: limits(), append_visibility: :atomic)
    store = Memory.store(pid)
    {:ok, clock} = Clock.manual(Keyword.get(opts, :now, @epoch))

    {:ok, lease} =
      Lease.new(
        store: store,
        fold: fold(),
        limits: limits(),
        clock: {:manual, clock},
        test_hook: Keyword.get(opts, :hook),
        timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
      )

    %{store: store, memory: pid, clock: clock, lease: lease}
  end

  # ── PostgreSQL ──────────────────────────────────────────────────────

  @doc "R6 helper guard: URL present, parsed name == current_database() == expectation (when set)."
  def database_guard!(repo) do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed (never skipped)"

    parsed = url |> String.split("/") |> List.last() |> String.split("?") |> hd()
    expect = System.get_env("ELZOO_TEST_DATABASE_EXPECT")

    if expect && expect != parsed,
      do: raise("ELZOO_TEST_DATABASE_EXPECT does not match the configured database: fail closed")

    actual =
      case SQL.query(repo, "SELECT current_database()", [], timeout: 2_000, log: false) do
        {:ok, %{rows: [[name]]}} ->
          name

        _ ->
          raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
      end

    if actual != parsed,
      do: raise("effective database differs from the configured one: fail closed")

    if expect && expect != actual,
      do: raise("effective database differs from the expectation: fail closed")

    :ok
  rescue
    e in RuntimeError ->
      reraise e, __STACKTRACE__

    _ ->
      raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
  end

  def url!,
    do: System.get_env("ELZOO_TEST_DATABASE_URL") || raise("ELZOO_TEST_DATABASE_URL is required")

  @doc "Create a fresh schema with migration v1; returns the unquoted prefix."
  def schema!(repo) do
    prefix = "elzoo_lease_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    SQL.query!(repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(repo, 1, Elzoo.Lease.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(repo, prefix),
    do:
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE", [],
        log: false
      )

  def pg_store(repo, prefix, extra \\ []),
    do: Postgres.store(repo, Keyword.merge([prefix: prefix, fold: fold(), limits: limits()], extra))

  def pg_lease(store, opts \\ []) do
    Lease.new(
      store: store,
      fold: fold(),
      limits: limits(),
      clock: :store,
      test_hook: Keyword.get(opts, :hook),
      timeout_ms: Keyword.get(opts, :timeout_ms, 15_000)
    )
  end

  def pg_now(repo) do
    [[now]] = SQL.query!(repo, Clock.postgres_sql(), [], log: false).rows
    now
  end

  # ── forged records through the ready Store (test only) ──────────────

  @doc "Append `{kind, payload}` specs at `expected` through the ready Store; returns the target revision."
  def forge!(store, key, expected, specs) do
    {:ok, rows, request} =
      Record.records(key, expected, Enum.map(specs, fn {k, p} -> {k, 1, p} end), fold(), limits())

    {module, _} = store
    {:committed, target} = module.append(store, key, expected, rows, [])
    {target, request}
  end

  def holder_payload(owner, at, ttl_ms), do: Record.holder_payload(owner, at, ttl_ms)
  def release_payload(prior, by, at, reason), do: Record.release_payload(prior, by, at, reason)

  @doc "Read the visible rows of a stream (above `low_water`) through the ready Store."
  def rows(store, key) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [key])
    {:ok, rows, _} = Log.read(store, key, head.low_water + 1, 1_000)
    rows
  end

  @doc """
  A valid checkpoint at the stream's head (needed by `retain/5`); `resume` is
  the replay state of a previous checkpoint when the prefix is already pruned.
  Returns `{checkpoint, replay}`.
  """
  def checkpoint(store, key, resume \\ nil) do
    rows = rows(store, key)
    fold = if resume, do: Map.put(fold(), :resume, resume), else: fold()
    replay = Log.replay(rows, List.last(rows).sequence, fold)

    c = %{
      stream: key,
      sequence: elem(replay.cursor, 0),
      fold_version: 1,
      model: Integer.to_string(replay.model),
      cursor: replay.cursor,
      seen: replay.seen,
      nonce: :crypto.strong_rand_bytes(16)
    }

    c = Map.put(c, :digest, Codec.hash(Codec.checkpoint_bytes(c)))
    {module, _} = store
    {:committed, _} = module.put_checkpoint(store, c)
    {c, replay}
  end

  def retain!(store, key, through) do
    {module, _} = store
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [key])

    {:committed, ^through} =
      module.retain(store, key, head.low_water, through, :crypto.strong_rand_bytes(16))

    :ok
  end
end
