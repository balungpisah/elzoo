# SPDX-License-Identifier: Apache-2.0
Mix.start()

Mix.Project.in_project(:observability_consumer, ".", fn _ ->
  Application.put_env(:prometheus, :global_labels, [])
  Mix.Task.run("compile", ["--warnings-as-errors"])
  {:ok, _} = Application.ensure_all_started(:observability_consumer)
  false = Code.ensure_loaded?(Elzoo.Application)
  false = Code.ensure_loaded?(Elzoo.Registry)
  nil = Application.spec(:elzoo)
  ~c"6.1.3" = Application.spec(:prometheus, :vsn)
  ~c"0.4.3" = Application.spec(:ddskerl, :vsn)
  ~c"1.4.2" = Application.spec(:telemetry, :vsn)

  Mix.Task.run("test", [
    "--no-start",
    "--warnings-as-errors",
    "test/elzoo/observability_test.exs",
    "test/elzoo/telemetry_test.exs"
  ])

  IO.puts("OBSERVABILITY_COPIED_CONSUMER_PASSED")
end)
