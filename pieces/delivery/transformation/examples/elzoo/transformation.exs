# SPDX-License-Identifier: Apache-2.0
# Public calls of delivery/transformation: re-wrap a payload at an output Port.
# The test in test/elzoo/transformation_test.exs evaluates this file.

alias Elzoo.Transformation

source = %{
  "version" => 1,
  "message_id" => "source-1",
  "schema_id" => "example/order",
  "schema_version" => 1,
  "kind" => "event",
  "producer" => %{"unit_id" => "orders", "port_id" => "placed"},
  "correlation_id" => "request-1",
  "idempotency_key" => "dedup-1",
  "sequence" => 7,
  "payload" => %{"total" => 5}
}

output_port = %{
  "id" => "out",
  "direction" => "output",
  "schema_id" => "example/invoice",
  "schema_version" => 2
}

target = %{
  "unit_id" => "billing",
  "message_id" => "translated-1",
  "port" => output_port
}

fun = fn payload -> {:invoice, payload} end

%{
  translated: Transformation.translate(source, target, fun),
  implicit_correlation:
    Transformation.translate(Map.delete(source, "correlation_id"), target, fun),
  input_port:
    Transformation.translate(
      source,
      %{target | "port" => %{output_port | "direction" => "input"}},
      fun
    ),
  extra_key: Transformation.translate(source, Map.put(target, "extra", "x"), fun)
}
