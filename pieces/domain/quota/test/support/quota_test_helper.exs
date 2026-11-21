# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants, holds row locks and
# reads ground truth.
defmodule Elzoo.QuotaTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.QuotaTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.QuotaTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.QuotaTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner calls install/1 from up/0.
  def up, do: Elzoo.Quota.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.QuotaTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.QuotaTest.{AppRepo, OwnerRepo, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @tables ~w(counters reservations units)
  @app_name "elz303_app"

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
    start!(OwnerRepo, url: url, log: false, pool_size: 4)
    start_app!(role)

    start!(RepeatableRepo,
      url: url,
      log: false,
      pool_size: 2,
      after_connect: {__MODULE__, :connect, [role, "repeatable read"]}
    )

    [[database]] = q!(OwnerRepo, "SELECT current_database()")

    if database != url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/"),
      do: flunk("effective database differs from configured; refusing")

    [[version]] = q!(OwnerRepo, "SELECT current_setting('server_version_num')")
    assert String.to_integer(version) in 160_000..169_999
    role
  end

  def start_app!(role) do
    start!(AppRepo,
      url: url!(),
      log: false,
      pool_size: 6,
      parameters: [application_name: @app_name],
      after_connect: {__MODULE__, :connect, [role, nil]}
    )
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
  session (owner) role and without the owner's privileges. Any other answer fails.
  """
  def role_guard!(role) do
    [[current, session, super, bypass, inherits]] =
      q!(
        AppRepo,
        "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'USAGE') FROM pg_roles r WHERE r.rolname = current_user"
      )

    if current != role or current == session or super or bypass or inherits,
      do: flunk("the application connection is not the non-owner application role")
  end

  # ------------------------------------------------------------ schema

  @doc "A random schema with the quota tables and only the README grants to the role."
  def install!(role) do
    p = "elz303_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.QuotaTest.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.QuotaTest.Migration, prefix: p, log: false)

    tables = Enum.map_join(@tables, ", ", &table(p, &1))
    q!(OwnerRepo, ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"))
    q!(OwnerRepo, ~s(GRANT SELECT, INSERT, UPDATE ON #{tables} TO "#{role}"))
    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def table(p, name), do: ~s("#{p}".elzoo_quota_#{name})

  # ------------------------------------------------------------ ground truth

  @doc "Every row of every tenant, read as the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:truth, truth}} =
      OwnerRepo.transaction(fn ->
        for t <- @tables,
            do: q!(OwnerRepo, "ALTER TABLE #{table(p, t)} NO FORCE ROW LEVEL SECURITY")

        counters =
          q!(
            OwnerRepo,
            "SELECT tenant, window_tag, window_id, unit, committed::text, held::text, reserved::text FROM #{table(p, :counters)} ORDER BY 1, 2, 3, 4"
          )
          |> Enum.map(fn [t, tag, wid, unit, c, h, r] ->
            %{
              key: {t, tag, wid, unit},
              committed: String.to_integer(c),
              held: String.to_integer(h),
              reserved: String.to_integer(r)
            }
          end)

        reservations =
          q!(
            OwnerRepo,
            "SELECT tenant, run_id, window_tag, window_id, expiry_ms, request_digest, state FROM #{table(p, :reservations)} ORDER BY 1, 2"
          )
          |> Enum.map(fn [t, id, tag, wid, x, digest, state] ->
            %{key: {t, id}, window: {tag, wid}, expiry_ms: x, digest: digest, state: state}
          end)

        units =
          q!(
            OwnerRepo,
            "SELECT tenant, run_id, unit, estimate::text, settled_unknown, actual::text, basis, actor_ref, reason FROM #{table(p, :units)} ORDER BY 1, 2, 3"
          )
          |> Enum.map(fn [t, id, unit, e, unknown, a, basis, actor, reason] ->
            %{
              key: {t, id},
              unit: unit,
              estimate: String.to_integer(e),
              unknown: unknown,
              actual: a && String.to_integer(a),
              basis: basis,
              actor_ref: actor,
              reason: reason
            }
          end)

        OwnerRepo.rollback(
          {:truth, %{counters: counters, reservations: reservations, units: units}}
        )
      end)

    truth
  end

  @doc """
  Each counter equals the sum over its unit rows: `reserved` the estimates of open
  reservations, `held` the estimates settled `:unknown` and not reconciled, `committed` the
  known and reconciled actuals. Unit rows agree with their reservation's state.
  """
  def assert_invariants!(p) do
    t = truth(p)
    reservations = Map.new(t.reservations, &{&1.key, &1})

    expected =
      Enum.reduce(t.units, %{}, fn u, acc ->
        res = Map.fetch!(reservations, u.key)
        {tenant, _} = u.key
        {tag, wid} = res.window
        key = {tenant, tag, wid, u.unit}

        add =
          case {res.state, u.unknown, u.basis} do
            {"open", false, nil} ->
              assert u.actual == nil
              %{reserved: u.estimate}

            {"released", false, nil} ->
              assert u.actual == nil
              %{}

            {"settled", false, nil} ->
              assert is_integer(u.actual)
              %{committed: u.actual}

            {"settled", true, nil} ->
              assert u.actual == nil
              %{held: u.estimate}

            {"settled", true, basis} when basis in ["metering", "write_off"] ->
              assert is_integer(u.actual) and is_binary(u.actor_ref) and is_binary(u.reason)
              %{committed: u.actual}
          end

        Map.update(acc, key, Map.merge(%{committed: 0, held: 0, reserved: 0}, add), fn sums ->
          Map.merge(sums, add, fn _, a, b -> a + b end)
        end)
      end)

    for c <- t.counters do
      sums = Map.get(expected, c.key, %{committed: 0, held: 0, reserved: 0})

      assert %{committed: c.committed, held: c.held, reserved: c.reserved} == sums,
             inspect(c.key)
    end

    assert Enum.all?(Map.keys(expected), fn key -> Enum.any?(t.counters, &(&1.key == key)) end)
    t
  end

  # ------------------------------------------------------------ concurrency

  @doc "Another connection (the owner, under the tenant scope) holds one counter row's lock."
  def hold!(p, tenant, window_id, unit_text) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, :released} =
          TI.transact(OwnerRepo, %{tenant: tenant}, fn ->
            [[backend]] = q!(OwnerRepo, "SELECT pg_backend_pid()")

            [[1]] =
              q!(
                OwnerRepo,
                "SELECT 1 FROM #{table(p, :counters)} WHERE tenant = $1 AND window_tag = 'period' AND window_id = $2 AND unit = $3 FOR UPDATE",
                [tenant, window_id, unit_text]
              )

            send(parent, {:holding, self(), backend})

            receive do
              :release -> {:ok, :released}
            end
          end)

        send(parent, {:released, self()})
      end)

    receive do
      {:holding, ^pid, backend} -> {pid, backend}
    after
      10_000 -> flunk("the lock holder did not take the row lock")
    end
  end

  def release!({pid, _backend}) do
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

  @doc "The server's deadlock_timeout in milliseconds."
  def deadlock_timeout_ms do
    [[ms]] =
      q!(
        OwnerRepo,
        "SELECT setting::int * CASE unit WHEN 's' THEN 1000 ELSE 1 END FROM pg_settings WHERE name = 'deadlock_timeout'"
      )

    ms
  end
end
