# SPDX-License-Identifier: Apache-2.0
# Test support for assembly/knowledge-ingest: Repos, the migration, a scripted embedding
# provider that counts its calls, seam hooks, and the per-test environment (a random schema
# with Oban, the durable-log tables for the intent Store, the Piece tables and a search index;
# a real state/artifact store over the disposable MinIO). Self-contained: no other Piece's test
# support is required, so it runs in a copied consumer.
Postgrex.Types.define(
  Elzoo.KnowledgeIngest.TestTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)

defmodule Elzoo.KnowledgeIngest.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.KnowledgeIngest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.KnowledgeIngest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.KnowledgeIngest.TestMigration do
  @moduledoc false
  use Ecto.Migration

  # prefix/0 is Ecto.Migration's: the migrator's :prefix option.
  def up do
    Oban.Migration.up(prefix: prefix())
    Elzoo.DurableLog.Postgres.Migration.up()
    Elzoo.KnowledgeIngest.Migration.install(prefix())
  end
end

defmodule Elzoo.KnowledgeIngest.ArtifactMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
end

defmodule Elzoo.KnowledgeIngest.TestBinding do
  use Elzoo.AiEmbedding.Binding,
    id: "knowledge-ingest-test",
    provider_account: "test:account",
    recovery_grace_ms: 600_000
end

defmodule Elzoo.KnowledgeIngest.Script do
  @moduledoc """
  The scripted provider's state: the responses still to give (each `:ok`, `{:status, tag}`,
  `{:status, tag, meta}`, `:timeout`, `:hang` or `:nonunit`; `:ok` once they run out), every
  call's inputs and process, and whether two calls were ever live at once.
  """
  def start, do: Agent.start(fn -> %{script: [], calls: [], pids: [], overlap: false} end)
  def script(s, responses), do: Agent.update(s, &%{&1 | script: responses})
  def calls(s), do: Agent.get(s, & &1.calls)
  def pids(s), do: Agent.get(s, & &1.pids)
  def overlap?(s), do: Agent.get(s, & &1.overlap)

  def take(s, inputs) do
    me = self()

    Agent.get_and_update(s, fn st ->
      live = Enum.filter(st.pids, &Process.alive?/1)
      {response, rest} = if st.script == [], do: {:ok, []}, else: {hd(st.script), tl(st.script)}

      {response,
       %{
         st
         | script: rest,
           calls: st.calls ++ [inputs],
           pids: st.pids ++ [me],
           overlap: st.overlap or live != []
       }}
    end)
  end
end

defmodule Elzoo.KnowledgeIngest.TestProvider do
  @moduledoc "A scripted embedding provider; `provider_config` is `%{script: pid}`."
  @behaviour Elzoo.AiEmbedding.Provider
  alias Elzoo.KnowledgeIngest.Script

  @impl true
  def capabilities do
    %{
      piece: "test/knowledge-ingest-provider",
      provider: "test",
      wire_surface: "scripted",
      models: %{
        "test-embed" => %{native: 4, min: 2, max: 4},
        "test-other" => %{native: 4, min: 4, max: 4}
      },
      input_types: [:unspecified, :document],
      max_inputs: 2048,
      convention: %{input_includes_cached: false},
      options: %{}
    }
  end

  @impl true
  def translate(request, cfg), do: {:ok, %{request: request, cfg: cfg}}

  @impl true
  def call(%{request: request, cfg: %{script: s}}, _opts) do
    case Script.take(s, request.inputs) do
      :ok -> {:ok, {:raw, raw(request, &vector/1)}}
      :nonunit -> {:ok, {:raw, raw(request, fn _ -> [1.0, 1.0, 0.0, 0.0] end)}}
      :timeout -> {:transport, :timeout}
      :hang -> receive(do: (:never -> {:transport, :timeout}))
      {:status, tag} -> {:ok, {:status, tag}}
      {:status, tag, meta} -> {:ok, {:status, tag, meta}}
    end
  end

  @doc "The vector of the input at batch position `i` (unit length, written out by hand)."
  def vector(i) when rem(i, 2) == 0, do: [0.6, 0.8, 0.0, 0.0]
  def vector(_), do: [0.0, 0.0, 0.28, 0.96]

  defp raw(request, vector) do
    {:ok, usage} =
      Elzoo.AiModel.Usage.from_provider(
        %{
          input: 10 * length(request.inputs),
          cache_read: :unknown,
          cache_writes: [%{ttl: "provider_default", amount: :unknown}],
          output: :unknown
        },
        %{input_includes_cached: false},
        :provider_reported
      )

    %{
      items: for(i <- 0..(length(request.inputs) - 1), do: %{index: i, vector: vector.(i)}),
      provider_model: request.model,
      usage: usage,
      request_id: "req"
    }
  end

  @impl true
  def decode({:raw, raw}, _), do: {:ok, raw}
  def decode({:status, tag}, _), do: {:failure, tag}
  def decode({:status, tag, meta}, _), do: {:failure, tag, meta}

  @impl true
  def classify_failure({:transport, :timeout}), do: :timeout
  def classify_failure(_), do: :transport
