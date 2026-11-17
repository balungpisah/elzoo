defmodule Elzoo.WebhookIn do
  @moduledoc """
  A bounded Plug for one signed, first-party webhook request profile.

  The host must call this Plug before any body-reading/parser middleware and
  must enforce the total request lifetime. Plug has no public universal flag
  for detecting a previous partial body read.
  """
  @behaviour Plug

  @path "/elzoo/v1/messages"
  @max_body 65_536
  @max_text 4_096
  @max_revision 9_223_372_036_854_775_806
  @max_timestamp 9_223_372_036_854_775_807
  @budget_ms 15_000
  @read_ms 5_000
  @read_chunk 8_192

  @options [:source_id, :key, :clock, :principal, :admit]
  @event_keys [
    "version",
    "event_id",
    "conversation_id",
    "input_id",
    "expected_revision",
    "text"
  ]

  @impl true
  def init(options) do
    if valid_options?(options) do
      Map.new(options)
    else
      raise ArgumentError, "invalid webhook ingress options"
    end
  end

  @impl true
  def call(%Plug.Conn{} = conn, opts) do
    cond do
      conn.request_path != @path or conn.query_string != "" ->
        respond(conn, 404, "not_found")

      conn.method != "POST" ->
        respond(conn, 405, "method_not_allowed")

      true ->
        process_request(conn, opts)
    end
  end

  defp process_request(conn, opts) do
    with :ok <- unread_body(conn.body_params),
         :ok <- content_length(conn),
         :ok <- content_type(conn),
         :ok <- content_encoding(conn),
         {:ok, timestamp_bytes, timestamp} <- timestamp_header(conn),
         {:ok, signature} <- signature_header(conn) do
      case read_raw_body(conn) do
        {:ok, body, next_conn, started} ->
          authenticate_and_admit(
            next_conn,
            opts,
            timestamp_bytes,
            timestamp,
            signature,
            body,
            started
          )

        {:error, status, tag, next_conn} ->
          respond(next_conn, status, tag)
      end
    else
      {:error, status, tag} -> respond(conn, status, tag)
    end
  end

  defp authenticate_and_admit(conn, opts, timestamp_bytes, timestamp, signature, body, started) do
    with {:ok, key} <- key_need(opts.key),
         {:ok, now} <- clock_need(opts.clock),
         :ok <- freshness(timestamp, now),
         :ok <- signature(opts.source_id, key, timestamp_bytes, body, signature),
         {:ok, event} <- decode_event(body) do
      scope_and_admit(conn, opts, event, started)
    else
      {:error, :unauthorized} -> respond(conn, 401, "unauthorized")
      {:error, :invalid} -> respond(conn, 400, "invalid")
      {:error, :unavailable} -> respond(conn, 503, "unavailable")
    end
  end

  defp scope_and_admit(conn, opts, event, started) do
    event_id = event.event_id

    cond do
      expired?(started) ->
        respond(conn, 408, "timeout", event_id)

      true ->
        case principal(opts.principal, conn) do
          {:ok, scope} ->
            case validate_scope(scope) do
              {:ok, scope} ->
                cond do
                  event.conversation_id not in scope.resources ->
                    respond(conn, 403, "forbidden", event_id)

                  expired?(started) ->
                    respond(conn, 408, "timeout", event_id)

                  true ->
                    admit(conn, opts.admit, event, scope)
                end

              :error ->
                respond(conn, 503, "unavailable", event_id)
            end

          {:error, :forbidden} ->
            respond(conn, 403, "forbidden", event_id)

          _ ->
            respond(conn, 503, "unavailable", event_id)
        end
    end
  end

  defp admit(conn, callback, event, scope) do
    reply =
      try do
        callback.(event, scope)
      rescue
        _ -> :unknown
      catch
        _, _ -> :unknown
      end

    case reply do
      {:committed, revision}
      when is_integer(revision) and revision == event.expected_revision + 1 and
             revision in 1..9_223_372_036_854_775_807 ->
        respond(conn, 202, "committed", event.event_id, revision)

      {:pending, :approval} ->
        respond(conn, 202, "pending_approval", event.event_id)

      {:rejected, :forbidden} ->
        respond(conn, 403, "forbidden", event.event_id)

      {:rejected, :conflict} ->
        respond(conn, 409, "conflict", event.event_id)

      {:rejected, :invalid} ->
        respond(conn, 400, "invalid", event.event_id)

      :unknown ->
        respond(conn, 503, "unknown", event.event_id)

      {:error, :unavailable} ->
        respond(conn, 503, "unavailable", event.event_id)

      _ ->
        respond(conn, 503, "unknown", event.event_id)
    end
  end

  defp read_raw_body(conn) do
    started = System.monotonic_time(:millisecond)
    read_raw_body(conn, started, [], 0)
  end

  defp read_raw_body(conn, started, chunks, total) do
    remaining = @budget_ms - (System.monotonic_time(:millisecond) - started)

    if remaining <= 0 do
      {:error, 408, "timeout", conn}
    else
      options = [
        length: @read_chunk,
        read_length: @read_chunk,
        read_timeout: min(@read_ms, remaining)
      ]

      case Plug.Conn.read_body(conn, options) do
        {:ok, chunk, next_conn} when is_binary(chunk) ->
          finish_read(next_conn, started, chunks, total, chunk, false)

        {:more, chunk, next_conn} when is_binary(chunk) ->
          finish_read(next_conn, started, chunks, total, chunk, true)

        {:error, :timeout} ->
          {:error, 408, "timeout", conn}

        {:error, _} ->
          if expired?(started),
            do: {:error, 408, "timeout", conn},
            else: {:error, 400, "invalid", conn}

        _ ->
          if expired?(started),
            do: {:error, 408, "timeout", conn},
            else: {:error, 400, "invalid", conn}
      end
    end
  rescue
    _ ->
      if expired?(started), do: {:error, 408, "timeout", conn}, else: {:error, 400, "invalid", conn}
  end

  defp finish_read(conn, started, chunks, total, chunk, more?) do
    size = byte_size(chunk)
    next_total = total + size

    cond do
      expired?(started) ->
        {:error, 408, "timeout", conn}

      next_total > @max_body ->
        {:error, 413, "too_large", conn}

      more? and size == 0 ->
        {:error, 408, "timeout", conn}

      more? ->
        read_raw_body(conn, started, [chunk | chunks], next_total)

      true ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Kernel.<>(chunk), conn, started}
    end
  end

  defp key_need(callback) do
    case safe_call(callback) do
      {:ok, key} when is_binary(key) and byte_size(key) in 32..128 ->
        {:ok, key}

      _ ->
        {:error, :unavailable}
    end
  end

  defp clock_need(callback) do
    case safe_call(callback) do
      clock when is_integer(clock) and clock in 0..@max_timestamp -> {:ok, clock}
      _ -> {:error, :unavailable}
    end
  end

  defp safe_call(callback) do
    try do
      callback.()
    rescue
      _ -> :raised
    catch
      _, _ -> :raised
    end
  end

  defp principal(callback, conn) do
    try do
      callback.(conn)
    rescue
      _ -> :malformed
    catch
      _, _ -> :malformed
    end
  end

  defp freshness(timestamp, now) do
    if abs(timestamp - now) <= 300, do: :ok, else: {:error, :unauthorized}
  end

  defp signature(source_id, key, timestamp_bytes, body, signature) do
    framed = [
      "elzoo-webhook-v1\n",
      source_id,
      "\nPOST\n/elzoo/v1/messages\n",
      timestamp_bytes,
      "\n",
      body
    ]

    expected = :crypto.mac(:hmac, :sha256, key, framed)
    if Plug.Crypto.secure_compare(signature, expected), do: :ok, else: {:error, :unauthorized}
  end

  defp decode_event(body) do
    with {:ok, %Jason.OrderedObject{values: pairs} = object} <-
           Jason.decode(body, objects: :ordered_objects),
         true <- no_duplicate_keys?(object),
         true <- Enum.sort(Enum.map(pairs, &elem(&1, 0))) == Enum.sort(@event_keys),
         event <- Map.new(pairs),
         true <- event["version"] === 1,
         true <- valid_id?(event["event_id"]),
         true <- valid_id?(event["conversation_id"]),
         true <- valid_id?(event["input_id"]),
         true <-
           is_integer(event["expected_revision"]) and
             event["expected_revision"] in 0..@max_revision,
         true <- valid_text?(event["text"]) do
      {:ok,
       %{
         version: 1,
         event_id: event["event_id"],
         conversation_id: event["conversation_id"],
         input_id: event["input_id"],
         expected_revision: event["expected_revision"],
         text: event["text"]
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp no_duplicate_keys?(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    length(keys) == length(Enum.uniq(keys)) and
      Enum.all?(pairs, fn {_key, value} -> no_duplicate_keys?(value) end)
  end

  defp no_duplicate_keys?(list) when is_list(list), do: Enum.all?(list, &no_duplicate_keys?/1)
  defp no_duplicate_keys?(_), do: true

  defp validate_scope(scope) when is_map(scope) and not is_struct(scope) do
    with true <- Enum.sort(Map.keys(scope)) == [:actor, :resources, :tenant],
         true <- valid_scope_id?(scope.tenant),
         true <- valid_scope_id?(scope.actor),
         true <- valid_resources?(scope.resources) do
      {:ok, %{tenant: scope.tenant, actor: scope.actor, resources: scope.resources}}
    else
      _ -> :error
    end
  end

  defp validate_scope(_), do: :error

  defp valid_scope_id?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..128 and :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_scope_id?(_), do: false

  defp valid_resources?(resources), do: valid_resources?(resources, 0)
  defp valid_resources?([], count), do: count <= 64

  defp valid_resources?([resource | rest], count) when count < 64 do
    valid_scope_id?(resource) and valid_resources?(rest, count + 1)
  end

  defp valid_resources?(_, _count), do: false

  defp valid_id?(value) when is_binary(value) and byte_size(value) in 1..128 do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      (byte >= ?A and byte <= ?Z) or (byte >= ?a and byte <= ?z) or
        (byte >= ?0 and byte <= ?9) or byte in [?., ?_, ?-]
    end)
  end

  defp valid_id?(_), do: false

  defp valid_text?(value) when is_binary(value) do
    byte_size(value) in 1..@max_text and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_text?(_), do: false

  defp unread_body(%Plug.Conn.Unfetched{aspect: :body_params}), do: :ok
  defp unread_body(_), do: {:error, 400, "invalid"}

  defp content_length(conn) do
    case single_header(conn, "content-length") do
      :missing ->
        :ok

      {:ok, value} ->
        cond do
          not canonical_decimal?(value) ->
            {:error, 400, "invalid"}

          byte_size(value) > 5 ->
            {:error, 413, "too_large"}

          String.to_integer(value) > @max_body ->
            {:error, 413, "too_large"}

          true ->
            :ok
        end

      _ ->
        {:error, 400, "invalid"}
    end
  end

  defp content_type(conn) do
    case single_header(conn, "content-type") do
      {:ok, value} ->
        if String.valid?(value) do
          if String.downcase(String.trim(value)) == "application/json",
            do: :ok,
            else: {:error, 415, "unsupported_media_type"}
        else
          {:error, 400, "invalid"}
        end

      :missing ->
        {:error, 415, "unsupported_media_type"}

      {:error, _} ->
        {:error, 400, "invalid"}
    end
  end

  defp content_encoding(conn) do
    case Plug.Conn.get_req_header(conn, "content-encoding") do
      [] ->
        :ok

      [value] when not is_binary(value) ->
        {:error, 400, "invalid"}

      [value] ->
        cond do
          not String.valid?(value) -> {:error, 400, "invalid"}
          :binary.match(value, ",") != :nomatch -> {:error, 400, "invalid"}
          true -> {:error, 415, "unsupported_media_type"}
        end

      _ ->
        {:error, 400, "invalid"}
    end
  end

  defp timestamp_header(conn) do
    case single_header(conn, "x-elzoo-timestamp") do
      {:ok, value} when is_binary(value) and byte_size(value) <= 19 ->
        if canonical_decimal?(value) do
          timestamp = String.to_integer(value)

          if timestamp <= @max_timestamp,
            do: {:ok, value, timestamp},
            else: {:error, 400, "invalid"}
        else
          {:error, 400, "invalid"}
        end

      _ ->
        {:error, 400, "invalid"}
    end
  end

  defp signature_header(conn) do
    case single_header(conn, "x-elzoo-signature") do
      {:ok, "v1=" <> hex} when byte_size(hex) == 64 ->
        case Base.decode16(hex, case: :lower) do
          {:ok, signature} -> {:ok, signature}
          _ -> {:error, 400, "invalid"}
        end

      _ ->
        {:error, 400, "invalid"}
    end
  end

  defp single_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [] ->
        :missing

      [value] when is_binary(value) ->
        if :binary.match(value, ",") != :nomatch, do: {:error, :coalesced}, else: {:ok, value}

      [_] ->
        {:error, :malformed}

      _ ->
        {:error, :duplicate}
    end
  end

  defp valid_options?(options) when is_list(options) do
    Keyword.keyword?(options) and Enum.sort(Keyword.keys(options)) == Enum.sort(@options) and
      valid_id?(Keyword.get(options, :source_id)) and
      is_function(Keyword.get(options, :key), 0) and
      is_function(Keyword.get(options, :clock), 0) and
      is_function(Keyword.get(options, :principal), 1) and
      is_function(Keyword.get(options, :admit), 2)
  end

  defp valid_options?(_), do: false

  defp canonical_decimal?("0"), do: true

  defp canonical_decimal?(<<first, rest::binary>>) when first in ?1..?9 do
    Enum.all?(:binary.bin_to_list(rest), &(&1 in ?0..?9))
  end

  defp canonical_decimal?(_), do: false

  defp expired?(started), do: System.monotonic_time(:millisecond) - started >= @budget_ms

  defp respond(conn, status, tag, event_id \\ nil, revision \\ nil) do
    body =
      %{"status" => tag}
      |> maybe_put("event_id", event_id)
      |> maybe_put("revision", revision)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
    |> Plug.Conn.halt()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
