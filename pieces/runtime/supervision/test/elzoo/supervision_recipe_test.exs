# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SupervisionRecipeTest do
  use ExUnit.Case, async: true

  test "OTP owns restart; volatile state resets under the selected child spec" do
    child = %{id: :counter, start: {Agent, :start_link, [fn -> 0 end]}}
    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)

    try do
      [{:counter, pid, _, _}] = Supervisor.which_children(supervisor)
      Agent.update(pid, &(&1 + 9))
      assert Agent.get(pid, & &1) == 9
      :ok = Supervisor.terminate_child(supervisor, :counter)
      {:ok, replacement} = Supervisor.restart_child(supervisor, :counter)
      assert Agent.get(replacement, & &1) == 0
    after
      Supervisor.stop(supervisor)
    end
  end
end
