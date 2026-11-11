# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Elz099StreamingProviderTest do
  use ExUnit.Case, async: true

  alias ServerSentEvents.Parser

  test "F3 direct parser 1.1.0 retains split fields, CRLF and UTF-8 until the event separator" do
    assert Application.spec(:server_sent_events, :vsn) == ~c"1.1.0"
    assert List.keymember?(Application.started_applications(), :server_sent_events, 0)

    chunks = [
      "id: probe\r\nevent: delta\r\nda",
      "ta: caf" <> <<0xC3>>,
      <<0xA9>> <> "\r",
      "\ndata: next\r\n"
    ]

    parser =
      Enum.reduce(chunks, Parser.new(), fn chunk, parser ->
        assert {[], next} = Parser.parse(parser, chunk)
        next
      end)

    assert {[event], parser} = Parser.parse(parser, "\r")
    assert event == %{id: "probe", event: "delta", data: "café\nnext"}
    assert {[], _} = Parser.parse(parser, "\n")

    assert (chunks ++ ["\r", "\n"]) |> ServerSentEvents.decode_stream() |> Enum.to_list() == [event]
    IO.puts("ELZ-099 F3: parser=1.1.0 split_field/crlf/utf8=ok incomplete_event=retained")
  end

  test "F4 an isolated dependency consumer builds and starts fuse and parser without Elzoo or ReqLLM" do
    destination =
      Path.join(System.tmp_dir!(), "elz099-provider-consumer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(destination)
    on_exit(fn -> File.rm_rf!(destination) end)
    fixture = Path.expand("examples/elz099_provider_consumer", __DIR__)
    File.cp_r!(fixture, destination)

    packages = [:fuse, :server_sent_events]

    # Copy only installed package source (including its upstream license and
    # Hex identity). Build artifacts are deliberately excluded: this consumer
    # recompiles both dependencies, with no injected root code paths.
    for package <- packages do
      source = Map.fetch!(Mix.Project.deps_paths(), package)
      target = Path.join([destination, "deps", Atom.to_string(package)])
      File.mkdir_p!(target)

      for entry <- File.ls!(source), entry not in ["_build", "ebin", ".git"] do
        File.cp_r!(Path.join(source, entry), Path.join(target, entry))
      end
    end

    lock = Mix.Dep.Lock.read() |> Map.take(packages)
    assert map_size(lock) == 2
    File.write!(Path.join(destination, "mix.lock"), inspect(lock, limit: :infinity) <> "\n")
    refute File.exists?(Path.join(destination, "_build"))

    output = run_mix!(destination, ["compile", "--warnings-as-errors"])
    assert output =~ "Compiling fuse"
    assert output =~ "Generated server_sent_events app"
    output = run_mix!(destination, ["run", "smoke.exs"])
    assert output =~ "ELZ-099 ISOLATED DEPENDENCY CONSUMER PASSED"
    IO.write(output)
  end

  defp run_mix!(destination, args) do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: destination,
        env: [{~c"MIX_ENV", ~c"test"}, {~c"MIX_BUILD_PATH", false}, {~c"MIX_DEPS_PATH", false}],
        args: args
      ])

    try do
      {output, status} = read_command(port, "", System.monotonic_time(:millisecond) + 45_000)
      assert status == 0, "mix #{Enum.join(args, " ")} failed:\n#{output}"
      output
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp read_command(port, output, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} -> read_command(port, output <> bytes, deadline)
      {^port, {:exit_status, status}} -> {output, status}
    after
      remaining -> flunk("dependency consumer command exceeded 45 seconds: #{output}")
    end
  end
end
