# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Scheduler.Record do
  @moduledoc """
  Scheduler record kinds and their self-contained JSON payloads
  (schema_version 1, Jason 1.4.5 as the ready `integration/json` recipe
  prescribes). Every record is `:non_state_bearing`; the schedule's durable
  projection is derived by scanning the stream (see `Elzoo.Scheduler.Ledger`).
  The index stream uses the two `index_*` kinds only; schedule streams use the
  rest. Any decode failure of a required record fails closed (`:unreadable`).
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Codec

  @version 1
  @index_kinds ~w(index_registered index_retired)

  @schedule_kinds ~w(
    schedule_defined schedule_paused schedule_resumed schedule_deleted
    tick_recorded slot_decided occurrence_dispatch occurrence_settled
    occurrence_expired occurrence_redefined
  )

  @slot_decisions ~w(admitted skipped replaced already_recorded)
  @skip_reasons ~w(offline_catch_up overlap queue_full ambiguous)
  @dispatch_phases ~w(dispatched pending error)
  @settlement_kinds ~w(acknowledged released)
  @settlement_vias ~w(completed discarded cancelled reaped deleted)

  def version, do: @version
  def index_kinds, do: @index_kinds
  def schedule_kinds, do: @schedule_kinds
  def kinds, do: Map.new(@index_kinds ++ @schedule_kinds, &{&1, :non_state_bearing})
  def kind_names, do: @index_kinds ++ @schedule_kinds
  def slot_decisions, do: @slot_decisions
  def skip_reasons, do: @skip_reasons
  def dispatch_phases, do: @dispatch_phases
  def settlement_kinds, do: @settlement_kinds
  def settlement_vias, do: @settlement_vias

  # ── payload builders (each returns a JSON binary) ─────────────────

  def defined_payload(defn),
    do:
      Jason.encode!(%{
        "v" => @version,
        "schedule_id" => defn.schedule_id,
        "generation" => defn.generation,
        "spec" => spec_payload(defn.spec),
        "timezone" => defn.timezone,
        "overlap" => overlap_payload(defn.overlap_policy),
        "dispatch" => dispatch_payload(defn.dispatch),
        "occurrence_ttl_ms" => defn.occurrence_ttl_ms,
        "at" => defn.at
      })

  defp spec_payload({:cron, expr}), do: %{"kind" => "cron", "expression" => expr}
  defp spec_payload({:at, instant}), do: %{"kind" => "at", "instant" => instant}
  defp overlap_payload(:skip), do: %{"kind" => "skip"}
  defp overlap_payload(:replace), do: %{"kind" => "replace"}
  defp overlap_payload({:queue, n}), do: %{"kind" => "queue", "n" => n}

  defp dispatch_payload({queue, max_attempts, backoff}),
    do: %{"queue" => queue, "max_attempts" => max_attempts, "backoff" => backoff}

  def control_payload(at), do: Jason.encode!(%{"v" => @version, "at" => at})

  def tick_payload(at, last_recorded, boundary, backlog, unsettled),
    do:
      Jason.encode!(%{
        "v" => @version,
        "at" => at,
        "last_recorded" => last_recorded,
        "availability_boundary" => boundary,
        "backlog" => backlog,
        "unsettled" => unsettled
      })

  def slot_payload(slot, decision),
    do: Jason.encode!(Map.merge(%{"v" => @version, "slot" => slot}, decision))

  def dispatch_record_payload(id, phase, job_id, detail),
    do:
      Jason.encode!(%{
        "v" => @version,
        "id" => id,
        "phase" => phase,
        "job_id" => job_id,
        "detail" => detail
      })

  def settled_payload(id, kind, via, at),
    do:
      Jason.encode!(%{
        "v" => @version,
        "id" => id,
        "kind" => Atom.to_string(kind),
        "via" => Atom.to_string(via),
        "at" => at
      })

  def expired_payload(id, at),
    do: Jason.encode!(%{"v" => @version, "id" => id, "at" => at})

  def redefined_payload(id, to_generation),
    do: Jason.encode!(%{"v" => @version, "id" => id, "to_generation" => to_generation})

  def index_payload(schedule_id, at),
    do: Jason.encode!(%{"v" => @version, "schedule_id" => schedule_id, "at" => at})

  # ── decoding for the Ledger projection ─────────────────────────────

  @doc "Decode a validated row's payload; `{:ok, map}` or `:unreadable`."
  def decode(row, fold, limits) do
    with :ok <- Log.validate_row(row, fold, limits),
         true <- row.kind in kind_names() and row.schema_version == @version,
         {:ok, %{"v" => @version} = data} <- Jason.decode(row.payload),
         {:ok, event} <- decode_kind(row.kind, data) do
      {:ok, event}
    else
      _ -> :unreadable
    end
  rescue
    _ -> :unreadable
  end

  defp decode_kind("index_registered", d), do: index(d, :registered)
  defp decode_kind("index_retired", d), do: index(d, :retired)

  defp decode_kind("schedule_defined", d) do
    with %{
           "schedule_id" => sid,
           "generation" => gen,
           "spec" => spec,
           "timezone" => zone,
           "overlap" => overlap,
           "dispatch" => dispatch,
           "occurrence_ttl_ms" => ttl,
           "at" => at
         } <- d,
         true <- is_binary(sid) and sid != "" and is_integer(gen) and gen >= 0,
         {:ok, spec} <- decode_spec(spec),
         true <- is_binary(zone) and byte_size(zone) in 1..64,
         {:ok, overlap} <- decode_overlap(overlap),
         {:ok, dispatch} <- decode_dispatch(dispatch),
         true <- is_integer(ttl) and ttl >= 1,
         true <- instant?(at) do
      {:ok,
       {:defined,
        %{
          schedule_id: sid,
          generation: gen,
          spec: spec,
          timezone: zone,
          overlap_policy: overlap,
          dispatch: dispatch,
          occurrence_ttl_ms: ttl,
          at: at
        }}}
    else
      _ -> :error
    end
  end

  defp decode_kind(kind, %{"at" => at})
       when kind in ~w(schedule_paused schedule_resumed schedule_deleted) do
    if instant?(at) do
      tag =
        %{
          "schedule_paused" => :paused,
          "schedule_resumed" => :resumed,
          "schedule_deleted" => :deleted
        }
        |> Map.fetch!(kind)

      {:ok, {:control, tag, at}}
    else
      :error
    end
  end

  defp decode_kind("tick_recorded", d) do
    with %{
           "at" => at,
           "last_recorded" => last,
           "availability_boundary" => boundary,
           "backlog" => backlog,
           "unsettled" => unsettled
         } <- d,
         true <-
           instant?(at) and instant?(last) and instant?(boundary) and is_integer(backlog) and
             backlog >= 0 and is_list(unsettled) and Enum.all?(unsettled, &is_binary/1) do
      {:ok, {:tick, at, last, boundary, backlog, unsettled}}
    else
      _ -> :error
    end
  end

  defp decode_kind("slot_decided", d) do
    with %{"slot" => slot, "decision" => decision} <- d,
         true <- instant?(slot) and decision in @slot_decisions,
         {:ok, extra} <- decode_slot_extra(decision, d) do
      {:ok, {:slot, slot, String.to_atom(decision), extra}}
    else
      _ -> :error
    end
  end

  defp decode_kind("occurrence_dispatch", d) do
    with %{"id" => id, "phase" => phase, "job_id" => job_id} <- d,
         true <- is_binary(id) and phase in @dispatch_phases,
         true <- (is_integer(job_id) and job_id >= 0) or is_nil(job_id) do
      {:ok, {:dispatch, id, String.to_atom(phase), job_id}}
    else
      _ -> :error
    end
  end

  defp decode_kind("occurrence_settled", d) do
    with %{"id" => id, "kind" => kind, "via" => via, "at" => at} <- d,
         true <-
           is_binary(id) and kind in @settlement_kinds and via in @settlement_vias and instant?(at) do
      {:ok, {:settled, id, String.to_atom(kind), String.to_atom(via), at}}
    else
      _ -> :error
    end
  end

  defp decode_kind("occurrence_expired", %{"id" => id, "at" => at}) when is_binary(id) do
    if instant?(at), do: {:ok, {:expired, id, at}}, else: :error
  end

  defp decode_kind("occurrence_redefined", %{"id" => id, "to_generation" => gen})
       when is_binary(id) do
    if is_integer(gen) and gen >= 0, do: {:ok, {:redefined, id, gen}}, else: :error
  end

  defp decode_kind(_, _), do: :error

  defp decode_slot_extra("admitted", %{"id" => id, "origin" => origin, "at" => at})
       when is_binary(id) and origin in ~w(live offline_catch_up),
       do:
         if(instant?(at),
           do: {:ok, %{id: id, origin: String.to_atom(origin), at: at}},
           else: :error
         )

  defp decode_slot_extra("skipped", %{"reason" => reason}) when reason in @skip_reasons,
    do: {:ok, %{reason: String.to_atom(reason)}}

  defp decode_slot_extra("replaced", %{"old" => old, "new" => new, "origin" => origin, "at" => at})
       when is_binary(old) and is_binary(new) and origin in ~w(live offline_catch_up),
       do:
         if(instant?(at),
           do: {:ok, %{old: old, new: new, origin: String.to_atom(origin), at: at}},
           else: :error
         )

  defp decode_slot_extra("already_recorded", _), do: {:ok, %{}}
  defp decode_slot_extra(_, _), do: :error

  defp decode_spec(%{"kind" => "cron", "expression" => expr}) when is_binary(expr),
    do: {:ok, {:cron, expr}}

  defp decode_spec(%{"kind" => "at", "instant" => instant}) when is_integer(instant),
    do: {:ok, {:at, instant}}

  defp decode_spec(_), do: :error

  defp decode_overlap(%{"kind" => "skip"}), do: {:ok, :skip}
  defp decode_overlap(%{"kind" => "replace"}), do: {:ok, :replace}

  defp decode_overlap(%{"kind" => "queue", "n" => n}) when is_integer(n) and n >= 1,
    do: {:ok, {:queue, n}}

  defp decode_overlap(_), do: :error

  defp decode_dispatch(%{"queue" => q, "max_attempts" => m, "backoff" => b})
       when is_binary(q) and is_integer(m) and m >= 1 and is_map(b),
       do: {:ok, {q, m, b}}

  defp decode_dispatch(_), do: :error

  defp index(%{"schedule_id" => sid, "at" => at}, tag) when is_binary(sid),
    do: if(instant?(at), do: {:ok, {tag, sid, at}}, else: :error)

  defp index(_, _), do: :error

  def instant?(n), do: is_integer(n) and n >= 0

  # ── batch row builder (same discipline as the ready Writer) ────────

  @doc """
  Build the Store rows of one batch at `expected` revision from `{kind, payload}`
  specs sharing one fresh nonce. Returns `{:ok, [%Log.Record{}], request}` where
  `request` is the Store write receipt fields, or `{:error, {:rejected, reason}}`
  when the ready Store's static validation refuses them.
  """
  def records(stream, expected, specs, fold, limits) do
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      specs
      |> Enum.with_index(expected + 1)
      |> Enum.map(fn {{kind, payload}, sequence} ->
        row = %Log.Record{
          stream: stream,
          sequence: sequence,
          kind: kind,
          schema_version: @version,
          payload: payload,
          nonce: nonce
        }

        %{row | digest: Log.digest(row)}
      end)

    tuples = Enum.map(specs, fn {kind, payload} -> {kind, @version, payload} end)

    with :ok <-
           Log.preflight(
             %{stream: stream, expected: expected, records: tuples, outbox: []},
             fold,
             limits
           ),
         true <- Enum.all?(rows, &(Log.validate_row(&1, fold, limits) == :ok)) do
      request = %{
        operation: :append,
        stream: stream,
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
