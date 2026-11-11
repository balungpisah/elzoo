# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Binding do
  @moduledoc "Build-time binding: supply only stable `:id` and `:provider_account`."
  def failures do
    permanent =
      ~w(provider_invalid_request authentication_failed permission_denied not_found provider_too_large billing_error conflict)a

    retryable = [:throttled, :overloaded]

    unknown =
      ~w(transport adapter_error caller_cancelled disconnected sink_timeout sink_failed session_lost intent_unavailable)a

    dispatched =
      ~w(provider_error stream_error malformed_response unsupported_response missing_completion receive_limit block_limit event_limit)a

    Map.new(permanent, &{&1, {"failed", "dispatched", "permanent"}})
    |> Map.merge(Map.new(retryable, &{&1, {"failed", "dispatched", "retryable"}}))
    |> Map.merge(Map.new(unknown, &{&1, {"unknown", "unknown", "unclassified"}}))
    |> Map.merge(Map.new(dispatched, &{&1, {"unknown", "dispatched", "unclassified"}}))
    |> Map.merge(%{
      credentials_unavailable: {"timed_out", "not_dispatched", "unavailable"},
      provider_timeout: {"timed_out", "dispatched", "unclassified"},
      timeout: {"timed_out", "unknown", "unclassified"}
    })
  end

  defmacro __using__(opts) do
    quote do
      def __data_stream_binding__, do: true
      options = unquote(opts)

      true =
        Keyword.keyword?(options) and Enum.sort(Keyword.keys(options)) == [:id, :provider_account]

      use Elzoo.EffectIntent.Binding,
        adapter: Elzoo.DataStream.Adapter,
        id: Keyword.fetch!(options, :id),
        provider_account: Keyword.fetch!(options, :provider_account),
        operation: "generate_stream",
        clock: "unix-ms",
        replay: :none,
        revision: :forbidden,
        recovery_grace_ms: :none,
        failures: Elzoo.DataStream.Binding.failures(),
        no_send_attestations: [:credentials_unavailable]
    end
  end
end
