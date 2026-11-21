# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants and reads ground truth.
defmodule Elzoo.DeadLetterStore.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connections: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.DeadLetterStore.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role under a fixed application_name, so a test can see its lock waits.
defmodule Elzoo.DeadLetterStore.RaceRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role whose transactions default to REPEATABLE READ.
defmodule Elzoo.DeadLetterStore.IsoRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# Never started: every call on it fails.
defmodule Elzoo.DeadLetterStore.DownRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DeadLetterStore.TestMigration do
  @moduledoc false
  use Ecto.Migration

  # The Piece's DDL as a consumer migration calls it, in the test's random schema.
  def up, do: Elzoo.DeadLetterStore.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.DeadLetterStore.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.DeadLetterStore.{AppRepo, IsoRepo, OwnerRepo, RaceRepo, TestMigration}

  @doc """
  Fail-closed target guard before any schema or data effect: ELZOO_TEST_DATABASE_URL must name a
  database, and that database must be the effective current_database().
  """
  def url! do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        flunk("ELZOO_TEST_DATABASE_URL is required; PostgreSQL tests fail closed (never skipped)")

    if url |> URI.parse() |> Map.get(:path, "") |> to_string() |> String.trim_leading("/") == "",
      do: flunk("ELZOO_TEST_DATABASE_URL names no database; refusing")

    url
  end

  @doc "The fixed application role of ELZ-285; the test fails when it is unset or not a role name."
  def app_role! do
    role = System.get_env("ELZOO_TEST_APP_ROLE")

    if not (is_binary(role) and role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/),
      do: flunk("ELZOO_TEST_APP_ROLE must name the application role of ELZ-285; it is unset")

    role
  end

  # Postgrex after_connect: switch to the application role, then optional session settings.
  def after_connect(conn, role, statements) do
    Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])
    Enum.each(statements, &Postgrex.query!(conn, &1, []))
  end

  @doc "Start every Repo on DBConnection.ConnectionPool (not the Sandbox); returns the race name."
  def start_repos! do
    url = url!()
    role = app_role!()
    race = "elzoo_dls_race_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    app = fn extra -> [after_connect: {__MODULE__, :after_connect, [role, extra]}] end

    for {repo, opts} <- [
          {OwnerRepo, []},
          {AppRepo, app.([]) ++ [telemetry_prefix: [:elzoo_dls_app]]},
          {RaceRepo, app.([]) ++ [parameters: [application_name: race]]},
          {IsoRepo,
           app.(["SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ"])}
        ] do
      start!(repo, url, opts)
    end

    %{role: role, race: race}
  end

  defp start!(repo, url, opts) do
    configured = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")

    {:ok, pid} =
      repo.start_link(
        [url: url, pool: DBConnection.ConnectionPool, pool_size: 4, log: false] ++ opts
      )

    Process.unlink(pid)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    [[effective]] = q!(repo, "SELECT current_database()")
    if effective != configured, do: flunk("effective database differs from configured; refusing")
  end

  @doc """
  The application connection is the application role: no superuser, no BYPASSRLS role, not the
  session (owner) role and no inherited owner privileges. Any other answer fails.
  """
  def role_facts!(repo, role) do
    [[current, session, super, bypass, inherits]] =
      q!(
        repo,
        "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'USAGE') FROM pg_roles r WHERE r.rolname = current_user"
      )

    facts = %{current: current, session: session, super: super, bypass: bypass, inherits: inherits}

    if current != role or current == session or super or bypass or inherits,
      do:
        flunk("the application connection is not the non-owner application role: #{inspect(facts)}")

    facts
  end

  @doc "A random schema with the Piece's migration and only the README grants for `role`."
  def install!(role) do
    p = "elz301_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    # Registered before the migration and grants, so a failure there still drops the schema.
    ExUnit.Callbacks.on_exit(fn -> drop!(p) end)
    :persistent_term.put({TestMigration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, TestMigration, prefix: p, log: false)
    q!(OwnerRepo, ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"))

    q!(
      OwnerRepo,
      ~s(GRANT SELECT, INSERT, UPDATE, DELETE ON "#{p}".elzoo_dead_letters TO "#{role}")
    )

    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  @doc "Ground truth: every row, read by the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:rows, rows}} =
      OwnerRepo.transact(fn ->
        q!(OwnerRepo, ~s(ALTER TABLE "#{p}".elzoo_dead_letters NO FORCE ROW LEVEL SECURITY))

        {:error,
         {:rows,
          q!(
            OwnerRepo,
            ~s|SELECT tenant, source, message_id, state, resolution, actor_ref, resolved_at_ms, record, work_ref, put_at_ms FROM "#{p}".elzoo_dead_letters ORDER BY 1, 2, 3|
          )}}
      end)

    rows
  end

  @doc "Distinct backends of the race Repo that wait for a lock (pg_locks, not granted)."
  def waiting(race) do
    [[n]] =
      q!(
        OwnerRepo,
        "SELECT count(DISTINCT l.pid) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE NOT l.granted AND a.application_name = $1",
        [race]
      )

    n
  end

  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)
  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows

  def poll(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("poll timeout")
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end

  @doc "A valid delivery/dead-letter record with no last-result triple."
  def record(id, extra \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "message_id" => id,
        "correlation_id" => id,
        "attempts" => 3,
        "reason" => "permanent"
      },
      extra
    )
  end
end
