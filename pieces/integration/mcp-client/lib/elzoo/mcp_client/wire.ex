# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Wire do
  @moduledoc """
  Request bytes (`elzoo/mcp-tool-call` v1): an exact JSON object with `version` 1,
  `tool` (MCP tool name), `arguments` (a JSON object) and `release` (the caller's
  exact-action release reference). Strict decoding: duplicate or unknown keys are
  refused. The release reference is shape-checked only, never verified here.
  """
  @max 65_536
  @fields ~w(arguments release tool version)
  @tool ~r/\A[A-Za-z0-9_.-]{1,128}\z/
  @release ~r/\A[A-Za-z0-9._:\/@-]{1,256}\z/

  def max, do: @max

  @doc "Decodes and checks request bytes against `max_bytes` before anything else."
  def request(bytes, max_bytes) when is_binary(bytes) and is_integer(max_bytes) do
    if byte_size(bytes) > max_bytes or byte_size(bytes) > @max,
      do: {:error, :too_large},
      else: decode(bytes)
  end

  def request(_, _), do: {:error, :invalid_request}

  defp decode(bytes) do
    with {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         keys = Enum.map(pairs, &elem(&1, 0)),
         true <- Enum.sort(keys) == @fields,
         m = Map.new(pairs),
         1 <- m["version"],
         true <- release?(m["release"]),
         true <- tool?(m["tool"]) do
      case m["arguments"] do
        %Jason.OrderedObject{} = args ->
          case plain(args) do
            {:ok, a} -> {:ok, %{tool: m["tool"], arguments: a, release: m["release"]}}
            :error -> {:error, :invalid_arguments}
          end

        _ ->
          {:error, :invalid_arguments}
      end
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  # Ordered objects back to maps; a duplicate key anywhere is refused.
  defp plain(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case plain(v) do
          {:ok, pv} -> {:cont, {:ok, Map.put(acc, k, pv)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp plain(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn v, {:ok, acc} ->
      case plain(v) do
        {:ok, pv} -> {:cont, {:ok, [pv | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp plain(v), do: {:ok, v}

  @doc "MCP tool name grammar: 1..128 of `[A-Za-z0-9_.-]`."
  def tool?(t), do: is_binary(t) and Regex.match?(@tool, t)

  @doc "Release reference shape: 1..256 of `[A-Za-z0-9._:/@-]`."
  def release?(r), do: is_binary(r) and Regex.match?(@release, r)

  @doc "Bounded printable text without control characters."
  def text?(v, max),
    do:
      is_binary(v) and byte_size(v) in 1..max and String.valid?(v) and
        not Regex.match?(~r/\p{Cc}/u, v)

  def hex?(v), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)

  @loopback ["127.0.0.1", "localhost", "::1"]

  @doc """
  Endpoint allowlist check for a network policy. `:loopback` accepts only the
  literal hosts 127.0.0.1, localhost and ::1 (http or https); `:private` and
  `:public` require https and a non-loopback host. No userinfo, query or fragment.
  """
  def endpoint(url, network) when is_binary(url) and network in [:loopback, :private, :public] do
    with true <- byte_size(url) in 1..512 and String.valid?(url),
         false <- Regex.match?(~r/[\s\p{Cc}]/u, url),
         {:ok, %URI{scheme: scheme, host: host, port: port} = uri} <- URI.new(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- is_integer(port) and port in 1..65_535,
         true <- allowed?(network, scheme, String.downcase(host)) do
      {:ok, %{url: url, scheme: scheme, host: String.downcase(host), port: port}}
    else
      _ -> :error
    end
  end

  def endpoint(_, _), do: :error

  defp allowed?(:loopback, _scheme, host), do: host in @loopback
  defp allowed?(_, "https", host), do: host not in @loopback
  defp allowed?(_, _, _), do: false

  def origin(%{scheme: s, host: h, port: p}), do: "#{s}://#{h}:#{p}"
end
