# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStore do
  @moduledoc """
  S3-only object-store Adapter (`integration/object-store`, ELZ-053) on `req_s3` 0.2.5 and the
  pinned Req. One `Elzoo.ObjectStore.Config` binds one endpoint and one bucket under a
  backing-store identity. Each call performs one operation and returns one result of the finite
  table in `Elzoo.ObjectStore.Result`; nothing is retried by the Adapter.

  Local checks (key, body, bounds, arguments, deadline) are decided in the caller before any
  connection is opened. The request itself runs in a monitored process that the caller kills at
  the deadline; a deadline reached after dispatch is `unknown{deadline}`, never `absent` or
  `committed`. `presign/3` performs no I/O.
  """

  alias Elzoo.ObjectStore.{Config, Presigned, Request, Result}

  @max_key 1024

  defdelegate new(opts), to: Config
  defdelegate to_delivery_result(result, request), to: Result

  @doc """
  Store `body` at `key`. `body` is a binary or `{:stream, enumerable, length}` (an enumerable of
  binaries with the exact declared byte length). Options: `content_sha256` (32 raw bytes;
  required for a stream, checked against a binary before dispatch), `content_type` (default
  `application/octet-stream`), `if_absent` (`If-None-Match: *`), the deadline options and
  `declaration`. `committed` only when the provider echoes the SHA-256 that was sent.
  """
  def put(%Config{} = c, key, body, opts \\ []) do
    base = Result.base(c, :put, %{key: key})

    with :ok <- check_key(key, base),
         :ok <- check_declaration(opts, :put, base),
         {:ok, deadline} <- deadline(c, opts, base),
         {:ok, content_type} <- content_type(opts, base),
         {:ok, if_absent} <- if_absent(opts, base),
         {:ok, body, sha} <- check_body(c, body, opts, base) do
      execute(
        c,
        {:put, key, body, %{sha256: sha, content_type: content_type, if_absent: if_absent}},
        base,
        deadline
      )
    end
  end

  @doc "Read the object at `key` into memory, bounded by `max_object_bytes`."
  def get(%Config{} = c, key, opts \\ []) do
    base = Result.base(c, :get, %{key: key})

    with :ok <- check_key(key, base),
         :ok <- check_declaration(opts, :get, base),
         {:ok, deadline} <- deadline(c, opts, base) do
      execute(c, {:get, key, c.max_object_bytes}, base, deadline)
    end
  end

  @doc "Read the metadata of the object at `key`."
  def head(%Config{} = c, key, opts \\ []) do
    base = Result.base(c, :head, %{key: key})

    with :ok <- check_key(key, base),
         :ok <- check_declaration(opts, :head, base),
         {:ok, deadline} <- deadline(c, opts, base) do
      execute(c, {:head, key}, base, deadline)
    end
  end

  @doc """
  One bounded page of keys under `prefix` (required; `""` allowed). Options: `page_size`
  (1..`max_page_size`, default `default_page_size`), `continuation` (the previous page's token).
  """
  def list(%Config{} = c, prefix, opts \\ []) do
    base = Result.base(c, :list, %{prefix: prefix})
    page_size = Keyword.get(opts, :page_size, c.default_page_size)
    continuation = Keyword.get(opts, :continuation)

    cond do
      not prefix?(prefix) ->
        Result.refused(base, :invalid_request, :local)

      check_declaration(opts, :list, base) != :ok ->
        check_declaration(opts, :list, base)

      not (is_integer(page_size) and page_size >= 1 and page_size <= c.max_page_size) ->
        Result.refused(base, :invalid_request, :local)

      not (is_nil(continuation) or token?(continuation)) ->
        Result.refused(base, :invalid_request, :local)

      true ->
        with {:ok, deadline} <- deadline(c, opts, base) do
          execute(c, {:list, prefix, page_size, continuation}, base, deadline)
        end
    end
  end

  @doc """
  Delete the object at `key`. `committed` on the provider's 204, which acknowledges the delete
  request, not that an object existed or that absence persists.
  """
  def delete(%Config{} = c, key, opts \\ []) do
    base = Result.base(c, :delete, %{key: key})

    with :ok <- check_key(key, base),
         :ok <- check_declaration(opts, :delete, base),
         {:ok, deadline} <- deadline(c, opts, base) do
      execute(c, {:delete, key}, base, deadline)
    end
  end

  @doc """
  Explicit reconciliation after an `unknown` put: a `head` whose stored SHA-256 is compared
  with `intended_sha256` (32 raw bytes). Returns the head's refused/unknown result unchanged, or
  `%{status: :reconciled, observation: :match | :mismatch | :absent, head: head_result}`.
  `:absent` is an observation at that moment, never proof that the write had no effect.
  """
  def reconcile_put(%Config{} = c, key, intended_sha256, opts \\ []) do
    base = Result.base(c, :reconcile, %{key: key})

    if is_binary(intended_sha256) and byte_size(intended_sha256) == 32 do
      case head(c, key, opts) do
        %{status: :absent} = h ->
          Map.merge(base, %{status: :reconciled, observation: :absent, head: h})

        %{status: :found, metadata: m} = h ->
          obs = if m.sha256 == hex(intended_sha256), do: :match, else: :mismatch
          Map.merge(base, %{status: :reconciled, observation: obs, head: h})

        other ->
          other
      end
    else
      Result.refused(base, :invalid_request, :local)
    end
  end

  @doc """
  A presigned URL for `key` (no I/O). Options: `method` (`:get` default, or `:put`),
  `expires_s` (1..`presign_max_s`, default `presign_default_s`), `now` (a `DateTime`, default
  the current UTC time). Returns `{:ok, %Elzoo.ObjectStore.Presigned{}}` or a refused result.
  """
  def presign(%Config{} = c, key, opts \\ []) do
    base = Result.base(c, :presign, %{key: key})
    method = Keyword.get(opts, :method, :get)
    expires = Keyword.get(opts, :expires_s, c.presign_default_s)
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)

    cond do
      check_key(key, base) != :ok ->
        check_key(key, base)

      check_declaration(opts, :presign, base) != :ok ->
        check_declaration(opts, :presign, base)

      method not in [:get, :put] or not (is_integer(expires) and expires in 1..c.presign_max_s) ->
        Result.refused(base, :invalid_request, :local)

      true ->
        case Config.resolve_credentials(c) do
          {:ok, ak, sk} ->
            presigned(c, key, method, expires, now, ak, sk, base)

          :error ->
            Result.refused(base, :credentials_unavailable, :local)
        end
    end
  end

  defp presigned(c, key, method, expires, now, ak, sk, base) do
    url =
      ReqS3.presign_url(
        access_key_id: ak,
        secret_access_key: sk,
        region: c.region,
        endpoint_url: c.endpoint,
        bucket: c.bucket,
        key: Request.encode_key(key),
        method: method,
        expires: expires,
        datetime: now
      )

    {:ok,
     %Presigned{
       url: url,
       method: method,
       expires_at: DateTime.add(now, expires, :second),
       store: c.store_id,
       bucket: c.bucket,
       key: key
     }}
  rescue
    _ -> Result.unknown(base, :adapter_error)
  end

  # ---- execution

  defp execute(c, op, base, deadline_ms) do
    parent = self()
    tag = make_ref()

    {pid, mref} =
      spawn_monitor(fn -> send(parent, {tag, Request.run(c, op, base, deadline_ms)}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        receive do
          {^tag, result} -> result
        after
          0 -> Result.unknown(base, :adapter_error)
        end
    after
      deadline_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mref, :process, ^pid, _} -> :ok
        end

        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        Result.unknown(base, :deadline)
    end
  end

  # ---- local checks (before any connection)

  @doc false
  def key?(key),
    do:
      is_binary(key) and byte_size(key) in 1..@max_key and String.valid?(key) and
        not String.match?(key, ~r/[\x00-\x1f\x7f]/u) and
        Enum.all?(String.split(key, "/"), &(&1 not in ["", ".", ".."]))

  defp check_key(key, base) do
    if key?(key), do: :ok, else: Result.refused(base, :invalid_key, :local)
  end

  defp prefix?(p),
    do:
      is_binary(p) and byte_size(p) <= @max_key and String.valid?(p) and
        not String.match?(p, ~r/[\x00-\x1f\x7f]/u)

  defp token?(t),
    do: is_binary(t) and byte_size(t) in 1..1024 and String.match?(t, ~r/\A[\x21-\x7e]+\z/)

  defp deadline(c, opts, base) do
    ms =
      case {Keyword.get(opts, :deadline_ms), Keyword.get(opts, :deadline_unix_ms)} do
        {nil, nil} ->
          c.default_deadline_ms

        {ms, nil} ->
          ms

        {nil, at} when is_integer(at) ->
          now = Keyword.get(opts, :now_unix_ms, fn -> System.os_time(:millisecond) end).()
          at - now

        _ ->
          :invalid
      end

    if is_integer(ms) and ms >= 1 and ms <= Config.timer_max(),
      do: {:ok, ms},
      else: Result.refused(base, :invalid_request, :local)
  end

  defp content_type(opts, base) do
    ct = Keyword.get(opts, :content_type, "application/octet-stream")

    if Config.text?(ct, 256), do: {:ok, ct}, else: Result.refused(base, :invalid_request, :local)
  end

  # Only a boolean enables or disables the conditional write; anything else is refused before
  # dispatch, so a mistaken value never turns into an unconditional overwrite.
  defp if_absent(opts, base) do
    case Keyword.get(opts, :if_absent, false) do
      v when is_boolean(v) -> {:ok, v}
      _ -> Result.refused(base, :invalid_request, :local)
    end
  end

  defp check_body(c, body, opts, base) do
    sha = Keyword.get(opts, :content_sha256)
    sha_ok = is_nil(sha) or (is_binary(sha) and byte_size(sha) == 32)

    case body do
      _ when not sha_ok ->
        Result.refused(base, :invalid_request, :local)

      bin when is_binary(bin) and byte_size(bin) > c.max_object_bytes ->
        Result.refused(base, :too_large, :local)

      bin when is_binary(bin) ->
        actual = :crypto.hash(:sha256, bin)

        if is_nil(sha) or sha == actual,
          do: {:ok, {:binary, bin}, actual},
          else: Result.refused(base, :checksum_mismatch, :local)

      {:stream, _enum, length} when is_integer(length) and length > c.max_object_bytes ->
        Result.refused(base, :too_large, :local)

      {:stream, enum, length} when is_integer(length) and length >= 0 and is_binary(sha) ->
        if Enumerable.impl_for(enum),
          do: {:ok, {:stream, enum, length}, sha},
          else: Result.refused(base, :invalid_request, :local)

      _ ->
        Result.refused(base, :invalid_request, :local)
    end
  end

  # An ELZ-011 Effect declaration, when given, must validate, name this capability and the
  # called operation; otherwise nothing is dispatched.
  defp check_declaration(opts, operation, base) do
    case Keyword.fetch(opts, :declaration) do
      :error ->
        :ok

      {:ok, decl} ->
        case Elzoo.Effect.validate(decl) do
          {:ok, %{"capability_id" => "integration/object-store", "operation" => op}} ->
            if op == Atom.to_string(operation),
              do: :ok,
              else: Result.refused(base, :invalid_request, :local)

          _ ->
            Result.refused(base, :invalid_request, :local)
        end
    end
  end

  defp hex(raw), do: Base.encode16(raw, case: :lower)
end
