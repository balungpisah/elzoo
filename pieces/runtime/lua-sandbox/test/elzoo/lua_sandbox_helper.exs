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

  @none %{mode: "none", names: [], recorded: []}

  def request(source, input \\ nil, limits \\ %{}, calls \\ @none) do
    %{
      source: source,
      input: input,
      policy: LuaSandbox.policy().identity,
      limits: Map.merge(@default_limits, Map.new(limits)),
      calls: calls
    }
  end

  def run(executable, source, input \\ nil, limits \\ %{}, calls \\ @none) do
    LuaSandbox.run(executable, request(source, input, limits, calls))
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

  @doc "A copy of the executable under a unique path, so `pgrep -f` finds only its children."
  def unique_exe!(executable, directory, name) do
    path = Path.join(directory, "#{name}-#{System.unique_integer([:positive])}")
    File.cp!(executable, path)
    File.chmod!(path, 0o755)
    path
  end

  @doc "The first pid of a process whose command line contains the path, or flunk."
  def wait_for_pid(path, attempts \\ 300) do
    case pids(path) do
      [pid | _] ->
        pid

      [] when attempts > 0 ->
        Process.sleep(10)
        wait_for_pid(path, attempts - 1)

      [] ->
        flunk("no process of #{Path.basename(path)} appeared")
    end
  end

  @doc "True when `kill -0` finds no process with this pid."
  def gone?(pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status != 0
  end

  # The second BEAM: loads the compiled modules of this run, runs each named request once.
  @beam_script """
  [executable, cases_file, out_file] = System.argv()
  cases = cases_file |> File.read!() |> :erlang.binary_to_term()

  results =
    for {name, request} <- cases do
      {name, Elzoo.LuaSandbox.run(executable, request)}
    end

  File.write!(out_file, :erlang.term_to_binary(results, [:deterministic]))
  """

  @doc "Run each `{name, request}` once in a fresh BEAM; the results are `{name, reply}`."
  def other_beam!(exe, requests, directory, label) do
    elixir = System.find_executable("elixir")
    assert is_binary(elixir), "the elixir executable is missing"

    cases_file = Path.join(directory, "cases-#{label}.bin")
    out_file = Path.join(directory, "out-#{label}.bin")
    script = Path.join(directory, "beam-#{label}.exs")
    File.write!(script, @beam_script)
    File.write!(cases_file, :erlang.term_to_binary(requests))

    # Every code path outside the Erlang and Elixir installations: the compiled Piece and
    # its providers, which a copied consumer may build outside its own build path.
    installed = [List.to_string(:code.root_dir()), Path.dirname(Application.app_dir(:elixir))]

    code_paths =
      for path <- :code.get_path(),
          path = List.to_string(path),
          not Enum.any?(installed, &String.starts_with?(path, &1)),
          arg <- ["-pa", path],
          do: arg

    {output, status} =
      System.cmd(elixir, code_paths ++ [script, exe, cases_file, out_file], stderr_to_stdout: true)

    assert status == 0, "second BEAM failed: #{String.slice(output, 0, 500)}"
    out_file |> File.read!() |> :erlang.binary_to_term()
  end

  @doc "A Lua source whose function runs `body`; the chunk returns the function."
  def function_source(body), do: "return function() " <> body <> " end"

  @doc """
  A test-only Port: send one raw frame (bytes, header included) to the real executable
  and collect everything it writes until it exits. Returns `{output, exit_status}`.
  """
  def raw_exchange(executable, frame_bytes, args \\ []) do
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])
    send(port, {self(), {:command, frame_bytes}})
    collect(port, <<>>)
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      10_000 ->
        Port.close(port)
        flunk("the executable did not finish")
    end
  end

  @doc "Decode one reply frame from raw output."
  def decode_frame!(output) do
    <<length::unsigned-little-32, body::binary>> = output
    assert byte_size(body) == length
    Jason.decode!(body)
  end
end
