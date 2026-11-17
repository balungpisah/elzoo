Code.require_file("support/wave4_channel.ex", __DIR__)

Application.ensure_all_started(:elzoo)

config = Application.fetch_env!(:elzoo, :wave4_channel_example)
profile = Keyword.fetch!(config, :profile)
host_options = Keyword.fetch!(config, :host)
native_options = Keyword.fetch!(host_options, :native)

host_options =
  Keyword.put(
    host_options,
    :native,
    Map.put_new(native_options, :engine, Elzoo.Wave4ChannelExample.NativeBindings.build(profile))
  )

{:ok, host} = Elzoo.Wave4ChannelExample.start_link(host_options)
Process.unlink(host)

webhook =
  config
  |> Keyword.fetch!(:webhook)
  |> Keyword.put(:admit, fn event, scope -> Elzoo.Wave4ChannelExample.admit(host, event, scope) end)

router_options = [
  host: host,
  conversation_id: profile.conversation_id,
  webhook: webhook,
  principal: Keyword.fetch!(config, :principal)
]

{:ok, listener} =
  Plug.Cowboy.http(
    Elzoo.Wave4ChannelExample.Router,
    router_options,
    port: Keyword.fetch!(config, :port)
  )

Process.unlink(listener)
Process.sleep(:infinity)
