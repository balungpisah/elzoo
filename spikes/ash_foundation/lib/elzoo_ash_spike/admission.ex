# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.Admission do
  @moduledoc "Pure experimental admission policy. No effects or formal proof claim."

  def new(tenant),
    do: %{tenant: tenant, limit: 2, revision: 0, mode: :running, active: MapSet.new()}

  def snapshot(state),
    do: Map.take(state, [:limit, :revision, :mode]) |> Map.put(:active, MapSet.size(state.active))

  def step(state, :snapshot, _args), do: {{:ok, snapshot(state)}, state}

  def step(state, :configure, %{expected_revision: revision, limit: limit}) do
    cond do
      revision != state.revision -> reject(state, :revision_conflict)
      not is_integer(limit) or limit not in 1..64 -> reject(state, :invalid_limit)
      true -> accept(%{state | limit: limit, revision: revision + 1})
    end
  end

  def step(state, command, %{expected_revision: revision})
      when command in [:pause, :drain, :resume] do
    cond do
      revision != state.revision ->
        reject(state, :revision_conflict)

      command in [:pause, :resume] and state.mode == :draining ->
        reject(state, :still_draining)

      true ->
        mode =
          case command do
            :pause -> :paused
            :resume -> :running
            :drain -> if MapSet.size(state.active) == 0, do: :paused, else: :draining
          end

        accept(%{state | mode: mode, revision: revision + 1})
    end
  end

  def step(state, :admit, %{work_id: id}) do
    cond do
      not valid_id?(id) -> reject(state, :invalid_work_id)
      MapSet.member?(state.active, id) -> reject(state, :already_active)
      state.mode != :running -> reject(state, :not_running)
      MapSet.size(state.active) >= state.limit -> reject(state, :capacity)
      true -> accept(%{state | active: MapSet.put(state.active, id)})
    end
  end

  def step(state, :finish, %{work_id: id}) do
    if MapSet.member?(state.active, id) do
      active = MapSet.delete(state.active, id)

      mode =
        if state.mode == :draining and MapSet.size(active) == 0, do: :paused, else: state.mode

      revision = if mode == state.mode, do: state.revision, else: state.revision + 1
      accept(%{state | active: active, mode: mode, revision: revision})
    else
      reject(state, :unknown_work)
    end
  end

  def step(state, _, _), do: reject(state, :invalid_command)
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..64
  defp accept(state), do: {{:ok, snapshot(state)}, state}
  defp reject(state, reason), do: {{:error, reason}, state}
end

defmodule ElzooAshSpike.AdmissionServer do
  @moduledoc "Volatile trusted host for the admission experiment, not a job executor."
  use GenServer
  alias ElzooAshSpike.Admission

  def start_link(tenant), do: GenServer.start_link(__MODULE__, tenant)
  def command(server, tenant, action, args), do: GenServer.call(server, {tenant, action, args})

  @impl true
  def init(tenant), do: {:ok, Admission.new(tenant)}

  @impl true
  def handle_call({tenant, action, args}, _from, state) do
    if tenant != state.tenant do
      {:reply, {:error, :wrong_tenant}, state}
    else
      {result, next} = Admission.step(state, action, args)

      measurements = %{
        active: MapSet.size(next.active),
        limit: next.limit,
        revision: next.revision
      }

      metadata = %{action: action, outcome: elem(result, 0), mode: next.mode}
      :telemetry.execute([:elzoo, :admission, :operation], measurements, metadata)
      {:reply, result, next}
    end
  end
end
