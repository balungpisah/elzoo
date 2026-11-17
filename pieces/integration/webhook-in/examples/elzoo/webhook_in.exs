source_id = "demo-source"
key = :binary.copy(<<42>>, 32)
timestamp = Integer.to_string(System.system_time(:second))

event = %{
  "version" => 1,
  "event_id" => "demo-event-1",
  "conversation_id" => "demo-conversation",
  "input_id" => "demo-input-1",
  "expected_revision" => 0,
  "text" => "hello"
}

body = Jason.encode!(event)

mac_input =
  "elzoo-webhook-v1\n" <>
    source_id <>
    "\nPOST\n/elzoo/v1/messages\n" <>
    timestamp <>
    "\n" <>
    body

signature = "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, key, mac_input), case: :lower)

conn =
  Plug.Test.conn("POST", "/elzoo/v1/messages", body)
  |> Plug.Conn.put_req_header("content-type", "application/json")
  |> Plug.Conn.put_req_header("x-elzoo-timestamp", timestamp)
  |> Plug.Conn.put_req_header("x-elzoo-signature", signature)

config =
  Elzoo.WebhookIn.init(
    source_id: source_id,
    key: fn -> {:ok, key} end,
    clock: fn -> String.to_integer(timestamp) end,
    principal: fn _conn ->
      {:ok, %{tenant: "demo-tenant", actor: "demo-actor", resources: ["demo-conversation"]}}
    end,
    admit: fn _event, _scope -> {:pending, :approval} end
  )

conn = Elzoo.WebhookIn.call(conn, config)
IO.puts(conn.resp_body)
