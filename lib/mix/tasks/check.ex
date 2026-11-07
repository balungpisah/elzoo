defmodule Mix.Tasks.Check do
  @moduledoc "Run the full check, or opt into affected consumers with --affected BASE."

  use Mix.Task

  @shortdoc "Compile Cure, run runtime checks, and print the acceptance marker"

  @impl Mix.Task
  def run(args) do
    base =
      case args do
        [] -> nil
        ["--affected", base] -> base
        _ -> Mix.raise("usage: mix check [--affected BASE]; use mix test for a targeted run")
      end

    Mix.Task.run("format", ["--check-formatted"])
    Mix.Task.run("compile", ["--warnings-as-errors"])

    Mix.Task.run("elzoo.ledger", ["--check"])
    Mix.Task.run("elzoo.ash_spike", [])

    registry = Elzoo.Registry.load!()

    selection =
      if is_nil(base),
        do: Elzoo.CheckSelection.full(registry),
        else: Elzoo.CheckSelection.from_git(registry, base)

    Mix.shell().info(Elzoo.CheckSelection.report(selection))

    System.at_exit(fn status ->
      if status == 0, do: Mix.shell().info(Elzoo.CheckSelection.success_marker(selection))
    end)

    Mix.Task.run("test", Elzoo.CheckSelection.test_args(selection))
  end
end
