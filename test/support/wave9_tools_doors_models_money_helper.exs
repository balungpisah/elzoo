for file <- [
      "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
      "../../pieces/state/recipe-store/test/support/recipe_store_test_helper.exs"
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
