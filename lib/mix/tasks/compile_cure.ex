# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Compile.Cure do
  @moduledoc """
  Compile application Cure sources into the current Mix application ebin.

  This compiler is part of the normal Mix compilation pipeline. It writes
  verified Cure BEAMs to `Mix.Project.compile_path/0`, so `mix test`, releases,
  and a production build load the same compiled bytes instead of JIT-loading
  source from a test harness.

  ELZ-046: the manifest carries a sha256 fingerprint of named inputs: every
  source path and content, the nearest `Cure.toml` of each source, the sorted
  source roots, the project `mix.lock`, every file in the loaded Cure `ebin`,
  this module's BEAM md5, and the Elixir, OTP and ERTS versions. The compile is
  skipped only when the fingerprint matches, every listed BEAM exists, and
  `--force` was not given. A mismatch on any named input recompiles. The
  fingerprint covers these inputs only; it is not a proof that no other input
  exists.
  """

  use Mix.Task.Compiler

  @manifest "elzoo.cure.manifest"
  @manifest_version "elzoo-cure-manifest 2"
  @module_line ~r/^Cure\.[A-Za-z0-9_.]+$/

  @impl Mix.Task.Compiler
  def run(args) do
    force? = "--force" in args

    source_roots =
      Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

    sources =
      source_roots |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.cure"))) |> Enum.sort()

    output_dir = Mix.Project.compile_path()
    File.mkdir_p!(output_dir)
    Path.wildcard(Path.join(output_dir, ".elzoo_cure_stage_*")) |> Enum.each(&File.rm_rf!/1)
    previous = read_manifest(output_dir)

    if sources == [] do
      remove_stale!(output_dir, previous.modules, [])
      write_manifest!(output_dir, nil, [])
      {:ok, []}
    else
      ensure_cure_started!()
      fingerprint = fingerprint(sources, source_roots)

      if not force? and skip?(previous, fingerprint, output_dir) do
        Mix.shell().info(
          "Cure sources unchanged (fingerprint #{String.slice(fingerprint, 0, 12)}); " <>
            "skipping #{length(previous.modules)} modules"
        )

        add_code_path!(output_dir)
        {:ok, []}
      else
        compile!(sources, source_roots, output_dir, previous.modules, fingerprint)
      end
    end
  end

  defp compile!(sources, source_roots, output_dir, previous_modules, fingerprint) do
    sources = dependency_order(sources)

    # compile_file/2 is the stable standalone source-to-BEAM API for this
    # small application. Cure's canonical artifact sweep currently rejects
    # this generic higher-order example, while compile_file/2 is the same
    # dependent kernel/codegen path used by the pinned release. Source roots
    # let imported siblings resolve independently of filename ordering.
    stage = Path.join(output_dir, ".elzoo_cure_stage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(stage)

    try do
      Enum.each(sources, fn source ->
        case Cure.Compiler.compile_file(source,
               output_dir: stage,
               source_roots: source_roots,
               emit_events: false
             ) do
          {:ok, module, warnings} ->
            Enum.each(warnings, &Mix.shell().info("Cure warning #{source}: #{inspect(&1)}"))
            Mix.shell().info("Compiled #{source} -> #{module}")

          {:error, reason} ->
            Mix.raise("Failed to compile #{source}: #{inspect(reason)}")
        end
      end)

      beams = Path.wildcard(Path.join(stage, "Cure.*.beam"))
      modules = Enum.map(beams, &(&1 |> Path.basename(".beam") |> String.to_atom()))
      remove_stale!(output_dir, previous_modules, modules)

      Enum.each(beams, fn beam ->
        File.cp!(beam, Path.join(output_dir, Path.basename(beam)))
      end)

      write_manifest!(output_dir, fingerprint, modules)
      add_code_path!(output_dir)
      {:ok, []}
    after
      File.rm_rf(stage)
    end
  end

  # Skip only when the recorded fingerprint equals the current one and every
  # recorded BEAM is present. A missing fingerprint (old manifest format,
  # unreadable or malformed file) never skips.
  defp skip?(%{fingerprint: recorded, modules: modules}, current, output_dir) do
    is_binary(recorded) and recorded == current and modules != [] and
      Enum.all?(modules, &File.regular?(Path.join(output_dir, "#{&1}.beam")))
  end

  @doc false
  def fingerprint(sources, source_roots) do
    lines =
      [
        @manifest_version,
        "elixir=" <> System.version(),
        "otp=" <> List.to_string(:erlang.system_info(:otp_release)),
        "erts=" <> List.to_string(:erlang.system_info(:version)),
        "compiler_md5=" <> hex(__MODULE__.module_info(:md5)),
        "lockfile=" <> lockfile_digest(),
        "cure_ebin=" <> cure_ebin_digest(),
        "roots=" <> Enum.join(Enum.sort(source_roots), "\n"),
        "cure_toml=" <> cure_toml_digest(sources)
      ] ++
        Enum.map(sources, fn source -> "source=" <> source <> "\n" <> file_digest(source) end)

    hex(:crypto.hash(:sha256, Enum.join(lines, "\n\n")))
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  defp file_digest(path), do: hex(:crypto.hash(:sha256, File.read!(path)))

  # Doubt never skips: an unreadable input yields a fresh random digest.
  defp doubt, do: "unreadable-" <> hex(:crypto.strong_rand_bytes(8))

  # The whole lock file, so a bump of Cure or any of its dependencies changes
  # the fingerprint. A project without a lock file (a copied consumer before
  # its first deps.get) records a constant; its Cure ebin is hashed below.
  defp lockfile_digest do
    lockfile = Mix.Project.config() |> Keyword.get(:lockfile, "mix.lock")

    case File.read(lockfile) do
      {:ok, contents} -> hex(:crypto.hash(:sha256, contents))
      {:error, :enoent} -> "nolock"
      {:error, _} -> doubt()
    end
  end

  # Every file in the loaded Cure ebin: the compiler that produces the BEAMs.
  # This catches a pin bump, a local edit under deps/cure, and a different
  # Cure build on the same version.
  defp cure_ebin_digest do
    with dir when is_list(dir) <- :code.lib_dir(:cure),
         ebin = Path.join(List.to_string(dir), "ebin"),
         files = Enum.sort(Path.wildcard(Path.join(ebin, "*"))),
         true <- files != [] do
      files
      |> Enum.map(&(Path.basename(&1) <> "=" <> file_digest(&1)))
      |> Enum.join("\n")
      |> then(&hex(:crypto.hash(:sha256, &1)))
    else
      _ -> doubt()
    end
  rescue
    _ -> doubt()
  end

  # Cure binds each source to the nearest ancestor Cure.toml, stopping at the
  # repository root (a `.git` entry) or the filesystem root. Mirror that walk
  # and hash each manifest found, so an edition change recompiles.
  defp cure_toml_digest(sources) do
    sources
    |> Enum.map(&nearest_cure_toml(Path.dirname(Path.expand(&1))))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&(&1 <> "=" <> file_digest(&1)))
    |> Enum.join("\n")
    |> case do
      "" -> "none"
      listing -> hex(:crypto.hash(:sha256, listing))
    end
  end

  defp nearest_cure_toml(dir) do
    manifest = Path.join(dir, "Cure.toml")
    parent = Path.dirname(dir)

    cond do
      File.regular?(manifest) -> manifest
      File.exists?(Path.join(dir, ".git")) -> nil
      parent == dir -> nil
      true -> nearest_cure_toml(parent)
    end
  end

  defp add_code_path!(output_dir) do
    unless String.to_charlist(output_dir) in :code.get_path() do
      :code.add_patha(String.to_charlist(output_dir))
    end
  end

  defp manifest_path(output_dir), do: Path.join(output_dir, @manifest)

  defp dependency_order(sources) do
    case Cure.Compiler.DepGraph.scan(sources) do
      {:ok, graph} ->
        dep_map = Cure.Compiler.DepGraph.order_deps_map(graph)

        dep_map
        |> Cure.Compiler.DepGraph.toposort(Map.keys(dep_map))
        |> Enum.map(&Map.fetch!(graph.modules, &1))

      {:error, reason} ->
        Mix.raise("Could not order Cure sources: #{inspect(reason)}")
    end
  end

  # Manifest format (version 2):
  #
  #     elzoo-cure-manifest 2
  #     fingerprint <sha256 hex>
  #     module Cure.Elzoo.Core
  #     ...
  #
  # Module lines must match `Cure.<name>`; anything else makes the manifest
  # invalid, which keeps its well-formed module list for stale removal but
  # drops the fingerprint. A version 1 manifest held one module name per line
  # and has no fingerprint. Neither case skips.
  defp read_manifest(output_dir) do
    case File.read(manifest_path(output_dir)) do
      {:ok, contents} -> parse_manifest(String.split(contents, "\n", trim: true))
      {:error, _reason} -> %{fingerprint: nil, modules: []}
    end
  end

  defp parse_manifest([@manifest_version | rest]) do
    {fingerprint, modules, valid?} =
      Enum.reduce(rest, {nil, [], true}, fn
        "fingerprint " <> hex, {nil, modules, valid?} when byte_size(hex) == 64 ->
          {hex, modules, valid? and String.match?(hex, ~r/^[0-9a-f]{64}$/)}

        "module " <> name, {fingerprint, modules, valid?} ->
          if String.match?(name, @module_line),
            do: {fingerprint, [String.to_atom(name) | modules], valid?},
            else: {fingerprint, modules, false}

        _other, {fingerprint, modules, _valid?} ->
          {fingerprint, modules, false}
      end)

    %{fingerprint: if(valid?, do: fingerprint), modules: modules}
  end

  defp parse_manifest(lines) do
    modules = for line <- lines, String.match?(line, @module_line), do: String.to_atom(line)
    %{fingerprint: nil, modules: modules}
  end

  defp write_manifest!(output_dir, fingerprint, modules) do
    header = [@manifest_version | if(fingerprint, do: ["fingerprint " <> fingerprint], else: [])]
    body = modules |> Enum.map(&("module " <> Atom.to_string(&1))) |> Enum.sort()
    File.write!(manifest_path(output_dir), Enum.join(header ++ body, "\n") <> "\n")
  end

  defp remove_stale!(output_dir, previous_modules, current_modules) do
    current = MapSet.new(current_modules)

    Enum.each(previous_modules, fn module ->
      if not MapSet.member?(current, module) do
        :code.purge(module)
        :code.delete(module)
        File.rm(Path.join(output_dir, "#{module}.beam"))
      end
    end)
  end

  defp ensure_cure_started! do
    case Application.ensure_all_started(:cure) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("Could not start Cure compiler: #{inspect(reason)}")
    end
  end
end
