# SPDX-License-Identifier: Apache-2.0
binding = fn unit, id, direction, delivery ->
  %{
    "unit_id" => unit,
    "port" => %{
      "id" => id,
      "direction" => direction,
      "schema_id" => "count",
      "schema_version" => 1
    },
    "delivery" => delivery,
    "required_route" => true
  }
end

edge = fn placement, source, target ->
  %{
    "id" => "edge-1",
    "placement" => placement,
    "source" => %{"unit_id" => source["unit_id"], "port_id" => source["port"]["id"]},
    "target" => %{"unit_id" => target["unit_id"], "port_id" => target["port"]["id"]}
  }
end

fused_source = binding.("unit-a", "out", "output", "fused")
fused_target = binding.("unit-a", "in", "input", "fused")
hop_source = binding.("unit-a", "out", "output", "volatile")
hop_target = binding.("unit-b", "in", "input", "volatile")
cross_target = binding.("unit-b", "in", "input", "fused")
dangling = put_in(edge.("hop", hop_source, hop_target), ["source", "port_id"], "missing")

%{
  fused_inside_one_unit:
    Elzoo.Edge.connect(edge.("fused", fused_source, fused_target), fused_source, fused_target),
  hop_between_two_units:
    Elzoo.Edge.connect(edge.("hop", hop_source, hop_target), hop_source, hop_target),
  fused_between_two_units:
    Elzoo.Edge.connect(edge.("fused", fused_source, cross_target), fused_source, cross_target),
  source_reference_names_missing_port: Elzoo.Edge.connect(dangling, hop_source, hop_target),
  source_binding_with_fifth_key:
    Elzoo.Edge.connect(
      edge.("hop", hop_source, hop_target),
      Map.put(hop_source, "extra", 1),
      hop_target
    )
}
