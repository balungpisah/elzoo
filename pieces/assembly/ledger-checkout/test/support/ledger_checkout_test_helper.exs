# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants and reads ground truth.
defmodule Elzoo.LedgerCheckoutTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.LedgerCheckoutTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.LedgerCheckoutTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role with a small Repo :timeout (100 ms).
defmodule Elzoo.LedgerCheckoutTest.ShortRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# A second application Repo whose next transactions a test can fault: :raise_before (a lost
# connection before anything is sent) or :raise_after (a lost connection after the commit, an
# :unavailable that committed). One connection, so a session SET changes its isolation level.
defmodule Elzoo.LedgerCheckoutTest.FaultRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
  defoverridable transact: 2

  def transact(fun, opts) do
    case Elzoo.LedgerCheckoutTest.Faults.next(__MODULE__) do
      :raise_before ->
        raise DBConnection.ConnectionError, "scripted loss before the transaction"

      :raise_after ->
        _ = super(fun, opts)
        raise DBConnection.ConnectionError, "scripted loss after the commit"

      :none ->
        super(fun, opts)
    end
  end
end

defmodule Elzoo.LedgerCheckoutTest.Faults do
  @moduledoc false
  # Per Repo a list of faults for its next transactions, in order.
  def start!, do: Agent.start(fn -> %{} end, name: __MODULE__)
  def stop!, do: Agent.stop(__MODULE__)
  def reset!, do: Agent.update(__MODULE__, fn _ -> %{} end)
  def script(repo, faults), do: Agent.update(__MODULE__, &Map.put(&1, repo, faults))

  def next(repo) do
    Agent.get_and_update(__MODULE__, fn s ->
      case Map.get(s, repo, []) do
        [f | rest] -> {f, Map.put(s, repo, rest)}
        [] -> {:none, s}
      end
    end)
  end
end

defmodule Elzoo.LedgerCheckoutTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner installs the checkout and the reused Pieces.
  def up do
    p = :persistent_term.get({__MODULE__, :prefix})
    Elzoo.PaymentLifecycle.Migration.install(p)
    Elzoo.Invoice.Migration.install(p)
    Elzoo.Journal.Migration.install(p)
    Elzoo.LedgerCheckout.Migration.install(p)
  end
end

defmodule Elzoo.LedgerCheckoutTest.ChargeBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :charge, provider_account: "acct-1"
end

defmodule Elzoo.LedgerCheckoutTest.RefundBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :refund, provider_account: "acct-1"
end

# The scripted provider Need: each call pops the next scripted answer of its callback. Events
# are JSON signed with HMAC-SHA256 over the raw body, checked before the body is parsed.
defmodule Elzoo.LedgerCheckoutTest.Script do
  @behaviour Elzoo.PaymentLifecycle.Provider
  @key "scripted-provider-signing-key"

  def start!, do: Agent.start(fn -> %{answers: %{}, calls: []} end, name: __MODULE__)
  def stop!, do: Agent.stop(__MODULE__)
  def reset!, do: Agent.update(__MODULE__, fn _ -> %{answers: %{}, calls: []} end)

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
         true <- :crypto.hash_equals(sig, sign(raw)),
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

  @doc "A signed EUR event request for apply_event/3."
  def event(id, op, state, units, ref) do
    raw =
      Jason.encode!(%{
        "id" => id,
        "op" => Tuple.to_list(op) |> Enum.map(&to_string/1),
        "state" => Atom.to_string(state),
        "units" => units,
        "ref" => ref
      })

    %{raw_body: raw, headers: [{"x-signature", sign(raw)}]}
  end
end

