# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Membership do
  @moduledoc """
  Pure resolution of the permissions a principal holds at one space at one
  injected time, from host-supplied spaces, roles, memberships and
  non-inheriting prefixes. No I/O, clock, storage or authorization decision.
  See the bundle README.
  """

  alias Elzoo.Principal

  @cure :"Cure.Elzoo.Membership"
  @max_time 9_223_372_036_854_775_807
  @max_depth 32
  @facts_keys [:memberships, :non_inheriting, :roles, :spaces]
  @space_keys [:block_inheritance, :id, :parent, :tenant]
  @role_keys [:id, :permissions]
  @membership_keys [:principal, :revoked_at, :role, :space, :valid_from, :valid_to]

  @doc "The sorted permissions `principal` holds at `space_id` at `now_unix_s`."
  def permissions(principal, space_id, facts, now_unix_s) do
    with :ok <- principal(principal),
         :ok <- now(now_unix_s),
         {:ok, index} <- facts(facts),
         true <-
           (text?(space_id) and Map.has_key?(index.spaces, space_id)) || {:error, :unknown_space},
         true <- tenant(index, space_id) == principal.tenant || {:error, :cross_tenant} do
      {:ok, resolve(principal, space_id, index, grants(principal, index, now_unix_s, nil))}
    end
  end

  @doc "The sorted space IDs of the principal's tenant where `permission` is in `permissions/4`."
  def spaces(principal, permission, facts, now_unix_s) do
    with :ok <- principal(principal),
         :ok <- now(now_unix_s),
         {:ok, index} <- facts(facts),
         true <- text?(permission) || {:error, :permission} do
      grants = grants(principal, index, now_unix_s, permission)

      ids =
        for {id, %{tenant: tenant}} <- index.spaces,
            tenant == principal.tenant,
            permission in resolve(principal, id, index, grants),
            do: id

      {:ok, Enum.sort(ids)}
    end
  end

  # ---------------------------------------------------------------- resolution

  # Active memberships of the authority owner in the principal's tenant, as a
  # map from membership space to the permissions its roles hold there.
  # `only` restricts the permissions to one label for spaces/4.
  defp grants(principal, index, now, only) do
    owner = if principal.kind == :agent, do: principal.delegated_by, else: principal.id

    for m <- index.memberships,
        m.principal == owner,
        active?(m, now),
        tenant(index, m.space) == principal.tenant,
        reduce: %{} do
      acc ->
        held = Map.fetch!(index.roles, m.role)
        held = if only, do: Enum.filter(held, &(&1 == only)), else: held
        Map.update(acc, m.space, held, &(held ++ &1))
    end
  end

  defp active?(m, now) do
    m.valid_from <= now and (m.valid_to == nil or now < m.valid_to) and
      (m.revoked_at == nil or now < m.revoked_at)
  end

  defp resolve(%Principal{kind: :agent} = agent, space, index, grants) do
    if space in agent.allowed_spaces,
      do: Enum.filter(inherited(space, index, grants), &(&1 in agent.allowed_scopes)),
      else: []
  end

  defp resolve(_principal, space, index, grants), do: inherited(space, index, grants)

  # Walks from the target D up to its root. `path` holds the block_inheritance
  # flags of the spaces from D up to, but excluding, the current space M.
  defp inherited(space, index, grants), do: inherited(space, [], index, grants, [])

  defp inherited(nil, _path, _index, _grants, acc), do: :lists.usort(acc)

  defp inherited(m, path, index, grants, acc) do
    node = Map.fetch!(index.spaces, m)
    open = cure(:flows, [path, false])
    local = cure(:flows, [path, true])

    held =
      grants
      |> Map.get(m, [])
      |> Enum.filter(&if(local_only?(&1, index.prefixes), do: local, else: open))

    inherited(node.parent, path ++ [node.block_inheritance], index, grants, held ++ acc)
  end

  defp local_only?(permission, prefixes) do
    Enum.any?(prefixes, &(:binary.longest_common_prefix([permission, &1]) == byte_size(&1)))
  end

  defp tenant(index, space), do: Map.fetch!(index.spaces, space).tenant

  # ---------------------------------------------------------------- validation

  # Revalidated only through the public ELZ-267 API; every valid epoch is >= 0.
  defp principal(principal) do
    if Principal.check(principal, %{current_epoch: 0, revoked_ids: []}) == :ok,
      do: :ok,
      else: {:error, :principal}
  end

  defp now(now), do: if(time?(now), do: :ok, else: {:error, :now})

  defp facts(facts) do
    with true <- shape?(facts, @facts_keys),
         {:ok, spaces} <- spaces_index(facts.spaces),
         {:ok, roles} <- roles_index(facts.roles),
         {:ok, memberships} <- memberships(facts.memberships, spaces, roles),
         true <- within?(facts.non_inheriting, 16) and Enum.all?(facts.non_inheriting, &text?/1) do
      {:ok,
       %{spaces: spaces, roles: roles, memberships: memberships, prefixes: facts.non_inheriting}}
    else
      _ -> {:error, :facts}
    end
  end

  defp spaces_index(list) do
    with true <- list != [] and within?(list, 1024),
         true <- Enum.all?(list, &space?/1),
         index = Map.new(list, &{&1.id, Map.take(&1, [:tenant, :parent, :block_inheritance])}),
         true <- map_size(index) == length(list),
         true <- Enum.all?(Map.keys(index), &rooted?(&1, index, 1)) do
      {:ok, index}
    end
  end

  defp space?(s) do
    shape?(s, @space_keys) and text?(s.id) and text?(s.tenant) and
      (s.parent == nil or text?(s.parent)) and is_boolean(s.block_inheritance)
  end

  # The parent exists in the same tenant and the root is at most 32 spaces up;
  # a cycle never reaches a root, so it exceeds the depth.
  defp rooted?(_id, _index, depth) when depth > @max_depth, do: false

  defp rooted?(id, index, depth) do
    %{tenant: tenant, parent: parent} = Map.fetch!(index, id)

    case parent do
      nil -> true
      _ -> match?(%{tenant: ^tenant}, index[parent]) and rooted?(parent, index, depth + 1)
    end
  end

  defp roles_index(list) do
    with true <- within?(list, 256),
         true <- Enum.all?(list, &role?/1),
         index = Map.new(list, &{&1.id, :lists.usort(&1.permissions)}),
         true <- map_size(index) == length(list) do
      {:ok, index}
    end
  end

  defp role?(r) do
    shape?(r, @role_keys) and text?(r.id) and within?(r.permissions, 256) and
      Enum.all?(r.permissions, &text?/1)
  end

  defp memberships(list, spaces, roles) do
    with true <- within?(list, 1024),
         true <- Enum.all?(list, &membership?(&1, spaces, roles)) do
      {:ok, Enum.uniq(list)}
    end
  end

  defp membership?(m, spaces, roles) do
    shape?(m, @membership_keys) and text?(m.principal) and text?(m.space) and
      Map.has_key?(spaces, m.space) and text?(m.role) and Map.has_key?(roles, m.role) and
      time?(m.valid_from) and
      (m.valid_to == nil or (time?(m.valid_to) and m.valid_to > m.valid_from)) and
      (m.revoked_at == nil or time?(m.revoked_at))
  end

  # A plain atom-keyed map with exactly these keys; a struct is refused.
  defp shape?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp shape?(_, _), do: false

  # A proper list of at most n entries.
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  defp time?(n), do: is_integer(n) and n >= 0 and n <= @max_time

  # The ELZ-267 text rule: 1..128 bytes of valid UTF-8 without C0 or C1 controls.
  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  defp cure(function, args), do: apply(@cure, function, args)
end
