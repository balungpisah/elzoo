# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Staging do
  @moduledoc """
  Reference host storage for submission bytes: a host-owned process holding
  immutable entries keyed by `{intent_key, binding_digest, manifest_digest}`.
  `lookup_fun/1` gives the 2-arity submission lookup Need for
  `Elzoo.AiBatch.configure/1`; the returned closure captures only the process
  identifier, never the bytes. An entry is written once (a second put of the
  same key with other bytes is refused) and lives as long as the process: after
  a host restart it is gone unless the host persisted it elsewhere. Entries are
  wrapped so that inspecting the process state shows sizes, not content.
  """
  use Agent

  defmodule Entry do
    @moduledoc false
    defstruct [:bytes]

    defimpl Inspect do
      def inspect(e, _), do: "#Elzoo.AiBatch.Staging.Entry<#{byte_size(e.bytes)} bytes>"
    end
  end

  def start_link(opts \\ []), do: Agent.start_link(fn -> %{} end, opts)

  @doc "Stores `bytes` for the admission `a` (as returned by `Elzoo.AiBatch.admit_submit/2`)."
  def put(staging, %{key: key, binding_digest: bd, manifest_digest: md, submission: bytes})
      when is_binary(bytes) do
    Agent.get_and_update(staging, fn entries ->
      case Map.fetch(entries, {key, bd, md}) do
        {:ok, %Entry{bytes: ^bytes}} -> {:ok, entries}
        {:ok, _} -> {{:error, :conflict}, entries}
        :error -> {:ok, Map.put(entries, {key, bd, md}, %Entry{bytes: bytes})}
      end
    end)
  end

  @doc "Removes the entry of an intent (for example after its outcome is recorded)."
  def delete(staging, key, bd, md), do: Agent.update(staging, &Map.delete(&1, {key, bd, md}))

  @doc "The submission lookup Need over this process."
  def lookup_fun(staging) do
    fn key, %{binding_digest: bd, manifest_digest: md} ->
      case Agent.get(staging, &Map.fetch(&1, {key, bd, md})) do
        {:ok, %Entry{bytes: bytes}} -> {:ok, bytes}
        :error -> {:error, :not_found}
      end
    end
  end
end
