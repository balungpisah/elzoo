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

other_schema = %{
  "id" => "threshold.count",
  "direction" => "input",
  "schema_id" => "example/money",
  "schema_version" => 1
}

other_version = %{
  "id" => "threshold.count",
  "direction" => "input",
  "schema_id" => "example/count",
  "schema_version" => 2
}

fifth_key = %{
  "id" => "counter.total",
  "direction" => "output",
  "schema_id" => "example/count",
  "schema_version" => 1,
  "delivery" => "durable"
}

%{
  compatible: Elzoo.Port.compatible(output, input),
  direction_mismatch: Elzoo.Port.compatible(input, input),
  schema_mismatch: Elzoo.Port.compatible(output, other_schema),
  version_mismatch: Elzoo.Port.compatible(output, other_version),
  invalid_source_shape: Elzoo.Port.compatible(fifth_key, input)
}
