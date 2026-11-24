# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PaymentLifecycle.Provider do
  @moduledoc """
  The provider Need of `domain/payment-lifecycle`: one payment provider account, implemented
  by a later provider Piece (`integration/payments`) or by the host. The Piece calls each
  callback at most once per call of its own and never retries.

  `idempotency_key` is the `delivery/effect-intent` derived key of the operation's intent; it
  derives from the logical payment or refund ID and never from an Attempt, and the provider
  must deduplicate by it. `{:not_sent, reason}` is the implementation's attestation that no
  byte of the request reached the provider. `verify_event/2` checks the provider's signature
  over the raw body before it parses anything. Codes, refs and event IDs are 1..256 bytes of
  valid UTF-8 without a control character. The README states this Contract in full.
  """
  alias Elzoo.Money.Amount

  @type state :: :succeeded | :pending | :failed
  @type result :: %{provider_ref: String.t(), state: state()}
  @type send_answer ::
          {:ok, result()}
          | {:declined, String.t()}
          | {:not_sent, term()}
          | {:unknown, :timeout | :transport}

  @callback charge(%{
              idempotency_key: String.t(),
              payment_id: String.t(),
              amount: %Amount{},
              recipient: String.t()
            }) :: send_answer()

  @callback refund(%{
              idempotency_key: String.t(),
              payment_id: String.t(),
              refund_id: String.t(),
              provider_ref: String.t(),
              amount: %Amount{}
            }) :: send_answer()

  @callback poll(%{idempotency_key: String.t(), kind: :charge | :refund}) ::
              {:ok, result()} | :no_effect | :pending | :unavailable

  @callback verify_event(raw_body :: binary(), headers :: [{binary(), binary()}]) ::
              {:ok,
               %{
                 event_id: String.t(),
                 operation: {:charge, String.t()} | {:refund, String.t(), String.t()},
                 state: state(),
                 amount: %Amount{},
                 provider_ref: String.t()
               }}
              | {:error, :invalid}
end
