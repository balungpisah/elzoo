# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CompositionTest do
  use ExUnit.Case, async: true

  test "a dropped input never invokes or advances the downstream operator" do
    first = fn state -> fn _input -> {:Transition, state + 1, :none} end end
    second = fn _ -> fn _ -> flunk("downstream invoked after a drop") end end

    assert apply(:"Cure.Elzoo.Composition", :compose, [first, second, {:Joined, 0, 42}, :input]) ==
             {:Transition, {:Joined, 1, 42}, :none}
  end

  test "compatible stateful functions compose through the same transition" do
    first = fn state -> fn input -> {:Transition, state + 1, {:some, input * 2}} end end
    second = fn state -> fn input -> {:Transition, state + input, {:some, state + input}} end end

    assert apply(:"Cure.Elzoo.Composition", :compose, [first, second, {:Joined, 0, 10}, 3]) ==
             {:Transition, {:Joined, 1, 16}, {:some, 16}}
  end
end
