# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderDataPolicy do
  @moduledoc """
  Pure decision: may a payload carrying a set of data classes go to one provider,
  in one region, under one retention mode, according to a tenant's policy?

  Returns `:allow`, `{:deny, reason}` or `{:error, :policy | :request}`. The host
  treats every result other than `:allow` as DENY. No I/O, clock, telemetry or log;
  results never echo supplied values.
  """

  @classes [:public, :internal, :confidential, :pii, :secret]
  @admissible [:public, :internal, :confidential, :pii]
  @order [:pii, :confidential, :internal, :public]

  @doc "The closed data-class tag set."
  def data_classes, do: @classes

  @doc "Decide one request against one tenant policy."
  def decide(policy, request) do
    with {:ok, providers} <- policy(policy),
         {:ok, request} <- request(request) do
      verdict(providers, request)
    end
  end

  defp verdict(providers, %{provider: provider, region: region, retention: retention} = request) do
    classes = request.classes

    cond do
      :secret in classes ->
        {:deny, :secret}

      not Map.has_key?(providers, provider) ->
        {:deny, :provider}

      true ->
        admitted = Map.fetch!(providers, provider)

        Enum.find_value(@order, :allow, fn class ->
          if class in classes, do: check(Map.fetch(admitted, class), region, retention)
        end)
    end
  end

  defp check(:error, _region, _retention), do: {:deny, :class}

  defp check({:ok, {regions, retentions}}, region, retention) do
    cond do
      region not in regions -> {:deny, :region}
      retention not in retentions -> {:deny, :retention}
      true -> nil
    end
  end

  # Policy shape: exactly `providers`, 0..256 entries with unique IDs. An exact
  # key count also refuses structs, whose `__struct__` key is one more.
  defp policy(%{providers: providers} = policy) when map_size(policy) == 1 do
    with true <- bounded?(providers, 0, 256),
         {:ok, entries} <- all(providers, &provider/1),
         ids = Enum.map(entries, &elem(&1, 0)),
         true <- unique?(ids) do
      {:ok, Map.new(entries)}
    else
      _ -> {:error, :policy}
    end
  end

  defp policy(_), do: {:error, :policy}

  defp provider(%{provider: id, classes: classes} = entry) when map_size(entry) == 2 do
    with true <- text?(id) and bounded?(classes, 1, 4),
         {:ok, admitted} <- all(classes, &admission/1),
         true <- unique?(Enum.map(admitted, &elem(&1, 0))) do
      {:ok, {id, Map.new(admitted)}}
    else
      _ -> :error
    end
  end

  defp provider(_), do: :error

  defp admission(%{class: class, regions: regions, retention: retention} = entry)
       when map_size(entry) == 3 do
    if class in @admissible and texts?(regions, 64) and
         texts?(retention, 16),
       do: {:ok, {class, {regions, retention}}},
       else: :error
  end

  defp admission(_), do: :error

  # Request shape: exactly four keys; 1..5 class tags, counted before coalescing.
  defp request(%{provider: provider, region: region, retention: retention, classes: classes} = r)
       when map_size(r) == 4 do
    if text?(provider) and text?(region) and text?(retention) and
         bounded?(classes, 1, 5) and Enum.all?(classes, &(&1 in @classes)),
       do:
         {:ok,
          %{provider: provider, region: region, retention: retention, classes: Enum.uniq(classes)}},
       else: {:error, :request}
  end

  defp request(_), do: {:error, :request}

  defp all(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp unique?(list), do: length(list) == length(Enum.uniq(list))

  defp texts?(list, max), do: bounded?(list, 1, max) and Enum.all?(list, &text?/1)

  # A proper list whose length is in min..max; walks at most max + 1 cells.
  defp bounded?(list, min, max), do: count(list, 0, max) in min..max//1

  defp count([], n, _max), do: n
  defp count([_ | tail], n, max) when n <= max, do: count(tail, n + 1, max)
  defp count(_, _n, _max), do: :invalid

  # 1..64 bytes of valid UTF-8 without C0 (U+0000..U+001F), DEL or C1 (U+0080..U+009F).
  defp text?(value) do
    is_binary(value) and byte_size(value) in 1..64 and String.valid?(value) and
      not String.match?(value, ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u)
  end
end
