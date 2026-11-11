# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Usage do
  @moduledoc false
  alias Elzoo.AiModel.Usage, as: Core
  @max 9_223_372_036_854_775_807
  @keys ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens cache_creation output_tokens_details)
  def new,
    do: %{
      input: :unknown,
      output: :unknown,
      read: :unknown,
      writes: [%{ttl: "provider_default", amount: :unknown}],
      reasoning: :unknown
    }

  def merge(_, nil), do: {:ok, new()}

  def merge(old, m) when is_map(m) do
    with :ok <- shape(m, @keys),
         :ok <-
           counters(
             Map.take(
               m,
               ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)
             )
           ),
         {:ok, reasoning} <- reasoning(old.reasoning, Map.fetch(m, "output_tokens_details")),
         {:ok, writes} <- writes(old.writes, m) do
      r = %{
        old
        | input: scalar(m, "input_tokens", old.input),
          output: scalar(m, "output_tokens", old.output),
          read: scalar(m, "cache_read_input_tokens", old.read),
          reasoning: reasoning,
          writes: writes
      }

      with {:ok, _} <- value(r), do: {:ok, r}
    end
  end

  def merge(_, _), do: {:error, :malformed_response}

  def value(r) do
    {:ok, u} =
      Core.from_provider(
        %{
          input: r.input,
          cache_read: r.read,
          cache_writes: r.writes,
          output: r.output,
          reasoning: r.reasoning
        },
        %{input_includes_cached: false},
        :provider_reported
      )

    if Enum.any?(
         [Core.sum(u.cache_writes), Core.prompt_input_tokens(u)],
         &(is_integer(&1) and &1 > @max)
       ),
       do: {:error, :malformed_response},
       else:
         {:ok,
          %{
            u
            | counters: Enum.sort_by(u.counters, & &1.unit),
              cache_writes: Enum.sort_by(u.cache_writes, & &1.ttl)
          }}
  end

  defp scalar(m, k, old) do
    case Map.fetch(m, k) do
      :error -> old
      {:ok, nil} -> :unknown
      {:ok, n} -> n
    end
  end

  defp reasoning(old, :error), do: {:ok, old}
  defp reasoning(_, {:ok, nil}), do: {:ok, :unknown}

  defp reasoning(_, {:ok, m}) when is_map(m) do
    with :ok <- shape(m, ["thinking_tokens"]),
         :ok <- counters(m),
         n = scalar(m, "thinking_tokens", :unknown),
         true <- n in [:unknown, 0] do
      {:ok, n}
    else
      false -> {:error, :unsupported_response}
      error -> error
    end
  end

  defp reasoning(_, _), do: {:error, :malformed_response}

  defp writes(old, m) do
    if not Map.has_key?(m, "cache_creation") and not Map.has_key?(m, "cache_creation_input_tokens") do
      {:ok, old}
    else
      total = scalar(m, "cache_creation_input_tokens", :unknown)

      case Map.fetch(m, "cache_creation") do
        :error ->
          {:ok, [%{ttl: "provider_default", amount: total}]}

        {:ok, nil} ->
          {:ok, [%{ttl: "provider_default", amount: :unknown}]}

        {:ok, group} when is_map(group) ->
          with :ok <- shape(group, ~w(ephemeral_5m_input_tokens ephemeral_1h_input_tokens)),
               :ok <- counters(group) do
            a = scalar(group, "ephemeral_5m_input_tokens", :unknown)
            b = scalar(group, "ephemeral_1h_input_tokens", :unknown)

            cond do
              is_integer(a) and is_integer(b) and a + b > @max ->
                {:error, :malformed_response}

              is_integer(a) and is_integer(b) and (total == :unknown or total == a + b) ->
                {:ok, [%{ttl: "1h", amount: b}, %{ttl: "5m", amount: a}]}

              true ->
                {:ok, [%{ttl: "provider_default", amount: :unknown}]}
            end
          end

        _ ->
          {:error, :malformed_response}
      end
    end
  end

  defp shape(m, keys),
    do: if(Enum.all?(Map.keys(m), &(&1 in keys)), do: :ok, else: {:error, :unsupported_response})

  defp counters(m),
    do:
      if(Enum.all?(Map.values(m), fn x -> is_nil(x) or (is_integer(x) and x in 0..@max) end),
        do: :ok,
        else: {:error, :malformed_response}
      )
end
