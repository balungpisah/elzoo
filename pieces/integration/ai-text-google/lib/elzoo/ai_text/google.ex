# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Google do
  @moduledoc """
  The Gemini API `generateContent` provider of `integration/ai-text`, with an
  API key, through `req_llm` 1.30's documented provider-callback API
  (`ReqLLM.Providers.Google.prepare_request/4`, its `encode_body/1`, then
  `Req.request/1`).

  Evidenced model: `gemini-3.8-flash` only. Any other model is refused
  `:invalid_request` in the pure `translate/2`, before any credential read.

  `req_llm` resolves the model, encodes the contents (user parts in order with
  each image as `inline_data`, assistant function calls, function responses),
  the tool declarations, `toolConfig` and `maxOutputTokens`, sets the
  `x-goog-api-key` header and owns the transport. This module then edits the
  encoded body, from values `translate/2` computed: each function declaration
  carries the caller's parameter schema unchanged in `parametersJsonSchema`
  (`req_llm`'s `parameters` path removes `additionalProperties` and `$schema`),
  each function call and function response carries the neutral call id, the
  system instruction holds one part per system message, and structured output
  is `responseMimeType: "application/json"` with `responseJsonSchema` unchanged.

  One Elzoo response step, prepended so it runs before every Req and `req_llm`
  response step, copies the status, the `retry-after` header and the raw body
  (bounded to 4 MiB of wire bytes while received), then halts **every**
  response; one Elzoo error step halts a transport exception unchanged. So no
  redirect is followed, no retry happens and `req_llm`'s error value is never
  built. Fixed settings: `max_retries: 0`, `retry: false`.
  """
  @behaviour Elzoo.AiText.Provider

  @piece "integration/ai-text-google"
  @max_raw_bytes 4_194_304
  @models %{"gemini-3.8-flash" => %{}}
  @refusals ~w(SAFETY PROHIBITED_CONTENT BLOCKLIST SPII IMAGE_SAFETY)
  # responseJsonSchema: the keywords the fetched reference lists as supported,
  # without oneOf, which the reference interprets as anyOf (exclusivity lost).
  @schema_keywords ~w($id $defs $ref $anchor type format title description enum items
                      prefixItems minItems maxItems minimum maximum anyOf
                      properties additionalProperties required propertyOrdering)

  def models, do: Map.keys(@models)

  @impl true
  def capabilities do
    %{
      piece: @piece,
      provider: "google",
      wire_surface: "generate_content",
      features: [:tools, :structured_output, :image_input],
      reasoning: [],
      cache_ttls: [],
      # usageMetadata.promptTokenCount includes the cached content.
      convention: %{input_includes_cached: true},
      options: %{}
    }
  end

  ## translate: pure, no credential

  @impl true
  def translate(request, config) do
    with {:ok, cfg} <- provider_config(config),
         {:ok, model} <- model(request.model),
         :ok <- combination(request),
         :ok <- tool_schemas(request.tools),
         {:ok, systems, others} <- split(request.messages),
         {:ok, names} <- call_names(others),
         :ok <- output_schema(request.output_schema) do
      tools = tools(request.tools)

      opts =
        [max_tokens: request.max_output_tokens]
        |> put_if(tools != [], :tools, tools)
        |> put_if(tools != [], :tool_choice, tool_choice(request.tool_choice))

      edits = %{
        system: systems,
        schemas: Map.new(request.tools, &{&1.name, &1.input_schema}),
        call_ids: for(%{role: :assistant, tool_calls: c} <- others, call <- c, do: call.id),
        result_ids: for(%{role: :tool_result, tool_use_id: id} <- others, do: id),
        output_schema: request.output_schema
      }

      {:ok,
       %{
         model: model,
         context: context(others, names),
         opts: opts,
         edits: edits,
         config: cfg
       }}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

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
         {:ok, %{provider: :google} = m} <- ReqLLM.model("google:" <> id) do
      {:ok, m}
    else
      _ -> {:refused, :invalid_request}
    end
  end

  # Structured output together with tools is kept out of this slice (no listed
  # scenario covers the combination) and refused explicitly.
  defp combination(%{output_schema: s, tools: [_ | _]}) when s != nil,
    do: {:refused, :unsupported_feature}

  defp combination(_), do: :ok

  # parametersJsonSchema "must describe an object": a tool schema whose root is
  # not type object is refused, never rewritten.
  defp tool_schemas(tools) do
    if Enum.all?(tools, &(&1.input_schema["type"] == "object")),
      do: :ok,
      else: {:refused, :unsupported_feature}
  end

  # Gemini has one system instruction ahead of the contents: system messages are
  # accepted only before the first other message. req_llm refuses a final model
  # turn (prefill) for Gemini 3 and later, so it is refused here first. A final
  # user message must hold non-empty text (gemini-3.8-flash turn validation); a
  # final tool result is a function-response continuation.
  defp split(messages) do
    {systems, others} = Enum.split_while(messages, &(&1.role == :system))

    cond do
      Enum.any?(others, &(&1.role == :system)) -> {:refused, :unsupported_feature}
      others == [] -> {:refused, :invalid_request}
      List.last(others).role == :assistant -> {:refused, :unsupported_feature}
      not final_text?(List.last(others)) -> {:refused, :unsupported_feature}
      true -> {:ok, Enum.map(systems, & &1.text), others}
    end
  end

  defp final_text?(%{role: :user, parts: parts}),
    do: Enum.any?(parts, &match?(%{type: :text, text: t} when t != "", &1))

  defp final_text?(%{role: :user, text: t}), do: t != ""
  defp final_text?(%{role: :tool_result}), do: true

  # A functionResponse needs the function name: each tool result must answer a
  # call proposed earlier in the transcript.
  defp call_names(messages) do
    Enum.reduce_while(messages, {:ok, %{}}, fn
      %{role: :assistant, tool_calls: calls}, {:ok, names} ->
        {:cont, {:ok, Enum.reduce(calls, names, &Map.put_new(&2, &1.id, &1.name))}}

      %{role: :tool_result, tool_use_id: id}, {:ok, names} ->
        if Map.has_key?(names, id),
          do: {:cont, {:ok, names}},
          else: {:halt, {:refused, :invalid_request}}

      _, acc ->
        {:cont, acc}
    end)
  end

  # The output schema is sent unchanged, so it must use only the keywords the
  # reference lists for responseJsonSchema; anything else is refused, never
  # dropped or rewritten.
  defp output_schema(nil), do: :ok

  defp output_schema(schema),
    do:
      if(supported?(schema) and acyclic?(schema),
        do: :ok,
        else: {:refused, :unsupported_feature}
      )

  # Beside $ref, only the listed keywords that start with "$".
  defp supported?(%{"$ref" => _} = s) do
    Enum.all?(Map.keys(s), &(&1 in @schema_keywords and String.starts_with?(&1, "$"))) and
      subschemas?(s)
  end

  defp supported?(%{} = s) do
    Enum.all?(s, fn {k, v} -> k in @schema_keywords and keyword?(k, v) end) and subschemas?(s)
  end

  defp supported?(_), do: false

  # Below the root, no $id (a new resource, where #/$defs/<name> would name
  # that subschema's own $defs) and no $defs: every $ref then resolves against
  # the root $defs that acyclic?/1 checks.
  defp inner?(%{} = s),
    do: not (is_map_key(s, "$id") or is_map_key(s, "$defs")) and supported?(s)

  # A boolean subschema (true or false) has no generateContent form.
  defp inner?(_), do: false

  defp keyword?("enum", v), do: is_list(v) and Enum.all?(v, &(is_binary(&1) or is_number(&1)))
  defp keyword?(_, _), do: true

  defp subschemas?(s) do
    Enum.all?(s, fn
      {k, %{} = m} when k in ["$defs", "properties"] ->
        Enum.all?(Map.values(m), &inner?/1)

      {k, l} when k in ["prefixItems", "anyOf"] ->
        is_list(l) and Enum.all?(l, &inner?/1)

      {k, %{} = m} when k in ["items", "additionalProperties"] ->
        inner?(m)

      {k, _} when k in ["$defs", "properties", "items"] ->
        false

      _ ->
        true
    end)
  end

  # Every $ref names a root $defs entry as "#/$defs/<name>", and the references
  # between those entries have no cycle: the reference unrolls cycles only to a
  # limited degree, which is an approximation, so a cyclic schema is refused.
  defp acyclic?(schema) do
    defs = Map.get(schema, "$defs", %{})

    with {:ok, _} <- targets(refs(schema), defs) do
      graph =
        Map.new(defs, fn {name, d} ->
          {:ok, children} = targets(refs(d), defs)
          {name, children}
        end)

      match?(
        {:ok, _},
        Enum.reduce_while(Map.keys(graph), {:ok, MapSet.new()}, fn n, {:ok, done} ->
          case visit(n, graph, done, MapSet.new()) do
            {:ok, done} -> {:cont, {:ok, done}}
            :cycle -> {:halt, :cycle}
          end
        end)
      )
    else
      _ -> false
    end
  end

  defp refs(%{} = m),
    do:
      Enum.flat_map(m, fn
        {"$ref", r} when is_binary(r) -> [r]
        {_, v} -> refs(v)
      end)

  defp refs(l) when is_list(l), do: Enum.flat_map(l, &refs/1)
  defp refs(_), do: []

  defp targets(refs, defs) do
    Enum.reduce_while(refs, {:ok, []}, fn r, {:ok, acc} ->
      case Regex.run(~r/\A#\/\$defs\/([^\/~]+)\z/, r) do
        [_, name] when is_map_key(defs, name) -> {:cont, {:ok, [name | acc]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp visit(n, graph, done, stack) do
    cond do
      MapSet.member?(done, n) ->
        {:ok, done}

      MapSet.member?(stack, n) ->
        :cycle

      true ->
        graph
        |> Map.fetch!(n)
        |> Enum.reduce_while({:ok, done}, fn c, {:ok, done} ->
          case visit(c, graph, done, MapSet.put(stack, n)) do
            {:ok, done} -> {:cont, {:ok, done}}
            :cycle -> {:halt, :cycle}
          end
        end)
        |> case do
          {:ok, done} -> {:ok, MapSet.put(done, n)}
          :cycle -> :cycle
        end
    end
  end

  defp context(messages, names) do
    ReqLLM.Context.new(
      Enum.map(messages, fn
        %{role: :user, parts: parts} ->
          ReqLLM.Context.user(Enum.map(parts, &part/1))

        %{role: :user, text: t} ->
          ReqLLM.Context.user([ReqLLM.Message.ContentPart.text(t)])

        %{role: :assistant, text: t, tool_calls: calls} ->
          ReqLLM.Context.assistant(t,
            tool_calls: Enum.map(calls, &%{id: &1.id, name: &1.name, arguments: &1.arguments})
          )

        # The documented FunctionResponse.response object: "error" for a
        # failed call, as the reference describes; "content" otherwise.
        %{role: :tool_result, tool_use_id: id, text: t, is_error: error?} ->
          key = if error?, do: "error", else: "content"
          ReqLLM.Context.tool_result(id, Map.fetch!(names, id), %{key => t})
      end)
    )
  end

  defp part(%{type: :text, text: t}), do: ReqLLM.Message.ContentPart.text(t)

  defp part(%{type: :image, media_type: m, bytes: bytes}),
    do: ReqLLM.Message.ContentPart.image(bytes, m)

  # Tools are declared with a callback that refuses to run: proposals are data.
  defp tools(list) do
    Enum.map(list, fn t ->
      ReqLLM.Tool.new!(
        name: t.name,
        description: t.description,
        parameter_schema: t.input_schema,
        callback: fn _ -> {:error, :not_executable} end
      )
    end)
  end

  defp tool_choice(:auto), do: :auto
  defp tool_choice(:none), do: :none
  defp tool_choice(:any), do: :required
  defp tool_choice({:tool, name}), do: %{type: "function", function: %{name: name}}

  defp put_if(opts, true, k, v), do: Keyword.put(opts, k, v)
  defp put_if(opts, false, _, _), do: opts

  ## call: exactly one HTTP exchange

  @impl true
  def call(%{model: model, context: context, opts: opts, edits: edits, config: cfg}, call_opts) do
    http = [retry: false] ++ if(cfg[:plug], do: [plug: cfg.plug], else: [])

    opts =
      opts ++
        [
          api_key: call_opts.credential,
          max_retries: 0,
          receive_timeout: call_opts.receive_timeout_ms,
          req_http_options: http
        ] ++ if(cfg[:base_url], do: [base_url: cfg.base_url], else: [])

    case prepare(model, context, opts, edits) do
      {:ok, request} ->
        request
        |> Req.Request.prepend_response_steps(elzoo_capture: &capture/1)
        |> Req.Request.prepend_error_steps(elzoo_halt: &halt_error/1)
        |> Req.request()
        |> exchange()

      :error ->
        # Request construction failed before any byte was sent; req_llm's
        # error value is dropped unread.
        {:transport, :not_sent}
    end
  end

  # The request with its body encoded once, here, and edited; req_llm's encode
  # step is then removed so it does not run again.
  defp prepare(model, context, opts, edits) do
    with {:ok, request} <- ReqLLM.Providers.Google.prepare_request(:chat, model, context, opts),
         request = ReqLLM.Providers.Google.encode_body(request),
         {:ok, body} <- edit(request.options[:json], edits) do
      {:ok,
       %{
         request
         | into: &bounded/2,
           request_steps: Keyword.delete(request.request_steps, :llm_encode_body)
       }
       |> Req.Request.put_option(:json, body)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc false
  # The encoded body, as JSON, edited from the neutral request: refused (nothing
  # sent) unless req_llm emitted exactly one function call part per neutral call
  # and one function response part per tool result, in order.
  def edit(json, edits) do
    body = json |> Jason.encode!() |> Jason.decode!()
    {contents, {calls, results}} = ids(body["contents"], {edits.call_ids, edits.result_ids})

    if calls == [] and results == [] do
      body =
        body
        |> Map.put("contents", contents)
        |> declarations(edits.schemas)
        |> system(edits.system)
        |> output(edits.output_schema)

      {:ok, body}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp ids(contents, acc) do
    Enum.map_reduce(contents, acc, fn content, acc ->
      {parts, acc} =
        Enum.map_reduce(content["parts"], acc, fn
          %{"functionCall" => call} = p, {[id | calls], results} ->
            {%{p | "functionCall" => Map.put(call, "id", id)}, {calls, results}}

          %{"functionResponse" => resp} = p, {calls, [id | results]} ->
            {%{p | "functionResponse" => Map.put(resp, "id", id)}, {calls, results}}

          %{"functionCall" => _}, _ ->
            raise ArgumentError

          %{"functionResponse" => _}, _ ->
            raise ArgumentError

          p, acc ->
            {p, acc}
        end)

      {%{content | "parts" => parts}, acc}
    end)
  end

  defp declarations(%{"tools" => tools} = body, schemas) do
    tools =
      Enum.map(tools, fn %{"functionDeclarations" => decls} = tool ->
        decls =
          Enum.map(decls, fn d ->
            d
            |> Map.delete("parameters")
            |> Map.put("parametersJsonSchema", Map.fetch!(schemas, d["name"]))
          end)

        %{tool | "functionDeclarations" => decls}
      end)

    %{body | "tools" => tools}
  end

  defp declarations(body, _), do: body

  defp system(body, []), do: Map.delete(body, "systemInstruction")

  defp system(body, texts),
    do: Map.put(body, "systemInstruction", %{"parts" => Enum.map(texts, &%{"text" => &1})})

  defp output(body, nil), do: body

  defp output(body, schema) do
    config =
      Map.get(body, "generationConfig", %{})
      |> Map.merge(%{"responseMimeType" => "application/json", "responseJsonSchema" => schema})

    Map.put(body, "generationConfig", config)
  end

  @doc false
  # Req `into:` function: accumulates the body up to 4 MiB of wire bytes; a larger
  # body stops the transfer and is marked oversize (never kept, never classified
  # by status).
  def bounded({:data, data}, {request, response}) do
    body = if is_binary(response.body), do: response.body, else: ""

    if byte_size(body) + byte_size(data) > @max_raw_bytes do
      {:halt, {request, Req.Response.put_private(%{response | body: ""}, :elzoo_oversize, true)}}
    else
      {:cont, {request, %{response | body: body <> data}}}
    end
  end

  @doc false
  def capture({request, response}) do
    oversize = response.private[:elzoo_oversize] == true

    raw = %{
      status: response.status,
      oversize: oversize,
      retry_after: header(response, "retry-after"),
      body: if(is_binary(response.body) and not oversize, do: response.body, else: nil)
    }

    Req.Request.halt(request, Req.Response.put_private(response, :elzoo_raw, raw))
  end

  @doc false
  def halt_error({request, exception}), do: Req.Request.halt(request, exception)

  # A header present but not printable or over 256 bytes is kept as :malformed.
  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [] ->
        nil

      [v | _] when is_binary(v) and byte_size(v) <= 256 ->
        if String.match?(v, ~r/\A[\x21-\x7E]+\z/), do: v, else: :malformed

      _ ->
        :malformed
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

  ## decode: documented GenerateContentResponse

  @impl true
  def decode(%{oversize: true}, _request), do: {:failure, :malformed_response}

  def decode(%{status: status} = raw, request) when status in 200..299 do
    with {:ok, %{} = r} <- json(raw.body),
         id when is_binary(id) <- r["responseId"],
         {:ok, parts, reason} <- candidate(r),
         {:ok, text, calls} <- parts(parts) do
      {:ok,
       %{
         response_id: id,
         request_id: :absent,
         provider_model: r["modelVersion"],
         content: text,
         tool_calls: calls,
         structured_json: if(request.output_schema, do: text, else: nil),
         finish: finish(reason, calls),
         usage: usage(r["usageMetadata"])
       }}
    else
      _ -> {:failure, :malformed_response}
    end
  end

  def decode(raw, _request) do
    tag = classify_failure(raw)

    case {tag, retry_after(raw)} do
      {t, n} when t in [:throttled, :overloaded] and is_integer(n) ->
        {:failure, t, %{retry_after: n}}

      _ ->
        {:failure, tag}
    end
  end

  defp json(body) when is_binary(body) and byte_size(body) <= @max_raw_bytes, do: Jason.decode(body)
  defp json(_), do: :error

  # Exactly one candidate with a finish reason; or none, with the prompt's
  # documented block reason (the API answers a blocked prompt with no candidate).
  defp candidate(%{"candidates" => [%{"finishReason" => reason} = c]}) when is_binary(reason) do
    case c["content"] do
      nil -> {:ok, [], reason}
      %{"parts" => parts} when is_list(parts) -> {:ok, parts, reason}
      %{} = content when not is_map_key(content, "parts") -> {:ok, [], reason}
      _ -> :error
    end
  end

  defp candidate(%{"promptFeedback" => %{"blockReason" => reason}} = r) when is_binary(reason) do
    if r["candidates"] in [nil, []], do: {:ok, [], reason}, else: :error
  end

  defp candidate(_), do: :error

  # Text parts (thought summaries skipped) and function calls; any other part
  # type was never requested and is malformed.
  defp parts(parts) do
    Enum.reduce_while(parts, {:ok, "", []}, fn
      %{"thought" => true}, acc ->
        {:cont, acc}

      %{"text" => t}, {:ok, text, calls} when is_binary(t) ->
        {:cont, {:ok, text <> t, calls}}

      %{"functionCall" => %{"name" => name} = call}, {:ok, text, calls} when is_binary(name) ->
        args = Jason.encode!(Map.get(call, "args", %{}))
        {:cont, {:ok, text, calls ++ [%{id: call["id"], name: name, arguments_json: args}]}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp finish("STOP", []), do: :stop
  defp finish("STOP", _calls), do: :tool_calls
  defp finish("MAX_TOKENS", _), do: :length
  defp finish(reason, _) when reason in @refusals, do: :refusal

  defp finish(reason, _),
    do: if(Elzoo.AiModel.text?(reason, 64), do: {:other, reason}, else: {:other, "unrecognized"})

  # usageMetadata: promptTokenCount (includes cachedContentTokenCount),
  # cachedContentTokenCount, candidatesTokenCount and thoughtsTokenCount (not
  # part of candidatesTokenCount: output is their sum). No cache-write counter
  # exists on generateContent. A counter not reported is :unknown.
  defp usage(%{} = u) when map_size(u) > 0 do
    candidates = amount(u["candidatesTokenCount"])
    thoughts = amount(u["thoughtsTokenCount"])

    raw = %{
      input: amount(u["promptTokenCount"]),
      cache_read: amount(u["cachedContentTokenCount"]),
      cache_writes: [],
      output:
        if(is_integer(candidates) and is_integer(thoughts),
          do: candidates + thoughts,
          else: :unknown
        ),
      reasoning: thoughts
    }

    case Elzoo.AiModel.Usage.from_provider(raw, capabilities().convention, :provider_reported) do
      {:ok, usage} -> usage
      _ -> Elzoo.AiModel.Usage.unknown(capabilities().convention)
    end
  end

  defp usage(_), do: Elzoo.AiModel.Usage.unknown(capabilities().convention)

  defp amount(n) when is_integer(n) and n >= 0, do: n
  defp amount(_), do: :unknown

  # A Retry-After header (delta-seconds) when there is one; else the
  # google.rpc.RetryInfo retryDelay of the error body (a protobuf JSON Duration
  # such as "1.5s"), rounded up. Over 86,400 s or malformed: nil.
  defp retry_after(%{retry_after: nil} = raw), do: retry_delay(raw.body)
  defp retry_after(%{retry_after: v}), do: seconds(v)

  defp seconds(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 86_400 -> n
      _ -> nil
    end
  end

  defp seconds(_), do: nil

  defp retry_delay(body) do
    with {:ok, details} <- details(body),
         [delay | _] <-
           for(
             %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => d} <- details,
             do: d
           ),
         true <- is_binary(delay),
         [_ | groups] <- Regex.run(~r/\A(\d{1,6})(?:\.(\d{1,9}))?s\z/, delay) do
      [whole | fraction] = groups
      up = if fraction != [] and String.trim(hd(fraction), "0") != "", do: 1, else: 0
      n = String.to_integer(whole) + up
      if n <= 86_400, do: n, else: nil
    else
      _ -> nil
    end
  end

  defp details(body) do
    case json(body) do
      {:ok, %{"error" => %{"details" => d}}} when is_list(d) -> {:ok, d}
      _ -> :error
    end
  end

  ## classify_failure: by status, from Gemini's documented generateContent errors

  @impl true
  def classify_failure({:transport, :timeout}), do: :timeout
  def classify_failure({:transport, _}), do: :transport

  # The documented invalid-key answer: 400 INVALID_ARGUMENT with an ErrorInfo
  # whose reason is API_KEY_INVALID.
  def classify_failure(%{status: 400} = raw) do
    case details(raw[:body]) do
      {:ok, d} ->
        if Enum.any?(
             d,
             &match?(
               %{
                 "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                 "reason" => "API_KEY_INVALID"
               },
               &1
             )
           ),
           do: :authentication_failed,
           else: :provider_invalid_request

      _ ->
        :provider_invalid_request
    end
  end

  def classify_failure(%{status: 401}), do: :authentication_failed
  def classify_failure(%{status: 403}), do: :permission_denied
  def classify_failure(%{status: 404}), do: :not_found
  def classify_failure(%{status: 413}), do: :provider_too_large
  def classify_failure(%{status: 429}), do: :throttled
  def classify_failure(%{status: 503}), do: :overloaded
  def classify_failure(%{status: 504}), do: :provider_timeout
  def classify_failure(_), do: :provider_error
end
