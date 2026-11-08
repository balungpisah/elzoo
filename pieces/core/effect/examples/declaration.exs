# SPDX-License-Identifier: Apache-2.0
request = %{
  "capability_id" => "integration/http",
  "operation" => "publication",
  "classification" => "untrusted",
  "command" => %{
    "version" => 1,
    "message_id" => "m",
    "schema_id" => "elzoo/publication",
    "schema_version" => 1,
    "kind" => "command",
    "producer" => %{"unit_id" => "caller", "port_id" => "publish"},
    "idempotency_key" => "logical-1",
    "deadline_unix_ms" => 1000,
    "payload" => ~s({"version":1,"kind":"publication","text":"hello"})
  }
}

{:ok, record} = Elzoo.Effect.decode(request)
^request = Elzoo.Effect.encode(record)
true = Elzoo.Effect.declared?(request, ["integration/http"])
request
