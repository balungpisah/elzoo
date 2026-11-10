# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/http_job_test_helper.exs", __DIR__)

defmodule Elzoo.HttpJobTest do
  use ExUnit.Case, async: false
  alias Elzoo.HttpJob, as: H
  alias Elzoo.HttpJob.{TestRepo, TestMigration, TestBinding, Fixture, Wire, Policy}
  alias Elzoo.EffectIntent, as: I
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Postgres

  setup_all do
    {:ok, repo} =
      TestRepo.start_link(
        url: System.fetch_env!("ELZOO_TEST_DATABASE_URL"),
        pool_size: 15,
        log: false
      )

    Process.unlink(repo)
    on_exit(fn -> Supervisor.stop(repo) end)
    :ok
  end

  setup do
    prefix = "httpjob_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    TestRepo.query!("CREATE SCHEMA #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)
    f = Fixture.start()
    Process.unlink(f.state)
    Process.unlink(f.tasks)
    Process.unlink(f.server)

    on_exit(fn ->
      Fixture.stop(f)
      TestRepo.query!("DROP SCHEMA #{prefix} CASCADE", [], log: false)
      :persistent_term.erase(TestBinding)
    end)

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: H.Adapter,
        id: "publication-v1",
        provider_account: f.origin,
        operation: "publication",
        clock: "unix-ms",
        failures: H.Binding.failures(),
        no_send_attestations: [:preflight_unavailable, :request_rejected],
        recovery_grace_ms: 4000,
        replay: :none
      )

    :persistent_term.put(TestBinding, descriptor)
    transport = start_supervised!({Task.Supervisor, max_children: 1}, id: :transport)
    callers = start_supervised!({Task.Supervisor, max_children: 2}, id: :callers)
    sends = start_supervised!({Task.Supervisor, max_children: 1}, id: :sends)
    holder = start_supervised!({Agent, fn -> nil end}, id: :holder)
    clock = start_supervised!({Agent, fn -> 100 end}, id: :clock)
    auth = start_supervised!({Agent, fn -> :fresh end}, id: :auth)
    parent = self()

    opts = [
      binding: TestBinding,
      origin: f.origin,
      tenant: "test-tenant",
      queue: "http_job",
      transport_supervisor: transport,
      caller_supervisor: callers,
      credentials: fn -> {:ok, "fixture-secret"} end,
      authenticate: &Fixture.authenticate/2,
      resolve_intent: fn _ -> {:ok, Agent.get(holder, & &1)} end,
      observer: fn e -> send(parent, {:event, e}) end,
      total_ms: 250,
      connect_ms: 100,
      receive_ms: 100,
      poll_seconds: 2,
      call_ms: 1000
    ]

    {:ok, cfg} = H.configure(opts)
    body = Jason.encode!(%{"version" => 1, "kind" => "publication", "text" => "secret payload"})

    declaration = %{
      "capability_id" => "integration/http",
      "operation" => "publication",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "message",
        "idempotency_key" => "stable-reference",
        "deadline_unix_ms" => 1000,
        "schema_id" => "elzoo/publication",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "caller", "port_id" => "out"},
        "payload" => body
      }
    }

    {:ok, admission} = H.admission(cfg, declaration)
    store = Postgres.store(TestRepo, prefix: prefix, fold: I.fold(TestBinding), limits: I.limits())

    host = %{
      store:
        Postgres.store(TestRepo, prefix: prefix, fold: StoreHost.fold(), limits: StoreHost.limits()),
      authorize: fn _, g ->
        if Agent.get(auth, & &1) == :fresh, do: :fresh, else: {:recovered, g}
      end
    }

    owner_opts = [
      binding: TestBinding,
      identity: admission.identity,
      arguments: admission.arguments,
      deadline: admission.deadline,
      clock: fn -> Agent.get(clock, & &1) end,
      store: store,
      host: {StoreHost, host},
      task_supervisor: sends,
      adapter_context: cfg
    ]

    %{
      cfg: cfg,
      opts: opts,
      owner_opts: owner_opts,
      holder: holder,
      clock: clock,
      auth: auth,
      f: f,
      prefix: prefix,
      declaration: declaration,
      admission: admission,
      body: body,
      transport: transport,
      callers: callers,
      store: store
    }
  end

  defp owner(c, opts \\ nil) do
    p = start_supervised!({I, opts || c.owner_opts}, id: make_ref())
    Agent.update(c.holder, fn _ -> p end)
    p
  end

  defp job(c),
    do: %Oban.Job{
      args: %{"v" => 1, "queue" => c.cfg.queue, "job_key" => c.admission.key},
      attempt: 1
    }

  defp tick(c), do: H.perform(c.cfg, job(c))
  # Wall-clock bounded wait (ELZ-074): polls every 10 ms until the condition
  # holds or the monotonic deadline passes; the final poll is asserted and the
  # elapsed time is reported. A slow but progressing runner passes; a stalled
  # one still fails. The deadline stays below ExUnit's 120 s per-test timeout
  # (test/test_helper.exs) so the final assertion is reached.
  @wait_ms 60_000
  defp wait(fun, timeout_ms \\ @wait_ms) do
    started = System.monotonic_time(:millisecond)
    wait_until(fun, started, started + timeout_ms)
  end

  defp wait_until(fun, started, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        elapsed = System.monotonic_time(:millisecond) - started
        assert fun.(), "Expected truthy, got false after #{elapsed} ms (wall clock)"

      true ->
        Process.sleep(10)
        wait_until(fun, started, deadline)
    end
  end

  defp oban(c, extra \\ []) do
    start_supervised!(
      {Oban,
       Keyword.merge(
         [
           name: H.TestOban,
           repo: TestRepo,
           prefix: c.prefix,
           queues: [http_job: 2],
           stager: [interval: 50],
           notifier: Oban.Notifiers.PG,
           log: false
         ],
         extra
       )}
    )

    Elzoo.Jobs.register(c.cfg.queue, H.runner(c.cfg))
    on_exit(fn -> Elzoo.Jobs.unregister(c.cfg.queue) end)
    H.TestOban
  end

  # ELZ-092 (#170): a gate for the rescued wakes' `resolve_intent`. While the gate is
  # closed, a wake registers, reports `{:resolve, pid}` and waits; `open` releases every
  # registered wake with `reply` and returns their pids. A wake that arrives after `open`
  # (an Oban retry after a wake failed closed) resolves the owner at once, so no wake can
  # wait forever. The Agent serializes registration and opening, so no wake is lost.
  defp rescue_gate(p) do
    gate = start_supervised!({Agent, fn -> {:closed, []} end}, id: :rescue_gate)
    parent = self()

    resolve = fn _ ->
      wake = self()

      case Agent.get_and_update(gate, fn
             {:closed, waiting} -> {:wait, {:closed, [wake | waiting]}}
             {:open, _} = open -> {:open, open}
           end) do
        :open ->
          {:ok, p}

        :wait ->
          send(parent, {:resolve, self()})

          receive do
            {:release, reply} -> reply
          end
      end
    end

    open = fn reply ->
      waiting = Agent.get_and_update(gate, fn {_, waiting} -> {waiting, {:open, []}} end)
      Enum.each(waiting, &send(&1, {:release, reply}))
      waiting
    end

    {resolve, open}
  end

  test "admission consumes thin declaration, exact bytes and explicit identity/deadline", c do
    assert c.admission.identity == [
             "test-tenant",
             c.f.origin,
             "publication-v1",
             "publication",
             "stable-reference"
           ]

    assert c.admission.arguments == c.body and c.admission.deadline == 1000

    assert {:error, :admission} =
             H.admission(
               c.cfg,
               put_in(c.declaration, ["command", "deadline_unix_ms"], 9_223_372_036_854_775_807)
             )

    for path_value <- [
          {["classification"], "trusted"},
          {["operation"], "refund"},
          {["capability_id"], "other"},
          {["command", "kind"], "event"},
          {["command", "payload"], %{}},
          {["command", "schema_version"], 2}
        ] do
      {path, value} = path_value
      assert {:error, :admission} = H.admission(c.cfg, put_in(c.declaration, path, value))
    end

    assert {:error, :admission} =
             H.admission(
               c.cfg,
               update_in(c.declaration, ["command"], &Map.delete(&1, "idempotency_key"))
             )

    assert {:error, :admission} =
             H.admission(
               c.cfg,
               put_in(
                 c.declaration,
                 ["command", "payload"],
                 ~s({"version":1,"kind":"publication","text":"a","text":"b"})
               )
             )
  end

  test "real HTTP plus SQL owner confirms; duplicate wakes and result do not send again", c do
    p = owner(c)
    assert {:snooze, 2} = tick(c)
    wait(fn -> I.status(p).phase == {:Confirmed, 1} end)
    assert :ok = tick(c)
    assert :ok = tick(c)
    assert [{"PUT", path, body}] = Fixture.calls(c.f)
    assert path == "/publications/" <> c.admission.key and body == c.body
    completion = Fixture.completion(c.admission.key, c.body, 1)
    assert {:ok, :retained} = I.observe(p, completion)
    assert {:Confirmed, 1} = I.status(p).phase
    assert_receive {:event, %{event: :http_job, outcome: :waiting, elapsed_ms: _} = event}
    assert Map.keys(event) |> Enum.sort() == [:elapsed_ms, :event, :outcome]
    refute inspect(event) =~ "secret"
  end

  test "forged key digest and MAC are retained refusals, never Confirmed", c do
    for {mode, n} <- Enum.with_index([:badkey, :baddigest, :badmac], 1) do
      Fixture.mode(c.f, mode)

      opts =
        Keyword.put(c.owner_opts, :identity, List.replace_at(c.admission.identity, 4, "forged#{n}"))

      p = owner(c, opts)
      assert {:ok, :dispatched} = I.advance(p, :dispatch)
      wait(fn -> I.status(p).revision >= 3 end)
      assert {:Dispatched, _, 1} = I.status(p).phase
      assert I.status(p).evidence >= 1
      assert {:error, :not_rearmable} = I.advance(p, :rearm)
    end
  end

  test "explicit preflight no-send rearms but a changed context origin is permanently refused", c do
    mode = start_supervised!({Agent, fn -> true end}, id: :preflight)

    cfg = %{
      c.cfg
      | credentials: fn ->
          if Agent.get_and_update(mode, &{&1, false}),
            do: {:error, :preflight_unavailable},
            else: {:ok, "token"}
        end
    }

    c = %{c | cfg: cfg, owner_opts: Keyword.put(c.owner_opts, :adapter_context, cfg)}
    p = owner(c)
    assert {:snooze, 2} = tick(c)
    wait(fn -> I.status(p).phase == {:Definite, :AdapterNoSend, 1} end)
    assert Fixture.calls(c.f) == []
    assert {:snooze, 1} = tick(c)
    assert {:snooze, 2} = tick(c)
    wait(fn -> I.status(p).phase == {:Confirmed, 2} end)
    assert length(Fixture.calls(c.f)) == 1
    bad = %{cfg | origin: "http://127.0.0.1:1"}

    opts =
      c.owner_opts
      |> Keyword.put(:identity, List.replace_at(c.admission.identity, 4, "wrong-origin"))
      |> Keyword.put(:adapter_context, bad)

    q = owner(c, opts)
    assert {:ok, :dispatched} = I.advance(q, :dispatch)
    wait(fn -> I.status(q).flags.disarmed end)
    assert {:Definite, :AdapterNoSend, 1} = I.status(q).phase
    assert length(Fixture.calls(c.f)) == 1
  end

  test "quarantined Dispatched after old contradictory completion cancels without polling", c do
    mode = start_supervised!({Agent, fn -> true end}, id: :preflight)

    cfg = %{
      c.cfg
      | credentials: fn ->
          if Agent.get_and_update(mode, &{&1, false}),
            do: {:error, :preflight_unavailable},
            else: {:ok, "token"}
        end
    }

    c = %{c | cfg: cfg, owner_opts: Keyword.put(c.owner_opts, :adapter_context, cfg)}
    Fixture.mode(c.f, :drop)
    p = owner(c)
    assert {:snooze, 2} = tick(c)
    wait(fn -> I.status(p).phase == {:Definite, :AdapterNoSend, 1} end)
    assert {:snooze, 1} = tick(c)
    assert {:snooze, 2} = tick(c)
    wait(fn -> I.status(p).revision >= 6 end)
    assert {:ok, :retained} = I.observe(p, Fixture.completion(c.admission.key, c.body, 1))
    assert I.status(p).flags.quarantined
    Agent.update(c.clock, fn _ -> 5000 end)
    before = Fixture.calls(c.f)
    assert {:cancel, :operator_required} = tick(c)
    Process.sleep(50)
    assert Fixture.calls(c.f) == before
    assert {:Dispatched, _, 2} = I.status(p).phase
  end

  test "HTTP failures malformed responses and timeout remain dispatched; 404 poll cannot rearm",
       c do
    for {mode, n} <-
          Enum.with_index(
            [
              :http404,
              :http503,
              :redirect,
              :duplicate,
              :invalid,
              :encoded,
              :oversize,
              :pending,
              :drop,
              :drip
            ],
            1
          ) do
      Fixture.mode(c.f, mode)

      p =
        owner(
          c,
          Keyword.put(
            c.owner_opts,
            :identity,
            List.replace_at(c.admission.identity, 4, "failure#{n}")
          )
        )

      assert {:ok, :dispatched} = I.advance(p, :dispatch)
      wait(fn -> I.status(p).revision >= 3 end)
      assert {:Dispatched, _, 1} = I.status(p).phase
      assert {:error, :not_rearmable} = I.advance(p, :rearm)

      if mode == :http404 do
        assert {:ok, :polling} = I.advance(p, :poll)
        wait(fn -> I.status(p).revision >= 4 end)
        assert {:Dispatched, _, 1} = I.status(p).phase
      end

      GenServer.stop(p)
    end
  end

  test "configuration freezes every poll delay, finite grace and excludes replay", c do
    assert {:error, :configuration} = H.configure(Keyword.put(c.opts, :poll_seconds, 1))
    assert {:error, :configuration} = H.configure(Keyword.put(c.opts, :origin, "http://other"))
    b = TestBinding.__effect_intent_binding__()

    replay = %{
      window_ms: 1000,
      max_flight_ms: 100,
      clock_allowance_ms: 0,
      semantics: :same_key_same_arguments
    }

    altered = Elzoo.EffectIntent.Binding.compile!(Map.put(Map.delete(b, :digest), :replay, replay))
    :persistent_term.put(TestBinding, altered)
    assert {:error, :configuration} = H.configure(c.opts)
    :persistent_term.put(TestBinding, b)
    assert {:error, :configuration} = H.configure(Keyword.put(c.opts, :total_ms, "bad"))
  end

  test "request and receipt byte schemas refuse duplicates types controls and resource excess", c do
    assert :ok = Wire.publication(c.body)

    for b <- [
          "{}",
          "[]",
          <<255>>,
          String.duplicate("x", 16385),
          ~s({"version":1.0,"kind":"publication","text":"a"}),
          ~s({"version":1,"kind":"publication","text":"a","text":"b"})
        ],
        do: assert(Wire.publication(b) == {:error, :schema})

    v = Fixture.completion(c.admission.key, c.body, 1)["value"]
    assert {:ok, n} = Wire.normalize(Map.put(v, "secret", "secret"))
    assert n["trust"] == "untrusted" and not Map.has_key?(n, "secret")
    assert Wire.normalize(n) == {:ok, n}

    for bad <- [1, "true", nil],
        do: assert(Wire.normalize(Map.put(v, "ack", bad)) == {:error, :schema})

    assert {:error, :schema} = Wire.normalize(Map.put(v, "kind", "x" <> <<0>>))
    unknown = "novel_http_kind_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:ok, n} =
             Wire.receipt(Jason.encode!(Map.merge(v, %{unknown => "ignored", "kind" => unknown})))

    assert n["kind"] == unknown
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    deep = Enum.reduce(1..9, true, fn _, x -> [x] end)
    assert {:error, :schema} = Wire.json(Jason.encode!(%{"x" => deep}))
    assert {:error, :schema} = Wire.json(Jason.encode!(%{"x" => Enum.to_list(1..130)}))
  end

  test "bounded stalled dispatch followed by retry cannot make a second send", c do
    p = owner(c)
    :sys.suspend(p)
    assert {:error, :call_timeout} = H.Call.run(c.callers, 25, fn -> I.advance(p, :dispatch) end)
    :sys.resume(p)
    wait(fn -> match?({:Confirmed, 1}, I.status(p).phase) end)
    assert :ok = tick(c)
    assert length(Fixture.calls(c.f)) == 1
  end

  test "runner errors, expiry and max/disarm decisions are bounded and total", c do
    p = owner(c)
    Agent.update(c.clock, fn _ -> 1000 end)
    assert {:cancel, :not_dispatchable} = tick(c)
    assert Fixture.calls(c.f) == []
    assert H.perform(c.cfg, %Oban.Job{args: %{}}) == {:cancel, :invalid_job}

    assert H.perform(%{c.cfg | resolve_intent: fn _ -> exit(:failure) end}, job(c)) ==
             {:error, :owner_unavailable}

    assert H.perform(%{c.cfg | resolve_intent: fn _ -> {:ok, self()} end, call_ms: 10}, job(c)) ==
             {:error, :owner_unavailable}

    s = I.status(p)
    assert Policy.action(%{s | attempts: 3, phase: {:Intended, :Fresh, 3}}, 3) == :JobExhausted

    assert Policy.action(
             %{s | flags: %{s.flags | quarantined: true}, phase: {:Dispatched, :Fresh, 0}},
             3
           ) == :JobOperator

    assert Policy.action(
             %{s | phase: {:Definite, :AdapterNoSend, 0}, flags: %{s.flags | disarmed: true}},
             3
           ) == :JobOperator

    assert Policy.action(%{s | phase: {:Stranded, 0}}, 3) == :JobOperator
    assert Policy.action(%{s | phase: :unexpected}, 3) == :JobUnavailable
  end

  test "real Oban job completion and cancellation are job control, not provider rollback", c do
    p = owner(c)
    name = oban(c)

    assert {:ok, id} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(c.cfg.queue, c.admission.key, 3))

    wait(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "completed"}} end)
    assert {:Confirmed, 1} = I.status(p).phase

    assert {:ok, %{cancelled_jobs: 0, external_outcome: :unknown}} =
             H.cancel(c.cfg, name, String.duplicate("0", 64))

    assert Enum.count(Fixture.calls(c.f), &match?({"PUT", _, _}, &1)) == 1
  end

  test "read-only restart exhausts job; same unique ID resumes only after host grant", c do
    Fixture.mode(c.f, :http404)
    p = owner(c)
    assert {:snooze, 2} = tick(c)
    wait(fn -> I.status(p).revision >= 3 end)
    GenServer.stop(p)
    r = owner(c)
    refute I.status(r).active
    name = oban(c)

    assert {:ok, id} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(c.cfg.queue, c.admission.key, 1))

    wait(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "discarded"}} end)
    GenServer.stop(r)
    Agent.update(c.auth, fn _ -> :recover end)
    active = owner(c)
    Fixture.mode(c.f, :success)

    assert {:ok, ^id} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(c.cfg.queue, c.admission.key, 1))

    assert :ok = Oban.retry_job(name, id)
    wait(fn -> I.status(active).phase == {:Confirmed, 1} end)
    assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1
  end

  test "observer throw/hang and caller pool saturation cannot repeat an effect", c do
    p = owner(c)
    cfg = %{c.cfg | observer: fn _ -> throw(:observer) end}
    assert {:snooze, 2} = H.perform(cfg, job(c))
    wait(fn -> I.status(p).phase == {:Confirmed, 1} end)

    assert :ok =
             H.perform(
               %{cfg | observer: fn _ -> Process.sleep(:infinity) end, observer_ms: 10},
               job(c)
             )

    for _ <- 1..2, do: Task.Supervisor.start_child(c.callers, fn -> Process.sleep(:infinity) end)
    assert {:error, :owner_unavailable} = tick(c)
    assert length(Fixture.calls(c.f)) == 1
  end

  test "cancellation after HTTP receipt preserves unknown intent until host expiry", c do
    Fixture.mode(c.f, :hold)
    p = owner(c)
    name = oban(c)

    assert {:ok, _} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(c.cfg.queue, c.admission.key, 3))

    wait(fn -> length(Fixture.calls(c.f)) == 1 end)

    assert {:ok, %{cancelled_jobs: count, external_outcome: :unknown}} =
             H.cancel(c.cfg, name, c.admission.key)

    assert count == 1
    wait(fn -> I.status(p).revision >= 3 end)
    assert {:Dispatched, _, 1} = I.status(p).phase
    assert {:error, :not_rearmable} = I.advance(p, :rearm)
    Agent.update(c.clock, fn _ -> 5000 end)
    assert {:ok, _} = I.advance(p, :expire)
    assert {:Stranded, 1} = I.status(p).phase
    assert length(Fixture.calls(c.f)) == 1
  end

  test "live Oban rescue and concurrent wakeups still reserve one physical send", c do
    p = owner(c)
    {resolve, open} = rescue_gate(p)
    cfg = %{c.cfg | call_ms: 3000, resolve_intent: resolve}
    c = %{c | cfg: cfg}
    name = oban(c)

    assert {:ok, _id} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(cfg.queue, c.admission.key, 3))

    assert_receive {:resolve, first}, 2000
    assert {:ok, [_]} = Oban.Engine.rescue_jobs(Oban.config(name), Oban.Job, rescue_after: 0)
    assert_receive {:resolve, second}, 2000
    # Both wakes are released together; a later Oban retry passes the open gate.
    released = open.({:ok, p})
    assert first in released and second in released
    wait(fn -> I.status(p).phase == {:Confirmed, 1} end)
    assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1
  end

  # ELZ-092 (#170) regression: the state behind the intermittent stall of the test above.
  # There, both rescued wakes could fail closed (a transient caller-pool rejection) and
  # the old stub then blocked Oban's retry until `call_ms`, so the job was discarded with
  # the owner still Intended. Here both scripted wakes fail closed deterministically: the
  # gate releases them with a reply that is not an owner, so `tick` stops before any owner
  # command. Oban's retry must then make the one send.
  test "rescued wakes that both fail closed leave the one send to Oban's retry", c do
    p = owner(c)
    {resolve, open} = rescue_gate(p)
    parent = self()
    id = "elz-092-#{System.unique_integer([:positive])}"
    key = c.admission.key

    # Runs in the execution process when a wake ends, before Oban acknowledges it, so the
    # retry (scheduled only by that acknowledgement) cannot have started for attempt 2.
    :ok =
      :telemetry.attach(
        id,
        [:elzoo, :job, :stop],
        fn _, _, meta, _ ->
          if meta[:request_ref] == key do
            calls = Enum.map(Fixture.calls(c.f), &elem(&1, 0))
            send(parent, {:wake_end, meta.attempt, meta.outcome, I.status(p), calls})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    cfg = %{c.cfg | call_ms: 3000, resolve_intent: resolve}
    c = %{c | cfg: cfg}
    name = oban(c)

    assert {:ok, job_id} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(cfg.queue, c.admission.key, 3))

    assert_receive {:resolve, first}, 2000
    assert {:ok, [_]} = Oban.Engine.rescue_jobs(Oban.config(name), Oban.Job, rescue_after: 0)
    assert_receive {:resolve, second}, 2000
    released = open.(:unavailable)
    assert first in released and second in released
    assert_receive {:wake_end, 1, :error, _, _}, 5000
    assert_receive {:wake_end, 2, :error, status, []}, 5000
    assert {status.phase, status.revision, status.attempts} == {{:Intended, :Fresh, 0}, 1, 0}
    wait(fn -> I.status(p).phase == {:Confirmed, 1} end)
    wait(fn -> Elzoo.Jobs.state_by_id(name, job_id) == {:ok, {job_id, "completed"}} end)
    assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1

    errors =
      TestRepo.query!("SELECT errors FROM #{c.prefix}.oban_jobs WHERE id = $1", [job_id],
        log: false
      ).rows

    assert [[errors]] = errors

    assert Enum.any?(
             errors,
             &(&1["attempt"] == 2 and &1["error"] =~ "{:error, :owner_unavailable}")
           )
  end

  test "Lifeline recovers orphan executing row which retry_job alone ignores", c do
    p = owner(c)

    name =
      oban(c,
        queues: false,
        peer: {Oban.Peers.Isolated, [leader?: true]},
        lifeline: [interval: 50, rescue_after: 100]
      )

    assert {:ok, id} =
             Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(c.cfg.queue, c.admission.key, 3))

    TestRepo.query!(
      "UPDATE #{c.prefix}.oban_jobs SET state='executing',attempt=1,attempted_at=timezone('UTC',now())-interval '1 minute' WHERE id=$1",
      [id],
      log: false
    )

    assert :ok = Oban.retry_job(name, id)
    # retry_job cannot recover an executing row. Lifeline must do that job.
    wait(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "available"}} end)
    assert :ok = Oban.start_queue(name, queue: :http_job, limit: 1)
    wait(fn -> I.status(p).phase == {:Confirmed, 1} end)
    assert length(Fixture.calls(c.f)) == 1
  end

  defp mutation(relative, before_text, after_text, fun) do
    path = Path.expand("../../lib/" <> relative, __DIR__)
    source = File.read!(path)
    assert String.contains?(source, before_text)
    old = Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_string(String.replace(source, before_text, after_text), path)
      fun.()
    after
      Code.compile_string(source, path)
      Code.compiler_options(old)
    end
  end

  test "real normalizer source mutants violate the retained fields trust ack and atom properties",
       c do
    v =
      Fixture.completion(c.admission.key, c.body, 1)["value"]
      |> Map.merge(%{"secret" => "secret", "trust" => "trusted"})

    mutation(
      "elzoo/http_job/wire.ex",
      ~s("trust" => "untrusted"),
      ~s("trust" => "untrusted", "secret" => map["secret"]),
      fn ->
        {:ok, n} = Wire.normalize(v)
        assert Map.has_key?(n, "secret")
      end
    )

    mutation(
      "elzoo/http_job/wire.ex",
      ~s("trust" => "untrusted"),
      ~s("trust" => map["trust"]),
      fn ->
        {:ok, n} = Wire.normalize(v)
        refute n["trust"] == "untrusted"
      end
    )

    mutation(
      "elzoo/http_job/wire.ex",
      ~s|ack when is_boolean(ack) <- map["ack"]|,
      ~s/ack <- (map["ack"] || true)/,
      fn ->
        assert {:ok, _} = Wire.normalize(Map.delete(v, "ack"))
      end
    )

    mutation(
      "elzoo/http_job/wire.ex",
      "def normalize(map) when is_map(map) do",
      "def normalize(map) when is_map(map) do\nEnum.each(Map.keys(map), &String.to_atom/1)",
      fn ->
        novel = "elz011_mutation_#{System.unique_integer([:positive])}"
        assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
        {:ok, _} = Wire.normalize(Map.put(v, novel, "x"))
        assert is_atom(String.to_existing_atom(novel))
      end
    )

    assert {:ok, n} = Wire.normalize(v)
    refute Map.has_key?(n, "secret")
    assert n["trust"] == "untrusted"
  end

  test "real retry and redirect source mutants cause extra wire requests", c do
    for {mode, before_text, after_text} <- [
          {:http503, "retry: false", "retry: :transient, max_retries: 1, retry_delay: 0"},
          {:redirect, "redirect: false", "redirect: true"}
        ] do
      Fixture.mode(c.f, mode)
      count = length(Fixture.calls(c.f))

      opts =
        Keyword.put(
          c.owner_opts,
          :identity,
          List.replace_at(c.admission.identity, 4, Atom.to_string(mode))
        )

      p = owner(c, opts)

      mutation("elzoo/http_job/adapter.ex", before_text, after_text, fn ->
        assert {:ok, :dispatched} = I.advance(p, :dispatch)
        wait(fn -> I.status(p).revision >= 3 end)
        assert length(Fixture.calls(c.f)) >= count + 2
      end)

      GenServer.stop(p)
    end
  end

  test "changed request identity and bypassing the durable owner are detected on wire", c do
    p = owner(c)

    mutation(
      "elzoo/http_job/adapter.ex",
      ~s("/publications/" <> req.key),
      ~s|"/publications/" <> String.duplicate("0",64)|,
      fn ->
        assert {:snooze, 2} = tick(c)
        wait(fn -> I.status(p).revision >= 3 end)
        assert [{"PUT", path, _}] = Fixture.calls(c.f)
        refute path == "/publications/" <> c.admission.key
        assert {:Dispatched, _, 1} = I.status(p).phase
      end
    )

    bypass =
      "defp tick(c, key) do\nReq.put!(c.origin <> \"/publications/\" <> key, body: " <>
        inspect(c.body) <> ", retry: false, redirect: false)"

    count = length(Fixture.calls(c.f))

    mutation("elzoo/http_job.ex", "defp tick(c, key) do", bypass, fn ->
      tick(c)
      wait(fn -> length(Fixture.calls(c.f)) > count end)
      assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 2
    end)
  end

  test "actual Adapter total timer bounds slow drip and its source mutation violates that bound",
       c do
    Fixture.mode(c.f, :drip)

    request = %{
      key: c.admission.key,
      attempt: 1,
      attempt_id: c.admission.key <> "/attempt/1",
      arguments: c.body,
      arguments_digest: :crypto.hash(:sha256, c.body),
      schema: H.Adapter.schema(),
      binding: TestBinding.__effect_intent_binding__().digest,
      context: c.cfg
    }

    start = System.monotonic_time(:millisecond)
    assert {:error, :transport_timeout, :unknown} = H.Adapter.send_effect(request)
    assert System.monotonic_time(:millisecond) - start < 1000

    mutation(
      "elzoo/http_job/call.ex",
      "Task.yield(task, timeout)",
      "Task.yield(task, max(timeout, 5000))",
      fn ->
        start = System.monotonic_time(:millisecond)
        H.Adapter.send_effect(request)
        assert System.monotonic_time(:millisecond) - start >= 1000
      end
    )
  end

  test "a timed-out credential preparation is unknown with no wire entry or no-send ground", c do
    cfg = %{c.cfg | credentials: fn -> Process.sleep(:infinity) end}
    p = owner(c, Keyword.put(c.owner_opts, :adapter_context, cfg))
    assert {:ok, :dispatched} = I.advance(p, :dispatch)
    wait(fn -> I.status(p).revision >= 3 end)
    assert {:Dispatched, _, 1} = I.status(p).phase
    assert {:error, :not_rearmable} = I.advance(p, :rearm)
    assert Fixture.calls(c.f) == []

    assert {:error, :schema} =
             Wire.normalize(%{
               "version" => 1,
               "key" => c.admission.key,
               "digest" => String.duplicate("a", 64),
               "ack" => true,
               "kind" => <<0xC2, 0x85>>
             })
  end

  test "Cure policy type/source audit is clean", _ do
    roots = Mix.Project.config()[:cure_paths] |> Enum.map(&Path.expand/1)
    source = File.read!(Path.expand("../../cure/elzoo/http_job.cure", __DIR__))
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    a = Cure.Audit.Ledger.audit_env(env)

    assert a.axioms == [] and a.holes == [] and a.unresolved == [] and a.unaudited == [] and
             a.not_proven_total == [] and a.absurd == 0
  end

  defp adapter_request(c, cfg) do
    %{
      key: c.admission.key,
      attempt: 1,
      attempt_id: c.admission.key <> "/attempt/1",
      arguments: c.body,
      arguments_digest: :crypto.hash(:sha256, c.body),
      schema: H.Adapter.schema(),
      binding: TestBinding.__effect_intent_binding__().digest,
      context: cfg
    }
  end

  test "stream size guard closes a large response early and its removal violates the bound", c do
    total = 16 * 1024 * 1024
    # Isolate the size oracle from transport clocks, including on slow CI hosts.
    # This direct Adapter fixture injects an untimed clock; public configuration
    # still rejects it, and the separate total-time/slow-drip tests remain timed.
    clocks = [total_ms: :infinity, receive_ms: :infinity, connect_ms: :infinity]
    assert {:error, :configuration} = H.configure(Keyword.merge(c.opts, clocks))
    cfg = struct(c.cfg, clocks)
    request = adapter_request(c, cfg)

    run = fn ->
      ref = make_ref()
      Fixture.mode(c.f, {:stream, total, self(), ref})
      assert {:error, :receipt_invalid, :schema} = H.Adapter.send_effect(request)
      assert_receive {:stream_finished, ^ref, bytes}, 5000
      bytes
    end

    within_bound = fn bytes -> assert bytes < div(total, 2) end
    within_bound.(run.())

    mutation("elzoo/http_job/adapter.ex", "<= Wire.limit(),", "<= 1_000_000_000,", fn ->
      bytes = run.()
      assert bytes == total
      assert_raise ExUnit.AssertionError, fn -> within_bound.(bytes) end
    end)

    within_bound.(run.())
  end

  # Gate only the runner's already-read snapshot, never the owner or its state.
  # The real owner/Store still serialize both competing commands.
  defp with_snapshot_gate(fun, replacement \\ nil) do
    parent = self()
    key = {__MODULE__, :snapshot_gate}

    :persistent_term.put(key, fn phase ->
      send(parent, {:snapshot, self(), phase})

      receive do
        :release -> :ok
      after
        5000 -> raise "snapshot gate timed out"
      end
    end)

    path = Path.expand("../../lib/elzoo/http_job.ex", __DIR__)
    source = File.read!(path)
    point = "act(c, pid, Policy.action(current, c.maximum))"
    assert String.contains?(source, point)

    gated =
      String.replace(
        source,
        point,
        ":persistent_term.get({Elzoo.HttpJobTest, :snapshot_gate}).(current.phase)\n      " <> point
      )

    gated =
      case replacement do
        nil ->
          gated

        {before_text, after_text} ->
          assert String.contains?(gated, before_text)
          String.replace(gated, before_text, after_text)
      end

    old = Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_string(gated, path)
      fun.()
    after
      Code.compile_string(source, path)
      Code.compiler_options(old)
      :persistent_term.erase(key)
    end
  end

  defp refused_race(c, phase, replacement \\ nil) do
    identity =
      List.replace_at(c.admission.identity, 4, "race-#{System.unique_integer([:positive])}")

    admission = %{c.admission | identity: identity, key: I.Model.key(identity)}

    cfg =
      if phase == :rearm,
        do: %{c.cfg | credentials: fn -> {:error, :preflight_unavailable} end},
        else: c.cfg

    opts = c.owner_opts |> Keyword.put(:identity, identity) |> Keyword.put(:adapter_context, cfg)
    p = owner(c, opts)
    c = %{c | admission: admission, cfg: cfg}
    Fixture.mode(c.f, :hold)

    if phase == :rearm do
      assert {:ok, :dispatched} = I.advance(p, :dispatch)
      wait(fn -> match?({:Definite, :AdapterNoSend, 1}, I.status(p).phase) end)
    end

    try do
      with_snapshot_gate(
        fn ->
          first = Task.async(fn -> tick(c) end)
          assert_receive {:snapshot, first_pid, old_phase}, 2000
          second = Task.async(fn -> tick(c) end)
          assert_receive {:snapshot, second_pid, ^old_phase}, 2000
          send(first_pid, :release)
          assert {:snooze, _} = Task.await(first)
          expected = if phase == :rearm, do: :Intended, else: :Dispatched
          assert elem(I.status(p).phase, 0) == expected
          send(second_pid, :release)
          Task.await(second)
        end,
        replacement
      )
    after
      GenServer.stop(p)
    end
  end

  test "stale dispatch and rearm refusals reread once without cancelling another execution", c do
    assert {:snooze, 2} = refused_race(c, :dispatch)
    assert {:snooze, 2} = refused_race(c, :rearm)

    for {before_text, after_text, phase, reason} <- [
          {"confirm_refusal(c, pid, :JobDispatch, :not_dispatchable)",
           "{:cancel, :not_dispatchable}", :dispatch, :not_dispatchable},
          {"confirm_refusal(c, pid, :JobRearm, :exhausted)", "{:cancel, :exhausted}", :rearm,
           :exhausted}
        ] do
      result = refused_race(c, phase, {before_text, after_text})
      assert {:cancel, ^reason} = result
      assert_raise ExUnit.AssertionError, fn -> assert {:snooze, 2} = result end
    end
  end

  test "live rescued Oban job retains wakeups after stale dispatch and then confirms", c do
    Fixture.mode(c.f, :hold)
    p = owner(c)

    with_snapshot_gate(fn ->
      name = oban(c)

      assert {:ok, id} =
               Elzoo.Jobs.enqueue(name, Elzoo.Jobs.changeset(c.cfg.queue, c.admission.key, 3))

      assert_receive {:snapshot, first, {:Intended, :Fresh, 0}}, 3000
      assert {:ok, [_]} = Oban.Engine.rescue_jobs(Oban.config(name), Oban.Job, rescue_after: 0)
      assert_receive {:snapshot, second, {:Intended, :Fresh, 0}}, 3000
      send(first, :release)
      wait(fn -> match?({:Dispatched, _, 1}, I.status(p).phase) end)
      send(second, :release)
      assert_receive {:event, %{outcome: :waiting}}, 2000
      assert_receive {:event, %{outcome: :waiting}}, 2000
      wait(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "scheduled"}} end)
      # Dispatch acknowledges task scheduling; the loopback request arrives later.
      wait(fn -> Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) >= 1 end)
      assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1
      Fixture.mode(c.f, :success)
      # Subsequent snapshots are real poll and completion wakes.
      assert_receive {:snapshot, poller, {:Dispatched, _, 1}}, 5000
      send(poller, :release)
      wait(fn -> I.status(p).phase == {:Confirmed, 1} end)
      assert_receive {:snapshot, finisher, {:Confirmed, 1}}, 5000
      send(finisher, :release)
      wait(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "completed"}} end)
      assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1
    end)
  end

  test "HTTP failure tags preserve the frozen rows and tag mutations are detected", c do
    request = adapter_request(c, c.cfg)

    rows = [
      http404: :http_4xx,
      http503: :http_5xx,
      redirect: :http_redirect,
      pending: :not_acknowledged,
      invalid: :receipt_invalid,
      drop: :transport_error,
      hold: :transport_timeout
    ]

    check = fn mode, tag ->
      Fixture.mode(c.f, mode)
      assert {:error, ^tag, _} = H.Adapter.send_effect(request)
    end

    for {mode, tag} <- rows, do: check.(mode, tag)

    for {tag, replacement, mode} <- [
          {:http_5xx, :transport_error, :http503},
          {:http_redirect, :http_4xx, :redirect}
        ] do
      mutation(
        "elzoo/http_job/adapter.ex",
        "{:error, :#{tag}, :status}",
        "{:error, :#{replacement}, :status}",
        fn ->
          assert_raise ExUnit.AssertionError, fn -> check.(mode, tag) end
        end
      )
    end

    for tag <- [:preflight_unavailable, :request_rejected] do
      req = %{request | context: %{c.cfg | credentials: fn -> {:error, tag} end}}
      assert {:error, ^tag, :preflight} = H.Adapter.send_effect(req)
    end
  end

  test "admission refuses a missing deadline and a different command schema", c do
    for command <- [
          Map.delete(c.declaration["command"], "deadline_unix_ms"),
          Map.put(c.declaration["command"], "schema_id", "other")
        ] do
      assert {:error, :admission} = H.admission(c.cfg, Map.put(c.declaration, "command", command))
    end
  end
end
