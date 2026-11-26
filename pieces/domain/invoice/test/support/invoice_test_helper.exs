# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants, holds row locks and
# reads ground truth.
defmodule Elzoo.InvoiceTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.InvoiceTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.InvoiceTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.InvoiceTest.FaultRepo do
  @moduledoc false
  # A test-only Repo wrapper: a second AppRepo pool registered under this module's name, so
  # Ecto.Adapters.SQL finds it, with the three functions that the Piece and
  # Elzoo.TenantIsolation call on a Repo module. When the calling process has armed it,
  # transact/1 reports the result of the function and then forces a database error inside the
  # same transaction, after the function (a finalize/3) has taken its number.
  alias Ecto.Adapters.SQL
  alias Elzoo.InvoiceTest.AppRepo

  def arm, do: Process.put(__MODULE__, self())

  def in_transaction?, do: as_fault(&AppRepo.in_transaction?/0)
  def rollback(value), do: as_fault(fn -> AppRepo.rollback(value) end)

  def transact(fun, opts \\ []) do
    as_fault(fn ->
      AppRepo.transact(
        fn ->
          result = fun.()

          case Process.delete(__MODULE__) do
            nil ->
              result

            pid ->
              send(pid, {:fault_after, result})
              SQL.query!(__MODULE__, "SELECT 1 / 0", [], log: false)
          end
        end,
        opts
      )
    end)
  end

  defp as_fault(fun) do
    previous = AppRepo.put_dynamic_repo(__MODULE__)

    try do
      fun.()
    after
      AppRepo.put_dynamic_repo(previous)
    end
  end
end

