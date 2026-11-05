# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Export do
  @moduledoc "Plan and copy a selected, dependency-closed set of owned source files."
  alias Elzoo.Registry

  def plan!(registry, ids, destination) do
    destination = Path.expand(destination)

    case File.lstat(destination) do
      {:ok, %{type: :directory}} -> :ok
      _ -> raise ArgumentError, "destination must be an existing directory created with mix new"
    end

    unless File.regular?(Path.join(destination, "mix.exs")),
      do: raise(ArgumentError, "destination must contain mix.exs; it is never edited automatically")

    pieces = Registry.select!(registry, ids)
    provider_ids = pieces |> Enum.flat_map(& &1["providers"]) |> Enum.uniq() |> Enum.sort()
    providers = Map.take(registry.providers, provider_ids)

    has_cure =
      Enum.any?(pieces, fn piece -> Enum.any?(piece["files"], &String.ends_with?(&1, ".cure")) end)

    if has_cure and not Map.has_key?(providers, "cure"),
      do: raise(ArgumentError, "Cure sources require a declared cure provider")

    source_files =
      Enum.flat_map(pieces, fn piece ->
        Enum.map(piece["files"], &{&1, "#{piece["directory"]}/#{&1}"}) ++
          [
            {".elzoo/#{piece["directory"]}/README.md", "#{piece["directory"]}/README.md"},
            {".elzoo/#{piece["directory"]}/piece.json", "#{piece["directory"]}/piece.json"}
          ]
      end) ++
        [
          {"licenses/elzoo/LICENSE", "LICENSE"},
          {"licenses/elzoo/NOTICE", "NOTICE"},
          {".elzoo/docs/consuming.md", "docs/consuming.md"}
        ] ++
        if(has_cure,
          do: [{"lib/mix/tasks/compile_cure.ex", "lib/mix/tasks/compile_cure.ex"}],
          else: []
        )

    files =
      Enum.reduce(source_files, %{}, fn {target, source}, acc ->
        bytes = File.read!(Registry.source!(registry.root, source))
        put_file!(acc, target, bytes)
      end)

    hashes = Map.new(files, fn {path, bytes} -> {path, sha256(bytes)} end)
    {revision, dirty} = provenance(registry.root)

    receipt = %{
      "schema_version" => 1,
      "origin" => "https://github.com/balungpisah/elzoo",
      "revision" => revision,
      "uncommitted_changes" => dirty,
      "requested" => Enum.sort(Enum.uniq(ids)),
      "pieces" =>
        Enum.map(pieces, &Map.take(&1, ~w(id kind contract license dependencies grounding limits))),
      "providers" => providers,
      "sha256" => hashes,
      "notice" =>
        "Evidence applies to the recorded original bytes and named scenarios. Customization requires rechecking. No automatic upgrade or proof of the consuming application."
    }

    key = ids |> Enum.sort() |> Enum.uniq() |> Enum.join("+") |> sha256() |> binary_part(0, 16)

    files =
      files
      |> put_file!(".elzoo/receipts/#{key}.json", Jason.encode!(receipt, pretty: true) <> "\n")
      |> put_file!(".elzoo/install/#{key}.md", instructions(pieces, providers, has_cure))

    Enum.each(files, fn {path, bytes} -> preflight!(destination, path, bytes) end)

    %{
      destination: destination,
      files: files,
      pieces: pieces,
      providers: providers,
      instructions: ".elzoo/install/#{key}.md",
      receipt: ".elzoo/receipts/#{key}.json"
    }
  end

  def write!(plan) do
    # Recheck every path before writing any file. Exclusive creates also avoid
    # replacing a file created after preflight. This is not a multi-file filesystem
    # transaction: do not run concurrent writers against the destination.
    Enum.each(plan.files, fn {path, bytes} -> preflight!(plan.destination, path, bytes) end)

    Enum.each(Enum.sort(plan.files), fn {relative, bytes} ->
      path = Path.join(plan.destination, relative)

      if not File.exists?(path) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes, [:exclusive])
      end
    end)

    :ok
  end

  defp put_file!(files, path, bytes) do
    Registry.relative!(path)

    case Map.fetch(files, path) do
      :error -> Map.put(files, path, bytes)
      {:ok, ^bytes} -> files
      {:ok, _} -> raise ArgumentError, "selected pieces disagree on target #{path}"
    end
  end

  defp preflight!(destination, relative, bytes) do
    Registry.relative!(relative)

    case File.lstat(destination) do
      {:ok, %{type: :directory}} -> :ok
      _ -> raise ArgumentError, "destination must remain a real directory: #{destination}"
    end

    parts = Path.split(relative)

    Enum.reduce(Enum.with_index(parts), destination, fn {part, index}, base ->
      path = Path.join(base, part)

      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :directory}} when index < length(parts) - 1 ->
          :ok

        {:ok, %{type: :regular}} when index == length(parts) - 1 ->
          unless File.read!(path) == bytes,
            do: raise(ArgumentError, "refusing to overwrite modified/conflicting file: #{path}")

        {:ok, %{type: :symlink}} ->
          raise ArgumentError, "refusing destination symlink: #{path}"

        {:ok, _} ->
          raise ArgumentError, "destination path conflict: #{path}"

        {:error, reason} ->
          raise ArgumentError, "cannot inspect #{path}: #{reason}"
      end

      path
    end)
  end

  defp instructions(pieces, providers, has_cure) do
    dependencies =
      providers
      |> Enum.sort()
      |> Enum.flat_map(fn {id, provider} ->
        case provider["source"] do
          "hex" ->
            ["{:#{provider["package"]}, \"~> #{provider["version"]}\"}"]

          "git" ->
            [
              "{:#{provider["package"]}, git: #{inspect(provider["url"])}, ref: #{inspect(provider["revision"])}, depth: 1#{if id == "cure", do: ", runtime: false", else: ""}}"
            ]

          "platform" ->
            []
        end
      end)

    applications =
      pieces |> Enum.flat_map(&Map.get(&1, "applications", [])) |> Enum.uniq() |> Enum.sort()

    compiler =
      if has_cure do
        """
        Add this project option in mix.exs (the copied compiler uses cure/ by default):

            compilers: (Mix.compilers() -- [:app]) ++ [:cure, :app]

        Keep the exact Cure SHA above and Elixir 1.20.4 / OTP 29.1.2 for the recorded
        proof results. Cure is an exact-revision build/test dependency; runtime: false
        excludes its automatic startup in the consuming application. The compiler
        task still starts Cure during compilation. No Elzoo runtime is required.
        """
      else
        "These selected pieces need no Cure compiler and no Elzoo runtime application.\n"
      end

    """
    # Install selected source pieces

    Selected dependency closure: #{Enum.map_join(pieces, ", ", & &1["id"])}.

    Files were copied; mix.exs, mix.lock, configuration and test_helper.exs were
    not edited. Review and merge these direct dependencies into deps/0:

    ```elixir
    [#{Enum.join(dependencies, ",\n ")}]
    ```

    The Hex constraints above allow patch-level updates; they are consumer
    resolution suggestions, not evidence for untested releases. Use your own
    lockfile; the receipt records the exact versions exercised in Elzoo. To
    reproduce that evidence exactly, pin those recorded versions. If existing
    dependencies impose incompatible
    versions, resolve that deliberately and rerun the copied boundary tests.

    Additional OTP applications to include in extra_applications: [#{Enum.map_join(applications, ", ", &(":" <> &1))}].

    #{compiler}
    Ensure test/test_helper.exs starts ExUnit, then run mix deps.get and mix test.
    Examples are under examples/elzoo/. Read the selected contracts in
    .elzoo/pieces/ before weaving these into application behavior. Package/OTP
    implementations remain upstream-owned; copied source is Apache-2.0 (see
    licenses/elzoo/LICENSE and NOTICE). This does not relicense your project.

    Copies belong to your application. The receipt records origins and original
    SHA-256 bytes, not a proof of your customizations. Take an updated selection
    into a separate scratch project and review the diff; never overwrite edits.
    """
  end

  defp provenance(root) do
    with {sha, 0} <- System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true),
         {status, 0} <-
           System.cmd("git", ["-C", root, "status", "--porcelain"], stderr_to_stdout: true) do
      {String.trim(sha), String.trim(status) != ""}
    else
      _ -> {nil, true}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
