# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WebhookOut.Binding do
  @moduledoc """
  Compile-time `delivery/effect-intent` binding for the webhook-out Adapter:
  `use Elzoo.WebhookOut.Binding, provider_account: ..., recovery_grace_ms: ...`. The Adapter ID
  is `"webhook-out"` and the operation `"post"`; the failure table is `failures/0`, in which only
  the four not-sent tags (`:egress`, `:dns`, `:secret`, `:unavailable`) are attested no-send.
  No replay and no revision. The provider account enters the binding digest and the intent key.
  """

  # tag => {envelope outcome, dispatch, error_class}
  @failures %{
    egress: {"rejected", "not_dispatched", "unavailable"},
    dns: {"rejected", "not_dispatched", "unavailable"},
    secret: {"rejected", "not_dispatched", "unavailable"},
    unavailable: {"rejected", "not_dispatched", "unavailable"},
    retryable: {"failed", "dispatched", "retryable"},
    permanent: {"failed", "dispatched", "permanent"},
    timed_out: {"timed_out", "unknown", "unclassified"},
    transport: {"unknown", "unknown", "unclassified"}
  }
  # Only failures before any request byte reached the transport.
  @no_send [:egress, :dns, :secret, :unavailable]

  @doc false
  def failures, do: @failures
  @doc false
  def no_send, do: @no_send

  defmacro __using__(opts) do
    quote do
      @webhook_out_options unquote(opts)
      @before_compile Elzoo.WebhookOut.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :webhook_out_options))
    true = Enum.sort(Map.keys(opts)) == [:provider_account, :recovery_grace_ms]

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: Elzoo.WebhookOut.Adapter,
        id: "webhook-out",
        provider_account: opts.provider_account,
        operation: "post",
        clock: "unix-ms",
        failures: @failures,
        no_send_attestations: @no_send,
        recovery_grace_ms: opts.recovery_grace_ms,
        replay: :none
      )

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
    end
  end

  @doc "Loads the descriptor and checks that it is a webhook-out binding with this failure table."
  def load(module) do
    with {:ok, b} <- Elzoo.EffectIntent.Binding.load(module),
         true <- b.adapter == Elzoo.WebhookOut.Adapter and b.replay == :none,
         true <- b.id == "webhook-out" and b.operation == "post",
         true <- b.failures == @failures,
         true <- Enum.sort(b.no_send_attestations) == Enum.sort(@no_send) do
      {:ok, b}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end
end
