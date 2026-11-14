# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeStore do
  @moduledoc """
  The immutable recipe versions of a tenant, with a published pointer, a check
  gate and pin records (`state/recipe-store`, ELZ-171).

  The bytes of a version are an artifact of `state/artifact` (the compact JSON
  of the neutral package, under the artifact ID of the 64 hex characters of its
  identity). Everything else is a record of the one stream `recipe-store/<tenant>`
  of the ready Store (`state/event-log`): `stored`, verdict, `published`, pin,
  unpin and delete mark. A change reads the stream, decides on the folded state
  with the pure `Cure.Elzoo.RecipeStore.decide/6` and appends one record at the
  head revision, so two changes of one tenant are in one order. On a conflict it
  reads again, at most 3 tries, then `{:error, :contended}`; an indeterminate
  append is `{:error, :indeterminate}` and never tried again.

  A delete commits the mark first and only then deletes the artifact versions,
  so no artifact record is deleted while the tenant stream holds no mark.

  No process, no cache, no listing across tenants. No package content appears
  in an error; this module emits no log and no telemetry event.
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}
  alias Elzoo.{Artifact, RecipeCheck, RecipePackage}

  @cure :"Cure.Elzoo.RecipeStore"
  @version 1
  @max_records 10_000
  @max_tries 3
  @max_run_id 128
  @page 1_000

  @stored "recipe_stored"
  @checked "recipe_checked"
  @published "recipe_published"
  @pinned "recipe_pinned"
  @unpinned "recipe_unpinned"
  @deleted "recipe_deleted"
  @kinds [@stored, @checked, @published, @pinned, @unpinned, @deleted]

  @identity ~r/\Arecipe-package-v1:sha256:[0-9a-f]{64}\z/
  @segment ~r/\A[A-Za-z0-9._-]+\z/

  defstruct [:artifact, :log, :fold, :limits]

  @doc "Record kinds to merge into the fold of the Store (all `:non_state_bearing`, schema version 1)."
  def kinds, do: Map.new(@kinds, &{&1, :non_state_bearing})

  @doc """
  `opts` has exactly `artifact` (a handle of `Elzoo.Artifact.new/1`) and `log`
  (a ready Store `{module, opts}` whose fold holds `kinds/0` at schema version 1).
  """
  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:artifact, :log],
      do: build(Keyword.fetch!(opts, :artifact), Keyword.fetch!(opts, :log)),
      else: {:error, {:invalid, :opts}}
  end

  def new(_), do: {:error, {:invalid, :opts}}

  defp build(artifact, log) do
    {fold, limits} =
      case log do
        {module, o} when is_atom(module) and (is_map(o) or is_list(o)) ->
          if is_map(o) or Keyword.keyword?(o) do
            o = Map.new(o)
            {Map.get(o, :fold), Map.get(o, :limits)}
          else
            {nil, nil}
          end

        _ ->
          {nil, nil}
      end

    cond do
      not is_struct(artifact, Artifact) ->
        {:error, {:invalid, :artifact}}

      not (is_nil(fold) == false and Codec.fold_valid?(fold) and
             Map.take(fold.kinds, @kinds) == kinds() and @version in fold.versions and
             is_map(limits) and is_integer(Map.get(limits, :max_record_bytes)) and
             limits.max_record_bytes >= 1_024 and is_integer(Map.get(limits, :max_batch_size)) and
               limits.max_batch_size >= 1) ->
        {:error, {:invalid, :log}}

      true ->
        {:ok, %__MODULE__{artifact: artifact, log: log, fold: fold, limits: limits}}
    end
  end

  # ── operations ───────────────────────────────────────────────────────

  @doc "Store a neutral package; `{:ok, identity}`."
  def put(rs, caller, package) do
    with :ok <- store(rs),
         :ok <- check_caller(caller),
         {:ok, identity, bytes} <- package(package),
         {:ok, loaded} <- load(rs, caller.tenant) do
      case put_step(rs, caller, loaded, identity, false) do
        {:append, _, _, _} ->
          if loaded.revision >= @max_records,
            do: {:error, :stream_full},
            else: write_then_record(rs, caller, loaded, identity, bytes)

        {:done, result} ->
          result
      end
    end
  end

  defp write_then_record(rs, caller, loaded, identity, bytes) do
    input = %{
      bytes: bytes,
      media_type: "application/json",
      access_expires_at_unix_ms: :never,
      retain_until_unix_ms: :never
    }

    case Artifact.put(rs.artifact, caller, artifact_id(identity), input) do
      {:ok, _} ->
        change(rs, caller.tenant, loaded, &put_step(rs, caller, &1, identity, true))

      {:error, reason} ->
        {:error, {:artifact, reason}}
    end
  end

  # The decision of `put/3` over a folded state. After the artifact write
  # (`written`), a mark that appeared meanwhile removes the versions again.
  defp put_step(rs, caller, loaded, identity, written) do
    case Map.get(loaded.state.versions, identity) do
      %{deleted: true} ->
        if written, do: artifact_delete(rs, caller, identity)
        {:done, {:error, :deleted}}

      %{} ->
        {:done, {:ok, identity}}

      nil ->
        {:append, @stored, payload(identity), {:ok, identity}}
    end
  end

  @doc "The stored package map, after its identity was computed again from the bytes."
  def get(rs, caller, identity) do
    with :ok <- store(rs),
         :ok <- check_caller(caller),
         :ok <- check_identity(identity),
         {:ok, loaded} <- load(rs, caller.tenant),
         :ok <- allowed(loaded, :OpGet, identity) do
      read_package(rs, caller, identity)
    end
  end

  @doc "Check the package with `Elzoo.RecipeCheck.check/2`; a passing verdict is recorded."
  def check(rs, caller, identity, facts) do
    with :ok <- store(rs),
         :ok <- check_caller(caller),
         :ok <- check_identity(identity),
         {:ok, loaded} <- load(rs, caller.tenant),
         :ok <- allowed(loaded, :OpCheck, identity),
         {:ok, package} <- read_package(rs, caller, identity) do
      case RecipeCheck.check(package, facts) do
        {:ok, verdict} = passed ->
          change(rs, caller.tenant, loaded, fn l ->
            case allowed(l, :OpCheck, identity) do
              :ok -> {:append, @checked, payload(identity, upper_cost: verdict.upper_cost), passed}
              {:error, _} = refusal -> {:done, refusal}
            end
          end)

        other ->
          other
      end
    end
  end

  @doc "Set the published pointer to a stored, checked, live version."
  def publish(rs, caller, identity) do
    with :ok <- store(rs), :ok <- check_caller(caller), :ok <- check_identity(identity) do
      change(rs, caller.tenant, nil, fn loaded ->
        case allowed(loaded, :OpPublish, identity) do
          :ok ->
            previous = loaded.state.published
            result = {:ok, %{published: identity, previous: previous}}

            if previous == identity,
              do: {:done, {:ok, %{published: identity, previous: identity}}},
              else: {:append, @published, payload(identity), result}

          {:error, _} = refusal ->
            {:done, refusal}
        end
      end)
    end
  end

  @doc "`{:ok, identity | nil}`."
  def published(rs, caller) do
    with :ok <- store(rs), :ok <- check_caller(caller), {:ok, loaded} <- load(rs, caller.tenant) do
      {:ok, loaded.state.published}
    end
  end

  @doc "Record that the live Run `run_id` uses a stored, live version."
  def pin(rs, caller, identity, run_id) do
    with :ok <- store(rs),
         :ok <- check_caller(caller),
         :ok <- check_identity(identity),
         :ok <- check_run_id(run_id) do
      change(rs, caller.tenant, nil, fn loaded ->
        case allowed(loaded, :OpPin, identity) do
          :ok ->
            if MapSet.member?(loaded.state.versions[identity].pins, run_id),
              do: {:done, {:ok, :pinned}},
              else: {:append, @pinned, payload(identity, run_id: run_id), {:ok, :pinned}}

          {:error, _} = refusal ->
            {:done, refusal}
        end
      end)
    end
  end

  @doc "Remove the pin record of the pair; an unknown pair appends nothing."
  def unpin(rs, caller, identity, run_id) do
    with :ok <- store(rs),
         :ok <- check_caller(caller),
         :ok <- check_identity(identity),
         :ok <- check_run_id(run_id) do
      change(rs, caller.tenant, nil, fn loaded ->
        case Map.get(loaded.state.versions, identity) do
          %{pins: pins} ->
            if MapSet.member?(pins, run_id),
              do: {:append, @unpinned, payload(identity, run_id: run_id), {:ok, :unpinned}},
              else: {:done, {:ok, :unpinned}}

          nil ->
            {:done, {:ok, :unpinned}}
        end
      end)
    end
  end

  @doc """
  Refused while a pin record exists and while the version is published. The
  delete mark is committed first, and only then `Artifact.delete/4` is called
  for each version that `Artifact.versions/3` lists. A version that is already
  marked runs the Artifact delete again.
  """
  def delete(rs, caller, identity) do
    with :ok <- store(rs),
         :ok <- check_caller(caller),
         :ok <- check_identity(identity),
         {:ok, _} <-
           change(rs, caller.tenant, nil, fn loaded ->
             case verdict(loaded, :OpDelete, identity) do
               :Allow -> {:append, @deleted, payload(identity), {:ok, :marked}}
               :Resume -> {:done, {:ok, :marked}}
               refusal -> {:done, {:error, reason(refusal)}}
             end
           end) do
      case artifact_delete(rs, caller, identity) do
        :ok -> {:ok, :deleted}
        {:error, reason} -> {:error, {:delete_incomplete, reason}}
      end
    end
  end

  @doc "The versions of the tenant in the order of their `stored` records, from the tenant stream only."
  def versions(rs, caller) do
    with :ok <- store(rs), :ok <- check_caller(caller), {:ok, loaded} <- load(rs, caller.tenant) do
      published = loaded.state.published

      {:ok,
       for identity <- loaded.state.order do
         v = loaded.state.versions[identity]

         %{
           identity: identity,
           checked: v.checked,
           pins: MapSet.size(v.pins),
           published: identity == published,
           deleted: v.deleted
         }
       end}
    end
  end

  # ── decision (pure, from Cure) ───────────────────────────────────────

  defp verdict(loaded, op, identity) do
    {exists, deleted, checked, pinned, published} =
      case Map.get(loaded.state.versions, identity) do
        nil ->
          {false, false, false, false, false}

        v ->
          {true, v.deleted, v.checked, MapSet.size(v.pins) > 0, loaded.state.published == identity}
      end

    apply(@cure, :decide, [op, exists, deleted, checked, pinned, published])
  end

  defp allowed(loaded, op, identity) do
    case verdict(loaded, op, identity) do
      :Allow -> :ok
      refusal -> {:error, reason(refusal)}
    end
  end

  defp reason(:NotFound), do: :not_found
  defp reason(:Deleted), do: :deleted
  defp reason(:NotChecked), do: :not_checked
  defp reason(:Pinned), do: :pinned
  defp reason(:Published), do: :published

  # ── one change: read, decide, append at the head revision ────────────

  # `fun` gets the folded state and gives `{:done, result}` or
  # `{:append, kind, payload, result}`. The first state may be given.
  defp change(rs, tenant, loaded, fun), do: change(rs, tenant, loaded, fun, @max_tries)

  defp change(rs, tenant, nil, fun, tries) do
    with {:ok, loaded} <- load(rs, tenant), do: change(rs, tenant, loaded, fun, tries)
  end

  defp change(rs, tenant, loaded, fun, tries) do
    case fun.(loaded) do
      {:done, result} ->
        result

      {:append, kind, payload, result} ->
        case append(rs, loaded, kind, payload) do
          :ok -> result
          :conflict when tries > 1 -> change(rs, tenant, nil, fun, tries - 1)
          :conflict -> {:error, :contended}
          {:error, _} = failure -> failure
        end
    end
  end

  defp append(_rs, %{revision: revision}, _kind, _payload) when revision >= @max_records,
    do: {:error, :stream_full}

  defp append(rs, %{stream: stream, revision: expected}, kind, payload) do
    with {:ok, rows, request} <- rows(rs, stream, expected, kind, payload) do
      case Store.write(rs.log, :append, [stream, expected, rows, []], request) do
        {:committed, _} -> :ok
        {:conflict, _} -> :conflict
        {:rejected, reason} -> {:error, {:log, reason}}
        {:indeterminate, _} -> {:error, :indeterminate}
      end
    end
  end

  defp rows(rs, stream, expected, kind, payload) do
    nonce = :crypto.strong_rand_bytes(16)

    row = %Log.Record{
      stream: stream,
      sequence: expected + 1,
      kind: kind,
      schema_version: @version,
      payload: payload,
      nonce: nonce
    }

    row = %{row | digest: Log.digest(row)}

    request = %{
      stream: stream,
      expected: expected,
      records: [{kind, @version, payload}],
      outbox: []
    }

    with :ok <- Log.preflight(request, rs.fold, rs.limits),
         :ok <- Log.validate_row(row, rs.fold, rs.limits) do
      {:ok, [row],
       %{
         operation: :append,
         stream: stream,
         expected: expected,
         target: expected + 1,
         nonce: nonce,
         digest: Codec.hash([Log.canonical_bytes(row)]),
         records: [row]
       }}
    else
      {:rejected, reason} -> {:error, {:log, reason}}
      {:error, reason} -> {:error, {:log, reason}}
    end
  end

  # ── artifact ─────────────────────────────────────────────────────────

  defp artifact_id("recipe-package-v1:sha256:" <> hex), do: hex

  defp read_package(rs, caller, identity) do
    case Artifact.get(rs.artifact, caller, artifact_id(identity), :head) do
      {:ok, %{bytes: bytes}} -> decode_bytes(bytes, identity)
      {:error, reason} -> {:error, {:artifact, reason}}
    end
  end

  defp decode_bytes(bytes, identity) do
    with {:ok, %{"identity" => ^identity} = map} <- Jason.decode(bytes),
         {:ok, _} <- RecipePackage.decode(map) do
      {:ok, map}
    else
      _ -> {:error, :integrity_mismatch}
    end
  end

  # Complete when each call gave `{:ok, _}` or `{:error, :deleted}`, or no version exists.
  defp artifact_delete(rs, caller, identity) do
    aid = artifact_id(identity)

    case Artifact.versions(rs.artifact, caller, aid) do
      {:ok, versions} ->
        Enum.reduce_while(versions, :ok, fn %{version: version}, :ok ->
          case Artifact.delete(rs.artifact, caller, aid, version) do
            {:ok, _} -> {:cont, :ok}
            {:error, :deleted} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Compact JSON, keys in ascending UTF-8 byte order: the bytes of the identity.
  defp package(package) do
    with true <- is_map(package) and not is_struct(package),
         {:ok, _} <- RecipePackage.decode(package) do
      {:ok, package["identity"], IO.iodata_to_binary(canonical(package))}
    else
      _ -> {:error, :invalid_package}
    end
  rescue
    _ -> {:error, :invalid_package}
  end

  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, child} -> [Jason.encode!(key), ?:, canonical(child)] end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  defp canonical(value) when is_list(value),
    do: [?[, Enum.intersperse(Enum.map(value, &canonical/1), ?,), ?]]

  defp canonical(value), do: Jason.encode!(value)

  # ── the tenant stream ────────────────────────────────────────────────

  defp stream(tenant), do: "recipe-store/" <> tenant

  defp load(rs, tenant) do
    stream = stream(tenant)

    with {:ok, head} <- head(rs, stream),
         {:ok, rows} <- read_rows(rs, stream, 1, head.revision, []),
         {:ok, state} <- fold(rows) do
      {:ok, %{stream: stream, revision: head.revision, state: state}}
    end
  end

  defp head(rs, stream) do
    case Store.read(rs.log, :head, [stream]) do
      {:ok, %{low_water: 0} = head} -> {:ok, head}
      {:ok, %{low_water: low}} -> {:error, {:log, {:pruned, low}}}
      {:error, reason} -> {:error, {:log, reason}}
    end
  end

  defp read_rows(_rs, _stream, from, revision, acc) when from > revision,
    do: {:ok, Enum.reverse(acc)}

  defp read_rows(rs, stream, from, revision, acc) do
    limit = min(@page, revision - from + 1)

    case Log.read(rs.log, stream, from, limit) do
      {:ok, rows, head} ->
        if head.revision >= revision and rows != [] and length(rows) <= limit and
             rows_valid?(rs, rows, stream, from),
           do: read_rows(rs, stream, from + length(rows), revision, Enum.reverse(rows, acc)),
           else: {:error, {:log, :malformed}}

      {:error, reason} ->
        {:error, {:log, reason}}
    end
  end

  defp rows_valid?(rs, rows, stream, from) do
    rows
    |> Enum.with_index(from)
    |> Enum.all?(fn {row, sequence} ->
      is_map(row) and Map.get(row, :stream) == stream and Map.get(row, :sequence) == sequence and
        Log.validate_row(row, rs.fold, rs.limits) == :ok
    end)
  end

  defp fold(rows) do
    Enum.reduce_while(rows, {:ok, %{versions: %{}, order: [], published: nil}}, fn row,
                                                                                   {:ok, state} ->
      case event(row) do
        {:ok, event} -> {:cont, {:ok, apply_event(state, event)}}
        :unreadable -> {:halt, {:error, {:log, :malformed}}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, %{state | order: Enum.reverse(state.order)}}
      error -> error
    end
  end

  defp event(%{kind: kind, schema_version: @version, payload: payload}) when kind in @kinds do
    with {:ok, %{"v" => @version, "identity" => identity} = data} <- Jason.decode(payload),
         true <- Regex.match?(@identity, identity),
         {:ok, event} <- decode(kind, identity, data) do
      {:ok, event}
    else
      _ -> :unreadable
    end
  end

  defp event(_), do: :unreadable

  defp decode(@stored, id, _), do: {:ok, {:stored, id}}
  defp decode(@published, id, _), do: {:ok, {:published, id}}
  defp decode(@deleted, id, _), do: {:ok, {:deleted, id}}

  defp decode(@checked, id, %{"upper_cost" => cost}) when is_integer(cost) and cost >= 0,
    do: {:ok, {:checked, id}}

  defp decode(@pinned, id, %{"run_id" => run}),
    do: with(:ok <- run_id(run), do: {:ok, {:pinned, id, run}})

  defp decode(@unpinned, id, %{"run_id" => run}),
    do: with(:ok <- run_id(run), do: {:ok, {:unpinned, id, run}})

  defp decode(_, _, _), do: :error

  defp run_id(run), do: if(valid_run_id?(run), do: :ok, else: :error)

  defp apply_event(state, {:stored, id}) do
    if Map.has_key?(state.versions, id),
      do: state,
      else: %{
        state
        | versions:
            Map.put(state.versions, id, %{checked: false, pins: MapSet.new(), deleted: false}),
          order: [id | state.order]
      }
  end

  defp apply_event(state, {:published, id}), do: %{state | published: id}
  defp apply_event(state, {:checked, id}), do: update(state, id, &%{&1 | checked: true})
  defp apply_event(state, {:deleted, id}), do: update(state, id, &%{&1 | deleted: true})

  defp apply_event(state, {:pinned, id, run}),
    do: update(state, id, &%{&1 | pins: MapSet.put(&1.pins, run)})

  defp apply_event(state, {:unpinned, id, run}),
    do: update(state, id, &%{&1 | pins: MapSet.delete(&1.pins, run)})

  defp update(state, id, fun) do
    case state.versions do
      %{^id => v} -> %{state | versions: Map.put(state.versions, id, fun.(v))}
      _ -> state
    end
  end

  defp payload(identity, extra \\ []),
    do:
      Jason.encode!(
        Map.new([v: @version, identity: identity] ++ extra, fn {k, v} -> {Atom.to_string(k), v} end)
      )

  # ── operands ─────────────────────────────────────────────────────────

  defp store(%__MODULE__{}), do: :ok
  defp store(_), do: {:error, {:invalid, :store}}

  defp check_caller(%{tenant: tenant, principal: principal, scopes: scopes}) do
    if is_binary(tenant) and byte_size(tenant) in 1..64 and Regex.match?(@segment, tenant) and
         tenant not in [".", ".."] and Codec.text?(principal) and is_list(scopes) and
         Enum.all?(scopes, &Codec.text?/1),
       do: :ok,
       else: {:error, {:invalid, :caller}}
  end

  defp check_caller(_), do: {:error, {:invalid, :caller}}

  defp check_identity(identity),
    do:
      if(is_binary(identity) and Regex.match?(@identity, identity),
        do: :ok,
        else: {:error, {:invalid, :identity}}
      )

  defp check_run_id(run_id),
    do: if(valid_run_id?(run_id), do: :ok, else: {:error, {:invalid, :run_id}})

  defp valid_run_id?(run_id),
    do: Codec.text?(run_id) and byte_size(run_id) in 1..@max_run_id
end
