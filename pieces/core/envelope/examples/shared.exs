# SPDX-License-Identifier: Apache-2.0
# ELZ-006 and ELZ-007 import these same maps, not private result extensions.
message = %{
  "version" => 1,
  "message_id" => "delivery-1",
  "schema_id" => "example/ingest-message",
  "schema_version" => 1,
  "kind" => "command",
  "producer" => %{"unit_id" => "pipeline", "port_id" => "ingest.accepted"},
  "correlation_id" => "request-1",
  "attempt_id" => "attempt-1",
  "reply_to" => %{"unit_id" => "caller", "port_id" => "result"},
  "deadline_unix_ms" => 1_800_000_000_000,
  "payload" => {:Message, "producer", "incarnation", 1, 5}
}

common = %{
  "version" => 1,
  "message_id" => message["message_id"],
  "correlation_id" => message["correlation_id"],
  "attempt_id" => message["attempt_id"],
  "deadline_unix_ms" => message["deadline_unix_ms"]
}

results = %{
  "completed" =>
    Map.merge(common, %{
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => nil,
      "value_schema_id" => "example/optional-count",
      "value_schema_version" => 1
    }),
  "rejected" =>
    Map.merge(common, %{
      "outcome" => "rejected",
      "dispatch" => "not_dispatched",
      "error_class" => "permanent"
    }),
  "timeout_before_dispatch" =>
    Map.merge(common, %{
      "outcome" => "timed_out",
      "dispatch" => "not_dispatched",
      "error_class" => "unavailable"
    }),
  "timeout_after_dispatch" =>
    Map.merge(common, %{
      "outcome" => "timed_out",
      "dispatch" => "dispatched",
      "error_class" => "unclassified"
    }),
  "timeout_unknown_dispatch" =>
    Map.merge(common, %{
      "outcome" => "timed_out",
      "dispatch" => "unknown",
      "error_class" => "unclassified"
    }),
  "failed" =>
    Map.merge(common, %{
      "outcome" => "failed",
      "dispatch" => "dispatched",
      "error_class" => "permanent"
    }),
  "lost_observation" =>
    Map.merge(common, %{
      "outcome" => "unknown",
      "dispatch" => "unknown",
      "error_class" => "unclassified"
    })
}

{:ok, ^message} = Elzoo.Envelope.validate(message)
Enum.each(results, fn {_, result} -> {:ok, ^result} = Elzoo.Envelope.validate_result(result) end)

reply = %{
  "version" => 1,
  "message_id" => "reply-1",
  "kind" => "reply",
  "schema_id" => "elzoo/delivery-result",
  "schema_version" => 1,
  "producer" => %{"unit_id" => "pipeline", "port_id" => "result"},
  "correlation_id" => message["correlation_id"],
  "causation_id" => message["message_id"],
  "attempt_id" => message["attempt_id"],
  "payload" => results["completed"]
}

{:ok, ^reply} = Elzoo.Envelope.validate(reply)
%{message: message, results: results, reply: reply}
