# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent.Host do
  @moduledoc """
  Trusted synchronous activation callback. The consumer, not an untrusted request,
  owns this callback and verifies reconciliation, outstanding writes and old-owner
  safety. A grant is for one fresh startup nonce and one exact recovered snapshot.
  """
  @callback activate(term(), map()) :: {:active, pos_integer(), map()} | {:read_only, term()}
end

defmodule Elzoo.EffectIntent.StoreHost do
  @moduledoc """
  Reference host callback over the existing Store, with no second CAS engine.
  Configure a separate host Store view using fold/0 and limits/0. authorize/2 is
  a TRUSTED host function returning :fresh or {:recovered, observed_generation}
  only after its own authoritative verification; it is not a caller-facing API.
  No quiescent-release path is implemented.
  """
  @behaviour Elzoo.EffectIntent.Host
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Store, Record}
  alias Elzoo.EffectIntent.Model

  def fold,
    do: %{
      initial: nil,
      kinds: %{"intent_host" => :state_bearing},
      versions: [1],
      reduce: fn _, "intent_host", 1, b -> b end
    }

  def limits, do: %{max_record_bytes: 512, max_batch_size: 1, max_checkpoint_bytes: 1024}
  def stream(key), do: "intent-host/" <> key

  @impl true
  def activate(%{store: store, authorize: authorize}, request) when is_function(authorize, 2) do
    with true <- valid_request?(request),
         {:ok, head} <- Store.read(store, :head, [stream(request.key)]),
         true <- head.revision < 4096,
         :ok <- authorized(authorize.(request, head.revision), request, head.revision),
         payload =
           Model.binary({1, request.nonce, request.revision, request.digest, head.revision + 1}),
         true <- byte_size(payload) <= 512,
         row = %Record{
           stream: stream(request.key),
           sequence: head.revision + 1,
           kind: "intent_host",
           schema_version: 1,
           payload: payload,
           nonce: request.nonce
         },
         row = %{row | digest: Log.digest(row)},
         write = %{
           operation: :append,
           stream: row.stream,
           expected: head.revision,
           target: row.sequence,
           nonce: row.nonce,
           digest: row.digest
         },
         {:committed, generation} <-
           Store.write(store, :append, [row.stream, head.revision, [row], []], write) do
      {:active, generation, Map.merge(request, %{generation: generation})}
    else
      _ -> {:read_only, :host_reconciliation_required}
    end
  rescue
    _ -> {:read_only, :host_reconciliation_required}
  catch
    _, _ -> {:read_only, :host_reconciliation_required}
  end

  def activate(_, _), do: {:read_only, :host_reconciliation_required}
  defp authorized(:fresh, %{revision: 0}, 0), do: :ok
  defp authorized({:recovered, g}, _, g), do: :ok
  defp authorized(_, _, _), do: :error

  defp valid_request?(%{key: k, nonce: n, revision: r, digest: d} = q),
    do:
      map_size(q) == 4 and is_binary(k) and byte_size(k) == 64 and
        is_binary(n) and byte_size(n) == 16 and is_integer(r) and r in 0..4096 and
        is_binary(d) and byte_size(d) == 32

  defp valid_request?(_), do: false
end
