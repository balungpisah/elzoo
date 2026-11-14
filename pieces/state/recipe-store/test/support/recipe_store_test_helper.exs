# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeStore.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RecipeStore.TestMigration do
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

# A Store of the test that wraps a ready Store and lets a hook of the test see
# each append first. The hook gives `:pass` or `{:reply, reply}`; the reply is
# the raw Store reply (a refusal, a conflict) and nothing is written then.
defmodule Elzoo.RecipeStore.TestStore do
  def wrap({_, inner_opts} = inner, hook),
    do: {__MODULE__, inner_opts |> Map.new() |> Map.merge(%{inner: inner, hook: hook})}

  def capabilities({_, %{inner: {m, _} = i}}), do: m.capabilities(i)
  def head({_, %{inner: {m, _} = i}}, stream), do: m.head(i, stream)
  def read({_, %{inner: {m, _} = i}}, stream, from, limit), do: m.read(i, stream, from, limit)
  def read_at({_, %{inner: {m, _} = i}}, stream, seq), do: m.read_at(i, stream, seq)

  def append({_, %{inner: {m, _} = i, hook: hook}}, stream, expected, records, items) do
    case hook.(stream, expected, records) do
      :pass -> m.append(i, stream, expected, records, items)
      {:reply, reply} -> reply
    end
  end
end

defmodule Elzoo.RecipeStore.DualCase do
  @moduledoc "One scenario on the Memory Store and on the ready PostgreSQL Store."
  defmacro dual(name, ctx, do: block) do
    quote do
      for backend <- [:memory, :postgres] do
        @tag backend: backend
        test "#{unquote(name)} [#{backend}]", unquote(ctx) do
          unquote(block)
        end
      end
    end
  end
end

