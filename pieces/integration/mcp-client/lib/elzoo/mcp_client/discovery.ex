# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Discovery do
  @moduledoc """
  Bounded, inert tool discovery. Pages `tools/list` up to `max_pages` and
  `max_tools`; each descriptor becomes untrusted data. Annotations and
  descriptions are carried, never read; discovery never sends `tools/call`.
  """
  alias Elzoo.McpClient.{Redact, Session, Transport, Wire}

  def list(%Session{config: c, client: client}) do
    with {:ok, tools, truncated} <- pages(client, c, nil, c.max_pages, [], false) do
      {:ok,
       %{
         server: c.settings.server,
         protocol_version: version(client),
         tools: Redact.value(tools, Redact.secrets(c.credentials)),
         truncated: truncated
       }}
    end
  end

  defp pages(_client, _c, _cursor, 0, acc, _), do: {:ok, Enum.reverse(acc), true}

  defp pages(client, c, cursor, left, acc, truncated) do
    case Transport.list_page(client, cursor, c.call_timeout_ms) do
      {:ok, %{"tools" => tools} = page} when is_list(tools) ->
        {acc, truncated} = take(tools, c, acc, truncated)
        next = Map.get(page, "nextCursor")

        cond do
          length(acc) >= c.max_tools and (is_binary(next) or truncated) ->
            {:ok, Enum.reverse(acc), true}

          is_binary(next) and next != "" and byte_size(next) <= 1024 ->
            if left == 1,
              do: {:ok, Enum.reverse(acc), true},
              else: pages(client, c, next, left - 1, acc, truncated)

          is_nil(next) ->
            {:ok, Enum.reverse(acc), truncated}

          true ->
            {:ok, Enum.reverse(acc), true}
        end

      {:ok, _} ->
        {:error, :malformed_response}

      {:error, reason} ->
        {:error, reason(reason)}
    end
  catch
    _, _ -> {:error, :adapter_error}
  end

  defp take(tools, c, acc, truncated) do
    Enum.reduce(tools, {acc, truncated}, fn tool, {acc, truncated} ->
      cond do
        length(acc) >= c.max_tools ->
          {acc, true}

        true ->
          case descriptor(tool, c.max_descriptor_bytes) do
            {:ok, d} ->
              if Enum.any?(acc, &(&1["name"] == d["name"])),
                do: {acc, true},
                else: {[d | acc], truncated}

            :error ->
              {acc, true}
          end
      end
    end)
  end

  @doc false
  def descriptor(%{"name" => name} = tool, max_bytes) do
    description = Map.get(tool, "description")
    schema = Map.get(tool, "inputSchema")
    annotations = Map.get(tool, "annotations")

    d = %{
      "trust" => "untrusted",
      "name" => name,
      "description" => description,
      "input_schema" => schema,
      "annotations" => annotations
    }

    if Wire.tool?(name) and (is_nil(description) or is_binary(description)) and is_map(schema) and
         (is_nil(annotations) or is_map(annotations)) and
         byte_size(Jason.encode!(d)) <= max_bytes,
       do: {:ok, d},
       else: :error
  rescue
    _ -> :error
  end

  def descriptor(_, _), do: :error

  defp version(client) do
    case ExMCP.Client.negotiated_version(client) do
      {:ok, v} when is_binary(v) -> v
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  # Finite reasons; the error term is never echoed.
  defp reason(reason) do
    case Transport.classify({:error, reason}) do
      {:CallUnsent, :ReplyCredentialFault, _} -> :credentials_unavailable
      {:CallUnsent, :ReplyTargetRefused, _} -> :target_refused
      {:CallUnsent, _, _} -> :not_connected
      {:CallWire, :ReplyAuthRefused, _} -> :authentication_failed
      {:CallWire, {:ReplyRpcError, _}, _} -> :server_error
      {:CallWire, _, _} -> :malformed_response
      {:CallLost, :ReplyTimeout, _} -> :timeout
      {:CallLost, _, _} -> :connection_lost
      _ -> :adapter_error
    end
  end
end
