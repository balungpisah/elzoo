defmodule Mix.Tasks.Check do
  @moduledoc "Run Elzoo's complete development check."

  use Mix.Task

  @shortdoc "Compile Cure, run runtime checks, and print the acceptance marker"

  @impl Mix.Task
  def run(args) do
    if args != [], do: Mix.raise("mix check accepts no arguments; use mix test for a targeted run")

    Mix.Task.run("format", ["--check-formatted"])
    Mix.Task.run("compile", ["--warnings-as-errors"])

    Mix.Task.run("elzoo.ledger", ["--check"])

    System.at_exit(fn status ->
      if status == 0, do: Mix.shell().info("ELZOO CHECK PASSED")
    end)

    Mix.Task.run("test", ["--warnings-as-errors"])
  end
end
