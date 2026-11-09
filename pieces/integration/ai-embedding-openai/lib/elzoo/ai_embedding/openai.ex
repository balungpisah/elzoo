# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.OpenAI do
  @moduledoc """
  The OpenAI embeddings provider of `integration/ai-embedding`, through
  `req_llm` 1.30's documented provider-callback API
  (`ReqLLM.Providers.OpenAI.prepare_request(:embedding, ...)` then
  `Req.request/1`), not the `ReqLLM.embed/3` facade (which hides the status, the
  request id and the raw usage, and returns a short list as success).

  `req_llm` resolves the model, encodes `POST /v1/embeddings` (`model`, `input`
  as an array, `dimensions` when requested, `encoding_format: "float"`, `user`
  when given), sets the bearer header and owns the transport. One Elzoo response
  step, prepended so it runs before every Req and `req_llm` response step, copies
  the status, the `x-request-id` and `retry-after` headers and the raw body, then
  halts **every** response; one Elzoo error step halts a transport exception
  unchanged. So no redirect is followed, no retry happens, `req_llm`'s decode,
  usage and error steps never run, and this module decodes the documented
  response format itself.

  Fixed settings: `req_http_options: [max_retries: 0, receive_timeout: ms]`
  (`prepare_request(:embedding, ...)` refuses top-level `max_retries` and
  `receive_timeout`; `req_llm`'s retry step reads the request's own
  `max_retries`). The credential is passed only as `api_key:` from the injected
  Need; `req_llm`'s configuration and environment fallbacks are never reached.
  """
  @behaviour Elzoo.AiEmbedding.Provider

  @piece "integration/ai-embedding-openai"
  @max_raw_bytes 268_435_456
  # OpenAI "Vector embeddings": text-embedding-3-small 1536, text-embedding-3-large
  # 3072, each shortened through the dimensions parameter.
  @models %{
    "text-embedding-3-small" => %{native: 1536, min: 1, max: 1536},
    "text-embedding-3-large" => %{native: 3072, min: 1, max: 3072}
  }

  def models, do: @models

  @impl true
  def capabilities do
    %{
      piece: @piece,
      provider: "openai",
      wire_surface: "embeddings",
      models: @models,
      input_types: [:unspecified],
      max_inputs: 2048,
      convention: Elzoo.AiEmbedding.OpenAI.Usage.convention(),
      options: %{"user" => &user/1}
    }
  end

  # The documented `user` member: an end-user identifier, here 1..256 printable ASCII.
  defp user(v) do
    if is_binary(v) and byte_size(v) in 1..256 and String.match?(v, ~r/\A[\x20-\x7E]+\z/),
      do: :ok,
      else: :error
  end

  ## translate: pure, no credential

  @impl true
  def translate(request, config) do
    with {:ok, cfg} <- provider_config(config),
         true <- Map.has_key?(@models, request.model) || {:refused, :invalid_request},
         true <- request.input_type == :unspecified || {:refused, :unsupported_feature},
         {:ok, model} <- model(request.model) do
      opts =
        [encoding_format: "float"]
        |> put_if(request.dimensions != nil, :dimensions, request.dimensions)
        |> put_if(
          Map.has_key?(request.provider_options, "user"),
          :user,
          request.provider_options["user"]
        )

      {:ok, %{model: model, inputs: request.inputs, opts: opts, config: cfg}}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

  # Provider construction term: nil, or a map with an optional HTTPS `:base_url`
  # and an optional `:plug` (the Req test transport of the tests).
  defp provider_config(nil), do: {:ok, %{}}

  defp provider_config(%{} = c) do
    if Enum.all?(Map.keys(c), &(&1 in [:base_url, :plug])) and
         (c[:base_url] == nil or
            (is_binary(c.base_url) and String.starts_with?(c.base_url, "https://"))),
       do: {:ok, c},
       else: {:refused, :invalid_request}
  end

  defp provider_config(_), do: {:refused, :invalid_request}

  defp model(id) do
    case ReqLLM.model("openai:" <> id) do
      {:ok, %{provider: :openai} = m} -> {:ok, m}
      _ -> {:refused, :invalid_request}
    end
  end

  defp put_if(opts, true, k, v), do: Keyword.put(opts, k, v)
  defp put_if(opts, false, _, _), do: opts

  ## call: exactly one HTTP exchange

  @impl true
  def call(%{model: model, inputs: inputs, opts: opts, config: cfg}, call_opts) do
    http =
      [max_retries: 0, receive_timeout: call_opts.receive_timeout_ms] ++
        if(cfg[:plug], do: [plug: cfg.plug], else: [])

    opts =
      opts ++
        [api_key: call_opts.credential, req_http_options: http] ++
        if(cfg[:base_url], do: [base_url: cfg.base_url], else: [])

    # The input is always a list, so the documented response is always a list.
    case ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, inputs, opts) do
      {:ok, request} ->
        request
        |> Req.Request.prepend_response_steps(elzoo_capture: &capture/1)
        |> Req.Request.prepend_error_steps(elzoo_halt: &halt_error/1)
        |> Req.request()
        |> exchange()

      _ ->
        # Request construction failed before any byte was sent; req_llm's
        # error value is dropped unread.
        {:transport, :not_sent}
    end
  end

  @doc false
  def capture({request, response}) do
    raw = %{
      status: response.status,
      request_id: header(response, "x-request-id"),
      retry_after: header(response, "retry-after"),
      body: if(is_binary(response.body), do: response.body, else: nil)
    }

    Req.Request.halt(request, Req.Response.put_private(response, :elzoo_raw, raw))
  end

  @doc false
  def halt_error({request, exception}), do: Req.Request.halt(request, exception)

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [v | _] when is_binary(v) and byte_size(v) <= 256 ->
        if String.match?(v, ~r/\A[\x21-\x7E]+\z/), do: v, else: nil

      _ ->
        nil
    end
  end

  defp exchange({:ok, %Req.Response{} = r}) do
    case r.private[:elzoo_raw] do
      %{} = raw -> {:ok, raw}
      _ -> {:transport, :other}
    end
  end

  defp exchange({:error, %Req.TransportError{reason: :timeout}}), do: {:transport, :timeout}
  defp exchange({:error, %Req.TransportError{reason: :closed}}), do: {:transport, :closed}
  defp exchange({:error, _}), do: {:transport, :other}

  ## decode: documented CreateEmbeddingResponse format

  @impl true
  def decode(%{status: status} = raw, _request) when status in 200..299 do
    with body when is_binary(body) and byte_size(body) <= @max_raw_bytes <- raw.body,
         {:ok, %{"object" => "list", "data" => data} = m} when is_list(data) <- Jason.decode(body),
         {:ok, items} <- items(data) do
      {:ok,
       %{
         items: items,
         provider_model: m["model"],
         usage: Elzoo.AiEmbedding.OpenAI.Usage.from_raw(Map.get(m, "usage")),
         response_id: :absent,
         request_id: raw.request_id || :absent
       }}
    else
      _ -> {:failure, :malformed_response}
    end
  end

  def decode(%{status: status} = raw, _request) when is_integer(status) do
    tag = classify_failure(raw)

    case {tag, retry_after(raw.retry_after)} do
      {t, n} when t in [:throttled, :overloaded] and is_integer(n) ->
        {:failure, t, %{retry_after: n}}

      _ ->
        {:failure, tag}
    end
  end

  # Items exactly as listed; the interface validates indices, lengths and values.
  defp items(data) do
    Enum.reduce_while(data, {:ok, []}, fn
      %{"object" => "embedding", "index" => i, "embedding" => v}, {:ok, acc} ->
        {:cont, {:ok, [%{index: i, vector: v} | acc]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp retry_after(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 86_400 -> n
      _ -> nil
    end
  end

  defp retry_after(_), do: nil

  ## classify_failure: the statuses documented for POST /embeddings (400, 401,
  ## 403, 429, 500, 503) plus 404 and 413 by their HTTP meaning.

  @impl true
  def classify_failure({:transport, :timeout}), do: :timeout
  def classify_failure({:transport, _}), do: :transport
  def classify_failure(%{status: 400}), do: :provider_invalid_request
  def classify_failure(%{status: 401}), do: :authentication_failed
  def classify_failure(%{status: 403}), do: :permission_denied
  def classify_failure(%{status: 404}), do: :not_found
  def classify_failure(%{status: 413}), do: :provider_too_large
  def classify_failure(%{status: 429}), do: :throttled
  def classify_failure(%{status: 503}), do: :overloaded
  def classify_failure(_), do: :provider_error
end
