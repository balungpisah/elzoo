defmodule Elzoo.ExportTest do
  use ExUnit.Case, async: false
  @root File.cwd!()

  setup do
    destination =
      Path.join(System.tmp_dir!(), "elzoo-consumer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "mix.exs"), project([], false))
    on_exit(fn -> File.rm_rf!(destination) end)
    {:ok, destination: destination, registry: Elzoo.Registry.load!(@root)}
  end

  test "planning is read-only; copies are idempotent and carry exact hashes", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["integration/json"], ctx.destination)
    assert File.ls!(ctx.destination) == ["mix.exs"]
    refute Map.has_key?(plan.providers, "cure")
    refute Map.has_key?(plan.files, "lib/mix/tasks/compile_cure.ex")
    :ok = Elzoo.Export.write!(plan)
    :ok = Elzoo.Export.write!(plan)
    receipt = Path.join(ctx.destination, plan.receipt) |> File.read!() |> Jason.decode!()
    assert receipt["providers"]["jason"]["version"] == "1.4.5"

    for {relative, expected} <- receipt["sha256"] do
      actual =
        Path.join(ctx.destination, relative)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == expected
    end

    assert File.read!(Path.join(ctx.destination, "mix.exs")) == project([], false)
  end

  test "install guidance separates compiler lifecycle from tested library versions", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["integration/cure-json"], ctx.destination)
    instructions = plan.files[plan.instructions]
    assert instructions =~ "runtime: false"
    assert instructions =~ "a004c335cc4e9f2203ba6f51fc31e8540b66378d"
    assert instructions =~ ~s({:jason, "~> 1.4.5"})
    assert instructions =~ "not evidence for untested releases"
    receipt = Jason.decode!(plan.files[plan.receipt])
    assert receipt["providers"]["jason"]["version"] == "1.4.5"
  end

  test "a conflict found late in the selection writes nothing", ctx do
    file = Path.join(ctx.destination, "test/elzoo/json_recipe_test.exs")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "application-owned changes")

    assert_raise ArgumentError, ~r/refusing to overwrite/, fn ->
      Elzoo.Export.plan!(ctx.registry, ["integration/json"], ctx.destination)
    end

    refute File.exists?(Path.join(ctx.destination, ".elzoo"))
    refute File.exists?(Path.join(ctx.destination, "licenses"))
    assert File.read!(file) == "application-owned changes"
  end

  test "destination symlinks and changes after planning are refused", ctx do
    outside = Path.join(ctx.destination, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(ctx.destination, "lib"))

    assert_raise ArgumentError, ~r/destination symlink/, fn ->
      Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    end

    File.rm!(Path.join(ctx.destination, "lib"))
    plan = Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    source = Path.join(ctx.destination, "lib/elzoo/unit.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "new application changes")
    assert_raise ArgumentError, ~r/refusing to overwrite/, fn -> Elzoo.Export.write!(plan) end
    refute File.exists?(Path.join(ctx.destination, ".elzoo"))
  end

  test "replacing the destination root with a symlink invalidates a plan", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    moved = ctx.destination <> "-moved"
    File.rename!(ctx.destination, moved)
    on_exit(fn -> File.rm_rf!(moved) end)
    File.ln_s!(moved, ctx.destination)
    assert_raise ArgumentError, ~r/destination must remain/, fn -> Elzoo.Export.write!(plan) end
    refute File.exists?(Path.join(moved, ".elzoo"))
  end

  @tag timeout: 120_000
  test "an OTP-only piece runs in a normal independent Mix project", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    Elzoo.Export.write!(plan)
    File.write!(Path.join(ctx.destination, "test/test_helper.exs"), "ExUnit.start()\n")

    {output, status} =
      System.cmd("mix", ["test"],
        cd: ctx.destination,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
      )

    assert status == 0, output
    assert output =~ "1 passed"
  end

  @tag timeout: 120_000
  test "all selected sources compile and run outside Elzoo with only upstream code paths", ctx do
    ids =
      ctx.registry.entries
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "ready"))
      |> Enum.map(& &1["id"])

    assert_cure_consumer(ctx, ids)
  end

  for id <-
        ~w(core/operator core/port core/assembly core/envelope core/edge core/wiring core/selection delivery/idempotency delivery/windowed-idempotency delivery/request-reply delivery/routing delivery/transformation delivery/backpressure delivery/dead-letter delivery/retry-timeout runtime/adapter runtime/host assembly/ingest-json-unit) do
    @tag timeout: 120_000
    test "#{id} carries its own checks into an independent consumer", ctx do
      assert_cure_consumer(ctx, [unquote(id)])
    end
  end

  defp assert_cure_consumer(ctx, ids) do
    plan = Elzoo.Export.plan!(ctx.registry, ids, ctx.destination)
    Elzoo.Export.write!(plan)

    File.write!(
      Path.join(ctx.destination, "mix.exs"),
      project([:logger, :jason, :req, :crypto], Map.has_key?(plan.providers, "cure"))
    )

    File.write!(Path.join(ctx.destination, "test/test_helper.exs"), "ExUnit.start(seed: 0)\n")

    # Reuse only compiled upstream dependency artifacts. A fresh VM gets no
    # elzoo ebin, project sources, or runtime application. The fixture keeps
    # these injected upstream code paths for compiler/test use. Compilation may
    # start Cure; the second VM below tests runtime without the compiler. This
    # is not a cold dependency-fetch or release-assembly test.
    paths =
      Path.wildcard(Path.join([@root, "_build", "test", "lib", "*", "ebin"]))
      |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "elzoo"))

    bootstrap = Path.join(ctx.destination, "isolated.exs")

    File.write!(bootstrap, """
    unless :code.which(Elzoo.Registry) == :non_existing and :code.which(:"Cure.Elzoo.Core") == :non_existing,
      do: raise("Elzoo leaked into the consumer code path")
    Mix.CLI.main(["test", "--no-deps-check"])
    """)

    args = Enum.flat_map(paths, &["-pa", &1]) ++ [bootstrap]

    {output, status} =
      System.cmd("elixir", args,
        cd: ctx.destination,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
      )

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
    if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :cure end),
      do: raise("Cure started as a runtime application")
    """

    {output, status} =
      System.cmd(
        "elixir",
        Enum.flat_map(runtime_paths, &["-pa", &1]) ++ ["--eval", runtime],
        cd: ctx.destination,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp project(applications, cure?) do
    compilers = if cure?, do: "compilers: (Mix.compilers() -- [:app]) ++ [:cure, :app],", else: ""

    """
    defmodule Consumer.MixProject do
      use Mix.Project
      def project, do: [app: :consumer, version: "0.1.0", prune_code_paths: false, #{compilers} deps: []]
      def application, do: [extra_applications: #{inspect(applications)}]
    end
    """
  end
end
