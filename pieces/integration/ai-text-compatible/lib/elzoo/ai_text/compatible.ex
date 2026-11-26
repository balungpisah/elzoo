# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Compatible do
  @moduledoc """
  The OpenAI-compatible Chat Completions provider of `integration/ai-text`, for
  one HTTPS base URL per endpoint that the host or a tenant gives (a self-hosted
  or regional model), through `req_llm` 1.31's documented provider-callback API
  (`ReqLLM.Providers.LMStudio.prepare_request/4` then `Req.request/1`).

  `endpoint/1` builds the `provider_config` term: it checks the base URL's shape,
  admits it once through `Elzoo.EgressPolicy.resolve/3` and keeps the checked
  host, port and addresses with the host's transport Need and model table. Every
  call reaches only those addresses through that Need's Req options. A feature
  the table does not declare for the request's model is refused
  `:unsupported_feature`, and a model outside the table `:invalid_request`, in the
  pure `translate/2`.

  `call/2` drops `req_llm`'s own `finch` option, merges the transport Need's
  options, then `retry: false`, `redirect: false` and the interface's receive
  timeout. One Elzoo response step, prepended so it runs before every Req and
  `req_llm` response step, copies the status, the `x-request-id` and
  `retry-after` headers and the raw body, bounded to 4 MiB of wire bytes while it
  is received, then halts every response; one Elzoo error step halts a transport
  exception unchanged. So no redirect is followed, no retry happens and this
  module decodes the documented Chat Completions response itself.
  """
  @behaviour Elzoo.AiText.Provider

  alias Elzoo.AiModel.Usage
  alias Elzoo.EgressPolicy

  @piece "integration/ai-text-compatible"
  @features [:tools, :structured_output, :stop_sequences, :sampling, :image_input]
  @keys [:base_url, :policy, :resolver, :transport, :models]
  @max_url_bytes 2048
  @max_raw_bytes 4_194_304
  # The Chat Completions reference documents at most 4 stop sequences.
  @max_stops 4
  @convention %{input_includes_cached: true}

  defmodule Endpoint do
    @moduledoc false
    # The transport Need is never shown; the resolver is not kept.
    @derive {Inspect, except: [:transport]}
    @enforce_keys [:base_url, :host, :port, :addresses, :transport, :models]
    defstruct @enforce_keys
  end

  @impl true
  def capabilities do
    %{
      piece: @piece,
      provider: "openai-compatible",
      wire_surface: "chat_completions",
      features: @features,
      reasoning: [],
      cache_ttls: [],
      convention: @convention,
      options: %{}
    }
  end

  ## endpoint: shape checks, then one egress decision

  @doc """
  Builds the `provider_config` term from exactly `base_url`, `policy`,
  `resolver`, `transport` and `models` (see the README). Returns
  `{:ok, endpoint}`, `{:error, {:egress, reason}}` or `{:error, :invalid}`; the
  resolver is called once, and only after every shape check passed.
  """
  def endpoint(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.sort(keys) == Enum.sort(@keys),
         true <- base_url?(opts[:base_url]),
         %EgressPolicy{} <- opts[:policy],
         true <- is_function(opts[:resolver], 1) and is_function(opts[:transport], 1),
         {:ok, models} <- models(opts[:models]) do
      case EgressPolicy.resolve(opts[:base_url], opts[:policy], opts[:resolver]) do
        {:ok, %{host: host, port: port, addresses: addresses}} ->
          {:ok,
           %Endpoint{
             base_url: opts[:base_url],
             host: host,
             port: port,
             addresses: addresses,
             transport: opts[:transport],
             models: models
           }}

        {:error, reason} ->
          {:error, {:egress, reason}}
      end
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  # The egress policy refuses userinfo and a fragment and never a query or a
  # non-https scheme on its own terms; this Piece refuses all four first.
  defp base_url?(url) when is_binary(url) and byte_size(url) in 1..@max_url_bytes do
    String.valid?(url) and
      match?(
        {:ok, %URI{scheme: "https", userinfo: nil, query: nil, fragment: nil}},
        URI.new(url)
      )
  end

  defp base_url?(_), do: false

  defp models(list) when is_list(list) and length(list) in 1..64 do
    entries =
      Enum.map(list, fn
        %{id: id, features: features} = m when map_size(m) == 2 and not is_struct(m) ->
          # No control character at all: text?/2 refuses C0 and DEL, \p{Cc} adds C1.
          if Elzoo.AiModel.text?(id, 256) and not String.match?(id, ~r/\p{Cc}/u) and
               is_list(features) and
               Enum.all?(features, &(&1 in @features)),
             do: {id, Enum.uniq(features)},
             else: :error

        _ ->
          :error
      end)

    cond do
      :error in entries -> :error
      length(Enum.uniq_by(entries, &elem(&1, 0))) != length(entries) -> :error
      true -> {:ok, Map.new(entries)}
    end
  end

  defp models(_), do: :error

  ## translate: pure, no credential

  @impl true
  def translate(request, %Endpoint{} = endpoint) do
    with {:ok, declared} <- Map.fetch(endpoint.models, request.model) |> declared(),
         true <- Enum.all?(needed(request), &(&1 in declared)) || {:refused, :unsupported_feature},
         :ok <- tool_errors(request.messages),
         true <- length(request.stop_sequences) <= @max_stops || {:refused, :invalid_request},
         {:ok, model} <- ReqLLM.model(%{provider: :lmstudio, id: request.model}) do
      tools = Enum.map(request.tools, &tool/1)

      opts =
        [max_tokens: request.max_output_tokens]
        |> put_if(tools != [], :tools, tools)
        |> put_if(tools != [], :tool_choice, tool_choice(request.tool_choice))
        |> put_if(request.stop_sequences != [], :stop, request.stop_sequences)
        |> Kernel.++(sampling(request.sampling))
        |> put_if(request.output_schema != nil, :provider_options,
          response_format: response_format(request.output_schema)
        )

      {:ok,
       %{
         model: model,
         context: ReqLLM.Context.new(Enum.map(request.messages, &message/1)),
         opts: opts,
         endpoint: endpoint
       }}
    else
      {:refused, _} = refused -> refused
      _ -> {:refused, :invalid_request}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

  def translate(_request, _not_an_endpoint), do: {:refused, :invalid_request}

  defp declared({:ok, features}), do: {:ok, features}
  defp declared(:error), do: {:refused, :invalid_request}

  defp needed(r) do
    images? = Enum.any?(r.messages, &match?(%{parts: [_ | _]}, &1))

    # Replayed tool calls and tool results are tool use on the wire, even with
    # no tool offered in this request.
    tools? =
      r.tools != [] or
        Enum.any?(r.messages, fn m ->
          match?(%{role: :tool_result}, m) or match?(%{role: :assistant, tool_calls: [_ | _]}, m)
        end)

    for {true, feature} <- [
          {tools?, :tools},
          {r.output_schema != nil, :structured_output},
          {r.stop_sequences != [], :stop_sequences},
          {r.sampling != nil, :sampling},
          {images?, :image_input}
        ],
        do: feature
  end

  # The Chat Completions tool message has no error member: the flag is refused,
  # never dropped.
  defp tool_errors(messages) do
    if Enum.any?(messages, &match?(%{role: :tool_result, is_error: true}, &1)),
      do: {:refused, :unsupported_feature},
      else: :ok
  end

  # The caller's schema unchanged; strict mode would require OpenAI's
  # strict-schema subset, so it is off and the interface validates the reply.
  defp response_format(schema),
    do: %{type: "json_schema", json_schema: %{name: "output", strict: false, schema: schema}}

  # req_llm's option schema takes floats only.
  defp sampling(nil), do: []

  defp sampling(s) do
    for {k, v} <- [temperature: s.temperature, top_p: s.top_p], v != nil, do: {k, v * 1.0}
  end

  defp message(%{role: :system, text: t}), do: ReqLLM.Context.system([text(t)])
  defp message(%{role: :user, parts: parts}), do: ReqLLM.Context.user(Enum.map(parts, &part/1))
  defp message(%{role: :user, text: t}), do: ReqLLM.Context.user([text(t)])

  defp message(%{role: :assistant, text: t, tool_calls: calls}) do
    ReqLLM.Context.assistant(t,
      tool_calls: Enum.map(calls, &%{id: &1.id, name: &1.name, arguments: &1.arguments})
    )
  end

  defp message(%{role: :tool_result, tool_use_id: id, text: t}),
    do: ReqLLM.Context.tool_result(id, t)

  defp part(%{type: :text, text: t}), do: text(t)

  defp part(%{type: :image, media_type: m, bytes: bytes}),
    do: ReqLLM.Message.ContentPart.image(bytes, m)

  defp text(t), do: ReqLLM.Message.ContentPart.text(t)

  # Tools are declared with a callback that refuses to run: proposals are data.
  defp tool(t) do
    ReqLLM.Tool.new!(
      name: t.name,
      description: t.description,
      parameter_schema: t.input_schema,
      callback: fn _ -> {:error, :not_executable} end
    )
  end

  defp tool_choice(:auto), do: :auto
  defp tool_choice(:none), do: :none
  defp tool_choice(:any), do: :required
  defp tool_choice({:tool, name}), do: %{type: "function", function: %{name: name}}

  defp put_if(opts, true, k, v), do: Keyword.put(opts, k, v)
  defp put_if(opts, false, _, _), do: opts

  ## call: exactly one HTTP exchange, only to the checked addresses

  @impl true
  def call(%{model: model, context: context, opts: opts, endpoint: e}, call_opts) do
    with {:ok, transport} <- transport(e),
         {:ok, request} <- prepare(model, context, opts, e, call_opts),
         {:ok, request} <- pinned(request, transport, call_opts) do
      # The body is bounded while it is received, not after buffering.
      %{request | into: &bounded/2}
      |> Req.Request.prepend_response_steps(elzoo_capture: &capture/1)
      |> Req.Request.prepend_error_steps(elzoo_halt: &halt_error/1)
      |> Req.request()
      |> exchange()
    end
  end

  # The host's pinning of the checked addresses. A failure, a raise or a
  # non-keyword answer sends nothing.
  defp transport(e) do
    case e.transport.(%{host: e.host, port: e.port, addresses: e.addresses}) do
      {:ok, opts} when is_list(opts) ->
        if Keyword.keyword?(opts), do: {:ok, opts}, else: {:transport, :unavailable}

      _ ->
        {:transport, :unavailable}
    end
  rescue
    _ -> {:transport, :unavailable}
  catch
    _, _ -> {:transport, :unavailable}
  end

  defp prepare(model, context, opts, e, call_opts) do
    opts =
      opts ++
        [
          api_key: call_opts.credential,
          base_url: e.base_url,
          max_retries: 0,
          receive_timeout: call_opts.receive_timeout_ms
        ]

    case ReqLLM.Providers.LMStudio.prepare_request(:chat, model, context, opts) do
      {:ok, %Req.Request{} = request} ->
        {:ok, request}

      _ ->
        # Request construction failed before any byte was sent; req_llm's
        # error value is dropped unread.
        {:transport, :not_sent}
    end
  rescue
    _ -> {:transport, :not_sent}
  end

  # req_llm's `finch` option is dropped, so the transport Need's options are the
  # only connection options (Req refuses `connect_options` beside `finch`); the
  # Piece's own settings come last and never include `connect_options`.
  defp pinned(request, transport, call_opts) do
    {:ok,
     request
     |> Req.Request.drop_options([:finch])
     |> Req.merge(without_receive_timeout(transport))
     |> Req.merge(retry: false, redirect: false, receive_timeout: call_opts.receive_timeout_ms)}
  rescue
    _ -> {:transport, :unavailable}
  end

  # Req 0.7.5 merges a keyword `finch` option's own `receive_timeout` after the
  # top-level one (Req.Finch.build/1), so the host's would win over the
  # interface's; it is removed and the pool name and other settings are kept.
  # Every entry is rewritten in place, so a repeated `finch` key keeps Req.merge/2's
  # last-wins order.
  defp without_receive_timeout(transport) do
    Enum.map(transport, fn
      {:finch, finch} when is_list(finch) -> {:finch, Keyword.delete(finch, :receive_timeout)}
      other -> other
    end)
  end

  @doc false
  # Req `into:` function: accumulates the body up to 4 MiB of wire bytes; a larger
  # body stops the transfer and is marked oversize (never kept, never classified
  # by status), as in integration/ai-text-openai.
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
      request_id: header(response, "x-request-id"),
      retry_after: header(response, "retry-after"),
      body:
        if(is_binary(response.body) and not oversize and byte_size(response.body) <= @max_raw_bytes,
          do: response.body,
          else: nil
        )
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

  ## decode: the documented Chat Completions response

  @impl true
  def decode(%{oversize: true}, _request), do: {:failure, :malformed_response}

  def decode(%{status: status} = raw, request) when status in 200..299 do
    with body when is_binary(body) <- raw.body,
         {:ok, %{} = r} <- Jason.decode(body),
         "chat.completion" <- r["object"],
         id when is_binary(id) <- r["id"],
         [%{"message" => %{"role" => "assistant"} = message, "finish_reason" => reason}]
         when is_binary(reason) <- r["choices"],
         # The documented message requires `content`, which may be null.
         true <- Map.has_key?(message, "content"),
         {:ok, content, refusal} <- content(message),
         {:ok, calls} <- calls(Map.get(message, "tool_calls")) do
      {:ok,
       %{
         response_id: id,
         request_id: raw.request_id || :absent,
         provider_model: r["model"],
         content: content,
         tool_calls: calls,
         structured_json: if(request.output_schema, do: content, else: nil),
         finish: finish(reason, refusal),
         usage: usage(Map.get(r, "usage"))
       }}
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

  # `content` and `refusal` are each a string or null; the refusal text is the
  # content when it is present.
  defp content(message) do
    case {Map.get(message, "content"), Map.get(message, "refusal")} do
      {c, nil} when is_binary(c) -> {:ok, c, false}
      {nil, nil} -> {:ok, "", false}
      {c, r} when is_binary(r) and (is_binary(c) or c == nil) -> {:ok, (c || "") <> r, true}
      _ -> :error
    end
  end

  defp calls(nil), do: {:ok, []}

  defp calls(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"id" => id, "type" => "function", "function" => %{"name" => n, "arguments" => a}},
      {:ok, acc}
      when is_binary(id) and is_binary(n) and is_binary(a) ->
        # The arguments string is passed on raw; the interface marks invalid JSON.
        {:cont, {:ok, acc ++ [%{id: id, name: n, arguments_json: a}]}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp calls(_), do: :error

  defp finish(_, true), do: :refusal
  defp finish("stop", _), do: :stop
  defp finish("length", _), do: :length
  defp finish("tool_calls", _), do: :tool_calls
  defp finish("content_filter", _), do: :content_filter

  defp finish(reason, _),
    do: {:other, if(Elzoo.AiModel.text?(reason, 64), do: reason, else: "unrecognized")}

  # The documented `usage` object (CompletionUsage): `prompt_tokens` includes
  # `prompt_tokens_details.cached_tokens`. An absent field is `:unknown`.
  defp usage(%{} = u) when map_size(u) > 0 do
    prompt = if is_map(u["prompt_tokens_details"]), do: u["prompt_tokens_details"], else: %{}
    completion = u["completion_tokens_details"]

    raw =
      %{
        input: amount(u["prompt_tokens"]),
        cache_read: amount(prompt["cached_tokens"]),
        cache_writes: [%{ttl: "provider_default", amount: amount(prompt["cache_write_tokens"])}],
        output: amount(u["completion_tokens"])
      }
      |> then(fn r ->
        case completion do
          %{"reasoning_tokens" => n} -> Map.put(r, :reasoning, amount(n))
          _ -> r
        end
      end)

    case Usage.from_provider(raw, @convention, :provider_reported) do
      {:ok, usage} -> usage
      _ -> Usage.unknown(@convention)
    end
  end

  defp usage(_), do: Usage.unknown(@convention)

  defp amount(n) when is_integer(n) and n >= 0, do: n
  defp amount(_), do: :unknown

  defp retry_after(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 86_400 -> n
      _ -> nil
    end
  end

  defp retry_after(_), do: nil

  ## classify_failure: the status table of integration/ai-text-openai

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
