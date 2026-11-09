# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Credential do
  @moduledoc """
  The credential rule (live Contract, amendment 3): the injected bearer token is
  accepted only if it is at least 24 bytes and is not a substring of any
  Adapter-emitted fixed string (`fixed/0`: every literal of at least 24 bytes in
  this Piece's compiled modules, enumerated from the compiled source by a test)
  nor of the binding's configured strings (server identity, endpoint, provider
  account, binding id and module name). Otherwise the auth provider refuses it
  before any send, which is `refused{credentials_unavailable}`.
  """
  alias Elzoo.McpClient.Config

  @min 24
  # Regenerate from the compiled modules when a literal is added; the test fails
  # until it is listed.
  @fixed [
    "#Elzoo.McpClient.Config<binding: ",
    "#Elzoo.McpClient.Context<",
    "#Elzoo.McpClient.Session<binding: ",
    "Cure.Elzoo.McpClientOutcome",
    "Elixir.DynamicSupervisor",
    "Elixir.Elzoo.EffectIntent",
    "Elixir.Elzoo.EffectIntent.Binding",
    "Elixir.Elzoo.EffectIntent.Model",
    "Elixir.Elzoo.McpClient.Adapter",
    "Elixir.Elzoo.McpClient.AuthProvider",
    "Elixir.Elzoo.McpClient.Binding",
    "Elixir.Elzoo.McpClient.Config",
    "Elixir.Elzoo.McpClient.Context",
    "Elixir.Elzoo.McpClient.Credential",
    "Elixir.Elzoo.McpClient.Discovery",
    "Elixir.Elzoo.McpClient.Ledger",
    "Elixir.Elzoo.McpClient.Outcome",
    "Elixir.Elzoo.McpClient.Redact",
    "Elixir.Elzoo.McpClient.Session",
    "Elixir.Elzoo.McpClient.Snapshot",
    "Elixir.Elzoo.McpClient.Transport",
    "Elixir.Elzoo.McpClient.Wire",
    "Elixir.ExJsonSchema.Schema",
    "Elixir.ExJsonSchema.Validator",
    "Elixir.ExMCP.Error.ProtocolError",
    "Elixir.Inspect.Elzoo.McpClient.Config",
    "Elixir.Inspect.Elzoo.McpClient.Context",
    "Elixir.Inspect.Elzoo.McpClient.Session",
    "Elixir.Jason.OrderedObject",
    "Elixir.Mint.TransportError",
    "MRTR round limit exceeded",
    "TagCredentialsUnavailable",
    "TagServerInvalidArguments",
    "\\A[A-Za-z0-9._:/@-]{1,256}\\z",
    "\\A[A-Za-z0-9_.-]{1,128}\\z",
    "__effect_intent_binding__",
    "auth_provider_token_failed",
    "invalid MCP client binding: id, server, endpoint, network or grace",
    "server_invalid_arguments",
    "the following keys must also be given when building "
  ]

  def min_bytes, do: @min
  def fixed, do: @fixed

  @doc "The binding's configured strings for a Config."
  def configured(%Config{binding: binding, settings: settings}) do
    {:ok, b, _} = Elzoo.McpClient.Binding.load(binding)

    [
      settings.server,
      settings.endpoint.url,
      settings.endpoint.host,
      b.provider_account,
      b.id,
      Atom.to_string(binding),
      inspect(binding)
    ]
  rescue
    _ -> [inspect(binding)]
  end

  @doc "True when the token may be used. `:redaction` skips the rule (shape only)."
  def acceptable?(_token, :redaction), do: true

  def acceptable?(token, configured) when is_binary(token) and is_list(configured) do
    byte_size(token) >= @min and
      not Enum.any?(@fixed ++ configured, &(is_binary(&1) and :binary.match(&1, token) != :nomatch))
  end

  def acceptable?(_, _), do: false
end
