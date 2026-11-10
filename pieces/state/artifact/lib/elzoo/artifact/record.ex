# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Artifact.Record do
  @moduledoc """
  `state/artifact` record kinds, self-contained JSON payloads
  (schema_version 1, Jason 1.4.5 as the ready `integration/json` recipe
  prescribes) and the fold of an artifact stream's rows into per-version
  records and a committed head.

  Each `artifact_staged` record carries every field of its version record;
  `artifact_committed` and `artifact_deleted` only move the version's state.
  An artifact stream is `artifact/<tenant>/<artifact_id>`; the tenant index
  is `artifact-index/<tenant>` of `artifact_index` records (best-effort,
  duplicates deduplicated at read).
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Codec

  @version 1
  @staged "artifact_staged"
  @committed "artifact_committed"
  @deleted "artifact_deleted"
  @index_kind "artifact_index"
  @states [:staging, :committed, :deleted]
  @max_segment 64
  @max_media 256
  @max_stamp 9_223_372_036_854_775_807
  @segment ~r/\A[A-Za-z0-9._-]+\z/

  def version, do: @version

  @doc "Artifact kinds for the consumer's fold: all `:non_state_bearing`."
  def kinds,
    do: %{
      @staged => :non_state_bearing,
      @committed => :non_state_bearing,
      @deleted => :non_state_bearing,
      @index_kind => :non_state_bearing
    }

  def kind_names, do: [@staged, @committed, @deleted]
  def staged, do: @staged
  def committed, do: @committed
  def deleted, do: @deleted
  def index_kind, do: @index_kind
  def max_segment, do: @max_segment
  def states, do: @states

  @doc """
  A safe object-key and stream-name segment: UTF-8 alphanumerics plus `-_.`,
  1..#{@max_segment} bytes, never `.` or `..`. Validated before any key or
  stream construction; an unsafe value is `{:error, :invalid}` at the API.
  """
  def segment?(s),
    do:
      is_binary(s) and String.valid?(s) and byte_size(s) in 1..@max_segment and
        String.match?(s, @segment) and s not in [".", ".."]

  def stream(tenant, artifact_id), do: "artifact/" <> tenant <> "/" <> artifact_id
  def index_stream(tenant), do: "artifact-index/" <> tenant

  def object_key(tenant, artifact_id, version, sha256_hex),
    do: "artifacts/#{tenant}/#{artifact_id}/v#{version}/#{sha256_hex}"

  def stamp?(n), do: is_integer(n) and n >= 0 and n <= @max_stamp
  def media?(m), do: Codec.text?(m) and byte_size(m) in 1..@max_media

  @doc "SHA-256 over the versioned canonical preimage `<<hash_format::8, bytes>>`; hex output."
  def content_hash(hash_format, bytes) when is_integer(hash_format) and hash_format in 1..255,
    do: Base.encode16(:crypto.hash(:sha256, <<hash_format::8, bytes::binary>>), case: :lower)

  def content_hash(_, _), do: nil

  # ── payloads ─────────────────────────────────────────────────────────

  def staged_payload(r),
    do:
      Jason.encode!(%{
        "v" => @version,
        "artifact_id" => r.artifact_id,
        "version" => r.version,
        "tenant" => r.tenant,
        "sha256" => r.sha256,
        "hash_format" => r.hash_format,
        "object_sha256" => r.object_sha256,
        "size_bytes" => r.size_bytes,
        "media_type" => r.media_type,
        "object_key" => r.object_key,
        "access" => encode_access(r.access),
        "created_at" => r.created_at,
        "access_expires_at" => stamp_or_null(r.access_expires_at),
        "retain_until" => stamp_or_null(r.retain_until),
        "metadata" => r.metadata,
        "upload" => Atom.to_string(r.upload)
      })

  def marker_payload(kind, artifact_id, version, at) when kind in [@committed, @deleted],
    do:
      Jason.encode!(%{
        "v" => @version,
        "artifact_id" => artifact_id,
        "version" => version,
        "at" => at
      })

  def index_payload(artifact_id, at),
    do: Jason.encode!(%{"v" => @version, "artifact_id" => artifact_id, "at" => at})

  defp encode_access(%{tenant: t, principals: p, scopes: s}),
    do: %{
      "tenant" => t,
      "principals" => rule(p),
      "scopes" => rule(s)
    }

  defp rule(:any), do: "any"
  defp rule(list) when is_list(list), do: list
  defp stamp_or_null(:never), do: nil
  defp stamp_or_null(n), do: n

  # ── fold of an artifact stream ───────────────────────────────────────
  #
  # `fold/2` reduces the visible rows of one artifact stream into
  # `%{versions: %{version => record}, head: record | nil, damage: [diag]}`.
  # A `staged` row seeds the version's record; later markers move its state.
  # Any validation, JSON, version or field failure on an artifact row is a
  # recorded `damage` diagnostic (fail closed, never silently skipped); rows
  # of other kinds (a consumer's own records) are ignored.

  def fold(rows, fold_spec) do
    Enum.reduce(rows, %{versions: %{}, order: [], damage: []}, &row(&1, &2, fold_spec))
    |> finish()
  end

  defp row(row, acc, fold_spec) do
    case event(row, fold_spec) do
      {:staged, rec} ->
        if Map.has_key?(acc.versions, rec.version),
          do: damage(acc, {:duplicate_staged, rec.version}),
          else:
            Map.merge(acc, %{
              versions: Map.put(acc.versions, rec.version, rec),
              order: acc.order ++ [rec.version]
            })

      {:marker, state, version, at} ->
        case Map.fetch(acc.versions, version) do
          {:ok, rec} ->
            %{acc | versions: Map.put(acc.versions, version, %{rec | state: state, state_at: at})}

          :error ->
            damage(acc, {:orphan_marker, version})
        end

      :foreign ->
        acc

      :unreadable ->
        damage(acc, {:unreadable, Map.get(row, :sequence)})
    end
  end

  defp finish(acc) do
    versions = acc.versions

    head =
      versions
      |> Enum.filter(fn {_, r} -> r.state == :committed end)
      |> Enum.map(fn {_, r} -> r end)
      |> Enum.max_by(& &1.version, fn -> nil end)

    %{
      versions: versions,
      head: head,
      damage: acc.damage,
      max_version: versions |> Map.keys() |> Enum.max(fn -> 0 end)
    }
  end

  defp damage(acc, diag), do: %{acc | damage: [diag | acc.damage]}

  @doc "Decode an artifact row into `{:staged, record}`, `{:marker, state, version, at}`, `{:index, id, at}`, `:foreign` or `:unreadable`. Rows of kinds this Piece does not own are `:foreign` (skipped, never damage)."
  def event(row, fold_spec) do
    if is_map(row) and Map.get(row, :kind) not in (kind_names() ++ [@index_kind]) do
      :foreign
    else
      with :ok <- Log.validate_row(row, fold_spec, Map.get(fold_spec, :limits, %{})),
           true <- row.schema_version == @version,
           {:ok, %{"v" => @version} = data} <- Jason.decode(row.payload) do
        decode(row.kind, data)
      else
        _ -> :unreadable
      end
    end
  rescue
    _ -> :unreadable
  end

  defp decode(@staged, data) do
    with %{
           "artifact_id" => id,
           "version" => ver,
           "tenant" => tenant,
           "sha256" => sha,
           "hash_format" => fmt,
           "object_sha256" => osha,
           "size_bytes" => size,
           "media_type" => media,
           "object_key" => key,
           "access" => access,
           "created_at" => at,
           "metadata" => meta,
           "upload" => upload
         } <- data,
         true <-
           segment?(id) and is_integer(ver) and ver >= 1 and segment?(tenant) and
             hex?(sha) and is_integer(fmt) and fmt in 1..255 and hex?(osha) and
             is_integer(size) and size >= 0 and media?(media) and is_binary(key) and
             stamp?(at) and upload in ["committed", "uncertain"] and
             expiry?(data["access_expires_at"]) and expiry?(data["retain_until"]) and
             key == object_key(tenant, id, ver, sha),
         {:ok, access_terms} <- decode_access(access, tenant) do
      {:staged,
       %{
         artifact_id: id,
         version: ver,
         tenant: tenant,
         sha256: sha,
         hash_format: fmt,
         object_sha256: osha,
         size_bytes: size,
         media_type: media,
         object_key: key,
         access: access_terms,
         created_at: at,
         state_at: at,
         access_expires_at: expiry(data["access_expires_at"]),
         retain_until: expiry(data["retain_until"]),
         metadata: meta,
         upload: String.to_atom(upload),
         state: :staging
       }}
    else
      _ -> :unreadable
    end
  end

  defp decode(kind, %{"artifact_id" => _id, "version" => ver, "at" => at})
       when kind in [@committed, @deleted] do
    if is_integer(ver) and ver >= 1 and stamp?(at),
      do: {:marker, if(kind == @committed, do: :committed, else: :deleted), ver, at},
      else: :unreadable
  end

  defp decode(@index_kind, %{"artifact_id" => id, "at" => at}) do
    if segment?(id) and stamp?(at), do: {:index, id, at}, else: :unreadable
  end

  defp decode(_, _), do: :unreadable

  defp hex?(s), do: is_binary(s) and byte_size(s) == 64 and String.match?(s, ~r/\A[0-9a-f]+\z/)
  defp expiry?(nil), do: true
  defp expiry?(n), do: stamp?(n)
  defp expiry(nil), do: :never
  defp expiry(n), do: n

  defp decode_access(%{"tenant" => t, "principals" => p, "scopes" => s}, tenant) do
    cond do
      t != tenant -> :error
      not rule?(p) -> :error
      not rule?(s) -> :error
      true -> {:ok, %{tenant: t, principals: access_rule(p), scopes: access_rule(s)}}
    end
  end

  defp decode_access(_, _), do: :error

  defp rule?("any"), do: true
  defp rule?(l) when is_list(l), do: Enum.all?(l, &Codec.text?/1)
  defp rule?(_), do: false

  defp access_rule("any"), do: :any
  defp access_rule(l), do: l

  @doc "Decode an `artifact_index` row into `{:index, artifact_id, at}` or `:unreadable`."
  def index_event(row, fold_spec) do
    with :ok <- Log.validate_row(row, fold_spec, Map.get(fold_spec, :limits, %{})),
         true <- row.kind == @index_kind and row.schema_version == @version,
         {:ok, %{"v" => @version, "artifact_id" => id, "at" => at}} <- Jason.decode(row.payload),
         true <- segment?(id) and stamp?(at) do
      {:index, id, at}
    else
      _ -> :unreadable
    end
  rescue
    _ -> :unreadable
  end

  @doc """
  Build the Store records of one batch at `expected` revision from
  `{kind, payload}` specs (schema_version 1) sharing one fresh nonce — the
  same shape `Elzoo.Lease.Record.records/4` produces. Returns
  `{:ok, rows, request}` or `{:error, {:rejected, reason}}` when the ready
  Store's static validation refuses them.
  """
  def rows(stream_name, expected, specs, fold_spec, limits) do
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      specs
      |> Enum.with_index(expected + 1)
      |> Enum.map(fn {{kind, ver, payload}, sequence} ->
        row = %Log.Record{
          stream: stream_name,
          sequence: sequence,
          kind: kind,
          schema_version: ver,
          payload: payload,
          nonce: nonce
        }

        %{row | digest: Log.digest(row)}
      end)

    tuples = Enum.map(specs, fn {kind, ver, payload} -> {kind, ver, payload} end)

    with :ok <-
           Log.preflight(
             %{stream: stream_name, expected: expected, records: tuples, outbox: []},
             fold_spec,
             limits
           ),
         true <- Enum.all?(rows, &(Log.validate_row(&1, fold_spec, limits) == :ok)) do
      request = %{
        operation: :append,
        stream: stream_name,
        expected: expected,
        target: expected + length(rows),
        nonce: nonce,
        digest: Codec.hash(Enum.map(rows, &Log.canonical_bytes/1)),
        records: rows
      }

      {:ok, rows, request}
    else
      {:rejected, reason} -> {:error, {:rejected, reason}}
      false -> {:error, {:rejected, :record_too_large}}
    end
  end
end
