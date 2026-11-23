for file <- [
      "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
      "../../pieces/state/recipe-store/test/support/recipe_store_test_helper.exs"
    ],
    do: Code.require_file(file, __DIR__)

# ELZ-349 harness: the Repos, the consumer migrations, the per-tenant engine hosts (one Run owner
# per tenant, a Unit directory that routes each Unit's offers to its own engine), the scripted
# host process (model calls, tool calls, posts and notices), the bot, decision and child
# callables, the child-start binding and the parent-close application of the Wave 8 root
# acceptance. Harness code, not a Piece.

# The owner connection (elzoo_test, not a superuser): schemas, installs, grants, catalog reads and
# the unprotected Store tables.
defmodule Elzoo.Wave8.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.Wave8.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The consumer migration of the shared schema: one mailbox install and one work-item install.
defmodule Elzoo.Wave8.Migration do
  @moduledoc false
  use Ecto.Migration

  def up do
    Elzoo.DurableMailbox.Migration.install(prefix())
    Elzoo.WorkItem.Migration.install(prefix())
  end
end

defmodule Elzoo.Wave8.StoreMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
end

defmodule Elzoo.Wave8.Lock do
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

defmodule Elzoo.Wave8.Bot do
  @moduledoc """
  The agent-loop finish wrapper (harness code): the nested callable of one bot turn. It steps a
  `workflow/agent-loop` state whose spec `id` is the turn ID, keeps the content of each completed
  model call, and turns the agent loop's finish into an `elzoo.room.answer` finish: on
  `answered`, the JSON object in the content of the model call that the finish names; on
  `stopped`, the fixed no-answer.
  """
  alias Elzoo.AgentLoop

  @no_answer %{"text" => "[no answer]", "mentions" => [], "handoff_to" => nil, "escalate" => false}

  def no_answer, do: @no_answer

  def step(%{inner: inner, contents: contents} = state, input) do
    contents =
      case input do
        %{
          "kind" => "action_outcome",
          "outcome" => "completed",
          "schema_id" => "elzoo.ai-text.result",
          "action_id" => id,
          "payload" => %{"content" => text}
        }
        when is_binary(text) ->
          Map.put(contents, id, text)

        _ ->
          contents
      end

    {:Transition, next, out} = AgentLoop.step(inner, input, &estimate/1)
    state = %{state | inner: next, contents: contents}
    {:Transition, state, convert(out, contents)}
  end

  defp convert({:some, %{"actions" => actions} = request}, contents),
    do: {:some, %{request | "actions" => Enum.map(actions, &answer(&1, contents))}}

  defp convert(out, _), do: out

  defp answer(%{"kind" => "finish", "schema_id" => "elzoo.agent-loop.result"} = action, contents) do
    payload =
      case action["payload"] do
        %{"status" => "answered", "action_id" => id} ->
          case Jason.decode(Map.get(contents, id, "")) do
            {:ok, %{} = answer} -> answer
            _ -> @no_answer
          end

        _ ->
          @no_answer
      end

    %{action | "schema_id" => "elzoo.room.answer", "schema_version" => 1, "payload" => payload}
  end

  defp answer(action, _), do: action

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

defmodule Elzoo.Wave8.Agent do
  @moduledoc "The root callable of an agent-loop child Run (C): the agent loop with the estimate."
  def step(state, input), do: Elzoo.AgentLoop.step(state, input, &Elzoo.Wave8.Bot.estimate/1)
end

defmodule Elzoo.Wave8.Child do
  @moduledoc """
  The harness child patterns of the parent-close cases. Each asks one `local_work` action `w1`
  at its start; `hold` makes that work wait for `:release`. After the outcome, a `wait` child
  stays idle until an `elzoo.delegation.cancel_requested` message; the others finish at once.
  The finish names `w1`, as the engine requires for a completed Run.
  """
  def step(%{phase: :new} = s, %{"kind" => "start"}) do
    action = %{
      "id" => "w1",
      "kind" => "local_work",
      "schema_id" => "elzoo.wave8.work",
      "schema_version" => 1,
      "payload" => %{"hold" => s.hold, "child" => s.name}
    }

    {:Transition, %{s | phase: :working}, request([action])}
  end

  def step(%{phase: :working} = s, %{
        "kind" => "action_outcome",
        "action_id" => "w1",
        "outcome" => "completed"
      }) do
    if s.wait, do: {:Transition, %{s | phase: :idle}, :none}, else: finish(s)
  end

  def step(%{phase: :idle} = s, %{
        "kind" => "message",
        "schema_id" => "elzoo.delegation.cancel_requested"
      }),
      do: finish(s)

  def step(s, _), do: {:Transition, s, :none}

  defp finish(s) do
    action = %{
      "id" => "done",
      "kind" => "finish",
      "schema_id" => "elzoo.wave8.child-result",
      "schema_version" => 1,
      "payload" => %{"action_id" => "w1"}
    }

    {:Transition, %{s | phase: :done}, request([action])}
  end

  defp request(actions), do: {:some, %{"type" => "request", "version" => 1, "actions" => actions}}

  # The held work tells the host and waits; the carry binding echoes its payload.
  def work(%{"hold" => true} = payload) do
    if host = Process.whereis(Elzoo.Wave8.Host), do: send(host, {:held_work, self(), payload})
    receive do: (:release -> payload)
  end

  def work(payload), do: payload
  def echo(payload), do: payload
end

defmodule Elzoo.Wave8.Host do
  @moduledoc """
  The scripted host: the adapter context of every Effect. A model call takes the script entry
  of `{label, action_id}`, else the next queued entry of `{label, member}`; `:hold` keeps it
  until `release/3`. Tool calls, posts and notices go to `Elzoo.Wave8.Helper`. Every outcome
  reaches its engine through `input/4`, as an Adapter sink does.
  """
  use GenServer
  alias Elzoo.Wave8.Helper, as: H

  def start, do: GenServer.start(__MODULE__, nil, name: __MODULE__)
  def world(w), do: GenServer.call(__MODULE__, {:world, w})
  def sync, do: GenServer.call(__MODULE__, :sync, 120_000)
  def get, do: GenServer.call(__MODULE__, :get, 120_000)
  def script(key, value), do: GenServer.call(__MODULE__, {:script, key, value})
  def queue(key, values), do: GenServer.call(__MODULE__, {:queue, key, values})
  def release(key, value \\ nil), do: GenServer.call(__MODULE__, {:release, key, value}, 120_000)
  def release_work(child), do: GenServer.call(__MODULE__, {:release_work, child}, 120_000)

  @impl true
  def init(_),
    do:
      {:ok,
       %{
         w: nil,
         script: %{},
         queues: %{},
         held: %{},
         work: %{},
         posts: [],
         notices: [],
         errors: [],
         refusals: [],
         calls: []
       }}

  @impl true
  def handle_call({:world, w}, _, s), do: {:reply, :ok, %{s | w: w}}
  def handle_call(:sync, _, s), do: {:reply, :ok, s}
  def handle_call(:get, _, s), do: {:reply, s, s}

  def handle_call({:script, key, value}, _, s),
    do: {:reply, :ok, put_in(s.script[key], value)}

  def handle_call({:queue, key, values}, _, s),
    do: {:reply, :ok, update_in(s.queues, &Map.update(&1, key, values, fn q -> q ++ values end))}

  def handle_call({:release, key, value}, _, s) do
    case Map.pop(s.held, key) do
      {nil, _} ->
        {:reply, {:error, :not_held}, s}

      {held, rest} ->
        s = %{s | held: rest}
        value = value || pop_answer(s, held)
        {:reply, :ok, H.answer_model(s, held, value)}
    end
  end

  def handle_call({:release_work, child}, _, s) do
    case Map.pop(s.work, child) do
      {nil, _} ->
        {:reply, {:error, :not_held}, s}

      {pid, rest} ->
        send(pid, :release)
        {:reply, :ok, %{s | work: rest}}
    end
  end

  defp pop_answer(_s, %{value: value}) when value != :hold, do: value
  defp pop_answer(_s, _), do: raise("a held call needs a value at release")

  @impl true
  def handle_info({:effect_started, task, request}, s) do
    {:noreply, H.effect(s, task, Jason.decode!(request.arguments))}
  rescue
    e ->
      {:noreply,
       %{s | errors: s.errors ++ [{:effect, Exception.format(:error, e, __STACKTRACE__)}]}}
  end

  def handle_info({:held_work, pid, payload}, s),
    do: {:noreply, put_in(s.work[payload["child"]], pid)}

  def handle_info(_, s), do: {:noreply, s}
