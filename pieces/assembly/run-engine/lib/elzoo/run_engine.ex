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
  @refusal_schema "elzoo.run-engine.refusal"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def input(engine, id, input, context), do: GenServer.call(engine, {:input, id, input, context})

  def control(engine, id, command, context),
    do: GenServer.call(engine, {:control, id, command, context})

  def status(engine), do: GenServer.call(engine, :status)

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  # The host's DynamicUnits unit_options uses {__MODULE__, :step, the literal
  # empty state above}. Configuration is itself recorded, never a process lookup
  # from inside the transition. Only MFAs and plain declarations survive replay.
  def step(@empty, %{version: 1, kind: :configure, control: control}) do
    next = %{@empty | control: control}
    true = fits?(next)
    {:Transition, next, :none}
  end

  def step(%{version: 1, control: control} = state, %{version: 1} = record)
      when is_map(control) do
    {next, output} = transition(state, record)

    slots =
      Map.new(next.slots, fn {key, slot} ->
        discard =
          next.control.generation_closed or next.control.lifecycle.phase == :terminal or
            slot.attempt_id != next.control.attempt_id or
            next.control.callables[slot.callable].closed

        {key, if(discard, do: Map.delete(slot, :pending_input), else: slot)}
      end)

    next = %{next | slots: slots}

    requests =
      Map.reject(next.requests, fn {ordinal, _} ->
        next.slots
        |> Enum.filter(fn {{request, _}, _} -> request == ordinal end)
        |> Enum.all?(fn {_, slot} -> slot.phase in [:running, :waiting, :settled, :reconcile] end)
      end)

    next = %{next | requests: requests}
    true = fits?(next)
    {:Transition, next, output}
  end

  defp transition(state, %{kind: :protocol} = record) do
    c = state.control
    input = record.input

    cond do
      record.run_id != c.run_id or Run.classify_attempt(c.attempt_id, record.attempt_id) == :stale ->
        {classify(state, :late), :none}

      Map.has_key?(c.invocations, record.id) ->
        true = c.invocations[record.id] == digest({input, record.correlation})
        {classify(state, :duplicate), :none}

      true ->
        state = expire_waits(state, input["at_ms"])
        {state, accepted, callable} = protocol(state, record)

        if accepted and not state.control.generation_closed and
             is_nil(state.control.stop_pending) and state.control.lifecycle.phase != :paused and
             not state.control.callables[callable].closed do
          invoke(state, record, callable)
        else
          if accepted and state.control.lifecycle.phase == :paused and
               not state.control.generation_closed and is_nil(state.control.stop_pending) and
               not state.control.callables[callable].closed and
               record.correlation[:occurrence] != nil do
            key = record.correlation.occurrence

            order =
              Enum.reduce(state.slots, 0, fn {_, slot}, n ->
                max(n, (slot[:pending_input] || %{order: 0}).order)
              end)

            pending = %{order: order + 1, record: %{record | input: Jason.encode!(record.input)}}
            {put_in(state.slots[key][:pending_input], pending), :none}
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
      state = update_in(state.slots[key], &Map.delete(&1, :pending_input))
      invoke(state, %{record | input: Jason.decode!(record.input)}, slot.callable)
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :configure, control: control}) do
    true = state.control.lifecycle.phase == :terminal and active_count(state) == 0
    true = state.control.run_id != control.run_id
    {%{@empty | control: %{control | lifetime: state.control.lifetime}}, :none}
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

        true ->
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
              {put_in(state.slots[key], slot), :none}

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
      state = put_in(state.slots[key], Map.merge(slot, Map.put(facts, :phase, phase)))

      state =
        if facts[:finish_callable],
          do: put_in(state.control.callables[facts.finish_callable].closed, true),
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

  defp transition(state, %{kind: :nested, occurrence: key, facts: facts, at_ms: at} = record) do
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
        depth: state.control.callables[slot.callable].depth + 1
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
        "version" => 1,
        "kind" => "start",
        "at_ms" => at,
        "schema_id" => facts.schema_id,
        "schema_version" => facts.schema_version,
        "payload" => facts.payload
      }

      invoke(
        state,
        Map.merge(record, %{
          input: input,
          correlation: %{occurrence: key}
        }),
        callable
      )
    else
      {state, :none}
    end
  end

  defp transition(state, %{kind: :run_view, view: view}) do
    c = state.control
    true = c.run_id == view.id
    state = if view.current_attempt != c.attempt_id, do: close_local(state, view.at_ms), else: state
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
        state = if c.charge_stopped, do: state, else: close_local(state, view.at_ms)

        state
        |> put_in([:control, :lifecycle, :phase], :terminal)
        |> put_in([:control, :lifecycle, :outcome], view.outcome)
        |> put_in([:control, :stop_pending], nil)
      else
        state
      end

    {state, :none}
  end

  defp transition(state, %{kind: :lifecycle, command: command, context: context}) do
    {:ok, life, decision} =
      BotRunLifecycle.step(
        lifecycle(state, nil),
        command,
        life_context(state, context, state.control.attempt_id, false, command.at_ms)
      )

    state = install_lifecycle(state, life, decision)
    state = restore_waiting(state)
    {classify(state, decision), :none}
  end

  defp transition(state, %{kind: :finish, occurrence: key, source: source, at_ms: at}) do
    slot = state.slots[key]

    if slot.phase == :ready and permitted?(state, slot, at) do
      true = state.slots[source].outcome == "completed"
      true = state.slots[source].attempt_id == slot.attempt_id

      input =
        outcome(slot.action_id, "completed", @refusal_schema, refusal(state, key, "finished"), at)

      {:ok, checked} = PatternStep.decode(input)
      request = state.control.trackers[elem(key, 0)]
      {:applied, tracker} = PatternStep.accept(request.tracker, checked)
      state = put_in(state.control.trackers[elem(key, 0)].tracker, tracker)
      state = settle_join(state, key, input, %{}) |> settle_budget(key, 0, at)

      state =
        put_in(state.slots[key], %{
          action_id: slot.action_id,
          kind: slot.kind,
          callable: slot.callable,
          attempt_id: slot.attempt_id,
          phase: :settled,
          outcome: "completed",
          verdict: slot.verdict
        })

      state = put_in(state.control.completion, source)
      state = put_in(state.control.generation_closed, true)
      {put_in(state.control.stop_pending, :completed), :none}
    else
      {state, :none}
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

  defp protocol(state, record) do
    input = record.input
    kind = input["kind"]
    c = state.control
    key = record.correlation[:occurrence]

    cond do
      kind in ["action_outcome", "person_answer"] ->
        settle_protocol(state, record, key)

      kind == "wake" ->
        exhausted = c.count >= c.cap
        {:ok, checked} = PatternStep.decode(input)

        {:ok, life, decision} =
          BotRunLifecycle.step(
            lifecycle(state, nil),
            checked,
            life_context(state, record.context, record.attempt_id, exhausted, input["at_ms"])
          )

        next = install_lifecycle(state, life, decision)
        next = if exhausted, do: put_in(next.control.generation_closed, true), else: next
        next = if exhausted, do: put_in(next.control.charge_stopped, true), else: next

        {classify(next, decision),
         decision == :permit_new_work and not exhausted and active_count(next) == 0, "root"}

      kind == "cancel" ->
        {:ok, checked} = PatternStep.decode(input)

        {:ok, life, decision} =
          BotRunLifecycle.step(
            lifecycle(state, nil),
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
        {:ok, checked} = PatternStep.decode(input)

        {:ok, life, decision} =
          BotRunLifecycle.step(
            lifecycle(state, nil),
            checked,
            life_context(state, record.context, record.attempt_id, false, input["at_ms"])
          )

        next = install_lifecycle(state, life, decision)
        {classify(next, decision), decision == :permit_new_work and active_count(next) == 0, "root"}
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

      true ->
        request = c.trackers[elem(key, 0)]
        {:ok, checked} = PatternStep.decode(input)
        # Charge closure changes generation permission, not the original tracker.
        # Deadline/cancel/stale/restart rules still classify the same occurrence.
        retained =
          c.generation_closed and c.charge_stopped and
            (slot[:deadline_ms] == nil or at < slot.deadline_ms) and is_nil(c.cancelled_attempt)

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
                BotRunLifecycle.step(
                  life,
                  checked,
                  life_context(state, record.context, record.attempt_id, false, at)
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
            state = put_in(state.control.trackers[elem(key, 0)].tracker, tracker)
            state = settle_join(state, key, input, record.correlation)
            state = settle_budget(state, key, record.correlation[:actual], at)

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
                :request_key
              ])

            slot =
              Map.merge(slot, %{
                phase: :settled,
                outcome: input["outcome"] || "completed",
                actual: record.correlation[:actual]
              })

            state = put_in(state.slots[key], slot)
            state = update_in(state.control.lifecycle.waits, &Map.delete(&1, input["action_id"]))

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

  defp local_precedence(state, _record, true), do: {state, true}

  defp local_precedence(state, record, false) do
    {:ok, wake} =
      PatternStep.decode(%{
        "type" => "input",
        "version" => 1,
        "kind" => "wake",
        "at_ms" => record.input["at_ms"]
      })

    {:ok, life, decision} =
      BotRunLifecycle.step(
        lifecycle(state, nil),
        wake,
        life_context(state, record.context, record.attempt_id, false, record.input["at_ms"])
      )

    {install_lifecycle(state, life, decision),
     decision not in [:unchanged, :late] and
       (not match?({:request_outcome, _}, decision) or
          decision == {:request_outcome, :out_of_budget})}
  end

  defp restore_waiting(state) do
    if active_count(state) > 0 and state.control.lifecycle.phase == :active,
      do: put_in(state.control.lifecycle.phase, :waiting),
      else: state
  end

  defp close_local(state, at) do
    Enum.reduce(state.slots, state, fn {key, slot}, acc ->
      if slot.kind == "local_work" and slot.phase == :running do
        input =
          outcome(slot.action_id, "failed", @refusal_schema, refusal(acc, key, "local_closed"), at)

        {:ok, checked} = PatternStep.decode(input)

        {:applied, tracker} =
          PatternStep.accept(acc.control.trackers[elem(key, 0)].tracker, checked)

        acc = put_in(acc.control.trackers[elem(key, 0)].tracker, tracker)
        acc = settle_join(acc, key, input, %{loss: :unavailable})
        acc = update_in(acc.control.lifecycle.waits, &Map.delete(&1, slot.action_id))

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

  defp invoke(state, record, callable) do
    c = state.control
    node = Map.fetch!(c.callables, callable)
    {module, function} = node.mfa
    {:ok, _} = PatternStep.decode(record.input)
    {:Transition, next_pattern, output} = apply(module, function, [node.state, record.input])
    true = output == :none or match?({:some, _}, output)
    hash = digest({record.input, record.correlation})
    state = put_in(state.control.invocations[record.id], hash)

    case output do
      :none ->
        if bytes(next_pattern) <= 65_536 and plain?(next_pattern),
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
              if bytes(next_pattern) <= 65_536 and plain?(next_pattern),
                do: put_in(state.control.callables[callable].state, next_pattern),
                else: state

            state = put_in(state.control.generation_closed, true)
            state = put_in(state.control.charge_stopped, true)

            {:ok, wake} =
              PatternStep.decode(%{
                "type" => "input",
                "version" => 1,
                "kind" => "wake",
                "at_ms" => record.input["at_ms"]
              })

            {:ok, life, decision} =
              BotRunLifecycle.step(
                lifecycle(state, nil),
                wake,
                life_context(
                  state,
                  record.context,
                  state.control.attempt_id,
                  true,
                  record.input["at_ms"]
                )
              )

            state = install_lifecycle(state, life, decision)

            state =
              if node.parent do
                deny(state, node.parent, "out_of_budget")
              else
                state
              end

            {classify(state, :over_cap), :none}

          bytes(next_pattern) > 65_536 or not plain?(next_pattern) ->
            {classify(state, :invalid_pattern_state), :none}

          true ->
            state = put_in(state.control.callables[callable].state, next_pattern)
            admit_request(state, value, ordinal, callable, record.input["at_ms"])
        end
    end
  end

  defp admit_request(state, value, ordinal, callable, at) do
    with {:ok, {:PatternStep, %{"type" => "request", "actions" => actions}} = checked} <-
           PatternStep.decode(value),
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
        {outcome, dispatch, error} = envelope_class(input["outcome"] || "completed", correlation)

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

  defp expire_waits(state, at) do
    Enum.reduce(state.slots, state, fn {key, slot}, acc ->
      if slot.kind in ["ask_person", "local_work", "model_call", "tool_call", "nested_callable"] and
           slot.phase in [:waiting, :running, :approval] and at >= slot.deadline_ms do
        record = %{
          version: 1,
          kind: :protocol,
          id: "expire:" <> occurrence_id(key),
          run_id: acc.control.run_id,
          attempt_id: slot.attempt_id,
          input:
            outcome(slot.action_id, "expired", @refusal_schema, refusal(acc, key, "expired"), at),
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

  defp lifecycle(state, ordinal) do
    life = state.control.lifecycle

    tracker =
      if ordinal, do: state.control.trackers[ordinal].tracker, else: {:PatternStepTracker, %{}}

    %{life | tracker: tracker}
  end

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
    state = put_in(state.control.lifecycle, %{life | tracker: {:PatternStepTracker, %{}}})

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
         true <- text?(opts[:identity], 160) and text?(opts[:run_id], 200),
         cap when is_integer(cap) and cap in 1..256 <- opts[:request_cap],
         {module, function, initial} <- opts[:pattern],
         true <-
           is_atom(module) and is_atom(function) and bytes(initial) <= 65_536 and plain?(initial),
         %{id: gate_id, version: version, call: call} <- opts[:gate],
         true <- text?(gate_id, 128) and is_integer(version) and version in 1..2_147_483_647,
         true <- is_function(call, 2) and is_function(opts[:clock], 0),
         true <- is_function(opts[:context], 0) and is_map(opts[:bindings]),
         true <-
           is_map(opts[:schemas]) and is_map(opts[:resources]) and is_map(opts[:effect_intent]),
         true <- text?(opts[:tenant], 200) and text?(opts[:principal], 200),
         {:ok, view} <- Run.status(opts[:run_owner], opts[:run_id]),
         true <- is_binary(view.current_attempt),
         %{cap: budget_cap, unit: unit, id: budget_id, incarnation: incarnation} <- opts[:budget],
         {:ok, budget} <- Budget.initial(budget_id, incarnation, budget_cap, unit),
         rule when rule in [:pause, :finish] <- opts[:budget_rule],
         deadline when is_integer(deadline) and deadline > 0 <- opts[:run_deadline],
         {:ok, pid} <- DynamicUnits.start(opts[:directory], opts[:identity]) do
      fingerprint =
        digest(
          {{module, function}, schema_identities(opts[:schemas]),
           binding_identities(opts[:bindings]), %{id: gate_id, version: version}, opts[:tenant],
           opts[:principal], cap, budget_cap, unit, rule, deadline}
        )

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
            depth: 0
          }
        },
        lifecycle: %{
          phase: if(view.outcome, do: :terminal, else: :active),
          waits: %{},
          tracker: {:PatternStepTracker, %{}},
          outcome: view.outcome,
          run_deadline: deadline,
          pause_deadline: nil
        },
        classification: :configured
      }

      s = %{opts: Map.new(opts), unit: pid, halted: nil, work: %{}, intents: %{}}
      snapshot = DurableUnit.snapshot(pid)

      result =
        cond do
          snapshot == @empty or
              (snapshot.control.run_id != opts[:run_id] and
                 snapshot.control.lifecycle.phase == :terminal and active_count(snapshot) == 0) ->
            commit(s, stable_id("configure:", opts[:run_id]), %{
              version: 1,
              kind: :configure,
              control: control
            })

          snapshot.control.fingerprint == fingerprint and snapshot.control.run_id == opts[:run_id] ->
            {:ok, s}

          true ->
            {:error, :incompatible_recovery, s}
        end

      with {:ok, s} <- result,
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
    state = snapshot(s)
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

  def handle_call({:input, id, input, context}, _, s) do
    {reply, s} = ingest(s, id, input, context)
    {:reply, reply, s}
  end

  def handle_call({:control, id, command, context}, _, s) do
    result = with {:ok, s} <- current(s), do: apply_control(s, id, command, context)

    case result do
      {:ok, s} -> {:reply, {:ok, :applied}, s}
      {:error, reason, s} -> {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_info({:durable_unit_input, id, %{version: 1, kind: :protocol} = record}, s) do
    result =
      with {:ok, s} <- current(s),
           {:ok, input, correlation} <-
             checked_ingress(s, record.input, Map.merge(record.context, record.correlation)),
           record = %{record | input: input, correlation: correlation},
           {:ok, s} <- commit(s, id, record),
           do: drain(s)

    case result do
      {:ok, s} -> {:noreply, s}
      {:error, _, s} -> {:noreply, s}
    end
  end

  def handle_info(%Outbox.Item{} = item, s) do
    if s.halted do
      {:noreply, s}
    else
      case drain(s) do
        {:ok, s} ->
          case ack(s, item) do
            :ok -> {:noreply, s}
            reason -> {:noreply, %{s | halted: reason}}
          end

        {:error, _, s} ->
          {:noreply, s}
      end
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp ingest(%{halted: reason} = s, _, _, _) when not is_nil(reason), do: {{:error, reason}, s}

  defp ingest(s, id, neutral, context) do
    with true <- text?(id, 160) and is_map(neutral) and is_map(context),
         true <- text?(context[:run_id], 200) and text?(context[:attempt_id], 200),
         false <- Map.has_key?(neutral, "at_ms"),
         {:ok, s} <- current(s),
         at when is_integer(at) and at > 0 <- s.opts.clock.(),
         input = Map.put(neutral, "at_ms", at),
         {:ok, _} <- PatternStep.decode(input),
         {:ok, input, correlation} <- checked_ingress(s, input, context),
         record = %{
           version: 1,
           kind: :protocol,
           id: id,
           input: input,
           run_id: context.run_id,
           attempt_id: context.attempt_id,
           correlation: correlation,
           context: Map.take(context, [:verified_person, :pause_deadline])
         },
         true <- plain?(record),
         :ok <-
           if(bytes({1, {id, record}}) <= @ingress_bytes, do: :ok, else: {:error, :input_too_large}),
         {:ok, record} <- original_record(s, id, record),
         :ok <- pause_operand(s, record.context, record.input["at_ms"]),
         result = DurableUnit.step(s.unit, id, record) do
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
      {:error, reason, s} -> {{:error, reason}, s}
      {:error, reason} -> {{:error, reason}, s}
      _ -> {{:error, :invalid_input}, s}
    end
  catch
    :exit, _ -> {{:indeterminate, :delivery}, %{s | halted: :delivery_unknown}}
  end

  defp checked_ingress(s, input, context) do
    correlation = Map.take(context, [:occurrence, :actual, :dispatch, :loss, :resource])
    key = context[:occurrence]
    slot = snapshot(s).slots[key]

    expected =
      cond do
        slot && slot.kind == "local_work" &&
            correlation[:loss] in [:killed, :timed_out, :unavailable] ->
          {@refusal_schema, 1}

        slot ->
          s.opts.bindings[slot.kind][:result]

        true ->
          nil
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
           do: {:ok, input, correlation},
           else: {:error, :invalid_correlation}

      input["kind"] in ["wake", "cancel"] ->
        {:ok, input, correlation}

      input["kind"] in ["action_outcome", "person_answer"] and is_nil(slot) ->
        {:ok, input, correlation}

      expected != nil and {input["schema_id"], input["schema_version"]} != expected ->
        {:ok, invalid_outcome(s, slot, input, "invalid_outcome"),
         Map.put(correlation, :loss, :unavailable)}

      true ->
        case check_payload(s, input) do
          :ok ->
            {:ok, input, correlation}

          {:error, reason} when not is_nil(slot) ->
            reason =
              if reason in [:too_large, :too_deep], do: "outcome_too_large", else: "invalid_outcome"

            {:ok, invalid_outcome(s, slot, input, reason),
             Map.put(correlation, :loss, :unavailable)}

          _ ->
            {:error, :invalid_payload}
        end
    end
  end

  defp invalid_outcome(s, slot, input, reason) do
    class = if slot.kind == "local_work", do: "failed", else: "unknown"

    outcome(
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
  defp original_record(s, id, candidate) do
    case find_input(s.opts.store, s.opts.identity, id, 1) do
      nil ->
        {:ok, candidate}

      %{kind: :protocol} = original ->
        comparable = fn r -> r |> put_in([:input, "at_ms"], 0) end

        if comparable.(original) == comparable.(candidate),
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

  defp current(%{halted: reason} = s) when not is_nil(reason), do: {:error, reason, s}

  defp current(s) do
    case DynamicUnits.start(s.opts.directory, s.opts.identity) do
      {:ok, pid} when pid == s.unit ->
        with {:ok, s} <- sync_run(s), do: consume_resources(s)

      {:ok, pid} ->
        with {:ok, s} <- recover_local(%{s | unit: pid, work: %{}}),
             {:ok, s} <- sync_run(s),
             {:ok, s} <- recover_intents(s),
             {:ok, s} <- release_waiting(s, "replacement", %{}),
             {:ok, s} <- consume_resources(s),
             do: drain(s)

      other ->
        storage_failure(s, other)
    end
  catch
    :exit, _ -> {:error, :ownership_unknown, %{s | halted: :ownership_unknown}}
  end

  defp sync_run(s) do
    with {:ok, view} <- Run.status(s.opts.run_owner, s.opts.run_id) do
      c = snapshot(s).control

      if c.run_revision == view.revision do
        if view.outcome, do: end_resources(s, view.outcome), else: {:ok, s}
      else
        with {:ok, s} <-
               commit(s, "run:" <> Integer.to_string(view.revision), %{
                 version: 1,
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
      _ -> {:error, :run_unavailable, %{s | halted: :run_unavailable}}
    end
  end

  defp recover_local(s) do
    Enum.reduce_while(snapshot(s).slots, {:ok, s}, fn {key, slot}, {:ok, acc} ->
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

  defp drain(%{halted: reason} = s) when not is_nil(reason), do: {:error, reason, s}

  defp drain(s) do
    state = snapshot(s)

    pending =
      state.slots
      |> Enum.filter(fn {_, slot} -> slot[:pending_input] != nil end)
      |> Enum.min_by(fn {_, slot} -> slot.pending_input.order end, fn -> nil end)

    finished_child =
      Enum.find(state.control.callables, fn {_, child} ->
        child.parent && (child.closed or state.control.generation_closed) &&
          (state.slots[child.parent].phase == :running or
             (state.slots[child.parent].phase == :settled and
                is_nil(state.slots[child.parent][:actual]))) &&
          Enum.all?(state.slots, fn {_, slot} ->
            slot.callable != occurrence_id(child.parent) or
              (slot.phase == :settled and (slot[:reservation] == nil or is_integer(slot[:actual])))
          end)
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
             do: drain(s)

      pending != nil and state.control.lifecycle.phase not in [:paused, :terminal] and
          not state.control.generation_closed ->
        {key, _} = pending

        with {:ok, s} <-
               commit(s, stable_id("resume:", {s.opts.run_id, key}), %{
                 version: 1,
                 kind: :resume_input,
                 occurrence: key
               }),
             do: drain(s)

      finished_child != nil ->
        {id, child} = finished_child
        budget = state.control.budgets[id]

        {:Transition, _, {:some, {:status, status}}} =
          Budget.step(budget.state, {s.opts.clock.(), :status})

        if status.reserved == 0 do
          result =
            if state.slots[child.parent].phase == :settled do
              commit(s, stable_id("nested-actual:", {s.opts.run_id, child.parent}), %{
                version: 1,
                kind: :nested_actual,
                occurrence: child.parent,
                actual: status.committed,
                at_ms: s.opts.clock.()
              })
            else
              internal_outcome(s, child.parent, "completed", "nested_completed", %{
                actual: status.committed
              })
            end

          with {:ok, s} <- result,
               do: drain(s)
        else
          {:ok, s}
        end

      next == nil ->
        {:ok, s}

      true ->
        {key, slot} = next
        before = state

        with {:ok, s} <- progress(s, key, slot) do
          if snapshot(s) == before, do: {:ok, s}, else: drain(s)
        end
    end
  end

  defp progress(s, {request, _}, %{phase: :checking}) do
    state = snapshot(s)

    candidates =
      for {{^request, _} = key, slot} <- Enum.sort(state.slots),
          slot.phase == :checking,
          do: {key, action(state, key)}

    rejected =
      Enum.find_value(candidates, fn {key, action} ->
        cond do
          check_payload(s, action) != :ok -> {key, "payload_schema"}
          not action_ids?(action) -> {key, "invalid_identity"}
          not Map.has_key?(s.opts.bindings, action["kind"]) -> {key, "missing_binding"}
          true -> nil
        end
      end)

    case rejected do
      {key, reason} ->
        commit(s, stable_id("precheck:", {s.opts.run_id, key}), %{
          version: 1,
          kind: :precheck,
          occurrence: key,
          reason: reason
        })

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
          version: 1,
          kind: :gate,
          schema_id: "elzoo.run-engine.gate-verdict",
          schema_version: 1,
          request: request,
          entries: entries,
          at_ms: s.opts.clock.()
        }

        commit(s, stable_id("gate:", {1, {s.opts.identity, s.opts.run_id}, request}), record)
    end
  end

  defp progress(s, key, %{phase: :refusing} = slot) do
    reason = slot[:refusal] || slot.verdict.reason
    class = if reason == "out_of_budget", do: "out_of_budget", else: "refused"
    child = snapshot(s).control.budgets[occurrence_id(key)]

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
    binding = s.opts.bindings[slot.kind]
    state = snapshot(s)
    action = action(state, key)
    facts = binding.facts.(action)

    facts =
      Map.merge(facts, %{binding_id: binding.id, binding_version: binding.version, action: action})

    commit(s, stable_id("admit:", {s.opts.run_id, key}), %{
      version: 1,
      kind: :admission,
      occurrence: key,
      facts: facts,
      at_ms: s.opts.clock.()
    })
  end

  defp progress(s, key, %{phase: :authorizing}) do
    context = action_context(s, key, %{})

    decision =
      case Authorization.decide(context.policy, context.proposal, context.authority) do
        {:ok, decision} -> decision
        _ -> :refused
      end

    commit(s, stable_id("auth:", {s.opts.run_id, key}), %{
      version: 1,
      kind: :authorization,
      occurrence: key,
      decision: decision,
      at_ms: s.opts.clock.()
    })
  end

  defp progress(s, key, %{phase: :approval} = slot) do
    if snapshot(s).control.lifecycle.phase == :terminal do
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
          with {:ok, s} <- continuation(s, key, :approval, %{request_key: request_key}),
               do: release_waiting(s, "retained", %{})

        _ ->
          internal_outcome(s, key, "refused", "approval_refused", %{actual: 0})
      end
    end
  end

  defp progress(s, key, %{phase: :ready} = slot) do
    with {:ok, s} <- sync_run(s) do
      state = snapshot(s)
      context = action_context(s, key, %{})
      decision = Authorization.decide(context.policy, context.proposal, context.authority)

      if permitted?(state, slot, s.opts.clock.()) and check_payload(s, action(state, key)) == :ok and
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

  defp dispatch(s, key, %{kind: "local_work"} = slot) do
    binding = s.opts.bindings[slot.kind]
    {module, function, args} = binding.work.(action(snapshot(s), key))
    at = s.opts.clock.()
    clock = s.opts.clock
    c = snapshot(s).control
    {schema_id, schema_version} = binding.result
    context = s.opts.context.()

    wrap = fn _work_ref, result ->
      {input, correlation} =
        case result do
          {:completed, value} ->
            {outcome(slot.action_id, "completed", schema_id, value, clock.()),
             %{occurrence: key, actual: slot.estimate}}

          {:lost, reason} ->
            {outcome(
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
         version: 1,
         kind: :protocol,
         id: id,
         run_id: c.run_id,
         attempt_id: slot.attempt_id,
         input: input,
         correlation: correlation,
         context: Map.take(context, [:pause_deadline])
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
    action = action(snapshot(s), key)
    binding = s.opts.bindings[slot.kind]
    continuation(s, key, :waiting, %{person_id: binding.person.(action)})
  end

  defp dispatch(s, key, %{kind: "nested_callable"} = slot) do
    facts = s.opts.bindings[slot.kind].nested.(action(snapshot(s), key))

    if bytes(facts.initial_state) <= 65_536 and
         check_payload(
           s,
           %{
             "schema_id" => facts.schema_id,
             "schema_version" => facts.schema_version,
             "payload" => facts.payload
           }
         ) == :ok do
      id = stable_id("nested:", {s.opts.run_id, key})

      commit(s, id, %{
        version: 1,
        id: id,
        kind: :nested,
        occurrence: key,
        facts: facts,
        at_ms: s.opts.clock.(),
        context: Map.take(s.opts.context.(), [:pause_deadline])
      })
    else
      internal_outcome(s, key, "refused", "nested_input", %{actual: 0})
    end
  end

  defp dispatch(s, key, %{kind: "finish"} = slot) do
    if slot.callable == "root" do
      source =
        Enum.find_value(snapshot(s).slots, fn {k, original} ->
          if original.action_id == action(snapshot(s), key)["payload"]["action_id"] and
               original.phase == :settled and original.outcome == "completed" and
               original.attempt_id == slot.attempt_id,
             do: k
        end)

      if source do
        commit(s, stable_id("finish:", {s.opts.run_id, key}), %{
          version: 1,
          kind: :finish,
          occurrence: key,
          source: source,
          at_ms: s.opts.clock.()
        })
      else
        with {:ok, s} <- continuation(s, key, :refusing, %{refusal: "completion_evidence"}),
             do: internal_outcome(s, key, "refused", "completion_evidence", %{actual: 0})
      end
    else
      with {:ok, s} <- continuation(s, key, :running, %{finish_callable: slot.callable}),
           do: internal_outcome(s, key, "completed", "finished", %{actual: 0})
    end
  end

  defp dispatch(s, key, %{kind: kind} = slot)
       when kind in ["resource_open", "resource_use", "resource_close"] do
    resource = s.opts.resources[slot.resource_name]
    action = action(snapshot(s), key)

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
              {:ok, _} -> {:ok, s}
              {:refused, reason} when reason in [:not_open, :paused] -> {:ok, s}
              _ -> {:error, :resource_dispatch_unknown, %{s | halted: :resource_dispatch_unknown}}
            end
        end
      end
    end
  end

  defp intent(s, key, slot) do
    descriptor = slot.intent
    startup = Map.fetch!(s.opts.effect_intent, descriptor.binding)

    if check_binding(s, descriptor) != :ok do
      {:error, :changed_binding, %{s | halted: :changed_binding}}
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
              {:error, :intent_recovery, %{s | halted: :intent_recovery}}
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
    commit(s, stable_id("continue:", {s.opts.run_id, key, phase, facts}), %{
      version: 1,
      kind: :continuation,
      occurrence: key,
      phase: phase,
      facts: facts
    })
  end

  defp internal_outcome(s, key, class, reason, correlation) do
    state = snapshot(s)
    slot = Map.fetch!(state.slots, key)

    if class in ["refused", "out_of_budget"] and
         slot.phase in [:ready, :approval, :running, :opening] do
      with {:ok, s} <- continuation(s, key, :refusing, %{refusal: reason}),
           do: internal_outcome(s, key, class, reason, correlation)
    else
      id =
        stable_id(
          "out:",
          {1, {s.opts.identity, s.opts.run_id}, elem(key, 0), elem(key, 1), :gate_refusal}
        )

      record = %{
        version: 1,
        kind: :protocol,
        id: id,
        run_id: state.control.run_id,
        attempt_id: slot.attempt_id,
        input:
          outcome(
            slot.action_id,
            class,
            @refusal_schema,
            refusal(state, key, reason),
            s.opts.clock.()
          ),
        correlation: Map.put(correlation, :occurrence, key),
        context: Map.take(s.opts.context.(), [:pause_deadline])
      }

      commit(s, id, record)
    end
  end

  defp finish_run(s, result, key) do
    evidence = if result == :completed, do: completion_evidence(s, key), else: nil
    reason = if snapshot(s).control.charge_stopped, do: "request_cap", else: "engine"

    case run_command(s, :complete, %{outcome: result, reason: reason, evidence_ref: evidence}) do
      {:ok, _, _} ->
        sync_run(s)

      {:unchanged, :duplicate, _} ->
        sync_run(s)

      _ ->
        case Run.status(s.opts.run_owner, s.opts.run_id) do
          {:ok, %{outcome: outcome}} when not is_nil(outcome) -> sync_run(s)
          _ -> {:error, :terminal_commit_pending, %{s | halted: :terminal_commit_pending}}
        end
    end
  end

  defp completion_evidence(s, key) do
    c = snapshot(s).control
    slot = snapshot(s).slots[key]
    # The caller's existing Writer/Store is the evidence authority. No invented
    # DU sequence or tuple is passed to Run as a completion reference.
    %{writer: writer, stream: stream} = s.opts.evidence

    event = %{
      run_id: c.run_id,
      attempt_id: c.attempt_id,
      operation_id: c.operation_id,
      action_id: slot.action_id
    }

    {:committed, sequence} =
      Elzoo.DurableLog.Writer.append(writer, [{"completion", 1, binary(event)}])

    %{stream: stream, sequence: sequence}
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
          {:halt, {:error, :cleanup_pending, %{acc | halted: :cleanup_pending}}}
      end
    end)
  end

  defp consume_resource(s, name, resource) do
    cursor = Map.get(snapshot(s).control.cursors, name, 0)
    {:ok, %{entries: entries}} = RunResource.read(resource, cursor)

    Enum.reduce_while(entries, {:ok, s}, fn entry, {:ok, acc} ->
      result =
        Enum.reduce_while(Enum.with_index(entry.inputs), {:ok, acc}, fn {input, index},
                                                                        {:ok, acc} ->
          key =
            Enum.find_value(snapshot(acc).slots, fn {key, slot} ->
              if slot.action_id == input["action_id"] and slot[:resource_name] == name, do: key
            end)

          id = stable_id("resource:", {s.opts.run_id, name, entry.seq, index})

          correlation = %{occurrence: key, resource: name}
          context = Map.take(acc.opts.context.(), [:pause_deadline])

          with {:ok, checked, correlation} <- checked_ingress(acc, input, correlation),
               :ok <- pause_operand(acc, context, input["at_ms"]) do
            record = %{
              version: 1,
              kind: :protocol,
              id: id,
              run_id: s.opts.run_id,
              attempt_id:
                if(key,
                  do: snapshot(acc).slots[key].attempt_id,
                  else: snapshot(acc).control.attempt_id
                ),
              input: checked,
              correlation: correlation,
              context: context
            }

            case commit(acc, id, record) do
              {:ok, acc} -> {:cont, {:ok, acc}}
              error -> {:halt, error}
            end
          else
            {:error, reason} -> {:halt, {:error, reason, acc}}
          end
        end)

      budget_owner =
        if entry.budget_command do
          {_, command} = entry.budget_command

          Enum.find_value(snapshot(acc).slots, fn {_, slot} ->
            if (slot[:resource_name] == name and slot[:reservation]) &&
                 Map.take(slot.reservation, [:cost_ref, :generation]) ==
                   Map.take(command, [:cost_ref, :generation]),
               do: slot.callable
          end)
        end

      with {:ok, acc} <- result,
           :ok <-
             if(entry.budget_command == nil or budget_owner != nil,
               do: :ok,
               else: {:error, :resource_budget, acc}
             ),
           {:ok, acc} <- resource_effects(acc, name, resource, entry.effects),
           {:ok, acc} <-
             commit(acc, stable_id("cursor:", {s.opts.run_id, name, entry.seq}), %{
               version: 1,
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
    end)
  end

  defp resource_effects(s, name, owner, effects) do
    Enum.reduce_while(effects, {:ok, s}, fn descriptor, {:ok, acc} ->
      key = {:resource, name, descriptor.identity}

      origin =
        Enum.find(snapshot(acc).slots, fn {_, slot} ->
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
            if slot[:request_key] do
              release_waiting(acc, "replacement", %{})
            else
              state = snapshot(acc)
              context = action_context(acc, occurrence, %{})

              cond do
                state.control.lifecycle.phase == :paused ->
                  {:ok, acc}

                permitted?(state, slot, acc.opts.clock.()) and
                  check_payload(acc, action(state, occurrence)) == :ok and
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
                else: {:error, :cleanup_pending, %{acc | halted: :cleanup_pending}}
            else
              {:error, :cleanup_pending, %{acc | halted: :cleanup_pending}}
            end
          else
            {:error, _, _} = error -> error
            _ -> {:error, :unknown_resource_intent, %{acc | halted: :unknown_resource_intent}}
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
      {:ok, _, _} -> with {:ok, s} <- sync_run(s), do: release_waiting(s, id, context)
      other -> {:error, {:run_control, other}, s}
    end
  end

  defp apply_control(s, id, %{kind: kind} = command, context) when kind in [:pause, :continue] do
    event =
      command
      |> Map.delete(:kind)
      |> Map.put(:control, kind)
      |> Map.put(:at_ms, s.opts.clock.())
      |> Map.put(:attempt_id, snapshot(s).control.attempt_id)

    state = snapshot(s)
    context = Map.take(context, [:verified_person, :pause_deadline])

    with {:ok, record} <-
           original_record(s, id, %{version: 1, kind: :lifecycle, command: event, context: context}),
         {:ok, _, _} <-
           BotRunLifecycle.step(
             lifecycle(state, nil),
             record.command,
             life_context(
               state,
               record.context,
               state.control.attempt_id,
               false,
               record.command.at_ms
             )
           ),
         {:ok, s} <- commit(s, id, record),
         {:ok, s} <-
           resource_control(
             s,
             if(snapshot(s).control.lifecycle.phase == :paused, do: :pause, else: :continue),
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
    c = snapshot(s).control

    if attempt != c.attempt_id do
      {:ok, s}
    else
      input = %{"type" => "input", "version" => 1, "kind" => "cancel", "attempt_id" => attempt}

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
    Enum.reduce_while(snapshot(s).slots, {:ok, s}, fn {key, slot}, {:ok, acc} ->
      recovering =
        slot.phase in [:running, :reconcile] and
          (id in ["startup", "replacement"] or
             slot.kind in ["resource_open", "resource_use", "resource_close"])

      if (slot.phase == :approval or recovering) and not is_nil(slot[:request_key]) and
           permitted?(snapshot(acc), slot, acc.opts.clock.()) and
           check_payload(acc, action(snapshot(acc), key)) == :ok do
        fresh =
          action_context(s, key, context)
          |> Map.take([:now, :max_age, :verifiers, :run, :policy, :proposal, :authority, :approver])

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

              with {:ok, acc} <- result,
                   do: {:cont, {:ok, acc}}

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
              {:halt, {:error, :changed_binding, %{acc | halted: :changed_binding}}}

            _ ->
              {:cont, {:ok, acc}}
          end
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp action_context(s, key, overrides) do
    state = snapshot(s)
    slot = state.slots[key]
    binding = s.opts.bindings[slot.kind]
    context = Map.merge(s.opts.context.(), overrides)

    Map.merge(context, %{
      now: s.opts.clock.(),
      proposal: Map.put(binding.proposal.(action(state, key)), :tenant, s.opts.tenant),
      authority: %{
        proposer: s.opts.principal,
        effect_class: binding.effect_class,
        own: context.authority,
        parent: state.control.callables[slot.callable].authority
      }
    })
  end

  defp recover_intents(s) do
    Enum.reduce_while(snapshot(s).slots, {:ok, s}, fn {key, slot}, {:ok, acc} ->
      if slot.phase in [:running, :reconcile] and
           slot.kind in ["model_call", "tool_call", "resource_open", "resource_use"] and
           is_nil(slot[:request_key]) do
        with {:ok, acc, owner} <- intent(acc, key, slot) do
          view = EffectIntent.status(owner)

          result =
            cond do
              not view.active ->
                continuation(acc, key, :reconcile, %{reconciliation: :read_only})

              view.attempts > 0 and slot.kind in ["model_call", "tool_call"] ->
                internal_outcome(acc, key, "unknown", "lost_outcome", %{dispatch: "unknown"})

              true ->
                facts = %{reconciliation: :active}

                with {:ok, acc} <- continuation(acc, key, :ready, facts) do
                  if snapshot(acc).control.lifecycle.phase == :paused,
                    do: {:ok, acc},
                    else: progress(acc, key, Map.merge(slot, Map.put(facts, :phase, :ready)))
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
    case DurableUnit.step(s.unit, id, record) do
      {:ok, _} ->
        {:ok, s}

      {:error, :input_id_conflict} ->
        # Internal logical IDs do not depend on sampled answer/time. Read the
        # winner, never invent a new ID to evade an uncertain append.
        winner = find_input(s.opts.store, s.opts.identity, id, 1)

        if winner &&
             Map.take(winner, [:kind, :request, :occurrence]) ==
               Map.take(record, [:kind, :request, :occurrence]),
           do: {:ok, s},
           else: storage_failure(s, {:error, :integrity_failure})

      other ->
        storage_failure(s, other)
    end
  catch
    :exit, _ -> {:error, :delivery_unknown, %{s | halted: :delivery_unknown}}
  end

  defp storage_failure(s, {:error, {:rejected, _}}) do
    case DynamicUnits.stop(s.opts.directory, s.opts.identity) do
      :ok -> {:error, :storage_rejected, %{s | halted: :storage_rejected}}
      _ -> {:error, :stop_unknown, %{s | halted: :stop_unknown}}
    end
  end

  defp storage_failure(s, {:error, reason}), do: {:error, reason, %{s | halted: reason}}
  defp storage_failure(s, _), do: {:error, :storage_unknown, %{s | halted: :storage_unknown}}

  defp ack(s, item) do
    {1, {:request, request}} = :erlang.binary_to_term(item.payload, [:safe])

    pending =
      Enum.any?(snapshot(s).slots, fn {{ordinal, _}, slot} ->
        ordinal == request and slot.phase in [:checking, :refusing, :allowed, :authorizing, :ready]
      end)

    if pending do
      :ok
    else
      case Outbox.ack(s.opts.store, item.idempotency_key, :crypto.strong_rand_bytes(16)) do
        {:committed, _} ->
          :ok

        {:indeterminate, receipt} ->
          case Elzoo.DurableLog.confirm_ack(s.opts.store, receipt) do
            {:committed, _} -> :ok
            _ -> :ack_unknown
          end

        {:conflict, _} ->
          case Elzoo.DurableLog.Store.read(s.opts.store, :read_ack, [item.idempotency_key]) do
            {:ok, %{state: :acked, idempotency_key: key}} when key == item.idempotency_key -> :ok
            _ -> :ack_unknown
          end

        _ ->
          :ack_unknown
      end
    end
  end

  defp sample_gate(s, action) do
    binding = s.opts.bindings[action["kind"]]

    try do
      {:ok, checked} =
        PatternStep.decode(%{"type" => "request", "version" => 1, "actions" => [action]})

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

  defp action(state, {request, index}) do
    case state.slots[{request, index}][:action] do
      nil ->
        {:ok, {:PatternStep, map}} =
          state.requests[request] |> Jason.decode!() |> PatternStep.decode()

        Enum.at(map["actions"], index)

      action ->
        action
    end
  end

  defp action_ids?(action), do: text?(action["id"], 200) and text?(action["schema_id"], 200)

  defp schema_identities(schemas),
    do: Map.new(schemas, fn {key, value} -> {key, {value.port, value.digest}} end)

  defp binding_identities(bindings),
    do: Map.new(bindings, fn {key, value} -> {key, {value.id, value.version}} end)

  defp snapshot(s) do
    if Process.alive?(s.unit) do
      DurableUnit.snapshot(s.unit)
    else
      {_, %{fold: fold}} = s.opts.store

      recovered =
        Elzoo.Checkpoint.recover(s.opts.store, s.opts.identity, fold, 1, fn bytes ->
          {:ok, :erlang.binary_to_term(bytes, [:safe])}
        end)

      recovered.model.state
    end
  end

  defp snapshot_value(control), do: %{control: control}

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

  defp fits?(state) do
    c = state.control
    reserved = (c.cap + 1 - map_size(c.receipts)) * 1_024 + active_count(state) * 4_096

    plain?(state) and bytes(c) + reserved <= @control_bytes and
      Enum.all?(state.slots, fn {_, slot} -> slot_fits?(slot) end) and
      bytes(state.slots) <= 8_388_608 and bytes(state.requests) <= @request_bytes and
      bytes({1, {String.duplicate("i", 160), state}}) <= @record_bytes
  end

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

  defp outcome(id, class, schema, payload, at),
    do: %{
      "type" => "input",
      "version" => 1,
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
end
