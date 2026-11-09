# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Outcome do
  @moduledoc false
  # Elixir side of the Cure decision Elzoo.McpClientOutcome.classify/2.
  @core :"Cure.Elzoo.McpClientOutcome"
  @tags %{
    TagCompleted: :completed,
    TagUnknownTool: :unknown_tool,
    TagInvalidArguments: :invalid_arguments,
    TagTooLarge: :too_large,
    TagCredentialsUnavailable: :credentials_unavailable,
    TagNotConnected: :not_connected,
    TagTargetRefused: :target_refused,
    TagAuthenticationFailed: :authentication_failed,
    TagServerInvalidArguments: :server_invalid_arguments,
    TagServerInvalidRequest: :server_invalid_request,
    TagServerProtocolError: :server_protocol_error,
    TagServerError: :server_error,
    TagTimeout: :timeout,
    TagConnectionLost: :connection_lost,
    TagInputRequired: :input_required,
    TagMalformedResponse: :malformed_response,
    TagAdapterError: :adapter_error
  }
  @stages [:CallPre, :CallUnsent, :CallWire, :CallLost, :CallCrashed]

  def classify(stage, reply) when stage in @stages do
    Map.fetch!(@tags, apply(@core, :classify, [stage, reply]))
  rescue
    _ -> :adapter_error
  end

  def classify(_, _), do: :adapter_error
end