# The host's allowance Needs: idempotent by grant_id, a refusal included, and nothing granted
# after a revoke. The first decision of a grant_id takes the next scripted answer: :ok,
# {:error, :refused}, :unavailable (not decided), {:sleep, ms} (then :ok) or :kill (decides
# :ok, then kills the caller). Every call is logged.
defmodule Elzoo.LedgerCheckoutTest.Allowance do
  alias Elzoo.LedgerCheckoutTest.Log

  def start!,
    do: Agent.start(fn -> %{grant: [], revoke: [], decided: %{}} end, name: __MODULE__)

  def stop!, do: Agent.stop(__MODULE__)
  def reset!, do: Agent.update(__MODULE__, fn _ -> %{grant: [], revoke: [], decided: %{}} end)
  def script(callback, answers), do: Agent.update(__MODULE__, &Map.put(&1, callback, answers))

  def needs, do: %{grant: &grant/1, revoke: &revoke/1}

  def grant(%{grant_id: id} = req) do
    Log.need(:grant, req)

    answer =
      Agent.get_and_update(__MODULE__, fn s ->
        case s.decided[id] do
          :granted -> {:ok, s}
          :refused -> {{:error, :refused}, s}
          :revoked -> {{:error, :refused}, s}
          nil -> pop(s, :grant, id)
        end
      end)

    case answer do
      {:sleep, ms} ->
        Process.sleep(ms)
        decide(id, :granted)

      :kill ->
        decide(id, :granted)
        Process.exit(self(), :kill)

      :unavailable ->
        {:error, :unavailable}

      other ->
        other
    end
  end

  def revoke(%{grant_id: id} = req) do
    Log.need(:revoke, req)

    Agent.get_and_update(__MODULE__, fn s ->
      case s.revoke do
        [a | rest] when a != :ok -> {a, %{s | revoke: rest}}
        list -> {:ok, %{s | revoke: Enum.drop(list, 1), decided: Map.put(s.decided, id, :revoked)}}
      end
    end)
  end

  defp pop(s, callback, id) do
    {a, rest} =
      case Map.fetch!(s, callback) do
        [a | rest] -> {a, rest}
        [] -> {:ok, []}
      end

    decided =
      case a do
        :ok -> Map.put(s.decided, id, :granted)
        {:error, :refused} -> Map.put(s.decided, id, :refused)
        _ -> s.decided
      end

    {a, %{s | callback => rest, decided: decided}}
  end

  defp decide(id, state) do
    Agent.update(__MODULE__, &put_in(&1, [:decided, id], state))
    :ok
  end
end

# The call log: every query of the application Repos with the calling process, and every Need
# call, in order. The optional gate blocks one query of one process, after it ran, so a test can
# hold a resume/3 (and its lock) at a known point or kill it there.
defmodule Elzoo.LedgerCheckoutTest.Log do
  def start!, do: Agent.start(fn -> %{log: [], gate: nil} end, name: __MODULE__)
  def stop!, do: Agent.stop(__MODULE__)
  def reset!, do: Agent.update(__MODULE__, fn _ -> %{log: [], gate: nil} end)

  def query(_event, _measurements, %{query: sql}, _config) do
    pid = self()

    action =
      Agent.get_and_update(__MODULE__, fn s ->
        s = %{s | log: [{:query, pid, sql} | s.log]}

        case s.gate do
          {only, [pattern | rest], test} when only == nil or only == pid ->
            cond do
              not (sql =~ pattern) -> {nil, s}
              rest == [] -> {{:block, test}, %{s | gate: nil}}
              true -> {nil, %{s | gate: {only, rest, test}}}
            end

          _ ->
            {nil, s}
        end
      end)

    with {:block, test} <- action do
      send(test, {:gated, pid})

      receive do
        :open -> :ok
      end
    end
  end

  def need(kind, req),
    do: Agent.update(__MODULE__, &%{&1 | log: [{kind, self(), req} | &1.log]})

  @doc """
  Block `pid`'s query that matches the last pattern once the earlier ones matched in order,
  until the test sends `:open`; the test receives `{:gated, pid}`.
  """
  def gate!(patterns, pid) do
    test = self()
    Agent.update(__MODULE__, &%{&1 | gate: {pid, patterns, test}})
  end

  def entries, do: Agent.get(__MODULE__, &Enum.reverse(&1.log))

  def mark, do: Agent.get(__MODULE__, &length(&1.log))

  @doc "The queries of one process since `mark` that touch a reused Piece's table, and its Need calls."
  def piece_calls(pid, mark) do
    for entry <- Enum.drop(entries(), mark),
        match?({_, ^pid, _}, entry),
        piece_call?(entry),
        do: entry
  end

  defp piece_call?({:query, _, sql}), do: sql =~ ~r/elzoo_(payment|invoice|journal)/
  defp piece_call?(_), do: true

  @doc "The effects of steps and compensations among `entries`, in order, as tags."
  def effects(entries), do: for(entry <- entries, tag = effect(entry), tag != nil, do: tag)

  defp effect({:query, _, "INSERT INTO " <> rest}) do
    cond do
      rest =~ ~r/^"[a-z0-9_]+"\.elzoo_payment_refunds/ -> :refund
      rest =~ ~r/^"[a-z0-9_]+"\.elzoo_invoice_reversals/ -> :reverse_payment
      rest =~ ~r/^"[a-z0-9_]+"\.elzoo_invoice_applications/ -> :apply_payment
      rest =~ ~r/^"[a-z0-9_]+"\.elzoo_journal_operations/ -> :journal
      true -> nil
    end
  end

  defp effect({kind, _, _}) when kind in [:grant, :revoke], do: kind
  defp effect(_), do: nil
end

