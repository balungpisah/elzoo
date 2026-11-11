# SPDX-License-Identifier: Apache-2.0
for app <- [:elzoo, :req_llm, :ex_mcp] do
  unless :code.lib_dir(app) == {:error, :bad_name},
    do: raise("unexpected application available to dependency consumer: #{app}")
end

for module <- [Elzoo.Application, ReqLLM, ExMCP.Client] do
  if Code.ensure_loaded?(module), do: raise("root module leaked into dependency consumer")
end

for {app, version} <- [fuse: ~c"2.5.0", server_sent_events: ~c"1.1.0"] do
  unless Application.spec(app, :vsn) == version, do: raise("unexpected #{app} version")

  unless List.keymember?(Application.started_applications(), app, 0),
    do: raise("#{app} was not started by the dependency consumer")
end

name = {Elz099ProviderConsumer, make_ref()}

try do
  :ok = :fuse.install(name, {{:standard, 0, 1_000}, {:reset, 60_000}})
  :ok = :fuse.ask(name, :sync)
  :ok = :fuse.melt(name)
  :blown = :fuse.ask(name, :sync)
after
  :ok = :fuse.remove(name)
end

{[], parser} = ServerSentEvents.Parser.parse("data: par")
{[%{data: "parser"}], _} = ServerSentEvents.Parser.parse(parser, "ser\n\n")
IO.puts("ELZ-099 F4: independently built fuse=2.5.0 parser=1.1.0; Elzoo/ReqLLM/ExMCP absent")
IO.puts("ELZ-099 ISOLATED DEPENDENCY CONSUMER PASSED")
