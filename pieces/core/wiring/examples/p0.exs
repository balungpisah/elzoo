# SPDX-License-Identifier: Apache-2.0
port = fn id, direction, schema ->
  %{"id" => id, "direction" => direction, "schema_id" => schema, "schema_version" => 1}
end

declaration = fn port, delivery, required ->
  %{"port" => port, "delivery" => delivery, "required_route" => required}
end

reference = fn unit, port -> %{"unit_id" => unit, "port_id" => port} end

edge = fn id, placement, source_unit, source_port, target_unit, target_port ->
  %{
    "id" => id,
    "placement" => placement,
    "source" => reference.(source_unit, source_port),
    "target" => reference.(target_unit, target_port)
  }
end

fused = %{
  "version" => 1,
  "units" => [
    %{
      "id" => "pipeline",
      "ports" => [
        declaration.(port.("ingest.accepted", "output", "example/ingest-message"), "fused", true),
        declaration.(port.("dedup.input", "input", "example/ingest-message"), "fused", true),
        declaration.(port.("dedup.accepted", "output", "example/count"), "fused", true),
        declaration.(port.("accumulate.input", "input", "example/count"), "fused", true)
      ]
    }
  ],
  "edges" => [
    edge.("ingest-dedup", "fused", "pipeline", "ingest.accepted", "pipeline", "dedup.input"),
    edge.("dedup-accumulate", "fused", "pipeline", "dedup.accepted", "pipeline", "accumulate.input")
  ]
}

hop = %{
  "version" => 1,
  "units" => [
    %{
      "id" => "ingest",
      "ports" => [
        declaration.(port.("accepted", "output", "example/ingest-message"), "volatile", true)
      ]
    },
    %{
      "id" => "dedup",
      "ports" => [declaration.(port.("input", "input", "example/ingest-message"), "volatile", true)]
    }
  ],
  "edges" => [edge.("ingest-dedup", "hop", "ingest", "accepted", "dedup", "input")]
}

{:ok, ^fused} = Elzoo.Wiring.validate(fused)
{:ok, ^hop} = Elzoo.Wiring.validate(hop)
%{fused: fused, hop: hop}
