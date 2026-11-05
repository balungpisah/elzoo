# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.UnitTest do
  use ExUnit.Case, async: true

  defmodule Counter do
    def step(state, value), do: {:Transition, state + value, {:some, state + value}}
  end

  test "the OTP shell accepts an application-owned transition without an Elzoo host" do
    {:ok, unit} = Elzoo.Unit.start_link({Counter, :step, 0})

    try do
      assert Elzoo.Unit.step(unit, 4) == {:some, 4}
      assert Elzoo.Unit.step(unit, -1) == {:some, 3}
      assert Elzoo.Unit.snapshot(unit) == {Counter, :step, 3}
    after
      GenServer.stop(unit)
    end
  end
end
