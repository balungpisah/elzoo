# SPDX-License-Identifier: Apache-2.0
# The owner connection: it creates the schema, runs the migration, grants and reads ground truth.
defmodule Elzoo.WebhookOut.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connections: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.WebhookOut.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role with its own telemetry prefix, so a test can hold one claim open.
defmodule Elzoo.WebhookOut.RaceRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application role whose transactions default to REPEATABLE READ.
defmodule Elzoo.WebhookOut.IsoRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# Started and killed inside one test: its connections drop.
defmodule Elzoo.WebhookOut.CrashRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# Never started: every call on it fails.
defmodule Elzoo.WebhookOut.DownRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.WebhookOut.TestBinding do
  use Elzoo.WebhookOut.Binding, provider_account: "test:webhooks", recovery_grace_ms: 1000
end

defmodule Elzoo.WebhookOut.TestMigration do
  @moduledoc false
  use Ecto.Migration

  # The Piece's DDL and the dead-letter store's, as a consumer migration calls them.
  def up do
    prefix = :persistent_term.get({__MODULE__, :prefix})
    Elzoo.WebhookOut.Migration.install(prefix)
    Elzoo.DeadLetterStore.Migration.install(prefix)
  end
end

defmodule Elzoo.WebhookOut.Harness do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Elzoo.WebhookOut.{AppRepo, IsoRepo, OwnerRepo, RaceRepo, TestMigration}

  @tables ~w(elzoo_webhook_endpoints elzoo_webhook_events elzoo_webhook_deliveries elzoo_webhook_observations)

  @doc "Fail-closed target guard: ELZOO_TEST_DATABASE_URL must name the effective database."
  def url! do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        flunk("ELZOO_TEST_DATABASE_URL is required; PostgreSQL tests fail closed (never skipped)")

    if url |> URI.parse() |> Map.get(:path, "") |> to_string() |> String.trim_leading("/") == "",
      do: flunk("ELZOO_TEST_DATABASE_URL names no database; refusing")

    url
  end

  @doc "The fixed application role of ELZ-285; the test fails when it is unset."
  def app_role! do
    role = System.get_env("ELZOO_TEST_APP_ROLE")

    if not (is_binary(role) and role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/),
      do: flunk("ELZOO_TEST_APP_ROLE must name the application role of ELZ-285; it is unset")

    role
  end

  def after_connect(conn, role, statements) do
    Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])
    Enum.each(statements, &Postgrex.query!(conn, &1, []))
  end

  @doc "Repo options of the application role."
  def app_opts(role, extra \\ []),
    do: [after_connect: {__MODULE__, :after_connect, [role, extra]}]

  @doc "Start every Repo on DBConnection.ConnectionPool (not the Sandbox)."
  def start_repos! do
    role = app_role!()

    for {repo, opts} <- [
          {OwnerRepo, []},
          {AppRepo, app_opts(role) ++ [telemetry_prefix: [:elzoo_wo_app]]},
          {RaceRepo, app_opts(role) ++ [telemetry_prefix: [:elzoo_wo_race]]},
          {IsoRepo,
           app_opts(role, [
             "SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ"
           ])}
        ] do
      start!(repo, opts)
    end

    %{role: role}
  end

  @doc "Start one Repo; returns its pid, stopped on exit."
  def start!(repo, opts) do
    url = url!()
    configured = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")

    {:ok, pid} =
      repo.start_link(
        [url: url, pool: DBConnection.ConnectionPool, pool_size: 6, log: false] ++ opts
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
    pid
  end

  @doc "The application connection is the non-owner, non-bypass application role."
  def role_facts!(repo, role) do
    [[current, session, super, bypass, member]] =
      q!(
        repo,
        "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'MEMBER') FROM pg_roles r WHERE r.rolname = current_user"
      )

    if current != role or current == session or super or bypass or member,
      do: flunk("the application connection is not the non-owner application role")

    :ok
  end

  @doc "A random schema with both migrations and only the README grants for `role`."
  def install!(role) do
    p = "elz362_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    q!(OwnerRepo, ~s(CREATE SCHEMA "#{p}"))
    ExUnit.Callbacks.on_exit(fn -> q!(OwnerRepo, ~s(DROP SCHEMA IF EXISTS "#{p}" CASCADE)) end)
    :persistent_term.put({TestMigration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 1, TestMigration, prefix: p, log: false)

    # The README grants of integration/webhook-out, then delivery/dead-letter-store's.
    for sql <- [
          ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"),
          ~s(GRANT SELECT, INSERT ON "#{p}".elzoo_webhook_endpoints, "#{p}".elzoo_webhook_events TO "#{role}"),
          ~s(GRANT SELECT, INSERT, UPDATE ON "#{p}".elzoo_webhook_deliveries, "#{p}".elzoo_webhook_observations TO "#{role}"),
          ~s(GRANT SELECT, INSERT, UPDATE, DELETE ON "#{p}".elzoo_dead_letters TO "#{role}")
        ],
        do: q!(OwnerRepo, sql)

    p
  end

  def truncate!(p) do
    tables = Enum.map_join(@tables ++ ["elzoo_dead_letters"], ", ", &~s("#{p}".#{&1}))
    q!(OwnerRepo, "TRUNCATE #{tables}")
  end

  @doc "Ground truth of one table, read by the owner with FORCE dropped in a rolled-back transaction."
  def truth(p, table, columns \\ "*") do
    {:error, {:rows, rows}} =
      OwnerRepo.transact(fn ->
        q!(OwnerRepo, ~s(ALTER TABLE "#{p}".#{table} NO FORCE ROW LEVEL SECURITY))
        {:error, {:rows, q!(OwnerRepo, ~s|SELECT #{columns} FROM "#{p}".#{table} ORDER BY 1, 2|)}}
      end)

    rows
  end

  @doc "Lock requests that wait (pg_locks, not granted); the tests run one at a time."
  def waiting do
    [[n]] = q!(OwnerRepo, "SELECT count(*) FROM pg_locks WHERE NOT granted")
    n
  end

  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)
  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows

  def poll(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("poll timeout")
      true -> Process.sleep(10) && poll(fun, tries - 1)
    end
  end

  @doc """
  The Standard Webhooks receiver check, written from the specification
  (https://www.standardwebhooks.com/, "Verifying webhook authenticity"): the signed content is
  `msg_id.timestamp.payload`, the key is the base64 decoding of the secret after the `whsec_`
  prefix, and the header is a space-delimited list of `v1,<base64 HMAC-SHA-256>` entries.
  """
  def verify_signature(secret, headers, body) do
    id = header(headers, "webhook-id")
    ts = header(headers, "webhook-timestamp")
    "whsec_" <> encoded = secret
    key = Base.decode64!(encoded)
    expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, id <> "." <> ts <> "." <> body))

    header(headers, "webhook-signature")
    |> String.split(" ")
    |> Enum.any?(fn
      "v1," <> sig -> byte_size(sig) == byte_size(expected) and :crypto.hash_equals(sig, expected)
      _ -> false
    end)
  end

  def header(headers, name) do
    case for({^name, v} <- headers, do: v) do
      [v] -> v
      _ -> flunk("expected exactly one #{name} header")
    end
  end

  def secret, do: "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
end
