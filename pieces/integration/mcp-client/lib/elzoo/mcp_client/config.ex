# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Config do
  @moduledoc """
  Trusted construction Config built by `Elzoo.McpClient.configure/1`.
  `credentials` is the injected credential Need; `seal_key` is process-local.
  Inspect shows only the binding module: the credential Need and seal never print.
  """
  @enforce_keys [
    :binding,
    :settings,
    :tenant,
    :credentials,
    :protocol_mode,
    :call_timeout_ms,
    :handshake_timeout_ms,
    :max_request_bytes,
    :max_response_bytes,
    :max_pages,
    :max_tools,
    :max_descriptor_bytes,
    :seal_key
  ]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(%{binding: binding}, _opts),
      do: "#Elzoo.McpClient.Config<binding: " <> Kernel.inspect(binding) <> ", ...>"
  end
end

defmodule Elzoo.McpClient.Session do
  @moduledoc """
  One connection: the Config and the `ExMCP.Client` process started under the
  caller's supervisor. Inspect shows only the binding module.
  """
  @enforce_keys [:config, :client, :ledger]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(%{config: %{binding: binding}}, _opts),
      do: "#Elzoo.McpClient.Session<binding: " <> Kernel.inspect(binding) <> ", ...>"
  end
end

defmodule Elzoo.McpClient.Context do
  @moduledoc """
  The EffectIntent Adapter context: the session and the recipient Need, a
  trusted local process that receives each classified outcome by best-effort
  mailbox delivery.
  """
  @enforce_keys [:session, :recipient]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(%{session: session}, opts),
      do: "#Elzoo.McpClient.Context<" <> Inspect.inspect(session, opts) <> ">"
  end
end
