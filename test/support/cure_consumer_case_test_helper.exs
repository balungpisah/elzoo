# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CureConsumerCase do
  @moduledoc """
  Shared harness for the copied-consumer tests (ELZ-049).

  The helpers below moved verbatim from `test/export_test.exs`, where every consumer ran in one
  `async: false` module. Database-free consumers now run from three `async: true` modules, so
  up to three consumer VMs run at the same time (two where `max_cases` is 2, see
  test/test_helper.exs). Consumers that need PostgreSQL stay in
  sequence in `Elzoo.ExportTest`: the CI job prepares one disposable database.
  """
  use ExUnit.CaseTemplate

  @root File.cwd!()

  # Consumers whose copy closure names a PostgreSQL provider (postgrex, ecto_sql, oban). They
  # share `ELZOO_TEST_DATABASE_URL`, so they run in sequence.
  @postgres_consumer_ids ~w(integration/sql integration/jobs assembly/durable-job)

  # Database-free consumers, in three groups balanced by the measured `total` seconds on main
  # `0a42370` (symbolic-elzoo job 128581094645): about 65 s, 65 s and 60 s in sequence. The
  # group of a consumer changes only its position in the run, never its test.
  @database_free_groups %{
    a: ~w(assembly/request-route-retry delivery/routing core/selection state/checkpoint
         delivery/request-reply delivery/dead-letter runtime/host),
    b: ~w(assembly/ingest-json-unit runtime/adapter core/wiring core/assembly state/event-log
         delivery/transformation core/edge core/operator),
    c: ~w(workflow/state-machine delivery/retry-timeout delivery/windowed-idempotency state/outbox
         delivery/idempotency core/envelope delivery/backpressure core/port)
  }

  @consumer_test_modules [
    Elzoo.ExportTest,
    Elzoo.ConsumerGroupATest,
    Elzoo.ConsumerGroupBTest,
    Elzoo.ConsumerGroupCTest
  ]

  def postgres_consumer_ids, do: @postgres_consumer_ids
  def database_free_groups, do: @database_free_groups
  def database_free_group(name), do: Map.fetch!(@database_free_groups, name)
  def consumer_test_modules, do: @consumer_test_modules
  def postgres_providers, do: ~w(postgrex ecto_sql oban)

  using do
    quote do
      import Elzoo.CureConsumerCase,
        only: [assert_cure_consumer: 2, assert_cure_consumer: 3, timed: 2, project: 2]

      require Elzoo.CureConsumerCase
    end
  end

  setup do
    destination =
      Path.join(System.tmp_dir!(), "elzoo-consumer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "mix.exs"), project([], false))
    on_exit(fn -> File.rm_rf!(destination) end)
    {:ok, destination: destination, registry: Elzoo.Registry.load!(@root)}
  end

  # Per-test limit for the concurrent database-free groups. Measured basis (PR #90, run
  # 42454973591): with three concurrent consumer VMs on the two-core macbook-ubuntu runner under
  # about 30 minutes of sustained load, `assembly/request-route-retry` rose from 35.8 s
  # (sequential) to 99.1 s in the last completed repeat, and two later repeats went over the 120 s
  # limit by an unknown amount. 240 s is 2x that 120 s lower bound. The two-VM setup that
  # test/test_helper.exs now enforces on that runner (`max_cases`) is measured in the PR's later
  # repeat series. Sequential consumers keep the 120 s default.
  @concurrent_timeout 240_000
  def concurrent_timeout, do: @concurrent_timeout

  @doc """
  Defines one per-ID consumer test for each ID. The name and the `consumer_id` tag are the same
  in every module, so `--exclude consumer_id:<id>` (ELZ-038) keeps working. `:timeout` is the
  per-test limit (default 120 s; the concurrent groups pass `concurrent_timeout/0`).
  """
  defmacro consumer_tests(ids, opts \\ []) do
    quote bind_quoted: [ids: ids, opts: opts] do
      for id <- ids do
        @tag timeout: Keyword.get(opts, :timeout, 120_000)
        @tag consumer_id: id
        test "#{id} carries its own checks into an independent consumer", ctx do
          assert_cure_consumer(ctx, [unquote(id)])
        end
      end
    end
  end

  # ELZ-045: observation only. One line per step, monotonic clock. Printed on
  # success, assertion failure, raise or exit; not when ExUnit kills the test
  # process on a tag timeout.
  def timed(label, fun) do
    started = System.monotonic_time(:millisecond)

    try do
      fun.()
    after
      seconds = (System.monotonic_time(:millisecond) - started) / 1000
      IO.puts("ELZOO TIMING #{label} seconds=#{:erlang.float_to_binary(seconds, decimals: 1)}")
    end
  end

  defp consumer_label(ids),
    do: "consumer=" <> if(length(ids) == 1, do: hd(ids), else: "aggregate(#{length(ids)})")

  def assert_cure_consumer(ctx, ids, opts \\ []) do
    label = consumer_label(ids)

    timed("#{label} total", fn -> assert_cure_consumer_steps(ctx, ids, opts, label) end)
  end

  defp assert_cure_consumer_steps(ctx, ids, opts, label) do
    plan =
      timed("#{label} plan_write", fn ->
        plan = Elzoo.Export.plan!(ctx.registry, ids, ctx.destination)
        Elzoo.Export.write!(plan)
        plan
      end)

    File.write!(
      Path.join(ctx.destination, "mix.exs"),
      project(consumer_applications(plan), Map.has_key?(plan.providers, "cure"))
    )

    helper =
      case Keyword.fetch(opts, :inner_timeout) do
        {:ok, ms} -> "ExUnit.start(seed: 0, timeout: #{ms})\n"
        :error -> "ExUnit.start(seed: 0)\n"
      end

    File.write!(Path.join(ctx.destination, "test/test_helper.exs"), helper)

    # Reuse only compiled upstream dependency artifacts. A fresh VM gets no
    # elzoo ebin, project sources, or runtime application. The fixture keeps
    # these injected upstream code paths for compiler/test use. Compilation may
    # start Cure; the second VM below tests runtime without the compiler. This
    # is not a cold dependency-fetch or release-assembly test.
    graph = Mix.Project.deps_tree()

    roots =
      for {_, p} <- plan.providers,
          p["source"] != "platform",
          do: String.to_existing_atom(p["package"])

    apps = provider_closure(roots, graph, MapSet.new())

    paths =
      Path.wildcard(Path.join([@root, "_build", "test", "lib", "*", "ebin"]))
      |> Enum.filter(&MapSet.member?(apps, Path.basename(Path.dirname(&1))))

    bootstrap = Path.join(ctx.destination, "isolated.exs")

    File.write!(bootstrap, """
    unless :code.which(Elzoo.Registry) == :non_existing and :code.which(:"Cure.Elzoo.Core") == :non_existing,
      do: raise("Elzoo leaked into the consumer code path")
    Mix.CLI.main(["test", "--no-deps-check"])
    """)

    args = Enum.flat_map(paths, &["-pa", &1]) ++ [bootstrap]

    {output, status} =
      timed("#{label} consumer_mix_test", fn ->
        System.cmd("elixir", args,
          cd: ctx.destination,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
        )
      end)

    assert status == 0, output
    assert output =~ "passed"
    refute output =~ "0 tests"
    refute File.exists?(Path.join(ctx.destination, "lib/elzoo/application.ex"))

    runtime_paths =
      [
        Path.join(ctx.destination, "_build/test/lib/consumer/ebin")
        | Enum.reject(paths, &(Path.basename(Path.dirname(&1)) == "cure"))
      ]

    runtime = """
    if :code.which(Cure.Compiler) != :non_existing, do: raise("compiler leaked into runtime")
    {:ok, _} = Application.ensure_all_started(:consumer)
    if :code.which(:"Cure.Elzoo.Composition") != :non_existing do
      {:Transition, 0, :none} = apply(:"Cure.Elzoo.Composition", :discard, [0, :input])
    end
    if :code.which(Elzoo.WindowedIdempotency) != :non_existing do
      {:ok, state} = Elzoo.WindowedIdempotency.new(3, 2)
      message = {:Message, 1, 1, 1, 10}
      {:ok, {next, {:some, ^message}}, :fresh} = Elzoo.WindowedIdempotency.receive(state, message)
      {:ok, {^next, :none}, :duplicate} = Elzoo.WindowedIdempotency.receive(next, message)
      if :code.which(Elzoo.Application) != :non_existing,
        do: raise("Elzoo.Application leaked into windowed consumer")
    end
    if :code.which(Elzoo.Backpressure) != :non_existing do
      {:ok, initial} = Elzoo.Backpressure.new(1)
      {:ok, full, :admitted} = Elzoo.Backpressure.admit(initial)
      {:ok, ^full, :saturated} = Elzoo.Backpressure.admit(full)
      {:ok, ^initial} = Elzoo.Backpressure.release(full)
    end
    if :code.which(Elzoo.DurableLog.Memory) != :non_existing do
      if :code.which(Elzoo.Application) != :non_existing or :code.which(Ash) != :non_existing,
        do: raise("application or Ash leaked into durable-state consumer")
      fold = %{initial: 0, kinds: %{"added" => :state_bearing}, versions: [1],
        destinations: ["sink"], reduce: fn n, _, _, _ -> n + 1 end}
      limits = %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
      Process.put(:consumer_memories, [])
      factory = fn ->
        {:ok, pid} = Elzoo.DurableLog.Memory.start_link(fold: fold, limits: limits)
        Process.put(:consumer_memories, [pid | Process.get(:consumer_memories)])
        {Elzoo.DurableLog.Memory.store(pid), %{fold: fold, limits: limits,
          record: {"added", 1, "event"}, destination: "sink", encode: &Integer.to_string/1,
          hook: &Elzoo.DurableLog.Memory.conformance_hook/3}}
      end
      try do
        for {name, check} <- Elzoo.DurableLog.Conformance.checks() do
          case check.(factory) do
            :ok -> :ok
            error -> raise("compiler-free Memory check failed: " <> inspect({name, error}))
          end
        end
        {store, opts} = factory.()
        {:ok, writer} = Elzoo.DurableLog.Writer.start_link(store: store, stream: "consumer",
          fold: fold, limits: limits)
        try do
          {:committed, 1} = Elzoo.DurableLog.Writer.append(writer, [opts.record], [{"sink", "effect"}])
          if :code.which(Elzoo.Checkpoint) != :non_existing do
            {:committed, 1} = Elzoo.Checkpoint.take(writer, "consumer", 1, &Integer.to_string/1)
            %{model: 1, cursor: {1, false, []}} = Elzoo.Checkpoint.recover(store, "consumer", fold,
              1, fn bytes -> {:ok, String.to_integer(bytes)} end)
          end
          if :code.which(Elzoo.Outbox) != :non_existing do
            {:ok, [item]} = Elzoo.Outbox.pending(store, "consumer", 10)
            {:committed, 1} = Elzoo.Outbox.ack(store, item.idempotency_key, :crypto.strong_rand_bytes(16))
            {:ok, []} = Elzoo.Outbox.pending(store, "consumer", 10)
          end
        after
          GenServer.stop(writer)
        end
        IO.puts("compiler-free Memory K1–K11 passed")
      after
        Enum.each(Process.get(:consumer_memories), &GenServer.stop/1)
      end
    end
    if :code.which(Elzoo.DeadLetter) != :non_existing do
      request = %{"version" => 1, "message_id" => "dead", "schema_id" => "v",
        "schema_version" => 1, "kind" => "command",
        "producer" => %{"unit_id" => "u", "port_id" => "p"}, "payload" => "private"}
      {:ok, record} = Elzoo.DeadLetter.from_result(request, nil, 0, "deadline_before_dispatch")
      {:ok, decoded} = Elzoo.DeadLetter.decode(record)
      ^record = Elzoo.DeadLetter.encode(decoded)
    end
    if :code.which(Elzoo.RetryTimeout) != :non_existing do
      {:ok, policy} = Elzoo.RetryTimeout.policy([])
      {:ok, 40} = Elzoo.RetryTimeout.backoff(policy, 3)
      {:ok, :unresolved} = Elzoo.RetryTimeout.decide(policy, 1, :dispatched)
      {:ok, tasks} = Task.Supervisor.start_link()
      attempt = fn request ->
        %{"version" => 1, "message_id" => request["message_id"],
          "correlation_id" => request["message_id"], "attempt_id" => request["attempt_id"],
          "outcome" => "completed", "dispatch" => "dispatched", "value" => nil,
          "value_schema_id" => "v", "value_schema_version" => 1}
      end
      {:ok, runner} = Elzoo.RetryTimeout.Runner.start_link(capacity: 1, policy: policy,
        task_supervisor: tasks, attempt_timeout_ms: 1000, attempt: attempt,
        dead_letter: fn _ -> :ok end)
      request = %{"version" => 1, "message_id" => "run", "schema_id" => "v",
        "schema_version" => 1, "kind" => "command",
        "producer" => %{"unit_id" => "u", "port_id" => "p"}, "payload" => nil}
      {:ok, ref} = Elzoo.RetryTimeout.Runner.submit(runner, request)
      receive do
        {Elzoo.RetryTimeout, ^ref, {:completed, _}} -> :ok
      after
        2000 -> raise("compiler-free runner did not settle")
      end
      GenServer.stop(runner)
      Supervisor.stop(tasks)
    end
    if :code.which(:"Cure.Elzoo.Port") != :non_existing do
      {:ok, true} = Elzoo.Port.compatible(
        %{"id" => "out", "direction" => "output", "schema_id" => "count", "schema_version" => 1},
        %{"id" => "in", "direction" => "input", "schema_id" => "count", "schema_version" => 1})
    end
    if :code.which(:"Cure.Elzoo.Adapter") != :non_existing do
      {:ok, _} = Elzoo.JsonBoundary.encode("runtime without compiler")
    end
    if :code.which(:"Cure.Elzoo.Envelope") != :non_existing do
      {%{message: message}, _} = Code.eval_file("examples/shared.exs")
      {:ok, record} = Elzoo.Envelope.decode(message)
      ^message = Elzoo.Envelope.encode(record)
    end
    if :code.which(:"Cure.Elzoo.Edge") != :non_existing do
      port = fn id, direction -> %{"id" => id, "direction" => direction, "schema_id" => "count", "schema_version" => 1} end
      source = %{"unit_id" => "unit", "port" => port.("out", "output"), "delivery" => "fused", "required_route" => true}
      target = %{"unit_id" => "unit", "port" => port.("in", "input"), "delivery" => "fused", "required_route" => true}
      edge = %{"id" => "edge", "placement" => "fused", "source" => %{"unit_id" => "unit", "port_id" => "out"}, "target" => %{"unit_id" => "unit", "port_id" => "in"}}
      {:ok, true} = Elzoo.Edge.connect(edge, source, target)
    end
    if :code.which(:"Cure.Elzoo.Wiring") != :non_existing do
      {%{fused: wiring}, _} = Code.eval_file("examples/p0.exs")
      {%{message: message}, _} = Code.eval_file("examples/shared.exs")
      {:ok, ^message} = Elzoo.Wiring.accept(wiring, "ingest-dedup", message)
    end
    if :code.which(Elzoo.IngestBoundary) != :non_existing do
      Code.require_file("examples/elzoo/host.exs")
      core = :"Cure.Elzoo.Core"
      {:ok, supervisor} = Elzoo.IngestHost.start_link([
        {"pipeline", {core, :assembly, apply(core, :empty, [])}}
      ])
      try do
        units = %{"pipeline" => fn -> Elzoo.IngestHost.lookup(supervisor, "pipeline") end}
        envelope = %{
          "version" => 1, "message_id" => "compiler-free-ingress",
          "schema_id" => "example/ingest-message", "schema_version" => 1,
          "kind" => "event",
          "producer" => %{"unit_id" => "pipeline", "port_id" => "ingress.request"},
          "payload" => %{"sender" => 1, "incarnation" => 1, "sequence" => 1, "value" => 10}
        }
        {:ok, json} = Elzoo.IngestBoundary.handle(:fused, units, Jason.encode!(envelope))
        result = Jason.decode!(json)
        %{"outcome" => "completed", "dispatch" => "dispatched", "value" => 10,
          "message_id" => "compiler-free-ingress"} = result
        {:ok, ^result} = Elzoo.Envelope.validate_result(result)
      after
        Supervisor.stop(supervisor)
      end
      if :code.which(Elzoo.Application) != :non_existing,
        do: raise("Elzoo.Application leaked into the consumer")
    end
    if :code.which(:"Cure.Elzoo.RequestReply") != :non_existing do
      {%{message: message, results: results, reply: reply}, _} = Code.eval_file("examples/shared.exs")
      result = results["completed"]
      {:ok, ^result} = Elzoo.RequestReply.correlate(message, result)
      {:ok, ^result} = Elzoo.RequestReply.accept_reply(message, reply, message["reply_to"])
    end
    if :code.which(:"Cure.Elzoo.Routing") != :non_existing do
      {%{fused: wiring}, _} = Code.eval_file("examples/p0.exs")
      {%{message: message}, _} = Code.eval_file("examples/shared.exs")
      table = %{"version" => 1, "source" => message["producer"],
        "routes" => [%{"edge_id" => "ingest-dedup", "match" => %{}}]}
      {:ok, ["ingest-dedup"]} = Elzoo.Routing.route(wiring, table, message)
    end
    if :code.which(Elzoo.Transformation) != :non_existing do
      {%{message: message}, _} = Code.eval_file("examples/shared.exs")
      target = %{"unit_id" => "translated", "message_id" => "translated-1",
        "port" => %{"id" => "out", "direction" => "output", "schema_id" => "translated", "schema_version" => 1}}
      {:ok, translated} = Elzoo.Transformation.translate(message, target, fn _ -> nil end)
      nil = translated["payload"]
      "translated-1" = translated["message_id"]
    end
    if :code.which(:"Cure.Elzoo.Selection") != :non_existing do
      port = fn id, direction -> %{"id" => id, "direction" => direction, "schema_id" => "count", "schema_version" => 1} end
      requirement = %{"upstream" => port.("source", "output"), "downstream" => port.("sink", "input"), "delivery" => "fused"}
      candidate = %{"piece_id" => "candidate", "interface" => %{"input" => port.("in", "input"), "output" => port.("out", "output")}, "delivery" => "fused", "rank" => 0}
      {:ok, "candidate"} = Elzoo.Selection.select(requirement, [candidate])
      {:ok, [{0, ["candidate"]}]} = Elzoo.Selection.rank(requirement, [candidate])
    end
    if :code.which(Elzoo.RequestRouteRetry) != :non_existing do
      {:ok, %{"worker" => state}} = Elzoo.RequestRouteRetry.initial_state(:fused, 3, 1)
      {:ok, unit} = Elzoo.Unit.start_link({:"Cure.Elzoo.RequestRouteRetry", :worker, state})
      {:ok, tasks} = Task.Supervisor.start_link()
      {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 1)
      {:ok, runner} = Elzoo.RequestRouteRetry.start_link(placement: :fused,
        units: %{"worker" => unit}, window: 3, max_senders: 1, capacity: 1,
        policy: policy, task_supervisor: tasks, attempt_timeout_ms: 1000,
        dead_letter: fn _ -> :ok end)
      request = %{"version" => 1, "message_id" => "rr-compiler-free",
        "kind" => "command", "schema_id" => "example/rr-request", "schema_version" => 1,
        "producer" => %{"unit_id" => "client", "port_id" => "request"},
        "payload" => %{"sender" => 1, "incarnation" => 1, "sequence" => 1, "value" => 9}}
      {:ok, ref} = Elzoo.RequestRouteRetry.submit(runner, request)
      receive do
        {Elzoo.RetryTimeout, ^ref, {:completed, %{"value" => %{"decision" => "fresh", "total" => 9}}}} -> :ok
      after
        2000 -> raise("compiler-free request/route/retry did not settle")
      end
      GenServer.stop(runner)
      GenServer.stop(unit)
      Supervisor.stop(tasks)
    end
    if :code.which(:"Cure.Elzoo.JobRun") != :non_existing do
      {:ok, {:active, :begin_attempt}} = Elzoo.JobRun.step(:requested, :start, false, :retry)
      {:ok, {:active, :yield_stale}} = Elzoo.JobRun.step(:active, :stale_start, false, :retry)
      {:ok, :stale_start} = Elzoo.JobRun.start_input(7, 7, 3, 2)
      {:ok, :stale_completed} = Elzoo.JobRun.result_input(true, 1, 2)
      IO.puts("compiler-free JobRun decision passed")
    end
    if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :cure end),
      do: raise("Cure started as a runtime application")
    """

    {output, status} =
      timed("#{label} runtime_vm", fn ->
        System.cmd(
          "elixir",
          Enum.flat_map(runtime_paths, &["-pa", &1]) ++ ["--eval", runtime],
          cd: ctx.destination,
          stderr_to_stdout: true
        )
      end)

    assert status == 0, output

    if "state/event-log" in Enum.map(plan.pieces, & &1["id"]),
      do: assert(output =~ "compiler-free Memory K1–K11 passed")

    if "workflow/state-machine" in Enum.map(plan.pieces, & &1["id"]),
      do: assert(output =~ "compiler-free JobRun decision passed")
  end

  defp consumer_applications(plan) do
    providers = for {_, p} <- plan.providers, p["source"] == "hex", do: p["package"]
    applications = Enum.flat_map(plan.pieces, &Map.get(&1, "applications", []))
    [:logger | Enum.map(Enum.uniq(providers ++ applications), &String.to_existing_atom/1)]
  end

  defp provider_closure([], _, seen), do: seen

  defp provider_closure([app | rest], graph, seen) do
    if MapSet.member?(seen, Atom.to_string(app)) do
      provider_closure(rest, graph, seen)
    else
      provider_closure(
        Map.get(graph, app, []) ++ rest,
        graph,
        MapSet.put(seen, Atom.to_string(app))
      )
    end
  end

  def project(applications, cure?) do
    compilers =
      if cure?,
        do: "cure_paths: [\"cure\"], compilers: (Mix.compilers() -- [:app]) ++ [:cure, :app],",
        else: ""

    """
    defmodule Consumer.MixProject do
      use Mix.Project
      def project, do: [app: :consumer, version: "0.1.0", prune_code_paths: false, test_ignore_filters: [~r/test_helper.exs$/], #{compilers} deps: []]
      def application, do: [extra_applications: #{inspect(applications)}]
    end
    """
  end
end
