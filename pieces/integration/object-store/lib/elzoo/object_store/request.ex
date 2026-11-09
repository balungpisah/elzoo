# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStore.Request do
  @moduledoc false
  # The request process. It resolves the credential Need, builds the Req request (req_s3
  # attached, every credential, endpoint and region passed explicitly), performs one
  # operation and sends back one sanitized result map. Every exception, exit and throw is
  # caught here and turned into a reason atom, so no Req structure (which holds the resolved
  # credential) and no exception term leaves this process. The caller kills it at the
  # deadline; it is started with spawn_monitor (no link, no proc_lib crash report).

  alias Elzoo.ObjectStore.{Config, Result}

  @tag :elzoo_object_store_body
  @error_body_cap 65_536

  def run(%Config{} = config, op, base, remaining_ms) do
    case Config.resolve_credentials(config) do
      {:ok, ak, sk} ->
        req = build(config, ak, sk, remaining_ms)

        try do
          perform(req, config, op, base)
        rescue
          e in Req.TransportError -> Result.unknown(base, transport_reason(e))
          _ -> Result.unknown(base, :adapter_error)
        catch
          :throw, {@tag, _} -> Result.unknown(base, :transport)
          _, _ -> Result.unknown(base, :adapter_error)
        end

      :error ->
        Result.refused(base, :credentials_unavailable, :local)
    end
  catch
    _, _ -> Result.unknown(base, :adapter_error)
  end

  defp transport_reason(%Req.TransportError{reason: :timeout}), do: :deadline
  defp transport_reason(_), do: :transport

  defp build(config, ak, sk, remaining_ms) do
    options =
      [
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false,
        receive_timeout: remaining_ms,
        connect_options: [timeout: remaining_ms],
        aws_sigv4: [access_key_id: ak, secret_access_key: sk, region: config.region, service: :s3]
      ] ++ if(config.finch, do: [finch: config.finch], else: [])

    options
    |> Req.new()
    |> ReqS3.attach(aws_endpoint_url_s3: config.endpoint)
  end

  @doc false
  def object_url(config, key), do: "s3://#{config.bucket}/#{encode_key(key)}"

  @doc false
  def encode_key(key), do: URI.encode(key, &(URI.char_unreserved?(&1) or &1 == ?/))

  # ---- operations

  defp perform(req, config, {:put, key, body, opts}, base) do
    {body, length} =
      case body do
        {:binary, bin} -> {bin, byte_size(bin)}
        {:stream, enum, length} -> {guarded(enum, length), length}
      end

    sent = Base.encode64(opts.sha256)

    headers =
      [
        {"content-type", opts.content_type},
        {"content-length", Integer.to_string(length)},
        {"x-amz-checksum-sha256", sent}
      ] ++ if(opts.if_absent, do: [{"if-none-match", "*"}], else: [])

    resp =
      Req.request!(req,
        method: :put,
        url: object_url(config, key),
        headers: headers,
        body: body,
        into: capped(@error_body_cap)
      )

    case resp.status do
      200 ->
        if header(resp, "x-amz-checksum-sha256") == sent do
          Map.merge(base, %{
            status: :committed,
            etag: etag(resp),
            bytes: length,
            sha256: Base.encode16(opts.sha256, case: :lower)
          })
        else
          Result.unknown(base, :unverified)
        end

      status ->
        Result.classify_error(base, status, body_code(resp), :put)
    end
  end

  defp perform(req, config, {:get, key, max}, base) do
    resp =
      Req.request!(req,
        method: :get,
        url: object_url(config, key),
        headers: [{"x-amz-checksum-mode", "ENABLED"}],
        into: capped(max)
      )

    case resp.status do
      200 ->
        if resp.private[:elzoo_over] do
          Result.refused(base, :too_large, :adapter)
        else
          body = collected(resp)
          meta = metadata(resp, byte_size(body))

          if meta.sha256 == nil or meta.sha256 == hex(:crypto.hash(:sha256, body)) do
            Map.merge(base, %{status: :found, metadata: meta, body: body})
          else
            Result.unknown(base, :integrity)
          end
        end

      status ->
        Result.classify_error(base, status, body_code(resp), :get)
    end
  end

  defp perform(req, config, {:head, key}, base) do
    resp =
      Req.request!(req,
        method: :head,
        url: object_url(config, key),
        headers: [{"x-amz-checksum-mode", "ENABLED"}]
      )

    case {resp.status, header(resp, "x-minio-error-code")} do
      {200, _} ->
        Map.merge(base, %{status: :found, metadata: metadata(resp, nil)})

      {404, nil} ->
        # The provider omitted the error code: one documented bucket HEAD decides between a
        # missing key and a missing bucket before `absent` is answered.
        bucket = Req.request!(req, method: :head, url: "s3://#{config.bucket}")

        case bucket.status do
          200 -> Map.put(base, :status, :absent)
          404 -> Result.refused(base, :no_such_bucket, :provider)
          status -> Result.classify_error(base, status, nil, :head)
        end

      {status, code} ->
        Result.classify_error(base, status, code, :head)
    end
  end

  defp perform(req, config, {:list, prefix, page_size, continuation}, base) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}, {"max-keys", Integer.to_string(page_size)}] ++
        if(continuation, do: [{"continuation-token", continuation}], else: [])

    resp =
      Req.request!(req,
        method: :get,
        url: "s3://#{config.bucket}",
        params: params,
        decode_body: true
      )

    case resp.status do
      200 -> listed(resp.body, page_size, base)
      status -> Result.classify_error(base, status, body_code(resp), :list)
    end
  end

  defp perform(req, config, {:delete, key}, base) do
    resp =
      Req.request!(req,
        method: :delete,
        url: object_url(config, key),
        into: capped(@error_body_cap)
      )

    case resp.status do
      204 -> Map.merge(base, %{status: :committed, etag: nil, bytes: 0, sha256: nil})
      status -> Result.classify_error(base, status, body_code(resp), :delete)
    end
  end

  defp listed(%{"ListBucketResult" => %{} = r}, page_size, base) do
    contents = List.wrap(Map.get(r, "Contents", []))
    keys = Enum.map(contents, &(is_map(&1) && &1["Key"]))
    truncated = r["IsTruncated"]
    token = r["NextContinuationToken"]

    cond do
      not Enum.all?(keys, &is_binary/1) or length(keys) > page_size ->
        Result.unknown(base, :unexpected)

      truncated == "true" and is_binary(token) and token != "" ->
        Map.merge(base, %{status: :listed, keys: keys, truncated: true, continuation: token})

      truncated == "false" ->
        Map.merge(base, %{status: :listed, keys: keys, truncated: false, continuation: nil})

      true ->
        Result.unknown(base, :unexpected)
    end
  end

  defp listed(_, _, base), do: Result.unknown(base, :unexpected)

  # ---- bodies

  # Pull the caller's enumerable one element at a time. A failure inside it, a non-binary
  # element or more bytes than declared stops the transfer with a tagged throw (classified
  # `unknown{transport}`: the body transfer was interrupted after dispatch).
  defp guarded(enum, length) do
    Stream.resource(
      fn -> {&Enumerable.reduce(enum, &1, fn x, _ -> {:suspend, x} end), 0} end,
      fn
        :done ->
          {:halt, :done}

        {cont, sent} ->
          step =
            try do
              cont.({:cont, nil})
            catch
              _, _ -> throw({@tag, :source_failed})
            end

          case step do
            {:suspended, chunk, next} when is_binary(chunk) ->
              sent = sent + byte_size(chunk)
              if sent > length, do: throw({@tag, :overflow})
              {[chunk], {next, sent}}

            {:suspended, _chunk, _next} ->
              throw({@tag, :not_binary})

            {done, _} when done in [:done, :halted] ->
              {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp capped(max) do
    fn {:data, data}, {req, resp} ->
      n = (resp.private[:elzoo_n] || 0) + byte_size(data)

      if n > max do
        {:halt, {req, Req.Response.put_private(resp, :elzoo_over, true)}}
      else
        acc = [resp.private[:elzoo_acc] || [] | data]

        resp =
          resp
          |> Req.Response.put_private(:elzoo_n, n)
          |> Req.Response.put_private(:elzoo_acc, acc)

        {:cont, {req, resp}}
      end
    end
  end

  defp collected(resp), do: IO.iodata_to_binary(resp.private[:elzoo_acc] || [])

  defp body_code(%{body: %{"Error" => %{"Code" => code}}}) when is_binary(code), do: code

  defp body_code(resp) do
    body =
      case resp.body do
        b when is_binary(b) and b != "" -> b
        _ -> collected(resp)
      end

    case Regex.run(
           ~r/<Code>([A-Za-z0-9.]{1,64})<\/Code>/,
           binary_part(body, 0, min(byte_size(body), @error_body_cap))
         ) do
      [_, code] -> code
      _ -> nil
    end
  end

  # ---- response fields

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp etag(resp) do
    case header(resp, "etag") do
      nil -> nil
      v -> String.trim(v, "\"")
    end
  end

  defp metadata(resp, size) do
    size =
      size ||
        case Integer.parse(header(resp, "content-length") || "") do
          {n, ""} -> n
          _ -> nil
        end

    sha256 =
      with v when is_binary(v) <- header(resp, "x-amz-checksum-sha256"),
           {:ok, raw} when byte_size(raw) == 32 <- Base.decode64(v) do
        hex(raw)
      else
        _ -> nil
      end

    %{
      etag: etag(resp),
      size: size,
      content_type: header(resp, "content-type"),
      last_modified: header(resp, "last-modified"),
      sha256: sha256
    }
  end

  defp hex(raw), do: Base.encode16(raw, case: :lower)
end
