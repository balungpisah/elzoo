# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObservabilityTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Elzoo.Observability, as: O

  @registry :elzoo_observability_v1
  @count :elzoo_v1_events_total
  @duration :elzoo_v1_duration_microseconds_total
  @handler {:elzoo_observability, 1}
  @pairs [
    {"assembly/durable-job", :perform, :job},
    {"assembly/durable-job", :relay, :job},
    {"assembly/http-job", :perform, :job},
    {"assembly/http-job", :send, :effect},
    {"assembly/http-job", :poll, :effect}
  ]

  setup do
    globals = Application.fetch_env(:prometheus, :global_labels)
    Application.put_env(:prometheus, :global_labels, [])
    Application.ensure_all_started(:prometheus)
    O.detach()
    :prometheus_registry.clear(@registry)

    on_exit(fn ->
      Application.ensure_all_started(:prometheus)
      O.detach()
      :prometheus_registry.clear(@registry)

      case globals do
        {:ok, value} -> Application.put_env(:prometheus, :global_labels, value)
        :error -> Application.delete_env(:prometheus, :global_labels)
      end
    end)

    :ok
  end

  defp emit(adapter, operation, family, phase, measurements, extras \\ %{}) do
    :telemetry.execute(
      [:elzoo, family, phase],
      measurements,
      Map.merge(extras, %{adapter: adapter, operation: operation})
    )
  end

  defp value(name, phase, operation \\ "send", adapter \\ "assembly/http-job"),
    do: :prometheus_counter.value(@registry, name, [adapter, operation, phase])

  defp body do
    assert {:ok, %{content_type: "text/plain; version=0.0.4", body: text}} = O.scrape()
    text
  end

  # Parse the public wire body, not provider state or the implementation's table.
  defp series(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Map.new(fn line ->
      [key, number] = String.split(line, " ")
      {key, String.to_integer(number)}
    end)
  end

  defp key(name, adapter, operation, phase),
    do: ~s(#{name}{adapter="#{adapter}",operation="#{operation}",phase="#{phase}"})

  test "closed v1 wire schema has exactly 15 counts and 10 microsecond sums, no cross-products" do
    assert :ok = O.initialize()
    assert :ok = O.attach()

    expected =
      for {{adapter, operation, family}, i} <- Enum.with_index(@pairs, 1),
          {phase, j} <- Enum.with_index([:start, :stop, :exception], 1),
          reduce: %{} do
        acc ->
          n = i + j
          duration = i * 100 + j * 7
          for _ <- 1..n, do: emit(adapter, operation, family, phase, %{duration: duration})
          acc = Map.put(acc, key(@count, adapter, operation, phase), n)

          if phase == :start,
            do: acc,
            else: Map.put(acc, key(@duration, adapter, operation, phase), n * duration)
      end

    # All other adapter/operation/family products must be refused even when
    # injected directly, bypassing runtime/telemetry's metadata validator.
    for adapter <- ["assembly/durable-job", "assembly/http-job", "unknown"],
        operation <- [:perform, :relay, :send, :poll, :unknown, "send"],
        family <- [:job, :effect],
        {adapter, operation, family} not in @pairs,
        phase <- [:start, :stop, :exception] do
      emit(adapter, operation, family, phase, %{duration: 999_999})
    end

    :telemetry.execute([:elzoo, :effect, :unknown], %{duration: 999}, %{})
    :telemetry.execute([:elzoo, :job, :start], %{}, %{})
    text = body()
    assert series(text) == expected
    assert map_size(expected) == 25
    assert text =~ "# TYPE elzoo_v1_events_total counter"

    assert text =~
             "# HELP elzoo_v1_duration_microseconds_total Observed Elzoo v1 terminal duration in microseconds"

    refute text =~ "_bucket"
  end

  test "duration has independent absent/invalid/zero/max handling; start never creates a sum" do
    assert :ok = O.initialize()
    assert :ok = O.attach()
    max = 9_223_372_036_854_775_807

    for measurements <- [
          %{},
          %{duration: -1},
          %{duration: 1.5},
          %{duration: "5"},
          %{duration: max + 1}
        ] do
      emit("assembly/http-job", :send, :effect, :stop, measurements)
    end

    assert value(@count, "stop") == 5
    assert value(@duration, "stop") == :undefined
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 0})
    assert value(@duration, "stop") == 0
    emit("assembly/http-job", :send, :effect, :stop, %{duration: max})
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 23})
    assert value(@count, "stop") == 8
    assert value(@duration, "stop") == max + 23
    emit("assembly/http-job", :send, :effect, :start, %{duration: max})
    assert value(@count, "start") == 1
    assert value(@duration, "start") == :undefined
    assert Map.values(series(body())) |> Enum.member?(max + 23)
  end

  test "ignored secrets never enter text, logs or telemetry failure events, including provider loss" do
    assert :ok = O.initialize()
    assert :ok = O.attach()
    parent = self()
    failure_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      failure_id,
      [:telemetry, :handler, :failure],
      fn _, _, m, _ ->
        send(parent, {:failure, m})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(failure_id) end)

    ignored = [
      :outcome,
      :reason,
      :tenant,
      :queue,
      :request_ref,
      :attempt,
      :queue_wait,
      :payload_bytes,
      :exception,
      :url,
      :credentials,
      :payload,
      :other
    ]

    secret = "DO-NOT-EXPORT-Bearer-credential-42"
    extras = Map.new(ignored, &{&1, %{secret => [secret, %RuntimeError{message: secret}]}})

    log =
      capture_log(fn ->
        for ignored_value <- [secret, "TenantSecret42", String.duplicate("a", 64), extras] do
          emit(
            "assembly/http-job",
            :send,
            :effect,
            :stop,
            %{duration: 17, payload_bytes: secret},
            Map.new(ignored, &{&1, ignored_value})
          )
        end

        text = body()
        refute text =~ secret
        refute text =~ "TenantSecret42"
        refute text =~ String.duplicate("a", 64)
        assert map_size(series(text)) == 2
        assert value(@count, "stop") == 4
        assert value(@duration, "stop") == 68
        assert :ok = Application.stop(:prometheus)
        emit("assembly/http-job", :send, :effect, :exception, %{duration: 19}, extras)
        assert {:error, :unavailable} = O.scrape()
        assert Enum.any?(:telemetry.list_handlers([:elzoo, :effect, :stop]), &(&1.id == @handler))
        assert {:ok, _} = Application.ensure_all_started(:prometheus)
      end)

    refute log =~ secret
    refute_receive {:failure, _}, 0

    [handler] =
      Enum.filter(:telemetry.list_handlers([:elzoo, :effect, :stop]), &(&1.id == @handler))

    assert handler.config == :v1
  end

  test "manual lifecycle preserves totals, attacher death, duplicate and delayed administration semantics" do
    assert {:error, :unavailable} = O.attach()
    assert {:error, :unavailable} = O.scrape()
    assert {:error, :not_attached} = O.detach()
    assert :ok = O.initialize()
    assert series(body()) == %{}
    assert {:error, :conflict} = O.initialize()
    task = Task.async(fn -> O.attach() end)
    assert :ok = Task.await(task)
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 31})
    assert {:error, :already_attached} = O.attach()
    assert value(@count, "stop") == 1
    assert :ok = O.detach()
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 100})
    assert value(@duration, "stop") == 31
    assert :ok = O.attach()
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 7})
    assert value(@count, "stop") == 2
    assert value(@duration, "stop") == 38
    # A delayed administrator has no owner token: it detaches the current singleton.
    parent = self()

    delayed =
      Task.async(fn ->
        send(parent, {:detach_waiting, self()})
        receive do: (:detach -> O.detach())
      end)

    pid = delayed.pid
    assert_receive {:detach_waiting, ^pid}
    assert :ok = O.detach()
    assert :ok = O.attach()
    send(pid, :detach)
    assert :ok = Task.await(delayed)
    assert {:error, :not_attached} = O.detach()
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 101})
    assert value(@count, "stop") == 2
  end

  test "unsafe globals and foreign collectors refuse entry without deleting foreign metrics" do
    for global <- [[tenant: "SECRET"], nil, %{}] do
      Application.put_env(:prometheus, :global_labels, global)
      assert {:error, :unsafe_config} = O.initialize()
      assert {:error, :unsafe_config} = O.attach()
      assert {:error, :unsafe_config} = O.scrape()
    end

    Application.delete_env(:prometheus, :global_labels)
    assert :ok = O.initialize()
    assert :ok = O.attach()
    :prometheus_gauge.new(registry: @registry, name: :foreign, help: ~c"Foreign")
    :prometheus_gauge.set(@registry, :foreign, [], 41)
    assert {:error, :conflict} = O.initialize()
    assert {:error, :unavailable} = O.attach()
    assert {:error, :unavailable} = O.scrape()
    assert :prometheus_gauge.value(@registry, :foreign, []) == 41
    :prometheus_registry.deregister_collector(@registry, :prometheus_gauge)
    assert {:ok, _} = O.scrape()
  end

  test "a callback selected by real telemetry execution may finish after detach" do
    assert :ok = O.initialize()
    gate = {__MODULE__, :selected}
    :ok = :telemetry.attach(gate, [:elzoo, :effect, :stop], &__MODULE__.hold_event/4, self())
    on_exit(fn -> :telemetry.detach(gate) end)
    assert :ok = O.attach()
    # Pinned telemetry snapshots handlers before invoking the first callback;
    # same-key ETS handlers retain insertion order. The gate was inserted first.
    emitter =
      Task.async(fn -> emit("assembly/http-job", :send, :effect, :stop, %{duration: 43}) end)

    try do
      pid = emitter.pid
      assert_receive {:selected, ^pid, :undefined}
      assert :ok = O.detach()
      assert value(@count, "stop") == :undefined
      send(pid, :continue)
      Task.await(emitter)
      assert value(@count, "stop") == 1
      assert value(@duration, "stop") == 43
      assert :ok = O.attach()
      assert value(@count, "stop") == 1
    after
      Task.shutdown(emitter, :brutal_kill)
    end
  end

  @doc false
  def hold_event(_, _, _, parent) do
    send(parent, {:selected, self(), value(@count, "stop")})
    receive do: (:continue -> :ok)
  end

  test "public definition probes distinguish missing and wrong-arity from unpopulated definitions" do
    :prometheus_counter.new(registry: @registry, name: @count, help: ~c"Foreign", labels: [])
    assert {:error, :conflict} = O.initialize()
    assert {:error, :unavailable} = O.attach()
    assert {:error, :unavailable} = O.scrape()
    assert :prometheus_counter.value(@registry, @count, []) == 0
    :prometheus_registry.clear(@registry)
    assert :ok = O.initialize()
    :prometheus_counter.deregister(@registry, @duration)
    assert {:error, :unavailable} = O.attach()
    assert {:error, :unavailable} = O.scrape()
    assert {:error, :conflict} = O.initialize()
  end

  test "provider restart loses metrics, not registration; explicit initialization recovers" do
    assert :ok = O.initialize()
    assert :ok = O.attach()
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 59})
    assert :ok = Application.stop(:prometheus)
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 67})
    assert {:error, :unavailable} = O.initialize()
    assert {:ok, _} = Application.ensure_all_started(:prometheus)
    assert {:error, :unavailable} = O.scrape()
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 71})
    assert :ok = O.initialize()
    assert {:error, :already_attached} = O.attach()
    emit("assembly/http-job", :send, :effect, :stop, %{duration: 73})
    assert value(@count, "stop") == 1
    assert value(@duration, "stop") == 73
  end

  test "count survives failed duration update without replay or telemetry failure" do
    assert :ok = O.initialize()
    assert :ok = O.attach()
    :prometheus_counter.deregister(@registry, @duration)
    emit("assembly/http-job", :send, :effect, :exception, %{duration: 13})
    assert value(@count, "exception") == 1
    assert Enum.any?(:telemetry.list_handlers([:elzoo, :effect, :exception]), &(&1.id == @handler))
  end

  test "concurrent emitters and scrapes finish with exact quiescent totals, no scraper required" do
    assert :ok = O.initialize()
    assert :ok = O.attach()
    parent = self()

    tasks =
      for i <- 1..12 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          for _ <- 1..31, do: emit("assembly/http-job", :poll, :effect, :exception, %{duration: i})
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    for _ <- 1..19, do: assert({:ok, _} = O.scrape())
    Enum.each(tasks, &Task.await/1)
    assert value(@count, "exception", "poll") == 372
    assert value(@duration, "exception", "poll") == 2418
  end

  test "local pull endpoint can be held or absent without blocking event updates" do
    assert :ok = O.initialize()
    assert :ok = O.attach()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
          true = String.starts_with?(request, "GET /metrics HTTP/1.1")
          send(parent, {:scraper_held, self()})
          receive do: (:serve -> :ok)
          {:ok, %{content_type: type, body: text}} = O.scrape()

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: ",
              type,
              "\r\ncontent-length: ",
              Integer.to_string(byte_size(text)),
              "\r\n\r\n",
              text
            ])
        after
          :gen_tcp.close(socket)
        end
      end)

    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    try do
      :ok = :gen_tcp.send(client, "GET /metrics HTTP/1.1\r\nhost: localhost\r\n\r\n")
      assert_receive {:scraper_held, server_pid}
      # No timing threshold: completion is observed while the scraper is
      # still held at an explicit barrier, not inferred from a short sleep.
      updater =
        Task.async(fn ->
          for _ <- 1..47, do: emit("assembly/http-job", :send, :effect, :stop, %{duration: 29})
        end)

      Task.await(updater)
      assert value(@count, "stop") == 47
      assert value(@duration, "stop") == 1363
      send(server_pid, :serve)
      response = read_response(client, "")
      [headers, text] = String.split(response, "\r\n\r\n", parts: 2)
      assert headers =~ "content-type: text/plain; version=0.0.4"

      assert series(text) == %{
               key(@count, "assembly/http-job", :send, :stop) => 47,
               key(@duration, "assembly/http-job", :send, :stop) => 1363
             }

      Task.await(server)
      :gen_tcp.close(listener)
      # No listener or scraper exists now; observations still update in place.
      emit("assembly/http-job", :send, :effect, :stop, %{duration: 11})
      assert value(@count, "stop") == 48
      assert value(@duration, "stop") == 1374
    after
      :gen_tcp.close(client)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp read_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> read_response(socket, acc <> bytes)
      {:error, :closed} -> acc
      other -> flunk("local scrape failed: #{inspect(other)}")
    end
  end
end
