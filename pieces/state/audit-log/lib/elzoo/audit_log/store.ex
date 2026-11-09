# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuditLog.Store do
  @moduledoc """
  Store tuple returned by `Elzoo.AuditLog.bind/2`: the ready `Elzoo.DurableLog.Postgres`
  Store with one session attribution bound to it.

  Reads, capabilities and writes to unaudited tables (`put_checkpoint`, `ack`) delegate
  unchanged. `append` and `retain` pin one connection with `repo.checkout/2`, set the session
  setting `elzoo_audit.attribution` to the attribution plus the operation it covers (stream and
  exact record digests for an append; stream and `through` for a retention), call the inner
  Store and reset the setting. Replies are the inner Store's replies; nothing is added to the
  ready Store's reply set. Inside the caller's open transaction the setting is not touched and
  the inner Store's caller-transaction refusal applies. If the checkout itself fails (Repo not
  running, pool queue timeout, exit), the write returns the conservative
  `{:indeterminate, %{cause: ...}}` with the request identity the inner Store would have used,
  never an exit.
  """
  @behaviour Elzoo.DurableLog.Store
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Codec

  @setting "elzoo_audit.attribution"
  def setting, do: @setting

  defp inner({__MODULE__, opts}), do: opts.inner

  @impl true
  def capabilities(store), do: delegate(store, :capabilities, [])
  @impl true
  def head(store, stream), do: delegate(store, :head, [stream])
  @impl true
  def read(store, stream, from, limit), do: delegate(store, :read, [stream, from, limit])
  @impl true
  def read_at(store, stream, sequence), do: delegate(store, :read_at, [stream, sequence])
  @impl true
  def put_checkpoint(store, checkpoint), do: delegate(store, :put_checkpoint, [checkpoint])
  @impl true
  def latest_checkpoint(store, stream, version),
    do: delegate(store, :latest_checkpoint, [stream, version])

  @impl true
  def read_checkpoint(store, stream, sequence, version),
    do: delegate(store, :read_checkpoint, [stream, sequence, version])

  @impl true
  def pending(store, stream, limit), do: delegate(store, :pending, [stream, limit])
  @impl true
  def read_ack(store, id), do: delegate(store, :read_ack, [id])
  @impl true
  def ack(store, id, nonce), do: delegate(store, :ack, [id, nonce])
  @impl true
  def read_maintenance(store, stream, operation),
    do: delegate(store, :read_maintenance, [stream, operation])

  @impl true
  def repair_torn_tail(store, stream, expected, nonce, digest),
    do: delegate(store, :repair_torn_tail, [stream, expected, nonce, digest])

  @impl true
  def append(store, stream, expected, records, items) do
    covered = %{op: "append", stream: stream, digests: digests(records)}
    bound(store, covered, :append, [stream, expected, records, items])
  end

  @impl true
  def retain(store, stream, expected, through, nonce) do
    covered = %{op: "retain", stream: stream, through: through}
    bound(store, covered, :retain, [stream, expected, through, nonce])
  end

  defp delegate(store, operation, args) do
    {module, _} = inner = inner(store)
    apply(module, operation, [inner | args])
  end

  # A missing or failed setting is never a reason to skip the write path: the database
  # trigger then refuses the write, which the inner Store reports conservatively.
  defp bound({__MODULE__, opts} = store, covered, operation, args) do
    repo = opts.repo

    if in_transaction?(repo) do
      delegate(store, operation, args)
    else
      value = encode(Map.merge(opts.attribution, covered))

      try do
        repo.checkout(fn ->
          put(repo, value)

          try do
            delegate(store, operation, args)
          after
            put(repo, "")
          end
        end)
      rescue
        error in [DBConnection.ConnectionError, Postgrex.Error] ->
          _ = error
          unknown(operation, args, :unavailable)

        _ ->
          unknown(operation, args, :exception)
      catch
        :exit, {:timeout, _} -> unknown(operation, args, :timeout)
        :exit, _ -> unknown(operation, args, :exit)
        _, _ -> unknown(operation, args, :exception)
      end
    end
  end

  # The request identity the inner PostgreSQL Store reports for the same call.
  defp unknown(:append, [stream, expected, records, _], cause) do
    info = %{
      operation: :append,
      stream: stream,
      expected: expected,
      target: nil,
      nonce: nil,
      digest: nil
    }

    info =
      try do
        %{
          info
          | target: expected + length(records),
            nonce: hd(records).nonce,
            digest: Codec.hash(Enum.map(records, &Log.canonical_bytes/1))
        }
      rescue
        _ -> info
      end

    Elzoo.DurableLog.Store.unknown(info, cause)
  end

  defp unknown(:retain, [stream, expected, through, nonce], cause) do
    info =
      try do
        Codec.receipt(:retain, stream, expected, through, nonce)
      rescue
        _ -> %{operation: :retain, stream: stream, expected: expected, target: through}
      end

    Elzoo.DurableLog.Store.unknown(info, cause)
  end

  defp in_transaction?(repo) do
    repo.in_transaction?() == true
  rescue
    _ -> false
  end

  defp put(repo, value) do
    SQL.query(repo, "SELECT set_config($1, $2, false)", [@setting, value], log: false)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp digests(records) do
    for %{digest: <<_::256>> = digest} <- records, do: Base.encode16(digest, case: :lower)
  rescue
    _ -> []
  end

  defp encode(value) do
    Jason.encode!(value)
  rescue
    _ -> ""
  end
end
