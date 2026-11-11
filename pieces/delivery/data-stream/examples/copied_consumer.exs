# SPDX-License-Identifier: Apache-2.0
# Launched by the Piece's copy test with ONLY selected upstream code paths.
Mix.start()

Mix.Project.in_project(:data_stream_consumer, ".", fn _ ->
  Mix.Task.run("compile", ["--warnings-as-errors"])
  {:ok, _} = Application.ensure_all_started(:data_stream_consumer)

  for module <- [
        Elzoo.Application,
        Elzoo.Registry,
        Elzoo.CureConsumerCase,
        ReqLLM,
        Elzoo.AiText.Anthropic,
        Elzoo.AiText.OpenAI,
        Elzoo.AiText
      ] do
    false = Code.ensure_loaded?(module)
  end

  for app <- [:elzoo, :req_llm, :fuse, :ex_mcp], do: false = Application.spec(app) != nil
  true = is_pid(Process.whereis(Req.Finch))
  {:ok, modules} = :application.get_key(:data_stream_consumer, :modules)
  true = :"Cure.Elzoo.Backpressure" in modules
  true = :"Cure.Elzoo.EffectIntentPolicy" in modules
  true = Application.spec(:server_sent_events, :vsn) == ~c"1.1.0"
  true = Application.spec(:req, :vsn) == ~c"0.7.5"
  true = Application.spec(:jason, :vsn) == ~c"1.4.5"

  Mix.Task.run("test", [
    "--no-start",
    "--warnings-as-errors",
    "test/elzoo/data_stream_protocol_test.exs",
    "test/elzoo/data_stream_schema_test.exs",
    "test/elzoo/data_stream_owner_test.exs",
    "test/elzoo/data_stream_store_test.exs",
    "test/elzoo/data_stream_postgres_test.exs",
    "test/elzoo/data_stream_bounds_test.exs",
    "test/elzoo/data_stream_mutation_test.exs"
  ])

  IO.puts("DATA_STREAM_COPIED_CONSUMER_PASSED")
end)
