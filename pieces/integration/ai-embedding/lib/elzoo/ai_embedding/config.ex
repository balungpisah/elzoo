# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Config do
  @moduledoc "Trusted construction Config (see `Elzoo.AiEmbedding.configure/1`); Inspect shows no secret, Need or sink."
  @enforce_keys [
    :binding,
    :tenant,
    :provider,
    :provider_config,
    :credentials,
    :models,
    :max_inputs,
    :max_input_bytes,
    :max_request_bytes,
    :receive_timeout_ms,
    :sink,
    :seal_key
  ]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(c, _opts) do
      "#Elzoo.AiEmbedding.Config<binding: #{Kernel.inspect(c.binding)}, provider: " <>
        "#{Kernel.inspect(c.provider)}, models: #{length(c.models)}, redacted>"
    end
  end
end
