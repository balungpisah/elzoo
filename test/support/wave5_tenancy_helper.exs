Code.require_file(
  "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
  __DIR__
)

# The owner connection: it creates the schema, runs the migrations, grants and reads ground truth.
defmodule Elzoo.Wave5.OwnerRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# The application connection: every connection runs SET ROLE to ELZOO_TEST_APP_ROLE (ELZ-285).
defmodule Elzoo.Wave5.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# Never started: the unreachable Store binding of group 7.
defmodule Elzoo.Wave5.DownRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Wave5.TenancyMigration do
  @moduledoc false
  use Ecto.Migration
  alias Elzoo.{RetentionErasure, TenantIsolation}

  # Consumer tables, the vault and the tenant floor, as a consumer migration calls them.
  def up do
    p = :persistent_term.get({__MODULE__, :prefix})

    execute(
      ~s|CREATE TABLE "#{p}".documents (id bigserial PRIMARY KEY, tenant text NOT NULL, body text NOT NULL)|
    )

    execute(
      ~s|CREATE TABLE "#{p}".notes (id bigserial PRIMARY KEY, tenant text NOT NULL, space text NOT NULL, body text NOT NULL)|
    )

    execute(
      ~s|CREATE TABLE "#{p}".memberships (id bigserial PRIMARY KEY, tenant text NOT NULL, principal text NOT NULL, space text NOT NULL, role text NOT NULL, valid_from bigint NOT NULL, valid_to bigint, revoked_at bigint, source text UNIQUE)|
    )

    execute(
      ~s|CREATE TABLE "#{p}".ledger (id bigserial PRIMARY KEY, tenant text NOT NULL, space text NOT NULL, membership_id bigint NOT NULL REFERENCES "#{p}".memberships (id), entry text NOT NULL)|
    )

    RetentionErasure.Migration.install(p)
    TenantIsolation.Migration.install(p)

    for {table, space} <- Elzoo.Wave5.TenancyHelper.protected() do
      TenantIsolation.Migration.protect({p, table},
        prefix: p,
        tenant_column: "tenant",
        space_column: space
      )
    end
  end
end

defmodule Elzoo.Wave5.WorkPattern do
  @moduledoc false
  # A start or wake input asks for one local work; every other input asks for nothing.
  def on_input(n, %{"kind" => kind}) when kind in ["start", "wake"] do
    action = %{
      "id" => "work-#{n}",
      "kind" => "local_work",
      "schema_id" => "action",
      "schema_version" => 1,
      "payload" => %{"n" => n}
    }

    {:Transition, n + 1, {:some, %{"type" => "request", "version" => 1, "actions" => [action]}}}
  end

  def on_input(n, _input), do: {:Transition, n, :none}

  # The local work of a Run: reports its dispatch to the test process.
  def observe(observer, tenant, id, payload) do
    send(observer, {:work, tenant, id})
    payload
  end
end

