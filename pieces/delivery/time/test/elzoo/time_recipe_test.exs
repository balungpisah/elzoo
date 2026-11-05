# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TimeRecipeTest do
  use ExUnit.Case, async: true

  test "OTP supplies timer messages and cancellable timer references" do
    token = make_ref()
    Process.send_after(self(), {:elapsed, token}, 0)
    assert_receive {:elapsed, ^token}, 1000
    timer = Process.send_after(self(), :cancelled_timer, 60_000)
    assert is_integer(Process.cancel_timer(timer))
    refute_received :cancelled_timer
    assert is_integer(System.monotonic_time(:millisecond))
  end
end
