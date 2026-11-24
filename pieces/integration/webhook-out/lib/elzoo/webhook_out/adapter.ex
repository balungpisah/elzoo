# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WebhookOut.Adapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter of one webhook-out try. Order inside the send task: the
  binding and argument checks and the try that the intent key names; the endpoint, event and
  delivery read under the tenant scope with the payload digest check; the URL resolved again
  under the tenant's current policy; the secret; the transport Need; the trusted clock; then
  exactly one signed POST, stopped at `send_timeout_ms`. Every step before the POST is a
  not-sent failure with a no-send attestation. Before it returns, the Adapter writes the typed
  result as the observation of `(delivery_id, try, attempt)`; a failure of that write does not
  change the envelope. The Adapter never retries, never follows a redirect and keeps no
  response body.
  """
  alias Elzoo.WebhookOut
  alias Elzoo.WebhookOut.Binding

  @schema "elzoo/webhook-out-try-v1"
  @value_schema "elzoo/webhook-out-response"
  @argument_keys ~w(delivery_id endpoint_id event_id payload_sha256 tenant)

  def failure_tags, do: Map.keys(Binding.failures())
  def schema, do: @schema

  def validate(bytes, @schema), do: if(match?({:ok, _}, arguments(bytes)), do: :ok, else: :error)
  def validate(_, _), do: :error

  def send_effect(req) do
    with %{context: %WebhookOut{} = b, key: key, attempt: attempt, attempt_id: aid} <- req,
         {:ok, descriptor} <- Binding.load(b.effect.binding),
         true <- descriptor.digest == req.binding,
         {:ok, a} <- arguments(req.arguments),
         {:ok, try} <- try_of(b, a, key) do
      result = deliver(b, a, try)
      _ = observe(b, a, try, attempt, result)
      envelope(b, key, aid, result)
    else
      _ -> {:error, :unavailable, :webhook_out}
    end
  rescue
    # Only reached outside deliver/3, which returns every result itself; conservative.
    _ -> {:error, :transport, :webhook_out}
  catch
    _, _ -> {:error, :transport, :webhook_out}
  end

  # The canonical arguments of WebhookOut.arguments/5, as a map.
  defp arguments(bytes) when is_binary(bytes) do
    with {:ok, %{} = a} <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(a)) == @argument_keys,
         true <- Enum.all?(Map.values(a), &is_binary/1),
         ^bytes <- WebhookOut.canonical(a) do
      {:ok, Map.new(a, fn {k, v} -> {String.to_existing_atom(k), v} end)}
    else
      _ -> :error
    end
  end

  defp arguments(_), do: :error

  # The try whose intent identity hashes to the request's key.
  defp try_of(b, a, key) do
    case Enum.find(1..16, fn n ->
           Elzoo.EffectIntent.Model.key(WebhookOut.identity(b, a.tenant, a.delivery_id, n)) == key
         end) do
      nil -> :error
      n -> {:ok, n}
    end
  end

  # The typed result of this attempt; every failure before the POST is {:not_sent, tag}.
  defp deliver(b, a, try) do
    with {:ok, row} <- read(b, a, try),
         {:ok, target} <- egress(b, a.tenant, row.url),
         {:ok, key} <- secret(b, row.secret),
         {:ok, req} <- transport(b, target),
         {:ok, ts} <- timestamp(b) do
      post(b, req, row.url, a.event_id, ts, row.payload, key)
    end
  end

  defp read(b, a, try) do
    result =
      WebhookOut.run(b, a.tenant, fn ->
        case WebhookOut.q!(
               b,
               "SELECT d.endpoint_id, d.event_id, d.payload_sha256, d.state, d.try, e.url, e.secret_ref, e.secret_scope, ev.payload FROM #{WebhookOut.t(b, :deliveries)} d JOIN #{WebhookOut.t(b, :endpoints)} e ON e.tenant = d.tenant AND e.endpoint_id = d.endpoint_id JOIN #{WebhookOut.t(b, :events)} ev ON ev.tenant = d.tenant AND ev.event_id = d.event_id WHERE d.tenant = $1 AND d.delivery_id = $2",
               [a.tenant, a.delivery_id]
             ) do
          [row] -> {:ok, row}
          [] -> {:ok, nil}
        end
      end)

    case result do
      {:ok, [endpoint, event, digest, "pending", ^try, url, ref, scope, payload]}
      when endpoint == a.endpoint_id and event == a.event_id and digest == a.payload_sha256 ->
        if WebhookOut.sha256(payload) == digest,
          do: {:ok, %{url: url, secret: %{ref: ref, scope: scope}, payload: payload}},
          else: {:not_sent, :unavailable}

      _ ->
        {:not_sent, :unavailable}
    end
  end

  defp egress(b, tenant, url) do
    case WebhookOut.egress(b, tenant, url) do
      {:ok, target} -> {:ok, target}
      {:error, {:egress, r}} when r in [:dns_failed, :unavailable] -> {:not_sent, :dns}
      _ -> {:not_sent, :egress}
    end
  end

  # A Standard Webhooks secret: whsec_ and the base64 of 24..64 bytes.
  defp secret(b, request) do
    with {:ok, credential} <- Elzoo.Secrets.resolve(request, b.secrets.(request)),
         "whsec_" <> encoded <- Elzoo.Secrets.reveal(credential),
         {:ok, key} when byte_size(key) in 24..64 <- decode64(encoded) do
      {:ok, key}
    else
      _ -> {:not_sent, :secret}
    end
  rescue
    _ -> {:not_sent, :secret}
  catch
    _, _ -> {:not_sent, :secret}
  end

  defp decode64(encoded) do
    with :error <- Base.decode64(encoded), do: Base.decode64(encoded, padding: false)
  end

  # The host's Req options for the pinned addresses, then the Piece's own. connect_options is
  # never set here: Req.merge/2 would replace the host's as a whole.
  defp transport(b, target) do
    with {:ok, opts} <- b.transport.(target),
         true <- Keyword.keyword?(opts) do
      {:ok,
       opts
       |> Req.new()
       |> Req.merge(
         retry: false,
         redirect: false,
         receive_timeout: b.send_timeout_ms,
         # The response body is discarded as it arrives, never kept.
         into: fn {:data, _}, acc -> {:cont, acc} end
       )}
    else
      _ -> {:not_sent, :unavailable}
    end
  rescue
    _ -> {:not_sent, :unavailable}
  catch
    _, _ -> {:not_sent, :unavailable}
  end

  defp timestamp(b) do
    {:ok, div(WebhookOut.now!(b), 1000)}
  rescue
    _ -> {:not_sent, :unavailable}
  catch
    _, _ -> {:not_sent, :unavailable}
  end

  # Exactly one POST, in a task stopped at send_timeout_ms (which also bounds the connect).
  defp post(b, req, url, id, ts, body, key) do
    signature = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}"))

    headers = [
      {"webhook-id", id},
      {"webhook-timestamp", Integer.to_string(ts)},
      {"webhook-signature", "v1," <> signature},
      {"content-type", "application/json"}
    ]

    task =
      Task.async(fn ->
        try do
          classify(Req.request(req, method: :post, url: url, headers: headers, body: body))
        catch
          _, _ -> {:unknown, :transport}
        end
      end)

    case Task.yield(task, b.send_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:unknown, :timed_out}
    end
  end

  defp classify({:ok, %Req.Response{status: s}}) when s in 200..299, do: :delivered

  defp classify({:ok, %Req.Response{status: s}}) when s in [408, 429] or s in 500..599,
    do: {:failed, :retryable}

  defp classify({:ok, %Req.Response{}}), do: {:failed, :permanent}
  defp classify({:error, %Req.TransportError{reason: :timeout}}), do: {:unknown, :timed_out}
  defp classify(_), do: {:unknown, :transport}

  # The typed result, written in its own transaction; its failure is ignored.
  defp observe(b, a, try, attempt, result) do
    WebhookOut.run(b, a.tenant, fn ->
      WebhookOut.q!(
        b,
        "INSERT INTO #{WebhookOut.t(b, :observations)} (tenant, delivery_id, try, attempt, result, applied) VALUES ($1, $2, $3, $4, $5, false) ON CONFLICT DO NOTHING",
        [a.tenant, a.delivery_id, try, attempt, WebhookOut.encode_result(result)]
      )

      {:ok, :observed}
    end)
  end

  defp envelope(b, key, aid, :delivered) do
    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => aid,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"seal" => seal(b, key, aid)},
      "value_schema_id" => @value_schema,
      "value_schema_version" => 1
    }
  end

  defp envelope(_, _, _, {_, tag}), do: {:error, tag, :webhook_out}

  @doc "A receiver has no status query: an unknown outcome stays unknown."
  def poll(_req), do: {:unavailable, :no_status_query}

  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => @value_schema,
          "value_schema_version" => 1,
          "value" => %{"seal" => s} = v
        },
        _req
      ) do
    if map_size(v) == 1 and is_binary(s) and byte_size(s) == 64, do: :ok, else: :error
  end

  def validate_result(_, _), do: :error

  def authenticate({:unavailable, :no_status_query}, _), do: :ok

  # Process-local integrity of this Adapter's own completion, not receiver authentication.
  def authenticate(
        %{"attempt_id" => aid, "value" => %{"seal" => s}},
        %{key: key, attempt_id: aid, context: %WebhookOut{} = b}
      )
      when is_binary(s) do
    expected = seal(b, key, aid)

    if byte_size(s) == byte_size(expected) and :crypto.hash_equals(s, expected),
      do: :ok,
      else: :error
  end

  def authenticate(_, _), do: :error

  defp seal(b, key, aid) do
    data = Enum.map([key, aid], &<<byte_size(&1)::32, &1::binary>>)
    :crypto.mac(:hmac, :sha256, b.seal_key, data) |> Base.encode16(case: :lower)
  end
end
