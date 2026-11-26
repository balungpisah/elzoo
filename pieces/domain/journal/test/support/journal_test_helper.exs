# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants, holds row locks and
# reads ground truth.
defmodule Elzoo.JournalTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.JournalTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.JournalTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.JournalTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner calls install/1 from up/0.
  def up, do: Elzoo.Journal.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.JournalTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.JournalTest.{AppRepo, OwnerRepo, RepeatableRepo}
  alias Elzoo.Money
  alias Elzoo.TenantIsolation, as: TI

  @tables ~w(accounts operations postings)

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

    for {repo, extra} <- [
          {OwnerRepo, [pool_size: 4]},
          {AppRepo,
           [
             pool_size: 6,
             telemetry_prefix: [:elz297, :app],
             after_connect: {__MODULE__, :connect, [role, nil]}
           ]},
          {RepeatableRepo,
           [pool_size: 2, after_connect: {__MODULE__, :connect, [role, "repeatable read"]}]}
        ] do
      {:ok, pid} = repo.start_link([url: url, log: false] ++ extra)
      Process.unlink(pid)
      pid
    end

    [[database]] = q!(OwnerRepo, "SELECT current_database()")

    if database != url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/"),
      do: flunk("effective database differs from configured; refusing")

    [[version]] = q!(OwnerRepo, "SELECT current_setting('server_version_num')")
    assert String.to_integer(version) in 190_000..199_999
    role
  end

  def stop_repos!(pids) do
    for pid <- pids do
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
  session (owner) role and no member of it (direct or indirect, with or without INHERIT). Any
  other answer fails.
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

  @doc "A random schema with the journal tables and only the README grants to the role."
  def install!(role) do
    p = "elz297_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.JournalTest.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.JournalTest.Migration, prefix: p, log: false)

    for sql <- [
          ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"),
          ~s(GRANT SELECT, INSERT ON "#{p}".elzoo_journal_operations, "#{p}".elzoo_journal_postings TO "#{role}"),
          ~s(GRANT SELECT, INSERT, UPDATE ON "#{p}".elzoo_journal_accounts TO "#{role}")
        ],
        do: q!(OwnerRepo, sql)

    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def table(p, name), do: ~s("#{p}".elzoo_journal_#{name})

  # ------------------------------------------------------------ ground truth

  @doc "Every row of every tenant, read as the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:truth, truth}} =
      OwnerRepo.transaction(fn ->
        for t <- @tables,
            do: q!(OwnerRepo, "ALTER TABLE #{table(p, t)} NO FORCE ROW LEVEL SECURITY")

        accounts =
          q!(
            OwnerRepo,
            "SELECT tenant, account_id, currency_alpha, currency_numeric, currency_minor_unit, allow_negative, balance::text, version FROM #{table(p, :accounts)} ORDER BY 1, 2"
          )
          |> Enum.map(fn [t, id, a, n, m, allow, balance, version] ->
            %{
              key: {t, id},
              identity: {a, n, m},
              allow: allow,
              balance: String.to_integer(balance),
              version: version
            }
          end)

        operations =
          q!(
            OwnerRepo,
            "SELECT tenant, operation_id, actor_ref, reason, reverses, request_digest FROM #{table(p, :operations)} ORDER BY 1, 2"
          )
          |> Enum.map(fn [t, id, actor, reason, reverses, digest] ->
            %{key: {t, id}, actor: actor, reason: reason, reverses: reverses, digest: digest}
          end)

        postings =
          q!(
            OwnerRepo,
            "SELECT tenant, operation_id, account_id, minor_units::text, version, balance::text FROM #{table(p, :postings)} ORDER BY 1, 3, 5"
          )
          |> Enum.map(fn [t, op, id, units, version, balance] ->
            %{
              tenant: t,
              operation: op,
              account: id,
              units: String.to_integer(units),
              version: version,
              balance: String.to_integer(balance)
            }
          end)

        OwnerRepo.rollback(
          {:truth, %{accounts: accounts, operations: operations, postings: postings}}
        )
      end)

    truth
  end

  @doc """
  Each stored balance equals the sum of its account's postings (and each posting's stored
  balance the running sum, in versions 1..n), and every operation's 2..64 postings sum to zero
  in one currency identity; a reversal's postings negate its original's.
  """
  def assert_invariants!(p) do
    t = truth(p)
    by_account = Enum.group_by(t.postings, &{&1.tenant, &1.account})
    by_operation = Enum.group_by(t.postings, &{&1.tenant, &1.operation})
    identities = Map.new(t.accounts, &{&1.key, &1.identity})

    for account <- t.accounts do
      postings = Map.get(by_account, account.key, [])
      assert account.balance == Enum.sum(Enum.map(postings, & &1.units)), inspect(account.key)
      assert account.version == length(postings)
      assert Enum.map(postings, & &1.version) == Enum.to_list(1..account.version//1)

      Enum.reduce(postings, 0, fn posting, running ->
        assert posting.balance == running + posting.units
        posting.balance
      end)

      if not account.allow, do: assert(Enum.all?(postings, &(&1.balance >= 0)))
    end

    for operation <- t.operations do
      postings = Map.fetch!(by_operation, operation.key)
      assert length(postings) in 2..64
      assert Enum.sum(Enum.map(postings, & &1.units)) == 0, inspect(operation.key)
      {tenant, _} = operation.key

      assert postings |> Enum.map(&identities[{tenant, &1.account}]) |> Enum.uniq() |> length() ==
               1

      if operation.reverses do
        original = Map.fetch!(by_operation, {tenant, operation.reverses})
        negated = original |> Enum.map(&{&1.account, -&1.units}) |> Enum.sort()
        assert Enum.sort(Enum.map(postings, &{&1.account, &1.units})) == negated
      end
    end

    assert map_size(by_operation) == length(t.operations)
    t
  end

  # ------------------------------------------------------------ concurrency

  @doc "Another connection (the owner, under the tenant scope) holds one account's row lock."
  def hold!(p, tenant, account_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, :released} =
          TI.transact(OwnerRepo, %{tenant: tenant}, fn ->
            [[backend]] = q!(OwnerRepo, "SELECT pg_backend_pid()")

            [[1]] =
              q!(
                OwnerRepo,
                "SELECT 1 FROM #{table(p, :accounts)} WHERE tenant = $1 AND account_id = $2 FOR UPDATE",
                [tenant, account_id]
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

  @doc """
  A third connection under the tenant scope tries the account's row lock with NOWAIT in a
  rolled-back transaction: `:free`, or `:locked` when another transaction holds it (55P03).
  """
  def nowait!(p, tenant, account_id) do
    {:error, {:probe, result}} =
      TI.transact(OwnerRepo, %{tenant: tenant}, fn ->
        result =
          q(
            OwnerRepo,
            "SELECT 1 FROM #{table(p, :accounts)} WHERE tenant = $1 AND account_id = $2 FOR UPDATE NOWAIT",
            [tenant, account_id]
          )

        {:error, {:probe, result}}
      end)

    case result do
      {:ok, %{rows: [[1]]}} -> :free
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> :locked
    end
  end

  @doc "Wait until exactly `n` backends wait on the holder (seen in pg_stat_activity)."
  def await_blocked_by!({_pid, backend}, n),
    do:
      await!(
        "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
        [backend],
        n
      )

  @doc "Wait until exactly `n` backends of this database wait on any lock."
  def await_blocked!(n),
    do:
      await!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND cardinality(pg_blocking_pids(pid)) > 0",
        [],
        n
      )

  defp await!(sql, params, n, tries \\ 500) do
    [[count]] = q!(OwnerRepo, sql, params)

    cond do
      count == n ->
        :ok

      tries == 0 ->
        flunk("expected #{n} waiting backends, saw #{count}")

      true ->
        Process.sleep(20)
        await!(sql, params, n, tries - 1)
    end
  end

  @doc "The backend pids that wait on the holder."
  def blocked_by({_pid, backend}),
    do:
      List.flatten(
        q!(OwnerRepo, "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))", [
          backend
        ])
      )

  # ------------------------------------------------------------ registry

  @doc "The held extract text of domain/money (the iso4217 directory beside its registry)."
  def extract do
    dir = Money.Registry.module_info(:compile)[:source] |> to_string() |> Path.dirname()

    File.read!(
      Path.join([dir, "iso4217", Money.Registry.latest(Money.Registry.default()) <> ".tsv"])
    )
  end

  @doc """
  A derived extract at `version`: lines starting with a dropped prefix are removed and each
  `{from, to}` replacement is applied (the domain/money registry tests' form).
  """
  def derived(version, drop, replacements) do
    v1 = Money.Registry.latest(Money.Registry.default())

    extract()
    |> String.split("\n")
    |> Enum.reject(fn line -> Enum.any?(drop, &String.starts_with?(line, &1)) end)
    |> Enum.map(fn line ->
      Enum.reduce(
        [
          {"# version\t#{v1}", "# version\t#{version}"},
          {"# current_published\t#{v1}", "# current_published\t#{version}"} | replacements
        ],
        line,
        fn {from, to}, acc -> String.replace(acc, from, to) end
      )
    end)
    |> Enum.join("\n")
  end

  # ------------------------------------------------------------ telemetry

  @doc false
  def forward(_event, _measurements, metadata, pid), do: send(pid, {:app_query, metadata.query})
end
