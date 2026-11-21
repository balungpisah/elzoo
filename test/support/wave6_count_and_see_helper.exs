Code.require_file(
  "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
  __DIR__
)

Code.require_file("../../pieces/workflow/eval/test/support/eval_helper.exs", __DIR__)
Code.require_file("../../pieces/state/artifact/test/support/artifact_test_helper.exs", __DIR__)

# The owner connection (elzoo_test, the non-superuser Store and audit owner): it creates the
# schemas, runs the migrations, grants, holds a row lock for the race and reads the audit log.
defmodule Elzoo.Wave6.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.Wave6.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Wave6.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner installs the four Piece-owned table sets.
  def up do
    p = :persistent_term.get({__MODULE__, :prefix})
    Elzoo.Metering.Migration.install(p)
    Elzoo.Quota.Migration.install(p)
    Elzoo.Journal.Migration.install(p)
    Elzoo.DeadLetterStore.Migration.install(p)
  end
end

defmodule Elzoo.Wave6.AuditMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.AuditLog.Migration.up(:persistent_term.get({__MODULE__, :opts}))
end

defmodule Elzoo.Wave6.CountHelper do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL

  alias Elzoo.{
    AuditLog,
    CheckedCommand,
    DeadLetterStore,
    Entitlement,
    Journal,
    Metering,
    PatternStep,
    PayloadSchema,
    Pricing,
    Quota,
    RunEngine,
    TenantIsolation
  }

  alias Elzoo.AiModel.Usage
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, TestMigration}
  alias Elzoo.RunEngine.{TestHelper, TestPattern}
  alias Elzoo.Wave6.{AppRepo, OwnerRepo}

  @now 1_800_000_000_000
  @period "2026-11"
  @app_name "elz323_app"
  @unit "output_tokens"
  @call_estimate 20_000
  @nested_estimate 25_000
  @limits %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  @units [:input_uncached_tokens, :output_tokens]

  def now, do: @now
  def period, do: @period

  # ------------------------------------------------------------ connections

  @doc "The fixed application role of ELZ-285; the test fails when it is unset or not a role name."
  def app_role! do
    role = System.get_env("ELZOO_TEST_APP_ROLE")

    if not (is_binary(role) and role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/),
      do: flunk("ELZOO_TEST_APP_ROLE must name the application role of ELZ-285; it is unset")

    role
  end

  def start_repos! do
    url = PostgresHarness.database_url!()
    role = app_role!()
    {:ok, pid} = OwnerRepo.start_link(url: url, pool_size: 4, log: false)
    Process.unlink(pid)
    :ok = PostgresHarness.reachable!(OwnerRepo)
    start_app!(role)
    role
  end

  def start_app!(role) do
    {:ok, pid} =
      AppRepo.start_link(
        url: PostgresHarness.database_url!(),
        pool_size: 10,
        log: false,
        parameters: [application_name: @app_name],
        after_connect: {Postgrex, :query!, [~s(SET ROLE "#{role}"), []]}
      )

    Process.unlink(pid)
    :ok = PostgresHarness.reachable!(AppRepo)
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
  The role facts of the application connection: its role, the session (owner) role, superuser,
  BYPASSRLS, and whether it holds the owner's privileges through inheritance.
  """
  def role_facts(repo) do
    [[current, session, super, bypass, inherits_owner]] =
      q!(
        repo,
        "SELECT current_user::text, session_user::text, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'USAGE') FROM pg_roles r WHERE r.rolname = current_user"
      )

    %{
      current: current,
      session: session,
      super: super,
      bypass: bypass,
      inherits_owner: inherits_owner
    }
  end

  @doc "Fails, never skips: the application connection must be the non-owner application role."
  def role_guard!(role) do
    facts = role_facts(AppRepo)

    if facts.current != role or facts.current == facts.session or facts.super or facts.bypass or
         facts.inherits_owner,
       do:
         flunk(
           "the application connection is not the non-owner application role: #{inspect(facts)}"
         )

    facts
  end

  @doc """
  The audit role attributes of `state/audit-log` as the owner reads them: the application
  role's TRUNCATE on any Store table, any privilege on the audit schema or its tables, Store
  table ownership; the audit owner of both definer functions and whether it is a superuser;
  and the pool of the audited Repo.
  """
  def audit_facts(fx, role) do
    [[truncate, owns, schema, tables, owner_super]] =
      owner!(
        """
        SELECT
          bool_or(has_table_privilege($1, c.oid, 'TRUNCATE')) FILTER (WHERE n.nspname = ANY($2)),
          bool_or(pg_get_userbyid(c.relowner) = $1) FILTER (WHERE n.nspname = ANY($2)),
          has_schema_privilege($1, $3, 'USAGE') OR has_schema_privilege($1, $3, 'CREATE'),
          coalesce(bool_or(has_table_privilege($1, c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')) FILTER (WHERE n.nspname = $3), false),
          (SELECT rolsuper FROM pg_roles WHERE rolname = session_user)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p') AND n.nspname IN ($3, $4, $5)
        """,
        [role, [fx.prefix, fx.aux], fx.audit, fx.prefix, fx.aux]
      )

    definers =
      owner!(
        """
        SELECT p.proname::text, p.prosecdef, pg_get_userbyid(p.proowner)::text, r.rolsuper
        FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND p.proname IN ('capture_changes', 'elzoo_attribute')
        ORDER BY 1
        """,
        [fx.audit]
      )

    %{
      app_truncate: truncate,
      app_owns_store_table: owns,
      app_audit_schema: schema,
      app_audit_tables: tables,
      owner_superuser: owner_super,
      definers: definers,
      pool: Keyword.get(Ecto.Adapter.lookup_meta(AppRepo).opts, :pool)
    }
  end

  # ------------------------------------------------------------ fixture

  @doc """
  A random schema with the Store tables, the metering, quota, journal and dead-letter tables
  and the `state/audit-log` migration over its `elzoo_log_records`; a second schema with
  unaudited Store tables for the jobs outbox and the eval artifact. Least privilege for the
  application role in these schemas only.
  """
  def fixture!(role) do
    hex = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    p = "wave6_" <> hex
    aux = p <> "_x"
    audit = p <> "_audit"

    for s <- [p, aux], do: owner!("CREATE SCHEMA #{s}")

    for s <- [p, aux],
        do: :ok = Ecto.Migrator.up(OwnerRepo, 1, TestMigration, prefix: s, log: false)

    :persistent_term.put({Elzoo.Wave6.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 2, Elzoo.Wave6.Migration, prefix: p, log: false)

    owner!("CREATE SCHEMA #{audit}")

    :persistent_term.put({Elzoo.Wave6.AuditMigration, :opts},
      store_prefix: p,
      carbonite_prefix: audit
    )

    :ok = Ecto.Migrator.up(OwnerRepo, 3, Elzoo.Wave6.AuditMigration, prefix: audit, log: false)

    for s <- [p, aux],
        sql <- [
          "GRANT USAGE ON SCHEMA #{s} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{s}.elzoo_log_heads, #{s}.elzoo_outbox TO #{role}",
          "GRANT SELECT, INSERT ON #{s}.elzoo_log_records, #{s}.elzoo_checkpoints TO #{role}"
        ],
        do: owner!(sql)

    for sql <- [
          "GRANT SELECT, INSERT ON #{p}.elzoo_metering_corrections TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_metering_observations TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_quota_counters, #{p}.elzoo_quota_reservations, #{p}.elzoo_quota_units TO #{role}",
          "GRANT SELECT, INSERT ON #{p}.elzoo_journal_operations, #{p}.elzoo_journal_postings TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_journal_accounts TO #{role}",
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{p}.elzoo_dead_letters TO #{role}"
        ],
        do: owner!(sql)

    %{
      prefix: p,
      aux: aux,
      audit: audit,
      role: role,
      store: store(p),
      meter: Metering.new(repo: AppRepo, prefix: p),
      quota: Quota.new(repo: AppRepo, prefix: p),
      journal: Journal.new(repo: AppRepo, prefix: p),
      dls: DeadLetterStore.new(repo: AppRepo, prefix: p),
      provider: provider!()
    }
  end

  def cleanup!(fx) do
    Agent.stop(fx.provider.usage)
    for s <- [fx.prefix, fx.aux, fx.audit], do: owner!("DROP SCHEMA IF EXISTS #{s} CASCADE")
  end

  @doc "The checked-command Store on the application connection; its writes must be bound."
  def store(prefix),
    do: Postgres.store(AppRepo, prefix: prefix, fold: command_fold(), limits: @limits)

  defp command_fold do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations: ["journal-credits", "spend-alerts"],
      reduce: fn model, _sequence, _kind, _payload -> model end
    }
  end

  @doc "The Store bound to one session attribution of `state/audit-log`."
  def bound(fx, actor, action, reason) do
    {:ok, bound} = AuditLog.bind(fx.store, %{actor: actor, action: action, reason: reason})
    bound
  end

  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)
  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows
  def owner!(sql, params \\ []), do: q!(OwnerRepo, sql, params)
  def as(scope, fun), do: TenantIsolation.transact(AppRepo, scope, fun)

  def denied?(result),
    do: match?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}, result)

  # ------------------------------------------------------------ the counting provider

  defp provider! do
    {:ok, usage} = Agent.start_link(fn -> %{} end)
    Process.unlink(usage)
    %{usage: usage, calls: :counters.new(1, [])}
  end

  def calls(fx), do: :counters.get(fx.provider.calls, 1)

  @doc "Usage of one completed call, as `integration/ai-model` validates it."
  def usage(input, output) do
    {:ok, usage} =
      Usage.validate(%{
        counters: [
          %{unit: :input_uncached_tokens, amount: input},
          %{unit: :output_tokens, amount: output}
        ],
        cache_writes: [],
        convention: %{input_includes_cached: false},
        source: :provider_reported
      })

    usage
  end

  # ------------------------------------------------------------ Runs

  def model_call(id), do: TestHelper.action(id, "model_call", %{"prompt" => id})
  def finish(source), do: TestHelper.finish_action("finish", %{"action_id" => source})
  def allow_gate, do: %{id: "host-gate", version: 1, call: fn _, _ -> :allow end}

  @features %{
    "model_call" => "model.chat",
    "tool_call" => "tools.web",
    "nested_callable" => "agents.nested",
    "finish" => nil
  }

  @doc """
  The counted gate (harness code, Q9 A): each action kind needs a feature of the tenant's
  current entitlement resolution, decided by `Elzoo.Entitlement.feature/2`.
  """
  def feature_gate(resolution) do
    call = fn checked, _context ->
      %{"actions" => [action]} = PatternStep.encode(checked)

      case Map.fetch(@features, action["kind"]) do
        {:ok, nil} ->
          :allow

        {:ok, feature} ->
          case Entitlement.feature(resolution, feature) do
            :allow -> :allow
            {:deny, reason} -> {:deny, Atom.to_string(reason)}
          end

        :error ->
          {:deny, "unmapped_action"}
      end
    end

    %{id: "entitlement-gate", version: 1, call: call}
  end

  @doc """
  Allocates a Run (the RunEngine fixture with its own Run owner and Unit store) without starting
  it. The host's Run key is the engine identity, unique per Run; the Budget cap is `cap`.
  """
  def prepare_run(tenant, requests, opts \\ []) do
    {nested, opts} = Keyword.pop(opts, :nested)
    cap = Keyword.get(opts, :cap, 50_000)

    overrides = [
      tenant: tenant,
      gate: Keyword.get(opts, :gate, allow_gate()),
      budget: %{cap: cap, unit: @unit, id: "budget", incarnation: "sealed"}
    ]

    {c, bindings} =
      if nested do
        TestHelper.nested_setup(
          nested,
          overrides ++
            [pattern: {TestPattern, :scripted, %{name: "root", script: requests}}]
        )
      else
        c = TestHelper.fixture(overrides ++ [pattern: {TestPattern, :step, %{requests: requests}}])
        {c, c.opts[:bindings]}
      end

    %{c: c, tenant: tenant, key: c.prefix, cap: cap, bindings: in_unit(bindings, tenant)}
  end

  # Every binding counts in the Budget unit; a model call estimates its share; an Effect
  # intent's identity names the Run's tenant.
  defp in_unit(bindings, tenant) do
    Map.new(bindings, fn {kind, binding} ->
      facts = fn action ->
        f = %{binding.facts.(action) | unit: @unit}

        f =
          case kind do
            "model_call" -> %{f | estimate: @call_estimate}
            "nested_callable" -> %{f | estimate: @nested_estimate}
            _ -> f
          end

        if f[:intent], do: update_in(f, [:intent, :identity], &[tenant | tl(&1)]), else: f
      end

      {kind, %{binding | facts: facts}}
    end)
  end

  def start_run(run) do
    engine = TestHelper.start(run.c, bindings: run.bindings, result_reader: reader(run.c))
    assert {:ok, :applied} = TestHelper.send_input(engine)
    Map.put(run, :engine, engine)
  end

  defp reader(c), do: %{evidence_store: c.evidence_store, retention_count: 1_024}

  @doc "The engine restarts over its own committed history; a dispatched call becomes unknown."
  def restart(run) do
    GenServer.stop(run.engine)
    Agent.update(run.c.host_mode, fn _ -> :recover end)
    Agent.update(run.c.clock, &(&1 + 500))
    engine = TestHelper.start(run.c, bindings: run.bindings, result_reader: reader(run.c))
    %{run | engine: engine}
  end

  def occurrence(run, action_id) do
    {occurrence, _} =
      Enum.find(TestHelper.view(run.engine).slots, fn {_, s} -> s.action_id == action_id end)

    occurrence
  end

  @doc "The provider takes the next dispatched call and returns no answer: the provider task."
  def take_call! do
    assert_receive {:effect_started, task, _request}, 10_000
    task
  end

  @doc """
  The counting scripted provider completes the next dispatched call of `run` with `usage`;
  the host routes the outcome with its output tokens as the actual and keeps the usage value.
  """
  def serve!(fx, run, action_id, usage) do
    task = take_call!()
    :counters.add(fx.provider.calls, 1, 1)
    Agent.update(fx.provider.usage, &Map.put(&1, {run.key, action_id}, usage))
    output = Usage.amount(usage, :output_tokens)

    assert {:ok, :applied} =
             RunEngine.input(
               run.engine,
               "result-" <> action_id,
               TestHelper.result(action_id),
               TestHelper.verified(%{
                 occurrence: occurrence(run, action_id),
                 actual: output,
                 dispatch: "dispatched"
               })
             )

    send(task, {:result, %{}})
    :ok
  end

  def transcript(run, tenant \\ nil),
    do:
      RunEngine.transcript(
        run.engine,
        %{tenant: tenant || run.tenant, principal: "principal", run_id: "run"},
        %{max_records: 65_536, max_bytes: 536_870_912}
      )

  def usage_id(run, {r, i}, attempt, unit), do: "#{run.key}/#{r}.#{i}/#{attempt}/#{unit}"

  @doc """
  The host meters a Run from its committed transcript: each settled model call gives one
  observation per unit, its `usage_id` derived from Run, occurrence and Attempt. A completed
  call takes the usage the provider returned; a call cut off by a restart is `:unknown`.
  Running it again replays: every observation already recorded is `:duplicate`.
  """
  def meter_run!(fx, run) do
    {:ok, %{entries: entries}} = transcript(run)
    actions = for %{type: :action} = a <- entries, into: %{}, do: {a.occurrence, a}
    usages = Agent.get(fx.provider.usage, & &1)

    for %{type: :settlement, outcome: outcome} = s <- entries,
        actions[s.occurrence].kind == "model_call",
        outcome in ["completed", "unknown"],
        unit <- @units do
      a = actions[s.occurrence]

      {amount, source} =
        case outcome do
          "completed" ->
            usage = Map.fetch!(usages, {run.key, s.action_id})
            {Usage.amount(usage, unit), usage.source}

          "unknown" ->
            {:unknown, :unknown}
        end

      observation = %{
        usage_id: usage_id(run, s.occurrence, a.attempt_id, unit),
        run_id: run.key,
        operation_id: s.action_id,
        attempt_id: a.attempt_id,
        provider_id: "scripted",
        model_id: "model-a",
        unit: unit,
        amount: amount,
        source: source,
        period: @period,
        observed_at_ms: @now + s.at_ms
      }

      {s.action_id, unit, Metering.record(fx.meter, run.tenant, observation)}
    end
  end

  @doc "The Run's committed actual: the root settlements' actuals, unknown if any is unknown."
  def committed_actual(run) do
    {:ok, %{entries: entries}} = transcript(run)
    actuals = for %{type: :settlement, path: []} = s <- entries, do: s.actual
    if :unknown in actuals, do: :unknown, else: Enum.sum(actuals)
  end

  # ------------------------------------------------------------ allowance

  def plan(features, amount) do
    plan = %{
      plan_id: "team",
      version: 1,
      features: features,
      allowances: [%{unit: :output_tokens, amount: amount, period_kind: :utc_month}]
    }

    {:ok, hash} = Entitlement.content_hash(plan)
    Map.put(plan, :content_hash, hash)
  end

  def grant(id, tenant, overrides \\ %{}),
    do:
      Map.merge(
        %{
          grant_id: id,
          tenant: tenant,
          plan_id: "team",
          version: 1,
          valid_from_ms: @now - 1_000,
          valid_to_ms: nil,
          grace_until_ms: nil,
          revoked_at_ms: nil
        },
        overrides
      )

  @doc """
  The host reserves a Run's estimate before it starts, keyed by the Run's own key, and returns
  the result with the estimate that becomes the Run's Budget cap.
  """
  def reserve(fx, tenant, run_key, estimate, resolution, now \\ @now) do
    Quota.reserve(fx.quota, tenant, %{
      run_id: run_key,
      window: {:period, @period},
      estimates: [%{unit: :output_tokens, amount: estimate}],
      expiry_ms: now + 600_000,
      now_ms: now,
      resolution: resolution
    })
  end

  def settle(fx, tenant, run_key, actual),
    do:
      Quota.settle(fx.quota, tenant, %{
        run_id: run_key,
        actuals: [%{unit: :output_tokens, actual: actual}]
      })

  def status(fx, tenant, resolution) do
    {:ok, [row]} =
      Quota.status(fx.quota, tenant, %{window: {:period, @period}, resolution: resolution})

    row
  end

  @doc "Another connection (the owner, under the tenant scope) holds a counter row's lock."
  def hold!(fx, tenant) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, :released} =
          TenantIsolation.transact(OwnerRepo, %{tenant: tenant}, fn ->
            [[1]] =
              q!(
                OwnerRepo,
                "SELECT 1 FROM #{fx.prefix}.elzoo_quota_counters WHERE tenant = $1 AND window_id = $2 AND unit = 'output_tokens' FOR UPDATE",
                [tenant, @period]
              )

            send(parent, {:holding, self()})
            receive do: (:release -> {:ok, :released})
          end)

        send(parent, {:released, self()})
      end)

    receive do
      {:holding, ^pid} -> pid
    after
      10_000 -> flunk("the lock holder did not take the row lock")
    end
  end

  def release!(pid) do
    send(pid, :release)

    receive do
      {:released, ^pid} -> :ok
    after
      10_000 -> flunk("the lock holder did not release")
    end
  end

  @doc "Wait until exactly `n` application backends wait for a lock."
  def await_waiting!(n, tries \\ 1_000) do
    [[count]] =
      owner!(
        "SELECT count(DISTINCT l.pid) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE NOT l.granted AND a.application_name = $1",
        [@app_name]
      )

    cond do
      count == n ->
        :ok

      tries == 0 ->
        flunk("expected #{n} waiting backends, saw #{count}")

      true ->
        Process.sleep(10)
        await_waiting!(n, tries - 1)
    end
  end

  # ------------------------------------------------------------ price and post

  def eur do
    {:ok, eur} = Elzoo.Money.parse("EUR")
    eur
  end

  @doc "A `:price` card version: one currency, exact decimal rates, a required rounding."
  def card(version, input_rate, output_rate) do
    line = fn unit, rate ->
      %{
        provider_id: "scripted",
        model_id: "model-a",
        unit: unit,
        rate: rate,
        per: 1_000_000,
        minimum: nil
      }
    end

    body = %{
      card_id: "retail",
      version: version,
      kind: :price,
      currency: eur(),
      rounding: :half_even,
      lines: [line.(:input_uncached_tokens, input_rate), line.(:output_tokens, output_rate)]
    }

    {:ok, hash} = Pricing.content_hash(body)
    Map.put(body, :content_hash, hash)
  end

  @doc "The `domain/pricing` usage value of one tenant's period, from `model_totals/3`."
  def usage_value(fx, tenant) do
    {:ok, rows} = Metering.model_totals(fx.meter, tenant, %{period: @period, max_rows: 100})
    %{tenant: tenant, period: @period, rows: rows}
  end

  def open_accounts!(fx, tenant, accounts) do
    for {id, allow_negative} <- accounts do
      assert {:ok, :applied} =
               Journal.open_account(fx.journal, tenant, %{
                 account_id: id,
                 currency: eur(),
                 allow_negative: allow_negative
               })
    end
  end

  def money(minor) do
    {:ok, amount} = Elzoo.Money.from_minor_units(eur(), minor)
    amount
  end

  @doc "One balanced operation of two postings: `amount` to `debit`, its negation to `credit`."
  def transfer(fx, tenant, operation_id, reason, debit, credit, %Elzoo.Money.Amount{} = amount) do
    {:ok, minus} = Elzoo.Money.negate(amount)

    Journal.post(fx.journal, tenant, %{
      operation_id: operation_id,
      actor_ref: "svc:billing",
      reason: reason,
      postings: [%{account_id: debit, amount: amount}, %{account_id: credit, amount: minus}]
    })
  end

  def balance(fx, tenant, account) do
    {:ok, %Elzoo.Money.Amount{minor_units: minor}} = Journal.balance(fx.journal, tenant, account)
    minor
  end

  def history(fx, tenant, account) do
    {:ok, %{entries: entries}} =
      Journal.history(fx.journal, tenant, %{account_id: account, after: nil, limit: 1_000})

    entries
  end

  # ------------------------------------------------------------ identity and membership

  @now_s div(@now, 1_000)

  @doc """
  Principals from `integration/token-verify` API keys generated in the test: the host stores
  HMAC-SHA-256(digest key, secret) per key ID. Returns each principal, verified from its key.
  """
  def principals!(people) do
    digest_key = :crypto.strong_rand_bytes(32)

    entries =
      for {{id, tenant}, n} <- Enum.with_index(people), into: %{} do
        key_id = "key#{n}" <> Base.encode16(:crypto.strong_rand_bytes(4))
        secret = :crypto.strong_rand_bytes(32)

        fields = %{
          kind: :human,
          id: id,
          tenant: tenant,
          allowed_scopes: [],
          allowed_spaces: [],
          auth_epoch: 1
        }

        {key_id,
         %{
           key: "ek_" <> key_id <> "_" <> Base.url_encode64(secret, padding: false),
           digest: :crypto.mac(:hmac, :sha256, digest_key, secret),
           fields: fields
         }}
      end

    config =
      Elzoo.TokenVerify.api_key_config(
        prefix: "ek",
        digest_key: fn ->
          {:ok,
           %Elzoo.Secrets.Credential{
             value: digest_key,
             version: 1,
             expires_at_unix_ms: (@now_s + 3_600) * 1_000
           }}
        end,
        lookup: fn key_id ->
          case Map.fetch(entries, key_id) do
            {:ok, e} ->
              {:ok,
               %{
                 digest: e.digest,
                 principal: e.fields,
                 current_epoch: 1,
                 expires_at_unix_s: nil,
                 revoked: false
               }}

            :error ->
              {:error, :not_found}
          end
        end
      )

    for {_, e} <- entries, into: %{} do
      assert {:ok, %Elzoo.Principal{} = principal} =
               Elzoo.TokenVerify.verify_api_key(e.key, config, @now_s)

      {e.fields.id, principal}
    end
  end

  @doc "The host's membership facts: one space per tenant and the billing roles."
  def membership_facts(memberships) do
    %{
      spaces: [
        %{id: "t1-home", tenant: "T1", parent: nil, block_inheritance: false},
        %{id: "t2-home", tenant: "T2", parent: nil, block_inheritance: false}
      ],
      roles: [
        %{id: "billing-admin", permissions: ["billing.credit", "billing.grant"]},
        %{id: "finance", permissions: ["billing.credit"]},
        %{id: "support", permissions: ["billing.read"]}
      ],
      memberships:
        Enum.map(memberships, fn {principal, space, role} ->
          %{
            principal: principal,
            space: space,
            role: role,
            valid_from: @now_s - 100,
            valid_to: nil,
            revoked_at: nil
          }
        end),
      non_inheriting: []
    }
  end

  @doc """
  The host's authorization verdict for a command: ALLOW only when the principal's membership
  gives the permission at the tenant's space; any refusal of `permissions/4` is DENY.
  """
  def verdict(principal, space, permission, facts) do
    case Elzoo.Membership.permissions(principal, space, facts, @now_s) do
      {:ok, permissions} -> if permission in permissions, do: :allow, else: :deny
      {:error, _} -> :deny
    end
  end

  def now_s, do: @now_s

  # ------------------------------------------------------------ checked commands

  @port_base %{"direction" => "input", "schema_version" => 1}

  defp descriptor(id, class, properties, prepare, outbox) do
    port = Map.merge(@port_base, %{"id" => id, "schema_id" => id})

    {:ok, schema} =
      PayloadSchema.build(port, %{
        "type" => "object",
        "required" => Map.keys(properties),
        "additionalProperties" => false,
        "properties" => properties
      })

    %{
      id: id,
      version: 1,
      content_hash: :crypto.hash(:sha256, "wave6-count-and-see/" <> id),
      effect_class: class,
      port: port,
      schema: schema,
      prepare: prepare,
      gate: %{call: fn _frame, _context -> :allow end},
      approval: %{verifiers: ["command-reviewer"], max_age: 60_000},
      outbox: outbox
    }
  end

  @doc "The allowance grant: writes the host's plan grant into the command's resource."
  def grant_descriptor,
    do:
      descriptor(
        "allowance/grant",
        "allowance",
        %{
          "grant_id" => %{"type" => "string"},
          "plan_id" => %{"type" => "string"},
          "version" => %{"type" => "integer"},
          "valid_from_ms" => %{"type" => "integer"}
        },
        &grant_prepare/3,
        nil
      )

  def grant_prepare(snapshot, %{payload: p}, _facts) do
    writes =
      for {field, value} <- [
            {"grant_id", {:text, p["grant_id"]}},
            {"plan_id", {:text, p["plan_id"]}},
            {"version", p["version"]},
            {"valid_from_ms", p["valid_from_ms"]}
          ],
          do: %{target: snapshot.resource, field: field, value: value}

    {:ok, writes, {:record, [{"revision", snapshot.revision + 1}]}}
  end

  @doc "The manual credit: the command commits its outcome and one outbox item; no effect."
  def credit_descriptor,
    do:
      descriptor(
        "journal/credit",
        "credit",
        %{"account_id" => %{"type" => "string"}, "minor_units" => %{"type" => "integer"}},
        &credit_prepare/3,
        "journal-credits"
      )

  def credit_prepare(snapshot, %{payload: p}, _facts) do
    {:ok,
     [
       %{target: snapshot.resource, field: "account_id", value: {:text, p["account_id"]}},
       %{target: snapshot.resource, field: "minor_units", value: p["minor_units"]}
     ], {:record, [{"revision", snapshot.revision + 1}]}}
  end

  @doc "The spend-alert notice: one outbox item per crossing."
  def alert_descriptor,
    do:
      descriptor(
        "spend-alert/notice",
        "alert",
        %{"period" => %{"type" => "string"}, "threshold" => %{"type" => "integer"}},
        &alert_prepare/3,
        "spend-alerts"
      )

  def alert_prepare(snapshot, %{payload: p}, _facts) do
    {:ok,
     [
       %{target: snapshot.resource, field: "period", value: {:text, p["period"]}},
       %{target: snapshot.resource, field: "threshold", value: p["threshold"]}
     ], {:record, [{"revision", snapshot.revision + 1}]}}
  end

  def handle(store, descriptor) do
    {:ok, handle} = CheckedCommand.new(store, descriptor)
    handle
  end

  def scope(tenant, actor, resources), do: %{tenant: tenant, actor: actor, resources: resources}

  def policy(class, verdict) do
    artifact = %{
      id: "policy-" <> class,
      version: 1,
      effect_classes: [class],
      rules: [%{id: "rule-" <> class, effect_class: class, verdict: verdict}]
    }

    Map.put(artifact, :content_hash, :crypto.hash(:sha256, :erlang.term_to_binary(artifact)))
  end

  @doc """
  The host's command: the bound Store of the actor's session, a read of the resource, exact
  authority for the writes the command prepares over it, then execute. `expected_revision`
  defaults to the read revision.
  """
  def command(fx, descriptor, tenant, actor, operation_id, resource, payload, opts \\ []) do
    store = bound(fx, actor, descriptor.id, Keyword.get(opts, :reason, "host command"))
    handle = handle(store, descriptor)
    {:ok, snapshot} = CheckedCommand.resource(handle, scope(tenant, actor, [resource]), resource)

    request = %{
      operation_id: operation_id,
      resource: resource,
      expected_revision: Keyword.get(opts, :expected_revision, snapshot.revision),
      payload: payload
    }

    facts = %{tenant: tenant, actor: actor, data: {:record, []}}

    own =
      case descriptor.prepare.(snapshot, request, facts) do
        {:ok, writes, _} -> writes
        {:refused, _} -> []
      end

    context = %{
      tenant: tenant,
      actor: actor,
      policy: policy(descriptor.effect_class, Keyword.get(opts, :verdict, :allow)),
      own: own,
      parent: :none,
      facts: {:record, []}
    }

    CheckedCommand.execute(handle, context, request)
  end

  def resource(fx, descriptor, tenant, actor, id) do
    {:ok, resource} =
      CheckedCommand.resource(handle(fx.store, descriptor), scope(tenant, actor, [id]), id)

    resource
  end

  @doc "The grant fact that `Elzoo.Entitlement.resolve/3` reads, from the command's resource."
  def grants_from(_tenant, %{fields: fields}) when map_size(fields) == 0, do: []

  def grants_from(tenant, %{fields: f}) do
    {:text, grant_id} = f["grant_id"]
    {:text, plan_id} = f["plan_id"]

    [
      grant(grant_id, tenant, %{
        plan_id: plan_id,
        version: f["version"],
        valid_from_ms: f["valid_from_ms"]
      })
    ]
  end

  def stream(tenant),
    do:
      "cc1:" <>
        Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
          padding: false
        )

  def pending(fx, tenant, destination) do
    {:ok, items} = Elzoo.Outbox.pending(fx.store, stream(tenant), 64)
    Enum.filter(items, &(&1.destination == destination))
  end

  @doc """
  The host's apply of committed credits: each pending credit item posts once with
  `Elzoo.Journal.post/3`, reusing the command's `operation_id` as the journal operation ID,
  then is acknowledged. `crash: :after_post` stops before the acknowledgement.
  """
  def apply_credits(fx, tenant, opts \\ []) do
    for item <- pending(fx, tenant, "journal-credits") do
      %{"operation_id" => op, "resource" => id, "actor" => actor} = Jason.decode!(item.payload)
      %{fields: f} = resource(fx, credit_descriptor(), tenant, actor, id)
      {:text, account} = f["account_id"]

      result =
        transfer(
          fx,
          tenant,
          op,
          "manual credit",
          account,
          "credits-granted",
          money(f["minor_units"])
        )

      if Keyword.get(opts, :crash) == :after_post, do: raise("crash between post and ack")
      assert {:committed, _} = Elzoo.Outbox.ack(fx.store, item.idempotency_key, item.nonce)
      {op, result}
    end
  end

  def log_records(fx, tenant),
    do:
      hd(
        hd(
          owner!("SELECT count(*) FROM #{fx.prefix}.elzoo_log_records WHERE stream = $1", [
            stream(tenant)
          ])
        )
      )

  # ------------------------------------------------------------ failures

  @jobs_fold %{
    initial: 0,
    kinds: %{"event" => :state_bearing},
    versions: [1],
    destinations: ["jobs"],
    reduce: &__MODULE__.count_fold/4
  }
  @jobs_limits %{max_record_bytes: 1024, max_batch_size: 4, max_checkpoint_bytes: 10_000}
  def count_fold(n, _, _, _), do: n + 1

  @doc "An outbox stream of `n` items `item-1`..`item-n` in the PostgreSQL Store, as the app role."
  def jobs_outbox!(fx, n) do
    store = Postgres.store(AppRepo, prefix: fx.aux, fold: @jobs_fold, limits: @jobs_limits)

    {:ok, w} =
      Elzoo.DurableLog.Writer.start_link(
        store: store,
        stream: "jobs/r",
        fold: @jobs_fold,
        limits: @jobs_limits
      )

    for i <- 1..n,
        do:
          {:committed, ^i} =
            Elzoo.DurableLog.Writer.append(w, [{"event", 1, "e"}], [{"jobs", "item-#{i}"}])

    GenServer.stop(w)
    store
  end

  def jobs_pending(store) do
    {:ok, items} = Elzoo.Outbox.pending(store, "jobs/r", 100)
    Enum.map(items, & &1.payload)
  end

  def failure_record(id),
    do: %{
      "version" => 1,
      "message_id" => id,
      "correlation_id" => id,
      "attempts" => 3,
      "reason" => "permanent"
    }

  # ------------------------------------------------------------ eval (Q7 A)

  def artifact!(fx) do
    store =
      Postgres.store(AppRepo,
        prefix: fx.aux,
        fold: Elzoo.Artifact.TestHelper.fold(),
        limits: Elzoo.Artifact.TestHelper.limits()
      )

    if not Elzoo.Artifact.TestHelper.s3?(),
      do: flunk("the disposable S3 test server (ELZOO_TEST_S3_*) is required; it is not set")

    {:ok, art} =
      Elzoo.Artifact.new(
        store: store,
        object_store: Elzoo.Artifact.TestHelper.config!(),
        max_bytes: 1_048_576
      )

    art
  end

  defp typed(direction),
    do: %{
      "port" => %{
        "id" => direction,
        "direction" => direction,
        "schema_id" => "value",
        "schema_version" => 1
      },
      "schema" => %{"type" => "object"}
    }

  defp callable(name, kind, extra),
    do:
      Map.merge(
        %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")},
        extra
      )

  defp slot(name), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

  defp node(id, kind, needs, gives, extra),
    do:
      Map.merge(
        %{
          "id" => id,
          "kind" => kind,
          "needs" => Enum.map(needs, &slot/1),
          "gives" => Enum.map(gives, &slot/1)
        },
        extra
      )

  defp ordered(value) when is_map(value),
    do: %Jason.OrderedObject{values: for({k, v} <- Enum.sort(value), do: {k, ordered(v)})}

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp package(graph) do
    package = %{
      "format_version" => 1,
      "name" => "package",
      "version" => "opaque",
      "needs" => [],
      "permissions" => [],
      "graph" => graph,
      "settings" => %{
        "version" => 1,
        "id" => "independent-settings",
        "revision" => 1,
        "port" => typed("input")["port"],
        "secrets" => [],
        "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      "skills" => []
    }

    hash = :crypto.hash(:sha256, Jason.encode!(ordered(package)))
    Map.put(package, "identity", "recipe-package-v1:sha256:" <> Base.encode16(hash, case: :lower))
  end

  @doc """
  A recipe-test base spec: a graph root with an agent child, a decision child and one tool
  node per choice. `swap: true` is the changed package: each choice leads to the other node.
  """
  def eval_base(opts \\ []) do
    {yes, no} = if Keyword.get(opts, :swap, false), do: {"t_no", "t_yes"}, else: {"t_yes", "t_no"}

    data = fn from, give, to, need ->
      %{"from" => from, "to" => to, "kind" => "data", "give" => give, "need" => need}
    end

    choice = fn from, to, name ->
      %{"from" => from, "to" => to, "kind" => "choice", "choice" => name}
    end

    main =
      callable("main", "graph", %{
        "nodes" => [
          node("a", "call", ["x"], ["text"], %{"callable" => "agent"}),
          node("d", "decision", ["text"], ["value"], %{"callable" => "choice"}),
          node("t_yes", "tool", [], ["yes_result"], %{"tool" => "files_read"}),
          node("t_no", "tool", [], ["no_result"], %{"tool" => "files_read"})
        ],
        "links" => [
          data.("$input", "x", "a", "x"),
          data.("a", "text", "d", "text"),
          choice.("d", yes, "yes"),
          choice.("d", no, "no")
        ],
        "input_slots" => [slot("x")]
      })

    graph = %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 1,
      "root" => "main",
      "callables" => [
        main,
        callable("agent", "agent", %{"binding" => "worker"}),
        callable("choice", "decision", %{"binding" => "judge", "choices" => ["yes", "no"]})
      ],
      "bindings" => [
        %{"name" => "worker", "target" => "agent-config"},
        %{"name" => "judge", "target" => "decision-config"}
      ],
      "rules" => []
    }

    cost = fn callable, extra -> Map.merge(%{"callable" => callable}, extra) end

    %{
      package: package(graph),
      facts: %{
        "provided_needs" => [],
        "granted_permissions" => [],
        "tool_requirements" => %{},
        "unit" => "credits",
        "costs" => [
          cost.("agent", %{"estimate" => 5}),
          cost.("choice", %{"estimate" => 3}),
          cost.("main", %{"node" => "t_yes", "estimate" => 2}),
          cost.("main", %{"node" => "t_no", "estimate" => 2})
        ],
        "cap" => 1_000
      },
      sources: [
        %{
          "id" => "files",
          "kind" => "other",
          "callable" => "adapter",
          "tools" => [
            %{
              "trust" => "untrusted",
              "name" => "read",
              "description" => "Tool read",
              "input_schema" => %{"type" => "object"},
              "annotations" => nil
            }
          ]
        }
      ],
      agents: %{
        "agent-config" => %{
          model: "scripted-model",
          max_output_tokens: 256,
          role_instructions: ["Answer."],
          window: %{
            provider_id: "scripted",
            model_id: "scripted-model",
            size: 100_000,
            unit: :tokens,
            estimator_id: "recipe-test-bytes",
            estimator_version: 1
          },
          max_request_bytes: 65_536,
          max_image_refs: 0,
          result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
          turn_limit: 4
        }
      },
      decisions: %{
        "decision-config" => %{
          request: %{
            "version" => 1,
            "model" => "scripted-decider",
            "max_output_tokens" => 32,
            "messages" => [%{"role" => "user", "text" => "Pick one."}]
          },
          repairs: 1
        }
      },
      effects: %{model: Elzoo.RecipeTest.ModelBinding, tool: Elzoo.RecipeTest.ToolBinding},
      adapters: [Elzoo.RecipeTest.ScriptedAdapter],
      tools: %{},
      executable: nil,
      skills: nil,
      gate: nil
    }
  end

  @doc "A dataset version 1, JSON as an author writes it: one case that picks `yes`."
  def eval_dataset do
    completed = fn value -> %{"class" => "completed", "value" => value} end
    answer = completed.(%{"content" => "hello", "finish" => "stop", "tool_proposals" => []})

    decided =
      completed.(%{
        "content" => Jason.encode!(%{"answer" => "yes"}),
        "finish" => "stop",
        "tool_proposals" => [],
        "structured" => %{"valid" => %{"answer" => "yes"}}
      })

    Jason.encode!(%{
      "format_version" => 1,
      "dataset_id" => "wave6-eval",
      "version" => 1,
      "cases" => [
        %{
          "case_id" => "chooses-yes",
          "input" => %{"x" => "hi"},
          "restart_after" => nil,
          "script" => [
            %{"key" => %{"model" => "scripted-model"}, "results" => [answer]},
            %{"key" => %{"model" => "scripted-decider"}, "results" => [decided]},
            %{
              "key" => %{"tool" => "files_read"},
              "results" => [completed.(%{"yes_result" => "r", "no_result" => "r"})]
            }
          ],
          "checks" => [
            %{"kind" => "outcome_is", "outcome" => "completed"},
            %{
              "kind" => "structured_matches",
              "schema" => %{
                "type" => "object",
                "required" => ["status", "gives"],
                "properties" => %{
                  "status" => %{"const" => "completed"},
                  "gives" => %{"type" => "object", "required" => ["yes_result"]}
                }
              }
            },
            %{"kind" => "tool_called", "alias" => "files_read", "at_least" => 1}
          ]
        }
      ]
    })
  end
end
