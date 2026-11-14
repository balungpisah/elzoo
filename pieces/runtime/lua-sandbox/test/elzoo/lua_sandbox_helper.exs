# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxHelper do
  @moduledoc false
  # Shared by the Lua sandbox tests: a fresh native build per test module, request
  # construction and small fake executables written into a disposable directory.

  import ExUnit.Assertions

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.Json

  @default_limits %{
    steps: 1_000_000,
    call_depth: 64,
    value_bytes: 65_536,
    memory_bytes: 16_777_216,
    wall_ms: 1_000
  }

  def default_limits, do: @default_limits

  def source_directory do
    directory = Mix.Project.deps_paths()[:lua_source]
    assert is_binary(directory), "lua_source checkout missing from Mix.Project.deps_paths()"
    directory
  end

  @doc "A disposable directory, removed when the calling test or module exits."
  def tmp_dir!(label) do
    directory =
      Path.join(System.tmp_dir!(), "elz163-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  @doc "Build once from the installed checkout; the output directory is removed at exit."
  def build!(label \\ "build") do
    directory = tmp_dir!(label)
    assert {:ok, executable} = LuaSandbox.build(source_directory(), directory)
    assert File.regular?(executable)
    {executable, directory}
  end

  def request(source, input \\ nil, limits \\ %{}) do
    %{
      source: source,
      input: input,
      policy: LuaSandbox.policy().identity,
      limits: Map.merge(@default_limits, Map.new(limits))
    }
  end

  def run(executable, source, input \\ nil, limits \\ %{}) do
    LuaSandbox.run(executable, request(source, input, limits))
  end

  def identity_function(executable, input, limits \\ %{}) do
    run(executable, "return function(x) return x end", input, limits)
  end

  @doc "A `#!/bin/sh` executable with the given body."
  def fake!(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  @doc "Shell `printf` command that writes exactly these bytes (octal escapes)."
  def printf(bytes) do
    escaped =
      for <<byte <- bytes>>,
        into: "",
        do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")

    "printf '#{escaped}'"
  end

  def frame(body), do: Json.frame(body)

  @doc "A well-formed reply body for the real runtime identity."
  def reply(value) do
    Json.encode(%{
      "status" => "ok",
      "value" => value,
      "runtime" =>
        Map.new(LuaSandbox.Build.runtime_identity(), fn {k, v} -> {Atom.to_string(k), v} end)
    })
  end

  @doc "PIDs whose command line contains the unique path."
  def pids(pattern) do
    case System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split() |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end
end
