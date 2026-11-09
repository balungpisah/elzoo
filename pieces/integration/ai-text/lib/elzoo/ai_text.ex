# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText do
  @moduledoc """
  The provider-neutral text-model interface: trusted construction
  (`configure/1`), admission of a `core/effect` declaration (`admission/2`,
  which refuses locally decided requests before any intent exists), the
  `delivery/effect-intent` Adapter (`Elzoo.AiText.Adapter`), the Contract
  outcome of a failure tag (`outcome/1`) and the bounded retry decision
  (`Elzoo.AiText.Retry`). The Contract is in the Piece documentation.
  """
  alias Elzoo.AiModel.CacheHint
  alias Elzoo.AiText.{Binding, Config, Outcome, Provider, Request, Schema}

  @capability "integration/ai-text"
  @operation "generate"
  @schema_id "elzoo/ai-text-request"
  @max_bigint 9_223_372_036_854_775_807
  @options [
    :binding,
    :tenant,
    :provider,
    :provider_config,
    :credentials,
    :models,
    :max_request_bytes,
    :max_output_tokens,
    :receive_timeout_ms,
    :sink
  ]

  @doc """
  Builds the trusted Config. Options: `binding` (a module using
  `Elzoo.AiText.Binding`), `tenant`, `provider` (a module implementing
  `Elzoo.AiText.Provider`), `provider_config` (the provider's own construction
  term, checked by the provider's `translate/2`), `credentials` (the injected
  credential Need: a zero-arity function returning `{:ok, binary}`), `models`
  (the model allowlist, 1..64 identifiers), `sink` (see `Elzoo.AiText.Sink`),
  optional `max_request_bytes` (1..65,536, default 65,536), `max_output_tokens`
  (cap, 1..1,000,000, default 64,000) and `receive_timeout_ms` (1..600,000,
  default 120,000). Fixed for the Config's lifetime; no hot update.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)),
         {:ok, _} <- Binding.load(opts[:binding]),
         true <- Outcome.verify(),
         true <- Elzoo.AiModel.text?(opts[:tenant], 256),
         provider when is_atom(provider) <- opts[:provider],
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0),
         true <- Provider.valid_capabilities?(provider.capabilities()),
         true <- is_function(opts[:credentials], 0) and is_function(opts[:sink], 2),
         models when is_list(models) and length(models) in 1..64 <- opts[:models],
         true <- Enum.all?(models, &Elzoo.AiModel.text?(&1, 256)),
         max when is_integer(max) and max in 1..65_536 <-
           Keyword.get(opts, :max_request_bytes, 65_536),
         out when is_integer(out) and out in 1..1_000_000 <-
           Keyword.get(opts, :max_output_tokens, 64_000),
         timeout when is_integer(timeout) and timeout in 1..600_000 <-
           Keyword.get(opts, :receive_timeout_ms, 120_000) do
      {:ok,
       %Config{
         binding: opts[:binding],
         tenant: opts[:tenant],
         provider: provider,
         provider_config: Keyword.get(opts, :provider_config),
         credentials: opts[:credentials],
         models: models,
         max_request_bytes: max,
         max_output_tokens: out,
         receive_timeout_ms: timeout,
         sink: opts[:sink],
         seal_key: :crypto.strong_rand_bytes(32)
       }}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  @doc """
  Admits a `core/effect` declaration: untrusted classification, capability
  `integration/ai-text`, operation `generate`, command schema
  `elzoo/ai-text-request` version 1, explicit `idempotency_key` (the logical
  request reference) and `deadline_unix_ms`, payload the request JSON. Returns
  `{:ok, %{key, identity, arguments, deadline}}` for the host to start
  `Elzoo.EffectIntent` with `adapter_context: config`, `{:error, {:refused,
  reason}}` for a locally decided refusal (`:invalid_request`,
  `:unsupported_feature`, `:too_large`), or `{:error, :declaration}`. It never
  creates an intent, reads the credential or calls the provider's transport.
  """
  def admission(%Config{} = c, declaration) do
    with {:ok, _} <- Elzoo.Effect.validate(declaration),
         "untrusted" <- declaration["classification"],
         @capability <- declaration["capability_id"],
         @operation <- declaration["operation"],
         command = declaration["command"],
         @schema_id <- command["schema_id"],
         1 <- command["schema_version"],
         ref when is_binary(ref) <- command["idempotency_key"],
         true <- Elzoo.AiModel.text?(ref, 256),
         deadline when is_integer(deadline) and deadline >= 0 and deadline <= @max_bigint <-
           command["deadline_unix_ms"],
         payload when is_binary(payload) <- command["payload"],
         {:ok, b} <- Binding.load(c.binding),
         {:ok, _} <- Elzoo.EffectIntent.Binding.recovery_deadline(deadline, b.recovery_grace_ms) do
      with {:ok, request, canonical} <- Request.decode(payload, c.max_request_bytes),
           {:ok, _wire} <- check(c, request) do
        identity = [c.tenant, b.provider_account, b.id, b.operation, ref]

        {:ok,
         %{
           key: Elzoo.EffectIntent.Model.key(identity),
           identity: identity,
           arguments: canonical,
           deadline: deadline
         }}
      else
        {:error, reason} when reason in [:invalid_request, :unsupported_feature, :too_large] ->
          {:error, {:refused, reason}}

        _ ->
          {:error, {:refused, :invalid_request}}
      end
    else
      _ -> {:error, :declaration}
    end
  rescue
    _ -> {:error, :declaration}
  end

  def admission(_, _), do: {:error, :declaration}

  @doc """
  The neutral checks shared by admission and the Adapter: model allowlist,
  output cap, cache-hint tenant equality, declared features and reasoning
  levels, declared and valid provider options, compilable schemas, then the
  provider's pure `translate/2`. Returns `{:ok, wire}` or `{:error, reason}`.
  """
  def check(%Config{} = c, request) do
    caps = c.provider.capabilities()
    features = caps.features

    cond do
      request.model not in c.models ->
        {:error, :invalid_request}

      request.max_output_tokens > c.max_output_tokens ->
        {:error, :invalid_request}

      request.cache_hint != nil and
          not match?({:ok, _}, CacheHint.validate(request.cache_hint, c.tenant)) ->
        {:error, :invalid_request}

      not options_valid?(request.provider_options, caps.options) ->
        {:error, :invalid_request}

      not schemas_valid?(request) ->
        {:error, :invalid_request}

      unsupported?(request, caps, features) ->
        {:error, :unsupported_feature}

      true ->
        case c.provider.translate(request, c.provider_config) do
          {:ok, wire} ->
            {:ok, wire}

          {:refused, r} when r in [:invalid_request, :unsupported_feature, :too_large] ->
            {:error, r}

          _ ->
            {:error, :invalid_request}
        end
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp unsupported?(r, caps, features) do
    (r.tools != [] and :tools not in features) or
      (r.output_schema != nil and :structured_output not in features) or
      (r.sampling != nil and :sampling not in features) or
      (r.stop_sequences != [] and :stop_sequences not in features) or
      (r.cache_hint != nil and
         (:cache_hint not in features or r.cache_hint.ttl not in caps.cache_ttls)) or
      (r.reasoning != :none and (:reasoning not in features or r.reasoning not in caps.reasoning))
  end

  defp options_valid?(options, declared) do
    Enum.all?(options, fn {k, v} ->
      case Map.fetch(declared, k) do
        {:ok, validator} -> validator.(v) == :ok
        :error -> false
      end
    end)
  end

  defp schemas_valid?(r) do
    Enum.all?([r.output_schema | Enum.map(r.tools, & &1.input_schema)], fn
      nil -> true
      s -> match?({:ok, _}, Schema.build(s))
    end)
  end

  @doc "Contract outcome of a failure tag: `{:ok, {:refused | :unknown, reason}}`."
  def outcome(tag), do: Outcome.contract(tag)
end
