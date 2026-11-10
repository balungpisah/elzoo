# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Artifact.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Artifact.TestMigration do
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

defmodule Elzoo.Artifact.TestClock do
  @moduledoc "A manual clock for `{:manual, pid}` construction."
  use GenServer
  def start_link(now), do: GenServer.start_link(__MODULE__, now)
  def set(pid, now), do: GenServer.call(pid, {:set, now})
  def advance(pid, ms), do: GenServer.call(pid, {:advance, ms})

  @impl true
  def init(now), do: {:ok, now}
  @impl true
  def handle_call(:now, _from, now), do: {:reply, now, now}
  def handle_call({:set, now}, _from, _), do: {:reply, :ok, now}
  def handle_call({:advance, ms}, _from, now), do: {:reply, :ok, now + ms}
end

defmodule Elzoo.Artifact.TestHelper do
  @moduledoc """
  Shared fixtures for the `state/artifact` tests: the consumer fold with the
  artifact kinds merged, the Memory Store double, a fake ObjectStore binding
  driven by a loopback stub (never a live provider), the PostgreSQL schema
  per test and the fail-closed database guard.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog.{Memory, Postgres}
  alias Elzoo.Artifact

  @epoch 1_800_000_000_000

  def epoch, do: @epoch

  def fold,
    do: %{
      initial: 0,
      kinds:
        Map.merge(
          %{"added" => :state_bearing, "foreign" => :non_state_bearing},
          Artifact.kinds()
        ),
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  def limits, do: %{max_record_bytes: 8_192, max_batch_size: 4, max_checkpoint_bytes: 10_000}

  # ── Memory Store ────────────────────────────────────────────────────

  def memory(opts \\ []) do
    {:ok, pid} = Memory.start_link(fold: fold(), limits: limits(), append_visibility: :atomic)
    store = Memory.store(pid)
    {:ok, clock} = Elzoo.Artifact.TestClock.start_link(Keyword.get(opts, :now, @epoch))

    {:ok, art} =
      Artifact.new(
        store: store,
        object_store: Keyword.fetch!(opts, :object_store),
        clock: {:manual, clock},
        max_bytes: Keyword.get(opts, :max_bytes, 1_024),
        max_metadata_bytes: Keyword.get(opts, :max_metadata_bytes, 512),
        staging_ttl_ms: Keyword.get(opts, :staging_ttl_ms, 60_000),
        hash_format: Keyword.get(opts, :hash_format, 1)
      )

    %{
      store: store,
      memory: pid,
      clock: clock,
      art: art,
      object_store: Keyword.fetch!(opts, :object_store)
    }
  end

  # ── object-store bindings: disposable MinIO or loopback stubs ──────────
  #
  # Vendored from integration/object-store's test support so the bundle is
  # self-contained in the copied consumer layout (no cross-piece require).

  @s3_vars ~w(ELZOO_TEST_S3_URL ELZOO_TEST_S3_BUCKET ELZOO_TEST_S3_ACCESS_KEY_ID ELZOO_TEST_S3_SECRET_ACCESS_KEY ELZOO_TEST_S3_REGION)

  def s3_vars, do: @s3_vars

  def s3?, do: Enum.all?(@s3_vars, &(System.get_env(&1) not in [nil, ""]))

  defp s3_env, do: Map.new(@s3_vars, &{&1, System.get_env(&1)})

  def secret!, do: s3_env()["ELZOO_TEST_S3_SECRET_ACCESS_KEY"]

  def config!(overrides \\ []) do
    e = s3_env()

    {:ok, c} =
      Elzoo.ObjectStore.new(
        Keyword.merge(
          [
            store_id: "test-minio",
            endpoint: e["ELZOO_TEST_S3_URL"],
            bucket: e["ELZOO_TEST_S3_BUCKET"],
            region: e["ELZOO_TEST_S3_REGION"],
            credentials: fn ->
              {:ok,
               %{
                 access_key_id: e["ELZOO_TEST_S3_ACCESS_KEY_ID"],
                 secret_access_key: e["ELZOO_TEST_S3_SECRET_ACCESS_KEY"]
               }}
            end
          ],
          overrides
        )
      )

    c
  end

  @doc "A config pointing at a loopback stub (fake credential; never the test server's)."
  def stub_config(port, overrides \\ []) do
    {:ok, c} =
      Elzoo.ObjectStore.new(
        Keyword.merge(
          [
            store_id: "stub",
            endpoint: "http://127.0.0.1:#{port}",
            bucket: "stub-bucket",
            region: "us-east-1",
            credentials: fn ->
              {:ok, %{access_key_id: "STUBKEYID", secret_access_key: "stub-secret-value"}}
            end
          ],
          overrides
        )
      )

    c
  end

  @doc "A loopback port with nothing listening (bound, then closed)."
  def closed_port do
    {:ok, s} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  @doc """
  A one-shot loopback server. `mode`: `{:reply, raw_response}` reads the
  request head (and the declared body) and answers; `:silent` reads and never
  answers. Returns `{port, ref}`.
  """
  def stub(mode) do
    ref = make_ref()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn(fn -> stub_accept(listen, mode) end)
    |> then(&:gen_tcp.controlling_process(listen, &1))

    {port, ref}
  end

  defp stub_accept(listen, mode) do
    case :gen_tcp.accept(listen, 30_000) do
      {:ok, socket} ->
        spawn(fn -> stub_serve(socket, mode) end)
        |> then(&:gen_tcp.controlling_process(socket, &1))

        stub_accept(listen, mode)

      _ ->
        :gen_tcp.close(listen)
    end
  end

  defp stub_serve(socket, {:reply, response}) do
    _ = stub_read(socket)
    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp stub_serve(socket, :silent) do
    _ = stub_read(socket)
    Process.sleep(60_000)
    :gen_tcp.close(socket)
  end

  defp stub_read(socket, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        length =
          case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        stub_body(socket, byte_size(body), length)

      [_] ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, data} -> stub_read(socket, acc <> data)
          _ -> :ok
        end
    end
  end

  defp stub_body(_socket, have, want) when have >= want, do: :ok

  defp stub_body(socket, have, want) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> stub_body(socket, have + byte_size(data), want)
      _ -> :ok
    end
  end

  # ── PostgreSQL ──────────────────────────────────────────────────────

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

  def schema!(repo) do
    prefix = "elzoo_art_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    SQL.query!(repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(repo, 1, Elzoo.Artifact.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(repo, prefix),
    do:
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE", [],
        log: false
      )

  def pg_store(repo, prefix),
    do: Postgres.store(repo, prefix: prefix, fold: fold(), limits: limits())

  def pg(repo, prefix, object_store, opts \\ []) do
    {:ok, clock} = Elzoo.Artifact.TestClock.start_link(Keyword.get(opts, :now, @epoch))

    {:ok, art} =
      Artifact.new(
        store: pg_store(repo, prefix),
        object_store: object_store,
        clock: {:manual, clock},
        max_bytes: Keyword.get(opts, :max_bytes, 1_024),
        max_metadata_bytes: Keyword.get(opts, :max_metadata_bytes, 512),
        staging_ttl_ms: Keyword.get(opts, :staging_ttl_ms, 60_000),
        hash_format: Keyword.get(opts, :hash_format, 1)
      )

    %{art: art, clock: clock}
  end

  def caller(tenant, opts \\ []),
    do: %{
      tenant: tenant,
      principal: Keyword.get(opts, :principal, "worker-1"),
      scopes: Keyword.get(opts, :scopes, [])
    }

  def input(bytes, opts \\ []),
    do: %{
      bytes: bytes,
      media_type: Keyword.get(opts, :media_type, "application/octet-stream"),
      metadata: Keyword.get(opts, :metadata, %{}),
      access: Keyword.get(opts, :access),
      access_expires_at: Keyword.get(opts, :access_expires_at, :never),
      retain_until: Keyword.get(opts, :retain_until, :never)
    }
end
