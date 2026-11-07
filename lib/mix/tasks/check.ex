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

    started = System.monotonic_time(:millisecond)

    stage(started, "format", fn -> Mix.Task.run("format", ["--check-formatted"]) end)
    stage(started, "compile", fn -> Mix.Task.run("compile", ["--warnings-as-errors"]) end)
    stage(started, "ledger", fn -> Mix.Task.run("elzoo.ledger", ["--check"]) end)
    stage(started, "ash_spike", fn -> Mix.Task.run("elzoo.ash_spike", []) end)

    registry = stage(started, "registry_load", fn -> Elzoo.Registry.load!() end)

    selection =
      if is_nil(base),
        do: Elzoo.CheckSelection.full(registry),
        else: Elzoo.CheckSelection.from_git(registry, base)

    Mix.shell().info(Elzoo.CheckSelection.report(selection))

    System.at_exit(fn status ->
      if status == 0, do: Mix.shell().info(Elzoo.CheckSelection.success_marker(selection))
    end)

    stage(started, "root_suite", fn ->
      Mix.Task.run("test", Elzoo.CheckSelection.test_args(selection))
    end)
  end

  # ELZ-045: observation only. A stamp before and after each stage, UTC time plus
  # seconds since `mix check` began (monotonic). It changes no stage or order.
  defp stage(started, name, fun) do
    stamp(started, name, "start")

    try do
      fun.()
    after
      stamp(started, name, "end")
    end
  end

  defp stamp(started, name, edge) do
    elapsed = (System.monotonic_time(:millisecond) - started) / 1000

    Mix.shell().info(
      "ELZOO STAGE #{name} #{edge} utc=#{DateTime.utc_now() |> DateTime.to_iso8601()} " <>
        "elapsed=#{:erlang.float_to_binary(elapsed, decimals: 1)}"
    )
  end
end
