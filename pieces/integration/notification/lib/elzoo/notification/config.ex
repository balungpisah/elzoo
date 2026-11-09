# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification.Config do
  @moduledoc """
  Trusted construction Config built by `Elzoo.Notification.configure/1`.
  `credentials` is the injected credential Need; `seal_key` is process-local.
  Inspect shows only the binding module: credentials, trust and seal never print.
  """
  @enforce_keys [
    :binding,
    :settings,
    :tenant,
    :credentials,
    :transport_supervisor,
    :tls,
    :max_request_bytes,
    :send_timeout_ms,
    :hostname,
    :seal_key
  ]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(%{binding: binding}, _opts),
      do: "#Elzoo.Notification.Config<binding: " <> Kernel.inspect(binding) <> ", ...>"
  end
end
