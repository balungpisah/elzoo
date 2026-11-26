Code.require_file("support/wave9_tools_doors_models_money_helper.exs", __DIR__)

defmodule Elzoo.Wave9.ToolsDoorsModelsMoneyTest do
  # ELZ-379: the Wave 9 Pieces together on real PostgreSQL 19 and MinIO, every application call
  # running as the fixed non-owner, non-bypass role of ELZ-285. Each test names its acceptance
  # group of the ELZ-379 task.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Elzoo.{
    Entitlement,
    Invoice,
    Journal,
    LedgerCheckout,
    Metering,
    Money,
    PaymentLifecycle,
    Plan,
    Pricing,
    WebhookOut
  }

  alias Elzoo.{McpRuntime, OauthClient, RetryTimeout}
  alias Elzoo.Wave9.{AppRepo, Models, OwnerRepo, Provider, Recorder, Server, Tools}
  alias Elzoo.Wave9.Bots, as: B
  alias Elzoo.RecipeStore.TestHelper, as: RS
  alias Elzoo.Wave9.Helper, as: H

  setup_all do
    role = H.start_repos!()
    on_exit(fn -> for repo <- [OwnerRepo, AppRepo], do: H.stop!(repo) end)
    # Fails, never skips: the application connection must be the application role.
    facts = H.role_guard!(role)
    {:ok, provider} = Provider.start()
    Process.unlink(provider)
    registries = B.registries!()
    lua_dir = Path.join(System.tmp_dir!(), "wave9-lua-" <> H.hex(4))
    {:ok, lua} = Elzoo.LuaSandbox.build(Mix.Project.deps_paths()[:lua_source], lua_dir)

    on_exit(fn ->
      if Process.alive?(provider), do: Agent.stop(provider)
      for pid <- registries, Process.alive?(pid), do: Supervisor.stop(pid)
      File.rm_rf!(lua_dir)
    end)

    %{role: role, facts: facts, lua: lua}
  end

  setup %{role: role} do
    Process.flag(:trap_exit, true)
    Provider.script(:charge, [])
    Agent.update(Provider, fn _ -> %{answers: %{}, calls: []} end)
    %{w: H.fixture!(role)}
  end

  @ok {:ok, %{provider_ref: "ch_1", state: :succeeded}}
  @pending {:ok, %{provider_ref: "ch_1", state: :pending}}
  @refunded {:ok, %{provider_ref: "re_1", state: :succeeded}}

  # ------------------------------------------------------------ setup

  describe "setup" do
    test "the application role, its session settings, verify/1 and exactly the README grants",
         %{w: w, role: role, facts: facts} do
      assert %{
               current: "elzoo_app",
               super: false,
               bypass: false,
               login: false,
               inherit: false,
               createrole: false,
               createdb: false,
               member_of_owner: false
             } = facts

      assert facts.session != "elzoo_app"
      s = H.session_settings()
      assert facts.lock_timeout == "#{div(s.lock_timeout_ms, 1_000)}s"
      assert facts.statement_timeout == "#{div(s.statement_timeout_ms, 1_000)}s"

      for limit <- [s.lock_timeout_ms, s.statement_timeout_ms, s.repo_timeout_ms],
          do: assert(limit > s.bound_ms)

      # The role guard fails, and does not skip, for an unset variable or another role.
      for value <- [nil, "elzoo_test", "postgres"] do
        old = System.get_env("ELZOO_TEST_APP_ROLE")

        if value,
          do: System.put_env("ELZOO_TEST_APP_ROLE", value),
          else: System.delete_env("ELZOO_TEST_APP_ROLE")

        try do
          assert_raise ExUnit.AssertionError, fn -> H.app_role!() end
        after
          System.put_env("ELZOO_TEST_APP_ROLE", old)
        end
      end

      # As elzoo_app, each Piece's verify/1 that exists.
      assert :ok = PaymentLifecycle.verify(w.lc)
      assert :ok = Invoice.verify(w.inv)
      assert :ok = Plan.verify(w.plan)
      assert :ok = WebhookOut.verify(w.hooks.binding)

      schemas = Map.values(w.p) ++ [w.intents_prefix]
      expected = Map.merge(H.readme_grants(w.p), H.store_grants(w.intents_prefix))
      assert H.grants(schemas, role) == {expected, false}

      # No DELETE and no TRUNCATE on any table, except DELETE on elzoo_dead_letters.
      for [table, delete, truncate] <- H.deletes(schemas, role) do
        refute truncate, table
        assert delete == (table == "#{w.p.dead_letters}.elzoo_dead_letters"), table
      end

      # The PUBLIC defaults: EXECUTE on the tenant readers with no explicit ACL, and TEMP.
      defaults = H.public_defaults(schemas, role)
      assert defaults.temp
      readers = for [name, true, true] <- defaults.functions, do: name
      assert length(readers) == length(defaults.functions)

      for {k, _} <- H.new_tables(),
          do: assert("#{w.p[k]}.elzoo_tenant_id" in readers, "#{k}")
    end
  end

  # ------------------------------------------------------------ group 1: tools

  defp echo_bot(w, label, session) do
    H.env(w, {:mcp_session, label}, session)
    B.script(w, label, [B.propose([{"mcp_echo", %{"x" => label}}]), B.say("done " <> label)])
    B.start_bot!(w, "T1", label, B.agent_spec(label, [:mcp]), "Call the echo tool.")
  end

  defp answered!(w, label) do
    B.finished!(w, label)

    # The completion is the answer: the content of the model call that the finish names.
    assert {:ok, %{schema_id: "elzoo.ai-text.result", payload: %{"finish" => "stop"} = answer}} =
             B.result(w, label)

    answer["content"]
  end

  defp tool_calls(w),
    do: for({{"tools/call", _}, _} = r <- Enum.with_index(Tools.recorded(w)), do: r)

  defp has?(value, needles) when is_binary(value),
    do: Enum.any?(needles, &String.contains?(value, &1))

  defp has?(value, needles),
    do: has?(inspect(value, limit: :infinity, printable_limit: :infinity), needles)

  describe "group 1: tools" do
    test "OAuth code flow, admission and session, one refresh, no token at rest, invalid_grant",
         %{w: w0} do
      w = B.engines!(w0)
      b = Tools.oauth!(w)
      srv = Recorder.start(w.env)
      on_exit(fn -> Recorder.stop(srv) end)

      # The code flow: the token request carried a verifier whose S256 hash is the challenge.
      {state, code, result} = Tools.authorize!(w, b, "T1", "conn-1")
      assert {:ok, %{grant: :authorization_code, state: :active, connection_id: "conn-1"}} = result
      assert [_] = Tools.token_requests(w, "authorization_code")
      [t1] = H.env(w, :issued)
      assert Tools.b64token?(t1["access_token"]) and Tools.b64token?(t1["refresh_token"])

      # The same state again: invalid_state with no second exchange.
      assert OauthClient.complete_authorization(b, "T1", %{state: state, code: code}) ==
               {:error, :invalid_state}

      assert [_] = Tools.token_requests(w, "authorization_code")

      # Admission: one OAuth Need call; the session of the admitted config's credential Need.
      config = Tools.runtime!(w, b, "T1", "conn-1")
      assert {:ok, client_config} = McpRuntime.admit(config)
      assert H.env(w, :oauth_calls) == 1
      s1 = Tools.session!(w, client_config, srv.url)
      assert [%{"name" => "echo"} | _] = s1.snapshot.tools

      # A bot calls the server's tool through the MCP tool binding; each request had the token.
      echo_bot(w, "bot1", s1)
      answered!(w, "bot1")

      assert [{"bot1", {:completed, %{content: [%{"text" => "echo:bot1"}]}}}] =
               H.env(w, :mcp_results)

      assert [_ | _] = tool_calls(w)

      for {_label, auth} <- Tools.recorded(w),
          do: assert(auth == ["Bearer " <> t1["access_token"]])

      # One refresh: two Runs, each with its own session of the admitted config, at once.
      s2 = Tools.session!(w, client_config, srv.url)
      s3 = Tools.session!(w, client_config, srv.url)
      seen = length(Tools.recorded(w))
      H.tick(w, 61_000)
      H.env(w, :hold_refresh, true)
      echo_bot(w, "bot2", s2)
      echo_bot(w, "bot3", s3)
      B.await!(fn -> H.env(w, :refresh_held) end)

      # The second caller waits on the connection row (as elzoo_app, in pg_locks): a session of
      # this database that holds a lock on elzoo_oauth_connections and waits on a row or a
      # transaction.
      B.await!(fn ->
        [[n]] =
          H.q!(
            AppRepo,
            """
            SELECT count(*) FROM pg_locks w
            WHERE NOT w.granted AND w.locktype IN ('transactionid', 'tuple')
              AND EXISTS (
                SELECT 1 FROM pg_locks r
                WHERE r.pid = w.pid AND r.granted AND r.locktype = 'relation'
                  AND r.database = (SELECT oid FROM pg_database WHERE datname = current_database())
                  AND r.relation = $1::text::regclass)
            """,
            ["#{w.p.oauth}.elzoo_oauth_connections"]
          )

        n > 0
      end)

      H.env(w, :release_refresh, true)

      # result/3 rechecks the Run owner's revision, which covers every Run of the tenant's shared
      # owner (#931): the results are read once both Runs are completed in the owner.
      for label <- ["bot2", "bot3"] do
        B.finished!(w, label)

        B.await!(fn ->
          match?(
            {:ok, %{outcome: :completed}},
            Elzoo.RunApprovalRelease.status(w.tenants["T1"].run, label)
          )
        end)
      end

      answered!(w, "bot2")
      answered!(w, "bot3")
      # The one refresh carried the refresh token of the code flow's pair.
      assert [%{"refresh_token" => refreshed}] = Tools.token_requests(w, "refresh_token")
      assert refreshed == t1["refresh_token"]
      [_, t2] = H.env(w, :issued)

      results = H.env(w, :mcp_results)
      assert [{_, {:completed, _}}, {_, {:completed, _}}, {_, {:completed, _}}] = results

      after_move = Enum.drop(Tools.recorded(w), seen)
      assert length(for {"tools/call", _} <- after_move, do: 1) == 2
      for {_label, auth} <- after_move, do: assert(auth == ["Bearer " <> t2["access_token"]])

      # No token at rest: no column of the connection holds a token's bytes; no result holds one.
      tokens = for t <- [t1, t2], k <- ["access_token", "refresh_token"], do: t[k]

      [row] =
        H.read_as(
          "T1",
          "SELECT * FROM #{w.p.oauth}.elzoo_oauth_connections WHERE connection_id = 'conn-1'"
        )

      assert [_ | _] = row
      refute Enum.any?(row, &has?(&1, tokens))
      refute has?(results, tokens)

      # invalid_grant: the tool call that triggers the refresh sends no tools/call.
      H.env(w, :hold_refresh, false)
      H.env(w, :refresh_answer, :invalid_grant)
      H.tick(w, 61_000)
      seen = length(Tools.recorded(w))

      assert {:refused, :credentials_unavailable} =
               B.mcp_call(w, s1.session, s1.snapshot, "echo", %{"x" => "after"})

      refute Enum.any?(Enum.drop(Tools.recorded(w), seen), &match?({"tools/call", _}, &1))

      # That refresh carried the rotated refresh token of the second pair.
      assert [_, %{"refresh_token" => rotated}] = Tools.token_requests(w, "refresh_token")
      assert rotated == t2["refresh_token"]

      assert {:ok, %{state: :reauthorization_required}} =
               OauthClient.get(b, "T1", %{connection_id: "conn-1"})

      # A later tool call sends nothing to either server; a new admit/1 is refused.
      recorded = length(Tools.recorded(w))

      assert {:refused, :credentials_unavailable} =
               B.mcp_call(w, s1.session, s1.snapshot, "echo", %{"x" => "later"})

      assert length(Tools.recorded(w)) == recorded
      assert [_, _] = Tools.token_requests(w, "refresh_token")
      assert McpRuntime.admit(config) == {:error, :credentials_unavailable}
      assert [_, _] = Tools.token_requests(w, "refresh_token")
      assert H.env(w, :errors) == nil
    end

    test "code mode: declared calls, an undeclared call, the step bound, bytecode, an expired module call",
         %{w: w0, lua: lua} do
      w = B.engines!(w0, lua: lua)

      two_calls =
        "return function(input) local a = bindings.add({n = input.n}) " <>
          "local b = bindings.mul({n = a.n}) return {total = b.n} end"

      code = fn label, source, opts ->
        H.env(w, {:declared, label}, %{functions: ["add", "mul"]})

        B.script(w, label, [
          B.propose([{"code_run_code", %{"source" => source, "input" => %{"n" => 1}}}]),
          B.say("done")
        ])

        B.start_bot!(w, "T1", label, B.agent_spec(label, [:code]), "Run the program.", opts)
      end

      lua_finish = fn label ->
        id = B.code_id(label <> ":t:1:1")

        [payload] =
          for {^id <> ":finish", "finish", "elzoo.agent-loop.tool-result", p} <- B.actions(w, label),
              do: p

        Jason.decode!(payload["content"]["content"])
      end

      module_actions = fn label ->
        for {id, kind, "elzoo.lua-tool.module-call", _} <- B.actions(w, label), do: {id, kind}
      end

      # Two declared calls: two module-call tool_call actions, admitted, then completed.
      code.("code1", two_calls, [])
      answered!(w, "code1")
      id = B.code_id("code1:t:1:1")
      assert module_actions.("code1") == [{id <> ":c:0", "tool_call"}, {id <> ":c:1", "tool_call"}]
      assert [{_, "add", 1}, {_, "mul", 2}] = H.env(w, {:module_calls, "code1"})

      for {action, _} <- module_actions.("code1"),
          do:
            assert(
              [{^action, "completed", _}] =
                for(s <- B.settlements(w, "code1"), elem(s, 0) == action, do: s)
            )

      assert %{"status" => "completed", "result" => %{"total" => 4}, "action_id" => _} =
               lua_finish.("code1")

      # A function the Run did not declare: unlisted_name, no module call.
      code.("code2", "return function(input) return bindings.wipe({n = 1}) end", [])
      answered!(w, "code2")

      assert %{"status" => "failed", "reason" => "sandbox_refused", "detail" => "unlisted_name"} =
               lua_finish.("code2")

      assert module_actions.("code2") == []

      # Over the step bound; a source that begins with the bytecode signature.
      code.("code3", "return function(input) while true do end end", [])
      answered!(w, "code3")
      assert %{"reason" => "sandbox_refused", "detail" => "steps"} = lua_finish.("code3")

      code.("code4", "\eLua" <> " return function(input) return 1 end", [])
      answered!(w, "code4")
      assert %{"reason" => "sandbox_refused", "detail" => "lua_error"} = lua_finish.("code4")

      # expiry_reports: :owner — the module call's slot expires at a harness input after the
      # clock moves; the report reaches lua-tool, which finishes before the run_code deadline.
      H.env(w, {:hold_module, "code5"}, true)
      code.("code5", two_calls, expiry: true)
      B.await!(fn -> B.held?(w, {:module, "code5"}) end)
      started = H.now(w)
      H.tick(w, B.module_ms() + 1)

      assert {:ok, _} = B.input!(w, "code5", "wake:code5", %{"kind" => "wake"})
      answered!(w, "code5")
      id = B.code_id("code5:t:1:1")

      assert %{
               "status" => "failed",
               "reason" => "module_call_not_completed",
               "action_id" => run_action
             } = lua_finish.("code5")

      assert run_action == id <> ":r:1"

      assert [{_, "expired", _}] =
               for(s <- B.settlements(w, "code5"), elem(s, 0) == id <> ":c:0", do: s)

      assert [{_, "completed", at}] =
               for(s <- B.settlements(w, "code5"), elem(s, 0) == "code5:t:1:1", do: s)

      assert at < started + B.code_ms()
      assert H.env(w, :errors) == nil
    end
  end

  # ------------------------------------------------------------ group 4: money

  defp plan_facts(grants) do
    plan = %{plan_id: "pro", version: 1, features: ["chat"], allowances: []}
    {:ok, hash} = Entitlement.content_hash(plan)
    %{plans: [Map.put(plan, :content_hash, hash)], grants: grants}
  end

  defp card do
    card = %{
      card_id: "models",
      version: 1,
      kind: :price,
      currency: H.eur_currency(),
      rounding: :half_up,
      lines: [
        %{
          provider_id: "gemini",
          model_id: "gemini-3.8-flash",
          unit: :input_uncached_tokens,
          rate: "2",
          per: 1_000,
          minimum: nil
        },
        %{
          provider_id: "gemini",
          model_id: "gemini-3.8-flash",
          unit: :output_tokens,
          rate: "4",
          per: 1_000,
          minimum: nil
        }
      ]
    }

    {:ok, hash} = Pricing.content_hash(card)
    Map.put(card, :content_hash, hash)
  end

  defp observe(w, tenant, id, period, unit, amount) do
    {:ok, :applied} =
      Metering.record(w.meter, tenant, %{
        usage_id: id,
        run_id: "run-" <> id,
        operation_id: "op",
        attempt_id: "attempt-1",
        provider_id: "gemini",
        model_id: "gemini-3.8-flash",
        unit: unit,
        amount: amount,
        source: if(amount == :unknown, do: :unknown, else: :provider_reported),
        period: period,
        observed_at_ms: H.now(w)
      })
  end

  defp charge(w, tenant, period) do
    {:ok, rows} = Metering.model_totals(w.meter, tenant, %{period: period, max_rows: 100})
    {:ok, charge} = Pricing.price(card(), %{tenant: tenant, period: period, rows: rows})
    charge
  end

  defp subscription_row(w, tenant),
    do:
      H.read_as(
        tenant,
        "SELECT subscription_id, revision FROM #{w.p.plan}.elzoo_plan_subscriptions ORDER BY 1"
      )

  describe "group 4: money" do
    test "renewal: the trial, the 1 ms edge, the 28 February period, a duplicate, entitlement",
         %{w: w} do
      trial_end = 1_801_353_600_000

      assert {:ok, %{subscription: s0, fee_line: nil, grants: [g0], duplicate: false}} =
               Plan.create(w.plan, "T1", %{
                 subscription_id: "sub-1",
                 plan: %{plan_id: "pro", version: 1},
                 fee: H.eur(2_900),
                 interval: :month,
                 start_ms: trial_end - 14 * 86_400_000,
                 trial_end_ms: trial_end
               })

      assert %{state: :trialing, period: %{index: 0, end_ms: ^trial_end}} = s0
      assert is_binary(g0.grant_id) and g0.grant_id != ""

      renew = fn now ->
        Plan.renew(w.plan, "T1", %{subscription_id: "sub-1", from_index: 0, now_ms: now})
      end

      assert renew.(trial_end - 1) == {:error, :not_due}

      assert {:ok, %{subscription: s1, fee_line: fee_line, grants: [g1], duplicate: false}} =
               renew.(trial_end)

      assert %{
               state: :active,
               period: %{index: 1, start_ms: ^trial_end, end_ms: 1_803_772_800_000}
             } = s1

      assert %{period: %{index: 1}, amount: %Money.Amount{minor_units: 2_900}} = fee_line
      renewal_id = g1.grant_id
      assert is_binary(renewal_id) and renewal_id != ""
      refute renewal_id == g0.grant_id

      before = subscription_row(w, "T1")

      assert {:ok, %{duplicate: true, grants: [%{grant_id: ^renewal_id}]}} =
               renew.(trial_end + 1)

      assert subscription_row(w, "T1") == before

      # The host stores the grants (here in its harness state); resolve/3 over the stored
      # grants is entitled in period 1.
      H.env(w, {:grants, "T1"}, [g0, g1])

      assert {:entitled, %{grants: [%{grant_id: ^renewal_id}]}} =
               Entitlement.resolve(plan_facts(H.env(w, {:grants, "T1"})), "T1", trial_end + 1)
    end

    test "invoice numbering, the issue post, an incomplete charge; the checkout pays it",
         %{w: w} do
      :ok = H.accounts!(w, "T1")

      # An earlier invoice of the series: number 1.
      H.invoice!(w, "T1", "inv-1", [{:adjustment, "a1", H.eur(1_000), "setup", "setup/1"}])
      assert %{number: 1} = H.finalize!(w, "T1", "inv-1")

      # A fee line of the plan and a complete charge of a period with no unknown usage.
      {:ok, %{fee_line: fee_line}} =
        Plan.create(w.plan, "T1", %{
          subscription_id: "sub-2",
          plan: %{plan_id: "pro", version: 1},
          fee: H.eur(2_900),
          interval: :month,
          start_ms: H.now(w),
          trial_end_ms: nil
        })

      observe(w, "T1", "u-in", "2027-02", :input_uncached_tokens, 3_000)
      observe(w, "T1", "u-out", "2027-02", :output_tokens, 1_000)
      charge = charge(w, "T1", "2027-02")
      assert %{incomplete: false, unknown_count: 0, total: %{minor_units: 1_000}} = charge

      H.invoice!(w, "T1", "inv-2", [
        {:fee, "fee", fee_line, "Pro plan"},
        {:charge, "usage", charge, "Model usage"}
      ])

      issue = H.finalize!(w, "T1", "inv-2")
      assert %{number: 2, operation_id: "invoice/inv-2/issue", duplicate: false} = issue
      assert issue.total.minor_units == 3_900
      assert {:ok, :applied} = H.post_issue(w, "T1", issue)
      assert {:ok, :duplicate} = H.post_issue(w, "T1", issue)

      assert {:ok, :applied} =
               Invoice.mark_posted(w.inv, "T1", %{
                 invoice_id: "inv-2",
                 operation_id: issue.operation_id,
                 result: :applied
               })

      assert %{posting: %{state: :posted}, state: :open} = H.invoice(w, "T1", "inv-2")
      assert H.balance(w, "T1", "receivable") == 3_900 + 0
      assert H.balance(w, "T1", "revenue") == -3_900

      # A period with an observation of unknown amount: incomplete, refused by add_line/3.
      observe(w, "T1", "u-unknown", "2027-03", :output_tokens, :unknown)
      incomplete = charge(w, "T1", "2027-03")
      assert %{incomplete: true, unknown_count: 1} = incomplete
      H.invoice!(w, "T1", "inv-3", [])

      assert {:error, :incomplete_charge} =
               Invoice.add_line(w.inv, "T1", %{
                 invoice_id: "inv-3",
                 line: {:charge, "usage", incomplete, "Model usage"}
               })

      # The checkout pays inv-2.
      {:ok, :applied} =
        LedgerCheckout.open(w.checkout, "T1", H.invoice_payment("pay-2", "inv-2", 3_900))

      assert {:ok, %{state: :running, wait: %{step: :charge, for: :charge_intent}}} =
               H.resume(w, "T1", "pay-2")

      assert %{payment: %{state: :pending}} = H.payment(w, "T1", "checkout.pay-2")
      {_, :pending} = H.charged!(w, "T1", "pay-2", @pending)

      # A verified success event; the same bytes; a later pending event; a forged one.
      ok_event = Provider.event("ev-1", {:charge, "checkout.pay-2"}, :succeeded, 3_900, "ch_1")

      assert {:ok, %{applied: true, state: :succeeded}} =
               PaymentLifecycle.apply_event(w.lc, "T1", ok_event)

      assert {:ok, %{duplicate: true}} = PaymentLifecycle.apply_event(w.lc, "T1", ok_event)

      assert {:ok, %{applied: false, state: :succeeded}} =
               PaymentLifecycle.apply_event(
                 w.lc,
                 "T1",
                 Provider.event("ev-2", {:charge, "checkout.pay-2"}, :pending, 3_900, "ch_1")
               )

      events = fn ->
        H.read_as(
          "T1",
          "SELECT event_id, applied FROM #{w.p.payments}.elzoo_payment_events ORDER BY 1"
        )
      end

      before = {events.(), H.payment(w, "T1", "checkout.pay-2")}

      forged =
        Provider.event(
          "ev-3",
          {:charge, "checkout.pay-2"},
          :failed,
          3_900,
          "ch_1",
          String.duplicate("0", 64)
        )

      assert {:error, :verification_failed} = PaymentLifecycle.apply_event(w.lc, "T1", forged)
      assert {events.(), H.payment(w, "T1", "checkout.pay-2")} == before
      assert events.() == [["ev-1", true], ["ev-2", false]]

      assert H.resume(w, "T1", "pay-2") == {:ok, %{state: :completed, wait: nil}}
      assert %{state: :paid} = H.invoice(w, "T1", "inv-2")
      assert H.balance(w, "T1", "receivable") == 0
      assert H.balance(w, "T1", "cash") == 3_900

      settle = fn ->
        H.read_as(
          "T1",
          "SELECT operation_id FROM #{w.p.journal}.elzoo_journal_operations WHERE operation_id LIKE 'checkout/%' ORDER BY 1"
        )
      end

      assert settle.() == [["checkout/pay-2/settle"]]

      # A further resume/3 calls nothing.
      revision = H.checkout!(w, "T1", "pay-2").revision
      calls = Agent.get(Provider, & &1.calls)
      assert H.resume(w, "T1", "pay-2") == {:ok, %{state: :completed, wait: nil}}
      assert H.checkout!(w, "T1", "pay-2").revision == revision
      assert Agent.get(Provider, & &1.calls) == calls
      assert settle.() == [["checkout/pay-2/settle"]]
    end

    test "compensation in reverse order; a failed compensation stops for an operator", %{w: w} do
      :ok = H.accounts!(w, "T1")

      for id <- ["inv-c", "inv-f"] do
        H.invoice!(w, "T1", id, [{:adjustment, "a1", H.eur(500), "order", "order/" <> id}])
        H.finalize!(w, "T1", id)
      end

      # The settle step names an account that was never opened.
      {:ok, :applied} =
        LedgerCheckout.open(
          w.checkout,
          "T1",
          H.invoice_payment("comp", "inv-c", 500, to: "never-opened")
        )

      {_, :succeeded} = H.charged!(w, "T1", "comp", @ok)
      refunds_before = length(Provider.calls(:refund))

      # One resume: the settle fails, the invoice step is compensated first, the refund waits.
      assert {:ok,
              %{state: :compensating, wait: %{step: :charge, for: :refund_intent, admission: a}}} =
               H.resume(w, "T1", "comp")

      assert %{state: :failed, failure: :unknown_account} = H.step(w, "T1", "comp", :settle)
      assert %{state: :compensated} = H.step(w, "T1", "comp", :invoice)
      assert %{state: :succeeded} = H.step(w, "T1", "comp", :charge)
      assert %{state: :open, paid: %{minor_units: 0}} = H.invoice(w, "T1", "inv-c")

      {_, :succeeded} = H.refund!(w, "T1", "comp", a, @refunded)
      assert H.resume(w, "T1", "comp") == {:ok, %{state: :compensated, wait: nil}}

      assert H.read_as(
               "T1",
               "SELECT reversal_id FROM #{w.p.invoice}.elzoo_invoice_reversals ORDER BY 1"
             ) == [["checkout/comp/c/invoice"]]

      assert [%{refund_id: "comp/charge", state: :succeeded}] =
               H.payment(w, "T1", "checkout.comp").refunds

      assert length(Provider.calls(:refund)) == refunds_before + 1

      revision = H.checkout!(w, "T1", "comp").revision
      calls = Agent.get(Provider, & &1.calls)
      assert H.resume(w, "T1", "comp") == {:ok, %{state: :compensated, wait: nil}}
      assert H.checkout!(w, "T1", "comp").revision == revision
      assert Agent.get(Provider, & &1.calls) == calls

      # A third checkout whose scripted refund is declined.
      {:ok, :applied} =
        LedgerCheckout.open(
          w.checkout,
          "T1",
          H.invoice_payment("fail", "inv-f", 500, to: "never-opened")
        )

      {_, :succeeded} = H.charged!(w, "T1", "fail", @ok)

      assert {:ok, %{state: :compensating, wait: %{for: :refund_intent, admission: a}}} =
               H.resume(w, "T1", "fail")

      {_, :failed} = H.refund!(w, "T1", "fail", a, {:declined, "refund_declined"})
      assert {:ok, %{state: :needs_operator}} = H.resume(w, "T1", "fail")
      assert %{state: :compensation_failed} = H.step(w, "T1", "fail", :charge)

      assert {:ok, %{checkout_ids: ["fail"], more: false}} =
               LedgerCheckout.list_running(w.checkout, "T1", %{
                 after: nil,
                 limit: 16,
                 state: :needs_operator
               })
    end

    test "refunds, an unknown charge, approval drift and a top-up", %{w: w} do
      :ok = H.accounts!(w, "T1")

      # A separate succeeded payment of 100: a refund of 60 admitted, one of 50 over.
      {:ok, :applied} =
        PaymentLifecycle.create(w.lc, "T1", %{
          payment_id: "pay-100",
          approved: %{amount: H.eur(100), recipient: "merchant-1"},
          approval_ref: "approval-100"
        })

      {:ok, admission} =
        PaymentLifecycle.charge(w.lc, "T1", %{
          payment_id: "pay-100",
          amount: H.eur(100),
          recipient: "merchant-1"
        })

      {_, :succeeded} =
        H.pay_intent!(
          w,
          "T1",
          Elzoo.Wave9.ChargeBinding,
          admission,
          {:charge, "pay-100"},
          :charge,
          @ok
        )

      refund = fn id, units ->
        PaymentLifecycle.refund(w.lc, "T1", %{
          payment_id: "pay-100",
          refund_id: id,
          amount: H.eur(units)
        })
      end

      assert {:ok, %{identity: _}} = refund.("r-60", 60)
      assert [%{refund_id: "r-60", state: :pending}] = H.payment(w, "T1", "pay-100").refunds
      assert refund.("r-50", 50) == {:error, :over_refund}

      # An unknown charge waits at the charge intent with no compensation; a poll makes it definite.
      {:ok, :applied} = LedgerCheckout.open(w.checkout, "T1", H.top_up("unk", 100))
      {pid, :unknown} = H.charged!(w, "T1", "unk", {:unknown, :timeout})

      assert {:ok, %{state: :running, wait: %{step: :charge, for: :charge_intent}}} =
               H.resume(w, "T1", "unk")

      assert %{state: :started, compensation: nil} = H.step(w, "T1", "unk", :charge)
      assert H.poll!(w, "T1", pid, {:charge, "checkout.unk"}, @ok) == :succeeded
      assert H.resume(w, "T1", "unk") == {:ok, %{state: :completed, wait: nil}}
      assert H.balance(w, "T1", "wallet") == 100

      # Approval drift: compensated with :approval_mismatch, the payment :created, no provider call.
      calls = Agent.get(Provider, & &1.calls)

      {:ok, :applied} =
        LedgerCheckout.open(w.checkout, "T1", H.top_up("drift", 150, approved: 100))

      assert H.resume(w, "T1", "drift") == {:ok, %{state: :compensated, wait: nil}}
      assert %{failure: :approval_mismatch} = H.checkout!(w, "T1", "drift")
      assert %{payment: %{state: :created}} = H.payment(w, "T1", "checkout.drift")
      assert Agent.get(Provider, & &1.calls) == calls

      # A top-up posts to the wallet; a later post over its balance is refused.
      {:ok, :applied} = LedgerCheckout.open(w.checkout, "T1", H.top_up("top", 40))
      {_, :succeeded} = H.charged!(w, "T1", "top", @ok)
      assert H.resume(w, "T1", "top") == {:ok, %{state: :completed, wait: nil}}

      assert H.read_as(
               "T1",
               "SELECT operation_id FROM #{w.p.journal}.elzoo_journal_operations WHERE operation_id LIKE '%/wallet' ORDER BY 1"
             ) == [["checkout/top/wallet"], ["checkout/unk/wallet"]]

      assert H.balance(w, "T1", "wallet") == 140
      {:ok, minus} = Money.negate(H.eur(141))

      assert Journal.post(w.journal, "T1", %{
               operation_id: "spend-1",
               actor_ref: "svc:shop",
               reason: "spend",
               postings: [
                 %{account_id: "wallet", amount: minus},
                 %{account_id: "revenue", amount: H.eur(141)}
               ]
             }) == {:error, :insufficient_funds}
    end
  end

  # ------------------------------------------------------------ group 2: the mounted server

  defp allowed(id, tenant) do
    for bot <- Server.bots(tenant),
        match?(
          {:ok, %{verdict: :allow}},
          Elzoo.Authorization.decide(
            Server.policy(),
            %{
              tenant: tenant,
              resource: "mcp-server",
              action_id: "mcp.run/" <> bot.bot_id,
              payload: nil,
              writes: [%{target: "bot/" <> bot.bot_id, field: "run", value: true}]
            },
            %{proposer: id, effect_class: "mcp.run", own: Server.own(id), parent: :none}
          )
        ),
        bot.start_schema["type"] == "object",
        do: bot.name
  end

  describe "group 2: doors" do
    test "the mounted server: lists, a call, the bound, bad arguments and the refusals", %{w: w0} do
      w = B.engines!(w0)
      srv = Server.start!(w)
      assert Server.idle_timeout_ms() > Server.call_timeout_ms() + 5_000

      # Lists: each caller exactly the bots that domain/authorization allows it, in byte order.
      p = Server.client!(w, srv, "T1", Server.token(w, srv, "P"))
      q = Server.client!(w, srv, "T1", Server.token(w, srv, "Q"))
      d = Server.client!(w, srv, "T2", Server.token(w, srv, "D"))
      assert Server.names(p) == ["slow", "summarize"]
      assert Server.names(q) == ["summarize", "translate"]
      assert Server.names(p) == Enum.sort(allowed("P", "T1"))
      assert Server.names(q) == Enum.sort(allowed("Q", "T1"))
      assert Server.names(d) == ["invoice"]
      refute "badroot" in (Server.names(p) ++ Server.names(q))

      # A call: one pinned Run with P as its acting principal; the completion payload.
      result = B.mcp_call(w, p.session, p.snapshot, "summarize", %{"text" => "hello"})
      assert {false, %{"payload" => payload, "run_id" => run_id}} = Server.text(result)
      assert [{"T1", "P", "bot-summarize"}] = Server.starts(w)
      assert {:ok, %{payload: ^payload}} = B.result(w, run_id)
      assert payload["content"] == "done: hello"
      assert B.entry(w, run_id).scope.principal == "human:P"

      pins =
        for {"recipe_pinned", %{"run_id" => ^run_id} = r} <-
              RS.rows(w.rs_owner_store, RS.stream("T1")),
            do: r

      assert [%{"identity" => identity}] = pins
      assert identity == w.tenants["T1"].version

      # A Run still open at the bound: the tool error {run_id, state: running}; the Run goes on.
      slow = B.mcp_call(w, p.session, p.snapshot, "slow", %{"text" => "later"})
      assert {true, %{"run_id" => slow_run, "state" => "running"}} = Server.text(slow)

      B.release!(
        w,
        {:model, slow_run},
        B.outcome(slow_run <> ":m:1", "completed", "elzoo.ai-text.result", B.say("late"))
      )

      B.finished!(w, slow_run)
      assert {:ok, %{payload: %{"content" => "late"}}} = B.result(w, slow_run)

      # Arguments that fail the start schema, as a raw tools/call: invalid_arguments, no Run.
      starts = length(Server.starts(w))
      token_p = Server.token(w, srv, "P")
      sid = Server.legacy!(srv, token_p)

      assert {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} =
               Server.raw(srv, token_p, sid, "tools/call", %{
                 name: "summarize",
                 arguments: %{text: 5}
               })

      assert text =~ "invalid_arguments"
      assert length(Server.starts(w)) == starts

      # An expired token: 401 before any handler, no start.
      expired = Server.token(w, srv, "P", exp: -10, iat: -700)
      needs = Server.need_calls(w)

      resp =
        Server.post(
          srv,
          [{"authorization", "Bearer " <> expired}],
          Server.rpc(1, "tools/list", %{})
        )

      assert resp.status == 401 and Jason.decode!(resp.body) == %{"error" => "unauthorized"}
      assert length(Server.starts(w)) == starts
      assert Server.need_calls(w) == needs

      # Another tenant's valid token is not refused at the door: its caller lists only its own
      # bots, a T1 bot by name is -32602 with no start, and P's legacy session is 404 -32600.
      token_d = Server.token(w, srv, "D")
      sid_d = Server.legacy!(srv, token_d)

      assert {200, %{"error" => %{"code" => -32602}}} =
               Server.raw(srv, token_d, sid_d, "tools/call", %{
                 name: "summarize",
                 arguments: %{text: "x"}
               })

      assert length(Server.starts(w)) == starts

      needs = Server.need_calls(w)

      assert {404, %{"error" => %{"code" => -32600}}} =
               Server.raw(srv, token_d, sid, "tools/list", %{})

      assert Server.need_calls(w) == needs

      # subscriptions/listen with a valid token: -32601 and no stream.
      listen =
        Server.post(
          srv,
          [{"authorization", "Bearer " <> token_p}, {"mcp-method", "subscriptions/listen"}],
          Server.rpc(7, "subscriptions/listen", %{})
        )

      assert listen.status == 200
      assert %{"error" => %{"code" => -32601}, "id" => nil} = Jason.decode!(listen.body)

      # A session connected while its token was valid, called after exp + leeway: 401.
      short = Server.client!(w, srv, "T1", Server.token(w, srv, "P", exp: 30))
      H.tick(w, 31_000)

      assert {:refused, :authentication_failed} =
               B.mcp_call(w, short.session, short.snapshot, "summarize", %{"text" => "x"})

      assert length(Server.starts(w)) == starts
      assert H.env(w, :errors) == nil
    end
  end

  # ------------------------------------------------------------ group 2: events out

  describe "group 2: events out" do
    test "signed delivery, dedup tries, a dead letter, a private address at send and register",
         %{w: w} do
      b = w.hooks.binding
      e1 = H.endpoint(w, "e1", ["order.paid"], true)
      e2 = H.endpoint(w, "e2", ["order.paid"], false)
      e3 = H.endpoint(w, "e3", ["order.refunded"], false)
      for e <- [e1, e2, e3], do: assert({:ok, :applied} = WebhookOut.register(b, "T1", e))

      H.hook_answers(w, "/hooks/e1", [503, 200])
      H.hook_answers(w, "/hooks/e2", [503])

      assert {:ok, %{deliveries: 2}} =
               WebhookOut.enqueue(b, "T1", %{
                 event_id: "evt-1",
                 name: "order.paid",
                 payload: %{"order" => 7}
               })

      d1 = H.delivery_id("e1", "evt-1")
      d2 = H.delivery_id("e2", "evt-1")

      # First round: both are sent once; E1 gets a second try, E2 is dead-lettered.
      [_, _] = H.hook_round!(w, "T1")
      assert %{state: :pending, try: 2} = H.hook_status(w, "T1", d1)

      assert %{state: :dead_lettered, dead_letter: :filed} = H.hook_status(w, "T1", d2)

      assert [%{message_id: ^d2, record: %{"reason" => "dispatched_unresolved"}}] =
               H.dead_letters(w, "T1")

      {:ok, backoff} = RetryTimeout.backoff(w.hooks.retry, 1)
      H.tick(w, backoff)
      [_] = H.hook_round!(w, "T1")
      assert %{state: :delivered, try: 2} = H.hook_status(w, "T1", d1)

      requests = H.hook_requests(w)
      e1_posts = for r <- requests, r.path == "/hooks/e1", do: r
      e2_posts = for r <- requests, r.path == "/hooks/e2", do: r
      assert length(e1_posts) == 2 and length(e2_posts) == 1
      ids = for r <- e1_posts, {"webhook-id", id} <- r.headers, do: id
      assert ids == ["evt-1", "evt-1"]

      # The Standard Webhooks check with each endpoint's secret; another secret refuses.
      secrets = H.env(w, :hook_secrets)
      other = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

      for r <- requests do
        secret = secrets["key-" <> Path.basename(r.path)]
        assert H.verify_signature(secret, r.headers, r.body)
        refute H.verify_signature(other, r.headers, r.body)
      end

      # E3: registered while the double answered public; a private address at send.
      H.dns(w, [H.private_address()])
      seen = length(H.hook_requests(w))

      assert {:ok, %{deliveries: 1}} =
               WebhookOut.enqueue(b, "T1", %{
                 event_id: "evt-2",
                 name: "order.refunded",
                 payload: %{"order" => 8}
               })

      d3 = H.delivery_id("e3", "evt-2")
      retry = w.hooks.retry

      for n <- 1..3 do
        [{t, {:ok, :applied}}] = H.hook_round!(w, "T1")
        assert t.try == 1 and t.rearm == n > 1
        status = H.hook_status(w, "T1", d3)

        if n < 3 do
          {:ok, ms} = RetryTimeout.delay(retry, n, :retryable, %{failure_delay_ms: nil, random: 0})
          assert %{state: :pending, try: 1} = status
          assert status.due_at_ms == H.now(w) + ms
          H.tick(w, ms)
        else
          assert %{state: :dead_lettered, dead_letter: :filed} = status
        end
      end

      assert length(H.hook_requests(w)) == seen

      assert Enum.sort(for(e <- H.dead_letters(w, "T1"), do: {e.message_id, e.record["reason"]})) ==
               Enum.sort([{d2, "dispatched_unresolved"}, {d3, "retries_exhausted"}])

      # register/3 while the double answers a private address: refused, no row.
      e4 = H.endpoint(w, "e4", ["order.paid"], false)
      assert {:error, {:egress, :non_public_address}} = WebhookOut.register(b, "T1", e4)

      assert H.read_as(
               "T1",
               "SELECT endpoint_id FROM #{w.p.hooks}.elzoo_webhook_endpoints ORDER BY 1"
             ) == [["e1"], ["e2"], ["e3"]]
    end
  end

  # ------------------------------------------------------------ group 3: models

  describe "group 3: models" do
    test "routing: throttle and a new Attempt, cool-down, data policy, credentials, image, unknown, local rate",
         %{w: w0, lua: lua} do
      w = B.engines!(w0, lua: lua)
      m = Models.setup!(w)

      # The engine and recipe-store Store schemas hold exactly the Store grants.
      stores = [w.rs_prefix | for({_, t} <- w.tenants, do: t.prefix)]

      assert H.grants(stores, w.role) ==
               {Enum.reduce(stores, %{}, &Map.merge(&2, H.store_grants(&1))), false}

      start = fn label, text, opts ->
        spec =
          B.agent_spec(label, [:host], %{
            model_attempts: 2,
            move_on: ["throttled", "overloaded"],
            image_input: true
          })

        B.start_bot!(w, "T1", label, spec, text, [model: :routed] ++ opts)
      end

      # The loop's finish. A stopped finish names no completed action, so the engine refuses it
      # as `completion_evidence` and the Run has no completion (run-engine's root finish rule).
      finish = fn label ->
        B.await!(fn -> List.keyfind(B.settlements(w, label), label <> ":finish", 0) end)
        [payload] = for {_, "finish", _, p} <- B.actions(w, label), do: p
        payload
      end

      after_of = fn action ->
        for a <- Models.log(w, :after),
            a.action_id == action,
            do: Map.take(a, [:ref, :n, :outcome, :decision])
      end

      select_of = fn action ->
        for s <- Models.log(w, :select), s.action_id == action, do: s.result
      end

      intents_of = fn run -> for i <- Models.log(w, :intent), i.run_id == run, do: i end

      # Throttle: compat answers 429 with Retry-After 30; the action ends failed with the
      # candidate's facts, and Attempt 2 under the model-attempt schema goes to gemini.
      t0 = H.now(w)
      Models.script(w, "compat", [Models.compat_throttled(30)])
      Models.script(w, "gemini", [Models.gemini_answer("hello from gemini")])
      start.("r1", "Hello.", [])
      assert answered!(w, "r1") == "hello from gemini"

      assert after_of.("r1:m:1") == [
               %{
                 ref: "compat",
                 n: 1,
                 outcome: {:refused, :throttled, %{retry_after: 30}},
                 decision: {:ok, {:next, %{ref: "compat", not_before_ms: t0 + 30_000}}}
               }
             ]

      assert after_of.("r1:m:1:2") == [
               %{ref: "gemini", n: 1, outcome: :completed, decision: {:ok, :done}}
             ]

      assert {"r1:m:1", "failed", _} = List.keyfind(B.settlements(w, "r1"), "r1:m:1", 0)

      assert [{"r1:m:1:2", "model_call", "elzoo.agent-loop.model-attempt", attempt}] =
               for(a <- B.actions(w, "r1"), elem(a, 0) == "r1:m:1:2", do: a)

      assert attempt["attempts"] == [
               %{
                 "attempt" => 1,
                 "reason" => "throttled",
                 "retry_after" => 30,
                 "candidate" => "compat"
               }
             ]

      assert [{:ok, %{eligible: ["compat", "gemini"]}}] = select_of.("r1:m:1")

      assert [{:ok, %{eligible: ["gemini"], excluded: excluded}}] = select_of.("r1:m:1:2")
      assert {"compat", :tried} in excluded
      assert length(Models.requests(w, "compat")) == 1
      assert length(Models.requests(w, "gemini")) == 1

      # The throttled Attempt is one observation of unknown amount; gemini's counters are the
      # provider's. The totals count the first Attempt as unknown, never as zero.
      observations = for o <- Models.log(w, :observation), o.run_id == "r1", do: o
      assert [unknown] = for(o <- observations, o.amount == :unknown, do: o)
      assert %{provider_id: "wave9-compat", attempt_id: "r1:m:1", source: :unknown} = unknown
      known = for o <- observations, o.amount != :unknown, do: {o.unit, o.amount, o.source}
      assert {:output_tokens, 87, :provider_reported} in known

      {:ok, totals} = Metering.totals(w.meter, "T1", %{period: Models.period(), max_rows: 100})

      assert %{known: 0, unknown_count: 1, count: 1} =
               Enum.find(totals, &(&1.unit == :output_tokens and &1.source == :unknown))

      assert %{known: 87, unknown_count: 0} =
               Enum.find(totals, &(&1.unit == :output_tokens and &1.source == :provider_reported))

      H.tick(w, 1_000)
      compat_needs = {Models.cred_calls(w, "compat"), Models.art_calls(w, "compat")}
      image = %{"artifact" => %{"id" => m.image, "version" => 1}, "media_type" => "image/png"}

      # Image: Ann's start with one PNG artifact (on MinIO), while compat cools down.
      Models.script(w, "gemini", [Models.gemini_answer("one pixel")])
      start.("r2i", "What is in this picture?", principal: "human:ann", images: [image])
      assert answered!(w, "r2i") == "one pixel"

      [{_, "model_call", _, call}] = for a <- B.actions(w, "r2i"), elem(a, 0) == "r2i:m:1", do: a
      newest = call["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()

      assert newest["parts"] == [
               %{"type" => "text", "text" => "What is in this picture?"},
               Map.put(image, "type", "image")
             ]

      # compat is still cooling down, but capability is checked first.
      assert [{:ok, %{eligible: ["gemini"], excluded: excluded2}}] = select_of.("r2i:m:1")
      assert {"compat", :capability} in excluded2

      gemini_image = Jason.decode!(List.last(Models.requests(w, "gemini")).body)
      assert [blob] = inline_data(gemini_image)
      assert Base.decode64!(blob["data"]) == Models.png()
      assert blob["mime_type"] == "image/png" or blob["mimeType"] == "image/png"
      assert Models.art_calls(w, "gemini") >= 1
      assert {Models.cred_calls(w, "compat"), Models.art_calls(w, "compat")} == compat_needs
      assert length(Models.requests(w, "compat")) == 1

      # The cool-down edge: cooling down at +29,999, eligible at +30,000.
      H.clock(w, t0 + 29_999)
      Models.script(w, "gemini", [Models.gemini_answer("still cooling")])
      start.("r3", "Hello.", [])
      assert answered!(w, "r3") == "still cooling"
      assert [{:ok, %{eligible: ["gemini"], excluded: excluded3}}] = select_of.("r3:m:1")
      assert {"compat", :cooling_down} in excluded3

      # Unknown stops: compat, eligible again, times out; one intent, no fallback to gemini.
      H.clock(w, t0 + 30_000)
      gemini_seen = length(Models.requests(w, "gemini"))
      Models.script(w, "compat", [{:transport_error, :timeout}])
      start.("r4", "Hello.", [])

      assert %{"status" => "stopped", "reason" => "model_call_not_completed"} = finish.("r4")
      assert [{:ok, %{eligible: ["compat", "gemini"]}}] = select_of.("r4:m:1")

      assert after_of.("r4:m:1") == [
               %{
                 ref: "compat",
                 n: 1,
                 outcome: {:unknown, :timeout},
                 decision: {:ok, {:stop, :unknown_outcome}}
               }
             ]

      assert {"r4:m:1", "unknown", _} = List.keyfind(B.settlements(w, "r4"), "r4:m:1", 0)
      assert {"r4:finish", "refused", _} = List.keyfind(B.settlements(w, "r4"), "r4:finish", 0)
      assert [%{ref: "compat", n: 1}] = intents_of.("r4")
      assert Models.intent_streams(w, "r4", ["r4:m:1", "r4:m:1:2"]) == [{"r4:m:1", "compat", 1}]
      assert length(Models.requests(w, "compat")) == 2
      assert length(Models.requests(w, "gemini")) == gemini_seen
      refute Enum.any?(B.actions(w, "r4"), &(elem(&1, 0) == "r4:m:1:2"))

      # Local rate wait: the second send of the window is refused by tenant_rate with W; the
      # binding waits W on the shared clock, then one intent to the same candidate.
      {:ok, limiter} =
        Elzoo.RateLimit.new(
          tenant_rate: %{capacity: 1, refill: 1, interval_ms: 5_000},
          principal_rate: %{capacity: 10, refill: 10, interval_ms: 1_000},
          max_in_flight: 8,
          tenant_in_flight: 8,
          max_keys: 16
        )

      Models.script(w, "compat", [
        Models.compat_answer({"host_lookup", %{}}),
        Models.compat_answer("after the wait")
      ])

      start.("r5", "Hello.", limiter: limiter)
      waiting = B.await!(fn -> H.env(w, {:waiting, "r5"}) end)
      assert %{action_id: "r5:m:2", ms: 5_000} = waiting
      assert length(Models.requests(w, "compat")) == 3
      H.tick(w, 5_000)
      assert answered!(w, "r5") == "after the wait"

      assert after_of.("r5:m:2") == [
               %{
                 ref: "compat",
                 n: 1,
                 outcome: {:rate_limited, 5_000},
                 decision: {:ok, {:retry_same, 5_000}}
               },
               %{ref: "compat", n: 2, outcome: :completed, decision: {:ok, :done}}
             ]

      assert [%{ref: "compat", n: 2}] = for(i <- intents_of.("r5"), i.action_id == "r5:m:2", do: i)
      assert Models.intent_streams(w, "r5", ["r5:m:2"]) == [{"r5:m:2", "compat", 2}]
      assert length(Models.requests(w, "compat")) == 4

      # The refused send made no intent and no observation: r5:m:2's observations are the
      # counters of the one completed send.
      r5_m2 = for o <- Models.log(w, :observation), o.attempt_id == "r5:m:2", do: o
      assert r5_m2 != []
      assert Enum.all?(r5_m2, &(&1.usage_id =~ ~r/\|compat\|[a-z_]+_tokens\z/))

      # Data policy: compat-eu is excluded by T1's policy in every select; its Needs are never
      # called and no intent names its provider account.
      selects = Models.log(w, :select)
      assert length(selects) == 7

      for select <- selects do
        assert {:ok, %{excluded: excluded}} = select.result
        assert {"compat-eu", {:data_policy, :region}} in excluded
      end

      assert Models.cred_calls(w, "compat-eu") == 0
      assert Models.art_calls(w, "compat-eu") == 0
      assert Models.requests(w, "compat-eu") == []
      refute Enum.any?(Models.log(w, :intent), &("acct-compat-eu" in &1.identity))

      # Credentials: each stub sees only its own key, in its own header; no Effect-intent Store
      # table holds either key.
      keys = m.keys

      # The compatible stub parses each Chat Completions body that req_llm's LMStudio provider
      # encoded: the documented request schema, the candidate's model, the messages and the
      # bot's tools; no request carries stop sequences.
      chat_schema = Models.chat_completions_schema()

      for req <- Models.requests(w, "compat") do
        body = req.json
        assert Elzoo.AiText.Schema.validate(body, chat_schema) == :ok, req.body
        assert body["model"] == "compat-chat"
        assert [_ | _] = body["messages"]
        assert [%{"type" => "function", "function" => %{"name" => "host_lookup"}}] = body["tools"]
        refute Map.has_key?(body, "stop")
      end

      for req <- Models.requests(w, "compat") do
        assert Models.header(req, "authorization") == ["Bearer " <> keys["compat"]]
        refute has?({req.headers, req.body}, [keys["gemini"], keys["compat-eu"]])
      end

      for req <- Models.requests(w, "gemini") do
        assert Models.header(req, "x-goog-api-key") == [keys["gemini"]]
        refute has?({req.headers, req.body}, [keys["compat"], keys["compat-eu"]])
      end

      stores =
        Models.store_bytes([w.intents_prefix | for({_, t} <- w.tenants, do: t.prefix)])

      assert Models.holds?(stores, "acct-gemini"), "the read finds the intents' identities"
      refute Models.holds?(stores, keys["compat"])
      refute Models.holds?(stores, keys["gemini"])
      refute Models.holds?(stores, "acct-compat-eu")
      assert H.env(w, :errors) in [nil, []]
    end
  end

  # ------------------------------------------------------------ group 5: isolation

  describe "group 5: isolation" do
    test "each tenant's flows; owner-only DDL, scoped reads, 42501 inserts, updates of the other tenant",
         %{w: w} do
      oauth = Tools.oauth!(w)
      hooks = w.hooks.binding

      for t <- ["T1", "T2"] do
        lower = String.downcase(t)

        # An authorization-code connection (one attempt row).
        assert {_, _, {:ok, %{state: :active}}} = Tools.authorize!(w, oauth, t, "conn-" <> lower)

        # A delivered and a dead-lettered webhook.
        ok = H.endpoint(w, "ok-" <> lower, ["order.paid"], true)
        dl = H.endpoint(w, "dl-" <> lower, ["order.paid"], false)
        for e <- [ok, dl], do: assert({:ok, :applied} = WebhookOut.register(hooks, t, e))
        H.hook_answers(w, "/hooks/ok-" <> lower, [200])
        H.hook_answers(w, "/hooks/dl-" <> lower, [503])

        assert {:ok, %{deliveries: 2}} =
                 WebhookOut.enqueue(hooks, t, %{
                   event_id: "evt-" <> lower,
                   name: "order.paid",
                   payload: %{"order" => 1}
                 })

        [_, _] = H.hook_round!(w, t)

        assert %{state: :delivered} =
                 H.hook_status(w, t, H.delivery_id("ok-" <> lower, "evt-" <> lower))

        assert %{state: :dead_lettered} =
                 H.hook_status(w, t, H.delivery_id("dl-" <> lower, "evt-" <> lower))

        # A subscription.
        assert {:ok, %{subscription: %{state: :active}}} =
                 Plan.create(w.plan, t, %{
                   subscription_id: "sub-" <> lower,
                   plan: %{plan_id: "pro", version: 1},
                   fee: H.eur(2_900),
                   interval: :month,
                   start_ms: H.now(w),
                   trial_end_ms: nil
                 })

        # A compensated invoice checkout with one applied event.
        :ok = H.accounts!(w, t)
        invoice = "inv-" <> lower
        H.invoice!(w, t, invoice, [{:adjustment, "a1", H.eur(500), "order", "order/" <> invoice}])
        H.finalize!(w, t, invoice)
        id = "iso-" <> lower

        {:ok, :applied} =
          LedgerCheckout.open(
            w.checkout,
            t,
            H.invoice_payment(id, invoice, 500, to: "never-opened")
          )

        {_, :pending} = H.charged!(w, t, id, @pending)

        event =
          Provider.event("ev-" <> lower, {:charge, "checkout." <> id}, :succeeded, 500, "ch_1")

        assert {:ok, %{applied: true, state: :succeeded}} =
                 PaymentLifecycle.apply_event(w.lc, t, event)

        assert {:ok, %{state: :compensating, wait: %{for: :refund_intent, admission: a}}} =
                 H.resume(w, t, id)

        {_, :succeeded} = H.refund!(w, t, id, a, @refunded)
        assert H.resume(w, t, id) == {:ok, %{state: :compensated, wait: nil}}
      end

      tables = for {k, names} <- H.new_tables(), name <- names, do: {w.p[k], name}
      assert length(tables) == 18

      for {s, table} <- tables do
        name = "#{s}.#{table}"

        # Owner only, as elzoo_app.
        assert H.denied?(H.try_app("ALTER TABLE #{name} NO FORCE ROW LEVEL SECURITY")), name
        assert H.denied?(H.try_app("DROP POLICY elzoo_tenant_floor ON #{name}")), name

        # Reads without a tenant predicate, in T2's scope and then in T1's.
        tenants = fn t -> H.read_as(t, "SELECT DISTINCT tenant FROM #{name}") |> List.flatten() end
        assert tenants.("T2") == ["T2"], name
        assert tenants.("T1") == ["T1"], name

        # In T1's scope, a copy of a T1 row naming T2 is refused (42501).
        insert =
          "INSERT INTO #{name} SELECT (jsonb_populate_record(NULL::#{name}, " <>
            "to_jsonb(t) || '{\"tenant\": \"T2\"}')).* FROM #{name} t LIMIT 1"

        assert H.rls_denied?(H.try_as("T1", insert)), name

        update = "UPDATE #{name} SET tenant = tenant WHERE tenant = 'T2'"

        if table in H.insert_only() do
          # Refused by privilege, before row security.
          result = H.try_as("T1", update)
          assert H.denied?(result) and not H.rls_denied?(result), name
        else
          # T2's rows match none in T1's scope; in T2's own scope the same update matches them.
          assert {:ok, %{num_rows: 0}} = H.try_as("T1", update), name
          assert {:ok, %{num_rows: n}} = H.try_as("T2", update)
          assert n > 0, name
        end
      end
    end
  end

  defp inline_data(value) when is_map(value) do
    Enum.flat_map(value, fn
      {k, v} when k in ["inline_data", "inlineData"] -> [v]
      {_, v} -> inline_data(v)
    end)
  end

  defp inline_data(value) when is_list(value), do: Enum.flat_map(value, &inline_data/1)
  defp inline_data(_), do: []
end
