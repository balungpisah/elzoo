# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.Config do
  @moduledoc false
  defstruct [
    :binding,
    :origin,
    :transport_supervisor,
    :caller_supervisor,
    :credentials,
    :authenticate,
    :resolve_intent,
    :observer,
    :tenant,
    :queue,
    :maximum,
    :total_ms,
    :connect_ms,
    :receive_ms,
    :call_ms,
    :observer_ms,
    :poll_seconds,
    :retry_policy
  ]
end
