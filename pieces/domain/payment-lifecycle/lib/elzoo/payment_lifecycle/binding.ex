# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PaymentLifecycle.Binding do
  @moduledoc """
  Compile-time `delivery/effect-intent` Binding of one operation of one provider account:
  `use Elzoo.PaymentLifecycle.Binding, operation: :charge | :refund, provider_account: ...`.
  The Adapter is `Elzoo.PaymentLifecycle.ChargeAdapter` or `RefundAdapter`, the Adapter ID
  `elzoo/payment-lifecycle/charge` or `.../refund`, the clock `unix-ms`; no replay, no revision,
  no recovery grace. `provider_account` must equal the lifecycle's, since it enters the intent
  identity and its key. The failure table is `failures/1`; `no_send/1` lists the attested
  not-dispatched tags.
  """
  @common %{
    # The provider Need attests that no byte reached the provider.
    not_sent: {"timed_out", "not_dispatched", "retryable"},
    declined: {"failed", "dispatched", "permanent"},
    # Dispatched and pollable: a pending answer, or an answer whose observation row was not
    # written.
    provider_pending: {"unknown", "dispatched", "unclassified"},
    observation_unrecorded: {"unknown", "dispatched", "unclassified"},
    timeout: {"timed_out", "unknown", "unclassified"},
    transport: {"unknown", "unknown", "unclassified"},
    adapter_error: {"unknown", "unknown", "unclassified"},
    # The operation's row could not be read before the send: no provider call.
    store_unavailable: {"timed_out", "not_dispatched", "retryable"}
  }
  # The charge is final, or a final answer of it is stored: no provider call.
  @charge Map.put(@common, :charge_closed, {"rejected", "not_dispatched", "permanent"})
  # The refund is :failed or a poll :no_effect of it is stored: no provider call.
  @refund Map.put(@common, :refund_closed, {"rejected", "not_dispatched", "permanent"})

  @doc "The failure table of an operation."
  def failures(:charge), do: @charge
  def failures(:refund), do: @refund

  @doc "The attested not-dispatched tags of an operation."
  def no_send(operation),
    do: for({tag, {_, "not_dispatched", _}} <- failures(operation), do: tag) |> Enum.sort()

  @doc "The Adapter module of an operation."
  def adapter(:charge), do: Elzoo.PaymentLifecycle.ChargeAdapter
  def adapter(:refund), do: Elzoo.PaymentLifecycle.RefundAdapter

  @doc false
  def options(operation, provider_account) when operation in [:charge, :refund] do
    [
      adapter: adapter(operation),
      id: Elzoo.PaymentLifecycle.adapter_id(operation),
      provider_account: provider_account,
      operation: Atom.to_string(operation),
      clock: "unix-ms",
      failures: failures(operation),
      no_send_attestations: no_send(operation),
      recovery_grace_ms: :none,
      replay: :none
    ]
  end

  defmacro __using__(opts) do
    quote do
      @payment_lifecycle_options unquote(opts)
      @before_compile Elzoo.PaymentLifecycle.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :payment_lifecycle_options))

    unless Enum.sort(Map.keys(opts)) == [:operation, :provider_account] and
             opts.operation in [:charge, :refund] and
             Elzoo.PaymentLifecycle.text?(opts.provider_account, 128),
           do: raise(ArgumentError, "invalid payment lifecycle binding")

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(options(opts.operation, opts.provider_account))

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
    end
  end
end
