# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Config do
  @moduledoc "Trusted construction Config (see `Elzoo.AiBatch.configure/1`); Inspect shows no secret, Need, lookup or sink."
  @enforce_keys [
    :submit_binding,
    :cancel_binding,
    :tenant,
    :provider,
    :provider_config,
    :credentials,
    :submissions,
    :models,
    :max_output_tokens,
    :max_items,
    :max_create_wire_bytes,
    :max_submission_bytes,
    :max_item_bytes,
    :page_size,
    :max_line_bytes,
    :max_scan_bytes,
    :receive_timeout_ms,
    :store_timeout_ms,
    :sink,
    :seal_key
  ]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(c, _opts) do
      "#Elzoo.AiBatch.Config<provider: #{Kernel.inspect(c.provider)}, models: " <>
        "#{length(c.models)}, max_items: #{c.max_items}, redacted>"
    end
  end
end
