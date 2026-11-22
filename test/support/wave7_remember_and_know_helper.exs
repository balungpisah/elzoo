Code.require_file(
  "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
  __DIR__
)

# ELZ-338 harness: Repos, the consumer migrations, the scripted topic embedding provider and the
# host code (embedding calls, metering, fusion, policies, Runs) of the Wave 7 root acceptance.
Postgrex.Types.define(
  Elzoo.Wave7.Types,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)

# The owner connection (elzoo_test, not a superuser): schemas, installs, grants, catalog reads and
# the unprotected tables (Store tables, Oban's jobs, the vault tables).
defmodule Elzoo.Wave7.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.Wave7.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Wave7.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration of the main schema, run by the table owner. prefix/0 is the
  # migrator's :prefix option.
  def up do
    p = prefix()
    Oban.Migration.up(prefix: p)
    Elzoo.DurableLog.Postgres.Migration.up()
    Elzoo.KnowledgeIngest.Migration.install(p)
    Elzoo.MemoryRecord.Migration.install(p)
    Elzoo.Metering.Migration.install(p)
    Elzoo.RetentionErasure.Migration.install(p)
  end
end

defmodule Elzoo.Wave7.StoreMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
end

# search-data's floor, in a consumer migration after the run-time install/1.
defmodule Elzoo.Wave7.FloorMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.SearchData.Migration.protect(:persistent_term.get({__MODULE__, prefix()}))
end

defmodule Elzoo.Wave7.EmbedBinding do
  use Elzoo.AiEmbedding.Binding,
    id: "wave7-embed",
    provider_account: "test:wave7",
    recovery_grace_ms: 600_000
end

defmodule Elzoo.Wave7.Topics do
  @moduledoc """
  The host table of topic words. A text's vector counts the words of each topic in it and is
  normalized to unit length; a text with no topic word is the `misc` unit vector.
  """
  @topics [
    refund: ~w(refund refunds),
    shipping: ~w(shipping ship shipped delivery),
    terms: ~w(terms warranty),
    faq: ~w(faq question),
    language: ~w(language english indonesian),
    allergy: ~w(allergy allergic peanuts),
    address: ~w(street address),
    misc: []
  ]

  def dimensions, do: length(@topics)

  def vector(text) do
    words = text |> String.downcase() |> String.split(~r/[^a-z]+/, trim: true)

    counts =
      for {_topic, list} <- @topics, do: Enum.count(words, &(&1 in list)) * 1.0

    counts = if Enum.all?(counts, &(&1 == 0.0)), do: List.replace_at(counts, -1, 1.0), else: counts
    norm = :math.sqrt(Enum.sum(Enum.map(counts, &(&1 * &1))))
    Enum.map(counts, &(&1 / norm))
  end
end

defmodule Elzoo.Wave7.Script do
  @moduledoc """
  The scripted provider's state: rules `{name, predicate, action}` used once each (the first rule
  whose predicate holds for a call's inputs decides it; `:ok` otherwise), every call's inputs and
  the test process that hears about held calls.
  """
  def start(owner),
    do: Agent.start(fn -> %{rules: [], calls: [], owner: owner, held: []} end)

  def rule(s, name, predicate, action),
    do: Agent.update(s, &%{&1 | rules: &1.rules ++ [{name, predicate, action}]})

  def calls(s), do: Agent.get(s, & &1.calls)
  def calls(s, fun), do: Enum.count(calls(s), fun)
  def owner(s), do: Agent.get(s, & &1.owner)

  def take(s, inputs) do
    Agent.get_and_update(s, fn st ->
      st = %{st | calls: st.calls ++ [inputs]}

      case Enum.split_with(st.rules, fn {_, pred, _} -> not pred.(inputs) end) do
        {_, []} -> {:ok, st}
        {before, [{_, _, action} | rest]} -> {action, %{st | rules: before ++ rest}}
      end
    end)
  end
end

