# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/webhook_out_test_helper.exs", __DIR__)

defmodule Elzoo.WebhookOutTest do
  # Scenarios 1-13 of the ELZ-362 Contract on the worker's own PostgreSQL 16 database. The
  # receiver is a Req.Test function plug given through the transport Need behind a resolver
  # double; no socket is opened. Effect-intent owners run on the volatile Memory Store.
  use ExUnit.Case, async: false

  alias Elzoo.{DeadLetterStore, EgressPolicy, RetryTimeout, TenantIsolation, WebhookOut}
  alias Elzoo.DurableLog.Memory
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost

  alias Elzoo.WebhookOut.{
    AppRepo,
    CrashRepo,
    DownRepo,
    Harness,
    IsoRepo,
    Migration,
    RaceRepo,
    TestBinding
  }

  @t0 1_800_000_000_000
  @public {93, 184, 215, 14}
  @host "hooks.example.com"
  @payload_secret "PAYLOAD-SECRET-q7"

  setup_all do
    %{role: role} = Harness.start_repos!()
    :ok = Harness.role_facts!(AppRepo, role)
    %{role: role, prefix: Harness.install!(role)}
  end

  setup %{prefix: p, role: role} do
    Harness.truncate!(p)
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, @t0)
    env = :ets.new(:env, [:public, :set])
    reqs = :ets.new(:reqs, [:public, :ordered_set])
    secret = Harness.secret()
    :ets.insert(env, [{:secret, secret}, {:requests, 0}])

    ctx = %{
      prefix: p,
      role: role,
      clock: clock,
      env: env,
      reqs: reqs,
      secret: secret,
      owners: :ets.new(:owners, [:public, :set]),
      tasks: start_supervised!({Task.Supervisor, []}, id: :tasks)
    }

    respond(ctx, fn _n, headers, body ->
      if Harness.verify_signature(secret, headers, body), do: 200, else: 401
    end)

    {:ok, b} = hooks(ctx)
    %{ctx: ctx, b: b}
  end

  # ---------------------------------------------------------------- host doubles

  defp hooks(ctx, overrides \\ []) do
    {:ok, retry} = RetryTimeout.policy(max_attempts: 3, base_backoff_ms: 1000, max_backoff_ms: 8000)
    env = ctx.env
    clock = ctx.clock
    policy = EgressPolicy.policy(hosts: [@host], ports: [443])

    plug = fn conn ->
      body = IO.iodata_to_binary(Req.Test.raw_body(conn))
      n = :ets.update_counter(env, :requests, 1)

      :ets.insert(
        ctx.reqs,
        {n,
         %{
           method: conn.method,
           host: conn.host,
           path: conn.request_path,
           headers: conn.req_headers,
           body: body
         }}
      )

      [{_, fun}] = :ets.lookup(env, :respond)

      case fun.(n, conn.req_headers, body) do
        {:sleep, ms} ->
          Process.sleep(ms)
          Plug.Conn.send_resp(conn, 200, "")

        {:redirect, status} ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://#{@host}/moved")
          |> Plug.Conn.send_resp(status, "")

        status ->
          Plug.Conn.send_resp(conn, status, "receiver body")
      end
    end

    opts = [
      repo: AppRepo,
      prefix: ctx.prefix,
      policy: fn _tenant -> {:ok, policy} end,
      resolver: fn host ->
        case :ets.lookup(env, {:dns, host}) do
          [{_, answer}] -> {:ok, answer}
          [] -> {:ok, [@public]}
        end
      end,
      transport: fn target ->
        :ets.insert(env, {:target, target})
        {:ok, [plug: plug]}
      end,
      secrets: fn request ->
        grant = if :ets.member(env, :deny), do: :deny, else: request
        [{_, value}] = :ets.lookup(env, :secret)

        %{
          grant: grant,
          resolver: fn ref, scope ->
            {:ok, %{ref: ref, scope: scope, value: value, version: 1, expires_at_unix_ms: @t0 * 2}}
          end,
          clock: fn -> :atomics.get(clock, 1) end
        }
      end,
      clock: fn -> :atomics.get(clock, 1) end,
      retry: retry,
      max_tries: 3,
      send_timeout_ms: 2000,
      try_deadline_ms: 60_000,
      dead_letters: DeadLetterStore.new(repo: AppRepo, prefix: ctx.prefix),
      effect: %{binding: TestBinding, provider_account: "test:webhooks"}
    ]

    WebhookOut.new(Keyword.merge(opts, overrides))
  end

  # The receiver's answer to request n (counted from now).
  defp respond(ctx, fun), do: :ets.insert(ctx.env, {:respond, fun})

  defp script(ctx, statuses) do
    [{_, base}] = :ets.lookup(ctx.env, :requests)
    respond(ctx, fn n, _, _ -> Enum.at(statuses, n - base - 1, List.last(statuses)) end)
  end

  defp dns(ctx, answer), do: :ets.insert(ctx.env, {{:dns, @host}, answer})
  defp deny(ctx), do: :ets.insert(ctx.env, {:deny, true})
  defp allow(ctx), do: :ets.delete(ctx.env, :deny)
  defp tick(ctx, ms), do: :atomics.add(ctx.clock, 1, ms)
  defp now(ctx), do: :atomics.get(ctx.clock, 1)
  defp requests(ctx), do: ctx.reqs |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  defp endpoint(id, extra \\ %{}) do
    Map.merge(
      %{
        endpoint_id: id,
        url: "https://#{@host}/hooks/#{id}",
        secret_ref: %{ref: "hook-key", scope: "T1/hooks"},
        events: ["order.paid"],
        dedup: false
      },
      extra
    )
  end

  defp register(b, tenant \\ "T1", e), do: WebhookOut.register(b, tenant, e)

  defp enqueue(b, id, payload), do: enqueue(b, id, "order.paid", payload)
  defp enqueue(b, id, name, payload), do: enqueue_in(b, "T1", id, name, payload)

  defp enqueue_in(b, tenant, id, name, payload),
    do: WebhookOut.enqueue(b, tenant, %{event_id: id, name: name, payload: payload})

  defp claim(b, tenant \\ "T1", limit \\ 256),
    do: WebhookOut.claim_due(b, tenant, %{limit: limit, lease_ms: 1000})

  defp status(b, tenant \\ "T1", t), do: WebhookOut.status(b, tenant, %{delivery_id: id(t)})
  defp id(%{delivery_id: id}), do: id
  defp id(id), do: id

  defp record(b, t, attempt, fallback \\ nil), do: record_in(b, "T1", t, attempt, fallback)

  defp record_in(b, tenant, t, attempt, fallback),
    do:
      WebhookOut.record(b, tenant, %{
        delivery_id: t.delivery_id,
        try: t.try,
        attempt: attempt,
        fallback: fallback
      })

  # The host: the live owner of this intent key, or a new or recovered one over its stores.
  defp owner(ctx, b, admission, context \\ nil) do
    case :ets.lookup(ctx.owners, admission.key) do
      [{_, stores, pid}] ->
        if Process.alive?(pid), do: pid, else: start_owner(ctx, b, admission, stores, context)

      [] ->
        stores =
          for {fold, limits} <- [
                {Intent.fold(TestBinding), Intent.limits()},
                {StoreHost.fold(), StoreHost.limits()}
              ],
              do: start_supervised!({Memory, fold: fold, limits: limits}, id: make_ref())

        start_owner(ctx, b, admission, stores, context)
    end
  end

  defp start_owner(ctx, b, a, [memory, host] = stores, context) do
    {:ok, pid} =
      Intent.start_link(
        binding: TestBinding,
        identity: a.identity,
        arguments: a.arguments,
        deadline: a.deadline,
        clock: fn -> :atomics.get(ctx.clock, 1) end,
        store: Memory.store(memory),
        # :fresh grants only a new intent; a recovered intent stays read-only.
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.tasks,
        adapter_context: context || b,
        allow_volatile: true
      )

    :ets.insert(ctx.owners, {a.key, stores, pid})
    pid
  end

  # The host process and its in-flight send die.
  defp crash!(ctx, key) do
    [{_, _, pid}] = :ets.lookup(ctx.owners, key)
    for t <- Task.Supervisor.children(ctx.tasks), do: Process.exit(t, :kill)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    Harness.poll(fn -> not Process.alive?(pid) end)
  end

  defp settled(pid) do
    Harness.poll(fn -> :sys.get_state(pid).tasks == %{} end)
    Intent.status(pid)
  end

  # Start or recover the try's intent, :rearm when asked, :dispatch, wait for the task.
  defp send!(ctx, b, t, context \\ nil) do
    pid = owner(ctx, b, t.admission, context)
    if t.rearm, do: assert({:ok, _} = Intent.advance(pid, :rearm))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
  end

  # One worker round: claim every due try, send it, record its result.
  defp round!(ctx, b) do
    {:ok, tries} = claim(b)

    Enum.map(tries, fn t ->
      st = send!(ctx, b, t)
      {t, record(b, t, st.attempts)}
    end)
  end

  defp observations(ctx),
    do: Harness.truth(ctx.prefix, "elzoo_webhook_observations", "try, attempt, result, applied")

  defp dead_letters(b, tenant \\ "T1") do
    {:ok, %{entries: entries}} =
      DeadLetterStore.list(b.dead_letters, tenant, %{source: "webhook-out", after: nil, limit: 100})

    entries
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # ---------------------------------------------------------------- 1

  describe "1: a signed delivery" do
    test "the receiver's Standard Webhooks check passes and the delivery is delivered", %{
      ctx: ctx,
      b: b
    } do
      assert {:ok, :applied} = register(b, endpoint("e1"))

      assert {:ok, %{deliveries: 1}} =
               enqueue(b, "evt-1", %{"order" => 7, "amount" => "1.00", "note" => @payload_secret})

      assert {:ok, [t]} = claim(b)
      # The delivery ID from its definition: SHA-256 of the canonical JSON of the two IDs.
      assert t.delivery_id == sha256(~s({"endpoint_id":"e1","event_id":"evt-1"}))
      assert %{endpoint_id: "e1", event_id: "evt-1", try: 1, rearm: false} = t

      assert t.admission.identity ==
               ["T1", "test:webhooks", "webhook-out", "post", t.delivery_id <> "/try/1"]

      assert t.admission.key == Elzoo.EffectIntent.Model.key(t.admission.identity)
      assert t.admission.deadline == @t0 + 60_000
      refute t.admission.arguments =~ @payload_secret
      assert t.admission.arguments =~ "payload_sha256"

      st = send!(ctx, b, t)
      assert {:Confirmed, 1} = st.phase
      assert {:ok, :applied} = record(b, t, 1)
      assert {:ok, %{state: :delivered, try: 1, dead_letter: :none}} = status(b, t)

      body = ~s({"amount":"1.00","note":"#{@payload_secret}","order":7})
      assert [req] = requests(ctx)
      assert %{method: "POST", host: @host, path: "/hooks/e1", body: ^body} = req
      assert Harness.header(req.headers, "webhook-id") == "evt-1"
      assert Harness.header(req.headers, "webhook-timestamp") == Integer.to_string(div(@t0, 1000))
      assert Harness.header(req.headers, "content-type") == "application/json"
      assert Harness.verify_signature(ctx.secret, req.headers, body)
      # A receiver holding another secret refuses the same request, as does a changed body.
      refute Harness.verify_signature(Harness.secret(), req.headers, body)
      refute Harness.verify_signature(ctx.secret, req.headers, body <> " ")
      # The transport Need got the egress-checked addresses to pin.
      assert [{:target, %{host: @host, port: 443, addresses: [@public]}}] =
               :ets.lookup(ctx.env, :target)

      assert [[1, 1, "delivered", true]] = observations(ctx)
    end
  end

  # ---------------------------------------------------------------- 2

  describe "2: egress" do
    test "a private address is refused at register/3 with nothing written", %{ctx: ctx, b: b} do
      dns(ctx, [{10, 0, 0, 1}])
      assert {:error, {:egress, :non_public_address}} = register(b, endpoint("e1"))
      dns(ctx, [@public, {127, 0, 0, 1}])
      assert {:error, {:egress, :non_public_address}} = register(b, endpoint("e1"))

      assert {:error, {:egress, :not_allowed}} =
               register(b, endpoint("e1", %{url: "https://other.example.com/x"}))

      assert {:error, {:egress, :scheme}} =
               register(b, endpoint("e1", %{url: "http://#{@host}/x"}))

      assert Harness.truth(ctx.prefix, "elzoo_webhook_endpoints") == []
    end

    test "a name that rebinds to a private address is refused at send, not sent", %{
      ctx: ctx,
      b: b
    } do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      dns(ctx, [{127, 0, 0, 1}])
      assert {:ok, [t]} = claim(b)
      st = send!(ctx, b, t)
      assert st.attempts == 1
      assert requests(ctx) == []
      assert [[1, 1, "not_sent:egress", false]] = observations(ctx)
      assert {:ok, :applied} = record(b, t, 1)
      due = now(ctx) + 1000

      assert {:ok, %{state: :pending, try: 1, due_at_ms: ^due, claimed_until_ms: nil}} =
               status(b, t)

      # Public again: the same try is sent after the delay, with a rearm.
      dns(ctx, [@public])
      tick(ctx, 1000)
      assert {:ok, [%{try: 1, rearm: true} = t2]} = claim(b)
      assert t2.admission == t.admission
      assert {:Confirmed, 2} = send!(ctx, b, t2).phase
      assert {:ok, :applied} = record(b, t2, 2)
      assert length(requests(ctx)) == 1
    end
  end

  # ---------------------------------------------------------------- 3

  describe "3: a crash after enqueue/3" do
    # Killing the Repo logs its pool's exit.
    @tag :capture_log
    test "leaves the deliveries due for the next claim", %{ctx: ctx, b: b} do
      pid = Harness.start!(CrashRepo, Harness.app_opts(ctx.role))
      {:ok, crashing} = hooks(ctx, repo: CrashRepo)
      assert {:ok, :applied} = register(crashing, endpoint("e1"))
      assert {:ok, :applied} = register(crashing, endpoint("e2"))
      assert {:ok, %{deliveries: 2}} = enqueue(crashing, "evt-1", %{"a" => 1})
      # The connection is dropped before any claim.
      Process.exit(pid, :kill)
      Harness.poll(fn -> not Process.alive?(pid) end)
      assert {:error, :unavailable} = claim(crashing)

      assert {:ok, tries} = claim(b)
      assert Enum.sort(Enum.map(tries, & &1.endpoint_id)) == ["e1", "e2"]
      assert Enum.all?(tries, &(&1.try == 1 and &1.event_id == "evt-1"))
    end
  end

  # ---------------------------------------------------------------- 4

  describe "4: leases" do
    test "a committed lease hides the row; after it the claim and the intent are equal and the recovered owner does not send",
         %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1", %{dedup: true}))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      assert {:ok, [t]} = claim(b)
      assert {:ok, []} = claim(b)
      lease = @t0 + 1000
      assert {:ok, %{claimed_until_ms: ^lease}} = status(b, t)

      # The send is in flight when the host dies: the receiver has the request, and no result
      # is stored.
      script(ctx, [{:sleep, 1500}])
      pid = owner(ctx, b, t.admission)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      Harness.poll(fn -> length(requests(ctx)) == 1 end)
      crash!(ctx, t.admission.key)
      assert observations(ctx) == []

      tick(ctx, 999)
      assert {:ok, []} = claim(b)
      tick(ctx, 1)
      assert {:ok, [t2]} = claim(b)
      assert t2.admission == t.admission and t2.try == 1 and not t2.rearm

      recovered = owner(ctx, b, t2.admission)
      refute Intent.status(recovered).active
      assert Intent.status(recovered).attempts == 1
      assert {:error, :read_only} = Intent.advance(recovered, :dispatch)
      assert {:error, :read_only} = Intent.advance(recovered, :rearm)
      Process.sleep(100)
      assert length(requests(ctx)) == 1

      # The host reads a dispatched intent with no result: the possibly sent rule.
      assert {:ok, :no_result} = record(b, t2, 1)
      assert {:ok, :applied} = record(b, t2, 1, :unknown)
      due = now(ctx) + 1000

      assert {:ok, %{state: :pending, try: 2, due_at_ms: ^due, claimed_until_ms: nil}} =
               status(b, t)
    end

    test "two concurrent claims take disjoint rows", %{ctx: ctx, b: b} do
      for i <- 1..4, do: assert({:ok, :applied} = register(b, endpoint("e#{i}")))
      assert {:ok, %{deliveries: 4}} = enqueue(b, "evt-1", %{"a" => 1})
      {:ok, race} = hooks(ctx, repo: RaceRepo)
      test = self()
      handler = "elz362-race-#{System.unique_integer()}"

      # The holder stops inside its claim transaction right after its locking statement.
      :telemetry.attach(
        handler,
        [:elzoo_wo_race, :query],
        fn _, _, meta, _ ->
          if Process.get(:hold) && String.contains?(meta.query, "SKIP LOCKED") do
            Process.delete(:hold)
            send(test, {:held, self()})

            receive do
              :release -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      holder =
        Task.async(fn ->
          Process.put(:hold, true)
          claim(race, "T1", 2)
        end)

      assert_receive {:held, holder_pid}
      assert {:ok, other} = claim(b)
      send(holder_pid, :release)
      assert {:ok, held} = Task.await(holder)

      held_ids = Enum.map(held, & &1.delivery_id)
      other_ids = Enum.map(other, & &1.delivery_id)
      assert length(held_ids) == 2 and length(other_ids) == 2
      assert MapSet.disjoint?(MapSet.new(held_ids), MapSet.new(other_ids))
      assert {:ok, []} = claim(b)
    end
  end

  # ---------------------------------------------------------------- 5

  describe "5: dedup and non-dedup after a 503" do
    test "dedup: two tries, two intents, one webhook-id and one body", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1", %{dedup: true}))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      script(ctx, [503, 200])

      assert [{t1, {:ok, :applied}}] = round!(ctx, b)
      [{_, _, pid1}] = :ets.lookup(ctx.owners, t1.admission.key)
      # No blind resend of try 1: the owner refuses it.
      assert {:error, _} = Intent.advance(pid1, :rearm)
      assert {:error, _} = Intent.advance(pid1, :dispatch)
      due = now(ctx) + 1000
      assert {:ok, %{state: :pending, try: 2, due_at_ms: ^due}} = status(b, t1)
      # The new try has no last result yet.
      assert [[2, nil, nil, nil]] =
               Harness.truth(
                 ctx.prefix,
                 "elzoo_webhook_deliveries",
                 "try, last_outcome, last_dispatch, last_error_class"
               )

      tick(ctx, 1000)
      assert [{t2, {:ok, :applied}}] = round!(ctx, b)
      assert t2.try == 2 and t2.delivery_id == t1.delivery_id
      refute t2.admission.key == t1.admission.key
      assert List.last(t2.admission.identity) == t1.delivery_id <> "/try/2"
      assert {:ok, %{state: :delivered, try: 2}} = status(b, t1)

      assert [r1, r2] = requests(ctx)
      assert Harness.header(r1.headers, "webhook-id") == "evt-1"
      assert Harness.header(r2.headers, "webhook-id") == "evt-1"
      assert r1.body == r2.body
      assert Harness.verify_signature(ctx.secret, r2.headers, r2.body)
      assert dead_letters(b) == []
    end

    test "non-dedup: one try, dead-lettered dispatched_unresolved in the store", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      script(ctx, [503])
      assert [{t, {:ok, :applied}}] = round!(ctx, b)
      assert {:ok, %{state: :dead_lettered, try: 1, dead_letter: :filed}} = status(b, t)
      tick(ctx, 100_000)
      assert {:ok, []} = claim(b)
      assert length(requests(ctx)) == 1

      assert [entry] = dead_letters(b)
      assert entry.message_id == t.delivery_id
      assert entry.work_ref == t.delivery_id

      assert entry.record == %{
               "version" => 1,
               "message_id" => t.delivery_id,
               "correlation_id" => "evt-1",
               "attempts" => 1,
               "reason" => "dispatched_unresolved",
               "last_outcome" => "failed",
               "last_dispatch" => "dispatched",
               "last_error_class" => "retryable"
             }
    end
  end

  # ---------------------------------------------------------------- 6

  describe "6: max_tries at its edge" do
    test "2 gives two tries and retries_exhausted; 3 makes a third try", %{ctx: ctx} do
      script(ctx, [503])

      for max <- [2, 3] do
        {:ok, b} = hooks(ctx, max_tries: max)
        name = "n#{max}"
        assert {:ok, :applied} = register(b, endpoint("e#{max}", %{dedup: true, events: [name]}))
        assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-#{max}", name, %{"a" => 1})
        before = length(requests(ctx))

        tries =
          Enum.flat_map(1..5, fn _ ->
            done = round!(ctx, b)
            tick(ctx, 10_000)
            done
          end)

        assert Enum.map(tries, fn {t, r} -> {t.try, r} end) ==
                 Enum.map(1..max, &{&1, {:ok, :applied}})

        assert length(requests(ctx)) - before == max
        [{t, _} | _] = tries
        assert {:ok, %{state: :dead_lettered, try: ^max, dead_letter: :filed}} = status(b, t)
        assert [entry] = Enum.filter(dead_letters(b), &(&1.message_id == t.delivery_id))
        assert %{"reason" => "retries_exhausted", "attempts" => ^max} = entry.record
      end
    end
  end

  # ---------------------------------------------------------------- 7

  describe "7: a send held past send_timeout_ms" do
    test "is a timeout, never sent again on the same try", %{ctx: ctx} do
      {:ok, b} = hooks(ctx, send_timeout_ms: 200)
      assert {:ok, :applied} = register(b, endpoint("plain"))
      assert {:ok, :applied} = register(b, endpoint("dedup", %{dedup: true, events: ["d"]}))
      script(ctx, [{:sleep, 1000}])

      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      assert {:ok, [t]} = claim(b)
      started = System.monotonic_time(:millisecond)
      st = send!(ctx, b, t)
      assert System.monotonic_time(:millisecond) - started < 900
      assert st.attempts == 1
      [{_, _, pid}] = :ets.lookup(ctx.owners, t.admission.key)
      assert {:error, _} = Intent.advance(pid, :rearm)
      assert {:error, _} = Intent.advance(pid, :dispatch)
      assert [[1, 1, "unknown:timed_out", false]] = observations(ctx)
      assert {:ok, :applied} = record(b, t, 1)
      assert {:ok, %{state: :dead_lettered}} = status(b, t)

      assert [%{record: %{"reason" => "dispatched_unresolved"} = r}] = dead_letters(b)

      assert {r["last_outcome"], r["last_dispatch"], r["last_error_class"]} ==
               {"timed_out", "unknown", "unclassified"}

      # Dedup: the next send is a new try.
      script(ctx, [{:sleep, 1000}, 200])
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-2", "d", %{"a" => 2})
      assert [{d1, {:ok, :applied}}] = round!(ctx, b)
      tick(ctx, 1000)
      assert [{d2, {:ok, :applied}}] = round!(ctx, b)
      assert d2.try == 2 and d2.admission.key != d1.admission.key
      assert {:ok, %{state: :delivered, try: 2}} = status(b, d1)
      assert length(requests(ctx)) == 3
    end
  end

  # ---------------------------------------------------------------- 8

  describe "8: a not-sent refusal" do
    test "is due again after delay/4 with rearm and sent on the same try", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      deny(ctx)
      assert [{t, {:ok, :applied}}] = round!(ctx, b)
      assert requests(ctx) == []
      assert [[1, 1, "not_sent:secret", true]] = observations(ctx)
      # delay(retry, 1, :retryable, %{failure_delay_ms: nil, ...}) with jitter :none is 1000.
      {:ok, ms} = RetryTimeout.delay(b.retry, 1, :retryable, %{failure_delay_ms: nil, random: 0})
      assert ms == 1000
      due = now(ctx) + ms

      assert {:ok, %{state: :pending, try: 1, due_at_ms: ^due, claimed_until_ms: nil}} =
               status(b, t)

      tick(ctx, 999)
      assert {:ok, []} = claim(b)
      tick(ctx, 1)
      allow(ctx)
      assert [{t2, {:ok, :applied}}] = round!(ctx, b)
      assert t2.rearm and t2.try == 1 and t2.admission == t.admission
      assert {:ok, %{state: :delivered, try: 1}} = status(b, t)
      assert [req] = requests(ctx)
      assert Harness.verify_signature(ctx.secret, req.headers, req.body)
    end

    test "at max_attempts it is dead-lettered retries_exhausted", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      deny(ctx)

      for {n, wait} <- [{1, 1000}, {2, 2000}] do
        assert [{t, {:ok, :applied}}] = round!(ctx, b)
        due = now(ctx) + wait
        assert {:ok, %{state: :pending, due_at_ms: ^due}} = status(b, t)
        assert t.rearm == n > 1
        tick(ctx, wait)
      end

      assert [{t, {:ok, :applied}}] = round!(ctx, b)
      assert {:ok, %{state: :dead_lettered, try: 1, dead_letter: :filed}} = status(b, t)
      assert requests(ctx) == []

      assert [%{record: record}] = dead_letters(b)

      assert record == %{
               "version" => 1,
               "message_id" => t.delivery_id,
               "correlation_id" => "evt-1",
               "attempts" => 3,
               "reason" => "retries_exhausted",
               "last_outcome" => "rejected",
               "last_dispatch" => "not_dispatched",
               "last_error_class" => "unavailable"
             }
    end
  end

  # ---------------------------------------------------------------- 9

  describe "9: other answers" do
    test "a 400 is permanent with no new try; a 302 is not followed", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1", %{dedup: true}))
      assert {:ok, :applied} = register(b, endpoint("e2", %{dedup: true, events: ["r"]}))

      script(ctx, [400])
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      assert [{t, {:ok, :applied}}] = round!(ctx, b)
      assert {:ok, %{state: :dead_lettered, try: 1}} = status(b, t)

      script(ctx, [{:redirect, 302}])
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-2", "r", %{"a" => 2})
      assert [{r, {:ok, :applied}}] = round!(ctx, b)
      assert {:ok, %{state: :dead_lettered, try: 1}} = status(b, r)

      tick(ctx, 100_000)
      assert {:ok, []} = claim(b)
      assert Enum.map(requests(ctx), & &1.path) == ["/hooks/e1", "/hooks/e2"]

      assert Enum.sort(
               Enum.map(
                 dead_letters(b),
                 &{&1.record["correlation_id"], &1.record["reason"], &1.record["last_error_class"]}
               )
             ) ==
               [{"evt-1", "permanent", "permanent"}, {"evt-2", "permanent", "permanent"}]
    end
  end

  # ---------------------------------------------------------------- 10

  describe "10: idempotency and bounds" do
    test "enqueue/3 duplicate, conflict, payload bound and an unlisted name", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      payload = %{"b" => [1, 2.5, nil], "a" => %{"y" => true, "x" => "é"}}
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", payload)
      # An endpoint registered later does not change a repeat: it writes nothing.
      assert {:ok, :applied} = register(b, endpoint("e2"))
      assert {:ok, :duplicate} = enqueue(b, "evt-1", Map.new(Enum.reverse(Map.to_list(payload))))
      assert {:error, :conflict} = enqueue(b, "evt-1", %{"a" => 1})
      assert {:error, :conflict} = enqueue(b, "evt-1", "order.other", payload)
      # 1 and 1.0 have different canonical bytes.
      assert {:ok, %{deliveries: 2}} = enqueue(b, "evt-2", %{"n" => 1})
      assert {:error, :conflict} = enqueue(b, "evt-2", %{"n" => 1.0})

      assert [[_, "evt-1", "order.paid", ~s({"a":{"x":"é","y":true},"b":[1,2.5,null]})], _] =
               Harness.truth(ctx.prefix, "elzoo_webhook_events", "tenant, event_id, name, payload")

      assert length(Harness.truth(ctx.prefix, "elzoo_webhook_deliveries")) == 3

      # A JSON string of n bytes has n + 2 canonical bytes.
      assert {:ok, %{deliveries: 2}} = enqueue(b, "evt-max", String.duplicate("a", 65_534))
      assert {:error, :invalid} = enqueue(b, "evt-over", String.duplicate("a", 65_535))
      assert {:ok, %{deliveries: 0}} = enqueue(b, "evt-none", "nobody.listens", %{"a" => 1})

      for bad <- ["", "evt 1", "evt\n1", "évt", String.duplicate("e", 129)],
          do: assert({:error, :invalid} = enqueue(b, bad, %{"a" => 1}))

      assert {:ok, %{deliveries: 0}} = enqueue(b, String.duplicate("e", 128), "x", 1)

      for bad <- [%{a: 1}, {:tuple}, <<255>>, self(), [1 | 2]],
          do: assert({:error, :invalid} = enqueue(b, "evt-bad", bad))

      for bad <- ["Order.paid", "", "a b", String.duplicate("n", 129)],
          do: assert({:error, :invalid} = enqueue(b, "evt-bad", bad, %{}))
    end

    test "register/3 duplicate, conflict and shape", %{ctx: ctx, b: b} do
      e = endpoint("e1", %{events: ["b.x", "a.y"]})
      assert {:ok, :applied} = register(b, e)
      assert {:ok, :duplicate} = register(b, %{e | events: ["a.y", "b.x"]})
      assert {:error, :conflict} = register(b, %{e | dedup: true})
      assert {:error, :conflict} = register(b, %{e | url: e.url <> "/v2"})

      assert {:error, :conflict} =
               register(b, %{e | secret_ref: %{ref: "other", scope: "T1/hooks"}})

      assert {:error, :conflict} = register(b, %{e | events: ["a.y"]})
      # Another tenant has its own endpoint IDs.
      assert {:ok, :applied} = register(b, "T2", %{e | dedup: true})

      for bad <- [
            %{e | endpoint_id: ""},
            %{e | endpoint_id: String.duplicate("e", 129)},
            %{e | url: "https://#{@host}/" <> String.duplicate("p", 2048)},
            %{e | events: []},
            %{e | events: ["a.y", "a.y"]},
            %{e | events: Enum.map(1..65, &"n#{&1}")},
            %{e | events: ["UPPER"]},
            %{e | dedup: nil},
            %{e | secret_ref: %{ref: "", scope: "s"}},
            Map.put(e, :extra, 1)
          ],
          do: assert({:error, :invalid} = register(b, bad))

      assert length(Harness.truth(ctx.prefix, "elzoo_webhook_endpoints")) == 2
    end

    test "new/1 and Migration.install/1 refuse bad options", %{ctx: ctx} do
      for bad <- [
            [max_tries: 0],
            [max_tries: 17],
            [send_timeout_ms: 60_001],
            [try_deadline_ms: 999],
            [prefix: "Bad"],
            [clock: :clock],
            [effect: %{binding: TestBinding, provider_account: "other"}],
            [effect: %{binding: String, provider_account: "test:webhooks"}],
            [retry: elem(RetryTimeout.policy(max_attempts: 257), 1)],
            [dead_letters: :none],
            [
              retry:
                elem(
                  RetryTimeout.policy(base_backoff_ms: 0, max_backoff_ms: 9_007_199_254_740_992),
                  1
                )
            ]
          ],
          do: assert({:error, :invalid} = hooks(ctx, bad))

      assert {:error, :invalid} = WebhookOut.new([])

      assert_raise ArgumentError, "invalid webhook-out prefix", fn ->
        Migration.install("bad-prefix")
      end
    end
  end

  # ---------------------------------------------------------------- 11

  describe "11: record/3 and dead letters" do
    test "a repeated record counts once and writes one dead letter", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      deny(ctx)

      for n <- 1..2 do
        assert [{t, {:ok, :applied}}] = round!(ctx, b)
        {:ok, before} = status(b, t)
        assert {:ok, :duplicate} = record(b, t, n)
        assert {:ok, ^before} = status(b, t)
        assert before.state == :pending
        tick(ctx, 10_000)
      end

      assert [{t, {:ok, :applied}}] = round!(ctx, b)
      assert {:ok, :duplicate} = record(b, t, 3)
      assert {:ok, %{state: :dead_lettered, dead_letter: :filed}} = status(b, t)
      assert [%{record: %{"attempts" => 3, "reason" => "retries_exhausted"}}] = dead_letters(b)
    end

    test "a failed put leaves the dead letter pending until file_dead_letters/3", %{
      ctx: ctx,
      b: b
    } do
      missing = "elz362_missing_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      {:ok, broken} =
        hooks(ctx, dead_letters: DeadLetterStore.new(repo: AppRepo, prefix: missing))

      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, :applied} = register(b, endpoint("e2"))
      assert {:ok, %{deliveries: 2}} = enqueue(b, "evt-1", %{"a" => 1})
      script(ctx, [400])
      {:ok, [t1, t2]} = claim(broken)

      for t <- [t1, t2] do
        st = send!(ctx, broken, t)
        assert {:error, :dead_letter} = record(broken, t, st.attempts)
        assert {:ok, %{state: :dead_lettered, dead_letter: :pending}} = status(b, t)
      end

      assert dead_letters(b) == []

      assert {:ok, %{filed: 0, pending: 2}} =
               WebhookOut.file_dead_letters(broken, "T1", %{limit: 10})

      # A repeated record/3 repeats the put while it is pending.
      assert {:ok, :duplicate} = record(b, t1, 1)
      assert {:ok, %{dead_letter: :filed}} = status(b, t1)

      assert {:ok, %{filed: 1, pending: 0}} = WebhookOut.file_dead_letters(b, "T1", %{limit: 10})
      assert {:ok, %{dead_letter: :filed}} = status(b, t2)
      assert {:ok, %{filed: 0, pending: 0}} = WebhookOut.file_dead_letters(b, "T1", %{limit: 10})

      assert Enum.sort(Enum.map(dead_letters(b), & &1.message_id)) ==
               Enum.sort([t1.delivery_id, t2.delivery_id])

      assert Enum.all?(dead_letters(b), &(&1.record["reason"] == "permanent"))
    end

    test "stale_try, no_result and a stored observation over a fallback", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1", %{dedup: true}))
      assert {:ok, :applied} = register(b, endpoint("e2", %{events: ["s"]}))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      script(ctx, [503])
      assert [{t1, {:ok, :applied}}] = round!(ctx, b)
      assert {:error, :stale_try} = record(b, t1, 1)
      assert {:error, :stale_try} = record(b, t1, 1, :unknown)

      tick(ctx, 1000)
      assert {:ok, [t2]} = claim(b)
      {:ok, before} = status(b, t2)
      assert {:ok, :no_result} = record(b, t2, 1)
      assert {:ok, ^before} = status(b, t2)

      script(ctx, [200])
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-2", "s", %{"a" => 2})
      assert {:ok, [s]} = claim(b)
      st = send!(ctx, b, s)
      # The stored :delivered wins over the host's :unknown.
      assert {:ok, :applied} = record(b, s, st.attempts, :unknown)
      assert {:ok, %{state: :delivered}} = status(b, s)

      assert {:error, :unknown_delivery} =
               record(b, %{delivery_id: String.duplicate("0", 64), try: 1}, 1)

      assert {:error, :invalid} = record(b, s, 0)
      assert {:error, :invalid} = record(b, s, 1, :completed)
    end

    test "an Adapter write in flight before the fallback's insert wins over it", %{
      ctx: ctx,
      b: b
    } do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      assert {:ok, [t]} = claim(b)
      test = self()

      # The Adapter's observation write, held uncommitted.
      writer =
        Task.async(fn ->
          TenantIsolation.transact(RaceRepo, %{tenant: "T1"}, fn ->
            Harness.q!(
              RaceRepo,
              ~s|INSERT INTO "#{ctx.prefix}".elzoo_webhook_observations (tenant, delivery_id, try, attempt, result, applied) VALUES ('T1', $1, 1, 1, 'delivered', false)|,
              [t.delivery_id]
            )

            send(test, :inserted)

            receive do
              :commit -> {:ok, :committed}
            end
          end)
        end)

      assert_receive :inserted
      recorder = Task.async(fn -> record(b, t, 1, :unknown) end)
      Harness.poll(fn -> Harness.waiting() > 0 end)
      send(writer.pid, :commit)
      assert {:ok, :committed} = Task.await(writer)
      assert {:ok, :applied} = Task.await(recorder)
      assert {:ok, %{state: :delivered}} = status(b, t)
      assert [[1, 1, "delivered", true]] = observations(ctx)
      assert dead_letters(b) == []
    end

    test "the expired and not-sent fallbacks", %{ctx: ctx, b: b} do
      assert {:ok, :applied} = register(b, endpoint("e1"))
      assert {:ok, :applied} = register(b, endpoint("e2", %{events: ["two"]}))
      assert {:ok, :applied} = register(b, endpoint("e3", %{events: ["three"]}))

      # Never dispatched: the host was down until the deadline.
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", %{"a" => 1})
      assert {:ok, [never]} = claim(b)
      assert {:error, :invalid} = record(b, never, 1, :expired)

      # One applied not-sent result, then the deadline.
      deny(ctx)
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-2", "two", %{"a" => 2})
      assert [{once, {:ok, :applied}}] = round!(ctx, b)

      tick(ctx, 60_000)
      assert {:ok, :applied} = record(b, never, 1, :expired)
      assert {:ok, :duplicate} = record(b, never, 1, :expired)
      assert {:ok, :applied} = record(b, once, 1, :expired)
      assert {:ok, %{state: :dead_lettered, dead_letter: :filed}} = status(b, never)
      assert {:ok, %{state: :dead_lettered, dead_letter: :filed}} = status(b, once)

      reasons = Map.new(dead_letters(b), &{&1.record["correlation_id"], &1.record})
      assert %{"reason" => "deadline_before_dispatch", "attempts" => 0} = reasons["evt-1"]
      refute Map.has_key?(reasons["evt-1"], "last_outcome")
      assert %{"reason" => "deadline_expired", "attempts" => 1} = reasons["evt-2"]
      assert reasons["evt-2"]["last_dispatch"] == "not_dispatched"

      # A not-sent result whose observation write failed (the Adapter's Repo is down).
      allow(ctx)
      {:ok, down} = hooks(ctx, repo: DownRepo)
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-3", "three", %{"a" => 3})
      assert {:ok, [three]} = claim(b)
      st = send!(ctx, b, three, down)
      assert st.attempts == 1
      assert requests(ctx) == []
      assert [] == Enum.filter(observations(ctx), fn [_, _, r, _] -> r =~ "unavailable" end)
      assert {:ok, :no_result} = record(b, three, 1)
      assert {:ok, :applied} = record(b, three, 1, :not_sent)
      due = now(ctx) + 1000
      assert {:ok, %{state: :pending, try: 1, due_at_ms: ^due}} = status(b, three)
      tick(ctx, 1000)
      assert {:ok, [%{rearm: true, try: 1} = again]} = claim(b)
      assert again.admission == three.admission
    end
  end

  # ---------------------------------------------------------------- 12

  describe "12: row security as the application role" do
    test "verify/1 passes and another tenant's rows are invisible", %{ctx: ctx, b: b} do
      assert :ok = WebhookOut.verify(b)

      assert {:ok, :applied} = register(b, "T1", endpoint("e1"))
      assert {:ok, :applied} = register(b, "T2", endpoint("e1"))
      assert {:ok, %{deliveries: 1}} = enqueue_in(b, "T1", "evt-1", "order.paid", %{"a" => 1})
      assert {:ok, %{deliveries: 1}} = enqueue_in(b, "T2", "evt-1", "order.paid", %{"a" => 2})
      # Same event and endpoint IDs: the same delivery ID in each tenant.
      assert {:ok, [t2]} = claim(b, "T2")
      tick(ctx, 5000)
      assert {:ok, [t1]} = claim(b, "T1")
      assert t1.delivery_id == t2.delivery_id
      assert t1.admission.key != t2.admission.key
      assert {:ok, []} = claim(b, "T3")
      assert {:error, :unknown_delivery} = status(b, "T3", t1)
      assert {:error, :unknown_delivery} = record_in(b, "T3", t1, 1, :unknown)

      # T1's record of its own delivery leaves T2's row unchanged.
      assert {:ok, :applied} = record_in(b, "T1", t1, 1, :unknown)
      assert {:ok, %{state: :dead_lettered}} = status(b, "T1", t1)
      assert {:ok, %{state: :pending, claimed_until_ms: lease}} = status(b, "T2", t2)
      assert lease == @t0 + 1000
      assert dead_letters(b, "T2") == []

      for {table, columns, values} <- [
            {"elzoo_webhook_endpoints",
             "tenant, endpoint_id, url, secret_ref, secret_scope, events, dedup",
             "'T2', 'x', 'u', 'r'::bytea, 's'::bytea, '{a}', false"},
            {"elzoo_webhook_events", "tenant, event_id, name, payload, payload_sha256",
             "'T2', 'x', 'n', '1', 'h'"},
            {"elzoo_webhook_deliveries",
             "tenant, delivery_id, event_id, endpoint_id, payload_sha256, state, try, due_at_ms, rearm, not_sent, attempts, dead_letter",
             "'T2', 'x', 'x', 'x', 'h', 'pending', 1, 0, false, 0, 0, 'none'"},
            {"elzoo_webhook_observations", "tenant, delivery_id, try, attempt, result, applied",
             "'T2', 'x', 1, 1, 'delivered', false"}
          ] do
        result =
          TenantIsolation.transact(AppRepo, %{tenant: "T1"}, fn ->
            Harness.q(
              AppRepo,
              ~s|INSERT INTO "#{ctx.prefix}".#{table} (#{columns}) VALUES (#{values})|
            )
          end)

        assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = result
      end
    end

    test "a caller's open transaction is :in_transaction before any query", %{ctx: ctx, b: b} do
      test = self()
      handler = "elz362-app-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:elzoo_wo_app, :query],
        fn _, _, meta, _ ->
          if self() == test, do: send(test, {:query, meta.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      t = %{delivery_id: String.duplicate("a", 64), try: 1}

      {:ok, results} =
        AppRepo.transact(fn ->
          flush()

          results = [
            register(b, endpoint("e1")),
            enqueue(b, "evt-1", %{"a" => 1}),
            claim(b),
            record(b, t, 1, :unknown),
            WebhookOut.file_dead_letters(b, "T1", %{limit: 1}),
            status(b, t)
          ]

          refute_received {:query, _}
          {:ok, results}
        end)

      assert results == List.duplicate({:error, :in_transaction}, 6)
      assert Harness.truth(ctx.prefix, "elzoo_webhook_endpoints") == []
    end

    test "a repeatable read Repo is :isolation", %{ctx: ctx} do
      {:ok, iso} = hooks(ctx, repo: IsoRepo)
      assert {:error, :isolation} = register(iso, endpoint("e1"))
      assert {:error, :isolation} = claim(iso)
      assert {:error, :isolation} = status(iso, String.duplicate("a", 64))
      assert Harness.truth(ctx.prefix, "elzoo_webhook_endpoints") == []
    end
  end

  defp flush do
    receive do
      {:query, _} -> flush()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------- 13

  describe "13: no payload or secret" do
    test "in errors, inspect of the binding or the dead letter", %{ctx: ctx, b: b} do
      assert inspect(b) == "#Elzoo.WebhookOut<redacted>"
      refute inspect(b, structs: false) =~ ctx.secret
      assert {:ok, :applied} = register(b, endpoint("e1"))
      payload = %{"card" => @payload_secret}
      assert {:ok, %{deliveries: 1}} = enqueue(b, "evt-1", payload)

      errors = [
        enqueue(b, "evt-1", %{"card" => @payload_secret <> "x"}),
        register(b, endpoint("e1", %{url: "https://#{@host}/#{@payload_secret}"})),
        register(b, endpoint("e9", %{url: "https://evil.example.com/#{@payload_secret}"})),
        enqueue(b, "evt-2", String.duplicate(@payload_secret, 5000))
      ]

      assert errors == [
               {:error, :conflict},
               {:error, :conflict},
               {:error, {:egress, :not_allowed}},
               {:error, :invalid}
             ]

      script(ctx, [400])
      assert [{t, {:ok, :applied}}] = round!(ctx, b)
      [{_, _, pid}] = :ets.lookup(ctx.owners, t.admission.key)
      [entry] = dead_letters(b)

      for text <- [inspect(entry), inspect(Intent.status(pid)), inspect(t), inspect(status(b, t))] do
        refute text =~ @payload_secret
        refute text =~ ctx.secret
      end
    end
  end
end
