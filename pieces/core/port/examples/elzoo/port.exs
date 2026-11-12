# SPDX-License-Identifier: Apache-2.0
output = %{
  "id" => "counter.total",
  "direction" => "output",
  "schema_id" => "example/count",
  "schema_version" => 1
}

input = %{
  "id" => "threshold.count",
  "direction" => "input",
  "schema_id" => "example/count",
  "schema_version" => 1
}

%{
  compatible: Elzoo.Port.compatible(output, input),
  direction_mismatch: Elzoo.Port.compatible(input, input),
  schema_mismatch:
    Elzoo.Port.compatible(output, Map.put(input, "schema_id", "example/money")),
  version_mismatch: Elzoo.Port.compatible(output, Map.put(input, "schema_version", 2)),
  invalid_source_shape: Elzoo.Port.compatible(Map.put(output, "delivery", "durable"), input)
}
