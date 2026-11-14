# SPDX-License-Identifier: Apache-2.0
# Build the executable once (here into a disposable directory), then evaluate one
# function in a fresh process. `mix run examples/elzoo/lua_sandbox.exs` from a project
# that declares the source-only `lua_source` dependency.
source_directory = Mix.Project.deps_paths()[:lua_source]

build_directory =
  Path.join(System.tmp_dir!(), "lua-sandbox-example-#{System.unique_integer([:positive])}")

{:ok, executable} = Elzoo.LuaSandbox.build(source_directory, build_directory)

try do
  {:ok, %{value: value}} =
    Elzoo.LuaSandbox.run(executable, %{
      source: "return function(x) return x + 1 end",
      input: 41,
      policy: Elzoo.LuaSandbox.policy().identity,
      calls: %{mode: "none", names: [], recorded: []},
      limits: %{
        steps: 10_000,
        call_depth: 8,
        value_bytes: 1_024,
        memory_bytes: 1_048_576,
        wall_ms: 500
      }
    })

  IO.inspect(value)
after
  File.rm_rf!(build_directory)
end
