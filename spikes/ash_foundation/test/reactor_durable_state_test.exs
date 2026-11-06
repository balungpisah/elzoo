# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.RestartProbe do
  use Reactor
  input(:observer)
  input(:block?)

  step :prepare do
    argument(:observer, input(:observer))

    run(fn %{observer: observer}, _ ->
      token = System.unique_integer([:positive, :monotonic])
      send(observer, {:prepared, token})
      {:ok, token}
    end)
  end

  step :blocked do
    argument(:observer, input(:observer))
    argument(:block?, input(:block?))
    argument(:prepared, result(:prepare))

    run(fn %{observer: observer, block?: block?, prepared: token}, _ ->
      send(observer, {:entered, token, self()})

      if block?,
        do:
          (receive do
             :continue -> :ok
           end)

      {:ok, token}
    end)
  end

  return(:blocked)
end

defmodule ElzooAshSpike.ReactorDurableStateTest do
  use ExUnit.Case, async: false

  test "killing a running step leaves no persisted progress for a fresh Reactor run" do
    observer = self()

    {runner, monitor} =
      spawn_monitor(fn ->
        Reactor.run(ElzooAshSpike.RestartProbe, %{observer: observer, block?: true}, %{},
          async?: false
        )
      end)

    on_exit(fn -> if Process.alive?(runner), do: Process.exit(runner, :kill) end)
    assert_receive {:prepared, first}, 5_000
    assert_receive {:entered, ^first, ^runner}, 5_000
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}

    assert {:ok, second} =
             Reactor.run(ElzooAshSpike.RestartProbe, %{observer: observer, block?: false}, %{},
               async?: false
             )

    assert_receive {:prepared, ^second}
    assert_receive {:entered, ^second, _}
    refute first == second

    IO.puts(
      "Reactor #{Application.spec(:reactor, :vsn)}: completed prerequisite ran again after kill; no persisted progress in a fresh run"
    )
  end
end
