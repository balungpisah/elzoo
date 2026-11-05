defmodule Elzoo.TransformationCorrelationTest do
  use ExUnit.Case, async: false

  test "effective conversation correlation survives a new message ID with or without an explicit source correlation" do
    {%{message: message}, _} = Code.eval_file("pieces/core/envelope/examples/shared.exs")

    target = %{
      "unit_id" => "translated",
      "message_id" => "t-1",
      "port" => %{"id" => "out", "direction" => "output", "schema_id" => "x", "schema_version" => 1}
    }

    for source <- [message, Map.delete(message, "correlation_id")] do
      assert {:ok, translated} = Elzoo.Transformation.translate(source, target, & &1)
      assert translated["correlation_id"] == Map.get(source, "correlation_id", source["message_id"])

      assert Elzoo.RequestReply.expected_correlation(translated) ==
               Elzoo.RequestReply.expected_correlation(source)
    end
  end
end
