# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.IdempotencyTest do
  use ExUnit.Case, async: true
  @receiver :"Cure.Elzoo.Idempotency"

  test "exact-key duplicates drop, but a new incarnation is fresh" do
    first = apply(@receiver, :message, [1, 1, 9, 7])
    duplicate = apply(@receiver, :message, [1, 1, 9, 999])
    restarted = apply(@receiver, :message, [1, 2, 9, 7])
    assert {:Transition, history, {:some, ^first}} = apply(@receiver, :receiver, [[], first])
    assert {:Transition, ^history, :none} = apply(@receiver, :receiver, [history, duplicate])

    assert {:Transition, next, {:some, ^restarted}} =
             apply(@receiver, :receiver, [history, restarted])

    assert length(next) == 2
  end
end
