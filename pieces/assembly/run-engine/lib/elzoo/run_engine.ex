# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunEngine do
  @moduledoc "Recorded pattern cycles composed with the existing Run and action owners."
  use GenServer
  alias Elzoo.{Aggregation, AsyncWork, Authorization, BotRunLifecycle, Budget, DurableUnit}
  alias Elzoo.{DynamicUnits, EffectIntent, Outbox, PatternStep, PayloadSchema, RunResource}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.EffectIntent.Binding

  @record_bytes 16_777_216
  @ingress_bytes 262_144
  @control_bytes 2_097_152
  @request_bytes 4_456_448
  @slot_bytes 131_072
  @empty %{version: 1, control: nil, slots: %{}, requests: %{}}
  @empty_v2 %{version: 2, control: nil, slots: %{}, requests: %{}}
  @refusal_schema "elzoo.run-engine.refusal"
  @call_limit 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def input(engine, id, input, context),
    do: GenServer.call(engine, {:input, id, input, context}, @call_limit)

  def control(engine, id, command, context),
    do: GenServer.call(engine, {:control, id, command, context}, @call_limit)

  def status(engine), do: GenServer.call(engine, :status, @call_limit)

  def result(engine, scope, limits),
    do: GenServer.call(engine, {:result, scope, limits}, @call_limit)

  def event_waits(engine, scope, limits),
    do: GenServer.call(engine, {:event_waits, scope, limits}, @call_limit)

  def transcript(engine, scope, limits),
    do: GenServer.call(engine, {:transcript, scope, limits}, @call_limit)

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  # The host's DynamicUnits unit_options uses {__MODULE__, :step, the literal
  # empty state above}. Configuration is itself recorded, never a process lookup
  # from inside the transition. Only MFAs and plain declarations survive replay.
  def step(@empty, %{version: 1, kind: :configure, control: control}),
    do: configure(@empty, control)

  def step(@empty_v2, %{version: 2, kind: :configure, control: control}),
    do: configure(@empty_v2, control)

  def step(%{version: version, control: control} = state, %{version: version} = record)
      when version in [1, 2] and is_map(control),
      do: step_record(state, record)

  defp configure(empty, control) do
    next = %{empty | control: control}
    true = fits?(next)
    {:Transition, next, :none}
  end

  defp step_record(state, record) do
    {next, output} = transition(state, record)

    next = finalize_step_state(next)
    true = fits?(next)
    {:Transition, next, output}
  end

  defp finalize_step_state(next) do
    slots =
      Map.new(next.slots, fn {key, slot} ->
        discard =
          next.control.generation_closed or next.control.lifecycle.phase == :terminal or
            slot.attempt_id != next.control.attempt_id or
            next.control.callables[slot.callable].closed

        {key, if(discard, do: Map.delete(slot, :pending_input), else: slot)}
      end)

    next = %{next | slots: slots}

    # A kept finish is dropped once its parent action is settled: the parent
    # outcome carries it, and kept payloads must not accumulate in control.
    callables =
      Map.new(next.control.callables, fn {id, node} ->
        if node[:finish] && next.slots[node.parent].phase == :settled,
          do: {id, Map.delete(node, :finish)},
          else: {id, node}
      end)

    next = put_in(next.control.callables, callables)

    requests =
      Map.reject(next.requests, fn {ordinal, _} ->
        next.slots
        |> Enum.filter(fn {{request, _}, _} -> request == ordinal end)
        |> Enum.all?(fn {_, slot} -> slot.phase in [:running, :waiting, :settled, :reconcile] end)
      end)

    next = %{next | requests: requests}
    next
  end

  defp empty_state(1), do: @empty
  defp empty_state(2), do: @empty_v2

  defp decode_step(input, 1), do: PatternStep.decode(input)
  defp decode_step(input, 2), do: PatternStep.decode(input, 2)

  defp decode_request(request, 1) do
    with {:ok, {:PatternStep, map} = checked} <- PatternStep.decode(request),
         do: {:ok, checked, map}
  end

  defp decode_request(request, 2) do
    with {:ok, {:PatternStepV2, map} = checked} <- PatternStep.decode(request, 2),
         do: {:ok, checked, map}
  end

  defp protocol_version(s), do: Map.get(s.opts, :protocol_version, 1)

  defp lifecycle_step(state, input, context) do
    lifecycle_decide(lifecycle(state, nil), input, context, state.version)
  end

  defp lifecycle_decide(life, input, context, 1), do: BotRunLifecycle.step(life, input, context)
  defp lifecycle_decide(life, input, context, 2), do: BotRunLifecycle.step(life, input, context, 2)

  defp transition(state, %{kind: :protocol} = record) do
    input = record.input

    case protocol_transition(state, record) do
      {:done, result} ->
        result

      {:continue, state, accepted, callable} ->
        if accepted and not state.control.generation_closed and
             is_nil(state.control.stop_pending) and state.control.lifecycle.phase != :paused and
             not state.control.callables[callable].closed do
          if input["kind"] in ["action_outcome", "person_answer"] or
               fits?(
                 put_in(state.control.invocations[record.id], digest({input, record.correlation}))
               ) do
            invoke(state, record, callable)
          else
            {classify(state, :record_size), :none}
          end
        else
          if accepted and state.control.lifecycle.phase == :paused and
               not state.control.generation_closed and is_nil(state.control.stop_pending) and
               not state.control.callables[callable].closed and
               record.correlation[:occurrence] != nil do
            key = record.correlation.occurrence

            if state.version == 2 do
              case paused_pending_input(state, record) do
                {:ok, next} ->
                  if fits?(next),
                    do: {next, :none},
                    else: {classify(state, :record_size), :none}

                {:error, _} ->
                  {classify(state, :record_size), :none}
              end
            else
              order =
                Enum.reduce(state.slots, 0, fn {_, slot}, n ->
                  max(n, (slot[:pending_input] || %{order: 0}).order)
                end)

              pending = %{order: order + 1, record: %{record | input: Jason.encode!(record.input)}}
              {put_in(state.slots[key][:pending_input], pending), :none}
            end
          else
            {state, :none}
          end
        end
    end
  end

  defp transition(state, %{kind: :nested_actual, occurrence: key, actual: actual, at_ms: at}) do
    slot = state.slots[key]

    if slot.phase == :settled and is_nil(slot[:actual]) do
      state = settle_budget(state, key, actual, at)
      {put_in(state.slots[key][:actual], actual), :none}
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :resume_input, occurrence: key}) do
    slot = state.slots[key]

    if not is_nil(slot[:pending_input]) and
         state.control.lifecycle.phase not in [:paused, :terminal] and
         not state.control.generation_closed and is_nil(state.control.stop_pending) and
         not state.control.callables[slot.callable].closed do
      record = slot.pending_input.record
      state = state |> update_in([:slots, key], &Map.delete(&1, :pending_input)) |> resume_phase()
      invoke(state, %{record | input: Jason.decode!(record.input)}, slot.callable)
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :configure, control: control}) do
    true = state.control.lifecycle.phase == :terminal and active_count(state) == 0
    true = state.control.run_id != control.run_id
    {%{empty_state(state.version) | control: %{control | lifetime: state.control.lifetime}}, :none}
  end

  defp transition(state, %{kind: :precheck, occurrence: key, reason: reason}) do
    if state.slots[key].phase == :checking,
      do: {deny(state, key, reason), :none},
      else: {state, :none}
  end

  defp transition(state, %{kind: :gate, request: request, entries: entries} = record) do
    true = length(entries) <= 64

    next =
      Enum.reduce(entries, state, fn entry, acc ->
        key = {request, entry.index}
        slot = Map.fetch!(acc.slots, key)

        true =
          entry.gate_id == acc.control.gate.id and entry.gate_version == acc.control.gate.version

        true = entry.verdict in [:allow, :deny]

        if is_nil(slot.verdict) and slot.phase == :checking do
          slot = %{
            slot
            | verdict: Map.take(entry, [:verdict, :reason, :gate_id, :gate_version]),
              phase: if(entry.verdict == :allow, do: :allowed, else: :refusing)
          }

          put_in(acc.slots[key], slot)
        else
          acc
        end
      end)

    {classify(next, {:gate, record.request}), :none}
  end

  defp transition(state, %{kind: :admission, occurrence: key, facts: facts, at_ms: at}) do
    slot = Map.fetch!(state.slots, key)

    if slot.phase == :allowed do
      true = slot.verdict.verdict == :allow
      c = state.control

      cond do
        c.lifecycle.phase == :paused ->
          {state, :none}

        c.lifecycle.phase == :terminal or c.stop_pending != nil ->
          {deny(state, key, "run_terminal"), :none}

        Run.classify_attempt(c.attempt_id, slot.attempt_id) == :stale ->
          {deny(state, key, "stale_attempt"), :none}

        at >= facts.deadline_ms ->
          {deny(state, key, "expired"), :none}

        not slot_fits?(Map.merge(slot, facts)) ->
          {deny(state, key, "record_size"), :none}

        state.version == 2 and slot.kind == "wait_event" and
          is_integer(Map.get(facts, :estimate)) and Map.get(facts, :estimate) == 0 ->
          admit_zero_estimate_wait(state, key, slot, facts, at)

        true ->
          before_budget = state
          budget_id = slot.callable
          budget = c.budgets[budget_id]

          {:Transition, next_budget, {:some, result}} =
            Budget.step(
              budget.state,
              {at,
               {:reserve,
                %{
                  cap: budget.cap,
                  unit: budget.unit,
                  estimate: facts.estimate,
                  cost_ref: occurrence_id(key),
                  expiry: facts.deadline_ms
                }}}
            )

          state = put_in(state.control.budgets[budget_id].state, next_budget)

          case result do
            {:reserved, reservation} ->
              slot = Map.merge(slot, facts)

              slot =
                if slot[:intent], do: Map.put(slot, :intent_digest, digest(slot.intent)), else: slot

              slot = Map.merge(slot, %{phase: :authorizing, reservation: reservation})
              admitted = put_in(state.slots[key], slot)

              # A first finish of a non-root child is kept in control until its parent
              # settles. The admitted state counts it as pending, so it is admitted only
              # when control with that finish in it fits; otherwise the Budget step is
              # dropped with the refusal and the child callable stays open.
              if keeps_first_finish?(c, slot) and not fits?(admitted),
                do: {deny(before_budget, key, "record_size"), :none},
                else: {admitted, :none}

            {:rejected, _} ->
              {deny(state, key, "out_of_budget"), :none}
          end
      end
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :authorization, occurrence: key, decision: decision, at_ms: at}) do
    slot = Map.fetch!(state.slots, key)

    if slot.phase == :authorizing do
      case decision do
        %{verdict: verdict} when verdict in [:allow, :ask] ->
          phase = if verdict == :ask, do: :approval, else: :ready
          {put_in(state.slots[key], Map.merge(slot, %{decision: decision, phase: phase})), :none}

        _ ->
          {release_and_deny(state, key, at, "authority"), :none}
      end
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :continuation, occurrence: key, phase: phase, facts: facts}) do
    slot = Map.fetch!(state.slots, key)

    if slot.phase in [:approval, :ready, :opening, :running, :reconcile] do
      {finish, facts} = Map.pop(facts, :finish)
      state = put_in(state.slots[key], Map.merge(slot, Map.put(facts, :phase, phase)))

      state =
        if facts[:finish_callable],
          do:
            update_in(
              state.control.callables[facts.finish_callable],
              &(&1 |> Map.put(:closed, true) |> Map.delete(:state))
            ),
          else: state

      # Only the first admitted finish of a child is kept.
      state =
        if finish && is_nil(state.control.callables[facts.finish_callable][:finish]),
          do: put_in(state.control.callables[facts.finish_callable][:finish], finish),
          else: state

      wait_kind =
        case slot.kind do
          "model_call" -> :model
          "tool_call" -> :tool
          "ask_person" -> :person
          _ -> nil
        end

      state =
        if wait_kind && phase in [:running, :waiting] do
          put_in(
            state.control.lifecycle.waits[slot.action_id],
            %{kind: wait_kind, attempt_id: slot.attempt_id, one_shot: true}
          )
        else
          state
        end

      state =
        if phase in [:running, :waiting] and state.control.lifecycle.phase == :active,
          do: put_in(state.control.lifecycle.phase, :waiting),
          else: state

      {state, :none}
    else
      {state, :none}
    end
  end

  defp transition(received, %{kind: :nested, occurrence: key, facts: facts, at_ms: at} = record) do
    state = received
    slot = Map.fetch!(state.slots, key)

    if slot.phase == :ready and permitted?(state, slot, at) do
      {:ok, budget} = Budget.initial(facts.budget_id, facts.incarnation, slot.estimate, slot.unit)
      callable = occurrence_id(key)

      child = %{
        mfa: facts.mfa,
        state: facts.initial_state,
        closed: false,
        parent: key,
        authority: slot.decision.permitted,
        depth: state.control.callables[slot.callable].depth + 1,
        state_bytes: Map.get(facts, :state_bytes, 65_536)
      }

      state = put_in(state.control.callables[callable], child)

      state =
        put_in(state.control.budgets[callable], %{
          state: budget,
          cap: slot.estimate,
          unit: slot.unit
        })

      state = put_in(state.slots[key].phase, :running)

      input = %{
        "type" => "input",
        "version" => state.version,
        "kind" => "start",
        "at_ms" => at,
        "schema_id" => facts.schema_id,
        "schema_version" => facts.schema_version,
        "payload" => facts.payload
      }

      {next, output} =
        invoke(
          state,
          Map.merge(record, %{
            input: input,
            correlation: %{occurrence: key}
          }),
          callable
        )

      if fits?(next),
        do: {next, output},
        else: {release_and_deny(received, key, at, "record_size"), :none}
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :run_view, view: view}) do
    c = state.control
    true = c.run_id == view.id

    state =
      if view.current_attempt != c.attempt_id do
        state
        |> close_local(view.at_ms)
        |> close_attempt(view.current_attempt, view.at_ms)
        |> drop_stale_failure()
      else
        state
      end

    state = put_in(state.control.attempt_id, view.current_attempt)
    state = put_in(state.control.run_revision, view.revision)
    state = put_in(state.control.operation_id, view.operation_id)

    state =
      if view.current_attempt != c.attempt_id do
        state
        |> put_in([:control, :lifecycle, :waits], %{})
        |> put_in([:control, :lifecycle, :phase], :active)
      else
        state
      end

    state =
      if view.outcome do
        state
        |> put_in([:control, :lifecycle, :phase], :terminal)
        |> put_in([:control, :lifecycle, :outcome], view.outcome)
        |> put_in([:control, :stop_pending], nil)
        |> close_run(view.at_ms)
      else
        state
      end

    {state, :none}
  end

  defp transition(state, %{kind: :lifecycle, command: command, context: context}) do
    {:ok, life, decision} =
      lifecycle_step(
        state,
        command,
        life_context(state, context, state.control.attempt_id, false, command.at_ms)
      )

    state = install_lifecycle(state, life, decision)
    state = restore_waiting(state)
    {classify(state, decision), :none}
  end

  # A root finish that names no action (its payload has `"action_id": null`, no
  # `action_id` key, or is not an object) ends the Run :failed: its own schema and
  # payload settle the finish slot, and that payload is the failure record.
  defp transition(state, %{kind: :finish, occurrence: key, source: nil, at_ms: at}) do
    slot = state.slots[key]

    if slot.phase == :ready and permitted?(state, slot, at) do
      true = slot.kind == "finish" and slot.callable == "root"
      true = is_nil(named_source(slot.action))
      input = internal_input(state, key, slot, "completed", nil, kept_finish(slot.action), at)
      state = settle_finish(state, key, slot, input, at)
      state = put_in(state.control.completion, key)
      state = put_in(state.control.generation_closed, true)
      {put_in(state.control.stop_pending, :failed), :none}
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :finish, occurrence: key, source: source, at_ms: at}) do
    slot = state.slots[key]

    if slot.phase == :ready and permitted?(state, slot, at) do
      true = state.slots[source].outcome == "completed"
      true = state.slots[source].attempt_id == slot.attempt_id

      input =
        outcome(
          state.version,
          slot.action_id,
          "completed",
          @refusal_schema,
          refusal(state, key, "finished"),
          at
        )

      state = settle_finish(state, key, slot, input, at)
      state = put_in(state.control.completion, source)
      state = put_in(state.control.generation_closed, true)
      {put_in(state.control.stop_pending, :completed), :none}
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :event_activation} = record) do
    key = record.occurrence
    slot = state.slots[key]

    if valid_activation?(state, record, key, slot) do
      wait = %{
        kind: :outside_event,
        attempt_id: slot.attempt_id,
        one_shot: true,
        source_id: record.source_id,
        correlation_id: record.ticket
      }

      life = lifecycle(state, elem(key, 0))
      life = %{life | waits: Map.put(life.waits, slot.action_id, wait)}
      state = install_lifecycle(state, life, :event_activation)

      slot =
        Map.merge(slot, %{
          phase: :waiting,
          event_source_id: record.source_id,
          event_source_version: record.source_version,
          event_cursor: record.cursor,
          event_ticket: record.ticket,
          activation_id: record.id,
          activation_at_ms: record.at_ms,
          actual: 0
        })

      state = put_in(state.slots[key], slot)
      true = fits?(state)
      {restore_waiting(state), :none}
    else
      {classify(state, :incompatible), :none}
    end
  end

  defp transition(state, %{
         kind: :resource_cursor,
         resource: resource,
         sequence: sequence,
         budget_owner: budget_owner,
         budget_command: command,
         at_ms: at
       }) do
    if sequence > Map.get(state.control.cursors, resource, 0) do
      state =
        if command do
          budget = state.control.budgets[budget_owner]
          {:Transition, next, {:some, result}} = Budget.step(budget.state, {at, command})
          true = elem(result, 0) in [:settled, :released]
          state = put_in(state.control.budgets[budget_owner].state, next)
          {kind, fields} = command

          key =
            Enum.find_value(state.slots, fn {key, slot} ->
              if (slot.callable == budget_owner and slot[:reservation]) &&
                   Map.take(slot.reservation, [:cost_ref, :generation]) ==
                     Map.take(fields, [:cost_ref, :generation]),
                 do: key
            end)

          put_in(state.slots[key][:actual], if(kind == :release, do: 0, else: fields.actual))
        else
          state
        end

      {put_in(state.control.cursors[resource], sequence), :none}
    else
      {state, :none}
    end
  end

  defp admit_zero_estimate_wait(state, key, slot, facts, at) do
    budget_id = slot.callable
    budget = state.control.budgets[budget_id]

    case Budget.step(budget.state, {at, :status}) do
      {:Transition, next_budget, {:some, {:status, _status}}} ->
        state = put_in(state.control.budgets[budget_id].state, next_budget)
        slot = Map.merge(slot, facts)

        slot =
          if slot[:intent], do: Map.put(slot, :intent_digest, digest(slot.intent)), else: slot

        slot = Map.merge(slot, %{phase: :authorizing, reservation: nil})
        {put_in(state.slots[key], slot), :none}

      _ ->
        {deny(state, key, "out_of_budget"), :none}
    end
  end

  defp valid_activation?(%{version: 2, control: control} = state, record, key, slot)
       when is_map(control) and is_map(record) and is_map(slot) do
    source = control[:event_source]

    keys = [
      :version,
      :kind,
      :id,
      :occurrence,
      :attempt_id,
      :source_id,
      :source_version,
      :ticket,
      :cursor,
      :deadline_ms,
      :at_ms
    ]

    is_map(source) and map_size(source) == 2 and Map.keys(record) |> Enum.sort() == Enum.sort(keys) and
      control[:protocol_version] == 2 and record.version == 2 and
      record.kind == :event_activation and record.occurrence == key and
      slot.phase == :ready and slot.attempt_id == record.attempt_id and
      control.attempt_id == record.attempt_id and slot.deadline_ms == record.deadline_ms and
      record.source_id == source.id and record.source_version == source.version and
      slot.kind == "wait_event" and
      is_integer(record.cursor) and record.cursor >= 0 and is_integer(record.at_ms) and
      record.at_ms > 0 and permitted?(state, slot, record.at_ms) and
      record.id ==
        Elzoo.RunEngine.event_activation_id(
          control.run_id,
          record.attempt_id,
          key,
          source.id
        ) and
      record.ticket ==
        Elzoo.RunEngine.event_ticket(
          control.tenant,
          control.principal,
          control.run_id,
          record.attempt_id,
          key,
          source.id
        )
  end

  defp valid_activation?(_, _, _, _), do: false

  defp protocol_transition(state, record) do
    c = state.control
    input = record.input

    cond do
      record.run_id != c.run_id or Run.classify_attempt(c.attempt_id, record.attempt_id) == :stale ->
        {:done, {classify(state, :late), :none}}

      Map.has_key?(c.invocations, record.id) ->
        true = c.invocations[record.id] == digest({input, record.correlation})
        {:done, {classify(state, :duplicate), :none}}

      true ->
        state = expire_and_report(state, input["at_ms"], record.context)
        {state, accepted, callable} = protocol(state, record)

        state =
          if state.control.lifecycle.phase == :terminal,
            do: close_run(state, input["at_ms"]),
            else: state

        {:continue, state, accepted, callable}
    end
  end

  defp protocol(state, record) do
    input = record.input
    kind = input["kind"]
    c = state.control
    key = record.correlation[:occurrence]

    cond do
      kind in ["action_outcome", "person_answer", "outside_event"] ->
        settle_protocol(state, record, key)

      kind == "wake" ->
        exhausted = c.count >= c.cap
        {:ok, checked} = decode_step(input, state.version)

        {:ok, life, decision} =
          lifecycle_step(
            state,
            checked,
            life_context(state, record.context, record.attempt_id, exhausted, input["at_ms"])
          )

        next = install_lifecycle(state, life, decision)
        next = if exhausted, do: put_in(next.control.generation_closed, true), else: next
        next = if exhausted, do: put_in(next.control.charge_stopped, true), else: next

        {classify(next, decision),
         decision == :permit_new_work and not exhausted and active_count(next) == 0, "root"}

      kind == "cancel" ->
        {:ok, checked} = decode_step(input, state.version)

        {:ok, life, decision} =
          lifecycle_step(
            state,
            checked,
            life_context(state, record.context, record.attempt_id, false, input["at_ms"])
          )

        state = put_in(state.control.cancelled_attempt, record.attempt_id)
        state = install_lifecycle(state, life, decision) |> close_local(input["at_ms"])
        {classify(state, decision), false, "root"}

      kind == "run_ended" ->
        {classify(state, :late), false, "root"}

      kind == "resource_event" ->
        {next, allowed} = local_precedence(state, record, false)
        granted = Map.has_key?(c.cursors, record.correlation[:resource])

        {classify(next, if(granted, do: :resource_event, else: :incompatible)),
         granted and allowed and active_count(next) == 0, "root"}

      true ->
        {:ok, checked} = decode_step(input, state.version)

        {:ok, life, decision} =
          lifecycle_step(
            state,
            checked,
            life_context(state, record.context, record.attempt_id, false, input["at_ms"])
          )

        next = install_lifecycle(state, life, decision)

        # With `messages: :while_active` in control, a message reaches the root also
        # while slots are active (or a slot holds a pending input); it settles no slot.
        accepted =
          if kind == "message" and c[:messages] == :while_active,
            do: decision in [:permit_new_work, :remain_waiting],
            else: decision == :permit_new_work and active_count(next) == 0

        {classify(next, decision), accepted, "root"}
    end
  end

  defp settle_protocol(state, record, key) do
    slot = state.slots[key]
    input = record.input
    at = input["at_ms"]
    c = state.control

    cond do
      is_nil(slot) or slot.phase == :settled or slot.attempt_id != record.attempt_id or
        slot.action_id != input["action_id"] or input["outcome"] == "late" ->
        {classify(state, :late), false, "root"}

      input["kind"] == "person_answer" and
          (slot[:person_id] != input["person_id"] or
             record.context[:verified_person] != input["person_id"]) ->
        {classify(state, :incompatible), false, slot.callable}

      input["kind"] == "outside_event" and not valid_event_record?(state, record, key, slot) ->
        {classify(state, :incompatible), false, slot.callable}

      true ->
        record =
          if input["kind"] == "outside_event" do
            %{record | context: Map.put(record.context, :verified_event, event_verification(input))}
          else
            record
          end

        request = c.trackers[elem(key, 0)]
        {:ok, checked} = decode_step(input, state.version)
        # Charge closure changes generation permission, not the original tracker.
        # Deadline/cancel/stale/restart rules still classify the same occurrence.
        retained = retains?(c, slot, at)

        {state, acceptance} =
          cond do
            retained or
              slot.kind in [
                "local_work",
                "nested_callable",
                "finish",
                "resource_open",
                "resource_use",
                "resource_close"
              ] or slot.phase == :refusing or
                (slot.phase == :approval and input["outcome"] == "expired") ->
              {next, allowed} = local_precedence(state, record, retained or slot.phase == :refusing)

              if allowed,
                do: {next, PatternStep.accept(request.tracker, checked)},
                else: {next, {:late, request.tracker}}

            true ->
              life = lifecycle(state, elem(key, 0))

              {:ok, life, decision} =
                lifecycle_decide(
                  life,
                  checked,
                  life_context(state, record.context, record.attempt_id, false, at),
                  state.version
                )

              next = install_lifecycle(state, life, decision)

              accepted =
                if life.tracker != request.tracker,
                  do: {:applied, life.tracker},
                  else: {:late, request.tracker}

              {next, accepted}
          end

        case acceptance do
          {:applied, tracker} ->
            actual = if slot.kind == "wait_event", do: 0, else: record.correlation[:actual]

            join_correlation =
              if slot.kind == "wait_event",
                do: %{actual: 0, dispatch: "not_dispatched"},
                else: record.correlation

            state = put_in(state.control.trackers[elem(key, 0)].tracker, tracker)
            state = settle_join(state, key, input, join_correlation)
            state = settle_budget(state, key, actual, at)
            state = remove_slot_wait(state, slot)

            slot = settled_event_slot(slot, input, record, actual)

            state = put_in(state.slots[key], slot)

            state =
              if slot.kind == "nested_callable",
                do: close_child_callables(state, occurrence_id(key)),
                else: state

            state =
              if active_count(state) == 0 and state.control.lifecycle.phase == :waiting,
                do: put_in(state.control.lifecycle.phase, :active),
                else: state

            {state, _} = local_precedence(state, record, retained)
            {classify(restore_waiting(state), :applied), true, slot.callable}

          {:late, _} ->
            {classify(state, :late), false, slot.callable}

          {:refused, _, _} ->
            {classify(state, :incompatible), false, slot.callable}
        end
    end
  end

  # A reused occurrence is refused at admission, before it can install a wait.
  defp remove_slot_wait(state, %{refusal: "reused_identity"}), do: state

  defp remove_slot_wait(state, slot),
    do: update_in(state.control.lifecycle.waits, &Map.delete(&1, slot.action_id))

  defp settled_event_slot(slot, input, record, actual) do
    slot =
      Map.take(slot, [
        :action_id,
        :kind,
        :attempt_id,
        :callable,
        :verdict,
        :reservation,
        :decision,
        :person_id,
        :deadline_ms,
        :resource_name,
        :intent_digest,
        :request_key,
        :event_source_id,
        :event_source_version,
        :event_cursor,
        :event_ticket,
        :activation_id,
        :activation_at_ms,
        :event_receipt
      ])

    slot =
      Map.merge(slot, %{phase: :settled, outcome: input["outcome"] || "completed", actual: actual})

    if record.version == 2 and input["kind"] == "outside_event" do
      Map.put(slot, :event_receipt, %{
        input_id: record.id,
        sequence: record.correlation[:source_sequence]
      })
    else
      slot
    end
  end

  defp valid_event_record?(%{version: 2, control: control}, record, key, slot)
       when is_map(control) and is_map(record) and is_map(slot) do
    input = record.input
    correlation = record.correlation
    wait = control.lifecycle.waits[slot.action_id]
    source = control[:event_source]

    context_keys = [:pause_deadline]

    correlation_keys = [
      :occurrence,
      :actual,
      :source_version,
      :source_sequence,
      :source_head_revision,
      :activation_id,
      :event_digest
    ]

    is_map(source) and is_map(wait) and
      Map.keys(record) |> Enum.sort() == [
        :attempt_id,
        :context,
        :correlation,
        :id,
        :input,
        :kind,
        :run_id,
        :version
      ] and
      Map.keys(correlation) |> Enum.sort() == Enum.sort(correlation_keys) and
      Enum.all?(Map.keys(record.context), &(&1 in context_keys)) and
      record.kind == :protocol and record.version == 2 and record.run_id == control.run_id and
      record.attempt_id == control.attempt_id and record.attempt_id == slot.attempt_id and
      record.correlation.occurrence == key and record.correlation.actual == 0 and
      input["kind"] == "outside_event" and input["action_id"] == slot.action_id and
      slot.kind == "wait_event" and slot.phase == :waiting and
      input["at_ms"] < slot.deadline_ms and input["at_ms"] > 0 and
      input["source_id"] == slot.event_source_id and input["source_id"] == source.id and
      input["correlation_id"] == slot.event_ticket and
      record.correlation.activation_id == slot.activation_id and
      record.correlation.source_version == slot.event_source_version and
      source.version == slot.event_source_version and
      is_integer(record.correlation.source_sequence) and
      record.correlation.source_sequence > slot.event_cursor and
      is_integer(record.correlation.source_head_revision) and
      record.correlation.source_head_revision >= record.correlation.source_sequence and
      record.correlation.source_head_revision >= slot.event_cursor and
      record.correlation.event_digest ==
        Elzoo.RunEngine.event_digest(
          input["event_id"],
          input["source_id"],
          input["correlation_id"],
          record.correlation.source_sequence,
          record.correlation.source_version,
          input["schema_id"],
          input["schema_version"],
          input["payload"]
        ) and
      wait.kind == :outside_event and wait.attempt_id == slot.attempt_id and wait.one_shot == true and
      wait.source_id == slot.event_source_id and wait.correlation_id == slot.event_ticket
  rescue
    _ -> false
  end

  defp valid_event_record?(_, _, _, _), do: false

  defp event_verification(input),
    do: %{
      source_id: input["source_id"],
      correlation_id: input["correlation_id"],
      event_id: input["event_id"]
    }

  defp local_precedence(state, _record, true), do: {state, true}

  defp local_precedence(state, record, false) do
    {:ok, wake} =
      decode_step(
        %{
          "type" => "input",
          "version" => state.version,
          "kind" => "wake",
          "at_ms" => record.input["at_ms"]
        },
        state.version
      )

    {:ok, life, decision} =
      lifecycle_step(
        state,
        wake,
        life_context(state, record.context, record.attempt_id, false, record.input["at_ms"])
      )

    {install_lifecycle(state, life, decision),
     decision not in [:unchanged, :late] and
       (not match?({:request_outcome, _}, decision) or
          decision == {:request_outcome, :out_of_budget})}
  end

  # A :resume_input that gives its input (one retained while paused or a held expiry
  # report) and leaves no slot active and no wait listed makes a waiting Run active
  # again before its pattern call, as settle_protocol/3 does before the call of a
  # settling input; this holds for every Run (ELZ-351, ELZ-359). The event-wait reader
  # projects the same step through it.
  defp resume_phase(state) do
    if active_count(state) == 0 and map_size(state.control.lifecycle.waits) == 0 and
         state.control.lifecycle.phase == :waiting,
       do: put_in(state.control.lifecycle.phase, :active),
       else: state
  end

  defp restore_waiting(state) do
    if active_count(state) > 0 and state.control.lifecycle.phase == :active,
      do: put_in(state.control.lifecycle.phase, :waiting),
      else: state
  end

  defp close_local(state, at, select \\ fn _ -> true end) do
    Enum.reduce(state.slots, state, fn {key, slot}, acc ->
      if slot.kind == "local_work" and slot.phase == :running and select.(slot) do
        input =
          outcome(
            acc.version,
            slot.action_id,
            "failed",
            @refusal_schema,
            refusal(acc, key, "local_closed"),
            at
          )

        {:ok, checked} = decode_step(input, acc.version)

        {:applied, tracker} =
          PatternStep.accept(acc.control.trackers[elem(key, 0)].tracker, checked)

        acc = put_in(acc.control.trackers[elem(key, 0)].tracker, tracker)
        acc = settle_join(acc, key, input, %{loss: :unavailable})
        acc = remove_slot_wait(acc, slot)

        put_in(
          acc.slots[key],
          Map.merge(
            Map.take(slot, [:action_id, :kind, :attempt_id, :callable, :verdict]),
            %{phase: :settled, outcome: "failed"}
          )
        )
      else
        acc
      end
    end)
  end

  # The end of a Run settles every open slot that the request-cap stop does not
  # retain (in any other ending: all of them), in the same fold step, at the time
  # of the record: the terminal view, and each later protocol input of the
  # current Attempt that is not a duplicate (also one whose own effect is late
  # or incompatible). Running local work is closed by the same selector.
  defp close_run(state, at) do
    select = &(not retains?(state.control, &1, at))

    state
    |> close_local(at, select)
    |> close_open(select, "run_closed", at)
  end

  defp close_attempt(state, current, at),
    do: close_open(state, &(&1.attempt_id != current), "attempt_closed", at)

  # A pattern failure belongs to the Attempt of its finish. At a change of Attempt a
  # failure that the Run owner has not recorded is stale: its pending stop, completion
  # and closed generation are dropped (the charge stop keeps its own), so the new
  # Attempt is not failed by an older finish and can generate.
  defp drop_stale_failure(%{control: %{stop_pending: :failed} = c} = state),
    do:
      put_in(state.control, %{
        c
        | stop_pending: nil,
          completion: nil,
          generation_closed: c.charge_stopped
      })

  defp drop_stale_failure(state), do: state

  # When a nested_callable slot settles, its child callable and every callable
  # below it close in the same fold step, the way close_open/4 closes callables:
  # closed and without state, so the reserve of each state bound leaves the
  # control state. Open slots of the closed callables are not settled here; they
  # settle by their own rules, and child_cost/2 still counts them for the parent
  # Budget. A callable below is one whose parent chain reaches the child
  # callable: each callable's parent is the slot key of the action that spawned
  # it, and that slot's callable is its parent callable.
  defp close_child_callables(state, cid) do
    update_in(state.control.callables, fn callables ->
      Map.new(callables, fn
        {"root", node} ->
          {"root", node}

        {id, node} ->
          if id == cid or descendant?(state, cid, id),
            do: {id, node |> Map.put(:closed, true) |> Map.delete(:state)},
            else: {id, node}
      end)
    end)
  end

  defp descendant?(state, cid, id) do
    with %{parent: parent_key} when is_tuple(parent_key) <- state.control.callables[id],
         %{callable: parent_id} when is_binary(parent_id) <- state.slots[parent_key] do
      parent_id == cid or descendant?(state, cid, parent_id)
    else
      _ -> false
    end
  end

  # One closer for two uses: a change of Attempt settles every open slot of an older
  # Attempt (reason `attempt_closed`), and the end of a Run settles every open slot
  # that is not retained (reason `run_closed`), in the same fold step, at the time of
  # the record. Nothing is read from a clock or a process.
  # A slot that nothing can have left is refused (its reservation is released);
  # a slot that may have been sent gets the outcome unknown and keeps its entry.
  # Callables go deepest first, so a nested parent reads its closed child.
  defp close_open(state, select, reason, at) do
    state =
      update_in(state.control.callables, fn callables ->
        Map.new(callables, fn
          {"root", node} -> {"root", node}
          {id, node} -> {id, node |> Map.put(:closed, true) |> Map.delete(:state)}
        end)
      end)

    state.slots
    |> Enum.filter(fn {_, slot} -> slot.phase != :settled and select.(slot) end)
    |> Enum.sort_by(fn {key, slot} -> {-state.control.callables[slot.callable].depth, key} end)
    |> Enum.reduce(state, fn {key, _}, acc -> close_slot(acc, key, reason, at) end)
  end

  defp close_slot(acc, key, reason, at) do
    slot = acc.slots[key]
    sent? = slot.kind != "wait_event" and may_have_sent?(acc, key, slot)
    parent? = slot.kind == "nested_callable" and sent?
    class = if sent?, do: "unknown", else: "refused"

    input =
      outcome(acc.version, slot.action_id, class, @refusal_schema, refusal(acc, key, reason), at)

    {:ok, checked} = decode_step(input, acc.version)

    case PatternStep.accept(acc.control.trackers[elem(key, 0)].tracker, checked) do
      {:applied, tracker} ->
        correlation =
          cond do
            parent? -> %{dispatch: "dispatched"}
            sent? -> %{dispatch: "unknown"}
            true -> %{}
          end

        acc = put_in(acc.control.trackers[elem(key, 0)].tracker, tracker)
        acc = settle_join(acc, key, input, correlation)

        {acc, actual} =
          cond do
            not sent? -> {settle_budget(acc, key, 0, at), 0}
            parent? -> closed_parent_actual(acc, key, at)
            true -> {acc, nil}
          end

        acc = remove_slot_wait(acc, slot)

        kept =
          Map.take(slot, [
            :action_id,
            :kind,
            :attempt_id,
            :callable,
            :verdict,
            :reservation,
            :decision,
            :person_id,
            :deadline_ms,
            :resource_name,
            :intent_digest,
            :request_key,
            :event_source_id,
            :event_source_version,
            :event_cursor,
            :event_ticket,
            :activation_id,
            :activation_at_ms,
            :event_receipt
          ])

        closed = %{phase: :settled, outcome: class, actual: actual}

        closed =
          if slot.kind == "wait_event", do: Map.put(closed, :close_reason, reason), else: closed

        put_in(acc.slots[key], Map.merge(kept, closed))

      _ ->
        # The tracker settled this action before (a slot that `deny` turned back
        # to refusing): its first settlement stands.
        put_in(acc.slots[key].phase, :settled)
    end
  end

  # The committed amount of the closed child when every child cost is known.
  defp closed_parent_actual(acc, key, at) do
    id = occurrence_id(key)

    case child_cost(acc, id) do
      :known ->
        {:Transition, _, {:some, {:status, status}}} =
          Budget.step(acc.control.budgets[id].state, {at, :status})

        {settle_budget(acc, key, status.committed, at), status.committed}

      _ ->
        {acc, nil}
    end
  end

  defp may_have_sent?(state, key, %{kind: kind, phase: phase} = slot) do
    cond do
      kind in ["model_call", "tool_call"] and phase == :approval ->
        slot[:request_key] != nil

      kind in ["resource_open", "resource_use", "resource_close"] ->
        phase in [:ready, :running, :reconcile]

      kind in ["model_call", "tool_call"] ->
        phase in [:running, :reconcile]

      kind == "ask_person" ->
        phase == :waiting

      kind == "nested_callable" ->
        phase == :running or
          (phase == :refusing and state.control.callables[occurrence_id(key)] != nil)

      true ->
        false
    end
  end

  defp invoke(state, record, callable) do
    c = state.control
    node = Map.fetch!(c.callables, callable)
    {module, function} = node.mfa
    bound = Map.get(node, :state_bytes, 65_536)
    {:ok, _} = decode_step(record.input, state.version)
    {:Transition, next_pattern, output} = apply(module, function, [node.state, record.input])
    true = output == :none or match?({:some, _}, output)
    hash = digest({record.input, record.correlation})
    state = put_in(state.control.invocations[record.id], hash)

    case output do
      :none ->
        if bytes(next_pattern) <= bound and plain?(next_pattern),
          do: {put_in(state.control.callables[callable].state, next_pattern), :none},
          else: {classify(state, :invalid_pattern_state), :none}

      {:some, value} ->
        ordinal = c.count + 1
        state = put_in(state.control.count, ordinal)

        receipt = %{
          ordinal: ordinal,
          input_id: record.id,
          digest: hash,
          callable: callable,
          disposition: if(ordinal > c.cap, do: :over_cap, else: :within_cap_invalid)
        }

        state = put_in(state.control.receipts[ordinal], receipt)
        true = bytes(receipt) <= 1_024

        cond do
          ordinal > c.cap ->
            state =
              if bytes(next_pattern) <= bound and plain?(next_pattern),
                do: put_in(state.control.callables[callable].state, next_pattern),
                else: state

            state = close_over_cap_generation(state, record.context, record.input["at_ms"])

            # A settled parent keeps its first settlement (first settlement wins).
            state =
              if node.parent && state.slots[node.parent].phase != :settled do
                deny(state, node.parent, "out_of_budget")
              else
                state
              end

            {classify(state, :over_cap), :none}

          bytes(next_pattern) > bound or not plain?(next_pattern) ->
            {classify(state, :invalid_pattern_state), :none}

          true ->
            state = put_in(state.control.callables[callable].state, next_pattern)
            admit_request(state, value, ordinal, callable, record.input["at_ms"])
        end
    end
  end

  defp admit_request(state, value, ordinal, callable, at) do
    with {:ok, checked, %{"type" => "request", "actions" => actions}} <-
           decode_request(value, state.version),
         {:ok, json} <- Jason.encode(value),
         true <- active_count(state) + length(actions) <= 64,
         true <- state.control.lifetime + length(actions) <= 256,
         true <- Enum.all?(actions, &action_ids?/1),
         true <- bytes(Map.put(state.requests, ordinal, json)) <= @request_bytes,
         {:ok, join} <-
           Aggregation.new(Enum.map(actions, & &1["id"]),
             branch_key: {:field, ["correlation_id"]},
             max_branches: 64,
             max_result_bytes: 262_144,
             deadline_unix_ms: :unbounded,
             now: fn -> at end
           ) do
      request = %{
        tracker: PatternStep.open(checked),
        join: Map.delete(join, :now),
        callable: callable
      }

      candidate = put_in(state.control.trackers[ordinal], request)
      candidate = put_in(candidate.requests[ordinal], json)
      candidate = update_in(candidate.control.lifetime, &(&1 + length(actions)))

      candidate =
        actions
        |> Enum.with_index()
        |> Enum.reduce(candidate, fn {action, index}, acc ->
          reused = Map.has_key?(acc.control.used_ids, action["id"])

          slot = %{
            action_id: action["id"],
            kind: action["kind"],
            attempt_id: acc.control.attempt_id,
            callable: callable,
            verdict: nil,
            phase: if(reused, do: :refusing, else: :checking),
            refusal: if(reused, do: "reused_identity", else: nil)
          }

          acc = put_in(acc.slots[{ordinal, index}], slot)
          put_in(acc.control.used_ids[action["id"]], true)
        end)

      if fits?(candidate) do
        candidate = put_in(candidate.control.receipts[ordinal].disposition, :within_cap_valid)
        {classify(candidate, {:request, ordinal}), {:some, {:request, ordinal}}}
      else
        {classify(state, :record_size), :none}
      end
    else
      _ -> {classify(state, :invalid_request), :none}
    end
  end

  defp settle_join(state, key, input, correlation) do
    ordinal = elem(key, 0)
    join = Map.put(state.control.trackers[ordinal].join, :now, fn -> input["at_ms"] end)
    loss = if input["outcome"] == "resource_lost", do: :unavailable, else: correlation[:loss]

    {:ok, join} =
      if loss in [:killed, :timed_out, :unavailable] do
        Aggregation.mark_lost(join, input["action_id"], loss)
      else
        {outcome, dispatch, error} =
          if input["kind"] == "outside_event",
            do: {"completed", "dispatched", nil},
            else: envelope_class(input["outcome"] || "completed", correlation)

        result = %{
          "version" => 1,
          "message_id" => occurrence_id(key),
          "correlation_id" => input["action_id"],
          "outcome" => outcome,
          "dispatch" => dispatch,
          "value" => input["payload"],
          "value_schema_id" => input["schema_id"],
          "value_schema_version" => input["schema_version"]
        }

        result =
          if error do
            result
            |> Map.drop(["value", "value_schema_id", "value_schema_version"])
            |> Map.put("error_class", error)
          else
            result
          end

        Aggregation.accept(join, result)
      end

    {join, _} = Aggregation.decision(join, input["at_ms"])
    put_in(state.control.trackers[ordinal].join, Map.delete(join, :now))
  end

  defp envelope_class("completed", _), do: {"completed", "dispatched", nil}

  defp envelope_class(value, _) when value in ["refused", "out_of_budget"],
    do: {"rejected", "not_dispatched", "permanent"}

  defp envelope_class("failed", %{dispatch: "dispatched"}),
    do: {"failed", "dispatched", "unclassified"}

  defp envelope_class("expired", c), do: {"timed_out", c[:dispatch] || "unknown", "unclassified"}

  defp envelope_class("retries_exhausted", %{dispatch: "not_dispatched"}),
    do: {"rejected", "not_dispatched", "permanent"}

  defp envelope_class("retries_exhausted", c),
    do: {"failed", c[:dispatch] || "unknown", "unclassified"}

  defp envelope_class(_, c), do: {"unknown", c[:dispatch] || "unknown", "unavailable"}

  defp settle_budget(state, key, actual, at) when is_integer(actual) and actual >= 0 do
    slot = state.slots[key]

    if slot[:reservation] do
      budget = state.control.budgets[slot.callable]

      operation =
        if actual == 0,
          do: {:release, Map.take(slot.reservation, [:cost_ref, :generation])},
          else:
            {:settle,
             Map.put(Map.take(slot.reservation, [:cost_ref, :generation]), :actual, actual)}

      {:Transition, next, {:some, _}} = Budget.step(budget.state, {at, operation})
      put_in(state.control.budgets[slot.callable].state, next)
    else
      state
    end
  end

  defp settle_budget(state, _, _, _), do: state

  # A root finish settles `completed` by its own :finish record: the tracker and the
  # join take the outcome, and its Budget entry settles at actual 0.
  defp settle_finish(state, key, slot, input, at) do
    {:ok, checked} = decode_step(input, state.version)
    request = state.control.trackers[elem(key, 0)]
    {:applied, tracker} = PatternStep.accept(request.tracker, checked)
    state = put_in(state.control.trackers[elem(key, 0)].tracker, tracker)
    state = settle_join(state, key, input, %{}) |> settle_budget(key, 0, at)

    put_in(state.slots[key], %{
      action_id: slot.action_id,
      kind: slot.kind,
      callable: slot.callable,
      attempt_id: slot.attempt_id,
      phase: :settled,
      outcome: "completed",
      verdict: slot.verdict
    })
  end

  defp expire_waits(state, at) do
    Enum.reduce(state.slots, state, fn {key, slot}, acc ->
      if slot.kind in [
           "ask_person",
           "local_work",
           "model_call",
           "tool_call",
           "nested_callable",
           "wait_event"
         ] and
           slot.phase in [:waiting, :running, :approval] and at >= slot.deadline_ms do
        record = %{
          version: acc.version,
          kind: :protocol,
          id: "expire:" <> occurrence_id(key),
          run_id: acc.control.run_id,
          attempt_id: slot.attempt_id,
          input:
            outcome(
              acc.version,
              slot.action_id,
              "expired",
              @refusal_schema,
              refusal(acc, key, "expired"),
              at
            ),
          correlation: %{occurrence: key, loss: :timed_out},
          context: %{}
        }

        {acc, _, _} = settle_protocol(acc, record, key)
        acc
      else
        acc
      end
    end)
  end

  # The expiry pass and, with `expiry_reports: :owner` in control, its reports
  # (ELZ-351): after the whole pass, each slot that it settled and whose callable is
  # still open holds the expiry input as its pending_input, in ascending occurrence
  # order, under the ID of the :resume_input record that will give it, when the state
  # with it placed still fits; otherwise the slot settles as without the option. A
  # report carries the pause deadline of the expiring input, so that a first excess
  # under budget_rule :pause can enter the pause; under :pause an input whose pause
  # deadline is not after its time holds no report. Without the option this is
  # expire_waits/2 alone.
  defp expire_and_report(state, at, context) do
    expired = expire_waits(state, at)

    if state.control[:expiry_reports] == :owner and
         (state.control.budget_rule == :finish or
            (is_integer(context[:pause_deadline]) and context.pause_deadline > at)) do
      state.slots
      |> Enum.filter(fn {key, slot} ->
        slot.phase != :settled and expired.slots[key].phase == :settled
      end)
      |> Enum.sort()
      |> Enum.reduce(expired, fn {key, slot}, acc ->
        if acc.control.callables[slot.callable].closed do
          acc
        else
          order =
            Enum.reduce(acc.slots, 0, fn {_, s}, n ->
              max(n, (s[:pending_input] || %{order: 0}).order)
            end)

          record = %{
            version: acc.version,
            kind: :protocol,
            id: stable_id("resume:", {acc.control.run_id, key}),
            run_id: acc.control.run_id,
            attempt_id: slot.attempt_id,
            input:
              Jason.encode!(
                outcome(
                  acc.version,
                  slot.action_id,
                  "expired",
                  @refusal_schema,
                  refusal(acc, key, "expired"),
                  at
                )
              ),
            correlation: %{occurrence: key, loss: :timed_out},
            context: Map.take(context, [:pause_deadline])
          }

          candidate = put_in(acc.slots[key][:pending_input], %{order: order + 1, record: record})
          if fits?(candidate), do: candidate, else: acc
        end
      end)
    else
      expired
    end
  end

  # Whether the own effect of protocol `record` settles slot `key` of `state`: the
  # slot is still open after the expiry pass of the same fold step and settled after
  # the record's own protocol rule, before the end of a Run closes what is left.
  # The steps of protocol_transition/2, pure; the transcript reader asks it so that
  # it reads no reason from an outcome that came too late to apply.
  @doc false
  def own_settlement?(state, record, key) do
    expired = expire_and_report(state, record.input["at_ms"], record.context)

    if expired.slots[key].phase == :settled do
      false
    else
      {next, _accepted, _callable} = protocol(expired, record)
      next.slots[key].phase == :settled
    end
  end

  defp lifecycle(state, ordinal) do
    life = state.control.lifecycle

    tracker =
      if ordinal,
        do: state.control.trackers[ordinal].tracker,
        else: tracker(state.version, %{})

    %{life | tracker: tracker}
  end

  defp tracker(1, state), do: {:PatternStepTracker, state}
  defp tracker(2, state), do: {:PatternStepTrackerV2, state}

  defp life_context(state, context, origin, exhausted, at) do
    budget = state.control.budgets["root"]
    {:Transition, _, {:some, {:status, status}}} = Budget.step(budget.state, {at, :status})

    Map.merge(context, %{
      current_attempt: state.control.attempt_id,
      originating_attempt: origin,
      budget_exhausted: exhausted or status.committed >= status.cap,
      budget_rule: state.control.budget_rule
    })
  end

  defp install_lifecycle(state, life, decision) do
    state = put_in(state.control.lifecycle, %{life | tracker: tracker(state.version, %{})})

    case decision do
      {:request_outcome, outcome} -> put_in(state.control.stop_pending, outcome)
      _ -> state
    end
  end

  defp deny(state, key, reason) do
    update_in(state.slots[key], &Map.merge(&1, %{phase: :refusing, refusal: reason}))
  end

  defp release_and_deny(state, key, at, reason),
    do: state |> settle_budget(key, 0, at) |> deny(key, reason)

  @impl true
  def init(opts) do
    with true <- Keyword.keyword?(opts),
         true <- valid_result_reader_options?(opts),
         true <- length(Keyword.get_values(opts, :protocol_version)) <= 1,
         true <- length(Keyword.get_values(opts, :event_source)) <= 1,
         reports when reports in [[], [:owner]] <- Keyword.get_values(opts, :expiry_reports),
         messages when messages in [[], [:while_active]] <- Keyword.get_values(opts, :messages),
         protocol_version when protocol_version in [1, 2] <- Keyword.get(opts, :protocol_version, 1),
         event_source = Keyword.get(opts, :event_source),
         true <-
           (protocol_version == 1 and is_nil(event_source)) or
             (protocol_version == 2 and valid_event_source?(event_source)),
         true <- text?(opts[:identity], 160) and text?(opts[:run_id], 200),
         cap when is_integer(cap) and cap in 1..256 <- opts[:request_cap],
         {module, function, initial} <- opts[:pattern],
         true <-
           is_atom(module) and is_atom(function) and bytes(initial) <= 65_536 and plain?(initial),
         %{id: gate_id, version: version, call: call} <- opts[:gate],
         true <- text?(gate_id, 128) and is_integer(version) and version in 1..2_147_483_647,
         true <- is_function(call, 2) and is_function(opts[:clock], 0),
         true <- is_function(opts[:context], 0) and is_map(opts[:bindings]),
         true <- bindings?(opts[:bindings]),
         true <-
           is_map(opts[:schemas]) and is_map(opts[:resources]) and is_map(opts[:effect_intent]),
         true <- text?(opts[:tenant], 200) and text?(opts[:principal], 200),
         {:ok, view} <- Run.status(opts[:run_owner], opts[:run_id]),
         true <- is_binary(view.current_attempt),
         %{cap: budget_cap, unit: unit, id: budget_id, incarnation: incarnation} <- opts[:budget],
         {:ok, budget} <- Budget.initial(budget_id, incarnation, budget_cap, unit),
         rule when rule in [:pause, :finish] <- opts[:budget_rule],
         deadline when is_integer(deadline) and deadline > 0 <- opts[:run_deadline],
         {:ok, pid} <- start_unit(opts[:directory], opts[:identity]) do
      identity =
        {{module, function}, schema_identities(opts[:schemas]), binding_identities(opts[:bindings]),
         %{id: gate_id, version: version}, opts[:tenant], opts[:principal], cap, budget_cap, unit,
         rule, deadline}

      fingerprint =
        if protocol_version == 1,
          do: digest(identity),
          else: digest({:run_engine_v2, identity, Map.take(event_source, [:id, :version])})

      # The option is recorded in control and in the fingerprint; absent, both are
      # unchanged.
      fingerprint =
        if reports == [:owner],
          do: digest({:expiry_reports, :owner, fingerprint}),
          else: fingerprint

      # `messages` wraps after `expiry_reports`, in the same way.
      fingerprint =
        if messages == [:while_active],
          do: digest({:messages, :while_active, fingerprint}),
          else: fingerprint

      control = %{
        fingerprint: fingerprint,
        run_id: opts[:run_id],
        operation_id: view.operation_id,
        attempt_id: view.current_attempt,
        run_revision: view.revision,
        gate: %{id: gate_id, version: version},
        cap: cap,
        count: 0,
        lifetime: 0,
        generation_closed: false,
        charge_stopped: false,
        stop_pending: nil,
        completion: nil,
        cancelled_attempt: nil,
        receipts: %{},
        invocations: %{},
        used_ids: %{},
        trackers: %{},
        cursors: %{},
        budget_rule: rule,
        budgets: %{"root" => %{state: budget, cap: budget_cap, unit: unit}},
        callables: %{
          "root" => %{
            mfa: {module, function},
            state: initial,
            closed: false,
            parent: nil,
            authority: :none,
            depth: 0,
            state_bytes: 65_536
          }
        },
        lifecycle: %{
          phase: if(view.outcome, do: :terminal, else: :active),
          waits: %{},
          tracker: tracker(protocol_version, %{}),
          outcome: view.outcome,
          run_deadline: deadline,
          pause_deadline: nil
        },
        classification: :configured
      }

      control =
        if protocol_version == 2,
          do:
            Map.merge(control, %{
              protocol_version: 2,
              event_source: Map.take(event_source, [:id, :version]),
              tenant: opts[:tenant],
              principal: opts[:principal]
            }),
          else: control

      control =
        if reports == [:owner], do: Map.put(control, :expiry_reports, :owner), else: control

      control =
        if messages == [:while_active],
          do: Map.put(control, :messages, :while_active),
          else: control

      s = %{
        opts: Map.new(opts),
        unit: pid,
        halted: nil,
        work: %{},
        intents: %{},
        state: nil,
        appended: false,
        decoded: %{}
      }

      snapshot = DurableUnit.snapshot(pid)

      result =
        cond do
          snapshot == empty_state(protocol_version) or
              (snapshot.version == protocol_version and is_map(snapshot.control) and
                 snapshot.control.run_id != opts[:run_id] and
                 snapshot.control.lifecycle.phase == :terminal and active_count(snapshot) == 0) ->
            commit(s, stable_id("configure:", opts[:run_id]), %{
              version: protocol_version,
              kind: :configure,
              control: control
            })

          snapshot.version == protocol_version and snapshot.control.fingerprint == fingerprint and
              snapshot.control.run_id == opts[:run_id] ->
            {:ok, :unchanged, %{s | state: snapshot}}

          true ->
            {:error, :incompatible_recovery, s}
        end

      with {:ok, _, s} <- result,
           {:ok, s} <- sync_run(s),
           {:ok, s} <- recover_local(s),
           {:ok, s} <- recover_intents(s),
           {:ok, s} <- release_waiting(s, "startup", %{}),
           {:ok, s} <- consume_resources(s),
           {:ok, s} <- drain(s) do
        {:ok, s}
      else
        {:error, reason, _} -> {:stop, reason}
      end
    else
      _ -> {:stop, :invalid_options_or_recovery}
    end
  catch
    :exit, _ -> {:stop, :indeterminate_startup}
  end

  @impl true
  def handle_call(:status, _, s) do
    {state, s} = read_state(s)
    c = state.control

    slots =
      Map.new(state.slots, fn {k, v} ->
        {k, Map.take(v, [:action_id, :kind, :phase, :outcome, :verdict, :reconciliation])}
      end)

    joins =
      Map.new(c.trackers, fn {k, v} -> {k, %{closed: v.join.closed, outcome: v.join.outcome}} end)

    {:reply,
     {:ok,
      %{
        run_id: c.run_id,
        attempt_id: c.attempt_id,
        phase: c.lifecycle.phase,
        outcome: c.lifecycle.outcome,
        request_cap: c.cap,
        request_count: c.count,
        generation_closed: c.generation_closed,
        stop_pending: c.stop_pending,
        classification: c.classification,
        slots: slots,
        joins: joins,
        reconciliation: s.halted
      }}, s}
  end

  def handle_call({:result, scope, limits}, _, s) do
    {:reply, read_result(s, scope, limits), s}
  end

  def handle_call({:event_waits, scope, limits}, _, s) do
    {:reply, read_retained(s, scope, limits, &Elzoo.RunEngine.ResultReader.event_waits/8), s}
  end

  def handle_call({:transcript, scope, limits}, _, s) do
    {:reply, read_retained(s, scope, limits, &Elzoo.RunEngine.ResultReader.transcript/8), s}
  end

  def handle_call({:input, id, input, context}, _, s) do
    {reply, s} = ingest(s, id, input, context)

    if Map.get(s, :fence_after_reply),
      do: {:stop, :normal, reply, Map.delete(s, :fence_after_reply)},
      else: {:reply, reply, s}
  end

  def handle_call({:control, id, command, context}, _, s) do
    result = with {:ok, s} <- current(s), do: apply_control(s, id, command, context)

    case result do
      {:ok, s} -> {:reply, {:ok, :applied}, s}
      {:error, reason, s} -> {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_info(
        {:durable_unit_input, id, %{version: 2, kind: :protocol} = record},
        %{opts: %{protocol_version: 2}} = s
      ) do
    try do
      case find_input_fenced(s, id) do
        {:ok, ^record, pairing} ->
          if record.input["kind"] == "outside_event" and pairing in [:paired, :unpaired],
            do: {:noreply, s},
            else: commit_and_drain_input(s, id, record)

        :absent ->
          if local_work_protocol_record?(id, record),
            do: accept_local_work_input(s, id, record),
            else: {:noreply, s}

        _ ->
          {:noreply, s}
      end
    rescue
      _ -> {:noreply, s}
    catch
      _, _ -> {:noreply, s}
    end
  end

  def handle_info({:durable_unit_input, _, %{version: 2, kind: :protocol}}, s), do: {:noreply, s}

  def handle_info(
        {:durable_unit_input, _, %{version: 1, kind: :protocol}},
        %{opts: %{protocol_version: 2}} = s
      ),
      do: {:noreply, s}

  def handle_info({:durable_unit_input, id, %{version: 1, kind: :protocol} = record}, s) do
    case current(s) do
      {:ok, s} ->
        record = local_outcome_context(s, record)

        case checked_ingress(s, record.input, Map.merge(record.context, record.correlation)) do
          {:ok, input, correlation, s} ->
            record = %{record | input: input, correlation: correlation}

            result =
              with {:ok, _, s} <- commit(s, id, record),
                   do: drain(s)

            case result do
              {:ok, s} -> {:noreply, s}
              {:error, _, s} -> {:noreply, s}
            end

          {:error, _} ->
            {:noreply, s}
        end

      {:error, _, s} ->
        {:noreply, s}
    end
  end

  def handle_info(%Outbox.Item{} = item, s) do
    if s.halted do
      {:noreply, s}
    else
      case drain(s) do
        {:ok, s} ->
          case ack(s, item) do
            {:ok, s} -> {:noreply, s}
            {reason, s} -> {:noreply, %{s | halted: reason, state: nil, decoded: %{}}}
          end

        {:error, _, s} ->
          {:noreply, s}
      end
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp commit_and_drain_input(s, id, record) do
    case commit(s, id, record) do
      {:ok, _, s} ->
        case drain(s) do
          {:ok, s} -> {:noreply, s}
          {:error, _, s} -> {:noreply, s}
        end

      {:error, _, s} ->
        {:noreply, s}
    end
  end

  defp accept_local_work_input(s, id, record) do
    case current(s) do
      {:ok, s} ->
        record = local_outcome_context(s, record)

        case checked_ingress(s, record.input, Map.merge(record.context, record.correlation)) do
          {:ok, input, correlation, s} ->
            record = %{record | input: input, correlation: correlation}
            commit_and_drain_input(s, id, record)

          _ ->
            {:noreply, s}
        end

      _ ->
        {:noreply, s}
    end
  end

  defp local_work_protocol_record?(id, %{
         version: 2,
         kind: :protocol,
         id: id,
         input: %{"kind" => "action_outcome"},
         context: context,
         correlation: correlation
       }) do
    is_binary(id) and String.starts_with?(id, "local:") and is_map(context) and
      is_map(correlation) and is_tuple(Map.get(correlation, :occurrence))
  end

  defp local_work_protocol_record?(_, _), do: false

  # A local-work outcome takes the host's pause deadline when its delivery is handled for
  # commit, as every other engine-made record does, never the one of its dispatch.
  defp local_outcome_context(s, record),
    do: %{record | context: Map.take(s.opts.context.(), [:pause_deadline])}

  defp ingest(%{halted: reason, opts: %{protocol_version: 2}} = s, id, neutral, context)
       when not is_nil(reason) do
    with true <- text?(id, 160) and is_map(neutral) and is_map(context),
         true <- text?(context[:run_id], 200) and text?(context[:attempt_id], 200),
         false <- Map.has_key?(neutral, "at_ms"),
         "outside_event" <- neutral["kind"],
         :ok <- outside_context(context) do
      case recorded_outside_event(s, id, neutral, context) do
        {:ok, _, :paired} -> {{:ok, :unchanged}, s}
        {:ok, _, :unpaired} -> fence_unpaired(s, reason)
        :absent -> {{:error, reason}, s}
        {:error, lookup_reason} -> {{:error, lookup_reason}, s}
      end
    else
      {:error, validation_reason} -> {{:error, validation_reason}, s}
      _ -> {{:error, reason}, s}
    end
  end

  defp ingest(%{halted: reason} = s, _, _, _) when not is_nil(reason), do: {{:error, reason}, s}

  defp ingest(s, id, neutral, context) do
    with true <- text?(id, 160) and is_map(neutral) and is_map(context),
         true <- text?(context[:run_id], 200) and text?(context[:attempt_id], 200),
         false <- Map.has_key?(neutral, "at_ms") do
      if protocol_version(s) == 2 and neutral["kind"] == "outside_event" do
        ingest_outside_event(s, id, neutral, context)
      else
        case current(s) do
          {:ok, s} -> ingest_current(s, id, neutral, context)
          {:error, reason, s} -> {{:error, reason}, s}
        end
      end
    else
      _ -> {{:error, :invalid_input}, s}
    end
  catch
    :exit, _ ->
      {{:indeterminate, :delivery}, %{s | halted: :delivery_unknown, state: nil, decoded: %{}}}
  end

  defp ingest_outside_event(s, id, neutral, context) do
    with :ok <- outside_context(context) do
      case recorded_outside_event(s, id, neutral, context) do
        {:ok, _record, :paired} -> {{:ok, :unchanged}, s}
        {:ok, _record, :unpaired} -> fence_unpaired(s)
        :absent -> fresh_outside_event(s, id, neutral, context)
        {:error, reason} -> {{:error, reason}, s}
      end
    else
      {:error, reason} -> {{:error, reason}, s}
    end
  end

  defp outside_context(context) do
    allowed = [:run_id, :attempt_id, :occurrence, :actual, :dispatch, :pause_deadline]

    if Enum.all?(Map.keys(context), &(&1 in allowed)) and context[:actual] in [nil, 0] and
         context[:dispatch] in [nil, "not_dispatched"] and is_tuple(context[:occurrence]),
       do: :ok,
       else: {:error, :invalid_correlation}
  end

  defp fence_unpaired(s, reply_reason \\ :delivery_unknown) do
    unit_stop =
      try do
        DynamicUnits.stop(s.opts.directory, s.opts.identity)
      rescue
        _ -> {:error, :unavailable}
      catch
        _, _ -> {:error, :unavailable}
      end

    work_stop =
      try do
        case GenServer.whereis(s.opts.async_work) do
          pid when is_pid(pid) -> GenServer.stop(pid, :normal, @call_limit)
          _ -> {:error, :unavailable}
        end
      rescue
        _ -> {:error, :unavailable}
      catch
        _, _ -> {:error, :unavailable}
      end

    if unit_stop == :ok and work_stop == :ok do
      s = %{
        s
        | unit: nil,
          halted: reply_reason,
          state: nil,
          decoded: %{},
          work: %{},
          intents: %{}
      }

      {{:error, reply_reason}, Map.put(s, :fence_after_reply, true)}
    else
      {{:error, :stop_unknown}, %{s | halted: :stop_unknown, state: nil, decoded: %{}}}
    end
  end

  defp recorded_outside_event(s, id, neutral, context) do
    case find_input_fenced(s, id) do
      :absent ->
        :absent

      {:ok,
       %{kind: :protocol, input: input, correlation: correlation, context: original_context} =
           record, pairing} ->
        if Map.delete(input, "at_ms") == neutral and record.run_id == context.run_id and
             record.attempt_id == context.attempt_id and
             correlation[:occurrence] == context[:occurrence] and
             Map.take(original_context, [:pause_deadline]) == Map.take(context, [:pause_deadline]),
           do: {:ok, record, pairing},
           else: {:error, :input_id_conflict}

      {:ok, _, _} ->
        {:error, :input_id_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :source_unavailable}
  catch
    _, _ -> {:error, :source_unavailable}
  end

  defp fresh_outside_event(s, id, neutral, context) do
    with :ok <- decode_outside_event(neutral),
         :ok <- valid_fresh_event_ingress_size(id, neutral),
         {state, s} <- read_state(s),
         key = context[:occurrence],
         slot = state.slots[key],
         source = s.opts.event_source,
         :ok <- valid_fresh_event_correlation(s, state, slot, source, neutral, context),
         {:ok, action} <- action_for(s, state, key),
         %{result: result_schema} <- choose(s, "wait_event", fn -> action end),
         :ok <- valid_requested_event_payload(s, neutral, result_schema),
         {:ok, %{head: head, event: event} = response} <-
           source_read(source, event_scope(s), neutral["event_id"]),
         true <- map_size(response) == 2,
         :ok <- valid_event_head(head, slot.event_cursor),
         :ok <-
           valid_source_event(
             event,
             neutral,
             source.id,
             slot.event_ticket,
             result_schema,
             slot.event_cursor,
             head
           ),
         :ok <- check_event_payload(s, event) do
      case recheck_fresh_event(s, context, slot) do
        {:ok, checked_s, _wait, _at} ->
          case current(checked_s) do
            {:ok, recovered_s} ->
              deliver_fresh_outside_event(recovered_s, id, neutral, context, slot, event, head)

            {:error, reason, recovered_s} ->
              {{:error, reason}, recovered_s}
          end

        {:error, reason, checked_s} ->
          {{:error, reason}, checked_s}
      end
    else
      {:error, {:source_read, :not_found}} -> {{:error, :source_not_found}, s}
      {:error, {:source_read, :gap}} -> {{:error, :source_gap}, s}
      {:error, {:source_read, :unavailable}} -> {{:error, :source_unavailable}, s}
      {:error, :not_found} -> {{:error, :source_not_found}, s}
      {:error, :gap} -> {{:error, :source_gap}, s}
      {:error, :unavailable} -> {{:error, :source_unavailable}, s}
      {:error, :invalid_payload} -> {{:error, :invalid_payload}, s}
      {:error, :invalid_correlation} -> {{:error, :invalid_correlation}, s}
      _ -> {{:error, :source_unavailable}, s}
    end
  end

  defp recheck_fresh_event(s, context, original_slot) do
    attempt = context[:attempt_id]
    key = context[:occurrence]
    source = s.opts.event_source

    with {:ok, owner} <- Run.status(s.opts.run_owner, s.opts.run_id),
         true <- is_nil(owner.outcome) and owner.current_attempt == attempt,
         {state, s} <- read_state(s),
         true <- state.control.attempt_id == attempt,
         wait when is_map(wait) <- state.slots[key],
         true <-
           Map.get(wait, :kind) == "wait_event" and Map.get(wait, :phase) == :waiting and
             Map.get(wait, :attempt_id) == attempt and
             Map.get(wait, :activation_id) == original_slot.activation_id and
             Map.get(wait, :deadline_ms) == original_slot.deadline_ms and
             Map.get(wait, :event_ticket) == original_slot.event_ticket and
             Map.get(wait, :event_cursor) == original_slot.event_cursor and
             Map.get(wait, :event_source_id) == original_slot.event_source_id and
             Map.get(wait, :event_source_version) == original_slot.event_source_version and
             source.id == original_slot.event_source_id and
             source.version == original_slot.event_source_version,
         at when is_integer(at) and at > 0 <- s.opts.clock.(),
         true <- is_integer(Map.get(wait, :deadline_ms)) and at < Map.get(wait, :deadline_ms) do
      {:ok, s, wait, at}
    else
      false -> {:error, :invalid_correlation, s}
      nil -> {:error, :invalid_correlation, s}
      {:error, :invalid_correlation} -> {:error, :invalid_correlation, s}
      _ -> {:error, :source_unavailable, s}
    end
  end

  defp deliver_fresh_outside_event(s, id, neutral, context, original_slot, event, head) do
    case recheck_fresh_event(s, context, original_slot) do
      {:ok, checked_s, slot, at} ->
        input = Map.put(neutral, "at_ms", at)

        case PatternStep.decode(input, 2) do
          {:ok, _} ->
            source = checked_s.opts.event_source

            correlation = %{
              occurrence: context[:occurrence],
              actual: 0,
              source_version: source.version,
              source_sequence: event.sequence,
              source_head_revision: head.revision,
              activation_id: slot.activation_id,
              event_digest:
                Elzoo.RunEngine.event_digest(
                  event.id,
                  event.source_id,
                  event.correlation_id,
                  event.sequence,
                  source.version,
                  event.schema_id,
                  event.schema_version,
                  event.payload
                )
            }

            case submit_ingress(checked_s, id, input, input, correlation, context) do
              {{:error, :input_too_large}, current_s} -> {{:error, :invalid_payload}, current_s}
              result -> result
            end

          _ ->
            {{:error, :source_unavailable}, checked_s}
        end

      {:error, reason, checked_s} ->
        {{:error, reason}, checked_s}
    end
  catch
    :exit, _ ->
      {{:indeterminate, :delivery}, %{s | halted: :delivery_unknown, state: nil, decoded: %{}}}
  end

  defp source_read(source, scope, event_id) do
    result =
      try do
        source.read.(scope, event_id)
      rescue
        _ -> {:error, :unavailable}
      catch
        _, _ -> {:error, :unavailable}
      end

    case result do
      {:ok, _} = result ->
        result

      {:error, reason} when reason in [:not_found, :unavailable, :gap] ->
        {:error, {:source_read, reason}}

      _ ->
        {:error, {:source_read, :unavailable}}
    end
  end

  defp decode_outside_event(neutral) do
    case PatternStep.decode(Map.put(neutral, "at_ms", 1), 2) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_payload}
    end
  end

  defp valid_fresh_event_ingress_size(id, neutral) do
    if bytes({1, {id, neutral}}) <= @ingress_bytes,
      do: :ok,
      else: {:error, :invalid_payload}
  rescue
    _ -> {:error, :invalid_payload}
  end

  defp valid_fresh_event_correlation(s, state, slot, source, input, context) do
    attempt = context[:attempt_id]

    with %{kind: "wait_event", phase: :waiting, attempt_id: ^attempt} <- slot,
         true <- context.run_id == s.opts.run_id and state.control.attempt_id == attempt,
         true <- input["action_id"] == slot.action_id,
         true <- input["source_id"] == slot.event_source_id and input["source_id"] == source.id,
         true <- input["correlation_id"] == slot.event_ticket,
         {:ok, owner} <- Run.status(s.opts.run_owner, s.opts.run_id),
         true <- is_nil(owner.outcome) and owner.current_attempt == attempt do
      :ok
    else
      _ -> {:error, :invalid_correlation}
    end
  rescue
    _ -> {:error, :invalid_correlation}
  catch
    _, _ -> {:error, :invalid_correlation}
  end

  defp valid_requested_event_payload(s, input, {schema_id, schema_version}) do
    if {input["schema_id"], input["schema_version"]} == {schema_id, schema_version} and
         check_payload(s, input) == :ok,
       do: :ok,
       else: {:error, :invalid_payload}
  rescue
    _ -> {:error, :invalid_payload}
  end

  defp valid_requested_event_payload(_, _, _), do: {:error, :invalid_payload}

  defp action_for(s, state, key) do
    {action, _s} = read_action(s, state, key)
    if is_map(action), do: {:ok, action}, else: {:error, :invalid_correlation}
  end

  defp event_scope(s),
    do: %{tenant: s.opts.tenant, principal: s.opts.principal, run_id: s.opts.run_id}

  defp valid_event_head(%{revision: revision, low_water: low_water} = head, cursor)
       when map_size(head) == 2 and is_integer(revision) and revision >= 0 and
              is_integer(low_water) and low_water >= 0 do
    cond do
      low_water > revision -> {:error, :unavailable}
      low_water > 0 -> {:error, :gap}
      cursor > revision -> {:error, :gap}
      true -> :ok
    end
  end

  defp valid_event_head(_, _), do: {:error, :unavailable}

  defp valid_activation_head(head), do: valid_event_head(head, 0)

  defp valid_source_event(
         event,
         input,
         source_id,
         ticket,
         {schema_id, schema_version},
         cursor,
         head
       )
       when is_map(event) and map_size(event) == 7 do
    keys = [:id, :source_id, :correlation_id, :sequence, :schema_id, :schema_version, :payload]

    cond do
      Enum.sort(Map.keys(event)) != Enum.sort(keys) ->
        {:error, :unavailable}

      event.id != input["event_id"] or event.source_id != source_id or
          event.correlation_id != ticket ->
        {:error, :invalid_correlation}

      not is_integer(event.sequence) or event.sequence <= 0 ->
        {:error, :unavailable}

      event.sequence <= cursor ->
        {:error, :invalid_correlation}

      event.sequence > head.revision ->
        {:error, :unavailable}

      {event.schema_id, event.schema_version} != {schema_id, schema_version} ->
        {:error, :invalid_payload}

      not same_payload?(event.payload, input["payload"]) ->
        {:error, :invalid_payload}

      true ->
        :ok
    end
  end

  defp valid_source_event(_, _, _, _, _, _, _), do: {:error, :unavailable}

  defp same_payload?(left, right) do
    binary(left) == binary(right)
  rescue
    _ -> false
  end

  defp check_event_payload(s, event) do
    case check_payload(s, %{
           "schema_id" => event.schema_id,
           "schema_version" => event.schema_version,
           "payload" => event.payload
         }) do
      :ok -> :ok
      _ -> {:error, :invalid_payload}
    end
  end

  defp ingest_current(s, id, neutral, context) do
    with at when is_integer(at) and at > 0 <- s.opts.clock.(),
         input = Map.put(neutral, "at_ms", at),
         {:ok, _} <- decode_step(input, protocol_version(s)) do
      case checked_ingress(s, input, context) do
        {:ok, checked, correlation, s} ->
          submit_ingress(s, id, input, checked, correlation, context)

        {:error, reason} ->
          {{:error, reason}, s}
      end
    else
      {:error, reason} -> {{:error, reason}, s}
      _ -> {{:error, :invalid_input}, s}
    end
  end

  defp submit_ingress(s, id, input, checked, correlation, context) do
    record = %{
      version: protocol_version(s),
      kind: :protocol,
      id: id,
      input: checked,
      run_id: context.run_id,
      attempt_id: context.attempt_id,
      correlation: correlation,
      context: Map.take(context, [:verified_person, :pause_deadline])
    }

    with true <- plain?(record),
         :ok <-
           if(bytes({1, {id, record}}) <= @ingress_bytes, do: :ok, else: {:error, :input_too_large}),
         {:ok, record} <-
           original_record(s, id, record, &recheck_settled(s, input, context, record, &1)),
         :ok <- preflight_paused_event(s, record),
         :ok <- pause_operand(s, record.context, record.input["at_ms"]),
         result = DurableUnit.step(s.unit, id, record) do
      s = %{s | state: nil}

      case result do
        {:ok, disposition} ->
          case drain(s) do
            {:ok, s} -> {{:ok, disposition}, s}
            {:error, reason, s} -> {{:error, reason}, s}
          end

        other ->
          {:error, reason, s} = storage_failure(s, other)
          {{:error, reason}, s}
      end
    else
      {:error, reason} -> {{:error, reason}, s}
      _ -> {{:error, :invalid_input}, s}
    end
  end

  defp preflight_paused_event(s, %{version: 2, input: %{"kind" => "outside_event"}} = record) do
    {state, _s} = read_state(s)

    key = record.correlation.occurrence
    slot = state.slots[key]

    if state.control.lifecycle.phase == :paused and is_map(slot) and slot.phase == :waiting and
         slot.kind == "wait_event" do
      case protocol_transition(state, record) do
        {:continue, candidate, true, callable} ->
          paused? = candidate.control.lifecycle.phase == :paused

          retain? =
            not candidate.control.generation_closed and is_nil(candidate.control.stop_pending) and
              not candidate.control.callables[callable].closed and key != nil

          cond do
            paused? and retain? ->
              with {:ok, pending} <- paused_pending_input(candidate, record),
                   true <- fits?(pending),
                   final = finalize_step_state(pending),
                   true <- fits?(final) do
                :ok
              else
                _ -> {:error, :invalid_payload}
              end

            candidate.control.lifecycle.phase == :terminal or not retain? ->
              if fits?(finalize_step_state(candidate)), do: :ok, else: {:error, :invalid_payload}

            true ->
              {:error, :invalid_payload}
          end

        _ ->
          {:error, :invalid_payload}
      end
    else
      :ok
    end
  rescue
    _ -> {:error, :invalid_payload}
  catch
    _, _ -> {:error, :invalid_payload}
  end

  defp preflight_paused_event(_, _), do: :ok

  defp paused_pending_input(state, record) do
    key = record.correlation.occurrence

    order =
      Enum.reduce(state.slots, 0, fn {_, slot}, n ->
        max(n, (slot[:pending_input] || %{order: 0}).order)
      end)

    case Jason.encode(record.input) do
      {:ok, encoded} ->
        pending = %{order: order + 1, record: %{record | input: encoded}}
        {:ok, put_in(state.slots[key][:pending_input], pending)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `admitted` gives the action of an occurrence whose slot no longer holds it.
  defp checked_ingress(s, input, context, admitted \\ fn -> nil end) do
    correlation = Map.take(context, [:occurrence, :actual, :dispatch, :loss, :resource])
    key = context[:occurrence]
    {state, s} = read_state(s)
    slot = state.slots[key]

    {expected, s} =
      cond do
        slot && slot.kind == "local_work" &&
            correlation[:loss] in [:killed, :timed_out, :unavailable] ->
          {{@refusal_schema, 1}, s}

        slot ->
          choose_expected(s, state, key, slot, admitted)

        true ->
          {nil, s}
      end

    cond do
      input["kind"] in ["action_outcome", "person_answer"] and slot != nil and
          (input["action_id"] != slot.action_id or input["outcome"] == "late" or
             (slot.kind == "ask_person" and input["kind"] == "action_outcome" and
                input["outcome"] == "completed") or
             (input["kind"] == "person_answer" and
                (slot.kind != "ask_person" or slot[:person_id] != input["person_id"] or
                   context[:verified_person] != input["person_id"]))) ->
        if check_payload(s, input) == :ok and
             {input["schema_id"], input["schema_version"]} == expected,
           do: {:ok, input, correlation, s},
           else: {:error, :invalid_correlation}

      input["kind"] in ["wake", "cancel"] ->
        {:ok, input, correlation, s}

      input["kind"] in ["action_outcome", "person_answer"] and is_nil(slot) ->
        {:ok, input, correlation, s}

      expected != nil and {input["schema_id"], input["schema_version"]} != expected ->
        {:ok, invalid_outcome(s, slot, input, "invalid_outcome"),
         Map.put(correlation, :loss, :unavailable), s}

      true ->
        case check_payload(s, input) do
          :ok ->
            {:ok, input, correlation, s}

          {:error, reason} when not is_nil(slot) ->
            reason =
              if reason in [:too_large, :too_deep], do: "outcome_too_large", else: "invalid_outcome"

            {:ok, invalid_outcome(s, slot, input, reason),
             Map.put(correlation, :loss, :unavailable), s}

          _ ->
            {:error, :invalid_payload}
        end
    end
  end

  defp choose_expected(s, state, key, slot, admitted) do
    case s.opts.bindings[slot.kind] do
      %{result: result} ->
        {result, s}

      by_schema when is_map(by_schema) ->
        {act, s} =
          if slot[:action] || Map.has_key?(state.requests, elem(key, 0)),
            do: read_action(s, state, key),
            else: {admitted.(), s}

        binding =
          case act do
            %{"schema_id" => schema_id} -> Map.get(by_schema, schema_id)
            _ -> nil
          end

        {binding[:result], s}

      nil ->
        {nil, s}
    end
  end

  defp invalid_outcome(s, slot, input, reason) do
    class = if slot.kind == "local_work", do: "failed", else: "unknown"

    outcome(
      protocol_version(s),
      slot.action_id,
      class,
      @refusal_schema,
      %{
        "reason" => reason,
        "gate_id" => s.opts.gate.id,
        "gate_version" => s.opts.gate.version,
        "request" => 0,
        "index" => 0
      },
      input["at_ms"]
    )
  end

  # Find the original committed or unresolved input without asking the pattern.
  # The host retains full history; a changed same-ID retry is not a fresh call.
  # `again` may give a second candidate for a recorded protocol input that differs.
  defp original_record(s, id, candidate, again \\ fn _ -> nil end) do
    case find_input(s.opts.store, s.opts.identity, id, 1) do
      nil ->
        {:ok, candidate}

      # A candidate of another kind is a conflict: it falls to the last clause.
      %{kind: :protocol} = original when candidate.kind == :protocol ->
        comparable = fn r -> r |> put_in([:input, "at_ms"], 0) end

        if comparable.(original) == comparable.(candidate) or
             ((second = again.(original)) && comparable.(original) == comparable.(second)),
           do: {:ok, original},
           else: {:error, :input_id_conflict}

      %{kind: :lifecycle} = original when candidate.kind == :lifecycle ->
        comparable = fn r -> put_in(r.command.at_ms, 0) end

        if comparable.(original) == comparable.(candidate),
          do: {:ok, original},
          else: {:error, :input_id_conflict}

      _ ->
        {:error, :input_id_conflict}
    end
  end

  # The slot of a settled occurrence keeps no action, so a retry of a recorded refusal is
  # checked again with the action of its admission, as at the first time. Nothing is written.
  defp recheck_settled(s, input, context, record, %{input: %{"kind" => "action_outcome"}}) do
    key = context[:occurrence]
    {state, s} = read_state(s)

    with %{phase: :settled} = slot <- state.slots[key],
         nil <- slot[:action],
         false <- Map.has_key?(state.requests, elem(key, 0)),
         {:ok, checked, correlation, _} <-
           checked_ingress(s, input, context, fn -> admitted_action(s, key) end) do
      %{record | input: checked, correlation: correlation}
    else
      _ -> nil
    end
  end

  defp recheck_settled(_, _, _, _, _), do: nil

  defp admitted_action(s, key) do
    id = stable_id("admit:", {s.opts.run_id, key})

    case find_input(s.opts.store, s.opts.identity, id, 1) do
      %{kind: :admission, facts: facts} -> facts[:action]
      _ -> nil
    end
  end

  defp find_input(store, stream, id, from) do
    {:ok, rows, head} = Elzoo.DurableLog.read(store, stream, from, 1_000)
    true = head.low_water == 0

    match =
      Enum.find_value(rows, fn row ->
        if row.kind == "input" do
          {1, {input_id, record}} = :erlang.binary_to_term(row.payload, [:safe])
          if input_id == id, do: record
        end
      end)

    if match || length(rows) < 1_000,
      do: match,
      else: find_input(store, stream, id, List.last(rows).sequence + 1)
  end

  defp find_input_fenced(s, id) do
    version = protocol_version(s)

    fold =
      DurableUnit.fold(
        operator: {__MODULE__, :step, empty_state(version)},
        retention_count: 1
      )

    with {:ok, record, model, paired, head} <-
           fenced_input_pages(
             s.opts.store,
             s.opts.identity,
             id,
             1,
             nil,
             nil,
             fold.initial,
             false,
             fold,
             version
           ),
         {:ok, [], current_head} <-
           Elzoo.DurableLog.read(s.opts.store, s.opts.identity, head.revision + 1, 1),
         :ok <- fenced_unit_head(current_head),
         true <- fenced_head_identity(head) == fenced_head_identity(current_head) do
      cond do
        not is_nil(record) -> {:ok, record, if(paired, do: :paired, else: :unpaired)}
        is_nil(model.pending) -> :absent
        true -> {:error, :source_unavailable}
      end
    else
      {:error, :input_id_conflict} -> {:error, :input_id_conflict}
      {:error, {:pruned, _}} -> {:error, :source_gap}
      {:error, :source_gap} -> {:error, :source_gap}
      {:error, _} -> {:error, :source_unavailable}
      false -> {:error, :source_unavailable}
      _ -> {:error, :source_unavailable}
    end
  rescue
    _ -> {:error, :source_unavailable}
  catch
    :exit, _ -> {:error, :source_unavailable}
    _, _ -> {:error, :source_unavailable}
  end

  defp fenced_input_pages(store, stream, id, from, head, found, model, paired, fold, version) do
    case Elzoo.DurableLog.read(store, stream, from, 1_000) do
      {:ok, rows, current_head} when is_list(rows) and is_map(current_head) ->
        head = head || current_head

        with :ok <- fenced_unit_head(current_head),
             true <- fenced_head_identity(head) == fenced_head_identity(current_head),
             :ok <-
               if(from > head.revision or length(rows) == min(1_000, head.revision - from + 1),
                 do: :ok,
                 else: {:error, :source_gap}
               ),
             {:ok, found, model, paired} <-
               fenced_input_rows(rows, stream, from, id, found, model, paired, fold, version) do
          if from > head.revision do
            if rows == [], do: {:ok, found, model, paired, head}, else: {:error, :source_gap}
          else
            last = List.last(rows)

            fenced_input_pages(
              store,
              stream,
              id,
              last.sequence + 1,
              head,
              found,
              model,
              paired,
              fold,
              version
            )
          end
        else
          {:error, _} = error -> error
          false -> {:error, :source_unavailable}
          _ -> {:error, :source_unavailable}
        end

      {:error, {:pruned, _}} ->
        {:error, :source_gap}

      _ ->
        {:error, :source_unavailable}
    end
  rescue
    _ -> {:error, :source_unavailable}
  catch
    _, _ -> {:error, :source_unavailable}
  end

  defp fenced_input_rows(rows, stream, first, id, found, model, paired, fold, version) do
    Enum.reduce_while(Enum.with_index(rows), {:ok, found, model, paired}, fn
      {row, index}, {:ok, current, current_model, current_paired} ->
        sequence = first + index

        if row.stream == stream and row.sequence == sequence and
             Elzoo.DurableLog.validate_row(row, fold, %{max_record_bytes: @record_bytes}) == :ok do
          with {:ok, next_found} <- fenced_input_record(row, id, current, version),
               {:ok, next_model} <- reduce_fenced_input_row(fold, current_model, row, version) do
            completed_target = row.kind == "result" and match?({^id, _}, current_model.pending)
            {:cont, {:ok, next_found, next_model, current_paired or completed_target}}
          else
            {:error, _} = error -> {:halt, error}
          end
        else
          {:halt, {:error, :source_gap}}
        end
    end)
  rescue
    _ -> {:error, :source_gap}
  catch
    _, _ -> {:error, :source_gap}
  end

  defp fenced_input_record(%{kind: "input", payload: payload}, id, current, version) do
    case :erlang.binary_to_term(payload, [:safe]) do
      {1, {input_id, record}}
      when is_binary(input_id) and byte_size(input_id) in 1..160 and is_map(record) ->
        cond do
          not Elzoo.RunEngine.HistoryVersion.valid_record?(record, input_id, version) ->
            {:error, :source_unavailable}

          input_id != id ->
            {:ok, current}

          is_nil(current) ->
            {:ok, record}

          current == record ->
            {:ok, current}

          true ->
            {:error, :input_id_conflict}
        end

      _ ->
        {:error, :source_gap}
    end
  end

  defp fenced_input_record(%{kind: "result"}, _, current, _), do: {:ok, current}
  defp fenced_input_record(_, _, _, _), do: {:error, :source_gap}

  defp reduce_fenced_input_row(fold, model, row, version) do
    next = fold.reduce.(model, row.kind, row.schema_version, row.payload)

    if is_map(next.state) and Elzoo.RunEngine.HistoryVersion.valid_state?(next.state, version),
      do: {:ok, next},
      else: {:error, :source_unavailable}
  rescue
    _ -> {:error, :source_unavailable}
  catch
    _, _ -> {:error, :source_unavailable}
  end

  defp fenced_unit_head(head) when is_map(head) do
    revision = Map.get(head, :revision)
    low_water = Map.get(head, :low_water)
    capabilities = get_in(head, [:capabilities, :append_visibility])

    cond do
      not is_integer(revision) or revision < 0 or not is_integer(low_water) or low_water < 0 ->
        {:error, :source_unavailable}

      low_water > revision ->
        {:error, :source_unavailable}

      low_water > 0 ->
        {:error, :source_gap}

      capabilities not in [:atomic, :staged_uncommitted_tail] or
          not is_nil(Map.get(head, :staged_tail)) ->
        {:error, :source_unavailable}

      true ->
        :ok
    end
  end

  defp fenced_unit_head(_), do: {:error, :source_gap}

  defp fenced_head_identity(head),
    do: Map.take(head, [:revision, :low_water, :capabilities, :staged_tail])

  # The Unit safely decodes whole committed states, not just protocol inputs.
  # Budget.initial/4 already loads the Budget representation before the first open.
  defp start_unit(directory, identity) do
    with {:module, Aggregation} <- Code.ensure_loaded(Aggregation),
         {:module, Authorization} <- Code.ensure_loaded(Authorization),
         {:module, BotRunLifecycle} <- Code.ensure_loaded(BotRunLifecycle),
         {:module, PatternStep} <- Code.ensure_loaded(PatternStep) do
      DynamicUnits.start(directory, identity)
    end
  end

  defp current(%{halted: reason} = s) when not is_nil(reason), do: {:error, reason, s}

  defp current(s) do
    case start_unit(s.opts.directory, s.opts.identity) do
      {:ok, pid} when pid == s.unit ->
        with {:ok, s} <- sync_run(s), do: consume_resources(s)

      {:ok, pid} ->
        with {:ok, s} <- recover_local(%{s | unit: pid, work: %{}, state: nil, decoded: %{}}),
             {:ok, s} <- sync_run(s),
             {:ok, s} <- recover_intents(s),
             {:ok, s} <- release_waiting(s, "replacement", %{}),
             {:ok, s} <- consume_resources(s),
             do: drain(s)

      other ->
        storage_failure(s, other)
    end
  catch
    :exit, _ ->
      {:error, :ownership_unknown, %{s | halted: :ownership_unknown, state: nil, decoded: %{}}}
  end

  defp sync_run(s) do
    with {:ok, view} <- Run.status(s.opts.run_owner, s.opts.run_id) do
      {state, s} = read_state(s)
      c = state.control

      if c.run_revision == view.revision do
        if view.outcome, do: end_resources(s, view.outcome), else: {:ok, s}
      else
        with {:ok, _, s} <-
               commit(s, "run:" <> Integer.to_string(view.revision), %{
                 version: protocol_version(s),
                 kind: :run_view,
                 view:
                   Map.put(
                     Map.take(
                       view,
                       [:id, :operation_id, :current_attempt, :revision, :outcome]
                     ),
                     :at_ms,
                     s.opts.clock.()
                   )
               }) do
          if view.outcome, do: end_resources(s, view.outcome), else: {:ok, s}
        end
      end
    else
      _ -> {:error, :run_unavailable, %{s | halted: :run_unavailable, state: nil, decoded: %{}}}
    end
  end

  defp recover_local(s) do
    {state, s} = read_state(s)

    Enum.reduce_while(state.slots, {:ok, s}, fn {key, slot}, {:ok, acc} ->
      if slot.kind == "local_work" and slot.phase == :running do
        case internal_outcome(acc, key, "failed", "local_restart", %{loss: :unavailable}) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          other -> {:halt, other}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp drain(%{halted: reason} = s) when not is_nil(reason),
    do: {:error, reason, %{s | state: nil, decoded: %{}}}

  defp drain(s) do
    s = %{s | appended: false}
    {state, s} = read_state(s)

    pending =
      state.slots
      |> Enum.filter(fn {_, slot} -> slot[:pending_input] != nil end)
      |> Enum.min_by(fn {_, slot} -> slot.pending_input.order end, fn -> nil end)

    finished_child =
      Enum.find_value(state.control.callables, fn {id, child} ->
        due_child(s, state, id, child)
      end)

    next =
      Enum.find(Enum.sort(state.slots), fn {_, slot} ->
        (slot.phase in [:checking, :refusing, :allowed, :authorizing, :ready] or
           (slot.phase == :approval and
              (slot[:request_key] == nil or state.control.lifecycle.phase == :terminal))) and
          (state.control.lifecycle.phase != :paused or slot.phase in [:checking, :refusing])
      end)

    cond do
      state.control.stop_pending != nil ->
        with {:ok, s} <- finish_run(s, state.control.stop_pending, state.control.completion),
             do: continue_drain(s)

      pending != nil and state.control.lifecycle.phase not in [:paused, :terminal] and
          not state.control.generation_closed ->
        {key, _} = pending

        with {:ok, _, s} <-
               commit(s, stable_id("resume:", {s.opts.run_id, key}), %{
                 version: protocol_version(s),
                 kind: :resume_input,
                 occurrence: key
               }),
             do: continue_drain(s)

      finished_child != nil ->
        {child, class, status} = finished_child

        result =
          cond do
            class == :unknown ->
              nested_outcome(s, state, child, %{actual: nil})

            state.slots[child.parent].phase == :settled ->
              with {:ok, _, s} <-
                     commit(s, stable_id("nested-actual:", {s.opts.run_id, child.parent}), %{
                       version: protocol_version(s),
                       kind: :nested_actual,
                       occurrence: child.parent,
                       actual: status.committed,
                       at_ms: s.opts.clock.()
                     }),
                   do: {:ok, s}

            true ->
              nested_outcome(s, state, child, %{actual: status.committed})
          end

        with {:ok, s} <- result,
             do: continue_drain(s)

      next == nil ->
        {:ok, %{s | appended: false, decoded: %{}}}

      true ->
        {key, slot} = next

        with {:ok, s} <- progress(s, key, slot),
             do: continue_drain(s)
    end
  end

  # A round that appended a record goes on; otherwise the drain ends.
  defp continue_drain(%{appended: true} = s), do: drain(s)
  defp continue_drain(s), do: {:ok, %{s | appended: false, decoded: %{}}}

  # A closed child whose every slot cost is known or final unknown gives its parent
  # an outcome, once. Unknown is not zero: the parent gets no actual and the
  # reservations stay held. A parent that cannot take the outcome is skipped: in a
  # terminal Run that is any parent the request-cap stop does not retain, and a
  # retained one at or after its deadline (the fold would classify the record late).
  defp due_child(s, state, id, child) do
    parent = child.parent
    class = parent && child_cost(state, id)

    if class in [:known, :unknown] do
      slot = state.slots[parent]

      running? =
        slot.phase == :running and slot.attempt_id == state.control.attempt_id and
          (state.control.lifecycle.phase != :terminal or
             (retained?(state.control) and
                (slot[:deadline_ms] == nil or s.opts.clock.() < slot.deadline_ms)))

      cond do
        not running? and not (slot.phase == :settled and is_nil(slot[:actual]) and class == :known) ->
          nil

        class == :unknown ->
          {child, :unknown, nil}

        true ->
          {:Transition, _, {:some, {:status, status}}} =
            Budget.step(state.control.budgets[id].state, {s.opts.clock.(), :status})

          if status.reserved == 0, do: {child, :known, status}
      end
    end
  end

  defp retained?(c),
    do: c.generation_closed and c.charge_stopped and is_nil(c.cancelled_attempt)

  # The request-cap stop keeps a slot open until its deadline (a slot with no
  # deadline yet stays until it has one).
  defp retains?(_c, %{kind: "wait_event"}, _at), do: false

  defp retains?(c, slot, at),
    do: retained?(c) and (slot[:deadline_ms] == nil or at < slot.deadline_ms)

  # The cost of a child, from the durable state only.
  defp child_cost(state, id) do
    if state.control.callables[id].closed or state.control.generation_closed do
      costs =
        for {key, slot} <- state.slots, slot.callable == id, do: cost(state, key)

      cond do
        :open in costs -> :open
        :unknown in costs -> :unknown
        true -> :known
      end
    else
      :open
    end
  end

  defp cost(state, key) do
    slot = state.slots[key]
    id = occurrence_id(key)

    cond do
      slot.phase != :settled -> :open
      is_integer(slot[:actual]) -> :known
      not held?(state, slot.callable, id) -> :known
      slot.kind in ["resource_open", "resource_use", "resource_close"] -> :open
      slot.kind != "nested_callable" -> :unknown
      state.control.callables[id] == nil -> :unknown
      child_cost(state, id) == :unknown -> :unknown
      true -> :open
    end
  end

  # The Budget of the callable counts the entry of the action: Open, or Expired
  # (it left `reserved` at its deadline, and nothing was committed for it).
  defp held?(state, callable, id) do
    {:BudgetState, _, _, _, _, _, _, entries} = state.control.budgets[callable].state
    ref = {:String, String.to_charlist(id)}

    Enum.any?(entries, fn
      {:EntryRow, ^ref, {:Open, _, _}} -> true
      {:EntryRow, ^ref, {:Expired, _}} -> true
      _ -> false
    end)
  end

  defp progress(s, {request, _}, %{phase: :checking}) do
    {state, s} = read_state(s)

    keys =
      for {{^request, _} = key, slot} <- Enum.sort(state.slots),
          slot.phase == :checking,
          do: key

    {candidates, s} =
      Enum.map_reduce(keys, s, fn key, acc ->
        {act, acc} = read_action(acc, state, key)
        {{key, act}, acc}
      end)

    rejected =
      Enum.find_value(candidates, fn {key, action} ->
        cond do
          check_payload(s, action) != :ok -> {key, "payload_schema"}
          not action_ids?(action) -> {key, "invalid_identity"}
          choose(s, action["kind"], fn -> action end) == nil -> {key, "missing_binding"}
          true -> nil
        end
      end)

    case rejected do
      {key, reason} ->
        with {:ok, _, s} <-
               commit(s, stable_id("precheck:", {s.opts.run_id, key}), %{
                 version: protocol_version(s),
                 kind: :precheck,
                 occurrence: key,
                 reason: reason
               }),
             do: {:ok, s}

      nil ->
        entries =
          for {{_, index}, action} <- candidates do
            {verdict, reason} =
              case sample_gate(s, action) do
                :allow -> {:allow, nil}
                {:deny, reason} -> {:deny, reason}
              end

            %{
              index: index,
              verdict: verdict,
              reason: reason,
              gate_id: s.opts.gate.id,
              gate_version: s.opts.gate.version
            }
          end

        record = %{
          version: protocol_version(s),
          kind: :gate,
          schema_id: "elzoo.run-engine.gate-verdict",
          schema_version: 1,
          request: request,
          entries: entries,
          at_ms: s.opts.clock.()
        }

        with {:ok, _, s} <-
               commit(s, stable_id("gate:", {1, {s.opts.identity, s.opts.run_id}, request}), record),
             do: {:ok, s}
    end
  end

  defp progress(s, key, %{phase: :refusing} = slot) do
    reason = slot[:refusal] || slot.verdict.reason
    class = if reason == "out_of_budget", do: "out_of_budget", else: "refused"
    {state, s} = read_state(s)
    child = state.control.budgets[occurrence_id(key)]

    actual =
      if slot.kind == "nested_callable" and child do
        {:Transition, _, {:some, {:status, status}}} =
          Budget.step(child.state, {s.opts.clock.(), :status})

        if status.reserved == 0, do: status.committed, else: nil
      else
        0
      end

    internal_outcome(s, key, class, reason, %{actual: actual, dispatch: "not_dispatched"})
  end

  defp progress(s, key, %{phase: :allowed} = slot) do
    {state, s} = read_state(s)
    {action, s} = read_action(s, state, key)
    binding = choose(s, slot.kind, fn -> action end)
    facts = binding.facts.(action)

    facts =
      Map.merge(facts, %{binding_id: binding.id, binding_version: binding.version, action: action})

    with {:ok, _, s} <-
           commit(s, stable_id("admit:", {s.opts.run_id, key}), %{
             version: protocol_version(s),
             kind: :admission,
             occurrence: key,
             facts: facts,
             at_ms: s.opts.clock.()
           }),
         do: {:ok, s}
  end

  defp progress(s, key, %{phase: :authorizing}) do
    {context, s} = action_context(s, key, %{})

    decision =
      case Authorization.decide(context.policy, context.proposal, context.authority) do
        {:ok, decision} -> decision
        _ -> :refused
      end

    with {:ok, _, s} <-
           commit(s, stable_id("auth:", {s.opts.run_id, key}), %{
             version: protocol_version(s),
             kind: :authorization,
             occurrence: key,
             decision: decision,
             at_ms: s.opts.clock.()
           }),
         do: {:ok, s}
  end

  defp progress(s, key, %{phase: :approval} = slot) do
    {state, s} = read_state(s)

    if state.control.lifecycle.phase == :terminal do
      {:ok, run} = Run.status(s.opts.run_owner, s.opts.run_id)
      effect = run.effects[slot.action_id]

      if effect && effect.classification in [:unknown, :settled, :reconciliation_required] do
        with {:ok, s} <- continuation(s, key, :running, %{}),
             do: internal_outcome(s, key, "unknown", "lost_outcome", %{dispatch: "unknown"})
      else
        internal_outcome(s, key, "refused", "run_terminal", %{actual: 0, dispatch: "not_dispatched"})
      end
    else
      case run_command(s, :approval_request, %{decision: slot.decision}) do
        {:ok, _, request_key} when is_tuple(request_key) ->
          hold_request(s, key, request_key)

        # Any other reply: (1) the Run already lists this request, so hold its
        # key; (2) the Run did not decide, so write nothing and ask at the next
        # drain; (3) the Run refused, so settle the slot as refused.
        reply ->
          case listed_request(s, slot) do
            {:ok, request_key} ->
              hold_request(s, key, request_key)

            :none ->
              if match?({:refused, :conflict}, reply) or match?({:error, :unavailable}, reply) or
                   match?({:indeterminate, _}, reply),
                 do: {:ok, s},
                 else: internal_outcome(s, key, "refused", "approval_refused", %{actual: 0})
          end
      end
    end
  end

  defp progress(s, key, %{phase: :ready} = slot) do
    with {:ok, s} <- sync_run(s) do
      {state, s} = read_state(s)
      {context, s} = action_context(s, key, %{})
      {act, s} = read_action(s, state, key)
      decision = Authorization.decide(context.policy, context.proposal, context.authority)

      if permitted?(state, slot, s.opts.clock.()) and check_payload(s, act) == :ok and
           match?({:ok, %{verdict: :allow}}, decision) do
        dispatch(s, key, slot)
      else
        if match?({:ok, %{verdict: :ask}}, decision) and slot[:request_key] do
          release_waiting(s, "dispatch", %{})
        else
          internal_outcome(s, key, "refused", "run_or_authority", %{actual: 0})
        end
      end
    end
  end

  defp dispatch(%{opts: %{protocol_version: 2}} = s, key, %{kind: "wait_event"} = slot),
    do: activate_event_wait(s, key, slot)

  defp dispatch(s, key, %{kind: "local_work"} = slot) do
    {state, s} = read_state(s)
    {action, s} = read_action(s, state, key)
    binding = choose(s, slot.kind, fn -> action end)
    {module, function, args} = binding.work.(action)
    at = s.opts.clock.()
    clock = s.opts.clock
    c = state.control
    {schema_id, schema_version} = binding.result

    wrap = fn _work_ref, result ->
      {input, correlation} =
        case result do
          {:completed, value} ->
            {outcome(protocol_version(s), slot.action_id, "completed", schema_id, value, clock.()),
             %{occurrence: key, actual: slot.estimate}}

          {:lost, reason} ->
            {outcome(
               protocol_version(s),
               slot.action_id,
               "failed",
               @refusal_schema,
               refusal(snapshot_value(c), key, "local_lost"),
               clock.()
             ), %{occurrence: key, loss: reason}}
        end

      input = Map.put(input, "schema_version", schema_version)
      id = stable_id("local:", {1, c.run_id, key})

      {:durable_unit_input, id,
       %{
         version: protocol_version(s),
         kind: :protocol,
         id: id,
         run_id: c.run_id,
         attempt_id: slot.attempt_id,
         input: input,
         correlation: correlation,
         context: %{}
       }}
    end

    with {:ok, s} <- continuation(s, key, :running, %{}) do
      case AsyncWork.start(
             s.opts.async_work,
             fn -> apply(module, function, args) end,
             max(1, min(slot.deadline_ms - at, 4_294_967_295)),
             wrap
           ) do
        {:ok, ref} ->
          {:ok, put_in(s.work[key], ref)}

        {:error, _reason} ->
          internal_outcome(s, key, "failed", "local_unavailable", %{loss: :unavailable, actual: 0})
      end
    end
  end

  defp dispatch(s, key, %{kind: "ask_person"} = slot) do
    {state, s} = read_state(s)
    {action, s} = read_action(s, state, key)
    binding = choose(s, slot.kind, fn -> action end)
    continuation(s, key, :waiting, %{person_id: binding.person.(action)})
  end

  defp dispatch(s, key, %{kind: "nested_callable"} = slot) do
    {state, s} = read_state(s)
    {action, s} = read_action(s, state, key)
    facts = choose(s, slot.kind, fn -> action end).nested.(action)

    bound = Map.get(facts, :state_bytes, 65_536)

    if is_integer(bound) and bound >= 1 and bound <= 65_536 and
         bytes(facts.initial_state) <= bound and
         check_payload(
           s,
           %{
             "schema_id" => facts.schema_id,
             "schema_version" => facts.schema_version,
             "payload" => facts.payload
           }
         ) == :ok do
      id = stable_id("nested:", {s.opts.run_id, key})

      with {:ok, _, s} <-
             commit(s, id, %{
               version: state.version,
               id: id,
               kind: :nested,
               occurrence: key,
               facts: facts,
               at_ms: s.opts.clock.(),
               context: Map.take(s.opts.context.(), [:pause_deadline])
             }),
           do: {:ok, s}
    else
      internal_outcome(s, key, "refused", "nested_input", %{actual: 0})
    end
  end

  defp dispatch(s, key, %{kind: "finish"} = slot) do
    if slot.callable == "root" do
      {state, s} = read_state(s)
      {finish_action, s} = read_action(s, state, key)
      target_id = named_source(finish_action)

      source =
        target_id &&
          Enum.find_value(state.slots, fn {k, original} ->
            if original.action_id == target_id and
                 original.phase == :settled and original.outcome == "completed" and
                 original.attempt_id == slot.attempt_id,
               do: k
          end)

      # A finish that names no action fails the Run: its :finish record has no source.
      # One that names an action needs that action settled completed in this Attempt.
      if source || is_nil(target_id) do
        with {:ok, _, s} <-
               commit(s, stable_id("finish:", {s.opts.run_id, key}), %{
                 version: state.version,
                 kind: :finish,
                 occurrence: key,
                 source: source,
                 at_ms: s.opts.clock.()
               }),
             do: {:ok, s}
      else
        with {:ok, s} <- continuation(s, key, :refusing, %{refusal: "completion_evidence"}),
             do: internal_outcome(s, key, "refused", "completion_evidence", %{actual: 0})
      end
    else
      {state, s} = read_state(s)
      {action, s} = read_action(s, state, key)

      with {:ok, s} <-
             continuation(s, key, :running, %{
               finish_callable: slot.callable,
               finish: kept_finish(action)
             }),
           do: internal_outcome(s, key, "completed", "finished", %{actual: 0})
    end
  end

  defp dispatch(s, key, %{kind: kind} = slot)
       when kind in ["resource_open", "resource_use", "resource_close"] do
    resource = s.opts.resources[slot.resource_name]
    {state, s} = read_state(s)
    {action, s} = read_action(s, state, key)

    command = %{
      id: slot.action_id,
      at_ms: s.opts.clock.(),
      body:
        {:action, action,
         %{
           run_id: s.opts.run_id,
           scope: if(slot.callable == "root", do: :owner, else: :nested),
           resource_names: s.opts.context.().resource_names
         }, slot[:intent]}
    }

    case RunResource.command(resource, command) do
      {:ok, _} ->
        with {:ok, s} <- continuation(s, key, :running, %{}) do
          dispatch_resource(s, key, slot)
        end

      _ ->
        internal_outcome(s, key, "refused", "resource_refused", %{actual: 0})
    end
  end

  defp dispatch(s, key, slot) do
    with {:ok, s, owner} <- intent(s, key, slot) do
      view = EffectIntent.status(owner)

      cond do
        view.active != true ->
          continuation(s, key, :reconcile, %{reconciliation: :read_only})

        view.attempts > 0 ->
          with {:ok, s} <- continuation(s, key, :running, %{}),
               do: internal_outcome(s, key, "unknown", "lost_outcome", %{dispatch: "unknown"})

        true ->
          facts = if slot[:reconciliation] == :active, do: %{reconciliation: :active}, else: %{}

          with {:ok, s} <- continuation(s, key, :running, facts) do
            case EffectIntent.advance(owner, :dispatch) do
              {:ok, :dispatched} ->
                {:ok, s}

              {:error, reason} ->
                current = EffectIntent.status(owner)

                if current.active and current.attempts == 0 and
                     (reason == :schema or s.opts.clock.() >= slot.deadline_ms) do
                  internal_outcome(s, key, "refused", "not_sent", %{
                    actual: 0,
                    dispatch: "not_dispatched"
                  })
                else
                  internal_outcome(s, key, "unknown", "dispatch_unknown", %{dispatch: "unknown"})
                end
            end
          end
      end
    end
  end

  defp activate_event_wait(s, key, slot) do
    source = s.opts.event_source
    {state, s} = read_state(s)

    activation_id =
      Elzoo.RunEngine.event_activation_id(
        s.opts.run_id,
        state.control.attempt_id,
        key,
        source.id
      )

    ticket =
      Elzoo.RunEngine.event_ticket(
        s.opts.tenant,
        s.opts.principal,
        s.opts.run_id,
        state.control.attempt_id,
        key,
        source.id
      )

    case find_input_fenced(s, activation_id) do
      {:ok, %{kind: :event_activation} = original, _pairing} ->
        if valid_activation?(state, original, key, state.slots[key]) do
          case commit(s, activation_id, original) do
            {:ok, _, s} -> {:ok, s}
            {:error, reason, s} -> {:error, reason, s}
          end
        else
          {:error, :input_id_conflict, s}
        end

      :absent ->
        head =
          try do
            source.head.(event_scope(s))
          rescue
            _ -> {:error, :unavailable}
          catch
            _, _ -> {:error, :unavailable}
          end

        with {:ok, %{revision: revision} = head} <- head,
             :ok <- valid_activation_head(head),
             at when is_integer(at) and at > 0 <- s.opts.clock.(),
             {:ok, owner} <- Run.status(s.opts.run_owner, s.opts.run_id),
             true <- is_nil(owner.outcome) and owner.current_attempt == state.control.attempt_id,
             {current, s} = read_state(s),
             %{phase: :ready, attempt_id: attempt, deadline_ms: deadline} <- current.slots[key],
             true <-
               attempt == state.control.attempt_id and deadline == slot.deadline_ms and
                 at < deadline do
          record = %{
            version: 2,
            kind: :event_activation,
            id: activation_id,
            occurrence: key,
            attempt_id: attempt,
            source_id: source.id,
            source_version: source.version,
            ticket: ticket,
            cursor: revision,
            deadline_ms: deadline,
            at_ms: at
          }

          {candidate, _} = transition(current, record)

          if fits?(candidate) do
            case commit(s, activation_id, record) do
              {:ok, _, s} -> {:ok, s}
              {:error, reason, s} -> {:error, reason, s}
            end
          else
            {:error, :record_size, s}
          end
        else
          {:error, :gap} -> {:error, :source_gap, s}
          {:error, _} -> {:error, :source_unavailable, s}
          _ -> {:error, :source_unavailable, s}
        end

      {:ok, _, _} ->
        {:error, :input_id_conflict, s}

      {:error, :source_gap} ->
        {:error, :source_gap, s}

      {:error, _} ->
        {:error, :source_unavailable, s}
    end
  rescue
    _ -> {:error, :source_unavailable, s}
  catch
    _, _ -> {:error, :source_unavailable, s}
  end

  defp dispatch_resource(s, key, slot) do
    if slot.kind == "resource_close" do
      {:ok, s}
    else
      with {:ok, s, owner} <- intent(s, key, slot) do
        resource = s.opts.resources[slot.resource_name]
        status = EffectIntent.status(owner)

        cond do
          status.attempts > 0 ->
            {:ok, s}

          not status.active ->
            continuation(s, key, :reconcile, %{reconciliation: :read_only})

          true ->
            result =
              RunResource.command(resource, %{
                id: stable_id("dispatch:", {s.opts.run_id, key}),
                at_ms: s.opts.clock.(),
                body: {:dispatch, slot.intent.identity, owner}
              })

            case result do
              {:ok, _} ->
                {:ok, s}

              {:refused, reason} when reason in [:not_open, :paused, :closing, :closed] ->
                {:ok, s}

              _ ->
                {:error, :resource_dispatch_unknown,
                 %{s | halted: :resource_dispatch_unknown, state: nil, decoded: %{}}}
            end
        end
      end
    end
  end

  defp intent(s, key, slot) do
    descriptor = slot.intent
    startup = Map.fetch!(s.opts.effect_intent, descriptor.binding)

    if check_binding(s, descriptor) != :ok do
      {:error, :changed_binding, %{s | halted: :changed_binding, state: nil, decoded: %{}}}
    else
      case s.intents[key] do
        pid when is_pid(pid) ->
          {:ok, s, pid}

        nil ->
          opts =
            Keyword.merge(startup,
              identity: descriptor.identity,
              arguments: descriptor.arguments,
              deadline: descriptor.deadline_ms
            )

          case EffectIntent.start_link(opts) do
            {:ok, pid} ->
              Process.unlink(pid)
              {:ok, put_in(s.intents[key], pid), pid}

            _ ->
              {:error, :intent_recovery, %{s | halted: :intent_recovery, state: nil, decoded: %{}}}
          end
      end
    end
  end

  defp check_binding(s, descriptor) do
    with startup when is_list(startup) <- s.opts.effect_intent[descriptor.binding],
         {:ok, binding} <- Binding.load(startup[:binding]),
         true <-
           descriptor.binding_digest == binding.digest and hd(descriptor.identity) == s.opts.tenant do
      :ok
    else
      _ -> {:error, :changed_binding}
    end
  end

  defp continuation(s, key, phase, facts) do
    with {:ok, _, s} <-
           commit(s, stable_id("continue:", {s.opts.run_id, key, phase, facts}), %{
             version: protocol_version(s),
             kind: :continuation,
             occurrence: key,
             phase: phase,
             facts: facts
           }),
         do: {:ok, s}
  end

  # The parent of a finished child gets the child's kept finish when its schema
  # is the declared result of the parent's binding.
  defp nested_outcome(s, state, child, correlation) do
    parent = child.parent

    case child[:finish] do
      nil ->
        internal_outcome(s, parent, "completed", "nested_completed", correlation)

      %{schema_id: id, schema_version: version} = finish ->
        {binding, s} = choose_for(s, state, parent)

        if {id, version} == binding.result,
          do: internal_outcome(s, parent, "completed", nil, correlation, finish),
          else:
            internal_outcome(s, parent, "failed", "nested_result_invalid", %{
              actual: correlation.actual,
              dispatch: "dispatched"
            })
    end
  end

  defp internal_outcome(s, key, class, reason, correlation, result \\ nil) do
    {state, s} = read_state(s)
    slot = Map.fetch!(state.slots, key)

    if class in ["refused", "out_of_budget"] and
         slot.phase in [:ready, :approval, :running, :opening] do
      with {:ok, s} <- continuation(s, key, :refusing, %{refusal: reason}),
           do: internal_outcome(s, key, class, reason, correlation, result)
    else
      id =
        stable_id(
          "out:",
          {protocol_version(s), {s.opts.identity, s.opts.run_id}, elem(key, 0), elem(key, 1),
           :gate_refusal}
        )

      record = %{
        version: protocol_version(s),
        kind: :protocol,
        id: id,
        run_id: state.control.run_id,
        attempt_id: slot.attempt_id,
        input: internal_input(state, key, slot, class, reason, result, s.opts.clock.()),
        correlation: Map.put(correlation, :occurrence, key),
        context: Map.take(s.opts.context.(), [:pause_deadline])
      }

      with {:ok, _, s} <- commit(s, id, record), do: {:ok, s}
    end
  end

  defp internal_input(state, key, slot, class, reason, nil, at),
    do:
      outcome(
        state.version,
        slot.action_id,
        class,
        @refusal_schema,
        refusal(state, key, reason),
        at
      )

  defp internal_input(state, _key, slot, class, _reason, finish, at) do
    outcome(state.version, slot.action_id, class, finish.schema_id, finish.payload, at)
    |> Map.put("schema_version", finish.schema_version)
  end

  # `:failed` comes only from a root finish that names no action (its :finish record).
  # The failure belongs to the Attempt of that finish: the evidence row and the owner
  # command carry it, and the reason says the pattern ended the Run. An owner whose
  # current Attempt is newer answers `stale`; the new Run view then drops the failure.
  defp finish_run(s, result, key) do
    {state, s} = read_state(s)

    attempt =
      if result == :failed, do: state.slots[key].attempt_id, else: state.control.attempt_id

    {evidence, s} =
      if result in [:completed, :failed],
        do: completion_evidence(s, key, attempt),
        else: {nil, s}

    reason =
      cond do
        result == :failed -> "pattern"
        state.control.charge_stopped -> "request_cap"
        true -> "engine"
      end

    fields = %{outcome: result, reason: reason, evidence_ref: evidence}
    fields = if result == :failed, do: Map.put(fields, :attempt_id, attempt), else: fields

    case run_command(s, :complete, fields) do
      {:ok, _, _} ->
        sync_run(s)

      {:unchanged, :duplicate, _} ->
        sync_run(s)

      {:unchanged, :stale, _} when result == :failed ->
        sync_run(s)

      _ ->
        case Run.status(s.opts.run_owner, s.opts.run_id) do
          {:ok, %{outcome: outcome}} when not is_nil(outcome) ->
            sync_run(s)

          _ ->
            {:error, :terminal_commit_pending,
             %{s | halted: :terminal_commit_pending, state: nil, decoded: %{}}}
        end
    end
  end

  defp completion_evidence(s, key, attempt) do
    {state, s} = read_state(s)
    c = state.control
    slot = state.slots[key]
    # The caller's existing Writer/Store is the evidence authority. No invented
    # DU sequence or tuple is passed to Run as a completion reference.
    %{writer: writer, stream: stream} = s.opts.evidence

    event = %{
      run_id: c.run_id,
      attempt_id: attempt,
      operation_id: c.operation_id,
      action_id: slot.action_id
    }

    {:committed, sequence} =
      Elzoo.DurableLog.Writer.append(writer, [{"completion", 1, binary(event)}])

    {%{stream: stream, sequence: sequence}, s}
  end

  defp end_resources(s, outcome) do
    Enum.reduce_while(s.opts.resources, {:ok, s}, fn {name, resource}, {:ok, acc} ->
      at = acc.opts.clock.()

      {:ok, input} =
        PatternStep.decode(%{
          "type" => "input",
          "version" => 1,
          "kind" => "run_ended",
          "at_ms" => at,
          "schema_id" => "elzoo.run-resource.run-ended",
          "schema_version" => 1,
          "payload" => %{"run_id" => s.opts.run_id, "outcome" => Atom.to_string(outcome)}
        })

      result =
        if match?({:ok, %{state: %{run_ended: true}}}, RunResource.read(resource, 0)) do
          {:ok, :already_ended}
        else
          RunResource.command(resource, %{
            id: "ended:" <> s.opts.run_id,
            at_ms: at,
            body: {:input, input}
          })
        end

      case result do
        {:ok, _} ->
          case consume_resource(acc, name, resource) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            error -> {:halt, error}
          end

        _ ->
          {:halt,
           {:error, :cleanup_pending, %{acc | halted: :cleanup_pending, state: nil, decoded: %{}}}}
      end
    end)
  end

  defp consume_resource(s, name, resource) do
    {state, s} = read_state(s)
    cursor = Map.get(state.control.cursors, name, 0)
    {:ok, %{entries: entries}} = RunResource.read(resource, cursor)

    Enum.reduce_while(entries, {:ok, s}, fn entry, {:ok, acc} ->
      result =
        Enum.reduce_while(Enum.with_index(entry.inputs), {:ok, acc}, fn {input, index},
                                                                        {:ok, acc} ->
          {acc_state, acc} = read_state(acc)

          key =
            Enum.find_value(acc_state.slots, fn {key, slot} ->
              if slot.action_id == input["action_id"] and slot[:resource_name] == name, do: key
            end)

          id = stable_id("resource:", {s.opts.run_id, name, entry.seq, index})

          correlation = %{occurrence: key, resource: name}
          context = Map.take(acc.opts.context.(), [:pause_deadline])

          with {:ok, _} <- PatternStep.decode(input),
               native_input = Map.put(input, "version", protocol_version(acc)),
               {:ok, _} <- decode_step(native_input, protocol_version(acc)),
               {:ok, checked, correlation, acc} <-
                 checked_ingress(acc, native_input, correlation),
               :ok <- pause_operand(acc, context, input["at_ms"]) do
            record = %{
              version: protocol_version(acc),
              kind: :protocol,
              id: id,
              run_id: s.opts.run_id,
              attempt_id:
                if(key,
                  do: acc_state.slots[key].attempt_id,
                  else: acc_state.control.attempt_id
                ),
              input: checked,
              correlation: correlation,
              context: context
            }

            case commit(acc, id, record) do
              {:ok, _, acc} -> {:cont, {:ok, acc}}
              error -> {:halt, error}
            end
          else
            {:error, reason} -> {:halt, {:error, reason, acc}}
          end
        end)

      with {:ok, acc} <- result do
        {acc_state, acc} = read_state(acc)

        budget_owner =
          if entry.budget_command do
            {_, command} = entry.budget_command

            Enum.find_value(acc_state.slots, fn {_, slot} ->
              if (slot[:resource_name] == name and slot[:reservation]) &&
                   Map.take(slot.reservation, [:cost_ref, :generation]) ==
                     Map.take(command, [:cost_ref, :generation]),
                 do: slot.callable
            end)
          end

        with :ok <-
               if(entry.budget_command == nil or budget_owner != nil,
                 do: :ok,
                 else: {:error, :resource_budget, acc}
               ),
             {:ok, acc} <- resource_effects(acc, name, resource, entry.effects),
             {:ok, _, acc} <-
               commit(acc, stable_id("cursor:", {s.opts.run_id, name, entry.seq}), %{
                 version: protocol_version(acc),
                 kind: :resource_cursor,
                 resource: name,
                 sequence: entry.seq,
                 budget_owner: budget_owner,
                 budget_command: entry.budget_command,
                 at_ms: s.opts.clock.()
               }) do
          {:cont, {:ok, acc}}
        else
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  defp resource_effects(s, name, owner, effects) do
    Enum.reduce_while(effects, {:ok, s}, fn descriptor, {:ok, acc} ->
      key = {:resource, name, descriptor.identity}
      {acc_state, acc} = read_state(acc)

      origin =
        Enum.find(acc_state.slots, fn {_, slot} ->
          slot[:resource_name] == name and
            (slot[:intent] == descriptor or slot[:intent_digest] == digest(descriptor))
        end)

      # Keep ordinary provenance even after settlement. The ready Resource only
      # exposes its immutable close descriptor without an action in :closing.
      result =
        if origin do
          {occurrence, slot} = origin

          if slot.phase == :settled do
            {:ok, acc}
          else
            with {:ok, acc, owner} <- intent(acc, occurrence, slot) do
              if EffectIntent.status(owner).attempts > 0 do
                # The action command was already sent to the Resource: recovery
                # never resends it and never re-authorizes it. The slot stays
                # open for its cursor, which settles it from the Resource log.
                {:ok, acc}
              else
                if slot[:request_key] do
                  release_waiting(acc, "replacement", %{})
                else
                  state = acc_state
                  {context, acc} = action_context(acc, occurrence, %{})
                  {act, acc} = read_action(acc, state, occurrence)

                  cond do
                    state.control.lifecycle.phase == :paused ->
                      {:ok, acc}

                    permitted?(state, slot, acc.opts.clock.()) and
                      check_payload(acc, act) == :ok and
                        match?(
                          {:ok, %{verdict: :allow}},
                          Authorization.decide(context.policy, context.proposal, context.authority)
                        ) ->
                      dispatch_resource(acc, occurrence, slot)

                    true ->
                      internal_outcome(acc, occurrence, "refused", "resource_authority", %{
                        actual: 0,
                        dispatch: "not_dispatched"
                      })
                  end
                end
              end
            end
          end
        else
          with {:ok, %{state: %{phase: :closing}}} <- RunResource.read(owner, 0),
               {:ok, acc, effect} <- intent(acc, key, %{intent: descriptor}) do
            status = EffectIntent.status(effect)

            if status.active and status.attempts == 0 do
              result =
                RunResource.command(owner, %{
                  id: stable_id("resource-dispatch:", key),
                  at_ms: acc.opts.clock.(),
                  body: {:dispatch, descriptor.identity, effect}
                })

              if match?({:ok, _}, result),
                do: {:ok, acc},
                else:
                  {:error, :cleanup_pending,
                   %{acc | halted: :cleanup_pending, state: nil, decoded: %{}}}
            else
              {:error, :cleanup_pending,
               %{acc | halted: :cleanup_pending, state: nil, decoded: %{}}}
            end
          else
            {:error, _, _} = error ->
              error

            _ ->
              {:error, :unknown_resource_intent,
               %{acc | halted: :unknown_resource_intent, state: nil, decoded: %{}}}
          end
        end

      case result do
        {:ok, acc} -> {:cont, {:ok, acc}}
        other -> {:halt, other}
      end
    end)
  end

  defp apply_control(s, id, %{kind: kind} = command, context)
       when kind in [:begin_attempt, :approval_evidence] do
    case run_command(s, kind, Map.delete(command, :kind)) do
      # An accepted control ends like an input, at the end of a drain, and replies after it.
      {:ok, _, _} ->
        with {:ok, s} <- sync_run(s),
             {:ok, s} <- release_waiting(s, id, context),
             do: drain(s)

      other ->
        {:error, {:run_control, other}, s}
    end
  end

  defp apply_control(s, id, %{kind: kind} = command, context) when kind in [:pause, :continue] do
    {state, s} = read_state(s)

    event =
      command
      |> Map.delete(:kind)
      |> Map.put(:control, kind)
      |> Map.put(:at_ms, s.opts.clock.())
      |> Map.put(:attempt_id, state.control.attempt_id)

    context = Map.take(context, [:verified_person, :pause_deadline])

    with {:ok, record} <-
           original_record(s, id, %{
             version: protocol_version(s),
             kind: :lifecycle,
             command: event,
             context: context
           }),
         {:ok, _, _} <-
           lifecycle_decide(
             lifecycle(state, nil),
             record.command,
             life_context(
               state,
               record.context,
               state.control.attempt_id,
               false,
               record.command.at_ms
             ),
             state.version
           ),
         {:ok, _, s} <- commit(s, id, record),
         {state_after, s} = read_state(s),
         {:ok, s} <-
           resource_control(
             s,
             if(state_after.control.lifecycle.phase == :paused, do: :pause, else: :continue),
             record.command.at_ms
           ),
         {:ok, s} <- consume_resources(s) do
      drain(s)
    else
      {:error, _, _} = error -> error
      {:error, :input_id_conflict} -> {:error, :input_id_conflict, s}
      _ -> {:error, :invalid_control, s}
    end
  end

  defp apply_control(s, id, %{kind: :cancel, attempt_id: attempt}, context) do
    {state, s} = read_state(s)
    c = state.control

    if attempt != c.attempt_id do
      {:ok, s}
    else
      input = %{
        "type" => "input",
        "version" => protocol_version(s),
        "kind" => "cancel",
        "attempt_id" => attempt
      }

      case ingest(s, id, input, Map.merge(context, %{run_id: c.run_id, attempt_id: attempt})) do
        {{:ok, _}, s} ->
          Enum.each(s.work, fn {_, ref} -> AsyncWork.cancel(s.opts.async_work, ref) end)
          {:ok, s}

        {_, s} ->
          {:error, :cancel_unknown, s}
      end
    end
  end

  defp apply_control(s, _, _, _), do: {:error, :invalid_control, s}

  defp release_waiting(s, id, context) do
    {state, s} = read_state(s)

    Enum.reduce_while(state.slots, {:ok, s}, fn {key, slot}, {:ok, acc} ->
      recovering =
        slot.phase in [:running, :reconcile] and
          (id in ["startup", "replacement"] or
             slot.kind in ["resource_open", "resource_use", "resource_close"])

      {acc_state, acc} = read_state(acc)

      if (slot.phase in [:approval, :ready] or recovering) and not is_nil(slot[:request_key]) and
           permitted?(acc_state, slot, acc.opts.clock.()) do
        {act, acc} = read_action(acc, acc_state, key)

        if check_payload(acc, act) == :ok do
          {ctx, acc} = action_context(acc, key, context)

          fresh =
            Map.take(ctx, [
              :now,
              :max_age,
              :verifiers,
              :run,
              :policy,
              :proposal,
              :authority,
              :approver
            ])

          if slot.kind not in ["tool_call", "model_call"] do
            result =
              run_command(acc, :release_approved, %{request_key: slot.request_key, context: fresh})

            case result do
              {:ok, _, %{approval: :released}} ->
                result =
                  if slot.phase in [:running, :reconcile] and
                       slot.kind in ["resource_open", "resource_use", "resource_close"],
                     do: dispatch_resource(acc, key, slot),
                     else:
                       with(
                         {:ok, acc} <- continuation(acc, key, :ready, %{}),
                         do: dispatch(acc, key, %{slot | phase: :ready})
                       )

                case result do
                  {:ok, acc} -> {:cont, {:ok, acc}}
                  other -> {:halt, other}
                end

              {:ok, _, %{approval: :waiting}} ->
                {:cont, {:ok, acc}}

              _ ->
                {:cont, {:ok, acc}}
            end
          else
            result =
              if check_binding(acc, slot.intent) == :ok do
                run_command(acc, :dispatch_approved, %{
                  request_key: slot.request_key,
                  context: fresh,
                  intent: %{
                    identity: slot.intent.identity,
                    arguments: slot.intent.arguments,
                    binding_ref: slot.intent.binding,
                    deadline: slot.intent.deadline_ms
                  }
                })
              else
                {:error, :changed_binding}
              end

            case result do
              {:ok, _, %{classification: classification}} ->
                result =
                  case classification do
                    :dispatched ->
                      continuation(acc, key, :running, %{})

                    value when value in [:settled, :unknown] ->
                      with {:ok, acc} <- continuation(acc, key, :running, %{}),
                           do:
                             internal_outcome(acc, key, "unknown", "lost_outcome", %{
                               dispatch: "unknown"
                             })

                    :reconciliation_required ->
                      continuation(acc, key, :reconcile, %{reconciliation: :read_only})

                    :not_sent ->
                      internal_outcome(acc, key, "refused", "not_sent", %{
                        actual: 0,
                        dispatch: "not_dispatched"
                      })

                    :waiting_approval ->
                      {:ok, acc}
                  end

                case result do
                  {:ok, acc} -> {:cont, {:ok, acc}}
                  error -> {:halt, error}
                end

              {:error, :changed_binding} ->
                {:halt,
                 {:error, :changed_binding,
                  %{acc | halted: :changed_binding, state: nil, decoded: %{}}}}

              _ ->
                {:cont, {:ok, acc}}
            end
          end
        else
          {:cont, {:ok, acc}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  # A :reconcile Resource slot that carried reconciliation :read_only while its
  # intent was inactive carries :active once the intent is active again, so the
  # view does not report a stale read-only reconciliation.
  defp reactivate_reconcile(acc, key, %{phase: :reconcile, reconciliation: :read_only}) do
    continuation(acc, key, :reconcile, %{reconciliation: :active})
  end

  defp reactivate_reconcile(acc, _key, _slot), do: {:ok, acc}

  defp action_context(s, key, overrides) do
    {state, s} = read_state(s)
    slot = state.slots[key]
    {action, s} = read_action(s, state, key)
    binding = choose(s, slot.kind, fn -> action end)
    context = Map.merge(s.opts.context.(), overrides)

    {Map.merge(context, %{
       now: s.opts.clock.(),
       proposal: Map.put(binding.proposal.(action), :tenant, s.opts.tenant),
       authority: %{
         proposer: s.opts.principal,
         effect_class: binding.effect_class,
         own: context.authority,
         parent: state.control.callables[slot.callable].authority
       }
     }), s}
  end

  defp recover_intents(s) do
    {state, s} = read_state(s)

    Enum.reduce_while(state.slots, {:ok, s}, fn {key, slot}, {:ok, acc} ->
      if slot.phase in [:running, :reconcile] and
           slot.kind in ["model_call", "tool_call", "resource_open", "resource_use"] and
           is_nil(slot[:request_key]) do
        with {:ok, acc, owner} <- intent(acc, key, slot) do
          view = EffectIntent.status(owner)

          result =
            cond do
              not view.active ->
                continuation(acc, key, :reconcile, %{reconciliation: :read_only})

              slot.kind in ["resource_open", "resource_use"] ->
                # A durable running or reconcile Resource slot proves the
                # Resource accepted the action command, which is never sent
                # again. dispatch_resource/3 takes the first-dispatch decision
                # on the intent alone: an intent with attempts stays untouched
                # and open for its cursor; an untried active intent gets only
                # the {:dispatch, ...} under its deterministic ID; an inactive
                # one moves to :reconcile with read_only. The slot keeps its
                # phase so drain/1 does not select it and resend the action; a
                # :reconcile slot whose intent is active again carries
                # reconciliation :active, not the stale :read_only.
                with {:ok, acc} <- dispatch_resource(acc, key, slot),
                     {:ok, acc} <- reactivate_reconcile(acc, key, slot) do
                  {:ok, acc}
                end

              view.attempts > 0 ->
                internal_outcome(acc, key, "unknown", "lost_outcome", %{dispatch: "unknown"})

              true ->
                facts = %{reconciliation: :active}

                with {:ok, acc} <- continuation(acc, key, :ready, facts) do
                  {acc_state, acc} = read_state(acc)

                  if acc_state.control.lifecycle.phase == :paused do
                    {:ok, acc}
                  else
                    progress(acc, key, Map.merge(slot, Map.put(facts, :phase, :ready)))
                  end
                end
            end

          case result do
            {:ok, acc} -> {:cont, {:ok, acc}}
            other -> {:halt, other}
          end
        else
          other -> {:halt, other}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp consume_resources(s) do
    Enum.reduce_while(s.opts.resources, {:ok, s}, fn {name, owner}, {:ok, acc} ->
      case consume_resource(acc, name, owner) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        other -> {:halt, other}
      end
    end)
  end

  defp resource_control(s, kind, at) do
    Enum.reduce_while(s.opts.resources, {:ok, s}, fn {name, owner}, {:ok, acc} ->
      result =
        RunResource.command(owner, %{
          id: stable_id("control:", {name, kind, at}),
          at_ms: at,
          body: kind
        })

      if match?({:ok, _}, result),
        do: {:cont, {:ok, acc}},
        else: {:halt, {:error, :resource_control_unknown, acc}}
    end)
  end

  defp hold_request(s, key, request_key) do
    with {:ok, s} <- continuation(s, key, :approval, %{request_key: request_key}),
         do: release_waiting(s, "retained", %{})
  end

  defp listed_request(s, slot) do
    %{action: %{action_id: action_id}, requirement: %{name: name, version: version}} = slot.decision

    with {:ok, view} <- Run.status(s.opts.run_owner, s.opts.run_id),
         %{request_key: request_key} <-
           Enum.find(view.approvals, fn
             %{request_key: {run_id, ^action_id, ^name, ^version, _}, status: status} ->
               run_id == s.opts.run_id and status != :superseded

             _ ->
               false
           end) do
      {:ok, request_key}
    else
      _ -> :none
    end
  end

  defp run_command(s, kind, fields) do
    {:ok, view} = Run.status(s.opts.run_owner, s.opts.run_id)

    command =
      Map.merge(
        %{
          kind: kind,
          run_id: s.opts.run_id,
          attempt_id: view.current_attempt,
          expected_revision: view.revision
        },
        fields
      )

    Run.command(s.opts.run_owner, command)
  end

  defp commit(s, id, record) do
    if Map.get(record, :version) == protocol_version(s),
      do: do_commit(s, id, record),
      else: {:error, :protocol_version_mismatch, s}
  end

  defp do_commit(s, id, record) do
    case DurableUnit.step(s.unit, id, record) do
      {:ok, :applied} ->
        {:ok, :applied, %{s | state: nil, appended: true}}

      {:ok, :duplicate} ->
        {:ok, :unchanged, %{s | state: nil}}

      {:error, :input_id_conflict} ->
        # Internal logical IDs do not depend on sampled answer/time. Read the
        # winner, never invent a new ID to evade an uncertain append.
        winner = find_input(s.opts.store, s.opts.identity, id, 1)

        if winner &&
             Map.take(winner, [:kind, :request, :occurrence]) ==
               Map.take(record, [:kind, :request, :occurrence]),
           do: {:ok, :unchanged, %{s | state: nil}},
           else: storage_failure(%{s | state: nil}, {:error, :integrity_failure})

      other ->
        storage_failure(%{s | state: nil}, other)
    end
  catch
    :exit, _ ->
      {:error, :delivery_unknown, %{s | halted: :delivery_unknown, state: nil, decoded: %{}}}
  end

  defp storage_failure(s, {:error, {:rejected, _}}) do
    case DynamicUnits.stop(s.opts.directory, s.opts.identity) do
      :ok ->
        {:error, :storage_rejected, %{s | halted: :storage_rejected, state: nil, decoded: %{}}}

      _ ->
        {:error, :stop_unknown, %{s | halted: :stop_unknown, state: nil, decoded: %{}}}
    end
  end

  defp storage_failure(s, {:error, reason}),
    do: {:error, reason, %{s | halted: reason, state: nil, decoded: %{}}}

  defp storage_failure(s, _),
    do: {:error, :storage_unknown, %{s | halted: :storage_unknown, state: nil, decoded: %{}}}

  defp ack(s, item) do
    {1, {:request, request}} = :erlang.binary_to_term(item.payload, [:safe])
    {state, s} = read_state(s)

    pending =
      Enum.any?(state.slots, fn {{ordinal, _}, slot} ->
        ordinal == request and slot.phase in [:checking, :refusing, :allowed, :authorizing, :ready]
      end)

    if pending do
      {:ok, s}
    else
      ack_nonce = :crypto.strong_rand_bytes(16)

      case Outbox.ack(s.opts.store, item.idempotency_key, ack_nonce) do
        {:committed, _} ->
          {:ok, s}

        {:indeterminate, _receipt} ->
          request = Elzoo.DurableLog.Codec.ack_receipt(item.idempotency_key, ack_nonce)

          case Elzoo.DurableLog.confirm_ack(s.opts.store, request) do
            {:committed, _} -> {:ok, s}
            _ -> {:ack_unknown, s}
          end

        {:conflict, _} ->
          case Elzoo.DurableLog.Store.read(s.opts.store, :read_ack, [item.idempotency_key]) do
            {:ok, %{state: :acked, idempotency_key: key}} when key == item.idempotency_key ->
              {:ok, s}

            _ ->
              {:ack_unknown, s}
          end

        _ ->
          {:ack_unknown, s}
      end
    end
  end

  defp sample_gate(s, action) do
    binding = choose(s, action["kind"], fn -> action end)

    try do
      {:ok, checked} =
        decode_step(
          %{"type" => "request", "version" => protocol_version(s), "actions" => [action]},
          protocol_version(s)
        )

      case s.opts.gate.call.(checked, %{
             proposer: s.opts.principal,
             effect_class: binding.effect_class,
             tenant: s.opts.tenant
           }) do
        :allow ->
          :allow

        {:deny, reason} when is_binary(reason) ->
          if byte_size(reason) in 1..64 and Regex.match?(~r/\A[a-z0-9_]+\z/, reason),
            do: {:deny, reason},
            else: {:deny, "gate_failure"}

        _ ->
          {:deny, "gate_failure"}
      end
    catch
      _, _ -> {:deny, "gate_failure"}
    end
  end

  defp check_payload(s, map) do
    case s.opts.schemas[{map["schema_id"], map["schema_version"]}] do
      %{compiled: compiled, port: port} -> PayloadSchema.check(compiled, port, map["payload"])
      _ -> {:error, :unknown_schema}
    end
  end

  defp read_action(s, state, {request, index} = key) do
    case state.slots[key][:action] do
      nil ->
        cache_key = {state.control.run_id, request}

        case s.decoded do
          %{^cache_key => actions} ->
            {Enum.at(actions, index), s}

          _ ->
            {:ok, _, map} =
              state.requests[request]
              |> Jason.decode!()
              |> decode_request(state.version)

            actions = map["actions"]
            {Enum.at(actions, index), put_in(s.decoded[cache_key], actions)}
        end

      action ->
        {action, s}
    end
  end

  defp action_ids?(action), do: text?(action["id"], 200) and text?(action["schema_id"], 200)

  defp schema_identities(schemas),
    do: Map.new(schemas, fn {key, value} -> {key, {value.port, value.digest}} end)

  defp binding_identities(bindings),
    do: Map.new(bindings, fn {key, value} -> {key, binding_identity(value)} end)

  defp binding_identity(%{id: id} = binding), do: {id, binding.version}

  defp binding_identity(by_schema),
    do: Map.new(by_schema, fn {schema_id, b} -> {schema_id, {b.id, b.version}} end)

  # An entry of `bindings` is a binding or a schema map from schema_id to binding.
  defp bindings?(bindings), do: Enum.all?(bindings, fn {_kind, entry} -> entry?(entry) end)

  defp entry?(entry),
    do:
      binding?(entry) or
        (is_map(entry) and map_size(entry) > 0 and
           Enum.all?(entry, fn {schema_id, b} -> text?(schema_id, 200) and binding?(b) end))

  defp binding?(entry),
    do: is_map(entry) and Map.has_key?(entry, :id) and not Enum.any?(Map.keys(entry), &is_binary/1)

  # The binding of an action: the entry of its kind, or, for a schema map, the
  # binding of its schema_id. The action is read only for a schema map.
  defp choose(s, kind, action_fun) do
    case s.opts.bindings[kind] do
      %{id: _} = binding ->
        binding

      by_schema when is_map(by_schema) ->
        case action_fun.() do
          %{"schema_id" => schema_id} -> Map.get(by_schema, schema_id)
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp choose_for(s, state, key) do
    case s.opts.bindings[state.slots[key].kind] do
      %{id: _} = binding ->
        {binding, s}

      by_schema when is_map(by_schema) ->
        {act, s} = read_action(s, state, key)

        binding =
          case act do
            %{"schema_id" => schema_id} -> Map.get(by_schema, schema_id)
            _ -> nil
          end

        {binding, s}

      nil ->
        {nil, s}
    end
  end

  defp read_state(%{halted: nil, state: state} = s) when not is_nil(state) do
    if Process.alive?(s.unit), do: {state, s}, else: read_state(%{s | state: nil})
  end

  defp read_state(s) do
    if Process.alive?(s.unit) do
      try do
        state = DurableUnit.snapshot(s.unit)
        {state, if(is_nil(s.halted), do: %{s | state: state}, else: s)}
      catch
        # The Unit died between the liveness check and the call (for example
        # DynamicUnits.stop): answer the last committed durable state, the same
        # read a restarted Unit replays. A read never halts the engine; only an
        # uncertain write does (commit/3, current/1). Never cache the fallback.
        :exit, _ -> {recover_snapshot(s), %{s | state: nil}}
      end
    else
      {recover_snapshot(s), %{s | state: nil}}
    end
  end

  defp recover_snapshot(s) do
    {_, %{fold: fold}} = s.opts.store

    recovered =
      Elzoo.Checkpoint.recover(s.opts.store, s.opts.identity, fold, 1, fn bytes ->
        {:ok, :erlang.binary_to_term(bytes, [:safe])}
      end)

    recovered.model.state
  end

  defp snapshot_value(control), do: %{control: control}

  defp valid_event_source?(%{id: id, version: version, head: head, read: read} = source) do
    map_size(source) == 4 and text?(id, 200) and is_integer(version) and
      version > 0 and is_function(head, 1) and is_function(read, 2)
  end

  defp valid_event_source?(_), do: false

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) in 1..max and String.valid?(s) and
        not String.contains?(s, <<0>>)

  defp pause_operand(s, context, at) do
    if s.opts.budget_rule == :finish or
         (is_integer(context[:pause_deadline]) and context.pause_deadline > at),
       do: :ok,
       else: {:error, :pause_deadline_required}
  end

  defp classify(state, classification), do: put_in(state.control.classification, classification)

  defp active_count(state),
    do: Enum.count(state.slots, fn {_, s} -> s.phase != :settled or s[:pending_input] != nil end)

  defp slot_fits?(slot), do: bytes(slot) <= @slot_bytes

  # What the continuation keeps in control for a child finish; dispatch and the
  # reserve below build it with this one function.
  defp kept_finish(action) do
    %{
      schema_id: action["schema_id"],
      schema_version: action["schema_version"],
      payload: action["payload"]
    }
  end

  # The action that a root finish names: its payload's `action_id`; nil when that is
  # null or absent, or when the payload is not an object.
  defp named_source(%{"payload" => %{"action_id" => id}}), do: id
  defp named_source(_), do: nil

  # A non-root finish whose callable has kept no finish: the continuation will keep it.
  defp keeps_first_finish?(c, slot) do
    node = c.callables[slot.callable]

    slot.kind == "finish" and slot.callable != "root" and node.closed == false and
      is_nil(node[:finish])
  end

  defp fits?(state) do
    if plain?(state) do
      c = state.control

      {callables_skel, open_state_delta, open_reserve} =
        Enum.reduce(c.callables, {%{}, 0, 0}, fn {id, node}, {acc, delta, reserve} ->
          if node.closed do
            {Map.put(acc, id, node), delta, reserve}
          else
            ns_bytes = bytes(node.state)
            bound = Map.get(node, :state_bytes, 65_536)

            {Map.put(acc, id, %{node | state: ""}), delta + ns_bytes - 6,
             reserve + max(0, bound - ns_bytes)}
          end
        end)

      control_bytes = bytes(%{c | callables: callables_skel}) + open_state_delta

      {slots_ok?, slots_bytes, active, pending_finish} =
        Enum.reduce_while(state.slots, {true, 6, 0, 0}, fn {key, slot},
                                                           {_, map_bytes, active, pending} ->
          s_bytes = bytes(slot)

          if s_bytes <= @slot_bytes do
            k_payload = term_payload_bytes(key)

            active =
              if slot.phase != :settled or slot[:pending_input] != nil, do: active + 1, else: active

            pending =
              if slot.phase in [:authorizing, :approval, :ready] and keeps_first_finish?(c, slot),
                do: pending + bytes(kept_finish(slot.action)) + 7,
                else: pending

            {:cont, {true, map_bytes + k_payload + s_bytes - 1, active, pending}}
          else
            {:halt, {false, 0, 0, 0}}
          end
        end)

      reserved =
        (c.cap + 1 - map_size(c.receipts)) * 1_024 + active * 4_096 + pending_finish +
          open_reserve

      if slots_ok? and control_bytes + reserved <= @control_bytes and slots_bytes <= 8_388_608 do
        requests_bytes = bytes(state.requests)

        if requests_bytes <= @request_bytes do
          state_bytes =
            if map_size(state) == 4 and Map.get(state, :version) in [1, 2] and
                 Map.has_key?(state, :control) and Map.has_key?(state, :slots) and
                 Map.has_key?(state, :requests) do
              40 + control_bytes + slots_bytes + requests_bytes
            else
              bytes(%{state | control: %{}, slots: %{}, requests: %{}}) - 18 + control_bytes +
                slots_bytes + requests_bytes
            end

          state_bytes + 171 <= @record_bytes
        else
          false
        end
      else
        false
      end
    else
      false
    end
  end

  defp term_payload_bytes({a, b}), do: 2 + int_payload_bytes(a) + int_payload_bytes(b)
  defp term_payload_bytes(term), do: bytes(term) - 1

  defp int_payload_bytes(n) when is_integer(n) and n >= 0 and n <= 255, do: 2

  defp int_payload_bytes(n) when is_integer(n) and n >= -2_147_483_648 and n <= 2_147_483_647,
    do: 5

  defp int_payload_bytes(term), do: bytes(term) - 1

  defp permitted?(state, slot, at),
    do:
      state.control.lifecycle.phase not in [:paused, :terminal] and
        state.control.stop_pending == nil and slot.attempt_id == state.control.attempt_id and
        at < slot.deadline_ms and not state.control.generation_closed

  defp bytes(term), do: byte_size(binary(term))
  defp plain?(x) when is_atom(x) or is_number(x) or is_binary(x), do: true
  defp plain?(x) when is_list(x), do: Enum.all?(x, &plain?/1)
  defp plain?(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.all?(&plain?/1)

  defp plain?(x) when is_map(x) and not is_struct(x),
    do: Enum.all?(x, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?(_), do: false
  defp binary(term), do: :erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}])
  defp digest(term), do: :crypto.hash(:sha256, binary(term))
  defp occurrence_id({request, index}), do: "#{request}:#{index}"
  defp stable_id(prefix, value), do: prefix <> Base.encode16(digest(value), case: :lower)

  @doc false
  def event_activation_id(run_id, attempt_id, occurrence, source_id),
    do: stable_id("event-activation:", {run_id, attempt_id, occurrence, source_id})

  @doc false
  def event_ticket(tenant, principal, run_id, attempt_id, occurrence, source_id) do
    identity = {run_id, attempt_id, occurrence, source_id}
    stable_id("event-ticket-", {tenant, principal, identity})
  end

  @doc false
  def event_digest(
        event_id,
        source_id,
        ticket,
        sequence,
        source_version,
        schema_id,
        schema_version,
        payload
      ) do
    digest({
      :run_engine_event_v2,
      event_id,
      source_id,
      ticket,
      sequence,
      source_version,
      schema_id,
      schema_version,
      payload
    })
  end

  @doc false
  def project_event_wait_transition(state, record) do
    case record do
      %{kind: :protocol} ->
        project_protocol_wait_transition(state, record)

      %{kind: kind}
      when kind in [:configure, :event_activation, :continuation, :lifecycle, :run_view, :finish] ->
        project_pure_event_wait_transition(state, record)

      # The part of a :resume_input step before its pattern call; it can switch the
      # lifecycle phase (resume_phase/1). The call itself is not projected, as for a
      # settling protocol input.
      %{kind: :resume_input, occurrence: key} ->
        case event_wait_pattern_invocation(state, record) do
          {:ok, _} ->
            {:ok,
             state
             |> update_in([:slots, key], &Map.delete(&1, :pending_input))
             |> resume_phase()}

          _ ->
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  rescue
    _ -> {:error, :history}
  catch
    _, _ -> {:error, :history}
  end

  @doc false
  def valid_event_wait_close_transition?(state, record, actual_state) do
    with {:ok, projected} <- project_event_wait_transition(state, record),
         {:ok, projected} <-
           project_recorded_over_cap_closure(state, record, projected, actual_state),
         true <- event_wait_close_markers(projected) == event_wait_close_markers(actual_state) do
      :ok
    else
      _ -> {:error, :history}
    end
  rescue
    _ -> {:error, :history}
  catch
    _, _ -> {:error, :history}
  end

  defp project_recorded_over_cap_closure(state, record, projected, actual_state) do
    ordinal = projected.control.count + 1
    receipt = get_in(actual_state, [:control, :receipts, ordinal])

    if is_map(receipt) and receipt[:disposition] == :over_cap do
      with {:ok, invocation} <- event_wait_pattern_invocation(state, record),
           true <- ordinal > projected.control.cap,
           true <- receipt == over_cap_receipt(projected, invocation),
           true <- get_in(actual_state, [:control, :count]) == ordinal,
           true <-
             get_in(actual_state, [:control, :invocations, invocation.record.id]) == receipt.digest do
        projected = put_in(projected.control.count, ordinal)
        projected = put_in(projected.control.receipts[ordinal], receipt)
        projected = put_in(projected.control.invocations[invocation.record.id], receipt.digest)

        {:ok,
         close_over_cap_generation(
           projected,
           invocation.record.context,
           invocation.record.input["at_ms"]
         )}
      else
        _ -> {:error, :history}
      end
    else
      {:ok, projected}
    end
  end

  defp event_wait_pattern_invocation(state, %{kind: :protocol} = record) do
    case protocol_transition(state, record) do
      {:continue, next, true, callable} ->
        input = record.input
        hash = digest({input, record.correlation})

        if not next.control.generation_closed and is_nil(next.control.stop_pending) and
             next.control.lifecycle.phase != :paused and not next.control.callables[callable].closed and
             (input["kind"] in ["action_outcome", "person_answer"] or
                fits?(put_in(next.control.invocations[record.id], hash))) do
          {:ok, %{record: record, callable: callable}}
        else
          {:error, :history}
        end

      _ ->
        {:error, :history}
    end
  end

  defp event_wait_pattern_invocation(state, %{kind: :resume_input, occurrence: key}) do
    slot = state.slots[key]

    with %{record: %{kind: :protocol, input: encoded} = pending} <- slot[:pending_input],
         {:ok, input} when is_map(input) <- Jason.decode(encoded),
         true <- state.control.lifecycle.phase not in [:paused, :terminal],
         true <- not state.control.generation_closed and is_nil(state.control.stop_pending),
         true <- not state.control.callables[slot.callable].closed do
      {:ok, %{record: %{pending | input: input}, callable: slot.callable}}
    else
      _ -> {:error, :history}
    end
  end

  defp event_wait_pattern_invocation(
         state,
         %{kind: :nested, occurrence: key, facts: facts} = record
       ) do
    slot = state.slots[key]

    if slot.phase == :ready and permitted?(state, slot, record.at_ms) do
      input = %{
        "type" => "input",
        "version" => state.version,
        "kind" => "start",
        "at_ms" => record.at_ms,
        "schema_id" => facts.schema_id,
        "schema_version" => facts.schema_version,
        "payload" => facts.payload
      }

      {:ok,
       %{
         record: Map.merge(record, %{input: input, correlation: %{occurrence: key}}),
         callable: occurrence_id(key)
       }}
    else
      {:error, :history}
    end
  end

  defp event_wait_pattern_invocation(_, _), do: {:error, :history}

  defp over_cap_receipt(state, %{record: record, callable: callable}) do
    %{
      ordinal: state.control.count + 1,
      input_id: record.id,
      digest: digest({record.input, record.correlation}),
      callable: callable,
      disposition: :over_cap
    }
  end

  defp event_wait_close_markers(state) do
    control = state.control

    {control.stop_pending, control.generation_closed, control.charge_stopped,
     control.lifecycle.phase, control.lifecycle.outcome}
  end

  defp close_over_cap_generation(state, context, at) do
    state = put_in(state.control.generation_closed, true)
    state = put_in(state.control.charge_stopped, true)

    {:ok, wake} =
      decode_step(
        %{"type" => "input", "version" => state.version, "kind" => "wake", "at_ms" => at},
        state.version
      )

    {:ok, life, decision} =
      lifecycle_step(state, wake, life_context(state, context, state.control.attempt_id, true, at))

    install_lifecycle(state, life, decision)
  end

  defp project_protocol_wait_transition(state, record) do
    case protocol_transition(state, record) do
      {:done, {next, _}} -> {:ok, finalize_step_state(next)}
      {:continue, next, _, _} -> {:ok, finalize_step_state(next)}
    end
  end

  defp project_pure_event_wait_transition(state, %{kind: :configure, control: control} = record) do
    if state == @empty or state == @empty_v2 do
      {:Transition, next, _} = configure(state, control)
      {:ok, next}
    else
      {next, _} = transition(state, record)
      {:ok, finalize_step_state(next)}
    end
  end

  defp project_pure_event_wait_transition(state, record) do
    {next, _} = transition(state, record)
    {:ok, finalize_step_state(next)}
  end

  defp outcome(version, id, class, schema, payload, at),
    do: %{
      "type" => "input",
      "version" => version,
      "kind" => "action_outcome",
      "action_id" => id,
      "outcome" => class,
      "schema_id" => schema,
      "schema_version" => 1,
      "payload" => payload,
      "at_ms" => at
    }

  defp refusal(state, {request, index}, reason),
    do: %{
      "reason" => reason,
      "gate_id" => state.control.gate.id,
      "gate_version" => state.control.gate.version,
      "request" => request,
      "index" => index
    }

  defp valid_result_reader_options?(opts) do
    case Keyword.get_values(opts, :result_reader) do
      [] ->
        true

      [%{evidence_store: store, retention_count: retention} = reader] ->
        not is_struct(reader) and map_size(reader) == 2 and
          is_tuple(store) and tuple_size(store) == 2 and is_atom(elem(store, 0)) and
          is_integer(retention) and retention > 0

      _ ->
        false
    end
  end

  defp read_result(s, scope, limits) do
    cond do
      not valid_result_scope?(s, scope) ->
        {:error, :scope}

      not valid_result_limits?(limits) ->
        {:error, :invalid_limits}

      not Map.has_key?(s.opts, :result_reader) ->
        {:error, :reader_unconfigured}

      true ->
        case result_owner(s) do
          {:ok, %{outcome: nil}} ->
            {:pending, :not_completed}

          {:ok, %{outcome: outcome}} when outcome in [:cancelled, :out_of_budget, :out_of_time] ->
            {:terminal, outcome}

          {:ok, %{outcome: :failed} = owner} ->
            failed_result(s, owner, limits)

          {:ok, %{outcome: :completed} = owner} ->
            completed_result(s, owner, limits)

          {:ok, _} ->
            {:error, :completion_mismatch}

          error ->
            error
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :unavailable}
  end

  # event_waits/3 and transcript/3: the same scope, limits, owner and history checks;
  # `reader` is the ResultReader projection of the retained Unit history.
  defp read_retained(s, scope, limits, reader) do
    cond do
      not valid_result_scope?(s, scope) ->
        {:error, :scope}

      not valid_result_limits?(limits) ->
        {:error, :invalid_limits}

      not Map.has_key?(s.opts, :result_reader) ->
        {:error, :reader_unconfigured}

      true ->
        case result_owner(s) do
          {:ok, owner} ->
            with true <- valid_event_wait_owner?(owner, s.opts.run_id),
                 {:ok, projection} <-
                   reader.(
                     s.opts.store,
                     s.opts.identity,
                     owner,
                     s.opts.result_reader.retention_count,
                     limits,
                     s.opts.bindings,
                     reader_config(s),
                     {__MODULE__, :step, empty_state(protocol_version(s))}
                   ),
                 {:ok, current} <- result_owner(s),
                 true <- owner_snapshot(owner) == owner_snapshot(current) do
              {:ok, projection}
            else
              false -> {:error, :unavailable}
              {:error, _} = error -> error
            end

          error ->
            error
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :unavailable}
  end

  defp valid_event_wait_owner?(owner, run_id) when is_map(owner) and not is_struct(owner) do
    is_binary(owner.id) and owner.id == run_id and text?(owner.operation_id, 200) and
      text?(owner.current_attempt, 200) and is_integer(owner.revision) and owner.revision > 0
  end

  defp valid_event_wait_owner?(_, _), do: false

  defp valid_result_scope?(s, scope) when is_map(scope) and not is_struct(scope) do
    Map.keys(scope) |> Enum.sort() == [:principal, :run_id, :tenant] and
      text?(scope.tenant, 200) and text?(scope.principal, 200) and
      text?(scope.run_id, 200) and scope.tenant == s.opts.tenant and
      scope.principal == s.opts.principal and scope.run_id == s.opts.run_id
  end

  defp valid_result_scope?(_, _), do: false

  defp valid_result_limits?(limits) when is_map(limits) and not is_struct(limits) do
    Map.keys(limits) |> Enum.sort() == [:max_bytes, :max_records] and
      is_integer(limits.max_records) and limits.max_records in 1..65_536 and
      is_integer(limits.max_bytes) and limits.max_bytes in 1..536_870_912
  end

  defp valid_result_limits?(_), do: false

  defp reader_config(s) do
    source = Map.get(s.opts, :event_source) || %{}

    %{
      version: protocol_version(s),
      tenant: s.opts.tenant,
      principal: s.opts.principal,
      source_id: Map.get(source, :id),
      source_version: Map.get(source, :version)
    }
  end

  defp result_owner(s) do
    case Run.status(s.opts.run_owner, s.opts.run_id) do
      {:ok, owner} when is_map(owner) -> {:ok, owner}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :unavailable}
  end

  defp completed_result(s, owner, limits) do
    reader = s.opts.result_reader
    evidence = Map.get(s.opts, :evidence)

    with true <- valid_completion_owner?(owner, s.opts.run_id, evidence),
         {:ok, selected} <-
           Elzoo.RunEngine.ResultReader.read(
             s.opts.store,
             s.opts.identity,
             reader.evidence_store,
             evidence.stream,
             owner,
             reader.retention_count,
             limits,
             s.opts.bindings,
             reader_config(s),
             {__MODULE__, :step, empty_state(protocol_version(s))}
           ),
         {:ok, current} <- result_owner(s),
         true <- owner_snapshot(owner) == owner_snapshot(current) do
      {:ok,
       %{
         run_id: owner.id,
         attempt_id: owner.current_attempt,
         operation_id: owner.operation_id,
         action_id: selected.action_id,
         schema_id: selected.schema_id,
         schema_version: selected.schema_version,
         payload: selected.payload,
         evidence_ref: owner.evidence_ref
       }}
    else
      false -> {:error, :completion_mismatch}
      {:error, _} = error -> error
    end
  end

  # An owner `:failed` is read from the history, never from its reason: this Run's
  # journaled root failure gives `{:failed, record}`, a verified history without one
  # gives `{:terminal, :failed}`, and a history that cannot show which gives an error.
  defp failed_result(s, owner, limits) do
    reader = s.opts.result_reader
    evidence = Map.get(s.opts, :evidence)

    with true <- valid_event_wait_owner?(owner, s.opts.run_id),
         {:ok, selected} <-
           Elzoo.RunEngine.ResultReader.read_failed(
             s.opts.store,
             s.opts.identity,
             reader.evidence_store,
             is_map(evidence) && Map.get(evidence, :stream),
             owner,
             valid_completion_owner?(owner, s.opts.run_id, evidence),
             reader.retention_count,
             limits,
             s.opts.bindings,
             reader_config(s),
             {__MODULE__, :step, empty_state(protocol_version(s))}
           ),
         {:ok, current} <- result_owner(s),
         true <- owner_snapshot(owner) == owner_snapshot(current) do
      case selected do
        :plain ->
          {:terminal, :failed}

        failure ->
          {:failed,
           %{
             run_id: owner.id,
             attempt_id: owner.current_attempt,
             operation_id: owner.operation_id,
             action_id: failure.action_id,
             schema_id: failure.schema_id,
             schema_version: failure.schema_version,
             payload: failure.payload,
             evidence_ref: owner.evidence_ref
           }}
      end
    else
      false -> {:error, :completion_mismatch}
      {:error, _} = error -> error
    end
  end

  defp valid_completion_owner?(owner, run_id, evidence) when is_map(evidence) do
    ref = Map.get(owner, :evidence_ref)

    is_binary(owner.id) and owner.id == run_id and text?(owner.operation_id, 200) and
      text?(owner.current_attempt, 200) and is_integer(owner.revision) and owner.revision > 0 and
      is_integer(owner.completion_revision) and owner.completion_revision > 0 and
      owner.completion_revision <= owner.revision and
      is_binary(evidence.stream) and is_map(ref) and not is_struct(ref) and map_size(ref) == 2 and
      Map.keys(ref) |> Enum.sort() == [:sequence, :stream] and
      ref.stream == evidence.stream and is_integer(ref.sequence) and ref.sequence > 0
  end

  defp valid_completion_owner?(_, _, _), do: false

  # The Run's own facts that the readers use. Not `:revision`: it is the revision of the
  # owner's whole stream, which a command of another Run of a shared owner moves too.
  defp owner_snapshot(owner) do
    Map.take(owner, [
      :id,
      :outcome,
      :operation_id,
      :current_attempt,
      :completion_revision,
      :evidence_ref
    ])
  end
end

defmodule Elzoo.RunEngine.HistoryVersion do
  def valid_state?(
        %{version: version, control: nil, slots: slots, requests: requests} = state,
        version
      )
      when version in [1, 2] do
    map_size(state) == 4 and is_map(slots) and map_size(slots) == 0 and is_map(requests) and
      map_size(requests) == 0
  end

  def valid_state?(
        %{version: version, control: control, slots: slots, requests: requests} = state,
        version
      )
      when version in [1, 2] and is_map(control) do
    map_size(state) == 4 and not is_struct(control) and is_map(slots) and not is_struct(slots) and
      is_map(requests) and not is_struct(requests) and valid_control?(control, version) and
      valid_request_cache?(requests, version) and valid_pending_inputs?(slots, version)
  end

  def valid_state?(_, _), do: false

  def valid_record?(%{version: version, kind: kind} = record, input_id, expected_version)
      when is_binary(input_id) do
    version == expected_version and
      case kind do
        :protocol ->
          is_map(record.input) and Map.get(record.input, "version") == expected_version and
            (expected_version != 2 or Map.get(record, :id) == input_id)

        :event_activation ->
          expected_version == 2 and Map.get(record, :id) == input_id

        :configure ->
          valid_control?(Map.get(record, :control), expected_version)

        _ ->
          true
      end
  end

  def valid_record?(_, _, _), do: false

  def valid_request_frame?(frame, version) when version in [1, 2] and is_map(frame) do
    Map.get(frame, "type") == "request" and Map.get(frame, "version") == version and
      match?({:ok, _}, Elzoo.PatternStep.decode(frame, version))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def valid_request_frame?(_, _), do: false

  def valid_input_frame?(frame, version) when version in [1, 2] and is_map(frame) do
    Map.get(frame, "type") == "input" and Map.get(frame, "version") == version and
      match?({:ok, _}, Elzoo.PatternStep.decode(frame, version))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def valid_input_frame?(_, _), do: false

  defp valid_request_cache?(requests, version) do
    Enum.all?(requests, fn
      {_ordinal, encoded} when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, frame} -> valid_request_frame?(frame, version)
          _ -> false
        end

      _ ->
        false
    end)
  rescue
    _ -> false
  end

  defp valid_pending_inputs?(slots, version) do
    Enum.all?(slots, fn
      {_key, slot} when is_map(slot) and not is_struct(slot) ->
        case Map.get(slot, :pending_input) do
          nil ->
            true

          %{record: %{kind: :protocol, input: encoded} = record} when is_binary(encoded) ->
            with {:ok, frame} <- Jason.decode(encoded),
                 true <- valid_input_frame?(frame, version),
                 input_id when is_binary(input_id) <- Map.get(record, :id),
                 true <- valid_record?(%{record | input: frame}, input_id, version) do
              true
            else
              _ -> false
            end

          _ ->
            false
        end

      _ ->
        false
    end)
  rescue
    _ -> false
  end

  defp valid_control?(control, version) when is_map(control) and not is_struct(control) do
    lifecycle = Map.get(control, :lifecycle)
    trackers = Map.get(control, :trackers)

    valid_control_version?(control, version) and valid_control_cap?(control) and
      is_map(lifecycle) and not is_struct(lifecycle) and
      valid_tracker?(Map.get(lifecycle, :tracker), version) and is_map(trackers) and
      not is_struct(trackers) and
      Enum.all?(trackers, fn
        {_ordinal, %{tracker: tracker}} -> valid_tracker?(tracker, version)
        _ -> false
      end)
  end

  defp valid_control?(_, _), do: false

  defp valid_control_version?(control, 1), do: not Map.has_key?(control, :protocol_version)
  defp valid_control_version?(control, 2), do: Map.get(control, :protocol_version) == 2
  defp valid_control_version?(_, _), do: false

  defp valid_control_cap?(%{cap: cap}), do: is_integer(cap) and cap in 1..256
  defp valid_control_cap?(_), do: false

  defp valid_tracker?({:PatternStepTracker, actions}, 1),
    do: is_map(actions) and not is_struct(actions)

  defp valid_tracker?({:PatternStepTrackerV2, actions}, 2),
    do: is_map(actions) and not is_struct(actions)

  defp valid_tracker?(_, _), do: false
