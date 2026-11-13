# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckSelection do
  @moduledoc "Selection of consumer tests and disjoint full-check parts."

  # This is the existing export-test inventory, not every ready Piece. Adding a
  # standalone consumer is a separate evidence change, not a selector side effect.
  @consumer_ids ~w(core/operator core/port core/assembly core/envelope core/edge core/wiring core/selection delivery/idempotency delivery/windowed-idempotency delivery/request-reply delivery/routing delivery/transformation delivery/backpressure delivery/dead-letter delivery/retry-timeout runtime/adapter runtime/host assembly/ingest-json-unit assembly/request-route-retry state/event-log state/checkpoint state/outbox state/scheduler integration/sql workflow/state-machine integration/jobs assembly/durable-job integration/ai-text)

  # The per-ID consumers that need the disposable PostgreSQL database stay together, separately from
  # the aggregate consumer (one database per job); test/export_test.exs asserts that this list equals
  # Elzoo.CureConsumerCase.postgres_consumer_ids/0. ELZ-091 added integration/ai-text: its closure
  # reaches integration/sql through delivery/effect-intent.
  @postgres_consumer_ids ~w(integration/sql integration/jobs assembly/durable-job integration/ai-text state/scheduler)
  @parts ~w(root-a root-b aggregate consumers-db consumers)

  # ELZ-129: fixed slow files from the baseline module profile. Root-a keeps the rest and the Ash spike.
  @root_b_tests ~w(test/export_test.exs test/install_configuration_test.exs test/registry_test.exs
                   test/elzoo_take_task_test.exs pieces/assembly/run-engine/test/elzoo/run_engine_test.exs
                   pieces/workflow/context-selection/test/elzoo/context_selection_test.exs
                   pieces/assembly/durable-job/test/elzoo/durable_job_test.exs
                   pieces/delivery/data-stream/test/elzoo/data_stream_copy_test.exs
                   pieces/assembly/http-job/test/elzoo/http_job_test.exs)

  # Small gate (`mix check --piece BASE`): the root tests that read the index and generated files or every Piece
  # directory, and the four modules that hold the per-ID consumers. Each one runs in every small gate:
  # - registry_test.exs: loads registry/catalogue.json and every manifest, compares LEDGER.md with the ledger;
  # - install_configuration_test.exs: loads the Registry and plans the export of every ready ID;
  # - elzoo_take_task_test.exs: loads the Registry and runs `mix elzoo.take` on one ready ID;
  # - cure_record_tags_test.exs: reads every .cure file below pieces/ (record names unique across Pieces);
  # - export_test.exs and the three consumer group modules: their setup loads the Registry; they hold the per-ID
  #   consumers (filtered by tag, as in affected mode); export_test.exs asserts that all four modules are loaded.
  #   ELZ-152: export_test.exs also plans the export of every ready ID into one destination.
  #   ELZ-153: it also holds one consumer test (tag `new_piece_consumer`) for each ready ID outside the inventory
  #   above. test/test_helper.exs excludes that tag; only `test_args/1` of piece mode includes it, for the IDs that
  #   the change adds.
  # docs/plans/release-plan.json, docs/plans/views.md and docs/plans/dependencies.mmd are read by no ExUnit test:
  # scripts/check-roadmap.py checks them in the plan job of the workflow.
  @piece_root_tests ~w(test/registry_test.exs test/install_configuration_test.exs test/elzoo_take_task_test.exs
                       test/cure_record_tags_test.exs test/export_test.exs test/consumer_group_a_test.exs
                       test/consumer_group_b_test.exs test/consumer_group_c_test.exs)

  def consumer_ids, do: @consumer_ids
  def postgres_consumer_ids, do: @postgres_consumer_ids
  def parts, do: @parts
  def piece_root_tests, do: @piece_root_tests

  @doc """
  One of five disjoint parts of the full check: two fixed root groups, the aggregate consumer,
  PostgreSQL per-ID consumers and database-free per-ID consumers. Together they select exactly
  the tests of the full check; test/export_test.exs checks the partition over the loaded suite.
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

  @doc """
  Small gate, first half (no Registry needed): the changed paths since `base` (commits, working tree and untracked
  files, as in affected mode) must all be in the Piece-only class of scripts/ci-change-class.py, the one allowlist of
  the workflow and the queue. Returns `{:ok, %{pieces: ids, added: ids, comparison: text}}` or `{:error, reason}`:
  the mode refuses, it never falls back to a narrower or a wider run. `added` holds the changed IDs that are no
  ready ID at `base`: no `piece.json` there, or a status other than `ready` (ELZ-153).
  """
  def piece_changes(base, root \\ File.cwd!(), classify \\ &classify_piece_paths/1) do
    with {:ok, %{paths: paths, base: resolved, head: head}} <- changed_paths(root, base),
         :ok <- nonempty(paths),
         :ok <- no_special_modes(root, resolved),
         :ok <- no_special_entries(root, paths),
         {:ok, ids} <- classify.(paths),
         {:ok, added} <- not_ready_at_base(root, resolved, ids) do
      {:ok,
       %{
         pieces: ids,
         added: added,
         comparison: "#{resolved} -> #{head} + working tree/untracked files"
       }}
    end
  end

  @doc """
  Small gate, second half: the tests of each changed Piece, of each ready Piece that depends on a changed one
  (transitively, the closure of affected mode), the root tests of `piece_root_tests/0` and the per-ID consumers of
  the affected ready IDs. The aggregate consumer never runs here. A changed directory that is not a ready ID (a new
  Piece) has no dependants and no consumer; its own tests run. A ready ID that the change adds (`added` of
  `piece_changes/3`) and that is outside the inventory gets a copied consumer of its own, in which only its own
  tests run (`new_piece_consumers`, ELZ-153). A changed Piece that was ready at the base gets none, and neither
  does a dependant.
  """
  def piece(registry, %{pieces: [_ | _] = ids} = changes, root \\ File.cwd!()) do
    ready = ready_ids(registry)
    changed_ready = Enum.filter(ids, &(&1 in ready))

    affected =
      if changed_ready == [],
        do: [],
        else: Enum.sort(dependants(registry, MapSet.new(changed_ready)))

    selected = Enum.filter(@consumer_ids, &(&1 in affected))

    piece_tests =
      (ids ++ affected)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&"pieces/#{&1}/test")
      |> Enum.filter(&File.dir?(Path.join(root, &1)))

    %{
      mode: :piece,
      comparison: Map.get(changes, :comparison, "not requested"),
      changed: Enum.sort(ids),
      new: Enum.sort(ids -- ready),
      affected: affected,
      selected: Enum.sort(selected),
      skipped: Enum.sort(@consumer_ids -- selected),
      new_piece_consumers:
        Enum.sort(
          for id <- Map.get(changes, :added, []),
              id in changed_ready,
              id not in @consumer_ids,
              do: id
        ),
      test_paths: piece_tests ++ @piece_root_tests
    }
  end

  # ELZ-153: the changed IDs that are no ready ID in the base commit. `pieces/<id>/piece.json` is read from the
  # commit itself: no such file, a file that is not JSON and a status other than `ready` all mean "not ready at
  # the base". A Git failure refuses.
  defp not_ready_at_base(root, base, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, added} ->
      case ready_at_base?(root, base, "pieces/#{id}/piece.json") do
        {:ok, true} -> {:cont, {:ok, added}}
        {:ok, false} -> {:cont, {:ok, added ++ [id]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # `git ls-tree` prints nothing and exits 0 for a path that the commit does not hold.
  defp ready_at_base?(root, base, path) do
    case git(root, ["ls-tree", "--full-tree", "-z", base, "--", path]) do
      {:ok, ""} ->
        {:ok, false}

      {:ok, _} ->
        with {:ok, bytes} <- git(root, ["show", "#{base}:#{path}"]),
             do: {:ok, match?({:ok, %{"status" => "ready"}}, Jason.decode(bytes))}

      error ->
        error
    end
  end

  defp nonempty([]), do: {:error, "empty changed-path set"}
  defp nonempty(_), do: :ok

  # Removed or replaced special entries are invisible to lstat. Keep the base-to-working-tree comparison.
  defp no_special_modes(root, base) do
    with {:ok, output} <-
           git(root, [
             "diff",
             "--no-ext-diff",
             "--no-renames",
             "--raw",
             "-z",
             "--no-abbrev",
             "--ignore-submodules=none",
             "--no-relative",
             base,
             "--"
           ]),
         true <- output == "" or String.ends_with?(output, "\0") do
      output
      |> String.split("\0")
      |> Enum.drop(-1)
      |> Enum.chunk_every(2)
      |> Enum.reduce_while(:ok, fn
        [header, path], :ok ->
          case {Regex.run(~r/\A:([0-7]{6}) ([0-7]{6}) [0-9a-f]{40} [0-9a-f]{40} [ADMT]\z/, header),
                safe_path?(path)} do
            {[_, old, new], true} when old in ["120000", "160000"] or new in ["120000", "160000"] ->
              {:halt, {:error, "tracked symlink or submodule in the change: #{inspect(path)}"}}

            {[_, old, new], true}
            when old in ["000000", "100644", "100755"] and new in ["000000", "100644", "100755"] and
                   (old != "000000" or new != "000000") ->
              {:cont, :ok}

            _ ->
              {:halt, {:error, "malformed Git mode output"}}
          end

        _, :ok ->
          {:halt, {:error, "malformed Git mode output"}}
      end)
    else
      false -> {:error, "malformed Git mode output"}
      error -> error
    end
  end

  # The Git name list has no file modes: a symlink or a directory (a submodule checkout) in the working tree refuses.
  defp no_special_entries(root, paths) do
    case Enum.find(paths, &(special_entry(Path.join(root, &1)) != nil)) do
      nil -> :ok
      path -> {:error, "#{special_entry(Path.join(root, path))} in the change: #{inspect(path)}"}
    end
  end

  defp special_entry(file) do
    case File.lstat(file) do
      {:ok, %File.Stat{type: :symlink}} -> "symlink"
      {:ok, %File.Stat{type: :directory}} -> "directory or submodule"
      {:ok, %File.Stat{type: :regular}} -> nil
      {:ok, %File.Stat{type: type}} -> "#{type} entry"
      {:error, :enoent} -> nil
      {:error, reason} -> "unreadable path (#{reason})"
    end
  end

  @doc "The Piece-only rule of scripts/ci-change-class.py (`piece-paths`), applied to a path list."
  def classify_piece_paths(paths, script \\ Path.expand("scripts/ci-change-class.py")) do
    case System.cmd("python3", [script, "piece-paths" | paths], stderr_to_stdout: true) do
      {output, 0} -> piece_verdict(Jason.decode(output))
      {_, status} -> {:error, "the Piece-only classifier failed (exit #{status})"}
    end
  rescue
    error in ErlangError -> {:error, "python3 unavailable: #{inspect(error.original)}"}
  end

  defp piece_verdict({:ok, %{"piece_only" => true, "pieces" => [_ | _] = ids, "refused" => nil}}) do
    if Enum.all?(
         ids,
         &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\/[a-z0-9][a-z0-9-]*\z/, &1))
       ),
       do: {:ok, Enum.sort(ids)},
       else: {:error, "malformed Piece IDs from the classifier"}
  end

  defp piece_verdict({:ok, %{"piece_only" => false, "refused" => path}}) when is_binary(path),
    do: {:error, "path outside the Piece-only class: #{inspect(path)}"}

  defp piece_verdict({:ok, %{"piece_only" => false, "refused" => nil}}),
    do: {:error, "no changed path below pieces/<family>/<name>/"}

  defp piece_verdict(_), do: {:error, "malformed answer of the Piece-only classifier"}

  def test_args(%{mode: :full}), do: ["--warnings-as-errors"]

  # An include wins over the default exclusion of test/test_helper.exs, for the named IDs only.
  def test_args(%{mode: :piece, skipped: skipped, new_piece_consumers: own, test_paths: paths}) do
    ["--warnings-as-errors", "--exclude", "aggregate_consumer"] ++
      Enum.flat_map(skipped, &["--exclude", "consumer_id:#{&1}"]) ++
      Enum.flat_map(own, &["--include", "new_piece_consumer:#{&1}"]) ++ paths
  end

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
  of the part's test arguments and of the partition check in test/export_test.exs.

  Notes on ExUnit: `--exclude consumer_id` drops every test that has that tag, whatever its value; an
  `--only` filter wins over an `--exclude` filter, so the database-free consumers are listed one by one
  (every per-ID consumer except the PostgreSQL ones). Root parts load all files and exclude the other
  group's files by absolute name. The partition test checks every loaded test identity.
  """
  def part_filters("root-a"),
    do: %{
      include: [],
      exclude:
        ["consumer_id", "aggregate_consumer"] ++ Enum.map(@root_b_tests, &"file:#{Path.expand(&1)}")
    }

  def part_filters("root-b") do
    files = Path.wildcard("test/**/*.exs") ++ Path.wildcard("pieces/**/*.exs")

    %{
      include: [],
      exclude:
        ["consumer_id", "aggregate_consumer"] ++
          Enum.map(files -- @root_b_tests, &"file:#{Path.expand(&1)}")
    }
  end

  def part_filters("aggregate"), do: %{include: ["aggregate_consumer"], exclude: []}

  def part_filters("consumers-db"),
    do: %{
      include: Enum.map(@postgres_consumer_ids, &"consumer_id:#{&1}"),
      exclude: []
    }

  def part_filters("consumers"),
    do: %{
      include: Enum.map(@consumer_ids -- @postgres_consumer_ids, &"consumer_id:#{&1}"),
      exclude: []
    }

  def report(%{mode: :part, part: part}) do
    "ELZOO CHECK SELECTION: part #{part}\n" <>
      "LIMIT: one of the parts #{Enum.join(@parts, ", ")}; the full check is the five together."
  end

  def report(%{mode: :piece} = selection) do
    [
      "ELZOO CHECK SELECTION: piece (small gate)",
      "Comparison: #{selection.comparison}",
      "Changed Piece IDs: #{inspect(selection.changed, limit: :infinity)}",
      "Changed Piece directories that are not ready IDs: #{inspect(selection.new, limit: :infinity)}",
      "Affected ready IDs (changed and dependants): #{inspect(selection.affected, limit: :infinity)}",
      "Selected consumer IDs (#{length(selection.selected)}): #{inspect(selection.selected, limit: :infinity)}",
      "Skipped consumer IDs (#{length(selection.skipped)}): #{inspect(selection.skipped, limit: :infinity)}",
      "Added ready IDs without a per-ID consumer, each run in a copied consumer of its own with its own tests " <>
        "only (#{length(selection.new_piece_consumers)}): #{inspect(selection.new_piece_consumers, limit: :infinity)}",
      "Test paths: #{inspect(selection.test_paths, limit: :infinity)}",
      "Aggregate consumer: not run in piece mode",
      "Ash spike: not run in piece mode",
      "LIMIT: a selected check, not the full check: only the test paths above run (unselected per-ID consumers " <>
        "excluded; the consumer of an added Piece runs the tests of that Piece only; a changed Piece that was " <>
        "ready at the base gets no such consumer); the aggregate consumer, the other root tests and the Ash " <>
        "spike do not run. The full check runs on main after the merge."
    ]
    |> Enum.join("\n")
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
  def success_marker(%{mode: :part, part: "root-a"}), do: "ELZOO ROOT A SUITE PASSED"
  def success_marker(%{mode: :part, part: "root-b"}), do: "ELZOO ROOT B SUITE PASSED"
  def success_marker(%{mode: :part, part: "aggregate"}), do: "ELZOO AGGREGATE CONSUMER PASSED"
  def success_marker(%{mode: :part, part: "consumers-db"}), do: "ELZOO CONSUMERS DB PASSED"
  def success_marker(%{mode: :part, part: "consumers"}), do: "ELZOO CONSUMERS PASSED"

  def success_marker(%{mode: :piece}),
    do: "ELZOO PIECE CHECK PASSED (small gate; a selected check, not the full check; see LIMIT)"

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
