# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants and reads ground truth.
defmodule Elzoo.OauthClientTest.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.OauthClientTest.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role on connections whose default_transaction_isolation is repeatable read.
defmodule Elzoo.OauthClientTest.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.OauthClientTest.Migration do
  @moduledoc false
  use Ecto.Migration

  # The consumer migration: the table owner calls install/1 from up/0.
  def up, do: Elzoo.OauthClient.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

# The local authorization server: a Req function plug, given through the transport Need, that
# records every request and answers from a responder. No socket is opened.
defmodule Elzoo.OauthClientTest.Server do
  @moduledoc false

  def start do
    {:ok, agent} =
      Agent.start_link(fn -> %{requests: [], responder: fn _req, _n -> {500, %{}} end} end)

    agent
  end

  @doc "Answer each later request with `responder.(request, n)`, n counting from 1."
  def respond(agent, responder), do: Agent.update(agent, &%{&1 | responder: responder})

  def requests(agent), do: Agent.get(agent, & &1.requests)
  def count(agent), do: length(requests(agent))

  def plug(agent, test) do
    fn conn ->
      request = %{
        method: conn.method,
        host: conn.host,
        path: conn.request_path,
        form: conn.body_params,
        headers: Map.new(conn.req_headers)
      }

      responder =
        Agent.get_and_update(agent, fn s ->
          {{s.responder, length(s.requests) + 1}, %{s | requests: s.requests ++ [request]}}
        end)

      {fun, n} = responder
      reply(conn, fun.(request, n), test)
    end
  end

  # :hold waits for :go from the test; :never never answers (the Piece's task is killed).
  defp reply(conn, {:hold, then}, test) do
    send(test, {:holding, self()})

    receive do
      :go -> reply(conn, then, test)
    end
  end

  defp reply(conn, :never, test) do
    send(test, {:holding, self()})

    receive do
      :never_sent -> conn
    end
  end

  defp reply(conn, {:transport_error, reason}, _test), do: Req.Test.transport_error(conn, reason)
  defp reply(conn, {status, body}, test), do: reply(conn, {status, body, []}, test)

  defp reply(conn, {status, body, headers}, _test) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end
end

defmodule Elzoo.OauthClientTest.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.OauthClientTest.{AppRepo, OwnerRepo, RepeatableRepo}

  @tables ~w(elzoo_oauth_connections elzoo_oauth_attempts)
  @app_name "elz361_app"

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
  def connect(conn, role, isolation) do
    Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])

    if isolation,
      do: Postgrex.query!(conn, "SET default_transaction_isolation = '#{isolation}'", [])
  end

  def start_repos! do
    url = url!()
    role = app_role!()
    start!(OwnerRepo, url: url, log: false, pool_size: 4)

    start!(AppRepo,
      url: url,
      log: false,
      pool_size: 6,
      parameters: [application_name: @app_name],
      after_connect: {__MODULE__, :connect, [role, nil]}
    )

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

  @doc "The application connection is the non-owner, non-bypass application role."
  def role_guard!(role) do
    [[current, session, super, bypass, member_of_owner]] =
      q!(
        AppRepo,
        "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'MEMBER') FROM pg_roles r WHERE r.rolname = current_user"
      )

    if current != role or current == session or super or bypass or member_of_owner,
      do: flunk("the application connection is not the non-owner application role")
  end

  @doc "A random schema with both tables and only the README grants to the role."
  def install!(role) do
    p = "elz361_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    :persistent_term.put({Elzoo.OauthClientTest.Migration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, Elzoo.OauthClientTest.Migration, prefix: p, log: false)

    tables = Enum.map_join(@tables, ", ", &~s("#{p}".#{&1}))
    q!(OwnerRepo, ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"))
    q!(OwnerRepo, ~s(GRANT SELECT, INSERT, UPDATE ON #{tables} TO "#{role}"))
    p
  end

  def drop!(p), do: q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE))

  def table(p, :connections), do: ~s("#{p}".elzoo_oauth_connections)
  def table(p, :attempts), do: ~s("#{p}".elzoo_oauth_attempts)

  @doc "Every row of every tenant, read as the owner with FORCE dropped in a rolled-back transaction."
  def truth(p) do
    {:error, {:truth, truth}} =
      OwnerRepo.transaction(fn ->
        for t <- @tables, do: q!(OwnerRepo, ~s(ALTER TABLE "#{p}".#{t} NO FORCE ROW LEVEL SECURITY))

        OwnerRepo.rollback(
          {:truth,
           %{
             connections: q!(OwnerRepo, "SELECT * FROM #{table(p, :connections)} ORDER BY 1, 2"),
             attempts: q!(OwnerRepo, "SELECT * FROM #{table(p, :attempts)} ORDER BY 1, 2")
           }}
        )
      end)

    truth
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
        Process.sleep(10)
        await_waiting!(n, tries - 1)
    end
  end
end