defmodule Elzoo.InvoiceTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner calls install/1 from up/0.
  def up, do: Elzoo.Invoice.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.InvoiceTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.InvoiceTest.{AppRepo, FaultRepo, OwnerRepo, RepeatableRepo}
  alias Elzoo.Money.Codec
  alias Elzoo.TenantIsolation, as: TI

  @tables ~w(elzoo_invoices elzoo_invoice_lines elzoo_invoice_applications elzoo_invoice_reversals elzoo_invoice_series)
  @app_name "elz367_app"

  def tables, do: @tables

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

    app = [
      url: url,
      log: false,
      parameters: [application_name: @app_name],
      after_connect: {__MODULE__, :connect, [role, nil]}
    ]

    start!(AppRepo, [pool_size: 6] ++ app)
    start!(AppRepo, [name: FaultRepo, pool_size: 2] ++ app)

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
    assert String.to_integer(version) in 190_000..199_999
    role
  end

  defp start!(repo, opts) do
    {:ok, pid} = repo.start_link(opts)
    Process.unlink(pid)
    pid
  end

  def stop!(name) do
    case Process.whereis(name) do
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

  @doc "A random schema with the invoice tables and only the README grants to the role."
  def install!(role) do
    p = "elz367_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.InvoiceTest.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.InvoiceTest.Migration, prefix: p, log: false)

    tables = Enum.map_join(@tables, ", ", &~s("#{p}".#{&1}))
    q!(OwnerRepo, ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"))
    q!(OwnerRepo, ~s(GRANT SELECT, INSERT, UPDATE ON #{tables} TO "#{role}"))
    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def table(p, name), do: ~s("#{p}".#{name})

  # ------------------------------------------------------------ ground truth

  defp minor(bytes) do
    {:ok, amount} = Codec.decode(bytes)
    amount.minor_units
  end

  @doc "Every row of every tenant, read as the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:truth, truth}} =
      OwnerRepo.transaction(fn ->
        for t <- @tables,
            do: q!(OwnerRepo, "ALTER TABLE #{table(p, t)} NO FORCE ROW LEVEL SECURITY")

        read = fn t, sql -> q!(OwnerRepo, "SELECT #{sql} FROM #{table(p, t)} ORDER BY 1, 2, 3") end

        invoices =
          read.(
            "elzoo_invoices",
            "tenant, invoice_id, kind, series, number, state, total, paid, credited, corrects, operation_id, posting_state, revision"
          )
          |> Enum.map(fn [
                           t,
                           id,
                           kind,
                           series,
                           number,
                           state,
                           total,
                           paid,
                           credited,
                           corrects,
                           op,
                           posting,
                           rev
                         ] ->
            %{
              key: {t, id},
              kind: kind,
              series: series,
              number: number,
              state: state,
              total: minor(total),
              paid: minor(paid),
              credited: minor(credited),
              corrects: corrects,
              operation_id: op,
              posting: posting,
              revision: rev
            }
          end)

        lines =
          read.("elzoo_invoice_lines", "tenant, invoice_id, line_id, position, amount")
          |> Enum.map(fn [t, id, line_id, pos, a] ->
            %{key: {t, id}, line_id: line_id, position: pos, amount: minor(a)}
          end)

        applications =
          read.("elzoo_invoice_applications", "tenant, invoice_id, payment_ref, amount")
          |> Enum.map(fn [t, id, ref, a] -> %{key: {t, id}, ref: ref, amount: minor(a)} end)

        reversals =
          read.("elzoo_invoice_reversals", "tenant, invoice_id, reversal_id, payment_ref, amount")
          |> Enum.map(fn [t, id, rid, ref, a] ->
            %{key: {t, id}, reversal_id: rid, ref: ref, amount: minor(a)}
          end)

        series =
          q!(
            OwnerRepo,
            "SELECT tenant, series, last_number FROM #{table(p, "elzoo_invoice_series")} ORDER BY 1, 2"
          )
          |> Map.new(fn [t, s, last] -> {{t, s}, last} end)

        OwnerRepo.rollback(
          {:truth,
           %{
             invoices: invoices,
             lines: lines,
             applications: applications,
             reversals: reversals,
             series: series
           }}
        )
      end)

    truth
  end

  @doc """
  The stored state agrees with itself: each total is the sum of its lines, each paid the sum of
  its applications minus their reversals (no application reversed past its amount), each
  credited the magnitude sum of the issued credit notes that correct it; drafts have no number
  and finalized documents have one; the numbers of each series are exactly 1..last_number; a
  finalized invoice is :paid exactly when paid >= payable; a posting exists exactly for a
  finalized non-zero total, named invoice/<id>/issue.
  """
  def assert_invariants!(p) do
    t = truth(p)

    sum = fn rows, key ->
      rows |> Enum.filter(&(&1.key == key)) |> Enum.map(& &1.amount) |> Enum.sum()
    end

    for a <- t.applications do
      reversed =
        t.reversals |> Enum.filter(&(&1.key == a.key and &1.ref == a.ref)) |> Enum.map(& &1.amount)

      assert Enum.sum(reversed) <= a.amount and Enum.all?(reversed, &(&1 > 0))
    end

    for r <- t.reversals,
        do: assert(Enum.any?(t.applications, &(&1.key == r.key and &1.ref == r.ref)))

    for d <- t.invoices do
      {tenant, id} = d.key
      assert d.total == sum.(t.lines, d.key), inspect(d.key)
      positions = t.lines |> Enum.filter(&(&1.key == d.key)) |> Enum.map(& &1.position)
      assert Enum.sort(positions) == Enum.to_list(1..length(positions)//1)
      assert d.paid == sum.(t.applications, d.key) - sum.(t.reversals, d.key), inspect(d.key)

      credited =
        t.invoices
        |> Enum.filter(&(&1.kind == "credit_note" and &1.state == "issued" and &1.corrects == id))
        |> Enum.filter(&(elem(&1.key, 0) == tenant))
        |> Enum.map(&(-&1.total))
        |> Enum.sum()

      assert d.credited == credited, inspect(d.key)

      case d.state do
        "draft" -> assert d.number == nil
        s when s in ["open", "paid", "issued"] -> assert is_integer(d.number)
        "void" -> :ok
      end

      if d.kind == "invoice" and d.state in ["open", "paid"],
        do: assert(d.state == "paid" == d.paid >= d.total - d.credited, inspect(d.key))

      if d.number != nil and d.total != 0 do
        assert d.operation_id == "invoice/#{id}/issue" and d.posting in ["pending", "posted"]
      else
        assert d.operation_id == nil and d.posting == nil
      end
    end

    numbered = Enum.filter(t.invoices, &(&1.number != nil))
    groups = Enum.group_by(numbered, &{elem(&1.key, 0), &1.series}, & &1.number)
    assert Map.keys(groups) -- Map.keys(t.series) == []

    for {key, last} <- t.series,
        do: assert(Enum.sort(Map.get(groups, key, [])) == Enum.to_list(1..last//1), inspect(key))

    t
  end

  # ------------------------------------------------------------ concurrency

  @doc "Another connection (the owner, under the tenant scope) holds one series row's lock."
  def hold_series!(p, tenant, series),
    do:
      hold!(
        tenant,
        "SELECT 1 FROM #{table(p, "elzoo_invoice_series")} WHERE tenant = $1 AND series = $2 FOR UPDATE",
        [tenant, series]
      )

  @doc "Another connection (the owner, under the tenant scope) holds one invoice row's lock."
  def hold_invoice!(p, tenant, invoice_id),
    do:
      hold!(
        tenant,
        "SELECT 1 FROM #{table(p, "elzoo_invoices")} WHERE tenant = $1 AND invoice_id = $2 FOR UPDATE",
        [tenant, invoice_id]
      )

  defp hold!(tenant, sql, params) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, :released} =
          TI.transact(OwnerRepo, %{tenant: tenant}, fn ->
            [[1]] = q!(OwnerRepo, sql, params)

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

  @doc "Wait until exactly `n` application backends wait on a lock (pg_locks, not granted)."
  def await_waiting!(n, tries \\ 500) do
    [[count]] =
      q!(
        OwnerRepo,
        "SELECT count(DISTINCT l.pid) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE NOT l.granted AND a.application_name = $1",
        [@app_name]
      )

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
