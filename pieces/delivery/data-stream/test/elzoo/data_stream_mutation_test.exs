# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.MutationTest do
  use ExUnit.Case, async: false
  alias Elzoo.DataStream.Fixture
  @tag timeout: 30_000
  test "actual raw guard and EOF-flush mutations fail the named controls in an isolated VM" do
    destination =
      Path.join(
        System.tmp_dir!(),
        "elz101-mutations-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir_p!(destination)
    on_exit(fn -> File.rm_rf!(destination) end)

    sources = [
      "lib/elzoo/data_stream/json.ex",
      "lib/elzoo/data_stream/framer.ex",
      "lib/elzoo/data_stream/protocol.ex",
      "lib/elzoo/data_stream/usage.ex"
    ]

    core =
      ["lib/elzoo/ai_model.ex"] ++
        Enum.map(~w(usage model_ref provenance), &"lib/elzoo/ai_model/#{&1}.ex")

    for {id, paths} <- [{"delivery/data-stream", sources}, {"integration/ai-model", core}],
        path <- paths do
      source = if File.regular?(path), do: path, else: Path.join(["pieces", id, path])
      target = Path.join(destination, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
      assert File.read!(source) == File.read!(target)
    end

    File.write!(
      Path.join(destination, "wire"),
      Fixture.wire([Fixture.start(), Fixture.delta(), Fixture.stop()]) |> String.trim_trailing("\n")
    )

    script = ~S"""
    alias Elzoo.DataStream.{Framer,Protocol}
    {:ok,_,%{compile_warnings: [],runtime_warnings: []}} = Kernel.ParallelCompiler.compile(Path.wildcard("lib/**/*.ex"),return_diagnostics: true)
    raw = File.read!("lib/elzoo/data_stream/framer.ex")
    guard = "byte_size(f.raw) > 65_536"
    2 = length(:binary.matches(raw,guard))
    mutant = raw |> String.replace("Elzoo.DataStream.Framer","RawGuardMutant") |> String.replace(guard,"byte_size(f.raw) > 4_194_304")
    [{RawGuardMutant,_}] = Code.compile_string(mutant)
    # The flawed boundary caps decoded data only: huge comments decode to no
    # event, so this callback has nothing to cap. Production must reject first.
    cb = fn block,n ->
      case ServerSentEvents.Parser.parse(block) do
        {[],_} -> {:ok,n}
        {[%{data: data}],_} when byte_size(data) <= 65_536 -> {:ok,n+1}
        _ -> {:error,:block_limit,n}
      end
    end
    comment = ":" <> String.duplicate("x",65_535) <> "\n\n"
    {:error,:block_limit,_,0} = Framer.feed(Framer.new(),comment,0,cb)
    {:ok,_,0} = RawGuardMutant.feed(RawGuardMutant.new(),comment,0,cb)
    IO.puts("DATA_STREAM_MUTATION raw-only-decoded-limit caught by comment-plus-separator control")
    old = "def eof(f, state, _cb), do: {:error, :malformed_response, f, state}"
    true = String.contains?(raw,old)
    eof_mutant = raw |> String.replace("Elzoo.DataStream.Framer","EOFFlushMutant") |> String.replace(old,"def eof(f, state, cb), do: feed(f, \"\\n\\n\", state, cb)")
    [{EOFFlushMutant,_}] = Code.compile_string(eof_mutant)
    cb = fn block,s ->
      case Protocol.block(block,s) do
        {:ok,p} -> {:ok,p}
        {:ok,p,:none} -> {:ok,p}
        {:ok,p,:stop} -> {:halt,p}
        {:error,r,p} -> {:error,r,p}
      end
    end
    wire = File.read!("wire")
    {:ok,f,s} = Framer.feed(Framer.new(),wire,Protocol.new("claude-sonnet-5",:absent),cb)
    {:error,:malformed_response,_,_} = Framer.eof(f,s,cb)
    {:ok,f,s} = EOFFlushMutant.feed(EOFFlushMutant.new(),wire,Protocol.new("claude-sonnet-5",:absent),cb)
    {:halt,_,%{phase: :stopped}} = EOFFlushMutant.eof(f,s,cb)
    IO.puts("DATA_STREAM_MUTATION EOF-flush-is-success caught by undelimited-stop control")
    false = Code.ensure_loaded?(Elzoo.Application)
    """

    File.write!(Path.join(destination, "probe.exs"), script)

    args = [
      "-pa",
      Application.app_dir(:jason, "ebin"),
      "-pa",
      Application.app_dir(:server_sent_events, "ebin"),
      "probe.exs"
    ]

    {output, exit} =
      System.cmd(System.find_executable("elixir"), args,
        cd: destination,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 4:4 +SDcpu 1 +SDio 1"}, {"ERL_LIBS", nil}]
      )

    assert exit == 0, output
    assert output =~ "DATA_STREAM_MUTATION raw-only-decoded-limit caught"
    assert output =~ "DATA_STREAM_MUTATION EOF-flush-is-success caught"
    IO.write(output)
  end
end
