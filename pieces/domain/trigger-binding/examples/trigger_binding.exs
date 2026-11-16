# SPDX-License-Identifier: Apache-2.0
declaration = %{
  "version" => 1,
  "id" => "orders-webhook",
  "revision" => 4,
  "tenant" => "shop-17",
  "source" => "orders-webhook",
  "schema_id" => "order.created",
  "schema_version" => 1,
  "enabled" => true,
  "target" => %{
    "bot_ref" => "bot:order-assistant",
    "package_digest" => String.duplicate("a", 64),
    "callable" => "handle_order"
  }
}

host_scope = %{tenant: "shop-17", source: "orders-webhook"}
event_schema = %{"schema_id" => "order.created", "schema_version" => 1}

IO.inspect(Elzoo.TriggerBinding.validate_declaration(declaration))
IO.inspect(Elzoo.TriggerBinding.select([declaration], host_scope, event_schema))
IO.inspect(Elzoo.TriggerBinding.select([], host_scope, event_schema))
