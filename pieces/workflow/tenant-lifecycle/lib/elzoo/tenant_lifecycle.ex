# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TenantLifecycle do
  @moduledoc """
  Tenant lifecycle and one-use invitations over the `"lifecycle"`,
  `"invitations"` and `"switches"` fields of a tenant control resource.

  `prepare/3` is a pure `Elzoo.CheckedCommand` preparer; a transition that
  suspends or reactivates the tenant writes the reserved `lifecycle` tenant
  switch through `Elzoo.KillSwitch.engage/2` and `release/2` in the same
  append. `status/1` reads the state from a `CheckedCommand.resource/3` result.
  No I/O, clock, process, storage, telemetry or log.
  """

  alias Elzoo.{KillSwitch, PatternStep}

  @lifecycle "lifecycle"
  @invitations "invitations"
  @switches "switches"
  @reason "lifecycle"
  @states %{
    "provisioned" => :TlProvisioned,
    "active" => :TlActive,
    "suspended" => :TlSuspended,
    "closing" => :TlClosing,
    "erased" => :TlErased
  }
  @commands %{
    "provision" => :TlProvisionCmd,
    "activate" => :TlActivateCmd,
    "suspend" => :TlSuspendCmd,
    "close" => :TlCloseCmd,
    "erase" => :TlEraseCmd,
    "invite" => :TlInviteCmd,
    "accept" => :TlAcceptCmd,
    "revoke" => :TlRevokeCmd
  }
  @lifecycle_ops ~w(provision activate suspend close erase)
  @max_invitations 32
  # Unix seconds whose millisecond value still fits the kill-switch bound 2^63-1.
  @max_s 9_223_372_036_854_775
  @max_revision 9_223_372_036_854_775_806
  @cure :"Cure.Elzoo.TenantLifecycle"

  @doc "CheckedCommand preparer: one lifecycle or invitation command."
  def prepare(snapshot, request, facts) do
    with {:ok, view} <- snapshot(snapshot),
         {:ok, target} <- request_target(request, snapshot),
         {:ok, op, args} <- payload(request),
         {:ok, actor, data} <- facts(facts, op, view.tenant),
         true <- op != "invite" or args.expires_at > data["now"] do
      view = Map.merge(view, %{target: target, actor: actor, data: data})

      case decide(view.state, op) do
        :terminal -> {:refused, "terminal"}
        :invalid_transition -> {:refused, "invalid_transition"}
        :not_active -> {:refused, "not_active"}
        {:move, to, switch} -> move(view, op, to, switch)
        :stay -> invitation(view, op, args)
      end
    else
      _ -> {:refused, "invalid_request"}
    end
  end

  @doc """
  The CheckedCommand gate of the lifecycle descriptor over one
  `CheckedCommand.resource/3` read: it allows the five lifecycle ops without
  `Elzoo.KillSwitch.check/2`, so a suspended tenant can be reactivated, and
  checks every other op like any other gate.
  """
  def gate(read) do
    %{
      call: fn checked, %{tenant: tenant} ->
        case PatternStep.encode(checked) do
          %{"actions" => [%{"payload" => %{"op" => op}}]} when op in @lifecycle_ops -> :allow
          _ -> KillSwitch.check(read, %{tenant: tenant, recipe: nil, tool: nil})
        end
      end
    }
  end

  @doc "The lifecycle state of a `CheckedCommand.resource/3` result; never raises."
  def status({:ok, %{tenant: _, resource: _, revision: _, fields: fields} = view})
      when map_size(view) == 4 and is_map(fields) and not is_struct(fields) do
    case state(fields) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, :unavailable}
    end
  end

  def status(_), do: {:error, :unavailable}

  # ------------------------------------------------------------ decision

  defp decide(state, op) do
    case apply(@cure, :decide, [Map.get(@states, state, :TlNone), Map.fetch!(@commands, op)]) do
      :TlTerminal -> :terminal
      :TlInvalidTransition -> :invalid_transition
      :TlNotActive -> :not_active
      :TlStay -> :stay
      {:TlMove, to, switch} -> {:move, state_text(to), switch}
    end
  end

  defp state_text(atom),
    do:
      Enum.find_value(@states, fn
        {text, ^atom} -> text
        _ -> nil
      end)

  defp move(view, op, to, switch) do
    if op == "erase" and view.data["vault_erased"] != true,
      do: {:refused, "not_erased"},
      else: move_writes(view, op, to, switch)
  end

  defp move_writes(view, op, to, switch) do
    invitations =
      if op == "close" and view.invitations != [],
        do: [write(view.target, @invitations, {:list, []})],
        else: []

    case switch_writes(view, switch) do
      {:ok, switches} ->
        pending = if op == "close", do: 0, else: length(view.invitations)

        {:ok, [write(view.target, @lifecycle, {:text, to}) | invitations ++ switches],
         response(to, pending, view.revision)}

      {:refused, _} = refused ->
        refused
    end
  end

  # Engage keeps a lifecycle switch that is already engaged; release keeps an
  # absent one. Only a changed list is written.
  defp switch_writes(_view, :TlKeep), do: {:ok, []}

  defp switch_writes(view, :TlEngage) do
    switch =
      {:record,
       [
         {"engaged_at", view.data["now"] * 1000},
         {"id", {:text, view.tenant}},
         {"kind", {:text, "tenant"}},
         {"reason", {:text, @reason}}
       ]}

    case KillSwitch.engage(view.switches, switch) do
      {:ok, list} -> {:ok, [write(view.target, @switches, list)]}
      {:error, :already_engaged} -> {:ok, []}
      {:error, :too_many} -> {:refused, "too_many"}
      {:error, _} -> {:refused, "invalid_request"}
    end
  end

  defp switch_writes(view, :TlRelease) do
    case KillSwitch.release(view.switches, {"tenant", view.tenant, @reason}) do
      {:ok, list} -> {:ok, [write(view.target, @switches, list)]}
      {:error, :not_engaged} -> {:ok, []}
      {:error, _} -> {:refused, "invalid_request"}
    end
  end

  defp invitation(view, "invite", args) do
    cond do
      view.data["known_target"] != true or view.data["inviter_may_grant"] != true ->
        {:refused, "not_permitted"}

      List.keymember?(view.invitations, args.id, 0) ->
        {:refused, "duplicate"}

      length(view.invitations) >= @max_invitations ->
        {:refused, "too_many"}

      true ->
        entry = Map.merge(args, %{code_digest: view.data["code_digest"], issued_by: view.actor})
        invitations(view, List.keysort([{args.id, entry} | view.invitations], 0))
    end
  end

  defp invitation(view, "accept", id) do
    now = view.data["now"]

    case List.keyfind(view.invitations, id, 0) do
      nil ->
        {:refused, "unknown_invitation"}

      {_, invitation} ->
        cond do
          now >= invitation.expires_at ->
            {:refused, "expired"}

          not :crypto.hash_equals(invitation.code_digest, view.data["presented_digest"]) ->
            {:refused, "bad_code"}

          invitation.invitee not in [nil, view.actor] ->
            {:refused, "wrong_invitee"}

          true ->
            membership =
              {:record,
               [
                 {"principal", {:text, view.actor}},
                 {"revoked_at", nil},
                 {"role", {:text, invitation.role}},
                 {"space", {:text, invitation.space}},
                 {"valid_from", now},
                 {"valid_to", nil}
               ]}

            {:ok,
             [write(view.target, @invitations, encode(List.keydelete(view.invitations, id, 0)))],
             membership}
        end
    end
  end

  defp invitation(view, "revoke", id) do
    if List.keymember?(view.invitations, id, 0),
      do: invitations(view, List.keydelete(view.invitations, id, 0)),
      else: {:refused, "unknown_invitation"}
  end

  defp invitations(view, entries) do
    {:ok, [write(view.target, @invitations, encode(entries))],
     response(view.state, length(entries), view.revision)}
  end

  defp write(target, field, value), do: %{target: target, field: field, value: value}

  defp response(state, pending, revision),
    do: {:record, [{"lifecycle", {:text, state}}, {"pending", pending}, {"revision", revision + 1}]}

  # ------------------------------------------------------------ shape

  defp snapshot(%{tenant: tenant, resource: resource, revision: revision, fields: fields} = s)
       when map_size(s) == 4 and is_integer(revision) and revision >= 0 and
              revision <= @max_revision and is_map(fields) and not is_struct(fields) do
    switches = Map.get(fields, @switches, {:list, []})

    with true <- text?(tenant) and text?(resource),
         {:ok, state} <- state(fields),
         {:ok, invitations} <- entries(Map.get(fields, @invitations, {:list, []})),
         # A malformed stored switches list is refused by every command.
         false <- KillSwitch.release(switches, {"tenant", tenant, @reason}) == {:error, :invalid} do
      {:ok,
       %{
         tenant: tenant,
         revision: revision,
         state: state,
         invitations: invitations,
         switches: switches
       }}
    else
      _ -> :error
    end
  end

  defp snapshot(_), do: :error

  defp state(fields) do
    case Map.fetch(fields, @lifecycle) do
      :error -> {:ok, "none"}
      {:ok, {:text, state}} when is_map_key(@states, state) -> {:ok, state}
      _ -> :error
    end
  end

  defp request_target(
         %{operation_id: _, resource: resource, expected_revision: _, payload: _} = request,
         %{resource: resource}
       )
       when map_size(request) == 4,
       do: {:ok, resource}

  defp request_target(_, _), do: :error

  defp payload(%{payload: %{"op" => op} = p}) when is_map_key(@commands, op) and not is_struct(p) do
    case {op, p} do
      {op, p} when map_size(p) == 1 and op in ~w(provision activate suspend close erase) ->
        {:ok, op, nil}

      {op, %{"id" => id}} when map_size(p) == 2 and op in ~w(accept revoke) ->
        if text?(id), do: {:ok, op, id}, else: :error

      {"invite",
       %{
         "id" => id,
         "space" => space,
         "role" => role,
         "invitee" => invitee,
         "expires_at" => expires_at
       }}
      when map_size(p) == 6 ->
        if text?(id) and text?(space) and text?(role) and (invitee == nil or text?(invitee)) and
             time?(expires_at),
           do:
             {:ok, op,
              %{id: id, space: space, role: role, invitee: invitee, expires_at: expires_at}},
           else: :error

      _ ->
        :error
    end
  end

  defp payload(_), do: :error

  defp facts(%{tenant: tenant, actor: actor, data: {:record, pairs}} = facts, op, tenant)
       when map_size(facts) == 3 do
    keys =
      case op do
        "erase" -> ["now", "vault_erased"]
        "invite" -> ["code_digest", "inviter_may_grant", "known_target", "now"]
        "accept" -> ["now", "presented_digest"]
        _ -> ["now"]
      end

    with true <- text?(actor) and proper?(pairs) and Enum.all?(pairs, &match?({_, _}, &1)),
         sorted = List.keysort(pairs, 0),
         ^keys <- Enum.map(sorted, &elem(&1, 0)),
         data = Map.new(sorted),
         true <- time?(data["now"]),
         {:ok, data} <- digests(data) do
      {:ok, actor, data}
    else
      _ -> :error
    end
  end

  defp facts(_, _, _), do: :error

  # Digests are exactly 32 bytes; they are unwrapped for :crypto.hash_equals/2.
  defp digests(data) do
    Enum.reduce_while(~w(code_digest presented_digest), {:ok, data}, fn key, {:ok, acc} ->
      case Map.fetch(acc, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, {:bytes, <<_::256>> = digest}} -> {:cont, {:ok, Map.put(acc, key, digest)}}
        _ -> {:halt, :error}
      end
    end)
  end

  # Decodes a stored invitations value into `[{id, invitation}]` in strictly
  # ascending ID order, at most 32 entries.
  defp entries({:list, items}) do
    if proper?(items) and length(items) <= @max_invitations do
      decoded = Enum.map(items, &invitation_record/1)

      with false <- :error in decoded,
           ids = Enum.map(decoded, &elem(&1, 0)),
           true <- ids == Enum.uniq(Enum.sort(ids)) do
        {:ok, decoded}
      else
        _ -> :error
      end
    else
      :error
    end
  end

  defp entries(_), do: :error

  defp invitation_record(
         {:record,
          [
            {"code_digest", {:bytes, <<_::256>> = digest}},
            {"expires_at", expires_at},
            {"id", {:text, id}},
            {"invitee", invitee},
            {"issued_by", {:text, issued_by}},
            {"role", {:text, role}},
            {"space", {:text, space}}
          ]}
       ) do
    invitee =
      case invitee do
        nil -> {:ok, nil}
        {:text, p} -> if text?(p), do: {:ok, p}, else: :error
        _ -> :error
      end

    with {:ok, invitee} <- invitee,
         true <- time?(expires_at) and text?(id) and text?(issued_by) and text?(role),
         true <- text?(space) do
      {id,
       %{
         id: id,
         space: space,
         role: role,
         invitee: invitee,
         expires_at: expires_at,
         code_digest: digest,
         issued_by: issued_by
       }}
    else
      _ -> :error
    end
  end

  defp invitation_record(_), do: :error

  defp encode(entries) do
    {:list,
     Enum.map(entries, fn {_, i} ->
       {:record,
        [
          {"code_digest", {:bytes, i.code_digest}},
          {"expires_at", i.expires_at},
          {"id", {:text, i.id}},
          {"invitee", if(i.invitee, do: {:text, i.invitee})},
          {"issued_by", {:text, i.issued_by}},
          {"role", {:text, i.role}},
          {"space", {:text, i.space}}
        ]}
     end)}
  end

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  defp time?(t), do: is_integer(t) and t >= 0 and t <= @max_s

  # The domain/principal text rule: 1..128 bytes of UTF-8 without a C0 or C1
  # control character (U+0000-U+001F, U+007F-U+009F).
  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
