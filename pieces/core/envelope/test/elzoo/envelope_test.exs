# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EnvelopeTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/envelope.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp examples do
    {examples, _} = Code.eval_file(Path.expand("../../examples/shared.exs", __DIR__))
    examples
  end

  test "shared consumer examples round-trip with nil presence, reply address and attempt" do
    %{message: message, results: results, reply: reply} = examples()
    assert {:ok, record} = Elzoo.Envelope.decode(message)
    assert elem(record, 0) == :EnvelopeMessage
    assert Elzoo.Envelope.encode(record) == message
    assert {:ok, ^reply} = Elzoo.Envelope.validate(reply)

    for {_, result} <- results do
      assert {:ok, record} = Elzoo.Envelope.decode_result(result)
      assert Elzoo.Envelope.encode_result(record) == result
      assert result["message_id"] == message["message_id"]
      assert result["attempt_id"] == message["attempt_id"]
      assert result["deadline_unix_ms"] == message["deadline_unix_ms"]
    end

    refute reply["message_id"] == reply["payload"]["message_id"]
    assert reply["payload"]["value"] == nil

    assert {:error, :invalid_result_fields} =
             Elzoo.Envelope.decode_result(Map.delete(results["completed"], "value"))
  end

  test "missing required fields, unknown keys and malformed foreign types are rejected" do
    message = examples().message

    for field <- ~w(version message_id schema_id schema_version kind producer payload) do
      assert Elzoo.Envelope.decode(Map.delete(message, field)) == {:error, :invalid_shape}
    end

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(message, :payload, :secret),
          Map.put(message, "trace", %{"payload" => :secret}),
          Map.put(message, "schema_version", 1.0),
          Map.put(message, "kind", :event),
          Map.put(message, "message_id", <<255>>),
          Map.put(message, "producer", %{}),
          Map.put(message, "producer", Map.put(message["producer"], "pid", self())),
          Map.put(message, "reply_to", nil),
          Map.put(message, "reply_to", self()),
          Map.put(message, "reply_to", %{"unit_id" => "caller", "port_id" => <<255>>})
        ] do
      assert Elzoo.Envelope.decode(invalid) == {:error, :invalid_shape}
    end

    for field <-
          ~w(correlation_id causation_id idempotency_key trace_id attempt_id sequence deadline_unix_ms) do
      assert Elzoo.Envelope.decode(Map.put(message, field, nil)) == {:error, :invalid_shape}
    end
  end

  test "Cure rejects invalid contents without echoing sensitive values" do
    message = examples().message

    for {field, value, reason} <- [
          {"version", 2, :invalid_version},
          {"message_id", "", :invalid_message_id},
          {"schema_id", "", :invalid_schema_id},
          {"schema_version", 0, :invalid_schema_version},
          {"kind", "secret-invalid-kind", :invalid_kind},
          {"sequence", -1, :invalid_sequence},
          {"deadline_unix_ms", -1, :invalid_deadline},
          {"trace_id", "", :invalid_metadata},
          {"attempt_id", "", :invalid_attempt_id},
          {"producer", %{"unit_id" => "", "port_id" => "out"}, :invalid_producer},
          {"reply_to", %{"unit_id" => "caller", "port_id" => ""}, :invalid_reply_to}
        ] do
      assert Elzoo.Envelope.decode(Map.put(message, field, value)) == {:error, reason}
    end
  end

  test "optional fields can all be absent and no payload validation or clock decision occurs" do
    message = Map.drop(examples().message, ~w(correlation_id attempt_id reply_to deadline_unix_ms))

    for payload <- [nil, :opaque, self(), make_ref(), fn -> :opaque end, <<255>>] do
      candidate = Map.put(message, "payload", payload)
      assert {:ok, record} = Elzoo.Envelope.decode(candidate)
      assert Elzoo.Envelope.encode(record) == candidate
    end

    for deadline <- [0, 1, Integer.pow(10, 50)] do
      assert {:ok, _} = Elzoo.Envelope.decode(Map.put(message, "deadline_unix_ms", deadline))
    end
  end

  test "complete outcome/dispatch/error-label matrix rejects impossible combinations" do
    common = Map.take(examples().results["completed"], ~w(version message_id correlation_id))

    for outcome <- ~w(completed rejected failed timed_out unknown),
        dispatch <- ~w(dispatched not_dispatched unknown),
        label <- ~w(retryable permanent unavailable unclassified) do
      extra =
        if outcome == "completed",
          do: %{"value" => nil, "value_schema_id" => "example/value", "value_schema_version" => 1},
          else: %{"error_class" => label}

      result = Map.merge(common, Map.merge(extra, %{"outcome" => outcome, "dispatch" => dispatch}))

      legal =
        case outcome do
          "completed" -> dispatch == "dispatched"
          "rejected" -> dispatch == "not_dispatched"
          "failed" -> dispatch == "dispatched"
          "timed_out" -> true
          "unknown" -> dispatch != "not_dispatched"
        end

      if legal do
        assert {:ok, record} = Elzoo.Envelope.decode_result(result)
        assert Elzoo.Envelope.encode_result(record) == result
      else
        assert Elzoo.Envelope.decode_result(result) == {:error, :invalid_result_fields}
      end
    end
  end

  test "result shape, value schema and mutually exclusive fields have executable negatives" do
    completed = examples().results["completed"]
    rejected = examples().results["rejected"]

    for field <- ~w(version message_id correlation_id outcome dispatch) do
      assert Elzoo.Envelope.decode_result(Map.delete(completed, field)) == {:error, :invalid_shape}
    end

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(completed, "extra", :secret),
          Map.put(completed, "attempt_id", nil),
          Map.put(completed, "value_schema_version", "1"),
          Map.put(completed, "correlation_id", <<255>>)
        ] do
      assert Elzoo.Envelope.decode_result(invalid) == {:error, :invalid_shape}
    end

    for invalid <- [
          Map.put(completed, "error_class", "permanent"),
          Map.delete(completed, "value_schema_id"),
          Map.delete(completed, "value_schema_version"),
          Map.put(completed, "value_schema_id", ""),
          Map.put(completed, "value_schema_version", 0),
          Map.put(rejected, "value", nil),
          Map.put(rejected, "value_schema_id", "count"),
          Map.put(rejected, "value_schema_version", 1),
          Map.delete(rejected, "error_class"),
          Map.put(rejected, "error_class", "made_up")
        ] do
      assert Elzoo.Envelope.decode_result(invalid) == {:error, :invalid_result_fields}
    end

    assert Elzoo.Envelope.decode_result(Map.put(completed, "outcome", "success")) ==
             {:error, :invalid_outcome}
  end

  test "actual compiled Unicode record matches the measured translation ABI" do
    source = """
    mod Elzoo.EnvelopeExample
      use Std.Option
      use Elzoo.Envelope
      fn message() -> Elzoo.Envelope.EnvelopeMessage(Int) =
        EnvelopeMessage{version: 1, message_id: "résultat.合計", schema_id: "example/数量", schema_version: 1, kind: "event", producer_unit: "計算", producer_port: "out", payload: 5, reply_to: Some(ReplyEndpoint{unit_id: "caller", port_id: "in"}), attempt_id: Some("試行"), correlation_id: None(), causation_id: None(), idempotency_key: None(), trace_id: None(), sequence: Some(0), deadline_unix_ms: None()}
    end
    """

    assert {:ok, module} = Cure.Compiler.compile_and_load(source, source_roots: @roots)

    message = %{
      "version" => 1,
      "message_id" => "résultat.合計",
      "schema_id" => "example/数量",
      "schema_version" => 1,
      "kind" => "event",
      "producer" => %{"unit_id" => "計算", "port_id" => "out"},
      "payload" => 5,
      "reply_to" => %{"unit_id" => "caller", "port_id" => "in"},
      "attempt_id" => "試行",
      "sequence" => 0
    }

    assert {:ok, record} = Elzoo.Envelope.decode(message)
    assert apply(module, :message, []) == record
    assert Elzoo.Envelope.encode(record) == message

    assert apply(:"Cure.Elzoo.Envelope", :validate, [put_elem(record, 1, 2)]) ==
             {:error, :invalid_version}
  end

  test "source checks without owned foreign axioms, holes or unchecked totality" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)
    assert audit.unaudited == []
    assert audit.unresolved == []
    assert audit.holes == []
    assert audit.axioms == []
    assert audit.not_proven_total == []
    assert audit.absurd == 0
  end
end
