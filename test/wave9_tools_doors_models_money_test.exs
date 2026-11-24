Code.require_file("support/wave9_tools_doors_models_money_helper.exs", __DIR__)

defmodule Elzoo.Wave9.ToolsDoorsModelsMoneyTest do
  # ELZ-379: the Wave 9 Pieces together on real PostgreSQL 16 and MinIO, every application call
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
  alias Elzoo.Wave9.{AppRepo, OwnerRepo, Provider, Recorder, Tools}
  alias Elzoo.Wave9.Bots, as: B
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

      # The second caller waits on the connection row (as elzoo_app, in pg_locks).
      B.await!(fn ->
        [[n]] = H.q!(AppRepo, "SELECT count(*) FROM pg_locks WHERE NOT granted")
        n > 0
      end)

      H.env(w, :release_refresh, true)
      answered!(w, "bot2")
      answered!(w, "bot3")
      assert [_] = Tools.token_requests(w, "refresh_token")
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
      assert [_, _] = Tools.token_requests(w, "refresh_token")

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
      assert g0.grant_id == "sub-1/0"

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
      assert g1.grant_id == "sub-1/1"

      before = subscription_row(w, "T1")
      assert {:ok, %{duplicate: true}} = renew.(trial_end + 1)
      assert subscription_row(w, "T1") == before

      # The host stores the grants; resolve/3 over them is entitled in period 1.
      assert {:entitled, %{grants: [%{grant_id: "sub-1/1"}]}} =
               Entitlement.resolve(plan_facts([g0, g1]), "T1", trial_end + 1)
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
end
