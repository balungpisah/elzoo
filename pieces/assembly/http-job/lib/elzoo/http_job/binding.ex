# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.Binding do
  @moduledoc "Compile-time fixed-origin binding, no replay or provider no-effect capability."
  @failures %{
    preflight_unavailable: {"timed_out", "not_dispatched", "unavailable"},
    request_rejected: {"rejected", "not_dispatched", "permanent"},
    http_4xx: {"failed", "dispatched", "permanent"},
    http_5xx: {"failed", "dispatched", "retryable"},
    http_redirect: {"failed", "dispatched", "unclassified"},
    not_acknowledged: {"unknown", "dispatched", "unclassified"},
    receipt_invalid: {"unknown", "dispatched", "unclassified"},
    transport_timeout: {"timed_out", "unknown", "retryable"},
    transport_error: {"unknown", "unknown", "unavailable"}
  }
  def failures, do: @failures

  defmacro __using__(opts) do
    quote do
      @http_job_options unquote(opts)
      @before_compile Elzoo.HttpJob.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :http_job_options))
    true = Enum.sort(Map.keys(opts)) == Enum.sort([:id, :origin, :recovery_grace_ms])
    true = origin?(opts.origin)
    true = is_integer(opts.recovery_grace_ms) and opts.recovery_grace_ms >= 0

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: Elzoo.HttpJob.Adapter,
        id: opts.id,
        provider_account: opts.origin,
        operation: "publication",
        clock: "unix-ms",
        failures: @failures,
        no_send_attestations: [:preflight_unavailable, :request_rejected],
        recovery_grace_ms: opts.recovery_grace_ms,
        replay: :none
      )

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
    end
  end

  def origin?(url) when is_binary(url) do
    uri = URI.parse(url)

    byte_size(url) <= 256 and uri.scheme in ["http", "https"] and is_binary(uri.host) and
      uri.host != "" and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil and uri.path in [nil, ""] and
      is_integer(uri.port) and uri.port in 1..65535 and Elzoo.HttpJob.Wire.text?(url, 256)
  rescue
    _ -> false
  end

  def origin?(_), do: false
end
