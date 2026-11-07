# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckSelection do
  @moduledoc "Selection of independent consumer tests; root tests always run."

  # This is the existing export-test inventory, not every ready Piece. Adding a
  # standalone consumer is a separate evidence change, not a selector side effect.
  @consumer_ids ~w(core/operator core/port core/assembly core/envelope core/edge core/wiring core/selection delivery/idempotency delivery/windowed-idempotency delivery/request-reply delivery/routing delivery/transformation delivery/backpressure delivery/dead-letter delivery/retry-timeout runtime/adapter runtime/host assembly/ingest-json-unit assembly/request-route-retry state/event-log state/checkpoint state/outbox integration/sql workflow/state-machine integration/jobs assembly/durable-job)

  def consumer_ids, do: @consumer_ids

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

  def test_args(%{mode: :affected, skipped: skipped}) do
    ["--warnings-as-errors", "--exclude", "aggregate_consumer"] ++
      Enum.flat_map(skipped, &["--exclude", "consumer_id:#{&1}"])
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
      "Aggregate consumer: #{if selection.mode == :full, do: "selected (all ready IDs)", else: "skipped (PR/opt-in mode)"}",
      "OTP-only consumer and all root tests: selected",
      if(selection.mode == :affected,
        do: "LIMIT: this subset does not validate unselected Pieces or the full aggregate.",
        else: "Full consumer coverage requested."
      )
    ]
    |> Enum.join("\n")
  end

  def success_marker(%{mode: :full}), do: "ELZOO CHECK PASSED"

  def success_marker(%{mode: :affected}),
    do: "ELZOO AFFECTED CHECK PASSED (not full consumer acceptance)"

  defp fallback(registry, reason) do
    plan(registry, :affected, ready_ids(registry), @consumer_ids, "select all: #{reason}")
  end

  defp plan(registry, mode, affected, selected, reason) do
    %{
      mode: mode,
      reason: reason,
      affected: Enum.sort(affected),
      selected: Enum.sort(selected),
      skipped: Enum.sort(@consumer_ids -- selected),
      without_consumer: ready_ids(registry) -- @consumer_ids
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
