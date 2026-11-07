# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ContextSelection do
  @moduledoc """
  Pure context selection over a host-owned access/provenance snapshot.

  `select/2` is the only supported entry. The host owns every context setting,
  current check and snapshot clock. Request data contains only candidates.
  Retrieval evidence vetoes but never grants access. Native Cure helpers are
  not a security boundary, even when declared local in Cure.
  """
  @cure :"Cure.Elzoo.ContextSelection"
  @amount_max 9_007_199_254_740_991
  @version_max 2_147_483_647
  @context [
    :principal,
    :tenant,
    :now,
    :snapshot_at,
    :window,
    :windows,
    :reservations,
    :policy,
    :provenance
  ]
  @window [:provider_id, :model_id, :size, :unit, :estimator_id, :estimator_version]
  @policy [:max_age, :allow_derived, :priority, :recency, :max_selected_count, :max_selected_bytes]
  @candidate [
    :item_id,
    :version,
    :source,
    :content,
    :estimate,
    :priority,
    :access,
    :derived_from,
    :content_hash
  ]
  @node [:item_id, :version, :tenant, :source, :content_hash, :derived_from, :check]
  @check [:item_id, :version, :tenant, :source, :content_hash, :principal, :checked_at, :result]
  @access [:principal, :checked_at, :result]
  @safe_fields Enum.uniq(
                 [:candidates] ++
                   @context ++
                   @window ++ @policy ++ @candidate ++ @node ++ @check ++ @access ++ [:updated_at]
               )
  @details %{
    ContextSelectionMissingNode: {:policy, :missing_node},
    ContextSelectionBindingMismatch: {:access_denied, :binding_mismatch},
    ContextSelectionMissingCheck: {:access_denied, :missing_check},
    ContextSelectionDenied: {:access_denied, :denied},
    ContextSelectionFutureCheck: {:stale_access_check, :future_check},
    ContextSelectionExpiredCheck: {:stale_access_check, :expired_check},
    ContextSelectionNewerVersion: {:superseded, :newer_version},
    ContextSelectionDerivedDisabled: {:policy, :derived_disabled},
    ContextSelectionSourceUnchecked: {:access_denied, :source_unchecked},
    ContextSelectionSourceDenied: {:access_denied, :source_denied},
    ContextSelectionSourceStale: {:stale_access_check, :source_stale},
    ContextSelectionSupersededSource: {:policy, :superseded_source},
    ContextSelectionCyclicProvenance: {:policy, :cyclic_provenance},
    ContextSelectionProvenanceDepth: {:policy, :provenance_depth},
    ContextSelectionDuplicate: {:policy, :duplicate},
    ContextSelectionInsufficientWindow: {:over_window, :insufficient_window},
    ContextSelectionCountLimit: {:policy, :count_limit},
    ContextSelectionByteLimit: {:policy, :byte_limit}
  }
  @invariants %{
    ContextSelectionWindowInvariant: :window,
    ContextSelectionAccessInvariant: :access,
    ContextSelectionCountInvariant: :count,
    ContextSelectionBytesInvariant: :bytes
  }

  @doc "Select candidates using an immutable, host-supplied context."
  @spec select(term(), term()) :: {:ok, map()} | {:error, tuple()}
  def select(request, context) do
    try do
      {nodes, reserved} = validate_context(context)
      candidates = validate_request(request, context, nodes)
      indexed = Enum.with_index(candidates)
      {eligible, vetoes} = retrieval_filter(indexed, context.principal)

      ranked =
        Enum.sort_by(eligible, fn {c, i} ->
          {if(context.policy.priority == :descending, do: -c.priority, else: 0),
           if(context.policy.recency == :newest, do: -c.updated_at, else: 0), i}
        end)

      encoded = Enum.map(ranked, fn {c, i} -> encode_candidate(c, i) end)
      raw = Enum.map(context.provenance, &encode_node/1)
      known = Enum.map(candidates, &encode_key/1)
      result = apply(@cure, :select, [encoded, raw, known, encode_context(context, reserved)])
      decode(result, candidates, nodes, vetoes, context, reserved)
    catch
      {:context_selection_validation, class, reason} -> {:error, {class, reason}}
    end
  end

  defp fail(class, reason), do: throw({:context_selection_validation, class, reason})
  defp require!(true, _class, _reason), do: :ok
  defp require!(false, class, reason), do: fail(class, reason)

  defp schema!(value, required, optional, class, field) do
    require!(is_map(value) and not is_struct(value), class, {:invalid_field, field})

    case Enum.find(required, &(not Map.has_key?(value, &1))) do
      nil -> :ok
      missing -> fail(class, {:missing_field, missing})
    end

    allowed = required ++ optional
    unknown = Map.keys(value) -- allowed

    if unknown != [] do
      case Enum.find(@safe_fields, &(&1 in unknown)) do
        nil -> fail(class, :unknown_field)
        key -> fail(class, {:unknown_field, key})
      end
    end

    :ok
  end

  defp bounded_list!(value, limit, class, name), do: bounded_list!(value, limit, class, name, 0)
  defp bounded_list!([], _limit, _class, _name, _count), do: :ok
  defp bounded_list!([_ | _], limit, class, name, limit), do: fail(class, {:bound_exceeded, name})

  defp bounded_list!([_ | tail], limit, class, name, count),
    do: bounded_list!(tail, limit, class, name, count + 1)

  defp bounded_list!(_, _limit, class, name, _count), do: fail(class, {:invalid_field, name})

  defp id!(v, class, field),
    do:
      require!(
        is_binary(v) and byte_size(v) in 1..1024 and String.valid?(v),
        class,
        {:invalid_field, field}
      )

  defp amount!(v, class, field), do: integer!(v, 0, @amount_max, class, field)

  defp integer!(v, lo, hi, class, field),
    do: require!(is_integer(v) and v >= lo and v <= hi, class, {:invalid_field, field})

  defp version!(v, class, field), do: integer!(v, 1, @version_max, class, field)

  defp hash!(v, class),
    do:
      require!(
        is_nil(v) or (is_binary(v) and byte_size(v) == 32),
        class,
        {:invalid_field, :content_hash}
      )

  defp enum!(v, domain, class, field), do: require!(v in domain, class, {:invalid_field, field})
  defp key(x), do: {x.item_id, x.version}
  defp window_key(x), do: {x.provider_id, x.model_id}

  defp unique!(values, class, reason),
    do: require!(length(values) == MapSet.size(MapSet.new(values)), class, reason)

  defp validate_context(c) do
    cl = :unavailable_context
    schema!(c, @context, [], cl, :context)
    id!(c.principal, cl, :principal)
    id!(c.tenant, cl, :tenant)
    amount!(c.now, cl, :now)
    amount!(c.snapshot_at, cl, :snapshot_at)
    window!(c.window, cl)
    bounded_list!(c.windows, 32, cl, :windows)
    Enum.each(c.windows, &window!(&1, cl))
    bounded_list!(c.reservations, 32, cl, :reservations)

    Enum.each(c.reservations, fn
      {name, amount} ->
        id!(name, cl, :reservations)
        amount!(amount, cl, :reservations)

      _ ->
        fail(cl, {:invalid_field, :reservations})
    end)

    policy!(c.policy, cl)
    bounded_list!(c.provenance, 256, cl, :provenance)
    Enum.each(c.provenance, &node!(&1, cl))
    unique!(Enum.map(c.windows, &window_key/1), cl, :duplicate_window)
    unique!(Enum.map(c.reservations, &elem(&1, 0)), cl, :duplicate_reservation)
    unique!(Enum.map(c.provenance, &key/1), cl, :duplicate_provenance_node)
    require!(c.snapshot_at <= c.now, cl, :invalid_snapshot_time)

    case Enum.find(c.windows, &(window_key(&1) == window_key(c.window))) do
      nil -> fail(cl, :unknown_window)
      registered -> require!(registered == c.window, cl, :window_mismatch)
    end

    reserved = Enum.sum(Enum.map(c.reservations, &elem(&1, 1)))
    require!(reserved <= c.window.size, cl, :reservations_exceed_window)
    expansions = length(c.provenance) + Enum.sum(Enum.map(c.provenance, &length(&1.derived_from)))
    require!(expansions <= 4096, cl, {:bound_exceeded, :provenance_expansions})
    {Map.new(c.provenance, &{key(&1), &1}), reserved}
  end

  defp window!(w, cl) do
    schema!(w, @window, [], cl, :window)
    id!(w.provider_id, cl, :provider_id)
    id!(w.model_id, cl, :model_id)
    amount!(w.size, cl, :size)
    enum!(w.unit, [:tokens, :bytes], cl, :unit)
    id!(w.estimator_id, cl, :estimator_id)
    version!(w.estimator_version, cl, :estimator_version)
  end

  defp policy!(p, cl) do
    schema!(p, @policy, [], cl, :policy)
    amount!(p.max_age, cl, :max_age)
    require!(is_boolean(p.allow_derived), cl, {:invalid_field, :allow_derived})
    enum!(p.priority, [:descending, :input], cl, :priority)
    enum!(p.recency, [:newest, :input], cl, :recency)
    integer!(p.max_selected_count, 0, 256, cl, :max_selected_count)
    integer!(p.max_selected_bytes, 0, 8_388_608, cl, :max_selected_bytes)
  end

  defp refs!(refs, cl) do
    bounded_list!(refs, 16, cl, :derived_from)

    Enum.each(refs, fn ref ->
      schema!(ref, [:item_id, :version], [], cl, :derived_from)
      id!(ref.item_id, cl, :item_id)
      version!(ref.version, cl, :version)
    end)

    unique!(Enum.map(refs, &key/1), cl, {:invalid_field, :derived_from})
  end

  defp node!(n, cl) do
    schema!(n, @node, [], cl, :provenance)
    id!(n.item_id, cl, :item_id)
    version!(n.version, cl, :version)
    id!(n.tenant, cl, :tenant)
    id!(n.source, cl, :source)
    hash!(n.content_hash, cl)
    refs!(n.derived_from, cl)

    if n.check != nil do
      ck = n.check
      schema!(ck, @check, [], cl, :check)
      id!(ck.item_id, cl, :item_id)
      version!(ck.version, cl, :version)
      id!(ck.tenant, cl, :tenant)
      id!(ck.source, cl, :source)
      hash!(ck.content_hash, cl)
      id!(ck.principal, cl, :principal)
      amount!(ck.checked_at, cl, :checked_at)
      enum!(ck.result, [:allowed, :denied], cl, :result)
    end
  end

  defp validate_request(request, c, nodes) do
    cl = :invalid_input
    schema!(request, [:candidates], [], cl, :request)
    bounded_list!(request.candidates, 256, cl, :candidates)

    bytes =
      Enum.reduce(request.candidates, 0, fn
        %{content: content}, total when is_binary(content) -> total + byte_size(content)
        _, total -> total
      end)

    require!(bytes <= 8_388_608, cl, {:bound_exceeded, :candidate_bytes})
    Enum.each(request.candidates, &candidate!(&1, c, nodes))
    identities = MapSet.new(Map.keys(nodes) ++ Enum.map(request.candidates, &key/1))
    require!(MapSet.size(identities) <= 256, cl, {:bound_exceeded, :provenance})

    Enum.reduce(request.candidates, %{}, fn item, seen ->
      case Map.fetch(seen, key(item)) do
        :error -> Map.put(seen, key(item), item)
        {:ok, ^item} -> seen
        {:ok, _} -> fail(cl, :conflicting_candidate)
      end
    end)

    request.candidates
  end

  defp candidate!(item, c, nodes) do
    cl = :invalid_input

    {required, optional} =
      if c.policy.recency == :newest,
        do: {@candidate ++ [:updated_at], []},
        else: {@candidate, [:updated_at]}

    schema!(item, required, optional, cl, :candidates)
    id!(item.item_id, cl, :item_id)
    version!(item.version, cl, :version)
    id!(item.source, cl, :source)
    require!(is_binary(item.content), cl, {:invalid_field, :content})
    require!(byte_size(item.content) <= 1_048_576, cl, {:bound_exceeded, :content_bytes})
    amount!(item.estimate, cl, :estimate)
    integer!(item.priority, -2_147_483_648, @version_max, cl, :priority)
    schema!(item.access, @access, [], cl, :access)
    id!(item.access.principal, cl, :principal)
    amount!(item.access.checked_at, cl, :checked_at)
    enum!(item.access.result, [:allowed, :denied], cl, :result)
    refs!(item.derived_from, cl)
    hash!(item.content_hash, cl)
    if Map.has_key?(item, :updated_at), do: amount!(item.updated_at, cl, :updated_at)

    if item.content_hash != nil,
      do: require!(item.content_hash == :crypto.hash(:sha256, item.content), cl, :hash_mismatch)

    if c.window.unit == :bytes,
      do: require!(item.estimate >= byte_size(item.content), cl, :byte_estimate_underflow)

    case Map.fetch(nodes, key(item)) do
      :error ->
        :ok

      {:ok, n} ->
        require!(
          Map.take(item, [:source, :content_hash, :derived_from]) ==
            Map.take(n, [:source, :content_hash, :derived_from]),
          cl,
          :candidate_binding_mismatch
        )
    end
  end

  defp retrieval_filter(indexed, principal) do
    Enum.reduce(indexed, {[], []}, fn {c, i}, {eligible, drops} ->
      cond do
        c.access.result == :denied ->
          {eligible, [drop(c, i, :access_denied, :retrieval_denied) | drops]}

        c.access.principal != principal ->
          {eligible, [drop(c, i, :access_denied, :principal_mismatch) | drops]}

        true ->
          {[{c, i} | eligible], drops}
      end
    end)
  end

  defp text(s), do: {:String, String.to_charlist(s)}
  defp encode_key(k), do: {:ContextSelectionKey, text(k.item_id), k.version}
  defp encode_hash(nil), do: :none
  defp encode_hash(hash), do: {:some, text(Base.encode16(hash, case: :lower))}
  defp encode_check(nil), do: :none

  defp encode_check(c),
    do:
      {:some,
       {:ContextSelectionCheck, encode_key(c), text(c.tenant), text(c.source),
        encode_hash(c.content_hash), text(c.principal), c.checked_at, c.result == :allowed}}

  defp encode_node(n),
    do:
      {:ContextSelectionNode, encode_key(n), text(n.tenant), text(n.source),
       encode_hash(n.content_hash), Enum.map(n.derived_from, &encode_key/1), encode_check(n.check)}

  defp encode_candidate(c, i),
    do:
      {:ContextSelectionCandidate, i, encode_key(c), encode_hash(c.content_hash), c.estimate,
       byte_size(c.content)}

  defp encode_context(c, reserved),
    do:
      {:ContextSelectionContext, text(c.principal), text(c.tenant), c.now, c.snapshot_at,
       c.policy.max_age, c.policy.allow_derived, c.window.size, reserved,
       c.policy.max_selected_count, c.policy.max_selected_bytes}

  defp drop(c, i, reason, detail),
    do: %{index: i, item_id: c.item_id, version: c.version, reason: reason, detail: detail}

  defp decode({:ContextSelectionFailed, kind}, _items, _nodes, _vetoes, _c, _r),
    do: {:error, {:invariant_failed, Map.fetch!(@invariants, kind)}}

  defp decode({:ContextSelectionSelected, chosen, rejected}, items, nodes, vetoes, c, reserved) do
    by_index = items |> Enum.with_index() |> Map.new(fn {item, i} -> {i, item} end)

    selected =
      Enum.map(chosen, fn {:ContextSelectionCandidate, i, _key, _hash, _estimate, _bytes} ->
        original = Map.fetch!(by_index, i)
        current = Map.fetch!(nodes, key(original)).check

        original
        |> Map.put(:index, i)
        |> Map.put(:kind, if(original.derived_from == [], do: :source, else: :derived))
        |> Map.put(:retrieval_access, original.access)
        |> Map.put(:access, Map.take(current, @access))
      end)

    dropped =
      Enum.map(rejected, fn {:ContextSelectionDrop, i, detail} ->
        {reason, atom} = Map.fetch!(@details, detail)
        drop(Map.fetch!(by_index, i), i, reason, atom)
      end)

    total = Enum.sum(Enum.map(selected, & &1.estimate))
    bytes = Enum.sum(Enum.map(selected, &byte_size(&1.content)))

    cond do
      total + reserved > c.window.size ->
        {:error, {:invariant_failed, :window}}

      length(selected) > c.policy.max_selected_count ->
        {:error, {:invariant_failed, :count}}

      bytes > c.policy.max_selected_bytes ->
        {:error, {:invariant_failed, :bytes}}

      Enum.any?(
        selected,
        &(&1.retrieval_access.result != :allowed or &1.retrieval_access.principal != c.principal)
      ) ->
        {:error, {:invariant_failed, :access}}

      true ->
        {:ok,
         %{
           selected: selected,
           dropped: Enum.sort_by(dropped ++ vetoes, & &1.index),
           total_estimate: %{
             size: total,
             unit: c.window.unit,
             estimator_id: c.window.estimator_id,
             estimator_version: c.window.estimator_version
           },
           reserved_estimate: reserved,
           selected_count: length(selected),
           selected_bytes: bytes,
           window: c.window,
           principal: c.principal,
           tenant: c.tenant,
           evaluated_at: c.now
         }}
    end
  end
end
