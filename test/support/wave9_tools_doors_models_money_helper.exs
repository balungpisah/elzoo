for file <- [
      "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
      "../../pieces/state/recipe-store/test/support/recipe_store_test_helper.exs",
      "../../pieces/integration/mcp-client/test/support/mcp_client_test_helper.exs"
    ],
    do: Code.require_file(file, __DIR__)

# ELZ-379 harness: the Repos, one consumer migration per Piece install (each Piece in its own
# disposable schema), the shared clock, the scripted payment provider and its host loop, the
# webhook driver with its receiver and resolver double, and the helpers that read tables as the
# application role. Harness code, not a Piece.

# The owner connection (elzoo_test, not a superuser): schemas, installs, grants, catalog reads and
# the unprotected Store tables.
defmodule Elzoo.Wave9.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285) and
# sets the role's lock_timeout and statement_timeout (ledger-checkout's Need).
defmodule Elzoo.Wave9.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# One consumer migration per install, each run by the owner in its own schema.
for {name, installs} <- [
      {Oauth, [Elzoo.OauthClient.Migration]},
      {Hooks, [Elzoo.WebhookOut.Migration]},
      {DeadLetters, [Elzoo.DeadLetterStore.Migration]},
      {Plan, [Elzoo.Plan.Migration]},
      {Invoice, [Elzoo.Invoice.Migration]},
      {Payments, [Elzoo.PaymentLifecycle.Migration]},
      {Checkout, [Elzoo.LedgerCheckout.Migration]},
      {Journal, [Elzoo.Journal.Migration]},
      {Metering, [Elzoo.Metering.Migration]}
    ] do
  defmodule Module.concat(Elzoo.Wave9.Migration, name) do
    @moduledoc false
    use Ecto.Migration
    @installs installs
    def up, do: for(m <- @installs, do: m.install(prefix()))
  end
end

defmodule Elzoo.Wave9.StoreMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
end

defmodule Elzoo.Wave9.ChargeBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :charge, provider_account: "wave9-pay"
end

defmodule Elzoo.Wave9.RefundBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :refund, provider_account: "wave9-pay"
end

defmodule Elzoo.Wave9.Hooks do
  use Elzoo.WebhookOut.Binding, provider_account: "wave9:webhooks", recovery_grace_ms: 1_000
end