end

defmodule Elzoo.KnowledgeIngest.Hooks do
  @moduledoc "Seam handlers by point; a handler gets the point's info map."
  def start, do: Agent.start(fn -> %{} end)
  def on(h, point, fun), do: Agent.update(h, &Map.put(&1, point, fun))
  def off(h, point), do: Agent.update(h, &Map.delete(&1, point))

  def call(h, point, info) do
    case Agent.get(h, &Map.get(&1, point)) do
      nil -> :ok
      fun -> fun.(info)
    end
  end
end

defmodule Elzoo.KnowledgeIngest.Harness do
  @moduledoc false
  alias Ecto.Adapters.SQL
  alias Elzoo.{Artifact, EffectIntent, KnowledgeIngest, SearchData, TenantIsolation}
  alias Elzoo.DurableLog.{Memory, Postgres}
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.KnowledgeIngest.{Hooks, Script, TestBinding, TestProvider, TestRepo}

  @s3 ~w(ELZOO_TEST_S3_URL ELZOO_TEST_S3_BUCKET ELZOO_TEST_S3_ACCESS_KEY_ID ELZOO_TEST_S3_SECRET_ACCESS_KEY ELZOO_TEST_S3_REGION)

  @doc "Fail closed: the database must name a database and be the effective one."
  def url! do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required; tests fail closed"

    if url |> URI.parse() |> Map.get(:path, "") |> to_string() |> String.trim_leading("/") == "",
      do: raise("ELZOO_TEST_DATABASE_URL names no database; refusing")

    url
  end

  @doc "The ELZ-285 application role; the tests fail, not skip, without it."
  def app_role! do
    role =
      System.get_env("ELZOO_TEST_APP_ROLE") ||
        raise "ELZOO_TEST_APP_ROLE is required (ELZ-285); tests fail closed"

    if role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/,
      do: role,
      else: raise("ELZOO_TEST_APP_ROLE is not a plain identifier; refusing")
  end

  def s3! do
    if Enum.any?(@s3, &(System.get_env(&1) in [nil, ""])),
      do: raise("ELZOO_TEST_S3_* is required; tests fail closed")

    e = Map.new(@s3, &{&1, System.get_env(&1)})

    {:ok, c} =
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

    c
  end

  def start!(repo, opts) do
    url = url!()
    configured = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")

    pid =
      case repo.start_link([url: url, log: false, types: Elzoo.KnowledgeIngest.TestTypes] ++ opts) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.unlink(pid)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    [[effective]] = query!(repo, "SELECT current_database()").rows
    if effective != configured, do: raise("effective database differs from configured; refusing")
    pid
  end

  @doc "after_connect of every application connection: SET ROLE, then optional settings."
  def connect(conn, role, settings) do
    Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])
    for sql <- settings, do: Postgrex.query!(conn, sql, [])
  end

  def query!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)

  @doc "Telemetry handler: tell `pid` of each query that `pid` itself sends."
  def forward(_event, _measurements, _meta, {pid, id}),
    do: if(self() == pid, do: send(pid, {:query, id}))

  def artifact_fold,
    do: %{
      initial: 0,
      kinds: Artifact.kinds(),
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  @doc "Start TestRepo and the module's artifact schema (dropped after the module); its prefix."
  def module_setup! do
    start!(TestRepo, pool_size: 20)
    ap = "elz334a_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    query!(TestRepo, ~s(CREATE SCHEMA "#{ap}"))

    :ok =
      Ecto.Migrator.up(TestRepo, 1, Elzoo.KnowledgeIngest.ArtifactMigration, prefix: ap, log: false)

    ExUnit.Callbacks.on_exit(fn -> drop!(ap) end)
    ap
  end

  @doc "A random schema with Oban, the durable-log tables and the Piece tables."
  def schema! do
    p = "elz334_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    query!(TestRepo, ~s(CREATE SCHEMA "#{p}"))

    :ok =
      Ecto.Migrator.up(TestRepo, 1, Elzoo.KnowledgeIngest.TestMigration, prefix: p, log: false)

    p
  end

  def drop!(p), do: query!(TestRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def descriptor,
    do: %{
      provider: "test",
      model: "test-embed",
      dimensions: 4,
      dtype: :float32,
      normalization: :unit_l2_verified
    }

  def search!(p, opts \\ []) do
    declaration =
      %{
        index_identity: Keyword.get(opts, :index_identity, "docs"),
        descriptor: descriptor(),
        metric: :cosine
      }
      |> Map.merge(Map.new(Keyword.take(opts, [:text_search])))

    {:ok, b} = SearchData.new(TestRepo, declaration, prefix: p)
    {:ok, ^b} = SearchData.Migration.install(b)
    b
  end

  def oban!(name, p, extra \\ []) do
    opts =
      [
        name: name,
        repo: TestRepo,
        prefix: p,
        queues: [],
        plugins: [],
        lifeline: false,
        pruner: false,
        stager: [interval: 50],
        notifier: Oban.Notifiers.PG,
        peer: {Oban.Peers.Isolated, leader?: true},
        log: false
      ]
      |> Keyword.merge(extra)

    {:ok, pid} = Oban.start_link(opts)
    Process.unlink(pid)
    pid
  end

  @doc "Stop the Oban instance `name` (or pid), whichever process holds it now."
  def stop_oban(name) when is_atom(name) do
    case Oban.whereis(name) do
      nil -> :ok
      pid -> stop_oban(pid)
    end
  end

  def stop_oban(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  def clock, do: fn -> System.os_time(:millisecond) end

  def sql_intent(p) do
    %{
      store:
        Postgres.store(TestRepo,
          prefix: p,
          fold: EffectIntent.fold(TestBinding),
          limits: EffectIntent.limits()
        ),
      host:
        {StoreHost,
         %{
           store:
             Postgres.store(TestRepo,
               prefix: p,
               fold: StoreHost.fold(),
               limits: StoreHost.limits()
             ),
           authorize: fn _, _ -> :fresh end
         }},
      clock: clock()
    }
  end

  def memory_intent do
    {:ok, m} =
      Memory.start_link(fold: EffectIntent.fold(TestBinding), limits: EffectIntent.limits())

    {:ok, h} = Memory.start_link(fold: StoreHost.fold(), limits: StoreHost.limits())
    Process.unlink(m)
    Process.unlink(h)

    %{
      store: Memory.store(m),
      host: {StoreHost, %{store: Memory.store(h), authorize: fn _, _ -> :fresh end}},
      clock: clock(),
      allow_volatile: true
    }
  end

  def embedding(script, extra \\ []) do
    Keyword.merge(
      [
        binding: TestBinding,
        provider: TestProvider,
        provider_config: %{script: script},
        credentials: fn -> {:ok, "sk-test-key"} end,
        models: ["test-embed", "test-other"]
      ],
      extra
    )
  end

  @doc """
  The per-test environment: schema, search index, Oban (no queue runs; tests drain), artifact
  store (its records in the module's artifact schema), scripted provider, hooks and config.
  """
  def env!(art_prefix, opts \\ []) do
    p = schema!()
    ExUnit.Callbacks.on_exit(fn -> drop!(p) end)
    name = String.to_atom("ki_oban_" <> p)
    queue = "ki_" <> binary_part(p, 7, 12)
    # run: true runs the queue (group 6) with a short shutdown grace; otherwise tests drain.
    running = if opts[:run], do: [queues: [{String.to_atom(queue), 2}], shutdown_grace_period: 50], else: []
    oban = oban!(name, p, running ++ Keyword.get(opts, :oban, []))
    ExUnit.Callbacks.on_exit(fn -> stop_oban(name) end)
    ExUnit.Callbacks.on_exit(fn -> Elzoo.Jobs.unregister(queue) end)

    {:ok, art} =
      Artifact.new(
        store:
          Postgres.store(TestRepo,
            prefix: art_prefix,
            fold: artifact_fold(),
            limits: %{max_record_bytes: 8_192, max_batch_size: 4, max_checkpoint_bytes: 10_000}
          ),
        object_store: s3!(),
        clock: clock(),
        max_bytes: 16_777_216
      )

    {:ok, script} = Script.start()
    {:ok, hooks} = Hooks.start()
    search = search!(p, Keyword.take(opts, [:text_search, :index_identity]))

    env = %{
      p: p,
      oban: name,
      oban_pid: oban,
      queue: queue,
      art: art,
      script: script,
      hooks: hooks,
      search: search,
      intent: Keyword.get_lazy(opts, :intent, fn -> sql_intent(p) end)
    }

    {:ok, c} = config(env, Keyword.get(opts, :config, []), Keyword.get(opts, :seam, %{}))
    :ok = Elzoo.Jobs.register(queue, KnowledgeIngest.runner(c))
    Map.put(env, :c, c)
  end

  def opts(env, overrides \\ []) do
    Keyword.merge(
      [
        repo: TestRepo,
        prefix: env.p,
        oban: env.oban,
        queue: env.queue,
        search: env.search,
        artifact: env.art,
        artifact_scopes: ["read"],
        embedding: embedding(env.script),
        request: %{model: "test-embed"},
        intent: env.intent
      ],
      overrides
    )
  end

  def config(env, overrides \\ [], seam \\ %{}) do
    hooks = env.hooks

    KnowledgeIngest.__new__(
      opts(env, overrides),
      Map.merge(%{hook: fn point, info -> Hooks.call(hooks, point, info) end}, seam)
    )
  end

  @doc "Register `c`'s runner on the env's queue (replacing the current one)."
  def register(env, c), do: Elzoo.Jobs.register(env.queue, KnowledgeIngest.runner(c))

  def put_doc!(env, tenant, artifact_id, bytes, opts \\ []) do
    caller = %{tenant: tenant, principal: "svc-ingest", scopes: ["read"]}

    {:ok, rec} =
      Artifact.put(env.art, caller, artifact_id, %{
        bytes: bytes,
        media_type: "text/plain",
        access: Keyword.get(opts, :access),
        access_expires_at_unix_ms: :never,
        retain_until_unix_ms: :never
      })

    rec
  end

  def request(artifact_id, opts \\ []) do
    %{
      source_ref: Keyword.get(opts, :source_ref, "doc-1"),
      version: Keyword.get(opts, :version, 1),
      artifact: %{artifact_id: artifact_id, version: Keyword.get(opts, :artifact_version, 1)},
      media_type: Keyword.get(opts, :media_type, "text/plain"),
      chunking: Keyword.get(opts, :chunking, [])
    }
  end

  def drain(env),
    do: Oban.drain_queue(env.oban, queue: env.queue, with_scheduled: true, with_recursion: true)

  @doc "Run the queue's available jobs once (no scheduled, no recursion)."
  def drain_once(env), do: Oban.drain_queue(env.oban, queue: env.queue)

  @doc "Rows of `sql` (`$1` is the tenant) under the tenant floor."
  def scoped!(tenant, sql, params \\ []), do: scoped_as!(TestRepo, tenant, sql, params)

  def scoped_as!(repo, tenant, sql, params) do
    {:ok, rows} =
      TenantIsolation.transact(repo, %{tenant: tenant}, fn ->
        {:ok, query!(repo, sql, [tenant | params]).rows}
      end)

    rows
  end

  def jobs(env),
    do:
      query!(
        TestRepo,
        ~s(SELECT id, state, args->>'job_key', attempt FROM "#{env.p}".oban_jobs ORDER BY id)
      ).rows

  def job!(env, id) do
    import Ecto.Query
    TestRepo.one!(from(j in Oban.Job, where: j.id == ^id), prefix: env.p)
  end

  def staged(env, tenant),
    do:
      scoped!(
        tenant,
        ~s[SELECT count(*) FROM "#{env.p}".elzoo_knowledge_chunks WHERE tenant = $1]
      )
      |> hd()
      |> hd()

  @doc "A one-shot barrier for `n` processes: each `arrive` blocks until all have arrived."
  def barrier(n) do
    {:ok, pid} = Agent.start(fn -> {n, []} end)
    pid
  end

  def arrive(b) do
    me = self()

    Agent.update(b, fn {n, waiting} ->
      if n == 1 do
        Enum.each([me | waiting], &send(&1, {:barrier, b}))
        {0, []}
      else
        {n - 1, [me | waiting]}
      end
    end)

    receive do
      {:barrier, ^b} -> :ok
    after
      10_000 -> raise "barrier timeout"
    end
  end

  def poll(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "poll timeout"
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end
end

defmodule Elzoo.KnowledgeIngest.Cases do
  @moduledoc "Helpers shared by the test modules."
  import ExUnit.Assertions
  alias Elzoo.Jobs.Worker
  alias Elzoo.KnowledgeIngest, as: KI
  alias Elzoo.KnowledgeIngest.{Harness, Hooks}
  alias Elzoo.SearchData

  def env(ctx, opts \\ []), do: Harness.env!(ctx.ap, opts)
  def tenant, do: "t-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  def caller(t, actor \\ "svc-ingest"), do: %{tenant: t, actor: actor}
  def key(r), do: %{source_ref: r.source_ref, version: r.version}
  def xs(n, g \\ "x"), do: String.duplicate(g, 2000 * n)
  # n chunks of 2,000 graphemes (with chunk_overlap 0), each of another letter
  def blocks(n), do: Enum.map_join(0..(n - 1), &String.duplicate(<<?a + &1>>, 2000))

  # A document of `bytes` in a new artifact, and its request.
  def doc(env, t, bytes, opts \\ []) do
    id = "a-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    Harness.put_doc!(env, t, id, bytes, Keyword.take(opts, [:access]))
    Harness.request(id, Keyword.drop(opts, [:access]))
  end

  def submit!(env, t, r) do
    assert {:ok, %{state: :requested}} = KI.submit(env.c, caller(t), r)
    r
  end

  def status(env, t, r) do
    {:ok, s} = KI.status(env.c, caller(t), key(r))
    s
  end

  def attempts(env, t, r) do
    {:ok, %{entries: e, next: nil}} =
      KI.attempts(env.c, caller(t), Map.merge(key(r), %{after: nil, limit: 256}))

    e
  end

  def jobs(env, step), do: Enum.filter(Harness.jobs(env), &(Enum.at(&1, 2) =~ "/#{step}/"))

  # Run one job of `step` (the latest) through the Worker, as Oban would.
  def run(env, step, changes) do
    [id | _] = jobs(env, step) |> List.last()
    Worker.perform(Map.merge(Harness.job!(env, id), changes))
  end

  def ingest_id(prefix, index, t, ref, v) do
    fields = ["elzoo/knowledge-ingest/ingest/1", prefix, index, t, ref, Integer.to_string(v)]

    :crypto.hash(:sha256, Enum.map(fields, &<<byte_size(&1)::32, &1::binary>>))
    |> Base.encode16(case: :lower)
  end

  # Count the queries this process sends through TestRepo while `fun` runs.
  def queries(fun) do
    me = self()
    id = make_ref()

    :telemetry.attach(
      id,
      [:elzoo, :knowledge_ingest, :test_repo, :query],
      &Harness.forward/4,
      {me, id}
    )

    try do
      result = fun.()
      {result, count(id)}
    after
      :telemetry.detach(id)
    end
  end

  def count(id) do
    receive do
      {:query, ^id} -> 1 + count(id)
    after
      0 -> 0
    end
  end

  def once(env, point, fun) do
    {:ok, flag} = Agent.start(fn -> true end)

    Hooks.on(env.hooks, point, fn info ->
      if Agent.get_and_update(flag, &{&1, false}), do: fun.(info), else: :ok
    end)
  end

  def puts(env) do
    {:ok, n} = Agent.start(fn -> 0 end)
    Hooks.on(env.hooks, :put_source, fn _ -> Agent.update(n, &(&1 + 1)) end)
    n
  end

  def stored(env, t, ref) do
    Harness.scoped!(
      t,
      ~s[SELECT DISTINCT version FROM "#{env.p}".#{SearchData.table_name("docs")} WHERE tenant = $1 AND source_ref = $2],
      [ref]
    )
    |> List.flatten()
  end

  @doc "The candidates of a query for `ref` with `embedding` as the query."
  def query(env, t, ref, embedding) do
    SearchData.query(env.search, %{
      tenant: t,
      query_embedding: embedding,
      k: 256,
      allowed_sources: [ref],
      principal: "host",
      checked_at: 0
    })
  end
end
