# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Transport do
  @moduledoc false
  # The only place that talks to ex_mcp 1.8.1. Every option list is built here
  # and accepts nothing from the caller:
  #
  # - client: transport :http, the fail-closed auth provider, reconnect: false,
  #   health_check_interval: nil, use_sse: false; never :handler, :capabilities,
  #   :retry_policy, :auth, :conformance_mode or :dns_resolver;
  # - every tools/list: retry_policy: false, http_stream_retry: :safe_only;
  # - every tools/call: the same plus max_mrtr_rounds: 0, never retry_safe, sent
  #   through ExMCP.Client.make_request/5 (@doc false at 1.8.1) because
  #   ExMCP.Client.call_tool/4 resends tools/call after a -32020 error.
  alias Elzoo.McpClient.{AuthProvider, Config, Wire}

  @list_options [retry_policy: false, http_stream_retry: :safe_only, format: :map]
  @call_options [
    retry_policy: false,
    http_stream_retry: :safe_only,
    max_mrtr_rounds: 0,
    format: :map
  ]
  # JSON-RPC envelope around the arguments; the argument bound is Elzoo's own.
  @envelope_bytes 4_096

  def list_options, do: @list_options
  def call_options, do: @call_options

  @doc false
  def client_options(%Config{settings: settings} = c) do
    %{endpoint: endpoint, network: network} = settings

    [
      transport: :http,
      url: endpoint.url,
      protocol_mode: c.protocol_mode,
      auth_provider: {AuthProvider, %{need: c.credentials}},
      reconnect: false,
      health_check_interval: nil,
      use_sse: false,
      handshake_timeout: c.handshake_timeout_ms,
      request_timeout: c.call_timeout_ms,
      max_request_bytes: c.max_request_bytes + @envelope_bytes,
      max_response_bytes: c.max_response_bytes
    ] ++ network_options(network, endpoint)
  end

  defp network_options(:loopback, _), do: []

  defp network_options(:private, endpoint),
    do: [
      allowed_private_hosts: [endpoint.host],
      security: %{trusted_origins: [Wire.origin(endpoint)]}
    ]

  defp network_options(:public, endpoint),
    do: [security: %{trusted_origins: [Wire.origin(endpoint)]}]

  @doc "Starts the client under the caller's DynamicSupervisor, never restarted."
  def start(%Config{} = c, supervisor) do
    spec = %{
      id: ExMCP.Client,
      start: {ExMCP.Client, :start_link, [client_options(c)]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, connect_reason(reason)}
      _ -> {:error, :connect_failed}
    end
  catch
    _, _ -> {:error, :connect_failed}
  end

  # Finite connect reasons; nothing from the error term is echoed.
  defp connect_reason(reason) do
    text = safe_text(reason)

    cond do
      String.contains?(text, "auth_provider") ->
        :credentials_unavailable

      String.contains?(text, "unauthorized") or String.contains?(text, "forbidden") ->
        :authentication_failed

      Enum.any?(
        ~w(non_loopback_address non_public_address dns_failed dns_timeout security_violation invalid_http_url),
        &String.contains?(text, &1)
      ) ->
        :target_refused

      true ->
        :connect_failed
    end
  end

  defp safe_text(term), do: inspect(term, limit: 64, printable_limit: 256)

  @doc "One tools/list page."
  def list_page(client, cursor, timeout) do
    opts = if cursor, do: [cursor: cursor], else: []
    ExMCP.Client.list_tools(client, opts ++ [timeout: timeout] ++ @list_options)
  catch
    :exit, _ -> {:error, :not_connected}
  end

  @doc "Exactly one tools/call request; returns {stage, reply, result}."
  def call(client, tool, arguments, timeout) do
    params = %{"name" => tool, "arguments" => arguments}

    ExMCP.Client.make_request(
      client,
      "tools/call",
      params,
      [timeout: timeout] ++ @call_options,
      timeout
    )
    |> classify()
  catch
    # The client died or was closed while (or before) the call ran: the request
    # may have been written, so this is never a refusal.
    :exit, _ -> {:CallLost, :ReplyBroken, nil}
  end

  @doc false
  def classify({:ok, %{} = result}) do
    case result(result) do
      {:ok, value} -> {:CallWire, :ReplyResult, value}
      :error -> {:CallWire, :ReplyMalformed, nil}
    end
  end

  def classify({:ok, _}), do: {:CallWire, :ReplyMalformed, nil}

  def classify({:error, :timeout}), do: {:CallLost, :ReplyTimeout, nil}

  # ex_mcp's own round-limit error for an input_required result (max_mrtr_rounds: 0).
  def classify(
        {:error,
         %ExMCP.Error.ProtocolError{message: "MRTR round limit exceeded", data: %{"maximum" => 0}}}
      ),
      do: {:CallWire, :ReplyInputRequired, nil}

  # A JSON-RPC error object from the server; the code arrives negated for Cure.
  def classify({:error, %{"code" => code}}) when is_integer(code) and code < 0,
    do: {:CallWire, {:ReplyRpcError, -code}, nil}

  def classify({:error, %ExMCP.Error.ProtocolError{code: code}})
      when is_integer(code) and code < 0,
      do: {:CallWire, {:ReplyRpcError, -code}, nil}

  # ex_mcp rejected the server's answer as an invalid MCP result: the request
  # was delivered, no completed result was observed.
  def classify({:error, %{type: :protocol_error}}), do: {:CallWire, :ReplyMalformed, nil}

  def classify({:error, reason} = error) do
    if ExMCP.Client.delivery_outcome(error) == :not_sent,
      do: {:CallUnsent, unsent(reason), nil},
      else: sent(transport_reason(reason))
  end

  def classify(_), do: {:CallCrashed, :ReplyMalformed, nil}

  defp unsent(reason) do
    case transport_reason(reason) do
      {:auth_provider_token_failed, _, _} ->
        :ReplyCredentialFault

      r when r in [:request_too_large, :frame_too_large] ->
        :ReplyOversize

      :not_connected ->
        :ReplyNotConnected

      %Mint.TransportError{} ->
        :ReplyNotConnected

      %Mint.HTTPError{} ->
        :ReplyNotConnected

      {:transport_error, {:send_failed, _}} ->
        :ReplyNotConnected

      r
      when r in [
             :non_loopback_address,
             :non_public_address,
             :dns_failed,
             :dns_timeout,
             :invalid_http_url,
             :invalid_network_policy
           ] ->
        :ReplyTargetRefused

      {:security_violation, _} ->
        :ReplyTargetRefused

      {:trust_store_unavailable, _} ->
        :ReplyTargetRefused

      _ ->
        # Validation or deadline refusals before sending: not attested as a
        # listed refusal here, so the stage is reported as a crash (unknown).
        :ReplyMalformed
    end
  end

  defp sent(r) when r in [:unauthorized, :forbidden], do: {:CallWire, :ReplyAuthRefused, nil}
  defp sent({:authentication_failed, _}), do: {:CallWire, :ReplyAuthRefused, nil}
  defp sent({:http_error, _status, _}), do: {:CallWire, :ReplyHttpStatus, nil}
  defp sent({:http_error, _status}), do: {:CallWire, :ReplyHttpStatus, nil}
  defp sent({:json_decode_error, _}), do: {:CallWire, :ReplyMalformed, nil}

  defp sent(r) when r in [:response_too_large, :response_stream_invalid],
    do: {:CallWire, :ReplyMalformed, nil}

  defp sent(:outcome_unknown), do: {:CallLost, :ReplyBroken, nil}
  defp sent(:response_stream_broken), do: {:CallLost, :ReplyBroken, nil}
  defp sent({:http_receive_failed, _}), do: {:CallLost, :ReplyBroken, nil}
  defp sent({:http_request_failed, _}), do: {:CallLost, :ReplyBroken, nil}
  defp sent(:closed), do: {:CallLost, :ReplyBroken, nil}
  defp sent(:timeout), do: {:CallLost, :ReplyTimeout, nil}
  defp sent(_), do: {:CallCrashed, :ReplyMalformed, nil}

  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason({:transport_error, reason}), do: reason
  defp transport_reason(reason), do: reason

  # A complete tool result: content list, optional isError and structuredContent.
  defp result(%{"content" => content} = r) when is_list(content) do
    is_error = Map.get(r, "isError", false)
    structured = Map.get(r, "structuredContent")

    if Map.get(r, "resultType", "complete") == "complete" and is_boolean(is_error) and
         (is_nil(structured) or is_map(structured)),
       do: {:ok, %{content: content, is_error: is_error, structured: structured}},
       else: :error
  end

  defp result(_), do: :error

  @doc false
  def unsent_stage_for_pre(:too_large), do: {:CallPre, :ReplyOversize, nil}
  def unsent_stage_for_pre(:invalid_arguments), do: {:CallPre, :ReplyBadArguments, nil}
  def unsent_stage_for_pre(:not_connected), do: {:CallPre, :ReplyNotConnected, nil}
  def unsent_stage_for_pre(_), do: {:CallCrashed, :ReplyMalformed, nil}
end
