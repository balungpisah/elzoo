# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Config do
  @moduledoc "Trusted construction Config (see `Elzoo.AiText.configure/1`); Inspect shows no secret, Need or sink."
  @enforce_keys [
    :binding,
    :tenant,
    :provider,
    :provider_config,
    :credentials,
    :models,
    :max_request_bytes,
    :max_output_tokens,
    :receive_timeout_ms,
    :sink,
    :seal_key
  ]
  # Optional keys of Contract amendment 2; struct!/2 callers that name only the
  # enforced keys get no artifact Need, so a request with image parts is refused.
  defstruct @enforce_keys ++
              [
                artifacts: nil,
                image_bounds: %{max_image_bytes: 5_242_880, max_total_image_bytes: 20_971_520}
              ]

  defimpl Inspect do
    def inspect(c, _opts) do
      "#Elzoo.AiText.Config<binding: #{Kernel.inspect(c.binding)}, provider: " <>
        "#{Kernel.inspect(c.provider)}, models: #{length(c.models)}, redacted>"
    end
  end
end
