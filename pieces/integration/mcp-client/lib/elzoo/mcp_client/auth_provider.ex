# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.AuthProvider do
  @moduledoc """
  Fail-closed `ExMCP.Authorization.Provider`. `init/1` keeps the credential Need
  (a zero-arity function), never a token. `get_token/1` calls the Need before
  each request and checks the value with guards and a byte scan only; anything
  but `{:ok, token}` with a 1..4096-byte RFC 6750 `b64token` is refused.
  `handle_unauthorized/3` and `handle_forbidden/3` always refuse, so ex_mcp
  never resends a request after a 401 or 403 and never starts an OAuth flow.
  """
  @behaviour ExMCP.Authorization.Provider

  @impl true
  def init(%{need: need}) when is_function(need, 0), do: {:ok, %{need: need}}
  def init(_), do: {:error, :credentials_unavailable}

  @impl true
  def get_token(%{need: need} = state) do
    case token(need) do
      {:ok, token} -> {:ok, token, state}
      :error -> {:error, :credentials_unavailable}
    end
  end

  @impl true
  def handle_unauthorized(_www_authenticate, _scopes, state), do: {:error, :unauthorized, state}

  @impl true
  def handle_forbidden(_www_authenticate, _scopes, state), do: {:error, :forbidden, state}

  @doc false
  def token(need) do
    case need.() do
      {:ok, t} when is_binary(t) and byte_size(t) in 1..4096 ->
        if b64token?(t), do: {:ok, t}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # RFC 6750 b64token: 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="
  defp b64token?(<<?=, _::binary>>), do: false
  defp b64token?(t), do: scan(t, false)

  defp scan(<<>>, _), do: true
  defp scan(<<?=, rest::binary>>, _), do: scan(rest, true)

  defp scan(<<c, rest::binary>>, false)
       when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?-, ?., ?_, ?~, ?+, ?/],
       do: scan(rest, false)

  defp scan(_, _), do: false
end
