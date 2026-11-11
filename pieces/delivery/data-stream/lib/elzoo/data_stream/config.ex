# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Config do
  @moduledoc false
  defstruct [
    :tenant,
    :binding,
    :descriptor,
    :store,
    :host,
    :credentials,
    :models,
    :authorized_callers,
    capacity: 4,
    total_timeout_ms: 60_000,
    receive_timeout_ms: 5_000,
    ack_timeout_ms: 1_000
  ]

  @required [:tenant, :binding, :store, :host, :credentials, :models]
  @optional [
    :allow_volatile,
    :authorized_callers,
    :capacity,
    :total_timeout_ms,
    :receive_timeout_ms,
    :ack_timeout_ms
  ]
  def load(settings, caller) do
    with true <- Elzoo.DataStream.Terminal.maximal_size() <= 4096,
         true <- is_list(settings) and Keyword.keyword?(settings),
         true <- length(settings) == length(Keyword.keys(settings) |> Enum.uniq()),
         true <- Enum.all?(Keyword.keys(settings), &(&1 in @required or &1 in @optional)),
         true <- Enum.all?(@required, &Keyword.has_key?(settings, &1)),
         {:ok, b} <- Elzoo.EffectIntent.Binding.load(settings[:binding]),
         true <-
           function_exported?(settings[:binding], :__data_stream_binding__, 0) and
             settings[:binding].__data_stream_binding__() == true,
         true <-
           b.failures == Elzoo.DataStream.Binding.failures() and
             b.no_send_attestations == [:credentials_unavailable],
         true <-
           b.adapter == Elzoo.DataStream.Adapter and b.clock == "unix-ms" and
             b.operation == "generate_stream" and b.replay == :none and b.revision == :forbidden and
             b.recovery_grace_ms == :none,
         true <-
           Elzoo.DataStream.Request.id?(b.id) and Elzoo.DataStream.Request.id?(b.provider_account),
         c =
           struct!(
             __MODULE__,
             Keyword.drop(settings, [:allow_volatile])
             |> Keyword.put_new(:authorized_callers, [caller])
             |> Keyword.put(:descriptor, b)
           ),
         true <- Elzoo.DataStream.Request.id?(c.tenant),
         true <- bounded_unique?(c.models, 1, 16, &Elzoo.DataStream.Protocol.model?/1),
         true <- bounded_unique?(c.authorized_callers, 1, 64, &(is_pid(&1) and node(&1) == node())),
         true <- is_function(c.credentials, 0),
         true <- integer?(c.capacity, 1, 64) and integer?(c.total_timeout_ms, 1, 300_000),
         true <-
           integer?(c.receive_timeout_ms, 1, min(30_000, c.total_timeout_ms)) and
             integer?(c.ack_timeout_ms, 1, min(10_000, c.total_timeout_ms)),
         {mod, opts} when is_atom(mod) and is_map(opts) <- c.store,
         true <- mod != Elzoo.DurableLog.Memory or settings[:allow_volatile] == true,
         true <- Keyword.get(settings, :allow_volatile, false) in [false, true],
         true <- Map.get(opts, :fold) == Elzoo.EffectIntent.fold(c.binding),
         true <-
           Enum.all?(Elzoo.EffectIntent.limits(), fn {k, v} ->
             Map.get(Map.get(opts, :limits, %{}), k, 0) >= v
           end),
         {host, _} when is_atom(host) <- c.host,
         true <- Code.ensure_loaded?(host) and function_exported?(host, :activate, 2) do
      {:ok, c, Keyword.get(settings, :allow_volatile, false)}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  catch
    _, _ -> {:error, :configuration}
  end

  defp integer?(n, a, b), do: is_integer(n) and n >= a and n <= b

  defp bounded_unique?(l, a, b, p),
    do: is_list(l) and length(l) in a..b and length(l) == length(Enum.uniq(l)) and Enum.all?(l, p)
end

defimpl Inspect, for: Elzoo.DataStream.Config do
  def inspect(_, _), do: "#DataStream.Config<redacted>"
end
