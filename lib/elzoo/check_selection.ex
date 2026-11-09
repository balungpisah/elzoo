# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckSelection do
  @moduledoc "Selection of independent consumer tests; root tests always run."

  # This is the existing export-test inventory, not every ready Piece. Adding a
  # standalone consumer is a separate evidence change, not a selector side effect.
  @consumer_ids ~w(core/operator core/port core/assembly core/envelope core/edge core/wiring core/selection delivery/idempotency delivery/windowed-idempotency delivery/request-reply delivery/routing delivery/transformation delivery/backpressure delivery/dead-letter delivery/retry-timeout runtime/adapter runtime/host assembly/ingest-json-unit assembly/request-route-retry state/event-log state/checkpoint state/outbox integration/sql workflow/state-machine integration/jobs assembly/durable-job integration/ai-text)

  # ELZ-073: the consumers that need the disposable PostgreSQL database stay together with the
  # aggregate consumer (one database per job); test/export_test.exs asserts that this list equals
  # Elzoo.CureConsumerCase.postgres_consumer_ids/0. ELZ-091 added integration/ai-text: its closure
  # reaches integration/sql through delivery/effect-intent.
  @postgres_consumer_ids ~w(integration/sql integration/jobs assembly/durable-job integration/ai-text)
  @parts ~w(root consumers-db consumers)

  def consumer_ids, do: @consumer_ids
  def postgres_consumer_ids, do: @postgres_consumer_ids
  def parts, do: @parts

  @doc """
  One of three disjoint parts of the full check (ELZ-073): `root` (every test that is not a copied
  consumer), `consumers-db` (the aggregate consumer and the PostgreSQL per-ID consumers) and
  `consumers` (the database-free per-ID consumers). Together they select exactly the tests of the
  full check; test/export_test.exs proves the partition over the loaded suite.
  """
  def part(part) when part in @parts, do: %{mode: :part, part: part}

  def full(registry) do
    plan(registry, :full, ready_ids(registry), @consumer_ids, "full check (default)")
  end

  @doc "Select from a validated Registry and a complete changed-path result."
  def for_changes(registry, {:error, reason}), do: fallback(registry, reason)
  def for_changes(registry, {:ok, []}), do: fallback(registry, "empty changed-path set")

  def for_changes(registry, {:ok, paths}) when is_list(paths) do
    owners = Map.new(ready_ids(registry), &{"pieces/#{&1}", &1})

    mapped =
      Enum.map(paths, fn path ->
        with true <- safe_path?(path),
             ["pieces", family, name | [_ | _]] <- String.split(path, "/"),
             id when is_binary(id) <- owners["pieces/#{family}/#{name}"] do
          {:ok, id}
        else
          _ -> {:unknown, path}
        end
      end)

    case Enum.find(mapped, &match?({:unknown, _}, &1)) do
      {:unknown, path} ->
        fallback(registry, "shared or unmapped path: #{inspect(path)}")

      nil ->
        changed = MapSet.new(mapped, fn {:ok, id} -> id end)
        affected = dependants(registry, changed)
        selected = Enum.filter(@consumer_ids, &MapSet.member?(affected, &1))
        plan(registry, :affected, Enum.sort(affected), selected, "changed Pieces and dependants")
    end
  end

  def for_changes(registry, _), do: fallback(registry, "malformed changed-path input")

  def from_git(registry, base, root \\ File.cwd!()) do
    case changed_paths(root, base) do
      {:ok, %{paths: paths, base: resolved, head: head}} ->
        for_changes(registry, {:ok, paths})
        |> Map.put(:comparison, "#{resolved} -> #{head} + working tree/untracked files")

      {:error, reason} ->
        fallback(registry, reason)
        |> Map.put(:comparison, "unavailable (requested #{inspect(base)})")
    end
  end

  @doc "Read tracked changes and untracked files, preserving both sides of renames."
  def changed_paths(root, base) when is_binary(base) and base != "" do
    with {:ok, resolved} <- commit(root, base),
         {:ok, head} <- commit(root, "HEAD"),
         {:ok, tracked} <-
           git(root, ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", resolved, "--"]),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, paths} <- nul_paths(tracked),
         {:ok, extra} <- nul_paths(untracked) do
      {:ok, %{base: resolved, head: head, paths: Enum.sort(Enum.uniq(paths ++ extra))}}
    end
  end

  def changed_paths(_, _), do: {:error, "missing comparison base"}

  def test_args(%{mode: :full}), do: ["--warnings-as-errors"]

  def test_args(%{mode: :affected, skipped: skipped, aggregate: aggregate}) do
    ["--warnings-as-errors"] ++
      if(aggregate, do: [], else: ["--exclude", "aggregate_consumer"]) ++
      Enum.flat_map(skipped, &["--exclude", "consumer_id:#{&1}"])
  end

  def test_args(%{mode: :part, part: part}) do
    %{include: include, exclude: exclude} = part_filters(part)

    ["--warnings-as-errors"] ++
      Enum.flat_map(include, &["--only", &1]) ++ Enum.flat_map(exclude, &["--exclude", &1])
  end

  @doc """
  The ExUnit filters of one part, as `mix test` takes them (`--only` and `--exclude`). The single source
  of the part's test arguments and of the partition proof in test/export_test.exs.

  Notes on ExUnit: `--exclude consumer_id` drops every test that has that tag, whatever its value; an
  `--only` filter wins over an `--exclude` filter, so the database-free consumers are listed one by one
  (every per-ID consumer except the PostgreSQL ones). The partition test proves that no consumer test
  falls between the parts.
  """
  def part_filters("root"), do: %{include: [], exclude: ["consumer_id", "aggregate_consumer"]}

  def part_filters("consumers-db"),
    do: %{
      include: ["aggregate_consumer" | Enum.map(@postgres_consumer_ids, &"consumer_id:#{&1}")],
      exclude: []
    }

  def part_filters("consumers"),
    do: %{
      include: Enum.map(@consumer_ids -- @postgres_consumer_ids, &"consumer_id:#{&1}"),
      exclude: []
    }

  def report(%{mode: :part, part: part}) do
    "ELZOO CHECK SELECTION: part #{part}\n" <>
      "LIMIT: one of the parts #{Enum.join(@parts, ", ")}; the full check is the three together."
  end

  def report(selection) do
    [
      "ELZOO CHECK SELECTION: #{selection.mode}",
      "Comparison: #{Map.get(selection, :comparison, "not requested")}",
      "Reason: #{selection.reason}",
      "Affected ready IDs: #{inspect(selection.affected, limit: :infinity)}",
      "Selected consumer IDs (#{length(selection.selected)}): #{inspect(selection.selected, limit: :infinity)}",
      "Skipped consumer IDs (#{length(selection.skipped)}): #{inspect(selection.skipped, limit: :infinity)}",
      "Ready IDs without a fixed per-ID consumer: #{inspect(selection.without_consumer, limit: :infinity)}",
      "Affected ready IDs outside selected consumer closures: #{inspect(selection.uncovered, limit: :infinity)}",
      "Aggregate consumer: #{if selection.aggregate, do: "selected (all ready IDs)", else: "skipped"}; #{selection.aggregate_reason}",
      "OTP-only consumer and all root tests: selected",
      if(selection.mode == :affected,
        do:
          "LIMIT: unselected consumer checks are not validated; main's full check remains required.",
        else: "Full consumer coverage requested."
      )
    ]
    |> Enum.join("\n")
  end

  def success_marker(%{mode: :full}), do: "ELZOO CHECK PASSED"
  def success_marker(%{mode: :part, part: "root"}), do: "ELZOO ROOT SUITE PASSED"
  def success_marker(%{mode: :part, part: "consumers-db"}), do: "ELZOO CONSUMERS DB PASSED"
  def success_marker(%{mode: :part, part: "consumers"}), do: "ELZOO CONSUMERS PASSED"

  def success_marker(%{mode: :affected}),
    do: "ELZOO AFFECTED CHECK PASSED (not full consumer acceptance; see selected consumer scope)"

  defp fallback(registry, reason) do
    plan(registry, :affected, ready_ids(registry), @consumer_ids, "select all: #{reason}")
    |> Map.put(:aggregate, true)
    |> Map.put(:aggregate_reason, "full fallback: #{reason}")
  end

  defp plan(registry, mode, affected, selected, reason) do
    # Use the same closure as Export.plan!, including dependencies of consumers
    # that have no standalone test of their own. Never trade their copying
    # evidence for a shorter PR: uncovered affected IDs need the aggregate.
    covered =
      if selected == [],
        do: [],
        else: registry |> Elzoo.Registry.select!(selected) |> Enum.map(& &1["id"])

    uncovered = Enum.sort(affected -- covered)

    %{
      mode: mode,
      reason: reason,
      affected: Enum.sort(affected),
      selected: Enum.sort(selected),
      skipped: Enum.sort(@consumer_ids -- selected),
      without_consumer: ready_ids(registry) -- @consumer_ids,
      uncovered: uncovered,
      aggregate: mode == :full or uncovered != [],
      aggregate_reason:
        cond do
          mode == :full -> "full check (default)"
          uncovered != [] -> "affected IDs lack copying coverage in selected per-ID consumers"
          true -> "every affected ready ID is covered by selected per-ID consumers"
        end
    }
  end

  defp ready_ids(registry) do
    registry.entries
    |> Map.values()
    |> Enum.filter(&(&1["status"] == "ready"))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp dependants(registry, affected) do
    next =
      Enum.reduce(ready_ids(registry), affected, fn id, acc ->
        if Enum.any?(registry.entries[id]["dependencies"], &MapSet.member?(affected, &1)),
          do: MapSet.put(acc, id),
          else: acc
      end)

    if MapSet.equal?(affected, next), do: next, else: dependants(registry, next)
  end

  defp safe_path?(path) when is_binary(path) do
    String.valid?(path) and Path.type(path) == :relative and
      not String.contains?(path, ["\\", "\0", "\n", "\r"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp safe_path?(_), do: false

  defp commit(root, ref) do
    with {:ok, output} <-
           git(root, ["rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}"]) do
      sha = String.trim(output)

      if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
        do: {:ok, sha},
        else: {:error, "invalid comparison commit"}
    end
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_, status} -> {:error, "git #{hd(args)} failed (exit #{status})"}
    end
  rescue
    error in ErlangError -> {:error, "git unavailable: #{inspect(error.original)}"}
  end

  defp nul_paths(""), do: {:ok, []}

  defp nul_paths(output) do
    paths = String.split(output, "\0")

    if List.last(paths) == "" and Enum.all?(Enum.drop(paths, -1), &safe_path?/1),
      do: {:ok, Enum.drop(paths, -1)},
      else: {:error, "malformed Git changed-path output"}
  end
end
