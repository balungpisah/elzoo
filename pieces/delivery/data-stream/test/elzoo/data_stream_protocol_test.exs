# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.ProtocolTest do
  use ExUnit.Case, async: true
  alias Elzoo.DataStream.{JSON, Framer, Protocol}

  test "duplicates at every depth are rejected before constructing maps" do
    for value <- [~s({"a":1,"a":2}), ~s({"a":{"x":1,"\\u0078":2}}), ~s([{"a":1,"a":2}])] do
      assert {:error, :invalid_json} = JSON.decode(value)
    end

    for value <- [
          "1.0",
          "1e2",
          "92233720368547758080",
          String.duplicate("[", 17) <> "0" <> String.duplicate("]", 17)
        ] do
      assert {:error, :invalid_json} = JSON.decode(value)
    end

    assert {:ok, %{"text" => "1.0 [ { \\\"", "n" => 5}} =
             JSON.decode(~s({"text":"1.0 [ { \\\\\\"","n":5}))
  end

  test "raw comment ceiling counts separators, including a split CRLF" do
    block = ":" <> String.duplicate("x", 65_531) <> "\r\n\r\n"
    assert byte_size(block) == 65_536
    assert {:ok, f, 1} = Framer.feed(Framer.new(), block, 0, fn _, n -> {:ok, n + 1} end)
    assert f.blocks == 1

    assert {:error, :block_limit, _, _} =
             Framer.feed(Framer.new(), ":x" <> binary_part(block, 1, byte_size(block) - 1), 0, fn _,
                                                                                                  n ->
               {:ok, n + 1}
             end)

    part = binary_part(block, 0, byte_size(block) - 1)
    assert {:ok, f, 0} = Framer.feed(Framer.new(), part, 0, fn _, n -> {:ok, n + 1} end)
    assert {:ok, _, 1} = Framer.feed(f, "\n", 0, fn _, n -> {:ok, n + 1} end)
  end

  test "whole blocks are delivered one at a time and stop discards suffix" do
    callback = fn b, acc -> if b == "stop\n\n", do: {:halt, [b | acc]}, else: {:ok, [b | acc]} end

    assert {:halt, f, ["stop\n\n", "one\n\n"]} =
             Framer.feed(Framer.new(), "one\n\nstop\n\nignored\n\n", [], callback)

    assert f.blocks == 2

    assert {:error, :block_limit, _, _} =
             Framer.feed(Framer.new(), String.duplicate(":", 65_537), [], callback)
  end

  test "split BOM and CR LF framing agrees at every split" do
    bytes = <<239, 187, 191>> <> "event: ping\rdata: {\"type\":\"ping\"}\r\n\r\n"

    for n <- 0..byte_size(bytes) do
      <<a::binary-size(^n), b::binary>> = bytes
      cb = fn block, acc -> {:ok, [block | acc]} end
      assert {:ok, f, acc} = Framer.feed(Framer.new(), a, [], cb)
      assert {:ok, f, [^bytes]} = Framer.feed(f, b, acc, cb)
      assert {:ok, _, _} = Framer.eof(f, [bytes], cb)
    end

    assert {:ok, f, []} = Framer.feed(Framer.new(), <<239, 187>>, [], fn _, x -> {:ok, x} end)
    assert {:error, :malformed_response, _, _} = Framer.eof(f, [], fn _, x -> {:ok, x} end)
  end

  test "source stop freezes final provider usage even when downstream delivery later fails" do
    s = Protocol.new("claude-test", :absent)

    {:ok, s, :none} =
      Protocol.event(s, "message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-test",
          "content" => [],
          "stop_reason" => nil,
          "stop_sequence" => nil,
          "usage" => %{"output_tokens" => 2}
        }
      })

    {:ok, s, :none} =
      Protocol.event(s, "message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 5}
      })

    assert s.incurred_usage == :unknown
    assert Elzoo.AiModel.Usage.amount(s.last_usage.usage, :output_tokens) == 5
    {:ok, s, :stop} = Protocol.event(s, "message_stop", %{"type" => "message_stop"})
    assert {:provider_reported, usage} = s.incurred_usage
    assert Elzoo.AiModel.Usage.amount(usage, :output_tokens) == 5
  end
end
