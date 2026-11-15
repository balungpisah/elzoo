# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ReceiveLimitsTest do
  use ExUnit.Case, async: true

  # ELZ-218: `assert_receive` with no limit reads `assert_receive_timeout` (5,000 ms in
  # test/test_helper.exs); `refute_receive` with no limit keeps its own 100 ms default.
  describe "receive_limits" do
    test "receive_limits: assert_receive with no limit receives a message sent after 300 ms" do
      Process.send_after(self(), :late_for_assert, 300)

      assert_receive :late_for_assert
    end

    test "receive_limits: refute_receive with no limit returns before a message sent after 300 ms" do
      Process.send_after(self(), :late_for_refute, 300)

      refute_receive :late_for_refute

      # The message did arrive later, so the refute above was not vacuous.
      assert_receive :late_for_refute, 5_000
    end
  end

  describe "consumer_helper_text" do
    test "consumer_helper_text: both forms hold assert_receive_timeout and neither holds refute_receive_timeout" do
      for text <- [
            Elzoo.CureConsumerCase.consumer_test_helper({:ok, 60_000}),
            Elzoo.CureConsumerCase.consumer_test_helper(:error)
          ] do
        assert text =~ "assert_receive_timeout: 5_000"
        refute text =~ "refute_receive_timeout"
        assert text =~ "ExUnit.start(seed: 0"
      end
    end
  end
end
