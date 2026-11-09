# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Anthropic do
  @moduledoc """
  The Anthropic Message Batches provider of `integration/ai-batch`: a thin own
  Adapter on the pinned Req (`req_llm` has no batch client).

  Item bodies: each item is translated by `Elzoo.AiText.Anthropic.translate/2`
  (the synchronous translation), prepared with
  `ReqLLM.Providers.Anthropic.prepare_request/4` under the options the
  synchronous call uses and a placeholder key, and encoded with the documented
  provider callback `ReqLLM.Providers.Anthropic.encode_body/1`; the encoded map
  (read from the request's `:json` option, an undocumented location guarded by a
  drift test) becomes the item's `params` after removing `"stream": false`.
  Nothing is sent while preparing and the real key is never used there.

  Batch-global headers: `anthropic-version` is always the pin; the outer
  `anthropic-beta` is the sorted union of the items' values, each of which must
  be in `allowed_betas/0`; an item whose prepared request carries any other
  provider header, another version or another beta is refused
  `unsupported_feature`.

  Transport: one Req request per operation with the injected key as
  `x-api-key`, `retry: false`, `redirect: false`, no decompression, and every
  response body read through a bounded collector; results are streamed line by
  line under the page, line and scan bounds. Failure statuses are mapped by the
  synchronous provider's documented table (`Elzoo.AiText.Anthropic.decode/2` on a
  non-2xx exchange).
  """
  @behaviour Elzoo.AiBatch.Provider

  alias Elzoo.AiText.Anthropic, as: Text

  @piece "integration/ai-batch-anthropic"
  @version "2026-10-21"
  @base_url "https://api.anthropic.com"
  @path "/v1/messages/batches"
  @placeholder "elzoo-batch-body-only"
  @allowed_betas [
    "interleaved-thinking-2025-05-14",
    "prompt-caching-2024-07-31",
    "tools-2024-05-16"
  ]
  @allowed_headers ["anthropic-beta", "anthropic-version", "content-type", "x-api-key"]
  @max_body 4_194_304

  def api_version, do: @version
  def allowed_betas, do: @allowed_betas

  @impl true
  def capabilities do
    %{
      piece: @piece,
      provider: "anthropic",
      wire_surface: "message_batches",
      item_provider: Text,
      max_items: 100_000,
      max_create_wire_bytes: 256_000_000,
      options: %{}
    }
  end

  ## prepare: pure, no credential, nothing sent

  @impl true
  def prepare(%{items: items}, config) do
    with {:ok, cfg} <- provider_config(config),
         {:ok, prepared} <- collect(items, &item/1) do
      betas = prepared |> Enum.flat_map(& &1.betas) |> Enum.uniq() |> Enum.sort()

      body =
        Jason.encode!(%{
          "requests" => Enum.map(prepared, &%{"custom_id" => &1.item_id, "params" => &1.params})
        })

      {:ok, %{body: body, betas: betas, config: cfg}}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

  @doc """
  The item's batch `params` and beta values from the synchronous provider's
  wire: `{:ok, %{params, betas, headers}}` or `{:refused, reason}`. Public so the
  drift and equivalence tests read exactly what `prepare/2` sends.
  """
  def item_body(%{operation: op, model: model, context: context, opts: opts}) do
    opts =
      opts ++
        [
          api_key: @placeholder,
          max_retries: 0,
          anthropic_version: @version,
          req_http_options: [retry: false]
        ]

    with {:ok, request} <- ReqLLM.Providers.Anthropic.prepare_request(op, model, context, opts),
         {:ok, betas} <- headers(request.headers),
         %Req.Request{} = encoded <- ReqLLM.Providers.Anthropic.encode_body(request),
         %{} = json <- encoded.options[:json],
         {:ok, params} <- params(json) do
      {:ok, %{params: params, betas: betas, headers: Map.drop(request.headers, ["x-api-key"])}}
    else
      {:refused, r} -> {:refused, r}
      _ -> {:refused, :invalid_request}
    end
  end

  defp item(%{item_id: id, wire: wire}) do
    case item_body(wire) do
      {:ok, b} -> {:ok, Map.put(b, :item_id, id)}
      other -> other
    end
  end

  defp headers(headers) do
    keys = Map.keys(headers)

    with true <- Enum.all?(keys, &(&1 in @allowed_headers)),
         [@version] <- Map.get(headers, "anthropic-version"),
         betas = headers |> Map.get("anthropic-beta", []) |> Enum.flat_map(&String.split(&1, ",")),
         betas = Enum.map(betas, &String.trim/1),
         true <- Enum.all?(betas, &(&1 in @allowed_betas)) do
      {:ok, betas}
    else
      _ -> {:refused, :unsupported_feature}
    end
  end

  # The batch guide lists stream as not supported in batches: the default
  # false is removed; any other value is refused.
  defp params(json) do
    case Map.fetch(json, :stream) do
      {:ok, false} ->
        {:ok, Map.delete(json, :stream)}

      :error ->
        if(Map.has_key?(json, "stream"), do: {:refused, :unsupported_feature}, else: {:ok, json})

      _ ->
        {:refused, :unsupported_feature}
    end
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

  defp collect(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn x, {:ok, acc} ->
      case fun.(x) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  ## operations: one HTTP request each

  @impl true
  def submit(%{body: body, betas: betas, config: cfg}, call_opts) do
    beta = if betas == [], do: [], else: [{"anthropic-beta", Enum.join(betas, ",")}]

    case exchange(:post, @path, cfg, call_opts, body: body, headers: beta) do
      {:ok, %{status: s} = raw} when s in 200..299 ->
        case batch(raw.body) do
          {:ok, %{"id" => id}, _state} -> {:ok, %{provider_job_id: id, orphans: []}}
          _ -> {:failure, :malformed_response, %{orphans: []}}
        end

      other ->
        failure(other, %{orphans: []})
    end
  end

  @impl true
  def status(id, call_opts) do
    with {:ok, id} <- segment(id),
         do: state(exchange(:get, @path <> "/" <> id, cfg(call_opts), call_opts, []))
  end

  @impl true
  def cancel(id, call_opts) do
    with {:ok, id} <- segment(id),
         do: state(exchange(:post, @path <> "/" <> id <> "/cancel", cfg(call_opts), call_opts, []))
  end

  defp state({:ok, %{status: s} = raw}) when s in 200..299 do
    case batch(raw.body) do
      {:ok, _, state} -> {:ok, state}
      _ -> {:failure, :malformed_response, %{}}
    end
  end

  defp state(other), do: failure(other, %{})

  defp cfg(call_opts) do
    case provider_config(call_opts[:provider_config]) do
      {:ok, c} -> c
      _ -> %{}
    end
  end

  # A job id is a path segment: only id characters are sent; any other id is
  # refused before a request (reported as the provider's invalid-request tag).
  defp segment(id) do
    if is_binary(id) and id =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/,
      do: {:ok, id},
      else: {:failure, :provider_invalid_request, %{}}
  end

  @impl true
  def results(id, page, call_opts) do
    with {:ok, id} <- segment(id), do: read_results(id, page, call_opts)
  end

  defp read_results(id, page, call_opts) do
    path = @path <> "/" <> id <> "/results"
    init = %{buf: "", scanned: 0, ordinal: 0, lines: [], halted: nil, error: nil, body: ""}

    into = fn {:data, data}, {req, resp} ->
      st = Req.Response.get_private(resp, :elzoo_scan, init)

      st =
        if resp.status in 200..299,
          do: scan(st, data, page),
          else: error_body(st, data)

      action = if st.halted, do: :halt, else: :cont
      {action, {req, Req.Response.put_private(resp, :elzoo_scan, st)}}
    end

    case request(:get, path, cfg(call_opts), call_opts, into: into) do
      {:ok, %Req.Response{status: s} = r} when s in 200..299 ->
        st = Req.Response.get_private(r, :elzoo_scan, init)
        finish_scan(st, page)

      {:ok, %Req.Response{} = r} ->
        st = Req.Response.get_private(r, :elzoo_scan, init)
        failure({:ok, raw(r, st.body)}, %{})

      other ->
        failure(other, %{})
    end
  end

  defp error_body(st, data) do
    body = st.body <> data
    if byte_size(body) > 65_536, do: %{st | body: "", halted: :error}, else: %{st | body: body}
  end

  defp scan(st, data, page) do
    st = %{st | scanned: st.scanned + byte_size(data)}

    cond do
      st.scanned > page.max_scan_bytes ->
        %{st | halted: :error, error: :result_scan_limit}

      true ->
        {complete, rest} = split(st.buf <> data)
        st = Enum.reduce_while(complete, %{st | buf: rest}, &line(&1, &2, page))

        cond do
          st.halted ->
            st

          byte_size(st.buf) > page.max_line_bytes ->
            %{st | halted: :error, error: :result_line_limit}

          true ->
            st
        end
    end
  end

  defp split(buf) do
    parts = String.split(buf, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp line(text, st, page) do
    cond do
      byte_size(text) > page.max_line_bytes ->
        {:halt, %{st | halted: :error, error: :result_line_limit}}

      String.trim(text) == "" ->
        {:cont, st}

      st.ordinal < page.cursor ->
        {:cont, %{st | ordinal: st.ordinal + 1}}

      true ->
        case decode_line(text) do
          {:ok, l} ->
            st = %{st | ordinal: st.ordinal + 1, lines: [l | st.lines]}

            if length(st.lines) >= page.page_size,
              do: {:halt, %{st | halted: :page}},
              else: {:cont, st}

          :error ->
            {:halt, %{st | halted: :error, error: :malformed_response}}
        end
    end
  end

  defp finish_scan(%{halted: :error, error: e}, _)
       when e in [:result_scan_limit, :result_line_limit],
       do: {:failure, e, %{}}

  defp finish_scan(%{halted: :error}, _), do: {:failure, :malformed_response, %{}}

  defp finish_scan(%{halted: :page} = st, _),
    do: {:ok, %{lines: Enum.reverse(st.lines), done: false}}

  defp finish_scan(st, page) do
    # The stream ended: the last line may lack a newline.
    case line(st.buf, %{st | buf: ""}, page) do
      {:halt, %{halted: :error} = s} -> finish_scan(s, page)
      {_, s} -> {:ok, %{lines: Enum.reverse(s.lines), done: true}}
    end
  end

  # One documented results line: {"custom_id", "result": {"type", ...}}.
  defp decode_line(text) do
    with {:ok, %{"custom_id" => id, "result" => %{"type" => type} = result}} <- Jason.decode(text),
         true <- is_binary(id),
         {:ok, r} <- result(type, result) do
      {:ok, {id, r}}
    else
      _ -> :error
    end
  end

  defp result("succeeded", %{"message" => %{} = m}),
    do:
      {:ok, {:succeeded, %{status: 200, body: Jason.encode!(m), request_id: nil, retry_after: nil}}}

  defp result("errored", %{"error" => e}) do
    case e do
      %{"error" => %{"type" => "invalid_request_error"}} -> {:ok, {:errored, :invalid_request}}
      %{"type" => "invalid_request_error"} -> {:ok, {:errored, :invalid_request}}
      %{} -> {:ok, {:errored, :provider_error}}
      _ -> :error
    end
  end

  defp result("canceled", _), do: {:ok, :cancelled}
  defp result("expired", _), do: {:ok, :expired}
  defp result(_, _), do: :error

  # The documented Message Batch object.
  defp batch(body) when is_binary(body) do
    with {:ok, %{"type" => "message_batch", "id" => id, "processing_status" => ps} = b} <-
           Jason.decode(body),
         true <- is_binary(id) and id =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/,
         %{} = counts <- b["request_counts"],
         {:ok, state} <- job_state(ps, counts) do
      {:ok, b, state}
    else
      _ -> :error
    end
  end

  defp batch(_), do: :error

  @count_keys ["canceled", "errored", "expired", "processing", "succeeded"]

  defp job_state(ps, counts) do
    if Enum.sort(Map.keys(counts)) == @count_keys and
         Enum.all?(Map.values(counts), &(is_integer(&1) and &1 >= 0)) do
      case {ps, counts["processing"]} do
        {"in_progress", _} ->
          {:ok, :running}

        {"canceling", _} ->
          {:ok, :ending}

        {"ended", 0} ->
          {:ok,
           {:ended,
            %{
              succeeded: counts["succeeded"],
              errored: counts["errored"],
              cancelled: counts["canceled"],
              expired: counts["expired"]
            }}}

        _ ->
          :error
      end
    else
      :error
    end
  end

  ## transport

  defp exchange(method, path, cfg, call_opts, opts) do
    init = %{body: "", over: false}

    into = fn {:data, data}, {req, resp} ->
      st = Req.Response.get_private(resp, :elzoo_body, init)
      body = st.body <> data

      if byte_size(body) > @max_body,
        do: {:halt, {req, Req.Response.put_private(resp, :elzoo_body, %{body: "", over: true})}},
        else: {:cont, {req, Req.Response.put_private(resp, :elzoo_body, %{st | body: body})}}
    end

    case request(method, path, cfg, call_opts, Keyword.put(opts, :into, into)) do
      {:ok, %Req.Response{} = r} ->
        st = Req.Response.get_private(r, :elzoo_body, init)
        {:ok, raw(r, if(st.over, do: nil, else: st.body))}

      other ->
        other
    end
  end

  defp raw(r, body),
    do: %{
      status: r.status,
      request_id: header(r, "request-id"),
      retry_after: header(r, "retry-after"),
      body: body
    }

  defp request(method, path, cfg, call_opts, opts) do
    headers =
      [
        {"x-api-key", call_opts.credential},
        {"anthropic-version", @version},
        {"content-type", "application/json"}
      ] ++ Keyword.get(opts, :headers, [])

    [
      method: method,
      base_url: cfg[:base_url] || @base_url,
      url: path,
      headers: headers,
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: call_opts.receive_timeout_ms,
      into: Keyword.fetch!(opts, :into)
    ]
    |> then(&if(opts[:body], do: Keyword.put(&1, :body, opts[:body]), else: &1))
    |> then(&if(cfg[:plug], do: Keyword.put(&1, :plug, cfg.plug), else: &1))
    |> Req.new()
    |> Req.request()
    |> case do
      {:ok, %Req.Response{} = r} -> {:ok, r}
      {:error, %Req.TransportError{reason: :timeout}} -> {:transport, :timeout}
      {:error, _} -> {:transport, :other}
    end
  rescue
    _ -> {:transport, :other}
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [v | _] when is_binary(v) and byte_size(v) <= 256 ->
        if String.match?(v, ~r/\A[\x21-\x7E]+\z/), do: v, else: nil

      _ ->
        nil
    end
  end

  # Non-2xx statuses through the synchronous provider's documented table; a
  # transport result through its classify_failure.
  defp failure({:ok, %{status: s} = raw}, extra) when is_integer(s) do
    case Text.decode(raw, nil) do
      {:failure, tag, meta} -> {:failure, tag, Map.merge(extra, meta)}
      {:failure, tag} -> {:failure, tag, extra}
      _ -> {:failure, :malformed_response, extra}
    end
  end

  defp failure({:transport, _} = t, extra), do: {:failure, Text.classify_failure(t), extra}
  defp failure(_, extra), do: {:failure, :transport, extra}
end