defmodule Elzoo.Wave9.Provider do
  @moduledoc """
  The scripted payment provider (Q9 D): each call pops the next scripted answer of its callback
  and is logged. Events are JSON signed with HMAC-SHA-256 over the raw body; `verify_event`
  checks the signature before it parses anything.
  """
  @behaviour Elzoo.PaymentLifecycle.Provider
  @key "wave9-scripted-provider-signing-key"

  def start, do: Agent.start(fn -> %{answers: %{}, calls: []} end, name: __MODULE__)

  def script(callback, answers),
    do: Agent.update(__MODULE__, &put_in(&1, [:answers, callback], answers))

  def calls(callback),
    do: Agent.get(__MODULE__, &for({^callback, r} <- Enum.reverse(&1.calls), do: r))

  @impl true
  def charge(req), do: answer(:charge, req)
  @impl true
  def refund(req), do: answer(:refund, req)
  @impl true
  def poll(req), do: answer(:poll, req)

  defp answer(callback, req) do
    Agent.get_and_update(__MODULE__, fn s ->
      {a, rest} =
        case Map.get(s.answers, callback, []) do
          [a | rest] -> {a, rest}
          [] -> {{:unknown, :transport}, []}
        end

      {a, %{s | answers: Map.put(s.answers, callback, rest), calls: [{callback, req} | s.calls]}}
    end)
  end

  @impl true
  def verify_event(raw, headers) do
    with {_, sig} <- List.keyfind(headers, "x-signature", 0),
         true <- byte_size(sig) == 64 and :crypto.hash_equals(sig, sign(raw)),
         {:ok, %{"id" => id, "op" => op, "state" => s, "units" => u, "ref" => r}} <-
           Jason.decode(raw),
         {:ok, eur} <- Elzoo.Money.parse("EUR"),
         {:ok, amount} <- Elzoo.Money.from_minor_units(eur, u) do
      operation =
        case op do
          ["charge", p] -> {:charge, p}
          ["refund", p, rid] -> {:refund, p, rid}
        end

      {:ok,
       %{
         event_id: id,
         operation: operation,
         state: String.to_existing_atom(s),
         amount: amount,
         provider_ref: r
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp sign(raw), do: :crypto.mac(:hmac, :sha256, @key, raw) |> Base.encode16(case: :lower)

  @doc "A signed EUR event; `sig` replaces the signature (an event that fails `verify_event`)."
  def event(id, op, state, units, ref, sig \\ nil) do
    raw =
      Jason.encode!(%{
        "id" => id,
        "op" => Tuple.to_list(op) |> Enum.map(&to_string/1),
        "state" => Atom.to_string(state),
        "units" => units,
        "ref" => ref
      })

    %{raw_body: raw, headers: [{"x-signature", sig || sign(raw)}]}
  end
end

defmodule Elzoo.Wave9.Helper do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL

  alias Elzoo.{
    DeadLetterStore,
    EgressPolicy,
    Invoice,
    Journal,
    LedgerCheckout,
    Metering,
    Money,
    PaymentLifecycle,
    Plan,
    RetryTimeout,
    TenantIsolation,
    WebhookOut
  }

  alias Elzoo.DurableLog.{Postgres, PostgresHarness}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.Wave9.{AppRepo, OwnerRepo, Provider}

  # Session settings of the application Repo (task, "Session settings"). The bound of one
  # access_token/3 caller: pool queue wait (queue_target + queue_interval) + the row-lock wait
  # (one exchange of another caller) + exchange_timeout_ms + the time of its Needs.
  @exchange_ms 5_000
  @needs_ms 1_000
  @queue_target_ms 1_000
  @queue_interval_ms 1_000
  @bound_ms @queue_target_ms + @queue_interval_ms + (@exchange_ms + @needs_ms) + @exchange_ms +
              @needs_ms
  @lock_timeout_ms 20_000
  @statement_timeout_ms 20_000
  @repo_timeout_ms 30_000

  def exchange_ms, do: @exchange_ms

  def session_settings,
    do: %{
      bound_ms: @bound_ms,
      exchange_timeout_ms: @exchange_ms,
      needs_ms: @needs_ms,
      queue_target_ms: @queue_target_ms,
      queue_interval_ms: @queue_interval_ms,
      lock_timeout_ms: @lock_timeout_ms,
      statement_timeout_ms: @statement_timeout_ms,
      repo_timeout_ms: @repo_timeout_ms
    }

  @t0 1_801_000_000_000
  def t0, do: @t0

  # ------------------------------------------------------------ connections (from ELZ-349)

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

  @doc false
  def after_connect(conn, role) do
    for sql <- [
          ~s(SET ROLE "#{role}"),
          "SET lock_timeout = #{@lock_timeout_ms}",
          "SET statement_timeout = #{@statement_timeout_ms}"
        ],
        do: Postgrex.query!(conn, sql, [])
  end

  def start_repos! do
    url = PostgresHarness.database_url!()
    role = app_role!()
    base = [url: url, log: false]

    for {repo, extra} <- [
          {OwnerRepo, [pool_size: 4]},
          {AppRepo,
           [
             pool_size: 24,
             timeout: @repo_timeout_ms,
             queue_target: @queue_target_ms,
             queue_interval: @queue_interval_ms,
             after_connect: {__MODULE__, :after_connect, [role]}
           ]}
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
  LOGIN, INHERIT, CREATEROLE, CREATEDB, whether it is a member of the session role (direct or
  indirect, with or without INHERIT), and its lock_timeout and statement_timeout.
  """
  def role_facts(repo) do
    [[current, session, super, bypass, login, inherit, createrole, createdb, member, lock, stmt]] =
      q!(
        repo,
        "SELECT current_user::text, session_user::text, r.rolsuper, r.rolbypassrls, r.rolcanlogin, r.rolinherit, r.rolcreaterole, r.rolcreatedb, pg_has_role(current_user, session_user, 'MEMBER'), current_setting('lock_timeout'), current_setting('statement_timeout') FROM pg_roles r WHERE r.rolname = current_user"
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
      member_of_owner: member,
      lock_timeout: lock,
      statement_timeout: stmt
    }
  end

  @doc """
  Fails, never skips: the application connection must be `elzoo_app`, not the session role,
  NOSUPERUSER, NOBYPASSRLS, NOLOGIN, NOINHERIT, NOCREATEROLE, NOCREATEDB and not a member of
  the session role.
  """
  def role_guard!(role) do
    facts = role_facts(AppRepo)

    if role != "elzoo_app" or facts.current != role or facts.current == facts.session or
         facts.super or facts.bypass or facts.login or facts.inherit or facts.createrole or
         facts.createdb or facts.member_of_owner,
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

  @doc """
  The application role's privileges on the four Store tables of schema `s` (ELZ-323's
  `grant_store!/2`, copied): `USAGE`, `SELECT, INSERT, UPDATE` on heads and outbox and
  `SELECT, INSERT` on records and checkpoints. No `DELETE` and no `TRUNCATE`.
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

  def store_grants(s),
    do: %{
      "schema #{s}" => "USAGE",
      "#{s}.elzoo_log_heads" => "INSERT,SELECT,UPDATE",
      "#{s}.elzoo_outbox" => "INSERT,SELECT,UPDATE",
      "#{s}.elzoo_log_records" => "INSERT,SELECT",
      "#{s}.elzoo_checkpoints" => "INSERT,SELECT"
    }

  @doc """
  Every Store of one engine (Unit, Run, host, evidence and each Effect intent `store` and `host`
  store) is a `Postgres` Store on the application Repo (as ELZ-349's `engine_on_app!/2`).
  """
  def engine_on_app!(opts, role) do
    intents = for {_, o} <- opts[:effect_intent], do: [o[:store], elem(o[:host], 1).store]
    run_store = :sys.get_state(opts[:run_owner]).store

    stores =
      [opts[:store], run_store, opts[:result_reader].evidence_store] ++ List.flatten(intents)

    for store <- Enum.uniq(stores), do: store_on_app!(store, role)
    length(Enum.uniq(stores))
  end

  def store_on_app!(store, role) do
    assert {Postgres, %{repo: repo}} = store
    assert repo == AppRepo

    assert %{
             current: ^role,
             super: false,
             bypass: false,
             login: false,
             inherit: false,
             createrole: false,
             createdb: false,
             member_of_owner: false
           } = facts = role_facts(repo)

    assert facts.current != facts.session
  end

  @doc """
  The role's explicit privileges on every relation, schema and column of the test schemas, as
  the owner reads them from the ACLs, and whether the role owns any relation there.
  """
  def grants(schemas, role) do
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
          UNION ALL
          SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC ' ELSE '' END || 'function ' || n.nspname || '.' || p.proname,
                 a.privilege_type, a.grantee
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE n.nspname = ANY($1)
        )
        SELECT k, string_agg(p, ',' ORDER BY p) FROM g
        WHERE grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = $2))
        GROUP BY 1 ORDER BY 1
        """,
        [schemas, role]
      )

    [[owns]] =
      owner!(
        """
        SELECT coalesce(bool_or(pg_get_userbyid(c.relowner) = $2), false)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ANY($1)
        """,
        [schemas, role]
      )

    {Map.new(rows, fn [rel, privs] -> {rel, privs} end), owns}
  end

  @doc """
  The PUBLIC defaults that the floor needs (oauth-client's README): `EXECUTE` on each tenant
  reader function of the schemas, held by default (no explicit ACL), and `TEMP` on the database.
  """
  def public_defaults(schemas, role) do
    functions =
      owner!(
        """
        SELECT n.nspname || '.' || p.proname, p.proacl IS NULL,
               has_function_privilege($2, p.oid, 'EXECUTE')
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY($1) ORDER BY 1
        """,
        [schemas, role]
      )

    [[temp]] = owner!("SELECT has_database_privilege($1, current_database(), 'TEMP')", [role])
    %{functions: functions, temp: temp}
  end

  @doc "As the owner: the role holds no DELETE or TRUNCATE on any table of the schemas but `except`."
  def deletes(schemas, role) do
    owner!(
      """
      SELECT n.nspname || '.' || c.relname, has_table_privilege($2, c.oid, 'DELETE'),
             has_table_privilege($2, c.oid, 'TRUNCATE')
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY($1) AND c.relkind IN ('r', 'p') ORDER BY 1
      """,
      [schemas, role]
    )
  end

  def hex(n), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp drop!(schemas), do: for(s <- schemas, do: owner!("DROP SCHEMA IF EXISTS #{s} CASCADE"))

  # ------------------------------------------------------------ fixture: installs and grants

  @pieces [
    oauth: Elzoo.Wave9.Migration.Oauth,
    hooks: Elzoo.Wave9.Migration.Hooks,
    dead_letters: Elzoo.Wave9.Migration.DeadLetters,
    plan: Elzoo.Wave9.Migration.Plan,
    invoice: Elzoo.Wave9.Migration.Invoice,
    payments: Elzoo.Wave9.Migration.Payments,
    checkout: Elzoo.Wave9.Migration.Checkout,
    journal: Elzoo.Wave9.Migration.Journal,
    metering: Elzoo.Wave9.Migration.Metering
  ]

  @doc """
  The README grants of each Piece schema, as the owner gives them (the expected map of
  `grants/2` is `readme_grants/1`).
  """
  def readme_grants(p) do
    s = fn k -> p[k] end

    %{
      "schema #{s.(:oauth)}" => "USAGE",
      "#{s.(:oauth)}.elzoo_oauth_connections" => "INSERT,SELECT,UPDATE",
      "#{s.(:oauth)}.elzoo_oauth_attempts" => "INSERT,SELECT,UPDATE",
      "schema #{s.(:hooks)}" => "USAGE",
      "#{s.(:hooks)}.elzoo_webhook_endpoints" => "INSERT,SELECT",
      "#{s.(:hooks)}.elzoo_webhook_events" => "INSERT,SELECT",
      "#{s.(:hooks)}.elzoo_webhook_deliveries" => "INSERT,SELECT,UPDATE",
      "#{s.(:hooks)}.elzoo_webhook_observations" => "INSERT,SELECT,UPDATE",
      "schema #{s.(:dead_letters)}" => "USAGE",
      "#{s.(:dead_letters)}.elzoo_dead_letters" => "DELETE,INSERT,SELECT,UPDATE",
      "schema #{s.(:plan)}" => "USAGE",
      "#{s.(:plan)}.elzoo_plan_subscriptions" => "INSERT,SELECT,UPDATE",
      "schema #{s.(:invoice)}" => "USAGE",
      "#{s.(:invoice)}.elzoo_invoices" => "INSERT,SELECT,UPDATE",
      "#{s.(:invoice)}.elzoo_invoice_lines" => "INSERT,SELECT,UPDATE",
      "#{s.(:invoice)}.elzoo_invoice_applications" => "INSERT,SELECT,UPDATE",
      "#{s.(:invoice)}.elzoo_invoice_reversals" => "INSERT,SELECT,UPDATE",
      "#{s.(:invoice)}.elzoo_invoice_series" => "INSERT,SELECT,UPDATE",
      "schema #{s.(:payments)}" => "USAGE",
      "#{s.(:payments)}.elzoo_payment_payments" => "INSERT,SELECT,UPDATE",
      "#{s.(:payments)}.elzoo_payment_refunds" => "INSERT,SELECT,UPDATE",
      "#{s.(:payments)}.elzoo_payment_observations" => "INSERT,SELECT,UPDATE",
      "#{s.(:payments)}.elzoo_payment_events" => "INSERT,SELECT",
      "schema #{s.(:checkout)}" => "USAGE",
      "#{s.(:checkout)}.elzoo_checkout_checkouts" => "INSERT,SELECT,UPDATE",
      "#{s.(:checkout)}.elzoo_checkout_steps" => "INSERT,SELECT,UPDATE",
      "schema #{s.(:journal)}" => "USAGE",
      "#{s.(:journal)}.elzoo_journal_operations" => "INSERT,SELECT",
      "#{s.(:journal)}.elzoo_journal_postings" => "INSERT,SELECT",
      "#{s.(:journal)}.elzoo_journal_accounts" => "INSERT,SELECT,UPDATE",
      "schema #{s.(:metering)}" => "USAGE",
      "#{s.(:metering)}.elzoo_metering_corrections" => "INSERT,SELECT",
      "#{s.(:metering)}.elzoo_metering_observations" => "INSERT,SELECT,UPDATE"
    }
  end

  defp grant_sql(p, role) do
    s = fn k -> p[k] end

    [
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:oauth)}.elzoo_oauth_connections, #{s.(:oauth)}.elzoo_oauth_attempts TO #{role}",
      "GRANT SELECT, INSERT ON #{s.(:hooks)}.elzoo_webhook_endpoints, #{s.(:hooks)}.elzoo_webhook_events TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:hooks)}.elzoo_webhook_deliveries, #{s.(:hooks)}.elzoo_webhook_observations TO #{role}",
      "GRANT SELECT, INSERT, UPDATE, DELETE ON #{s.(:dead_letters)}.elzoo_dead_letters TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:plan)}.elzoo_plan_subscriptions TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:invoice)}.elzoo_invoices, #{s.(:invoice)}.elzoo_invoice_lines, #{s.(:invoice)}.elzoo_invoice_applications, #{s.(:invoice)}.elzoo_invoice_reversals, #{s.(:invoice)}.elzoo_invoice_series TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:payments)}.elzoo_payment_payments, #{s.(:payments)}.elzoo_payment_refunds, #{s.(:payments)}.elzoo_payment_observations TO #{role}",
      "GRANT SELECT, INSERT ON #{s.(:payments)}.elzoo_payment_events TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:checkout)}.elzoo_checkout_checkouts, #{s.(:checkout)}.elzoo_checkout_steps TO #{role}",
      "GRANT SELECT, INSERT ON #{s.(:journal)}.elzoo_journal_operations, #{s.(:journal)}.elzoo_journal_postings TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:journal)}.elzoo_journal_accounts TO #{role}",
      "GRANT SELECT, INSERT ON #{s.(:metering)}.elzoo_metering_corrections TO #{role}",
      "GRANT SELECT, INSERT, UPDATE ON #{s.(:metering)}.elzoo_metering_observations TO #{role}"
    ] ++ for({k, _} <- @pieces, do: "GRANT USAGE ON SCHEMA #{s.(k)} TO #{role}")
  end

  @doc """
  The protected tables that this task adds (group 5), by Piece schema key, and the three
  insert-only ones.
  """
  def new_tables,
    do: [
      oauth: ~w(elzoo_oauth_connections elzoo_oauth_attempts),
      hooks:
        ~w(elzoo_webhook_endpoints elzoo_webhook_events elzoo_webhook_deliveries elzoo_webhook_observations),
      plan: ~w(elzoo_plan_subscriptions),
      invoice:
        ~w(elzoo_invoices elzoo_invoice_lines elzoo_invoice_applications elzoo_invoice_reversals elzoo_invoice_series),
      payments:
        ~w(elzoo_payment_payments elzoo_payment_refunds elzoo_payment_events elzoo_payment_observations),
      checkout: ~w(elzoo_checkout_checkouts elzoo_checkout_steps)
    ]

  def insert_only, do: ~w(elzoo_webhook_endpoints elzoo_webhook_events elzoo_payment_events)

  @doc """
  The disposable world of one test: one schema per Piece install, the Effect-intent Store schema,
  the shared clock and the Piece bindings of groups 2 (events out) and 4 (money), all on the
  application Repo.
  """
  def fixture!(role) do
    base = "wave9_" <> hex(5)
    p = Map.new(@pieces, fn {k, _} -> {k, base <> "_" <> Atom.to_string(k)} end)
    intents = base <> "_intents"
    schemas = Map.values(p) ++ [intents]
    for s <- schemas, do: owner!("CREATE SCHEMA #{s}")
    ExUnit.Callbacks.on_exit(fn -> drop!(schemas) end)

    for {k, migration} <- @pieces,
        do: :ok = Ecto.Migrator.up(OwnerRepo, 1, migration, prefix: p[k], log: false)

    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave9.StoreMigration, prefix: intents, log: false)
    for sql <- grant_sql(p, role), do: owner!(sql)
    :ok = grant_store!(intents, role)

    {:ok, clock} = Agent.start(fn -> @t0 end)
    {:ok, env} = Agent.start(fn -> %{} end)
    {:ok, tasks} = Task.Supervisor.start_link()
    Process.unlink(tasks)
    {:ok, intent_pids} = Agent.start(fn -> [] end)
    now = fn -> Agent.get(clock, & &1) end

    {:ok, lc} =
      PaymentLifecycle.new(
        repo: AppRepo,
        prefix: p.payments,
        provider: Provider,
        provider_account: "wave9-pay",
        deadline_ms: 600_000,
        clock: now
      )

    {:ok, inv} = Invoice.new(repo: AppRepo, prefix: p.invoice)
    journal = Journal.new(repo: AppRepo, prefix: p.journal)
    {:ok, plan} = Plan.new(repo: AppRepo, prefix: p.plan)
    meter = Metering.new(repo: AppRepo, prefix: p.metering)

    {:ok, checkout} =
      LedgerCheckout.new(
        repo: AppRepo,
        prefix: p.checkout,
        payments: lc,
        invoices: inv,
        journal: journal
      )

    dead_letters = DeadLetterStore.new(repo: AppRepo, prefix: p.dead_letters)

    w = %{
      base: base,
      p: p,
      intents_prefix: intents,
      role: role,
      clock: clock,
      env: env,
      tasks: tasks,
      intent_pids: intent_pids,
      lc: lc,
      inv: inv,
      journal: journal,
      plan: plan,
      meter: meter,
      checkout: checkout,
      dead_letters: dead_letters
    }

    w = Map.put(w, :hooks, hooks!(w))

    # Before the first call of each test, as elzoo_app, each Piece's verify/1 of this test's own
    # schemas (oauth-client's runs when its binding is built, in Tools.oauth!/1).
    for verified <- [
          PaymentLifecycle.verify(lc),
          Invoice.verify(inv),
          Plan.verify(plan),
          Elzoo.WebhookOut.verify(w.hooks.binding)
        ],
        do: assert(verified == :ok)

    ExUnit.Callbacks.on_exit(fn ->
      for pid <- Agent.get(intent_pids, & &1), do: stop(pid)
      stop(tasks)
      for a <- [clock, env, intent_pids], do: Agent.stop(a)
    end)

    w
  end

  def now(w), do: Agent.get(w.clock, & &1)
  def clock(w, ms), do: Agent.update(w.clock, fn _ -> ms end)
  def tick(w, ms), do: Agent.update(w.clock, &(&1 + ms))
  def env(w, key), do: Agent.get(w.env, &Map.get(&1, key))
  def env(w, key, value), do: Agent.update(w.env, &Map.put(&1, key, value))
  def env_update(w, key, default, fun), do: Agent.update(w.env, &Map.update(&1, key, default, fun))

  # ------------------------------------------------------------ Effect intents (Postgres)

  @doc """
  A new Effect-intent owner of one admission, its intent and host Stores `Postgres` Stores on the
  application Repo in the intents schema.
  """
  def owner!(w, binding, admission, context) do
    store =
      Postgres.store(AppRepo,
        prefix: w.intents_prefix,
        fold: Intent.fold(binding),
        limits: Intent.limits()
      )

    host =
      Postgres.store(AppRepo,
        prefix: w.intents_prefix,
        fold: StoreHost.fold(),
        limits: StoreHost.limits()
      )

    store_on_app!(store, w.role)

    {:ok, pid} =
      Intent.start_link(
        binding: binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> now(w) end,
        store: store,
        host: {StoreHost, %{store: host, authorize: fn _, _ -> :fresh end}},
        task_supervisor: w.tasks,
        adapter_context: context
      )

    Process.unlink(pid)
    Agent.update(w.intent_pids, &[pid | &1])
    pid
  end

  def settled(pid, tries \\ 500) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(10) && settled(pid, tries - 1)
    end
  end

  def advance(pid, command) do
    result = Intent.advance(pid, command)
    {result, settled(pid)}
  end

  # ------------------------------------------------------------ group 4: money

  def eur_currency do
    {:ok, c} = Money.parse("EUR")
    c
  end

  def eur(units) do
    {:ok, a} = Money.from_minor_units(eur_currency(), units)
    a
  end

  @doc "The journal accounts of a tenant: cash, receivable, revenue, float, and the wallet."
  def accounts!(w, tenant) do
    for {account, negative} <- [
          {"cash", true},
          {"receivable", true},
          {"revenue", true},
          {"float", true},
          {"wallet", false}
        ],
        do:
          {:ok, :applied} =
            Journal.open_account(w.journal, tenant, %{
              account_id: account,
              currency: eur_currency(),
              allow_negative: negative
            })

    :ok
  end

  def balance(w, tenant, account) do
    {:ok, amount} = Journal.balance(w.journal, tenant, account)
    amount.minor_units
  end

  @doc """
  The host's charge or refund intent of an admission: start its owner (Postgres Stores), dispatch
  it with one scripted answer and call `record/3`. Returns the owner and the operation's state.
  """
  def pay_intent!(w, tenant, binding, admission, operation, callback, answer) do
    Provider.script(callback, [answer])
    pid = owner!(w, binding, admission, w.lc)
    {{:ok, _}, _} = advance(pid, :dispatch)

    {:ok, %{state: state}} =
      PaymentLifecycle.record(w.lc, tenant, %{operation: operation, attempt: 1, fallback: nil})

    {pid, state}
  end

  @doc "The host's poll of a charge intent, then `record/3`."
  def poll!(w, tenant, pid, operation, answer) do
    Provider.script(:poll, [answer])
    {{:ok, _}, %{attempts: n}} = advance(pid, :poll)

    {:ok, %{state: state}} =
      PaymentLifecycle.record(w.lc, tenant, %{operation: operation, attempt: n, fallback: nil})

    state
  end

  @doc "Fee and usage invoice lines of an invoice in the tenant's series `S`; returns its ID."
  def invoice!(w, tenant, id, lines) do
    {:ok, :applied} =
      Invoice.create(w.inv, tenant, %{
        invoice_id: id,
        billing_account: "acct-" <> tenant,
        currency: eur_currency(),
        series: "S"
      })

    for line <- lines,
        do: {:ok, :applied} = Invoice.add_line(w.inv, tenant, %{invoice_id: id, line: line})

    id
  end

  def finalize!(w, tenant, id) do
    {:ok, result} =
      Invoice.finalize(w.inv, tenant, %{
        invoice_id: id,
        issued_at_ms: now(w),
        due_at_ms: now(w) + 86_400_000
      })

    result
  end

  def invoice(w, tenant, id) do
    {:ok, d} = Invoice.get(w.inv, tenant, %{invoice_id: id})
    d
  end

  @doc "The issue post of a finalized invoice: +total to the receivable, -total to revenue."
  def post_issue(w, tenant, %{operation_id: op, total: total}) do
    {:ok, minus} = Money.negate(total)

    Journal.post(w.journal, tenant, %{
      operation_id: op,
      actor_ref: "svc:billing",
      reason: "invoice issue",
      postings: [
        %{account_id: "receivable", amount: total},
        %{account_id: "revenue", amount: minus}
      ]
    })
  end

  def invoice_payment(id, invoice_id, units, opts \\ []) do
    %{
      checkout_id: id,
      kind: :invoice_payment,
      invoice_id: invoice_id,
      amount: eur(units),
      recipient: "merchant-1",
      approved: %{amount: eur(Keyword.get(opts, :approved, units)), recipient: "merchant-1"},
      approval_ref: "approval-" <> id,
      settle: %{to: Keyword.get(opts, :to, "cash"), from: "receivable"},
      actor_ref: "svc:checkout"
    }
  end

  def top_up(id, units, opts \\ []) do
    %{
      checkout_id: id,
      kind: :top_up,
      amount: eur(units),
      recipient: "merchant-1",
      approved: %{amount: eur(Keyword.get(opts, :approved, units)), recipient: "merchant-1"},
      approval_ref: "approval-" <> id,
      wallet: %{to: "wallet", from: "float"},
      allowance: nil,
      parallel: false,
      actor_ref: "svc:checkout"
    }
  end

  def resume(w, tenant, id), do: LedgerCheckout.resume(w.checkout, tenant, %{checkout_id: id})

  def checkout!(w, tenant, id) do
    {:ok, c} = LedgerCheckout.get(w.checkout, tenant, %{checkout_id: id})
    c
  end

  def step(w, tenant, id, name), do: Enum.find(checkout!(w, tenant, id).steps, &(&1.step == name))

  def payment(w, tenant, payment_id) do
    {:ok, p} = PaymentLifecycle.get(w.lc, tenant, %{payment_id: payment_id})
    p
  end

  @doc "The first resume/3 waits at the charge intent; the host drives it with `answer`."
  def charged!(w, tenant, id, answer) do
    assert {:ok, %{state: :running, wait: %{step: :charge, for: :charge_intent, admission: a}}} =
             resume(w, tenant, id)

    assert List.last(a.identity) == "checkout." <> id <> "/charge"

    pay_intent!(
      w,
      tenant,
      Elzoo.Wave9.ChargeBinding,
      a,
      {:charge, "checkout." <> id},
      :charge,
      answer
    )
  end

  def refund!(w, tenant, id, admission, answer),
    do:
      pay_intent!(
        w,
        tenant,
        Elzoo.Wave9.RefundBinding,
        admission,
        {:refund, "checkout." <> id, "comp/charge"},
        :refund,
        answer
      )

  # ------------------------------------------------------------ group 2: events out

  @public {93, 184, 215, 14}
  @private {10, 0, 0, 7}
  def public_address, do: @public
  def private_address, do: @private
  def hook_host, do: "hooks.example.com"

  @doc """
  The webhook-out binding: the tenant's egress policy (one host, port 443), the resolver double
  (the public address unless the case set another answer), the transport Need that gives the
  local receiver as a `Req.Test` plug, the Secrets Need of the endpoint's `whsec_` secret, the
  shared clock, and a retry policy with `jitter: :none`.
  """
  def hooks!(w) do
    {:ok, retry} =
      RetryTimeout.policy(
        max_attempts: 3,
        base_backoff_ms: 1_000,
        max_backoff_ms: 8_000,
        jitter: :none
      )

    policy = EgressPolicy.policy(hosts: [hook_host()], ports: [443])
    env(w, :hook_secrets, %{})
    env(w, :hook_requests, [])

    plug = fn conn ->
      body = IO.iodata_to_binary(Req.Test.raw_body(conn))
      request = %{path: conn.request_path, headers: conn.req_headers, body: body}
      env_update(w, :hook_requests, [request], &(&1 ++ [request]))
      answers = env(w, {:hook_answers, conn.request_path}) || [200]
      [status | rest] = answers
      env(w, {:hook_answers, conn.request_path}, if(rest == [], do: answers, else: rest))
      Plug.Conn.send_resp(conn, status, "")
    end

    {:ok, b} =
      WebhookOut.new(
        repo: AppRepo,
        prefix: w.p.hooks,
        policy: fn _tenant -> {:ok, policy} end,
        resolver: fn host ->
          {:ok, env(w, {:dns, host}) || [@public]}
        end,
        transport: fn target ->
          env(w, :hook_target, target)
          {:ok, [plug: plug]}
        end,
        secrets: fn %{ref: ref} = request ->
          value = Map.fetch!(env(w, :hook_secrets), ref)

          %{
            grant: request,
            resolver: fn ref, scope ->
              {:ok,
               %{ref: ref, scope: scope, value: value, version: 1, expires_at_unix_ms: @t0 * 2}}
            end,
            clock: fn -> now(w) end
          }
        end,
        clock: fn -> now(w) end,
        retry: retry,
        max_tries: 3,
        send_timeout_ms: 2_000,
        try_deadline_ms: 600_000,
        dead_letters: w.dead_letters,
        effect: %{binding: Elzoo.Wave9.Hooks, provider_account: "wave9:webhooks"}
      )

    Map.put(%{binding: b}, :retry, retry)
  end

  def hook_secret(w, ref) do
    secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
    env_update(w, :hook_secrets, %{ref => secret}, &Map.put(&1, ref, secret))
    secret
  end

  def hook_requests(w), do: env(w, :hook_requests)
  def hook_answers(w, path, statuses), do: env(w, {:hook_answers, path}, statuses)
  def dns(w, answer), do: env(w, {:dns, hook_host()}, answer)

  @doc "The Standard Webhooks check of one request with the endpoint's `whsec_` secret."
  def verify_signature(secret, headers, body) do
    header = fn name -> for({^name, v} <- headers, do: v) |> List.first() end
    id = header.("webhook-id")
    ts = header.("webhook-timestamp")
    "whsec_" <> encoded = secret
    key = Base.decode64!(encoded)
    expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, id <> "." <> ts <> "." <> body))

    header.("webhook-signature")
    |> String.split(" ")
    |> Enum.any?(fn
      "v1," <> sig -> byte_size(sig) == byte_size(expected) and :crypto.hash_equals(sig, expected)
      _ -> false
    end)
  end

  @doc """
  The webhook driver: one worker round of the tenant — claim every due try, start an owner per
  try (rearm when asked), dispatch it, wait for its task, record its result, then file the
  pending dead letters. Returns `[{try, record_result}]`.
  """
  def hook_round!(w, tenant) do
    b = w.hooks.binding
    {:ok, tries} = WebhookOut.claim_due(b, tenant, %{limit: 64, lease_ms: 1_000})

    results =
      for t <- tries do
        # The live owner of this key, else a new one (a restarted owner is read-only).
        pid =
          case env(w, {:hook_owner, t.admission.key}) do
            pid when is_pid(pid) ->
              pid

            nil ->
              pid = owner!(w, Elzoo.Wave9.Hooks, t.admission, b)
              env(w, {:hook_owner, t.admission.key}, pid)
              pid
          end

        if t.rearm, do: assert({:ok, _} = Intent.advance(pid, :rearm))
        {_, %{attempts: n}} = advance(pid, :dispatch)

        {t,
         WebhookOut.record(b, tenant, %{
           delivery_id: t.delivery_id,
           try: t.try,
           attempt: max(n, 1),
           fallback: nil
         })}
      end

    {:ok, _} = WebhookOut.file_dead_letters(b, tenant, %{limit: 64})
    results
  end

  def hook_status(w, tenant, delivery_id) do
    {:ok, s} = WebhookOut.status(w.hooks.binding, tenant, %{delivery_id: delivery_id})
    s
  end

  def delivery_id(endpoint_id, event_id),
    do: sha256(Jason.encode!(%{"endpoint_id" => endpoint_id, "event_id" => event_id}))

  def dead_letters(w, tenant) do
    {:ok, %{entries: entries}} =
      DeadLetterStore.list(w.dead_letters, tenant, %{source: "webhook-out", after: nil, limit: 100})

    entries
  end

  def endpoint(w, id, events, dedup) do
    hook_secret(w, "key-" <> id)

    %{
      endpoint_id: id,
      url: "https://#{hook_host()}/hooks/#{id}",
      secret_ref: %{ref: "key-" <> id, scope: "hooks"},
      events: events,
      dedup: dedup
    }
  end
end

# ------------------------------------------------------------------ engines and the scripted host

defmodule Elzoo.Wave9.Lock do
  @moduledoc "One lock per tenant, re-entrant for its holder: one Run-owner command at a time."
  use GenServer

  def start, do: GenServer.start(__MODULE__, nil)

  def run(lock, fun) do
    :ok = GenServer.call(lock, :acquire, :infinity)

    try do
      fun.()
    after
      :ok = GenServer.call(lock, :release, :infinity)
    end
  end

  @impl true
  def init(_), do: {:ok, %{owner: nil, count: 0, queue: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _} = from, s) do
    cond do
      s.owner == nil -> {:reply, :ok, %{s | owner: pid, count: 1}}
      s.owner == pid -> {:reply, :ok, %{s | count: s.count + 1}}
      true -> {:noreply, %{s | queue: :queue.in(from, s.queue)}}
    end
  end

  def handle_call(:release, _, %{count: count} = s) when count > 1,
    do: {:reply, :ok, %{s | count: count - 1}}

  def handle_call(:release, _, s) do
    case :queue.out(s.queue) do
      {{:value, {pid, _} = next}, queue} ->
        GenServer.reply(next, :ok)
        {:reply, :ok, %{s | owner: pid, count: 1, queue: queue}}

      {:empty, _} ->
        {:reply, :ok, %{s | owner: nil, count: 0}}
    end
  end
end

defmodule Elzoo.Wave9.Host do
  @moduledoc """
  The scripted host: the adapter context of every engine Effect (the run-engine TestBinding).
  Each Effect runs in its own process, so two Runs' tool calls run at once; the bindings are in
  `Elzoo.Wave9.Bots`. Every outcome reaches its engine through `input/4`, as an Adapter sink does.
  """
  use GenServer

  def start(w), do: GenServer.start(__MODULE__, w)

  @impl true
  def init(w), do: {:ok, w}

  @impl true
  def handle_info({:effect_started, task, request}, w) do
    Task.start(fn ->
      try do
        Elzoo.Wave9.Bots.effect(w, task, Jason.decode!(request.arguments))
      rescue
        e ->
          Elzoo.Wave9.Helper.env_update(
            w,
            :errors,
            [],
            &(&1 ++ [Exception.format(:error, e, __STACKTRACE__)])
          )
      end
    end)

    {:noreply, w}
  end

  def handle_info(_, w), do: {:noreply, w}
end

defmodule Elzoo.Wave9.Agent do
  @moduledoc "The root callable of a bot Run: the agent loop with the host's estimate."
  def step(state, input), do: Elzoo.AgentLoop.step(state, input, &estimate/1)

  @doc "The host's estimate: one token per byte, an upper bound."
  def estimate(bytes),
    do:
      {:ok,
       %{
         size: byte_size(bytes),
         unit: :tokens,
         direction: :upper_bound,
         estimator_id: "bytes",
         estimator_version: 1
       }}
end

defmodule Elzoo.Wave9.CodeMode do
  @moduledoc """
  The nested callable of the registry tool `run_code` (harness code): it steps a
  `workflow/lua-tool` state and maps lua-tool's finish (`elzoo.lua-tool.result`) to the
  `elzoo.agent-loop.tool-result` v1 result that agent-loop reads, whose marked content is the
  canonical JSON of that finish.
  """
  def step(%{inner: inner} = state, input) do
    {:Transition, next, out} = Elzoo.LuaTool.step(inner, input)
    {:Transition, %{state | inner: next}, convert(out)}
  end

  defp convert({:some, %{"actions" => actions} = request}),
    do: {:some, %{request | "actions" => Enum.map(actions, &finish/1)}}

  defp convert(out), do: out

  defp finish(%{"kind" => "finish", "schema_id" => "elzoo.lua-tool.result"} = action),
    do: %{
      action
      | "schema_id" => "elzoo.agent-loop.tool-result",
        "payload" => Elzoo.Wave9.Bots.tool_payload(Jason.encode!(action["payload"]), "wave9:code")
    }

  defp finish(action), do: action

  @doc """
  The `local_work` of one sandbox run: lua-tool's string-keyed run payload as the sandbox's
  request, and the sandbox's reply in lua-tool's run-result form.
  """
  def run(executable, %{"source" => source, "input" => input, "policy" => policy} = p) do
    limits = Map.new(p["limits"], fn {k, v} -> {String.to_existing_atom(k), v} end)
    calls = p["calls"]

    request = %{
      source: source,
      input: input,
      policy: policy,
      limits: limits,
      calls: %{
        mode: calls["mode"],
        names: calls["names"],
        recorded:
          for(
            r <- calls["recorded"],
            do: %{name: r["name"], arguments: r["arguments"], result: r["result"]}
          )
      }
    }

    case Elzoo.LuaSandbox.run(executable, request) do
      {:ok, %{value: value, identity: identity, runtime: runtime}} ->
        %{"ok" => %{"value" => value, "identity" => identity, "runtime" => json(runtime)}}

      {:pending_call, %{index: k, name: name, arguments: args}} ->
        %{"pending_call" => %{"index" => k, "name" => name, "arguments" => args}}

      {:refused, reason} ->
        %{"refused" => to_string(reason)}

      {:host_outcome, reason} ->
        %{"host_outcome" => to_string(reason)}
    end
  end

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()
end

defmodule Elzoo.Wave9.Bots do
  @moduledoc """
  The engines of the Wave 9 bots (the run-engine fixture's construction, copied as ELZ-349 does:
  one Run owner per tenant, a Unit directory, every Store on the application Repo, one lock per
  Run owner) and the host bindings that the engines' Effects reach: the scripted model, the MCP
  tool binding, the module tools of code mode, the local `lookup` tool and the routing binding.
  """
  import ExUnit.Assertions
  alias Elzoo.{DynamicUnits, Lease, McpClient, PayloadSchema, RecipeStore, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableLog.{Postgres, Writer}
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.McpClient.RuntimeBinding
  alias Elzoo.RecipeStore.TestHelper, as: RS
  alias Elzoo.Wave9.{AppRepo, Lock, OwnerRepo}
  alias Elzoo.Wave9.Helper, as: H

  @engines Elzoo.Wave9.EngineRegistry
  @units Elzoo.Wave9.UnitRegistry

  # Slot deadlines after admission, by the shared clock (ms). A lua-tool module call has the
  # shortest, below the run_code slot and the Run.
  @model_ms 300_000
  @tool_ms 300_000
  @module_ms 20_000
  @code_ms 200_000
  @run_ms 1_000_000

  def module_ms, do: @module_ms
  def code_ms, do: @code_ms

  def registries! do
    {:ok, engines} = Registry.start_link(keys: :unique, name: @engines)
    {:ok, units} = Registry.start_link(keys: :unique, name: @units)
    for pid <- [engines, units], do: Process.unlink(pid)
    [engines, units]
  end

  @doc """
  The engines of both tenants and the scripted host: one engine schema per tenant with a Run
  owner, a Unit directory, an evidence writer and the Effect intents, and a recipe store (with
  its artifact Store on the application Repo and objects on MinIO) with the bots' published
  version.
  """
  def engines!(w, opts \\ []) do
    rs = w.base <> "_rs"
    H.owner!("CREATE SCHEMA #{rs}")

    ExUnit.Callbacks.on_exit(fn ->
      delete_objects!(rs)
      H.owner!("DROP SCHEMA IF EXISTS #{rs} CASCADE")
    end)

    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave9.StoreMigration, prefix: rs, log: false)
    :ok = H.grant_store!(rs, w.role)
    rs_store = Postgres.store(AppRepo, prefix: rs, fold: RS.fold(), limits: RS.limits())
    H.store_on_app!(rs_store, w.role)
    {:ok, binding} = Elzoo.EffectIntent.Binding.load(Elzoo.RunEngine.TestBinding)
    {:ok, engines} = Agent.start(fn -> %{} end)
    {:ok, host} = Elzoo.Wave9.Host.start(w)
    {:ok, clients} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Process.unlink(clients)

    w =
      Map.merge(w, %{
        rs_prefix: rs,
        rs_store: rs_store,
        rs_owner_store: Postgres.store(OwnerRepo, prefix: rs, fold: RS.fold(), limits: RS.limits()),
        engines: engines,
        host: host,
        clients: clients,
        binding_digest: binding.digest,
        lua: Keyword.get(opts, :lua),
        object_store: RS.object_store!()
      })

    tenants = Map.new(~w(T1 T2), fn t -> {t, tenant!(w, t)} end)
    w = Map.put(w, :tenants, tenants)
    :sys.replace_state(host, fn _ -> w end)

    ExUnit.Callbacks.on_exit(fn ->
      # Each engine starts its Effect-intent owners and unlinks them (run_engine.ex, intent/3),
      # so they outlive the engine. Their pids are read from the engine before it stops.
      owners = for {_, e} <- Agent.get(engines, & &1), pid <- engine_intents(e.engine), do: pid
      for {_, e} <- Agent.get(engines, & &1), pid <- [e.engine, e.async], do: stop(pid)

      # Every Effect-intent owner, the engines' and the Run owner's (linked to it), ends before a
      # task it waits on is stopped: an owner whose task stops writes a :Lost event into its
      # tenant schema, which would race the DROP SCHEMA below (40P01).
      for pid <- owners, do: shutdown(pid)
      for {_, t} <- tenants, do: stop_linked(t.run)
      for pid <- owners, do: refute(Process.alive?(pid))

      for {_, t} <- tenants,
          pid <- [t.evidence, t.lock, t.directory, t.supervisor, t.tasks, t.context],
          do: stop(pid)

      stop(host)
      stop(clients)
      Agent.stop(engines)
      for {_, t} <- tenants, do: H.owner!("DROP SCHEMA IF EXISTS #{t.prefix} CASCADE")
    end)

    w
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # The MinIO objects of every artifact that this run's recipe-store schema records (recipe
  # packages and the image), each under `artifacts/<tenant>/<artifact_id>/`, so that the shared
  # test bucket keeps no object of a finished run.
  defp delete_objects!(rs) do
    store = RS.object_store!()

    for [stream] <-
          H.owner!("SELECT stream FROM #{rs}.elzoo_log_heads WHERE stream LIKE 'artifact/%'"),
        ["artifact", tenant, artifact_id] <- [String.split(stream, "/", parts: 3)],
        key <- object_keys(store, "artifacts/#{tenant}/#{artifact_id}/", nil),
        do: assert(%{status: :committed} = Elzoo.ObjectStore.delete(store, key))

    :ok
  end

  defp object_keys(store, prefix, continuation) do
    case Elzoo.ObjectStore.list(store, prefix, continuation: continuation) do
      %{status: :listed, keys: keys, truncated: false} -> keys
      %{status: :listed, keys: keys, continuation: next} -> keys ++ object_keys(store, prefix, next)
    end
  end

  defp engine_intents(engine) do
    if Process.alive?(engine),
      do: for({_, pid} <- :sys.get_state(engine).intents, is_pid(pid), do: pid),
      else: []
  catch
    :exit, _ -> []
  end

  # Stop one process with :shutdown and wait until it is gone.
  defp shutdown(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  # Stop a process with :shutdown and wait until it and every process linked to it are gone.
  defp stop_linked(pid) do
    {:links, links} = Process.info(pid, :links) || {:links, []}
    linked = for l <- links, is_pid(l), l != self(), do: l
    refs = for l <- [pid | linked], do: {l, Process.monitor(l)}
    Process.exit(pid, :shutdown)

    for {l, ref} <- refs do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        5_000 ->
          Process.exit(l, :kill)

          receive do
            {:DOWN, ^ref, :process, _, _} -> :ok
          end
      end
    end

    :ok
  end

  defp tenant!(w, tenant) do
    prefix = w.base <> "_" <> String.downcase(tenant)
    H.owner!("CREATE SCHEMA #{prefix}")
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave9.StoreMigration, prefix: prefix, log: false)
    :ok = H.grant_store!(prefix, w.role)

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 64)
    Process.unlink(supervisor)
    {:ok, tasks} = Task.Supervisor.start_link()
    Process.unlink(tasks)
    {:ok, lock} = Lock.start()

    unit_opts = [
      operator: {RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432,
      offer: fn item ->
        case Registry.lookup(@engines, item.stream) do
          [{pid, _}] -> send(pid, item)
          [] -> :ok
        end

        :ok
      end
    ]

    unit_store =
      Postgres.store(AppRepo,
        prefix: prefix,
        fold: Elzoo.DurableUnit.fold(unit_opts),
        limits: Elzoo.DurableUnit.limits(unit_opts)
      )

    unit_opts = Keyword.put(unit_opts, :store, unit_store)

    {:ok, directory} =
      DynamicUnits.start_link(
        registry: @units,
        supervisor: supervisor,
        idle_ms: 600_000,
        unit_options: fn _ -> unit_opts end
      )

    Process.unlink(directory)

    run_store = Postgres.store(AppRepo, prefix: prefix, fold: Run.fold(), limits: Run.limits())
    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, "runs", "owner", 3_600_000)

    host_store =
      Postgres.store(AppRepo, prefix: prefix, fold: StoreHost.fold(), limits: StoreHost.limits())

    intents = %{
      "effect" => [
        binding: Elzoo.RunEngine.TestBinding,
        store:
          Postgres.store(AppRepo,
            prefix: prefix,
            fold: Elzoo.EffectIntent.fold(Elzoo.RunEngine.TestBinding),
            limits: Elzoo.EffectIntent.limits()
          ),
        clock: fn -> H.now(w) end,
        host: {StoreHost, %{store: host_store, authorize: fn _, _ -> :fresh end}},
        task_supervisor: tasks,
        adapter_context: w.host
      ]
    }

    {:ok, run} = Run.start_link(store: run_store, lease: lease, held: held, effect_intent: intents)
    Process.unlink(run)

    {:ok, rev, _} =
      Run.command(run, %{
        kind: :create,
        run_id: "host",
        operation_id: "host",
        provider_refs: %{},
        expected_revision: held.live.revision
      })

    {:ok, _, _} =
      Run.command(run, %{
        kind: :begin_attempt,
        run_id: "host",
        attempt_id: "attempt",
        expected_revision: rev
      })

    evidence_fold = %{
      initial: nil,
      kinds: %{"completion" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn _, _, _, bytes -> bytes end
    }

    evidence_limits = %{
      max_record_bytes: 131_072,
      max_batch_size: 1,
      max_checkpoint_bytes: 1_048_576
    }

    evidence_store =
      Postgres.store(AppRepo, prefix: prefix, fold: evidence_fold, limits: evidence_limits)

    {:ok, evidence} =
      Writer.start_link(
        store: evidence_store,
        stream: "evidence",
        fold: evidence_fold,
        limits: evidence_limits
      )

    Process.unlink(evidence)

    {:ok, context} =
      Agent.start(fn ->
        %{
          policy: %{
            id: "policy",
            version: 1,
            content_hash: <<0::256>>,
            effect_classes: ["compute", "publish"],
            rules: [
              %{id: "compute", effect_class: "compute", verdict: :allow},
              %{id: "publish", effect_class: "publish", verdict: :allow}
            ]
          },
          authority: [%{target: "document", field: "published", value: true}],
          resource_names: ["document"],
          pause_deadline: H.now(w) + 10_000_000
        }
      end)

    {:ok, art} =
      Elzoo.Artifact.new(store: w.rs_store, object_store: w.object_store, max_bytes: 65_536)

    {:ok, recipes} = RecipeStore.new(artifact: art, log: w.rs_store)
    caller = %{tenant: tenant, principal: "bots", scopes: []}

    package =
      RS.package(name: "wave9-bots-" <> String.downcase(tenant) <> "-" <> H.hex(3), version: "1")

    {:ok, version} = RecipeStore.put(recipes, caller, package)
    {:ok, _} = RecipeStore.check(recipes, caller, version, RS.facts())
    {:ok, _} = RecipeStore.publish(recipes, caller, version)

    %{
      tenant: tenant,
      prefix: prefix,
      supervisor: supervisor,
      tasks: tasks,
      lock: lock,
      directory: directory,
      unit_store: unit_store,
      run: run,
      evidence: evidence,
      evidence_store: evidence_store,
      intents: intents,
      context: context,
      art: art,
      recipes: recipes,
      caller: caller,
      version: version
    }
  end

  # ------------------------------------------------------------ schemas and bindings

  @schemas ~w(elzoo/ai-text-request elzoo.agent-loop.model-attempt elzoo.ai-text.result
              elzoo.agent-loop.message elzoo.agent-loop.tool-call elzoo.agent-loop.tool-result
              elzoo.agent-loop.result elzoo.lua-tool.input elzoo.lua-tool.run
              elzoo.lua-tool.run-result elzoo.lua-tool.module-call elzoo.lua-tool.module-result
              elzoo.lua-tool.result elzoo.run-engine.refusal result)

  def schemas do
    Map.new(@schemas, fn id ->
      port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
      {:ok, compiled} = PayloadSchema.build(port, %{})
      {{id, 1}, %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, "{}")}}
    end)
  end

  defp proposal(tenant),
    do: fn action ->
      %{
        tenant: tenant,
        resource: "document",
        action_id: action["id"],
        payload: {:text, "publish"},
        writes: [%{target: "document", field: "published", value: true}]
      }
    end

  @doc """
  The bindings of one engine: the model call (both schema keys of agent-loop), the tool calls
  (agent-loop's and lua-tool's module calls, each its own result schema), the code-mode nested
  binding of `run_code`, the sandbox `local_work` and the finish.
  """
  def bindings(w, tenant, run_id) do
    proposal = proposal(tenant)

    effect = fn id, result, ms ->
      %{
        id: id,
        version: 1,
        effect_class: "publish",
        result: {result, 1},
        proposal: proposal,
        facts: fn a ->
          deadline = H.now(w) + ms

          %{
            estimate: 1,
            unit: "credits",
            deadline_ms: deadline,
            intent: %{
              identity: [tenant, "account", "effect", "publish", run_id <> "|" <> a["id"]],
              arguments:
                Jason.encode!(%{
                  "tenant" => tenant,
                  "run_id" => run_id,
                  "action_id" => a["id"],
                  "schema_id" => a["schema_id"],
                  "payload" => a["payload"]
                }),
              binding: "effect",
              binding_digest: w.binding_digest,
              deadline_ms: deadline
            }
          }
        end
      }
    end

    compute = fn id, result, ms, estimate ->
      %{
        id: id,
        version: 1,
        effect_class: "compute",
        result: {result, 1},
        proposal: proposal,
        facts: fn _ -> %{estimate: estimate, unit: "credits", deadline_ms: H.now(w) + ms} end
      }
    end

    model = effect.("wave9.model", "elzoo.ai-text.result", @model_ms)

    %{
      "model_call" => %{
        "elzoo/ai-text-request" => model,
        "elzoo.agent-loop.model-attempt" => model
      },
      "tool_call" => %{
        "elzoo.agent-loop.tool-call" =>
          effect.("wave9.tool", "elzoo.agent-loop.tool-result", @tool_ms),
        "elzoo.lua-tool.module-call" =>
          effect.("wave9.module", "elzoo.lua-tool.module-result", @module_ms)
      },
      "nested_callable" => %{
        "elzoo.agent-loop.tool-call" =>
          compute.("wave9.code", "elzoo.agent-loop.tool-result", @code_ms, 10_000)
          |> Map.put(:nested, &code_child(w, run_id, &1))
      },
      "local_work" => %{
        "elzoo.lua-tool.run" =>
          compute.("wave9.run", "elzoo.lua-tool.run-result", @code_ms, 1)
          |> Map.put(:work, fn a -> {Elzoo.Wave9.CodeMode, :run, [w.lua, a["payload"]]} end)
      },
      "finish" => compute.("wave9.finish", "result", @model_ms, 1)
    }
  end

  # ------------------------------------------------------------ code mode

  @doc "The module functions that the host offers: `add`, `mul` and `wipe`, as manifests."
  def manifests do
    for {name, description} <- [
          {"add", "Add one to n"},
          {"mul", "Double n"},
          {"wipe", "Delete every document"}
        ] do
      schema = %{
        "type" => "object",
        "properties" => %{"n" => %{"type" => "integer"}},
        "required" => ["n"],
        "additionalProperties" => false
      }

      port = fn dir ->
        %{
          "id" => name <> "_" <> dir,
          "direction" => dir,
          "schema_id" => "wave9.module." <> name,
          "schema_version" => 1
        }
      end

      %{
        "name" => name,
        "version" => 1,
        "description" => description,
        "arguments" => %{"port" => port.("input"), "schema" => schema},
        "result" => %{"port" => port.("output"), "schema" => schema},
        "cost" => %{"unit" => "call", "estimate" => 1},
        "permissions" => []
      }
    end
  end

  # The code-mode binding of `run_code`: the lua-tool spec from the proposal's source and the
  # Run's declared functions (their manifests only), and lua-tool as the nested child.
  defp code_child(w, run_id, action) do
    %{"arguments" => %{"source" => source} = args} = action["payload"]
    declared = Map.get(H.env(w, {:declared, run_id}) || %{}, :functions, [])

    {:ok, bindings} =
      Elzoo.LuaBinding.resolve(
        for(name <- declared, do: %{"name" => name, "version" => 1}),
        manifests()
      )

    {:ok, source_entry} = Elzoo.LuaBinding.source(bindings, "modules")

    {:ok, inner} =
      Elzoo.LuaTool.new(%{
        id: code_id(action["id"]),
        source: source,
        policy: Elzoo.LuaSandbox.policy().identity,
        limits: lua_limits(),
        bindings: bindings,
        sources: [source_entry],
        source_id: "modules",
        max_calls: 4
      })

    %{
      budget_id: "nested-" <> action["id"],
      incarnation: "sealed",
      mfa: {Elzoo.Wave9.CodeMode, :step},
      initial_state: %{inner: inner},
      schema_id: "elzoo.lua-tool.input",
      schema_version: 1,
      payload: %{"input" => Map.get(args, "input", %{})}
    }
  end

  @doc "The lua-tool `id` of a `run_code` action: 1..64 bytes without `\":\"`."
  def code_id(action_id), do: "code-" <> binary_part(H.sha256(action_id), 0, 32)

  @doc "`wall_ms` at the sandbox's maximum of 1,000 and a `steps` bound well within it."
  def lua_limits,
    do: %{
      "steps" => 20_000,
      "call_depth" => 16,
      "value_bytes" => 4_096,
      "memory_bytes" => 4_194_304,
      "wall_ms" => 1_000
    }

  # ------------------------------------------------------------ agent-loop specs

  def sources(kinds) do
    tool = fn name, description, schema ->
      %{
        "trust" => "untrusted",
        "name" => name,
        "description" => description,
        "input_schema" => schema,
        "annotations" => nil
      }
    end

    for kind <- kinds do
      case kind do
        :mcp ->
          %{
            "id" => "mcp",
            "kind" => "other",
            "callable" => "adapter",
            "tools" => [
              tool.("echo", "Echo x from the tenant's tool server", %{
                "type" => "object",
                "properties" => %{"x" => %{"type" => "string"}}
              })
            ]
          }

        :code ->
          %{
            "id" => "code",
            "kind" => "other",
            "callable" => "nested",
            "tools" => [
              tool.("run_code", "Run a Lua program over the declared functions", %{
                "type" => "object",
                "properties" => %{
                  "source" => %{"type" => "string"},
                  "input" => %{"type" => "object"}
                },
                "required" => ["source"]
              })
            ]
          }

        :host ->
          %{
            "id" => "host",
            "kind" => "other",
            "callable" => "adapter",
            "tools" => [tool.("lookup", "Look up a fact", %{"type" => "object"})]
          }
      end
    end
  end

  def agent_spec(id, kinds, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        model: "scripted-model",
        max_output_tokens: 256,
        role_instructions: ["You are the bot #{id}."],
        window: %{
          provider_id: "scripted",
          model_id: "scripted-model",
          size: 100_000,
          unit: :tokens,
          estimator_id: "bytes",
          estimator_version: 1
        },
        max_request_bytes: 60_000,
        max_image_refs: 8,
        sources: sources(kinds),
        result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
        ask: nil,
        turn_limit: 6
      },
      extra
    )
  end

  # ------------------------------------------------------------ engines

  @doc """
  Start one bot Run: create and begin the Run in the tenant's Run owner (under its lock), then
  the engine with every Store on the application Repo, then its start input.
  """
  def start_bot!(w, tenant, label, spec, text, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, label)
    {:ok, state} = Elzoo.AgentLoop.new(spec)

    e =
      start_engine!(w, tenant, %{
        label: label,
        run_id: run_id,
        principal: Keyword.get(opts, :principal, "service:bots"),
        pattern: {Elzoo.Wave9.Agent, :step, state},
        model: Keyword.get(opts, :model, :scripted),
        expiry: Keyword.get(opts, :expiry, false),
        limiter: Keyword.get(opts, :limiter)
      })

    payload =
      case Keyword.get(opts, :images) do
        nil -> %{"text" => text}
        images -> %{"text" => text, "images" => images}
      end

    assert {:ok, _} =
             input!(w, run_id, "start:" <> run_id, %{
               "kind" => "start",
               "schema_id" => "elzoo.agent-loop.message",
               "schema_version" => 1,
               "payload" => payload
             })

    e
  end

  def start_engine!(w, tenant, %{run_id: run_id, pattern: pattern} = spec) do
    t = w.tenants[tenant]
    ensure_run!(w, tenant, run_id)
    name = {:via, Registry, {@engines, run_id}}

    {:ok, async} =
      GenServer.start(Elzoo.AsyncWork, owner: name, task_supervisor: t.tasks, max_concurrency: 8)

    deadline = H.now(w) + @run_ms
    principal = Map.get(spec, :principal, "service:bots")

    opts =
      [
        name: name,
        identity: run_id,
        directory: t.directory,
        store: t.unit_store,
        run_owner: t.run,
        run_id: run_id,
        tenant: tenant,
        principal: principal,
        pattern: pattern,
        schemas: schemas(),
        gate: %{id: "gate", version: 1, call: fn _, _ -> :allow end},
        clock: fn -> H.now(w) end,
        bindings: bindings(w, tenant, run_id),
        context: fn -> Agent.get(t.context, & &1) end,
        async_work: async,
        resources: %{},
        effect_intent: t.intents,
        request_cap: 256,
        budget: %{cap: 10_000_000, unit: "credits", id: "budget", incarnation: "sealed"},
        budget_rule: :finish,
        run_deadline: deadline,
        evidence: %{writer: t.evidence, stream: "evidence"},
        result_reader: %{evidence_store: t.evidence_store, retention_count: 1_024}
      ] ++ if(Map.get(spec, :expiry), do: [expiry_reports: :owner], else: [])

    H.engine_on_app!(opts, w.role)
    {:ok, pid} = RunEngine.start_link(opts)
    Process.unlink(pid)

    entry =
      Map.merge(spec, %{
        tenant: tenant,
        engine: pid,
        async: async,
        scope: %{tenant: tenant, principal: principal, run_id: run_id},
        run_deadline: deadline
      })

    Agent.update(w.engines, &Map.put(&1, run_id, entry))
    entry
  end

  defp rev(w, tenant) do
    {:ok, %{revision: revision}} = Run.status(w.tenants[tenant].run, "host")
    revision
  end

  def command!(w, tenant, command) do
    locked(w, tenant, fn ->
      Run.command(w.tenants[tenant].run, Map.put(command, :expected_revision, rev(w, tenant)))
    end)
  end

  def locked(w, tenant, fun), do: Lock.run(w.tenants[tenant].lock, fun)

  defp ensure_run!(w, tenant, run_id) do
    {:ok, _, _} =
      command!(w, tenant, %{
        kind: :create,
        run_id: run_id,
        operation_id: "op-" <> run_id,
        provider_refs: %{}
      })

    {:ok, _, _} =
      command!(w, tenant, %{kind: :begin_attempt, run_id: run_id, attempt_id: "attempt"})

    :ok
  end

  def entry(w, run_id), do: Agent.get(w.engines, & &1[run_id])

  def view(w, run_id) do
    {:ok, view} = RunEngine.status(entry(w, run_id).engine)
    view
  end

  def transcript(w, run_id) do
    e = entry(w, run_id)

    {:ok, %{entries: entries}} =
      RunEngine.transcript(e.engine, e.scope, %{max_records: 65_536, max_bytes: 536_870_912})

    entries
  end

  @doc "Every action of a Run's record, nested ones included: `{action_id, kind, schema_id, payload}`."
  def actions(w, run_id),
    do:
      for(
        %{type: :action, action_id: id} = a <- transcript(w, run_id),
        do: {id, a[:kind], a[:schema_id], a[:payload]}
      )

  @doc "The settlements of a Run's record: `{action_id, outcome, at_ms}`."
  def settlements(w, run_id),
    do:
      for(
        %{type: :settlement, action_id: id, outcome: o, at_ms: at} <- transcript(w, run_id),
        do: {id, o, at}
      )

  def result(w, run_id) do
    e = entry(w, run_id)
    RunEngine.result(e.engine, e.scope, %{max_records: 65_536, max_bytes: 536_870_912})
  end

  @doc "An input of the harness to an engine (under the tenant's lock), at its current Attempt."
  def input!(w, run_id, id, input, extra \\ %{}) do
    e = entry(w, run_id)

    locked(w, e.tenant, fn ->
      {:ok, view} = RunEngine.status(e.engine)
      context = Map.merge(%{run_id: view.run_id, attempt_id: view.attempt_id}, extra)
      RunEngine.input(e.engine, id, Map.merge(%{"type" => "input", "version" => 1}, input), context)
    end)
  end

  def outcome(id, class, schema, payload),
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "action_id" => id,
      "outcome" => class,
      "schema_id" => schema,
      "schema_version" => 1,
      "payload" => payload
    }

  @doc """
  The sink: the outcome reaches the engine through `input/4`, for the open slot of the action,
  under the tenant's lock.
  """
  def give_outcome(w, run_id, action_id, input) do
    e = entry(w, run_id)

    locked(w, e.tenant, fn ->
      {:ok, view} = RunEngine.status(e.engine)

      case Enum.find(view.slots, fn {_, slot} ->
             slot.action_id == action_id and slot.phase != :settled
           end) do
        nil ->
          :settled

        {key, _} ->
          context = %{
            run_id: view.run_id,
            attempt_id: view.attempt_id,
            occurrence: key,
            actual: 1,
            dispatch: "dispatched"
          }

          RunEngine.input(e.engine, "out:" <> action_id, input, context)
      end
    end)
  end

  @doc "Wait until the Run is terminal."
  def finished!(w, run_id, tries \\ 3_000) do
    view = view(w, run_id)

    cond do
      view.reconciliation != nil -> flunk("engine halted: #{inspect(view.reconciliation)}")
      view.phase == :terminal -> view
      tries == 0 -> flunk("Run #{run_id} did not finish: #{inspect(view.slots)}")
      true -> Process.sleep(10) && finished!(w, run_id, tries - 1)
    end
  end

  def await!(fun, tries \\ 3_000) do
    cond do
      value = fun.() -> value
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && await!(fun, tries - 1)
    end
  end

  # ------------------------------------------------------------ the host's Effects

  def tool_payload(text, source),
    do: %{
      "content" => %{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => [source],
        "trust" => "untrusted",
        "max_bytes" => 4_096,
        "content" => text
      },
      "media_type" => "text/plain",
      "encoding" => "utf8"
    }

  @doc "A completed model result: text, or tool proposals `{alias, arguments}`."
  def say(text), do: %{"content" => text, "finish" => "stop", "tool_proposals" => []}

  def propose(calls),
    do: %{
      "content" => "",
      "finish" => "tool_calls",
      "tool_proposals" =>
        Enum.map(Enum.with_index(calls, 1), fn {{name, args}, n} ->
          %{"id" => "p#{n}", "name" => name, "arguments" => args, "malformed" => nil}
        end)
    }

  @doc "Script the model answers of a Run (popped in order); `:hold` keeps a call until release."
  def script(w, run_id, answers), do: H.env(w, {:script, run_id}, answers)

  def release!(w, key, answer) do
    %{task: task, run_id: run_id, action_id: id} = await!(fn -> H.env(w, {:held, key}) end)
    H.env(w, {:held, key}, nil)
    send(task, {:result, %{}})
    give_outcome(w, run_id, id, answer)
  end

  def held?(w, key), do: H.env(w, {:held, key}) != nil

  def calls(w), do: H.env(w, :calls) || []

  @doc false
  def effect(w, task, %{"run_id" => run_id, "action_id" => id, "schema_id" => schema} = call) do
    H.env_update(w, :calls, [{run_id, id, schema}], &(&1 ++ [{run_id, id, schema}]))
    e = entry(w, run_id)

    case schema do
      model when model in ["elzoo/ai-text-request", "elzoo.agent-loop.model-attempt"] ->
        case e.model do
          :scripted -> scripted(w, task, run_id, id)
          :routed -> Elzoo.Wave9.Models.route(w, task, e, call)
        end

      "elzoo.agent-loop.tool-call" ->
        case call["payload"]["tool"] do
          "echo" -> mcp_tool(w, task, run_id, id, call["payload"]["arguments"])
          "lookup" -> lookup(w, task, run_id, id)
        end

      "elzoo.lua-tool.module-call" ->
        module(w, task, run_id, id, call["payload"])
    end
  end

  defp scripted(w, task, run_id, id) do
    answer =
      Agent.get_and_update(w.env, fn env ->
        case Map.get(env, {:script, run_id}, []) do
          [a | rest] -> {a, Map.put(env, {:script, run_id}, rest)}
          [] -> {:unscripted, env}
        end
      end)

    case answer do
      :hold ->
        H.env(w, {:held, {:model, run_id}}, %{task: task, run_id: run_id, action_id: id})

      :unscripted ->
        H.env_update(w, :errors, [{:unscripted, run_id, id}], &(&1 ++ [{:unscripted, run_id, id}]))
        send(task, {:result, %{}})

        give_outcome(
          w,
          run_id,
          id,
          outcome(id, "failed", "elzoo.ai-text.result", %{"reason" => "unscripted"})
        )

      value ->
        send(task, {:result, %{}})
        give_outcome(w, run_id, id, outcome(id, "completed", "elzoo.ai-text.result", value))
    end
  end

  defp lookup(w, task, run_id, id) do
    if H.env(w, {:hold_lookup, run_id}) do
      H.env(w, {:held, {:lookup, run_id}}, %{task: task, run_id: run_id, action_id: id})
    else
      send(task, {:result, %{}})

      give_outcome(
        w,
        run_id,
        id,
        outcome(
          id,
          "completed",
          "elzoo.agent-loop.tool-result",
          tool_payload("fact: 42", "wave9:host")
        )
      )
    end
  end

  # The module functions of code mode: add one, double; a held call is never answered.
  defp module(w, task, run_id, id, %{"tool" => tool, "arguments" => %{"n" => n}}) do
    H.env_update(w, {:module_calls, run_id}, [{id, tool, n}], &(&1 ++ [{id, tool, n}]))

    if H.env(w, {:hold_module, run_id}) do
      H.env(w, {:held, {:module, run_id}}, %{task: task, run_id: run_id, action_id: id})
    else
      result = %{"add" => n + 1, "mul" => n * 2, "wipe" => 0}[tool]
      send(task, {:result, %{}})

      give_outcome(
        w,
        run_id,
        id,
        outcome(id, "completed", "elzoo.lua-tool.module-result", %{"result" => %{"n" => result}})
      )
    end
  end

  # ------------------------------------------------------------ the MCP tool binding

  @doc """
  The MCP tool binding: a `tool_call` of an agent-loop bot calls the tenant server's tool through
  the Run's ready-client session: `McpClient.admission/3` against the session's discovery
  snapshot, an Effect-intent owner on the application Repo, `context/3` bound to the admission
  and `call_tool/3`. The outcome is the agent-loop tool result (completed) or a refusal with its
  reason.
  """
  def mcp_tool(w, task, run_id, id, args) do
    %{session: session, snapshot: snapshot} = H.env(w, {:mcp_session, run_id})
    result = mcp_call(w, session, snapshot, "echo", args)
    H.env_update(w, :mcp_results, [{run_id, result}], &(&1 ++ [{run_id, result}]))
    send(task, {:result, %{}})

    input =
      case result do
        {:completed, %{content: content, is_error: false}} ->
          text = Enum.map_join(content, "\n", & &1["text"])
          outcome(id, "completed", "elzoo.agent-loop.tool-result", tool_payload(text, "wave9:mcp"))

        {class, reason} when class in [:refused, :unknown] ->
          outcome(id, Atom.to_string(class), "elzoo.agent-loop.tool-result", %{
            "reason" => Atom.to_string(reason)
          })
      end

    give_outcome(w, run_id, id, input)
  end

  def mcp_call(w, session, snapshot, tool, args) do
    ref = "call-" <> H.hex(8)

    payload =
      Jason.encode!(%{
        "version" => 1,
        "tool" => tool,
        "arguments" => args,
        "release" => "approval:wave9@v1"
      })

    declaration = %{
      "capability_id" => "integration/mcp-client",
      "operation" => "tools/call",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "m-" <> ref,
        "schema_id" => "elzoo/mcp-tool-call",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "wave9", "port_id" => "tools"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => H.now(w) + 600_000,
        "payload" => payload
      }
    }

    {:ok, admission} = McpClient.admission(session.config, declaration, snapshot)
    {:ok, context} = McpClient.context(session, admission, self())
    pid = H.owner!(w, RuntimeBinding, admission, context)
    McpClient.call_tool(session, admission, pid)
  end
end

# ------------------------------------------------------------------ group 1: OAuth and the tenant server

defmodule Elzoo.Wave9.Recorder do
  @moduledoc """
  The recording loopback MCP server of the tenant (the shape of mcp-runtime's test Recorder):
  ex_mcp's own `ExMCP.HttpPlug` with the ready client helper's Tools handler, behind this Plug,
  which records each request's method and `authorization` header before it is answered.
  """
  @behaviour Plug
  import Plug.Conn

  def start(env) do
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      Plug.Cowboy.http(
        __MODULE__,
        [
          env: env,
          http_plug:
            ExMCP.HttpPlug.init(
              handler: Elzoo.McpClientTest.Tools,
              server_info: %{name: "elzoo-test", version: "1"},
              validate_origin: false
            )
        ],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    %{ref: ref, url: "http://127.0.0.1:#{:ranch.get_port(ref)}/mcp"}
  end

  def stop(%{ref: ref}) do
    Plug.Cowboy.shutdown(ref)
  catch
    _, _ -> :ok
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Logger.put_process_level(self(), :none)
    {:ok, body, conn} = read_body(conn, length: 16_000_000)

    method =
      case Jason.decode(body) do
        {:ok, %{"method" => m}} when is_binary(m) -> m
        _ -> nil
      end

    label = if conn.method == "POST", do: method || :response, else: {:http, conn.method}
    entry = {label, get_req_header(conn, "authorization")}
    Agent.update(opts[:env], &Map.update(&1, :recorded, [entry], fn l -> l ++ [entry] end))

    cond do
      label == {:http, "GET"} -> send_resp(conn, 405, "")
      label == :response -> send_resp(conn, 202, "")
      true -> conn |> assign(:raw_body, body) |> ExMCP.HttpPlug.call(opts[:http_plug])
    end
  end
end

defmodule Elzoo.Wave9.Tools do
  @moduledoc """
  The OAuth wiring of group 1: the oauth-client binding (its transport Need gives the local
  authorization server as a `Req.Test` plug), the mcp-runtime config whose `oauth` Need wraps
  `access_token/3`, and the ready-client sessions of the tenant server in `:loopback` mode.
  """
  import ExUnit.Assertions
  alias Elzoo.{EgressPolicy, McpClient, McpRuntime, OauthClient}
  alias Elzoo.McpClient.RuntimeBinding
  alias Elzoo.Secrets.Credential
  alias Elzoo.Wave9.AppRepo
  alias Elzoo.Wave9.Helper, as: H

  @far 9_000_000_000_000
  @client_secret "wave9-client-secret-7Hq"
  @auth_host "auth.example.com"
  @mcp_url "https://mcp.tenant.example/mcp"

  def mcp_url, do: @mcp_url
  def b64token?(t), do: is_binary(t) and byte_size(t) >= 24 and t =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  defp sealing_key,
    do: %Credential{value: :binary.copy(<<7>>, 32), version: 1, expires_at_unix_ms: @far}

  def provider,
    do: %{
      provider_id: "auth",
      authorization_endpoint: "https://#{@auth_host}/authorize",
      token_endpoint: "https://#{@auth_host}/token",
      revocation_endpoint: nil,
      redirect_uri: "https://app.example.org/oauth/callback",
      client_id: "wave9-client",
      client_secret_ref: %{ref: "oauth-client", scope: "oauth"},
      client_auth: :client_secret_basic,
      scopes_allowed: ["tools:call"],
      refresh_rotation: false,
      default_lifetime_s: nil
    }

  def policy, do: EgressPolicy.policy(hosts: [@auth_host, "mcp.tenant.example"], ports: [443])

  def resolver(w), do: fn host -> {:ok, H.env(w, {:dns, host}) || [H.public_address()]} end

  @doc "The oauth-client binding on the application Repo, its Needs the harness doubles."
  def oauth!(w) do
    H.env(w, :token_requests, [])

    {:ok, b} =
      OauthClient.new(
        repo: AppRepo,
        prefix: w.p.oauth,
        providers: [provider()],
        policy: policy(),
        resolver: resolver(w),
        transport: fn _target -> {:ok, [plug: &token_endpoint(w, &1)]} end,
        exchange_timeout_ms: H.exchange_ms(),
        secrets: fn request ->
          %{
            grant: request,
            resolver: fn ref, scope ->
              {:ok,
               %{
                 ref: ref,
                 scope: scope,
                 value: @client_secret,
                 version: 1,
                 expires_at_unix_ms: @far
               }}
            end
          }
        end,
        sealing: %{
          key_id: "k1",
          key: fn -> {:ok, sealing_key()} end,
          keys: fn "k1", 1 -> {:ok, sealing_key()} end
        },
        clock: fn -> H.now(w) end
      )

    :ok = OauthClient.verify(b)
    b
  end

  @doc "A fresh token pair: RFC 6750 b64tokens of more than 24 bytes."
  def tokens(lifetime_s \\ 120) do
    %{
      "access_token" => "at-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      "token_type" => "Bearer",
      "expires_in" => lifetime_s,
      "refresh_token" => "rt-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    }
  end

  # The local authorization server's token endpoint: the code exchange checks the verifier
  # against the challenge it issued the code for; a refresh can be held or answered invalid_grant.
  defp token_endpoint(w, conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    form = URI.decode_query(body)
    auth = Plug.Conn.get_req_header(conn, "authorization")
    H.env_update(w, :token_requests, [form], &(&1 ++ [form]))

    {status, reply} =
      case form["grant_type"] do
        "authorization_code" ->
          case H.env(w, {:code, form["code"]}) do
            %{challenge: challenge, used: false} = code ->
              H.env(w, {:code, form["code"]}, %{code | used: true})

              ok =
                auth == ["Basic " <> Base.encode64("wave9-client:" <> @client_secret)] and
                  Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"] || ""),
                    padding: false
                  ) ==
                    challenge

              if ok, do: issue(w, form), else: {400, %{"error" => "invalid_grant"}}

            _ ->
              {400, %{"error" => "invalid_grant"}}
          end

        "refresh_token" ->
          if H.env(w, :hold_refresh) do
            H.env(w, :refresh_held, true)
            Elzoo.Wave9.Bots.await!(fn -> H.env(w, :release_refresh) end)
          end

          current = List.last(H.env(w, :issued) || [])

          cond do
            current == nil or form["refresh_token"] != current["refresh_token"] ->
              {400, %{"error" => "invalid_grant"}}

            H.env(w, :refresh_answer) == :invalid_grant ->
              {400, %{"error" => "invalid_grant"}}

            true ->
              issue(w, form)
          end
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(reply))
  end

  defp issue(w, _form) do
    t = tokens()
    H.env_update(w, :issued, [t], &(&1 ++ [t]))
    {200, t}
  end

  @doc """
  Ann's code flow: `begin_authorization/3`, the local authorization server reads `state` and
  `code_challenge` from the URL and issues a code, then `complete_authorization/3`.
  """
  def authorize!(w, b, tenant, connection_id) do
    assert {:ok, %{authorization_url: url}} =
             OauthClient.begin_authorization(b, tenant, %{
               connection_id: connection_id,
               provider_id: "auth",
               scopes: ["tools:call"]
             })

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["code_challenge_method"] == "S256"
    code = "code-" <> H.hex(8)
    H.env(w, {:code, code}, %{challenge: query["code_challenge"], used: false})

    {query["state"], code,
     OauthClient.complete_authorization(b, tenant, %{state: query["state"], code: code})}
  end

  def token_requests(w, grant),
    do: for(f <- H.env(w, :token_requests), f["grant_type"] == grant, do: f)

  @doc "The mcp-runtime config of the tenant server with the OAuth Need over `access_token/3`."
  def runtime!(w, b, tenant, connection_id) do
    {:ok, config} =
      McpRuntime.configure(
        tenant: tenant,
        server: "tenant-tools",
        url: @mcp_url,
        policy: policy(),
        resolver: resolver(w),
        credential: %{oauth: connection_id},
        oauth: fn %{tenant: t, connection_id: id} ->
          H.env_update(w, :oauth_calls, 1, &(&1 + 1))
          OauthClient.access_token(b, t, %{connection_id: id})
        end
      )

    config
  end

  @doc """
  The tenant server's session: the ready client configured directly in `:loopback` mode with the
  admitted config's credential Need, connected, and its discovery snapshot.
  """
  def session!(w, client_config, url) do
    {:ok, c} =
      McpClient.configure(
        binding: RuntimeBinding,
        runtime: %{
          server: "tenant-tools",
          endpoint: url,
          network: :loopback,
          addresses: [{127, 0, 0, 1}]
        },
        tenant: client_config.tenant,
        credentials: client_config.credentials,
        call_timeout_ms: 20_000
      )

    {:ok, s} = McpClient.connect(c, w.clients)
    {:ok, snapshot} = McpClient.list_tools(s)
    %{session: s, snapshot: snapshot}
  end

  def recorded(w), do: H.env(w, :recorded) || []
end

# ------------------------------------------------------------------ group 2: Elzoo's MCP server

defmodule Elzoo.Wave9.McpHost do
  @moduledoc "The init triple of the router's forward: the server that the running test stored."
  def put(value), do: :persistent_term.put(__MODULE__, value)
  def server, do: :persistent_term.get(__MODULE__)
end

defmodule Elzoo.Wave9.Router do
  @moduledoc "The host router: Elzoo's MCP server Plug under `forward \"/mcp\"`."
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/mcp", to: Elzoo.McpServer.Plug, init_opts: {Elzoo.Wave9.McpHost, :server, []})

  match _ do
    send_resp(conn, 404, "")
  end
end

defmodule Elzoo.Wave9.Server do
  @moduledoc """
  The MCP server wiring: `Elzoo.McpServer.new/1` with a JWT verifier, the shared clock in Unix
  seconds, a `domain/authorization` policy, and the `authority`, `bots`, `start` and `result`
  Needs over the engines and the recipe store; the router on `Plug.Cowboy` at 127.0.0.1.
  """
  import ExUnit.Assertions
  alias Elzoo.{McpClient, McpServer, RecipeStore, TokenVerify}
  alias Elzoo.McpClient.RuntimeBinding
  alias Elzoo.Wave9.Bots, as: B
  alias Elzoo.Wave9.Helper, as: H

  @issuer "https://issuer.example"
  @audience "elzoo-mcp"
  @call_timeout_ms 3_000
  @idle_timeout_ms 60_000

  def call_timeout_ms, do: @call_timeout_ms
  def idle_timeout_ms, do: @idle_timeout_ms

  # P and Q of T1 with different authority sets; D the T2 caller.
  @people %{
    "P" => %{tenant: "T1", own: ~w(summarize slow badroot)},
    "Q" => %{tenant: "T1", own: ~w(summarize translate badroot)},
    "D" => %{tenant: "T2", own: ~w(invoice summarize)}
  }

  @strict %{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"],
    "additionalProperties" => false
  }

  def bots("T1"),
    do: [
      bot("summarize", @strict),
      bot("translate", @strict),
      bot("slow", @strict),
      bot("badroot", %{"type" => "array"})
    ]

  def bots("T2"), do: [bot("invoice", @strict)]
  def bots(_), do: []

  defp bot(name, schema),
    do: %{
      bot_id: "bot-" <> name,
      name: name,
      description: "The " <> name <> " bot",
      start_schema: schema,
      schema_version: 1
    }

  def policy do
    allow = fn bot ->
      %{
        id: "allow-" <> bot,
        effect_class: "mcp.run",
        target: {:exact, "bot/bot-" <> bot},
        verdict: :allow
      }
    end

    %{
      id: "mcp-policy",
      version: 1,
      content_hash: :crypto.hash(:sha256, "wave9-mcp-policy-1"),
      effect_classes: ["mcp.run"],
      rules: Enum.map(~w(summarize translate slow badroot invoice), allow)
    }
  end

  def own(id),
    do: Enum.map(@people[id].own, &%{target: "bot/bot-" <> &1, field: "run", value: true})

  def principal(id),
    do: %{kind: :human, id: id, tenant: @people[id].tenant, allowed_scopes: [], allowed_spaces: []}

  @doc "The server, mounted, and the listener: `%{url, ref, key, starts}`."
  def start!(w) do
    key = JOSE.JWK.generate_key({:okp, :Ed25519})
    {_, public} = JOSE.JWK.to_public_map(key)
    H.env(w, :starts, [])

    verifier =
      TokenVerify.jwt_config(
        issuer: @issuer,
        audience: @audience,
        keys: [%{kid: "k1", alg: "EdDSA", jwk: public}],
        leeway_s: 0,
        subject: fn %{subject: id} ->
          case @people[id] do
            nil -> {:error, :unknown_subject}
            _ -> {:ok, %{principal: principal(id), current_epoch: 0}}
          end
        end
      )

    {:ok, server} =
      McpServer.new(
        verifier: {:jwt, verifier},
        clock: fn -> div(H.now(w), 1_000) end,
        policy: policy(),
        authority: fn p ->
          H.env_update(w, :need_calls, 1, &(&1 + 1))
          {:ok, own(p.id)}
        end,
        bots: fn tenant ->
          H.env_update(w, :need_calls, 1, &(&1 + 1))
          {:ok, bots(tenant)}
        end,
        start: &start_need(w, &1),
        result: &result_need(w, &1),
        call_timeout_ms: @call_timeout_ms,
        poll_interval_ms: 50
      )

    Elzoo.Wave9.McpHost.put({:ok, server})
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      Plug.Cowboy.http(Elzoo.Wave9.Router, [],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref,
        protocol_options: [idle_timeout: @idle_timeout_ms]
      )

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ref)
      catch
        _, _ -> :ok
      end
    end)

    %{url: "http://127.0.0.1:#{:ranch.get_port(ref)}/mcp", ref: ref, key: key}
  end

  def ptext(%{kind: kind, id: id}), do: Atom.to_string(kind) <> ":" <> id

  # The start Need: pin the bot's version for the new Run, start one Run with the caller as its
  # acting principal, give it the caller's text.
  defp start_need(w, %{
         tenant: tenant,
         principal: p,
         bot_id: bot_id,
         call_id: call_id,
         arguments: args
       }) do
    H.env_update(w, :starts, [{tenant, p.id, bot_id}], &(&1 ++ [{tenant, p.id, bot_id}]))
    run_id = "mcp-" <> call_id
    t = w.tenants[tenant]
    {:ok, :pinned} = RecipeStore.pin(t.recipes, t.caller, t.version, run_id)

    B.script(
      w,
      run_id,
      if(bot_id == "bot-slow", do: [:hold], else: [B.say("done: " <> args["text"])])
    )

    H.env(w, {:bot_of, run_id}, bot_id)

    B.start_bot!(w, tenant, run_id, B.agent_spec(run_id, []), args["text"], principal: ptext(p))
    {:ok, run_id}
  end

  # The result Need: the engine's result/3 for that Run, with the caller as its principal text.
  defp result_need(w, %{tenant: tenant, principal: p, run_id: run_id}) do
    e = B.entry(w, run_id)

    Elzoo.RunEngine.result(
      e.engine,
      %{tenant: tenant, principal: ptext(p), run_id: run_id},
      %{max_records: 65_536, max_bytes: 536_870_912}
    )
  end

  def starts(w), do: H.env(w, :starts)

  @doc "The calls of the `authority` and `bots` Needs so far (the handlers' first reads)."
  def need_calls(w), do: H.env(w, :need_calls) || 0

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  @doc "A bearer JWT of `sub`, signed with the test key; `exp` and `iat` relative to the clock."
  def token(w, srv, sub, opts \\ []) do
    now = div(H.now(w), 1_000)

    claims = %{
      "iss" => @issuer,
      "sub" => sub,
      "aud" => @audience,
      "exp" => now + Keyword.get(opts, :exp, 600),
      "iat" => now + Keyword.get(opts, :iat, -60)
    }

    %JOSE.JWK{kty: {_, <<seed::binary-32, _::binary-32>>}} = srv.key

    input =
      b64(Jason.encode!(%{"alg" => "EdDSA", "kid" => "k1"})) <> "." <> b64(Jason.encode!(claims))

    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [seed, :ed25519]))
  end

  @doc "The ready client of a caller: `RuntimeBinding`, `network: :loopback`, its default mode."
  def client!(w, srv, tenant, token) do
    {:ok, config} =
      McpClient.configure(
        binding: RuntimeBinding,
        runtime: %{
          server: "elzoo-bots",
          endpoint: srv.url,
          network: :loopback,
          addresses: [{127, 0, 0, 1}]
        },
        tenant: tenant,
        credentials: fn -> {:ok, token} end,
        call_timeout_ms: 20_000
      )

    {:ok, session} = McpClient.connect(config, w.clients)
    {:ok, snapshot} = McpClient.list_tools(session)
    %{session: session, snapshot: snapshot}
  end

  def names(%{snapshot: %{tools: tools}}), do: Enum.map(tools, & &1["name"])

  def text({:completed, %{content: [%{"type" => "text", "text" => text}]} = r}),
    do: {r.is_error, Jason.decode!(text)}

  def post(srv, headers, body) do
    Req.post!(srv.url,
      headers:
        [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
          headers,
      body: body,
      retry: false,
      decode_body: false,
      receive_timeout: 20_000
    )
  end

  def rpc(id, method, params),
    do: Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})

  @doc "A legacy session: `initialize` and `notifications/initialized`; its session ID."
  def legacy!(srv, token) do
    auth = [{"authorization", "Bearer " <> token}]

    init =
      post(
        srv,
        auth,
        rpc(1, "initialize", %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "raw", version: "1"}
        })
      )

    assert init.status == 200
    [sid] = Req.Response.get_header(init, "mcp-session-id")

    resp =
      post(
        srv,
        auth ++ session_headers(sid),
        Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"})
      )

    assert resp.status == 202
    sid
  end

  def session_headers(sid), do: [{"mcp-session-id", sid}, {"mcp-protocol-version", "2025-11-25"}]

  @doc "One raw JSON-RPC request on a legacy session: `{status, decoded body}`."
  def raw(srv, token, sid, method, params, extra \\ []) do
    resp =
      post(
        srv,
        [{"authorization", "Bearer " <> token}] ++ session_headers(sid) ++ extra,
        rpc(System.unique_integer([:positive]), method, params)
      )

    {resp.status, Jason.decode!(resp.body)}
  end
end

# ------------------------------------------------------------------ group 3: models

for {name, id, account} <- [
      {CompatBinding, "wave9.compat", "acct-compat"},
      {GeminiBinding, "wave9.gemini", "acct-gemini"},
      {CompatEuBinding, "wave9.compat-eu", "acct-compat-eu"}
    ] do
  defmodule Module.concat(Elzoo.Wave9.Models, name) do
    use Elzoo.AiText.Binding, id: id, provider_account: account, recovery_grace_ms: 60_000
  end
end

defmodule Elzoo.Wave9.Models do
  @moduledoc """
  The routing binding of group 3: the host's model-call binding for an agent-loop bot over route
  `chat` v1 (`delivery/model-routing`), with three candidates, each its own ai-text Config,
  credential Need, artifact Need, Binding module and Effect-intent owner on the application
  Repo. `compat` and `compat-eu` are `integration/ai-text-compatible` endpoints whose transport
  Need answers a `Req.Test` function plug; `gemini` is `integration/ai-text-google` with its test
  `plug` option. Every stub records its requests and answers from a script.
  """
  import ExUnit.Assertions
  alias Elzoo.{AiText, EgressPolicy, Metering, ModelRouting, RateLimit}
  alias Elzoo.Wave9.Bots, as: B
  alias Elzoo.Wave9.Helper, as: H

  @tenant "T1"
  @period "2026-11"
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  def png, do: @png
  def period, do: @period

  def route,
    do: %{
      id: "chat",
      version: 1,
      on_unknown: :stop,
      max_health_age_ms: 60_000,
      cool_down_ms: 10_000,
      retry: [
        max_attempts: 3,
        base_backoff_ms: 100,
        max_backoff_ms: 1_000,
        jitter: :none,
        max_failure_delay_ms: 10_000
      ],
      candidates: [
        %{
          ref: "compat",
          provider: "wave9-compat",
          region: "us",
          retention: "zero",
          model_id: "compat-chat",
          features: [:tools],
          rank: 1
        },
        %{
          ref: "gemini",
          provider: "google",
          region: "us",
          retention: "zero",
          model_id: "gemini-3.8-flash",
          features: [:tools, :structured_output, :image_input],
          rank: 2
        },
        %{
          ref: "compat-eu",
          provider: "wave9-compat",
          region: "eu",
          retention: "zero",
          model_id: "compat-eu-chat",
          features: [:tools, :image_input],
          rank: 3
        }
      ]
    }

  @doc "T1's data policy: both providers for internal data in region `us` only."
  def data_policy,
    do: %{
      providers:
        for provider <- ["wave9-compat", "google"] do
          %{
            provider: provider,
            classes: [%{class: :internal, regions: ["us"], retention: ["zero"]}]
          }
        end
    }

  @hosts %{"compat" => "llm.t1.example", "compat-eu" => "llm-eu.t1.example"}

  @doc """
  The three candidates of T1: keys, stubs, Needs and Configs, kept in the env under `:models`.
  The image artifact is committed in T1's `state/artifact` on MinIO.
  """
  def setup!(w) do
    {:ok, route} = ModelRouting.new(route())
    t = w.tenants[@tenant]
    image_id = "img-" <> H.hex(4)

    {:ok, %{version: 1}} =
      Elzoo.Artifact.put(t.art, t.caller, image_id, %{bytes: @png, media_type: "image/png"})

    keys = %{
      "compat" => "sk-compat-" <> H.hex(16),
      "gemini" => "AIza-gemini-" <> H.hex(16),
      "compat-eu" => "sk-compat-eu-" <> H.hex(16)
    }

    policy = EgressPolicy.policy(hosts: Map.values(@hosts), ports: [443])
    sink = fn key, delivery -> H.env(w, {:ai_out, key}, delivery) end

    candidates =
      Map.new(route.candidates, fn c ->
        ref = c.ref
        plug = stub(w, ref)

        credentials = fn ->
          H.env_update(w, {:cred_calls, ref}, 1, &(&1 + 1))
          {:ok, keys[ref]}
        end

        artifacts = fn %{artifact_id: id, version: v} ->
          H.env_update(w, {:art_calls, ref}, 1, &(&1 + 1))
          Elzoo.Artifact.get(t.art, t.caller, id, v)
        end

        {provider, provider_config, binding} =
          case ref do
            "gemini" ->
              {AiText.Google, %{base_url: "https://gemini.wave9.example", plug: plug},
               __MODULE__.GeminiBinding}

            _ ->
              {:ok, endpoint} =
                AiText.Compatible.endpoint(
                  base_url: "https://" <> @hosts[ref] <> "/v1",
                  policy: policy,
                  resolver: fn host -> {:ok, H.env(w, {:dns, host}) || [H.public_address()]} end,
                  transport: fn target ->
                    H.env_update(w, {:transport, ref}, [target], &(&1 ++ [target]))
                    {:ok, plug: plug}
                  end,
                  models: [%{id: c.model_id, features: c.features}]
                )

              {AiText.Compatible, endpoint,
               if(ref == "compat", do: __MODULE__.CompatBinding, else: __MODULE__.CompatEuBinding)}
          end

        {:ok, config} =
          AiText.configure(
            binding: binding,
            tenant: @tenant,
            provider: provider,
            provider_config: provider_config,
            credentials: credentials,
            models: [c.model_id],
            max_output_tokens: 4_096,
            receive_timeout_ms: 5_000,
            sink: sink,
            artifacts: artifacts
          )

        {ref, %{candidate: c, binding: binding, config: config}}
      end)

    m = %{route: route, candidates: candidates, keys: keys, image: image_id}
    H.env(w, :models, m)
    m
  end

  # One recording stub per candidate: a function plug that records method, path, headers and
  # body, and answers the next scripted response (`{status, headers, body}` or
  # `{:transport_error, reason}`).
  defp stub(w, ref) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)

      seen = %{
        path: conn.request_path,
        headers: conn.req_headers,
        body: body,
        json: Jason.decode!(body)
      }

      H.env_update(w, {:stub_requests, ref}, [seen], &(&1 ++ [seen]))

      answer =
        Agent.get_and_update(w.env, fn env ->
          case Map.get(env, {:stub_script, ref}, []) do
            [a | rest] -> {a, Map.put(env, {:stub_script, ref}, rest)}
            [] -> {{500, [], %{"error" => "unscripted"}}, env}
          end
        end)

      case answer do
        {:transport_error, reason} ->
          Req.Test.transport_error(conn, reason)

        {status, headers, json} ->
          headers
          |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(json))
      end
    end
  end

  @doc "Script the stub answers of a candidate (popped in order)."
  def script(w, ref, answers),
    do: H.env_update(w, {:stub_script, ref}, answers, &(&1 ++ answers))

  def requests(w, ref), do: H.env(w, {:stub_requests, ref}) || []
  def cred_calls(w, ref), do: H.env(w, {:cred_calls, ref}) || 0
  def art_calls(w, ref), do: H.env(w, {:art_calls, ref}) || 0
  def log(w, kind), do: H.env(w, {:models_log, kind}) || []
  defp log!(w, kind, entry), do: H.env_update(w, {:models_log, kind}, [entry], &(&1 ++ [entry]))

  # ---- documented-format stub answers

  @doc "A Chat Completions answer: text, or one tool call `{name, arguments}`."
  def compat_answer({name, args}),
    do:
      {200, [],
       compat_body(
         %{
           "role" => "assistant",
           "content" => nil,
           "tool_calls" => [
             %{
               "id" => "call_1",
               "type" => "function",
               "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
             }
           ]
         },
         "tool_calls"
       )}

  def compat_answer(text),
    do: {200, [], compat_body(%{"role" => "assistant", "content" => text}, "stop")}

  defp compat_body(message, finish),
    do: %{
      "id" => "chatcmpl-wave9",
      "object" => "chat.completion",
      "created" => 1_741_570_283,
      "model" => "compat-chat",
      "choices" => [
        %{"index" => 0, "message" => message, "finish_reason" => finish, "logprobs" => nil}
      ],
      "usage" => %{
        "prompt_tokens" => 19,
        "completion_tokens" => 10,
        "total_tokens" => 29,
        "prompt_tokens_details" => %{"cached_tokens" => 0},
        "completion_tokens_details" => %{"reasoning_tokens" => 0}
      }
    }

  def compat_throttled(seconds),
    do:
      {429, [{"retry-after", Integer.to_string(seconds)}],
       %{
         "error" => %{
           "message" => "Rate limit reached",
           "type" => "rate_limit_error",
           "code" => "rate_limit_exceeded"
         }
       }}

  @doc "A GenerateContentResponse answer: text, or one function call `{name, args}`."
  def gemini_answer({name, args}),
    do:
      {200, [],
       gemini_body([%{"functionCall" => %{"id" => "fc_1", "name" => name, "args" => args}}])}

  def gemini_answer(text), do: {200, [], gemini_body([%{"text" => text}])}

  defp gemini_body(parts),
    do: %{
      "candidates" => [
        %{
          "index" => 0,
          "finishReason" => "STOP",
          "content" => %{"role" => "model", "parts" => parts}
        }
      ],
      "modelVersion" => "gemini-3.8-flash",
      "responseId" => "wave9-gemini",
      "usageMetadata" => %{
        "promptTokenCount" => 36,
        "cachedContentTokenCount" => 0,
        "candidatesTokenCount" => 80,
        "thoughtsTokenCount" => 7,
        "totalTokenCount" => 123
      }
    }

  # ---- the binding

  @doc false
  def route(w, task, e, %{"run_id" => run_id, "action_id" => id, "schema_id" => schema} = call) do
    m = H.env(w, :models)

    {request, attempts} =
      case schema do
        "elzoo/ai-text-request" ->
          {call["payload"], []}

        "elzoo.agent-loop.model-attempt" ->
          {call["payload"]["request"], call["payload"]["attempts"]}
      end

    tried = for %{"candidate" => c} <- attempts, is_binary(c), do: c
    ctx = %{w: w, m: m, e: e, run_id: run_id, id: id, request: request}
    input = choose(ctx, tried)
    send(task, {:result, %{}})
    B.give_outcome(w, run_id, id, input)
  end

  @doc "The features that the request needs: `:tools` with tools, `:image_input` with image parts."
  def features(request) do
    images =
      Enum.any?(request["messages"] || [], fn msg ->
        msg["role"] == "user" and is_list(msg["parts"]) and
          Enum.any?(msg["parts"], &(&1["type"] == "image"))
      end)

    if(request["tools"] in [nil, []], do: [], else: [:tools]) ++
      if images, do: [:image_input], else: []
  end

  defp health(w, refs) do
    now = H.now(w)

    %{
      now_ms: now,
      budget_remaining: 1_000_000,
      candidates:
        Map.new(refs, fn ref ->
          {ref,
           %{circuit: :closed, observed_at_ms: now, not_before_ms: H.env(w, {:not_before, ref})}}
        end)
    }
  end

  defp choose(ctx, tried) do
    %{w: w, m: m, run_id: run_id, id: id, request: request} = ctx
    refs = Enum.map(m.route.candidates, & &1.ref)

    req = %{
      features: features(request),
      classes: [:internal],
      data_policy: data_policy(),
      costs: Map.new(refs, &{&1, 1}),
      tried: tried
    }

    selected = ModelRouting.select(m.route, req, health(w, refs))
    log!(w, :select, %{run_id: run_id, action_id: id, at: H.now(w), tried: tried, result: selected})

    case selected do
      {:ok, %{eligible: [ref | _]}} ->
        attempt(ctx, tried, ref, 1)

      {:error, {:no_candidate, _}} ->
        B.outcome(id, "refused", "elzoo.ai-text.result", %{"reason" => "no_candidate"})
    end
  end

  # One Attempt at `ref` (the n-th of this request there): the local rate admission, ai-text's
  # admission, one Effect-intent owner and its dispatch, then `after_failure/3`.
  defp attempt(ctx, tried, ref, n) do
    %{w: w, m: m, run_id: run_id, id: id} = ctx
    c = m.candidates[ref]

    {outcome, sent} =
      case limit(ctx) do
        {:rate_limited, wait} ->
          {{:rate_limited, wait}, false}

        ticket ->
          result = send_one(ctx, c, ref, n)
          release(ctx, ticket)
          result
      end

    decision =
      ModelRouting.after_failure(
        m.route,
        %{ref: ref, same_ref_attempts: n, outcome: outcome},
        %{now_ms: H.now(w), random: 0}
      )

    log!(w, :after, %{
      run_id: run_id,
      action_id: id,
      ref: ref,
      n: n,
      outcome: summary(outcome),
      decision: decision
    })

    case decision do
      {:ok, :done} ->
        {:completed, body} = outcome
        usage!(ctx, c, ref, body.usage)
        B.outcome(id, "completed", "elzoo.ai-text.result", view(body))

      {:ok, {:retry_same, ms}} ->
        wait!(ctx, ms)
        attempt(ctx, tried, ref, n + 1)

      {:ok, {:next, cool_down}} when sent ->
        if cool_down, do: H.env(w, {:not_before, ref}, cool_down.not_before_ms)
        unknown_usage!(ctx, c, ref, n)
        {:refused, reason, meta} = outcome

        B.outcome(id, "failed", "elzoo.ai-text.result", %{
          "reason" => Atom.to_string(reason),
          "retry_after" => meta[:retry_after],
          "candidate" => ref
        })

      {:ok, {:next, _}} ->
        choose(ctx, tried ++ [ref])

      {:ok, {:stop, :unknown_outcome}} ->
        {:unknown, reason} = outcome
        unknown_usage!(ctx, c, ref, n)

        B.outcome(id, "unknown", "elzoo.ai-text.result", %{
          "reason" => Atom.to_string(reason),
          "candidate" => ref
        })

      {:ok, {:stop, why}} ->
        B.outcome(id, "refused", "elzoo.ai-text.result", %{
          "reason" => reason_text(outcome, why),
          "candidate" => ref
        })
    end
  end

  defp reason_text({_, reason, _}, _) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({_, reason}, _) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_, why), do: Atom.to_string(why)

  defp summary({:completed, _}), do: :completed
  defp summary(other), do: other

  # ai-text admission, then one owner on the application Repo; the outcome is what the sink got.
  defp send_one(ctx, c, ref, n) do
    %{w: w, run_id: run_id, id: id, request: request} = ctx
    key = "#{run_id}|#{id}|#{ref}|#{n}"
    payload = Jason.encode!(Map.put(request, "model", c.candidate.model_id))

    declaration = %{
      "capability_id" => "integration/ai-text",
      "operation" => "generate",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "m-" <> H.sha256(key),
        "schema_id" => "elzoo/ai-text-request",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "wave9", "port_id" => "models"},
        "idempotency_key" => key,
        "deadline_unix_ms" => H.now(w) + 120_000,
        "payload" => payload
      }
    }

    case AiText.admission(c.config, declaration) do
      {:error, {:refused, reason}} ->
        {{:not_admitted, reason}, false}

      {:ok, admission} ->
        log!(w, :intent, %{
          run_id: run_id,
          action_id: id,
          ref: ref,
          n: n,
          identity: admission.identity
        })

        pid = H.owner!(w, c.binding, admission, c.config)
        {:ok, :dispatched} = Elzoo.EffectIntent.advance(pid, :dispatch)
        H.settled(pid)

        case H.env(w, {:ai_out, admission.key}) do
          {:outcome, _attempt, outcome} -> {outcome, true}
          _ -> {{:unknown, :transport}, true}
        end
    end
  end

  # The local rate admission (`delivery/rate-limit`) of a Run that has a limiter.
  defp limit(%{e: %{limiter: nil}}), do: nil

  defp limit(%{w: w, e: e, run_id: run_id}) do
    state = H.env(w, {:limiter, run_id}) || e.limiter
    who = %{tenant: e.tenant, principal: e.principal}

    case RateLimit.admit(state, who, 1, H.now(w)) do
      {:ok, ticket, state} ->
        H.env(w, {:limiter, run_id}, state)
        ticket

      {:refused, reason, wait, _} when reason in [:tenant_rate, :principal_rate] ->
        {:rate_limited, wait}
    end
  end

  defp release(_, nil), do: :ok

  defp release(%{w: w, run_id: run_id}, ticket) do
    {:ok, state} = RateLimit.release(H.env(w, {:limiter, run_id}), ticket)
    H.env(w, {:limiter, run_id}, state)
  end

  # The wait of `{:retry_same, ms}` on the trusted (shared) clock: the binding waits until the
  # clock has moved by `ms`; the test moves it.
  defp wait!(%{w: w, run_id: run_id, id: id}, ms) do
    until = H.now(w) + ms
    H.env(w, {:waiting, run_id}, %{action_id: id, ms: ms, until: until})
    B.await!(fn -> H.now(w) >= until end)
    H.env(w, {:waiting, run_id}, nil)
  end

  defp view(body),
    do: %{
      "content" => body.content,
      "finish" => finish(body.finish),
      "tool_proposals" =>
        Enum.map(body.tool_proposals, fn p ->
          %{
            "id" => p.id,
            "name" => p.name,
            "arguments" => p.arguments,
            "malformed" => p.malformed && Atom.to_string(p.malformed)
          }
        end)
    }

  defp finish({:other, raw}), do: raw
  defp finish(f), do: Atom.to_string(f)

  # Metering: each provider-reported counter of a completed Attempt; one observation of unknown
  # amount for an Attempt that may have cost and reported nothing.
  defp usage!(ctx, c, ref, usage) do
    for %{unit: unit, amount: amount} <- usage.counters do
      observe!(ctx, c, ref, Atom.to_string(unit), unit, amount, usage.source)
    end
  end

  defp unknown_usage!(ctx, c, ref, n),
    do: observe!(ctx, c, ref, "attempt-#{n}", :output_tokens, :unknown, :unknown)

  defp observe!(%{w: w, run_id: run_id, id: id}, c, ref, tag, unit, amount, source) do
    observation = %{
      usage_id: "#{run_id}|#{id}|#{ref}|#{tag}",
      run_id: run_id,
      operation_id: "op-" <> run_id,
      attempt_id: id,
      provider_id: c.candidate.provider,
      model_id: c.candidate.model_id,
      unit: unit,
      amount: amount,
      source: if(amount == :unknown, do: :unknown, else: source),
      period: @period,
      observed_at_ms: H.now(w)
    }

    assert {:ok, :applied} = Metering.record(w.meter, @tenant, observation)
    log!(w, :observation, observation)
  end

  # ---- reads of the test

  @doc "Every binary value of every row of the four Store tables of each schema, as the owner."
  def store_bytes(schemas) do
    for s <- schemas,
        table <- ~w(elzoo_log_heads elzoo_log_records elzoo_checkpoints elzoo_outbox),
        row <- H.owner!("SELECT * FROM #{s}.#{table}"),
        value <- row,
        is_binary(value),
        do: value
  end

  def holds?(values, bytes), do: Enum.any?(values, &(:binary.match(&1, bytes) != :nomatch))

  def header(req, name), do: for({^name, v} <- req.headers, do: v)

  @doc "The documented Chat Completions request schema (ai-text-compatible's fixture, read only)."
  def chat_completions_schema do
    path =
      Path.expand(
        "../../pieces/integration/ai-text-compatible/test/fixtures/openai/chat_completions_request.schema.json",
        __DIR__
      )

    {:ok, root} = Elzoo.AiText.Schema.build(Jason.decode!(File.read!(path)))
    root
  end

  @doc """
  The Effect-intent streams in the intents Store, as the owner reads them, of a Run's model-call
  actions: each `{action_id, ref, n}` whose intent stream exists, for every candidate and
  Attempt number 1..4. It derives each key from the identity ai-text builds, not from the
  harness log.
  """
  def intent_streams(w, run_id, actions) do
    streams =
      MapSet.new(List.flatten(H.owner!("SELECT stream FROM #{w.intents_prefix}.elzoo_log_heads")))

    m = H.env(w, :models)

    for action <- actions,
        c <- route().candidates,
        n <- 1..4,
        {:ok, b} = Elzoo.AiText.Binding.load(m.candidates[c.ref].binding),
        identity = [
          @tenant,
          b.provider_account,
          b.id,
          b.operation,
          "#{run_id}|#{action}|#{c.ref}|#{n}"
        ],
        MapSet.member?(
          streams,
          Elzoo.EffectIntent.Model.stream(Elzoo.EffectIntent.Model.key(identity))
        ),
        do: {action, c.ref, n}
  end
end
