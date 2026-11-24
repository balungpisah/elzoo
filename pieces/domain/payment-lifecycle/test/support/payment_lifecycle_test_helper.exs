# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants, holds row locks and
# reads ground truth.
defmodule Elzoo.PaymentLifecycleTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.PaymentLifecycleTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.PaymentLifecycleTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.PaymentLifecycleTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner calls install/1 from up/0.
  def up,
    do: Elzoo.PaymentLifecycle.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

# The host's two Bindings of one provider account.
defmodule Elzoo.PaymentLifecycleTest.ChargeBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :charge, provider_account: "acct-1"
end

defmodule Elzoo.PaymentLifecycleTest.RefundBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :refund, provider_account: "acct-1"
end

# The scripted provider: each call pops the next scripted answer of its callback and records
# the call with its idempotency_key. An answer :crash kills the calling task after the call is
# recorded (a crash after the send). Events are JSON signed with HMAC-SHA256 over the raw body,
# checked before the body is parsed.
defmodule Elzoo.PaymentLifecycleTest.Script do
  @behaviour Elzoo.PaymentLifecycle.Provider
  @key "scripted-provider-signing-key"

  def start! do
    {:ok, pid} = Agent.start(fn -> %{answers: %{}, calls: []} end, name: __MODULE__)
    pid
  end

  def stop!, do: Agent.stop(__MODULE__)

  def reset!, do: Agent.update(__MODULE__, fn _ -> %{answers: %{}, calls: []} end)

  def script(callback, answers),
    do: Agent.update(__MODULE__, &put_in(&1, [:answers, callback], answers))

  @doc "The recorded calls, oldest first, as {callback, request}."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def calls(callback), do: for({^callback, req} <- calls(), do: req)

  @impl true
  def charge(req), do: answer(:charge, req)
  @impl true
  def refund(req), do: answer(:refund, req)
  @impl true
  def poll(req), do: answer(:poll, req)

  defp answer(callback, req) do
    a =
      Agent.get_and_update(__MODULE__, fn s ->
        {a, rest} =
          case Map.get(s.answers, callback, []) do
            [a | rest] -> {a, rest}
            [] -> {{:unknown, :transport}, []}
          end

        {a, %{s | answers: Map.put(s.answers, callback, rest), calls: [{callback, req} | s.calls]}}
      end)

    if a == :crash, do: Process.exit(self(), :kill), else: a
  end

  @impl true
  def verify_event(raw, headers) do
    with {_, sig} <- List.keyfind(headers, "x-signature", 0),
         true <- :crypto.hash_equals(sig, sign(raw)),
         {:ok, %{"id" => id, "op" => op, "state" => s, "currency" => c, "units" => u, "ref" => r}} <-
           Jason.decode(raw),
         {:ok, currency} <- Elzoo.Money.parse(c),
         {:ok, amount} <- Elzoo.Money.from_minor_units(currency, u) do
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

  def sign(raw), do: :crypto.mac(:hmac, :sha256, @key, raw) |> Base.encode16(case: :lower)

  @doc "A signed event request for apply_event/3."
  def event(id, op, state, {currency, units}, ref) do
    raw =
      Jason.encode!(%{
        "id" => id,
        "op" => Tuple.to_list(op) |> Enum.map(&to_string/1),
        "state" => Atom.to_string(state),
        "currency" => currency,
        "units" => units,
        "ref" => ref
      })

    %{raw_body: raw, headers: [{"x-signature", sign(raw)}]}
  end
end

defmodule Elzoo.PaymentLifecycleTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.PaymentLifecycleTest.{AppRepo, OwnerRepo, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @tables ~w(payments refunds events observations)
  @app_name "elz365_app"

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
             pool_size: 8,
             telemetry_prefix: [:elz365, :app],
             parameters: [application_name: @app_name],
             after_connect: {__MODULE__, :connect, [role, nil]}
           ]},
          {RepeatableRepo,
           [pool_size: 2, after_connect: {__MODULE__, :connect, [role, "repeatable read"]}]}
        ] do
      {:ok, pid} = repo.start_link([url: url, log: false] ++ extra)
      Process.unlink(pid)
    end

    [[database]] = q!(OwnerRepo, "SELECT current_database()")

    if database != url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/"),
      do: flunk("effective database differs from configured; refusing")

    [[version]] = q!(OwnerRepo, "SELECT current_setting('server_version_num')")
    assert String.to_integer(version) in 160_000..169_999
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

  @doc "A random schema with the four tables and only the README grants to the role."
  def install!(role) do
    p = "elz365_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.PaymentLifecycleTest.Migration, :prefix}, p)

    :ok =
      Ecto.Migrator.up(OwnerRepo, 1, Elzoo.PaymentLifecycleTest.Migration, prefix: p, log: false)

    for sql <- [
          ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"),
          ~s(GRANT SELECT, INSERT, UPDATE ON #{table(p, :payments)}, #{table(p, :refunds)}, #{table(p, :observations)} TO "#{role}"),
          ~s(GRANT SELECT, INSERT ON #{table(p, :events)} TO "#{role}")
        ],
        do: q!(OwnerRepo, sql)

    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def table(p, name), do: ~s("#{p}".elzoo_payment_#{name})

  @doc "The Repo refuses the observation writes until restore_observations!/2 (a real 42501)."
  def refuse_observations!(p, role),
    do: q!(OwnerRepo, ~s(REVOKE INSERT ON #{table(p, :observations)} FROM "#{role}"))

  def restore_observations!(p, role),
    do: q!(OwnerRepo, ~s(GRANT INSERT ON #{table(p, :observations)} TO "#{role}"))

  # ------------------------------------------------------------ ground truth

  @doc "Every row of every tenant, read as the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:truth, truth}} =
      OwnerRepo.transaction(fn ->
        for t <- @tables,
            do: q!(OwnerRepo, "ALTER TABLE #{table(p, t)} NO FORCE ROW LEVEL SECURITY")

        read = fn name, sql -> {name, q!(OwnerRepo, sql)} end

        OwnerRepo.rollback(
          {:truth,
           Map.new([
             read.(
               :payments,
               "SELECT tenant, payment_id, state, provider_ref, revision, amount FROM #{table(p, :payments)} ORDER BY 1, 2"
             ),
             read.(
               :refunds,
               "SELECT tenant, payment_id, refund_id, requested, amount, state, provider_ref FROM #{table(p, :refunds)} ORDER BY 1, 2, 3"
             ),
             read.(
               :events,
               "SELECT tenant, event_id, payment_id, applied FROM #{table(p, :events)} ORDER BY 1, 2"
             ),
             read.(
               :observations,
               "SELECT tenant, payment_id, operation_ref, seq, attempt, source, answer, state, applied FROM #{table(p, :observations)} ORDER BY 1, 2, 3, 4"
             )
           ])}
        )
      end)

    truth
  end

  # ------------------------------------------------------------ concurrency

  @doc "Another connection (the owner, under the tenant scope) holds one payment row's lock."
  def hold!(p, tenant, payment_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, :released} =
          TI.transact(OwnerRepo, %{tenant: tenant}, fn ->
            [[1]] =
              q!(
                OwnerRepo,
                "SELECT 1 FROM #{table(p, :payments)} WHERE tenant = $1 AND payment_id = $2 FOR UPDATE",
                [tenant, payment_id]
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

  def forward(_event, _measurements, metadata, pid), do: send(pid, {:app_query, metadata.query})
end
