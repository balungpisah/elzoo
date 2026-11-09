# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/http_job_test_helper.exs", __DIR__)

defmodule Elzoo.HttpJobTelemetryTest do
  @moduledoc """
  ELZ-052 runtime/telemetry at the http-job runner and Adapter: documented
  events, keys and units (T4), no payload, secret or URL bytes (T5), failing
  handlers (T6), a slow handler (T7), absent handlers (T8) and elapsed-time
  equivalence at the owner's expiry reading and at result arrival (T12 ii,
  iii). New tests only; the existing http-job tests are unchanged.
  """
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Elzoo.HttpJob, as: H
  alias Elzoo.HttpJob.{TestRepo, TestMigration, TestBinding, Fixture}
  alias Elzoo.EffectIntent, as: I
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Postgres
  alias Elzoo.Telemetry

  @events for f <- [:job, :effect], k <- [:start, :stop, :exception], do: [:elzoo, f, k]
  @secret String.duplicate("Zx9Qw7", 6) <> "abcd"

  setup_all do
    case TestRepo.start_link(
           url: System.fetch_env!("ELZOO_TEST_DATABASE_URL"),
           pool_size: 15,
           log: false
         ) do
      {:ok, repo} ->
        Process.unlink(repo)
        on_exit(fn -> Supervisor.stop(repo) end)

      {:error, {:already_started, _}} ->
        :ok
    end

    :ok
  end

  setup do
    prefix = "httpjobtel_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
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

    opts = [
      binding: TestBinding,
      origin: f.origin,
      tenant: "test-tenant",
      queue: "http_job",
      transport_supervisor: transport,
      caller_supervisor: callers,
      credentials: fn -> {:ok, @secret} end,
      authenticate: &Fixture.authenticate/2,
      resolve_intent: fn _ -> {:ok, Agent.get(holder, & &1)} end,
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

    store = Postgres.store(TestRepo, prefix: prefix, fold: I.fold(TestBinding), limits: I.limits())

    host = %{
      store:
        Postgres.store(TestRepo, prefix: prefix, fold: StoreHost.fold(), limits: StoreHost.limits()),
      authorize: fn _, _ -> :fresh end
    }

    owner_opts = [
      binding: TestBinding,
      clock: fn -> Agent.get(clock, & &1) end,
      store: store,
      host: {StoreHost, host},
      task_supervisor: sends
    ]

    %{
      cfg: cfg,
      owner_opts: owner_opts,
      holder: holder,
      clock: clock,
      f: f,
      declaration: declaration,
      body: body
    }
  end

  # A fresh owner, key and job for one idempotency reference.
  defp variant(c, ref, cfg \\ nil) do
    cfg = cfg || c.cfg

    {:ok, a} =
      H.admission(cfg, put_in(c.declaration, ["command", "idempotency_key"], ref))

    opts =
      Keyword.merge(c.owner_opts,
        identity: a.identity,
        arguments: a.arguments,
        deadline: a.deadline,
        adapter_context: cfg
      )

    p = start_supervised!({I, opts}, id: make_ref())
    Agent.update(c.holder, fn _ -> p end)
    job = %Oban.Job{args: %{"v" => 1, "queue" => cfg.queue, "job_key" => a.key}, attempt: 1}
    %{p: p, key: a.key, job: job, cfg: cfg}
  end

  defp tick(v), do: H.perform(v.cfg, v.job)

  defp calls(c, key),
    do: Enum.count(Fixture.calls(c.f), fn {_, path, _} -> String.ends_with?(path, key) end)

  defp wait(fun, ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn ->
      fun.() or (System.monotonic_time(:millisecond) > deadline and flunk("wait timed out")) or
        (Process.sleep(10) && false)
    end)
    |> Enum.find(& &1)
  end

  defp attach(id, fun) do
    :ok = :telemetry.attach_many(id, @events, fun, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp capture(key) do
    parent = self()

    attach("hj-capture-#{key}", fn e, m, d, _ ->
      if d[:request_ref] == key, do: send(parent, {:hj, e, m, d})
    end)
  end

  defp collect(acc \\ []) do
    receive do
      {:hj, e, m, d} -> collect([{e, m, d} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp keys(family, kind) do
    base =
      case family do
        :job -> [:adapter, :attempt, :operation, :queue, :request_ref, :tenant]
        :effect -> [:adapter, :attempt, :operation, :request_ref, :tenant]
      end

    Enum.sort(base ++ %{start: [], stop: [:outcome], exception: [:reason]}[kind])
  end

  defp check({[:elzoo, family, kind] = event, m, d}, c, v) do
    assert Enum.sort(Map.keys(d)) == keys(family, kind)
    assert d.adapter == "assembly/http-job" and d.request_ref == v.key and d.attempt == 1
    assert d.tenant == "test-tenant"
    assert {:ok, ^d} = Telemetry.metadata(event, d)

    allowed =
      case {family, kind} do
        {:job, :start} -> [:queue_wait]
        {:effect, :start} -> [:payload_bytes]
        _ -> [:duration]
      end

    assert Map.keys(m) -- allowed == []
    assert Enum.all?(Map.values(m), &(is_integer(&1) and &1 >= 0))
    if family == :effect and kind == :start, do: assert(m.payload_bytes == byte_size(c.body))
    text = inspect({m, d})

    for forbidden <- [c.body, "secret payload", @secret, c.f.origin, "publication", "signature"],
        do: refute(text =~ forbidden)
  end

  defp ops(events),
    do: Enum.map(events, fn {[_, f, k], _, d} -> {f, d.operation, k, d[:outcome]} end)

  defp confirm_run(c, ref) do
    v = variant(c, ref)
    first = tick(v)
    wait(fn -> I.status(v.p).phase == {:Confirmed, 1} end)
    second = tick(v)
    %{results: [first, second], phase: I.status(v.p).phase, calls: calls(c, v.key), v: v}
  end

  test "T4/T5 runner and Adapter emit the documented events; no payload, secret or URL", c do
    v = variant(c, "t4")
    capture(v.key)
    assert {:snooze, 2} = tick(v)
    wait(fn -> I.status(v.p).phase == {:Confirmed, 1} end)
    assert :ok = tick(v)
    events = collect()
    by = Enum.group_by(ops(events), &elem(&1, 0))

    assert by.job == [
             {:job, :perform, :start, nil},
             {:job, :perform, :stop, :snooze},
             {:job, :perform, :start, nil},
             {:job, :perform, :stop, :ok}
           ]

    assert by.effect == [{:effect, :send, :start, nil}, {:effect, :send, :stop, :completed}]
    Enum.each(events, &check(&1, c, v))
  end

  test "T4 effect stop outcomes are the translated tags; poll maps to pending/unavailable", c do
    expected = %{
      http404: :http_4xx,
      http503: :http_5xx,
      redirect: :http_redirect,
      pending: :not_acknowledged,
      drip: :transport_timeout
    }

    observed =
      for mode <- [:http404, :http503, :redirect, :duplicate, :invalid, :pending, :drop, :drip],
          into: %{} do
        Fixture.mode(c.f, mode)
        v = variant(c, "mode-#{mode}")
        capture(v.key)
        assert {:ok, :dispatched} = I.advance(v.p, :dispatch)
        wait(fn -> I.status(v.p).revision >= 3 end)
        [_, {[:elzoo, :effect, :stop], _, d}] = collect()
        assert {:Dispatched, _, 1} = I.status(v.p).phase

        if mode == :http404 do
          assert {:ok, :polling} = I.advance(v.p, :poll)
          wait(fn -> I.status(v.p).revision >= 4 end)

          assert [{:effect, :poll, :start, nil}, {:effect, :poll, :stop, :unavailable}] =
                   ops(collect())
        end

        {mode, d.outcome}
      end

    for {mode, tag} <- expected, do: assert(observed[mode] == tag, inspect({mode, observed}))

    for mode <- [:duplicate, :invalid, :drop],
        do: assert(observed[mode] in [:receipt_invalid, :transport_error], inspect(observed))

    IO.puts("ELZ-052 T4 http-job effect outcomes: #{inspect(observed)}")
  end

  test "T4 explicit preflight refusal and owner-unavailable and invalid wakes", c do
    cfg = %{c.cfg | credentials: fn -> {:error, :preflight_unavailable} end}
    v = variant(c, "preflight", cfg)
    capture(v.key)
    assert {:ok, :dispatched} = I.advance(v.p, :dispatch)
    wait(fn -> I.status(v.p).phase == {:Definite, :AdapterNoSend, 1} end)
    assert [_, {[:elzoo, :effect, :stop], _, %{outcome: :preflight_unavailable}}] = collect()

    gone = %{c.cfg | resolve_intent: fn _ -> exit(:failure) end}
    w = variant(c, "gone")
    capture(w.key)
    assert H.perform(gone, w.job) == {:error, :owner_unavailable}

    assert [{:job, :perform, :start, nil}, {:job, :perform, :stop, :error}] = ops(collect())

    # Tenant and queue outside the telemetry grammar are omitted; the result is unchanged.
    odd = %{c.cfg | tenant: "tenant one", queue: "Q-1"}
    job = %{w.job | args: %{w.job.args | "queue" => "other"}}
    assert H.perform(odd, job) == {:cancel, :invalid_job}
    [{_, _, d1}, {_, _, d2}] = collect()
    refute Map.has_key?(d1, :tenant) or Map.has_key?(d1, :queue)
    assert d2.outcome == :cancel
  end

  test "T6/T8 raising, throwing and exiting handlers are detached and change no result", c do
    plain = confirm_run(c, "plain")

    for {kind, fun} <- [
          raise: fn _, _, _, _ -> raise "handler" end,
          throw: fn _, _, _, _ -> throw(:handler) end,
          exit: fn _, _, _, _ -> exit(:handler) end
        ] do
      id = "hj-failing-#{kind}"
      :ok = :telemetry.attach_many(id, @events, fun, nil)
      run = confirm_run(c, "failing-#{kind}")
      assert Map.delete(run, :v) == Map.delete(plain, :v)
      refute Enum.any?(:telemetry.list_handlers([:elzoo]), &(&1.id == id))
    end
  end

  test "T7 a 200 ms handler on every event changes no result; added time is reported", c do
    t0 = System.monotonic_time(:microsecond)
    plain = confirm_run(c, "fast")
    plain_us = System.monotonic_time(:microsecond) - t0
    counter = :counters.new(1, [])

    attach("hj-slow", fn _, _, d, _ ->
      if d[:adapter] == "assembly/http-job" do
        :counters.add(counter, 1, 1)
        Process.sleep(200)
      end
    end)

    t1 = System.monotonic_time(:microsecond)
    slow = confirm_run(c, "slow")
    slow_us = System.monotonic_time(:microsecond) - t1
    assert Map.delete(slow, :v) == Map.delete(plain, :v)
    assert slow.results == [{:snooze, 2}, :ok] and slow.calls == 1
    events = :counters.get(counter, 1)
    assert events == 6

    IO.puts(
      "ELZ-052 T7 http-job: events=#{events} handler=200ms plain_us=#{plain_us} slow_us=#{slow_us} added_us=#{slow_us - plain_us}"
    )
  end

  # T12 (ii): the runner :start emission precedes Intent.advance(pid, :expire).
  defp runner_deadline(c, ref, advance, via_handler?) do
    Agent.update(c.clock, fn _ -> 100 end)
    v = variant(c, ref)

    if via_handler? do
      once = :atomics.new(1, [])

      attach("hj-t12-runner-#{ref}", fn [_, family, kind], _, d, _ ->
        if family == :job and kind == :start and d[:request_ref] == v.key and
             :atomics.compare_exchange(once, 1, 0, 1) == :ok,
           do: Agent.update(c.clock, &(&1 + advance))
      end)
    else
      Agent.update(c.clock, &(&1 + advance))
    end

    result = tick(v)
    if result == {:snooze, 2}, do: wait(fn -> I.status(v.p).phase == {:Confirmed, 1} end)
    %{result: result, phase: I.status(v.p).phase, calls: calls(c, v.key)}
  end

  test "T12 (ii) a deadline-crossing runner start handler equals a clock-advanced run", c do
    crossing = runner_deadline(c, "rc-h", 1000, true)
    assert crossing == runner_deadline(c, "rc-c", 1000, false)
    assert crossing.result == {:cancel, :not_dispatchable} and crossing.calls == 0

    short = runner_deadline(c, "rs-h", 500, true)
    assert short == runner_deadline(c, "rs-c", 500, false)
    assert short == runner_deadline(c, "rs-plain", 0, false)
    assert short.result == {:snooze, 2} and short.phase == {:Confirmed, 1}
  end

  # T12 (iii): effect events delay the result's arrival at the owner. The
  # comparison run advances the same clock once inside the transport (its
  # authenticate callback, before the result reaches the owner) without a handler.
  defp arrival(c, ref, advance, via_handler?) do
    Agent.update(c.clock, fn _ -> 100 end)
    once = :atomics.new(1, [])

    bump = fn ->
      if :atomics.compare_exchange(once, 1, 0, 1) == :ok, do: Agent.update(c.clock, &(&1 + advance))
    end

    cfg =
      if via_handler?,
        do: c.cfg,
        else: %{
          c.cfg
          | authenticate: fn val, req ->
              bump.()
              Fixture.authenticate(val, req)
            end
        }

    v = variant(c, ref, cfg)

    if via_handler? do
      attach("hj-t12-effect-#{ref}", fn [_, family, kind], _, d, _ ->
        if family == :effect and kind == :stop and d[:request_ref] == v.key, do: bump.()
      end)
    end

    assert {:ok, :dispatched} = I.advance(v.p, :dispatch)
    wait(fn -> I.status(v.p).revision >= 3 end)
    s = I.status(v.p)
    %{phase: s.phase, revision: s.revision, clock: Agent.get(c.clock, & &1), calls: calls(c, v.key)}
  end

  test "T12 (iii) a deadline-crossing effect handler equals a clock advance before arrival", c do
    crossing = arrival(c, "ac-h", 5900, true)
    assert crossing == arrival(c, "ac-c", 5900, false)
    assert crossing.clock == 6000

    short = arrival(c, "as-h", 500, true)
    assert short == arrival(c, "as-c", 500, false)
    assert Map.delete(short, :clock) == Map.delete(arrival(c, "as-plain", 0, false), :clock)

    IO.puts(
      "ELZ-052 T12 (iii) http-job arrival: crossing=#{inspect(crossing)} short=#{inspect(short)}"
    )
  end
end