defmodule Elzoo.RecipeStore.TestHelper do
  @moduledoc """
  Fixtures of the `state/recipe-store` tests: the consumer fold with the
  Artifact and RecipeStore kinds, the Memory Store double, a PostgreSQL schema
  per test with the fail-closed database guard, the object-store binding of the
  disposable test server (fail closed), package and facts builders, and hooks.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog.{Codec, Memory, Postgres}
  alias Elzoo.RecipeStore.{TestStore, TestRepo}
  alias Elzoo.{Artifact, RecipeStore}

  def fold,
    do: %{
      initial: 0,
      kinds: Map.merge(Artifact.kinds(), RecipeStore.kinds()),
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  def limits, do: %{max_record_bytes: 8_192, max_batch_size: 500, max_checkpoint_bytes: 10_000}

  # ── object store: the disposable test server, fail closed ────────────

  @s3_vars ~w(ELZOO_TEST_S3_URL ELZOO_TEST_S3_BUCKET ELZOO_TEST_S3_ACCESS_KEY_ID ELZOO_TEST_S3_SECRET_ACCESS_KEY ELZOO_TEST_S3_REGION)

  def object_store! do
    for var <- @s3_vars,
        System.get_env(var) in [nil, ""],
        do: raise("#{var} is required: the object-store tests fail closed (never skipped)")

    e = Map.new(@s3_vars, &{&1, System.get_env(&1)})

    {:ok, config} =
      Elzoo.ObjectStore.new(
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
      )

    config
  end

  # ── Stores ───────────────────────────────────────────────────────────

  def memory_store do
    {:ok, pid} = Memory.start_link(fold: fold(), limits: limits(), append_visibility: :atomic)
    Memory.store(pid)
  end

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
    prefix = "elzoo_rs_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    SQL.query!(repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(repo, 1, Elzoo.RecipeStore.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(repo, prefix),
    do:
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE", [],
        log: false
      )

  def pg_store(prefix), do: Postgres.store(TestRepo, prefix: prefix, fold: fold(), limits: limits())

  # ── the unit under test ──────────────────────────────────────────────

  @doc """
  A RecipeStore over `store`. `:artifact_hook` and `:log_hook` wrap the Store
  of the artifact handle and the `log` of the Piece; `:max_bytes` bounds an
  artifact.
  """
  def build(store, opts \\ []) do
    wrap = fn store, hook -> if hook, do: TestStore.wrap(store, hook), else: store end

    {:ok, art} =
      Artifact.new(
        store: wrap.(store, opts[:artifact_hook]),
        object_store: Keyword.get_lazy(opts, :object_store, &object_store!/0),
        max_bytes: Keyword.get(opts, :max_bytes, 65_536)
      )

    {:ok, rs} = RecipeStore.new(artifact: art, log: wrap.(store, opts[:log_hook]))
    %{rs: rs, art: art}
  end

  def tenant, do: "t-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  def caller(tenant, opts \\ []),
    do: %{
      tenant: tenant,
      principal: Keyword.get(opts, :principal, "worker-1"),
      scopes: Keyword.get(opts, :scopes, [])
    }

  def artifact_id("recipe-package-v1:sha256:" <> hex), do: hex

  def stream(tenant), do: "recipe-store/" <> tenant

  @doc "The visible rows of a stream (kind and decoded payload) in order."
  def rows(store, stream) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])

    if head.revision == 0 do
      []
    else
      {:ok, rows, _} = Elzoo.DurableLog.read(store, stream, 1, head.revision)
      Enum.map(rows, &{&1.kind, Jason.decode!(&1.payload)})
    end
  end

  def kinds(store, stream, kind), do: for({^kind, p} <- rows(store, stream), do: p)

  @doc "Append valid rows of `kind` with the given payloads in one batch (test filler)."
  def append!(store, stream, kind, payloads) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      payloads
      |> Enum.with_index(head.revision + 1)
      |> Enum.map(fn {payload, sequence} ->
        row = %Elzoo.DurableLog.Record{
          stream: stream,
          sequence: sequence,
          kind: kind,
          schema_version: 1,
          payload: payload,
          nonce: nonce
        }

        %{row | digest: Elzoo.DurableLog.digest(row)}
      end)

    request = %{
      operation: :append,
      stream: stream,
      expected: head.revision,
      target: head.revision + length(rows),
      nonce: nonce,
      digest: Codec.hash(Enum.map(rows, &Elzoo.DurableLog.canonical_bytes/1)),
      records: rows
    }

    {:committed, _} =
      Elzoo.DurableLog.Store.write(store, :append, [stream, head.revision, rows, []], request)

    :ok
  end

  # ── hooks ────────────────────────────────────────────────────────────

  @doc """
  A hook for the append of the first record that `match` accepts: it tells the
  test (`{:paused, pid}`), waits for `:go`, then lets the append through. Later
  appends pass.
  """
  def pause_once(test_pid, match) do
    {:ok, agent} = Agent.start_link(fn -> false end)

    fn stream, expected, records ->
      if match.(stream, expected, records) and
           Agent.get_and_update(agent, fn done -> {not done, true} end) do
        send(test_pid, {:paused, self()})

        receive do
          :go -> :pass
        end
      else
        :pass
      end
    end
  end

  @doc "A hook that refuses (once) the first append that `match` accepts, as a Store rejection."
  def refuse_once(match, reason \\ :invalid_revision) do
    {:ok, agent} = Agent.start_link(fn -> false end)

    fn stream, expected, records ->
      if match.(stream, expected, records) and
           Agent.get_and_update(agent, fn done -> {not done, true} end),
         do: {:reply, {:rejected, reason}},
         else: :pass
    end
  end

  def tenant_stream?(stream), do: String.starts_with?(stream, "recipe-store/")
  def artifact_stream?(stream), do: String.starts_with?(stream, "artifact/")

  # ── packages and facts ───────────────────────────────────────────────

  defp typed(direction) do
    %{
      "port" => %{
        "id" => direction,
        "direction" => direction,
        "schema_id" => "value",
        "schema_version" => 1
      },
      "schema" => %{"type" => "object"}
    }
  end

  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, child} -> [Jason.encode!(key), ":", canonical(child)] end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]

  defp canonical(value), do: Jason.encode!(value)

  @doc "A valid neutral package; the options change the name, the version and the skills."
  def package(opts \\ []) do
    %{
      "format_version" => 1,
      "name" => Keyword.get(opts, :name, "weekly-report"),
      "version" => Keyword.get(opts, :version, "1"),
      "needs" => ["search-index"],
      "permissions" => ["read-docs"],
      "skills" => Keyword.get(opts, :skills, []),
      "graph" => %{
        "version" => 1,
        "id" => "graph",
        "revision" => 1,
        "root" => "main",
        "callables" => [
          %{
            "name" => "main",
            "kind" => "graph",
            "input" => typed("input"),
            "output" => typed("output"),
            "input_slots" => [],
            "nodes" => [
              %{
                "id" => "fetch",
                "kind" => "tool",
                "tool" => "listing_search",
                "needs" => [],
                "gives" => []
              },
              %{"id" => "review", "kind" => "ask", "needs" => [], "gives" => []}
            ],
            "links" => []
          }
        ],
        "bindings" => [],
        "rules" => []
      },
      "settings" => %{
        "version" => 1,
        "id" => "independent-settings",
        "revision" => 1,
        "port" => typed("input")["port"],
        "secrets" => [],
        "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      }
    }
    |> then(fn map ->
      digest = :crypto.hash(:sha256, IO.iodata_to_binary(canonical(map)))
      Map.put(map, "identity", "recipe-package-v1:sha256:" <> Base.encode16(digest, case: :lower))
    end)
  end

  def skill(sentinel),
    do: %{
      "name" => "notes",
      "version" => "1",
      "tools" => [],
      "frontmatter" => %{"name" => "notes", "description" => "Notes"},
      "body" => sentinel
    }

  @doc "Facts under which `package/1` passes; `overrides` change single members."
  def facts(overrides \\ %{}) do
    tool = %{
      "trust" => "untrusted",
      "name" => "search",
      "description" => "Search documents",
      "input_schema" => %{"type" => "object"},
      "annotations" => nil
    }

    {:ok, tools} =
      Elzoo.ToolRegistry.snapshot([
        %{"id" => "listing", "kind" => "host_listing", "callable" => "adapter", "tools" => [tool]}
      ])

    Map.merge(
      %{
        "tools" => tools,
        "provided_needs" => ["search-index"],
        "granted_permissions" => ["read-docs"],
        "tool_requirements" => %{
          "listing_search" => %{"needs" => ["search-index"], "permissions" => ["read-docs"]}
        },
        "unit" => "token",
        "costs" => [
          %{"callable" => "main", "node" => "fetch", "estimate" => 40},
          %{"callable" => "main", "node" => "review", "estimate" => 2}
        ],
        "cap" => 100
      },
      overrides
    )
  end

  def refusing_facts, do: facts(%{"granted_permissions" => []})
end
