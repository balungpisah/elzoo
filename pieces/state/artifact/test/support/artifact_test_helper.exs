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

  @doc "A raw HTTP/1.1 response; a `content-length` given in `headers` replaces the computed one."
  def response(status, headers, body \\ "") do
    reason = %{
      200 => "OK",
      204 => "No Content",
      400 => "Bad Request",
      403 => "Forbidden",
      404 => "Not Found",
      500 => "Internal Server Error"
    }

    head = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    "HTTP/1.1 #{status} #{Map.get(reason, status, "Status")}\r\n" <>
      head <>
      if(List.keymember?(headers, "content-length", 0),
        do: "",
        else: "content-length: #{byte_size(body)}\r\n"
      ) <> "connection: close\r\n\r\n" <> body
  end

  @doc """
  Start the programmable in-memory S3 double; returns `{config, pid}`.
  `fail(pid, method, status)` makes every later request of that method
  (`:put`, `:get`, `:head`, `:delete`) answer `status` until `heal(pid)`;
  `fail_once` does it for the next matching request only.
  """
  def fake_s3 do
    {:ok, pid} = Elzoo.Artifact.FakeS3.start_link()
    {stub_config(Elzoo.Artifact.FakeS3.port(pid)), pid}
  end

  def fake_fail(pid, method, status), do: Elzoo.Artifact.FakeS3.fail(pid, method, status)
  def fake_fail_once(pid, method, status), do: Elzoo.Artifact.FakeS3.fail_once(pid, method, status)
  def fake_heal(pid), do: Elzoo.Artifact.FakeS3.heal(pid)
  def fake_objects(pid), do: Elzoo.Artifact.FakeS3.objects(pid)
  def fake_requests(pid), do: Elzoo.Artifact.FakeS3.requests(pid)

  # ── Store stream inspection, checkpoints, retention, corruption ──────

  @doc "The visible rows (above `low_water`) and head of a Store stream."
  def stream_rows(store, stream, limit \\ 1_000) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])
    {:ok, rows, _} = Elzoo.DurableLog.read(store, stream, head.low_water + 1, limit)
    {rows, head}
  end

  @doc """
  A valid checkpoint at the stream's head (needed by `retain/5`), built by
  replaying the visible rows — the same shape the ready Store's own
  checkpoint producers emit. Returns `{checkpoint, replay}`.
  """
  def checkpoint(store, stream) do
    {rows, _head} = stream_rows(store, stream)
    replay = Elzoo.DurableLog.replay(rows, List.last(rows).sequence, fold())

    c = %{
      stream: stream,
      sequence: elem(replay.cursor, 0),
      fold_version: 1,
      model: Integer.to_string(replay.model),
      cursor: replay.cursor,
      seen: replay.seen,
      nonce: :crypto.strong_rand_bytes(16)
    }

    c = Map.put(c, :digest, Elzoo.DurableLog.Codec.hash(Elzoo.DurableLog.Codec.checkpoint_bytes(c)))
    {:committed, _} = Elzoo.DurableLog.Memory.put_checkpoint(store, c)
    {c, replay}
  end

  @doc "Retain the stream's prefix through `through` (checkpoint anchor required)."
  def retain!(store, stream, through) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])

    {:committed, ^through} =
      Elzoo.DurableLog.Memory.retain(
        store,
        stream,
        head.low_water,
        through,
        :crypto.strong_rand_bytes(16)
      )

    :ok
  end

  @doc "Merge `changes` into the persisted record at `{stream, sequence}` (Memory double only)."
  def corrupt_row(store, stream, sequence, changes),
    do: Elzoo.DurableLog.Memory.corrupt(store, :records, {stream, sequence}, changes)

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

