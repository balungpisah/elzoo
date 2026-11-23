# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Delegation do
  @moduledoc """
  Pure child-Run grant: a principal delegated from the root (one level), the
  parent's effective authority, a budget share, depth and cycle refusals over
  the lineage, revocations, the inherited or changed pin and a parent-close
  rule; and what the host does to each open child of an ended parent. Every
  fact is host-vouched. See the bundle README.
  """

  alias Elzoo.{Authorization, Principal}

  @facts_keys [
    :authority,
    :budget_remaining,
    :lineage,
    :max_depth,
    :parent,
    :pin,
    :revoked_ids,
    :root
  ]
  @request_keys [:budget, :change, :child_bot, :parent_close, :scopes, :spaces]
  @change_keys [:pin, :ref]
  @child_keys [:child_run_id, :parent_close]
  @rules [:abandon, :request_cancel, :cancel]
  @max_lineage 8
  @max_labels 256
  @max_revoked 1024
  @max_children 256
  @no_facts %{current_epoch: 0, revoked_ids: []}

  @doc "Decides a child grant from trusted parent facts and one request, or refuses it whole."
  def grant(facts, request) do
    with {:ok, authority} <- well_formed(facts, request),
         :ok <- not_revoked(facts, request),
         :ok <- current(facts),
         :ok <- within_depth(facts),
         :ok <- acyclic(facts, request),
         :ok <- held(facts.parent, request),
         :ok <- budget(facts, request),
         :ok <- version_change(request.change),
         {:ok, principal} <- delegate(facts.root, request) do
      {:ok,
       %{
         principal: principal,
         parent_authority: authority,
         budget: request.budget,
         depth: length(facts.lineage) + 1,
         lineage: facts.lineage ++ [request.child_bot],
         pin: if(request.change, do: request.change.pin, else: facts.pin),
         change_ref: request.change && request.change.ref,
         parent_close: request.parent_close || :request_cancel
       }}
    end
  end

  @doc "One action per open child of an ended parent, in order, or `{:error, :malformed}`."
  def on_parent_close(children) do
    if within?(children, @max_children) and Enum.all?(children, &child?/1) and
         distinct?(Enum.map(children, & &1.child_run_id)),
       do: {:ok, Enum.map(children, &action/1)},
       else: {:error, :malformed}
  end

  defp action(%{child_run_id: id, parent_close: :request_cancel}),
    do: %{
      child_run_id: id,
      action: :request_cancel,
      message: %{"child_run_id" => id, "reason" => "parent_closed"}
    }

  defp action(%{child_run_id: id, parent_close: rule}), do: %{child_run_id: id, action: rule}

  defp child?(child),
    do: shape?(child, @child_keys) and run_id?(child.child_run_id) and child.parent_close in @rules

  # Rule 1: every shape, bound and consistency fact; the validated authority.
  defp well_formed(facts, request) do
    with true <- shape?(facts, @facts_keys) and shape?(request, @request_keys),
         true <- root?(facts.root) and parent?(facts.parent, facts.root),
         true <- lineage?(facts.lineage, facts.parent, facts.root),
         true <- is_integer(facts.budget_remaining) and facts.budget_remaining >= 0,
         true <- is_integer(facts.max_depth) and facts.max_depth in 1..@max_lineage,
         true <- within?(facts.revoked_ids, @max_revoked) and Enum.all?(facts.revoked_ids, &text?/1),
         true <- pin?(facts.pin),
         true <- request?(request),
         {:ok, authority} <- Authorization.validate_authority(facts.authority) do
      {:ok, authority}
    else
      _ -> {:error, :malformed}
    end
  end

  defp root?(root), do: Principal.check(root, @no_facts) == :ok and root.kind in [:human, :service]

  defp parent?(root, root), do: true

  defp parent?(parent, root),
    do:
      Principal.check(parent, @no_facts) == :ok and parent.kind == :agent and
        parent.delegated_by == root.id and parent.tenant == root.tenant

  defp lineage?(lineage, parent, root) do
    within?(lineage, @max_lineage) and Enum.all?(lineage, &text?/1) and distinct?(lineage) and
      if(parent == root, do: lineage == [], else: List.last(lineage) == parent.id)
  end

  defp request?(request) do
    text?(request.child_bot) and labels?(request.scopes) and labels?(request.spaces) and
      is_integer(request.budget) and request.parent_close in [nil | @rules] and
      change?(request.change)
  end

  defp change?(nil), do: true
  defp change?(change), do: shape?(change, @change_keys) and pin?(change.pin)

  # Rule 2: the lineage is where a revoked middle bot is seen.
  defp not_revoked(%{root: root, parent: parent, lineage: lineage, revoked_ids: revoked}, request) do
    if root.id in revoked or parent.id in revoked or request.child_bot in revoked or
         Enum.any?(lineage, &(&1 in revoked)),
       do: {:error, :revoked},
       else: :ok
  end

  # Rule 3: an agent parent older than its root's epoch mints no child with the newer epoch.
  defp current(%{root: root, parent: parent}) do
    if parent.kind == :agent and parent.auth_epoch < root.auth_epoch,
      do: {:error, :stale},
      else: :ok
  end

  # Rule 4.
  defp within_depth(facts),
    do: if(length(facts.lineage) + 1 > facts.max_depth, do: {:error, :depth}, else: :ok)

  # Rule 5.
  defp acyclic(facts, request) do
    if request.child_bot == facts.root.id or request.child_bot in facts.lineage,
      do: {:error, :cycle},
      else: :ok
  end

  # Rule 6: exact-byte membership in the parent's own scopes and spaces.
  defp held(parent, request) do
    if Enum.all?(request.scopes, &(&1 in parent.allowed_scopes)) and
         Enum.all?(request.spaces, &(&1 in parent.allowed_spaces)),
       do: :ok,
       else: {:error, :escalation}
  end

  # Rule 7.
  defp budget(facts, request) do
    if request.budget >= 1 and request.budget <= facts.budget_remaining,
      do: :ok,
      else: {:error, :budget}
  end

  # Rule 8: a change needs the reference of the host's authorised, recorded action.
  defp version_change(nil), do: :ok

  defp version_change(%{ref: ref}) do
    if is_binary(ref) and byte_size(ref) in 1..256 and String.valid?(ref) and printable?(ref),
      do: :ok,
      else: {:error, :version_change}
  end

  # Rule 9: one delegation level, always from the root.
  defp delegate(root, request) do
    case Principal.delegate(root, %{
           id: request.child_bot,
           allowed_scopes: request.scopes,
           allowed_spaces: request.spaces
         }) do
      {:ok, principal} -> {:ok, principal}
      {:error, reason} -> {:error, {:principal, reason}}
    end
  end

  # A plain atom-keyed map with exactly these keys; a struct is refused.
  defp shape?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp shape?(_, _), do: false

  defp labels?(list), do: within?(list, @max_labels) and Enum.all?(list, &text?/1)

  # A proper list of at most n entries.
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  defp distinct?(list), do: length(Enum.uniq(list)) == length(list)

  defp pin?(pin), do: is_binary(pin) and byte_size(pin) in 1..128

  # The workflow/run ID rule.
  defp run_id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..200 and String.valid?(id) and
        not String.contains?(id, <<0>>)

  # The domain/principal ID rule.
  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
