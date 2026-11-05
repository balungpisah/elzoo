# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Elzoo.Ledger do
  use Mix.Task
  @requirements ["app.config"]
  @shortdoc "Validate piece metadata and generate the readable ledger"
  def run(args) do
    unless args in [[], ["--check"]], do: Mix.raise("usage: mix elzoo.ledger [--check]")
    content = Elzoo.Registry.load!() |> Elzoo.Registry.ledger()

    if args == ["--check"] do
      unless File.read("LEDGER.md") == {:ok, content},
        do: Mix.raise("LEDGER.md is stale; run mix elzoo.ledger")

      Mix.shell().info("Piece ledger is consistent")
    else
      File.write!("LEDGER.md", content)
      Mix.shell().info("Wrote LEDGER.md")
    end
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end