end

defmodule Elzoo.Wave8.Helper do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL

  alias Elzoo.{
    Artifact,
    Delegation,
    DurableMailbox,
    DynamicUnits,
    Lease,
    PayloadSchema,
    Principal,
    RecipeStore,
    Room,
    RunEngine,
    TenantIsolation,
    TurnPolicy,
    TypedDecision,
    UntrustedContent,
    VersionPin,
    WorkItem
  }

  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, Writer}
  alias Elzoo.EffectIntent.{Binding, StoreHost}
  alias Elzoo.RecipeStore.TestHelper, as: RS
  alias Elzoo.Wave8.{AppRepo, Host, Lock, OwnerRepo}

  @engines Elzoo.Wave8.EngineRegistry
  @units Elzoo.Wave8.UnitRegistry
  @tenants ~w(T1 T2)

  # Slot deadlines after admission, by the shared test clock (ms). The child-start tool calls
  # have the shortest, so the parent-close wake settles them before any turn or model call.
  @tool_ms 20_000
  @effect_ms 100_000
  @turn_ms 200_000
  @run_ms 1_000_000
  @margin_ms 1_000

  # The bot recipes, as the script bounds them: each agent loop has turn_limit 3, and a scripted
  # model result proposes at most 4 tool calls; each proposal may need one store action. A
  # typed decision has one repair.
  @turn_limit 3
  @max_proposals 4
  @repairs 1

  def turn_limit, do: @turn_limit
  def max_proposals, do: @max_proposals
  def tool_ms, do: @tool_ms
  def turn_ms, do: @turn_ms
  def margin_ms, do: @margin_ms

  @doc """
  The declared reserve (Q8 A), derived from the bot specs. One turn: `turn_limit` model calls,
  at most `max_proposals` tool calls and as many store actions after each of the first
  `turn_limit - 1` model results, and the finish; its requests are the model calls, one tool
  request and one store request per tool turn, and the finish. One decision: `repairs + 1`
  model calls and the finish, one request each.
  """
  def reserve do
    l = @turn_limit
    p = @max_proposals

    %{
      turn: %{actions: l + 2 * p * (l - 1) + 1, requests: l + 2 * (l - 1) + 1},
      decision: %{actions: @repairs + 2, requests: @repairs + 2},
      deadline_margin_ms: @margin_ms
    }
  end

  # ------------------------------------------------------------ connections (from ELZ-338)

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
    base = [url: url, log: false]

    for {repo, extra} <- [
          {OwnerRepo, [pool_size: 4]},
          {AppRepo,
           [pool_size: 16, after_connect: {Postgrex, :query!, [~s(SET ROLE "#{role}"), []]}]}
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
  LOGIN, INHERIT, CREATEROLE, CREATEDB, and whether it is a member of the session role (direct
  or indirect, with or without INHERIT).
  """
  def role_facts(repo) do
    [[current, session, super, bypass, login, inherit, createrole, createdb, member_of_owner]] =
      q!(
        repo,
        "SELECT current_user::text, session_user::text, r.rolsuper, r.rolbypassrls, r.rolcanlogin, r.rolinherit, r.rolcreaterole, r.rolcreatedb, pg_has_role(current_user, session_user, 'MEMBER') FROM pg_roles r WHERE r.rolname = current_user"
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
      member_of_owner: member_of_owner
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

  @doc """
  Every Store of one engine (Unit, Run, host, evidence, the transcript's reader and each Effect
  intent `store` and `host` store) is a `Postgres` Store on the application Repo, which runs as
  the non-owner application role (as ELZ-338's `engine_on_app!/2`).
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
  As the owner: the role holds no `TRUNCATE` and no `DELETE` on, and owns no table of, the
  schema (its four Store tables and Ecto's `schema_migrations`).
  """
  def schema_owner_facts!(prefix, role) do
    assert owner!(
             """
             SELECT bool_or(has_table_privilege($1, c.oid, 'TRUNCATE')),
                    bool_or(has_table_privilege($1, c.oid, 'DELETE')),
                    bool_or(pg_get_userbyid(c.relowner) = $1), count(*)
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = $2 AND c.relkind IN ('r', 'p')
             """,
             [role, prefix]
           ) == [[false, false, false, 5]]
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

  def hex(n), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)

  def digest(text, n),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, n)

  # ------------------------------------------------------------ fixture

  @doc """
  The disposable world of one test: the shared mailbox and work-item schema `p`, one recipe
  store schema, one engine schema per tenant, the scripted host, and each tenant's Run owner,
  Unit directory, evidence writer, Effect intents, recipe store and three versions.
  """
  def fixture!(role) do
    p = "wave8_" <> hex(6)
    rs = p <> "_rs"
    owner!("CREATE SCHEMA #{p}")
    owner!("CREATE SCHEMA #{rs}")
    ExUnit.Callbacks.on_exit(fn -> drop!([p, rs]) end)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave8.Migration, prefix: p, log: false)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave8.StoreMigration, prefix: rs, log: false)

    # The mailbox and work-item READMEs' grants, and the copied Store grants.
    for sql <- [
          "GRANT USAGE ON SCHEMA #{p} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_mailbox_chains, #{p}.elzoo_mailbox_links, #{p}.elzoo_mailbox_messages TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_work_items TO #{role}"
        ],
        do: owner!(sql)

    :ok = grant_store!(rs, role)

    {:ok, _} = Host.start()
    ExUnit.Callbacks.on_exit(fn -> stop(Process.whereis(Host)) end)
    {:ok, clock} = Agent.start(fn -> 2_000 end)
    {:ok, engines} = Agent.start(fn -> %{} end)
    {:ok, books} = Agent.start(fn -> %{} end)
    {:ok, turns} = Agent.start(fn -> %{} end)
    {:ok, hooks} = Agent.start(fn -> %{} end)
    {:ok, facts} = Agent.start(fn -> %{} end)
    {:ok, intent_pids} = Agent.start(fn -> MapSet.new() end)

    {:ok, mailbox} =
      DurableMailbox.new([repo: AppRepo, prefix: p], %{
        id: "wave8.room-mail",
        version: 1,
        max_pending: 256,
        messages: %{"elzoo.room.message" => %{schema_version: 1, schema: message_schema()}}
      })

    {:ok, child_mailbox} =
      DurableMailbox.new([repo: AppRepo, prefix: p], %{
        id: "wave8.child-mail",
        version: 1,
        max_pending: 16,
        messages: %{
          "elzoo.delegation.cancel_requested" => %{
            schema_version: 1,
            schema: %{
              "type" => "object",
              "required" => ["child_run_id", "reason"],
              "properties" => %{
                "child_run_id" => %{"type" => "string"},
                "reason" => %{"type" => "string"}
              }
            }
          }
        }
      })

    items = WorkItem.new(repo: AppRepo, prefix: p)

    # As elzoo_app, before the first call.
    :ok = DurableMailbox.verify(mailbox)
    :ok = DurableMailbox.verify(child_mailbox)
    :ok = WorkItem.verify(items)

    rs_store = Postgres.store(AppRepo, prefix: rs, fold: RS.fold(), limits: RS.limits())
    store_on_app!(rs_store, role)
    {:ok, binding} = Binding.load(Elzoo.RunEngine.TestBinding)
    object_store = RS.object_store!()

    w = %{
      prefix: p,
      rs_prefix: rs,
      role: role,
      clock: clock,
      engines: engines,
      books: books,
      turns: turns,
      hooks: hooks,
      facts: facts,
      intent_pids: intent_pids,
      mailbox: mailbox,
      child_mailbox: child_mailbox,
      items: items,
      rs_store: rs_store,
      rs_owner_store: Postgres.store(OwnerRepo, prefix: rs, fold: RS.fold(), limits: RS.limits()),
      binding_digest: binding.digest,
      rooms: %{},
      suffix: hex(4)
    }

    tenants =
      Map.new(@tenants, fn t ->
        {:ok, art} = Artifact.new(store: rs_store, object_store: object_store, max_bytes: 65_536)
        {:ok, recipes} = RecipeStore.new(artifact: art, log: rs_store)
        {t, tenant!(w, t, recipes)}
      end)

    w = Map.put(w, :tenants, tenants)

    ExUnit.Callbacks.on_exit(fn -> teardown(w) end)
    :ok = Host.world(w)
    w
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp drop!(schemas), do: for(s <- schemas, do: owner!("DROP SCHEMA IF EXISTS #{s} CASCADE"))

  def teardown(w) do
    for {_, e} <- Agent.get(w.engines, & &1), pid <- [e.engine, e.async], do: stop(pid)

    for {_, t} <- w.tenants do
      for pid <- [t.run, t.evidence, t.lock, t.directory, t.supervisor, t.tasks, t.context],
          do: stop(pid)
    end

    for pid <- Agent.get(w.intent_pids, &MapSet.to_list/1), do: stop(pid)
    for {_, t} <- w.tenants, do: drop!([t.prefix])

    for a <- [w.clock, w.engines, w.books, w.turns, w.hooks, w.facts, w.intent_pids],
        do: Agent.stop(a)
  end

  def message_schema,
    do: %{
      "type" => "object",
      "required" => ["message_id", "from", "text", "mentions"],
      "properties" => %{
        "message_id" => %{"type" => "string"},
        "from" => %{"type" => "string"},
        "text" => %{"type" => "string", "minLength" => 1},
        "mentions" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }

  # One tenant: its engine schema with a Run owner, a Unit directory, an evidence writer and the
  # Effect intents, its recipe store with three versions (v1 published), and its principals.
  defp tenant!(w, tenant, recipes) do
    prefix = "wave8_" <> String.downcase(tenant) <> "_" <> hex(6)
    owner!("CREATE SCHEMA #{prefix}")
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.Wave8.StoreMigration, prefix: prefix, log: false)
    :ok = grant_store!(prefix, w.role)
    schema_owner_facts!(prefix, w.role)

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
      # Each Unit's offers go to the engine registered under its own identity.
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

    now = fn -> Agent.get(w.clock, & &1) end
    pids = w.intent_pids

    intents = %{
      "effect" => [
        binding: Elzoo.RunEngine.TestBinding,
        store:
          Postgres.store(AppRepo,
            prefix: prefix,
            fold: Elzoo.EffectIntent.fold(Elzoo.RunEngine.TestBinding),
            limits: Elzoo.EffectIntent.limits()
          ),
        clock: now,
        host:
          {StoreHost,
           %{
             store: host_store,
             authorize: fn _, _ ->
               intent = self()
               Agent.update(pids, &MapSet.put(&1, intent))
               :fresh
             end
           }},
        task_supervisor: tasks,
        adapter_context: Process.whereis(Host)
      ]
    }

    {:ok, run} = Run.start_link(store: run_store, lease: lease, held: held, effect_intent: intents)
    Process.unlink(run)

    # A host Run whose status reads the owner's stream revision.
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

    writes = [%{target: "document", field: "published", value: true}]

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
          authority: writes,
          resource_names: ["document"],
          pause_deadline: 50_000
        }
      end)

    caller = %{tenant: tenant, principal: "room", scopes: []}
    facts = RS.facts()

    versions =
      for v <- 1..3 do
        package = RS.package(name: "wave8-room-#{w.suffix}", version: "#{v}")
        {:ok, id} = RecipeStore.put(recipes, caller, package)
        {:ok, _} = RecipeStore.check(recipes, caller, id, facts)
        id
      end

    {:ok, _} = RecipeStore.publish(recipes, caller, hd(versions))

    %{
      tenant: tenant,
      prefix: prefix,
      supervisor: supervisor,
      tasks: tasks,
      lock: lock,
      directory: directory,
      unit_store: unit_store,
      run: run,
      run_store: run_store,
      evidence: evidence,
      evidence_store: evidence_store,
      intents: intents,
      context: context,
      writes: writes,
      recipes: recipes,
      caller: caller,
      versions: versions,
      principals: principals(tenant)
    }
  end

  # ------------------------------------------------------------ principals (pinned test identities)

  @doc """
  The host's principals: in T1 the person Ann, the room service (the root of every lineage) and
  the room bots A, B and D, delegated from it; in T2 the person Cara, a room service and bot T.
  """
  def principals(tenant) do
    {person, bots} = if tenant == "T1", do: {"Ann", ~w(A B D)}, else: {"Cara", ~w(T)}

    {:ok, human} =
      Principal.new(%{
        kind: :human,
        id: person,
        tenant: tenant,
        auth_epoch: 1,
        allowed_scopes: ["files.read"],
        allowed_spaces: ["room"]
      })

    root = service(tenant, 1)

    bots =
      Map.new(bots, fn id ->
        scopes = if id in ["A", "T"], do: ["files.read", "files.write"], else: ["files.read"]

        {:ok, bot} =
          Principal.delegate(root, %{id: id, allowed_scopes: scopes, allowed_spaces: ["room"]})

        {id, bot}
      end)

    %{person: human, root: root, bots: bots}
  end

  def service(tenant, epoch) do
    {:ok, root} =
      Principal.new(%{
        kind: :service,
        id: "room-service",
        tenant: tenant,
        auth_epoch: epoch,
        allowed_scopes: ["files.read", "files.write", "admin"],
        allowed_spaces: ["room"]
      })

    root
  end

  # ------------------------------------------------------------ schemas and bindings

  @schemas ~w(elzoo.room.start elzoo.room.message elzoo.room.rollover elzoo.room.turn
              elzoo.room.answer elzoo.room.decide elzoo.typed-decision.result elzoo.room.post
              elzoo.room.notice elzoo.room.carry elzoo.room.finish elzoo/ai-text-request
              elzoo.ai-text.result elzoo.agent-loop.message elzoo.agent-loop.tool-call
              elzoo.agent-loop.tool-result elzoo.agent-loop.result
              elzoo.delegation.cancel_requested elzoo.wave8.work elzoo.wave8.child-result
              action result message elzoo.run-engine.refusal)

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
  The bindings of one engine (every engine gets the same ones): the turn and decision
  `nested_callable`s, the agent loop's `model_call` and `tool_call`, the post and notice
  `tool_call`s, the echoing carry and the harness `local_work`, and the finish.
  """
  def bindings(w, tenant, run_id) do
    now = fn -> Agent.get(w.clock, & &1) end
    proposal = proposal(tenant)

    effect = fn id, result, ms ->
      %{
        id: id,
        version: 1,
        effect_class: "publish",
        result: {result, 1},
        proposal: proposal,
        facts: fn a ->
          deadline = now.() + ms

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
        facts: fn _ -> %{estimate: estimate, unit: "credits", deadline_ms: now.() + ms} end
      }
    end

    %{
      "model_call" => effect.("wave8.model", "elzoo.ai-text.result", @effect_ms),
      "tool_call" => %{
        "elzoo.agent-loop.tool-call" =>
          effect.("wave8.tool", "elzoo.agent-loop.tool-result", @tool_ms),
        "elzoo.room.post" => effect.("wave8.post", "result", @effect_ms),
        "elzoo.room.notice" => effect.("wave8.notice", "result", @effect_ms)
      },
      "nested_callable" => %{
        "elzoo.room.turn" =>
          compute.("wave8.turn", "elzoo.room.answer", @turn_ms, 10_000)
          |> Map.put(:nested, &turn_child(w, run_id, &1)),
        "elzoo.room.decide" =>
          compute.("wave8.decide", "elzoo.typed-decision.result", @turn_ms, 10_000)
          |> Map.put(:nested, &decision_child/1)
      },
      "local_work" => %{
        "elzoo.room.carry" =>
          compute.("wave8.carry", "elzoo.room.carry", @effect_ms, 1)
          |> Map.put(:work, fn a -> {Elzoo.Wave8.Child, :echo, [a["payload"]]} end),
        "elzoo.wave8.work" =>
          compute.("wave8.work", "result", @effect_ms, 1)
          |> Map.put(:work, fn a -> {Elzoo.Wave8.Child, :work, [a["payload"]]} end)
      },
      "finish" => compute.("wave8.finish", "result", @effect_ms, 1)
    }
  end

  # The tools of every bot's agent loop: one source `room` with `delegate` and `accept_item`.
  def sources do
    tool = fn name, description ->
      %{
        "trust" => "untrusted",
        "name" => name,
        "description" => description,
        "input_schema" => %{"type" => "object"},
        "annotations" => nil
      }
    end

    [
      %{
        "id" => "room",
        "kind" => "other",
        "callable" => "adapter",
        "tools" => [
          tool.("delegate", "Start a child bot on a work item"),
          tool.("accept_item", "Accept the offered result of a work item")
        ]
      }
    ]
  end

  def agent_spec(id, member) do
    %{
      id: id,
      model: "scripted-model",
      max_output_tokens: 256,
      role_instructions: ["You are the bot #{member} of a room. Answer as JSON."],
      window: %{
        provider_id: "scripted",
        model_id: "scripted-model",
        size: 100_000,
        unit: :tokens,
        estimator_id: "bytes",
        estimator_version: 1
      },
      max_request_bytes: 65_536,
      max_image_refs: 0,
      sources: sources(),
      result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
      ask: nil,
      turn_limit: @turn_limit
    }
  end

  @doc """
  The rendering of a turn: each window entry, newest last, as its `from` and the
  `UntrustedContent.render/1` block of its decoded content, then the summary.
  """
  def render_turn(%{"window" => window, "summary" => summary}) do
    entries =
      window
      |> Enum.reverse()
      |> Enum.map(fn %{"from" => from, "content" => content} ->
        {:ok, marked} = UntrustedContent.decode(content)
        {:ok, block} = UntrustedContent.render(marked)
        from <> ":\n" <> block
      end)

    Enum.join(entries ++ if(summary, do: ["summary: " <> summary], else: []), "\n\n")
  end

  # The nested callable of one bot turn: the agent-loop finish wrapper with the turn ID as id.
  defp turn_child(w, run_id, action) do
    %{"turn_id" => turn_id, "member" => member} = payload = action["payload"]
    Agent.update(w.turns, &Map.put(&1, {run_id, turn_id}, member))
    {:ok, inner} = Elzoo.AgentLoop.new(agent_spec(turn_id, member))

    %{
      budget_id: "nested-" <> action["id"],
      incarnation: "sealed",
      mfa: {Elzoo.Wave8.Bot, :step},
      initial_state: %{inner: inner, contents: %{}},
      schema_id: "elzoo.agent-loop.message",
      schema_version: 1,
      payload: %{"text" => render_turn(payload)}
    }
  end

  # The `:decided` decision binding: a real typed-decision step on the pick schema.
  defp decision_child(action) do
    payload = action["payload"]

    text =
      "Pick the next speaker among #{Enum.join(payload["members"], ", ")}.\n\n" <>
        render_turn(Map.put(payload, "summary", nil))

    {:ok, state} =
      TypedDecision.new(%{
        id: payload["decision_id"],
        request: %{
          "model" => "scripted-model",
          "messages" => [
            %{"role" => "system", "text" => "You choose who speaks next in a room."},
            %{"role" => "user", "text" => text}
          ]
        },
        port: %{
          "id" => "pick",
          "direction" => "output",
          "schema_id" => "elzoo.room.pick",
          "schema_version" => 1
        },
        answer: {:schema, TurnPolicy.pick_schema()},
        repairs: @repairs
      })

    %{
      budget_id: "nested-" <> action["id"],
      incarnation: "sealed",
      mfa: {TypedDecision, :step},
      initial_state: state,
      schema_id: "elzoo.room.decide",
      schema_version: 1,
      payload: payload
    }
  end

  # ------------------------------------------------------------ engines

  @doc """
  Start one engine on its own Unit in the tenant's Run owner: create and begin the Run (under the
  tenant's lock), then the engine with every Store on the application Repo.
  """
  def start_engine!(w, tenant, %{run_id: run_id, unit: unit, pattern: pattern} = spec) do
    t = w.tenants[tenant]

    ensure_run!(w, tenant, run_id)
    name = {:via, Registry, {@engines, unit}}

    {:ok, async} =
      GenServer.start(Elzoo.AsyncWork, owner: name, task_supervisor: t.tasks, max_concurrency: 8)

    now = Agent.get(w.clock, & &1)
    deadline = Map.get(spec, :run_deadline) || now + @run_ms

    opts = [
      name: name,
      identity: unit,
      directory: t.directory,
      store: t.unit_store,
      run_owner: t.run,
      run_id: run_id,
      tenant: tenant,
      principal: "principal",
      pattern: pattern,
      schemas: schemas(),
      gate: %{id: "gate", version: 1, call: fn _, _ -> :allow end},
      clock: fn -> Agent.get(w.clock, & &1) end,
      bindings: bindings(w, tenant, run_id),
      context: fn -> Agent.get(t.context, & &1) end,
      async_work: async,
      resources: %{},
      effect_intent: t.intents,
      request_cap: Map.get(spec, :request_cap, 256),
      budget: %{
        cap: Map.get(spec, :budget, 10_000_000),
        unit: "credits",
        id: "budget",
        incarnation: "sealed"
      },
      budget_rule: :finish,
      run_deadline: deadline,
      evidence: %{writer: t.evidence, stream: "evidence"},
      result_reader: %{evidence_store: t.evidence_store, retention_count: 1_024}
    ]

    engine_on_app!(opts, w.role)
    {:ok, pid} = RunEngine.start_link(opts)
    Process.unlink(pid)

    entry =
      Map.merge(spec, %{
        tenant: tenant,
        engine: pid,
        async: async,
        scope: %{tenant: tenant, principal: "principal", run_id: run_id},
        run_deadline: deadline
      })

    Agent.update(w.engines, &Map.put(&1, run_id, entry))
    entry
  end

  def rev(w, tenant) do
    {:ok, %{revision: revision}} = Run.status(w.tenants[tenant].run, "host")
    revision
  end

  @doc "A harness command to the tenant's Run owner, at its current revision, under the lock."
  def command!(w, tenant, command) do
    locked(w, tenant, fn ->
      Run.command(w.tenants[tenant].run, Map.put(command, :expected_revision, rev(w, tenant)))
    end)
  end

  def locked(w, tenant, fun), do: Lock.run(w.tenants[tenant].lock, fun)

  defp ensure_run!(w, tenant, run_id) do
    case Run.status(w.tenants[tenant].run, run_id) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
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
  end

  def entry(w, run_id), do: Agent.get(w.engines, & &1[run_id])
  def engine(w, run_id), do: entry(w, run_id).engine

  def view(w, run_id) do
    {:ok, view} = RunEngine.status(engine(w, run_id))
    view
  end

  def transcript(w, run_id) do
    e = entry(w, run_id)

    {:ok, %{entries: entries}} =
      RunEngine.transcript(e.engine, e.scope, %{max_records: 65_536, max_bytes: 536_870_912})

    entries
  end

  def inputs(w, run_id), do: for(%{type: :input, input_id: id} <- transcript(w, run_id), do: id)

  @doc "The root actions of a Run's record: `{action_id, schema_id}`."
  def actions(w, run_id),
    do:
      for(
        %{type: :action, path: [], action_id: id, schema_id: s} <- transcript(w, run_id),
        do: {id, s}
      )

  @doc "Every action of a Run's record, nested ones included."
  def all_actions(w, run_id),
    do: for(%{type: :action, action_id: id} <- transcript(w, run_id), do: id)

  @doc "An input of the harness to an engine (under the tenant's lock), at its current Attempt."
  def input!(w, run_id, id, input, extra \\ %{}) do
    e = entry(w, run_id)

    locked(w, e.tenant, fn ->
      {:ok, view} = RunEngine.status(e.engine)
      context = Map.merge(%{run_id: view.run_id, attempt_id: view.attempt_id}, extra)
      RunEngine.input(e.engine, id, Map.merge(%{"type" => "input", "version" => 1}, input), context)
    end)
  end

  # ------------------------------------------------------------ rooms

  @doc """
  The start of a room: `members` as `{id, kind}`, `policy` merged over the defaults.
  """
  def start_payload(room_id, members, policy) do
    %{
      "room_id" => room_id,
      "link" => 1,
      "members" => for({id, kind} <- members, do: %{"id" => id, "kind" => kind}),
      "policy" =>
        Map.merge(
          %{
            "rule" => "addressed",
            "default_member" => nil,
            "max_bot_turns" => 3,
            "handoff" => "denied",
            "post_to" => "channel",
            "window" => %{"messages" => 8, "bytes" => 16_384},
            "rollover" => %{"max_turns" => 63}
          },
          policy
        ),
      "summary" => nil,
      "carry" => nil
    }
  end

  @doc """
  One room binding: the room's mailbox, recipe store and principal, the turn-policy state,
  the start and engine Needs, the shared clock, the request cap and the derived reserve.
  """
  def room!(w, tenant, name, opts \\ []) do
    t = w.tenants[tenant]
    {:ok, turn_policy} = TurnPolicy.new(%{host_rules: %{}})

    {:ok, room} =
      Room.new(
        mailbox: w.mailbox,
        recipes: t.recipes,
        principal: "room",
        turn_policy: turn_policy,
        start: fn tenant, request -> start_need(w, tenant, name, turn_policy, opts, request) end,
        engine: fn _tenant, %{run_id: run_id} -> engine_need(w, run_id) end,
        clock: fn -> Agent.get(w.clock, & &1) end,
        request_cap: Keyword.get(opts, :request_cap, 256),
        reserve: reserve(),
        read_limits: %{max_records: 65_536, max_bytes: 536_870_912}
      )

    room
  end

  # The start Need: a Run already started returns the same; else the Run and its engine.
  defp start_need(w, tenant, name, turn_policy, opts, %{
         unit_identity: unit,
         run_id: run_id,
         pin: pin,
         request_cap: cap
       }) do
    case Agent.get(w.hooks, & &1[{:start, run_id}]) do
      fun when is_function(fun, 0) ->
        Agent.update(w.hooks, &Map.delete(&1, {:start, run_id}))
        fun.()

      nil ->
        case entry(w, run_id) do
          %{engine: pid} = e ->
            if Process.alive?(pid),
              do: {:ok, Map.take(e, [:engine, :scope, :run_deadline])},
              else: {:error, :engine_down}

          nil ->
            seq = run_id |> String.split("/") |> List.last() |> String.to_integer()

            e =
              locked(w, tenant, fn ->
                case entry(w, run_id) do
                  nil ->
                    start_engine!(w, tenant, %{
                      kind: :tip,
                      room: name,
                      label: "#{name}/#{seq}",
                      seq: seq,
                      run_id: run_id,
                      unit: Keyword.get(opts, :unit, fn u, _ -> u end).(unit, seq),
                      pin: pin,
                      pattern: {TurnPolicy, :step, turn_policy},
                      request_cap: cap,
                      run_deadline: nil
                    })

                  e ->
                    e
                end
              end)

            {:ok, Map.take(e, [:engine, :scope, :run_deadline])}
        end
    end
  end

  defp engine_need(w, run_id) do
    case entry(w, run_id) do
      %{engine: pid} = e ->
        if Process.alive?(pid),
          do: {:ok, Map.take(e, [:engine, :scope, :run_deadline])},
          else: {:error, :not_started}

      nil ->
        {:error, :not_started}
    end
  end

  @doc "The start Need fails once for `run_id` (a host crash after the mailbox step)."
  def fail_start_once(w, run_id, reason),
    do: Agent.update(w.hooks, &Map.put(&1, {:start, run_id}, fn -> {:error, reason} end))

  def ids(tenant, chain_id, seq) do
    hash = Base.encode16(:crypto.hash(:sha256, [tenant, 0, chain_id]), case: :lower)
    "room/#{hash}/#{seq}"
  end

  @doc "Register the rooms of the post sink: chain ID to `%{name, peer_id, tenant}`."
  def rooms(w, tenant, rooms), do: Agent.update(w.facts, &Map.put(&1, {:rooms, tenant}, rooms))

  # ------------------------------------------------------------ the host (runs in Host)

  @doc false
  def effect(
        s,
        task,
        %{"tenant" => tenant, "run_id" => run_id, "action_id" => id, "schema_id" => schema} = call
      ) do
    w = s.w
    e = entry(w, run_id)
    label = e.label
    s = %{s | calls: s.calls ++ [{label, id, schema}]}

    case schema do
      "elzoo/ai-text-request" ->
        member = member(w, e, run_id, id)
        exact = {label, id}

        {value, s} =
          case Map.pop(s.script, exact) do
            {nil, _} ->
              case Map.get(s.queues, {label, member}, []) do
                [value | rest] -> {value, put_in(s.queues[{label, member}], rest)}
                [] -> {:unscripted, s}
              end

            {value, script} ->
              {value, %{s | script: script}}
          end

        held = %{task: task, tenant: tenant, run_id: run_id, action_id: id, value: value}

        case value do
          :unscripted ->
            s = %{s | errors: s.errors ++ [{:unscripted, label, id}]}
            answer_model(s, held, :fail)

          :hold ->
            %{s | held: Map.put(s.held, exact, held)}

          {:hold, v} ->
            %{s | held: Map.put(s.held, exact, %{held | value: v})}

          _ ->
            answer_model(s, held, value)
        end

      "elzoo.room.post" ->
        send(task, {:result, %{}})
        payload = call["payload"]
        forward(w, tenant, e, id, payload)
        give_outcome(w, run_id, id, outcome(id, "completed", "result", %{}))
        %{s | posts: s.posts ++ [{label, id, payload}]}

      "elzoo.room.notice" ->
        send(task, {:result, %{}})
        give_outcome(w, run_id, id, outcome(id, "completed", "result", %{}))
        %{s | notices: s.notices ++ [{label, id, call["payload"]}]}

      "elzoo.agent-loop.tool-call" ->
        tool(w, s, task, e, call)
    end
  end

  defp member(w, %{kind: :tip}, run_id, action_id) do
    [turn | _] = String.split(action_id, ":")
    Agent.get(w.turns, & &1[{run_id, turn}]) || :decide
  end

  defp member(_w, e, _run_id, _action_id), do: e.label

  @doc false
  def answer_model(s, held, value) do
    send(held.task, {:result, %{}})

    input =
      case value do
        :fail ->
          outcome(held.action_id, "failed", "elzoo.ai-text.result", %{"reason" => "unscripted"})

        value ->
          outcome(held.action_id, "completed", "elzoo.ai-text.result", value)
      end

    give_outcome(s.w, held.run_id, held.action_id, input)
    s
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
  under the tenant's lock. After a child Run's input, its end is handled.
  """
  def give_outcome(w, run_id, action_id, input) do
    e = entry(w, run_id)

    reply =
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

    if e.kind == :child, do: child_ended(w, run_id)
    reply
  end

  # The post sink: a post (never a notice) whose post_to names another room's chain is put there
  # as a peer's message.
  defp forward(w, tenant, e, action_id, payload) do
    rooms = Agent.get(w.facts, & &1[{:rooms, tenant}]) || %{}

    case {rooms[payload["post_to"]], rooms_by_name(rooms, e.room)} do
      {%{} = _to, {from_chain, %{peer_id: peer}}} ->
        message_id = "p/" <> digest(from_chain <> <<0>> <> action_id, 32)

        {:ok, _} =
          DurableMailbox.put(w.mailbox, tenant, %{
            sender: %{kind: :service, id: peer},
            address: {:chain, payload["post_to"]},
            message: %{
              message_id: message_id,
              name: "elzoo.room.message",
              schema_version: 1,
              payload: %{
                "message_id" => message_id,
                "from" => peer,
                "text" => payload["text"],
                "mentions" => payload["mentions"]
              }
            }
          })

      _ ->
        :ok
    end
  end

  defp rooms_by_name(rooms, name), do: Enum.find(rooms, fn {_, r} -> r.name == name end)

  # ------------------------------------------------------------ tools (runs in Host)

  defp tool(w, s, task, e, %{"action_id" => id, "payload" => payload} = call) do
    caller = caller(w, e, call["run_id"], id)

    case payload["tool"] do
      "delegate" ->
        case child_start(w, e, caller, id, payload["arguments"], task) do
          :started ->
            s

          {:refused, reason} ->
            send(task, {:result, %{}})

            input =
              outcome(id, "failed", "elzoo.agent-loop.tool-result", %{
                "reason" => Atom.to_string(reason)
              })

            give_outcome(w, e.run_id, id, input)
            put_refusal(s, e, id, reason)
        end

      "accept_item" ->
        send(task, {:result, %{}})
        {:ok, item} = WorkItem.get(w.items, e.tenant, payload["arguments"]["item_id"])

        result =
          WorkItem.decide(w.items, e.tenant, item.item_id, %{
            revision: item.revision,
            decided_by: caller.id,
            decision: :accepted
          })

        give_outcome(w, e.run_id, id, tool_result(id, "accepted: #{inspect(result)}"))
        s
    end
  end

  defp put_refusal(s, e, id, reason), do: %{s | refusals: s.refusals ++ [{e.label, id, reason}]}

  def tool_result(id, text),
    do:
      outcome(id, "completed", "elzoo.agent-loop.tool-result", %{
        "content" => %{
          "schema_id" => "elzoo.untrusted-content.marked",
          "schema_version" => 1,
          "sources" => ["wave8:tool"],
          "trust" => "untrusted",
          "max_bytes" => 4_096,
          "content" => text
        },
        "media_type" => "text/plain",
        "encoding" => "utf8"
      })

  # The principal, authority and lineage of the callable that asks a tool call.
  defp caller(w, %{kind: :tip, tenant: tenant}, run_id, action_id) do
    member = member(w, %{kind: :tip}, run_id, action_id)
    p = w.tenants[tenant].principals
    bot = p.bots[member]

    %{
      id: member,
      principal: bot,
      authority: w.tenants[tenant].writes,
      lineage: [member],
      pin: entry(w, run_id).pin
    }
  end

  defp caller(w, %{kind: :child, run_id: run_id}, _, _) do
    b = Agent.get(w.books, & &1[run_id])

    %{
      id: b.bot,
      principal: b.grant.principal,
      authority: b.grant.parent_authority,
      lineage: b.grant.lineage,
      pin: b.grant.pin
    }
  end

  def item_id(parent_run_id, action_id),
    do: "item/" <> digest(parent_run_id <> <<0>> <> action_id, 32)

  def child_run_id(parent_run_id, action_id),
    do: "child/" <> digest(parent_run_id <> <<0>> <> action_id, 32)

  @doc """
  Host facts for one tool call, keyed `{label, action_id}`: `max_depth`, `revoked_ids` and
  `root_epoch` overrides of the defaults (2, none, 1).
  """
  def host_facts(w, key, facts), do: Agent.update(w.facts, &Map.put(&1, {:override, key}, facts))

  @doc """
  The child-start binding (Q3 A, harness code): `Delegation.grant/2` from the host's facts, then
  the work item, the pin of the grant's version for the child's Run ID and its version-pin
  capture, the child Run on the tip's Run owner with its Attempt, `attach_child`, the child
  engine (budget cap the grant's budget) with its start input, and the item's start. A refusal
  writes nothing.
  """
  def child_start(w, e, caller, action_id, args, task) do
    tenant = e.tenant
    t = w.tenants[tenant]
    o = Agent.get(w.facts, & &1[{:override, {e.label, action_id}}]) || %{}

    root =
      case o[:root_epoch] do
        nil -> t.principals.root
        epoch -> service(tenant, epoch)
      end

    facts = %{
      root: root,
      parent: caller.principal,
      authority: caller.authority,
      budget_remaining: 500,
      max_depth: Map.get(o, :max_depth, 2),
      lineage: caller.lineage,
      revoked_ids: Map.get(o, :revoked_ids, []),
      pin: caller.pin
    }

    request = %{
      child_bot: args["child_bot"],
      scopes: args["scopes"],
      spaces: args["spaces"] || [],
      budget: args["budget"],
      parent_close: if(rule = args["parent_close"], do: String.to_existing_atom(rule)),
      change: nil
    }

    case grant(facts, request) do
      {:error, reason} ->
        {:refused, reason}

      {:ok, grant} ->
        child = child_run_id(e.run_id, action_id)
        item = item_id(e.run_id, action_id)
        {:ok, intent} = UntrustedContent.decode(marked(args["text"]))

        locked(w, tenant, fn ->
          {:ok, :applied} =
            WorkItem.create(w.items, tenant, %{
              item_id: item,
              parent_run_id: e.run_id,
              child_run_id: child,
              owner: caller.id,
              intent: intent,
              acceptance: :parent,
              parent_close: grant.parent_close
            })

          {:ok, :pinned} = RecipeStore.pin(t.recipes, t.caller, grant.pin, child)
          {:ok, capture} = VersionPin.new(grant.pin, sources())
          ensure_run!(w, tenant, child)

          {:ok, _, _} =
            command!(w, tenant, %{
              kind: :attach_child,
              run_id: e.run_id,
              attempt_id: "attempt",
              child_run_id: child,
              child_pid: nil
            })

          Agent.update(w.books, fn books ->
            Map.put(books, child, %{
              bot: grant.principal.id,
              item_id: item,
              parent_run_id: e.run_id,
              parent_action_id: action_id,
              grant: grant,
              capture: capture,
              task: task,
              ended: false,
              offer: nil
            })
          end)

          start_engine!(w, tenant, %{
            kind: :child,
            room: e[:room],
            label: grant.principal.id,
            run_id: child,
            unit: child,
            pin: grant.pin,
            pattern: child_pattern(grant.principal.id),
            budget: grant.budget
          })

          {:ok, :applied} =
            input!(w, child, "start:" <> child, %{
              "kind" => "start",
              "schema_id" => "elzoo.agent-loop.message",
              "schema_version" => 1,
              "payload" => %{"text" => args["text"]}
            })

          {:ok, %{revision: 2}} = WorkItem.start(w.items, tenant, item, %{revision: 1})
        end)

        child_ended(w, child)
        :started
    end
  end

  # ELZ-349 negative control 4 swaps this for a grant that skips Delegation.grant/2.
  defp grant(facts, request), do: Delegation.grant(facts, request)

  def marked(text),
    do: %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => ["room"],
      "trust" => "untrusted",
      "max_bytes" => 4_096,
      "content" => text
    }

  # The child patterns: C is an agent-loop child; the parent-close children are harness patterns.
  defp child_pattern("C") do
    {:ok, state} = Elzoo.AgentLoop.new(agent_spec("C", "C"))
    {Elzoo.Wave8.Agent, :step, state}
  end

  defp child_pattern(name) do
    {hold, wait} =
      case name do
        "K-abandon" -> {true, false}
        "K-request" -> {false, true}
        "K-cancel" -> {true, false}
        _ -> {false, false}
      end

    {Elzoo.Wave8.Child, :step, %{phase: :new, name: name, hold: hold, wait: wait}}
  end

  @doc """
  A child Run that ended: offer its completed outcome reference on its item from its
  `child_run_id` (or close a `cancel_requested` item `cancelled`), record `child_result` and
  give the parent's tool call its outcome while the item was running, and unpin its version.
  """
  def child_ended(w, child) do
    case entry(w, child) do
      nil -> nil
      e -> locked(w, e.tenant, fn -> ended(w, child, e) end)
    end
  end

  # Under the tenant lock, so a child that ends while its child-start still runs is read only
  # after `WorkItem.start/4`, and two callers cannot both see `ended: false`.
  defp ended(w, child, e) do
    b = Agent.get(w.books, & &1[child])

    with %{ended: false} <- b,
         {:ok, %{phase: :terminal}} <- RunEngine.status(e.engine) do
      tenant = e.tenant
      t = w.tenants[tenant]
      {:ok, item} = WorkItem.get(w.items, tenant, b.item_id)
      offer = %{revision: item.revision, child_run_id: child, evidence: "outcome:" <> child}

      result =
        case item.state do
          :cancel_requested ->
            WorkItem.close(w.items, tenant, b.item_id, %{revision: item.revision, to: :cancelled})

          _ ->
            WorkItem.offer(w.items, tenant, b.item_id, offer)
        end

      Agent.update(w.books, &update_in(&1[child], fn b -> %{b | ended: true, offer: result} end))

      if item.state == :running do
        {:ok, %{completion_revision: revision}} = Run.status(t.run, child)

        {:ok, _, _} =
          command!(w, tenant, %{
            kind: :child_result,
            run_id: b.parent_run_id,
            attempt_id: "attempt",
            child_run_id: child,
            child_completion_revision: revision
          })

        send(b.task, {:result, %{}})

        give_outcome(
          w,
          b.parent_run_id,
          b.parent_action_id,
          tool_result(b.parent_action_id, child_text(e))
        )
      end

      {:ok, :unpinned} = RecipeStore.unpin(t.recipes, t.caller, b.grant.pin, child)
    end

    :ok
  end

  defp child_text(e) do
    case RunEngine.result(e.engine, e.scope, %{max_records: 65_536, max_bytes: 536_870_912}) do
      {:ok, %{payload: %{"content" => text}}} when is_binary(text) -> text
      {:ok, %{payload: payload}} -> Jason.encode!(payload)
      other -> inspect(other)
    end
  end

  # ------------------------------------------------------------ parent close (harness code)

  @doc """
  The parent-close application: `list_open/3` of the parent Run, `on_parent_close/1`, and each
  action, in rule order (cancel, request_cancel, abandon), from the listing alone. `stop_after`
  stops after that many actions (the host's restart: nothing else of its bookkeeping is read).
  Returns the actions it applied with their results.
  """
  def parent_close!(w, tenant, parent_run_id, stop_after \\ :infinity) do
    {:ok, %{items: items, more: false}} =
      WorkItem.list_open(w.items, tenant, %{parent_run_id: parent_run_id, after: nil, limit: 256})

    {:ok, actions} =
      Delegation.on_parent_close(
        for i <- items, do: %{child_run_id: i.child_run_id, parent_close: i.parent_close}
      )

    by_child = Map.new(items, &{&1.child_run_id, &1})
    order = %{cancel: 0, request_cancel: 1, abandon: 2}

    actions
    |> Enum.sort_by(&order[&1.action])
    |> Enum.take(if(stop_after == :infinity, do: length(actions), else: stop_after))
    |> Enum.map(fn a ->
      {a.action, a.child_run_id, apply_close(w, tenant, by_child[a.child_run_id], a)}
    end)
  end

  defp apply_close(w, tenant, item, %{action: :cancel, child_run_id: child}) do
    e = entry(w, child)

    control =
      locked(w, tenant, fn ->
        {:ok, view} = RunEngine.status(e.engine)

        RunEngine.control(
          e.engine,
          "cancel:" <> child,
          %{kind: :cancel, attempt_id: view.attempt_id},
          %{
            run_id: view.run_id,
            attempt_id: view.attempt_id
          }
        )
      end)

    close =
      WorkItem.close(w.items, tenant, item.item_id, %{revision: item.revision, to: :cancelled})

    {control, close}
  end

  defp apply_close(w, tenant, item, %{
         action: :request_cancel,
         child_run_id: child,
         message: payload
       }) do
    t = w.tenants[tenant]

    open =
      DurableMailbox.open(w.child_mailbox, tenant, %{
        chain_id: child,
        run_id: child,
        unit_identity: child,
        pin: entry(w, child).pin,
        carry: %{}
      })

    put =
      DurableMailbox.put(w.child_mailbox, tenant, %{
        sender: %{kind: :service, id: t.principals.root.id},
        address: {:chain, child},
        message: %{
          message_id: "cancel:" <> child,
          name: "elzoo.delegation.cancel_requested",
          schema_version: 1,
          payload: payload
        }
      })

    close =
      WorkItem.close(w.items, tenant, item.item_id, %{
        revision: item.revision,
        to: :cancel_requested
      })

    {open, put, close}
  end

  defp apply_close(w, tenant, item, %{action: :abandon}) do
    WorkItem.close(w.items, tenant, item.item_id, %{revision: item.revision, to: :abandoned})
  end

  @doc """
  The idle-checked delivery to a child's own chain: only when the child's `status/1` is idle,
  claim one message and give it under `mail:<message_id>`, then settle it.
  """
  def deliver_child!(w, tenant, child) do
    e = entry(w, child)
    {:ok, view} = RunEngine.status(e.engine)

    if idle?(view) do
      case DurableMailbox.claim(w.child_mailbox, tenant, %{chain_id: child}) do
        {:ok, :empty} ->
          :empty

        {:ok, %{message: m, link_seq: seq}} ->
          {:ok, reply} =
            input!(w, child, "mail:" <> m.message_id, %{
              "kind" => "message",
              "schema_id" => m.name,
              "schema_version" => m.schema_version,
              "payload" => m.payload
            })

          {:ok, _} =
            DurableMailbox.settle(w.child_mailbox, tenant, %{
              chain_id: child,
              message_id: m.message_id,
              link_seq: seq,
              result: :applied
            })

          child_ended(w, child)
          {:delivered, reply}
      end
    else
      :busy
    end
  end

  def idle?(view) do
    view.reconciliation == nil and view.phase == :active and view.generation_closed == false and
      view.stop_pending == nil and Enum.all?(view.slots, fn {_, slot} -> slot.phase == :settled end)
  end

  # ------------------------------------------------------------ the test's host loop

  @doc """
  Wait until the Run is idle or terminal, or every open slot is held by the host (a held model
  call or held work, or a child-start tool call whose child runs).
  """
  def settle!(w, run_id, tries \\ 2_000) do
    Host.sync()
    view = view(w, run_id)
    host = Host.get()

    work = if Map.has_key?(host.work, entry(w, run_id).label), do: ["w1"], else: []

    held =
      MapSet.new(for({{_, id}, %{run_id: ^run_id}} <- host.held, do: id))
      |> MapSet.union(MapSet.new(open_children(w, run_id) ++ work))

    open = for {_, s} <- view.slots, s.phase != :settled, do: s

    cond do
      view.reconciliation != nil ->
        flunk("engine halted: #{inspect(view.reconciliation)}")

      view.classification == :invalid_request ->
        flunk("the engine refused a request (invalid_request): #{inspect(view)}")

      view.phase == :terminal or open == [] ->
        view

      blocked?(open, held) ->
        view

      tries == 0 ->
        flunk(
          "Run did not settle: open #{inspect(open)} phase #{inspect(view.phase)} held #{inspect(held)}"
        )

      true ->
        Process.sleep(10)
        settle!(w, run_id, tries - 1)
    end
  end

  # Open slots wait only on a held action: the nested turn or decision that runs it, and the
  # agent loop's tool call or model call itself.
  defp blocked?(open, held) do
    leaves = Enum.reject(open, &(&1.kind == "nested_callable"))
    leaves != [] and Enum.all?(leaves, &MapSet.member?(held, &1.action_id))
  end

  defp open_children(w, run_id) do
    for {_, b} <- Agent.get(w.books, & &1),
        b.parent_run_id == run_id,
        not b.ended,
        do: b.parent_action_id
  end

  @doc "Room calls of the minimal host, each under the tenant's lock."
  def deliver(w, tenant, room, chain_id),
    do: locked(w, tenant, fn -> Room.deliver(room, tenant, %{chain_id: chain_id}) end)

  def wake(w, tenant, room, chain_id, wake_id),
    do:
      locked(w, tenant, fn -> Room.wake(room, tenant, %{chain_id: chain_id, wake_id: wake_id}) end)

  def rollover(w, tenant, room, chain_id, seq, change \\ nil),
    do:
      locked(w, tenant, fn ->
        Room.rollover(room, tenant, %{chain_id: chain_id, link_seq: seq, change: change})
      end)

  def resume(w, tenant, room, chain_id),
    do: locked(w, tenant, fn -> Room.resume(room, tenant, %{chain_id: chain_id}) end)

  def open!(w, tenant, room, chain_id, start) do
    t = w.tenants[tenant]
    {:ok, turn_policy} = TurnPolicy.new(%{host_rules: %{}})
    # Every start passes check_start/2 first.
    :ok = TurnPolicy.check_start(turn_policy, start)

    {:ok, %{run_id: run_id}} =
      locked(w, tenant, fn ->
        Room.open(room, tenant, %{chain_id: chain_id, start: start, pin: hd(t.versions)})
      end)

    settle!(w, run_id)
    run_id
  end

  def tip(w, tenant, chain_id) do
    {:ok, %{tip: tip}} =
      DurableMailbox.chain(w.mailbox, tenant, %{chain_id: chain_id, after_seq: nil, limit: 1})

    tip
  end

  def chain(w, tenant, chain_id) do
    {:ok, chain} =
      DurableMailbox.chain(w.mailbox, tenant, %{chain_id: chain_id, after_seq: nil, limit: 256})

    chain
  end

  @doc """
  The minimal host loop for some rooms: settle each tip, deliver while a room has mail, until no
  room delivers. Returns the delivery results in order as `{chain_id, result}`.
  """
  def pump!(w, tenant, rooms, acc \\ []) do
    {results, progress} =
      Enum.reduce(rooms, {[], false}, fn {chain_id, room}, {results, progress} ->
        run_id = tip(w, tenant, chain_id).run_id
        view = settle!(w, run_id)

        if view.phase == :terminal or not idle?(view) do
          {results, progress}
        else
          result = deliver(w, tenant, room, chain_id)
          settle!(w, run_id)

          {results ++ [{chain_id, result}],
           progress or result in [{:ok, :delivered}, {:ok, :rollover}]}
        end
      end)

    if progress, do: pump!(w, tenant, rooms, acc ++ results), else: acc ++ results
  end

  @doc "A person's (or a peer's) message to a chain."
  def put(w, tenant, chain_id, message_id, from, text, mentions, opts \\ []) do
    DurableMailbox.put(w.mailbox, tenant, %{
      sender: Keyword.get(opts, :sender, %{kind: :human, id: from}),
      address: Keyword.get(opts, :address, {:chain, chain_id}),
      message: %{
        message_id: message_id,
        name: Keyword.get(opts, :name, "elzoo.room.message"),
        schema_version: 1,
        payload:
          Keyword.get(opts, :payload, %{
            "message_id" => message_id,
            "from" => from,
            "text" => text,
            "mentions" => mentions
          })
      }
    })
  end

  def status(w, tenant, chain_id, message_id) do
    {:ok, status} =
      DurableMailbox.status(w.mailbox, tenant, %{chain_id: chain_id, message_id: message_id})

    status
  end

  @doc "A model result with an answer: the answer's JSON object as the content."
  def say(text, mentions \\ [], opts \\ []),
    do: %{
      "content" =>
        Jason.encode!(%{
          "text" => text,
          "mentions" => mentions,
          "handoff_to" => Keyword.get(opts, :handoff_to),
          "escalate" => Keyword.get(opts, :escalate, false)
        }),
      "finish" => "stop",
      "tool_proposals" => []
    }

  @doc "A model result that proposes tool calls `{tool, arguments}`."
  def propose(calls) do
    true = length(calls) <= @max_proposals

    %{
      "content" => "",
      "finish" => "tool_calls",
      "tool_proposals" =>
        Enum.map(Enum.with_index(calls, 1), fn {{tool, args}, n} ->
          %{"id" => "p#{n}", "name" => "room_" <> tool, "arguments" => args, "malformed" => nil}
        end)
    }
  end

  def delegate(child, scopes, budget, close, text),
    do:
      {"delegate",
       %{
         "child_bot" => child,
         "scopes" => scopes,
         "spaces" => [],
         "budget" => budget,
         "parent_close" => close,
         "text" => text
       }}

  @doc "A decision model result: the pick as content and as ai-text's validated value."
  def pick(value),
    do: %{
      "content" => Jason.encode!(value),
      "structured" => %{"valid" => value},
      "finish" => "stop"
    }

  def posts(label_prefix) do
    for {label, id, p} <- Host.get().posts,
        String.starts_with?(label, label_prefix),
        do: {label, id, p}
  end

  def notices(label_prefix) do
    for {label, id, p} <- Host.get().notices,
        String.starts_with?(label, label_prefix),
        do: {label, id, p}
  end

  def await_held!(key, tries \\ 1_000) do
    cond do
      Map.has_key?(Host.get().held, key) -> :ok
      tries == 0 -> flunk("not held: #{inspect(key)}; calls #{inspect(Host.get().calls)}")
      true -> Process.sleep(10) && await_held!(key, tries - 1)
    end
  end

  def await_work!(child, tries \\ 1_000) do
    cond do
      Map.has_key?(Host.get().work, child) -> :ok
      tries == 0 -> flunk("no held work of #{child}")
      true -> Process.sleep(10) && await_work!(child, tries - 1)
    end
  end

  def await!(fun, tries \\ 1_000) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && await!(fun, tries - 1)
    end
  end

  def clock(w, ms), do: Agent.update(w.clock, fn _ -> ms end)
  def now(w), do: Agent.get(w.clock, & &1)

  # ------------------------------------------------------------ recipe store

  @doc "The live pin records of the tenant, as `{identity, run_id}` pairs, read by the owner."
  def pins(w, tenant) do
    w.rs_owner_store
    |> RS.rows(RS.stream(tenant))
    |> Enum.reduce(MapSet.new(), fn
      {"recipe_pinned", %{"identity" => i, "run_id" => r}}, set -> MapSet.put(set, {i, r})
      {"recipe_unpinned", %{"identity" => i, "run_id" => r}}, set -> MapSet.delete(set, {i, r})
      _, set -> set
    end)
  end

  def pins_of(w, tenant, run_id), do: for({i, ^run_id} <- pins(w, tenant), do: i)

  def publish!(w, tenant, identity) do
    t = w.tenants[tenant]
    {:ok, _} = RecipeStore.publish(t.recipes, t.caller, identity)
  end

  def book(w, child), do: Agent.get(w.books, & &1[child])

  @doc "The turns of a Run's record, in order: `{turn_id, member, message_id}`."
  def turns(w, run_id),
    do:
      for(
        %{type: :action, path: [], schema_id: "elzoo.room.turn", payload: p} <-
          transcript(w, run_id),
        do: {p["turn_id"], p["member"], p["message_id"]}
      )

  @doc "The notes of a carry."
  def notes(carry), do: for(%{"code" => code} <- carry["carry"]["notes"], do: code)
end
