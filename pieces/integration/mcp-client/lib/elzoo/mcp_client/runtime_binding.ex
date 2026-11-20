# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.RuntimeBinding do
  @moduledoc """
  The one compiled binding of runtime endpoint mode: `configure/1` takes it only
  together with a `runtime` map (server, endpoint, network and the host-checked
  addresses). Its EffectIntent descriptor fixes no endpoint: provider account
  `"mcp:runtime"`, the build-time failure table and no-send attestations, and a
  recovery grace of 60,000 ms. The server and endpoint enter the intent key
  through the identity digest (`Elzoo.McpClient.admission/3`).
  """
  alias Elzoo.McpClient.{Adapter, Binding}

  @descriptor Elzoo.EffectIntent.Binding.compile!(
                adapter: Adapter,
                id: "mcp-client-runtime",
                provider_account: "mcp:runtime",
                operation: "tools/call",
                clock: "unix-ms",
                failures: Binding.failures(),
                no_send_attestations: Binding.no_send(),
                recovery_grace_ms: 60_000,
                replay: :none
              )

  def __effect_intent_binding__, do: @descriptor
end
