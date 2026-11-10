# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Binding do
  @moduledoc """
  Compile-time `delivery/effect-intent` binding for one embedding-model provider
  account: `use Elzoo.AiEmbedding.Binding, id: ..., provider_account: ...,
  recovery_grace_ms: ...`. The failure table is `Elzoo.AiEmbedding.Outcome.failures/0`;
  only `credentials_unavailable` is attested no-send. No replay, no revision.
  The provider account (for example `"openai:<project label>"`) enters the
  binding digest and the intent key.
  """
  alias Elzoo.AiEmbedding.Outcome

  defmacro __using__(opts) do
    quote do
      @ai_embedding_options unquote(opts)
      @before_compile Elzoo.AiEmbedding.Binding
    end
  end

  defmacro __before_compile__(env) do
    opts = Map.new(Module.get_attribute(env.module, :ai_embedding_options))
    true = Enum.sort(Map.keys(opts)) == [:id, :provider_account, :recovery_grace_ms]

    descriptor =
      Elzoo.EffectIntent.Binding.compile!(
        adapter: Elzoo.AiEmbedding.Adapter,
        id: opts.id,
        provider_account: opts.provider_account,
        operation: "embed",
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

  @doc "Loads the descriptor and checks it is an ai-embedding binding with the Outcome table."
  def load(module) do
    with {:ok, b} <- Elzoo.EffectIntent.Binding.load(module),
         true <- b.adapter == Elzoo.AiEmbedding.Adapter and b.replay == :none,
         true <- b.operation == "embed",
         true <- b.failures == Outcome.failures(),
         true <- Enum.sort(b.no_send_attestations) == Enum.sort(Outcome.no_send()) do
      {:ok, b}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end
end
