# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Binding do
  @moduledoc """
  Compile-time MCP server binding: server identity, the one allowlisted endpoint
  URL and its network policy are fixed and enter the EffectIntent provider
  account, binding digest and intent key. No replay, no revision, no provider
  no-effect capability.
  """
  alias Elzoo.McpClient.Wire

  # tag => {envelope outcome, dispatch, error_class}; see the task work record.
  @failures %{
    unknown_tool: {"rejected", "not_dispatched", "permanent"},
    invalid_arguments: {"rejected", "not_dispatched", "permanent"},
    too_large: {"rejected", "not_dispatched", "permanent"},
    target_refused: {"rejected", "not_dispatched", "permanent"},
    credentials_unavailable: {"timed_out", "not_dispatched", "unavailable"},
    not_connected: {"timed_out", "not_dispatched", "unavailable"},
    authentication_failed: {"failed", "dispatched", "permanent"},
    server_invalid_arguments: {"unknown", "dispatched", "unclassified"},
    server_invalid_request: {"unknown", "dispatched", "unclassified"},
    server_protocol_error: {"unknown", "dispatched", "unclassified"},
    server_error: {"unknown", "dispatched", "unclassified"},
    input_required: {"unknown", "dispatched", "unclassified"},
    malformed_response: {"unknown", "dispatched", "unclassified"},
    timeout: {"timed_out", "unknown", "retryable"},
    connection_lost: {"unknown", "unknown", "unavailable"},
    adapter_error: {"unknown", "unknown", "unclassified"}
  }
  # Only these end before any request byte reaches transport (Elzoo's own
  # checks, or ex_mcp's delivery_outcome/1 :not_sent attestation).
  @no_send [
    :unknown_tool,
    :invalid_arguments,
    :too_large,
    :target_refused,
    :credentials_unavailable,
    :not_connected
  ]
  @outcomes %{
    unknown_tool: {:refused, :unknown_tool},
    invalid_arguments: {:refused, :invalid_arguments},
    too_large: {:refused, :too_large},
    target_refused: {:refused, :target_refused},
    credentials_unavailable: {:refused, :credentials_unavailable},
    not_connected: {:refused, :not_connected},
    authentication_failed: {:refused, :authentication_failed},
    server_invalid_arguments: {:unknown, {:server_error, :invalid_arguments}},
    server_invalid_request: {:unknown, {:server_error, :invalid_request}},
    server_protocol_error: {:unknown, {:server_error, :protocol_error}},
    server_error: {:unknown, {:server_error, :other}},
    input_required: {:unknown, :input_required},
    malformed_response: {:unknown, :malformed_response},
    timeout: {:unknown, :timeout},
    connection_lost: {:unknown, :connection_lost},
    adapter_error: {:unknown, :adapter_error}
  }
  def failures, do: @failures
  def no_send, do: @no_send

  @doc "Contract outcome of a failure tag: `{:refused, reason}` or `{:unknown, reason}`."
  def outcome(tag), do: Map.fetch(@outcomes, tag)

  defmacro __using__(opts) do
    quote do
      @mcp_client_options unquote(opts)
      @before_compile Elzoo.McpClient.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :mcp_client_options))
    settings = settings!(opts)

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: Elzoo.McpClient.Adapter,
        id: opts.id,
        provider_account: account(settings),
        operation: "tools/call",
        clock: "unix-ms",
        failures: @failures,
        no_send_attestations: @no_send,
        recovery_grace_ms: opts.recovery_grace_ms,
        replay: :none
      )

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
      def __mcp_client_binding__, do: unquote(Macro.escape(settings))
    end
  end

  @doc false
  def settings!(opts) do
    true =
      Enum.sort(Map.keys(opts)) ==
        Enum.sort([:id, :server, :endpoint, :network, :recovery_grace_ms])

    true = Wire.text?(opts.server, 128)
    {:ok, endpoint} = Wire.endpoint(opts.endpoint, opts.network)
    true = is_integer(opts.recovery_grace_ms) and opts.recovery_grace_ms >= 0
    settings = %{server: opts.server, endpoint: endpoint, network: opts.network}
    true = byte_size(account(settings)) <= 256
    settings
  rescue
    _ ->
      raise ArgumentError,
            "invalid MCP client binding: id, server, endpoint, network or grace"
  end

  def account(%{server: s, endpoint: %{url: u}, network: n}), do: "mcp:#{n}:#{u}##{s}"

  @doc "Loads and cross-checks the EffectIntent descriptor and the MCP settings."
  def load(module) do
    with {:ok, b} <- Elzoo.EffectIntent.Binding.load(module),
         true <- b.adapter == Elzoo.McpClient.Adapter and b.replay == :none,
         true <-
           b.failures == @failures and Enum.sort(b.no_send_attestations) == Enum.sort(@no_send),
         true <- function_exported?(module, :__mcp_client_binding__, 0),
         %{server: s, endpoint: %{url: u}, network: n} = settings <-
           module.__mcp_client_binding__(),
         true <-
           settings ==
             settings!(%{
               id: b.id,
               server: s,
               endpoint: u,
               network: n,
               recovery_grace_ms: 0
             }),
         true <- b.provider_account == account(settings) do
      {:ok, b, settings}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end
end
