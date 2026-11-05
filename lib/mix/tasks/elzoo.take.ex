# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Elzoo.Take do
  use Mix.Task
  @requirements ["app.config"]
  @shortdoc "Copy selected piece sources and provenance into an existing Mix project"
  def run(args) do
    {options, ids, invalid} = OptionParser.parse(args, strict: [to: :string, dry_run: :boolean])

    if invalid != [] or ids == [] or not options[:to],
      do: Mix.raise("usage: mix elzoo.take ID [ID ...] --to PATH [--dry-run]")

    plan = Elzoo.Registry.load!() |> Elzoo.Export.plan!(ids, options[:to])
    Mix.shell().info("Pieces: " <> Enum.map_join(plan.pieces, ", ", & &1["id"]))
    Mix.shell().info("Files: #{map_size(plan.files)}; install instructions: #{plan.instructions}")

    if options[:dry_run] do
      Enum.each(Enum.sort(Map.keys(plan.files)), fn path -> Mix.shell().info(path) end)
      Mix.shell().info("Dry run; no files written")
    else
      Elzoo.Export.write!(plan)

      Mix.shell().info(
        "Copied sources to #{plan.destination}; merge dependencies and run the copied tests"
      )
    end
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end
