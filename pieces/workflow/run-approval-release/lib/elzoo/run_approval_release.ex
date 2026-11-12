# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunApprovalRelease do
  @moduledoc """
  Serialized durable Run/Attempt owner. The consumer supplies a held lease,
  trusted commands and existing EffectIntent startup bindings. No restoration
  sends an effect, creates an Attempt, or grants approval.
  """
  use GenServer
  alias Elzoo.{Approval, EffectIntent, Lease}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}
  alias Elzoo.EffectIntent.{Binding, Model}

  @outcomes [:completed, :failed, :cancelled, :out_of_budget, :out_of_time]
  @fields %{
    create: [:operation_id, :provider_refs],
    begin_attempt: [:attempt_id],
    attach_child: [:attempt_id, :child_run_id, :child_pid],
    child_result: [:attempt_id, :child_run_id, :child_completion_revision],
    complete: [:attempt_id, :outcome, :reason, :evidence_ref],
    cancel: [:attempt_id],
    approval_request: [:attempt_id, :decision],
    approval_evidence: [:attempt_id, :request_key, :evidence],
    release_approved: [:attempt_id, :request_key, :context],
    dispatch_approved: [:attempt_id, :request_key, :context, :intent],
    effect_result: [:attempt_id, :action_id, :intent_key, :evidence_ref]
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def command(owner, command), do: GenServer.call(owner, {:command, command})
  def status(owner, run_id), do: GenServer.call(owner, {:status, run_id})
  def outcome?(value), do: value in @outcomes

  def classify_attempt(current, supplied),
    do: if(id?(current) and current == supplied, do: :current, else: :stale)

  @doc "Store construction declarations; merge lease kinds, retain the entire Run stream."
  def fold do
    %{
      initial: %{runs: %{}, approvals: Approval.new()},
      kinds: Map.put(Lease.kinds(), "run", :state_bearing),
      versions: [1],
      reduce: fn state, "run", 1, bytes ->
        {:ok, event} = Model.decode_term(bytes, limits().max_record_bytes)
        apply_event(state, event)
      end
    }
  end

  def limits,
    do: %{max_record_bytes: 131_072, max_batch_size: 4, max_checkpoint_bytes: 1_048_576}

  @impl true
  def init(opts) do
    with true <- Keyword.keyword?(opts),
         %Lease{} = lease <- opts[:lease],
         %{live: %{key: stream}, owner: owner} = held <- opts[:held],
         true <- Codec.text?(stream) and id?(owner),
         true <- lease.store == opts[:store],
         true <- is_map(opts[:effect_intent]),
         :ok <- reconcile(lease, opts[:reconcile]),
         {:held, current} <- Lease.hold(lease, stream, owner),
         true <- current.live.revision == held.live.revision,
         {:ok, snapshot} <- load(lease.store, stream, 1, []),
         true <- elem(snapshot.cursor, 0) == held.live.revision do
      s = %{
        store: lease.store,
        lease: lease,
        held: held,
        stream: stream,
        model: snapshot.model,
        bindings: opts[:effect_intent],
        intents: %{},
        monitors: %{}
      }

      case settle_pending(s) do
        {:ok, s} -> {:ok, s}
        {reply, _} -> {:stop, {:recovery, reply}}
      end
    else
      _ -> {:stop, :unreconciled_or_invalid_startup}
    end
  rescue
    _ -> {:stop, :unreconciled_or_invalid_startup}
  end

  defp reconcile(_, nil), do: :ok

  defp reconcile(lease, receipt) do
    case Lease.confirm(lease, receipt) do
      {:committed, _} -> :ok
      :superseded -> :ok
      _ -> {:error, :unknown}
    end
  end

  defp load(store, stream, from, acc) do
    with {:ok, rows, head} <- Log.read(store, stream, from, 1_000),
         true <- head.low_water == 0 do
      if length(rows) == 1_000 do
        load(store, stream, List.last(rows).sequence + 1, acc ++ rows)
      else
        case Log.replay(acc ++ rows, head, fold()) do
          %{cursor: {_, false, []}, tail: :intact} = snapshot -> {:ok, snapshot}
          _ -> {:error, :damaged_log}
        end
      end
    else
      _ -> {:error, :unavailable_history}
    end
  end

  @impl true
  def handle_call({:status, id}, _, s) do
    reply =
      case Map.fetch(s.model.runs, id) do
        {:ok, run} -> {:ok, view(s, run)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, s}
  end

  def handle_call({:command, command}, _, s) do
    {reply, next} =
      case validate(command) do
        :ok -> execute(s, command)
        error -> {error, s}
      end

    case reply do
      {:indeterminate, info} -> {:stop, {:shutdown, {:indeterminate, info}}, reply, next}
      _ -> {:reply, reply, next}
    end
  end

  defp validate(c) when is_map(c) and not is_struct(c) do
    fields = Map.get(@fields, c[:kind])

    fields =
      if c[:kind] == :approval_evidence and Map.has_key?(c, :revoked_evidence_key),
        do: [:attempt_id, :request_key, :revoked_evidence_key],
        else: fields

    if fields && Enum.sort(Map.keys(c)) == Enum.sort([:kind, :run_id, :expected_revision | fields]) &&
         id?(c.run_id) && Codec.uint?(c.expected_revision) &&
         (c.kind == :create or id?(c.attempt_id)), do: :ok, else: {:refused, :invalid_command}
  end

  defp validate(_), do: {:refused, :invalid_command}

  defp execute(s, %{kind: :create} = c) do
    cond do
      not id?(c.operation_id) or not refs?(c.provider_refs) ->
        {{:refused, :invalid_command}, s}

      Map.has_key?(s.model.runs, c.run_id) ->
        run = s.model.runs[c.run_id]

        if run.operation_id == c.operation_id and run.provider_refs == c.provider_refs,
          do: unchanged(s, :duplicate),
          else: {{:refused, :identity_conflict}, s}

      true ->
        at_revision(s, c, fn ->
          persist(s, {:create, c.run_id, c.operation_id, c.provider_refs}, c.run_id)
        end)
    end
  end

  defp execute(s, c) do
    case Map.fetch(s.model.runs, c.run_id) do
      :error ->
        {{:error, :not_found}, s}

      {:ok, run} ->
        case classify_command(s, run, c) do
          :apply -> at_revision(s, c, fn -> perform(s, run, c) end)
          {:unchanged, reason} -> unchanged(s, reason)
          {:refused, reason} -> {{:refused, reason}, s}
        end
    end
  end

  defp classify_command(_, run, %{kind: :begin_attempt, attempt_id: id}) do
    cond do
      id == run.current_attempt -> {:unchanged, :duplicate}
      id in run.attempts -> {:unchanged, :stale}
      run.outcome != nil -> {:unchanged, :terminal}
      true -> :apply
    end
  end

  defp classify_command(_, run, %{kind: :effect_result} = c) do
    case run.effects[c.action_id] do
      %{attempt_id: attempt} when attempt != c.attempt_id ->
        {:unchanged, :stale}

      %{attempt_id: attempt, key: key, evidence_ref: ref}
      when attempt == c.attempt_id and key == c.intent_key and ref != nil and ref == c.evidence_ref ->
        {:unchanged, :duplicate}

      nil ->
        if classify_attempt(run.current_attempt, c.attempt_id) == :stale,
          do: {:unchanged, :stale},
          else: :apply

      _ ->
        :apply
    end
  end

  defp classify_command(s, run, c) do
    cond do
      classify_attempt(run.current_attempt, c.attempt_id) == :stale ->
        {:unchanged, :stale}

      run.outcome != nil and c.kind == :complete ->
        if {run.outcome, run.reason, run.evidence_ref} == {c.outcome, c.reason, c.evidence_ref},
          do: {:unchanged, :duplicate},
          else: {:refused, :terminal_conflict}

      run.outcome != nil ->
        {:unchanged, :terminal}

      c.kind == :approval_request and
          match?({:ok, _, _, nil}, Approval.request(s.model.approvals, c.run_id, c.decision)) ->
        {:ok, _, request, nil} = Approval.request(s.model.approvals, c.run_id, c.decision)

        cond do
          run.requests[request.key] == c.attempt_id -> {:unchanged, :duplicate}
          Map.has_key?(run.effects, elem(request.key, 1)) -> {:refused, :intent_mismatch}
          true -> :apply
        end

      c.kind == :approval_evidence and Map.has_key?(c, :evidence) and
          run.evidence[c.request_key] == c.evidence ->
        {:unchanged, :duplicate}

      c.kind == :attach_child and Map.has_key?(run.children, c.child_run_id) ->
        if run.children[c.child_run_id].attempt_id == c.attempt_id,
          do: {:unchanged, :duplicate},
          else: {:refused, :attachment_conflict}

      c.kind == :child_result and is_integer(c.child_completion_revision) and
          get_in(run.children, [c.child_run_id, :settled]) == c.child_completion_revision ->
        {:unchanged, :duplicate}

      true ->
        :apply
    end
  end

  defp at_revision(s, c, fun),
    do:
      if(c.expected_revision == s.held.live.revision, do: fun.(), else: {{:refused, :conflict}, s})

  defp unchanged(s, reason), do: {{:unchanged, reason, s.held.live.revision}, s}

  defp perform(s, _, %{kind: :begin_attempt} = c),
    do: persist(s, {:attempt, c.run_id, c.attempt_id}, c.attempt_id)

  defp perform(s, _, %{kind: :attach_child} = c) do
    child = s.model.runs[c.child_run_id]

    cond do
      not id?(c.child_run_id) or c.child_run_id == c.run_id or
          not (is_pid(c.child_pid) or is_nil(c.child_pid)) ->
        {{:refused, :invalid_child}, s}

      child == nil ->
        {{:refused, :child_not_found}, s}

      child.parent != nil ->
        {{:refused, :attachment_conflict}, s}

      ancestor?(s.model.runs, c.run_id, c.child_run_id) ->
        {{:refused, :attachment_conflict}, s}

      true ->
        {reply, s} = persist(s, {:attach, c.run_id, c.attempt_id, c.child_run_id}, c.child_run_id)

        if match?({:ok, _, _}, reply) and is_pid(c.child_pid) do
          ref = Process.monitor(c.child_pid)

          {reply,
           %{s | monitors: Map.put(s.monitors, ref, {c.run_id, c.child_run_id, c.attempt_id})}}
        else
          {reply, s}
        end
    end
  end

  defp perform(s, run, %{kind: :child_result} = c) do
    child = s.model.runs[c.child_run_id]
    link = run.children[c.child_run_id]

    if child && link && link.attempt_id == c.attempt_id && child.outcome != nil &&
         child.completion_revision == c.child_completion_revision do
      persist(
        s,
        {:child_settled, c.run_id, c.child_run_id, c.child_completion_revision},
        c.child_run_id
      )
    else
      {{:refused, :child_completion}, s}
    end
  end

  defp perform(s, _, %{kind: :cancel} = c),
    do: finish(s, c.run_id, :cancelled, nil, nil)

  defp perform(s, _, %{kind: :complete} = c) do
    with true <- outcome?(c.outcome) and (is_nil(c.reason) or id?(c.reason)),
         :ok <- completion_evidence(s, c) do
      finish(s, c.run_id, c.outcome, c.reason, c.evidence_ref)
    else
      _ -> {{:refused, :completion_evidence}, s}
    end
  end

  defp perform(s, _, %{kind: :approval_request} = c) do
    case Approval.request(s.model.approvals, c.run_id, c.decision) do
      {:ok, _, request, event} ->
        persist(s, {:approval, c.run_id, c.attempt_id, request.key, event}, request.key)

      {:error, reason} ->
        {{:error, reason}, s}
    end
  end

  defp perform(s, run, %{kind: :approval_evidence} = c) do
    case request_for(s, run, c.request_key, c.attempt_id) do
      nil -> {{:refused, :unknown_request}, s}
      _ -> store_evidence(s, run, c)
    end
  end

  defp perform(s, run, %{kind: :dispatch_approved} = c) do
    with request when not is_nil(request) <- request_for(s, run, c.request_key, c.attempt_id),
         {:ok, intent} <- intent_binding(s, c.intent),
         action_id = elem(request.key, 1),
         existing = run.effects[action_id],
         true <-
           existing == nil or (existing.intent == intent and existing.attempt_id == c.attempt_id),
         {:ok, s} <- bind_intent(s, c, intent, existing),
         {:ok, s} <- release(s, c) do
      dispatch(s, c, intent)
    else
      nil ->
        {{:refused, :unknown_request}, s}

      false ->
        {{:refused, :intent_mismatch}, s}

      {:refused, reason} ->
        {{:refused, reason}, s}

      {:error, reason} ->
        {{:error, reason}, s}

      {:waiting, next} ->
        effect = next.model.runs[c.run_id].effects[elem(c.request_key, 1)]

        {{:ok, next.held.live.revision,
          dispatch_view(effect, :waiting_approval, :no_retained_consent, nil)}, next}

      {reply, next} ->
        {reply, next}
    end
  end

  defp perform(s, run, %{kind: :release_approved} = c) do
    with request when not is_nil(request) <- request_for(s, run, c.request_key, c.attempt_id),
         {:ok, next} <- release(s, c) do
      {{:ok, next.held.live.revision, %{approval: :released, request_key: c.request_key}}, next}
    else
      nil ->
        {{:refused, :unknown_request}, s}

      {:waiting, next} ->
        {{:ok, next.held.live.revision, %{approval: :waiting, request_key: c.request_key}}, next}

      {reply, next} ->
        {reply, next}
    end
  end

  defp perform(s, run, %{kind: :effect_result} = c) do
    effect = run.effects[c.action_id]

    with true <- effect != nil and effect.attempt_id == c.attempt_id and effect.key == c.intent_key,
         {:ok, evidence} <- evidence(s, c.evidence_ref),
         true <-
           evidence[:run_id] == c.run_id and evidence[:attempt_id] == c.attempt_id and
             evidence[:action_id] == c.action_id and evidence[:intent_key] == c.intent_key and
             evidence[:classification] == :settled do
      if effect.evidence_ref == c.evidence_ref,
        do: unchanged(s, :duplicate),
        else:
          persist(
            s,
            {:effect, c.run_id, c.action_id, :settled, nil, c.evidence_ref},
            dispatch_view(effect, :settled, nil, c.evidence_ref)
          )
    else
      _ -> {{:refused, :effect_evidence}, s}
    end
  end

  defp store_evidence(s, _run, %{revoked_evidence_key: key} = c) do
    case Approval.revoke(s.model.approvals, key) do
      {:ok, _, event} ->
        persist(s, {:approval, c.run_id, c.attempt_id, c.request_key, event}, c.request_key)

      {:error, reason} ->
        {{:error, reason}, s}
    end
  end

  defp store_evidence(s, run, c) do
    if valid_evidence?(c.evidence, c.request_key) do
      case run.evidence[c.request_key] do
        evidence when evidence == c.evidence -> unchanged(s, :duplicate)
        _ -> persist(s, {:evidence, c.run_id, c.request_key, c.evidence}, c.request_key)
      end
    else
      {{:refused, :invalid_evidence}, s}
    end
  end

  defp release(s, c) do
    approval = Approval.inspect_state(s.model.approvals)

    if Enum.any?(approval.releases, &(&1.key == c.request_key)) do
      case Approval.revalidate(s.model.approvals, c.request_key, c.context) do
        :ok -> {:ok, s}
        failure -> {failure, s}
      end
    else
      source = s.model.runs[c.run_id].evidence[c.request_key] || :retained

      selection =
        if source == :retained,
          do: Approval.select_retained(s.model.approvals, c.request_key, c.context),
          else: {:ok, source}

      case selection do
        {:ok, _} ->
          case Approval.release(s.model.approvals, c.request_key, source, c.context) do
            {:released, _, _, event} ->
              case persist(
                     s,
                     {:approval, c.run_id, c.attempt_id, c.request_key, event},
                     c.request_key
                   ) do
                {{:ok, _, _}, next} -> {:ok, next}
                other -> other
              end

            {:refused, reason, _} ->
              {{:refused, reason}, s}

            {:error, reason, _} ->
              {{:error, reason}, s}
          end

        {:refused, :no_retained_consent} ->
          {:waiting, s}

        failure ->
          {failure, s}
      end
    end
  end

  defp intent_binding(s, intent) do
    with true <- is_map(intent) and not is_struct(intent),
         true <-
           Enum.sort(Map.keys(intent)) ==
             Enum.sort([:identity, :arguments, :binding_ref, :deadline]),
         true <- Model.valid_identity?(intent.identity),
         true <- is_binary(intent.arguments) and byte_size(intent.arguments) <= 65_536,
         true <- Binding.uint?(intent.deadline) and id?(intent.binding_ref),
         opts when is_list(opts) <- s.bindings[intent.binding_ref],
         {:ok, binding} <- Binding.load(opts[:binding]),
         [_, account, adapter, operation, _] <- intent.identity,
         true <-
           {account, adapter, operation} ==
             {binding.provider_account, binding.id, binding.operation} do
      {:ok, Map.put(intent, :binding_digest, binding.digest)}
    else
      _ -> {:refused, :intent_binding}
    end
  end

  defp bind_intent(s, c, intent, nil) do
    case persist(
           s,
           {:intent, c.run_id, c.attempt_id, elem(c.request_key, 1), intent},
           Model.key(intent.identity)
         ) do
      {{:ok, _, _}, next} -> {:ok, next}
      other -> other
    end
  end

  defp bind_intent(s, _, _, _), do: {:ok, s}

  defp dispatch(s, c, intent) do
    action = elem(c.request_key, 1)
    effect = s.model.runs[c.run_id].effects[action]
    opts = s.bindings[intent.binding_ref]

    opts =
      Keyword.merge(opts,
        identity: intent.identity,
        arguments: intent.arguments,
        deadline: intent.deadline
      )

    if effect.classification in [:settled, :not_sent] do
      {{:ok, s.held.live.revision,
        dispatch_view(effect, effect.classification, effect.reason, effect.evidence_ref)}, s}
    else
      case intent_owner(s, effect.key, opts) do
        {:ok, pid, s} ->
          status = EffectIntent.status(pid)

          {classification, reason} =
            cond do
              not status.active -> {:reconciliation_required, :read_only}
              status.attempts > 0 -> {:unknown, :reserved}
              true -> first_dispatch(pid, intent, opts)
            end

          result = dispatch_view(effect, classification, reason, effect.evidence_ref)

          if {effect.classification, effect.reason} == {classification, reason},
            do: {{:ok, s.held.live.revision, result}, s},
            else:
              persist(
                s,
                {:effect, c.run_id, action, classification, reason, effect.evidence_ref},
                result
              )

        {:error, s} ->
          persist(
            s,
            {:effect, c.run_id, action, :reconciliation_required, :startup, nil},
            dispatch_view(effect, :reconciliation_required, :startup, nil)
          )
      end
    end
  end

  defp intent_owner(s, key, opts) do
    case s.intents[key] do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid, s}, else: start_intent(s, key, opts)

      nil ->
        start_intent(s, key, opts)
    end
  end

  defp start_intent(s, key, opts) do
    case EffectIntent.start_link(opts) do
      {:ok, pid} ->
        {:ok, pid, %{s | intents: Map.put(s.intents, key, pid)}}

      _ ->
        {:error, s}
    end
  end

  defp first_dispatch(pid, intent, opts) do
    now = opts[:clock].()

    if Binding.uint?(now) and now >= intent.deadline do
      {:not_sent, :expired}
    else
      case EffectIntent.advance(pid, :dispatch) do
        {:ok, :dispatched} ->
          {:dispatched, nil}

        {:error, reason} ->
          status = EffectIntent.status(pid)

          cond do
            not status.active ->
              {:unknown, :intent_write}

            status.attempts > 0 ->
              {:unknown, :reserved}

            reason == :schema ->
              {:not_sent, :schema}

            true ->
              time = opts[:clock].()

              if Binding.uint?(time) and time >= intent.deadline,
                do: {:not_sent, :expired},
                else: {:unknown, :not_dispatchable}
          end
      end
    end
  end

  defp request_for(s, run, key, attempt) do
    if is_tuple(key) and tuple_size(key) == 5 and elem(key, 0) == run.id and
         run.requests[key] == attempt,
       do: Enum.find(Approval.inspect_state(s.model.approvals).requests, &(&1.key == key)),
       else: nil
  end

  defp completion_evidence(_, %{outcome: outcome, evidence_ref: nil}) when outcome != :completed,
    do: :ok

  defp completion_evidence(s, c) do
    with {:ok, e} <- evidence(s, c.evidence_ref),
         true <-
           e[:run_id] == c.run_id and e[:attempt_id] == c.attempt_id and
             e[:operation_id] == s.model.runs[c.run_id].operation_id,
         true <- id?(e[:action_id]) do
      :ok
    else
      _ -> {:error, :evidence}
    end
  end

  defp evidence(s, %{stream: stream, sequence: seq} = ref) when map_size(ref) == 2 do
    with true <- Codec.text?(stream) and Codec.uint?(seq) and seq > 0,
         {:ok, row, head} when is_map(row) <- Store.read(s.store, :read_at, [stream, seq]),
         true <- seq <= head.revision and seq > head.low_water,
         true <- row.stream == stream and row.sequence == seq,
         true <- row.digest == Log.digest(row),
         {:ok, data} <- Model.decode_term(row.payload, limits().max_record_bytes),
         true <- is_map(data) do
      {:ok, data}
    else
      _ -> {:error, :evidence}
    end
  end

  defp evidence(_, _), do: {:error, :evidence}

  defp finish(s, id, outcome, reason, evidence_ref),
    do:
      persist(s, {:terminal, id, outcome, reason, evidence_ref, s.held.live.revision + 1}, outcome)

  defp persist(s, event, result) do
    payload = :erlang.term_to_binary(event, [:deterministic])

    case Lease.write(s.lease, s.held, [{"run", 1, payload}]) do
      {:held, held} ->
        next = %{s | held: held, model: apply_event(s.model, event)}
        {{:ok, held.live.revision, result}, next}

      {:fenced, _} ->
        {{:refused, :conflict}, s}

      {:indeterminate, info} ->
        {{:indeterminate, info}, s}

      {:rejected, reason} ->
        {{:refused, reason}, s}

      {:error, reason} ->
        {{:error, reason}, s}
    end
  end

  defp apply_event(s, {:create, id, operation, refs}) do
    run = %{
      id: id,
      operation_id: operation,
      provider_refs: refs,
      current_attempt: nil,
      attempts: [],
      outcome: nil,
      reason: nil,
      evidence_ref: nil,
      completion_revision: nil,
      parent: nil,
      children: %{},
      requests: %{},
      evidence: %{},
      effects: %{}
    }

    put_in(s.runs[id], run)
  end

  defp apply_event(s, {:attempt, id, attempt}) do
    update_in(s.runs[id], &%{&1 | current_attempt: attempt, attempts: &1.attempts ++ [attempt]})
  end

  defp apply_event(s, {:attach, id, attempt, child}) do
    s = put_in(s.runs[child].parent, %{run_id: id, attempt_id: attempt})

    put_in(s.runs[id].children[child], %{
      attempt_id: attempt,
      dead: false,
      pending: s.runs[child].completion_revision,
      settled: nil
    })
  end

  defp apply_event(s, {:child_dead, id, child}), do: put_in(s.runs[id].children[child].dead, true)

  defp apply_event(s, {:child_settled, id, child, revision}) do
    update_in(s.runs[id].children[child], &%{&1 | pending: nil, settled: revision})
  end

  defp apply_event(s, {:terminal, id, outcome, reason, ref, revision}) do
    s =
      update_in(
        s.runs[id],
        &%{&1 | outcome: outcome, reason: reason, evidence_ref: ref, completion_revision: revision}
      )

    case s.runs[id].parent do
      nil -> s
      %{run_id: parent} -> put_in(s.runs[parent].children[id].pending, revision)
    end
  end

  defp apply_event(s, {:approval, id, attempt, key, nil}),
    do: put_in(s.runs[id].requests[key], attempt)

  defp apply_event(s, {:approval, id, attempt, key, event}) do
    {:ok, approvals} = Approval.apply_event(s.approvals, event)
    s = %{s | approvals: approvals}
    put_in(s.runs[id].requests[key], attempt)
  end

  defp apply_event(s, {:evidence, id, key, evidence}),
    do: put_in(s.runs[id].evidence[key], evidence)

  defp apply_event(s, {:intent, id, attempt, action, intent}) do
    put_in(s.runs[id].effects[action], %{
      action_id: action,
      attempt_id: attempt,
      intent: intent,
      key: Model.key(intent.identity),
      classification: :waiting_approval,
      reason: nil,
      evidence_ref: nil
    })
  end

  defp apply_event(s, {:effect, id, action, classification, reason, ref}) do
    update_in(
      s.runs[id].effects[action],
      &%{&1 | classification: classification, reason: reason, evidence_ref: ref}
    )
  end

  defp settle_pending(s) do
    Enum.reduce_while(s.model.runs, {:ok, s}, fn {id, run}, {:ok, acc} ->
      Enum.reduce_while(run.children, {:ok, acc}, fn {child, link}, {:ok, acc} ->
        if link.pending && run.outcome == nil &&
             classify_attempt(run.current_attempt, link.attempt_id) == :current do
          case persist(acc, {:child_settled, id, child, link.pending}, child) do
            {{:ok, _, _}, next} -> {:cont, {:ok, next}}
            other -> {:halt, other}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, _} = ok -> {:cont, ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.pop(s.monitors, ref) do
      {nil, _} ->
        {:noreply, s}

      {{id, child, _attempt}, monitors} ->
        {reply, s} = persist(%{s | monitors: monitors}, {:child_dead, id, child}, child)

        case reply do
          {:indeterminate, info} -> {:stop, {:shutdown, {:indeterminate, info}}, s}
          _ -> {:noreply, s}
        end
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    for {_, pid} <- s.intents, Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  defp view(s, run) do
    approvals = Approval.inspect_state(s.model.approvals)

    run
    |> Map.drop([:evidence, :requests, :effects])
    |> Map.put(:revision, s.held.live.revision)
    |> Map.put(
      :approvals,
      for(
        r <- approvals.requests,
        elem(r.key, 0) == run.id,
        do: %{request_key: r.key, status: r.status}
      )
    )
    |> Map.put(
      :effects,
      Map.new(run.effects, fn {id, e} ->
        classification = if e.classification == :dispatched, do: :unknown, else: e.classification
        {id, dispatch_view(e, classification, e.reason, e.evidence_ref)}
      end)
    )
  end

  defp dispatch_view(e, classification, reason, ref),
    do: %{
      classification: classification,
      action_id: e.action_id,
      intent_key: e.key,
      reason: reason,
      evidence_ref: ref
    }

  defp ancestor?(runs, id, child) do
    case runs[id].parent do
      nil -> false
      %{run_id: ^child} -> true
      %{run_id: parent} -> ancestor?(runs, parent, child)
    end
  end

  defp id?(value), do: Codec.stream?(value)

  defp refs?(refs),
    do:
      is_map(refs) and not is_struct(refs) and map_size(refs) <= 64 and
        Enum.all?(refs, fn {k, v} -> id?(k) and id?(v) end)

  defp valid_evidence?(e, key) when is_map(e) and not is_struct(e) do
    Enum.sort(Map.keys(e)) ==
      Enum.sort([
        :verifier,
        :evidence_id,
        :reviewer,
        :request,
        :decision,
        :scope,
        :issued_at,
        :expiry
      ]) and
      Enum.all?(
        [e[:verifier], e[:evidence_id], e[:reviewer]],
        &match?({:ok, _}, Elzoo.Authorization.identity_field(&1, :evidence, :invalid_input))
      ) and e[:request] == key and
      e[:decision] in [:approve, :reject] and e[:scope] in [:once, :run, :root] and
      Binding.uint?(e[:issued_at]) and Binding.uint?(e[:expiry]) and e.expiry > e.issued_at
  end

  defp valid_evidence?(_, _), do: false
end
