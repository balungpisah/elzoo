# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Artifact.Record do
  @moduledoc """
  `state/artifact` record kinds, self-contained JSON payloads
  (schema_version 1, Jason 1.4.5 as the ready `integration/json` recipe
  prescribes) and the fold of an artifact stream's rows into per-version
  records and a committed head.

  Every `artifact_staged`, `artifact_committed` and `artifact_deleted` row
  carries the *full* version record plus its resulting `state`/`state_at`, so
  any single surviving row rebuilds its version whole. Store prefix
  retention therefore preserves every version that keeps at least one row;
  the fold is trusted only when the surviving versions are contiguous
  `1..max_version` (a fully retained version leaves a detectable gap) and no
  artifact row is unreadable — anything else is recorded `damage` and the
  caller fails closed. An artifact stream is `artifact/<tenant>/<artifact_id>`;
  the tenant index is `artifact-index/<tenant>` of `artifact_index` records
  (best-effort, duplicates deduplicated at read).
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

  @doc """
  The self-contained payload of one version row: every field of the version
  record plus its resulting `state` and `state_at`. `artifact_staged` rows
  carry `state: :staging` (`state_at == created_at`); `artifact_committed`
  and `artifact_deleted` rows carry the same record with the transitioned
  state, so the row alone determines the version's full state.
  """
  def payload(r),
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
        "state_at" => r.state_at,
        "access_expires_at" => stamp_or_null(r.access_expires_at),
        "retain_until" => stamp_or_null(r.retain_until),
        "metadata" => r.metadata,
        "upload" => Atom.to_string(r.upload),
        "state" => Atom.to_string(r.state)
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
  # `%{versions: %{version => record}, head: record | nil, damage: [diag],
  # max_version: n}`. Every artifact row is self-contained: it seeds its
  # version when unseen and otherwise must agree on every immutable field
  # and follow a legal state edge (the same edges the Cure `step/2` table
  # admits for writes). Any validation, JSON, version, field, consistency or
  # transition failure on an artifact row is a recorded `damage` diagnostic
  # (fail closed, never silently skipped); rows of other kinds (a consumer's
  # own records, including `artifact_index` rows) are ignored.

  def fold(rows, fold_spec) do
    Enum.reduce(rows, %{versions: %{}, damage: []}, &row(&1, &2, fold_spec))
    |> finish()
  end

  defp row(row, acc, fold_spec) do
    case event(row, fold_spec) do
      {:record, rec} ->
        apply_record(acc, rec)

      :foreign ->
        acc

      :unreadable ->
        damage(acc, {:unreadable, Map.get(row, :sequence)})
    end
  end

  # Fields that must be identical on every row of one version; only `state`
  # and `state_at` may change between rows (the transitions the write path
  # performs). `version` is the map key and `artifact_id`/`tenant` are
  # stream-invariant, but they are compared anyway — a disagreement is
  # corruption, not a new fact.
  @immutable [
    :artifact_id,
    :version,
    :tenant,
    :sha256,
    :hash_format,
    :object_sha256,
    :size_bytes,
    :media_type,
    :object_key,
    :access,
    :created_at,
    :access_expires_at,
    :retain_until,
    :metadata,
    :upload
  ]

  defp apply_record(acc, rec) do
    case Map.fetch(acc.versions, rec.version) do
      :error ->
        # Any state may seed a version: under prefix retention the staged
        # row can be gone while a later committed/deleted row survives.
        %{acc | versions: Map.put(acc.versions, rec.version, rec)}

      {:ok, old} ->
        cond do
          Map.take(old, @immutable) != Map.take(rec, @immutable) ->
            damage(acc, {:inconsistent_version, rec.version})

          legal_transition?(old.state, rec.state) ->
            %{acc | versions: Map.put(acc.versions, rec.version, rec)}

          true ->
            damage(acc, {:illegal_transition, rec.version})
        end
    end
  end

  # The read-side mirror of the write-path edges `Cure.Elzoo.Artifact.step/2`
  # admits: staging→committed (EvCommit), staging→deleted (EvAbort/EvReap),
  # committed→committed (idempotent EvCommit), committed→deleted
  # (EvDelete/EvReap). Deleted is terminal; nothing returns to staging.
  defp legal_transition?(:staging, :committed), do: true
  defp legal_transition?(:staging, :deleted), do: true
  defp legal_transition?(:committed, :committed), do: true
  defp legal_transition?(:committed, :deleted), do: true
  defp legal_transition?(_, _), do: false

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

  @doc """
  Whether a fold provably covers every version the stream ever recorded:
  the surviving version numbers are exactly `1..max_version` (versions are
  allocated contiguously and a fully retained or fully unreadable version
  leaves a detectable gap) and an empty fold is trusted only when no prefix
  was retained (`low_water == 0`). Anything else means persisted state was
  truncated and the caller must fail closed.
  """
  def complete?(%{versions: versions, max_version: max}, low_water) do
    contiguous =
      versions |> Map.keys() |> Enum.sort() == Enum.to_list(1..max//1)

    contiguous and (map_size(versions) > 0 or low_water == 0)
  end

  @doc "Decode an artifact row into `{:record, record}`, `:foreign` or `:unreadable`. Rows of kinds this Piece does not own (including `artifact_index` rows, which live on their own stream) are `:foreign` (skipped, never damage)."
  def event(row, fold_spec) do
    if is_map(row) and Map.get(row, :kind) not in kind_names() do
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

  @kind_state %{@staged => "staging", @committed => "committed", @deleted => "deleted"}

  defp decode(kind, data) do
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
           "state_at" => sat,
           "metadata" => meta,
           "upload" => upload,
           "state" => state
         } <- data,
         true <-
           segment?(id) and is_integer(ver) and ver >= 1 and segment?(tenant) and
             hex?(sha) and is_integer(fmt) and fmt in 1..255 and hex?(osha) and
             is_integer(size) and size >= 0 and media?(media) and is_binary(key) and
             stamp?(at) and stamp?(sat) and upload in ["committed", "uncertain"] and
             state == Map.fetch!(@kind_state, kind) and
             expiry?(data["access_expires_at"]) and expiry?(data["retain_until"]) and
             key == object_key(tenant, id, ver, sha),
         {:ok, access_terms} <- decode_access(access, tenant) do
      {:record,
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
         state_at: sat,
         access_expires_at: expiry(data["access_expires_at"]),
         retain_until: expiry(data["retain_until"]),
         metadata: meta,
         upload: String.to_atom(upload),
         state: String.to_atom(state)
       }}
    else
      _ -> :unreadable
    end
  end

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

  @doc "Decode an `artifact_index` row into `{:index, artifact_id, at}`, `:foreign` (a row of another kind) or `:unreadable` (a corrupt index row)."
  def index_event(row, fold_spec) do
    cond do
      not (is_map(row) and Map.get(row, :kind) == @index_kind) ->
        :foreign

      true ->
        with :ok <- Log.validate_row(row, fold_spec, Map.get(fold_spec, :limits, %{})),
             true <- row.schema_version == @version,
             {:ok, %{"v" => @version, "artifact_id" => id, "at" => at}} <- Jason.decode(row.payload),
             true <- segment?(id) and stamp?(at) do
          {:index, id, at}
        else
          _ -> :unreadable
        end
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
