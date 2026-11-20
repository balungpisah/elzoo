# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.KillSwitch do
  @moduledoc """
  Tenant, recipe and tool suspension over one `"switches"` field of a tenant
  control resource.

  `prepare/3` is a pure `Elzoo.CheckedCommand` preparer that engages or
  releases one switch; `check/2` is a pure decision over the exact return value
  of `Elzoo.CheckedCommand.resource/3` that a host gate calls. `engage/2` and
  `release/2` are the list transitions behind `prepare/3`. No I/O, clock,
  process, storage, telemetry or log.
  """

  @field "switches"
  @max_switches 64
  @max_ms 9_223_372_036_854_775_807
  @max_revision @max_ms - 1
  @kinds ["recipe", "tenant", "tool"]
  @unavailable {:deny, "kill_switch_unavailable"}
  @cure :"Cure.Elzoo.KillSwitch"

  @doc "CheckedCommand preparer: engage or release one switch."
  def prepare(snapshot, request, facts) do
    with {:ok, tenant, revision, list} <- snapshot(snapshot),
         {:ok, target} <- request_target(request, snapshot),
         {:ok, op, {kind, id, reason} = key} <- payload(request),
         {:ok, now} <- now(facts) do
      cond do
        String.starts_with?(reason, "lifecycle") ->
          {:refused, "reserved_reason"}

        kind == "tenant" and id != tenant ->
          {:refused, "cross_tenant"}

        true ->
          case transition(op, list, key, now) do
            {:ok, {:list, switches} = next} ->
              {:ok, [%{target: target, field: @field, value: next}],
               {:record, [{"engaged", length(switches)}, {"revision", revision + 1}]}}

            {:error, reason} ->
              {:refused, Atom.to_string(reason)}
          end
      end
    else
      _ -> {:refused, "invalid_request"}
    end
  end

  @doc "Add one switch record to a canonical `{:list, switches}` value."
  def engage(list, switch) do
    with {:ok, entries} <- entries(list),
         {:ok, key} <- switch_key(switch) do
      cond do
        List.keymember?(entries, key, 0) -> {:error, :already_engaged}
        length(entries) >= @max_switches -> {:error, :too_many}
        true -> {:ok, encode(List.keysort([{key, switch} | entries], 0))}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  @doc "Remove the switch with key `{kind, id, reason}` from a canonical list."
  def release(list, key) do
    with {:ok, entries} <- entries(list),
         true <- key?(key) do
      if List.keymember?(entries, key, 0),
        do: {:ok, encode(List.keydelete(entries, key, 0))},
        else: {:error, :not_engaged}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc "Gate decision over a `CheckedCommand.resource/3` read; never raises."
  def check(read, target) do
    flags =
      with {:ok, %{tenant: tenant, resource: _, revision: _, fields: fields} = view} <- read,
           true <- map_size(view) == 4 and is_map(fields) and not is_struct(fields),
           %{tenant: ^tenant, recipe: recipe, tool: tool} <- target,
           true <-
             map_size(target) == 3 and text?(tenant) and optional?(recipe) and optional?(tool),
           {:ok, entries} <- entries(Map.get(fields, @field, {:list, []})) do
        [
          true,
          engaged?(entries, "tenant", tenant),
          engaged?(entries, "recipe", recipe),
          engaged?(entries, "tool", tool)
        ]
      else
        _ -> [false, false, false, false]
      end

    case apply(@cure, :verdict, flags) do
      :KillAllow -> :allow
      :KillTenantSuspended -> {:deny, "tenant_suspended"}
      :KillRecipeSuspended -> {:deny, "recipe_suspended"}
      :KillToolSuspended -> {:deny, "tool_suspended"}
      _ -> @unavailable
    end
  end

  defp transition("engage", list, {kind, id, reason}, now),
    do:
      engage(
        list,
        {:record,
         [
           {"engaged_at", now},
           {"id", {:text, id}},
           {"kind", {:text, kind}},
           {"reason", {:text, reason}}
         ]}
      )

  defp transition("release", list, key, _now), do: release(list, key)

  defp snapshot(%{tenant: tenant, resource: resource, revision: revision, fields: fields} = s)
       when map_size(s) == 4 and is_integer(revision) and revision >= 0 and
              revision <= @max_revision and is_map(fields) and not is_struct(fields) do
    list = Map.get(fields, @field, {:list, []})

    if text?(tenant) and text?(resource) and match?({:ok, _}, entries(list)),
      do: {:ok, tenant, revision, list},
      else: :error
  end

  defp snapshot(_), do: :error

  defp request_target(
         %{operation_id: _, resource: resource, expected_revision: _, payload: _} = request,
         %{resource: resource}
       )
       when map_size(request) == 4,
       do: {:ok, resource}

  defp request_target(_, _), do: :error

  defp payload(%{payload: %{"op" => op, "kind" => kind, "id" => id, "reason" => reason} = p})
       when map_size(p) == 4 and op in ["engage", "release"] do
    if key?({kind, id, reason}), do: {:ok, op, {kind, id, reason}}, else: :error
  end

  defp payload(_), do: :error

  defp now(%{tenant: _, actor: _, data: {:record, [{"now", now}]}} = facts)
       when map_size(facts) == 3 and is_integer(now) and now >= 0 and now <= @max_ms,
       do: {:ok, now}

  defp now(_), do: :error

  # Decodes a canonical field value into `[{key, switch}]` in strictly
  # ascending key order (sorted and unique), at most 64 entries.
  defp entries({:list, switches}) when is_list(switches) do
    Enum.reduce_while(switches, {:ok, [], nil, 0}, fn switch, {:ok, acc, previous, count} ->
      case switch_key(switch) do
        {:ok, key} when count < @max_switches and (previous == nil or previous < key) ->
          {:cont, {:ok, [{key, switch} | acc], key, count + 1}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc, _, _} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  catch
    # An improper list makes Enum.reduce_while/3 raise.
    _, _ -> :error
  end

  defp entries(_), do: :error

  defp switch_key(
         {:record,
          [
            {"engaged_at", at},
            {"id", {:text, id}},
            {"kind", {:text, kind}},
            {"reason", {:text, reason}}
          ]}
       )
       when is_integer(at) and at >= 0 and at <= @max_ms do
    if key?({kind, id, reason}), do: {:ok, {kind, id, reason}}, else: :error
  end

  defp switch_key(_), do: :error

  defp encode(entries), do: {:list, Enum.map(entries, &elem(&1, 1))}

  defp key?({kind, id, reason}), do: kind in @kinds and text?(id) and code?(reason)
  defp key?(_), do: false

  defp engaged?(_entries, _kind, nil), do: false
  defp engaged?(entries, kind, id), do: Enum.any?(entries, &match?({{^kind, ^id, _}, _}, &1))

  defp optional?(nil), do: true
  defp optional?(id), do: text?(id)

  # The domain/principal text rule: 1..128 bytes of UTF-8 without a C0 or C1
  # control character (U+0000-U+001F, U+007F-U+009F).
  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  # The gate code rule of both engines: 1..64 bytes of [a-z0-9_].
  defp code?(c), do: is_binary(c) and byte_size(c) in 1..64 and lowercase_code?(c)

  defp lowercase_code?(<<>>), do: true

  defp lowercase_code?(<<c, rest::binary>>) when c in ?a..?z or c in ?0..?9 or c == ?_,
    do: lowercase_code?(rest)

  defp lowercase_code?(_), do: false
end
