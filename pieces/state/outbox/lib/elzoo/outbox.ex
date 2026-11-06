# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Outbox do
  @moduledoc """
  Committed pending offers and nonce-bound acknowledgement CAS. No dispatch.
  Store options carry the consumer's fold.destinations table and record-size limits.
  """
  alias Elzoo.DurableLog.{Codec, Store}

  defmodule Item do
    @moduledoc "An immutable committed item plus acknowledgement state."
    defstruct [
      :stream,
      :sequence,
      :position,
      :destination,
      :idempotency_key,
      :payload,
      :nonce,
      :digest,
      :ack_nonce,
      :ack_digest,
      state: :pending
    ]
  end

  def new(stream, sequence, position, destination, payload, nonce) do
    item = %Item{
      stream: stream,
      sequence: sequence,
      position: position,
      destination: destination,
      payload: payload,
      nonce: nonce,
      idempotency_key: Codec.item_key(stream, sequence, position)
    }

    %{item | digest: Codec.hash(Codec.item_bytes(item))}
  end

  def parse_id(id), do: Codec.parse_key(id)

  def pending(store, stream, limit) do
    with {:ok, rows} <- Store.read(store, :pending, [stream, limit]),
         {:ok, head} <- Store.read(store, :head, [stream]) do
      if Enum.all?(
           rows,
           &(Codec.item_valid?(&1) and &1.stream == stream and &1.state == :pending and
               &1.sequence > head.low_water and &1.sequence <= head.revision and
               declared?(store, &1))
         ) and
           length(Enum.uniq_by(rows, & &1.idempotency_key)) == length(rows) and
           length(rows) <= limit do
        {:ok, Enum.sort_by(rows, &{&1.sequence, &1.position})}
      else
        {:error, :malformed}
      end
    end
  end

  defp declared?(
         {_, %{fold: %{destinations: destinations}, limits: %{max_record_bytes: max}}},
         item
       ),
       do: item.destination in destinations and byte_size(item.payload) <= max

  defp declared?(_, _), do: false

  def ack(store, id, nonce) do
    with {:ok, _} <- Codec.parse_key(id), true <- Codec.nonce?(nonce) do
      request = Codec.ack_receipt(id, nonce)
      Store.write(store, :ack, [id, nonce], request)
    else
      _ -> {:rejected, :invalid_outbox_item}
    end
  end
end
