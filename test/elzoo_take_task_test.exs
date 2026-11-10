defmodule Elzoo.TakeTaskTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    destination = Elzoo.CureConsumerCase.create_destination!()
    File.write!(Path.join(destination, "mix.exs"), "# destination project\n")
    on_exit(fn -> File.rm_rf!(destination) end)
    {:ok, destination: destination}
  end

  test "Mix command writes the exact planned export", %{destination: destination} do
    plan = Elzoo.Export.plan!(Elzoo.Registry.load!(), ["core/envelope"], destination)
    capture_io(fn -> Mix.Task.rerun("elzoo.take", ["core/envelope", "--to", destination]) end)

    for {path, bytes} <- plan.files do
      assert File.read!(Path.join(destination, path)) == bytes
    end
  end

  test "dry run succeeds without writing", %{destination: destination} do
    output =
      capture_io(fn ->
        Mix.Task.rerun("elzoo.take", ["core/envelope", "--to", destination, "--dry-run"])
      end)

    assert output =~ "Dry run; no files written"

    for path <- ["lib", "test", "licenses", ".elzoo"] do
      refute File.exists?(Path.join(destination, path))
    end
  end

  test "original exception and source location survive the rescue", %{destination: destination} do
    File.rm!(Path.join(destination, "mix.exs"))

    error =
      assert_raise Mix.Error, fn ->
        Mix.Task.rerun("elzoo.take", ["core/envelope", "--to", destination])
      end

    assert error.message =~ "ArgumentError"
    assert error.message =~ "destination must contain mix.exs"
    assert error.message =~ "Elzoo.Export.plan!/3"
  end

  test "missing destination reports usage" do
    assert_raise Mix.Error, ~r/usage: mix elzoo.take/, fn ->
      Mix.Task.rerun("elzoo.take", ["core/envelope"])
    end
  end

  test "concurrent consumer destinations are distinct and exclusively created" do
    paths =
      1..32
      |> Task.async_stream(fn _ -> Elzoo.CureConsumerCase.create_destination!() end)
      |> Enum.map(fn {:ok, path} -> path end)

    on_exit(fn -> Enum.each(paths, &File.rm_rf!/1) end)
    assert length(Enum.uniq(paths)) == 32

    for path <- paths do
      assert File.dir?(path)
      assert File.mkdir(path) == {:error, :eexist}
    end
  end
end
