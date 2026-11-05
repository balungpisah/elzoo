# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.StreamRecipeTest do
  use ExUnit.Case, async: true

  test "Enum maps finite data and Stream evaluates only the consumed prefix" do
    assert Enum.map([1, 2, 3], &(&1 * 2)) == [2, 4, 6]

    stream =
      Stream.map(1..100, fn value ->
        send(self(), {:visited, value})
        value * 2
      end)

    refute_received {:visited, _}
    assert stream |> Stream.take(2) |> Enum.to_list() == [2, 4]
    assert_received {:visited, 1}
    assert_received {:visited, 2}
    refute_received {:visited, 3}
    assert Enum.scan([2, 3, 4], 0, &+/2) == [2, 5, 9]
  end
end
