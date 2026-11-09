# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification.Binding do
  @moduledoc """
  Compile-time SMTP binding: relay, port and sender are fixed and enter the
  EffectIntent provider account, binding digest and intent key. No replay,
  no revision, no provider no-effect capability.
  """
  alias Elzoo.Notification.Wire

  # tag => {envelope outcome, dispatch, error_class}; see the work record table.
  @failures %{
    invalid_address: {"rejected", "not_dispatched", "permanent"},
    too_large: {"rejected", "not_dispatched", "permanent"},
    session_throttled: {"rejected", "not_dispatched", "retryable"},
    authentication_failed: {"rejected", "not_dispatched", "permanent"},
    credentials_unavailable: {"timed_out", "not_dispatched", "unavailable"},
    connect_failed: {"timed_out", "not_dispatched", "unavailable"},
    provider_too_large: {"failed", "dispatched", "permanent"},
    rejected_recipient: {"failed", "dispatched", "permanent"},
    throttled: {"failed", "dispatched", "retryable"},
    connection_lost: {"unknown", "unknown", "unavailable"},
    deadline: {"timed_out", "unknown", "retryable"},
    unclassified_reply: {"unknown", "dispatched", "unclassified"},
    adapter_error: {"unknown", "unknown", "unclassified"}
  }
  # Only these end before any envelope address or message byte reaches transport.
  @no_send [
    :invalid_address,
    :too_large,
    :session_throttled,
    :authentication_failed,
    :credentials_unavailable,
    :connect_failed
  ]
  @outcomes %{
    invalid_address: {:refused, :invalid_address},
    too_large: {:refused, :too_large},
    provider_too_large: {:refused, :too_large},
    rejected_recipient: {:refused, :rejected_recipient},
    throttled: {:refused, :throttled},
    session_throttled: {:refused, :throttled},
    authentication_failed: {:refused, :authentication_failed},
    credentials_unavailable: {:refused, :credentials_unavailable},
    connect_failed: {:refused, :connect_failed},
    connection_lost: {:unknown, :connection_lost},
    deadline: {:unknown, :deadline},
    unclassified_reply: {:unknown, :unclassified_reply},
    adapter_error: {:unknown, :adapter_error}
  }
  def failures, do: @failures
  def no_send, do: @no_send

  @doc "Contract outcome of a failure tag: `{:refused, reason}` or `{:unknown, reason}`."
  def outcome(tag), do: Map.fetch(@outcomes, tag)

  defmacro __using__(opts) do
    quote do
      @notification_options unquote(opts)
      @before_compile Elzoo.Notification.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :notification_options))
    settings = settings!(opts)

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: Elzoo.Notification.Adapter,
        id: opts.id,
        provider_account: account(settings),
        operation: "email",
        clock: "unix-ms",
        failures: @failures,
        no_send_attestations: @no_send,
        recovery_grace_ms: opts.recovery_grace_ms,
        replay: :none
      )

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
      def __notification_binding__, do: unquote(Macro.escape(settings))
    end
  end

  @doc false
  def settings!(opts) do
    true = Enum.sort(Map.keys(opts)) == Enum.sort([:id, :relay, :port, :sender, :recovery_grace_ms])
    true = Wire.relay?(opts.relay)
    true = is_integer(opts.port) and opts.port in 1..65_535
    true = Wire.address?(opts.sender)
    true = is_integer(opts.recovery_grace_ms) and opts.recovery_grace_ms >= 0
    settings = %{relay: opts.relay, port: opts.port, sender: opts.sender}
    true = byte_size(account(settings)) <= 256
    settings
  rescue
    _ -> raise ArgumentError, "invalid notification binding: id, relay, port, sender or grace"
  end

  def account(%{relay: r, port: p, sender: s}), do: "smtp://#{r}:#{p}/#{s}"

  @doc "Loads and cross-checks the EffectIntent descriptor and the SMTP settings."
  def load(module) do
    with {:ok, b} <- Elzoo.EffectIntent.Binding.load(module),
         true <- b.adapter == Elzoo.Notification.Adapter and b.replay == :none,
         true <-
           b.failures == @failures and Enum.sort(b.no_send_attestations) == Enum.sort(@no_send),
         true <- function_exported?(module, :__notification_binding__, 0),
         %{relay: _, port: _, sender: _} = settings <- module.__notification_binding__(),
         true <- settings == settings!(Map.merge(settings, %{id: b.id, recovery_grace_ms: 0})),
         true <- b.provider_account == account(settings) do
      {:ok, b, settings}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end
end
