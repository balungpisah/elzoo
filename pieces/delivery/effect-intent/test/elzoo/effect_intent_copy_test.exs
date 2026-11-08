# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent.CopyTest do
  use ExUnit.Case, async: false
  @piece Path.expand("../..", __DIR__)
  test "byte-identical source closure and renamed modules/record tags run without catalogue Application" do
    dir = Path.join(System.tmp_dir!(), "elz023-copy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    groups = [
      {"core/envelope", ["cure/elzoo/envelope.cure", "lib/elzoo/envelope.ex"]},
      {"state/event-log",
       ["cure/elzoo/replay.cure", "lib/elzoo/durable_log.ex"] ++
         Enum.map(
           ~w(codec confirmation conformance memory store writer),
           &"lib/elzoo/durable_log/#{&1}.ex"
         )},
      {"state/checkpoint", ["lib/elzoo/checkpoint.ex"]},
      {"delivery/effect-intent",
       ["cure/elzoo/effect_intent.cure", "lib/elzoo/effect_intent.ex"] ++
         Enum.map(~w(binding host model policy), &"lib/elzoo/effect_intent/#{&1}.ex") ++
         ["examples/effect_intent.exs"]}
    ]

    for {piece, paths} <- groups, path <- paths do
      source = Path.join(@piece, path)

      source =
        if File.regular?(source),
          do: source,
          else: Path.expand("../../#{piece}/#{path}", @piece)

      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
      assert File.read!(source) == File.read!(target)
    end

    script = ~S"""
    {:ok, _} = Application.ensure_all_started(:cure)
    false = Code.ensure_loaded?(Elzoo.Application)
    cures = Path.wildcard("cure/**/*.cure")
    files = Path.wildcard("lib/**/*.ex")
    for path <- cures, do: ({:ok, _} = Cure.Compiler.compile_and_load(File.read!(path)))
    {:ok, _, []} = Kernel.ParallelCompiler.compile(files)
    {:ok, _} = Code.eval_file("examples/effect_intent.exs")
    tags = for path <- cures, [_, tag] <- Regex.scan(~r/^  rec (\w+)/m, File.read!(path)), do: tag
    rename = fn source ->
      source = String.replace(source, "Elzoo.", "Copied.")
      Enum.reduce(tags, source, fn tag, s -> Regex.replace(Regex.compile!("\\b" <> tag <> "\\b"), s, "Copy" <> tag) end)
    end
    for path <- cures, do: ({:ok, _} = Cure.Compiler.compile_and_load(rename.(File.read!(path))))
    renamed = for path <- files do
      p = "renamed/" <> path
      File.mkdir_p!(Path.dirname(p))
      File.write!(p, rename.(File.read!(path)))
      p
    end
    {:ok, _, []} = Kernel.ParallelCompiler.compile(renamed)
    {:ok, _} = Code.eval_string(rename.(File.read!("examples/effect_intent.exs")))
    false = Code.ensure_loaded?(Elzoo.Application)
    false = Enum.any?(Application.started_applications(), fn {a, _, _} -> a == :elzoo end)
    IO.puts("EFFECT_INTENT_COPY_OK original and renamed module/record tags")
    """

    File.write!(Path.join(dir, "run.exs"), script)

    closure = fn recurse, app, seen ->
      if MapSet.member?(seen, app),
        do: seen,
        else:
          (
            _ = Application.load(app)

            Enum.reduce(
              (Application.spec(app, :applications) || []) --
                (Application.spec(app, :optional_applications) || []),
              MapSet.put(seen, app),
              fn dep, acc -> recurse.(recurse, dep, acc) end
            )
          )
    end

    apps = closure.(closure, :cure, MapSet.new())
    refute MapSet.member?(apps, :elzoo)
    args = Enum.flat_map(apps, &["-pa", Application.app_dir(&1, "ebin")]) ++ ["run.exs"]

    {output, exit} =
      System.cmd(System.find_executable("elixir"), args,
        cd: dir,
        stderr_to_stdout: true,
        env: [
          {"LANG", "en_US.UTF-8"},
          {"LC_ALL", "en_US.UTF-8"},
          {"ERL_FLAGS", "+S 4:4 +SDcpu 1 +SDio 1"}
        ]
      )

    assert exit == 0, output
    assert output =~ "EFFECT_INTENT_COPY_OK"
  end
end
