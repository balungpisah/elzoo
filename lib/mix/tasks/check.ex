defmodule Mix.Tasks.Check do
  @moduledoc """
  Run the full check. Three opt-in forms exist: `--affected BASE` runs only the consumers that a change
  can affect, and `--part root|consumers-db|consumers` (ELZ-073) runs one of three disjoint parts of
  the full check, so that CI can run them at the same time. The three parts together run exactly the
  tests of the full check. `--piece BASE` is the small gate of a Piece-only change: format, compile,
  ledger, the Registry, and the tests of the changed Pieces, their dependants, the root tests that read
  the index and the per-ID consumers of the affected ready IDs. It refuses any other change.
  """

  use Mix.Task

  @shortdoc "Compile Cure, run runtime checks, and print the acceptance marker"

  @impl Mix.Task
  def run(args) do
    {base, part, piece_base} =
      case args do
        [] ->
          {nil, nil, nil}

        ["--affected", base] ->
          {base, nil, nil}

        ["--piece", base] ->
          {nil, nil, base}

        ["--part", part] ->
          if part in Elzoo.CheckSelection.parts(),
            do: {nil, part, nil},
            else:
              Mix.raise(
                "unknown part #{inspect(part)}; expected one of #{Enum.join(Elzoo.CheckSelection.parts(), ", ")}"
              )

        _ ->
          Mix.raise(
            "usage: mix check [--affected BASE | --part root|consumers-db|consumers | --piece BASE]; " <>
              "use mix test for a targeted run"
          )
      end

    # The small gate refuses before any stage when a changed path is outside the Piece-only class.
    piece_changes =
      if piece_base do
        case Elzoo.CheckSelection.piece_changes(piece_base) do
          {:ok, changes} ->
            changes

          {:error, reason} ->
            Mix.raise(
              "mix check --piece refuses: #{reason}. The small gate takes only a Piece-only change " <>
                "(scripts/ci-change-class.py); run mix check for this change"
            )
        end
      end

    started = System.monotonic_time(:millisecond)

    stage(started, "format", fn -> Mix.Task.run("format", ["--check-formatted"]) end)
    stage(started, "compile", fn -> Mix.Task.run("compile", ["--warnings-as-errors"]) end)
    stage(started, "ledger", fn -> Mix.Task.run("elzoo.ledger", ["--check"]) end)
    # The Ash spike belongs to the root part; the consumer parts run beside it.
    # The small gate does not run it either (see the LIMIT line of its report).
    if is_nil(piece_changes) and (is_nil(part) or part == "root"),
      do: stage(started, "ash_spike", fn -> Mix.Task.run("elzoo.ash_spike", []) end)

    registry = stage(started, "registry_load", fn -> Elzoo.Registry.load!() end)

    selection =
      cond do
        piece_changes ->
          # As for a part: the consumer inventory is validated against the registry first.
          _ = Elzoo.CheckSelection.full(registry)
          Elzoo.CheckSelection.piece(registry, piece_changes)

        part ->
          # The full selection validates the consumer inventory against the registry (it raises on a
          # mismatch); a part must not skip that check.
          _ = Elzoo.CheckSelection.full(registry)
          Elzoo.CheckSelection.part(part)

        is_nil(base) ->
          Elzoo.CheckSelection.full(registry)

        true ->
          Elzoo.CheckSelection.from_git(registry, base)
      end

    Mix.shell().info(Elzoo.CheckSelection.report(selection))

    System.at_exit(fn status ->
      if status == 0, do: Mix.shell().info(Elzoo.CheckSelection.success_marker(selection))
    end)

    stage(started, if(piece_changes, do: "piece_suite", else: "root_suite"), fn ->
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
