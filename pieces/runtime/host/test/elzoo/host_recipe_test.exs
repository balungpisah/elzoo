# SPDX-License-Identifier: Apache-2.0
Code.require_file("../../examples/elzoo/host.exs", __DIR__)

defmodule Elzoo.HostRecipeTest do
  use ExUnit.Case, async: true

  def transition({seen, total} = state, {key, value}) do
    if key in seen do
      {:Transition, state, :none}
    else
      {:Transition, {[key | seen], total + value}, {:some, total + value}}
    end
  end

  test "consumer-owned host starts without Elzoo.Application and kill resets dedup state" do
    {:ok, sup} =
      Elzoo.IngestHost.start(:normal, [{:pipeline, {__MODULE__, :transition, {[], 0}}}])

    Process.unlink(sup)
    on_exit(fn -> Supervisor.stop(sup) end)
    pid = Elzoo.IngestHost.lookup(sup, :pipeline)
    assert is_pid(pid)
    assert Elzoo.IngestHost.lookup(sup, :absent) == :undefined
    message = {{1, 1, 1}, 10}
    assert Elzoo.Unit.step(pid, message) == {:some, 10}
    assert Elzoo.Unit.step(pid, message) == :none
    Process.exit(pid, :kill)
    replacement = replacement(sup, pid, 1000)
    assert replacement != pid
    assert Elzoo.Unit.snapshot(replacement) == {__MODULE__, :transition, {[], 0}}
    assert Elzoo.Unit.step(replacement, message) == {:some, 10}
    :ok = Supervisor.terminate_child(sup, :pipeline)
    assert Elzoo.IngestHost.lookup(sup, :pipeline) == :undefined
    {:ok, again} = Supervisor.restart_child(sup, :pipeline)
    assert Elzoo.IngestHost.lookup(sup, :pipeline) == again
  end

  defp replacement(_, _, 0), do: flunk("Unit did not restart")

  defp replacement(sup, old, attempts) do
    case Elzoo.IngestHost.lookup(sup, :pipeline) do
      pid when is_pid(pid) and pid != old -> pid
      value when value == old or value == :restarting -> replacement(sup, old, attempts - 1)
    end
  end
end
