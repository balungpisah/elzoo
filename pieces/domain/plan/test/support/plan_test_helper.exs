# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants, holds row locks and
# reads ground truth.
defmodule Elzoo.PlanTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.PlanTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.PlanTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.PlanTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner calls install/1 from up/0.
  def up, do: Elzoo.Plan.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.PlanTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.PlanTest.{AppRepo, OwnerRepo, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @app_name "elz366_app"

  # ------------------------------------------------------------ connections

  @doc "ELZOO_TEST_DATABASE_URL must name a database; the tests fail closed without it."
  def url! do
    url = System.get_env("ELZOO_TEST_DATABASE_URL")
    if not is_binary(url), do: flunk("ELZOO_TEST_DATABASE_URL is required; tests fail closed")

    if url |> URI.parse() |> Map.get(:path, "") |> to_string() |> String.trim_leading("/") == "",
      do: flunk("ELZOO_TEST_DATABASE_URL names no database; refusing")

    url
  end

  @doc "The fixed application role of ELZ-285; the test fails, not skips, when it is unset."
  def app_role! do
    role = System.get_env("ELZOO_TEST_APP_ROLE")

    if not (is_binary(role) and role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/),
      do: flunk("ELZOO_TEST_APP_ROLE must name the application role of ELZ-285; it is unset")

    role
  end

  @doc false
  # after_connect of the application Repos: SET ROLE, then the optional default level.
  def connect(conn, role, isolation) do
    Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])

    if isolation,
      do: Postgrex.query!(conn, "SET default_transaction_isolation = '#{isolation}'", [])
  end

  def start_repos! do
    url = url!()
    role = app_role!()
    start!(OwnerRepo, url: url, log: false, pool_size: 3)

    start!(AppRepo,
      url: url,
      log: false,
      pool_size: 4,
      parameters: [application_name: @app_name],
      after_connect: {__MODULE__, :connect, [role, nil]}
    )

    start!(RepeatableRepo,
      url: url,
      log: false,
      pool_size: 1,
      after_connect: {__MODULE__, :connect, [role, "repeatable read"]}
    )

    [[database]] = q!(OwnerRepo, "SELECT current_database()")

    if database != url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/"),
      do: flunk("effective database differs from configured; refusing")

    [[version]] = q!(OwnerRepo, "SELECT current_setting('server_version_num')")
    assert String.to_integer(version) in 190_000..199_999
    role
  end

  defp start!(repo, opts) do
    {:ok, pid} = repo.start_link(opts)
    Process.unlink(pid)
    pid
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

  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows
  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)

  @doc """
  The application connection is the application role: no superuser, no BYPASSRLS, not the
  session (owner) role and no member of it. Any other answer fails.
  """
  def role_guard!(role) do
    [[current, session, super, bypass, member_of_owner]] =
      q!(
        AppRepo,
        "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'MEMBER') FROM pg_roles r WHERE r.rolname = current_user"
      )

    if current != role or current == session or super or bypass or member_of_owner,
      do: flunk("the application connection is not the non-owner application role")
  end

  # ------------------------------------------------------------ schema

  @doc "A random schema with the subscriptions table and only the README grants to the role."
  def install!(role) do
    p = "elz366_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.PlanTest.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.PlanTest.Migration, prefix: p, log: false)
    q!(OwnerRepo, ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"))
    q!(OwnerRepo, ~s(GRANT SELECT, INSERT, UPDATE ON #{table(p)} TO "#{role}"))
    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def table(p), do: ~s("#{p}".elzoo_plan_subscriptions)

  # ------------------------------------------------------------ ground truth

  @doc "Every row of every tenant, read as the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:truth, rows}} =
      OwnerRepo.transaction(fn ->
        q!(OwnerRepo, "ALTER TABLE #{table(p)} NO FORCE ROW LEVEL SECURITY")
        result = SQL.query!(OwnerRepo, "SELECT * FROM #{table(p)} ORDER BY 1, 2", [], log: false)
        rows = Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
        OwnerRepo.rollback({:truth, rows})
      end)

    rows
  end

  # ------------------------------------------------------------ concurrency

  @doc "Another connection (the owner, under the tenant scope) holds one subscription row's lock."
  def hold!(p, tenant, id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, :released} =
          TI.transact(OwnerRepo, %{tenant: tenant}, fn ->
            [[1]] =
              q!(
                OwnerRepo,
                "SELECT 1 FROM #{table(p)} WHERE tenant = $1 AND subscription_id = $2 FOR UPDATE",
                [tenant, id]
              )

            send(parent, {:holding, self()})

            receive do
              :release -> {:ok, :released}
            end
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

  @doc "Distinct application backends that wait for a lock (pg_locks, not granted)."
  def waiting do
    [[n]] =
      q!(
        OwnerRepo,
        "SELECT count(DISTINCT l.pid) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE NOT l.granted AND a.application_name = $1",
        [@app_name]
      )

    n
  end

  @doc "Wait until exactly `n` application backends wait on a lock."
  def await_waiting!(n, tries \\ 500) do
    count = waiting()

    cond do
      count == n ->
        :ok

      tries == 0 ->
        flunk("expected #{n} waiting backends, saw #{count}")

      true ->
        Process.sleep(20)
        await_waiting!(n, tries - 1)
    end
  end
end
