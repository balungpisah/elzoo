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
    :sink,
    :artifacts,
    :image_bounds
  ]
  @default_image_bounds %{max_image_bytes: 5_242_880, max_total_image_bytes: 20_971_520}

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

  Image input (Contract amendment 2): optional `artifacts`, the artifact read
  Need, a one-arity function given `%{artifact_id, version}` that returns what
  `Elzoo.Artifact.get/4` returns (the host wraps it with its own store and
  caller), and optional `image_bounds`, `%{max_image_bytes: 1..5,242,880,
  max_total_image_bytes: 1..41,943,040}` (default 5,242,880 and 20,971,520).
  Without `artifacts`, a request with image parts is refused
  `:unsupported_feature`.
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
           Keyword.get(opts, :receive_timeout_ms, 120_000),
         true <- opts[:artifacts] == nil or is_function(opts[:artifacts], 1),
         bounds = Keyword.get(opts, :image_bounds, @default_image_bounds),
         true <- image_bounds?(bounds) do
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
         seal_key: :crypto.strong_rand_bytes(32),
         artifacts: opts[:artifacts],
         image_bounds: bounds
       }}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  defp image_bounds?(%{max_image_bytes: one, max_total_image_bytes: all} = b),
    do:
      map_size(b) == 2 and is_integer(one) and one in 1..5_242_880 and is_integer(all) and
        all in 1..41_943_040

  defp image_bounds?(_), do: false

  @doc """
  Admits a `core/effect` declaration: untrusted classification, capability
  `integration/ai-text`, operation `generate`, command schema
  `elzoo/ai-text-request` version 1, explicit `idempotency_key` (the logical
  request reference) and `deadline_unix_ms`, payload the request JSON. Returns
  `{:ok, %{key, identity, arguments, deadline}}` for the host to start
  `Elzoo.EffectIntent` with `adapter_context: config`, `{:error, {:refused,
  reason}}` for a locally decided refusal (`:invalid_request`,
  `:unsupported_feature`, `:too_large`, `:input_unavailable`), or `{:error,
  :declaration}`. It never creates an intent, reads the credential or calls the
  provider's transport; for a request with image parts it calls the artifact
  Need once per image part (see `check/2`).
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
        {:error, reason}
        when reason in [:invalid_request, :unsupported_feature, :too_large, :input_unavailable] ->
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
  levels, declared and valid provider options, compilable schemas; then the
  resolution of each image part through the artifact Need; then the provider's
  pure `translate/2`. Returns `{:ok, wire}` or `{:error, reason}`.

  Resolution (Contract amendment 2) calls the Need once per image part, in
  order, and accepts an answer `{:ok, %{record: record, bytes: bytes}}` whose
  record names the referenced `artifact_id` and `version`, whose `size_bytes`
  equals `byte_size(bytes)` and whose `sha256` equals the lowercase hex SHA-256
  of `<<hash_format::8, bytes>>`; a record `media_type` other than the part's is
  `:invalid_request`; an image over `max_image_bytes`, or images together over
  `max_total_image_bytes`, is `:too_large`; any other failure (an error, a
  raise, another shape, a mismatch) is `:input_unavailable`. The provider then
  gets each image part as `%{type: :image, media_type: m, bytes: bytes}`.
  """
  def check(%Config{} = c, request) do
    case prepare(c, request) do
      {:error, {:resolve, reason}} -> {:error, reason}
      other -> other
    end
  end

  @doc false
  # check/2 with a resolution failure kept apart as {:error, {:resolve, reason}},
  # so that the Adapter reports it as the attested no-send input_unavailable.
  def prepare(%Config{} = c, request) do
    with :ok <- neutral(c, request),
         {:ok, resolved} <- resolve(c, request) do
      translate(c, resolved)
    end
  end

  defp neutral(c, request) do
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

      images(request) != [] and (:image_input not in features or c.artifacts == nil) ->
        {:error, :unsupported_feature}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp translate(c, request) do
    case c.provider.translate(request, c.provider_config) do
      {:ok, wire} ->
        {:ok, wire}

      {:refused, r} when r in [:invalid_request, :unsupported_feature, :too_large] ->
        {:error, r}

      _ ->
        {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp images(request),
    do: for(%{parts: parts} <- request.messages, %{type: :image} = p <- parts, do: p)

  # Resolves the image parts in message order; a request without image parts
  # is returned unchanged without a Need call.
  defp resolve(c, request) do
    if images(request) == [] do
      {:ok, request}
    else
      request.messages
      |> Enum.map_reduce({:ok, 0}, fn
        %{parts: parts} = m, acc ->
          {parts, acc} = Enum.map_reduce(parts, acc, &resolve_part(c, &1, &2))
          {%{m | parts: parts}, acc}

        m, acc ->
          {m, acc}
      end)
      |> case do
        {messages, {:ok, _total}} -> {:ok, %{request | messages: messages}}
        {_, {:error, reason}} -> {:error, {:resolve, reason}}
      end
    end
  end

  defp resolve_part(_c, part, {:error, _} = failed), do: {part, failed}
  defp resolve_part(_c, %{type: :text} = part, acc), do: {part, acc}

  defp resolve_part(c, %{type: :image} = part, {:ok, total}) do
    bounds = c.image_bounds

    case read(c.artifacts, part) do
      {:ok, bytes} when byte_size(bytes) > bounds.max_image_bytes ->
        {part, {:error, :too_large}}

      {:ok, bytes} when total + byte_size(bytes) > bounds.max_total_image_bytes ->
        {part, {:error, :too_large}}

      {:ok, bytes} ->
        {%{type: :image, media_type: part.media_type, bytes: bytes},
         {:ok, total + byte_size(bytes)}}

      {:error, reason} ->
        {part, {:error, reason}}
    end
  end

  # One Need call; the answer must be the referenced version, with bytes that
  # match its recorded size and content hash.
  defp read(need, part) do
    with {:ok, %{record: %{} = r, bytes: bytes}} when is_binary(bytes) <-
           need.(%{artifact_id: part.artifact_id, version: part.version}),
         true <- Map.get(r, :artifact_id) == part.artifact_id,
         true <- Map.get(r, :version) == part.version,
         true <- Map.get(r, :size_bytes) == byte_size(bytes),
         format when is_integer(format) and format in 1..255 <- Map.get(r, :hash_format),
         true <- Map.get(r, :sha256) == content_hash(format, bytes) do
      if Map.get(r, :media_type) == part.media_type,
        do: {:ok, bytes},
        else: {:error, :invalid_request}
    else
      _ -> {:error, :input_unavailable}
    end
  rescue
    _ -> {:error, :input_unavailable}
  catch
    _, _ -> {:error, :input_unavailable}
  end

  defp content_hash(format, bytes),
    do: :crypto.hash(:sha256, <<format::8, bytes::binary>>) |> Base.encode16(case: :lower)

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
