# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Lease.Record do
  @moduledoc """
  Lease record kinds, their self-contained JSON payloads (schema_version 1,
  Jason 1.4.5 as the ready `integration/json` recipe prescribes) and the
  translation of the latest lease record of a stream into the pure
  `Cure.Elzoo.Lease` reading. Every lease record alone determines the reading;
  no earlier record is needed. Any validation, digest, JSON, version or field
  failure of the latest lease record is `Unreadable` (fail closed).
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Codec

  @version 1
  @holder_kinds %{
    "lease_claimed" => :EvClaim,
    "lease_renewed" => :EvRenew,
    "lease_seized" => :EvSeize
  }
  @release_kind "lease_released"
  @kinds Map.keys(@holder_kinds) ++ [@release_kind]
  @reasons ~w(released stale terminal operator_takeover crashed_owner pruned_prefix corrupt_record clock_regression)a
  @max_ttl_ms 86_400_000
  @max_stamp 9_223_372_036_854_775_807

  def version, do: @version
  @doc "Lease kinds for the consumer's fold: all `:non_state_bearing`."
  def kinds, do: Map.new(@kinds, &{&1, :non_state_bearing})
  def kind_names, do: @kinds
  def reasons, do: @reasons
  def lease_kind?(kind), do: kind in @kinds
  def max_ttl_ms, do: @max_ttl_ms

  def owner?(owner), do: Codec.text?(owner) and byte_size(owner) in 1..200
  def ttl?(ttl), do: is_integer(ttl) and ttl in 1..@max_ttl_ms
  def reason?(reason), do: reason in @reasons
  def stamp?(n), do: is_integer(n) and n >= 0 and n <= @max_stamp

  @doc "Payload of `lease_claimed`, `lease_renewed` or `lease_seized`."
  def holder_payload(owner, at, ttl_ms),
    do:
      Jason.encode!(%{
        "v" => @version,
        "owner" => owner,
        "at" => at,
        "ttl_ms" => ttl_ms,
        "until" => until(at, ttl_ms)
      })

  @doc "Payload of `lease_released`; `prior` is the prior holder or nil when unknowable."
  def release_payload(prior, by, at, reason),
    do:
      Jason.encode!(%{
        "v" => @version,
        "owner" => prior,
        "by" => by,
        "at" => at,
        "reason" => Atom.to_string(reason)
      })

  def until(at, ttl_ms), do: at + ttl_ms * 1000

  @doc """
  Reading of a stream from its latest lease row (a `%Elzoo.DurableLog.Record{}`
  or nil) and its `low_water`. Returns `{reading, recorded_owner, reason}`:
  the Cure reading, the owner named by the latest record (nil when none or
  unreadable) and a reason tag for ambiguous readings.
  """
  def reading(nil, low_water, _fold, _limits) when low_water > 0,
    do: {:Unreadable, nil, :pruned_prefix}

  def reading(nil, _low_water, _fold, _limits), do: {{:NoHolder, 0}, nil, nil}

  def reading(row, _low_water, fold, limits) do
    case event(row, fold, limits) do
      {:EvRelease, at, _prior} ->
        {{:NoHolder, at}, nil, nil}

      {tag, at, until, owner} when tag in [:EvClaim, :EvRenew, :EvSeize] ->
        {{:HolderStamp, at, until}, owner, nil}

      :unreadable ->
        {:Unreadable, nil, :unreadable}
    end
  end

  @doc "Decode a validated lease row into an event; `:unreadable` on any failure."
  def event(row, fold, limits) do
    with :ok <- Log.validate_row(row, fold, limits),
         true <- lease_kind?(row.kind) and row.schema_version == @version,
         {:ok, %{"v" => @version} = data} <- Jason.decode(row.payload) do
      decode(row.kind, data)
    else
      _ -> :unreadable
    end
  rescue
    _ -> :unreadable
  end

  defp decode(@release_kind, %{"owner" => prior, "by" => by, "at" => at, "reason" => reason}) do
    if (is_nil(prior) or owner?(prior)) and owner?(by) and stamp?(at) and
         reason in Enum.map(@reasons, &Atom.to_string/1),
       do: {:EvRelease, at, prior},
       else: :unreadable
  end

  defp decode(kind, %{"owner" => owner, "at" => at, "ttl_ms" => ttl, "until" => until})
       when is_map_key(@holder_kinds, kind) do
    if owner?(owner) and stamp?(at) and ttl?(ttl) and stamp?(until) and until == until(at, ttl),
      do: {Map.fetch!(@holder_kinds, kind), at, until, owner},
      else: :unreadable
  end

  defp decode(_, _), do: :unreadable

  @doc """
  Build the Store records of one batch at `expected` revision from
  `{kind, payload}` pairs (schema_version 1) sharing one fresh nonce, as the
  ready Writer does. Returns `{:ok, [%Record{}], request}` where `request` is
  the Store write receipt (operation, stream, expected, target, nonce, digest,
  records) or `{:error, {:rejected, reason}}` when the ready Store's static
  validation (`Elzoo.DurableLog.preflight/3`, `validate_row/3`) refuses them.
  """
  def records(key, expected, specs, fold, limits) do
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      specs
      |> Enum.with_index(expected + 1)
      |> Enum.map(fn {{kind, version, payload}, sequence} ->
        row = %Log.Record{
          stream: key,
          sequence: sequence,
          kind: kind,
          schema_version: version,
          payload: payload,
          nonce: nonce
        }

        %{row | digest: Log.digest(row)}
      end)

    tuples = Enum.map(specs, fn {kind, version, payload} -> {kind, version, payload} end)

    with :ok <-
           Log.preflight(
             %{stream: key, expected: expected, records: tuples, outbox: []},
             fold,
             limits
           ),
         true <- Enum.all?(rows, &(Log.validate_row(&1, fold, limits) == :ok)) do
      request = %{
        operation: :append,
        stream: key,
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
