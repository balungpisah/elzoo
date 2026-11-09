# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Binding do
  @moduledoc """
  Compile-time `delivery/effect-intent` bindings for one batch provider account:
  `use Elzoo.AiBatch.Binding, operation: :submit | :cancel, id: ...,
  provider_account: ..., recovery_grace_ms: ...`. A submit binding uses
  `Elzoo.AiBatch.SubmitAdapter`, a cancel binding `Elzoo.AiBatch.CancelAdapter`.
  Both use the failure table of the text interface's Cure decision
  (`Elzoo.AiText.Outcome.failures/0`); only `credentials_unavailable` is attested
  no-send. No replay, no revision. The provider account enters the binding digest
  and the intent key.
  """
  alias Elzoo.AiText.Outcome

  @adapters %{submit: Elzoo.AiBatch.SubmitAdapter, cancel: Elzoo.AiBatch.CancelAdapter}

  def adapters, do: @adapters

  defmacro __using__(opts) do
    quote do
      @ai_batch_options unquote(opts)
      @before_compile Elzoo.AiBatch.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :ai_batch_options))
    true = Enum.sort(Map.keys(opts)) == [:id, :operation, :provider_account, :recovery_grace_ms]
    adapter = Map.fetch!(@adapters, opts.operation)

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: adapter,
        id: opts.id,
        provider_account: opts.provider_account,
        operation: Atom.to_string(opts.operation),
        clock: "unix-ms",
        failures: Outcome.failures(),
        no_send_attestations: Outcome.no_send(),
        recovery_grace_ms: opts.recovery_grace_ms,
        replay: :none
      )

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
    end
  end

  @doc "Loads the descriptor and checks it is an ai-batch binding of `operation` with the Outcome table."
  def load(module, operation) when operation in [:submit, :cancel] do
    with {:ok, b} <- Elzoo.EffectIntent.Binding.load(module),
         true <- b.adapter == Map.fetch!(@adapters, operation) and b.replay == :none,
         true <- b.operation == Atom.to_string(operation),
         true <- b.failures == Outcome.failures(),
         true <- Enum.sort(b.no_send_attestations) == Enum.sort(Outcome.no_send()) do
      {:ok, b}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end

  def load(_, _), do: {:error, :binding}
end
