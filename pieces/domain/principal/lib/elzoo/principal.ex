# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Principal do
  @moduledoc """
  Pure typed principal: validation, one-level delegation that never widens
  authority, and a check against host-supplied epoch and revocation facts.
  A principal value is not authentication evidence. See the bundle README.
  """

  @cure :"Cure.Elzoo.Principal"
  @max_epoch 9_223_372_036_854_775_807
  @max_labels 256
  @max_revoked 1024
  @new_keys [:allowed_scopes, :allowed_spaces, :auth_epoch, :id, :kind, :tenant]
  @delegate_keys [:allowed_scopes, :allowed_spaces, :id]
  @context_keys [:current_epoch, :revoked_ids]
  @kinds %{human: :KindHuman, service: :KindService, agent: :KindAgent}

  defstruct [:kind, :id, :tenant, :auth_epoch, :delegated_by, :allowed_scopes, :allowed_spaces]

  @doc "Builds a `:human` or `:service` principal from exactly its six fields."
  def new(fields) do
    with true <- shape?(fields, @new_keys) || {:error, :shape},
         true <- fields.kind in [:human, :service] || {:error, :kind},
         true <- text?(fields.id) || {:error, :id},
         true <- text?(fields.tenant) || {:error, :tenant},
         true <- epoch?(fields.auth_epoch) || {:error, :auth_epoch},
         {:ok, scopes} <- labels(fields.allowed_scopes, :scopes),
         {:ok, spaces} <- labels(fields.allowed_spaces, :spaces) do
      {:ok,
       %__MODULE__{
         kind: fields.kind,
         id: fields.id,
         tenant: fields.tenant,
         auth_epoch: fields.auth_epoch,
         delegated_by: nil,
         allowed_scopes: scopes,
         allowed_spaces: spaces
       }}
    end
  end

  @doc "Delegates to an agent whose scopes and spaces the parent holds; refused whole otherwise."
  def delegate(parent, fields) do
    with true <- valid?(parent) || {:error, :parent},
         true <- cure(:delegable, [@kinds[parent.kind]]) || {:error, :nested_delegation},
         true <- shape?(fields, @delegate_keys) || {:error, :shape},
         true <- text?(fields.id) || {:error, :id},
         true <- fields.id != parent.id || {:error, :self_delegation},
         {:ok, scopes} <- labels(fields.allowed_scopes, :scopes),
         {:ok, spaces} <- labels(fields.allowed_spaces, :spaces) do
      case cure(:delegate, [
             bytes(parent.allowed_scopes),
             bytes(parent.allowed_spaces),
             bytes(scopes),
             bytes(spaces)
           ]) do
        {:Granted, scopes, spaces} ->
          {:ok,
           %__MODULE__{
             kind: :agent,
             id: fields.id,
             tenant: parent.tenant,
             auth_epoch: parent.auth_epoch,
             delegated_by: parent.id,
             allowed_scopes: Enum.map(scopes, &:binary.list_to_bin/1),
             allowed_spaces: Enum.map(spaces, &:binary.list_to_bin/1)
           }}

        :Escalation ->
          {:error, :escalation}
      end
    end
  end

  @doc "Checks a principal against the host's current epoch and revoked IDs."
  def check(principal, context) do
    cond do
      not valid?(principal) ->
        {:error, :malformed}

      not context?(context) ->
        {:error, :malformed}

      principal.id in context.revoked_ids ->
        {:error, :revoked}

      principal.kind == :agent and principal.delegated_by in context.revoked_ids ->
        {:error, :revoked}

      principal.auth_epoch < context.current_epoch ->
        {:error, :stale}

      true ->
        :ok
    end
  end

  @doc "`:ok` only for a valid `:human` principal."
  def require_human(principal) do
    cond do
      not valid?(principal) -> {:error, :malformed}
      cure(:human, [@kinds[principal.kind]]) -> :ok
      true -> {:error, :not_human}
    end
  end

  # Revalidates every field and invariant of a struct, also one built by hand.
  defp valid?(
         %__MODULE__{
           kind: kind,
           id: id,
           tenant: tenant,
           auth_epoch: epoch,
           delegated_by: by,
           allowed_scopes: scopes,
           allowed_spaces: spaces
         } = principal
       ) do
    map_size(principal) == 8 and delegation?(kind, by) and text?(id) and text?(tenant) and
      epoch?(epoch) and canonical?(scopes) and canonical?(spaces)
  end

  defp valid?(_), do: false

  defp delegation?(kind, nil) when kind in [:human, :service], do: true
  defp delegation?(:agent, by), do: text?(by)
  defp delegation?(_, _), do: false

  defp context?(context) do
    shape?(context, @context_keys) and epoch?(context.current_epoch) and
      within?(context.revoked_ids, @max_revoked) and Enum.all?(context.revoked_ids, &text?/1)
  end

  # A plain atom-keyed map with exactly these keys; a struct is refused.
  defp shape?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp shape?(_, _), do: false

  defp labels(list, reason) do
    if within?(list, @max_labels) and Enum.all?(list, &text?/1),
      do: {:ok, :lists.usort(list)},
      else: {:error, reason}
  end

  defp canonical?(list),
    do: within?(list, @max_labels) and Enum.all?(list, &text?/1) and :lists.usort(list) == list

  # A proper list of at most n entries.
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  defp epoch?(n), do: is_integer(n) and n >= 0 and n <= @max_epoch

  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  defp bytes(labels), do: Enum.map(labels, &:binary.bin_to_list/1)

  defp cure(function, args), do: apply(@cure, function, args)
end
