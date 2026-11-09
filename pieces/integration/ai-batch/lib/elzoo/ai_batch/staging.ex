# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.SubmissionStore do
  @moduledoc """
  The submission lookup capability of `Elzoo.AiBatch.configure/1`: the Config
  holds only `{module, server}`, where `module` implements this behaviour and
  `server` is a pid or a registered name (an atom), so the Config (the
  EffectIntent `adapter_context`) cannot carry the staged bytes or a closure
  holding them. The bytes live in the host's process.

  `fetch(server, intent_key, %{binding_digest, manifest_digest})` returns
  `{:ok, bytes}`, the exact provider create body staged for that intent, or any
  other value when there is none.
  """
  @callback fetch(server :: pid() | atom(), key :: String.t(), digests :: map()) ::
              {:ok, binary()} | term()

  @doc false
  def valid?({module, server}) when is_atom(module) and (is_pid(server) or is_atom(server)) do
    Code.ensure_loaded?(module) and function_exported?(module, :fetch, 3) and
      server not in [nil, true, false]
  end

  def valid?(_), do: false
end

defmodule Elzoo.AiBatch.Staging do
  @moduledoc """
  Reference host store for the exact provider create bodies of admitted
  submissions (`Elzoo.AiBatch.SubmissionStore`): a host-owned process holding
  immutable entries keyed by `{intent_key, binding_digest, manifest_digest}`.
  Configure `submissions: {Elzoo.AiBatch.Staging, pid_or_name}`. An entry is
  written once (a second put of the same key with other bytes is refused) and
  lives as long as the process: after a host restart it is gone unless the host
  persisted it elsewhere. Entries are wrapped so that inspecting the process
  state shows sizes, not content.
  """
  use Agent
  @behaviour Elzoo.AiBatch.SubmissionStore

  defmodule Entry do
    @moduledoc false
    defstruct [:bytes]

    defimpl Inspect do
      def inspect(e, _), do: "#Elzoo.AiBatch.Staging.Entry<#{byte_size(e.bytes)} bytes>"
    end
  end

  def start_link(opts \\ []), do: Agent.start_link(fn -> %{} end, opts)

  @doc "Stages the exact create body of the admission `a` (as returned by `Elzoo.AiBatch.admit_submit/2`)."
  def put(staging, %{key: key, binding_digest: bd, manifest_digest: md, staged: bytes})
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

  @impl true
  def fetch(staging, key, %{binding_digest: bd, manifest_digest: md}) do
    case Agent.get(staging, &Map.fetch(&1, {key, bd, md})) do
      {:ok, %Entry{bytes: bytes}} -> {:ok, bytes}
      :error -> {:error, :not_found}
    end
  end
end
