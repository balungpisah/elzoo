# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcessMappingTest do
  @moduledoc "Every Adapter result row maps to a validated core/envelope delivery result with the sidecar."
  use ExUnit.Case, async: true
  alias Elzoo.OsProcess.Result

  @request %{"message_id" => "m-1", "attempt_id" => "a-1", "deadline_unix_ms" => 1_700_000_000_000}

  defp rows do
    [
      {Result.completed(7, "out", false, :none, 100), "completed", "dispatched", nil},
      {Result.rejected(:queue_full), "rejected", "not_dispatched", "unavailable"},
      {Result.rejected(:queue_timeout), "rejected", "not_dispatched", "unavailable"},
      {Result.rejected(:spawn_failed), "rejected", "not_dispatched", "permanent"},
      {Result.rejected(:cancelled), "rejected", "not_dispatched", "permanent"},
      {Result.expired(%{deadline_unix_ms: 1}), "timed_out", "not_dispatched", "unclassified"},
      {Result.terminated(:kill, :sigkill, "", false, 100), "timed_out", "dispatched",
       "unclassified"},
      {Result.unknown(:provider_masked_stop, %{cause: :cancel}), "unknown", "dispatched",
       "unclassified"},
      {Result.unknown(:group_alive, %{members: [1, 2]}), "unknown", "dispatched", "unclassified"}
    ]
  end

  test "each row validates through Elzoo.Envelope.validate_result/1 and returns the sidecar unchanged" do
    for {result, outcome, dispatch, class} <- rows() do
      assert {:ok, map, ^result} = Result.to_delivery_result(result, @request)
      assert {:ok, _} = Elzoo.Envelope.validate_result(map)
      assert map["outcome"] == outcome and map["dispatch"] == dispatch
      assert map["message_id"] == "m-1" and map["correlation_id"] == "m-1"
      assert map["attempt_id"] == "a-1" and map["deadline_unix_ms"] == 1_700_000_000_000

      if class do
        assert map["error_class"] == class
        refute Map.has_key?(map, "value")
      else
        assert map["value"] == %{"exit_code" => 7, "output" => "out", "truncated" => false}

        assert map["value_schema_id"] == "elzoo/os-process-completed" and
                 map["value_schema_version"] == 1

        refute Map.has_key?(map, "error_class")
      end

      refute Map.has_key?(map, "stage")
    end
  end

  test "correlation_id is echoed when present and falls back to the message id otherwise" do
    {:ok, map, _} =
      Result.to_delivery_result(Result.rejected(:queue_full), %{
        "message_id" => "m",
        "correlation_id" => "c"
      })

    assert map["correlation_id"] == "c"
    {:ok, map, _} = Result.to_delivery_result(Result.rejected(:queue_full), %{"message_id" => "m"})
    assert map["correlation_id"] == "m"

    assert {:error, :missing_message_id} =
             Result.to_delivery_result(Result.rejected(:queue_full), %{})
  end

  test "wait status decoding follows wait(2): exit code in the high byte, signal in the low 7 bits" do
    assert {:exit, 7} = Result.decode_wait_status(1792)
    assert {:exit, 0} = Result.decode_wait_status(0)
    assert {:signal, 15} = Result.decode_wait_status(15)
    assert {:signal, 9} = Result.decode_wait_status(9)
  end
end
