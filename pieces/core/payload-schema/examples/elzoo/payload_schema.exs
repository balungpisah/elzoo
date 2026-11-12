# SPDX-License-Identifier: Apache-2.0
# Values only: no function, recipe, tool or model is executed.
schema = %{
  "type" => "object",
  "properties" => %{"count" => %{"type" => "integer"}},
  "required" => ["count"]
}

input = %{
  "id" => "count.argument",
  "direction" => "input",
  "schema_id" => "example/count",
  "schema_version" => 1
}

output = %{input | "id" => "count.result", "direction" => "output"}
{:ok, input_schema} = Elzoo.PayloadSchema.build(input, schema)
{:ok, output_schema} = Elzoo.PayloadSchema.build(output, schema)

%{
  module_function: Elzoo.PayloadSchema.check(input_schema, input, %{"count" => 1}),
  recipe_node:
    Elzoo.PayloadSchema.check(input_schema, %{input | "id" => "recipe.count"}, %{"count" => 2}),
  tool_argument:
    Elzoo.PayloadSchema.check(input_schema, %{input | "id" => "tool.count"}, %{"count" => 3}),
  model_output: Elzoo.PayloadSchema.check(output_schema, output, %{"count" => 4})
}
