# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Anthropic do
  @moduledoc """
  The Anthropic Messages API provider of `integration/ai-text`, through
  `req_llm` 1.30's documented provider-callback API
  (`ReqLLM.Providers.Anthropic.prepare_request/4` then `Req.request/1`).

  `req_llm` resolves the model, encodes the request body (messages, tools,
  `cache_control` markers, thinking, structured-output format), sets the
  authentication and `anthropic-version` headers and owns the transport. One
  Elzoo response step, prepended so it runs before every Req and `req_llm`
  response step, copies the status, the `request-id` and `retry-after` headers
  and the raw body, then halts **every** response; one Elzoo error step halts a
  transport exception unchanged. So no redirect is followed, no retry happens,
  `req_llm`'s error value (which carries the request body) is never built, and
  this module decodes the documented response format itself.

  Fixed settings: `anthropic-version: 2026-10-21`, `max_retries: 0`,
  `retry: false` (defence in depth). The credential is passed only as
  `api_key:` from the injected Need; `req_llm`'s configuration and environment
  fallbacks are never reached. Sampling is not declared: version 2026-10-21
  returns 400 for `temperature`, `top_p` and `top_k`.
  """
  @behaviour Elzoo.AiText.Provider

  @version "2026-10-21"
  @piece "integration/ai-text-anthropic"
  @max_raw_bytes 4_194_304

  def api_version, do: @version

  @impl true
  def capabilities do
    %{
      piece: @piece,
      provider: "anthropic",
      wire_surface: "messages",
      features: [:tools, :structured_output, :stop_sequences, :cache_hint, :reasoning],
      reasoning: [:low, :medium, :high],
      cache_ttls: ["5m", "1h"],
      convention: %{input_includes_cached: false},
      options: %{}
    }
  end

  ## translate: pure, no credential

  @impl true
  def translate(request, config) do
    with {:ok, cfg} <- provider_config(config),
         :ok <- combination(request),
         {:ok, cache_opts} <- cache(request),
         {:ok, model} <- model(request.model),
         {:ok, context} <- context(request.messages),
         {:ok, tools} <- tools(request.tools) do
      opts =
        [max_tokens: request.max_output_tokens]
        |> put_if(request.stop_sequences != [], :stop_sequences, request.stop_sequences)
        |> put_if(tools != [], :tools, tools)
        |> put_if(tools != [], :tool_choice, tool_choice(request.tool_choice))
        |> put_if(request.reasoning != :none, :reasoning_effort, request.reasoning)
        |> Keyword.put(:provider_options, cache_opts)

      # Structured output: the documented 2026-10-21 member output_config.format
      # on the chat operation, with the caller's schema unchanged (req_llm's
      # object operation would send the beta output_format member instead).
      opts =
        case request.output_schema do
          nil ->
            opts

          schema ->
            Keyword.put(opts, :output_config, %{format: %{type: "json_schema", schema: schema}})
        end

      {:ok, %{operation: :chat, model: model, context: context, opts: opts, config: cfg}}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

  # Provider construction term: nil, or a map with an optional HTTPS
  # `:base_url` and an optional `:plug` (the Req.Test transport of the tests).
  defp provider_config(nil), do: {:ok, %{}}

  defp provider_config(%{} = c) do
    if Enum.all?(Map.keys(c), &(&1 in [:base_url, :plug])) and
         (c[:base_url] == nil or
            (is_binary(c.base_url) and String.starts_with?(c.base_url, "https://"))),
       do: {:ok, c},
       else: {:refused, :invalid_request}
  end

  defp provider_config(_), do: {:refused, :invalid_request}

  # Structured output together with tools is kept out of this slice (no listed
  # scenario covers the combination) and refused explicitly.
  defp combination(%{output_schema: s, tools: [_ | _]}) when s != nil,
    do: {:refused, :unsupported_feature}

  defp combination(_), do: :ok

  # Cache hint: req_llm marks tools and system together and at most one message
  # position. Other breakpoint sets cannot be expressed exactly and are refused.
  defp cache(%{cache_hint: nil}), do: {:ok, []}

  defp cache(%{cache_hint: hint, tools: tools, messages: messages}) do
    {positions, others} = Enum.split_with(hint.breakpoints, &match?({:message, _}, &1))
    want = Enum.sort(others)
    expected = Enum.sort(if tools == [], do: [:system], else: [:system, :tools])

    cond do
      hint.ttl not in ["5m", "1h"] ->
        {:refused, :unsupported_feature}

      want != expected ->
        {:refused, :unsupported_feature}

      length(positions) > 1 ->
        {:refused, :unsupported_feature}

      not Enum.any?(messages, &(&1.role == :system)) ->
        {:refused, :unsupported_feature}

      true ->
        cache_options(hint.ttl, positions, length(Enum.reject(messages, &(&1.role == :system))))
    end
  end

  defp cache_options(ttl, positions, count) do
    base =
      [anthropic_prompt_cache: true] ++
        if(ttl == "1h", do: [anthropic_prompt_cache_ttl: "1h"], else: [])

    case positions do
      [] -> {:ok, base}
      [{:message, i}] when i < count -> {:ok, base ++ [anthropic_cache_messages: i]}
      _ -> {:refused, :invalid_request}
    end
  end

  defp model(id) do
    case ReqLLM.model("anthropic:" <> id) do
      {:ok, %{provider: :anthropic} = m} -> {:ok, m}
      _ -> {:refused, :invalid_request}
    end
  end

  defp context(messages) do
    {:ok,
     ReqLLM.Context.new(
       Enum.map(messages, fn
         %{role: :system, text: t} ->
           ReqLLM.Context.system(t)

         %{role: :user, text: t} ->
           ReqLLM.Context.user(t)

         %{role: :assistant, text: t, tool_calls: calls} ->
           ReqLLM.Context.assistant(t,
             tool_calls: Enum.map(calls, &%{id: &1.id, name: &1.name, arguments: &1.arguments})
           )

         %{role: :tool_result, tool_use_id: id, text: t, is_error: error?} ->
           # req_llm encodes the block's is_error from the message metadata.
           message = ReqLLM.Context.tool_result(id, t)

           if error?,
             do: %{message | metadata: Map.put(message.metadata || %{}, :is_error, true)},
             else: message
       end)
     )}
  end

  # Tools are declared with a callback that refuses to run: proposals are data.
  defp tools(list) do
    {:ok,
     Enum.map(list, fn t ->
       ReqLLM.Tool.new!(
         name: t.name,
         description: t.description,
         parameter_schema: t.input_schema,
         callback: fn _ -> {:error, :not_executable} end
       )
     end)}
  end

  defp tool_choice(:auto), do: %{type: "auto"}
  defp tool_choice(:none), do: %{type: "none"}
  defp tool_choice(:any), do: %{type: "any"}
  defp tool_choice({:tool, name}), do: %{type: "tool", name: name}

  defp put_if(opts, true, k, v), do: Keyword.put(opts, k, v)
  defp put_if(opts, false, _, _), do: opts

  ## call: exactly one HTTP exchange

  @impl true
  def call(%{operation: op, model: model, context: context, opts: opts, config: cfg}, call_opts) do
    http =
      [retry: false] ++ if(cfg[:plug], do: [plug: cfg.plug], else: [])

    opts =
      opts ++
        [
          api_key: call_opts.credential,
          max_retries: 0,
          anthropic_version: @version,
          receive_timeout: call_opts.receive_timeout_ms,
          req_http_options: http
        ] ++ if(cfg[:base_url], do: [base_url: cfg.base_url], else: [])

    case ReqLLM.Providers.Anthropic.prepare_request(op, model, context, opts) do
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
      request_id: header(response, "request-id"),
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

  ## decode: documented Messages response format

  @impl true
  def decode(%{status: status} = raw, request) when status in 200..299 do
    with body when is_binary(body) and byte_size(body) <= @max_raw_bytes <- raw.body,
         {:ok, %{} = m} <- Jason.decode(body),
         "message" <- m["type"],
         id when is_binary(id) <- m["id"],
         content when is_list(content) <- m["content"],
         stop when is_binary(stop) <- m["stop_reason"],
         {:ok, blocks} <- blocks(content) do
      text = for({:text, t} <- blocks, do: t) |> Enum.join()
      calls = for {:tool, c} <- blocks, do: c

      {:ok,
       %{
         response_id: id,
         request_id: raw.request_id || :absent,
         provider_model: m["model"],
         content: text,
         tool_calls: calls,
         structured_json: if(request.output_schema, do: text, else: nil),
         finish: finish(stop),
         usage: Elzoo.AiText.Anthropic.Usage.from_raw(Map.get(m, "usage"))
       }}
    else
      _ -> {:failure, :malformed_response}
    end
  end

  def decode(%{status: status} = raw, _request) do
    # "Errors": timeout_error can also arrive with other statuses, such as 500.
    tag =
      if error_type(raw.body) == "timeout_error", do: :provider_timeout, else: classify_failure(raw)

    case {tag, retry_after(raw.retry_after)} do
      {t, n} when t in [:throttled, :overloaded] and is_integer(n) ->
        {:failure, t, %{retry_after: n}}

      _ when is_integer(status) ->
        {:failure, tag}
    end
  end

  defp error_type(body) when is_binary(body) and byte_size(body) <= @max_raw_bytes do
    case Jason.decode(body) do
      {:ok, %{"type" => "error", "error" => %{"type" => type}}} when is_binary(type) -> type
      _ -> nil
    end
  end

  defp error_type(_), do: nil

  defp blocks(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "text", "text" => t}, {:ok, acc} when is_binary(t) ->
        {:cont, {:ok, acc ++ [{:text, t}]}}

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}, {:ok, acc} ->
        args = if is_binary(input), do: input, else: Jason.encode!(input)
        {:cont, {:ok, acc ++ [{:tool, %{id: id, name: name, arguments_json: args}}]}}

      %{"type" => t}, {:ok, acc} when t in ["thinking", "redacted_thinking"] ->
        {:cont, {:ok, acc}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp finish("end_turn"), do: :stop
  defp finish("stop_sequence"), do: :stop
  defp finish("max_tokens"), do: :length
  defp finish("tool_use"), do: :tool_calls
  defp finish("refusal"), do: :refusal

  defp finish(raw),
    do: if(Elzoo.AiModel.text?(raw, 64), do: {:other, raw}, else: {:other, "unrecognized"})

  defp retry_after(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 86_400 -> n
      _ -> nil
    end
  end

  defp retry_after(_), do: nil

  ## classify_failure: by documented status (Anthropic "Errors")

  @impl true
  def classify_failure({:transport, :timeout}), do: :timeout
  def classify_failure({:transport, _}), do: :transport
  def classify_failure(%{status: 400}), do: :provider_invalid_request
  def classify_failure(%{status: 401}), do: :authentication_failed
  def classify_failure(%{status: 403}), do: :permission_denied
  def classify_failure(%{status: 404}), do: :not_found
  def classify_failure(%{status: 413}), do: :provider_too_large
  def classify_failure(%{status: 429}), do: :throttled
  def classify_failure(%{status: 504}), do: :provider_timeout
  def classify_failure(%{status: 529}), do: :overloaded
  def classify_failure(_), do: :provider_error
end
