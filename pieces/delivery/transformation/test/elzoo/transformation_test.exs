# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TransformationTest do
  use ExUnit.Case, async: false
  alias Elzoo.Transformation

  defp fixture do
    local = Path.expand("../../../../core/envelope/examples/shared.exs", __DIR__)

    {%{message: message}, _} =
      Code.eval_file(if(File.exists?(local), do: local, else: "examples/shared.exs"))

    target = %{
      "unit_id" => "translated",
      "message_id" => "translated-1",
      "port" => %{
        "id" => "out",
        "direction" => "output",
        "schema_id" => "example/new",
        "schema_version" => 2
      }
    }

    {message, target}
  end

  test "re-wraps payload and producer while preserving all intrinsic identity metadata except sequence" do
    {message, target} = fixture()

    message =
      Map.merge(message, %{
        "idempotency_key" => "dedup",
        "trace_id" => "trace",
        "sequence" => 3,
        "causation_id" => "old"
      })

    assert {:ok, translated} = Transformation.translate(message, target, &{:translated, &1})
    assert translated["payload"] == {:translated, message["payload"]}
    assert translated["message_id"] == target["message_id"]

    assert translated["producer"] == %{
             "unit_id" => target["unit_id"],
             "port_id" => target["port"]["id"]
           }

    assert translated["schema_id"] == target["port"]["schema_id"]
    assert translated["schema_version"] == target["port"]["schema_version"]
    assert translated["causation_id"] == message["message_id"]

    for key <-
          ~w(version kind correlation_id trace_id attempt_id reply_to deadline_unix_ms idempotency_key) do
      assert translated[key] == message[key]
    end

    refute Map.has_key?(translated, "sequence")
    assert Elzoo.Envelope.validate(translated) == {:ok, translated}
  end

  test "translation makes implicit correlation explicit and preserves explicit correlation" do
    {message, target} = fixture()

    for source <- [message, Map.delete(message, "correlation_id")] do
      assert {:ok, translated} = Transformation.translate(source, target, & &1)
      assert translated["correlation_id"] == Map.get(source, "correlation_id", source["message_id"])
      refute translated["message_id"] == source["message_id"]
    end
  end

  test "other absent metadata stays absent, payload is opaque, deadline is never evaluated" do
    {message, target} = fixture()

    message =
      Map.drop(
        message,
        ~w(correlation_id trace_id attempt_id reply_to deadline_unix_ms idempotency_key)
      )

    for payload <- [nil, %{}, [], :opaque, <<255>>],
        kind <- ~w(command event reply error control) do
      source = message |> Map.put("payload", payload) |> Map.put("kind", kind)
      assert {:ok, translated} = Transformation.translate(source, target, & &1)
      assert translated["payload"] == payload
      assert translated["kind"] == kind
      assert translated["correlation_id"] == source["message_id"]

      for key <-
            ~w(trace_id attempt_id reply_to deadline_unix_ms idempotency_key sequence),
          do: refute(Map.has_key?(translated, key))
    end

    for deadline <- [0, 1, Integer.pow(10, 50)] do
      assert {:ok, translated} =
               Transformation.translate(
                 Map.put(message, "deadline_unix_ms", deadline),
                 target,
                 fn _ -> nil end
               )

      assert translated["deadline_unix_ms"] == deadline
    end
  end

  test "envelope then exact target shape then output descriptor; invalid inputs never invoke callback" do
    {message, target} = fixture()
    never = fn _ -> flunk("callback must not run for invalid input") end
    assert Transformation.translate(nil, nil, never) == {:error, {:envelope, :invalid_shape}}

    assert Transformation.translate(Map.put(message, "version", 2), nil, never) ==
             {:error, {:envelope, :invalid_version}}

    for invalid <- [
          nil,
          %{},
          Map.put(target, "extra", true),
          Map.delete(target, "message_id"),
          Map.put(target, "unit_id", ""),
          Map.put(target, "message_id", <<255>>),
          Map.put(target, "message_id", ""),
          Map.put(target, "port", nil)
        ] do
      assert Transformation.translate(message, invalid, never) ==
               {:error, {:target, :invalid_shape}}
    end

    for {field, value, reason} <- [
          {"id", "", :invalid_id},
          {"direction", "bad", :invalid_direction},
          {"direction", "input", :invalid_direction},
          {"schema_id", "", :invalid_schema_id},
          {"schema_version", 0, :invalid_schema_version}
        ] do
      assert Transformation.translate(message, put_in(target, ["port", field], value), never) ==
               {:error, {:target, reason}}
    end
  end

  test "callback exceptions propagate unchanged and Enum/Stream perform ordinary batch work" do
    {message, target} = fixture()

    assert_raise ArgumentError, "callback failed", fn ->
      Transformation.translate(message, target, fn _ -> raise ArgumentError, "callback failed" end)
    end

    assert catch_throw(
             Transformation.translate(message, target, fn _ -> throw(:caller_failure) end)
           ) == :caller_failure

    assert [{:ok, translated}] =
             [message]
             |> Stream.map(&Transformation.translate(&1, target, fn _ -> nil end))
             |> Enum.to_list()

    assert translated["payload"] == nil
    assert Enum.map([], &Transformation.translate(&1, target, fn _ -> nil end)) == []
  end

  test "the bundled example shows the public calls and its values stay exact" do
    {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/transformation.exs", __DIR__))

    assert Enum.sort(Map.keys(result)) ==
             [:extra_key, :implicit_correlation, :input_port, :translated]

    assert result.translated ==
             {:ok,
              %{
                "version" => 1,
                "message_id" => "translated-1",
                "schema_id" => "example/invoice",
                "schema_version" => 2,
                "kind" => "event",
                "producer" => %{"unit_id" => "billing", "port_id" => "out"},
                "correlation_id" => "request-1",
                "causation_id" => "source-1",
                "idempotency_key" => "dedup-1",
                "payload" => {:invoice, %{"total" => 5}}
              }}

    assert {:ok, implicit} = result.implicit_correlation
    assert implicit["correlation_id"] == "source-1"
    assert implicit["causation_id"] == "source-1"
    assert result.input_port == {:error, {:target, :invalid_direction}}
    assert result.extra_key == {:error, {:target, :invalid_shape}}
  end
end
