Code.require_file("support/wave5_tenancy_helper.exs", __DIR__)

defmodule Elzoo.Wave5.TenancyTest do
  # ELZ-286: the Wave 5 Pieces together on real PostgreSQL, the application connection running
  # as the fixed non-owner, non-bypass role of ELZ-285. Each test names its acceptance group.
  use ExUnit.Case, async: false

  alias Elzoo.{
    CheckedCommand,
    EgressPolicy,
    KillSwitch,
    McpRuntime,
    Membership,
    PiiRedaction,
    Principal,
    RetentionErasure,
    RunEngine,
    TenantIsolation,
    TenantLifecycle,
    TokenVerify
  }

  alias Elzoo.RunEngine.{TestHelper, TestPattern}
  alias Elzoo.Wave5.{AppRepo, WorkPattern}
  alias Elzoo.Wave5.TenancyHelper, as: H

  @now H.now()

  setup_all do
    {role, repos} = H.start_repos!()
    # Registered before the guard, so a failed guard still stops both pools.
    on_exit(fn -> for pid <- repos, Process.alive?(pid), do: Supervisor.stop(pid) end)
    # Fails, never skips: the application connection must be the application role.
    H.role_guard!(role)
    engine_repo = TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    Process.unlink(registry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    Process.unlink(units)

    on_exit(fn ->
      for pid <- [registry, units, engine_repo], Process.alive?(pid), do: Supervisor.stop(pid)
    end)

    %{role: role}
  end

  setup %{role: role} do
    fx = H.fixture!(role)
    on_exit(fn -> H.cleanup!(fx) end)
    %{fx: fx, p: fx.prefix}
  end

  defp denied?(result),
    do: match?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}, result)

  defp sql(statement, params \\ []), do: H.q(AppRepo, statement, params)

  defp bodies(p, table, scope) do
    {:ok, rows} =
      H.as(scope, fn ->
        {:ok, List.flatten(H.q!(AppRepo, "SELECT body FROM #{p}.#{table} ORDER BY body"))}
      end)

    rows
  end

  defp seed!(p, table, scope, rows) do
    {:ok, _} =
      H.as(scope, fn ->
        for row <- rows do
          {columns, values} = Enum.unzip(row)
          marks = Enum.map_join(1..length(values), ", ", &"$#{&1}")

          {:ok, _} =
            sql("INSERT INTO #{p}.#{table} (#{Enum.join(columns, ", ")}) VALUES (#{marks})", values)
        end

        {:ok, :seeded}
      end)
  end

  defp human(id, tenant, scopes \\ [], spaces \\ []),
    do: %{
      kind: :human,
      id: id,
      tenant: tenant,
      allowed_scopes: scopes,
      allowed_spaces: spaces
    }

  # ------------------------------------------------------------ 1

  test "1 database floor as the application role: verify, T1-only rows, 42501, owner DDL refused, no row outside the helper",
       %{p: p, role: role} do
    for {table, space} <- H.protected() do
      assert TenantIsolation.verify(AppRepo, {p, table},
               prefix: p,
               tenant_column: "tenant",
               space_column: space
             ) == :ok,
             table
    end

    for {t, b} <- [{"T1", "a"}, {"T1", "b"}, {"T2", "c"}, {"T2", "d"}],
        do: seed!(p, "documents", %{tenant: t}, [[{"tenant", t}, {"body", b}]])

    seed!(p, "notes", %{tenant: "T1", spaces: ["t1-home"]}, [
      [{"tenant", "T1"}, {"space", "t1-home"}, {"body", "n1"}]
    ])

    m1 = H.add_membership!(p, "T1", "t1-alice", "t1-home", "editor")

    seed!(p, "ledger", %{tenant: "T1", spaces: ["t1-home"]}, [
      [{"tenant", "T1"}, {"space", "t1-home"}, {"membership_id", m1}, {"entry", "e1"}]
    ])

    # Under T1: reads, updates and deletes touch only T1 rows.
    assert {:ok, {["a", "b"], 2, 0, 0, 1}} =
             H.as(%{tenant: "T1"}, fn ->
               seen = List.flatten(H.q!(AppRepo, "SELECT body FROM #{p}.documents ORDER BY body"))
               {:ok, %{num_rows: updated}} = sql("UPDATE #{p}.documents SET body = body || '1'")

               {:ok, %{num_rows: other_updated}} =
                 sql("UPDATE #{p}.documents SET body = 'x' WHERE body IN ('c', 'd')")

               {:ok, %{num_rows: other_deleted}} =
                 sql("DELETE FROM #{p}.documents WHERE body IN ('c', 'd')")

               {:ok, %{num_rows: deleted}} = sql("DELETE FROM #{p}.documents WHERE body = 'b1'")
               {:ok, {seen, updated, other_updated, other_deleted, deleted}}
             end)

    truth = [["T1", "a1"], ["T2", "c"], ["T2", "d"]]
    assert H.truth(p, "documents", "tenant, body") == truth

    # An insert or a move to T2 under T1 is SQLSTATE 42501 and leaves no change.
    assert denied?(
             H.as(%{tenant: "T1"}, fn ->
               sql("INSERT INTO #{p}.documents (tenant, body) VALUES ('T2', 'z')")
             end)
           )

    assert denied?(H.as(%{tenant: "T1"}, fn -> sql("UPDATE #{p}.documents SET tenant = 'T2'") end))

    assert denied?(
             H.as(%{tenant: "T1", spaces: ["t1-home"]}, fn ->
               sql("UPDATE #{p}.notes SET tenant = 'T2'")
             end)
           )

    assert H.truth(p, "documents", "tenant, body") == truth

    # The application role cannot lift the floor.
    for {table, _} <- H.protected(),
        statement <- [
          "ALTER TABLE #{p}.#{table} NO FORCE ROW LEVEL SECURITY",
          "ALTER TABLE #{p}.#{table} DISABLE ROW LEVEL SECURITY",
          "DROP POLICY elzoo_tenant_floor ON #{p}.#{table}"
        ] do
      assert denied?(sql(statement)), statement
    end

    for {table, _} <- H.protected() do
      result =
        AppRepo.transact(fn ->
          {:ok, _} = sql("SET LOCAL row_security = off")

          case sql("SELECT count(*) FROM #{p}.#{table}") do
            {:error, error} -> AppRepo.rollback(error)
            {:ok, result} -> {:ok, result.rows}
          end
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege} = error}} =
               result,
             table

      assert error.message =~ "row-level security"
    end

    # The floor is unchanged, and outside the helper no protected table shows a row.
    for {table, space} <- H.protected() do
      assert TenantIsolation.verify(AppRepo, {p, table},
               prefix: p,
               tenant_column: "tenant",
               space_column: space
             ) == :ok

      assert H.q!(AppRepo, "SELECT count(*) FROM #{p}.#{table}") == [[0]], table
      assert length(H.truth(p, table, "tenant, id")) > 0, table
    end

    assert %{current: ^role, super: false, bypass: false, member_of_owner: false} =
             H.role_facts(AppRepo)
  end

  # ------------------------------------------------------------ 2, 3, 4

  defp t3_notes!(p) do
    seed!(p, "notes", %{tenant: "T3", spaces: ["r", "a", "b", "c"]}, [
      [{"tenant", "T3"}, {"space", "r"}, {"body", "note-r"}],
      [{"tenant", "T3"}, {"space", "a"}, {"body", "note-a"}],
      [{"tenant", "T3"}, {"space", "b"}, {"body", "note-b"}],
      [{"tenant", "T3"}, {"space", "c"}, {"body", "note-c"}]
    ])

    seed!(p, "notes", %{tenant: "T1", spaces: ["t1-home"]}, [
      [{"tenant", "T1"}, {"space", "t1-home"}, {"body", "note-t1"}]
    ])
  end

  # The space list for one permission, from the stored memberships, and the rows it shows.
  defp visible(p, principal, permission, table \\ "notes") do
    {:ok, spaces} = Membership.spaces(principal, permission, H.facts(p, principal.tenant), @now)
    {spaces, bodies(p, table, %{tenant: principal.tenant, spaces: spaces})}
  end

  defp principals(keys, config) do
    Map.new(keys, fn {id, key} ->
      assert {:ok, %Principal{id: ^id} = principal} = TokenVerify.verify_api_key(key, config, @now)
      {id, principal}
    end)
  end

  test "2 identity to rows: an API key's principal, its membership space list and the rows it shows",
       %{p: p} do
    t3_notes!(p)
    H.add_membership!(p, "T1", "t1-alice", "t1-home", "editor")
    H.add_membership!(p, "T3", "t3-rita", "r", "reader")
    H.add_membership!(p, "T3", "t3-ann", "a", "editor")

    {config, keys} =
      H.api_keys([
        human("t1-alice", "T1"),
        human("t3-rita", "T3"),
        human("t3-ann", "T3", ["docs.read", "docs.write"], ["a", "b"])
      ])

    %{"t1-alice" => alice, "t3-rita" => rita, "t3-ann" => ann} = principals(keys, config)
    assert ann.kind == :human and ann.tenant == "T3"

    # A wrong secret for a known key ID gives no principal.
    [_, key_id, _] = String.split(keys["t3-ann"], "_", parts: 3)

    wrong =
      "ek_" <> key_id <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert TokenVerify.verify_api_key(wrong, config, @now) == {:error, :invalid_signature}

    # R sees R and C (A is a barrier); A sees A and B.
    assert visible(p, rita, "docs.read") == {["c", "r"], ["note-c", "note-r"]}
    assert visible(p, ann, "docs.read") == {["a", "b"], ["note-a", "note-b"]}
    assert visible(p, ann, "docs.write") == {["a", "b"], ["note-a", "note-b"]}

    # An agent of the member at A is capped by its scopes and its named spaces.
    {:ok, agent} =
      Principal.delegate(ann, %{
        id: "t3-ann-agent",
        allowed_scopes: ["docs.read"],
        allowed_spaces: ["b"]
      })

    assert visible(p, agent, "docs.read") == {["b"], ["note-b"]}
    assert visible(p, agent, "docs.write") == {[], []}

    assert Principal.delegate(ann, %{id: "x", allowed_scopes: ["money.pay"], allowed_spaces: ["b"]}) ==
             {:error, :escalation}

    # T1 sees only T1, even over facts that hold every tenant's memberships, and with any
    # space list that the membership resolves.
    assert visible(p, alice, "docs.read") == {["t1-home"], ["note-t1"]}
    all = H.facts(p, "T1") |> Map.update!(:memberships, &(&1 ++ H.facts(p, "T3").memberships))
    assert Membership.spaces(alice, "docs.read", all, @now) == {:ok, ["t1-home"]}

    lists =
      for principal <- [alice, rita, ann, agent],
          permission <- ["docs.read", "docs.write", "money.pay"],
          facts <- [all, H.facts(p, principal.tenant)],
          {:ok, list} = Membership.spaces(principal, permission, facts, @now),
          uniq: true,
          do: list

    assert ["c", "r"] in lists and ["a", "b"] in lists

    for list <- [["r", "a", "b", "c"] | lists] do
      assert bodies(p, "notes", %{tenant: "T1", spaces: list}) -- ["note-t1"] == [], inspect(list)
    end
  end

  test "3 soft revocation: revoked_at removes the spaces at the next call; the row and its append-only references stay",
       %{p: p} do
    t3_notes!(p)
    rita_m = H.add_membership!(p, "T3", "t3-rita", "r", "reader")
    H.add_membership!(p, "T3", "t3-audrey", "r", "auditor")

    seed!(p, "ledger", %{tenant: "T3", spaces: ["r"]}, [
      [{"tenant", "T3"}, {"space", "r"}, {"membership_id", rita_m}, {"entry", "rita-entry"}]
    ])

    {config, keys} = H.api_keys([human("t3-rita", "T3"), human("t3-audrey", "T3")])
    %{"t3-rita" => rita, "t3-audrey" => audrey} = principals(keys, config)
    assert visible(p, rita, "docs.read") == {["c", "r"], ["note-c", "note-r"]}

    assert {:ok, 1} =
             H.as(%{tenant: "T3"}, fn ->
               {:ok, %{num_rows: n}} =
                 sql("UPDATE #{p}.memberships SET revoked_at = $1 WHERE id = $2", [@now, rita_m])

               {:ok, n}
             end)

    # The next call sees the revocation.
    assert visible(p, rita, "docs.read") == {[], []}
    assert Membership.permissions(rita, "r", H.facts(p, "T3"), @now) == {:ok, []}
    assert Membership.permissions(rita, "r", H.facts(p, "T3"), @now - 1) == {:ok, ["docs.read"]}

    # The membership row is kept, and the append-only row that references it stays valid and
    # readable by an authorized principal.
    assert Enum.filter(H.truth(p, "memberships", "id, revoked_at"), &(hd(&1) == rita_m)) ==
             [[rita_m, @now]]

    {:ok, audit_spaces} = Membership.spaces(audrey, "ledger.read", H.facts(p, "T3"), @now)
    assert audit_spaces == ["c", "r"]

    assert {:ok, [[^rita_m, "rita-entry"]]} =
             H.as(%{tenant: "T3", spaces: audit_spaces}, fn ->
               {:ok, H.q!(AppRepo, "SELECT membership_id, entry FROM #{p}.ledger")}
             end)

    # Append-only for the application role: no update and no delete of a ledger row.
    for statement <- ["UPDATE #{p}.ledger SET entry = 'x'", "DELETE FROM #{p}.ledger"] do
      assert denied?(H.as(%{tenant: "T3", spaces: audit_spaces}, fn -> sql(statement) end))
    end

    assert H.truth(p, "ledger", "membership_id, entry") == [[rita_m, "rita-entry"]]
  end

  # The host's write that needs money.pay at a space: its own check, then the floor.
  defp pay(p, principal, space, membership) do
    facts = H.facts(p, principal.tenant)
    {:ok, permissions} = Membership.permissions(principal, space, facts, @now)

    if "money.pay" in permissions do
      {:ok, spaces} = Membership.spaces(principal, "money.pay", facts, @now)

      H.as(%{tenant: principal.tenant, spaces: spaces}, fn ->
        sql(
          "INSERT INTO #{p}.ledger (tenant, space, membership_id, entry) VALUES ($1, $2, $3, 'pay')",
          [principal.tenant, space, membership]
        )
      end)
    else
      {:error, :forbidden}
    end
  end

  test "4 non-inheriting scope: money.pay at R resolves at R only and a write at C is refused until a membership at C",
       %{p: p} do
    at_r = H.add_membership!(p, "T3", "t3-tom", "r", "treasurer")
    {config, keys} = H.api_keys([human("t3-tom", "T3")])
    %{"t3-tom" => tom} = principals(keys, config)
    facts = H.facts(p, "T3")

    assert Membership.permissions(tom, "r", facts, @now) == {:ok, ["docs.read", "money.pay"]}
    assert Membership.permissions(tom, "c", facts, @now) == {:ok, ["docs.read"]}
    assert Membership.spaces(tom, "money.pay", facts, @now) == {:ok, ["r"]}
    assert Membership.spaces(tom, "docs.read", facts, @now) == {:ok, ["c", "r"]}

    assert pay(p, tom, "c", at_r) == {:error, :forbidden}
    assert {:ok, %{num_rows: 1}} = pay(p, tom, "r", at_r)

    # Past the host check, the money.pay space list still refuses a row at C.
    assert denied?(
             H.as(%{tenant: "T3", spaces: ["r"]}, fn ->
               sql(
                 "INSERT INTO #{p}.ledger (tenant, space, membership_id, entry) VALUES ('T3', 'c', $1, 'pay')",
                 [at_r]
               )
             end)
           )

    at_c = H.add_membership!(p, "T3", "t3-tom", "c", "treasurer")
    facts = H.facts(p, "T3")
    assert Membership.permissions(tom, "c", facts, @now) == {:ok, ["docs.read", "money.pay"]}
    assert Membership.spaces(tom, "money.pay", facts, @now) == {:ok, ["c", "r"]}
    assert {:ok, %{num_rows: 1}} = pay(p, tom, "c", at_c)
    assert H.truth(p, "ledger", "space, entry") == [["c", "pay"], ["r", "pay"]]
  end

  # ------------------------------------------------------------ 7

  # The host admits a Run only when the kill-switch read taken before start_link/1 allows it,
  # and fixes the engine's gate over that same read. A refused admission starts nothing.
  defp admit_run(fx, tenant, starts) do
    read = H.read(fx.store, tenant)

    case KillSwitch.check(read, %{tenant: tenant, recipe: H.recipe(), tool: nil}) do
      :allow ->
        :counters.add(starts, 1, 1)
        {:ok, live_run(tenant, read)}

      {:deny, code} ->
        {:refused, code}
    end
  end

  defp live_run(tenant, read) do
    observer = self()
    gate = %{id: "kill-switch-gate", version: 1, call: H.switch_call(read, %{"action" => nil})}
    c = H.engine_fixture(tenant: tenant, gate: gate, pattern: {WorkPattern, :on_input, 0})

    bindings =
      Map.update!(c.opts[:bindings], "local_work", fn binding ->
        Map.put(binding, :work, fn a ->
          {WorkPattern, :observe, [observer, tenant, a["id"], a["payload"]]}
        end)
      end)

    %{c: c, gate: gate, engine: TestHelper.start(c, bindings: bindings)}
  end

  defp wake(run, id), do: RunEngine.input(run.engine, id, TestHelper.wake(), TestHelper.verified())

  defp phase(run), do: TestHelper.view(run.engine).phase

  test "7 kill switch on live work: new Runs refused, live T1 Run paused by the host, commands refused, T2 proceeds, release and lifecycle",
       %{fx: fx} do
    store = fx.store
    starts = :counters.new(1, [])
    H.activate!(store, "T1")
    H.activate!(store, "T2")

    assert {:ok, t1} = admit_run(fx, "T1", starts)
    assert {:ok, t2} = admit_run(fx, "T2", starts)

    for {run, tenant} <- [{t1, "T1"}, {t2, "T2"}] do
      assert {:ok, :applied} = TestHelper.send_input(run.engine)
      assert_receive {:work, ^tenant, "work-0"}
    end

    # The T1 tenant switch commits through CheckedCommand on the PostgreSQL Store; the
    # descriptor's own gate does not deny on the tenant switch.
    assert {:completed, _} = H.switch(store, "T1", "engage-t1", "engage")

    assert KillSwitch.check(H.read(store, "T1"), %{tenant: "T1", recipe: H.recipe(), tool: nil}) ==
             {:deny, "tenant_suspended"}

    # A new T1 Run is refused before start_link/1: no engine starts.
    engines = Registry.count(Elzoo.RunEngine.TestRegistry)
    assert admit_run(fx, "T1", starts) == {:refused, "tenant_suspended"}
    assert :counters.get(starts, 1) == 2
    assert Registry.count(Elzoo.RunEngine.TestRegistry) == engines

    # The host stops the live T1 Run with its Run control. Its gate, over the read taken before
    # its start, still allows, so the gate is not what stops it.
    assert {:ok, :applied} =
             RunEngine.control(
               t1.engine,
               "pause-switch",
               %{kind: :pause, pause_deadline: 50_000},
               TestHelper.verified()
             )

    {:ok, frame} = Elzoo.PatternStep.decode(TestHelper.request([TestHelper.action("probe")]), 1)

    assert t1.gate.call.(frame, %{tenant: "T1", proposer: "principal", effect_class: "compute"}) ==
             :allow

    # The next input of the paused T1 Run dispatches no new work: no request, no local work.
    assert {:ok, :applied} = wake(t1, "wake-1")
    refute_receive {:work, "T1", _}, 500
    assert %{phase: :paused, request_count: 1} = TestHelper.view(t1.engine)

    # T2 proceeds throughout.
    assert {:ok, :applied} = wake(t2, "wake-1")
    assert_receive {:work, "T2", "work-1"}

    # A T1 command of another descriptor, its handle built over a fresh read, is refused.
    refused = H.note_plan(store, "T1", "note-t1-a", "hello")
    assert H.run(refused) == {:denied, {:gate, "tenant_suspended"}}
    assert {:completed, _} = H.note(store, "T2", "note-t2-a", "hello")

    # A gate over a failed read (an unreachable Store binding) denies kill_switch_unavailable.
    down =
      CheckedCommand.resource(
        H.ks_handle(H.down_store(fx.prefix)),
        H.scope("T2", "writer"),
        H.control()
      )

    assert down == {:unknown, :storage}

    assert H.run(
             H.note_plan(store, "T2", "note-t2-down", "hello",
               gate: fn _ -> H.switch_gate(down) end
             )
           ) ==
             {:denied, {:gate, "kill_switch_unavailable"}}

    # The release commits while the switch is engaged, before the T1 Run's pause deadline.
    assert {:completed, _} = H.switch(store, "T1", "release-t1", "release")
    assert Agent.get(t1.c.clock, & &1) < 50_000
    assert phase(t1) == :paused

    assert {:ok, :applied} =
             RunEngine.control(
               t1.engine,
               "continue-switch",
               %{kind: :continue, person_id: "person", run_deadline: 60_000},
               TestHelper.verified(%{verified_person: "person"})
             )

    # A wake while paused is not kept for later: the host's next input after continue asks
    # for the next work.
    assert phase(t1) == :active
    assert {:ok, :applied} = wake(t1, "wake-2")
    assert_receive {:work, "T1", "work-1"}
    assert {:ok, :applied} = wake(t2, "wake-2")
    assert_receive {:work, "T2", "work-2"}
    assert TestHelper.view(t2.engine).request_count == 3

    # A new T1 Run starts; the refused command commits under a new operation ID, and its old
    # operation ID replays the retained denial.
    assert {:ok, t1b} = admit_run(fx, "T1", starts)
    assert {:ok, :applied} = TestHelper.send_input(t1b.engine)
    assert_receive {:work, "T1", "work-0"}
    assert {:completed, _} = H.note(store, "T1", "note-t1-b", "hello")
    assert H.run(refused) == {:denied, {:gate, "tenant_suspended"}}

    # The old operation ID cannot be reused at the new revision either.
    assert H.run(H.note_plan(store, "T1", "note-t1-a", "hello")) == {:conflict, :identity}

    assert CheckedCommand.result(
             elem(refused, 0),
             %{tenant: "T1", actor: "writer"},
             {"T1", "writer", "note-t1-a"}
           ) ==
             {:denied, {:gate, "tenant_suspended"}}

    # Lifecycle suspend has the same effect on new Runs and commands; activate, committed while
    # the lifecycle switch is engaged, undoes it.
    assert {:completed, _} = H.lifecycle(store, "T1", "suspend-t1", "suspend")
    assert TenantLifecycle.status(H.read(store, "T1")) == {:ok, "suspended"}
    assert admit_run(fx, "T1", starts) == {:refused, "tenant_suspended"}
    assert H.note(store, "T1", "note-t1-c", "hello") == {:denied, {:gate, "tenant_suspended"}}
    assert {:completed, _} = H.note(store, "T2", "note-t2-c", "hello")
    assert {:completed, _} = H.lifecycle(store, "T1", "activate-t1-again", "activate")
    assert TenantLifecycle.status(H.read(store, "T1")) == {:ok, "active"}
    assert {:ok, t1c} = admit_run(fx, "T1", starts)
    assert {:ok, :applied} = TestHelper.send_input(t1c.engine)
    assert_receive {:work, "T1", "work-0"}
    assert {:completed, _} = H.note(store, "T1", "note-t1-d", "hello")
    assert :counters.get(starts, 1) == 4
  end

  # ------------------------------------------------------------ 5

  # A live Run whose gate is the provider data policy of its tenant, fixed at construction.
  defp model_run(tenant, policy, actions) do
    gate = %{id: "provider-data-gate", version: 1, call: H.provider_call(policy)}

    c =
      H.engine_fixture(
        tenant: tenant,
        gate: gate,
        pattern: {TestPattern, :step, %{requests: [TestHelper.request(actions)]}}
      )

    # The host's model binding: its Effect intent identity names the Run's tenant.
    bindings =
      Map.update!(c.opts[:bindings], "model_call", fn binding ->
        Map.put(binding, :facts, fn action ->
          update_in(binding.facts.(action), [:intent, :identity], &[tenant | tl(&1)])
        end)
      end)

    engine = TestHelper.start(c, bindings: bindings)
    assert {:ok, :applied} = TestHelper.send_input(engine)
    engine
  end

  defp model_action(id, provider, classes),
    do:
      TestHelper.action(id, "model_call", %{
        "provider" => provider,
        "region" => "eu",
        "retention" => "zero-retention",
        "classes" => classes
      })

  defp settled?(view, key), do: match?(%{^key => %{phase: :settled}}, view.slots)

  test "5 provider data policy: a :pii model action to a provider the tenant does not admit is denied by the host gate on a live Run; an admitted one passes; a malformed policy denies" do
    policy = %{
      providers: [
        %{
          provider: "eu-model",
          classes: [%{class: :pii, regions: ["eu"], retention: ["zero-retention"]}]
        }
      ]
    }

    engine =
      model_run("T1", policy, [
        model_action("to-us", "us-model", ["pii"]),
        model_action("to-eu", "eu-model", ["pii"])
      ])

    view = TestHelper.wait_for(engine, &settled?(&1, {1, 0}))

    assert %{outcome: "refused", verdict: %{verdict: :deny, reason: "data_provider"}} =
             view.slots[{1, 0}]

    # The admitted action passes the gate and its Effect is dispatched.
    assert_receive {:effect_started, _, %{key: _}}

    assert %{verdict: %{verdict: :allow, gate_id: "provider-data-gate"}} =
             TestHelper.view(engine).slots[{1, 1}]

    malformed =
      model_run("T1", %{providers: "eu-model"}, [model_action("to-eu", "eu-model", ["pii"])])

    view = TestHelper.wait_for(malformed, &settled?(&1, {1, 0}))

    assert %{outcome: "refused", verdict: %{verdict: :deny, reason: "data_policy_unavailable"}} =
             view.slots[{1, 0}]

    refute_receive {:effect_started, _, _}, 200
  end

  # ------------------------------------------------------------ 6

  defp mcp_clients do
    Enum.count(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, d} -> match?({ExMCP.Client, _, _}, d[:"$initial_call"])
        nil -> false
      end
    end)
  end

  defp mcp_config(answer, needs) do
    {:ok, config} =
      McpRuntime.configure(
        tenant: "T1",
        server: "t1-notes",
        url: "https://mcp.t1-tenant.example.test/mcp",
        policy: EgressPolicy.policy(hosts: ["mcp.t1-tenant.example.test"], ports: [443]),
        resolver: fn _host ->
          :counters.add(needs, 1, 1)
          {:ok, answer}
        end,
        credential: %{ref: "t1-notes-token", scope: "T1/t1-notes"},
        # The credential Need: counted, and it never answers.
        secrets: fn _request ->
          :counters.add(needs, 2, 1)
          raise "credential Need called"
        end
      )

    config
  end

  test "6 runtime MCP egress: a tenant URL resolving to a private, link-local, loopback or mixed set is refused before the credential Need and before any client" do
    needs = :counters.new(2, [])
    clients = mcp_clients()

    for answer <- [
          [{10, 0, 0, 5}],
          [{169, 254, 169, 254}],
          [{127, 0, 0, 1}],
          [{93, 184, 215, 14}, {10, 0, 0, 5}]
        ] do
      assert McpRuntime.admit(mcp_config(answer, needs)) == {:error, {:egress, :non_public_address}},
             inspect(answer)
    end

    assert :counters.get(needs, 1) == 4
    assert :counters.get(needs, 2) == 0
    assert mcp_clients() == clients

    # Control of the counter: a public answer passes egress and reaches the credential Need.
    assert McpRuntime.admit(mcp_config([{93, 184, 215, 14}], needs)) ==
             {:error, :credentials_unavailable}

    assert :counters.get(needs, 2) == 1
    assert mcp_clients() == clients
  end

  # ------------------------------------------------------------ 8

  defp decode_membership({:record, fields}),
    do: Map.new(fields, fn {name, value} -> {String.to_existing_atom(name), untext(value)} end)

  defp untext({:text, t}), do: t
  defp untext(v), do: v

  # The host applies an accepted invitation at most once per command identity.
  defp apply_membership!(p, tenant, m, source) do
    {:ok, n} =
      H.as(%{tenant: tenant}, fn ->
        {:ok, %{num_rows: n}} =
          sql(
            "INSERT INTO #{p}.memberships (tenant, principal, space, role, valid_from, source) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (source) DO NOTHING",
            [tenant, m.principal, m.space, m.role, m.valid_from, source]
          )

        {:ok, n}
      end)

    n
  end

  test "8 invitations on real PostgreSQL: invite and accept as checked commands, two racing accepts commit once, one membership, no code in the log",
       %{fx: fx, p: p} do
    store = fx.store
    H.activate!(store, "T3")
    H.add_membership!(p, "T3", "t3-owner", "r", "editor")
    {:ok, owner} = Principal.new(Map.put(human("t3-owner", "T3"), :auth_epoch, 1))

    # The host resolves that the inviter may hand out the role's permission at the space.
    {:ok, granted} = Membership.permissions(owner, "c", H.facts(p, "T3"), @now)
    assert "docs.write" in granted

    code_bytes = :crypto.strong_rand_bytes(16)
    code = Base.url_encode64(code_bytes, padding: false)
    digest = :crypto.hash(:sha256, code)

    invite = %{
      "op" => "invite",
      "id" => "inv-1",
      "space" => "c",
      "role" => "editor",
      "invitee" => nil,
      "expires_at" => @now + 3_600
    }

    invite_data =
      H.lifecycle_data("invite", [
        {"code_digest", {:bytes, digest}},
        {"known_target", true},
        {"inviter_may_grant", "docs.write" in granted}
      ])

    assert {:completed, %{revision: 3}} =
             H.run(H.lifecycle_plan(store, "T3", "t3-owner", "invite-1", invite, invite_data))

    # Two accepts, distinct operation IDs, both read and prepared at revision 3; each waits at a
    # barrier in its preparer (which still calls TenantLifecycle.prepare/3) until both are there.
    parent = self()
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    barrier = fn snapshot, request, facts ->
      first? =
        Agent.get_and_update(seen, fn s ->
          {not MapSet.member?(s, request.operation_id), MapSet.put(s, request.operation_id)}
        end)

      if first? do
        send(parent, {:at_barrier, self(), snapshot.revision})
        receive do: (:go -> :ok)
      end

      TenantLifecycle.prepare(snapshot, request, facts)
    end

    accept = %{"op" => "accept", "id" => "inv-1"}

    accept_data =
      H.lifecycle_data("accept", [{"presented_digest", {:bytes, :crypto.hash(:sha256, code)}}])

    plans =
      for {actor, op} <- [{"t3-bob", "accept-bob"}, {"t3-carol", "accept-carol"}],
          do: {actor, op, H.lifecycle_plan(store, "T3", actor, op, accept, accept_data, barrier)}

    assert Enum.all?(plans, fn {_, _, {_, _, request}} -> request.expected_revision == 3 end)
    tasks = for {_, _, plan} <- plans, do: Task.async(fn -> H.run(plan) end)

    waiting =
      for _ <- 1..2 do
        assert_receive {:at_barrier, pid, 3}
        pid
      end

    Enum.each(waiting, &send(&1, :go))
    results = Task.await_many(tasks, 30_000)
    Agent.stop(seen)

    assert Enum.count(results, &match?({:completed, %{revision: 4}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:conflict, :stale_revision})) == 1

    # Each result is retained under its identity; the host applies each completed accept, and
    # again on replay of the winner, which returns its first response.
    for {{actor, op, {handle, _, _} = plan}, result} <- Enum.zip(plans, results) do
      assert CheckedCommand.result(handle, %{tenant: "T3", actor: actor}, {"T3", actor, op}) ==
               result

      with {:completed, %{response: response}} <- result do
        assert apply_membership!(p, "T3", decode_membership(response), op) == 1
        assert H.run(plan) == result
        assert apply_membership!(p, "T3", decode_membership(response), op) == 0
      end
    end

    {{winner, _, _}, {:completed, %{response: response}}} =
      Enum.zip(plans, results) |> Enum.find(&match?({_, {:completed, _}}, &1))

    assert decode_membership(response) == %{
             principal: winner,
             space: "c",
             role: "editor",
             valid_from: @now,
             valid_to: nil,
             revoked_at: nil
           }

    assert H.truth(p, "memberships", "principal, space") |> Enum.filter(&(&1 != ["t3-owner", "r"])) ==
             [[winner, "c"]]

    {:ok, accepter} = Principal.new(Map.put(human(winner, "T3"), :auth_epoch, 1))

    assert Membership.permissions(accepter, "c", H.facts(p, "T3"), @now) ==
             {:ok, ["docs.read", "docs.write"]}

    # The invitation code is in no stored row; its digest is in the command log (control).
    assert H.leaks(p, [code, code_bytes]) == []
    assert "elzoo_log_records" in H.leaks(p, [digest])
  end

  # ------------------------------------------------------------ 9

  test "9 crypto-shredding with intact logs: tokenized text in the command, erase makes refs not_found, the stream recovers unchanged, lifecycle erase after the vault",
       %{fx: fx, p: p} do
    store = fx.store
    H.activate!(store, "T1")
    subject = "principal:t1-ann"
    name = "Ann Example"
    email = "ann.example@example.com"
    text = "Refund for #{name}: reply to #{email} today."

    # The vault Need of the redaction is the retention-erasure vault of the subject.
    vault = fn _kind, span -> RetentionErasure.put(fx.vault, subject, span) end

    assert {:ok, %{text: tokenized, findings: findings}} =
             PiiRedaction.redact(text, mode: :tokenize, known: [name], vault: vault)

    assert findings == [%{kind: :known, count: 1}, %{kind: :email, count: 1}]

    refs =
      Regex.scan(~r/\[pii:(?:known|email):(v1_[A-Za-z0-9_-]{22})\]/, tokenized,
        capture: :all_but_first
      )
      |> List.flatten()

    assert length(refs) == 2
    assert Enum.map(refs, &RetentionErasure.fetch(fx.vault, &1)) == [{:ok, name}, {:ok, email}]

    command_text = tokenized
    assert {:completed, _} = completed = H.note(store, "T1", "note-pii", command_text)

    # Every stored row holds only refs: no raw value, and the refs are in the command log.
    assert H.leaks(p, [name, email]) == []
    assert "elzoo_log_records" in H.leaks(p, refs)

    identity = {"T1", "writer", "note-pii"}
    result_scope = %{tenant: "T1", actor: "writer"}
    resource_scope = H.scope("T1", "writer", ["note-1"])
    handle = H.note_handle(store, H.switch_gate(H.read(store, "T1")))
    assert CheckedCommand.result(handle, result_scope, identity) == completed
    {:ok, resource} = CheckedCommand.resource(handle, resource_scope, "note-1")
    assert resource.fields == %{"text" => {:text, tokenized}}
    rows = H.log_rows(p)

    assert :ok = RetentionErasure.erase(fx.vault, subject)

    assert Enum.map(refs, &RetentionErasure.fetch(fx.vault, &1)) == [
             {:error, :not_found},
             {:error, :not_found}
           ]

    assert RetentionErasure.status(fx.vault, subject) == {:ok, :erased}

    # A fresh handle on a fresh Store binding recovers the whole tenant stream.
    fresh = H.note_handle(H.store(AppRepo, p), H.switch_gate(H.read(store, "T1")))
    assert CheckedCommand.result(fresh, result_scope, identity) == completed
    assert CheckedCommand.resource(fresh, resource_scope, "note-1") == {:ok, resource}

    assert [[0, revision]] =
             H.owner!("SELECT low_water, revision FROM #{p}.elzoo_log_heads WHERE stream = $1", [
               H.stream("T1")
             ])

    assert revision ==
             length(Enum.filter(rows, fn {{stream, _}, _} -> stream == H.stream("T1") end))

    assert H.log_rows(p) == rows

    # Lifecycle close, then erase with vault_erased: true only after every subject is erased.
    subjects = [subject, "tenant:T1"]
    assert {:ok, _} = RetentionErasure.put(fx.vault, "tenant:T1", "billing profile")
    assert {:completed, _} = H.lifecycle(store, "T1", "close-t1", "close")

    erased? = fn ->
      Enum.all?(subjects, &(RetentionErasure.status(fx.vault, &1) == {:ok, :erased}))
    end

    refute erased?.()

    assert H.lifecycle(
             store,
             "T1",
             "erase-t1-early",
             "erase",
             H.lifecycle_data("erase", [{"vault_erased", erased?.()}])
           ) == {:conflict, {:domain, "not_erased"}}

    assert TenantLifecycle.status(H.read(store, "T1")) == {:ok, "closing"}
    # The close and the refused erase appended records; the tenant erasure must keep them too.
    before_tenant_erase = H.log_rows(p)
    assert length(before_tenant_erase) > length(rows)
    assert :ok = RetentionErasure.erase(fx.vault, "tenant:T1")
    assert erased?.()

    assert {:completed, _} =
             H.lifecycle(
               store,
               "T1",
               "erase-t1",
               "erase",
               H.lifecycle_data("erase", [{"vault_erased", erased?.()}])
             )

    assert TenantLifecycle.status(H.read(store, "T1")) == {:ok, "erased"}

    # No log row was deleted or changed by either erasure; later commands only appended.
    after_rows = Map.new(H.log_rows(p))

    for snapshot <- [rows, before_tenant_erase],
        do: assert(Enum.all?(snapshot, fn {key, hash} -> Map.get(after_rows, key) == hash end))

    assert map_size(after_rows) > length(before_tenant_erase)
  end
end
