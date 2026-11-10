# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding do
  @moduledoc """
  The provider-neutral embedding interface: trusted construction
  (`configure/1`), admission of a `core/effect` declaration (`admission/2`,
  which refuses locally decided requests before any intent exists), the
  `delivery/effect-intent` Adapter (`Elzoo.AiEmbedding.Adapter`), the Contract
  outcome of a failure tag (`outcome/1`) and the bounded retry decision
  (`Elzoo.AiEmbedding.Retry`). The Contract is in the Piece documentation.
  """
  alias Elzoo.AiEmbedding.{Binding, Config, Outcome, Provider, Request}

  @capability "integration/ai-embedding"
  @operation "embed"
  @schema_id "elzoo/ai-embedding-request"
  @max_bigint 9_223_372_036_854_775_807
  @options [
    :binding,
    :tenant,
    :provider,
    :provider_config,
    :credentials,
    :models,
    :max_inputs,
    :max_input_bytes,
    :max_request_bytes,
    :receive_timeout_ms,
    :sink
  ]

  @doc """
  Builds the trusted Config. Options: `binding` (a module using
  `Elzoo.AiEmbedding.Binding`), `tenant`, `provider` (a module implementing
  `Elzoo.AiEmbedding.Provider`), `provider_config` (the provider's own
  construction term, checked by its `translate/2`), `credentials` (the injected
  credential Need: a zero-arity function returning `{:ok, binary}`), `models`
  (the allowlist, 1..64 identifiers, each declared by the provider), `sink` (see
  `Elzoo.AiEmbedding.Sink`), optional `max_inputs` (1..2048 and at most the
  provider's own limit, default 128), `max_input_bytes` (1..65,536, default
  32,768), `max_request_bytes` (1..65,536, default 65,536; the canonical payload
  bound) and `receive_timeout_ms` (1..600,000, default 60,000). Fixed for the
  Config's lifetime; no hot update. The norm tolerance is fixed by the Contract
  (`Elzoo.AiEmbedding.Descriptor.tolerance/0`), not a setting.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)),
         {:ok, _} <- Binding.load(opts[:binding]),
         true <- Outcome.verify(),
         true <- Elzoo.AiModel.text?(opts[:tenant], 256),
         provider when is_atom(provider) <- opts[:provider],
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0),
         caps = provider.capabilities(),
         true <- Provider.valid_capabilities?(caps),
         true <- is_function(opts[:credentials], 0) and is_function(opts[:sink], 2),
         models when is_list(models) and length(models) in 1..64 <- opts[:models],
         true <-
           Enum.all?(models, &(Elzoo.AiModel.text?(&1, 256) and Map.has_key?(caps.models, &1))),
         n when is_integer(n) and n in 1..2048 and n <= caps.max_inputs <-
           Keyword.get(opts, :max_inputs, min(128, caps.max_inputs)),
         per when is_integer(per) and per in 1..65_536 <-
           Keyword.get(opts, :max_input_bytes, 32_768),
         max when is_integer(max) and max in 1..65_536 <-
           Keyword.get(opts, :max_request_bytes, 65_536),
         timeout when is_integer(timeout) and timeout in 1..600_000 <-
           Keyword.get(opts, :receive_timeout_ms, 60_000) do
      {:ok,
       %Config{
         binding: opts[:binding],
         tenant: opts[:tenant],
         provider: provider,
         provider_config: Keyword.get(opts, :provider_config),
         credentials: opts[:credentials],
         models: models,
         max_inputs: n,
         max_input_bytes: per,
         max_request_bytes: max,
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
  `integration/ai-embedding`, operation `embed`, command schema
  `elzoo/ai-embedding-request` version 1, explicit `idempotency_key` (the
  logical request reference) and `deadline_unix_ms`, payload the request JSON.
  Returns `{:ok, %{key, identity, arguments, deadline}}` for the host to start
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
  input count and bytes per input (`:too_large`), dimensions declared for the
  model, declared input type (`:unsupported_feature` otherwise), declared and
  valid provider options, then the provider's pure `translate/2`. Returns
  `{:ok, wire}` or `{:error, reason}`.
  """
  def check(%Config{} = c, request) do
    caps = c.provider.capabilities()

    cond do
      request.model not in c.models ->
        {:error, :invalid_request}

      length(request.inputs) > c.max_inputs ->
        {:error, :too_large}

      Enum.any?(request.inputs, &(byte_size(&1) > c.max_input_bytes)) ->
        {:error, :too_large}

      not dimensions_valid?(request.dimensions, caps.models[request.model]) ->
        {:error, :invalid_request}

      request.input_type not in caps.input_types ->
        {:error, :unsupported_feature}

      not options_valid?(request.provider_options, caps.options) ->
        {:error, :invalid_request}

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

  @doc "The vector dimension a request expects: its `dimensions`, or the model's native one."
  def expected_dimensions(%Config{} = c, request) do
    request.dimensions || c.provider.capabilities().models[request.model].native
  end

  defp dimensions_valid?(nil, %{}), do: true
  defp dimensions_valid?(n, %{min: lo, max: hi}), do: is_integer(n) and n >= lo and n <= hi
  defp dimensions_valid?(_, _), do: false

  defp options_valid?(options, declared) do
    Enum.all?(options, fn {k, v} ->
      case Map.fetch(declared, k) do
        {:ok, validator} -> validator.(v) == :ok
        :error -> false
      end
    end)
  end

  @doc "Contract outcome of a failure tag: `{:ok, {:refused | :unknown, reason}}`."
  def outcome(tag), do: Outcome.contract(tag)
end