defmodule Elzoo.Artifact.FakeS3 do
  @moduledoc """
  A programmable in-memory S3 double for the `state/artifact` tests: real
  PUT/HEAD/GET/DELETE semantics over loopback HTTP so the ready
  `Elzoo.ObjectStore` client exercises its actual request/response path,
  plus scripted per-method failure statuses for outcomes a live provider
  cannot produce on demand (`:refused` on 403, `:unknown` on 5xx). Test
  evidence only — not a proof of provider semantics.
  """
  use GenServer

  def start_link,
    do: GenServer.start_link(__MODULE__, %{objects: %{}, fails: %{}, fails_once: [], requests: []})

  def port(pid), do: GenServer.call(pid, :port)
  def fail(pid, method, status), do: GenServer.call(pid, {:fail, method, status})
  def fail_once(pid, method, status), do: GenServer.call(pid, {:fail_once, method, status})
  def heal(pid), do: GenServer.call(pid, :heal)
  def objects(pid), do: GenServer.call(pid, :objects)
  def requests(pid), do: GenServer.call(pid, :requests)

  @impl true
  def init(state) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    fake = self()

    spawn(fn -> accept_loop(listen, fake) end)
    |> then(&:gen_tcp.controlling_process(listen, &1))

    {:ok, Map.merge(state, %{listen: listen, port: port})}
  end

  defp accept_loop(listen, fake) do
    case :gen_tcp.accept(listen, 30_000) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, fake) end)
        |> then(&:gen_tcp.controlling_process(socket, &1))

        accept_loop(listen, fake)

      _ ->
        :gen_tcp.close(listen)
    end
  end

  defp serve(socket, fake) do
    case read_request(socket) do
      {:ok, request} ->
        response = GenServer.call(fake, {:request, request})
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)

      :error ->
        :gen_tcp.close(socket)
    end
  end

  defp read_request(socket, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        length =
          case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        case read_body(socket, body, length) do
          {:ok, full} -> {:ok, parse(head, full)}
          :error -> :error
        end

      [_] ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          _ -> :error
        end
    end
  end

  defp read_body(_socket, have, want) when byte_size(have) >= want, do: {:ok, have}

  defp read_body(socket, acc, want) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> read_body(socket, acc <> data, want)
      _ -> :error
    end
  end

  defp parse(head, body) do
    [request_line | header_lines] = String.split(head, "\r\n", trim: true)
    [method, target | _] = String.split(request_line, " ")

    path =
      target
      |> String.split("?", parts: 2)
      |> hd()
      |> String.trim_leading("/")

    key =
      case String.split(path, "/", parts: 2) do
        [_bucket] -> ""
        [_bucket, rest] -> rest
      end

    headers =
      Map.new(header_lines, fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
          _ -> {"", ""}
        end
      end)

    {method, key, headers, body}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:objects, _from, state), do: {:reply, state.objects, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:heal, _from, state), do: {:reply, :ok, %{state | fails: %{}, fails_once: []}}

  def handle_call({:fail, method, status}, _from, state),
    do: {:reply, :ok, put_in(state.fails[to_string(method)], status)}

  def handle_call({:fail_once, method, status}, _from, state),
    do: {:reply, :ok, %{state | fails_once: state.fails_once ++ [{to_string(method), status}]}}

  def handle_call({:request, {method, key, headers, body}}, _from, state) do
    method = String.downcase(method)

    {fails_once, response} =
      case Enum.split_while(state.fails_once, fn {m, _} -> m != method end) do
        {before, [{^method, status} | rest]} ->
          {before ++ rest, scripted(method, key, status)}

        {_, []} ->
          {state.fails_once, nil}
      end

    {response, state} =
      response ||
        case Map.fetch(state.fails, method) do
          {:ok, status} -> {scripted(method, key, status), state}
          :error -> dispatch(state, method, key, headers, body)
        end

    entry = {method, key}
    {:reply, response, %{state | fails_once: fails_once, requests: [entry | state.requests]}}
  end

  # 403 classifies to :refused, 5xx to :unknown{server_error} in the ready
  # object-store result table; 404 carries NoSuchKey so reads observe :absent.
  defp scripted(method, _key, status) do
    body =
      case status do
        404 -> "<Error><Code>NoSuchKey</Code></Error>"
        s when s >= 400 -> "<Error><Code>InternalError</Code></Error>"
        _ -> ""
      end

    headers =
      if status == 404 and method in ["get", "head"],
        do: [{"x-minio-error-code", "NoSuchKey"}],
        else: []

    Elzoo.Artifact.TestHelper.response(status, headers, body)
  end

  defp dispatch(state, "put", key, headers, body) do
    objects = Map.put(state.objects, key, %{body: body})

    response =
      Elzoo.Artifact.TestHelper.response(200, [
        {"etag", "\"#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}\""},
        {"x-amz-checksum-sha256", Map.get(headers, "x-amz-checksum-sha256", "")}
      ])

    {response, %{state | objects: objects}}
  end

  defp dispatch(state, "get", key, _headers, _body) do
    case Map.fetch(state.objects, key) do
      {:ok, %{body: body}} ->
        response =
          Elzoo.Artifact.TestHelper.response(
            200,
            [
              {"content-type", "application/octet-stream"},
              {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, body))}
            ],
            body
          )

        {response, state}

      :error ->
        {scripted("get", key, 404), state}
    end
  end

  defp dispatch(state, "head", key, _headers, _body) do
    cond do
      key == "" ->
        {Elzoo.Artifact.TestHelper.response(200, []), state}

      match?({:ok, _}, Map.fetch(state.objects, key)) ->
        %{body: body} = state.objects[key]

        response =
          Elzoo.Artifact.TestHelper.response(200, [
            {"content-length", Integer.to_string(byte_size(body))},
            {"content-type", "application/octet-stream"},
            {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, body))}
          ])

        {response, state}

      true ->
        {scripted("head", key, 404), state}
    end
  end

  defp dispatch(state, "delete", key, _headers, _body),
    do:
      {Elzoo.Artifact.TestHelper.response(204, []),
       %{state | objects: Map.delete(state.objects, key)}}

  defp dispatch(state, _method, _key, _headers, _body),
    do: {Elzoo.Artifact.TestHelper.response(400, []), state}
end
