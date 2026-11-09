# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Adapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter for one text-model call. Order inside the
  send task: binding and argument checks; the credential Need (a failure is the
  only attested no-send, `credentials_unavailable`); the provider's pure
  `translate/2`; exactly one `call/2`; `decode/2` or `classify_failure/1`; the
  interface's own checks of the completion (tool proposals against their declared
  schemas, structured output against the requested schema, usage and
  provenance); the volatile sink; the envelope. The Adapter never retries.

  The completed envelope carries only the response id, a digest of the typed
  outcome and a process-local seal; content, tool arguments, credentials and raw
  provider bodies never enter EffectIntent state. Failure details are fixed
  atoms.
  """
  alias Elzoo.AiModel.{Provenance, Usage}
  alias Elzoo.AiText.{Binding, Config, Outcome, Request, Schema, Sink}

  @schema "elzoo/ai-text-request-v1"
  @value_schema "elzoo/ai-text-completion"
  @finishes [:stop, :length, :tool_calls, :content_filter, :refusal]

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
         {:ok, wire} <- Elzoo.AiText.check(c, request) do
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

  # The interface's own checks of a provider's decoded completion.
  defp complete(c, request, raw) do
    caps = c.provider.capabilities()

    with %{} <- raw,
         true <- Elzoo.AiModel.text?(raw[:response_id], 256),
         true <- valid_finish?(raw[:finish]),
         {:ok, usage} <- Usage.validate(raw[:usage]),
         content when is_binary(content) <- raw[:content],
         true <- String.valid?(content),
         calls when is_list(calls) <- raw[:tool_calls],
         {:ok, provenance} <-
           Provenance.validate(%{
             model_ref: %{
               provider: caps.provider,
               model_id: request.model,
               wire_surface: caps.wire_surface
             },
             provider_model: raw[:provider_model],
             response_id: raw.response_id,
             request_id: Map.get(raw, :request_id, :absent),
             provider_piece: caps.piece
           }) do
      {:completed,
       %{
         content: content,
         tool_proposals: Enum.map(calls, &proposal(&1, request)),
         structured: structured(request, raw[:structured_json]),
         finish: raw.finish,
         usage: usage,
         provenance: provenance
       }}
    else
      _ -> {:failure, :malformed_response, %{}}
    end
  end

  defp valid_finish?(f) when f in @finishes, do: true
  defp valid_finish?({:other, raw}), do: Elzoo.AiModel.text?(raw, 64)
  defp valid_finish?(_), do: false

  # A proposal is data. Invalid JSON, a non-object, an undeclared tool or a
  # schema mismatch is returned marked malformed, never dropped or repaired.
  defp proposal(call, request) do
    base = %{
      id: text_or_nil(call[:id]),
      name: text_or_nil(call[:name]),
      raw_arguments: call[:arguments_json],
      arguments: nil,
      malformed: nil
    }

    tool = Enum.find(request.tools, &(&1.name == call[:name]))

    with json when is_binary(json) <- call[:arguments_json],
         {:ok, args} when is_map(args) <- decode_json(json),
         {:declared, %{input_schema: s}} <- {:declared, tool},
         {:ok, root} <- Schema.build(s),
         :ok <- Schema.validate(args, root) do
      %{base | arguments: args}
    else
      {:declared, nil} -> %{base | malformed: :undeclared_tool}
      {:error, :schema_mismatch} -> %{base | malformed: :schema_mismatch}
      {:ok, _not_object} -> %{base | malformed: :not_an_object}
      _ -> %{base | malformed: :invalid_json}
    end
  end

  defp text_or_nil(v), do: if(Elzoo.AiModel.text?(v, 256), do: v, else: nil)

  defp structured(%{output_schema: nil}, _), do: nil

  defp structured(%{output_schema: schema}, json) do
    with true <- is_binary(json) || {:error, :missing},
         {:ok, value} <- decode_json(json),
         {:ok, root} <- Schema.build(schema),
         :ok <- Schema.validate(value, root) do
      {:valid, value}
    else
      {:error, :missing} -> {:invalid, :missing}
      {:error, :schema_mismatch} -> {:invalid, :schema_mismatch}
      _ -> {:invalid, :invalid_json}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, v} -> {:ok, v}
      _ -> {:error, :invalid_json}
    end
  end

  defp finish(c, key, attempt_id, {:completed, body} = outcome) do
    _ = Sink.deliver(c.sink, key, attempt_id, outcome)
    digest = digest(outcome)
    response_id = body.provenance.response_id

    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{
        "response_id" => response_id,
        "outcome_digest" => digest,
        "seal" => seal(c, key, attempt_id, response_id, digest)
      },
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
  defp failure(tag), do: {:error, tag, :ai_text}

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
          "value" => %{"response_id" => r, "outcome_digest" => d, "seal" => s} = v
        },
        _req
      ) do
    if map_size(v) == 3 and Elzoo.AiModel.text?(r, 256) and hex64?(d) and hex64?(s),
      do: :ok,
      else: :error
  end

  def validate_result(_, _), do: :error

  def authenticate({:unavailable, :no_status_query}, _), do: :ok

  # Process-local integrity of this Adapter's own result, not provider
  # authentication: a forged or post-restart completion fails.
  def authenticate(
        %{
          "attempt_id" => attempt_id,
          "value" => %{"response_id" => r, "outcome_digest" => d, "seal" => s}
        },
        %{key: key, attempt_id: attempt_id, context: %Config{} = c}
      )
      when is_binary(s) do
    expected = seal(c, key, attempt_id, r, d)

    if byte_size(s) == byte_size(expected) and :crypto.hash_equals(s, expected),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  def authenticate(_, _), do: :error

  defp hex64?(v), do: is_binary(v) and byte_size(v) == 64 and v =~ ~r/\A[0-9a-f]+\z/

  defp seal(%Config{seal_key: k}, key, attempt_id, response_id, digest) do
    data =
      Enum.map([key, attempt_id, response_id, digest], &<<byte_size(&1)::32, &1::binary>>)

    :crypto.mac(:hmac, :sha256, k, data) |> Base.encode16(case: :lower)
  end
end
