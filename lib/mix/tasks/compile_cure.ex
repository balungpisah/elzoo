# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Compile.Cure do
  @moduledoc """
  Compile application Cure sources into the current Mix application ebin.

  This compiler is part of the normal Mix compilation pipeline. It writes
  verified Cure BEAMs to `Mix.Project.compile_path/0`, so `mix test`, releases,
  and a production build load the same compiled bytes instead of JIT-loading
  source from a test harness.
  """

  use Mix.Task.Compiler

  @manifest "elzoo.cure.manifest"

  @impl Mix.Task.Compiler
  def run(_args) do
    source_roots =
      Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

    sources =
      source_roots |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.cure"))) |> Enum.sort()

    output_dir = Mix.Project.compile_path()
    File.mkdir_p!(output_dir)
    Path.wildcard(Path.join(output_dir, ".elzoo_cure_stage_*")) |> Enum.each(&File.rm_rf!/1)
    previous_modules = read_manifest(output_dir)

    if sources == [] do
      remove_stale!(output_dir, previous_modules, [])
      write_manifest!(output_dir, [])
      {:ok, []}
    else
      sources = dependency_order(sources)
      ensure_cure_started!()

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

        write_manifest!(output_dir, modules)

        unless String.to_charlist(output_dir) in :code.get_path() do
          :code.add_patha(String.to_charlist(output_dir))
        end

        {:ok, []}
      after
        File.rm_rf(stage)
      end
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

  defp read_manifest(output_dir) do
    case File.read(manifest_path(output_dir)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_atom/1)

      {:error, _reason} ->
        []
    end
  end

  defp write_manifest!(output_dir, modules) do
    contents = modules |> Enum.map(&Atom.to_string/1) |> Enum.sort() |> Enum.join("\n")
    File.write!(manifest_path(output_dir), contents <> if(contents == "", do: "", else: "\n"))
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
