# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/durable_job_test_helper.exs", __DIR__)

defmodule Elzoo.DurableJobTelemetryTest do
  @moduledoc """
  ELZ-052 runtime/telemetry at the durable-job worker and Relay: documented
  events, keys and units (T3, T3r), no payload or key bytes (T5), failing
  handlers (T6), a slow handler (T7), the Relay caller timeout (T11) and
  elapsed-time equivalence at the Run deadline (T12 i). New tests only; the
  existing durable-job tests are unchanged.
  """
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  import Elzoo.DurableJob.TestHelper
  alias Elzoo.{DurableJob, Outbox, Telemetry}
  alias Elzoo.DurableJob.Run

  @events for k <- [:start, :stop, :exception], do: [:elzoo, :job, k]
  @secret_input [424_242, 737_373]

  setup_all do
    prefix = setup_database!()
    on_exit(fn -> drop!(prefix) end)
    %{prefix: prefix}
  end

  defp attach(id, fun) do
    :ok = :telemetry.attach_many(id, @events, fun, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Collects every :job event of one queue into the test process.
  defp capture(queue) do
    parent = self()

    attach("dj-capture-#{queue}", fn e, m, d, _ ->
      if d[:queue] == queue, do: send(parent, {:dj, e, m, d})
    end)
  end

  defp drain(acc \\ []) do
    receive do
      {:dj, e, m, d} -> drain([{e, m, d} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp submit(f, key, input \\ [1, 2, 3], deadline \\ far()),
    do: DurableJob.submit(f.queue, key, input, fast(), deadline)

  defp run_kinds(f, key), do: kinds(f.store, Run.run_stream(f.queue, key))

  # Exact keys per README table, integer units, digest reference, no key or input bytes.
  defp check_event({[:elzoo, :job, kind], m, d}, key) do
    base =
      case d.operation do
        :perform -> [:adapter, :attempt, :operation, :queue, :request_ref]
        :relay -> [:adapter, :operation, :queue, :request_ref]
      end

    extra = %{start: [], stop: [:outcome], exception: [:reason]}[kind]
    assert Enum.sort(Map.keys(d)) == Enum.sort(base ++ extra)
    assert d.adapter == "assembly/durable-job"
    assert d.request_ref == Telemetry.ref(key)
    assert {:ok, _} = Telemetry.metadata([:elzoo, :job, kind], d)

    allowed =
      case {kind, d.operation} do
        {:start, :perform} -> [:queue_wait]
        {:start, :relay} -> []
        _ -> [:duration]
      end

    assert Map.keys(m) -- allowed == []
    assert Enum.all?(Map.values(m), &(is_integer(&1) and &1 >= 0))
    if kind != :start, do: assert(Map.has_key?(m, :duration))
    text = inspect({m, d})
    refute text =~ key
    for n <- @secret_input, do: refute(text =~ Integer.to_string(n))
  end

  defp ops(events), do: Enum.map(events, fn {[_, _, k], _, d} -> {d.operation, k, d[:outcome]} end)

  test "T3/T5 success: relay and worker emit start/stop with the documented keys and units", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres)
    capture(f.queue)
    key = "telemetry-secret-key-1"
    {:ok, _} = submit(f, key, @secret_input)
    {:ok, %{acked: [_]}} = relay!(f.queue)
    poll(fn -> phase(f, key) == :succeeded end)
    poll(fn -> length(drain_peek()) >= 4 end)
    events = drain()

    assert ops(events) == [
             {:relay, :start, nil},
             {:relay, :stop, :done},
             {:perform, :start, nil},
             {:perform, :stop, :ok}
           ]

    Enum.each(events, &check_event(&1, key))
    [_, _, {_, start, d}, _] = events
    assert d.attempt == 1 and d.queue == f.queue
    assert is_integer(start.queue_wait)
  end

  defp drain_peek do
    {:messages, msgs} = Process.info(self(), :messages)
    for {:dj, _, _, _} = m <- msgs, do: m
  end

  test "T3 retry, permanent failure and exhaustion map to error and cancel outcomes", %{
    prefix: prefix
  } do
    counter = :counters.new(1, [])

    handler = fn input ->
      :counters.add(counter, 1, 1)

      case {input, :counters.get(counter, 1)} do
        {[1], 1} -> {:error, :transient}
        {[1], _} -> {:ok, 1}
        {[2], _} -> {:error, :permanent}
      end
    end

    f = flow(prefix, :postgres, handler: handler)
    capture(f.queue)
    {:ok, _} = submit(f, "retry", [1])
    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "retry") == :succeeded end)
    poll(fn -> length(drain_peek()) >= 6 end)

    assert for({:perform, :stop, o} <- ops(drain()), do: o) == [:error, :ok]
    {:ok, _} = submit(f, "permanent", [2])
    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "permanent") == :failed end)
    poll(fn -> length(drain_peek()) >= 4 end)
    assert for({:perform, :stop, o} <- ops(drain()), do: o) == [:cancel]
  end

  test "T3r relay: cancelled before relay is done; malformed item omits request_ref", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres)
    capture(f.queue)
    {:ok, _} = submit(f, "early")
    assert DurableJob.cancel(f.queue, "early", "operator") == {:ok, :cancelled}
    {:ok, %{acked: [_]}} = relay!(f.queue)
    assert [{:relay, :start, nil}, {:relay, :stop, :done}] = ops(drain())

    cfg = :persistent_term.get({DurableJob, f.queue})
    item = %{payload: "{not json", idempotency_key: "x"}
    assert DurableJob.relay(cfg, item) == {:skip, :malformed}

    assert [{[_, _, :start], %{}, d1}, {[_, _, :stop], %{duration: _}, d2}] = drain()
    refute Map.has_key?(d1, :request_ref)
    assert d2.outcome == :skip_malformed
    assert {:ok, _} = Telemetry.metadata([:elzoo, :job, :stop], d2)
  end

  test "T3 a raise inside the execution emits exception and reaches the caller unchanged", %{
    prefix: prefix
  } do
    hook = fn
      :before_begin, _ -> raise "hook raised"
      _, _ -> :ok
    end

    f = flow(prefix, :postgres, test_hook: hook)
    capture(f.queue)
    :ok = Oban.pause_queue(f.oban, queue: f.queue)
    {:ok, _} = submit(f, "raising-key-7")
    {:ok, _} = relay!(f.queue)
    _ = drain()
    cfg = :persistent_term.get({DurableJob, f.queue})
    {:ok, {id, _}} = Elzoo.Jobs.state(f.oban, f.queue, "raising-key-7")

    job = %Oban.Job{
      id: id,
      attempt: 1,
      args: %{"v" => 1, "queue" => f.queue, "job_key" => "raising-key-7"}
    }

    assert_raise RuntimeError, "hook raised", fn -> DurableJob.perform(cfg, job) end
    assert [{:perform, :start, nil}, {:perform, :exception, nil}] = ops(events = drain())
    [_, {_, %{duration: _}, d}] = events
    assert d.reason == :raise
    Enum.each(events, &check_event(&1, "raising-key-7"))
  end

  defp scenario(prefix, key, attach_fun) do
    f = flow(prefix, :postgres)
    attach_fun.(f.queue)
    started = System.monotonic_time(:microsecond)
    {:ok, _} = submit(f, key)
    {:ok, relayed} = relay!(f.queue)
    poll(fn -> phase(f, key) == :succeeded end)
    poll(fn -> oban_state(f, key) == "completed" end)

    %{
      relayed: Map.update!(relayed, :acked, &length/1),
      kinds: run_kinds(f, key),
      oban: oban_state(f, key),
      elapsed_us: System.monotonic_time(:microsecond) - started
    }
  end

  test "T6/T8 raising, throwing and exiting handlers are detached and change no result", %{
    prefix: prefix
  } do
    plain = scenario(prefix, "plain", fn _ -> :ok end)

    for {kind, fun} <- [
          raise: fn _, _, _, _ -> raise "handler" end,
          throw: fn _, _, _, _ -> throw(:handler) end,
          exit: fn _, _, _, _ -> exit(:handler) end
        ] do
      id = "dj-failing-#{kind}"

      run =
        scenario(prefix, "failing-#{kind}", fn queue ->
          capture(queue)
          :ok = :telemetry.attach_many(id, @events, fun, nil)
        end)

      assert Map.delete(run, :elapsed_us) == Map.delete(plain, :elapsed_us)
      refute Enum.any?(:telemetry.list_handlers([:elzoo, :job]), &(&1.id == id))
      # The healthy capture handler kept receiving after the failing one was detached.
      assert {:perform, :stop, :ok} in ops(drain())
    end
  end

  test "T7 a 200 ms handler on every event changes no result; added time is reported", %{
    prefix: prefix
  } do
    plain = scenario(prefix, "fast", fn _ -> :ok end)
    counter = :counters.new(1, [])

    slow =
      scenario(prefix, "slow", fn queue ->
        attach("dj-slow", fn _, _, d, _ ->
          if d[:queue] == queue do
            :counters.add(counter, 1, 1)
            Process.sleep(200)
          end
        end)
      end)

    assert Map.delete(slow, :elapsed_us) == Map.delete(plain, :elapsed_us)
    assert slow.kinds == ~w(accepted attempt_started succeeded)
    events = :counters.get(counter, 1)
    assert events == 4
    added = slow.elapsed_us - plain.elapsed_us

    IO.puts(
      "ELZ-052 T7 durable-job: events=#{events} handler=200ms plain_us=#{plain.elapsed_us} slow_us=#{slow.elapsed_us} added_us=#{added}"
    )
  end

  test "T11 a Relay pass slower than the run_once caller timeout still completes unchanged", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres)

    attach("dj-slow-relay", fn _, _, d, _ ->
      if d[:queue] == f.queue and d.operation == :relay, do: Process.sleep(300)
    end)

    :ok = Oban.pause_queue(f.oban, queue: f.queue)
    {:ok, _} = submit(f, "t11")
    relay = DurableJob.relay_process(f.queue)
    assert {:timeout, _} = catch_exit(Elzoo.Jobs.Relay.run_once(relay, 100))
    # GenServer.call's timeout does not cancel pass/1: the next call is served
    # only after the continuing pass, which acked the item.
    assert {:ok, %{acked: [], skipped: []}} = Elzoo.Jobs.Relay.run_once(relay)
    assert {:ok, []} = Outbox.pending(f.store, Run.submission_stream(f.queue), 10)
    assert run_kinds(f, "t11") == ~w(accepted)
    :telemetry.detach("dj-slow-relay")
    :ok = Oban.resume_queue(f.oban, queue: f.queue)
    poll(fn -> phase(f, "t11") == :succeeded end)
    assert run_kinds(f, "t11") == ~w(accepted attempt_started succeeded)
  end

  # T12 (i): the worker :start emission precedes start_loop/4's Run deadline
  # reading. A handler that advances the injected clock by `advance` yields
  # exactly the outcome of a no-handler run whose clock was advanced by the same
  # amount before the worker ran.
  defp deadline_run(prefix, key, advance, via_handler?) do
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    f = flow(prefix, :postgres, now_ms: fn -> Agent.get(clock, & &1) end)
    :ok = Oban.pause_queue(f.oban, queue: f.queue)
    {:ok, _} = submit(f, key, [1], 2_000_000)
    {:ok, _} = relay!(f.queue)

    if via_handler? do
      once = :atomics.new(1, [])

      attach("dj-t12-#{key}", fn [_, _, kind], _, d, _ ->
        if kind == :start and d[:queue] == f.queue and d.operation == :perform and
             :atomics.compare_exchange(once, 1, 0, 1) == :ok,
           do: Agent.update(clock, &(&1 + advance))
      end)
    else
      Agent.update(clock, &(&1 + advance))
    end

    :ok = Oban.resume_queue(f.oban, queue: f.queue)
    poll(fn -> phase(f, key) in [:succeeded, :expired] end)
    poll(fn -> oban_state(f, key) in ["completed", "cancelled"] end)
    %{phase: phase(f, key), kinds: run_kinds(f, key), oban: oban_state(f, key)}
  end

  test "T12 (i) a deadline-crossing start handler equals a clock-advanced no-handler run", %{
    prefix: prefix
  } do
    crossing = deadline_run(prefix, "cross-h", 1_500_000, true)
    assert crossing == deadline_run(prefix, "cross-c", 1_500_000, false)
    assert crossing.phase == :expired and crossing.oban == "cancelled"
    assert crossing.kinds == ~w(accepted expired)

    short = deadline_run(prefix, "short-h", 500_000, true)
    assert short == deadline_run(prefix, "short-c", 500_000, false)
    assert short == deadline_run(prefix, "plain", 0, false)
    assert short.phase == :succeeded
  end
end
