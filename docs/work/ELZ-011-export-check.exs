# SPDX-License-Identifier: Apache-2.0
# Reproduction utility: real export closure in a new VM, upstream BEAM reuse only.
root = File.cwd!()
suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
dir = Path.join(System.tmp_dir!(), "elz011-http-consumer-#{suffix}")
File.mkdir!(dir)

File.write!(
  Path.join(dir, "mix.exs"),
  "defmodule Consumer.MixProject do\n use Mix.Project\n def project, do: [app: :consumer, version: \"0.1.0\", deps: []]\nend\n"
)

plan = Elzoo.Registry.load!() |> Elzoo.Export.plan!(["assembly/http-job"], dir)
:ok = Elzoo.Export.write!(plan)
apps = for {_, p} <- plan.providers, p["source"] == "hex", do: String.to_existing_atom(p["package"])
apps = Enum.uniq([:logger, :crypto | apps])

File.write!(Path.join(dir, "mix.exs"), """
defmodule Consumer.MixProject do
  use Mix.Project
  def project, do: [app: :consumer, version: "0.1.0", prune_code_paths: false,
    cure_paths: ["cure"], compilers: (Mix.compilers() -- [:app]) ++ [:cure, :app],
    test_ignore_filters: [~r/test_helper.exs$/], deps: []]
  def application, do: [extra_applications: #{inspect(apps)}]
end
""")

File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start(seed: 0, timeout: 120_000)\n")
graph = Mix.Project.deps_tree()

roots =
  for {_, p} <- plan.providers, p["source"] != "platform", do: String.to_existing_atom(p["package"])

closure = fn recurse, pending, seen ->
  case pending do
    [] ->
      seen

    [app | rest] ->
      if MapSet.member?(seen, Atom.to_string(app)),
        do: recurse.(recurse, rest, seen),
        else:
          recurse.(recurse, Map.get(graph, app, []) ++ rest, MapSet.put(seen, Atom.to_string(app)))
  end
end

selected = closure.(closure, roots, MapSet.new())

paths =
  Path.wildcard(Path.join(root, "_build/test/lib/*/ebin"))
  |> Enum.filter(&MapSet.member?(selected, Path.basename(Path.dirname(&1))))

script = Path.join(dir, "isolated.exs")

File.write!(script, """
false = Code.ensure_loaded?(Elzoo.Application)
false = Code.ensure_loaded?(Elzoo.Registry)
Mix.CLI.main(["test", "--no-deps-check"])
{:ok, _} = Code.eval_file("examples/http_job.exs")
false = Code.ensure_loaded?(Elzoo.Application)
false = Enum.any?(Application.started_applications(), fn {a, _, _} -> a == :elzoo end)
IO.puts("HTTP_JOB_NO_ROOT_APPLICATION")
""")

{output, status} =
  System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ [script],
    cd: dir,
    stderr_to_stdout: true,
    env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
  )

File.write!(Path.join(dir, "consumer.log"), output)
IO.puts(output)
receipt = Path.join(dir, plan.receipt) |> File.read!() |> Jason.decode!()

for {relative, expected} <- receipt["sha256"] do
  actual =
    :crypto.hash(:sha256, File.read!(Path.join(dir, relative))) |> Base.encode16(case: :lower)

  if actual != expected, do: raise("receipt mismatch: #{relative}")
end

IO.puts("CONSUMER=#{dir} EXIT=#{status} RECEIPT_HASHES=#{map_size(receipt["sha256"])}")
if status != 0, do: System.halt(status)

# Runtime smoke in a second VM without Cure/compiler or root application paths.
runtime_paths = Enum.reject(paths, &(Path.basename(Path.dirname(&1)) == "cure"))
consumer_ebin = Path.join(dir, "_build/test/lib/consumer/ebin")

runtime = """
false = Code.ensure_loaded?(Cure.Compiler)
false = Code.ensure_loaded?(Elzoo.Application)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = Code.eval_file("examples/http_job.exs")
s = %{active: true, flags: %{quarantined: false, disarmed: false}, attempts: 0, phase: {:Intended, :Fresh, 0}}
:JobDispatch = Elzoo.HttpJob.Policy.action(s, 3)
false = Enum.any?(Application.started_applications(), fn {a, _, _} -> a in [:elzoo, :cure] end)
IO.puts("HTTP_JOB_COMPILER_FREE_RUNTIME_OK")
"""

{runtime_output, runtime_status} =
  System.cmd(
    "elixir",
    Enum.flat_map([consumer_ebin | runtime_paths], &["-pa", &1]) ++ ["--eval", runtime],
    cd: dir,
    stderr_to_stdout: true
  )

IO.puts(runtime_output)
if runtime_status != 0, do: System.halt(runtime_status)