defmodule Elzoo.LedgerCheckoutTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL

  alias Elzoo.LedgerCheckoutTest.{
    AppRepo,
    FaultRepo,
    Log,
    OwnerRepo,
    RepeatableRepo,
    ShortRepo
  }

  alias Elzoo.TenantIsolation, as: TI

  @app_name "elz378_app"

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

    app = [
      parameters: [application_name: @app_name],
      after_connect: {__MODULE__, :connect, [role, nil]}
    ]

    for {repo, extra} <- [
          {OwnerRepo, [pool_size: 4]},
          {AppRepo, [pool_size: 10, telemetry_prefix: [:elz378, :app]] ++ app},
          {RepeatableRepo,
           [pool_size: 2, after_connect: {__MODULE__, :connect, [role, "repeatable read"]}]},
          {ShortRepo, [pool_size: 4, timeout: 100, telemetry_prefix: [:elz378, :short]] ++ app},
          {FaultRepo, [pool_size: 1, telemetry_prefix: [:elz378, :fault]] ++ app}
        ] do
      {:ok, pid} = repo.start_link([url: url, log: false] ++ extra)
      Process.unlink(pid)
    end

    for prefix <- [:app, :short, :fault] do
      :telemetry.attach(
        "elz378-#{prefix}",
        [:elz378, prefix, :query],
        &Log.query/4,
        nil
      )
    end

    [[database]] = q!(OwnerRepo, "SELECT current_database()")

    if database != url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/"),
      do: flunk("effective database differs from configured; refusing")

    [[version]] = q!(OwnerRepo, "SELECT current_setting('server_version_num')")
    assert String.to_integer(version) in 160_000..169_999
    role
  end

  def stop_repos! do
    for prefix <- [:app, :short, :fault], do: :telemetry.detach("elz378-#{prefix}")

    for repo <- [OwnerRepo, AppRepo, RepeatableRepo, ShortRepo, FaultRepo] do
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
  end

  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows
  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)

  @doc """
  Every application connection is the application role: no superuser, no BYPASSRLS, not the
  session (owner) role and no member of it. Any other answer fails.
  """
  def role_guard!(role) do
    for repo <- [AppRepo, ShortRepo, FaultRepo, RepeatableRepo] do
      [[current, session, super, bypass, member_of_owner]] =
        q!(
          repo,
          "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'MEMBER') FROM pg_roles r WHERE r.rolname = current_user"
        )

      if current != role or current == session or super or bypass or member_of_owner,
        do: flunk("the application connection is not the non-owner application role")
    end
  end

  # ------------------------------------------------------------ schema

  @doc "A random schema with the four Pieces' tables and only their README grants to the role."
  def install!(role) do
    p = "elz378_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.LedgerCheckoutTest.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.LedgerCheckoutTest.Migration, prefix: p, log: false)
    t = &~s("#{p}".#{&1})

    for sql <- [
          ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"),
          # domain/payment-lifecycle
          ~s(GRANT SELECT, INSERT, UPDATE ON #{t.("elzoo_payment_payments")}, #{t.("elzoo_payment_refunds")}, #{t.("elzoo_payment_observations")} TO "#{role}"),
          ~s(GRANT SELECT, INSERT ON #{t.("elzoo_payment_events")} TO "#{role}"),
          # domain/invoice
          ~s(GRANT SELECT, INSERT, UPDATE ON #{t.("elzoo_invoices")}, #{t.("elzoo_invoice_lines")}, #{t.("elzoo_invoice_applications")}, #{t.("elzoo_invoice_reversals")}, #{t.("elzoo_invoice_series")} TO "#{role}"),
          # domain/journal
          ~s(GRANT SELECT, INSERT ON #{t.("elzoo_journal_operations")}, #{t.("elzoo_journal_postings")} TO "#{role}"),
          ~s(GRANT SELECT, INSERT, UPDATE ON #{t.("elzoo_journal_accounts")} TO "#{role}"),
          # assembly/ledger-checkout (README "Grants")
          ~s(GRANT SELECT, INSERT, UPDATE ON #{t.("elzoo_checkout_checkouts")}, #{t.("elzoo_checkout_steps")} TO "#{role}")
        ],
        do: q!(OwnerRepo, sql)

    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  @doc "Rows of one tenant, read as the owner under that tenant's scope."
  def scoped(tenant, sql, params \\ []) do
    {:ok, rows} =
      TI.transact(OwnerRepo, %{tenant: tenant}, fn -> {:ok, q!(OwnerRepo, sql, params)} end)

    rows
  end

  @doc "The advisory locks held by application backends."
  def advisory_locks do
    [[n]] =
      q!(
        OwnerRepo,
        "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE l.locktype = 'advisory' AND l.granted AND a.application_name = $1",
        [@app_name]
      )

    n
  end

  def await!(fun, tries \\ 250) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && await!(fun, tries - 1)
    end
  end
end
