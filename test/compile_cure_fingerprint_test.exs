# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CompileCureFingerprintTest do
  @moduledoc """
  ELZ-046 negative controls for `Mix.Tasks.Compile.Cure`.

  Each scenario runs the real compiler inside a throwaway Mix project with one
  Cure source. The project carries a unique module name so nothing collides
  with the root application's BEAMs. These are tests over the listed scenarios,
  not a proof that every possible input is fingerprinted.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  setup do
    tag = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "elzoo-cure-fingerprint-#{tag}")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "cure"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule ElzooCureFingerprintFixture#{tag}.MixProject do
      use Mix.Project

      def project do
        [app: :cure_fingerprint_fixture, version: "0.1.0", compilers: [:cure],
         cure_paths: ["cure"], deps: []]
      end
    end
    """)

    source = Path.join(dir, "cure/fixture.cure")

    File.write!(source, """
    mod Elzoo.FingerprintFixture#{tag}
      fn answer() -> Int = 42
    end
    """)

    module = :"Cure.Elzoo.FingerprintFixture#{tag}"
    ebin = Path.join(dir, "_build/#{Mix.env()}/lib/cure_fingerprint_fixture/ebin")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      :code.purge(module)
      :code.delete(module)
      :code.del_path(String.to_charlist(ebin))
      File.rm_rf!(dir)
    end)

    %{
      dir: dir,
      source: source,
      module: module,
      ebin: ebin,
      manifest: Path.join(ebin, "elzoo.cure.manifest")
    }
  end

  test "a second run with unchanged inputs skips; changed inputs recompile", ctx do
    assert compile(ctx) == :compiled
    assert File.regular?(Path.join(ctx.ebin, "#{ctx.module}.beam"))
    manifest = File.read!(ctx.manifest)
    assert manifest =~ ~r/^elzoo-cure-manifest 2\nfingerprint [0-9a-f]{64}\nmodule Cure\.Elzoo\./

    # Control: nothing changed, so the compiler must skip.
    assert compile(ctx) == :skipped
    assert File.read!(ctx.manifest) == manifest

    # Negative control 1: one edited source recompiles.
    File.write!(ctx.source, File.read!(ctx.source) <> "# touched\n")
    assert compile(ctx) == :compiled
    refute File.read!(ctx.manifest) == manifest
    assert compile(ctx) == :skipped

    # Negative control 2: a corrupted manifest recompiles.
    File.write!(ctx.manifest, "elzoo-cure-manifest 2\nfingerprint not-a-digest\n")
    assert compile(ctx) == :compiled
    assert compile(ctx) == :skipped

    # Negative control 3: a version-1 manifest (module names only) recompiles.
    File.write!(ctx.manifest, "#{ctx.module}\n")
    assert compile(ctx) == :compiled
    assert compile(ctx) == :skipped

    # Negative control 4: a missing BEAM recompiles even with a matching fingerprint.
    File.rm!(Path.join(ctx.ebin, "#{ctx.module}.beam"))
    assert compile(ctx) == :compiled
    assert File.regular?(Path.join(ctx.ebin, "#{ctx.module}.beam"))
  end

  test "a changed source-root list recompiles", ctx do
    assert compile(ctx) == :compiled
    assert compile(ctx) == :skipped

    File.mkdir_p!(Path.join(ctx.dir, "cure2"))
    assert compile(ctx, cure_paths: ["cure", "cure2"]) == :compiled
    assert compile(ctx, cure_paths: ["cure", "cure2"]) == :skipped
    assert compile(ctx) == :compiled
  end

  defp compile(ctx, post_config \\ []) do
    flush_shell()

    Mix.Project.in_project(:cure_fingerprint_fixture, ctx.dir, post_config, fn _module ->
      Mix.Task.rerun("compile.cure", [])
    end)

    messages = drain_shell([])
    compiled? = Enum.any?(messages, &String.starts_with?(&1, "Compiled "))
    skipped? = Enum.any?(messages, &String.starts_with?(&1, "Cure sources unchanged"))

    case {compiled?, skipped?} do
      {true, false} -> :compiled
      {false, true} -> :skipped
      other -> flunk("ambiguous compiler output #{inspect(other)}: #{inspect(messages)}")
    end
  end

  defp flush_shell, do: drain_shell([])

  defp drain_shell(acc) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_shell([msg | acc])
      {:mix_shell, _, _} -> drain_shell(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
