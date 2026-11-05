# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Elzoo.AshSpike do
  @moduledoc "Check the isolated Ash foundation experiment without adding consumer dependencies."
  use Mix.Task

  @shortdoc "Set up or check the isolated Ash experiment"

  @impl Mix.Task
  def run(args) do
    commands =
      case args do
        ["--setup"] -> [["deps.get"]]
        [] -> [["format", "--check-formatted"], ["test", "--warnings-as-errors"]]
        _ -> Mix.raise("usage: mix elzoo.ash_spike [--setup]")
      end

    for command <- commands do
      {_, status} =
        System.cmd("mix", command,
          cd: Path.join(File.cwd!(), "spikes/ash_foundation"),
          env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}],
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("Ash spike failed: mix #{Enum.join(command, " ")}")
    end
  end
end