defmodule Elzoo.Wave7.TopicProvider do
  @moduledoc """
  The scripted embedding provider: a unit vector per input from `Elzoo.Wave7.Topics`, usage of
  10 `input_uncached_tokens` per input. `provider_config` is `%{script: pid}`.
  """
  @behaviour Elzoo.AiEmbedding.Provider
  alias Elzoo.Wave7.{Script, Topics}

  @impl true
  def capabilities do
    n = Topics.dimensions()

    %{
      piece: "test/wave7-topic-provider",
      provider: "topic",
      wire_surface: "scripted",
      models: %{"topic-embed" => %{native: n, min: n, max: n}},
      input_types: [:unspecified],
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
      :ok ->
        {:ok, {:raw, raw(request)}}

      :timeout ->
        {:transport, :timeout}

      :hold ->
        send(Script.owner(s), {:held, self()})
        receive(do: (:release -> {:ok, {:raw, raw(request)}}))

      {:status, tag, meta} ->
        {:ok, {:status, tag, meta}}

      {:status, tag} ->
        {:ok, {:status, tag}}
    end
  end

  defp raw(request) do
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
      items:
        request.inputs
        |> Enum.with_index()
        |> Enum.map(fn {text, i} -> %{index: i, vector: Topics.vector(text)} end),
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

defmodule Elzoo.Wave7.Helper do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL

  alias Elzoo.{
    AiEmbedding,
    Artifact,
    Citation,
    EffectIntent,
    KnowledgeIngest,
    Metering,
    PayloadSchema,
    RetentionErasure,
    RunEngine,
    SearchData,
    Secrets,
    TenantIsolation,
    TypedDecision,
    UntrustedContent
  }

  alias Elzoo.AiEmbedding.{Request, Sink}
  alias Elzoo.DurableLog.{Postgres, PostgresHarness}
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.RunEngine.TestHelper
  alias Elzoo.Wave7.{AppRepo, EmbedBinding, OwnerRepo, Script, TopicProvider}

  @now 1_795_000_000_000
  @period "2026-11"
  @model "topic-embed"
  @s3 ~w(ELZOO_TEST_S3_URL ELZOO_TEST_S3_BUCKET ELZOO_TEST_S3_ACCESS_KEY_ID ELZOO_TEST_S3_SECRET_ACCESS_KEY ELZOO_TEST_S3_REGION)
  @extra_schemas ~w(elzoo/ai-text-request elzoo.ai-text.result elzoo.typed-decision.result)

  def now, do: @now
  def period, do: @period

  # ------------------------------------------------------------ connections (from ELZ-323/286)

  @doc """
  The fixed application role of ELZ-285, `elzoo_app`; the test fails when the variable is unset,
  not a role name, or names another role, before any pool starts or grant runs.
  """
  def app_role! do
    role = System.get_env("ELZOO_TEST_APP_ROLE")

    if not (is_binary(role) and role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/),
      do: flunk("ELZOO_TEST_APP_ROLE must name the application role of ELZ-285; it is unset")

    if role != "elzoo_app",
      do:
        flunk("ELZOO_TEST_APP_ROLE must be elzoo_app, the fixed role of ELZ-285: #{inspect(role)}")

    role
  end

  def start_repos! do
    url = PostgresHarness.database_url!()
    role = app_role!()
    base = [url: url, log: false, types: Elzoo.Wave7.Types]

    for {repo, extra} <- [
          {OwnerRepo, [pool_size: 4]},
          {AppRepo,
           [pool_size: 12, after_connect: {Postgrex, :query!, [~s(SET ROLE "#{role}"), []]}]}
        ] do
      {:ok, pid} = repo.start_link(base ++ extra)
      Process.unlink(pid)
      :ok = PostgresHarness.reachable!(repo)
    end

    role
  end

  def stop!(repo) do
    case Process.whereis(repo) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @doc """
  The role facts of a connection: its role, the session (owner) role, superuser, BYPASSRLS,
  LOGIN, INHERIT, CREATEROLE, CREATEDB, and whether it holds the session role's privileges.
  """
  def role_facts(repo) do
    [[current, session, super, bypass, login, inherit, createrole, createdb, inherits_owner]] =
      q!(
        repo,
        "SELECT current_user::text, session_user::text, r.rolsuper, r.rolbypassrls, r.rolcanlogin, r.rolinherit, r.rolcreaterole, r.rolcreatedb, pg_has_role(current_user, session_user, 'USAGE') FROM pg_roles r WHERE r.rolname = current_user"
      )

    %{
      current: current,
      session: session,
      super: super,
      bypass: bypass,
      login: login,
      inherit: inherit,
      createrole: createrole,
      createdb: createdb,
      inherits_owner: inherits_owner
    }
  end

  @doc """
  Fails, never skips: the application connection must be `elzoo_app`, not the session role,
  NOSUPERUSER, NOBYPASSRLS, NOLOGIN, NOINHERIT, NOCREATEROLE, NOCREATEDB and without the
  session role's privileges.
  """
  def role_guard!(role) do
    facts = role_facts(AppRepo)

    if role != "elzoo_app" or facts.current != role or facts.current == facts.session or
         facts.super or facts.bypass or facts.login or facts.inherit or facts.createrole or
         facts.createdb or facts.inherits_owner,
       do:
         flunk(
           "the application connection is not the non-owner application role #{role}: #{inspect(facts)}"
         )

    facts
  end

  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)
  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows
  def owner!(sql, params \\ []), do: q!(OwnerRepo, sql, params)

  @doc "A table read as `elzoo_app` inside `TenantIsolation.transact/3` with the tenant's scope."
  def read_as(tenant, sql, params \\ []) do
    {:ok, rows} =
      TenantIsolation.transact(AppRepo, %{tenant: tenant}, fn -> {:ok, q!(AppRepo, sql, params)} end)

    rows
  end

  @doc "A statement as `elzoo_app` in the tenant's scope; its result, then always rolled back."
  def try_as(tenant, sql, params \\ []) do
    {:error, {:result, result}} =
      TenantIsolation.transact(AppRepo, %{tenant: tenant}, fn ->
        {:error, {:result, q(AppRepo, sql, params)}}
      end)

    result
  end

  @doc "A statement as `elzoo_app` with no tenant scope, always rolled back."
  def try_app(sql) do
    {:error, {:result, result}} =
      AppRepo.transaction(fn -> AppRepo.rollback({:result, q(AppRepo, sql)}) end)

    result
  end

  def denied?(result),
    do: match?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}, result)

  def rls_denied?(result) do
    case result do
      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege, message: m}}} ->
        m =~ "row-level security"

      _ ->
        false
    end
  end

  # ------------------------------------------------------------ the Store grants (from ELZ-323)

  @doc """
  The application role's privileges on the four Store tables of schema `s`: `USAGE`, `SELECT,
  INSERT, UPDATE` on heads and outbox and `SELECT, INSERT` on records and checkpoints. No
  `DELETE` and no `TRUNCATE`: no Store retention runs here.
  """
  def grant_store!(s, role) do
    for sql <- [
          "GRANT USAGE ON SCHEMA #{s} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{s}.elzoo_log_heads, #{s}.elzoo_outbox TO #{role}",
          "GRANT SELECT, INSERT ON #{s}.elzoo_log_records, #{s}.elzoo_checkpoints TO #{role}"
        ],
        do: owner!(sql)

    :ok
  end

  @doc """
  Every Store binding of a RunEngine fixture (Run, Unit, Effect intent, host, evidence and the
  transcript's reader) runs as the application role, and the owner reads that the role holds no
  `TRUNCATE` or `DELETE` on, and owns no table of, the engine schema (its four Store tables and
  Ecto's `schema_migrations`).
  """
  def engine_on_app!(c, role) do
    intents = for {_, o} <- c.opts[:effect_intent], do: [o[:store], elem(o[:host], 1).store]

    stores =
      [c.store, c.run_store, c.evidence_store, c.postgres_unit_store] ++ List.flatten(intents)

    for store <- Enum.uniq(stores) do
      assert {Postgres, %{repo: repo}} = store

      assert %{
               current: ^role,
               super: false,
               bypass: false,
               login: false,
               inherit: false,
               createrole: false,
               createdb: false,
               inherits_owner: false
             } = facts = role_facts(repo)

      assert facts.current != facts.session
    end

    assert owner!(
             """
             SELECT bool_or(has_table_privilege($1, c.oid, 'TRUNCATE')),
                    bool_or(has_table_privilege($1, c.oid, 'DELETE')),
                    bool_or(pg_get_userbyid(c.relowner) = $1), count(*)
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = $2 AND c.relkind IN ('r', 'p')
             """,
             [role, c.prefix]
           ) == [[false, false, false, 5]]
  end

  # ------------------------------------------------------------ fixture

  def descriptor,
    do: %{
      provider: "topic",
      model: @model,
      dimensions: Elzoo.Wave7.Topics.dimensions(),
      dtype: :float32,
      normalization: :unit_l2_verified
    }

  @doc """
  The disposable schemas: `p` holds Oban, the intent Store, the four knowledge-ingest tables,
  both search-data indexes with their floor, memory-record, metering and the vault; `p_art` the
  artifact Store. Only the README grants (and the copied Store grants) go to the role.
  """
  def fixture!(role) do
    p = "wave7_" <> hex(6)
    art = p <> "_art"
    for s <- [p, art], do: owner!("CREATE SCHEMA #{s}")
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave7.Migration, prefix: p, log: false)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave7.StoreMigration, prefix: art, log: false)

    owner_bindings =
      for {name, extra} <- [
            knowledge: %{index_identity: "wave7-knowledge", text_search: %{config: "english"}},
            memory: %{index_identity: "wave7-memory"}
          ],
          into: %{} do
        declaration = Map.merge(%{descriptor: descriptor(), metric: :cosine}, extra)

        {:ok, b} =
          SearchData.new(OwnerRepo, declaration, prefix: p, tenant_isolation: %{prefix: p})

        {:ok, ^b} = SearchData.Migration.install(b)
        {name, b}
      end

    for {{_, b}, version} <- Enum.with_index(owner_bindings, 2) do
      :persistent_term.put({Elzoo.Wave7.FloorMigration, p}, b)
      :ok = Ecto.Migrator.up(OwnerRepo, version, Elzoo.Wave7.FloorMigration, prefix: p, log: false)
    end

    grant!(p, art, owner_bindings, role)
    search = Map.new(owner_bindings, fn {k, b} -> {k, %{b | repo: AppRepo}} end)

    {:ok, script} = Script.start(self())
    {:ok, counter} = Agent.start(fn -> 0 end)
    {:ok, kek} = Agent.start(fn -> :crypto.strong_rand_bytes(32) end)
    {:ok, docs} = Agent.start(fn -> [] end)
    queue = "wave7_" <> binary_part(p, 6, 12)

    fx = %{
      prefix: p,
      art_prefix: art,
      role: role,
      search: search,
      owner_search: owner_bindings,
      script: script,
      counter: counter,
      kek: kek,
      docs: docs,
      queue: queue,
      oban: String.to_atom("wave7_oban_" <> p),
      art: artifact!(art),
      intent: intent(p),
      meter: Metering.new(repo: AppRepo, prefix: p),
      memory: Elzoo.MemoryRecord.new(repo: AppRepo, prefix: p),
      vault:
        RetentionErasure.vault(
          repo: AppRepo,
          prefix: p,
          kek: fn
            version when version in [:current, 1] ->
              {:ok,
               %Secrets.Credential{value: Agent.get(kek, & &1), version: 1, expires_at_unix_ms: 0}}

            _ ->
              {:error, :not_found}
          end
        )
    }

    oban!(fx, [])

    {:ok, c} =
      KnowledgeIngest.new(
        repo: AppRepo,
        prefix: p,
        oban: fx.oban,
        queue: queue,
        search: search.knowledge,
        artifact: fx.art,
        artifact_scopes: ["read"],
        embedding: embedding(fx),
        request: %{model: @model},
        intent: fx.intent,
        max_attempts: 3
      )

    # Every floor, checked as elzoo_app before the first call of each test.
    :ok = KnowledgeIngest.verify(c)
    for {_, b} <- search, do: :ok = SearchData.verify(b)

    for t <-
          ~w(elzoo_memory_records elzoo_memory_tombstones elzoo_metering_observations elzoo_metering_corrections),
        do:
          :ok =
            TenantIsolation.verify(AppRepo, {p, t},
              prefix: p,
              tenant_column: "tenant",
              space_column: nil
            )

    :ok = Elzoo.Jobs.register(queue, KnowledgeIngest.runner(c))
    Map.put(fx, :ki, c)
  end

  def hex(n), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)

  defp grant!(p, art, b, role) do
    vectors = Enum.map(b, fn {_, b} -> SearchData.table(b) end) |> Enum.join(", ")
    marks = Enum.map(b, fn {_, b} -> SearchData.marks(b) end) |> Enum.join(", ")

    for sql <- [
          # knowledge-ingest README
          "GRANT USAGE ON SCHEMA #{p} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_knowledge_ingests, #{p}.elzoo_knowledge_batches, #{p}.elzoo_knowledge_attempts TO #{role}",
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{p}.elzoo_knowledge_chunks TO #{role}",
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{p}.oban_jobs TO #{role}",
          "GRANT USAGE ON SEQUENCE #{p}.oban_jobs_id_seq TO #{role}",
          # search-data README, under the floor (both indexes)
          "GRANT SELECT ON #{SearchData.registry(b.knowledge)} TO #{role}",
          "GRANT SELECT, INSERT, DELETE ON #{vectors} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{marks} TO #{role}",
          # memory-record README
          "GRANT SELECT, INSERT, DELETE ON #{p}.elzoo_memory_records TO #{role}",
          "GRANT SELECT, INSERT ON #{p}.elzoo_memory_tombstones TO #{role}",
          # domain/metering README
          "GRANT SELECT, INSERT ON #{p}.elzoo_metering_corrections TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_metering_observations TO #{role}",
          # state/retention-erasure states no grant list: as in ELZ-286
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{p}.elzoo_vault_subjects, #{p}.elzoo_vault_keys, #{p}.elzoo_vault_entries TO #{role}"
        ],
        do: owner!(sql)

    # The intent Store (p) and the artifact Store (art): ELZ-323's grant_store!/2, copied.
    for s <- [p, art], do: :ok = grant_store!(s, role)
  end

  @doc """
  The role's explicit privileges on every relation of the test schemas, as the owner reads them
  from the ACLs: `%{relation => privileges}`, and whether the role owns any relation there.
  """
  def grants(fx) do
    rows =
      owner!(
        """
        WITH g AS (
          SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC ' ELSE '' END || n.nspname || '.' || c.relname AS k,
                 a.privilege_type AS p, a.grantee
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE n.nspname = ANY($1)
          UNION ALL
          SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC ' ELSE '' END || 'schema ' || n.nspname,
                 a.privilege_type, a.grantee
          FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a WHERE n.nspname = ANY($1)
          UNION ALL
          SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC ' ELSE '' END || 'column ' || n.nspname || '.' || c.relname || '.' || t.attname,
                 a.privilege_type, a.grantee
          FROM pg_attribute t JOIN pg_class c ON c.oid = t.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(t.attacl) a WHERE n.nspname = ANY($1)
        )
        SELECT k, string_agg(p, ',' ORDER BY p) FROM g
        WHERE grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = $2))
        GROUP BY 1 ORDER BY 1
        """,
        [[fx.prefix, fx.art_prefix], fx.role]
      )

    [[owns]] =
      owner!(
        """
        SELECT coalesce(bool_or(pg_get_userbyid(c.relowner) = $2), false)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ANY($1)
        """,
        [[fx.prefix, fx.art_prefix], fx.role]
      )

    {Map.new(rows, fn [rel, privs] -> {rel, privs} end), owns}
  end

  def cleanup!(fx) do
    stop_oban(fx.oban)
    Elzoo.Jobs.unregister(fx.queue)

    for {tenant, id, version} <- Agent.get(fx.docs, & &1) do
      Artifact.delete(fx.art, art_caller(tenant), id, version)
    end

    for agent <- [fx.script, fx.counter, fx.kek, fx.docs], do: Agent.stop(agent)
    for s <- [fx.prefix, fx.art_prefix], do: owner!("DROP SCHEMA IF EXISTS #{s} CASCADE")
    :persistent_term.erase({Elzoo.Wave7.FloorMigration, fx.prefix})
  end

  # ------------------------------------------------------------ artifact, intent, embedding

  defp s3! do
    if Enum.any?(@s3, &(System.get_env(&1) in [nil, ""])),
      do: flunk("ELZOO_TEST_S3_* is required (the disposable MinIO); the test fails closed")

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

  defp artifact!(art) do
    fold = %{
      initial: 0,
      kinds: Artifact.kinds(),
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

    {:ok, a} =
      Artifact.new(
        store:
          Postgres.store(AppRepo,
            prefix: art,
            fold: fold,
            limits: %{max_record_bytes: 8_192, max_batch_size: 4, max_checkpoint_bytes: 10_000}
          ),
        object_store: s3!(),
        clock: clock(),
        max_bytes: 16_777_216
      )

    a
  end

  def clock, do: fn -> System.os_time(:millisecond) end

  # One durable integration/sql intent Store on the application Repo: the ingest's and the host's.
  defp intent(p) do
    %{
      store:
        Postgres.store(AppRepo,
          prefix: p,
          fold: EffectIntent.fold(EmbedBinding),
          limits: EffectIntent.limits()
        ),
      host:
        {StoreHost,
         %{
           store:
             Postgres.store(AppRepo, prefix: p, fold: StoreHost.fold(), limits: StoreHost.limits()),
           authorize: fn _, _ -> :fresh end
         }},
      clock: clock()
    }
  end

  def embedding(fx),
    do: [
      binding: EmbedBinding,
      provider: TopicProvider,
      provider_config: %{script: fx.script},
      credentials: fn -> {:ok, "sk-wave7-test"} end,
      models: [@model],
      max_inputs: 4
    ]

  # ------------------------------------------------------------ Oban

  def oban!(fx, extra) do
    opts =
      [
        name: fx.oban,
        repo: AppRepo,
        prefix: fx.prefix,
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

    ensure_pg_scope!()
    {:ok, pid} = Oban.start_link(opts)
    Process.unlink(pid)
    pid
  end

  # Copied from the durable-job test helper (DJ11): Oban.Notifiers.PG (2.24.2) calls
  # `:pg.start_link(Oban.Notifiers.PG)` in its init/1, so the first notifier owns the scope and
  # the scope dies with it; a notifier started right after that Oban stops can find the dying
  # scope and exit :noproc. Before each start the scope is registered and unlinked.
  @pg_scope Oban.Notifiers.PG

  defp ensure_pg_scope! do
    case Process.whereis(@pg_scope) do
      nil ->
        case :pg.start(@pg_scope) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> ensure_pg_scope!()
        end

      pid ->
        case Process.info(pid, :links) do
          {:links, []} -> :ok
          _linked_or_exited -> await_scope_exit!(pid)
        end
    end
  end

  defp await_scope_exit!(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> ensure_pg_scope!()
    after
      5_000 -> raise "#{inspect(@pg_scope)} scope #{inspect(pid)} is still linked to a live owner"
    end
  end

  @doc "The queue running two jobs at a time with a short shutdown grace, and `lifeline`."
  def running(fx, lifeline),
    do: [queues: [{String.to_atom(fx.queue), 2}], shutdown_grace_period: 50, lifeline: lifeline]

  def stop_oban(name) do
    case Oban.whereis(name) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: Supervisor.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  @doc "A new instance on the same Repo with the runner registered on this node."
  def restart_oban!(fx, extra) do
    stop_oban(fx.oban)
    gone!(fx)
    pid = oban!(fx, extra)
    :ok = Elzoo.Jobs.register(fx.queue, KnowledgeIngest.runner(fx.ki))
    pid
  end

  def gone!(fx) do
    poll(fn -> Registry.lookup(Oban.Registry, fx.oban) == [] end)

    poll(fn ->
      Registry.select(Oban.Registry, [{{{:"$1", :_}, :_, :_}, [{:==, :"$1", fx.oban}], [true]}]) ==
        []
    end)
  end

  def drain(fx),
    do: Oban.drain_queue(fx.oban, queue: fx.queue, with_scheduled: true, with_recursion: true)

  def drain_once(fx), do: Oban.drain_queue(fx.oban, queue: fx.queue)

  @doc "Oban's job rows (unprotected) as the owner: id, state, job key, attempt."
  def jobs(fx),
    do:
      owner!("SELECT id, state, args->>'job_key', attempt FROM #{fx.prefix}.oban_jobs ORDER BY id")

  def job!(fx, id) do
    import Ecto.Query
    OwnerRepo.one!(from(j in Oban.Job, where: j.id == ^id), prefix: fx.prefix)
  end

  def poll(fun, tries \\ 1_200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("poll timeout")
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end

  # ------------------------------------------------------------ documents and ingests

  def art_caller(tenant), do: %{tenant: tenant, principal: service(tenant), scopes: ["read"]}
  def service(tenant), do: String.downcase(tenant) <> "-ingest"
  def caller(tenant), do: %{tenant: tenant, actor: service(tenant)}

  @doc "Puts `bytes` as a new artifact (or a new version of `id`); its `{id, version}`."
  # The artifact ID carries the fixture's random schema, so two runs on one bucket never share
  # an object key.
  def put_doc!(fx, tenant, name, bytes, media_type) do
    id = name <> "-" <> fx.prefix

    input = %{
      bytes: bytes,
      media_type: media_type,
      access: nil,
      access_expires_at_unix_ms: :never,
      retain_until_unix_ms: :never
    }

    {:ok, rec} =
      case Artifact.head(fx.art, art_caller(tenant), id) do
        {:ok, _} -> Artifact.new_version(fx.art, art_caller(tenant), id, input)
        _ -> Artifact.put(fx.art, art_caller(tenant), id, input)
      end

    Agent.update(fx.docs, &[{tenant, id, rec.version} | &1])
    {id, rec.version}
  end

  def request({id, art_version}, source_ref, version, media_type),
    do: %{
      source_ref: source_ref,
      version: version,
      artifact: %{artifact_id: id, version: art_version},
      media_type: media_type,
      chunking: [chunk_overlap: 0]
    }

  def submit!(fx, tenant, request) do
    assert {:ok, %{state: :requested}} = KnowledgeIngest.submit(fx.ki, caller(tenant), request)
    request
  end

  def key(r), do: %{source_ref: r.source_ref, version: r.version}

  def status(fx, tenant, r) do
    {:ok, s} = KnowledgeIngest.status(fx.ki, caller(tenant), key(r))
    s
  end

  def attempts(fx, tenant, r) do
    {:ok, %{entries: e, next: nil}} =
      KnowledgeIngest.attempts(fx.ki, caller(tenant), Map.merge(key(r), %{after: nil, limit: 256}))

    e
  end

  @doc "Parse and chunk of an artifact's bytes, as the host computes them."
  def parsed(bytes, media_type, source_ref) do
    {:ok, doc} = Elzoo.DocumentParse.parse(bytes, media_type)

    {:ok, %{chunks: chunks}} =
      Elzoo.TextChunking.chunk(doc.text, doc.text_sha256, source_ref,
        format: doc.format,
        chunk_overlap: 0
      )

    {doc, chunks}
  end

  # ------------------------------------------------------------ the host's embedding calls

  @doc """
  One host embedding call (`host/` reference) through admission and a durable intent owner on
  the shared intent Store. Records its usage observation and returns `{ref, outcome}`.
  """
  def embed!(fx, tenant, purpose, texts) do
    n = Agent.get_and_update(fx.counter, &{&1 + 1, &1 + 1})
    ref = "host/#{tenant}/#{purpose}/#{n}"
    {:ok, cfg} = AiEmbedding.configure(embedding(fx) ++ [tenant: tenant, sink: Sink.to_pid(self())])
    deadline = System.os_time(:millisecond) + cfg.receive_timeout_ms + 10_000

    declaration = %{
      "capability_id" => "integration/ai-embedding",
      "operation" => "embed",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => ref,
        "schema_id" => "elzoo/ai-embedding-request",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "wave7-host", "port_id" => "embed"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => deadline,
        "payload" => Request.canonical(%{"version" => 1, "model" => @model, "inputs" => texts})
      }
    }

    {:ok, a} = AiEmbedding.admission(cfg, declaration)
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, owner} =
      EffectIntent.start_link(
        binding: cfg.binding,
        identity: a.identity,
        arguments: a.arguments,
        deadline: a.deadline,
        clock: fx.intent.clock,
        store: fx.intent.store,
        host: fx.intent.host,
        task_supervisor: sup,
        adapter_context: cfg
      )

    {:ok, :dispatched} = EffectIntent.advance(owner, :dispatch)
    key = a.key

    outcome =
      receive do
        {AiEmbedding, ^key, {:outcome, _, outcome}} -> outcome
      after
        30_000 -> flunk("the host embedding call #{ref} gave no outcome")
      end

    for task <- Task.Supervisor.children(sup) do
      mref = Process.monitor(task)
      receive do: ({:DOWN, ^mref, :process, _, _} -> :ok), after: (5_000 -> :ok)
    end

    GenServer.stop(owner)
    Supervisor.stop(sup)
    {ref, meter_host!(fx, tenant, ref, outcome), outcome}
  end

  @doc "The joined query item of a completed one-input call."
  def item({:completed, %{embeddings: [%{index: 0, vector: v}]} = body}),
    do: %{index: 0, vector: v, descriptor: body.descriptor, provenance: body.provenance}

  # ------------------------------------------------------------ metering (host code)

  @doc """
  The host's mapping of an attempt outcome: `{amount, source}`, or `:none` when the call was not
  sent. A completed attempt records the reported amount; any attempt that may have been processed
  and paid (throttled, unknown, completed_lost, any other refusal) is unknown.
  """
  def metered(:completed, usage), do: reported(usage)
  def metered({:completed, %{usage: usage}}, _), do: reported(usage)
  def metered(:not_dispatched, _), do: :none
  def metered({:refused, :credentials_unavailable}, _), do: :none
  def metered({:refused, :credentials_unavailable, _}, _), do: :none
  def metered(:pending, _), do: :pending
  def metered(_, _), do: {:unknown, :unknown}

  defp reported(usage) do
    case Elzoo.AiModel.Usage.amount(usage, :input_uncached_tokens) do
      n when is_integer(n) -> {n, :provider_reported}
      _ -> {:unknown, :unknown}
    end
  end

  # A fixed time derived from the reference, so a repeated record has equal bytes.
  defp observed_at(ref) do
    <<n::32, _::binary>> = :crypto.hash(:sha256, ref)
    @now + rem(n, 1_000_000)
  end

  defp observe(fx, tenant, ref, run_id, operation_id, {amount, source}) do
    Metering.record(fx.meter, tenant, %{
      usage_id: ref <> "/input_uncached_tokens",
      run_id: run_id,
      operation_id: operation_id,
      attempt_id: ref,
      provider_id: "topic",
      model_id: @model,
      unit: :input_uncached_tokens,
      amount: amount,
      source: source,
      period: @period,
      observed_at_ms: observed_at(ref)
    })
  end

  defp meter_host!(fx, tenant, ref, outcome) do
    case metered(outcome, nil) do
      :none -> :none
      m -> observe(fx, tenant, ref, ref, ref, m)
    end
  end

  @doc """
  The host pages `attempts/3` of an ingest and records one observation per settled attempt:
  `[{ref, outcome, result}]`.
  """
  def meter_ingest!(fx, tenant, r) do
    for a <- attempts(fx, tenant, r) do
      [id | _] = String.split(a.ref, "/")

      result =
        case metered(a.outcome, a.usage) do
          :none -> :none
          :pending -> :pending
          m -> observe(fx, tenant, a.ref, id, "#{id}/#{a.batch}", m)
        end

      {a.ref, a.outcome, result}
    end
  end

  def totals(fx, tenant) do
    {:ok, rows} = Metering.totals(fx.meter, tenant, %{period: @period, max_rows: 100})
    Enum.map(rows, &{&1.unit, &1.source, &1.known, &1.unknown_count, &1.count})
  end

  # ------------------------------------------------------------ retrieval (host code)

  @doc "query/2 with a host embedding of `text`, and query_text/2 of `text`, same request keys."
  def retrieve!(fx, tenant, principal, text, sources, opts \\ []) do
    {_, _, outcome} = embed!(fx, tenant, "query", [text])

    base = %{
      tenant: tenant,
      k: 20,
      allowed_sources: sources,
      principal: principal,
      checked_at: @now
    }

    {:ok, vector} =
      SearchData.query(fx.search.knowledge, Map.put(base, :query_embedding, item(outcome)))

    lexical =
      SearchData.query_text(
        fx.search.knowledge,
        Map.put(base, :text, Keyword.get(opts, :lexical, text))
      )

    {vector, lexical}
  end

  @doc """
  Reciprocal-rank fusion (Q3 A): each candidate's priority is the sum, over the lists that hold
  its `item_id`, of `div(1_000_000, 60 + rank)` with ranks from 1. Candidates in first-seen
  order (vector list first).
  """
  def fuse(lists) do
    ranked =
      for list <- lists, do: Map.new(Enum.with_index(list, 1), fn {c, r} -> {c.item_id, r} end)

    lists
    |> List.flatten()
    |> Enum.uniq_by(& &1.item_id)
    |> Enum.map(fn c ->
      priority =
        ranked
        |> Enum.flat_map(&List.wrap(Map.get(&1, c.item_id)))
        |> Enum.map(&div(1_000_000, 60 + &1))
        |> Enum.sum()

      {c, priority}
    end)
  end

  def window,
    do: %{
      provider_id: "scripted",
      model_id: "model-a",
      size: 1_000_000,
      unit: :bytes,
      estimator_id: "bytes",
      estimator_version: 1
    }

  @doc """
  context-selection over `{candidate, priority}` pairs. `checks` gives the host's current reading
  of each candidate: `fn candidate -> :allowed | :denied end`.
  """
  def select(tenant, principal, pairs, checks, policy \\ %{}) do
    candidates =
      for {c, priority} <- pairs do
        c
        |> Map.take([:item_id, :version, :source, :content, :content_hash, :derived_from, :access])
        |> Map.merge(%{estimate: byte_size(c.content), priority: priority})
        |> then(
          &if(Map.has_key?(c, :updated_at), do: Map.put(&1, :updated_at, c.updated_at), else: &1)
        )
      end

    nodes =
      for c <- candidates do
        node = Map.take(c, [:item_id, :version, :source, :content_hash, :derived_from])

        check =
          c
          |> Map.take([:item_id, :version, :source, :content_hash])
          |> Map.merge(%{
            tenant: tenant,
            principal: principal,
            checked_at: @now,
            result: checks.(c)
          })

        Map.merge(node, %{tenant: tenant, check: check})
      end

    context = %{
      principal: principal,
      tenant: tenant,
      now: @now,
      snapshot_at: @now,
      window: window(),
      windows: [window()],
      reservations: [],
      policy:
        Map.merge(
          %{
            max_age: 60_000,
            allow_derived: false,
            priority: :descending,
            recency: :input,
            max_selected_count: 16,
            max_selected_bytes: 1_000_000
          },
          policy
        ),
      provenance: nodes
    }

    {:ok, result} = Elzoo.ContextSelection.select(%{candidates: candidates}, context)
    result
  end

  # ------------------------------------------------------------ prompts and Runs

  def marked(content, sources, trust, max_bytes \\ 8_192) do
    {:ok, m} =
      UntrustedContent.decode(%{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => sources,
        "trust" => trust,
        "max_bytes" => max_bytes,
        "content" => content
      })

    m
  end

  defp estimate(bytes),
    do:
      {:ok,
       %{
         size: byte_size(bytes),
         unit: :tokens,
         direction: :upper_bound,
         estimator_id: "bytes",
         estimator_version: 1
       }}

  @doc "PromptAssembly.build/2 with the host's instructions, one token per byte."
  def prompt!(memory, history) do
    {:ok, %{request: request}} =
      Elzoo.PromptAssembly.build(
        %{
          model: "model-a",
          max_output_tokens: 1_024,
          role_instructions: ["You are the support assistant. Answer from the given content."],
          skill_instructions: [],
          memory: memory,
          history: history,
          tools: [],
          window: %{window() | unit: :tokens},
          max_request_bytes: 65_536,
          max_image_refs: 0
        },
        &estimate/1
      )

    request
  end

  defp schema_entry(id) do
    schema = %{"type" => "object"}
    port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
    {:ok, compiled} = PayloadSchema.build(port, schema)

    {{id, 1},
     %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, Jason.encode!(schema))}}
  end

  @doc """
  A RunEngine Run of the root pattern `Elzoo.TypedDecision` (a pure step the engine drives) on an
  output Port of `{schema_id, 1}`, its Stores on the application Repo. The scripted model answers
  the one `model_call` with `model.(payload)`, an `elzoo.ai-text.result` value. Returns the Run's
  key, the model_call payload, the finish payload and the transcript entries.
  """
  def decision_run!(tenant, schema_id, request, answer, model) do
    role = app_role!()
    c = TestHelper.fixture(store_repo: AppRepo, grant: &grant_store!(&1, role), tenant: tenant)
    engine_on_app!(c, role)
    id = "decide"

    {:ok, state} =
      TypedDecision.new(%{
        id: id,
        request: request,
        port: %{
          "id" => "answer",
          "direction" => "output",
          "schema_id" => schema_id,
          "schema_version" => 1
        },
        answer: answer,
        repairs: 0
      })

    # The model call's Effect intent identity names the Run's tenant (as ELZ-323's in_unit/2).
    base = c.opts[:bindings]["model_call"]

    model_binding = %{
      base
      | result: {"elzoo.ai-text.result", 1},
        facts: fn a -> update_in(base.facts.(a), [:intent, :identity], &[tenant | tl(&1)]) end
    }

    engine =
      TestHelper.start(c,
        pattern: {TypedDecision, :step, state},
        schemas: Map.merge(c.opts[:schemas], Map.new(@extra_schemas, &schema_entry/1)),
        bindings: Map.put(c.opts[:bindings], "model_call", model_binding),
        result_reader: %{evidence_store: c.evidence_store, retention_count: 1_024}
      )

    assert {:ok, :applied} = TestHelper.send_input(engine)
    assert_receive {:effect_started, task, dispatched}, 10_000
    payload = Jason.decode!(dispatched.arguments)
    value = model.(payload)
    send(task, {:result, %{}})
    call = id <> ":call:0"

    view =
      TestHelper.wait_for(engine, fn v ->
        Enum.any?(v.slots, fn {_, s} -> s.action_id == call end)
      end)

    {occurrence, _} = Enum.find(view.slots, fn {_, s} -> s.action_id == call end)

    outcome = %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "action_id" => call,
      "outcome" => "completed",
      "schema_id" => "elzoo.ai-text.result",
      "schema_version" => 1,
      "payload" => %{
        "content" => Jason.encode!(value),
        "structured" => %{"valid" => value},
        "finish" => "stop"
      }
    }

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "result-" <> call,
               outcome,
               TestHelper.verified(%{occurrence: occurrence, actual: 0, dispatch: "dispatched"})
             )

    TestHelper.wait_for(engine, &(&1.outcome == :completed))

    {:ok, %{entries: entries}} =
      RunEngine.transcript(
        engine,
        %{tenant: tenant, principal: "principal", run_id: "run"},
        %{max_records: 65_536, max_bytes: 536_870_912}
      )

    [finish] = for %{type: :action, kind: "finish"} = e <- entries, do: e.payload

    %{
      key: String.replace(c.prefix, "engine_", "run-"),
      payload: payload,
      finish: finish,
      entries: entries
    }
  end

  @doc """
  The host's display of an answer (harness code): the text with its resolved citations when
  `Citation.check/3` accepts it against the given items, otherwise not shown as cited.
  """
  def display(value, items) do
    case Citation.check(value, items, %{min_citations: 1}) do
      {:ok, %{citations: citations}} -> {:cited, value["text"], citations}
      {:error, reason} -> {:not_cited, reason}
    end
  end
end
