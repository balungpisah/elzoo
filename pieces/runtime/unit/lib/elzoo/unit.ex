# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Unit do
  @moduledoc """
  Small OTP shell around a pure operator using the Cure transition representation.

  The shell stores the operator's state and serializes calls. It does not make
  decisions: `module.function(state, input)` remains the single transition
  used by fused and hopped execution.
  """

  use GenServer

  @type operator :: {module(), atom(), term()}

  @spec start_link(operator()) :: GenServer.on_start()
  def start_link(operator), do: GenServer.start_link(__MODULE__, operator)

  @spec step(GenServer.server(), term()) :: term()
  def step(server, input), do: GenServer.call(server, {:step, input})

  @spec snapshot(GenServer.server()) :: term()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init({module, function, state}) when is_atom(module) and is_atom(function),
    do: {:ok, {module, function, state}}

  @impl true
  def handle_call({:step, input}, _from, {module, function, state}) do
    {:Transition, next, output} = apply(module, function, [state, input])
    {:reply, output, {module, function, next}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
end
