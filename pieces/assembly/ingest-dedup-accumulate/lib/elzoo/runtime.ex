# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Runtime do
  @moduledoc """
  Public boundary for the compiled Cure composition.

  `fused/1` calls the assembly directly. `hopped/1` routes the same receiver
  and accumulator through OTP units. The example intentionally models only
  zero/one output and an unbounded exact-key history; it is not the complete
  Zoo receiver contract.
  """

  @core :"Cure.Elzoo.Core"
  @receiver :"Cure.Elzoo.Idempotency"
  @consumer :"Cure.Elzoo.Consumer"

  @type message :: tuple()
  @type output :: :none | {:some, integer()}

  @spec message(integer(), integer(), integer(), integer()) :: message()
  def message(sender, incarnation, sequence, value),
    do: apply(@receiver, :message, [sender, incarnation, sequence, value])

  @spec fused([message()]) :: {[output()], term()}
  def fused(messages), do: run_operator(@core, :assembly, apply(@core, :empty, []), messages)

  @spec hopped([message()]) :: {[output()], {term(), term()}}
  def hopped(messages) do
    {:ok, receiver} = Elzoo.Unit.start_link({@receiver, :receiver, []})
    {:ok, accumulator} = Elzoo.Unit.start_link({@core, :accumulate, 0})

    try do
      outputs =
        Enum.map(messages, fn input ->
          case Elzoo.Unit.step(receiver, input) do
            :none -> :none
            {:some, delivered} -> Elzoo.Unit.step(accumulator, delivered)
          end
        end)

      {outputs, {snapshot_state(receiver), snapshot_state(accumulator)}}
    after
      GenServer.stop(receiver)
      GenServer.stop(accumulator)
    end
  end

  @spec nested([message()], integer()) :: {[term()], term()}
  def nested(messages, limit) do
    state = apply(@core, :nested_empty, [limit])
    run_operator(@core, :nested, state, messages)
  end

  @spec consumer_nested([message()], integer()) :: {[term()], term()}
  def consumer_nested(messages, limit) do
    state = apply(@consumer, :start, [limit])

    Enum.map_reduce(messages, state, fn input, state ->
      {next, output} = apply(@consumer, :step, [state, input]) |> transition()
      {output, next}
    end)
  end

  @doc false
  @spec transition(tuple()) :: {term(), term()}
  def transition({:Transition, state, output}), do: {state, output}

  @doc false
  def joined({:Joined, left, right}), do: {left, right}

  @doc false
  def message_fields({:Message, sender, incarnation, sequence, value}),
    do: {sender, incarnation, sequence, value}

  defp run_operator(module, function, state, messages) do
    Enum.map_reduce(messages, state, fn input, state ->
      {next, output} = apply(module, function, [state, input]) |> transition()
      {output, next}
    end)
  end

  defp snapshot_state(server) do
    {_, _, state} = Elzoo.Unit.snapshot(server)
    state
  end
end
