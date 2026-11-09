# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.OpenAI do
  @moduledoc """
  The OpenAI Responses API provider of `integration/ai-text`, through `req_llm`
  1.30's documented provider-callback API
  (`ReqLLM.Providers.OpenAI.prepare_request/4` then `Req.request/1`).

  Evidenced models: `gpt-6.1-terra` only, on the Responses surface
  (`POST /v1/responses`). Any other model is refused `:invalid_request` in the
  pure `translate/2` (before any credential read), and the model's `req_llm`
  route is asserted to still be the Responses surface.

  `req_llm` resolves the model, encodes the body (input items, function tools,
  `text.format`, `reasoning`, `prompt_cache_key`, `prompt_cache_options`,
  `prompt_cache_breakpoint` content-part markers, `store`), sets the
  `authorization` header and owns the transport. One Elzoo response step,
  prepended so it runs before every Req and `req_llm` response step, copies the
  status, the `x-request-id` and `retry-after` headers and the raw body, then
  halts **every** response; one Elzoo error step halts a transport exception
  unchanged. So no redirect is followed, no retry happens, `req_llm`'s error value
  (which carries the request body) is never built, and this module decodes the
  documented response format itself.

  Fixed settings: `max_retries: 0`, `retry: false` (defence in depth),
  `store: false` (no provider-side response storage). The credential is passed
  only as `api_key:` from the injected Need. Sampling and stop sequences are not
  declared. No caller provider option is declared: the wire cache key and cache
  options are derived from the neutral cache hint only.
  """
  @behaviour Elzoo.AiText.Provider

  @piece "integration/ai-text-openai"
  @max_raw_bytes 4_194_304
  @models %{"gpt-6.1-terra" => %{reasoning: [:low, :medium, :high, :max]}}
  @key_prefix "ez1."

  def models, do: Map.keys(@models)

  @impl true
  def capabilities do
    %{
      piece: @piece,
      provider: "openai",
      wire_surface: "responses",
      features: [:tools, :structured_output, :cache_hint, :reasoning],
      reasoning: [:low, :medium, :high, :max],
      cache_ttls: ["30m", "12h"],
      convention: %{input_includes_cached: true},
      options: %{}
    }
  end

  @doc """
  The wire `prompt_cache_key` for a cache hint: `"ez1."` followed by the unpadded
  base64url SHA-256 of the 32-bit length-framed tenant and local key (an
  unambiguous preimage; SHA-256 is a collision-resistant derivation). 47 bytes.
  """
  def cache_key(tenant, local_key) when is_binary(tenant) and is_binary(local_key) do
    preimage =
      <<byte_size(tenant)::32, tenant::binary, byte_size(local_key)::32, local_key::binary>>

    @key_prefix <> Base.url_encode64(:crypto.hash(:sha256, preimage), padding: false)
  end

  ## translate: pure, no credential

  @impl true
  def translate(request, config) do
    with {:ok, cfg} <- provider_config(config),
         {:ok, model} <- model(request.model),
         :ok <- combination(request),
         {:ok, targets, cache_opts} <- cache(request),
         {:ok, context} <- context(request.messages, targets),
         {:ok, tools} <- tools(request.tools) do
      provider_options =
        [store: false] ++
          cache_opts ++
          case request.output_schema do
            nil ->
              []

            schema ->
              # The caller's schema unchanged; strict mode would require OpenAI's
              # strict-schema subset, so it is off and the interface validates.
              [
                response_format: %{
                  type: "json_schema",
                  json_schema: %{name: "output", strict: false, schema: schema}
                }
              ]
          end

      opts =
        [max_completion_tokens: request.max_output_tokens, reasoning_effort: request.reasoning]
        |> put_if(tools != [], :tools, tools)
        |> put_if(tools != [], :tool_choice, tool_choice(request.tool_choice))
        |> Keyword.put(:provider_options, provider_options)

      {:ok, %{model: model, context: context, opts: opts, config: cfg}}
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

  defp model(id) do
    with true <- Map.has_key?(@models, id),
         {:ok, %{provider: :openai} = m} <- ReqLLM.model("openai:" <> id),
         {:ok, :openai_responses, _, _} <- ReqLLM.RequestPlan.openai_surface(m) do
      {:ok, m}
    else
      _ -> {:refused, :invalid_request}
    end
  end

  # Structured output together with tools is kept out of this slice (no listed
  # scenario covers the combination). A tool result's error flag has no member
  # in the documented function_call_output item; it is refused, never dropped.
  defp combination(%{output_schema: s, tools: [_ | _]}) when s != nil,
    do: {:refused, :unsupported_feature}

  defp combination(%{messages: messages}) do
    if Enum.any?(messages, &match?(%{role: :tool_result, is_error: true}, &1)),
      do: {:refused, :unsupported_feature},
      else: :ok
  end

  # Cache hint: explicit mode with exactly the hint's breakpoints, each on a
  # unique addressable input_text part. `:system` needs exactly one system
  # message; `{:message, i}` indexes the non-system messages in order and must
  # name a user message. `:tools`, a missing or ambiguous system target and a
  # non-user target are refused :unsupported_feature; an index beyond the
  # non-system messages :invalid_request. Returns the set of positions (indexes
  # into the full message list) to mark.
  defp cache(%{cache_hint: nil}), do: {:ok, MapSet.new(), []}

  defp cache(%{cache_hint: hint, messages: messages}) do
    indexed = Enum.with_index(messages)
    systems = for {%{role: :system}, i} <- indexed, do: i
    others = for {m, i} <- indexed, m.role != :system, do: {m, i}

    result =
      Enum.reduce_while(hint.breakpoints, {:ok, []}, fn
        :tools, _ ->
          {:halt, {:refused, :unsupported_feature}}

        :system, {:ok, acc} ->
          case systems do
            [i] -> {:cont, {:ok, [i | acc]}}
            _ -> {:halt, {:refused, :unsupported_feature}}
          end

        {:message, n}, {:ok, acc} ->
          case Enum.at(others, n) do
            {%{role: :user}, i} -> {:cont, {:ok, [i | acc]}}
            {_, _} -> {:halt, {:refused, :unsupported_feature}}
            nil -> {:halt, {:refused, :invalid_request}}
          end
      end)

    with {:ok, positions} <- result,
         true <- hint.ttl in ["30m", "12h"] || {:refused, :unsupported_feature} do
      {:ok, MapSet.new(positions),
       [
         prompt_cache_key: cache_key(hint.tenant, hint.local_key),
         prompt_cache_options: %{mode: "explicit", ttl: hint.ttl}
       ]}
    end
  end

  @breakpoint %{prompt_cache_breakpoint: %{mode: "explicit"}}

  defp context(messages, targets) do
    {:ok,
     ReqLLM.Context.new(
       messages
       |> Enum.with_index()
       |> Enum.map(fn
         {%{role: :system, text: t}, i} ->
           ReqLLM.Context.system([part(t, i, targets)])

         {%{role: :user, text: t}, i} ->
           ReqLLM.Context.user([part(t, i, targets)])

         {%{role: :assistant, text: t, tool_calls: calls}, _} ->
           ReqLLM.Context.assistant(t,
             tool_calls: Enum.map(calls, &%{id: &1.id, name: &1.name, arguments: &1.arguments})
           )

         {%{role: :tool_result, tool_use_id: id, text: t}, _} ->
           ReqLLM.Context.tool_result(id, t)
       end)
     )}
  end

  defp part(text, i, targets) do
    if MapSet.member?(targets, i),
      do: ReqLLM.Message.ContentPart.text(text, @breakpoint),
      else: ReqLLM.Message.ContentPart.text(text)
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

  defp tool_choice(:auto), do: :auto
  defp tool_choice(:none), do: :none
  defp tool_choice(:any), do: :required
  defp tool_choice({:tool, name}), do: %{type: "tool", name: name}

  defp put_if(opts, true, k, v), do: Keyword.put(opts, k, v)
  defp put_if(opts, false, _, _), do: opts

  ## call: exactly one HTTP exchange

  @impl true
  def call(%{model: model, context: context, opts: opts, config: cfg}, call_opts) do
    http = [retry: false] ++ if(cfg[:plug], do: [plug: cfg.plug], else: [])

    opts =
      opts ++
        [
          api_key: call_opts.credential,
          max_retries: 0,
          receive_timeout: call_opts.receive_timeout_ms,
          req_http_options: http
        ] ++ if(cfg[:base_url], do: [base_url: cfg.base_url], else: [])

    case ReqLLM.Providers.OpenAI.prepare_request(:chat, model, context, opts) do
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

  ## decode: documented Responses format (pinned OpenAPI `Response`)

  @impl true
  def decode(%{status: status} = raw, request) when status in 200..299 do
    with body when is_binary(body) and byte_size(body) <= @max_raw_bytes <- raw.body,
         {:ok, %{} = r} <- Jason.decode(body),
         "response" <- r["object"],
         id when is_binary(id) <- r["id"],
         state when is_binary(state) <- r["status"],
         output when is_list(output) <- r["output"],
         {:ok, items} <- items(output) do
      if state == "failed" do
        # A failed response carries an error object and no usable output.
        {:failure, :provider_error}
      else
        completed(r, id, state, items, raw, request)
      end
    else
      _ -> {:failure, :malformed_response}
    end
  end

  def decode(%{status: status} = raw, _request) do
    tag = classify_failure(raw)

    case {tag, retry_after(raw.retry_after)} do
      {t, n} when t in [:throttled, :overloaded] and is_integer(n) ->
        {:failure, t, %{retry_after: n}}

      _ when is_integer(status) ->
        {:failure, tag}
    end
  end

  defp completed(r, id, state, items, raw, request) do
    with {:ok, finish} <- finish(state, r["incomplete_details"], items) do
      text = for({kind, t} <- items, kind in [:text, :refusal], do: t) |> Enum.join()
      calls = for {:tool, c} <- items, do: c

      {:ok,
       %{
         response_id: id,
         request_id: raw.request_id || :absent,
         provider_model: r["model"],
         content: text,
         tool_calls: calls,
         structured_json: if(request.output_schema, do: text, else: nil),
         finish: finish,
         usage: Elzoo.AiText.OpenAI.Usage.from_raw(Map.get(r, "usage"))
       }}
    else
      _ -> {:failure, :malformed_response}
    end
  end

  # Output items: assistant messages (output_text, refusal), function calls and
  # reasoning items. A provider-executed tool item (web search, code
  # interpreter, ...) was never requested and is malformed.
  defp items(output) do
    Enum.reduce_while(output, {:ok, []}, fn
      %{"type" => "message", "content" => content}, {:ok, acc} when is_list(content) ->
        case contents(content) do
          {:ok, parts} -> {:cont, {:ok, acc ++ parts}}
          :error -> {:halt, :error}
        end

      %{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => args}, {:ok, acc}
      when is_binary(id) and is_binary(name) and is_binary(args) ->
        # The arguments string is passed on raw; the interface marks invalid JSON.
        {:cont, {:ok, acc ++ [{:tool, %{id: id, name: name, arguments_json: args}}]}}

      %{"type" => "reasoning"}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp contents(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "output_text", "text" => t}, {:ok, acc} when is_binary(t) ->
        {:cont, {:ok, acc ++ [{:text, t}]}}

      %{"type" => "refusal", "refusal" => t}, {:ok, acc} when is_binary(t) ->
        {:cont, {:ok, acc ++ [{:refusal, t}]}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp finish("completed", _, items) do
    cond do
      Enum.any?(items, &match?({:refusal, _}, &1)) -> {:ok, :refusal}
      Enum.any?(items, &match?({:tool, _}, &1)) -> {:ok, :tool_calls}
      true -> {:ok, :stop}
    end
  end

  defp finish("incomplete", %{"reason" => "max_output_tokens"}, _), do: {:ok, :length}
  defp finish("incomplete", %{"reason" => "content_filter"}, _), do: {:ok, :content_filter}

  defp finish("incomplete", %{"reason" => reason}, _) when is_binary(reason),
    do: {:ok, {:other, bounded(reason)}}

  defp finish("incomplete", _, _), do: {:ok, {:other, "incomplete"}}

  defp finish(state, _, _) when state in ["cancelled", "queued", "in_progress"],
    do: {:ok, {:other, state}}

  defp finish(_, _, _), do: :error

  defp bounded(raw),
    do: if(Elzoo.AiModel.text?(raw, 64), do: raw, else: "unrecognized")

  defp retry_after(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 86_400 -> n
      _ -> nil
    end
  end

  defp retry_after(_), do: nil

  ## classify_failure: by status. The pinned POST /responses declares 400, 404,
  ## 429 and 503; the other statuses and 503 meaning overload are upstream
  ## assumptions and policy, exercised on stubs.

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
  def classify_failure(%{status: 504}), do: :provider_timeout
  def classify_failure(_), do: :provider_error
end
