# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Artifact do
  @moduledoc """
  `state/artifact` (ELZ-096): tenant-owned, versioned artifact *references*
  in the ready Store whose bytes live in the ready `integration/object-store`
  Piece. The Piece owns identity, versioning, integrity verification,
  recorded access terms, expiry and retention; byte transport belongs to
  `Elzoo.ObjectStore`, policy evaluation to the consumer.

  Persistence layout (builder choice per the Contract): one Store stream
  `artifact/<tenant>/<artifact_id>` of self-contained version records under
  head-revision CAS, plus a best-effort tenant index stream
  `artifact-index/<tenant>` — there is no cross-stream transaction, so index
  consistency with commits is best-effort and documented. Object writes are
  content-addressed (`artifacts/<tenant>/<id>/v<version>/<sha256>`); an
  `unknown` put is reconciled by `head`/`reconcile_put` verification, never
  blind re-put.

  Every operation presents `caller = %{tenant, principal, scopes}` — a
  consumer-vouched identity (attribution, not authentication). Read paths
  enforce the recorded access terms and `access_expires_at`; mutating
  operations require `caller.tenant` to equal the record tenant, which is
  structural (the stream is tenant-scoped). Cross-tenant `artifact_id`
  lookup reads a different stream and returns `:not_found`.

  ## Results

  `{:ok, value}` or `{:error, reason}` with
  `reason ∈ :not_found | :access_denied | :expired | :deleted | :too_large |
  :invalid | {:invalid, field} | {:integrity_mismatch, info} |
  {:commit_failed, info} | :staging_expired | :store_unavailable |
  :caller_transaction | {:object_store_refused, reason} |
  {:object_store_absent} | {:object_store_unknown, reason}`.

  `{:commit_failed, %{expected, observed}}` is the Store CAS conflict (the
  losing commit changes nothing); `{:commit_failed, :indeterminate}` is the
  Store's unknown outcome — the write may have committed; `status/2` (or the
  ready Store's `confirm/5` by nonce) reveals the truth on the next call.
  """

  alias Elzoo.Artifact.{Record, Telemetry}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}
  alias Elzoo.ObjectStore.Config

  @cure :"Cure.Elzoo.Artifact"
  @page 1_000
  @put_retries 2
  @max_list 100

  defstruct [
    :store,
    :object_store,
    :clock,
    :fold,
    :limits,
    :max_bytes,
    :max_metadata_bytes,
    :staging_ttl_ms,
    :hash_format,
    :object_opts
  ]

  @doc "Artifact kinds to merge into the consumer's fold (all `:non_state_bearing`)."
  def kinds, do: Record.kinds()

  @doc """
  Build the Piece. Options:

  - `store` — a ready Store term `{module, opts}`; its `opts.fold` and
    `opts.limits` are the source of truth (`fold.kinds` must contain
    `kinds/0`, `1` must be in `fold.versions`, `limits.max_record_bytes >=
    4_096`, `max_batch_size >= 1`). The PostgreSQL Store for durability, the
    Memory double for tests.
  - `object_store` — an `%Elzoo.ObjectStore.Config{}` binding (its credential
    Need resolves per call inside object-store; this Piece stores no
    credential material).
  - `clock` — a zero-arity function returning unix milliseconds (default
    `System.os_time(:millisecond)`), or `{:manual, pid}` accepting
    `GenServer.call(pid, :now)`.
  - `max_bytes` — staged byte bound, `1..min(object_store.max_object_bytes)`
    (default `min(16 MiB, max_object_bytes)`).
  - `max_metadata_bytes` — encoded-metadata bound, `1..65_536` (default
    `4_096`).
  - `staging_ttl_ms` — staging record lifetime; a commit later than
    `staged_at + staging_ttl_ms` is `:staging_expired` (default
    `3_600_000`).
  - `hash_format` — the declared content-hash format stamped on new records,
    positive `1..255` (default `1`; a format change is a declared migration,
    never silent reinterpretation).
  - `object_opts` — keyword options forwarded to every `Elzoo.ObjectStore`
    call (for example `deadline_ms`); empty by default.

  No environment reads; no root Application.
  """
  def new(opts) do
    store = Keyword.get(opts, :store)
    object_store = Keyword.get(opts, :object_store)
    clock = clock_fun(Keyword.get(opts, :clock))

    store_opts =
      case store do
        {m, o} when is_atom(m) and (is_map(o) or is_list(o)) -> Map.new(o)
        _ -> %{}
      end

    fold = Map.get(store_opts, :fold)
    limits = Map.get(store_opts, :limits)
    max_bytes = Keyword.get(opts, :max_bytes)
    max_meta = Keyword.get(opts, :max_metadata_bytes, 4_096)
    ttl = Keyword.get(opts, :staging_ttl_ms, 3_600_000)
    fmt = Keyword.get(opts, :hash_format, 1)
    object_opts = Keyword.get(opts, :object_opts, [])

    cond do
      not match?({module, _} when is_atom(module), store) ->
        {:error, {:invalid, :store}}

      not match?(%Config{}, object_store) ->
        {:error, {:invalid, :object_store}}

      clock == :error ->
        {:error, {:invalid, :clock}}

      not (Codec.fold_valid?(fold) and
               Map.take(fold.kinds, Map.keys(Record.kinds())) == Record.kinds() and
               Record.version() in fold.versions) ->
        {:error, {:invalid, :fold}}

      not (is_map(limits) and is_integer(Map.get(limits, :max_record_bytes)) and
             limits.max_record_bytes >= 4_096 and
             is_integer(Map.get(limits, :max_batch_size)) and limits.max_batch_size >= 1) ->
        {:error, {:invalid, :limits}}

      not (is_nil(max_bytes) or (is_integer(max_bytes) and max_bytes >= 1)) ->
        {:error, {:invalid, :max_bytes}}

      not (is_integer(max_meta) and max_meta in 1..65_536) ->
        {:error, {:invalid, :max_metadata_bytes}}

      not (is_integer(ttl) and ttl >= 1) ->
        {:error, {:invalid, :staging_ttl_ms}}

      not (is_integer(fmt) and fmt in 1..255) ->
        {:error, {:invalid, :hash_format}}

      not is_list(object_opts) ->
        {:error, {:invalid, :object_opts}}

      true ->
        bound = if max_bytes, do: max_bytes, else: min(16_777_216, object_store.max_object_bytes)

        if bound > object_store.max_object_bytes do
          {:error, {:invalid, :max_bytes}}
        else
          {:ok,
           %__MODULE__{
             store: store,
             object_store: object_store,
             clock: clock,
             fold: fold,
             limits: limits,
             max_bytes: bound,
             max_metadata_bytes: max_meta,
             staging_ttl_ms: ttl,
             hash_format: fmt,
             object_opts: object_opts
           }}
        end
    end
  end

  defp clock_fun(nil), do: fn -> System.os_time(:millisecond) end
  defp clock_fun(f) when is_function(f, 0), do: f
  defp clock_fun({:manual, pid}) when is_pid(pid), do: fn -> GenServer.call(pid, :now) end
  defp clock_fun(_), do: :error

  # ── stage / commit / abort / put / new_version ───────────────────────

  @doc """
  `stage/3` of the Contract: `stage(art, caller, artifact_id, input)`.
  Validates bounds and segments, hashes the bytes under the declared
  `hash_format`, `ObjectStore.put`s the content-addressed key, then commits
  the staging record through the Store CAS. A `refused` put is a typed
  failure with no record; an `unknown` put persists the staging record with
  `upload: :uncertain` — resolved by `commit`/`status` verification, never
  blind re-put. `input` keys: `bytes`, `media_type` (default
  `application/octet-stream`), `access` (default
  `%{tenant: caller.tenant, principals: :any, scopes: :any}`; a supplied
  `access.tenant` must equal `caller.tenant`), `metadata` (JSON-encodable,
  ≤ `max_metadata_bytes` encoded), `access_expires_at` and `retain_until`
  (`:never` or a unix-ms stamp; both default `:never` and must be declared
  explicitly by the caller or defaulted by the Piece — they are always
  recorded).
  """
  def stage(art, caller, artifact_id, input) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         {:ok, in_norm} <- input(input, art, caller) do
      now = art.clock.()

      case load(art, caller.tenant, artifact_id) do
        {:error, reason} ->
          {:error, reason}

        {:ok, view} ->
          version = view.folded.max_version + 1
          sha = Record.content_hash(art.hash_format, in_norm.bytes)
          osha = Base.encode16(:crypto.hash(:sha256, in_norm.bytes), case: :lower)
          key = Record.object_key(caller.tenant, artifact_id, version, sha)

          rec = %{
            artifact_id: artifact_id,
            version: version,
            tenant: caller.tenant,
            sha256: sha,
            hash_format: art.hash_format,
            object_sha256: osha,
            size_bytes: byte_size(in_norm.bytes),
            media_type: in_norm.media_type,
            object_key: key,
            access: in_norm.access,
            created_at: now,
            state_at: now,
            access_expires_at: in_norm.access_expires_at,
            retain_until: in_norm.retain_until,
            metadata: in_norm.metadata,
            upload: :committed,
            state: :staging
          }

          payload_size = byte_size(Record.staged_payload(rec))

          if payload_size > art.limits.max_record_bytes do
            {:error, :too_large}
          else
            case put_object(art, key, in_norm.bytes, rec.media_type) do
              :ok -> stage_record(art, view, rec)
              {:uncertain, _} -> stage_record(art, view, %{rec | upload: :uncertain})
              {:error, _} = failure -> failure
            end
          end
      end
    end
  end

  defp stage_record(art, view, rec) do
    case append(art, view.stream, view.head.revision, [
           {Record.staged(), Record.version(), Record.staged_payload(rec)}
         ]) do
      {:committed, _} ->
        index(art, rec.tenant, rec.artifact_id, rec.created_at)
        Telemetry.staged(rec)
        {:ok, rec}

      {:error, _} = failure ->
        failure
    end
  end

  @doc """
  `commit/3` of the Contract: `commit(art, caller, artifact_id, version)`.
  Verifies object presence and size/hash evidence through `reconcile_put`
  (the recorded transport checksum and size, never blind re-put) before the
  Store write flips `staging → committed`. Re-committing a committed version
  is idempotent (`{:ok, record}`).
  """
  def commit(art, caller, artifact_id, version) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         :ok <- check_version(version),
         {:ok, view} <- load(art, caller.tenant, artifact_id),
         {:ok, rec} <- fetch(view, artifact_id, version) do
      now = art.clock.()

      cond do
        rec.state == :committed ->
          {:ok, rec}

        rec.state == :deleted ->
          {:error, :deleted}

        rec.state_at + art.staging_ttl_ms <= now ->
          {:error, :staging_expired}

        true ->
          case verify(art, rec) do
            :ok -> commit_record(art, view, rec, now)
            {:error, _} = failure -> failure
          end
      end
    end
  end

  defp commit_record(art, view, rec, now) do
    case transition(art, view, rec, :commit, now) do
      {:ok, committed} ->
        Telemetry.committed(committed)
        {:ok, committed}

      {:error, _} = failure ->
        failure
    end
  end

  @doc """
  `abort/2` of the Contract: `abort(art, caller, %{artifact_id, version})`.
  `staging → deleted` plus a best-effort object delete whose outcome is
  reported (`:deleted`, `:refused`, `:unknown`, `:absent`), never hidden.
  """
  def abort(art, caller, %{artifact_id: artifact_id, version: version}) do
    terminate(art, caller, artifact_id, version, :abort)
  end

  def abort(_, _, _), do: {:error, :invalid}

  @doc """
  `put/4` of the Contract: `put(art, caller, artifact_id, input, opts \\ [])`.
  `stage` + `commit` convenience on the next version (`max + 1`; `v1` for a
  new artifact). A Store CAS conflict retries the whole sequence at most
  #{@put_retries} times; an indeterminate Store write is never retried —
  `status` reconciles. `opts` forwards to `Elzoo.ObjectStore.put/4`.
  """
  def put(art, caller, artifact_id, input, opts \\ []) do
    if is_list(opts),
      do: do_put(art, caller, artifact_id, input, opts, @put_retries),
      else: {:error, :invalid}
  end

  # stage+commit under one bounded conflict retry: a CAS conflict on either
  # write usually means a version race; an indeterminate write is never
  # retried (its outcome is unknown — status reconciles).
  defp do_put(art, caller, artifact_id, input, object_opts, retries) do
    art2 = %{art | object_opts: merge_opts(art.object_opts, object_opts)}

    case stage(art2, caller, artifact_id, input) do
      {:ok, rec} ->
        case commit(art2, caller, artifact_id, rec.version) do
          {:error, {:commit_failed, %{observed: _}}} when retries > 0 ->
            do_put(art, caller, artifact_id, input, object_opts, retries - 1)

          result ->
            result
        end

      {:error, {:commit_failed, %{observed: _}}} when retries > 0 ->
        do_put(art, caller, artifact_id, input, object_opts, retries - 1)

      result ->
        result
    end
  end

  defp merge_opts(base, extra), do: Keyword.merge(base || [], extra || [])

  @doc """
  `new_version/4` of the Contract: `new_version(art, caller, artifact_id,
  input, opts \\ [])` — the same as `put` on an existing `artifact_id`
  (at least one recorded version, any state), `version = max + 1`; otherwise
  `:not_found`.
  """
  def new_version(art, caller, artifact_id, input, opts \\ []) do
    with :ok <- check_caller(caller), :ok <- check_segment(:artifact_id, artifact_id) do
      case load(art, caller.tenant, artifact_id) do
        {:error, reason} -> {:error, reason}
        {:ok, view} ->
          if view.folded.max_version >= 1,
            do: put(art, caller, artifact_id, input, opts),
            else: {:error, :not_found}
      end
    end
  end

  # ── reads ────────────────────────────────────────────────────────────

  @doc """
  `head/3` of the Contract: `head(art, caller, artifact_id, opts \\ [])`.
  The artifact's head — its highest committed non-`deleted` version — with
  the recorded access terms and `access_expires_at` enforced.
  """
  def head(art, caller, artifact_id, _opts \\ []) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         {:ok, view} <- load(art, caller.tenant, artifact_id) do
      case view.folded.head do
        nil -> {:error, :not_found}
        rec -> access(rec, caller, art.clock.())
      end
    end
  end

  @doc """
  `get/3` of the Contract: `get(art, caller, artifact_id, version)` with
  `version` a positive integer or `:head`. Downloads the bytes and recomputes
  SHA-256 over `<<hash_format, bytes>>` under the record's *stored* format
  before returning them; a disagreement is
  `{:error, {:integrity_mismatch, info}}` and the bytes are never served.
  """
  def get(art, caller, artifact_id, version) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         :ok <- check_version(version),
         {:ok, view} <- load(art, caller.tenant, artifact_id),
         {:ok, rec} <- fetch(view, artifact_id, version) do
      now = art.clock.()

      cond do
        rec.state == :deleted ->
          {:error, :deleted}

        rec.state != :committed ->
          {:error, {:invalid, :state}}

        true ->
          case access(rec, caller, now) do
            {:ok, _} ->
              download(art, rec)

            {:error, _} = failure ->
              failure
          end
      end
    end
  end

  defp download(art, rec) do
    case Elzoo.ObjectStore.get(art.object_store, rec.object_key, art.object_opts) do
      %{status: :found, metadata: meta, body: body} ->
        observed = Record.content_hash(rec.hash_format, body)

        cond do
          observed == rec.sha256 and meta.size == rec.size_bytes ->
            {:ok, %{record: rec, bytes: body}}

          true ->
            Telemetry.integrity_failure(rec, :get)

            {:error,
             {:integrity_mismatch,
              %{
                artifact_id: rec.artifact_id,
                version: rec.version,
                expected: rec.sha256,
                observed: observed,
                expected_bytes: rec.size_bytes,
                observed_bytes: meta.size
              }}}
        end

      %{status: :absent} ->
        {:error, :object_store_absent}

      %{status: :refused, reason: reason} ->
        {:error, {:object_store_refused, reason}}

      %{status: :unknown, reason: reason} ->
        {:error, {:object_store_unknown, reason}}
    end
  end

  @doc """
  `list/3` of the Contract: `list(art, caller, limit, cursor)`. One bounded
  page (≤ #{@max_list}) of the caller-tenant index: `{artifact_id, head}`
  entries for committed heads the caller may access under the recorded terms
  and `access_expires_at` (denied or expired entries are omitted; staging or
  fully deleted artifacts are not listed). `cursor` is `nil` (from the
  start) or a previously returned `next_cursor`; the index is best-effort —
  its consistency with commits is documented, not guaranteed.
  """
  def list(art, caller, limit, cursor) do
    with :ok <- check_caller(caller),
         :ok <- check_list(limit, cursor) do
      case index_rows(art, caller.tenant) do
        {:error, reason} ->
          {:error, reason}

        {:ok, ids} ->
          now = art.clock.()
          offset = cursor || 0

          entries =
            ids
            |> Enum.drop(offset)
            |> Enum.take(limit)
            |> Enum.map(&list_entry(art, caller, &1, now))
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, entry} -> entry end)

          next = if offset + limit < length(ids), do: offset + limit, else: nil

          {:ok, %{entries: entries, cursor: next}}
      end
    end
  end

  defp list_entry(art, caller, artifact_id, now) do
    case load(art, caller.tenant, artifact_id) do
      {:ok, %{folded: %{head: nil}}} ->
        :skip

      {:ok, %{folded: %{head: rec}}} ->
        case access(rec, caller, now) do
          {:ok, head_rec} -> {:ok, %{artifact_id: artifact_id, head: head_rec}}
          {:error, _} -> :skip
        end

      _ ->
        :skip
    end
  end

  @doc """
  `versions/2` of the Contract: `versions(art, caller, artifact_id)`. Every
  recorded version of the artifact, sorted ascending, after enforcing the
  head record's (or the latest record's, when nothing is committed) access
  terms and `access_expires_at`.
  """
  def versions(art, caller, artifact_id) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         {:ok, view} <- load(art, caller.tenant, artifact_id) do
      case latest_for_access(view.folded) do
        nil ->
          {:error, :not_found}

        rec ->
          case access(rec, caller, art.clock.()) do
            {:ok, _} -> {:ok, view.folded.versions |> Map.values() |> Enum.sort_by(& &1.version)}
            {:error, _} = failure -> failure
          end
      end
    end
  end

  defp latest_for_access(%{head: %{state: :committed} = head}), do: head

  defp latest_for_access(%{versions: v, max_version: max}) when max >= 1,
    do: Map.get(v, max)

  defp latest_for_access(_), do: nil

  # ── delete / reap / status ───────────────────────────────────────────

  @doc """
  `delete/3` of the Contract: `delete(art, caller, artifact_id, version)`.
  `committed → deleted` under the recorded access terms and
  `access_expires_at`, plus a best-effort reported object delete. A staging
  version is `{:error, {:invalid, :state}}` — `abort` is its transition.
  """
  def delete(art, caller, artifact_id, version) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         :ok <- check_version(version),
         {:ok, view} <- load(art, caller.tenant, artifact_id),
         {:ok, rec} <- fetch(view, artifact_id, version) do
      cond do
        rec.state == :deleted ->
          {:error, :deleted}

        true ->
          case mutate_access(rec, caller, art.clock.()) do
            :ok -> terminate(art, caller, artifact_id, version, :delete, view, rec)
            {:error, _} = failure -> failure
          end
      end
    end
  end

  @doc """
  `reap/2` of the Contract: `reap(art, caller, artifact_id)`. Records past
  `access_expires_at` or `retain_until`, and staging records past
  `staging_ttl_ms`, move to `:deleted` (one CAS batch) and their bytes are
  deleted best-effort and reported. Caller-driven only — no background
  process. `caller.tenant` must equal the artifact's tenant.
  """
  def reap(art, caller, artifact_id) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         {:ok, view} <- load(art, caller.tenant, artifact_id) do
      now = art.clock.()

      due =
        view.folded.versions
        |> Map.values()
        |> Enum.filter(&due?(&1, now, art.staging_ttl_ms))
        |> Enum.sort_by(& &1.version)

      case due do
        [] ->
          {:ok, %{reaped: [], object: %{}}}

        _ ->
          # One CAS batch per max_batch_size chunk, chaining the expected
          # revision through our own commits; a conflict stops the sweep and
          # is reported honestly with what was already reaped.
          {reaped, interruption} =
            due
            |> Enum.chunk_every(art.limits.max_batch_size)
            |> Enum.reduce_while({[], view.head.revision, nil}, fn batch, {acc, expected, _} ->
              specs =
                Enum.map(batch, fn rec ->
                  {Record.deleted(), Record.version(),
                   Record.marker_payload(Record.deleted(), artifact_id, rec.version, now)}
                end)

              case append(art, view.stream, expected, specs) do
                {:committed, target} -> {:cont, {acc ++ batch, target, nil}}
                {:error, _} = failure -> {:halt, {acc, expected, failure}}
              end
            end)
            |> then(fn {committed_recs, _expected, failure} -> {committed_recs, failure} end)

          object_results =
            Map.new(reaped, fn rec ->
              outcome = delete_object(art, rec.object_key)
              Telemetry.deleted(rec, :reap, outcome)
              {rec.version, outcome}
            end)

          result = %{reaped: Enum.map(reaped, & &1.version), object: object_results}
          result = if interruption, do: Map.put(result, :interrupted, interruption), else: result

          {:ok, result}
      end
    end
  end

  defp due?(%{state: :staging} = rec, now, ttl),
    do:
      rec.state_at + ttl <= now or past?(rec.access_expires_at, now) or
        past?(rec.retain_until, now)

  defp due?(rec, now, _ttl),
    do: rec.state != :deleted and (past?(rec.access_expires_at, now) or past?(rec.retain_until, now))

  defp past?(:never, _now), do: false
  defp past?(stamp, now), do: stamp <= now

  @doc """
  `status/2` of the Contract: `status(art, caller, %{artifact_id, version})`.
  The honest state of one version — the record plus observed object evidence
  (`:verified`, `:absent`, `:mismatch`, `{:refused, reason}`,
  `{:unknown, reason}`) — under the recorded access terms. Staging records
  created after an `unknown` put carry `upload: :uncertain`; status exposes
  it, never converts it to absent.
  """
  def status(art, caller, %{artifact_id: artifact_id, version: version}) do
    with :ok <- check_caller(caller),
         :ok <- check_segment(:artifact_id, artifact_id),
         :ok <- check_version(version),
         {:ok, view} <- load(art, caller.tenant, artifact_id),
         {:ok, rec} <- fetch(view, artifact_id, version) do
      case access(rec, caller, art.clock.()) do
        {:ok, _} -> {:ok, %{record: rec, object: object_status(art, rec)}}
        {:error, _} = failure -> failure
      end
    end
  end

  def status(_, _, _), do: {:error, :invalid}

  defp object_status(art, rec) do
    case Elzoo.ObjectStore.head(art.object_store, rec.object_key, art.object_opts) do
      %{status: :found, metadata: meta} ->
        if meta.sha256 == rec.object_sha256 and meta.size == rec.size_bytes,
          do: :verified,
          else: :mismatch

      %{status: :absent} ->
        :absent

      %{status: :refused, reason: reason} ->
        {:refused, reason}

      %{status: :unknown, reason: reason} ->
        {:unknown, reason}
    end
  end

  # ── shared internals ─────────────────────────────────────────────────

  defp terminate(art, caller, artifact_id, version, cause) do
    with {:ok, view} <- load(art, caller.tenant, artifact_id),
         {:ok, rec} <- fetch(view, artifact_id, version) do
      terminate(art, caller, artifact_id, version, cause, view, rec)
    end
  end

  defp terminate(art, _caller, _id, _version, cause, view, rec) do
    now = art.clock.()
    event = if cause == :abort, do: :EvAbort, else: :EvDelete

    case apply(@cure, :step, [state_tag(rec.state), event]) do
      {:GoTo, :VDeleted} ->
        case transition(art, view, rec, cause, now) do
          {:ok, deleted} ->
            outcome = delete_object(art, rec.object_key)
            Telemetry.deleted(rec, cause, outcome)
            {:ok, %{record: deleted, object: outcome}}

          {:error, _} = failure ->
            failure
        end

      :RefuseDeleted ->
        {:error, :deleted}

      :RefuseInvalid ->
        {:error, {:invalid, :state}}
    end
  end

  defp transition(art, view, rec, cause, now) do
    {kind, cure_event} =
      case cause do
        :commit -> {Record.committed(), :EvCommit}
        :abort -> {Record.deleted(), :EvAbort}
        :delete -> {Record.deleted(), :EvDelete}
        :reap -> {Record.deleted(), :EvReap}
      end

    case apply(@cure, :step, [state_tag(rec.state), cure_event]) do
      {:GoTo, next} ->
        case append(art, view.stream, view.head.revision, [
               {kind, Record.version(),
                Record.marker_payload(kind, rec.artifact_id, rec.version, now)}
             ]) do
          {:committed, _} ->
            {:ok, %{rec | state: state_name(next), state_at: now}}

          {:error, _} = failure ->
            failure
        end

      :RefuseDeleted ->
        {:error, :deleted}

      :RefuseInvalid ->
        {:error, {:invalid, :state}}
    end
  end

  defp state_tag(:staging), do: :VStaging
  defp state_tag(:committed), do: :VCommitted
  defp state_tag(:deleted), do: :VDeleted
  defp state_name(:VCommitted), do: :committed
  defp state_name(:VDeleted), do: :deleted

  defp fetch(view, _artifact_id, :head),
    do: if(view.folded.head, do: {:ok, view.folded.head}, else: {:error, :not_found})

  defp fetch(view, _artifact_id, version) do
    case Map.fetch(view.folded.versions, version) do
      {:ok, rec} -> {:ok, rec}
      :error -> {:error, :not_found}
    end
  end

  # delete enforces the recorded terms and access_expires_at (the Contract
  # lists it among the enforced operations) in addition to the structural
  # tenant match every mutation requires; abort and reap are tenant-match only.
  defp mutate_access(rec, caller, now) do
    case access(rec, caller, now) do
      {:ok, _} -> :ok
      {:error, _} = failure -> failure
    end
  end

  defp access(rec, caller, now) do
    if rec.tenant != caller.tenant or rec.access.tenant != caller.tenant do
      {:error, :not_found}
    else
      principal_ok = term_present?(rec.access.principals, caller.principal)
      scopes_ok = terms_covered?(rec.access.scopes, caller.scopes)
      order = expiry_order(rec.access_expires_at, now)

      case apply(@cure, :decide, [principal_ok, scopes_ok, order]) do
        :AccessPermit -> {:ok, rec}
        :AccessDenied -> {:error, :access_denied}
        :AccessExpired -> {:error, :expired}
      end
    end
  end

  defp term_present?(:any, _value), do: true
  defp term_present?(list, value) when is_list(list), do: value in list

  defp terms_covered?(:any, _scopes), do: true
  defp terms_covered?(required, scopes) when is_list(required) and is_list(scopes),
    do: Enum.all?(required, &(&1 in scopes))

  defp expiry_order(:never, _now), do: :StampBefore
  defp expiry_order(stamp, now), do: apply(@cure, :compare, [now, stamp])

  defp put_object(art, key, bytes, media_type) do
    case Elzoo.ObjectStore.put(
           art.object_store,
           key,
           bytes,
           [content_type: media_type] ++ art.object_opts
         ) do
      %{status: :committed} -> :ok
      %{status: :refused, reason: reason} -> {:error, {:object_store_refused, reason}}
      %{status: :unknown, reason: reason} -> {:uncertain, reason}
    end
  end

  # Verify the recorded object evidence before a commit: presence, the stored
  # transport checksum and size through `reconcile_put` — never a blind re-put.
  defp verify(art, rec) do
    {:ok, raw} = Base.decode16(rec.object_sha256, case: :lower)

    case Elzoo.ObjectStore.reconcile_put(art.object_store, rec.object_key, raw, art.object_opts) do
      %{status: :reconciled, observation: :match, head: %{metadata: meta}} ->
        if meta.size == rec.size_bytes,
          do: :ok,
          else: integrity_failure(rec, :commit, :size_mismatch)

      %{status: :reconciled, observation: :mismatch} ->
        integrity_failure(rec, :commit, :object_mismatch)

      %{status: :reconciled, observation: :absent} ->
        {:error, {:commit_failed, %{evidence: :absent}}}

      %{status: :refused, reason: reason} ->
        {:error, {:object_store_refused, reason}}

      %{status: :unknown, reason: reason} ->
        {:error, {:object_store_unknown, reason}}
    end
  end

  defp integrity_failure(rec, via, detail) do
    Telemetry.integrity_failure(rec, via)
    {:error, {:commit_failed, %{evidence: detail}}}
  end

  defp delete_object(art, key) do
    case Elzoo.ObjectStore.delete(art.object_store, key, art.object_opts) do
      %{status: :committed} -> :deleted
      %{status: :refused} -> :refused
      %{status: :unknown} -> :unknown
      %{status: :absent} -> :absent
    end
  end

  defp append(art, stream, expected, specs) do
    case Record.rows(stream, expected, specs, art.fold, art.limits) do
      {:ok, rows, request} ->
        case Store.write(art.store, :append, [stream, expected, rows, []], request) do
          {:committed, _} = committed -> committed
          {:conflict, %{expected: e, observed: o}} -> {:error, {:commit_failed, %{expected: e, observed: o}}}
          {:rejected, :caller_transaction} -> {:error, :caller_transaction}
          {:rejected, :record_too_large} -> {:error, :too_large}
          {:rejected, reason} -> {:error, {:commit_failed, %{rejected: reason}}}
          {:indeterminate, _info} -> {:error, {:commit_failed, :indeterminate}}
        end

      {:error, {:rejected, reason}} ->
        if reason == :record_too_large, do: {:error, :too_large}, else: {:error, {:invalid, reason}}
    end
  end

  defp load(art, tenant, artifact_id) do
    stream = Record.stream(tenant, artifact_id)

    with {:ok, head} <- store_head(art, stream),
         {:ok, rows} <- store_rows(art, stream, head.low_water + 1, head.revision) do
      {:ok,
       %{
         stream: stream,
         head: head,
         folded: Record.fold(rows, fold_with_limits(art))
       }}
    end
  end

  defp fold_with_limits(art),
    do: Map.merge(%{kinds: art.fold.kinds, versions: art.fold.versions}, %{limits: art.limits})

  defp store_head(art, stream) do
    case Store.read(art.store, :head, [stream]) do
      {:ok, head} -> {:ok, head}
      {:error, :caller_transaction} -> {:error, :caller_transaction}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  defp store_rows(art, stream, from, revision), do: store_rows(art, stream, from, revision, [])

  defp store_rows(art, stream, from, revision, acc) do
    case Log.read(art.store, stream, from, @page) do
      {:ok, rows, _head} ->
        rows = Enum.filter(rows, &(is_map(&1) and is_integer(&1.sequence)))
        acc = acc ++ rows
        last = acc |> List.last(%{sequence: from - 1}) |> Map.get(:sequence)

        if length(rows) == @page and last < revision,
          do: store_rows(art, stream, last + 1, revision, acc),
          else: {:ok, acc}

      {:error, :caller_transaction} ->
        {:error, :caller_transaction}

      {:error, _} ->
        {:error, :store_unavailable}
    end
  end

  # Best-effort tenant index: an `artifact_index` record per staging call,
  # deduplicated at read. Any failure (conflict, unavailability) is skipped —
  # the Contract declares the index a separate record whose consistency with
  # commits is best-effort, so a missing entry is a documented gap, not a bug.
  defp index(art, tenant, artifact_id, at) do
    stream = Record.index_stream(tenant)

    with {:ok, head} <- store_head(art, stream),
         {:ok, rows, request} <-
           Record.rows(
             stream,
             head.revision,
             [{Record.index_kind(), Record.version(), Record.index_payload(artifact_id, at)}],
             art.fold,
             art.limits
           ) do
      Store.write(art.store, :append, [stream, head.revision, rows, []], request)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # All visible `artifact_index` rows of the tenant, deduplicated by
  # artifact_id in stream order; unreadable rows are skipped.
  defp index_rows(art, tenant) do
    stream = Record.index_stream(tenant)
    fold = fold_with_limits(art)

    with {:ok, head} <- store_head(art, stream),
         {:ok, rows} <- store_rows(art, stream, head.low_water + 1, head.revision) do
      ids =
        rows
        |> Enum.reduce({[], MapSet.new()}, fn row, {acc, seen} ->
          case Record.index_event(row, fold) do
            {:index, id, _at} ->
              if MapSet.member?(seen, id),
                do: {acc, seen},
                else: {[id | acc], MapSet.put(seen, id)}

            :unreadable ->
              {acc, seen}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      {:ok, ids}
    end
  end

  # ── validation ───────────────────────────────────────────────────────

  defp check_caller(%{tenant: tenant, principal: principal, scopes: scopes}) do
    cond do
      not Record.segment?(tenant) -> {:error, :invalid}
      not Codec.text?(principal) -> {:error, :invalid}
      not (is_list(scopes) and Enum.all?(scopes, &Codec.text?/1)) -> {:error, :invalid}
      true -> :ok
    end
  end

  defp check_caller(_), do: {:error, :invalid}

  defp check_segment(_field, value), do: if(Record.segment?(value), do: :ok, else: {:error, :invalid})

  defp check_version(:head), do: :ok
  defp check_version(v) when is_integer(v) and v >= 1, do: :ok
  defp check_version(_), do: {:error, :invalid}

  defp check_list(limit, cursor) do
    cond do
      not (is_integer(limit) and limit in 1..@max_list) -> {:error, :invalid}
      not (is_nil(cursor) or (is_integer(cursor) and cursor >= 0)) -> {:error, :invalid}
      true -> :ok
    end
  end

  defp input(input, art, caller) when is_map(input) do
    bytes = Map.get(input, :bytes)
    media = Map.get(input, :media_type, "application/octet-stream")
    metadata = Map.get(input, :metadata, %{})
    access = Map.get(input, :access)
    expires = Map.get(input, :access_expires_at, :never)
    retain = Map.get(input, :retain_until, :never)

    with :ok <- input_bytes(bytes, art.max_bytes),
         :ok <- input_media(media),
         {:ok, meta} <- input_metadata(metadata, art.max_metadata_bytes),
         {:ok, access_terms} <- input_access(access, caller.tenant),
         :ok <- input_stamp(:access_expires_at, expires),
         :ok <- input_stamp(:retain_until, retain) do
      {:ok,
       %{
         bytes: bytes,
         media_type: media,
         metadata: meta,
         access: access_terms,
         access_expires_at: expires,
         retain_until: retain
       }}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :invalid}
    end
  end

  defp input(_, _, _), do: {:error, :invalid}

  defp input_bytes(bytes, max) when is_binary(bytes),
    do: if(byte_size(bytes) > max, do: {:error, :too_large}, else: :ok)

  defp input_bytes(_, _), do: {:error, :invalid}

  defp input_media(media), do: if(Record.media?(media), do: :ok, else: {:error, :invalid})

  defp input_metadata(metadata, max) do
    try do
      encoded = Jason.encode!(metadata)

      if byte_size(encoded) <= max,
        do: {:ok, Jason.decode!(encoded)},
        else: {:error, :too_large}
    rescue
      _ -> {:error, :invalid}
    end
  end

  defp input_access(nil, tenant), do: {:ok, %{tenant: tenant, principals: :any, scopes: :any}}

  defp input_access(%{tenant: t, principals: p, scopes: s} = access, tenant)
       when map_size(access) == 3 do
    cond do
      t != tenant -> :error
      not (p == :any or (is_list(p) and Enum.all?(p, &Codec.text?/1))) -> :error
      not (s == :any or (is_list(s) and Enum.all?(s, &Codec.text?/1))) -> :error
      true -> {:ok, %{tenant: tenant, principals: p, scopes: s}}
    end
  end

  defp input_access(_, _), do: :error

  defp input_stamp(field, :never), do: if(field in [:access_expires_at, :retain_until], do: :ok, else: :error)
  defp input_stamp(_field, n) when is_integer(n) and n >= 0, do: :ok
  defp input_stamp(_, _), do: :error
end
