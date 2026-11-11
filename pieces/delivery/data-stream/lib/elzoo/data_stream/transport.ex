# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Transport do
  @moduledoc false
  alias Elzoo.DataStream.{Framer, Protocol}

  @statuses %{
    400 => :provider_invalid_request,
    401 => :authentication_failed,
    402 => :billing_error,
    403 => :permission_denied,
    404 => :not_found,
    409 => :conflict,
    413 => :provider_too_large,
    429 => :throttled,
    504 => :provider_timeout,
    529 => :overloaded
  }
  def headers(status, headers) do
    retry_after =
      case Map.get(headers, "retry-after", []) do
        [s] when is_binary(s) ->
          if Regex.match?(~r/\A[0-9]{1,5}\z/, s) and String.to_integer(s) <= 86_400,
            do: String.to_integer(s),
            else: :unknown

        _ ->
          :unknown
      end

    if status != 200 do
      {:error, Map.get(@statuses, status, :provider_error), retry_after}
    else
      with [ct] when is_binary(ct) <- Map.get(headers, "content-type", []),
           true <-
             Regex.match?(
               ~r/\Atext\/event-stream(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?\z/i,
               String.trim(ct)
             ),
           true <- Map.get(headers, "content-encoding", []) in [[], ["identity"]],
           id = Map.get(headers, "request-id", []),
           true <- id == [] or (length(id) == 1 and Protocol.id?(hd(id))) do
        {:ok, if(id == [], do: :absent, else: :binary.copy(hd(id))), retry_after}
      else
        _ -> {:error, :malformed_response, retry_after}
      end
    end
  end

  def request(body, key, config, into, seam) do
    {url, tls} = endpoint(seam)
    # Starting from the public low-level constructor bypasses global defaults
    # and plugins; attach exactly the pinned built-in steps.
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: url,
      body: body,
      headers: [
        {"anthropic-version", "2026-10-21"},
        {"content-type", "application/json"},
        {"accept", "text/event-stream"},
        {"accept-encoding", "identity"},
        {"x-api-key", key}
      ],
      into: into,
      retry: false,
      redirect: false,
      raw: true,
      decode_body: false,
      finch:
        Req.Finch.pool_options(%{
          connect_options: [protocols: [:http1], timeout: 5_000] ++ tls,
          pool_max_idle_time: 60_000
        }) ++ [pool_timeout: 5_000],
      receive_timeout: config.receive_timeout_ms
    )
  end

  # Private trusted test entry, separate from production Config. Only loopback
  # origins and an optional CA file are permitted; path/method stay fixed.
  def endpoint(:production), do: {"https://api.anthropic.com/v1/messages", []}

  def endpoint({:loopback, origin, ca}) do
    u = URI.parse(origin)

    true =
      u.scheme in ["http", "https"] and u.host in ["localhost", "127.0.0.1", "::1"] and
        is_integer(u.port) and u.port in 1..65_535 and u.path in [nil, ""] and is_nil(u.query) and
        is_nil(u.fragment) and is_nil(u.userinfo)

    true = ca == nil or (u.scheme == "https" and is_binary(ca))

    {origin <> "/v1/messages",
     if(is_nil(ca), do: [], else: [transport_opts: [cacertfile: ca, verify: :verify_peer]])}
  end

  def run(session, token, prepared, config, seam) do
    result =
      if System.monotonic_time(:millisecond) < prepared.deadline,
        do: credentials(config.credentials),
        else: :expired

    cond do
      System.monotonic_time(:millisecond) >= prepared.deadline ->
        :timeout

      not match?({:ok, _}, result) ->
        :credentials_unavailable

      true ->
        {:ok, key} = result

        case GenServer.call(session, {:handoff, token, self()}, :infinity) do
          :ok -> receive_http(session, token, prepared.body, key, config, seam)
          _ -> :timeout
        end
    end
  rescue
    _ -> :adapter_error
  catch
    _, _ -> :adapter_error
  end

  defp receive_http(session, token, body, key, config, seam) do
    slot = make_ref()
    Process.put(slot, {Framer.new(), false, false})

    block = fn bytes, _ ->
      case GenServer.call(session, {:block, token, self(), bytes}, :infinity) do
        :ok -> {:ok, nil}
        :halt -> {:halt, nil}
        {:error, r} -> {:error, r, nil}
      end
    end

    into = fn {:data, bytes}, {req, resp} ->
      {framer, _, _} = Process.get(slot)

      case GenServer.call(
             session,
             {:received, token, self(), byte_size(bytes), resp.status, resp.headers},
             :infinity
           ) do
        :ok ->
          case Framer.feed(framer, bytes, nil, block) do
            {:ok, f, _} ->
              Process.put(slot, {f, true, false})
              {:cont, {req, resp}}

            {:halt, f, _} ->
              Process.put(slot, {f, true, true})
              {:halt, {req, resp}}

            {:error, r, f, _} ->
              Process.put(slot, {f, true, false})
              GenServer.call(session, {:http_failure, token, self(), r}, :infinity)
              {:halt, {req, resp}}
          end

        {:error, _} ->
          Process.put(slot, {framer, true, false})
          {:halt, {req, resp}}
      end
    end

    response = request(body, key, config, into, seam) |> Req.request()
    {framer, called, stopped} = Process.delete(slot)

    cond do
      stopped and match?({:ok, %Req.Response{}}, response) ->
        :source_stop

      match?({:error, _}, response) ->
        :transport

      true ->
        {:ok, resp} = response

        if not called,
          do:
            GenServer.call(
              session,
              {:received, token, self(), 0, resp.status, resp.headers},
              :infinity
            )

        case Framer.eof(framer, nil, block) do
          {:halt, _, _} -> :source_stop
          {:error, r, _, _} -> r
          _ -> :missing_completion
        end
    end
  end

  defp credentials(fun) do
    case fun.() do
      {:ok, b} when is_binary(b) and byte_size(b) in 1..1024 ->
        if Regex.match?(~r/\A[\x21-\x7e]+\z/, b), do: {:ok, b}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
