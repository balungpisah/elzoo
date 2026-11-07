# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Compile.Cure do
  @moduledoc """
  Compile application Cure sources into the current Mix application ebin.

  This compiler is part of the normal Mix compilation pipeline. It writes
  verified Cure BEAMs to `Mix.Project.compile_path/0`, so `mix test`, releases,
  and a production build load the same compiled bytes instead of JIT-loading
  source from a test harness.

  ELZ-046: the manifest carries a sha256 fingerprint of the named inputs (every
  source path and content, the sorted source roots, the Cure dependency lock
  entry, the loaded `cure.app` descriptor, this module's BEAM md5, and the
  Elixir and OTP versions). When the fingerprint matches and every listed BEAM
  exists, the compile is skipped. Any other state recompiles everything. The
  fingerprint covers only these inputs; it is not a proof that no other input
  exists.
  """

  use Mix.Task.Compiler

  @manifest "elzoo.cure.manifest"
  @manifest_version "elzoo-cure-manifest 2"

  @impl Mix.Task.Compiler
  def run(_args) do
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

      if skip?(previous, fingerprint, output_dir) do
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
  # unreadable file) never skips.
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
        "compiler_md5=" <> Base.encode16(__MODULE__.module_info(:md5), case: :lower),
        "cure_lock=" <> cure_lock_entry(),
        "cure_app=" <> cure_app_digest(),
        "roots=" <> Enum.join(Enum.sort(source_roots), "\n")
      ] ++
        Enum.map(sources, fn source ->
          "source=" <> source <> "\n" <> Base.encode16(:crypto.hash(:sha256, File.read!(source)))
        end)

    :crypto.hash(:sha256, Enum.join(lines, "\n\n")) |> Base.encode16(case: :lower)
  end

  defp cure_lock_entry do
    case Mix.Dep.Lock.read() do
      %{cure: entry} -> inspect(entry, limit: :infinity)
      _ -> "none"
    end
  rescue
    _ -> "unreadable"
  end

  # The loaded cure.app lists the Cure version and every compiler module.
  # If it cannot be read, the digest is a fresh random value so nothing skips.
  defp cure_app_digest do
    with dir when is_list(dir) <- :code.lib_dir(:cure),
         {:ok, app} <- File.read(Path.join([List.to_string(dir), "ebin", "cure.app"])) do
      Base.encode16(:crypto.hash(:sha256, app), case: :lower)
    else
      _ -> "unreadable-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
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
  # A version 1 manifest held one module name per line. It still yields its
  # module list for stale removal, but no fingerprint, so it never skips.
  defp read_manifest(output_dir) do
    case File.read(manifest_path(output_dir)) do
      {:ok, contents} -> parse_manifest(String.split(contents, "\n", trim: true))
      {:error, _reason} -> %{fingerprint: nil, modules: []}
    end
  end

  defp parse_manifest([@manifest_version | rest]) do
    Enum.reduce(rest, %{fingerprint: nil, modules: []}, fn
      "fingerprint " <> hex, acc when byte_size(hex) == 64 -> %{acc | fingerprint: hex}
      "module " <> name, acc -> %{acc | modules: [String.to_atom(name) | acc.modules]}
      _other, acc -> %{acc | fingerprint: nil}
    end)
  end

  defp parse_manifest(lines) do
    modules = for line <- lines, line =~ ~r/^Cure\.[A-Za-z0-9_.]+$/, do: String.to_atom(line)
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