end

defmodule Elzoo.RunEngine.ResultReader do
  alias Elzoo.{DurableLog, DurableUnit}

  @record_bytes 16_777_216
  @completion_keys [:action_id, :attempt_id, :operation_id, :run_id]
  @initial_state %{version: 1, control: nil, slots: %{}, requests: %{}}
  @event_wait_protected_fields [
    :action_id,
    :kind,
    :attempt_id,
    :callable,
    :phase,
    :outcome,
    :close_reason,
    :event_source_id,
    :event_source_version,
    :event_cursor,
    :event_ticket,
    :activation_id,
    :activation_at_ms,
    :deadline_ms,
    :event_receipt
  ]

  def event_waits(unit_store, unit_stream, owner, retention, limits, bindings, audit, operator) do
    with {:ok, waits, nil} <-
           read_retained(
             unit_store,
             unit_stream,
             owner,
             retention,
             limits,
             bindings,
             audit,
             operator,
             nil
           ) do
      {:ok, %{run_id: owner.id, attempt_id: owner.current_attempt, waits: waits}}
    end
  end

  def transcript(unit_store, unit_stream, owner, retention, limits, bindings, audit, operator) do
    transcript = %{run_id: owner.id, entries: []}

    with {:ok, _waits, transcript} <-
           read_retained(
             unit_store,
             unit_stream,
             owner,
             retention,
             limits,
             bindings,
             audit,
             operator,
             transcript
           ) do
      {:ok, %{run_id: owner.id, entries: Enum.reverse(transcript.entries)}}
    end
  end

  # `transcript` is nil for event_waits; for transcript/8 it collects the entries
  # of each committed record of the scoped Run during the same fold.
  defp read_retained(
         unit_store,
         unit_stream,
         owner,
         retention,
         limits,
         bindings,
         audit,
         operator,
         transcript
       ) do
    fold = DurableUnit.fold(operator: operator, retention_count: retention)
    counters = %{records: 0, bytes: 0}
    version = elem(operator, 2).version

    with {:ok, model, provenance, counters, unit_head, transcript} <-
           read_unit_history(
             unit_store,
             unit_stream,
             1,
             nil,
             fold,
             version,
             bindings,
             audit,
             limits,
             counters,
             fold.initial,
             %{},
             transcript
           ),
         :ok <- if(is_nil(model.pending), do: :ok, else: {:error, :history}),
         :ok <-
           if(valid_model_version?(model, version),
             do: :ok,
             else: {:error, :history}
           ),
         true <- model.state.control.run_id == owner.id,
         true <- model.state.control.operation_id == owner.operation_id,
         true <- model.state.control.attempt_id == owner.current_attempt,
         {:ok, waits} <- project_event_waits(model.state, provenance, owner, bindings, audit),
         {:ok, _counters} <-
           recheck_head(
             unit_store,
             unit_stream,
             unit_head.revision + 1,
             unit_head,
             limits,
             counters
           ) do
      {:ok, waits, transcript}
    else
      false -> {:error, :unavailable}
      {:error, _} = error -> error
      _ -> {:error, :history}
    end
  rescue
    _ -> {:error, :history}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :history}
  end

  defp project_event_waits(state, provenance, owner, bindings, audit) do
    control = state.control

    with :ok <- valid_audit_control(control, owner, audit),
         {:ok, waits} <-
           state.slots
           |> Enum.filter(fn {_, slot} ->
             slot.kind == "wait_event" and
               (slot.phase == :waiting or not is_nil(slot[:activation_id])) and
               slot.attempt_id == owner.current_attempt
           end)
           |> Enum.sort_by(&elem(&1, 0))
           |> Enum.reduce_while({:ok, []}, fn {key, slot}, {:ok, acc} ->
             case project_event_wait(state, provenance, owner, key, slot, bindings, audit) do
               {:ok, wait} -> {:cont, {:ok, [wait | acc]}}
               {:error, _} = error -> {:halt, error}
             end
           end),
         true <- length(waits) <= 64 * control.cap do
      {:ok, Enum.reverse(waits)}
    else
      false -> {:error, :read_limit}
      {:error, _} = error -> error
      _ -> {:error, :history}
    end
  rescue
    _ -> {:error, :history}
  end

  defp project_event_wait(state, provenance, owner, key, slot, _bindings, audit) do
    control = state.control
    activation = Map.get(provenance, {:activation, owner.id, slot.attempt_id, key})
    settlement = Map.get(provenance, {owner.id, slot.attempt_id, key})

    with %{
           source_id: source_id,
           source_version: source_version,
           ticket: ticket,
           cursor: cursor,
           deadline_ms: deadline,
           activation_id: activation_id,
           activation_at_ms: activation_at
         } <- activation,
         true <- slot.phase in [:waiting, :settled],
         true <- slot.activation_id == activation_id and slot.activation_at_ms == activation_at,
         true <- slot.event_source_id == source_id and slot.event_source_version == source_version,
         true <- slot.event_ticket == ticket and slot.event_cursor == cursor,
         true <- slot.deadline_ms == deadline,
         :ok <- valid_activation_projection(activation, control, slot, owner, audit, key),
         {:ok, accepted_event} <- accepted_event_projection(slot, settlement),
         {:ok, status, outcome} <- projected_wait_state(control, owner, slot) do
      {:ok,
       %{
         occurrence: key,
         action_id: slot.action_id,
         source_id: source_id,
         correlation_id: ticket,
         cursor: cursor,
         deadline_ms: deadline,
         status: status,
         outcome: outcome,
         accepted_event: accepted_event
       }}
    else
      _ -> {:error, :history}
    end
  end

  defp accepted_event_projection(slot, settlement) when is_map(slot) do
    receipt = Map.get(slot, :event_receipt)

    cond do
      slot.phase == :waiting and is_nil(slot[:outcome]) and is_nil(receipt) and is_nil(settlement) ->
        {:ok, nil}

      slot.phase == :settled and slot.outcome == "completed" and
        is_map(receipt) and not is_struct(receipt) and map_size(receipt) == 2 and
        Enum.sort(Map.keys(receipt)) == [:input_id, :sequence] and
        is_map(settlement) and is_map(settlement[:accepted_event]) ->
        event = settlement.accepted_event

        if Map.keys(event) |> Enum.sort() == [:event_id, :input_id, :sequence] and
             is_binary(event.event_id) and is_binary(event.input_id) and
             receipt.input_id == event.input_id and receipt.sequence == event.sequence and
             is_integer(event.sequence) and event.sequence > 0 do
          {:ok, event}
        else
          {:error, :history}
        end

      slot.phase == :settled and is_binary(slot.outcome) and slot.outcome != "completed" and
        is_nil(receipt) and
          (is_nil(settlement) or settlement[:accepted_event] == nil) ->
        {:ok, nil}

      true ->
        {:error, :history}
    end
  end

  def read(
        unit_store,
        unit_stream,
        evidence_store,
        evidence_stream,
        owner,
        retention,
        limits,
        bindings,
        audit,
        operator
      ) do
    with {:ok, model, candidates, counters, unit_head} <-
           read_history(
             unit_store,
             unit_stream,
             owner,
             retention,
             limits,
             bindings,
             audit,
             operator
           ),
         {:ok, source} <- completed_source(model.state, candidates, owner, bindings) do
      read_evidence(
        {unit_store, unit_stream, unit_head},
        {evidence_store, evidence_stream},
        owner,
        source,
        limits,
        counters
      )
    end
  rescue
    _ -> {:error, :history}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :history}
  end

  # An owner `:failed`: `{:ok, :plain}` when the verified history holds no root failure
  # of the Run, else that failure once it and the owner's evidence row agree.
  # `owner_valid?` is the owner's evidence check of the completed reader.
  def read_failed(
        unit_store,
        unit_stream,
        evidence_store,
        evidence_stream,
        owner,
        owner_valid?,
        retention,
        limits,
        bindings,
        audit,
        operator
      ) do
    with {:ok, model, candidates, counters, unit_head} <-
           read_history(
             unit_store,
             unit_stream,
             owner,
             retention,
             limits,
             bindings,
             audit,
             operator
           ),
         {:ok, failure} <- failed_source(model.state, candidates, owner, owner_valid?) do
      if is_nil(failure) do
        with {:ok, _counters} <-
               recheck_head(
                 unit_store,
                 unit_stream,
                 unit_head.revision + 1,
                 unit_head,
                 limits,
                 counters
               ),
             do: {:ok, :plain}
      else
        read_evidence(
          {unit_store, unit_stream, unit_head},
          {evidence_store, evidence_stream},
          owner,
          failure,
          limits,
          counters
        )
      end
    end
  rescue
    _ -> {:error, :history}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :history}
  end

  # The whole retained Unit history, folded, paired and verified against the owner.
  defp read_history(unit_store, unit_stream, owner, retention, limits, bindings, audit, operator) do
    fold = DurableUnit.fold(operator: operator, retention_count: retention)
    version = elem(operator, 2).version

    with {:ok, model, candidates, counters, unit_head, nil} <-
           read_unit_history(
             unit_store,
             unit_stream,
             1,
             nil,
             fold,
             version,
             bindings,
             audit,
             limits,
             %{records: 0, bytes: 0},
             fold.initial,
             %{},
             nil
           ),
         :ok <- if(is_nil(model.pending), do: :ok, else: {:error, :history}),
         :ok <- if(valid_model_version?(model, version), do: :ok, else: {:error, :history}),
         {:ok, _waits} <- project_event_waits(model.state, candidates, owner, bindings, audit) do
      {:ok, model, candidates, counters, unit_head}
    else
      {:error, _} = error -> error
      _ -> {:error, :history}
    end
  end

  # The canonical evidence row that the owner names, then both stream heads again.
  defp read_evidence(
         {unit_store, unit_stream, unit_head},
         {evidence_store, evidence_stream},
         owner,
         source,
         limits,
         counters
       ) do
    with {:ok, completion, counters, evidence_head} <-
           read_completion(
             evidence_store,
             evidence_stream,
             owner.evidence_ref.sequence,
             owner,
             source,
             limits,
             counters
           ),
         {:ok, counters} <-
           recheck_head(
             unit_store,
             unit_stream,
             unit_head.revision + 1,
             unit_head,
             limits,
             counters
           ),
         {:ok, _counters} <-
           recheck_head(
             evidence_store,
             evidence_stream,
             evidence_head.revision + 1,
             evidence_head,
             limits,
             counters
           ),
         true <- completion.action_id == source.action_id do
      {:ok, source}
    else
      false -> {:error, :completion_mismatch}
      {:error, _} = error -> error
    end
  end

  defp read_unit_history(
         store,
         stream,
         sequence,
         head,
         fold,
         version,
         bindings,
         audit,
         limits,
         counters,
         model,
         candidates,
         transcript
       ) do
    with {:ok, rows, current_head} <- read_page(store, stream, sequence),
         :ok <- unit_head(current_head),
         :ok <- stable_head(head, current_head),
         :ok <- if(valid_model_version?(model, version), do: :ok, else: {:error, :history}) do
      head = head || current_head

      cond do
        sequence > head.revision ->
          if rows == [],
            do: {:ok, model, candidates, counters, head, transcript},
            else: {:error, :history}

        length(rows) != 1 ->
          {:error, :history}

        true ->
          [row] = rows

          with {:ok, counters} <- charge(row, counters, limits),
               :ok <- valid_row(row, stream, sequence, fold),
               {:ok, next, candidates} <-
                 reduce_row(row, model, candidates, fold, version, bindings, audit),
               {:ok, transcript} <- transcript_step(transcript, row, model, next) do
            read_unit_history(
              store,
              stream,
              sequence + 1,
              head,
              fold,
              version,
              bindings,
              audit,
              limits,
              counters,
              next,
              candidates,
              transcript
            )
          end
      end
    end
  end

  defp reduce_row(
         %{kind: "input", payload: payload} = row,
         model,
         candidates,
         fold,
         version,
         _bindings,
         _audit
       ) do
    true = valid_input_wire_version?(payload, version)
    next = fold.reduce.(model, row.kind, row.schema_version, row.payload)
    if valid_model_version?(next, version), do: {:ok, next, candidates}, else: {:error, :history}
  rescue
    _ -> {:error, :history}
  catch
    _, _ -> {:error, :history}
  end

  defp reduce_row(
         %{kind: "result"} = row,
         model,
         candidates,
         fold,
         version,
         bindings,
         audit
       ) do
    before = model
    true = valid_result_wire_version?(row.payload, version)
    next = fold.reduce.(model, row.kind, row.schema_version, row.payload)

    with true <- valid_model_version?(next, version),
         {:ok, candidates} <- accepted_activation(before, next, candidates, version, audit),
         :ok <- validate_event_wait_transition(before, next, candidates, version),
         {:ok, candidates} <- accepted_failure(before, next, candidates) do
      candidates =
        case accepted_settlement(before, next, candidates, version, bindings, audit) do
          {:ok, key, candidate} ->
            Map.put_new(candidates, {candidate.run_id, candidate.attempt_id, key}, candidate)

          :none ->
            candidates
        end

      {:ok, next, candidates}
    else
      _ -> {:error, :history}
    end
  rescue
    _ -> {:error, :history}
  catch
    _, _ -> {:error, :history}
  end

  defp reduce_row(_, _, _, _, _, _, _), do: {:error, :history}

  # A root failure: a :finish record with no source whose pure fold, replayed on the
  # state before it, gives exactly the recorded state and settles a root finish that
  # names no action. Such a record that changed nothing (not permitted at its time) is
  # not one. Every other step into a pending `:failed` stop, and such a record whose
  # replay differs, is damaged history. While a failure is pending, a record that ends
  # it (the terminal Run view, or the Run view of a new Attempt, which drops it) or
  # changes the Attempt must replay to exactly its recorded state, in v1 too.
  defp accepted_failure(
         %{pending: {_input_id, record}, state: before},
         %{state: after_state},
         candidates
       )
       when is_map(record) do
    case record do
      %{kind: :finish, source: nil, occurrence: key} ->
        if replays?(before, record, after_state) do
          if after_state === before,
            do: {:ok, candidates},
            else: failure_candidate(before, after_state, key, candidates)
        else
          {:error, :history}
        end

      _ ->
        cond do
          failure_pending?(after_state) and not failure_pending?(before) ->
            {:error, :history}

          failure_pending?(before) and
              (not failure_pending?(after_state) or attempt(before) != attempt(after_state)) ->
            if replays?(before, record, after_state),
              do: {:ok, candidates},
              else: {:error, :history}

          true ->
            {:ok, candidates}
        end
    end
  rescue
    _ -> {:error, :history}
  end

  defp accepted_failure(_, _, candidates), do: {:ok, candidates}

  defp failure_pending?(state), do: get_in(state, [:control, :stop_pending]) == :failed
  defp attempt(state), do: get_in(state, [:control, :attempt_id])

  # The engine's own pure fold of `record` on `before` gives exactly `after_state`.
  defp replays?(before, record, after_state) do
    case Elzoo.RunEngine.project_event_wait_transition(before, record) do
      {:ok, projected} -> projected === after_state
      _ -> false
    end
  end

  # The checks of one root failure against the state before and after it: a root finish
  # of the current Attempt, admitted as the pattern asked for it, naming no action, now
  # settled completed as the Run's completion with the :failed stop pending.
  defp failure_candidate(before, after_state, key, candidates) do
    slot = Map.get(before.slots, key)
    after_slot = Map.get(after_state.slots, key)
    control = after_state.control

    with %{kind: "finish", callable: "root", phase: :ready} <- slot,
         true <- slot.attempt_id == before.control.attempt_id,
         {:ok, action} <- original_action(before, key),
         true <- action === slot[:action] and action["id"] === slot.action_id,
         true <- action["kind"] == "finish",
         false <- match?(%{"payload" => %{"action_id" => id}} when not is_nil(id), action),
         %{phase: :settled, outcome: "completed"} <- after_slot,
         true <- after_slot.action_id == slot.action_id and after_slot.kind == slot.kind,
         true <- after_slot.attempt_id == slot.attempt_id,
         true <- control.completion == key and control.stop_pending == :failed,
         true <- control.generation_closed do
      failure = %{
        key: key,
        run_id: before.control.run_id,
        attempt_id: slot.attempt_id,
        operation_id: before.control.operation_id,
        action_id: slot.action_id,
        schema_id: action["schema_id"],
        schema_version: action["schema_version"],
        payload: action["payload"]
      }

      {:ok, Map.put(candidates, {:failure, failure.run_id, failure.attempt_id, key}, failure)}
    else
      _ -> {:error, :history}
    end
  end

  # The action at its index of the request frame: the request cache keeps the frame
  # while a slot of that request is not yet under way, as a finish in `ready` is not.
  defp original_action(state, {request, index}) do
    with encoded when is_binary(encoded) <- Map.get(state.requests, request),
         {:ok, frame} <- Jason.decode(encoded),
         true <- Elzoo.RunEngine.HistoryVersion.valid_request_frame?(frame, state.version),
         actions when is_list(actions) <- Map.get(frame, "actions"),
         action when is_map(action) <- Enum.at(actions, index) do
      {:ok, action}
    else
      _ -> :error
    end
  end

  # Transcript entries of one committed record: the change of the folded state that
  # the record makes, read together with the record. Nothing is called or stepped.
  # Only the scoped Run's records give entries: an earlier Run on the Unit is
  # folded, and a protocol record of another Run (a late input) gives none.
  defp transcript_step(nil, _row, _before, _next), do: {:ok, nil}
  defp transcript_step(transcript, %{kind: "input"}, _before, _next), do: {:ok, transcript}

  defp transcript_step(
         transcript,
         %{kind: "result", sequence: sequence},
         %{pending: {input_id, record}, state: before},
         %{state: after_state}
       ) do
    run_id = transcript.run_id

    if get_in(after_state, [:control, :run_id]) == run_id and
         (record.kind != :protocol or record.run_id == run_id) do
      before = if get_in(before, [:control, :run_id]) == run_id, do: before, else: nil
      entries = transcript_entries(sequence - 1, input_id, record, before, after_state)
      {:ok, %{transcript | entries: Enum.reverse(entries, transcript.entries)}}
    else
      {:ok, transcript}
    end
  end

  defp transcript_entries(sequence, input_id, record, before, after_state) do
    base = %{sequence: sequence, at_ms: transcript_at(record)}
    before_slots = if before, do: before.slots, else: %{}
    before_callables = if before, do: before.control.callables, else: %{}
    slots = Enum.sort(after_state.slots)
    changed = fn key -> Map.get(before_slots, key) end
    input = if record.kind == :protocol, do: transcript_input(record.input)

    inputs =
      if record.kind == :protocol,
        do: [%{type: :input, input_id: input_id, kind: input["kind"]}],
        else: []

    gates =
      for {key, slot} <- slots,
          record.kind == :gate,
          was = changed.(key),
          is_map(was) and is_nil(was.verdict) and is_map(slot.verdict),
          do: Map.merge(%{type: :gate, occurrence: key}, slot.verdict)

    actions =
      for {key, slot} <- slots,
          record.kind == :admission and key == record.occurrence,
          match?(%{phase: :allowed}, changed.(key)) and slot.phase == :authorizing do
        action = record.facts.action

        %{
          type: :action,
          occurrence: key,
          path: transcript_path(after_state, slot.callable),
          attempt_id: slot.attempt_id,
          kind: slot.kind,
          action_id: slot.action_id,
          schema_id: action["schema_id"],
          schema_version: action["schema_version"],
          payload: action["payload"]
        }
      end

    authorizations =
      for {key, slot} <- slots,
          record.kind == :authorization and key == record.occurrence,
          match?(%{phase: :authorizing}, changed.(key)) and slot.phase != :authorizing do
        {verdict, policy} =
          case record.decision do
            %{verdict: verdict, policy: policy} when verdict in [:allow, :ask, :deny] ->
              {verdict, Map.take(policy, [:id, :version, :content_hash])}

            _ ->
              {:refused, nil}
          end

        %{type: :authorization, occurrence: key, verdict: verdict, policy: policy}
      end

    starts =
      for {key, _slot} <- slots,
          record.kind == :nested and key == record.occurrence,
          callable = transcript_callable(key),
          Map.has_key?(after_state.control.callables, callable),
          not Map.has_key?(before_callables, callable),
          do: %{
            type: :nested_start,
            occurrence: key,
            schema_id: record.facts.schema_id,
            schema_version: record.facts.schema_version,
            payload: record.facts.payload
          }

    finishes =
      after_state.control.callables
      |> Enum.filter(fn {id, node} ->
        is_map(node[:finish]) and is_nil(get_in(before_callables, [id, :finish]))
      end)
      |> Enum.map(fn {_id, node} ->
        %{
          type: :nested_finish,
          occurrence: node.parent,
          schema_id: node.finish.schema_id,
          schema_version: node.finish.schema_version,
          payload: node.finish.payload
        }
      end)
      |> Enum.sort_by(& &1.occurrence)

    settlements =
      for {key, slot} <- slots,
          slot.phase == :settled and not match?(%{phase: :settled}, changed.(key)),
          do: %{
            type: :settlement,
            occurrence: key,
            path: transcript_path(after_state, slot.callable),
            action_id: slot.action_id,
            outcome: slot[:outcome],
            by: record.kind,
            reason: transcript_reason(record, input, key, slot, before),
            actual: transcript_actual(record, key, slot)
          }

    actuals =
      for {key, slot} <- slots,
          was = changed.(key),
          match?(%{phase: :settled}, was) and not is_integer(was[:actual]),
          slot.phase == :settled and is_integer(slot[:actual]),
          do: %{type: :actual, occurrence: key, actual: slot.actual}

    terminal =
      if after_state.control.lifecycle.phase == :terminal and
           get_in(before || %{}, [:control, :lifecycle, :phase]) != :terminal,
         do: [%{type: :terminal, outcome: after_state.control.lifecycle.outcome}],
         else: []

    Enum.map(
      inputs ++
        gates ++
        actions ++
        authorizations ++ starts ++ finishes ++ settlements ++ actuals ++ terminal,
      &Map.merge(base, &1)
    )
  end

  defp transcript_input(input) do
    {:ok, input} = decode_input(input)
    input
  end

  defp transcript_at(%{kind: :protocol, input: input}), do: transcript_input(input)["at_ms"]
  defp transcript_at(%{kind: :run_view, view: view}), do: view.at_ms
  defp transcript_at(%{kind: :lifecycle, command: command}), do: command.at_ms

  defp transcript_at(%{kind: kind, at_ms: at})
       when kind in [
              :gate,
              :admission,
              :authorization,
              :nested,
              :finish,
              :nested_actual,
              :resource_cursor,
              :event_activation
            ],
       do: at

  defp transcript_at(_), do: nil

  # The occurrences of the enclosing nested_callable actions, from the root down:
  # each child callable's parent is the slot of the action that started it.
  defp transcript_path(_state, "root"), do: []

  defp transcript_path(state, callable) do
    parent = state.control.callables[callable].parent
    transcript_path(state, state.slots[parent].callable) ++ [parent]
  end

  defp transcript_callable({request, index}), do: "#{request}:#{index}"

  # Only a refusal outcome for this very slot gives its reason, and only when its own
  # effect settled the slot: one record can also settle slots in its fold step by
  # expiry or run_closed, the named slot included (it expired first, or its late
  # outcome left it to the end of the Run), and those settlements get none.
  defp transcript_reason(%{kind: :protocol} = record, input, key, slot, before) do
    if input["schema_id"] == "elzoo.run-engine.refusal" and
         record.correlation[:occurrence] == key and input["action_id"] == slot.action_id and
         is_map(input["payload"]) and is_map(before) and
         Elzoo.RunEngine.own_settlement?(before, %{record | input: input}, key),
       do: input["payload"]["reason"],
       else: nil
  end

  defp transcript_reason(_record, _input, _key, _slot, _before), do: nil

  # A finish action settled by its :finish record settles its Budget entry at 0.
  defp transcript_actual(%{kind: :finish, occurrence: key}, key, _slot), do: 0

  defp transcript_actual(_record, _key, slot),
    do: if(is_integer(slot[:actual]), do: slot.actual, else: :unknown)

  defp validate_event_wait_transition(
         %{pending: {_input_id, record}, state: before_state},
         %{state: after_state},
         provenance,
         2
       )
       when is_map(record) and is_map(before_state) and is_map(after_state) do
    with {:ok, expected_state} <-
           Elzoo.RunEngine.project_event_wait_transition(before_state, record),
         :ok <- validate_pure_wait_transition_result(record, expected_state, after_state),
         :ok <-
           Elzoo.RunEngine.valid_event_wait_close_transition?(before_state, record, after_state),
         :ok <- validate_activated_waits(expected_state, after_state, provenance) do
      :ok
    else
      _ -> {:error, :history}
    end
  end

  defp validate_event_wait_transition(_, _, _, 1), do: :ok
  defp validate_event_wait_transition(_, _, _, _), do: {:error, :history}

  defp validate_pure_wait_transition_result(
         %{kind: kind},
         expected_state,
         actual_state
       )
       when kind in [:configure, :event_activation, :continuation, :lifecycle, :run_view, :finish],
       do: if(expected_state == actual_state, do: :ok, else: {:error, :history})

  defp validate_pure_wait_transition_result(_, _, _), do: :ok

  defp validate_activated_waits(
         %{control: %{run_id: run_id}, slots: expected_slots} = expected,
         %{control: %{run_id: run_id} = control, slots: actual_slots},
         provenance
       ) do
    activations =
      Enum.flat_map(provenance, fn
        {{:activation, ^run_id, _attempt_id, key}, activation} -> [{key, activation}]
        _ -> []
      end)

    activation_keys = activations |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    with {:ok, expected_keys} <- activated_wait_keys(expected_slots),
         {:ok, actual_keys} <- activated_wait_keys(actual_slots),
         true <- expected_keys == activation_keys and actual_keys == activation_keys,
         true <-
           Enum.all?(activations, fn {key, activation} ->
             expected_slot = Map.get(expected_slots, key)
             actual_slot = Map.get(actual_slots, key)

             same_event_wait?(expected_slot, actual_slot) and
               activation_matches_wait?(activation, expected, expected_slot) and
               activation_matches_wait?(activation, %{expected | control: control}, actual_slot)
           end) do
      :ok
    else
      _ -> {:error, :history}
    end
  end

  defp validate_activated_waits(_, _, _), do: {:error, :history}

  defp activated_wait_keys(slots) do
    slots
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {key, slot}, {:ok, acc} ->
      cond do
        is_map(slot) and slot.kind == "wait_event" and slot.phase == :waiting and
            is_nil(slot[:activation_id]) ->
          {:halt, {:error, :history}}

        is_map(slot) and not is_nil(slot[:activation_id]) ->
          {:cont, {:ok, MapSet.put(acc, key)}}

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp same_event_wait?(expected, actual)
       when is_map(expected) and is_map(actual),
       do:
         Map.take(expected, @event_wait_protected_fields) ==
           Map.take(actual, @event_wait_protected_fields)

  defp same_event_wait?(_, _), do: false

  defp activation_matches_wait?(activation, %{control: control}, slot)
       when is_map(activation) and is_map(control) and is_map(slot) do
    activation.run_id == control.run_id and activation.operation_id == control.operation_id and
      activation.tenant == control.tenant and activation.principal == control.principal and
      activation.source_id == get_in(control, [:event_source, :id]) and
      activation.source_version == get_in(control, [:event_source, :version]) and
      activation.attempt_id == slot.attempt_id and activation.action_id == slot.action_id and
      activation.callable == slot.callable and slot.kind == "wait_event" and
      activation.activation_id == slot.activation_id and
      activation.activation_at_ms == slot.activation_at_ms and
      activation.ticket == slot.event_ticket and activation.cursor == slot.event_cursor and
      activation.deadline_ms == slot.deadline_ms and activation.version == 2
  rescue
    _ -> false
  end

  defp activation_matches_wait?(_, _, _), do: false

  defp accepted_activation(
         %{pending: {_input_id, %{kind: kind}}},
         _next,
         provenance,
         _version,
         _audit
       )
       when kind != :event_activation,
       do: {:ok, provenance}

  defp accepted_activation(
         %{pending: {input_id, record}, state: before},
         %{state: after_state},
         provenance,
         _version,
         audit
       )
       when is_map(record) and is_map(before) and is_map(after_state) do
    key = record[:occurrence]

    with %{kind: :event_activation, version: 2} <- record,
         true <- before.version == 2 and after_state.version == 2,
         true <- input_id == record.id,
         true <- valid_activation_pair?(record, input_id, before, after_state, audit),
         %{kind: "wait_event", phase: :ready} <- before.slots[key],
         %{kind: "wait_event", phase: :waiting} = slot <- after_state.slots[key],
         true <- slot.activation_id == record.id,
         true <- slot.event_source_id == record.source_id,
         true <- slot.event_source_version == record.source_version,
         true <- slot.event_ticket == record.ticket,
         true <- slot.event_cursor == record.cursor,
         true <- slot.deadline_ms == record.deadline_ms,
         true <- slot.activation_at_ms == record.at_ms do
      activation = %{
        run_id: before.control.run_id,
        attempt_id: record.attempt_id,
        operation_id: before.control.operation_id,
        tenant: before.control.tenant,
        principal: before.control.principal,
        source_id: record.source_id,
        source_version: record.source_version,
        version: 2,
        ticket: record.ticket,
        cursor: record.cursor,
        deadline_ms: record.deadline_ms,
        activation_id: record.id,
        activation_at_ms: record.at_ms
      }

      activation =
        Map.merge(activation, %{
          action_id: slot.action_id,
          callable: slot.callable
        })

      activation_key = {:activation, activation.run_id, activation.attempt_id, key}

      if Map.has_key?(provenance, activation_key),
        do: {:error, :history},
        else: {:ok, Map.put(provenance, activation_key, activation)}
    else
      _ -> {:error, :history}
    end
  rescue
    _ -> {:error, :history}
  catch
    _, _ -> {:error, :history}
  end

  defp accepted_activation(_, _, provenance, _, _), do: {:ok, provenance}

  defp valid_model_version?(%{state: %{version: version}, pending: pending} = model, version) do
    valid_model?(model) and Elzoo.RunEngine.HistoryVersion.valid_state?(model.state, version) and
      case pending do
        nil -> true
        {id, record} -> Elzoo.RunEngine.HistoryVersion.valid_record?(record, id, version)
        _ -> false
      end
  end

  defp valid_model_version?(_, _), do: false

  defp valid_input_wire_version?(payload, version) do
    case :erlang.binary_to_term(payload, [:safe]) do
      {1, {id, record}} -> Elzoo.RunEngine.HistoryVersion.valid_record?(record, id, version)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_result_wire_version?(payload, version) do
    case :erlang.binary_to_term(payload, [:safe]) do
      {1, {id, %{version: ^version}}} when is_binary(id) -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_audit_control(control, owner, %{version: 1}) when is_map(control) do
    if control.run_id == owner.id and control.operation_id == owner.operation_id and
         control.attempt_id == owner.current_attempt,
       do: :ok,
       else: {:error, :history}
  end

  defp valid_audit_control(%{protocol_version: 2} = control, owner, %{version: 2} = audit) do
    if audit.version == 2 and control.protocol_version == 2 and
         control.run_id == owner.id and control.operation_id == owner.operation_id and
         control.attempt_id == owner.current_attempt and control.tenant == audit.tenant and
         control.principal == audit.principal and
         control.event_source == %{id: audit.source_id, version: audit.source_version},
       do: :ok,
       else: {:error, :history}
  end

  defp valid_audit_control(_, _, _), do: {:error, :history}

  defp valid_activation_pair?(record, input_id, before, after_state, audit) do
    control = before.control
    source = control[:event_source]
    slot = before.slots[record.occurrence]
    after_slot = after_state.slots[record.occurrence]
    wait = get_in(after_state, [:control, :lifecycle, :waits, slot.action_id])

    activation_keys = [
      :version,
      :kind,
      :id,
      :occurrence,
      :attempt_id,
      :source_id,
      :source_version,
      :ticket,
      :cursor,
      :deadline_ms,
      :at_ms
    ]

    audit.version == 2 and record.id == input_id and record.version == 2 and
      record.kind == :event_activation and control.protocol_version == 2 and
      Enum.sort(Map.keys(record)) == Enum.sort(activation_keys) and
      historical_text?(control.tenant, 200) and historical_text?(control.principal, 200) and
      historical_event_source?(source) and
      control.lifecycle.phase not in [:paused, :terminal] and is_nil(control.stop_pending) and
      not control.generation_closed and slot.attempt_id == control.attempt_id and
      control.attempt_id == record.attempt_id and
      record.source_id == source.id and record.source_version == source.version and
      slot.kind == "wait_event" and slot.phase == :ready and
      slot.attempt_id == record.attempt_id and slot.deadline_ms == record.deadline_ms and
      is_integer(record.cursor) and record.cursor >= 0 and is_integer(record.at_ms) and
      record.at_ms > 0 and record.at_ms < record.deadline_ms and
      record.id ==
        Elzoo.RunEngine.event_activation_id(
          control.run_id,
          record.attempt_id,
          record.occurrence,
          source.id
        ) and
      record.ticket ==
        Elzoo.RunEngine.event_ticket(
          control.tenant,
          control.principal,
          control.run_id,
          record.attempt_id,
          record.occurrence,
          source.id
        ) and after_state.control.event_source == control.event_source and
      is_map(wait) and
      wait == %{
        kind: :outside_event,
        attempt_id: record.attempt_id,
        one_shot: true,
        source_id: record.source_id,
        correlation_id: record.ticket
      } and
      after_slot.phase == :waiting and after_slot.activation_id == record.id and
      after_slot.activation_at_ms == record.at_ms and after_slot.event_ticket == record.ticket and
      after_slot.event_cursor == record.cursor and after_slot.deadline_ms == record.deadline_ms
  rescue
    _ -> false
  end

  defp historical_event_source?(%{id: id, version: version} = source) do
    not is_struct(source) and map_size(source) == 2 and historical_text?(id, 200) and
      is_integer(version) and version > 0
  end

  defp historical_event_source?(_), do: false

  defp historical_text?(value, limit) do
    is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  defp valid_activation_projection(activation, control, slot, owner, audit, key) do
    if audit.version == 2 and activation.run_id == owner.id and
         activation.attempt_id == owner.current_attempt and
         activation.operation_id == owner.operation_id and activation.tenant == audit.tenant and
         activation.principal == audit.principal and activation.source_id == audit.source_id and
         activation.source_version == audit.source_version and
         activation.activation_id == slot.activation_id and
         control.tenant == audit.tenant and control.principal == audit.principal and
         control.event_source == %{id: audit.source_id, version: audit.source_version} and
         activation.activation_id ==
           Elzoo.RunEngine.event_activation_id(
             owner.id,
             owner.current_attempt,
             key,
             audit.source_id
           ) and
         activation.ticket ==
           Elzoo.RunEngine.event_ticket(
             audit.tenant,
             audit.principal,
             owner.id,
             owner.current_attempt,
             key,
             audit.source_id
           ),
       do: :ok,
       else: {:error, :history}
  rescue
    _ -> {:error, :history}
  end

  defp projected_wait_state(_control, _owner, %{phase: :settled, outcome: outcome})
       when is_binary(outcome),
       do: {:ok, :settled, outcome}

  defp projected_wait_state(control, owner, %{phase: :waiting} = slot) do
    if is_nil(slot[:outcome]) and is_nil(slot[:event_receipt]) do
      closed =
        not is_nil(slot[:close_reason]) or not is_nil(control.stop_pending) or
          control.lifecycle.phase == :terminal or not is_nil(owner.outcome)

      {:ok, if(closed, do: :closed, else: :waiting), nil}
    else
      {:error, :history}
    end
  end

  defp projected_wait_state(_, _, _), do: {:error, :history}

  defp accepted_settlement(
         %{pending: {outer_id, record}, state: before},
         %{state: after_state},
         provenance,
         version,
         bindings,
         audit
       )
       when is_map(record) and is_map(before) and is_map(after_state) do
    with {:ok, effective, key} <- effective_protocol(record, before),
         {:ok, input} <- decode_input(effective.input),
         true <- version != 2 or record.kind != :protocol or outer_id == record.id,
         activation <-
           Map.get(provenance, {:activation, effective.run_id, effective.attempt_id, key}),
         before_control when is_map(before_control) <- Map.get(before, :control),
         after_control when is_map(after_control) <- Map.get(after_state, :control),
         before_slot when is_map(before_slot) <- Map.get(before.slots, key),
         after_slot when is_map(after_slot) <- Map.get(after_state.slots, key),
         {:ok, before_action} <- recorded_action(before, key),
         {:ok, accepted_event} <-
           accepted_settlement_event(
             before,
             after_state,
             effective,
             input,
             key,
             activation,
             bindings,
             audit
           ),
         true <- before_control.run_id == effective.run_id,
         true <- after_control.run_id == effective.run_id,
         true <- before_control.attempt_id == effective.attempt_id,
         true <- after_control.attempt_id == effective.attempt_id,
         true <- is_binary(before_control.operation_id),
         true <- before_control.operation_id == after_control.operation_id,
         true <- before_slot.phase != :settled and after_slot.phase == :settled,
         true <- after_slot.outcome == "completed",
         true <- input["action_id"] == before_slot.action_id,
         true <- input["action_id"] == after_slot.action_id,
         true <- before_slot.action_id == after_slot.action_id,
         true <- before_slot.kind == after_slot.kind,
         true <- before_slot.attempt_id == effective.attempt_id,
         true <- after_slot.attempt_id == effective.attempt_id,
         true <- before_action["id"] == before_slot.action_id,
         true <- before_action["kind"] == before_slot.kind do
      {:ok, key,
       %{
         run_id: effective.run_id,
         attempt_id: effective.attempt_id,
         operation_id: before_control.operation_id,
         action_id: after_slot.action_id,
         action_kind: before_action["kind"],
         action_schema_id: before_action["schema_id"],
         schema_id: input["schema_id"],
         schema_version: input["schema_version"],
         payload: input["payload"],
         input_id: effective.id,
         accepted_event: accepted_event
       }}
    else
      _ -> :none
    end
  rescue
    _ -> :none
  end

  defp accepted_settlement(_, _, _, _, _, _), do: :none

  defp accepted_settlement_event(
         before,
         after_state,
         record,
         input,
         key,
         activation,
         bindings,
         audit
       ) do
    slot = before.slots[key]

    if slot.kind == "wait_event" do
      accepted_outside_event(before, after_state, record, input, key, activation, bindings, audit)
    else
      if input["kind"] in ["action_outcome", "person_answer"] and accepted_completion?(input),
        do: {:ok, nil},
        else: :error
    end
  end

  defp accepted_outside_event(before, after_state, record, input, key, activation, bindings, audit) do
    slot = before.slots[key]
    after_slot = after_state.slots[key]
    correlation = record.correlation

    with true <- before.version == 2,
         true <- audit.version == 2,
         %{
           run_id: run_id,
           attempt_id: attempt,
           source_id: source_id,
           source_version: source_version,
           ticket: ticket,
           cursor: cursor,
           activation_id: activation_id
         } <- activation,
         true <- record.kind == :protocol and record.version == 2,
         true <-
           Map.keys(record) |> Enum.sort() == [
             :attempt_id,
             :context,
             :correlation,
             :id,
             :input,
             :kind,
             :run_id,
             :version
           ],
         true <-
           is_map(record.context) and Enum.all?(Map.keys(record.context), &(&1 == :pause_deadline)),
         true <- record.run_id == run_id and record.attempt_id == attempt,
         wait <- get_in(before, [:control, :lifecycle, :waits, slot.action_id]),
         true <-
           is_map(wait) and wait.kind == :outside_event and wait.attempt_id == attempt and
             wait.one_shot == true and wait.source_id == source_id and wait.correlation_id == ticket,
         true <- slot.attempt_id == attempt and slot.phase == :waiting,
         true <- slot.activation_id == activation_id,
         true <- slot.event_source_id == source_id and slot.event_source_version == source_version,
         true <- slot.event_ticket == ticket and slot.event_cursor == cursor,
         true <- input["at_ms"] > 0 and input["at_ms"] < slot.deadline_ms,
         {:ok, _checked_input} <- Elzoo.PatternStep.decode(input, 2),
         true <- input["kind"] == "outside_event" and input["action_id"] == slot.action_id,
         true <- input["source_id"] == source_id and input["correlation_id"] == ticket,
         true <-
           Map.keys(correlation) |> Enum.sort() ==
             Enum.sort([
               :occurrence,
               :actual,
               :source_version,
               :source_sequence,
               :source_head_revision,
               :activation_id,
               :event_digest
             ]),
         true <- correlation.occurrence == key and correlation.actual == 0,
         true <- correlation.source_version == source_version,
         true <- source_id == audit.source_id and source_version == audit.source_version,
         true <-
           before.control.tenant == audit.tenant and before.control.principal == audit.principal,
         true <- before.control.event_source == %{id: source_id, version: source_version},
         true <- correlation.activation_id == activation_id,
         true <- is_integer(correlation.source_sequence) and correlation.source_sequence > cursor,
         true <-
           is_integer(correlation.source_head_revision) and
             correlation.source_head_revision >= correlation.source_sequence,
         true <- correlation.source_head_revision >= cursor,
         true <- is_binary(input["event_id"]),
         true <-
           correlation.event_digest ==
             Elzoo.RunEngine.event_digest(
               input["event_id"],
               source_id,
               ticket,
               correlation.source_sequence,
               source_version,
               input["schema_id"],
               input["schema_version"],
               input["payload"]
             ),
         {:ok, before_action} <- recorded_action(before, key),
         {:ok, {expected_schema, expected_schema_version}} <-
           result_schema(bindings, "wait_event", before_action),
         true <-
           {input["schema_id"], input["schema_version"]} ==
             {expected_schema, expected_schema_version},
         true <- before.control.run_id == run_id and after_state.control.run_id == run_id,
         true <- before.control.attempt_id == attempt and after_state.control.attempt_id == attempt,
         true <- before.control.operation_id == after_state.control.operation_id,
         true <-
           before.control.tenant == audit.tenant and before.control.principal == audit.principal,
         true <-
           after_state.control.tenant == audit.tenant and
             after_state.control.principal == audit.principal,
         true <- after_slot.phase == :settled and after_slot.outcome == "completed",
         true <- is_nil(slot[:event_receipt]),
         true <-
           after_slot.event_receipt ==
             %{input_id: record.id, sequence: correlation.source_sequence} do
      {:ok,
       %{
         event_id: input["event_id"],
         input_id: record.id,
         sequence: correlation.source_sequence
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp accepted_completion?(%{"kind" => "action_outcome", "outcome" => "completed"}), do: true

  defp accepted_completion?(%{"kind" => "person_answer"} = input),
    do: not Map.has_key?(input, "outcome")

  defp accepted_completion?(_), do: false

  defp effective_protocol(%{kind: :protocol, correlation: correlation} = record, _state)
       when is_map(correlation),
       do:
         if(is_tuple(correlation[:occurrence]),
           do: {:ok, record, correlation.occurrence},
           else: :none
         )

  defp effective_protocol(%{kind: :resume_input, occurrence: key}, state) when is_tuple(key) do
    case get_in(state, [:slots, key, :pending_input, :record]) do
      %{kind: :protocol, correlation: %{occurrence: ^key}} = record -> {:ok, record, key}
      _ -> :none
    end
  end

  defp effective_protocol(_, _), do: :none

  defp decode_input(input) when is_map(input), do: {:ok, input}

  defp decode_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> :error
    end
  end

  defp decode_input(_), do: :error

  defp recorded_action(state, {request, index} = key) do
    case get_in(state, [:slots, key, :action]) do
      %{"id" => _} = action ->
        {:ok, action}

      nil ->
        with encoded when is_binary(encoded) <- Map.get(state.requests, request),
             {:ok, request} <- Jason.decode(encoded),
             true <- Elzoo.RunEngine.HistoryVersion.valid_request_frame?(request, state.version),
             actions when is_list(actions) <- Map.get(request, "actions"),
             action when is_map(action) <- Enum.at(actions, index) do
          {:ok, action}
        else
          _ -> {:error, :completion_mismatch}
        end

      _ ->
        {:error, :completion_mismatch}
    end
  rescue
    _ -> {:error, :completion_mismatch}
  end

  defp result_schema(bindings, kind, action) do
    case Map.get(bindings, kind) do
      %{result: {schema_id, version}} when is_binary(schema_id) and is_integer(version) ->
        {:ok, {schema_id, version}}

      by_schema when is_map(by_schema) and not is_struct(by_schema) ->
        case Map.get(by_schema, action["schema_id"]) do
          %{result: {schema_id, version}} when is_binary(schema_id) and is_integer(version) ->
            {:ok, {schema_id, version}}

          _ ->
            {:error, :completion_mismatch}
        end

      _ ->
        {:error, :completion_mismatch}
    end
  rescue
    _ -> {:error, :completion_mismatch}
  end

  defp completed_source(state, candidates, owner, bindings) do
    control = state.control
    key = control.completion

    with true <- control.run_id == owner.id and control.attempt_id == owner.current_attempt,
         true <- control.operation_id == owner.operation_id,
         true <- control.lifecycle.phase == :terminal and control.lifecycle.outcome == :completed,
         true <- is_nil(control.stop_pending) and is_tuple(key),
         {:ok, source} <- Map.fetch(candidates, {owner.id, owner.current_attempt, key}),
         slot when is_map(slot) <- Map.get(state.slots, key),
         true <-
           source.run_id == owner.id and source.attempt_id == owner.current_attempt and
             source.operation_id == owner.operation_id,
         true <-
           source.action_id == slot.action_id and slot.outcome == "completed" and
             slot.phase == :settled and slot.attempt_id == owner.current_attempt and
             slot.attempt_id == source.attempt_id and slot.kind == source.action_kind,
         true <- accepted_completion_pair?(source, slot),
         {:ok, {schema_id, schema_version}} <-
           result_schema(bindings, source.action_kind, %{"schema_id" => source.action_schema_id}),
         true <- {source.schema_id, source.schema_version} == {schema_id, schema_version},
         true <-
           is_binary(source.schema_id) and is_integer(source.schema_version) and
             source.schema_version > 0 and Map.has_key?(source, :payload) do
      {:ok, source}
    else
      _ -> {:error, :completion_mismatch}
    end
  rescue
    _ -> {:error, :completion_mismatch}
  end

  # The root failure of the owner's current Attempt: nil when the history holds none (a
  # failure of an older Attempt was dropped at the change of Attempt). One that it holds
  # must be this owner's operation, the Run's completion, settled, with the Run terminal
  # `:failed`, and the owner must name evidence; else a mismatch.
  defp failed_source(state, candidates, owner, owner_valid?) do
    control = state.control

    failures =
      for {{:failure, run_id, attempt_id, _}, failure} <- candidates,
          run_id == owner.id and attempt_id == owner.current_attempt,
          do: failure

    case failures do
      [] ->
        {:ok, nil}

      [failure] ->
        slot = Map.get(state.slots, failure.key)

        if owner_valid? and failure.attempt_id == owner.current_attempt and
             failure.operation_id == owner.operation_id and
             control.lifecycle.phase == :terminal and control.lifecycle.outcome == :failed and
             is_nil(control.stop_pending) and control.completion == failure.key and
             is_map(slot) and slot.phase == :settled and slot.outcome == "completed" and
             slot.kind == "finish" and slot.action_id == failure.action_id and
             slot.attempt_id == owner.current_attempt,
           do: {:ok, failure},
           else: {:error, :completion_mismatch}

      _ ->
        {:error, :completion_mismatch}
    end
  rescue
    _ -> {:error, :completion_mismatch}
  end

  defp accepted_completion_pair?(%{action_kind: "wait_event", accepted_event: event} = source, slot)
       when is_map(event) and not is_struct(event) and map_size(event) == 3 do
    Enum.sort(Map.keys(event)) == [:event_id, :input_id, :sequence] and
      is_binary(event.event_id) and is_binary(event.input_id) and event.input_id == source.input_id and
      is_integer(event.sequence) and event.sequence > 0 and
      slot.event_receipt == %{input_id: event.input_id, sequence: event.sequence}
  end

  defp accepted_completion_pair?(%{action_kind: kind, accepted_event: nil}, _slot),
    do: kind != "wait_event"

  defp accepted_completion_pair?(_, _), do: false

  defp read_completion(store, stream, sequence, owner, source, limits, counters) do
    fold = %{
      kinds: %{"completion" => :state_bearing},
      versions: [1]
    }

    with {:ok, [row], head} <- read_page(store, stream, sequence),
         :ok <- evidence_head(head, sequence),
         {:ok, counters} <- charge(row, counters, limits),
         :ok <- valid_row(row, stream, sequence, fold),
         {:ok, event} <- decode_completion(row.payload),
         true <- row.kind == "completion" and row.schema_version == 1,
         true <- event.run_id == owner.id and event.attempt_id == owner.current_attempt,
         true <- event.operation_id == owner.operation_id and event.action_id == source.action_id do
      {:ok, event, counters, head}
    else
      {:error, _} = error -> error
      _ -> {:error, :completion_mismatch}
    end
  end

  defp decode_completion(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      event when is_map(event) and not is_struct(event) and map_size(event) == 4 ->
        if Enum.sort(Map.keys(event)) == @completion_keys and
             Enum.all?(@completion_keys, &is_binary(Map.get(event, &1))),
           do: {:ok, event},
           else: {:error, :completion_mismatch}

      _ ->
        {:error, :completion_mismatch}
    end
  rescue
    _ -> {:error, :completion_mismatch}
  end

  defp read_page(store, stream, sequence) do
    case DurableLog.read(store, stream, sequence, 1) do
      {:ok, rows, head} when is_list(rows) and is_map(head) ->
        {:ok, rows, head}

      {:error, {:pruned, _}} ->
        {:error, :history}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp unit_head(head) do
    cond do
      not is_integer(Map.get(head, :revision)) or head.revision < 1 -> {:error, :history}
      Map.get(head, :low_water) != 0 -> {:error, :history}
      not valid_capability?(head) -> {:error, :unavailable}
      not is_nil(Map.get(head, :staged_tail)) -> {:error, :history}
      true -> :ok
    end
  end

  defp evidence_head(head, sequence) do
    cond do
      not is_integer(Map.get(head, :revision)) or head.revision < sequence ->
        {:error, :history}

      not is_integer(Map.get(head, :low_water)) or head.low_water < 0 or
          head.low_water >= sequence ->
        {:error, :history}

      not valid_capability?(head) ->
        {:error, :unavailable}

      not is_nil(Map.get(head, :staged_tail)) ->
        {:error, :history}

      true ->
        :ok
    end
  end

  defp valid_capability?(head) do
    get_in(head, [:capabilities, :append_visibility]) in [:atomic, :staged_uncommitted_tail]
  end

  defp stable_head(nil, _), do: :ok

  defp stable_head(first, current) do
    if head_identity(first) == head_identity(current), do: :ok, else: {:error, :history}
  end

  defp head_identity(head),
    do: Map.take(head, [:revision, :low_water, :capabilities, :staged_tail])

  defp recheck_head(store, stream, sequence, expected, limits, counters) do
    with {:ok, rows, current} <- read_page(store, stream, sequence),
         {:ok, counters} <- charge_rows(rows, counters, limits),
         :ok <- if(rows == [], do: :ok, else: {:error, :history}),
         :ok <- stable_head(expected, current),
         :ok <- if(is_nil(Map.get(current, :staged_tail)), do: :ok, else: {:error, :history}) do
      {:ok, counters}
    else
      {:error, _} = error -> error
    end
  end

  defp charge_rows(rows, counters, limits) do
    Enum.reduce_while(rows, {:ok, counters}, fn row, {:ok, current} ->
      case charge(row, current, limits) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp valid_row(row, stream, sequence, fold) do
    if Map.get(row, :stream) == stream and Map.get(row, :sequence) == sequence and
         DurableLog.validate_row(row, fold, %{max_record_bytes: @record_bytes}) == :ok,
       do: :ok,
       else: {:error, :history}
  rescue
    _ -> {:error, :history}
  end

  defp charge(row, counters, limits) do
    size = :erlang.iolist_size(DurableLog.canonical_bytes(row))

    if size > 0 and counters.records < limits.max_records and
         counters.bytes + size <= limits.max_bytes do
      {:ok, %{records: counters.records + 1, bytes: counters.bytes + size}}
    else
      {:error, :read_limit}
    end
  rescue
    _ -> {:error, :history}
  end

  defp valid_model?(%{state: state, pending: pending, completed: completed})
       when is_list(completed) and (is_nil(pending) or is_tuple(pending)),
       do:
         (state == @initial_state and completed == []) or
           (empty_initial_state?(state) and completed == []) or valid_state?(state)

  defp valid_model?(_), do: false

  defp valid_state?(%{version: version, control: control, slots: slots, requests: requests} = state)
       when version in [1, 2] do
    map_size(state) == 4 and is_map(control) and not is_struct(control) and
      is_map(slots) and not is_struct(slots) and is_map(requests) and not is_struct(requests)
  end

  defp valid_state?(_), do: false

  defp empty_initial_state?(
         %{version: version, control: nil, slots: slots, requests: requests} = state
       )
       when version in [1, 2],
       do: map_size(state) == 4 and map_size(slots) == 0 and map_size(requests) == 0

  defp empty_initial_state?(_), do: false
end
