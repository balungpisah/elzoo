# SPDX-License-Identifier: Apache-2.0
# Executable admission example; no network or implicit owner/queue is created.
defmodule Elzoo.HttpJob.ExampleBinding do
  use Elzoo.HttpJob.Binding,
    id: "example-publication",
    origin: "http://127.0.0.1:8999",
    recovery_grace_ms: 4000
end

{:ok, config} =
  Elzoo.HttpJob.configure(
    binding: Elzoo.HttpJob.ExampleBinding,
    origin: "http://127.0.0.1:8999",
    tenant: "example",
    queue: "publication",
    transport_supervisor: :example_transport,
    caller_supervisor: :example_calls,
    credentials: fn -> {:error, :preflight_unavailable} end,
    authenticate: fn _, _ -> :error end,
    resolve_intent: fn _ -> {:error, :not_started} end
  )

request = %{
  "capability_id" => "integration/http",
  "operation" => "publication",
  "classification" => "untrusted",
  "command" => %{
    "version" => 1,
    "message_id" => "message-1",
    "schema_id" => "elzoo/publication",
    "schema_version" => 1,
    "kind" => "command",
    "producer" => %{"unit_id" => "caller", "port_id" => "publish"},
    "idempotency_key" => "logical-1",
    "deadline_unix_ms" => 1000,
    "payload" => ~s({"version":1,"kind":"publication","text":"hello"})
  }
}

{:ok, admission} = Elzoo.HttpJob.admission(config, request)
true = byte_size(admission.key) == 64
true = admission.arguments == request["command"]["payload"]
:ok