defmodule Elzoo.Wave5.TenancyHelper do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL

  alias Elzoo.{
    CheckedCommand,
    KillSwitch,
    PatternStep,
    PayloadSchema,
    ProviderDataPolicy,
    RetentionErasure,
    Secrets,
    TenantIsolation,
    TenantLifecycle,
    TokenVerify
  }

  alias Elzoo.DurableLog.{Postgres, PostgresHarness, TestMigration}
  alias Elzoo.Wave5.{AppRepo, DownRepo, OwnerRepo}

  @now 1_800_000_000
  @recipe "recipe-1"
  @resource "control"
  @limits %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  @hash :crypto.hash(:sha256, "wave5-tenancy-descriptors-v1")

  def now, do: @now
  def recipe, do: @recipe
  def control, do: @resource

  def protected,
    do: [{"documents", nil}, {"notes", "space"}, {"memberships", nil}, {"ledger", "space"}]

  # ------------------------------------------------------------ connections

  @doc "The fixed application role of ELZ-285; the test fails when it is unset or not a role name."
  def app_role! do
    role = System.get_env("ELZOO_TEST_APP_ROLE")

    if not (is_binary(role) and role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/),
      do: flunk("ELZOO_TEST_APP_ROLE must name the application role of ELZ-285; it is unset")

    role
  end

  def start_repos! do
    url = PostgresHarness.database_url!()
    role = app_role!()

    pids =
      for {repo, extra} <- [
            {OwnerRepo, []},
            {AppRepo, [after_connect: {Postgrex, :query!, [~s(SET ROLE "#{role}"), []]}]}
          ] do
        {:ok, pid} = repo.start_link([url: url, pool_size: 6, log: false] ++ extra)
        Process.unlink(pid)
        :ok = PostgresHarness.reachable!(repo)
        pid
      end

    {role, pids}
  end

  @doc """
  The application connection is the application role, which is no superuser, no BYPASSRLS
  role, not the session (owner) role and holds no owner's privileges. Any other answer fails.
  """
  def role_facts(repo) do
    [[current, session, super, bypass, inherits_owner]] =
      q!(
        repo,
        "SELECT current_user, session_user, r.rolsuper, r.rolbypassrls, pg_has_role(current_user, session_user, 'USAGE') FROM pg_roles r WHERE r.rolname = current_user"
      )

    %{
      current: current,
      session: session,
      super: super,
      bypass: bypass,
      inherits_owner: inherits_owner
    }
  end

  def role_guard!(role) do
    facts = role_facts(AppRepo)

    if facts.current != role or facts.current == facts.session or facts.super or facts.bypass or
         facts.inherits_owner,
       do:
         flunk(
           "the application connection is not the non-owner application role: #{inspect(facts)}"
         )

    facts
  end

  # ------------------------------------------------------------ fixture

  def fixture!(role) do
    p = "wave5_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    owner!("CREATE SCHEMA #{Postgres.identifier(p)}")
    :ok = Ecto.Migrator.up(OwnerRepo, 1, TestMigration, prefix: p, log: false)
    :persistent_term.put({Elzoo.Wave5.TenancyMigration, :prefix}, p)
    :ok = Ecto.Migrator.up(OwnerRepo, 2, Elzoo.Wave5.TenancyMigration, prefix: p, log: false)

    # Least privilege for the application role, in this schema only.
    for sql <- [
          "GRANT USAGE ON SCHEMA #{p} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{p}.documents, #{p}.notes TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.memberships TO #{role}",
          "GRANT SELECT, INSERT ON #{p}.ledger TO #{role}",
          "GRANT USAGE ON ALL SEQUENCES IN SCHEMA #{p} TO #{role}",
          "GRANT SELECT, INSERT, UPDATE ON #{p}.elzoo_log_heads, #{p}.elzoo_outbox TO #{role}",
          "GRANT SELECT, INSERT ON #{p}.elzoo_log_records, #{p}.elzoo_checkpoints TO #{role}",
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{p}.elzoo_vault_subjects, #{p}.elzoo_vault_keys, #{p}.elzoo_vault_entries TO #{role}"
        ],
        do: owner!(sql)

    {:ok, kek} = Agent.start_link(fn -> :crypto.strong_rand_bytes(32) end)
    Process.unlink(kek)

    vault =
      RetentionErasure.vault(
        repo: AppRepo,
        prefix: p,
        kek: fn
          version when version in [:current, 1] ->
            {:ok,
             %Secrets.Credential{value: Agent.get(kek, & &1), version: 1, expires_at_unix_ms: 0}}

          _ ->
            {:error, :not_found}
        end
      )

    %{prefix: p, store: store(AppRepo, p), vault: vault, kek: kek}
  end

  def cleanup!(fx) do
    Agent.stop(fx.kek)
    owner!("DROP SCHEMA IF EXISTS #{Postgres.identifier(fx.prefix)} CASCADE")
  end

  def store(repo, prefix), do: Postgres.store(repo, prefix: prefix, fold: fold(), limits: @limits)

  @doc "A Store binding whose Repo was never started: every read fails."
  def down_store(prefix), do: store(DownRepo, prefix)

  defp fold do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn model, _sequence, _kind, _payload -> model end
    }
  end

  def q(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)
  def q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows
  def owner!(sql, params \\ []), do: q!(OwnerRepo, sql, params)

  # Ground truth: the owner with FORCE dropped inside a rolled-back transaction.
  def truth(p, table, columns) do
    {:error, {:rows, rows}} =
      OwnerRepo.transact(fn ->
        q!(OwnerRepo, "ALTER TABLE #{p}.#{table} NO FORCE ROW LEVEL SECURITY")
        {:error, {:rows, q!(OwnerRepo, "SELECT #{columns} FROM #{p}.#{table} ORDER BY 1, 2")}}
      end)

    rows
  end

  def as(scope, fun), do: TenantIsolation.transact(AppRepo, scope, fun)

  # ------------------------------------------------------------ identity and membership

  # T1 and T2 are flat; T3 is R with a barrier child A, its child B and a sibling C.
  def spaces do
    [
      %{id: "t1-home", tenant: "T1", parent: nil, block_inheritance: false},
      %{id: "t2-home", tenant: "T2", parent: nil, block_inheritance: false},
      %{id: "r", tenant: "T3", parent: nil, block_inheritance: false},
      %{id: "a", tenant: "T3", parent: "r", block_inheritance: true},
      %{id: "b", tenant: "T3", parent: "a", block_inheritance: false},
      %{id: "c", tenant: "T3", parent: "r", block_inheritance: false}
    ]
  end

  def roles do
    [
      %{id: "reader", permissions: ["docs.read"]},
      %{id: "editor", permissions: ["docs.read", "docs.write"]},
      %{id: "treasurer", permissions: ["docs.read", "money.pay"]},
      %{id: "auditor", permissions: ["ledger.read"]}
    ]
  end

  @doc "The host's membership facts: static spaces and roles, and the tenant's stored rows."
  def facts(p, tenant) do
    {:ok, %{rows: rows}} =
      as(%{tenant: tenant}, fn ->
        q(
          AppRepo,
          "SELECT principal, space, role, valid_from, valid_to, revoked_at FROM #{p}.memberships ORDER BY id"
        )
      end)

    memberships =
      for [principal, space, role, from, to, revoked] <- rows,
          do: %{
            principal: principal,
            space: space,
            role: role,
            valid_from: from,
            valid_to: to,
            revoked_at: revoked
          }

    %{spaces: spaces(), roles: roles(), memberships: memberships, non_inheriting: ["money."]}
  end

  @doc "Inserts a membership row as the application role: its ID, or :exists for a known source."
  def add_membership!(p, tenant, principal, space, role, source \\ nil) do
    {:ok, id} =
      as(%{tenant: tenant}, fn ->
        {:ok, %{rows: rows}} =
          q(
            AppRepo,
            "INSERT INTO #{p}.memberships (tenant, principal, space, role, valid_from, source) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (source) DO NOTHING RETURNING id",
            [tenant, principal, space, role, @now - 100, source]
          )

        {:ok, with([[id]] <- rows, do: id, else: ([] -> :exists))}
      end)

    id
  end

  @doc """
  API keys generated in the test: the host stores HMAC-SHA-256(digest key, secret) per key ID.
  Returns `{config, keys}` with each principal's presented key.
  """
  def api_keys(principals) do
    digest_key = :crypto.strong_rand_bytes(32)

    entries =
      for {fields, n} <- Enum.with_index(principals), into: %{} do
        key_id = "key#{n}" <> Base.encode16(:crypto.strong_rand_bytes(4))
        secret = :crypto.strong_rand_bytes(32)

        {key_id,
         %{
           key: "ek_" <> key_id <> "_" <> Base.url_encode64(secret, padding: false),
           digest: :crypto.mac(:hmac, :sha256, digest_key, secret),
           fields: Map.put(fields, :auth_epoch, 1)
         }}
      end

    config =
      TokenVerify.api_key_config(
        prefix: "ek",
        digest_key: fn ->
          {:ok,
           %Secrets.Credential{
             value: digest_key,
             version: 1,
             expires_at_unix_ms: (@now + 3_600) * 1_000
           }}
        end,
        lookup: fn key_id ->
          case Map.fetch(entries, key_id) do
            {:ok, e} ->
              {:ok,
               %{
                 digest: e.digest,
                 principal: e.fields,
                 current_epoch: 1,
                 expires_at_unix_s: nil,
                 revoked: false
               }}

            :error ->
              {:error, :not_found}
          end
        end
      )

    keys = Map.new(entries, fn {_, e} -> {e.fields.id, e.key} end)
    {config, keys}
  end

  # ------------------------------------------------------------ checked commands

  @ks_port %{
    "id" => "kill-switch",
    "direction" => "input",
    "schema_id" => "kill_switch/change",
    "schema_version" => 1
  }
  @tl_port %{
    "id" => "tenant-lifecycle",
    "direction" => "input",
    "schema_id" => "tenant_lifecycle/command",
    "schema_version" => 1
  }
  @note_port %{
    "id" => "note",
    "direction" => "input",
    "schema_id" => "notes/write",
    "schema_version" => 1
  }

  defp schema(port, properties, required) do
    {:ok, schema} =
      PayloadSchema.build(port, %{
        "type" => "object",
        "required" => required,
        "additionalProperties" => false,
        "properties" => properties
      })

    schema
  end

  defp descriptor(id, class, port, schema, prepare, gate) do
    %{
      id: id,
      version: 1,
      content_hash: @hash,
      effect_class: class,
      port: port,
      schema: schema,
      prepare: prepare,
      gate: gate,
      approval: %{verifiers: ["command-reviewer"], max_age: 60_000}
    }
  end

  @doc "The kill-switch descriptor. Its gate is the host's own policy: it never calls check/2."
  def ks_handle(store) do
    s =
      schema(
        @ks_port,
        %{
          "op" => %{"enum" => ["engage", "release"]},
          "kind" => %{"enum" => ["tenant", "recipe", "tool"]},
          "id" => %{"type" => "string"},
          "reason" => %{"type" => "string"}
        },
        ["op", "kind", "id", "reason"]
      )

    {:ok, h} =
      CheckedCommand.new(
        store,
        descriptor(
          "kill-switch/change",
          "kill_switch",
          @ks_port,
          s,
          &KillSwitch.prepare/3,
          %{call: fn _frame, _context -> :allow end}
        )
      )

    h
  end

  @doc "The lifecycle descriptor, its gate over the read taken just before the command."
  def tl_handle(store, read, prepare \\ &TenantLifecycle.prepare/3) do
    s =
      schema(
        @tl_port,
        %{
          "op" => %{"enum" => ~w(provision activate suspend close erase invite accept revoke)},
          "id" => %{"type" => "string"},
          "space" => %{"type" => "string"},
          "role" => %{"type" => "string"},
          "invitee" => %{"type" => ["string", "null"]},
          "expires_at" => %{"type" => "integer"}
        },
        ["op"]
      )

    {:ok, h} =
      CheckedCommand.new(
        store,
        descriptor(
          "tenant-lifecycle/command",
          "tenant_lifecycle",
          @tl_port,
          s,
          prepare,
          TenantLifecycle.gate(read)
        )
      )

    h
  end

  @doc "A tenant's ordinary command: writes one text field of its resource."
  def note_handle(store, gate) do
    s = schema(@note_port, %{"text" => %{"type" => "string"}}, ["text"])

    {:ok, h} =
      CheckedCommand.new(
        store,
        descriptor("notes/write", "notes", @note_port, s, &note_prepare/3, gate)
      )

    h
  end

  def note_prepare(snapshot, request, _facts) do
    {:ok, [%{target: request.resource, field: "text", value: {:text, request.payload["text"]}}],
     {:record, [{"revision", snapshot.revision + 1}]}}
  end

  @doc "The host gate of both engines over one kill-switch read; an unmapped action is denied."
  def switch_call(read, tools) do
    fn checked, %{tenant: tenant} ->
      %{"actions" => [action]} = PatternStep.encode(checked)

      case Map.fetch(tools, action["schema_id"]) do
        {:ok, tool} -> KillSwitch.check(read, %{tenant: tenant, recipe: @recipe, tool: tool})
        :error -> {:deny, "unmapped_action"}
      end
    end
  end

  def switch_gate(read), do: %{call: switch_call(read, %{"notes/write" => nil})}

  def scope(tenant, actor, resources \\ [@resource]),
    do: %{tenant: tenant, actor: actor, resources: resources}

  def read(store, tenant, actor \\ "operator", resource \\ @resource),
    do: CheckedCommand.resource(ks_handle(store), scope(tenant, actor, [resource]), resource)

  def policy(class) do
    artifact = %{
      id: "policy-" <> class,
      version: 1,
      effect_classes: [class],
      rules: [%{id: "allow-" <> class, effect_class: class, verdict: :allow}]
    }

    Map.put(artifact, :content_hash, :crypto.hash(:sha256, :erlang.term_to_binary(artifact)))
  end

  @doc """
  The host's command: a fresh read of the resource, exact-value authority for the writes that
  this command prepares over it, and execute. `handle_fun` builds the handle over the read.
  """
  def plan(store, handle_fun, tenant, actor, request, data, prepare, class) do
    {:ok, snap} = read = read(store, tenant, actor, request.resource)
    request = Map.put_new(request, :expected_revision, snap.revision)

    own =
      case prepare.(snap, request, %{tenant: tenant, actor: actor, data: data}) do
        {:ok, writes, _} -> writes
        {:refused, _} -> []
      end

    context = %{
      tenant: tenant,
      actor: actor,
      policy: policy(class),
      own: own,
      parent: :none,
      facts: data
    }

    {handle_fun.(read), context, request}
  end

  def run({handle, context, request}), do: CheckedCommand.execute(handle, context, request)

  def request(op_id, payload, resource \\ @resource),
    do: %{operation_id: op_id, resource: resource, payload: payload}

  def switch(store, tenant, op_id, op, reason \\ "incident") do
    payload = %{"op" => op, "kind" => "tenant", "id" => tenant, "reason" => reason}

    plan(
      store,
      fn _ -> ks_handle(store) end,
      tenant,
      "operator",
      request(op_id, payload),
      {:record, [{"now", @now * 1_000}]},
      &KillSwitch.prepare/3,
      "kill_switch"
    )
    |> run()
  end

  def lifecycle_data(op, overrides \\ []) do
    base =
      case op do
        "erase" -> [{"vault_erased", true}]
        _ -> []
      end

    pairs =
      Enum.reduce(overrides, [{"now", @now} | base], fn {k, v}, acc ->
        List.keystore(acc, k, 0, {k, v})
      end)

    {:record, Enum.sort_by(pairs, &elem(&1, 0))}
  end

  def lifecycle_plan(store, tenant, actor, op_id, payload, data, prepare \\ nil) do
    plan(
      store,
      fn read ->
        if prepare, do: tl_handle(store, read, prepare), else: tl_handle(store, read)
      end,
      tenant,
      actor,
      request(op_id, payload),
      data,
      &TenantLifecycle.prepare/3,
      "tenant_lifecycle"
    )
  end

  def lifecycle(store, tenant, op_id, op, data \\ nil),
    do:
      run(
        lifecycle_plan(store, tenant, "operator", op_id, %{"op" => op}, data || lifecycle_data(op))
      )

  def activate!(store, tenant) do
    assert {:completed, _} = lifecycle(store, tenant, "provision-" <> tenant, "provision")
    assert {:completed, _} = lifecycle(store, tenant, "activate-" <> tenant, "activate")
  end

  @doc "A notes command whose gate is the kill-switch check over a read taken just before it."
  def note_plan(store, tenant, op_id, text, opts \\ []) do
    gate_fun = Keyword.get(opts, :gate, &switch_gate/1)

    plan(
      store,
      # The gate's read is of the tenant control resource, taken just before execute/3.
      fn _note -> note_handle(store, gate_fun.(read(store, tenant))) end,
      tenant,
      Keyword.get(opts, :actor, "writer"),
      request(op_id, %{"text" => text}, Keyword.get(opts, :resource, "note-1")),
      {:record, []},
      &note_prepare/3,
      "notes"
    )
  end

  def note(store, tenant, op_id, text, opts \\ []),
    do: run(note_plan(store, tenant, op_id, text, opts))

  # ------------------------------------------------------------ provider data policy

  @classes Map.new(ProviderDataPolicy.data_classes(), &{Atom.to_string(&1), &1})

  @doc """
  The host gate of a model action: the payload names its provider, region, retention and the
  data classes the host tagged. Every result other than :allow is DENY with a fixed code.
  """
  def provider_call(policy) do
    fn checked, _context ->
      %{"actions" => [action]} = PatternStep.encode(checked)
      p = action["payload"]

      request = %{
        provider: p["provider"],
        region: p["region"],
        retention: p["retention"],
        classes: Enum.map(p["classes"], &Map.get(@classes, &1, :unknown))
      }

      case ProviderDataPolicy.decide(policy, request) do
        :allow -> :allow
        {:deny, reason} -> {:deny, "data_" <> Atom.to_string(reason)}
        {:error, _} -> {:deny, "data_policy_unavailable"}
      end
    end
  end

  # ------------------------------------------------------------ stored rows

  @doc """
  Every row of every table in the fixture schema, as JSON text (bytea as hex), read by the
  owner with FORCE dropped on the protected tables inside a rolled-back transaction.
  """
  def all_rows(p) do
    {:error, {:rows, rows}} =
      OwnerRepo.transact(fn ->
        for {table, _} <- protected(),
            do: q!(OwnerRepo, "ALTER TABLE #{p}.#{table} NO FORCE ROW LEVEL SECURITY")

        tables =
          q!(OwnerRepo, "SELECT tablename FROM pg_tables WHERE schemaname = $1 ORDER BY 1", [p])

        rows =
          for [table] <- tables,
              [row] <- q!(OwnerRepo, "SELECT row_to_json(t)::text FROM #{p}.#{table} t"),
              do: {table, row}

        {:error, {:rows, rows}}
      end)

    rows
  end

  def stream(tenant),
    do:
      "cc1:" <>
        Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
          padding: false
        )

  @doc "Raw values and the hex form that a bytea column shows them in."
  def leaks(p, values) do
    needles = Enum.flat_map(values, &[&1, Base.encode16(&1, case: :lower)])

    for {table, row} <- all_rows(p),
        Enum.any?(needles, &String.contains?(row, &1)),
        uniq: true,
        do: table
  end

  def log_rows(p) do
    for [stream, sequence, kind, version, payload, nonce, digest] <-
          owner!(
            "SELECT stream, sequence, kind, schema_version, payload, nonce, digest FROM #{p}.elzoo_log_records ORDER BY stream, sequence"
          ),
        do:
          {{stream, sequence},
           :crypto.hash(
             :sha256,
             :erlang.term_to_binary({kind, version, payload, nonce, digest})
           )}
  end
end
