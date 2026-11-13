# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{OutputRepair, PayloadSchema}

port = %{
  "id" => "answer",
  "direction" => "output",
  "schema_id" => "example/answer",
  "schema_version" => 1
}

schema = %{
  "type" => "object",
  "properties" => %{"answer" => %{"enum" => ["yes", "no"]}},
  "required" => ["answer"],
  "additionalProperties" => false
}

{:ok, checked} = PayloadSchema.build(port, schema)

# An answer outside the set, with one repair left.
invalid = %{
  content: ~s({"answer": "maybe"}),
  structured: {:invalid, :schema_mismatch},
  finish: :stop
}

{:repair, violations} = OutputRepair.decide(checked, port, invalid, 0, 1)

# The same output at the bound fails with the same violations.
{:fail, :invalid_at_bound, ^violations} = OutputRepair.decide(checked, port, invalid, 1, 1)

valid = %{content: ~s({"answer": "no"}), structured: {:valid, %{"answer" => "no"}}, finish: :stop}
{:accept, value} = OutputRepair.decide(checked, port, valid, 1, 1)

{OutputRepair.render(violations), value}
