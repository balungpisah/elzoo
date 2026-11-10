# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Adapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter for one embedding call. Order inside the
  send task: binding and argument checks; the credential Need (a failure is the
  only attested no-send, `credentials_unavailable`); the provider's pure
  `translate/2`; exactly one `call/2`; `decode/2` or `classify_failure/1`; the
  interface's own checks of the response; the volatile sink; the envelope. The
  Adapter never retries.

  Response checks (any defect is `unknown{malformed_response}`, never a shorter
  or partial list): exactly one item per input; the indices exactly
  `0..length(inputs)-1`; every vector exactly the expected dimension; every
  element a finite number within the float32 range (integers are taken as
  floats); the served model equal to the requested model; a valid usage value
  and provenance. Only then are the items sorted by their validated index, so
  input order is list order, and the normalization is computed
  (`Elzoo.AiEmbedding.Descriptor.normalization/1`): a vector outside the fixed
  tolerance completes with `normalization: :none`.

  The completed envelope carries only a digest of the typed outcome and a
  process-local seal; vectors, input texts, credentials and raw provider bodies
  never enter EffectIntent state. Failure details are fixed atoms.
  """
  alias Elzoo.AiModel.{Provenance, Usage}
  alias Elzoo.AiEmbedding.{Binding, Config, Descriptor, Outcome, Request, Sink}

  @schema "elzoo/ai-embedding-request-v1"
  @value_schema "elzoo/ai-embedding-result"

  def failure_tags, do: Outcome.tags()
  def schema, do: @schema

  def validate(bytes, @schema) do
    case Request.decode(bytes) do
      {:ok, _, ^bytes} -> :ok
      _ -> {:error, :schema}
    end
  end

  def validate(_, _), do: {:error, :schema}

  def send_effect(req) do
    with %{context: %Config{} = c, key: key, attempt_id: attempt_id} <- req,
         {:ok, b} <- Binding.load(c.binding),
         true <- b.digest == req.binding,
         true <- is_binary(req.arguments),
         {:ok, request, _} <- Request.decode(req.arguments, c.max_request_bytes),
         {:ok, wire} <- Elzoo.AiEmbedding.check(c, request) do
      case credential(c) do
        {:ok, secret} ->
          outcome = exchange(c, request, wire, secret)
          finish(c, key, attempt_id, outcome)

        :error ->
          finish(c, key, attempt_id, {:failure, :credentials_unavailable, %{}})
      end
    else
      _ -> failure(:adapter_error)
    end
  rescue
    _ -> failure(:adapter_error)
  catch
    _, _ -> failure(:adapter_error)
  end

  # The injected Need: {:ok, binary} of 1..1024 printable ASCII bytes, without
  # whitespace or control characters. Anything else, or a raise/throw/exit, is
  # credentials_unavailable. The value is never inspected or interpolated.
  defp credential(%Config{credentials: need}) do
    case need.() do
      {:ok, secret} when is_binary(secret) and byte_size(secret) in 1..1024 ->
        if printable?(secret), do: {:ok, secret}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp printable?(<<>>), do: true
  defp printable?(<<c, rest::binary>>) when c in 0x21..0x7E, do: printable?(rest)
  defp printable?(_), do: false

  # Exactly one provider call. Every exception after the credential was read is
  # adapter_error (unknown): bytes may have reached transport.
  defp exchange(c, request, wire, secret) do
    provider = c.provider
    call_opts = %{credential: secret, receive_timeout_ms: c.receive_timeout_ms}

    case provider.call(wire, call_opts) do
      {:ok, exchange} ->
        case provider.decode(exchange, request) do
          {:ok, raw} -> complete(c, request, raw)
          {:failure, tag} -> {:failure, provider_tag(tag), %{}}
          {:failure, tag, meta} -> {:failure, provider_tag(tag), meta(meta)}
          _ -> {:failure, :malformed_response, %{}}
        end

      {:transport, _} = t ->
        {:failure, provider_tag(provider.classify_failure(t)), %{}}

      _ ->
        {:failure, :adapter_error, %{}}
    end
  rescue
    _ -> {:failure, :adapter_error, %{}}
  catch
    _, _ -> {:failure, :adapter_error, %{}}
  end

  defp provider_tag(tag), do: if(tag in Outcome.provider_tags(), do: tag, else: :adapter_error)

  defp meta(%{retry_after: s}) when is_integer(s) and s >= 0 and s <= 86_400, do: %{retry_after: s}
  defp meta(_), do: %{}

  # The interface's own checks of a provider's decoded response.
  defp complete(c, request, raw) do
    caps = c.provider.capabilities()
    n = length(request.inputs)
    dims = Elzoo.AiEmbedding.expected_dimensions(c, request)

    with %{} <- raw,
         items when is_list(items) and length(items) == n <- raw[:items],
         {:ok, embeddings} <- embeddings(items, n, dims),
         true <- raw[:provider_model] == request.model,
         {:ok, usage} <- Usage.validate(raw[:usage]),
         {:ok, provenance} <-
           Provenance.validate(%{
             model_ref: %{
               provider: caps.provider,
               model_id: request.model,
               wire_surface: caps.wire_surface
             },
             provider_model: raw.provider_model,
             response_id: Map.get(raw, :response_id, :absent),
             request_id: Map.get(raw, :request_id, :absent),
             provider_piece: caps.piece
           }),
         descriptor = %{
           provider: caps.provider,
           model: request.model,
           dimensions: dims,
           dtype: :float32,
           normalization: Descriptor.normalization(Enum.map(embeddings, & &1.vector))
         },
         {:ok, _} <- Descriptor.validate(descriptor) do
      {:completed,
       %{embeddings: embeddings, descriptor: descriptor, usage: usage, provenance: provenance}}
    else
      _ -> {:failure, :malformed_response, %{}}
    end
  end

  # Exactly the index set 0..n-1, each vector of `dims` finite float32-range
  # numbers; sorted by the validated index.
  defp embeddings(items, n, dims) do
    parsed =
      Enum.map(items, fn
        %{index: i, vector: v} when is_integer(i) and i >= 0 and i < n and is_list(v) ->
          if length(v) == dims, do: {i, floats(v)}, else: :error

        _ ->
          :error
      end)

    with true <- Enum.all?(parsed, &match?({_, {:ok, _}}, &1)),
         indices = Enum.map(parsed, &elem(&1, 0)),
         true <- Enum.sort(indices) == Enum.to_list(0..(n - 1)) do
      {:ok,
       parsed
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map(fn {i, {:ok, v}} -> %{index: i, vector: v} end)}
    else
      _ -> :error
    end
  end

  defp floats(v) do
    max = Descriptor.float32_max()

    Enum.reduce_while(v, {:ok, []}, fn
      x, {:ok, acc} when is_number(x) and abs(x) <= max -> {:cont, {:ok, [x * 1.0 | acc]}}
      _, _ -> {:halt, :error}
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp finish(c, key, attempt_id, {:completed, _} = outcome) do
    _ = Sink.deliver(c.sink, key, attempt_id, outcome)
    digest = digest(outcome)

    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"outcome_digest" => digest, "seal" => seal(c, key, attempt_id, digest)},
      "value_schema_id" => @value_schema,
      "value_schema_version" => 1
    }
  end

  defp finish(c, key, attempt_id, {:failure, tag, meta}) do
    {:ok, contract} = Outcome.contract(tag)

    delivered =
      case contract do
        {:refused, reason} -> {:refused, reason, Map.merge(%{retry_after: nil}, meta)}
        {:unknown, reason} -> {:unknown, reason}
      end

    _ = Sink.deliver(c.sink, key, attempt_id, delivered)
    failure(tag)
  end

  # Detail is a fixed atom: never provider text, a body or an exception.
  defp failure(tag), do: {:error, tag, :ai_embedding}

  defp digest(outcome),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(outcome, [:deterministic]))
      |> Base.encode16(case: :lower)

  @doc "No provider status query in this slice: an unknown outcome stays unknown until reconciliation."
  def poll(_req), do: {:unavailable, :no_status_query}

  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => @value_schema,
          "value_schema_version" => 1,
          "value" => %{"outcome_digest" => d, "seal" => s} = v
        },
        _req
      ) do
    if map_size(v) == 2 and hex64?(d) and hex64?(s), do: :ok, else: :error
  end

  def validate_result(_, _), do: :error

  def authenticate({:unavailable, :no_status_query}, _), do: :ok

  # Process-local integrity of this Adapter's own result, not provider
  # authentication: a forged or post-restart completion fails.
  def authenticate(
        %{"attempt_id" => attempt_id, "value" => %{"outcome_digest" => d, "seal" => s}},
        %{key: key, attempt_id: attempt_id, context: %Config{} = c}
      )
      when is_binary(s) do
    expected = seal(c, key, attempt_id, d)

    if byte_size(s) == byte_size(expected) and :crypto.hash_equals(s, expected),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  def authenticate(_, _), do: :error

  defp hex64?(v), do: is_binary(v) and byte_size(v) == 64 and v =~ ~r/\A[0-9a-f]+\z/

  defp seal(%Config{seal_key: k}, key, attempt_id, digest) do
    data = Enum.map([key, attempt_id, digest], &<<byte_size(&1)::32, &1::binary>>)
    :crypto.mac(:hmac, :sha256, k, data) |> Base.encode16(case: :lower)
  end
end
