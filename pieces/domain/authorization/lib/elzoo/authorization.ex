# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Authorization do
  @moduledoc """
  Pure ALLOW/ASK/DENY decision for one proposed action (domain/authorization).

  This module validates, normalizes and encodes trusted context and proposal
  data, calls the Cure reducer `Cure.Elzoo.Authorization.decide/4` and decodes
  its result. It computes no verdict itself except the control-key DENY,
  which is test-grounded. No I/O, clock, process or authentication.
  """

  @cure :"Cure.Elzoo.Authorization"

  @max_depth 16
  @max_nodes 4096
  @max_value_bytes 4096
  @max_identity_bytes 1024
  @max_int Integer.pow(2, 256)
  @max_writes 256
  @max_authority 4096
  @max_rules 1024
  @max_effect_classes 256
  @max_version Integer.pow(2, 31) - 1

  @control_keys [
    :policy,
    :authority,
    :bounding_authority,
    :parent_authority,
    :approval,
    :approvals,
    :evidence,
    :verifier,
    :decision
  ]
  @proposal_required [:tenant, :resource, :action_id, :payload, :writes]
  @proposal_optional [:proposer, :effect_class]
  @context_keys [:proposer, :effect_class, :own, :parent]
  @policy_keys [:id, :version, :content_hash, :effect_classes, :rules]
  @rule_required [:id, :effect_class, :verdict]
  @rule_optional [
    :principal,
    :tenant,
    :resource,
    :payload,
    :target,
    :field,
    :value,
    :requirement
  ]

  @doc "Fixed Contract bounds."
  def bounds do
    %{
      depth: @max_depth,
      nodes: @max_nodes,
      value_bytes: @max_value_bytes,
      identity_bytes: @max_identity_bytes,
      int_magnitude: @max_int,
      writes: @max_writes,
      authority: @max_authority,
      rules: @max_rules,
      effect_classes: @max_effect_classes,
      version: @max_version
    }
  end

  @doc "Control keys that make a proposal a DENY."
  def control_keys, do: @control_keys

  # ------------------------------------------------------------------ decide

  @doc """
  Decide one proposal. `authority_context` is trusted:
  `%{proposer: text, effect_class: text, own: [write], parent: [write] | :none}`.
  """
  def decide(policy, proposal, authority_context) do
    with {:ok, policy} <- validate_policy(policy),
         {:ok, ctx} <- validate_context(authority_context, policy) do
      case validate_proposal(proposal, ctx) do
        {:ok, action} -> run_decide(policy, action, ctx)
        {:deny, reason} -> {:ok, control_deny(policy, reason)}
        {:error, _} = error -> error
      end
    end
  end

  @doc false
  def run_decide(policy, action, ctx) do
    result =
      apply(@cure, :decide, [
        encode_policy(policy),
        encode_action(action),
        encode_writes(ctx.own),
        encode_parent(ctx.parent)
      ])

    case result do
      {:Decided, outcome} -> {:ok, decode_outcome(outcome, policy, action)}
      {:DecideFailed, class, failure} -> {:error, {decode_class(class), decode_failure(failure)}}
    end
  end

  defp control_deny(policy, reason) do
    %{
      verdict: :deny,
      reason: reason,
      policy: identity(policy),
      action: nil,
      permitted: [],
      escrowed: [],
      requirement: nil,
      rules: []
    }
  end

  @doc "What the Assembly shows the proposer."
  def proposer_view(decision, :full), do: decision

  def proposer_view(%{verdict: verdict, policy: policy}, :verdict_only),
    do: %{verdict: verdict, policy: policy}

  @doc "Structural equality of two normalized actions or values."
  def same_action?(a, b), do: a == b

  @doc "Policy identity triple."
  def identity(policy),
    do: %{id: policy.id, version: policy.version, content_hash: policy.content_hash}

  # ------------------------------------------------------------------ trusted context

  @doc false
  def validate_context(ctx, policy) when is_map(ctx) and not is_struct(ctx) do
    with :ok <- exact_keys(ctx, @context_keys, @context_keys, :unavailable_context),
         {:ok, proposer} <- identity_field(ctx.proposer, :proposer, :unavailable_context),
         {:ok, class} <- identity_field(ctx.effect_class, :effect_class, :unavailable_context),
         :ok <- declared_class(class, policy),
         {:ok, own} <- validate_authority(ctx.own),
         {:ok, parent} <- validate_parent(ctx.parent) do
      {:ok, %{proposer: proposer, effect_class: class, own: own, parent: parent}}
    end
  end

  def validate_context(_ctx, _policy), do: {:error, {:unavailable_context, :not_a_map}}

  defp declared_class(class, policy) do
    if class in policy.effect_classes,
      do: :ok,
      else: {:error, {:unavailable_context, :undeclared_effect_class}}
  end

  defp validate_parent(:none), do: {:ok, :none}
  defp validate_parent(parent), do: validate_authority(parent)

  @doc "Validate and normalize an authority set (trusted context)."
  def validate_authority(writes) do
    case write_set(writes, @max_authority, :authority, :unavailable_context) do
      {:ok, ws} ->
        {:ok, ws}

      {:error, {:conflict, t, f}} ->
        {:error, {:unavailable_context, {:conflicting_authority, t, f}}}

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------ policy

  @doc "Validate a trusted policy."
  def validate_policy(policy) when is_map(policy) and not is_struct(policy) do
    with :ok <- exact_keys(policy, @policy_keys, @policy_keys, :unavailable_context),
         {:ok, id} <- identity_field(policy.id, :id, :unavailable_context),
         :ok <- version(policy.version, :unavailable_context),
         :ok <- content_hash(policy.content_hash),
         {:ok, classes} <- effect_classes(policy.effect_classes),
         {:ok, rules} <- rules(policy.rules, classes) do
      {:ok,
       %{
         id: id,
         version: policy.version,
         content_hash: policy.content_hash,
         effect_classes: classes,
         rules: rules
       }}
    else
      {:error, {:unavailable_context, {:invalid_policy, _}}} = error ->
        error

      {:error, {:unavailable_context, reason}} ->
        {:error, {:unavailable_context, {:invalid_policy, reason}}}
    end
  end

  def validate_policy(_), do: {:error, {:unavailable_context, {:invalid_policy, :not_a_map}}}

  defp content_hash(<<_::256>>), do: :ok
  defp content_hash(_), do: {:error, {:unavailable_context, :content_hash}}

  defp version(v, _class) when is_integer(v) and v >= 1 and v <= @max_version, do: :ok
  defp version(_, class), do: {:error, {class, :version}}

  defp effect_classes(list) when is_list(list) do
    with :ok <- proper_list(list, :effect_classes, :unavailable_context),
         :ok <- count_in(list, 1, @max_effect_classes, :effect_classes, :unavailable_context),
         {:ok, ids} <- map_ok(list, &identity_field(&1, :effect_class, :unavailable_context)) do
      if length(Enum.uniq(ids)) == length(ids),
        do: {:ok, ids},
        else: {:error, {:unavailable_context, :duplicate_effect_class}}
    end
  end

  defp effect_classes(_), do: {:error, {:unavailable_context, :effect_classes}}

  defp rules(list, classes) when is_list(list) do
    with :ok <- proper_list(list, :rules, :unavailable_context),
         :ok <- count_in(list, 0, @max_rules, :rules, :unavailable_context),
         {:ok, rules} <- map_ok(list, &rule(&1, classes)) do
      ids = Enum.map(rules, & &1.id)

      if length(Enum.uniq(ids)) == length(ids),
        do: {:ok, rules},
        else: {:error, {:unavailable_context, :duplicate_rule_id}}
    end
  end

  defp rules(_, _), do: {:error, {:unavailable_context, :rules}}

  defp rule(r, classes) when is_map(r) and not is_struct(r) do
    with :ok <- exact_keys(r, @rule_required, @rule_optional, :unavailable_context),
         {:ok, id} <- identity_field(r.id, :rule_id, :unavailable_context),
         {:ok, class} <- identity_field(r.effect_class, :effect_class, :unavailable_context),
         :ok <- rule_class(class, classes),
         {:ok, verdict} <- verdict(r.verdict),
         {:ok, principal} <- text_match(Map.get(r, :principal, :any)),
         {:ok, tenant} <- text_match(Map.get(r, :tenant, :any)),
         {:ok, resource} <- text_match(Map.get(r, :resource, :any)),
         {:ok, payload} <- value_match(Map.get(r, :payload, :any)),
         {:ok, target} <- text_match(Map.get(r, :target, :any)),
         {:ok, field} <- text_match(Map.get(r, :field, :any)),
         {:ok, value} <- value_match(Map.get(r, :value, :any)),
         {:ok, requirement} <- requirement(Map.get(r, :requirement), verdict) do
      {:ok,
       %{
         id: id,
         effect_class: class,
         principal: principal,
         tenant: tenant,
         resource: resource,
         payload: payload,
         target: target,
         field: field,
         value: value,
         verdict: verdict,
         requirement: requirement
       }}
    end
  end

  defp rule(_, _), do: {:error, {:unavailable_context, :rule}}

  defp rule_class(class, classes) do
    if class in classes, do: :ok, else: {:error, {:unavailable_context, :rule_effect_class}}
  end

  defp verdict(v) when v in [:allow, :ask, :deny], do: {:ok, v}
  defp verdict(_), do: {:error, {:unavailable_context, :verdict}}

  defp text_match(:any), do: {:ok, :any}

  defp text_match({:exact, t}) do
    with {:ok, t} <- identity_field(t, :match, :unavailable_context), do: {:ok, {:exact, t}}
  end

  defp text_match(_), do: {:error, {:unavailable_context, :match}}

  defp value_match(:any), do: {:ok, :any}

  defp value_match({:exact, v}) do
    case validate_value(v) do
      {:ok, v} -> {:ok, {:exact, v}}
      {:error, {:invalid_input, r}} -> {:error, {:unavailable_context, r}}
    end
  end

  defp value_match(_), do: {:error, {:unavailable_context, :match}}

  defp requirement(nil, :ask), do: {:error, {:unavailable_context, :ask_without_requirement}}
  defp requirement(nil, _), do: {:ok, nil}

  defp requirement(_, v) when v != :ask,
    do: {:error, {:unavailable_context, :requirement_on_non_ask}}

  defp requirement(%{name: name, version: v, scope: scope} = r, :ask) when map_size(r) == 3 do
    with {:ok, name} <- identity_field(name, :requirement_name, :unavailable_context),
         :ok <- version(v, :unavailable_context),
         true <- scope in [:once, :run, :root] || {:error, {:unavailable_context, :scope}} do
      {:ok, %{name: name, version: v, scope: scope}}
    end
  end

  defp requirement(_, _), do: {:error, {:unavailable_context, :requirement}}

  # ------------------------------------------------------------------ proposal

  @doc """
  Validate a proposal against validated trusted context. Pinned order: control
  key, unknown key, missing key, value/identity validity and bounds, empty write
  set, conflicting writes, proposer mismatch, effect class mismatch.
  """
  def validate_proposal(p, ctx) when is_map(p) and not is_struct(p) do
    keys = Map.keys(p)

    case Enum.find(@control_keys, &(&1 in keys)) do
      nil -> proposal_fields(p, ctx)
      key -> {:deny, {:control_field, key}}
    end
  end

  def validate_proposal(_, _), do: {:error, {:invalid_input, :not_a_map}}

  defp proposal_fields(p, ctx) do
    with :ok <- exact_keys(p, @proposal_required, @proposal_optional, :invalid_input),
         {:ok, tenant} <- identity_field(p.tenant, :tenant, :invalid_input),
         {:ok, resource} <- identity_field(p.resource, :resource, :invalid_input),
         {:ok, action_id} <- identity_field(p.action_id, :action_id, :invalid_input),
         {:ok, payload} <- validate_value(p.payload),
         {:ok, proposer} <- optional_identity(p, :proposer),
         {:ok, class} <- optional_identity(p, :effect_class),
         {:ok, writes} <- proposal_writes(p.writes),
         :ok <- same_or_absent(proposer, ctx.proposer, :proposer_mismatch),
         :ok <- same_or_absent(class, ctx.effect_class, :effect_class_mismatch) do
      {:ok,
       %{
         proposer: ctx.proposer,
         tenant: tenant,
         resource: resource,
         action_id: action_id,
         effect_class: ctx.effect_class,
         payload: payload,
         writes: writes
       }}
    end
  end

  defp proposal_writes(writes) do
    with :ok <- proper_list(writes, :writes, :invalid_input),
         :ok <- count_in(writes, 0, @max_writes, :writes, :invalid_input),
         {:ok, validated} <- map_ok(writes, &write/1),
         :ok <- if(validated == [], do: {:error, {:invalid_input, :empty_writes}}, else: :ok) do
      case normalize_writes(validated) do
        {:ok, ws} -> {:ok, ws}
        {:error, {:conflict, t, f}} -> {:error, {:invalid_input, {:conflicting_writes, t, f}}}
      end
    end
  end

  defp optional_identity(p, key) do
    case Map.fetch(p, key) do
      :error -> {:ok, :absent}
      {:ok, v} -> identity_field(v, key, :invalid_input)
    end
  end

  defp same_or_absent(:absent, _trusted, _reason), do: :ok
  defp same_or_absent(v, v, _reason), do: :ok
  defp same_or_absent(_, _, reason), do: {:error, {:invalid_input, reason}}

  # ------------------------------------------------------------------ writes

  defp write_set(list, max, name, class) do
    with :ok <- proper_list(list, name, class),
         :ok <- count_in(list, 0, max, name, class),
         {:ok, validated} <- map_ok(list, &write/1) |> reclass(class) do
      normalize_writes(validated)
    end
  end

  defp reclass({:error, {:invalid_input, r}}, :unavailable_context),
    do: {:error, {:unavailable_context, r}}

  defp reclass(other, _), do: other

  defp write(%{target: t, field: f, value: v} = w) when map_size(w) == 3 do
    with {:ok, t} <- identity_field(t, :target, :invalid_input),
         {:ok, f} <- identity_field(f, :field, :invalid_input),
         {:ok, v} <- validate_value(v) do
      {:ok, %{target: t, field: f, value: v}}
    end
  end

  defp write(_), do: {:error, {:invalid_input, :write}}

  # Coalesce identical entries, fail closed on conflicting values, sort by
  # UTF-8 byte order of (target, field). Elixir binary order is byte order.
  defp normalize_writes(writes) do
    writes
    |> Enum.group_by(&{&1.target, &1.field})
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.reduce_while({:ok, []}, fn {{t, f}, entries}, {:ok, acc} ->
      case Enum.uniq(entries) do
        [one] -> {:cont, {:ok, [one | acc]}}
        _ -> {:halt, {:error, {:conflict, t, f}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # ------------------------------------------------------------------ normalized data

  @doc """
  Validate an already normalized write list as produced by `decide/3`
  (canonical order, no duplicates, `min..256` entries). Anything that is not
  exactly its own normalization is rejected, never repaired or truncated.
  """
  def validate_writes(writes, min \\ 1) do
    with :ok <- proper_list(writes, :writes, :invalid_input),
         :ok <- count_in(writes, min, @max_writes, :writes, :invalid_input),
         {:ok, validated} <- map_ok(writes, &write/1) do
      case normalize_writes(validated) do
        {:ok, ^writes} -> {:ok, writes}
        {:ok, _} -> {:error, {:invalid_input, :writes_not_normalized}}
        {:error, {:conflict, t, f}} -> {:error, {:invalid_input, {:conflicting_writes, t, f}}}
      end
    end
  end

  @action_keys [:proposer, :tenant, :resource, :action_id, :effect_class, :payload, :writes]

  @doc "Validate a normalized action as carried by a decision or approval binding."
  def validate_action(a) when is_map(a) and not is_struct(a) do
    with :ok <- exact_keys(a, @action_keys, [], :invalid_input),
         {:ok, _} <- identity_field(a.proposer, :proposer, :invalid_input),
         {:ok, _} <- identity_field(a.tenant, :tenant, :invalid_input),
         {:ok, _} <- identity_field(a.resource, :resource, :invalid_input),
         {:ok, _} <- identity_field(a.action_id, :action_id, :invalid_input),
         {:ok, _} <- identity_field(a.effect_class, :effect_class, :invalid_input),
         :ok <- normalized_value(a.payload),
         {:ok, _} <- validate_writes(a.writes) do
      {:ok, a}
    end
  end

  def validate_action(_), do: {:error, {:invalid_input, :action}}

  defp normalized_value(v) do
    case validate_value(v) do
      {:ok, ^v} -> :ok
      {:ok, _} -> {:error, {:invalid_input, :value_not_normalized}}
      error -> error
    end
  end

  @doc "Validate a policy identity triple."
  def validate_identity(%{id: id, version: v, content_hash: h} = i) when map_size(i) == 3 do
    with {:ok, _} <- identity_field(id, :policy_id, :invalid_input),
         :ok <- version(v, :invalid_input),
         :ok <- if(match?(<<_::256>>, h), do: :ok, else: {:error, {:invalid_input, :content_hash}}) do
      {:ok, i}
    end
  end

  def validate_identity(_), do: {:error, {:invalid_input, :policy_identity}}

  @doc "Validate an approval requirement."
  def validate_requirement(r) do
    case requirement(r, :ask) do
      {:ok, req} -> {:ok, req}
      {:error, {:unavailable_context, reason}} -> {:error, {:invalid_input, reason}}
    end
  end

  # ------------------------------------------------------------------ values

  @doc """
  Validate and normalize one portable value. Records are given as a
  duplicate-preserving list of `{name, value}` pairs.
  """
  def validate_value(v) do
    case value(v, 1) do
      {:ok, normalized, nodes} when nodes <= @max_nodes -> {:ok, normalized}
      {:ok, _, _} -> {:error, {:invalid_input, {:bound_exceeded, :nodes}}}
      {:error, _} = error -> error
    end
  end

  defp value(_v, depth) when depth > @max_depth,
    do: {:error, {:invalid_input, {:bound_exceeded, :depth}}}

  defp value(nil, _), do: {:ok, nil, 1}
  defp value(b, _) when is_boolean(b), do: {:ok, b, 1}

  defp value(n, _) when is_integer(n) do
    if abs(n) < @max_int,
      do: {:ok, n, 1},
      else: {:error, {:invalid_input, {:bound_exceeded, :integer}}}
  end

  defp value({:text, t}, _) when is_binary(t) do
    cond do
      byte_size(t) > @max_value_bytes -> {:error, {:invalid_input, {:bound_exceeded, :text}}}
      not String.valid?(t) -> {:error, {:invalid_input, :invalid_utf8}}
      true -> {:ok, {:text, t}, 1}
    end
  end

  defp value({:bytes, b}, _) when is_binary(b) do
    if byte_size(b) > @max_value_bytes,
      do: {:error, {:invalid_input, {:bound_exceeded, :bytes}}},
      else: {:ok, {:bytes, b}, 1}
  end

  defp value({:list, items}, depth) when is_list(items) do
    with :ok <- proper_list(items, :list, :invalid_input) do
      children(items, depth, fn item -> value(item, depth + 1) end)
      |> case do
        {:ok, vs, n} -> {:ok, {:list, vs}, n + 1}
        error -> error
      end
    end
  end

  defp value({:record, pairs}, depth) when is_list(pairs) do
    with :ok <- proper_list(pairs, :record, :invalid_input),
         :ok <- pair_shapes(pairs),
         :ok <- unique_names(pairs) do
      children(pairs, depth, fn {name, v} ->
        with :ok <- field_name(name),
             {:ok, nv, n} <- value(v, depth + 1) do
          {:ok, {name, nv}, n + 1}
        end
      end)
      |> case do
        {:ok, fields, n} -> {:ok, {:record, Enum.sort_by(fields, &elem(&1, 0))}, n + 1}
        error -> error
      end
    end
  end

  defp value(f, _) when is_float(f), do: {:error, {:invalid_input, :float}}
  defp value(_, _), do: {:error, {:invalid_input, :unsupported_value}}

  defp children(items, _depth, fun) do
    Enum.reduce_while(items, {:ok, [], 0}, fn item, {:ok, acc, n} ->
      case fun.(item) do
        {:ok, v, m} when n + m <= @max_nodes -> {:cont, {:ok, [v | acc], n + m}}
        {:ok, _, _} -> {:halt, {:error, {:invalid_input, {:bound_exceeded, :nodes}}}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, n} -> {:ok, Enum.reverse(acc), n}
      error -> error
    end
  end

  defp pair_shapes(pairs) do
    if Enum.all?(pairs, &match?({_, _}, &1)),
      do: :ok,
      else: {:error, {:invalid_input, :record_field}}
  end

  # Duplicate names are rejected before any map is built.
  defp unique_names(pairs) do
    names = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(names)) == length(names),
      do: :ok,
      else: {:error, {:invalid_input, :duplicate_field}}
  end

  defp field_name(name) when is_binary(name) do
    cond do
      byte_size(name) > @max_value_bytes ->
        {:error, {:invalid_input, {:bound_exceeded, :field_name}}}

      not String.valid?(name) ->
        {:error, {:invalid_input, :invalid_utf8}}

      true ->
        :ok
    end
  end

  defp field_name(_), do: {:error, {:invalid_input, :record_field}}

  # ------------------------------------------------------------------ helpers

  @doc false
  def identity_field(t, name, class) when is_binary(t) do
    cond do
      t == "" -> {:error, {class, {:empty, name}}}
      byte_size(t) > @max_identity_bytes -> {:error, {class, {:bound_exceeded, name}}}
      not String.valid?(t) -> {:error, {class, {:invalid_utf8, name}}}
      true -> {:ok, t}
    end
  end

  def identity_field(_, name, class), do: {:error, {class, {:not_text, name}}}

  @doc false
  def exact_keys(map, required, optional, class) do
    allowed = required ++ optional
    keys = Map.keys(map)

    cond do
      key = Enum.find(keys, &(&1 not in allowed)) -> {:error, {class, {:unknown_field, key}}}
      key = Enum.find(required, &(&1 not in keys)) -> {:error, {class, {:missing_field, key}}}
      true -> :ok
    end
  end

  @doc false
  def proper_list(list, name, class) do
    if is_list(list) and proper?(list), do: :ok, else: {:error, {class, {:not_a_list, name}}}
  end

  defp proper?([]), do: true
  defp proper?([_ | t]), do: proper?(t)
  defp proper?(_), do: false

  @doc false
  def count_in(list, min, max, name, class) do
    n = length(list)

    cond do
      n > max -> {:error, {class, {:bound_exceeded, name}}}
      n < min -> {:error, {class, {:bound_exceeded, name}}}
      true -> :ok
    end
  end

  @doc false
  def map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn x, {:ok, acc} ->
      case fun.(x) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # ------------------------------------------------------------------ Cure codec

  @doc false
  def bytes(t), do: :binary.bin_to_list(t)
  @doc false
  def text(l), do: :binary.list_to_bin(l)

  @doc false
  def encode_value(nil), do: :AVNull
  def encode_value(b) when is_boolean(b), do: {:AVBool, b}
  def encode_value(n) when is_integer(n), do: {:AVInt, n}
  def encode_value({:text, t}), do: {:AVText, bytes(t)}
  def encode_value({:bytes, b}), do: {:AVBytes, bytes(b)}
  def encode_value({:list, vs}), do: {:AVList, Enum.map(vs, &encode_value/1)}

  def encode_value({:record, fs}),
    do: {:AVRecord, Enum.map(fs, fn {n, v} -> {:AuthFieldOf, bytes(n), encode_value(v)} end)}

  @doc false
  def decode_value(:AVNull), do: nil
  def decode_value({:AVBool, b}), do: b
  def decode_value({:AVInt, n}), do: n
  def decode_value({:AVText, l}), do: {:text, text(l)}
  def decode_value({:AVBytes, l}), do: {:bytes, text(l)}
  def decode_value({:AVList, vs}), do: {:list, Enum.map(vs, &decode_value/1)}

  def decode_value({:AVRecord, fs}),
    do: {:record, Enum.map(fs, fn {:AuthFieldOf, n, v} -> {text(n), decode_value(v)} end)}

  @doc false
  def encode_write(w), do: {:AuthWrite, bytes(w.target), bytes(w.field), encode_value(w.value)}
  @doc false
  def encode_writes(ws), do: Enum.map(ws, &encode_write/1)

  @doc false
  def decode_write({:AuthWrite, t, f, v}),
    do: %{target: text(t), field: text(f), value: decode_value(v)}

  @doc false
  def decode_writes(ws), do: Enum.map(ws, &decode_write/1)

  @doc false
  def encode_parent(:none), do: :NoParent
  def encode_parent(ws), do: {:ParentAuthority, encode_writes(ws)}

  defp encode_text_match(:any), do: :AnyText
  defp encode_text_match({:exact, t}), do: {:ExactText, bytes(t)}
  defp encode_value_match(:any), do: :AnyValue
  defp encode_value_match({:exact, v}), do: {:ExactValue, encode_value(v)}

  defp encode_verdict(:allow), do: :AuthAllow
  defp encode_verdict(:ask), do: :AuthAsk
  defp encode_verdict(:deny), do: :AuthDeny
  defp decode_verdict(:AuthAllow), do: :allow
  defp decode_verdict(:AuthAsk), do: :ask
  defp decode_verdict(:AuthDeny), do: :deny

  @doc false
  def encode_scope(:once), do: :ScopeOnce
  def encode_scope(:run), do: :ScopeRun
  def encode_scope(:root), do: :ScopeRoot
  @doc false
  def decode_scope(:ScopeOnce), do: :once
  def decode_scope(:ScopeRun), do: :run
  def decode_scope(:ScopeRoot), do: :root

  @doc false
  def encode_requirement(%{name: n, version: v, scope: s}),
    do: {:AuthRequirement, bytes(n), v, encode_scope(s)}

  @doc false
  def decode_requirement({:AuthRequirement, n, v, s}),
    do: %{name: text(n), version: v, scope: decode_scope(s)}

  defp encode_rule(r) do
    {:AuthRule, bytes(r.id), bytes(r.effect_class), encode_text_match(r.principal),
     encode_text_match(r.tenant), encode_text_match(r.resource), encode_value_match(r.payload),
     encode_text_match(r.target), encode_text_match(r.field), encode_value_match(r.value),
     encode_verdict(r.verdict),
     if(r.requirement, do: {:some, encode_requirement(r.requirement)}, else: :none)}
  end

  @doc false
  def encode_identity(%{id: id, version: v, content_hash: h}),
    do: {:AuthPolicyIdentity, bytes(id), v, bytes(h)}

  @doc false
  def decode_identity({:AuthPolicyIdentity, id, v, h}),
    do: %{id: text(id), version: v, content_hash: text(h)}

  @doc false
  def encode_policy(p), do: {:AuthPolicy, encode_identity(p), Enum.map(p.rules, &encode_rule/1)}

  @doc false
  def encode_action(a) do
    {:AuthAction, bytes(a.proposer), bytes(a.tenant), bytes(a.resource), bytes(a.action_id),
     bytes(a.effect_class), encode_value(a.payload), encode_writes(a.writes)}
  end

  @doc false
  def decode_action({:AuthAction, p, t, r, id, c, payload, ws}) do
    %{
      proposer: text(p),
      tenant: text(t),
      resource: text(r),
      action_id: text(id),
      effect_class: text(c),
      payload: decode_value(payload),
      writes: decode_writes(ws)
    }
  end

  defp decode_outcome(
         {:AuthOutcome, verdict, reason, permitted, escrowed, req, rules},
         policy,
         action
       ) do
    requirement =
      case req do
        {:some, r} -> decode_requirement(r)
        :none -> nil
      end

    %{
      verdict: decode_verdict(verdict),
      reason: decode_reason(reason, requirement),
      policy: identity(policy),
      action: action,
      permitted: decode_writes(permitted),
      escrowed: decode_writes(escrowed),
      requirement: requirement,
      rules: Enum.map(rules, &text/1)
    }
  end

  @doc false
  def decode_reason(:ReasonAllowed, _), do: :allowed
  def decode_reason(:ReasonAsk, req), do: {:ask, req}
  def decode_reason({:ReasonRule, id}, _), do: {:rule, text(id)}
  def decode_reason(:ReasonNoMatchingRule, _), do: :no_matching_rule
  def decode_reason(:ReasonAuthorityExceeded, _), do: :authority_exceeded

  @doc false
  def decode_class(:FailInvalidInput), do: :invalid_input
  def decode_class(:FailUnavailableContext), do: :unavailable_context

  @doc false
  def decode_failure(:MissingRequirement), do: :missing_requirement

  def decode_failure({:AmbiguousRequirement, rs}),
    do: {:ambiguous_requirement, Enum.map(rs, &decode_requirement/1)}
end
