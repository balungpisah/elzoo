# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob.Registration do
  @moduledoc """
  First child of an Assembly: owns the queue's `:persistent_term` config and
  its `Elzoo.Jobs` runner. It traps exits, registers both in `init/1` with
  itself as `owner`, and erases them in `terminate/2` (an orderly stop, or the
  supervisor's exit signal). A brutal kill of this process skips `terminate/2`,
  so entry points and the runner also require the owner to be alive; a newer
  Registration for the same queue is never erased by an older one.
  """
  use GenServer
  alias Elzoo.DurableJob
  alias Elzoo.Jobs

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    owner = self()
    config = Map.put(config, :owner, owner)
    :persistent_term.put({DurableJob, config.queue}, config)

    :ok =
      Jobs.register(config.queue, %{
        owner: owner,
        perform: fn job ->
          if Process.alive?(owner),
            do: DurableJob.perform(config, job),
            else: {:snooze, config.snooze}
        end,
        backoff: &DurableJob.backoff/1
      })

    {:ok, config}
  end

  @impl true
  def handle_info({:EXIT, _, reason}, config), do: {:stop, reason, config}

  @impl true
  def terminate(_reason, config) do
    owner = self()

    case :persistent_term.get({DurableJob, config.queue}, nil) do
      %{owner: ^owner} -> :persistent_term.erase({DurableJob, config.queue})
      _ -> :ok
    end

    case Jobs.runner(config.queue) do
      %{owner: ^owner} -> Jobs.unregister(config.queue)
      _ -> :ok
    end
  end
end
